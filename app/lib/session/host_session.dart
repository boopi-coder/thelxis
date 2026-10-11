import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/identity.dart';
import '../core/log.dart';
import '../core/settings.dart';
import '../core/trusted_devices.dart';
import '../files/files.dart';
import '../l10n/strings.dart';
import '../net/handshake.dart';
import '../net/net_address.dart';
import '../net/signaling_channel.dart';
import '../platform/host_platform.dart';
import '../platform/impl/android_host.dart' show CapturePermissionDenied;
import '../protocol/control_messages.dart';
import '../protocol/input_messages.dart';
import '../protocol/models.dart';
import '../protocol/signaling_messages.dart';
import 'capture.dart';
import 'clipboard_sync.dart';
import 'host_auth.dart';
import 'host_credentials.dart';
import 'host_input.dart';
import 'ice_config.dart';
import 'prompts.dart';
import 'quality.dart';
import 'session_base.dart';
import 'webrtc_util.dart';

const _log = Logger('host');

/// Everything a [HostSession] needs from the app, bundled so the session can
/// be constructed uniformly by the manager.
class HostEnv {
  HostEnv({
    required this.settings,
    required this.identity,
    required this.trusted,
    required this.credentials,
    required this.platform,
    required this.captures,
    required this.requestApproval,
    required this.onNotice,
    this.startCapture = ScreenCapture.start,
    this.incomingDir,
    this.clipboard,
  });

  final AppSettings settings;
  final Identity identity;
  final TrustedDevices trusted;
  final HostCredentials credentials;
  final HostPlatform platform;
  final CaptureRegistry captures;

  /// Where files sent by the viewer land; null means `<Downloads>/Thelxis`.
  final Future<Directory> Function()? incomingDir;

  /// Clipboard to sync; null means the system clipboard.
  final ClipboardAccess? clipboard;

  /// Starts capturing a display; replaceable in tests.
  final Future<MediaStream> Function(HostDisplay display, List<HostDisplay> all, {int fps})
      startCapture;

  /// Shows the accept prompt; resolves with the user's decision.
  final Future<ApprovalResult> Function(AcceptRequestPrompt prompt) requestApproval;

  /// Surfaces a notice the user must see (failed SDP signature, screen
  /// capture refused).
  final void Function(String title, String message) onNotice;
}

/// The controlled side of a session (PROTOCOL.md sections 4 to 6): owns the
/// PeerConnection, authorizes the viewer, captures the screen and injects
/// input.
class HostSession extends SessionBase {
  HostSession({
    required this.env,
    required super.peer,
    required this.channel,
    required super.sid,
    this.turn,
    this.turnHost,
    this.reversePermissions,
  }) {
    _input = HostInputDispatcher(env.platform.input);
  }

  final HostEnv env;
  final SignalingChannel channel;
  final TurnInfo? turn;
  final NetAddress? turnHost;

  /// Set when this host dialed out (reverse mode): the local user already
  /// consented, so the viewer's `request` is granted with these permissions.
  final Permissions? reversePermissions;

  late final HostInputDispatcher _input;
  RTCPeerConnection? _pc;
  RTCDataChannel? _control;
  RTCDataChannel? _inputChannel;
  RTCRtpSender? _sender;
  HostAuthenticator? _auth;
  StatsPoller? _poller;
  ClipboardSync? _clipboard;
  StreamSubscription<SignalEvent>? _signalSub;

  Permissions _permissions = Permissions.none;
  bool _authorized = false;
  bool _authBusy = false;
  bool _usedPassword = false;
  bool _ended = false;
  bool _remoteSet = false;
  bool _captureHeld = false;
  bool _sharing = false;

  /// Set when `auth_result ok` goes out. The `files` channel opens before
  /// authorization, so file access must stay shut until then.
  bool _accessGranted = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  List<HostDisplay> _displays = const [];
  HostDisplay? _active;
  MediaStream? _stream;
  int _captureFps = 30;
  QualityPreset _quality = QualityPreset.auto;

  Future<void> _mediaOps = Future.value();
  Timer? _authTimer;
  Timer? _restartTimer;
  Timer? _failTimer;
  SessionPhase _phaseBeforeReconnect = SessionPhase.connecting;

  final List<String> chatLog = [];

  // --- test seams (see ViewerSession) ---------------------------------------

  @visibleForTesting
  Future<({String? local, String? remote})> Function()? debugFingerprints;

  @visibleForTesting
  void Function(Map<String, dynamic> message)? debugControlTap;

