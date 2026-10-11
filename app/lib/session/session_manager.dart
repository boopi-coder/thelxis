import 'dart:async';
import 'dart:io' show Directory, InternetAddress;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/address_book.dart';
import '../core/identity.dart';
import '../core/log.dart';
import '../core/settings.dart';
import '../core/system_info.dart';
import '../core/trusted_devices.dart';
import '../net/connect_code.dart';
import '../net/connect_target.dart';
import '../net/connectivity/connectivity.dart';
import '../net/dialer.dart';
import '../net/discovery.dart';
import '../net/gateway.dart';
import '../net/handshake.dart' show generateNonce;
import '../net/inband_signaling.dart';
import '../net/listener.dart';
import '../net/net_address.dart';
import '../net/peer_identity.dart';
import '../net/signaling_channel.dart';
import '../files/files.dart';
import '../l10n/strings.dart';
import '../platform/host_platform.dart';
import '../platform/session_badge.dart';
import '../platform/impl/android_host.dart';
import '../protocol/models.dart';
import '../protocol/signaling_messages.dart';
import 'capture.dart';
import 'clipboard_sync.dart';
import 'host_credentials.dart';
import 'host_session.dart';
import 'ice_config.dart';
import 'prompts.dart';
import 'session_base.dart';
import 'session_history.dart';
import 'viewer_session.dart';
import 'webrtc_util.dart';

const _log = Logger('sessions');

/// A file-transfer event of some session, for in-app notifications
/// ("Alice sent report.pdf").
class FileNotice {
  const FileNotice(this.session, this.event);

  final SessionBase session;
  final FileTransferEvent event;

  /// The text to show, or null when the event is not worth a notification.
  String? text(FilesStrings strings) {
    final peer = session.peer.name;
    final name = event.transfer.name;
    return switch (event.kind) {
      FileTransferEventKind.received => strings.fileReceivedFrom(peer, name),
      // On the controlled device a file starting to arrive is worth knowing.
      FileTransferEventKind.incomingStarted => session.isHost ? strings.incomingFrom(peer, name) : null,
      FileTransferEventKind.sent => strings.fileSent(name),
      FileTransferEventKind.failed => strings.transferFailed(name),
      FileTransferEventKind.cancelled => null,
    };
  }
}

/// An offer code (`TX1.`) this device made and is waiting to hear back on
/// (PROTOCOL.md section 12). Single use; expires after ten minutes.
class PendingCodeOffer {
  PendingCodeOffer._({
    required this.code,
    required this.nonce,
    required this.expiresAt,
    required this.parts,
  });

  /// An offer without a PeerConnection, for UI tests that replace the
  /// manager's code methods.
  @visibleForTesting
  PendingCodeOffer.forTest({required this.code, required this.nonce, required this.expiresAt})
      : parts = null;

  /// The text to give to the other person.
  final String code;
  final String nonce;
  final DateTime expiresAt;
  final HostPeerParts? parts;
  Timer? _expiry;
  bool _closed = false;

  Duration get remaining => expiresAt.difference(DateTime.now());
  bool get isExpired => remaining <= Duration.zero;

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _expiry?.cancel();
    try {
      await parts?.pc.close();
    } on Object {
      // Already gone.
    }
  }
}

/// A user-presentable connection failure.
class ConnectException implements Exception {
  const ConnectException(this.message, {this.cancelled = false, this.kind});

  final String message;

  /// The user declined a prompt; nothing to report as an error.
  final bool cancelled;
  final DialFailure? kind;

  @override
  String toString() => message;
}

/// Redirects the OS-facing parts of every session this manager creates.
/// Production passes nothing; end-to-end tests give each peer its own incoming
/// folder and clipboard, since two peers in one process share the OS ones.
class SessionOverrides {
  const SessionOverrides({this.incomingDir, this.clipboard});

  /// Where received files land; null means `<Downloads>/Thelxis`.
  final Future<Directory> Function()? incomingDir;

  /// Clipboard to sync; null means the system clipboard.
  final ClipboardAccess? clipboard;
}

