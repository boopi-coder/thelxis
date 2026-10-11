import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:flutter/foundation.dart';

import '../core/address_book.dart';
import '../core/identity.dart';
import '../core/log.dart';
import '../core/settings.dart';
import '../core/system_info.dart';
import '../core/trusted_devices.dart';
import '../net/connect_target.dart';
import '../net/connectivity/connectivity.dart';
import '../net/dialer.dart';
import '../net/discovery.dart';
import '../net/listener.dart';
import '../net/net_address.dart';
import '../net/peer_identity.dart';
import '../net/signaling_channel.dart';
import '../l10n/strings.dart';
import '../platform/host_platform.dart';
import '../platform/session_badge.dart';
import '../platform/impl/android_host.dart';
import '../protocol/models.dart';
import '../protocol/signaling_messages.dart';
import 'capture.dart';
import 'host_credentials.dart';
import 'host_session.dart';
import 'prompts.dart';
import 'session_base.dart';
import 'session_history.dart';
import 'viewer_session.dart';

const _log = Logger('sessions');

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

  late final SignalingListener listener;
  late final Dialer dialer;
  final PromptQueue prompts = PromptQueue();
  final CaptureRegistry captures = CaptureRegistry();

  final List<HostSession> _hosts = [];
  final List<ViewerSession> _viewers = [];
  StreamSubscription<IncomingPeer>? _incomingSub;
  StreamSubscription<void>? _captureStopSub;
  StreamSubscription<void>? _badgeStopSub;
  BadgeState? _lastBadge;
  Future<void> _applying = Future.value();
  bool? _lastUpnp;
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
        requestApproval: _requestApproval,
        onNotice: (title, message) {
          unawaited(prompts.push(WarningPrompt(title: title, message: message)));
          onAttention?.call();
        },
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

  Future<void> _apply() async {
    if (_disposed) return;
    final android = _android;
    if (settings.allowIncoming) {
      if (!listener.isListening) {
        await listener.start(port: listenerPort, address: listenerAddress);
      }
      if (settings.lanDiscovery) {
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
      env: ViewerEnv(settings: settings, userName: settings.deviceName),
      peer: incoming.peer,
      sid: incoming.sid,
      channel: incoming.channel,
    );
    _track(session);
    _viewers.add(session);
    notifyListeners();
    await session.start();
  }

  // --- outgoing ----------------------------------------------------------

  /// Connects to [target] as the controlling side and returns the running
  /// session. Throws [ConnectException].
  Future<ViewerSession> connect(ConnectTarget target, {bool viewOnly = false}) async {
    final dial = await _dialVerified(target, HelloWant.control);
    final session = ViewerSession(
      env: ViewerEnv(settings: settings, userName: settings.deviceName),
      peer: dial.peer,
      sid: dial.sid,
      channel: dial.channel,
      turn: dial.turn,
      turnHost: dial.connectedTo,
      viewOnly: viewOnly,
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
        reachedAt: dial.connectedTo.hostPort,
        connected: true,
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
    unawaited(_incomingSub?.cancel());
    unawaited(_captureStopSub?.cancel());
    unawaited(_badgeStopSub?.cancel());
    unawaited(listener.dispose());
    super.dispose();
  }
}
