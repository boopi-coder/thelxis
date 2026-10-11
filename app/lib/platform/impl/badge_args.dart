// Wire format of the session badge channel (`io.thelxis/badge`), kept free of
// Flutter so the contract is unit-testable.
//
//   Dart -> native  show     {label, stopLabel, sinceMs, controlActive, peers}
//   Dart -> native  dismiss  (no arguments)
//   native -> Dart  stopPressed
//
// The native side owns the ticking clock: it computes the elapsed time from
// `sinceMs` itself every second, so the badge keeps counting even while the
// Dart isolate is busy or the Flutter window is hidden.

import '../session_badge.dart';

const String badgeChannelName = 'io.thelxis/badge';

/// `show` arguments. `sinceMs` is milliseconds since the Unix epoch (UTC).
Map<String, Object?> encodeBadgeArgs(BadgeState state) => <String, Object?>{
  'label': state.label,
  'stopLabel': state.stopLabel,
  'sinceMs': state.since.millisecondsSinceEpoch,
  'controlActive': state.controlActive,
  'peers': List<String>.unmodifiable(state.peers),
};

/// Elapsed time as the native badges render it: `HH:MM:SS`, hours are not
/// capped (100 hours is `100:00:00`), negative durations (clock changes) show
/// as zero.
String formatElapsed(Duration elapsed) {
  final total = elapsed.isNegative ? 0 : elapsed.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}
