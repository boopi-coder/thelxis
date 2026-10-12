import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/protocol/input_messages.dart';
import 'package:thelxis/session/input_encoder.dart';
import 'package:thelxis/ui/session/mouse_buttons_overlay.dart';
import 'package:thelxis/ui/theme.dart';

const _screen = Size(400, 800);

// SafeArea minimum margin of the overlay.
const _margin = 8.0;
const _roomW = 400 - 2 * _margin - kMouseButtonsWidth;
const _roomH = 800 - 2 * _margin - kMouseButtonsHeight;

void main() {
  late List<InputMessage> sent;
  late InputEncoder encoder;
  late ValueNotifier<Offset> cursor;
  late List<Offset> moved;
  late int underneath;
  late List<MethodCall> haptics;

  setUp(() {
    sent = [];
    moved = [];
    underneath = 0;
    haptics = [];
    encoder = InputEncoder(sent.add);
    cursor = ValueNotifier(const Offset(0.5, 0.5));
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        haptics.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    encoder.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    Offset position = const Offset(1, 1),
    bool show = true,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(brightness),
        home: Scaffold(
          body: Stack(
            children: [
              // Stands in for the remote surface: must not see pill touches.
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => underneath++,
                  child: const SizedBox.expand(),
                ),
              ),
              if (show)
                Positioned.fill(
                  child: MouseButtonsOverlay(
                    encoder: encoder,
                    cursor: cursor,
                    position: position,
                    onPositionChanged: moved.add,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Pill at position (1, 1): bottom-right of the safe area.
  Offset leftButton() => const Offset(400 - _margin - kMouseButtonsWidth + 36 + 25, 800 - _margin - 26);
  Offset rightButton() => const Offset(400 - _margin - 40, 800 - _margin - 26);
  Offset grip() => const Offset(400 - _margin - kMouseButtonsWidth + 18, 800 - _margin - 26);

  Map<String, dynamic> json(int i) => sent[i].toJson();

  testWidgets('press sends mouse-down at the cursor, release sends mouse-up at the new cursor', (tester) async {
    await pump(tester);
    cursor.value = const Offset(0.25, 0.75);
    final g = await tester.startGesture(leftButton());
    expect(sent, hasLength(1));
    expect(json(0), {'t': 'md', 'b': 0, 'x': 0.25, 'y': 0.75});
    expect(encoder.heldButtons, {0});

    // The other finger moves the cursor while the button stays held.
    cursor.value = const Offset(0.6, 0.4);
    await g.up();
    expect(sent, hasLength(2));
    expect(json(1), {'t': 'mu', 'b': 0, 'x': 0.6, 'y': 0.4});
    expect(encoder.heldButtons, isEmpty);
  });

  testWidgets('the right button is wire button 2 and both can be held at once', (tester) async {
    await pump(tester);
    final l = await tester.startGesture(leftButton(), pointer: 1);
    final r = await tester.startGesture(rightButton(), pointer: 2);
    expect(sent.map((m) => m.toJson()['b']), [0, 2]);
    expect(encoder.heldButtons, {0, 2});
    await l.up();
    expect(encoder.heldButtons, {2});
    await r.up();
    expect(encoder.heldButtons, isEmpty);
    expect(sent.map((m) => m.toJson()['t']), ['md', 'md', 'mu', 'mu']);
  });

  testWidgets('a cancelled touch still releases the button', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(leftButton());
    await g.cancel();
    expect(sent.map((m) => m.toJson()['t']), ['md', 'mu']);
  });

  testWidgets('pill touches never reach the surface below; touches elsewhere do', (tester) async {
    await pump(tester);
    for (final p in [leftButton(), rightButton(), grip()]) {
      await (await tester.startGesture(p)).up();
    }
    expect(underneath, 0);
    await (await tester.startGesture(const Offset(50, 100))).up();
    expect(underneath, 1);
  });

  testWidgets('buttons give haptic feedback on press', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(leftButton());
    await g.up();
    expect(haptics.where((c) => c.method == 'HapticFeedback.vibrate'), hasLength(1));
  });

  testWidgets('removing the overlay while a button is held releases it exactly once', (tester) async {
    await pump(tester);
    cursor.value = const Offset(0.3, 0.3);
    final g = await tester.startGesture(rightButton());
    await pump(tester, show: false);
    expect(sent.map((m) => m.toJson()['t']), ['md', 'mu']);
    expect(json(1), {'t': 'mu', 'b': 2, 'x': 0.3, 'y': 0.3});
    await g.up();
    expect(sent, hasLength(2), reason: 'a late finger-up must not add another release');
  });

  testWidgets('no duplicate release when the encoder already let go of the button', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(leftButton());
    encoder.releaseAll();
    sent.clear();
    await g.up();
    expect(sent, isEmpty);
  });

  testWidgets('dragging the grip moves the pill and reports the fraction once, at the end', (tester) async {
    await pump(tester, position: const Offset(0.5, 0.5));
    final before = tester.getTopLeft(find.byType(Listener).last);
    final g = await tester.startGesture(const Offset(_margin + _roomW / 2 + 18, _margin + _roomH / 2 + 26));
    await g.moveBy(const Offset(52, 0));
    await g.moveBy(const Offset(0, -73.2));
    await tester.pump();
    expect(moved, isEmpty);
    await g.up();
    await tester.pump();
    expect(moved, hasLength(1));
    expect(moved.single.dx, closeTo(0.75, 1e-3));
    expect(moved.single.dy, closeTo(0.4, 1e-3));
    expect(sent, isEmpty, reason: 'moving the pill is not a click');
    expect(tester.getTopLeft(find.byType(Listener).last), isNot(before));
  });

  testWidgets('the pill is clamped to the visible area', (tester) async {
    await pump(tester, position: const Offset(0.5, 0.5));
    final g = await tester.startGesture(const Offset(_margin + _roomW / 2 + 18, _margin + _roomH / 2 + 26));
    await g.moveBy(const Offset(5000, 5000));
    await g.up();
    expect(moved.single, const Offset(1, 1));
    // Lay the pill out at its new spot before touching its grip there.
    await tester.pump();

    moved.clear();
    final g2 = await tester.startGesture(grip());
    await g2.moveBy(const Offset(-1000, -1500));
    await g2.up();
    await tester.pump();
    expect(moved.single, Offset.zero);
    // Fully inside the screen, margin kept.
    final rect = tester.getRect(find.byWidgetPredicate((w) => w is Positioned && w.width == kMouseButtonsWidth));
    expect(rect.left, _margin);
    expect(rect.top, _margin);
  });

  testWidgets('topReserve keeps the pill clear of the toolbar', (tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: MouseButtonsOverlay(
            encoder: encoder,
            cursor: cursor,
            position: Offset.zero,
            onPositionChanged: moved.add,
            topReserve: 56,
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byWidgetPredicate((w) => w is Positioned && w.width == kMouseButtonsWidth));
    expect(rect.top, 56 + _margin);
  });

  testWidgets('a position given by the parent is placed proportionally and follows a new screen size', (tester) async {
    await pump(tester, position: const Offset(0.25, 0.5));
    Rect pill() => tester.getRect(find.byWidgetPredicate((w) => w is Positioned && w.width == kMouseButtonsWidth));
    expect(pill().left, closeTo(_margin + 0.25 * _roomW, 1e-6));
    expect(pill().top, closeTo(_margin + 0.5 * _roomH, 1e-6));

    // Rotate to landscape: same fractions of the new free area.
    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    expect(pill().left, closeTo(_margin + 0.25 * (800 - 2 * _margin - kMouseButtonsWidth), 1e-6));
    expect(pill().top, closeTo(_margin + 0.5 * (400 - 2 * _margin - kMouseButtonsHeight), 1e-6));
  });

  testWidgets('screen readers get labelled buttons; activating one is a click', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(find.bySemanticsLabel('Left mouse button'), findsOneWidget);
    expect(find.bySemanticsLabel('Right mouse button'), findsOneWidget);
    expect(find.bySemanticsLabel('Drag to move'), findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel('Right mouse button'));
    await tester.pump();
    expect(sent.map((m) => m.toJson()['t']), ['md', 'mu']);
    expect(json(0)['b'], 2);
    handle.dispose();
  });

  testWidgets('pressed state is visible in both themes', (tester) async {
    for (final b in Brightness.values) {
      await pump(tester, brightness: b);
      Color fill() =>
          (tester.widget<DecoratedBox>(find.byKey(const ValueKey('mouse-button-fill-$kMouseLeft'))).decoration
                  as BoxDecoration)
              .color!;
      expect(fill().a, 0, reason: '$b: idle buttons let the picture show through');
      final g = await tester.startGesture(leftButton());
      // One frame: the press shows at once, with no fade-in.
      await tester.pump();
      expect(fill().a, greaterThan(0.5), reason: '$b');
      expect(fill().toARGB32() & 0xFFFFFF, 0x0A84FF, reason: 'the single blue accent');
      await g.up();
      await tester.pump();
      expect(fill().a, 0, reason: '$b: released');
    }
  });
}