/// Owns the listener, the dialer and every live session; turns network events
/// and user actions into sessions and prompts.
class SessionManager extends ChangeNotifier {
  SessionManager({
    required this.settings,
    required this.identity,
    required this.systemInfo,
    required this.trusted,
    required this.addressBook,
    required this.credentials,
    required this.connectivity,
    required this.platform,
    required this.lan,
    required this.history,
    required this.badge,
    SignalingListener? listener,
    Dialer? dialer,
    this.onAttention,
    this.listenerPort = ThelxisPorts.signalingTcp,
    this.listenerAddress,
    this.overrides = const SessionOverrides(),
  }) {
    this.listener = listener ??
        SignalingListener(
          identity: identity,
          connectivity: connectivity,
          localInfo: _localInfo,
          admit: _admit,
        );
    this.dialer = dialer ??
        Dialer(
          identity: identity,
          localInfo: _localInfo,
          advertisedAddresses: connectivity.advertisedAddresses,
        );
  }

  final AppSettings settings;
  final Identity identity;
  final SystemInfo systemInfo;
  final TrustedDevices trusted;
  final AddressBook addressBook;
  final HostCredentials credentials;
  final Connectivity connectivity;
  final HostPlatform platform;
  final LanDiscovery lan;
  final SessionHistory history;

  /// The mandatory always-on-top "being controlled" badge (PROTOCOL.md 9).
  final SessionBadge badge;

  /// Brings the window to the front when something needs attention.
  final VoidCallback? onAttention;

  /// TCP port and bind address of the signaling listener (tests use an
  /// ephemeral loopback port).
  final int listenerPort;
  final InternetAddress? listenerAddress;
  final SessionOverrides overrides;

  late final SignalingListener listener;
  late final Dialer dialer;
  final PromptQueue prompts = PromptQueue();
  final StreamController<FileNotice> _fileNotices = StreamController<FileNotice>.broadcast();

  /// File-transfer events of every session (the UI turns them into toasts).
  Stream<FileNotice> get fileNotices => _fileNotices.stream;

  /// Language code of the current UI language, for text built without a
  /// BuildContext.
  String get languageCode => _strings.language.code;
  final CaptureRegistry captures = CaptureRegistry();

  final List<HostSession> _hosts = [];
  final List<ViewerSession> _viewers = [];
  StreamSubscription<IncomingPeer>? _incomingSub;
  StreamSubscription<void>? _captureStopSub;
  StreamSubscription<void>? _badgeStopSub;
  BadgeState? _lastBadge;
  Future<void> _applying = Future.value();
  bool? _lastUpnp;
  String? _lastManualKey;
  bool _gatewayBrowsing = false;
  late final OfficeGateway _gateway = OfficeGateway(
    connectivity: connectivity,
    findTarget: (id) => lan.find(id),
  );
  bool _started = false;
  bool _disposed = false;

  /// Sessions in which this device is being controlled.
  List<HostSession> get hostSessions => List.unmodifiable(_hosts);

  /// Sessions in which this device controls another one (ended ones stay until
  /// the UI dismisses them).
  List<ViewerSession> get viewerSessions => List.unmodifiable(_viewers);

  List<HostSession> get activeHostSessions => _hosts.where((s) => !s.isEnded).toList();

  /// Whether any session, incoming or outgoing, is still running. Updates
  /// install only while this is false.
  bool get hasActiveSessions =>
      _hosts.any((s) => !s.isEnded) || _viewers.any((s) => !s.isEnded);

  /// Incoming sessions that currently see this screen: capture running, or
  /// the session active / reconnecting. The badge and the banner show exactly
  /// these, and nothing else may hide them.
  List<HostSession> get liveHostSessions => _hosts
      .where((s) =>
          !s.isEnded &&
          (s.sharing || s.phase == SessionPhase.active || s.phase == SessionPhase.reconnecting))
      .toList();

  LocalPeerInfo _localInfo() => LocalPeerInfo(
        name: settings.deviceName,
        os: systemInfo.os,
        app: systemInfo.appVersion,
      );

