import 'dart:async';

import '../core/log.dart';
import '../platform/host_platform.dart';
import '../protocol/control_messages.dart';

const _log = Logger('input-health');

/// Watches whether this host can actually inject input while a viewer holds
/// control (PROTOCOL.md 6.2 `input_state`).
///
/// The OS fails silently in both cases it looks for: macOS drops events from a
/// process without Accessibility, Windows drops events aimed at an elevated
/// window. Without this the viewer just sees a picture that ignores it.
class InputHealthMonitor {
  InputHealthMonitor({
    required this.platform,
    required this.onChanged,
    this.interval = const Duration(seconds: 3),
  });

  final HostPlatform platform;

  /// Called whenever [issue] changes (null = input works).
  final void Function(InputIssue? issue) onChanged;

  /// Re-check period; the host re-checks at least this often (PROTOCOL.md 6.2).
  final Duration interval;

  Timer? _timer;
  bool _busy = false;
  bool _stopped = true;
  bool _prompted = false;
  InputIssue? _issue;

  /// Current problem, or null when input works (or nothing has been checked).
  InputIssue? get issue => _issue;

  /// Checks now, then keeps checking every [interval] until [stop].
  Future<void> start() {
    _stopped = false;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
    return check();
  }

  /// Stops checking and forgets the current issue without reporting it:
  /// control ended, so there is nothing left to be wrong.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _issue = null;
    _prompted = false;
  }

  Future<void> check() async {
    if (_stopped || _busy) return;
    _busy = true;
    try {
      final next = await _probe();
      if (_stopped) return;
      if (next != _issue) {
        _issue = next;
        onChanged(next);
      }
    } finally {
      _busy = false;
    }
  }

  Future<InputIssue?> _probe() async {
    var status = PermissionStatus.notRequired;
    try {
      status = await platform.permissionStatus(HostPermission.inputControl);
    } on Object catch (e) {
      // An unavailable status check must not raise a false alarm.
      _log.d('input permission status unavailable: $e');
    }
    if (status == PermissionStatus.denied) {
      if (!_prompted) {
        // Once per episode: shows the OS prompt or opens the settings pane on
        // the host, where the person who can fix it is sitting.
        _prompted = true;
        try {
          await platform.requestPermission(HostPermission.inputControl);
        } on Object catch (e) {
          _log.w('requesting the input permission failed', e);
        }
      }
      return InputIssue.permission;
    }
    _prompted = false;
    final injector = platform.input;
    if (injector is InjectionReport && (injector as InjectionReport).injectionRejected) {
      return InputIssue.blocked;
    }
    return null;
  }
}
