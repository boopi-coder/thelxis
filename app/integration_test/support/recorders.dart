import 'dart:async';

import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/session/clipboard_sync.dart';

/// One call the host made on its input injector.
sealed class Injected {
  const Injected();
}

class InjectedMove extends Injected {
  const InjectedMove(this.display, this.x, this.y);
  final HostDisplay display;
  final double x;
  final double y;
  @override
  String toString() => 'move(${display.id}, $x, $y)';
}

class InjectedButton extends Injected {
  const InjectedButton(this.button, this.down);
  final MouseButton button;
  final bool down;
  @override
  String toString() => 'button(${button.name}, ${down ? 'down' : 'up'})';
}

class InjectedScroll extends Injected {
  const InjectedScroll(this.dx, this.dy);
  final double dx;
  final double dy;
  @override
  String toString() => 'scroll($dx, $dy)';
}

class InjectedKey extends Injected {
  const InjectedKey(this.usb, this.down);
  final int usb;
  final bool down;
  @override
  String toString() => 'key(0x${usb.toRadixString(16)}, ${down ? 'down' : 'up'})';
}

class InjectedText extends Injected {
  const InjectedText(this.text);
  final String text;
  @override
  String toString() => 'text($text)';
}

class InjectedSpecial extends Injected {
  const InjectedSpecial(this.action);
  final SpecialAction action;
  @override
  String toString() => 'special(${action.name})';
}

class InjectedReleaseAll extends Injected {
  const InjectedReleaseAll();
  @override
  String toString() => 'releaseAll()';
}

/// Input injector that records instead of touching the OS, standing in for the
/// per-OS native implementation.
class RecordingInjector implements InputInjector {
  final List<Injected> events = [];

  Iterable<T> all<T extends Injected>() => events.whereType<T>();

  @override
  void mouseMove(HostDisplay display, double nx, double ny) => events.add(InjectedMove(display, nx, ny));

  @override
  void mouseButton(MouseButton button, bool down) => events.add(InjectedButton(button, down));

  @override
  void scroll(double dx, double dy) => events.add(InjectedScroll(dx, dy));

  @override
  void key(int usbHid, bool down) => events.add(InjectedKey(usbHid, down));

  @override
  void text(String text) => events.add(InjectedText(text));

  @override
  Future<void> special(SpecialAction action) async => events.add(InjectedSpecial(action));

  @override
  void releaseAll() => events.add(const InjectedReleaseAll());
}

/// A private clipboard per peer: both peers live in one process and would
/// otherwise share the single OS clipboard.
class FakeClipboard {
  FakeClipboard(this.name);

  final String name;
  static final Stopwatch _clock = Stopwatch()..start();
  String? _text;

  /// Who changed the clipboard and when (`user` = the test, `sync` = the app).
  final List<String> timeline = [];

  String? get text => _text;

  /// The user copies something.
  set text(String? value) {
    _text = value;
    _note('user', value);
  }

  ClipboardAccess get access => ClipboardAccess(
        read: () async => _text,
        write: (value) async {
          _text = value;
          _note('sync', value);
        },
      );

  void _note(String who, String? value) {
    final shown = value == null ? 'null' : '${value.length}:${value.substring(0, value.length < 10 ? value.length : 10)}';
    timeline.add('${_clock.elapsedMilliseconds} ms $name $who -> $shown');
  }
}

/// Tracks every timer created while it is installed as the zone specification,
/// so a finished scenario can prove that nothing was left running.
class TimerAudit {
  final List<_Tracked> _timers = [];

  ZoneSpecification get specification => ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          final timer = parent.createTimer(zone, duration, f);
          _timers.add(_Tracked(timer, duration, periodic: false, created: StackTrace.current));
          return timer;
        },
        createPeriodicTimer: (self, parent, zone, period, f) {
          final timer = parent.createPeriodicTimer(zone, period, f);
          _timers.add(_Tracked(timer, period, periodic: true, created: StackTrace.current));
          return timer;
        },
      );

  /// Timers created from application code that are still running: periodic
  /// ones, and one-shot ones that were meant to outlive a second (timeouts,
  /// keep-alives, retry delays). Short one-shot timers drain by themselves.
  List<String> leaks() {
    final out = <String>[];
    for (final t in _timers) {
      if (!t.timer.isActive) continue;
      if (!t.periodic && t.duration < const Duration(seconds: 1)) continue;
      final frames = t.created
          .toString()
          .split('\n')
          .where((l) => l.contains('package:thelxis/'))
          .take(3)
          .map((l) => l.trim());
      if (frames.isEmpty) continue;
      out.add('${t.periodic ? 'periodic' : 'one-shot'} ${t.duration.inMilliseconds} ms timer created at '
          '${frames.join(' <- ')}');
    }
    return out;
  }

  int get created => _timers.length;
}

class _Tracked {
  _Tracked(this.timer, this.duration, {required this.periodic, required this.created});
  final Timer timer;
  final Duration duration;
  final bool periodic;
  final StackTrace created;
}
