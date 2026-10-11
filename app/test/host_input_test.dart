import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/protocol/input_messages.dart';
import 'package:thelxis/session/host_input.dart';

class _Recorder implements InputInjector {
  final List<String> calls = [];

  @override
  void mouseMove(HostDisplay display, double nx, double ny) => calls.add('move ${display.id} $nx $ny');
  @override
  void mouseButton(MouseButton button, bool down) => calls.add('btn ${button.name} $down');
  @override
  void scroll(double dx, double dy) => calls.add('scroll $dx $dy');
  @override
  void key(int usbHid, bool down) => calls.add('key $usbHid $down');
  @override
  void text(String text) => calls.add('text $text');
  @override
  Future<void> special(SpecialAction action) async => calls.add('special ${action.name}');
  @override
  void releaseAll() => calls.add('releaseAll');
}

const _display = HostDisplay(
  id: '1',
  name: 'D',
  bounds: Rect.fromLTWH(0, 0, 100, 100),
  pixelWidth: 100,
  pixelHeight: 100,
  primary: true,
);

void main() {
  late _Recorder rec;
  late HostInputDispatcher d;

  setUp(() {
    rec = _Recorder();
    d = HostInputDispatcher(rec)
      ..enabled = true
      ..display = _display;
  });

  test('dispatches every message type to the injector', () {
    d.handle(const MouseMove(0.25, 0.75));
    d.handle(const MouseDown(2, 0.5, 0.5));
    d.handle(const MouseUp(2, 0.5, 0.5));
    d.handle(const Wheel(0, 60));
    d.handle(const KeyDown(0x70004));
    d.handle(const KeyUp(0x70004));
    d.handle(const TextInput('Привет'));
    d.handle(const SpecialInput('lock'));
    expect(rec.calls, [
      'move 1 0.25 0.75',
      'move 1 0.5 0.5',
      'btn right true',
      'move 1 0.5 0.5',
      'btn right false',
      'scroll 0.0 60.0',
      'key 458756 true',
      'key 458756 false',
      'text Привет',
      'special lock',
    ]);
  });

  test('nothing is injected unless control is enabled and a display is known', () {
    d.enabled = false;
    d.handle(const MouseMove(0.1, 0.1));
    d.handle(const KeyDown(0x70004));
    expect(rec.calls, isEmpty);
    d.enabled = true;
    d.display = null;
    d.handle(const MouseMove(0.1, 0.1));
    expect(rec.calls, isEmpty);
  });

  test('network input is validated: coordinates clamped, bad buttons, keys, NaN, unknown actions', () {
    d.handle(const MouseMove(5, -3));
    d.handle(const MouseMove(double.nan, 0.5));
    d.handle(const MouseDown(9, 0.5, 0.5));
    d.handle(const KeyDown(0));
    d.handle(const KeyDown(0x7FFFFFFF));
    d.handle(const Wheel(double.infinity, 0));
    d.handle(const Wheel(0, 1e9));
    d.handle(const SpecialInput('format_disk'));
    d.handle(const TextInput(''));
    expect(rec.calls, ['move 1 1.0 0.0', 'scroll 0.0 2400.0']);
  });

  test('releaseAll releases exactly what is held, then the injector', () {
    d.handle(const KeyDown(0x700E0));
    d.handle(const KeyDown(0x70004));
    d.handle(const MouseDown(0, 0.1, 0.1));
    expect(d.heldKeys, {0x700E0, 0x70004});
    expect(d.heldButtons, {0});
    rec.calls.clear();
    d.releaseAll();
    expect(rec.calls.where((c) => c.startsWith('key')).toSet(), {'key 458976 false', 'key 458756 false'});
    expect(rec.calls, contains('btn left false'));
    expect(rec.calls.last, 'releaseAll');
    expect(d.heldKeys, isEmpty);
    expect(d.heldButtons, isEmpty);
  });

  test('special action names', () {
    for (final a in SpecialInput.known) {
      expect(specialActionFor(a), isNotNull, reason: a);
    }
    expect(specialActionFor('nope'), isNull);
  });
}
