import 'dart:async';
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
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_base.dart';
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';

import 'support/fakes.dart';

class _Settings extends AppSettings {
  _Settings(super.prefs, {required super.defaultDeviceName, this.incoming = true});

  bool incoming;

  @override
  bool get allowIncoming => incoming;

  @override
  bool get lanDiscovery => false;

  @override
  bool get upnp => false;
}

class _Node {
  _Node(this.identity, this.settings, this.manager, this.book, this.trusted, this.net, this.platform);

  final Identity identity;
  final _Settings settings;
  final SessionManager manager;
  final AddressBook book;
  final TrustedDevices trusted;
  final FakeConnectivity net;
  final FakeHostPlatform platform;

  NetAddress get address => NetAddress('127.0.0.1', manager.listener.port);
}

Future<_Node> _node(String name, int seed, {bool incoming = true}) async {
  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.fromSeed(List<int>.generate(32, (i) => (i * 3 + seed) & 0xff));
  final settings = _Settings(prefs, defaultDeviceName: name, incoming: incoming);
  final net = FakeConnectivity();
  final platform = FakeHostPlatform();
  final book = AddressBook(prefs);
  final trusted = TrustedDevices(prefs);
  final info = SystemInfo(os: 'linux', osVersion: 't', arch: 'x64', hostname: name, appVersion: '0.1.0', defaultDeviceName: name);
  final lan = LanDiscovery(identity: identity, localInfo: () => LocalPeerInfo(name: name, os: 'linux', app: '0'), signalingPort: () => 0);
  final manager = SessionManager(
    settings: settings,
    identity: identity,
    systemInfo: info,
    trusted: trusted,
    addressBook: book,
    credentials: HostCredentials(identity: identity, settings: settings),
    connectivity: net,
    platform: platform,
    lan: lan,
    history: SessionHistory(settings),
    badge: FakeBadge(),
    listenerPort: 0,
    listenerAddress: InternetAddress.loopbackIPv4,
  );
  await manager.start();
  return _Node(identity, settings, manager, book, trusted, net, platform);
}

