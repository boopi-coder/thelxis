import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/address_book.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/net/connect_code.dart';
import 'package:thelxis/net/discovery.dart';
import 'package:thelxis/net/handshake.dart';
import 'package:thelxis/net/inband_signaling.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/net/signaling_channel.dart';
import 'package:thelxis/session/capture.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/host_session.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_history.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/session/viewer_session.dart';
import 'package:thelxis/l10n/framework_localizations.dart';
import 'package:thelxis/ui/home/connect_by_code_dialog.dart';
import 'package:thelxis/ui/home/connect_card.dart';
import 'package:thelxis/ui/shell_controller.dart';
import 'package:thelxis/ui/theme.dart';

import 'support/fakes.dart';

/// The real manager with the three methods that need a live PeerConnection
/// replaced, so the dialog's flows can be driven without the WebRTC plugin.
class _CodeManager extends SessionManager {
  _CodeManager({
    required super.settings,
    required super.identity,
    required super.systemInfo,
    required super.trusted,
    required super.addressBook,
    required super.credentials,
    required super.connectivity,
    required super.platform,
    required super.lan,
    required super.history,
    required super.badge,
    required this.hostSession,
    required this.viewerSession,
  });

  final HostSession hostSession;
  final ViewerSession viewerSession;
  PendingCodeOffer? offer;
  int created = 0;
  final List<String> applied = [];
  Object? acceptError;
  final List<OfferCode> answered = [];
  final List<PendingCodeOffer> discarded = [];

  @override
  Future<PendingCodeOffer> createCodeOffer({Duration lifetime = kCodeLifetime, Duration gatheringTimeout = const Duration(seconds: 5)}) async {
    created++;
    return offer!;
  }

  @override
  Future<void> discardCodeOffer(PendingCodeOffer o) async => discarded.add(o);

  @override
  Future<HostSession> acceptAnswerCode(PendingCodeOffer o, String text) async {
    applied.add(text);
    final e = acceptError;
    if (e != null) throw e;
    return hostSession;
  }

