import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/log.dart';
import '../core/password_proof.dart';
import '../core/settings.dart';
import '../l10n/strings.dart';
import '../net/net_address.dart';
import '../net/signaling_channel.dart';
import '../protocol/control_messages.dart';
import '../protocol/input_messages.dart';
import '../protocol/models.dart';
import '../protocol/signaling_messages.dart';
import 'clipboard_sync.dart';
import 'ice_config.dart';
import 'input_encoder.dart';
import 'session_base.dart';
import 'webrtc_util.dart';

const _log = Logger('viewer');

/// What the UI should ask the user while authorization is pending.
class AuthPrompt {
  const AuthPrompt({
    required this.canPassword,
    required this.canRequest,
    this.error,
  });

  final bool canPassword;
  final bool canRequest;

  /// Message from the previous attempt, e.g. "Wrong password".
  final String? error;
}

/// Settings and identity facts the viewer needs.
class ViewerEnv {
  const ViewerEnv({required this.settings, required this.userName});

  final AppSettings settings;

  /// Name sent with `request` (shown on the host as who is asking).
  final String userName;
}

/// The controlling side of a session: answers the host's signed offer,
/// authorizes, renders video and forwards input.
class ViewerSession extends SessionBase {
  ViewerSession({
    required this.env,
    required super.peer,
    required super.sid,
    required this.channel,
    this.turn,
    this.turnHost,
    this._viewOnly = false,
  }) {
    encoder = InputEncoder(_sendInput);
  }

  final ViewerEnv env;
  final SignalingChannel channel;
  final TurnInfo? turn;
  final NetAddress? turnHost;

  /// Remote video; initialised by [start].
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  late final InputEncoder encoder;

  RTCPeerConnection? _pc;
  RTCDataChannel? _control;
  RTCDataChannel? _inputChannel;
  StatsPoller? _poller;
  ClipboardSync? _clipboard;
  StreamSubscription<SignalEvent>? _signalSub;
  MediaStream? _fallbackStream;

  bool _ended = false;
  bool _remoteSet = false;
  bool _viewOnly;
  bool _clipboardOn = true;
  bool _frameSeen = false;
  bool _triedTrusted = false;
  bool _passwordBusy = false;
  String _nonce = '';
  List<String> _methods = const [];
  final List<RTCIceCandidate> _pending = [];
  SessionPhase _phaseBeforeReconnect = SessionPhase.connecting;

  Permissions? _permissions;
  List<DisplayInfo> _displays = const [];
  String _activeDisplay = '0';
  QualityPreset _quality = QualityPreset.auto;
  AuthPrompt? _authPrompt;
  String? _notice;
  bool _becameTrusted = false;
  bool _signalingDetached = false;
  final List<String> chatLog = [];

  // --- test seams: lets tests drive the protocol without a PeerConnection ---

  /// Replaces reading the DTLS fingerprints from the PeerConnection.
  @visibleForTesting
  Future<({String? local, String? remote})> Function()? debugFingerprints;

  /// Observes every control message this session sends.
  @visibleForTesting
  void Function(Map<String, dynamic> message)? debugControlTap;

  /// Observes every input message this session sends (after view-only checks).
  @visibleForTesting
  void Function(Map<String, dynamic> message)? debugInputTap;

  /// Feeds a control-channel message as if it arrived from the host.
  @visibleForTesting
  void debugReceiveControl(Map<String, dynamic> json) =>
      _onControlMessage(RTCDataChannelMessage(jsonEncode(json)));

  /// Pretends the renderer drew its first frame.
  @visibleForTesting
  void debugFirstFrame() {
    _frameSeen = true;
    notifyListeners();
  }

  /// Feeds an ICE connection state as if the PeerConnection reported it.
  @visibleForTesting
  void debugIceState(RTCIceConnectionState state) => _onIceState(state);

  @override
  bool get isHost => false;

