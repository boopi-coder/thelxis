import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/protocol/input_messages.dart';
import 'package:thelxis/session/input_encoder.dart';

void main() {
  late List<InputMessage> sent;
  late InputEncoder enc;
  var nowUs = 1000000;

  setUp(() {
    sent = [];
    nowUs = 1000000;
    // A frozen clock makes the 8.3 ms window deterministic under load.
    enc = InputEncoder(sent.add, nowMicros: () => nowUs);
  });
  tearDown(() => enc.dispose());

  test('the first move is sent immediately, a burst is coalesced to the last position', () async {
    enc.mouseMove(0.1, 0.1);
    expect(sent, hasLength(1));
    for (var i = 0; i < 50; i++) {
      enc.mouseMove(0.2 + i * 0.001, 0.2);
    }
    expect(sent, hasLength(1), reason: 'within the 8 ms window nothing else goes out');
    nowUs += 20000;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sent, hasLength(2), reason: 'one trailing message for the whole burst');
    final last = sent.last as MouseMove;
    expect(last.x, closeTo(0.249, 1e-9), reason: 'the final position is always delivered');
  });

  test('rate never exceeds ~120 Hz', () async {
    final real = InputEncoder(sent.add);
    addTearDown(real.dispose);
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 200) {
      real.mouseMove(sw.elapsedMicroseconds / 1e6, 0.5);
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final moves = sent.whereType<MouseMove>().length;
    // 230 ms at 120 Hz is at most ~28 messages (plus slack for timer jitter).
    expect(moves, lessThanOrEqualTo(32));
    expect(moves, greaterThan(2));
  });

  test('a button press flushes the pending move first so order is preserved', () {
    enc.mouseMove(0.1, 0.1);
    enc.mouseMove(0.3, 0.3); // pending
    enc.mouseDown(0, 0.3, 0.3);
    expect(sent.map((m) => m.runtimeType), [MouseMove, MouseMove, MouseDown]);
    expect((sent[1] as MouseMove).x, 0.3);
  });

  test('held keys and buttons are tracked and released together', () {
    enc.keyDown(0x700E0);
    enc.keyDown(0x70004);
    enc.mouseDown(0, 0.4, 0.5);
    enc.mouseDown(2, 0.4, 0.5);
    expect(enc.heldKeys, {0x700E0, 0x70004});
    expect(enc.heldButtons, {0, 2});
    sent.clear();
    enc.releaseAll();
    expect(sent.whereType<KeyUp>().map((k) => k.code).toSet(), {0x700E0, 0x70004});
    final ups = sent.whereType<MouseUp>().toList();
    expect(ups.map((u) => u.button).toSet(), {0, 2});
    expect(ups.every((u) => u.x == 0.4 && u.y == 0.5), isTrue, reason: 'released where the pointer last was');
    expect(enc.hasHeldInput, isFalse);
  });

  test('wheel deltas are accumulated and bounded', () async {
    enc.wheel(0, 10);
    enc.wheel(0, 10);
    enc.wheel(0, 10);
    nowUs += 20000;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final total = sent.whereType<Wheel>().fold<double>(0, (s, w) => s + w.dy);
    expect(total, 30);
    sent.clear();
    nowUs += 20000;
    enc.wheel(0, 99999);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((sent.whereType<Wheel>().last).dy, lessThanOrEqualTo(1200));
  });

  test('text, special and tapKey', () {
    enc.text('');
    enc.text('привет');
    enc.special('lock');
    enc.tapKey(0x70029);
    expect(sent.map((m) => m.toJson()['t']), ['txt', 'sp', 'kd', 'ku']);
    expect(enc.hasHeldInput, isFalse);
  });
}
