import 'package:flutter/material.dart';

import '../../session/hid.dart';
import '../../session/input_encoder.dart';

/// Row of keys missing on a phone keyboard: Esc, Tab, sticky Ctrl / Alt /
/// Win, arrows and F1 to F12. Tap a modifier to hold it for the next key;
/// long-press to lock it.
class ExtraKeysBar extends StatefulWidget {
  const ExtraKeysBar({super.key, required this.encoder, required this.winLabel});

  final InputEncoder encoder;

  /// "Win" or "Cmd" depending on the remote OS.
  final String winLabel;

  @override
  State<ExtraKeysBar> createState() => _ExtraKeysBarState();
}

enum _Latch { off, once, locked }

class _ExtraKeysBarState extends State<ExtraKeysBar> {
  final Map<int, _Latch> _mods = {
    Hid.controlLeft: _Latch.off,
    Hid.altLeft: _Latch.off,
    Hid.metaLeft: _Latch.off,
  };

  void _tapModifier(int code) {
    final cur = _mods[code]!;
    setState(() {
      if (cur == _Latch.off) {
        _mods[code] = _Latch.once;
        widget.encoder.keyDown(code);
      } else {
        _mods[code] = _Latch.off;
        widget.encoder.keyUp(code);
      }
    });
  }

  void _lockModifier(int code) {
    setState(() {
      if (_mods[code] == _Latch.off) widget.encoder.keyDown(code);
      _mods[code] = _Latch.locked;
    });
  }

  void _press(int code) {
    widget.encoder.tapKey(code);
    // One-shot modifiers are released after the key they modify.
    setState(() {
      for (final e in _mods.entries.toList()) {
        if (e.value == _Latch.once) {
          widget.encoder.keyUp(e.key);
          _mods[e.key] = _Latch.off;
        }
      }
    });
  }

  @override
  void dispose() {
    for (final e in _mods.entries) {
      if (e.value != _Latch.off) widget.encoder.keyUp(e.key);
    }
    super.dispose();
  }

  Widget _key(String label, VoidCallback onTap, {_Latch? latch, VoidCallback? onLong, IconData? icon}) {
    final scheme = Theme.of(context).colorScheme;
    final on = latch != null && latch != _Latch.off;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
      child: Material(
        color: on ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLong,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: icon != null
                ? Icon(icon, size: 20, color: on ? scheme.onPrimary : scheme.onSurface)
                : Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: on ? scheme.onPrimary : scheme.onSurface,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            _key('Esc', () => _press(Hid.escape)),
            _key('Tab', () => _press(Hid.tab)),
            _key('Ctrl', () => _tapModifier(Hid.controlLeft),
                latch: _mods[Hid.controlLeft], onLong: () => _lockModifier(Hid.controlLeft)),
            _key('Alt', () => _tapModifier(Hid.altLeft),
                latch: _mods[Hid.altLeft], onLong: () => _lockModifier(Hid.altLeft)),
            _key(widget.winLabel, () => _tapModifier(Hid.metaLeft),
                latch: _mods[Hid.metaLeft], onLong: () => _lockModifier(Hid.metaLeft)),
            _key('', () => _press(Hid.left), icon: Icons.keyboard_arrow_left),
            _key('', () => _press(Hid.up), icon: Icons.keyboard_arrow_up),
            _key('', () => _press(Hid.down), icon: Icons.keyboard_arrow_down),
            _key('', () => _press(Hid.right), icon: Icons.keyboard_arrow_right),
            _key('Del', () => _press(Hid.delete)),
            for (var n = 1; n <= 12; n++) _key('F$n', () => _press(Hid.f(n))),
          ],
        ),
      ),
    );
  }
}
