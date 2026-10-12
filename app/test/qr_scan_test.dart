import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/base64url.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/l10n/framework_localizations.dart';
import 'package:thelxis/net/connect_code.dart';
import 'package:thelxis/net/connect_target.dart';
import 'package:thelxis/net/handshake.dart';
import 'package:thelxis/net/scan_payload.dart';
import 'package:thelxis/ui/theme.dart';
import 'package:thelxis/ui/widgets/qr_scanner_page.dart';

String _pack(String prefix, Map<String, Object?> json) =>
    prefix + b64uEncode(ZLibCodec(raw: true).encode(utf8.encode(jsonEncode(json))));

void main() {
  late Identity me;
  late String invite;
  late String offer;
  late String answer;

  setUpAll(() async {
    me = await Identity.fromSeed(List<int>.generate(32, (i) => i + 7));
    invite = buildInviteLink(id: me.id, name: 'Office PC', addresses: ['192.168.1.5:47100']);
    final nonce = generateNonce();
    offer = await buildOfferCode(
      identity: me,
      name: 'Office PC',
      os: 'windows',
      nonce: nonce,
      exp: DateTime.now().add(kCodeLifetime).millisecondsSinceEpoch ~/ 1000,
      sdp: 'v=0\r\n',
    );
    answer = await buildAnswerCode(
      identity: me,
      name: 'Phone',
      os: 'android',
      hostNonce: nonce,
      viewerNonce: generateNonce(),
      sdp: 'v=0\r\n',
    );
  });

  group('classifyScan', () {
    test('recognises the three Thelxis payloads', () {
      expect(classifyScan(invite), ScanKind.invite);
      expect(classifyScan(offer), ScanKind.offer);
      expect(classifyScan(answer), ScanKind.answer);
    });

    test('tolerates surrounding whitespace and an upper-case scheme', () {
      expect(classifyScan('  $invite\n'), ScanKind.invite);
      expect(classifyScan(invite.replaceFirst('thelxis:', 'THELXIS:')), ScanKind.invite);
      expect(classifyScan('\n$offer '), ScanKind.offer);
    });

    test('a code from a newer protocol version still counts, so the flow can explain it', () {
      expect(classifyScan(_pack(kOfferPrefix, {'v': 2})), ScanKind.offer);
      expect(classifyScan(_pack(kAnswerPrefix, {'v': 2})), ScanKind.answer);
    });

    test('foreign and broken payloads are unknown', () {
      for (final text in [
        '',
        '   ',
        'hello',
        'https://example.com/connect?id=x',
        'WIFI:S:home;T:WPA;P:secret;;',
        'thelxis://connect?n=NoId',
        'thelxis://elsewhere?id=${me.id}',
        'TX1.',
        'TX1.not-base64!!',
        'TX2.${b64uEncode(utf8.encode('plain text, not deflate'))}',
        _pack(kOfferPrefix, {'no': 'version'}),
        '${me.formattedId}@192.168.1.5',
        me.formattedId,
      ]) {
        expect(classifyScan(text), ScanKind.unknown, reason: text);
      }
    });

    test('a code is only what its prefix says', () {
      expect(classifyScan(offer.replaceFirst(kOfferPrefix, kAnswerPrefix)), ScanKind.answer,
          reason: 'structure is checked here; the answer flow rejects the signature');
      expect(classifyScan(offer.substring(0, offer.length ~/ 2)), ScanKind.unknown, reason: 'truncated');
    });
  });

  group('firstAcceptedScan', () {
    test('picks the first value of an accepted kind, trimmed', () {
      expect(firstAcceptedScan(['junk', null, ' $invite '], {ScanKind.invite}), invite);
      expect(firstAcceptedScan([invite, offer], {ScanKind.offer}), offer);
    });

    test('null when nothing qualifies', () {
      expect(firstAcceptedScan([invite, 'junk', null], {ScanKind.answer}), isNull);
      expect(firstAcceptedScan(const [], {ScanKind.invite}), isNull);
    });
  });

  group('QrScannerPage', () {
    late List<String> haptics;
    late void Function(List<String?>) scan;

    setUp(() {
      haptics = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
          (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
        return null;
      });
    });

    /// Opens the page over a host screen; the result lands in [out].
    Future<void> open(WidgetTester tester, Set<ScanKind> accept, List<String?> out, {Locale locale = const Locale('en')}) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('ru')],
        localizationsDelegates: frameworkLocalizationsDelegates,
        home: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () async {
                out.add(await Navigator.of(ctx).push<String>(MaterialPageRoute(
                  builder: (_) => QrScannerPage(
                    accept: accept,
                    debugPreview: (onScan) {
                      scan = onScan;
                      return const ColoredBox(color: Colors.black);
                    },
                  ),
                )));
              },
              child: const Text('scan'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('scan'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the hint, rejects foreign codes and keeps scanning', (tester) async {
      final out = <String?>[];
      await open(tester, {ScanKind.invite}, out);
      expect(find.text('Point the camera at a Thelxis QR code'), findsOneWidget);
      expect(find.text('This is not a Thelxis QR code'), findsNothing);

      scan(['https://example.com']);
      await tester.pump();
      expect(find.text('This is not a Thelxis QR code'), findsOneWidget);
      expect(find.byType(QrScannerPage), findsOneWidget);

      // A Thelxis code of the wrong kind for this field is not accepted either.
      scan([offer]);
      await tester.pump();
      expect(find.byType(QrScannerPage), findsOneWidget);
      expect(out, isEmpty);
      expect(haptics, isEmpty);

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('This is not a Thelxis QR code'), findsNothing, reason: 'the message goes away');

      scan([invite]);
      await tester.pumpAndSettle();
      expect(out, [invite]);
      expect(haptics, isNotEmpty, reason: 'haptic on success');
      expect(find.byType(QrScannerPage), findsNothing);
    });

    testWidgets('only the first accepted scan counts', (tester) async {
      final out = <String?>[];
      await open(tester, {ScanKind.offer, ScanKind.answer}, out);
      scan([answer]);
      scan([offer]);
      await tester.pumpAndSettle();
      expect(out, [answer]);
    });

    testWidgets('close returns nothing', (tester) async {
      final out = <String?>[];
      await open(tester, {ScanKind.invite}, out);
      await tester.tap(find.byKey(const ValueKey('scan-close')));
      await tester.pumpAndSettle();
      expect(out, [null]);
    });

    testWidgets('Russian texts', (tester) async {
      final out = <String?>[];
      await open(tester, {ScanKind.invite}, out, locale: const Locale('ru'));
      expect(find.text('Наведите камеру на QR-код Thelxis'), findsOneWidget);
      scan(['junk']);
      await tester.pump();
      expect(find.text('Это не QR-код Thelxis'), findsOneWidget);
      expect(find.byTooltip('Закрыть'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
