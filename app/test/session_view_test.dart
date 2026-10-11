import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceConnectionState, RTCVideoValue;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/desktop/desktop_integration.dart';
import 'package:thelxis/files/files.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/session/viewer_session.dart';
import 'package:thelxis/ui/session/session_view.dart';
import 'package:thelxis/ui/shell_controller.dart';
import 'package:thelxis/ui/theme.dart';

import 'support/channel_pair.dart';
import 'support/fakes.dart';

const _video = Size(1920, 1080);

class _Harness {
  late AppServices services;
  late ChannelPair pair;
  late ViewerSession session;
  final FileChannelPair filesPair = FileChannelPair();
  final List<Map<String, dynamic>> input = [];
  final List<Map<String, dynamic>> control = [];

  Future<void> setUp({
    String touchMode = 'touchpad',
    bool control_ = true,
    bool files = true,
    bool attachFiles = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = await Identity.fromSeed(List<int>.filled(32, 61));
    services = AppServices.create(
      prefs: prefs,
      identity: identity,
      systemInfo: SystemInfo.fallback(),
      connectivity: FakeConnectivity(),
      platform: FakeHostPlatform(),
      badge: FakeBadge(),
    );
    await services.settings.setTouchMode(touchMode);
    final host = await Identity.fromSeed(List<int>.filled(32, 62));
    pair = await ChannelPair.create(self: identity, peerKey: host.publicKeyB64);
    session = ViewerSession(
      env: ViewerEnv(settings: services.settings, userName: 'Tester'),
      peer: PeerIdentity(key: host.publicKeyB64, id: host.id, name: 'Office PC', os: 'windows'),
      sid: 'sid',
      channel: pair.channel,
    )
      ..debugInputTap = input.add
      ..debugControlTap = control.add
      ..debugFingerprints = () async => (local: 'sha-256 11:22', remote: 'sha-256 99:88');
    if (attachFiles) session.debugAttachFiles(filesPair.a);
    session.debugReceiveControl({'t': 'hello', 'v': 2, 'methods': ['request'], 'nonce': 'n'});
    session.debugReceiveControl({
      't': 'auth_result',
      'ok': true,
      'permissions': {'view': true, 'control': control_, 'clipboard': true, 'files': files},
    });
    session.renderer.value = RTCVideoValue(width: _video.width, height: _video.height);
    session.debugFirstFrame();
    control.clear();
  }

  Future<void> tearDown() async {
    await session.end('user');
    await pair.close();
    await filesPair.close();
  }

  Widget app() => MultiProvider(
        providers: [
          Provider<AppServices>.value(value: services),
          ChangeNotifierProvider<AppSettings>.value(value: services.settings),
          ChangeNotifierProvider<SessionManager>.value(value: services.sessions),
          Provider<DesktopIntegration>.value(value: services.desktop),
          ChangeNotifierProvider(create: (_) => ShellController()),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(body: SessionView(session: session)),
        ),
      );

  List<Map<String, dynamic>> ofType(String t) => input.where((m) => m['t'] == t).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late _Harness h;

  Future<void> desktopApp(
    WidgetTester tester, {
    Size size = const Size(1000, 700),
    bool files = true,
    bool attachFiles = true,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    h = _Harness();
    await tester.runAsync(() => h.setUp(files: files, attachFiles: attachFiles));
    await tester.pumpWidget(h.app());
    await tester.pump(const Duration(milliseconds: 300));
    h.input.clear();
  }

  Future<void> finish(WidgetTester tester) async {
    // The framework requires debug overrides to be reset before the test body ends.
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await h.tearDown();
    });
  }

