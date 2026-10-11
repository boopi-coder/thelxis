import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/peer_identity.dart';
import 'link_stats.dart';

enum SessionPhase {
  /// Signaling / ICE in progress.
  connecting,

  /// Data channels are open, waiting for the authorization exchange.
  authenticating,

  /// Host only: the local user is looking at an accept prompt.
  awaitingApproval,
  active,

  /// Media path lost; recovering (never shows a frozen frame).
  reconnecting,
  ended,
}

/// State shared by [HostSession] and [ViewerSession] that the UI and the
/// session manager observe.
abstract class SessionBase extends ChangeNotifier {
  SessionBase({required this.sid, required this.peer}) : startedAt = DateTime.now();

  final String sid;
  final PeerIdentity peer;
  final DateTime startedAt;

  SessionPhase _phase = SessionPhase.connecting;
  DateTime? _activeSince;
  DateTime? _endedAt;
  String? _endReason;
  bool _everActive = false;

  /// Live link statistics (RTT, fps, bitrate, loss, codec, path).
  final ValueNotifier<LinkStats> stats = ValueNotifier(LinkStats.empty);

  /// Called once when the session ends, for history and cleanup.
  void Function(SessionBase session)? onEnded;

  /// True when this device is being controlled (host side).
  bool get isHost;

  SessionPhase get phase => _phase;
  bool get isEnded => _phase == SessionPhase.ended;
  bool get everActive => _everActive;
  String? get endReason => _endReason;
  DateTime? get activeSince => _activeSince;

  Duration get duration {
    final from = _activeSince;
    if (from == null) return Duration.zero;
    return (_endedAt ?? DateTime.now()).difference(from);
  }

  @protected
  void setPhase(SessionPhase next) {
    if (_phase == next || _phase == SessionPhase.ended) return;
    _phase = next;
    if (next == SessionPhase.active) {
      _activeSince ??= DateTime.now();
      _everActive = true;
    }
    if (next == SessionPhase.ended) {
      _endedAt = DateTime.now();
    }
    notifyListeners();
  }

  @protected
  void markEnded(String reason) {
    _endReason ??= reason;
    setPhase(SessionPhase.ended);
    final cb = onEnded;
    onEnded = null;
    cb?.call(this);
  }

  /// Ends the session; safe to call repeatedly.
  Future<void> end([String reason = 'user']);

  @override
  void dispose() {
    stats.dispose();
    super.dispose();
  }
}

/// Polls WebRTC stats once per second and publishes [LinkStats].
class StatsPoller {
  StatsPoller({
    required this.fetch,
    required this.target,
    this.interval = const Duration(seconds: 1),
  });

  final Future<List<StatEntry>> Function() fetch;
  final ValueNotifier<LinkStats> target;
  final Duration interval;

  final StatsSampler _sampler = StatsSampler();
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _timer;
  bool _busy = false;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final reports = await fetch();
      target.value = _sampler.update(
        reports,
        nowMs: _clock.elapsedMilliseconds.toDouble(),
      );
    } on Object {
      // A failed poll just skips one sample; the link state is shown elsewhere.
    } finally {
      _busy = false;
    }
  }
}
