
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/session/touch_gestures.dart';

class _Sink implements TouchGestureSink {
  final List<String> log = [];

  @override
  void cursorMoveBy(Offset delta) => log.add('by(${delta.dx.toStringAsFixed(1)},${delta.dy.toStringAsFixed(1)})');
  @override
  void cursorMoveTo(Offset position) => log.add('to(${position.dx.round()},${position.dy.round()})');
  @override
  void click(int button) => log.add('click$button');
  @override
  void buttonDown(int button) => log.add('down$button');
  @override
  void buttonUp(int button) => log.add('up$button');
  @override
  void scroll(Offset wheelDelta) => log.add('scroll(${wheelDelta.dx.toStringAsFixed(1)},${wheelDelta.dy.toStringAsFixed(1)})');
  @override
  void zoom(Offset focal, double factor, Offset pan) => log.add('zoom(${factor.toStringAsFixed(2)})');
  @override
  void longPress() => log.add('long');
}

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  late _Sink sink;
  late TouchGestureEngine engine;

  setUp(() {
    sink = _Sink();
    engine = TouchGestureEngine(sink: sink, longPressDelay: const Duration(milliseconds: 60));
  });
  tearDown(() => engine.dispose());

  group('touchpad mode', () {
    test('a quick tap is a left click', () {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerUp(1, const Offset(101, 100), _ms(80));
      expect(sink.log, ['click0']);
    });

    test('dragging moves the cursor relatively (with gain) and does not click', () {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerMove(1, const Offset(110, 100), _ms(16));
      engine.pointerMove(1, const Offset(130, 110), _ms(32));
      engine.pointerUp(1, const Offset(130, 110), _ms(48));
      expect(sink.log, ['by(16.0,0.0)', 'by(32.0,16.0)']);
    });

    test('a slow tap is not a click', () {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerUp(1, const Offset(100, 100), _ms(800));
      expect(sink.log, isEmpty);
    });

    test('two-finger tap is a right click', () {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerDown(2, const Offset(160, 100), _ms(10));
      engine.pointerUp(2, const Offset(160, 100), _ms(90));
      engine.pointerUp(1, const Offset(100, 100), _ms(95));
      expect(sink.log, ['click2']);
    });

    test('two-finger drag scrolls (natural direction) once past the threshold', () {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerDown(2, const Offset(160, 100), _ms(0));
      engine.pointerMove(1, const Offset(100, 90), _ms(16));
      engine.pointerMove(2, const Offset(160, 90), _ms(16));
      expect(sink.log, isEmpty, reason: 'below the 14 px threshold nothing happens yet');
      engine.pointerMove(1, const Offset(100, 60), _ms(32));
      engine.pointerMove(2, const Offset(160, 60), _ms(32));
      final scrolls = sink.log.where((l) => l.startsWith('scroll')).toList();
      expect(scrolls, isNotEmpty);
      // Fingers moved up (negative dy) => content scrolls down (positive wheel dy).
      expect(scrolls.last.contains(',-'), isFalse);
      engine.pointerUp(2, const Offset(160, 60), _ms(48));
      engine.pointerUp(1, const Offset(100, 60), _ms(50));
      expect(sink.log.where((l) => l.startsWith('click')), isEmpty, reason: 'a scroll is not a tap');
    });

    test('pinching zooms', () {
      engine.pointerDown(1, const Offset(100, 200), _ms(0));
      engine.pointerDown(2, const Offset(200, 200), _ms(0));
      engine.pointerMove(1, const Offset(60, 200), _ms(16));
      engine.pointerMove(2, const Offset(240, 200), _ms(16));
      expect(sink.log.where((l) => l.startsWith('zoom')), isNotEmpty);
      expect(sink.log.any((l) => l.startsWith('scroll')), isFalse);
    });

    test('long press holds the left button until release', () async {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sink.log, ['long', 'down0']);
      engine.pointerMove(1, const Offset(150, 100), _ms(200));
      engine.pointerUp(1, const Offset(150, 100), _ms(300));
      expect(sink.log.last, 'up0');
      expect(sink.log.where((l) => l.startsWith('click')), isEmpty);
    });

    test('moving before the long-press delay cancels it', () async {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerMove(1, const Offset(140, 100), _ms(10));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sink.log.contains('long'), isFalse);
    });
  });

  group('direct mode', () {
    setUp(() => engine.mode = TouchMode.direct);

    test('touch-down puts the cursor under the finger; tap clicks there', () {
      engine.pointerDown(1, const Offset(300, 200), _ms(0));
      engine.pointerUp(1, const Offset(300, 200), _ms(70));
      expect(sink.log, ['to(300,200)', 'to(300,200)', 'click0']);
    });

    test('dragging follows the finger absolutely', () {
      engine.pointerDown(1, const Offset(10, 10), _ms(0));
      engine.pointerMove(1, const Offset(50, 60), _ms(16));
      expect(sink.log.last, 'to(50,60)');
    });

    test('two-finger tap right-clicks at the centroid', () {
      engine.pointerDown(1, const Offset(100, 100), _ms(0));
      engine.pointerDown(2, const Offset(200, 100), _ms(5));
      engine.pointerUp(2, const Offset(200, 100), _ms(60));
      engine.pointerUp(1, const Offset(100, 100), _ms(65));
      expect(sink.log.contains('to(150,100)'), isTrue);
      expect(sink.log.last, 'click2');
    });
  });
}
