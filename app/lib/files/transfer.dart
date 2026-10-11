// Public model of one file moving in either direction.

enum TransferDirection { send, receive }

enum TransferStatus {
  /// Waiting for its turn in the queue.
  queued,

  /// Offer sent / request issued, waiting for the peer's answer.
  waiting,

  /// Bytes are flowing.
  active,

  /// All bytes delivered, waiting for the peer's checksum verdict.
  verifying,

  completed,
  failed,
  cancelled,
}

enum TransferError {
  denied,
  exists,
  noSpace,
  io,
  hash,
  unsafeName,
  notFound,
  timeout,
  closed,
  protocol,
}

/// Exponentially smoothed throughput, sampled over short windows so the number
/// shown to the user is steady instead of jumping with every chunk.
class SpeedMeter {
  SpeedMeter({this.alpha = 0.3, this.window = const Duration(milliseconds: 250)});

  final double alpha;
  final Duration window;

  double bytesPerSecond = 0;
  int _windowBytes = 0;
  Duration? _windowStart;
  bool _hasSample = false;

  /// Records [bytes] moved, observed at monotonic time [now].
  void add(int bytes, Duration now) {
    _windowStart ??= now;
    _windowBytes += bytes;
    final elapsed = now - _windowStart!;
    if (elapsed < window) return;
    final instant = _windowBytes * 1e6 / elapsed.inMicroseconds;
    bytesPerSecond = _hasSample ? alpha * instant + (1 - alpha) * bytesPerSecond : instant;
    _hasSample = true;
    _windowBytes = 0;
    _windowStart = now;
  }

  /// Starts timing at [now]; bytes added afterwards count from this instant.
  void start(Duration now) {
    reset();
    _windowStart = now;
  }

  void reset() {
    bytesPerSecond = 0;
    _windowBytes = 0;
    _windowStart = null;
    _hasSample = false;
  }

  /// Time left for [remainingBytes] at the current speed, or `null` while the
  /// speed is unknown.
  Duration? eta(int remainingBytes) {
    if (remainingBytes <= 0) return Duration.zero;
    if (bytesPerSecond < 1) return null;
    return Duration(milliseconds: (remainingBytes * 1000 / bytesPerSecond).ceil());
  }
}

/// One transfer as seen by the UI. The engine mutates it; consumers treat it
/// as read-only and rebuild when the owning endpoint notifies.
class Transfer {
  Transfer({
    required this.xid,
    required this.direction,
    required this.name,
    required this.size,
    this.localPath,
    this.remoteDir,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int xid;
  final TransferDirection direction;

  /// Display name; for folder transfers a relative path (`photos/a.jpg`).
  final String name;

  int size;

  /// Sender: the source file. Receiver: the final file once [isCompleted].
  String? localPath;

  /// Destination directory requested on the peer (uploads only).
  String? remoteDir;

  TransferStatus status = TransferStatus.queued;
  int transferred = 0;
  double bytesPerSecond = 0;
  Duration? eta;
  TransferError? error;
  final DateTime createdAt;
  DateTime? finishedAt;

  /// True when the peer (rather than the local user) ended it.
  bool endedByPeer = false;

  bool get isSend => direction == TransferDirection.send;
  bool get isReceive => direction == TransferDirection.receive;
  bool get isCompleted => status == TransferStatus.completed;
  bool get isFinished =>
      status == TransferStatus.completed ||
      status == TransferStatus.failed ||
      status == TransferStatus.cancelled;
  bool get isRunning => !isFinished;

  /// 0..1; `0` for empty files until completion.
  double get progress {
    if (isCompleted) return 1;
    if (size <= 0) return 0;
    return (transferred / size).clamp(0.0, 1.0);
  }
}

enum FileTransferEventKind {
  /// The peer started sending us a file (host notification material).
  incomingStarted,
  received,
  sent,
  failed,
  cancelled,
}

class FileTransferEvent {
  const FileTransferEvent(this.kind, this.transfer);
  final FileTransferEventKind kind;
  final Transfer transfer;
}

/// What the peer offers; passed to the optional `acceptIncoming` hook.
class IncomingOffer {
  const IncomingOffer({required this.xid, required this.name, required this.size});
  final int xid;
  final String name;
  final int size;
}

/// Thrown by endpoint calls that cannot even start.
class FileTransferException implements Exception {
  const FileTransferException(this.error, [this.message = '']);
  final TransferError error;
  final String message;

  @override
  String toString() => 'FileTransferException(${error.name}${message.isEmpty ? '' : ': $message'})';
}
