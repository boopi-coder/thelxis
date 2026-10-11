import 'dart:async';
import 'dart:convert';
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
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';

import 'support/fakes.dart';

class _Settings extends AppSettings {
  _Settings(super.prefs, {required super.defaultDeviceName, this.gatewayOn = false});

  bool gatewayOn;
  bool lanOn = false;

  @override
  bool get lanDiscovery => lanOn;

  @override
  bool get upnp => false;

  @override
  bool get officeGateway => gatewayOn;
}

class _Node {
  _Node(this.identity, this.settings, this.manager, this.book, this.net, this.lan);

  final Identity identity;
  final _Settings settings;
  final SessionManager manager;
  final AddressBook book;
  final FakeConnectivity net;
  final LanDiscovery lan;

  NetAddress get address => NetAddress('127.0.0.1', manager.listener.port);
}

Future<_Node> _node(String name, int seed, {bool gateway = false, int discoveryPort = 47102}) async {
  final prefs = await SharedPreferences.getInstance();
  final identity = await Identity.fromSeed(List<int>.generate(32, (i) => (i * 3 + seed) & 0xff));
  final settings = _Settings(prefs, defaultDeviceName: name, gatewayOn: gateway);
  final net = FakeConnectivity(addresses: ['203.0.113.5:47100']);
  final book = AddressBook(prefs);
  final lan = LanDiscovery(
    identity: identity,
    localInfo: () => LocalPeerInfo(name: name, os: 'linux', app: '0'),
    signalingPort: () => 0,
    discoveryPort: discoveryPort,
  );
  final manager = SessionManager(
    settings: settings,
    identity: identity,
    systemInfo: SystemInfo(os: 'linux', osVersion: 't', arch: 'x64', hostname: name, appVersion: '0.2.0', defaultDeviceName: name),
    trusted: TrustedDevices(prefs),
    addressBook: book,
    credentials: HostCredentials(identity: identity, settings: settings),
    connectivity: net,
    platform: FakeHostPlatform(),
    lan: lan,
    history: SessionHistory(settings),
    badge: FakeBadge(),
    listenerPort: 0,
    listenerAddress: InternetAddress.loopbackIPv4,
  );
  await manager.start();
  return _Node(identity, settings, manager, book, net, lan);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  Logger.sink = (_, _) {};

  late _Node gw;
  late _Node target;
  late _Node viewer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gw = await _node('Gateway PC', 1, gateway: true, discoveryPort: 47981);
    target = await _node('Office PC', 2);
    viewer = await _node('Home Mac', 3);
    // What the gateway's LAN browser would have learned.
    gw.lan.debugReply(
      buildHere(
        identity: target.identity,
        info: const LocalPeerInfo(name: 'Office PC', os: 'linux', app: '0'),
        port: target.manager.listener.port,
      ),
      '127.0.0.1',
    );
  });

  tearDown(() async {
    for (final n in [viewer, target, gw]) {
      await n.manager.endAll();
      n.manager.dispose();
      n.lan.dispose();
    }
  });

  test('the gateway is wired from the setting: route, announcement and browser', () async {
    expect(gw.manager.listener.gatewayHandler, isNotNull);
    expect(gw.lan.gatewayAdvertisement(), ['203.0.113.5:47100'], reason: 'advertisedAddresses(), not a guessed port');
    expect(target.manager.listener.gatewayHandler, isNull, reason: 'off by default');
    expect(target.lan.gatewayAdvertisement(), isNull);

    gw.settings.gatewayOn = false;
    await gw.manager.applySettings();
    expect(gw.manager.listener.gatewayHandler, isNull);
    expect(gw.lan.gatewayAdvertisement(), isNull);
    gw.settings.gatewayOn = true;
    await gw.manager.applySettings();
    expect(gw.manager.listener.gatewayHandler, isNotNull);
  });

  test('the discovery responder announces the gateway only while it is on', () async {
    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(sock.close);
    final events = sock.asBroadcastStream();
    Future<Map<String, dynamic>> ask() async {
      final reply = Completer<Map<String, dynamic>>();
      final sub = events.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = sock.receive();
        if (d != null && !reply.isCompleted) reply.complete(jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>);
      });
      sock.send(utf8.encode(buildDiscover()), InternetAddress.loopbackIPv4, 47981);
      try {
        return await reply.future.timeout(const Duration(seconds: 3));
      } finally {
        await sub.cancel();
      }
    }

    final on = await ask();
    expect(on['t'], 'here');
    expect(on['gateway'], isTrue);
    expect(on['gw_addresses'], ['203.0.113.5:47100']);

    gw.settings.gatewayOn = false;
    await gw.manager.applySettings();
    expect(gw.lan.isResponding, isFalse, reason: 'neither gateway nor "show this device": silent');
    // Visible as an ordinary device, not as a gateway.
    gw.settings.lanOn = true;
    await gw.manager.applySettings();
    final off = await ask();
    expect(off.containsKey('gateway'), isFalse);
    expect(off.containsKey('gw_addresses'), isFalse);
  });

  test('a viewer outside reaches the device through the gateway and verifies its ID', () async {
    final session = await viewer.manager.connect(
      ConnectTarget(id: target.identity.id, gateways: [gw.address]),
    );
    expect(session.peer.id, target.identity.id, reason: 'the target\'s own identity, not the gateway\'s');
    expect(session.peer.name, 'Office PC');
    expect(session.viaGateway, isTrue);
    expect(gw.net.gatewayGrants, [true]);

    final entry = viewer.book.byId(target.identity.id)!;
    expect(entry.gateways, [gw.address.hostPort]);
    expect(entry.addresses, isNot(contains(gw.address.hostPort)), reason: 'the gateway\'s address is not the device\'s');
  });

  test('later, the gateway from the address book is enough', () async {
    await viewer.book.upsertPeer(
      PeerIdentity(key: target.identity.publicKeyB64, id: target.identity.id, name: 'Office PC', os: 'linux'),
      gateways: [gw.address.hostPort],
    );
    final session = await viewer.manager.connect(ConnectTarget(id: target.identity.id));
    expect(session.viaGateway, isTrue);
  });

  test('without a known ID there is no way through a gateway', () async {
    await expectLater(
      viewer.manager.connect(ConnectTarget(addresses: [], gateways: [gw.address])),
      throwsA(isA<ConnectException>()),
    );
  });

  test('a gateway that is switched off is just another unreachable address', () async {
    gw.settings.gatewayOn = false;
    await gw.manager.applySettings();
    await expectLater(
      viewer.manager.connect(ConnectTarget(id: target.identity.id, gateways: [gw.address])),
      throwsA(isA<ConnectException>()),
    );
  });
}