  @override
  Future<({ViewerSession session, String answerCode})> answerOfferCode(OfferCode o) async {
    answered.add(o);
    return (session: viewerSession, answerCode: 'TX2.answer-code-body');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late Identity me;
  late Identity other;
  late _CodeManager manager;
  late AddressBook book;
  late ShellController shell;
  late String offerCode;
  late String hostNonce;
  final copied = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    me = await Identity.fromSeed(List<int>.generate(32, (i) => i + 40));
    other = await Identity.fromSeed(List<int>.generate(32, (i) => i + 80));
    final settings = AppSettings(prefs, defaultDeviceName: 'My PC');
    await settings.setAllowIncoming(false);
    book = AddressBook(prefs);
    shell = ShellController();
    hostNonce = generateNonce();
    final exp = DateTime.now().add(kCodeLifetime).millisecondsSinceEpoch ~/ 1000;
    offerCode = await buildOfferCode(
      identity: other,
      name: 'Office PC',
      os: 'windows',
      nonce: hostNonce,
      exp: exp,
      sdp: 'v=0\r\n',
    );
    final trusted = TrustedDevices(prefs);
    final credentials = HostCredentials(identity: me, settings: settings);
    final platform = FakeHostPlatform();
    final peer = PeerIdentity(key: other.publicKeyB64, id: other.id, name: 'Office PC', os: 'windows');
    final viewerSession = ViewerSession(
      env: ViewerEnv(settings: settings, userName: 'Me'),
      peer: peer,
      sid: 'sid',
      channel: InBandSignaling(
        identity: me,
        role: SignalingRole.dialer,
        peerKey: other.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: 'v' * 43,
      ),
    );
    final hostSession = HostSession(
      env: HostEnv(
        settings: settings,
        identity: me,
        trusted: trusted,
        credentials: credentials,
        platform: platform,
        captures: CaptureRegistry(),
        requestApproval: (p) async => ApprovalResult.denied,
        onNotice: (t, m) {},
        startCapture: (d, all, {int fps = 30}) => throw UnimplementedError(),
      ),
      peer: peer,
      sid: 'sid',
      channel: InBandSignaling(
        identity: me,
        role: SignalingRole.listener,
        peerKey: other.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: 'v' * 43,
      ),
    );
    manager = _CodeManager(
      settings: settings,
      identity: me,
      systemInfo: SystemInfo.fallback(),
      trusted: trusted,
      addressBook: book,
      credentials: credentials,
      connectivity: FakeConnectivity(),
      platform: platform,
      lan: LanDiscovery(
        identity: me,
        localInfo: () => const LocalPeerInfo(name: 'x', os: 'linux', app: '0'),
        signalingPort: () => 0,
      ),
      history: SessionHistory(settings),
      badge: FakeBadge(),
      hostSession: hostSession,
      viewerSession: viewerSession,
    );
    manager.offer = PendingCodeOffer.forTest(
      code: 'TX1.${'abc' * 40}',
      nonce: hostNonce,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': offerCode};
      return null;
    });
  });

  tearDown(() {
    manager.dispose();
  });

  Future<void> open(WidgetTester tester, {String? initialCode, Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionManager>.value(value: manager),
        ChangeNotifierProvider<AddressBook>.value(value: book),
        ChangeNotifierProvider<ShellController>.value(value: shell),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('ru')],
        localizationsDelegates: frameworkLocalizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showConnectByCodeDialog(ctx, initialCode: initialCode),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Real I/O (signature checks) and widget time both have to advance.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('host: create a code, copy it, paste the answer, connect', (tester) async {
    await open(tester);
    expect(find.text('Connect by code'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('code-create')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(manager.created, 1);
    expect(find.byKey(const ValueKey('code-copy-text')), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('code-copy-text'))).data, startsWith('TX1.'));
    expect(find.textContaining('Valid for 9:5'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('code-copy')));
    await tester.pump();
    expect(copied.single, manager.offer!.code);

    await tester.enterText(find.byKey(const ValueKey('code-answer-field')), 'TX2.theiranswer');
    await tester.tap(find.byKey(const ValueKey('code-apply')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(manager.applied, ['TX2.theiranswer']);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Connect by code'), findsNothing, reason: 'the dialog closes; the session shows in Sessions');
    await close(tester);
  });

  testWidgets('host: a wrong answer code is explained and the offer stays usable', (tester) async {
    manager.acceptError = const CodeException(CodeError.badSignature);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('code-create')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byKey(const ValueKey('code-answer-field')), 'TX2.forged');
    await tester.tap(find.byKey(const ValueKey('code-apply')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('signature is wrong'), findsOneWidget);
    expect(find.byKey(const ValueKey('code-answer-field')), findsOneWidget);
    manager.acceptError = null;
    await tester.tap(find.byKey(const ValueKey('code-apply')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(manager.applied, hasLength(2));
    await tester.pump(const Duration(milliseconds: 400));
    await close(tester);
  });

  testWidgets('host: cancelling discards the pending offer', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('code-create')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(manager.discarded, [manager.offer]);
    await close(tester);
  });

  testWidgets('a code too long for a QR is shown as text only; a short one also as a QR', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('code-create')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.bySemanticsLabel('QR code with the invite link'), findsOneWidget);
    await close(tester);

    manager.offer = PendingCodeOffer.forTest(
      code: 'TX1.${'x' * (kMaxQrCodeChars + 10)}',
      nonce: hostNonce,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('code-create')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.bySemanticsLabel('QR code with the invite link'), findsNothing);
    expect(find.byKey(const ValueKey('code-copy-text')), findsOneWidget);
    await close(tester);
  });

  testWidgets('viewer: paste a code, see who made it, confirm, get the answer code to send back', (tester) async {
    await open(tester);
    await tester.tap(find.text('I have a code'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Paste'));
    await tester.pump();
    expect((tester.widget<TextField>(find.byKey(const ValueKey('code-offer-field'))).controller!.text), offerCode);

    await tester.tap(find.byKey(const ValueKey('code-answer-button')));
    await settle(tester, () => find.text('Connect to this device?').evaluate().isNotEmpty);
    // Who is on the other end, to be checked out of band.
    expect(find.text('Connect to this device?'), findsOneWidget);
    expect(find.text('Office PC'), findsOneWidget);
    expect(find.textContaining(other.formattedId), findsOneWidget);
    expect(find.byKey(const ValueKey('code-confirm-known')), findsOneWidget);
    expect(find.text('New device'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('code-confirm-ok')));
    await settle(tester, () => manager.answered.isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(manager.answered.single.peer.id, other.id);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('code-answer-copy-text'))).data, 'TX2.answer-code-body');

    await tester.ensureVisible(find.byKey(const ValueKey('code-answer-copy')));
    await tester.tap(find.byKey(const ValueKey('code-answer-copy')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(copied.single, 'TX2.answer-code-body');

    await tester.tap(find.byKey(const ValueKey('code-done')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(shell.front, same(manager.viewerSession), reason: 'Done brings the session to the front');
    await close(tester);
  });

  testWidgets('viewer: declining the confirmation answers nothing', (tester) async {
    await open(tester, initialCode: offerCode);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('code-offer-field'))).controller!.text, offerCode,
        reason: 'a TX1 code starts in "I have a code"');
    await tester.tap(find.byKey(const ValueKey('code-answer-button')));
    await settle(tester, () => find.text('Connect to this device?').evaluate().isNotEmpty);
    await tester.tap(find.text('Cancel').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(manager.answered, isEmpty);
    await close(tester);
  });

  testWidgets('viewer: a known device is labelled as known', (tester) async {
    await book.upsertPeer(PeerIdentity(key: other.publicKeyB64, id: other.id, name: 'Office PC', os: 'windows'));
    await open(tester, initialCode: offerCode);
    await tester.tap(find.byKey(const ValueKey('code-answer-button')));
    await settle(tester, () => find.text('Connect to this device?').evaluate().isNotEmpty);
    expect(find.text('Known device'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pump(const Duration(milliseconds: 400));
    await close(tester);
  });

  testWidgets('viewer: garbage, tampered and expired codes get a plain explanation', (tester) async {
    Future<void> tryCode(String text, String expectText) async {
      await tester.enterText(find.byKey(const ValueKey('code-offer-field')), text);
      await tester.tap(find.byKey(const ValueKey('code-answer-button')));
      await settle(tester, () => find.textContaining(expectText).evaluate().isNotEmpty);
    }

    await open(tester, initialCode: 'TX1.garbage');
    await tryCode('TX1.garbage', 'not a valid code');
    expect(find.textContaining('not a valid code'), findsOneWidget);

    final expired = await tester.runAsync(() => buildOfferCode(
          identity: other,
          name: 'Office PC',
          os: 'windows',
          nonce: hostNonce,
          exp: DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
          sdp: 'v=0\r\n',
        ));
    await tryCode(expired!, 'has expired');
    expect(find.textContaining('has expired'), findsOneWidget);

    await tryCode('TX1.${'A' * 17000}', 'too long');
    expect(find.textContaining('too long'), findsOneWidget);
    expect(manager.answered, isEmpty);
    await close(tester);
  });

  testWidgets('Russian texts', (tester) async {
    await open(tester, locale: const Locale('ru'));
    expect(find.text('Подключение по коду'), findsOneWidget);
    expect(find.text('Создать код'), findsOneWidget);
    expect(find.text('У меня есть код'), findsOneWidget);
    await close(tester);
  });

  group('Connect field', () {
    testWidgets('a pasted code opens the code flow instead of "unrecognised address"', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionManager>.value(value: manager),
          ChangeNotifierProvider<AddressBook>.value(value: book),
          ChangeNotifierProvider<ShellController>.value(value: shell),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: SingleChildScrollView(child: ConnectCard()))),
      ));
      await tester.enterText(find.byType(TextField).first, offerCode);
      await tester.tap(find.text('Connect'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('code-offer-field')), findsOneWidget);
      expect(find.textContaining('Enter a Thelxis ID with an address'), findsNothing);
      await close(tester);
    });

    testWidgets('the Connect card has a Connect by code button', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionManager>.value(value: manager),
          ChangeNotifierProvider<AddressBook>.value(value: book),
          ChangeNotifierProvider<ShellController>.value(value: shell),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: SingleChildScrollView(child: ConnectCard()))),
      ));
      await tester.tap(find.byKey(const ValueKey('connect-by-code')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Create code'), findsOneWidget);
      await close(tester);
    });
  });
}
