import 'dart:async';

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
import '../platform/host_platform.dart';
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
    SignalingListener? listener,
    Dialer? dialer,
    this.onAttention,
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

  /// Brings the window to the front when something needs attention.
  final VoidCallback? onAttention;

  late final SignalingListener listener;
  late final Dialer dialer;
  final PromptQueue prompts = PromptQueue();
  final CaptureRegistry captures = CaptureRegistry();

  final List<HostSession> _hosts = [];
  final List<ViewerSession> _viewers = [];
  StreamSubscription<IncomingPeer>? _incomingSub;
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
        onSecurityWarning: (title, message) {
          unawaited(prompts.push(WarningPrompt(title: title, message: message)));
          onAttention?.call();
        },
      );

  // --- lifecycle ---------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _incomingSub = listener.incoming.listen(_onIncoming);
    settings.addListener(_onSettingsChanged);
    await applySettings();
  }

  void _onSettingsChanged() => unawaited(applySettings());

  /// Brings the listener, embedded TURN, port mappings and LAN responder in
  /// line with the settings. Serialised so rapid toggles cannot interleave.
  Future<void> applySettings() {
    _applying = _applying.then((_) => _apply()).catchError((Object e) {
      _log.e('applying settings failed', e);
    });
    return _applying;
  }

  Future<void> _apply() async {
    if (_disposed) return;
    if (settings.allowIncoming) {
      if (_lastUpnp != settings.upnp || !listener.isListening) {
        await connectivity.start(portMapping: settings.upnp);
        _lastUpnp = settings.upnp;
      }
      if (!listener.isListening) await listener.start();
      if (settings.lanDiscovery) {
        await lan.startResponder();
      } else {
        await lan.stopResponder();
      }
    } else {
      await stopAllHostSessions();
      await listener.stop();
      await lan.stopResponder();
      await connectivity.stop();
      _lastUpnp = null;
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
    _track(session);
    _hosts.add(session);
    notifyListeners();
    onAttention?.call();
    await session.start();
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
      throw const ConnectException('This device cannot be controlled remotely.');
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
    _track(session);
    _hosts.add(session);
    notifyListeners();
    await session.start();
    return session;
  }

  /// Resolves addresses, confirms first contact when needed, dials, and
  /// records the peer in the address book.
  Future<DialResult> _dialVerified(ConnectTarget target, HelloWant want) async {
    final addresses = _resolveAddresses(target);
    if (addresses.isEmpty) {
      throw const ConnectException(
        'No address is known for this ID yet. Ask for an invite link, or enter ID@address.',
      );
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
          if (!ok) throw const ConnectException('Cancelled.', cancelled: true);
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
          title: 'Identity mismatch',
          message: 'The device at ${addresses.first} is not the one with the ID you '
              'entered. This can mean the address changed hands, or that someone is '
              'intercepting the connection. Nothing was sent to it.',
        )));
        onAttention?.call();
      }
      throw ConnectException(e.message, kind: e.kind);
    }
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
    s.addListener(notifyListeners);
    s.onEnded = _onSessionEnded;
  }

  void _onSessionEnded(SessionBase s) {
    s.removeListener(notifyListeners);
    if (s is HostSession) {
      _hosts.remove(s);
      prompts.cancelWhere((p) => p is AcceptRequestPrompt && p.peer.key == s.peer.key);
    }
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
    unawaited(listener.dispose());
    super.dispose();
  }
}