  Permissions? get permissions => _permissions;
  List<DisplayInfo> get displays => _displays;
  String get activeDisplayId => _activeDisplay;
  QualityPreset get quality => _quality;
  AuthPrompt? get authPrompt => _authPrompt;

  /// One-line user-facing note (auth failure, trust granted, ...).
  String? get notice => _notice;

  /// The host added this device to its Trusted Devices during this session.
  bool get becameTrusted => _becameTrusted;
  bool get viewOnly => _viewOnly || !(_permissions?.control ?? false);
  bool get userViewOnly => _viewOnly;
  bool get clipboardSyncOn => _clipboardOn && (_permissions?.clipboard ?? false);
  bool get hasFirstFrame => _frameSeen;
  bool get signalingDetached => _signalingDetached;

  DisplayInfo? get activeDisplay {
    for (final d in _displays) {
      if (d.id == _activeDisplay) return d;
    }
    return _displays.isEmpty ? null : _displays.first;
  }

  Future<void> start() async {
    _clipboardOn = env.settings.clipboardSync;
    _signalSub = channel.events.listen(_onSignal);
    unawaited(channel.closed.then((_) {
      if (!_ended) unawaited(end('error'));
    }));
    try {
      await renderer.initialize();
      renderer.onFirstFrameRendered = () {
        _frameSeen = true;
        notifyListeners();
      };
      final pc = await createPeerConnection(buildRtcConfiguration(
        role: channel.role,
        turn: turn,
        turnHost: turnHost,
        publicStun: env.settings.publicStun,
      ));
      _pc = pc;
      pc.onIceCandidate = _onLocalCandidate;
      pc.onIceConnectionState = _onIceState;
      pc.onTrack = _onTrack;
      pc.onDataChannel = _onDataChannel;
      _poller = StatsPoller(fetch: () => readStats(pc), target: stats)..start();
    } on Object catch (e, st) {
      _log.e('viewer setup failed', e, st);
      await end('error');
    }
  }

  // --- signaling & WebRTC ------------------------------------------------

  Future<void> _onSignal(SignalEvent e) async {
    if (_ended) return;
    try {
      switch (e) {
        case RemoteSdp(:final type, :final sdp):
          if (type == 'offer') await _answer(sdp);
        case RemoteCandidate(:final candidate, :final sdpMid, :final sdpMLineIndex):
          final c = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
          if (_remoteSet) {
            await _pc?.addCandidate(c);
          } else {
            _pending.add(c);
          }
        case RemoteBye(:final reason):
          _notice = reason == 'denied' ? S.current.t('viewer.denied') : _notice;
          await end(reason == 'denied' ? 'denied' : 'remote');
        case SignatureFailure(:final message):
          _notice = message;
          await end('security');
        case SignalingDetached():
          _signalingDetached = true;
          notifyListeners();
        case SignalingResumed():
          _signalingDetached = false;
          notifyListeners();
      }
    } on Object catch (err) {
      _log.w('signal handling failed', err);
    }
  }

