// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:thelxis/net/connect_target.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/link_stats.dart';
import 'package:thelxis/session/session_base.dart';

import 'support/rig.dart';

/// The office gateway (PROTOCOL.md section 11) through the real stack: the
/// viewer reaches the target only via the gateway's `/thelxis/via/<ID>` pipe,
/// verifies the target's own key, and its media is relayed by the gateway's
/// embedded TURN (relay-only, so nothing can go around it).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  E2ELog.install();

  testWidgets('a viewer reaches a device through the office gateway', (tester) async {
    final target = await E2ENode.create('Target', listening: true);
    final gateway = await E2ENode.create('Gateway', listening: true);
    final viewer = await E2ENode.create('Viewer', listening: false);
    try {
      await gateway.settings.setOfficeGateway(true);
      await gateway.manager.applySettings();
      // What the gateway's LAN browser would have found.
      gateway.manager.lan.debugReply(
        buildHere(
          identity: target.identity,
          info: const LocalPeerInfo(name: 'Target', os: 'linux', app: '0.2.0'),
          port: target.manager.listener.port,
        ),
        '127.0.0.1',
      );

      final session = await viewer.manager.connect(
        ConnectTarget(
          id: target.identity.id,
          gateways: [NetAddress('127.0.0.1', gateway.manager.listener.port)],
        ),
        relayOnly: true,
      );
      expect(session.viaGateway, isTrue);
      expect(session.peer.id, target.identity.id, reason: 'the target\'s own key, not the gateway\'s');

      await waitUntil(() => session.authPrompt != null, what: 'viewer is asked for a password');
      await session.submitPassword(target.credentials.oneTimePassword);
      final host = await target.awaitHostSession();
      await waitUntil(
        () => session.phase == SessionPhase.active && host.phase == SessionPhase.active,
        what: 'both sides active',
        timeout: const Duration(seconds: 30),
      );
      await waitUntil(() => session.stats.value.path != LinkPath.unknown, what: 'the media path is known');
      expect(session.stats.value.path, LinkPath.gateway);
      expect(session.stats.value.pathLabel, 'Via gateway');
      await session.end('user');
    } catch (_) {
      print('--- state at failure ---\n${target.describe()}\n${gateway.describe()}\n${viewer.describe()}');
      rethrow;
    } finally {
      await viewer.shutDown();
      await gateway.shutDown();
      await target.shutDown();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
