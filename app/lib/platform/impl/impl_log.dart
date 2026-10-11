// Minimal logger for the native layer. Injector methods must never throw, so
// every failure funnels through here. Repeats of the same message are muted
// for a few seconds: a broken API call on the mouse-move path would otherwise
// log hundreds of lines per second.
//
// Never pass key codes, typed text or clipboard contents to this logger.

import 'package:flutter/foundation.dart';

final Map<String, int> _lastLoggedMs = <String, int>{};
const int _repeatMuteMs = 5000;

void implLog(String message, [Object? error]) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final last = _lastLoggedMs[message];
  if (last != null && now - last < _repeatMuteMs) return;
  _lastLoggedMs[message] = now;
  debugPrint('[thelxis/platform] $message${error == null ? '' : ': $error'}');
}

/// Runs [body], logging (never rethrowing) any failure. Used by every
/// [InputInjector] entry point.
void guarded(String what, void Function() body) {
  try {
    body();
  } catch (e) {
    implLog('$what failed', e);
  }
}