  Future<void> _answer(String sdp) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteSet = true;
    final answer = await pc.createAnswer(kAnswerConstraints);
    await pc.setLocalDescription(answer);
    await channel.sendAnswer(answer.sdp!);
    for (final c in _pending) {
      await pc.addCandidate(c);
    }
    _pending.clear();
  }

  void _onLocalCandidate(RTCIceCandidate c) {
    final text = c.candidate;
    if (_ended || text == null || text.isEmpty) return;
    channel.sendCandidate(candidate: text, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex);
  }

  Future<void> _onTrack(RTCTrackEvent event) async {
    if (event.track.kind != 'video') return;
    try {
      if (event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
      } else {
        // The host announced no stream id: wrap the track in a local stream.
        final stream = await createLocalMediaStream('thelxis-remote');
        await stream.addTrack(event.track);
        _fallbackStream = stream;
        renderer.srcObject = stream;
      }
      notifyListeners();
    } on Object catch (e) {
      _log.w('attaching remote video failed', e);
    }
  }

  void _onIceState(RTCIceConnectionState s) {
    if (_ended) return;
    switch (s) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        if (phase == SessionPhase.reconnecting) setPhase(_phaseBeforeReconnect);
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        if (phase != SessionPhase.reconnecting && phase != SessionPhase.ended) {
          _phaseBeforeReconnect = phase;
          setPhase(SessionPhase.reconnecting);
        }
      default:
        break;
    }
  }

  void _onDataChannel(RTCDataChannel dc) {
    switch (dc.label) {
      case 'control':
        _control = dc;
        dc.onMessage = _onControlMessage;
      case 'input':
        _inputChannel = dc;
      case 'files':
        filesChannel = dc;
    }
  }

  // --- authorization -----------------------------------------------------

  void _onControlMessage(RTCDataChannelMessage raw) {
    if (_ended) return;
    final m = ControlMessage.parse(decodeJsonMessage(raw));
    if (m == null) return;
    switch (m) {
      case HelloMessage():
        _onHello(m);
      case AuthResultMessage():
        _onAuthResult(m);
      case DisplaysMessage(:final items, :final active):
        _displays = items;
        _activeDisplay = active;
        notifyListeners();
      case PermissionsMessage(:final permissions):
        // Release first: once control is off, `_sendInput` drops everything.
        if (!permissions.control) encoder.releaseAll();
        _permissions = permissions;
        if (!permissions.clipboard) _clipboard?.stop();
        notifyListeners();
      case ClipboardMessage(:final text):
        if (_permissions?.clipboard ?? false) unawaited(_clipboard?.applyRemote(text));
      case ChatMessage(:final text):
        chatLog.add(text.length > 2000 ? text.substring(0, 2000) : text);
        notifyListeners();
      case ByeMessage():
        unawaited(end('remote'));
      default:
        break;
    }
  }

  void _onHello(HelloMessage hello) {
    _nonce = hello.nonce;
    _methods = hello.methods;
    setPhase(SessionPhase.authenticating);
    if (_methods.contains('trusted') && !_triedTrusted) {
      _triedTrusted = true;
      _sendControl(const AuthMessage.trusted());
      return;
    }
    _promptUser();
  }

  void _promptUser({String? error}) {
    final canPassword = _methods.contains('password');
    final canRequest = _methods.contains('request');
    if (!canPassword && canRequest) {
      // Nothing to ask: the host will show its accept prompt.
      _authPrompt = null;
      requestAccess();
      return;
    }
    _authPrompt = AuthPrompt(canPassword: canPassword, canRequest: canRequest, error: error);
    notifyListeners();
  }

  /// Sends the password proof. The password is used only to derive the key
  /// and is never transmitted (PROTOCOL.md 6.1).
  Future<void> submitPassword(String password) async {
    if (_passwordBusy || _ended) return;
    final pc = _pc;
    if (pc == null && debugFingerprints == null) return;
    _passwordBusy = true;
    try {
      final fps = await (debugFingerprints?.call() ?? readFingerprints(pc!));
      final local = fps.local;
      final remote = fps.remote;
      if (local == null || remote == null) {
        _promptUser(error: S.current.t('viewer.notReady'));
        return;
      }
      final key = await derivePasswordKey(password, peer.id);
      final proof = await computePasswordProofB64(
        key: key,
        nonce: _nonce,
        fingerprintA: local,
        fingerprintB: remote,
      );
      _authPrompt = null;
      _notice = null;
      notifyListeners();
      _sendControl(AuthMessage.password(proof));
    } finally {
      _passwordBusy = false;
    }
  }

  /// Asks the host's user to accept this connection.
  void requestAccess() {
    _authPrompt = null;
    _notice = S.current.t('viewer.waitingAccept');
    setPhase(SessionPhase.awaitingApproval);
    _sendControl(AuthMessage.request(env.userName));
  }

  void _onAuthResult(AuthResultMessage r) {
    if (r.ok) {
      _permissions = r.permissions ?? Permissions.none;
      _becameTrusted = r.trusted;
      _authPrompt = null;
      _notice = null;
      setPhase(SessionPhase.active);
      if (_permissions!.clipboard && _clipboardOn) unawaited(_startClipboard());
      return;
    }
    switch (r.reason) {
      case 'not_trusted':
        _promptUser();
      case 'bad_password':
        if (r.retry) {
          _promptUser(error: S.current.t('viewer.wrongPassword'));
        } else {
          _failAuth(S.current.t('viewer.wrongPassword.final'));
        }
      case 'locked':
        _failAuth(S.current.t('viewer.locked'));
      case 'denied':
        _failAuth(S.current.t('viewer.denied'), reason: 'denied');
      case 'not_allowed':
        _failAuth(S.current.t('viewer.notAllowed'), reason: 'denied');
      default:
        _failAuth(S.current.t('viewer.refused'));
    }
  }

  void _failAuth(String message, {String reason = 'error'}) {
    _notice = message;
    _authPrompt = null;
    notifyListeners();
    unawaited(end(reason));
  }

  // --- user actions ------------------------------------------------------

  void selectDisplay(String id) => _sendControl(SelectDisplayMessage(id));

  void setQuality(QualityPreset preset) {
    _quality = preset;
    _sendControl(QualityMessage(preset));
    notifyListeners();
  }

  void setViewOnly(bool value) {
    if (value) encoder.releaseAll();
    _viewOnly = value;
    notifyListeners();
  }

  void setClipboardSync(bool on) {
    _clipboardOn = on;
    if (on && (_permissions?.clipboard ?? false)) {
      unawaited(_startClipboard());
    } else {
      _clipboard?.stop();
    }
    notifyListeners();
  }

  void sendChat(String text) {
    if (text.trim().isEmpty) return;
    _sendControl(ChatMessage(text));
    chatLog.add('me: $text');
    notifyListeners();
  }

  Future<void> _startClipboard() async {
    _clipboard ??= ClipboardSync(onLocalChange: (t) => _sendControl(ClipboardMessage(t)));
    await _clipboard!.start();
  }

  void _sendControl(ControlMessage m) {
    final json = m.toJson();
    debugControlTap?.call(json);
    unawaited(sendJson(_control, json));
  }

  void _sendInput(InputMessage m) {
    if (viewOnly || _ended) return;
    debugInputTap?.call(m.toJson());
    final dc = _inputChannel;
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) return;
    unawaited(dc.send(RTCDataChannelMessage(jsonEncode(m.toJson()))));
  }

  // --- teardown ----------------------------------------------------------

  @override
  Future<void> end([String reason = 'user']) async {
    if (_ended) return;
    _ended = true;
    _poller?.stop();
    encoder
      ..releaseAll()
      ..dispose();
    _clipboard?.dispose();
    if (reason != 'remote' && reason != 'denied') {
      await sendJson(_control, const ByeMessage('user').toJson());
    }
    channel.bye(switch (reason) {
      'error' || 'security' => 'error',
      'timeout' => 'timeout',
      'denied' => 'denied',
      _ => 'user',
    });
    await _signalSub?.cancel();
    // Let the last control message reach the wire before the channel closes.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final files = filesChannel;
    filesChannel = null;
    try {
      renderer.srcObject = null;
      await files?.close();
      await _control?.close();
      await _inputChannel?.close();
      await _pc?.close();
      await _fallbackStream?.dispose();
    } on Object catch (e) {
      _log.d('viewer teardown: $e');
    }
    markEnded(reason);
  }

  /// Releases the renderer. Called by the session manager once the UI has
  /// closed the session's tab, so no widget still paints the texture.
  @override
  void dispose() {
    unawaited(renderer.dispose());
    super.dispose();
  }
}
