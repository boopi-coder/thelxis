// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/net/connect_target.dart';
import 'package:thelxis/net/connectivity/connectivity_impl.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/host_session.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_base.dart';
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/session/viewer_session.dart';

import '../../test/support/fakes.dart';
import 'recorders.dart';

/// Captures the application log so a failing scenario can print what led to
/// it, and mirrors it to stdout so it lands in the CI log.
class E2ELog {
  static final List<String> lines = [];

  static void install() {
    Logger.sink = (level, line) {
      final stamped = '${DateTime.now().toIso8601String().substring(11, 23)} $line';
      lines.add(stamped);
      if (lines.length > 600) lines.removeAt(0);
      print(stamped);
    };
  }
}

/// Polls [condition] every few milliseconds until it holds.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String what = 'condition',
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      throw TestFailure('Timed out after ${timeout.inSeconds} s waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Like [waitUntil] for a condition that needs `await` (WebRTC stats).
Future<void> waitUntilAsync(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  Duration poll = const Duration(milliseconds: 250),
  String what = 'condition',
}) async {
  final sw = Stopwatch()..start();
  while (!await condition()) {
    if (sw.elapsed > timeout) {
      throw TestFailure('Timed out after ${timeout.inSeconds} s waiting for: $what');
    }
    await Future<void>.delayed(poll);
  }
}

/// Answers the prompts a real user would, and remembers what was asked.
class PromptResponder {
  PromptResponder(this._queue) {
    _queue.addListener(_check);
  }

  final PromptQueue _queue;
  bool accept = true;
  bool alwaysAllow = false;

  /// What an accepted request grants; null takes the host's proposal.
  Permissions? grant;
  final List<Prompt<Object?>> seen = [];

  Iterable<T> asked<T extends Prompt<Object?>>() => seen.whereType<T>();

  void _check() {
    final p = _queue.current;
    if (p == null || seen.any((s) => identical(s, p))) return;
    seen.add(p);
    switch (p) {
      case AcceptRequestPrompt():
        p.resolve(accept
            ? ApprovalResult(accepted: true, permissions: grant ?? p.proposed, alwaysAllow: alwaysAllow)
            : ApprovalResult.denied);
      case ReverseOfferPrompt():
        p.resolve(accept);
      case FirstContactPrompt():
        p.resolve(accept);
      case WarningPrompt():
        p.resolve(null);
    }
  }

  void dispose() => _queue.removeListener(_check);
}

/// One app instance: identity, settings, stores, the real listener, dialer,
/// embedded TURN and session manager. Only hardware and OS facing parts are
/// replaced by recorders.
class E2ENode {
  E2ENode._({
    required this.name,
    required this.identity,
    required this.settings,
    required this.trusted,
    required this.book,
    required this.credentials,
    required this.connectivity,
    required this.platform,
    required this.injector,
    required this.badge,
    required this.clipboard,
    required this.incoming,
    required this.manager,
    required this.prompts,
  }) {
    manager.addListener(_tapNewSessions);
  }

  final String name;
  final Identity identity;
  final AppSettings settings;
  final TrustedDevices trusted;
  final AddressBook book;
  final HostCredentials credentials;
  final ConnectivityService connectivity;
  final FakeHostPlatform platform;
  final RecordingInjector injector;
  final FakeBadge badge;
  final FakeClipboard clipboard;
  final Directory incoming;
  final SessionManager manager;
  final PromptResponder prompts;

  /// Every control message this node's sessions sent, in order.
  final List<Map<String, dynamic>> sentControl = [];
  final Set<Object> _tapped = {};

  static Future<E2ENode> create(String name, {required bool listening, int displays = 1}) async {
    // Each node needs its own preference store: the plugin's singleton would
    // otherwise be shared, and with it the trusted devices and address book.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final identity = await Identity.generate();
    final settings = AppSettings(prefs, defaultDeviceName: name);
    await settings.setUpnp(false);
    await settings.setLanDiscovery(false);
    await settings.setAllowIncoming(listening);

    final connectivity = ConnectivityService(
      config: const ConnectivityConfig(turnUdpPort: 0, turnTcpPort: 0),
    );
    final injector = RecordingInjector();
    final platform = FakeHostPlatform(injector: injector, displayCount: displays);
    final badge = FakeBadge();
    final clipboard = FakeClipboard(name);
    final incoming = await Directory.systemTemp.createTemp('thelxis_e2e_${name.toLowerCase()}_in_');
    final trusted = TrustedDevices(prefs);
    final book = AddressBook(prefs);
    final credentials = HostCredentials(identity: identity, settings: settings);
    final manager = SessionManager(
      settings: settings,
      identity: identity,
      systemInfo: SystemInfo(
        os: 'linux',
        osVersion: 'e2e',
        arch: 'x64',
        hostname: name,
        appVersion: '0.1.0',
        defaultDeviceName: name,
      ),
      trusted: trusted,
      addressBook: book,
      credentials: credentials,
      connectivity: connectivity,
      platform: platform,
      lan: LanDiscovery(
        identity: identity,
        localInfo: () => LocalPeerInfo(name: name, os: 'linux', app: '0.1.0'),
        signalingPort: () => 0,
      ),
      history: SessionHistory(settings),
      badge: badge,
      listenerPort: 0,
      listenerAddress: InternetAddress.anyIPv4,
      overrides: SessionOverrides(incomingDir: () async => incoming, clipboard: clipboard.access),
    );
    final node = E2ENode._(
      name: name,
      identity: identity,
      settings: settings,
      trusted: trusted,
      book: book,
      credentials: credentials,
      connectivity: connectivity,
      platform: platform,
      injector: injector,
      badge: badge,
      clipboard: clipboard,
      incoming: incoming,
      manager: manager,
      prompts: PromptResponder(manager.prompts),
    );
    await manager.start();
    if (listening) {
      // The embedded TURN starts in the background; a dial that races it would
      // get no relay credentials.
      await waitUntil(
        () => connectivity.report.value.turnRunning && manager.listener.isListening,
        what: '$name: listener and embedded TURN up',
      );
    }
    return node;
  }