  @visibleForTesting
  void debugReceiveControl(Map<String, dynamic> json) =>
      _onControlMessage(RTCDataChannelMessage(jsonEncode(json)));

  /// Feeds an `input`-channel message as if the viewer sent it.
  @visibleForTesting
  void debugReceiveInput(Map<String, dynamic> json) =>
      _onInputMessage(RTCDataChannelMessage(jsonEncode(json)));

  /// Attaches file transfer to an in-memory channel (tests).
  @visibleForTesting
  void debugAttachFiles(FileChannel channel) => attachFiles(
        channel,
        isHost: true,
        filesAllowed: _filesAllowed,
        incomingDir: env.incomingDir,
      );

  bool _filesAllowed() => _accessGranted && _permissions.files && !_ended;

  /// Pretends the control channel opened (sends `hello`).
  @visibleForTesting
  void debugControlOpened() => _onControlState(RTCDataChannelState.RTCDataChannelOpen);

  @override
  bool get isHost => true;

  Permissions get permissions => _permissions;

  /// The PeerConnection, for end-to-end tests that read its stats.
  @visibleForTesting
  RTCPeerConnection? get debugPeerConnection => _pc;

  /// True from the moment the screen is being captured for the viewer until
  /// capture has fully stopped. The session badge and banner stay visible for
  /// as long as this is true, whatever the protocol phase says.
  bool get sharing => _sharing;
  QualityPreset get quality => _quality;

  /// Whether the viewer may currently inject input.
  bool get controlEnabled => _permissions.control && env.platform.inputSupported;

  Future<void> start() async {
    _signalSub = channel.events.listen(_onSignal);
    unawaited(channel.closed.then((_) {
      if (!_ended) unawaited(end('error'));
    }));
    try {
      final config = buildRtcConfiguration(
        role: channel.role,
        turn: turn,
        turnHost: turnHost,
        publicStun: env.settings.publicStun,
      );
      final pc = await createPeerConnection(config);
      _pc = pc;
      pc.onIceCandidate = _onLocalCandidate;
      pc.onIceConnectionState = _onIceState;

      MediaStream? tag;
      try {
        // A stream id in the SDP lets the viewer attach the track to a stream.
        tag = await createLocalMediaStream('thelxis-screen');
      } on Object catch (e) {
        _log.d('no msid stream: $e');
      }
      final tx = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendOnly,
          streams: tag == null ? null : [tag],
        ),
      );
      _sender = tx.sender;

      final control = await pc.createDataChannel('control', RTCDataChannelInit()..ordered = true);
      final input = await pc.createDataChannel('input', RTCDataChannelInit()..ordered = true);
      final files = await pc.createDataChannel('files', RTCDataChannelInit()..ordered = true);
      _control = control;
      _inputChannel = input;
      filesChannel = files;
      // Wrap synchronously: the viewer may send as soon as the channel opens.
      attachFiles(
        RtcFileChannel(files),
        isHost: true,
        filesAllowed: _filesAllowed,
        incomingDir: env.incomingDir,
      );
      control.onDataChannelState = _onControlState;
      control.onMessage = _onControlMessage;
      input.onMessage = _onInputMessage;
      if (control.state == RTCDataChannelState.RTCDataChannelOpen) _onControlState(control.state!);

      final offer = await pc.createOffer(kHostOfferConstraints);
      await pc.setLocalDescription(offer);
      await channel.sendOffer(offer.sdp!);

