import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCDataChannel;

import '../files/files.dart';
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

  final ValueNotifier<RTCDataChannel?> _filesChannel = ValueNotifier(null);

  /// The `files` data channel (PROTOCOL.md section 6.4) once it exists; the
  /// file-transfer module attaches to it. Null before it opens and after the
  /// session ends.
  RTCDataChannel? get filesChannel => _filesChannel.value;
  ValueListenable<RTCDataChannel?> get filesChannelListenable => _filesChannel;

  @protected
  set filesChannel(RTCDataChannel? channel) => _filesChannel.value = channel;

  final ValueNotifier<FileTransferEndpoint?> _files = ValueNotifier(null);

  /// File transfer for this session (PROTOCOL.md section 6.4), created the
  /// moment the `files` channel exists; null before that and after the
  /// session ends. Host side: it refuses everything until the viewer is
  /// authorized and `permissions.files` is set.
  FileTransferEndpoint? get files => _files.value;
  ValueListenable<FileTransferEndpoint?> get filesListenable => _files;

  /// Receives file-transfer events (received / sent / failed ...) for the
  /// session manager's notifications.
  void Function(SessionBase session, FileTransferEvent event)? onFileEvent;

  /// Wraps [channel] in a [FileTransferEndpoint]. Call it synchronously when
  /// the channel is created or handed over: frames that arrive earlier are
  /// lost.
  @protected
  void attachFiles(
    FileChannel channel, {
    required bool isHost,
    required bool Function() filesAllowed,
    Future<Directory> Function()? incomingDir,
  }) {
    if (_files.value != null || isEnded) return;
    _files.value = FileTransferEndpoint(
      channel: channel,
      isHost: isHost,
      filesAllowed: filesAllowed,
      incomingDir: incomingDir,
      onEvent: (e) => onFileEvent?.call(this, e),
    );
    notifyListeners();
  }

  /// Stops transfers (partial downloads stay resumable) and closes the
  /// channel.
  @protected
  Future<void> detachFiles() async {
    final endpoint = _files.value;
    _files.value = null;
    filesChannel = null;
    await endpoint?.dispose();
  }

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
    _filesChannel.dispose();
    _files.dispose();
    super.dispose();
  }
}

/// Polls WebRTC stats once per second and publishes [LinkStats].
class StatsPoller {
  StatsPoller({
    required this.fetch,
    required this.target,
    this.interval = const Duration(seconds: 1),
    this.viaGateway = false,
  });

  /// The media goes through an office gateway's relay: a relayed path is then
  /// reported as [LinkPath.gateway].
  final bool viaGateway;
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
      final sample = _sampler.update(
        reports,
        nowMs: _clock.elapsedMilliseconds.toDouble(),
      );
      target.value = viaGateway && sample.path == LinkPath.relay ? sample.withPath(LinkPath.gateway) : sample;
    } on Object {
      // A failed poll just skips one sample; the link state is shown elsewhere.
    } finally {
      _busy = false;
    }
  }
}