  HostEnv get _hostEnv => HostEnv(
        settings: settings,
        identity: identity,
        trusted: trusted,
        credentials: credentials,
        platform: platform,
        captures: captures,
        incomingDir: overrides.incomingDir,
        clipboard: overrides.clipboard,
        requestApproval: _requestApproval,
        onNotice: (title, message) {
          unawaited(prompts.push(WarningPrompt(title: title, message: message)));
          onAttention?.call();
        },
      );

  ViewerEnv get _viewerEnv => ViewerEnv(
        settings: settings,
        userName: settings.deviceName,
        incomingDir: overrides.incomingDir,
        clipboard: overrides.clipboard,
      );

  // --- lifecycle ---------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _incomingSub = listener.incoming.listen(_onIncoming);
    // Android: the user tapped Stop in the "screen is being shared" notice.
    final android = _android;
    if (android != null) {
      _captureStopSub = android.captureStopRequests.listen((_) => unawaited(stopAllHostSessions()));
    }
    // The badge's Stop button ends every incoming session.
    _badgeStopSub = badge.stopRequests.listen((_) => unawaited(stopAllHostSessions()));
    settings.addListener(_onSettingsChanged);
    await applySettings();
  }

  void _onSettingsChanged() {
    unawaited(applySettings());
    _syncBadge();
  }

  /// Brings the listener, embedded TURN, port mappings and LAN responder in
  /// line with the settings. Serialised so rapid toggles cannot interleave.
  Future<void> applySettings() {
    _applying = _applying.then((_) => _apply()).catchError((Object e) {
      _log.e('applying settings failed', e);
    });
    return _applying;
  }

  /// UI strings for the current setting, independent of widget rebuild order.
  S get _strings => S.forLanguage(
        resolveLanguage(settings.language, PlatformDispatcher.instance.locale),
      );

  AndroidHostPlatform? get _android {
    final p = platform;
    return p is AndroidHostPlatform ? p : null;
  }

  /// Hands the hand-made router forwarding (Settings -> Connectivity) to the
  /// connectivity module, before it starts and again on every change.
  void _applyManualForwarding() {
    final f = settings.manualForwarding;
    final key = f == null ? '' : '${f.externalHost}|${f.signalingTcp}|${f.turnUdp}|${f.turnTcp}';
    if (key == _lastManualKey) return;
    _lastManualKey = key;
    try {
      connectivity.setManualForwarding(f);
    } on Object catch (e) {
      _log.w('applying manual forwarding failed', e);
    }
  }

  /// The office gateway (PROTOCOL.md section 11) runs only while it is on and
  /// incoming connections are accepted. It needs the LAN discovery table
  /// fresh, so a browser runs for as long as it is on, and the discovery
  /// replies announce it to the devices behind it.
  void _applyGateway() {
    final on = settings.officeGateway && settings.allowIncoming;
    listener.gatewayHandler = on ? _gateway.handle : null;
    lan.gatewayAdvertisement = on ? connectivity.advertisedAddresses : () => null;
    if (on && !_gatewayBrowsing) {
      _gatewayBrowsing = true;
      lan.acquireBrowsing();
    } else if (!on && _gatewayBrowsing) {
      _gatewayBrowsing = false;
      lan.releaseBrowsing();
    }
  }

  Future<void> _apply() async {
    if (_disposed) return;
    final android = _android;
    _applyManualForwarding();
    _applyGateway();
    if (settings.allowIncoming) {
      if (!listener.isListening) {
        await listener.start(port: listenerPort, address: listenerAddress);
      }
      if (settings.lanDiscovery || settings.officeGateway) {
        // A gateway must be discoverable by the devices behind it.
        await lan.startResponder();
      } else {
        await lan.stopResponder();
      }
      // Router discovery can take seconds; the listener and LAN access must
      // not wait for it, and the UI follows `connectivity.report` instead.
      if (_lastUpnp != settings.upnp) {
        _lastUpnp = settings.upnp;
        unawaited(connectivity.start(portMapping: settings.upnp));
      }
      if (android != null) {
        unawaited(android.startPresence());
        unawaited(android.acquireMulticastLock());
      }
    } else {
      await stopAllHostSessions();
      await listener.stop();
      await lan.stopResponder();
      _lastUpnp = null;
      unawaited(connectivity.stop());
      if (android != null) {
        unawaited(android.stopPresence());
        unawaited(android.releaseMulticastLock());
      }
    }
    notifyListeners();
  }

  // --- incoming ----------------------------------------------------------

  String? _admit(PeerIdentity peer, HelloWant want) {
    if (!settings.allowIncoming) return 'not_accepting';
    if (want == HelloWant.control) {
      if (!platform.hostSupported) return 'not_accepting';
      final unauth = _hosts.where((s) => s.phase == SessionPhase.connecting || s.phase == SessionPhase.authenticating).length;
      if (unauth >= 3 || activeHostSessions.length >= 4) return 'busy';
    }
    return null;
  }

  Future<ApprovalResult> _requestApproval(AcceptRequestPrompt prompt) {
    onAttention?.call();
    return prompts.push(prompt).timeout(prompt.timeout, onTimeout: () {
      prompt.resolve(ApprovalResult.denied);
      return ApprovalResult.denied;
    });
  }

  void _onIncoming(IncomingPeer incoming) {
    switch (incoming.want) {
      case HelloWant.control:
        unawaited(_startHost(
          peer: incoming.peer,
          channel: incoming.channel,
          sid: incoming.sid,
        ));
      case HelloWant.beControlled:
        unawaited(_handleReverseOffer(incoming));
    }
  }

  Future<void> _startHost({
    required PeerIdentity peer,
    required SignalingChannel channel,
    required String sid,
    TurnInfo? turn,
    NetAddress? turnHost,
    Permissions? reversePermissions,
  }) async {
    final session = HostSession(
      env: _hostEnv,
      peer: peer,
      channel: channel,
      sid: sid,
      turn: turn,
      turnHost: turnHost,
      reversePermissions: reversePermissions,
    );
    trackHostSession(session);
    onAttention?.call();
    await session.start();
  }

  /// Registers an incoming session (badge, banner, history). Public so tests
  /// can drive a session without a PeerConnection.
  @visibleForTesting
  void trackHostSession(HostSession session) {
    _track(session);
    _hosts.add(session);
    notifyListeners();
  }

  Future<void> _handleReverseOffer(IncomingPeer incoming) async {
    onAttention?.call();
    final prompt = ReverseOfferPrompt(peer: incoming.peer);
    final accepted = await prompts.push(prompt).timeout(const Duration(seconds: 30), onTimeout: () {
      prompt.resolve(false);
      return false;
    });
    if (!accepted) {
      incoming.channel.bye('denied');
      return;
    }
    final session = ViewerSession(
      env: _viewerEnv,
      peer: incoming.peer,
      sid: incoming.sid,
      channel: incoming.channel,
    );
    _track(session);
    _viewers.add(session);
    notifyListeners();
    await session.start();
  }

  // --- connection codes (PROTOCOL.md section 12) ---------------------------

  static const int maxPendingCodes = 3;
  static const Uuid _uuid = Uuid();
  final List<PendingCodeOffer> _codeOffers = [];

  /// Offer codes waiting for an answer, oldest first.
  List<PendingCodeOffer> get codeOffers => List.unmodifiable(_codeOffers);

  /// Host side: builds a fresh offer (public STUN forced on, ICE gathering
  /// complete) and returns its `TX1.` code. At most [maxPendingCodes] stay
  /// pending; the oldest is dropped to make room.
  Future<PendingCodeOffer> createCodeOffer({
    Duration lifetime = kCodeLifetime,
    Duration gatheringTimeout = const Duration(seconds: 5),
  }) async {
    if (!platform.hostSupported) {
      throw ConnectException(S.current.t('err.noHost'));
    }
    while (_codeOffers.length >= maxPendingCodes) {
      await discardCodeOffer(_codeOffers.first);
    }
    final parts = await createHostPeerConnection(buildRtcConfiguration(
      role: SignalingRole.listener,
      publicStun: true,
    ));
    try {
      final offer = await parts.pc.createOffer(kHostOfferConstraints);
      final gathering = IceGatheringWatch(parts.pc);
      await parts.pc.setLocalDescription(offer);
      await gathering.complete(timeout: gatheringTimeout);
      final sdp = (await parts.pc.getLocalDescription())?.sdp ?? offer.sdp!;
      final nonce = generateNonce();
      final expiresAt = DateTime.now().add(lifetime);
      final code = await buildOfferCode(
        identity: identity,
        name: settings.deviceName,
        os: systemInfo.os,
        nonce: nonce,
        exp: expiresAt.millisecondsSinceEpoch ~/ 1000,
        sdp: sdp,
      );
      if (code.length > kMaxCodeChars) {
        throw ConnectException(S.current.t('code.tooBig'));
      }
      final pending = PendingCodeOffer._(code: code, nonce: nonce, expiresAt: expiresAt, parts: parts);
      pending._expiry = Timer(lifetime, () => unawaited(discardCodeOffer(pending)));
      _codeOffers.add(pending);
      notifyListeners();
      return pending;
    } on Object {
      try {
        await parts.pc.close();
      } on Object {
        // Nothing left to clean up.
      }
      rethrow;
    }
  }

  /// Forgets a pending offer and closes its PeerConnection.
  Future<void> discardCodeOffer(PendingCodeOffer offer) async {
    if (!_codeOffers.remove(offer)) return;
    await offer._close();
    notifyListeners();
  }

  /// Host side: applies the viewer's `TX2.` code to [offer] and starts the
  /// session; authorization follows as for any other session. Throws
  /// [CodeException] for a bad, foreign or tampered code (the offer stays
  /// usable) and [ConnectException] for an expired offer.
  Future<HostSession> acceptAnswerCode(PendingCodeOffer offer, String text) async {
    if (offer.isExpired || !_codeOffers.contains(offer)) {
      throw ConnectException(S.current.t('code.expired'));
    }
    final answer = await parseAnswerCode(text, hostNonce: offer.nonce, ownKey: identity.publicKeyB64);
    // Single use: from here on the offer belongs to the session.
    _codeOffers.remove(offer);
    offer._expiry?.cancel();
    offer._closed = true;
    final session = HostSession(
      env: _hostEnv,
      peer: answer.peer,
      sid: _uuid.v4(),
      channel: InBandSignaling(
        identity: identity,
        role: SignalingRole.listener,
        peerKey: answer.key,
        hostNonce: offer.nonce,
        viewerNonce: answer.nonce,
      ),
      forcePublicStun: true,
    );
    trackHostSession(session);
    onAttention?.call();
    await session.startFromCode(offer.parts!, answer.sdp);
    return session;
  }

  /// Viewer side: parses and verifies a pasted `TX1.` code. Throws
  /// [CodeException]. The caller shows the host's name and ID for confirmation
  /// before [answerOfferCode].
  Future<OfferCode> readOfferCode(String text) =>
      parseOfferCode(text, ownKey: identity.publicKeyB64);

  /// Viewer side: answers a verified offer. Returns the running session (it
  /// waits for the host to apply the answer) and the `TX2.` text to send back.
  Future<({ViewerSession session, String answerCode})> answerOfferCode(OfferCode offer) async {
    final viewerNonce = generateNonce();
    final session = ViewerSession(
      env: _viewerEnv,
      peer: offer.peer,
      sid: _uuid.v4(),
      channel: InBandSignaling(
        identity: identity,
        role: SignalingRole.dialer,
        peerKey: offer.key,
        hostNonce: offer.nonce,
        viewerNonce: viewerNonce,
      ),
      forcePublicStun: true,
    );
    final String answerCode;
    try {
      final sdp = await session.prepareCodeAnswer(offer.sdp);
      answerCode = await buildAnswerCode(
        identity: identity,
        name: settings.deviceName,
        os: systemInfo.os,
        hostNonce: offer.nonce,
        viewerNonce: viewerNonce,
        sdp: sdp,
      );
      if (answerCode.length > kMaxCodeChars) {
        throw ConnectException(S.current.t('code.tooBig'));
      }
    } on Object catch (e) {
      await session.end('error');
      session.dispose();
      if (e is ConnectException) rethrow;
      _log.w('answering a code failed', e);
      throw ConnectException(S.current.t('code.failed'));
    }
    _track(session);
    _viewers.add(session);
    await addressBook.upsertPeer(offer.peer, connected: true);
    notifyListeners();
    session.activateFromCode();
    return (session: session, answerCode: answerCode);
  }

  // --- outgoing ----------------------------------------------------------

  /// Connects to [target] as the controlling side and returns the running
  /// session. [relayOnly] forces the media through the host's embedded TURN.
  /// Throws [ConnectException].
  Future<ViewerSession> connect(
    ConnectTarget target, {
    bool viewOnly = false,
    bool relayOnly = false,
  }) async {
    final dial = await _dialVerified(target, HelloWant.control);
    final session = ViewerSession(
      env: _viewerEnv,
      peer: dial.peer,
      sid: dial.sid,
      channel: dial.channel,
      turn: dial.turn,
      turnHost: dial.connectedTo,
      viewOnly: viewOnly,
      relayOnly: relayOnly,
      viaGateway: dial.connectedTo.isViaGateway,
    );
    _track(session);
    _viewers.add(session);
    notifyListeners();
    await session.start();
    return session;
  }

  /// Reverse mode: dials [target] and offers it control of this device.
  Future<HostSession> offerControl(
    ConnectTarget target, {
    Permissions permissions = const Permissions(),
  }) async {
    if (!platform.hostSupported) {
      throw ConnectException(S.current.t('err.noHost'));
    }
    final dial = await _dialVerified(target, HelloWant.beControlled);
    final session = HostSession(
      env: _hostEnv,
      peer: dial.peer,
      channel: dial.channel,
      sid: dial.sid,
      turn: dial.turn,
      turnHost: dial.connectedTo,
      reversePermissions: permissions,
    );
    trackHostSession(session);
    await session.start();
    return session;
  }

  /// Resolves addresses, confirms first contact when needed, dials, and
  /// records the peer in the address book.
  Future<DialResult> _dialVerified(ConnectTarget target, HelloWant want) async {
    final addresses = _resolveAddresses(target);
    if (addresses.isEmpty) {
      throw ConnectException(S.current.t('err.noAddress'));
    }
    var expected = target.id;
    try {
      if (expected == null) {
        final probed = await dialer.probe(addresses);
        final known = addressBook.byId(probed.id);
        final firstContact = known == null || known.key != probed.key;
        if (firstContact) {
          onAttention?.call();
          final ok = await prompts.push(FirstContactPrompt(peer: probed, address: addresses.first));
          if (!ok) throw ConnectException(S.current.t('err.cancelled'), cancelled: true);
        }
        expected = probed.id;
      }
      final dial = await dialer.dial(addresses: addresses, want: want, expectedId: expected);
      await addressBook.upsertPeer(
        dial.peer,
        // Through a gateway the connected address is the gateway's, not the
        // device's.
        reachedAt: dial.connectedTo.isViaGateway ? null : dial.connectedTo.hostPort,
        connected: true,
        gateways: [
          for (final g in target.gateways) g.hostPort,
          if (dial.connectedTo.isViaGateway) dial.connectedTo.hostPort,
        ],
      );
      return dial;
    } on DialException catch (e) {
      if (e.kind == DialFailure.identityMismatch) {
        unawaited(prompts.push(WarningPrompt(
          title: S.current.t('warn.mismatch.title'),
          message: S.current.t('warn.mismatch.body', {'address': addresses.first}),
        )));
        onAttention?.call();
      }
      throw ConnectException(_dialMessage(e), kind: e.kind);
    }
  }

  static String _dialMessage(DialException e) {
    final s = S.current;
    return switch (e.kind) {
      DialFailure.unreachable => s.t('err.unreachable'),
      DialFailure.identityMismatch => s.t('err.mismatch'),
      DialFailure.badSignature => s.t('err.badSignature'),
      DialFailure.notAccepting => s.t('err.notAccepting'),
      DialFailure.busy => s.t('err.busy'),
      DialFailure.rateLimited => s.t('err.rateLimited'),
      DialFailure.version => s.t('err.version'),
      DialFailure.timeout => s.t('err.timeout'),
      DialFailure.protocol => s.t('err.protocol'),
    };
  }

  List<NetAddress> _resolveAddresses(ConnectTarget target) {
    final out = <NetAddress>[...target.addresses];
    final id = target.id;
    if (id != null) {
      final entry = addressBook.byId(id);
      if (entry != null) out.addAll(parseAddressList(entry.addresses));
      for (final p in lan.peers) {
        if (p.id == id) out.add(NetAddress(p.host, p.port));
      }
      // Office gateways come last: the dialer races them behind the direct
      // routes, and only because the target's ID is known and gets verified.
      for (final g in [...target.gateways, ...parseAddressList(entry?.gateways ?? const [])]) {
        out.add(g.viaTarget(id));
      }
    }
    final seen = <NetAddress>{};
    return [
      for (final a in out)
        if (seen.add(a)) a,
    ];
  }

  // --- bookkeeping -------------------------------------------------------

  void _track(SessionBase s) {
    s.addListener(_onSessionChanged);
    s.onEnded = _onSessionEnded;
    s.onFileEvent = (session, event) {
      if (!_fileNotices.isClosed) _fileNotices.add(FileNotice(session, event));
    };
  }

  void _onSessionChanged() {
    notifyListeners();
    _syncBadge();
  }

  /// Shows, updates or (only when no incoming session sees the screen any
  /// more) dismisses the native badge. There is intentionally no other path
  /// that calls `dismiss`.
  void _syncBadge() {
    final live = liveHostSessions;
    if (live.isEmpty) {
      if (_lastBadge != null) {
        _lastBadge = null;
        unawaited(badge.dismiss());
      }
      return;
    }
    final strings = _strings;
    final names = [for (final h in live) h.peer.name];
    final since = live
        .map((h) => h.activeSince ?? h.startedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final next = BadgeState(
      peers: names,
      label: live.length == 1
          ? strings.t('badge.one', {'name': names.first})
          : strings.plural('badge.many', live.length),
      stopLabel: strings.t('badge.stop'),
      since: since,
      controlActive: live.any((h) => h.controlEnabled),
    );
    final last = _lastBadge;
    if (last != null &&
        last.label == next.label &&
        last.stopLabel == next.stopLabel &&
        last.since == next.since &&
        last.controlActive == next.controlActive &&
        listEquals(last.peers, next.peers)) {
      return;
    }
    _lastBadge = next;
    unawaited(badge.show(next));
  }

  void _onSessionEnded(SessionBase s) {
    s.removeListener(_onSessionChanged);
    if (s is HostSession) {
      _hosts.remove(s);
      prompts.cancelWhere((p) => p is AcceptRequestPrompt && p.peer.key == s.peer.key);
    }
    _syncBadge();
    unawaited(history.add(SessionRecord(
      sid: s.sid,
      incoming: s.isHost,
      peerName: s.peer.name,
      peerId: s.peer.id,
      peerOs: s.peer.os,
      startedAt: s.startedAt,
      durationSeconds: s.duration.inSeconds,
      path: s.stats.value.pathLabel,
      reason: s.endReason ?? 'user',
    )));
    notifyListeners();
  }

  /// Removes an ended viewer session once its tab is closed.
  void dismiss(ViewerSession session) {
    if (!session.isEnded) return;
    if (_viewers.remove(session)) {
      notifyListeners();
      session.dispose();
    }
  }

  /// "Stop all": ends every session in which this device is controlled.
  Future<void> stopAllHostSessions() async {
    for (final s in _hosts.toList()) {
      await s.end('user');
    }
  }

  Future<void> endAll() async {
    await stopAllHostSessions();
    for (final s in _viewers.toList()) {
      await s.end('user');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_onSettingsChanged);
    for (final o in _codeOffers.toList()) {
      unawaited(o._close());
    }
    _codeOffers.clear();
    if (_gatewayBrowsing) {
      _gatewayBrowsing = false;
      lan.releaseBrowsing();
    }
    unawaited(_incomingSub?.cancel());
    unawaited(_captureStopSub?.cancel());
    unawaited(_badgeStopSub?.cancel());
    unawaited(_fileNotices.close());
    unawaited(listener.dispose());
    super.dispose();
  }
}