  group('desktop mouse', () {
    testWidgets('hover maps through the letterboxed picture; the black bars clamp', (tester) async {
      await desktopApp(tester);
      // 1000x700 viewport, 16:9 picture => 1000 x 562.5 at y = 68.75.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 10));
      addTearDown(mouse.removePointer);

      await mouse.moveTo(const Offset(500, 350));
      await tester.pump(const Duration(milliseconds: 20));
      expect(h.input.last, {'t': 'mm', 'x': 0.5, 'y': 0.5});

      await mouse.moveTo(const Offset(250, 68.75 + 562.5 / 4));
      await tester.pump(const Duration(milliseconds: 20));
      expect(h.input.last['x'], closeTo(0.25, 1e-4));
      expect(h.input.last['y'], closeTo(0.25, 1e-4));

      await mouse.moveTo(const Offset(500, 5)); // black bar above the picture
      await tester.pump(const Duration(milliseconds: 20));
      expect(h.input.last['y'], 0.0);
      expect(h.input.last['x'], 0.5);
      await finish(tester);
    });

    testWidgets('left and right clicks are sent as down/up at the pointer, bars are ignored', (tester) async {
      await desktopApp(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 350));
      addTearDown(mouse.removePointer);

      await mouse.down(const Offset(500, 350));
      await mouse.up();
      expect(h.ofType('md').single, {'t': 'md', 'b': 0, 'x': 0.5, 'y': 0.5});
      expect(h.ofType('mu').single, {'t': 'mu', 'b': 0, 'x': 0.5, 'y': 0.5});
      h.input.clear();

      await mouse.removePointer();
      final right = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await right.addPointer(location: const Offset(100, 300));
      addTearDown(right.removePointer);
      await right.down(const Offset(100, 300));
      await right.up();
      expect(h.ofType('md').single['b'], 2);
      expect(h.ofType('mu').single['b'], 2);
      h.input.clear();

      await right.removePointer();
      final bar = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await bar.addPointer(location: const Offset(500, 20));
      addTearDown(bar.removePointer);
      await bar.down(const Offset(500, 20));
      await bar.up();
      expect(h.ofType('md'), isEmpty);
      expect(h.ofType('mu'), isEmpty, reason: 'no release for a press that was never sent');
      await finish(tester);
    });

    testWidgets('the wheel is forwarded', (tester) async {
      await desktopApp(tester);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(500, 350)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await tester.pump(const Duration(milliseconds: 30));
      final wheel = h.ofType('wh');
      expect(wheel, isNotEmpty);
      expect(wheel.fold<double>(0, (s, m) => s + (m['dy'] as double)), 120);
      await finish(tester);
    });
  });

  group('desktop keyboard', () {
    testWidgets('key down/up use USB HID codes, repeats become key downs, Tab is not swallowed locally', (tester) async {
      await desktopApp(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(h.input.map((m) => '${m['t']}${m['c']}'), [
        'kd458756',
        'kd458756',
        'ku458756',
        'kd458795',
        'ku458795',
        'kd458832',
        'ku458832',
      ]);
      await finish(tester);
    });

    testWidgets('losing focus releases every held key', (tester) async {
      await desktopApp(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      h.input.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(h.ofType('ku').map((m) => m['c']).toSet(), {0x700E0, 0x70006});
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await finish(tester);
    });

    testWidgets('view-only mode sends nothing', (tester) async {
      await desktopApp(tester);
      await tester.tap(find.byTooltip('Controlling (tap for view only)'));
      await tester.pump();
      h.input.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 350));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(400, 300));
      await mouse.down(const Offset(400, 300));
      await mouse.up();
      expect(h.input, isEmpty);
      await finish(tester);
    });
  });

  group('desktop toolbar and overlays', () {
    testWidgets('quality menu sends the preset; stats overlay toggles', (tester) async {
      await desktopApp(tester);
      await tester.tap(find.byTooltip('Quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speed (30 fps, low bandwidth)'));
      await tester.pumpAndSettle();
      expect(h.control.last, {'t': 'quality', 'preset': 'speed'});

      expect(find.text('Latency'), findsNothing);
      await tester.tap(find.byTooltip('Statistics'));
      await tester.pump();
      expect(find.text('Latency'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('display switcher appears with several displays and selects one', (tester) async {
      await desktopApp(tester);
      expect(find.byTooltip('Display'), findsNothing);
      h.session.debugReceiveControl({
        't': 'displays',
        'items': [
          {'id': '0', 'name': 'Display 1', 'width': 2560, 'height': 1440, 'primary': true},
          {'id': '1', 'name': 'Display 2', 'width': 1920, 'height': 1080},
        ],
        'active': '0',
      });
      await tester.pump();
      await tester.tap(find.byTooltip('Display'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Display 2'));
      await tester.pumpAndSettle();
      expect(h.control.last, {'t': 'select_display', 'id': '1'});
      await finish(tester);
    });

    testWidgets('special keys: Ctrl+Alt+Del is sent as a special action', (tester) async {
      await desktopApp(tester);
      await tester.tap(find.byTooltip('Special keys'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ctrl + Alt + Del'));
      await tester.pumpAndSettle();
      expect(h.input.last, {'t': 'sp', 'a': 'ctrl_alt_del'});
      await finish(tester);
    });

    testWidgets('a lost connection shows the reconnecting overlay instead of a frozen picture', (tester) async {
      await desktopApp(tester);
      expect(find.text('Reconnecting…'), findsNothing);
      h.session.debugIceState(RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      await tester.pump();
      expect(find.text('Reconnecting…'), findsOneWidget);
      h.session.debugIceState(RTCIceConnectionState.RTCIceConnectionStateConnected);
      await tester.pump();
      expect(find.text('Reconnecting…'), findsNothing);
      await finish(tester);
    });

    testWidgets('End closes the session and shows the ended screen', (tester) async {
      await desktopApp(tester);
      await tester.tap(find.text('End'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(seconds: 6)); // lets socket-close timers fire
      // Closing the file channel needs one more round of real time.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(seconds: 6));
      expect(h.session.isEnded, isTrue);
      expect(find.text('Session ended.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the Files button opens the real file panel in the side sheet and closes it', (tester) async {
      await desktopApp(tester);
      expect(find.byType(FileTransferPanel), findsNothing);
      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileTransferPanel), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(FileTransferPanel), findsNothing);
      await finish(tester);
    });

    testWidgets('until the files channel is up the panel says so instead of showing a dead list', (tester) async {
      await desktopApp(tester, attachFiles: false);
      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileTransferPanel), findsNothing);
      expect(find.text('File transfer is not available yet'), findsOneWidget);
      // The channel arrives while the panel is open: it swaps in place.
      h.session.debugAttachFiles(h.filesPair.a);
      await tester.pumpAndSettle();
      expect(find.byType(FileTransferPanel), findsOneWidget);
      await finish(tester);
    });

    testWidgets('with the files permission the picture accepts drops and the toolbar offers Send', (tester) async {
      await desktopApp(tester);
      expect(tester.widget<FileDropTarget>(find.byType(FileDropTarget)).enabled, isTrue);
      expect(find.byType(SendFilesMenuButton), findsOneWidget);
      await finish(tester);
    });

    testWidgets('without the files permission nothing about files is reachable', (tester) async {
      await desktopApp(tester, files: false);
      expect(tester.widget<FileDropTarget>(find.byType(FileDropTarget)).enabled, isFalse);
      expect(find.byType(SendFilesMenuButton), findsNothing);
      await finish(tester);
    });

    testWidgets('a file dropped on the picture is queued for the host', (tester) async {
      await desktopApp(tester);
      final drop = tester.widget<FileDropTarget>(find.byType(FileDropTarget));
      final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('thelxis_drop_'));
      addTearDown(() => dir!.delete(recursive: true));
      final f = File('${dir!.path}/dropped.txt')..writeAsStringSync('x');
      drop.onFiles([f.path]);
      for (var i = 0; i < 100 && h.session.files!.transfers.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(h.session.files!.transfers.map((t) => t.name), contains('dropped.txt'));
      await finish(tester);
    });

    testWidgets('no Files button without the files permission', (tester) async {
      await desktopApp(tester, files: false);
      expect(find.byTooltip('Files'), findsNothing);
      await finish(tester);
    });
  });

  group('password prompt', () {
    testWidgets('a password host asks, proves, and never sends the password', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      h = _Harness();
      await tester.runAsync(() => h.setUp());
      // Restart authentication from the top.
      h.session.debugReceiveControl({'t': 'hello', 'v': 2, 'methods': ['password', 'request'], 'nonce': 'n2'});
      await tester.pumpWidget(h.app());
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Password'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'k7m2p9xq');
      await tester.tap(find.text('Connect'));
      // Key derivation runs on a worker isolate: poll in real time.
      await tester.runAsync(() async {
        final sw = Stopwatch()..start();
        while (!h.control.any((m) => m['t'] == 'auth') && sw.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      final auth = h.control.where((m) => m['t'] == 'auth').toList();
      expect(auth, hasLength(1));
      expect(auth.single['method'], 'password');
      expect(auth.single['proof'], isA<String>());
      expect(auth.single.values.contains('k7m2p9xq'), isFalse);
      await finish(tester);
    });
  });

  group('Android touch', () {
    Future<void> touchApp(
      WidgetTester tester, {
      String mode = 'touchpad',
      Size size = const Size(800, 600),
      bool files = true,
    }) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      h = _Harness();
      await tester.runAsync(() => h.setUp(touchMode: mode, files: files));
      await tester.pumpWidget(h.app());
      await tester.pump(const Duration(milliseconds: 300));
      h.input.clear();
    }

    testWidgets('touchpad: a tap clicks at the virtual cursor (screen centre first)', (tester) async {
      await touchApp(tester);
      await tester.tapAt(const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 50));
      final md = h.ofType('md').single;
      expect(md['b'], 0);
      expect(md['x'], 0.5);
      expect(md['y'], 0.5);
      expect(h.ofType('mu'), hasLength(1));
      await finish(tester);
    });

    testWidgets('touchpad: dragging moves the cursor relatively', (tester) async {
      await touchApp(tester);
      final g = await tester.startGesture(const Offset(100, 300));
      await g.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 20));
      await g.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 20));
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      final moves = h.ofType('mm');
      expect(moves, isNotEmpty);
      // 100 px of finger travel * 1.6 gain over a 800 px wide picture = +0.2.
      expect(moves.last['x'] as double, closeTo(0.5 + 100 * 1.6 / 800, 1e-3));
      expect(moves.last['y'], 0.5);
      expect(h.ofType('md'), isEmpty);
      await finish(tester);
    });

    testWidgets('direct mode: touching puts the cursor under the finger and a tap clicks there', (tester) async {
      await touchApp(tester, mode: 'direct');
      // 800x600 viewport, 16:9 picture => 800 x 450 at y = 75.
      await tester.tapAt(const Offset(200, 75 + 450 / 2));
      await tester.pump(const Duration(milliseconds: 50));
      final md = h.ofType('md').single;
      expect(md['x'], 0.25);
      expect(md['y'], 0.5);
      await finish(tester);
    });

    testWidgets('two-finger tap is a right click', (tester) async {
      await touchApp(tester);
      final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
      final b = await tester.startGesture(const Offset(360, 300), pointer: 2);
      await tester.pump(const Duration(milliseconds: 40));
      await b.up();
      await a.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.ofType('md').single['b'], 2);
      await finish(tester);
    });

    testWidgets('two-finger drag scrolls', (tester) async {
      await touchApp(tester);
      final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
      final b = await tester.startGesture(const Offset(360, 300), pointer: 2);
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(0, -20));
        await b.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 50));
      final total = h.ofType('wh').fold<double>(0, (s, m) => s + (m['dy'] as double));
      expect(total, greaterThan(0), reason: 'fingers up scroll the content down');
      await finish(tester);
    });

    testWidgets('pinch zoom changes how touches map to the remote screen', (tester) async {
      await touchApp(tester, mode: 'direct');
      // Pinch outwards around the centre.
      final a = await tester.startGesture(const Offset(380, 300), pointer: 1);
      final b = await tester.startGesture(const Offset(420, 300), pointer: 2);
      for (var i = 0; i < 8; i++) {
        await a.moveBy(const Offset(-25, 0));
        await b.moveBy(const Offset(25, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 50));
      h.input.clear();
      // Zoomed in: the viewport's left edge now shows a point right of x = 0.
      await tester.tapAt(const Offset(1, 75 + 450 / 2));
      await tester.pump(const Duration(milliseconds: 50));
      final md = h.ofType('md');
      expect(md, isNotEmpty);
      expect(md.single['x'] as double, greaterThan(0.1));
      expect(md.single['y'] as double, closeTo(0.5, 0.05));
      await finish(tester);
    });

    testWidgets('on a phone the Files button opens the panel as a bottom sheet and More offers Send files', (tester) async {
      await touchApp(tester, size: const Size(400, 800));
      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileTransferPanel), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(FileTransferPanel), findsNothing);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Send files…'), findsOneWidget);
      expect(find.text('Send folder…'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5)); // dismiss the menu
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.tearDown);
    });

    testWidgets('on a phone without the files permission More has no Send entries and there is no Files button', (tester) async {
      await touchApp(tester, size: const Size(400, 800), files: false);
      expect(find.byTooltip('Files'), findsNothing);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Send files…'), findsNothing);
      expect(find.text('Send folder…'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.tearDown);
    });

    testWidgets('the keyboard button reveals the extra-keys row', (tester) async {
      await touchApp(tester);
      expect(find.text('Esc'), findsNothing);
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Esc'), findsOneWidget);
      await tester.tap(find.text('Esc'));
      await tester.pump();
      expect(h.input.map((m) => '${m['t']}${m['c']}'), ['kd${0x70029}', 'ku${0x70029}']);
      // Latched Ctrl is released after the next key.
      await tester.tap(find.text('Ctrl'));
      await tester.tap(find.text('Tab'));
      await tester.pump();
      expect(h.input.map((m) => '${m['t']}${m['c']}').skip(2), [
        'kd${0x700E0}',
        'kd${0x7002B}',
        'ku${0x7002B}',
        'ku${0x700E0}',
      ]);
      await finish(tester);
    });
  });
}
