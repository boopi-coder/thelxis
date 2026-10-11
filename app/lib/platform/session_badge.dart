// Contract for the mandatory on-screen "being controlled" badge.
//
// OWNERSHIP: architect. Native implementations live in
// lib/platform/impl/badge_impl.dart (+ runner code per OS).
//
// Security requirement (product owner): while at least one incoming session
// is active, the host shows a small frosted-glass badge in a screen corner
// with the Thelxis logo, who is connected and the elapsed time. It is a
// separate always-on-top native window — independent of the main Flutter
// window, which may be hidden in the tray. There is deliberately NO API to
// hide it while sessions are active and NO setting to disable it. It carries
// a Stop button that ends the sessions (never just hides the badge).

import 'impl/badge_impl.dart' as impl;

class BadgeState {
  const BadgeState({
    required this.peers,
    required this.label,
    required this.stopLabel,
    required this.since,
    required this.controlActive,
  });

  /// Display names of connected viewers (verified ID shown in the app).
  final List<String> peers;

  /// Localized main line, e.g. "Подключён: Alice" / "2 подключения".
  final String label;

  /// Localized Stop button text/tooltip, e.g. "Отключить".
  final String stopLabel;

  /// Start of the earliest active session; the native side ticks the timer
  /// itself so it keeps counting even if Dart is busy.
  final DateTime since;

  /// True when at least one viewer may control (not view-only) — the badge
  /// uses a stronger accent then.
  final bool controlActive;
}

abstract class SessionBadge {
  static final SessionBadge instance = impl.createSessionBadge();

  /// Shows the badge or updates it. Called by core whenever the set of active
  /// incoming sessions changes and is non-empty.
  Future<void> show(BadgeState state);

  /// Called by core ONLY when no incoming session remains.
  Future<void> dismiss();

  /// Fires when the local user presses Stop on the badge. Core must end all
  /// incoming sessions in response.
  Stream<void> get stopRequests;
}