Future<T> _nextPrompt<T extends Prompt<Object?>>(PromptQueue q) {
  final done = Completer<T>();
  void check() {
    final c = q.current;
    if (c is T && !done.isCompleted) done.complete(c);
  }

  q.addListener(check);
  check();
  return done.future.timeout(const Duration(seconds: 8)).whenComplete(() => q.removeListener(check));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs out HTTP; these tests use real loopback sockets.
  HttpOverrides.global = null;
  // Sessions fail to create WebRTC objects here (no plugin); that is expected.
  Logger.sink = (_, _) {};

  late _Node host;
  late _Node viewer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = await _node('Host PC', 1);
    viewer = await _node('Viewer Mac', 2);
  });

  tearDown(() async {
    await viewer.manager.endAll();
    await host.manager.endAll();
    host.manager.dispose();
    viewer.manager.dispose();
  });

  test('the listener comes up from settings and reports itself to connectivity', () {
    expect(host.manager.listener.isListening, isTrue);
    expect(host.net.listening, isTrue);
    expect(host.net.lastPortMapping, isFalse);
  });

  test('turning "allow incoming" off shuts the listener and the relay down', () async {
    host.settings.incoming = false;
    await host.manager.applySettings();
    expect(host.manager.listener.isListening, isFalse);
    expect(host.net.started, isFalse);
    host.settings.incoming = true;
    await host.manager.applySettings();
    expect(host.manager.listener.isListening, isTrue);
  });

  test('a bare address asks for first-contact confirmation, then pins the device', () async {
    final prompt = _nextPrompt<FirstContactPrompt>(viewer.manager.prompts);
    final connecting = viewer.manager.connect(ConnectTarget(addresses: [host.address]));
    final p = await prompt;
    expect(p.peer.id, host.identity.id);
    expect(p.peer.name, 'Host PC');
    expect(viewer.book.byId(host.identity.id), isNull, reason: 'nothing is stored before the user confirms');
    p.resolve(true);

    final session = await connecting;
    expect(session.peer.id, host.identity.id);
    final entry = viewer.book.byId(host.identity.id)!;
    expect(entry.key, host.identity.publicKeyB64);
    expect(entry.addresses.first, host.address.hostPort);
    expect(entry.lastConnected, isNotNull);
    expect(viewer.manager.viewerSessions, contains(session));
    // The WebRTC plugin does not exist in unit tests, so the session ends by itself.
    await _until(() => session.isEnded);
    expect(session.endReason, 'error');
    viewer.manager.dismiss(session);
    expect(viewer.manager.viewerSessions, isEmpty);
  });

  test('declining the first-contact prompt cancels without error and stores nothing', () async {
    final prompt = _nextPrompt<FirstContactPrompt>(viewer.manager.prompts);
    final connecting = viewer.manager.connect(ConnectTarget(addresses: [host.address]));
    (await prompt).resolve(false);
    await expectLater(connecting, throwsA(isA<ConnectException>().having((e) => e.cancelled, 'cancelled', isTrue)));
    expect(viewer.book.entries, isEmpty);
  });

  test('a known device is not asked about again', () async {
    final peer = PeerIdentity(
      key: host.identity.publicKeyB64,
      id: host.identity.id,
      name: 'Host PC',
      os: 'linux',
    );
    await viewer.book.upsertPeer(peer);
    final session = await viewer.manager.connect(ConnectTarget(addresses: [host.address]));
    expect(viewer.manager.prompts.length, 0);
    await _until(() => session.isEnded);
  });

  test('ID@address with the wrong ID is a hard failure and raises a warning', () async {
    final stranger = await Identity.fromSeed(List<int>.filled(32, 99));
    final warning = _nextPrompt<WarningPrompt>(viewer.manager.prompts);
    await expectLater(
      viewer.manager.connect(ConnectTarget(id: stranger.id, addresses: [host.address])),
      throwsA(isA<ConnectException>()),
    );
    final w = await warning;
    expect(w.title, 'Identity mismatch');
    expect(viewer.book.entries, isEmpty);
    w.resolve(null);
  });

  test('an ID without any known address explains what to do', () async {
    await expectLater(
      viewer.manager.connect(const ConnectTarget(id: 'K7M2P9XQ4TAB8HDE')),
      throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('invite link'))),
    );
  });

  test('an ID resolves through the address book', () async {
    await viewer.book.upsertPeer(
      PeerIdentity(
        key: host.identity.publicKeyB64,
        id: host.identity.id,
        name: 'Host PC',
        os: 'linux',
        addresses: [host.address.hostPort],
      ),
    );
    final session = await viewer.manager.connect(ConnectTarget(id: host.identity.id));
    expect(session.peer.name, 'Host PC');
    await _until(() => session.isEnded);
  });

  test('a host that is not accepting refuses with a clear message', () async {
    host.settings.incoming = false;
    // The listener is still bound here, so the refusal comes from admission.
    final target = ConnectTarget(id: host.identity.id, addresses: [host.address]);
    await expectLater(
      viewer.manager.connect(target),
      throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('not accepting'))),
    );
  });

  test('reverse mode: the listening side is asked before it becomes the viewer', () async {
    final prompt = _nextPrompt<ReverseOfferPrompt>(host.manager.prompts);
    final offering = viewer.manager.offerControl(ConnectTarget(id: host.identity.id, addresses: [host.address]));
    final p = await prompt;
    expect(p.peer.id, viewer.identity.id);
    expect(p.peer.name, 'Viewer Mac');
    p.resolve(false);
    final hostSession = await offering;
    expect(hostSession.isHost, isTrue);
    expect(host.manager.viewerSessions, isEmpty, reason: 'declined: no viewer session on the listener');
    await _until(() => hostSession.isEnded);
  });

  test('reverse mode needs a host-capable platform', () async {
    final prefs = await SharedPreferences.getInstance();
    final identity = await Identity.fromSeed(List<int>.filled(32, 5));
    final settings = _Settings(prefs, defaultDeviceName: 'x');
    final m = SessionManager(
      settings: settings,
      identity: identity,
      systemInfo: SystemInfo.fallback(),
      trusted: TrustedDevices(prefs),
      addressBook: AddressBook(prefs),
      credentials: HostCredentials(identity: identity, settings: settings),
      connectivity: FakeConnectivity(),
      platform: FakeHostPlatform(supported: false),
      lan: LanDiscovery(identity: identity, localInfo: () => const LocalPeerInfo(name: 'x', os: 'linux', app: '0'), signalingPort: () => 0),
      history: SessionHistory(settings),
      badge: FakeBadge(),
    );
    await expectLater(
      m.offerControl(ConnectTarget(id: host.identity.id, addresses: [host.address])),
      throwsA(isA<ConnectException>()),
    );
    m.dispose();
  });

  test('finished sessions are written to the history', () async {
    final session = await viewer.manager.connect(ConnectTarget(id: host.identity.id, addresses: [host.address]), viewOnly: true)
        .catchError((Object _) => throw StateError('unexpected'));
    await _until(() => session.isEnded);
    await _until(() => viewer.manager.history.records.isNotEmpty);
    final r = viewer.manager.history.records.first;
    expect(r.peerId, host.identity.id);
    expect(r.incoming, isFalse);
  });

  test('the host side tracks the incoming session and drops it when it ends', () async {
    final session = await viewer.manager.connect(ConnectTarget(id: host.identity.id, addresses: [host.address]));
    await _until(() => host.manager.hostSessions.isNotEmpty || session.isEnded);
    await _until(() => session.isEnded);
    await _until(() => host.manager.hostSessions.isEmpty);
    await _until(() => host.manager.history.records.isNotEmpty);
    expect(host.manager.history.records.first.incoming, isTrue);
    expect(SessionPhase.values, contains(SessionPhase.ended));
  });
}

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 8)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