  /// Attaches the control tap to sessions the moment the manager tracks them,
  /// before their first message goes out.
  void _tapNewSessions() {
    for (final s in manager.hostSessions) {
      if (_tapped.add(s)) s.debugControlTap = sentControl.add;
    }
    for (final s in manager.viewerSessions) {
      if (_tapped.add(s)) s.debugControlTap = sentControl.add;
    }
  }

  HostSession get hostSession => manager.hostSessions.single;

  Future<HostSession> awaitHostSession() async {
    await waitUntil(() => manager.hostSessions.isNotEmpty, what: '$name: incoming host session');
    return manager.hostSessions.single;
  }

  Iterable<Map<String, dynamic>> sent(String type) => sentControl.where((m) => m['t'] == type);

  Future<void> shutDown() async {
    await manager.endAll();
    for (final v in manager.viewerSessions) {
      manager.dismiss(v);
    }
    // Turning "allow incoming" off stops the listener, the embedded TURN and
    // the port mappings, exactly as the settings switch does.
    await settings.setAllowIncoming(false);
    await manager.applySettings();
    await connectivity.stop();
    prompts.dispose();
    manager.removeListener(_tapNewSessions);
    manager.dispose();
    try {
      await incoming.delete(recursive: true);
    } on FileSystemException {
      // Temp files only.
    }
  }

  String describe() {
    final b = StringBuffer('$name (${identity.formattedId}):');
    for (final s in manager.hostSessions) {
      b.write('\n  host session ${_describe(s)}');
    }
    for (final s in manager.viewerSessions) {
      b.write('\n  viewer session ${_describe(s)}');
    }
    return b.toString();
  }

  static String _describe(SessionBase s) {
    final st = s.stats.value;
    return 'phase=${s.phase.name} everActive=${s.everActive} end=${s.endReason} '
        'path=${st.path.name} ${st.width}x${st.height} fps=${st.fps?.toStringAsFixed(1)}';
  }
}

/// A host and a viewer wired together over loopback.
class E2ERig {
  E2ERig._(this.host, this.viewer);

  final E2ENode host;
  final E2ENode viewer;

  static Future<E2ERig> start({
    Permissions? hostPermissions,
    bool viewerListens = false,
    int hostDisplays = 1,
  }) async {
    final host = await E2ENode.create('Host', listening: true, displays: hostDisplays);
    final viewer = await E2ENode.create('Viewer', listening: viewerListens);
    if (hostPermissions != null) {
      await host.settings.setDefaultPermissions(hostPermissions);
    }
    return E2ERig._(host, viewer);
  }

  final List<E2ENode> _extraViewers = [];

  /// Another controlling device that connects to the same host.
  Future<E2ENode> addViewer(String name) async {
    final node = await E2ENode.create(name, listening: false);
    _extraViewers.add(node);
    return node;
  }

  /// Dials the host from [node] and authorizes with the one-time password.
  Future<ViewerSession> connectExtra(E2ENode node) async {
    final session = await node.manager.connect(target);
    await waitUntil(() => session.authPrompt != null, what: '${node.name} is asked for a password');
    await session.submitPassword(host.credentials.oneTimePassword);
    await waitUntil(() => session.phase == SessionPhase.active, what: '${node.name} is active');
    return session;
  }

  ConnectTarget get target => ConnectTarget(
        id: host.identity.id,
        addresses: [NetAddress('127.0.0.1', host.manager.listener.port)],
      );

  /// Dials the host like the Connect field does and returns the viewer
  /// session as soon as signaling is up.
  Future<ViewerSession> dial({bool relayOnly = false, ConnectTarget? to}) {
    return viewer.manager.connect(to ?? target, relayOnly: relayOnly);
  }

  /// Authorizes with the host's current one-time password and waits until both
  /// ends are active.
  Future<HostSession> authorize(ViewerSession v, {String? password}) async {
    await waitUntil(() => v.authPrompt != null, what: 'viewer is asked for a password');
    await v.submitPassword(password ?? host.credentials.oneTimePassword);
    return bothActive(v);
  }

  Future<HostSession> bothActive(ViewerSession v) async {
    await waitUntil(
      () => v.phase == SessionPhase.active || v.isEnded,
      what: 'viewer session active',
    );
    if (v.isEnded) throw TestFailure('viewer session ended early: ${v.endReason} (${v.notice})');
    final h = await host.awaitHostSession();
    await waitUntil(() => h.phase == SessionPhase.active, what: 'host session active');
    return h;
  }

  Future<void> dispose() async {
    for (final extra in _extraViewers) {
      await extra.shutDown();
    }
    await viewer.shutDown();
    await host.shutDown();
  }

  String describe() => '${host.describe()}\n${viewer.describe()}';
}
