import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../session/hid.dart';
import '../../session/input_encoder.dart';

/// A shortcut or system action offered in the toolbar's special-keys menu.
class SpecialKey {
  const SpecialKey(this.label, this.icon, this.run);

  final String label;
  final IconData icon;
  final void Function(InputEncoder encoder) run;
}

void _chord(InputEncoder e, List<int> modifiers, int key) {
  for (final m in modifiers) {
    e.keyDown(m);
  }
  e.tapKey(key);
  for (final m in modifiers.reversed) {
    e.keyUp(m);
  }
}

/// Actions that make sense for a remote running [remoteOs]. Key combinations
/// are sent as kd/ku sequences; actions the OS reserves go through `sp`.
List<SpecialKey> specialKeysFor(String remoteOs) {
  final s = S.current;
  switch (remoteOs) {
    case 'android':
      return [
        SpecialKey(s.t('key.back'), Icons.arrow_back, (e) => e.special('back')),
        SpecialKey(s.t('key.home'), Icons.circle_outlined, (e) => e.special('home')),
        SpecialKey(s.t('key.recents'), Icons.crop_square, (e) => e.special('recents')),
        SpecialKey(s.t('key.notifications'), Icons.notifications_none, (e) => e.special('notifications')),
        SpecialKey(s.t('key.power'), Icons.power_settings_new, (e) => e.special('power')),
        SpecialKey(s.t('key.lock'), Icons.lock_outline, (e) => e.special('lock')),
      ];
    case 'macos':
      return [
        SpecialKey('Cmd', Icons.keyboard_command_key, (e) => e.tapKey(Hid.metaLeft)),
        SpecialKey('Cmd + Tab', Icons.swap_horiz, (e) => _chord(e, [Hid.metaLeft], Hid.tab)),
        SpecialKey('Cmd + Space', Icons.search, (e) => _chord(e, [Hid.metaLeft], Hid.space)),
        SpecialKey(s.t('key.lock'), Icons.lock_outline, (e) => e.special('lock')),
        SpecialKey('Esc', Icons.keyboard_return, (e) => e.tapKey(Hid.escape)),
      ];
    case 'linux':
      return [
        SpecialKey('Super', Icons.window, (e) => e.tapKey(Hid.metaLeft)),
        SpecialKey('Alt + Tab', Icons.swap_horiz, (e) => _chord(e, [Hid.altLeft], Hid.tab)),
        SpecialKey('Ctrl + Alt + Del', Icons.security, (e) => e.special('ctrl_alt_del')),
        SpecialKey(s.t('key.lock'), Icons.lock_outline, (e) => e.special('lock')),
        SpecialKey('Esc', Icons.keyboard_return, (e) => e.tapKey(Hid.escape)),
      ];
    default:
      return [
        SpecialKey('Ctrl + Alt + Del', Icons.security, (e) => e.special('ctrl_alt_del')),
        SpecialKey('Win', Icons.window, (e) => e.tapKey(Hid.metaLeft)),
        SpecialKey('Alt + Tab', Icons.swap_horiz, (e) => _chord(e, [Hid.altLeft], Hid.tab)),
        SpecialKey(
          s.t('key.taskManager'),
          Icons.monitor_heart_outlined,
          (e) => _chord(e, [Hid.controlLeft, Hid.shiftLeft], Hid.escape),
        ),
        SpecialKey(s.t('key.lock'), Icons.lock_outline, (e) => e.special('lock')),
        SpecialKey('Esc', Icons.keyboard_return, (e) => e.tapKey(Hid.escape)),
      ];
  }
}
