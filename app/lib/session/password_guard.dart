/// Locks password authentication after repeated failures (PROTOCOL.md 6.1:
/// 5 failures lock it for 5 minutes). Shared by all sessions of a host so an
/// attacker cannot dodge it by reconnecting.
class PasswordGuard {
  PasswordGuard({
    this.maxFailures = 5,
    this.lockout = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxFailures;
  final Duration lockout;
  final DateTime Function() _clock;

  final List<DateTime> _failures = [];
  DateTime? _lockedUntil;

  bool get isLocked {
    final until = _lockedUntil;
    if (until == null) return false;
    if (_clock().isBefore(until)) return true;
    _lockedUntil = null;
    _failures.clear();
    return false;
  }

  DateTime? get lockedUntil => isLocked ? _lockedUntil : null;

  void recordFailure() {
    final now = _clock();
    _failures
      ..removeWhere((t) => now.difference(t) > lockout)
      ..add(now);
    if (_failures.length >= maxFailures) _lockedUntil = now.add(lockout);
  }

  void recordSuccess() {
    _failures.clear();
    _lockedUntil = null;
  }
}
