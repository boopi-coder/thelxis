// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:thelxis/net/connect_code.dart';
import 'package:thelxis/session/session_base.dart';

import 'support/rig.dart';

/// Connection codes (PROTOCOL.md section 12) through the real WebRTC stack:
/// two nodes that do not listen on anything exchange `TX1.` / `TX2.` and
/// connect, with later signaling in-band on the control channel.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  E2ELog.install();

  testWidgets('connect by code: offer, answer, authorization, live session', (tester) async {
    final host = await E2ENode.create('Host', listening: false);
    final viewer = await E2ENode.create('Viewer', listening: false);
    try {
      final offer = await host.manager.createCodeOffer();
      expect(offer.code, startsWith('TX1.'));
      expect(host.manager.codeOffers, [offer]);

      // What the viewer's user sees before agreeing.
      final parsed = await viewer.manager.readOfferCode(offer.code);
      expect(parsed.peer.id, host.identity.id);
      expect(parsed.peer.name, 'Host');

      final answered = await viewer.manager.answerOfferCode(parsed);
      expect(answered.answerCode, startsWith('TX2.'));
      final session = answered.session;

      // A forged answer is refused and the offer stays usable.
      await expectLater(
        host.manager.acceptAnswerCode(offer, '${answered.answerCode.substring(0, answered.answerCode.length - 8)}AAAAAAAA'),
        throwsA(isA<CodeException>()),
      );
      expect(host.manager.codeOffers, [offer]);

      final hostSession = await host.manager.acceptAnswerCode(offer, answered.answerCode);
      expect(host.manager.codeOffers, isEmpty, reason: 'single use');

      await waitUntil(() => session.authPrompt != null, what: 'viewer is asked for a password', timeout: const Duration(seconds: 30));
      await session.submitPassword(host.credentials.oneTimePassword);
      await waitUntil(
        () => session.phase == SessionPhase.active && hostSession.phase == SessionPhase.active,
        what: 'both sides active',
      );
      expect(session.peer.id, host.identity.id);
      expect(hostSession.peer.id, viewer.identity.id);
      await waitUntil(() => (session.stats.value.width ?? 0) > 0, what: 'video flows');

      await session.end('user');
      await waitUntil(() => hostSession.isEnded, what: 'host session ends');
    } catch (_) {
      print('--- state at failure ---\n${host.describe()}\n${viewer.describe()}');
      rethrow;
    } finally {
      await viewer.shutDown();
      await host.shutDown();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('a code offer expires and at most three stay pending', (tester) async {
    final host = await E2ENode.create('Host', listening: false);
    try {
      final first = await host.manager.createCodeOffer();
      final second = await host.manager.createCodeOffer();
      final third = await host.manager.createCodeOffer();
      final fourth = await host.manager.createCodeOffer();
      expect(host.manager.codeOffers, [second, third, fourth], reason: 'the oldest made room');
      expect(host.manager.codeOffers, isNot(contains(first)));

      final short = await host.manager.createCodeOffer(lifetime: const Duration(seconds: 1));
      await waitUntil(() => !host.manager.codeOffers.contains(short), what: 'the short-lived offer is dropped');
    } finally {
      await host.shutDown();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