      _poller = StatsPoller(fetch: () => readStats(pc), target: stats)..start();
    } on Object catch (e, st) {
      _log.e('host session setup failed', e, st);
      await end('error');
    }
  }

  // --- signaling ---------------------------------------------------------

  Future<void> _onSignal(SignalEvent e) async {
    if (_ended) return;
    try {
      switch (e) {
        case RemoteSdp(:final type, :final sdp):
          if (type == 'answer') await _applyAnswer(sdp);
        case RemoteCandidate(:final candidate, :final sdpMid, :final sdpMLineIndex):
          final c = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
          if (_remoteSet) {
            await _pc?.addCandidate(c);
          } else {
            _pendingCandidates.add(c);
          }
        case RemoteBye():
          await end('remote');
        case SignatureFailure(:final message):
          env.onNotice(S.current.t('warn.sig.title'), message);
          await end('error');
        case SignalingDetached():
          _log.d('signaling dropped; media continues');
        case SignalingResumed():
          if (_remoteSet && _iceNeedsRestart) unawaited(_restartIce());
      }
    } on Object catch (err, st) {
      _log.w('signal handling failed', err);
      _log.d('$st');
    }
  }

  Future<void> _applyAnswer(String sdp) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteSet = true;
    for (final c in _pendingCandidates) {
      await pc.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  void _onLocalCandidate(RTCIceCandidate c) {
    final text = c.candidate;
    if (_ended || text == null || text.isEmpty) return;
    channel.sendCandidate(candidate: text, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex);
  }

  // --- ICE health --------------------------------------------------------

  bool _iceNeedsRestart = false;

  void _onIceState(RTCIceConnectionState s) {
    if (_ended) return;
    switch (s) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _iceNeedsRestart = false;
        _restartTimer?.cancel();
        _failTimer?.cancel();
        _restartTimer = _failTimer = null;
        if (phase == SessionPhase.reconnecting) setPhase(_phaseBeforeReconnect);
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _enterReconnecting();
        _restartTimer ??= Timer(const Duration(seconds: 3), () {
          _restartTimer = null;
          unawaited(_restartIce());
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _enterReconnecting();
        _failTimer ??= Timer(const Duration(seconds: 20), () {
          _log.w('ICE failed for 20 s, ending session');
          unawaited(end('timeout'));
        });
        unawaited(_restartIce());
      default:
        break;
    }
  }

  void _enterReconnecting() {
    _iceNeedsRestart = true;
    if (phase != SessionPhase.reconnecting && phase != SessionPhase.ended) {
      _phaseBeforeReconnect = phase;
      setPhase(SessionPhase.reconnecting);
    }
  }

  Future<void> _restartIce() async {
    final pc = _pc;
    if (_ended || pc == null || !_remoteSet) return;
    try {
      await pc.restartIce();
      final offer = await pc.createOffer(kIceRestartConstraints);
      await pc.setLocalDescription(offer);
      await channel.sendOffer(offer.sdp!);
    } on Object catch (e) {
      _log.w('ICE restart failed', e);
    }
    // Keep retrying until connected or the 20 s failure timer ends the session.
    if (!_ended && _iceNeedsRestart) {
      _restartTimer?.cancel();
      _restartTimer = Timer(const Duration(seconds: 8), () {
        _restartTimer = null;
        if (_iceNeedsRestart) unawaited(_restartIce());
      });
    }
  }

  // --- control channel ---------------------------------------------------

  void _onControlState(RTCDataChannelState state) {
    if (_ended) return;
    if (state == RTCDataChannelState.RTCDataChannelOpen && _auth == null) {
      _sendHello();
    }
  }

  void _sendHello() {
    final nonce = generateNonce();
    final auth = HostAuthenticator(
      nonce: nonce,
      peerKey: peer.key,
      trust: env.trusted,
      credentials: env.credentials,
      requireApproval: env.settings.requireApproval,
      defaultPermissions: env.settings.defaultPermissions,
      inputSupported: env.platform.inputSupported,
      preApprovedPermissions: reversePermissions,
    );
    _auth = auth;
    setPhase(SessionPhase.authenticating);
    _send(HelloMessage(methods: auth.methods, nonce: nonce));
    _authTimer = Timer(const Duration(seconds: 90), () {
      if (!_authorized) unawaited(end('timeout'));
    });
  }

  void _send(ControlMessage m) {
    final json = m.toJson();
    debugControlTap?.call(json);
    unawaited(sendJson(_control, json));
  }

  void _onControlMessage(RTCDataChannelMessage raw) {
    if (_ended) return;
    final json = decodeJsonMessage(raw);
    final m = ControlMessage.parse(json);
    if (m == null) return;
    switch (m) {
      case AuthMessage():
        unawaited(_onAuth(m));
      case ByeMessage():
        unawaited(end('remote'));
      case SelectDisplayMessage(:final id):
        if (_authorized) _enqueue(() => _selectDisplay(id));
      case QualityMessage(:final preset):
        if (_authorized) _enqueue(() => _setQuality(preset));
      case ClipboardMessage(:final text):
        if (_authorized && _permissions.clipboard) unawaited(_clipboard?.applyRemote(text));
      case ChatMessage(:final text):
        if (_authorized) {
          chatLog.add(text.length > 2000 ? text.substring(0, 2000) : text);
          notifyListeners();
        }
      default:
        break;
    }
  }

  Future<void> _onAuth(AuthMessage msg) async {
    final auth = _auth;
    if (auth == null || _authorized || _authBusy) return;
    _authBusy = true;
    try {
      final pc = _pc;
      if (pc == null && debugFingerprints == null) return;
      final fps = await (debugFingerprints?.call() ?? readFingerprints(pc!));
      var decision = await auth.evaluate(
        msg,
        localFingerprint: fps.local,
        remoteFingerprint: fps.remote,
      );
      if (decision is AuthNeedsApproval) {
        decision = await _askUser(auth, decision);
      }
      if (_ended) return;
      switch (decision) {
        case AuthGrant():
          _usedPassword = msg.method == 'password';
          await _grant(decision);
        case AuthDeny(:final reason, :final retry):
          _send(AuthResultMessage.fail(reason, retry: retry));
          if (!retry) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await end(reason == 'denied' ? 'denied' : 'error');
          }
        case AuthNeedsApproval():
          break;
      }
    } finally {
      _authBusy = false;
    }
  }

  Future<AuthDecision> _askUser(HostAuthenticator auth, AuthNeedsApproval need) async {
    setPhase(SessionPhase.awaitingApproval);
    final prompt = AcceptRequestPrompt(
      peer: peer,
      claimedUser: need.user,
      proposed: env.settings.defaultPermissions,
      canControl: env.platform.inputSupported,
      viaPassword: need.method == 'password',
    );
    ApprovalResult result;
    try {
      result = await env.requestApproval(prompt);
    } on Object {
      result = ApprovalResult.denied;
    }
    if (_ended) return const AuthDeny('denied');
    setPhase(SessionPhase.authenticating);
    if (!result.accepted) return const AuthDeny('denied');
    return auth.approved(result.permissions, alwaysAllow: result.alwaysAllow);
  }

  Future<void> _grant(AuthGrant grant) async {
    _authorized = true;
    _authTimer?.cancel();
    _permissions = grant.permissions;
    if (grant.trusted && !env.trusted.isTrusted(peer.key)) {
      await env.trusted.add(
        key: peer.key,
        id: peer.id,
        name: peer.name,
        permissions: grant.permissions,
      );
    }
    // Capture first: on Android this shows the system consent dialog, and the
    // viewer should keep seeing "waiting" rather than an empty picture.
    try {
      await _prepareCapture();
    } on CapturePermissionDenied catch (e) {
      _log.w('screen capture refused: ${e.message}');
      env.onNotice(
        S.current.t('warn.capture.title'),
        S.current.t('warn.capture.body', {'name': peer.name}),
      );
      _authorized = false;
      _send(const AuthResultMessage.fail('not_allowed'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await end('denied');
      return;
    } on Object catch (e, st) {
      _log.e('could not start capture', e, st);
      _authorized = false;
      _send(const AuthResultMessage.fail('not_allowed'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await end('error');
      return;
    }
    if (_ended) return;
    _send(AuthResultMessage.ok(_permissions, trusted: env.trusted.isTrusted(peer.key)));
    _accessGranted = true;
    _sendDisplays();
    if (_permissions.clipboard) await _startClipboard();
    if (!_ended) setPhase(SessionPhase.active);
  }

  // --- media -------------------------------------------------------------

  Future<void> _prepareCapture() async {
    final platform = env.platform;
    if (await platform.permissionStatus(HostPermission.screenCapture) == PermissionStatus.denied) {
      await platform.requestPermission(HostPermission.screenCapture);
    }
    await env.captures.acquire(platform);
    _captureHeld = true;
    _sharing = true;
    notifyListeners();
    _displays = await platform.displays();
    if (_displays.isEmpty) throw StateError('No displays');
    _active = _displays.firstWhere((d) => d.primary, orElse: () => _displays.first);
    _input
      ..display = _active
      ..enabled = controlEnabled;
    if (_permissions.view) await _captureInto(_active!);
  }

  Future<void> _captureInto(HostDisplay display) async {
    final profile = qualityProfileFor(_quality);
    final next = await env.startCapture(display, _displays, fps: profile.captureFps);
    final tracks = next.getVideoTracks();
    if (tracks.isEmpty) {
      await next.dispose();
      throw StateError('Capture produced no video');
    }
    final old = _stream;
    await _sender?.replaceTrack(tracks.first);
    _stream = next;
    _captureFps = profile.captureFps;
    await _applyQuality();
    if (old != null) await _stopStream(old);
  }

  Future<void> _stopStream(MediaStream stream) async {
    try {
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    } on Object catch (e) {
      _log.d('stopping capture stream: $e');
    }
  }

  /// Capture changes run one after another: overlapping re-captures would
  /// leak streams and race on the sender.
  void _enqueue(Future<void> Function() op) {
    _mediaOps = _mediaOps.then((_) => _ended ? null : op()).catchError((Object e) {
      _log.w('media operation failed', e);
    });
  }

  Future<void> _selectDisplay(String id) async {
    final target = _displays.where((d) => d.id == id).firstOrNull;
    if (!ScreenCapture.canRetarget ||
        target == null ||
        target.id == _active?.id ||
        !_permissions.view) {
      return;
    }
    _input.releaseAll();
    try {
      await _captureInto(target);
    } on Object catch (e) {
      _log.w('display switch failed', e);
      return;
    }
    _active = target;
    _input.display = target;
    _sendDisplays();
  }

  Future<void> _setQuality(QualityPreset preset) async {
    _quality = preset;
    final profile = qualityProfileFor(preset);
    // Re-capturing would repeat the Android consent dialog, and mobile capture
    // ignores the requested frame rate anyway; only desktop re-captures.
    if (ScreenCapture.canRetarget && profile.captureFps != _captureFps && _active != null && _permissions.view) {
      try {
        await _captureInto(_active!);
      } on Object catch (e) {
        _log.w('re-capture at new frame rate failed', e);
      }
    } else {
      await _applyQuality();
    }
    notifyListeners();
  }

  Future<void> _applyQuality() async {
    final sender = _sender;
    if (sender == null) return;
    final p = qualityProfileFor(_quality);
    try {
      await sender.setParameters(RTCRtpParameters(
        encodings: [
          RTCRtpEncoding(
            maxBitrate: p.maxBitrate,
            maxFramerate: p.maxFramerate,
            // Null leaves the encoder's own layering untouched.
            numTemporalLayers: null,
            scaleResolutionDownBy: null,
          ),
        ],
        degradationPreference: degradationFor(p.degradation),
      ));
    } on Object catch (e) {
      _log.w('applying quality failed', e);
    }
  }

  void _sendDisplays() {
    final a = _active;
    if (a == null) return;
    _send(DisplaysMessage(
      items: [
        for (final d in _displays)
          DisplayInfo(
            id: d.id,
            name: d.name,
            width: d.pixelWidth,
            height: d.pixelHeight,
            primary: d.primary,
          ),
      ],
      active: a.id,
    ));
  }

  // --- clipboard & input -------------------------------------------------

  Future<void> _startClipboard() async {
    _clipboard ??= ClipboardSync(
      onLocalChange: (text) => _send(ClipboardMessage(text)),
      readClipboard: env.clipboard?.read,
      writeClipboard: env.clipboard?.write,
    );
    await _clipboard!.start();
  }

  void _onInputMessage(RTCDataChannelMessage raw) {
    if (_ended || !_authorized) return;
    final m = InputMessage.parse(decodeJsonMessage(raw));
    if (m != null) _input.handle(m);
  }

  /// Local user pauses or resumes the viewer's control (banner button).
  void setControlAllowed(bool allowed) {
    if (_ended || !_authorized) return;
    _permissions = _permissions.copyWith(control: allowed);
    _input.enabled = controlEnabled;
    if (!allowed) _input.releaseAll();
    _send(PermissionsMessage(_permissions));
    notifyListeners();
  }

  // --- teardown ----------------------------------------------------------

  @override
  Future<void> end([String reason = 'user']) async {
    if (_ended) return;
    _ended = true;
    _accessGranted = false;
    _authTimer?.cancel();
    _restartTimer?.cancel();
    _failTimer?.cancel();
    _poller?.stop();
    _clipboard?.dispose();
    _input
      ..enabled = false
      ..releaseAll();

    final byeReason = switch (reason) {
      'timeout' => 'timeout',
      'error' => 'error',
      _ => 'user',
    };
    if (reason != 'remote') {
      await sendJson(_control, ByeMessage(byeReason).toJson());
    }
    channel.bye(switch (reason) {
      'denied' => 'denied',
      'timeout' => 'timeout',
      'error' => 'error',
      _ => 'user',
    });
    await _signalSub?.cancel();
    // Let the last control message reach the wire before the channel closes.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final stream = _stream;
    _stream = null;
    if (stream != null) await _stopStream(stream);
    if (_captureHeld) {
      _captureHeld = false;
      await env.captures.release(env.platform);
    }
    _sharing = false;
    await detachFiles();
    try {
      await _control?.close();
      await _inputChannel?.close();
      await _pc?.close();
    } on Object catch (e) {
      _log.d('closing peer connection: $e');
    }
    if (_authorized && _usedPassword) env.credentials.onSessionSucceeded();
    markEnded(reason);
  }
}
