/// Flutter pointer button bit masks (kPrimaryButton etc.) mapped to the wire
/// button numbers of PROTOCOL.md 5.3: 0 left, 1 middle, 2 right, 3 back,
/// 4 forward.
const List<int> _masks = [0x1, 0x4, 0x2, 0x8, 0x10];

/// Turns the `buttons` bit mask carried by every Flutter pointer event into
/// press/release transitions. Flutter reports additional presses as `move`
/// events with a changed mask, so diffing is required.
class MouseButtonTracker {
  int _down = 0;

  /// Wire numbers of buttons currently held.
  List<int> get held => [
        for (var i = 0; i < _masks.length; i++)
          if (_down & _masks[i] != 0) i,
      ];

  /// Returns `(button, isDown)` transitions caused by the new mask.
  List<(int, bool)> update(int buttons) {
    final changes = <(int, bool)>[];
    for (var i = 0; i < _masks.length; i++) {
      final was = _down & _masks[i] != 0;
      final now = buttons & _masks[i] != 0;
      if (was != now) changes.add((i, now));
    }
    _down = buttons & 0x1f;
    return changes;
  }

  void reset() => _down = 0;
}
