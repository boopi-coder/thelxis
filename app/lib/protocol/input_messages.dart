/// Messages on the `input` data channel, viewer to host (PROTOCOL.md 5.3).
/// Coordinates are normalised (0..1) to the active display.
sealed class InputMessage {
  const InputMessage();

  Map<String, dynamic> toJson();

  static InputMessage? parse(Object? json) {
    if (json is! Map) return null;
    double? d(String k) => json[k] is num ? (json[k] as num).toDouble() : null;
    int? i(String k) => json[k] is num ? (json[k] as num).toInt() : null;
    switch (json['t']) {
      case 'mm':
        final x = d('x'), y = d('y');
        return x == null || y == null ? null : MouseMove(x, y);
      case 'md':
      case 'mu':
        final b = i('b'), x = d('x'), y = d('y');
        if (b == null || x == null || y == null) return null;
        return json['t'] == 'md' ? MouseDown(b, x, y) : MouseUp(b, x, y);
      case 'wh':
        return Wheel(d('dx') ?? 0, d('dy') ?? 0);
      case 'kd':
        final c = i('c');
        return c == null ? null : KeyDown(c);
      case 'ku':
        final c = i('c');
        return c == null ? null : KeyUp(c);
      case 'txt':
        final s = json['s'];
        return s is String ? TextInput(s) : null;
      case 'sp':
        final a = json['a'];
        return a is String ? SpecialInput(a) : null;
    }
    return null;
  }
}

double _round4(double v) => (v * 10000).roundToDouble() / 10000;

class MouseMove extends InputMessage {
  const MouseMove(this.x, this.y);
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() => {'t': 'mm', 'x': _round4(x), 'y': _round4(y)};
}

class MouseDown extends InputMessage {
  const MouseDown(this.button, this.x, this.y);
  final int button;
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() =>
      {'t': 'md', 'b': button, 'x': _round4(x), 'y': _round4(y)};
}

class MouseUp extends InputMessage {
  const MouseUp(this.button, this.x, this.y);
  final int button;
  final double x;
  final double y;

  @override
  Map<String, dynamic> toJson() =>
      {'t': 'mu', 'b': button, 'x': _round4(x), 'y': _round4(y)};
}

class Wheel extends InputMessage {
  const Wheel(this.dx, this.dy);
  final double dx;
  final double dy;

  @override
  Map<String, dynamic> toJson() => {'t': 'wh', 'dx': dx, 'dy': dy};
}

class KeyDown extends InputMessage {
  const KeyDown(this.code);

  /// USB HID usage, `page << 16 | id`.
  final int code;

  @override
  Map<String, dynamic> toJson() => {'t': 'kd', 'c': code};
}

class KeyUp extends InputMessage {
  const KeyUp(this.code);
  final int code;

  @override
  Map<String, dynamic> toJson() => {'t': 'ku', 'c': code};
}

class TextInput extends InputMessage {
  const TextInput(this.text);
  final String text;

  @override
  Map<String, dynamic> toJson() => {'t': 'txt', 's': text};
}

/// Special actions: `ctrl_alt_del lock back home recents notifications power`.
class SpecialInput extends InputMessage {
  const SpecialInput(this.action);
  final String action;

  static const List<String> known = [
    'ctrl_alt_del',
    'lock',
    'back',
    'home',
    'recents',
    'notifications',
    'power',
  ];

  @override
  Map<String, dynamic> toJson() => {'t': 'sp', 'a': action};
}
