import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/log.dart';
import 'file_channel.dart';
import 'hashing.dart';
import 'host_fs.dart';
import 'local_files.dart';
import 'log_safe.dart';
import 'protocol.dart';
import 'safe_path.dart';
import 'transfer.dart';
import 'transfer_flows.dart';

part 'transfer_receive.dart';
part 'transfer_send.dart';

const Logger _log = Logger('files.engine');

/// The transfer state machine of PROTOCOL §6.4, for one session side.
///
/// * At most one outbound stream and one inbound stream are active; further
///   transfers wait in queues.
/// * Incoming messages are processed strictly one after another
///   ([_serial]) — a `cancel` followed by a `put` must observe the cleanup of
///   the first before starting the second.
/// * The sender runs in its own async loop and is woken by the peer's replies.
///
/// Use through `FileTransferEndpoint`; this class is exposed for tests.
class TransferEngine {
  TransferEngine({
    required this.channel,
    required this.isHost,
    required this.filesAllowed,
    required this.incomingDir,
    required this.onChanged,
    this.onEvent,
    this.hostFs,
    this.acceptIncoming,
    this.config = const TransferConfig(),
  }) : _nextXid = isHost ? 2 : 1;

  final FileChannel channel;
  final bool isHost;
  final bool Function() filesAllowed;
  final Future<Directory> Function() incomingDir;
  final void Function() onChanged;
  final void Function(FileTransferEvent event)? onEvent;
  final HostFs? hostFs;
  final FutureOr<bool> Function(IncomingOffer offer)? acceptIncoming;
  final TransferConfig config;

  /// Every transfer in creation order (finished ones are trimmed).
  final List<Transfer> transfers = [];

  final Map<int, TransferFlow> _flows = {};
  final Queue<SendFlow> _sendQueue = Queue();
  final Queue<ReceiveFlow> _getQueue = Queue();
  final List<Completer<void>> _idleWaiters = [];

  int _nextXid;
  bool _sendLoopRunning = false;
  bool _getLoopRunning = false;
  bool _closed = false;
  bool _disposed = false;
  ReceiveFlow? _activeReceive;
  Future<void> _inbox = Future<void>.value();
  Timer? _notifyTimer;

  bool get isClosed => _closed;

  bool get _permitted => filesAllowed();

  /// xids chosen by the peer have the opposite parity: odd = viewer.
  bool _peerOwnsXid(int xid) => isHost ? xid.isOdd : xid.isEven;

  int _allocateXid() {
    final xid = _nextXid;
    _nextXid += 2;
    return xid;
  }

  // --------------------------------------------------------------------------
  // Public entry points
  // --------------------------------------------------------------------------

  /// Queues [item] for upload (host: push to the viewer).
  Transfer queueSend(LocalFileItem item, {String? remoteDir}) {
    _requireCapacity();
    final t = Transfer(
      xid: _allocateXid(),
      direction: TransferDirection.send,
      name: item.name,
      size: item.size,
      localPath: item.path,
      remoteDir: isHost ? null : remoteDir,
    );
    final flow = SendFlow(t, path: item.path, dest: t.remoteDir);
    _register(flow);
    _sendQueue.add(flow);
    _changed(immediate: true);
    _kickSend();
    return t;
  }

  /// Queues a download of [remotePath] saved as [name] (a relative name for
  /// folder downloads) below [localDir] or the incoming folder. Viewer only.
  Transfer queueGet({
    required String remotePath,
    required String name,
    String? localDir,
    int sizeHint = 0,
  }) {
    assert(!isHost, 'only the viewer requests files');
    _requireCapacity();
    final t = Transfer(
      xid: _allocateXid(),
      direction: TransferDirection.receive,
      name: name,
      size: sizeHint,
    );
    final flow = ReceiveFlow(t, requestPath: remotePath, localDir: localDir);
    _register(flow);
    _getQueue.add(flow);
    _changed(immediate: true);
    _kickGet();
    return t;
  }

  /// Records a transfer that could not even start (missing source, ...), so
  /// the user sees what happened to it.
  Transfer addFailed(String name, TransferError error, {TransferDirection direction = TransferDirection.send}) {
    final t = Transfer(xid: _allocateXid(), direction: direction, name: name, size: 0)
      ..status = TransferStatus.failed
      ..error = error
      ..finishedAt = DateTime.now();
    transfers.add(t);
    _trimHistory();
    _emit(FileTransferEventKind.failed, t);
    _changed(immediate: true);
    return t;
  }

  /// User-initiated cancel; tells the peer when it knows about [xid]. The
  /// transfer is final immediately; file cleanup follows in order with the
  /// frames still in flight.
  void cancel(int xid) {
    final flow = _flows[xid];
    if (flow == null || flow.transfer.isFinished) return;
    flow.cancelled = true;
    switch (flow) {
      case SendFlow():
        if (flow.offerSent || flow.viaGet) _sendMsg(Cancel(xid));
        // The send routine may be parked on back-pressure; it notices
        // `cancelled` as soon as it wakes and stops without sending more.
        flow.poke();
        _conclude(flow, TransferStatus.cancelled);
      case ReceiveFlow():
        // Before an offer arrived the peer may be busy with another file; a
        // late `put` for this xid is ignored because the flow is gone.
        if (flow.requestSent || flow.hasOpenFile) _sendMsg(Cancel(xid));
        final hadFile = flow.hasOpenFile;
        _conclude(flow, TransferStatus.cancelled);
        if (hadFile) _serial(() => _discardPart(flow));
    }
  }

  /// Completes when no transfer is queued or running.
  Future<void> whenIdle() {
    if (_isIdle) return Future<void>.value();
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  bool get _isIdle => _flows.isEmpty;

  /// Removes finished transfers from the list.
  void clearFinished() {
    transfers.removeWhere((t) => t.isFinished);
    _changed(immediate: true);
  }

  /// Text frame from the peer that belongs to the transfer protocol.
  void handleMessage(FileMsg message) => _serial(() => _dispatch(message));

  /// Binary frame from the peer.
  void handleFrame(Uint8List frame) => _serial(() => _onFrame(frame));

  /// The channel went away: fail whatever is unfinished but keep `.part`
  /// files so a later session can resume them.
  void onChannelClosed() {
    if (_closed) return;
    _closed = true;
    _failEverything(TransferError.closed);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (!_closed && channel.isOpen) {
      for (final flow in _flows.values) {
        final peerKnows = switch (flow) {
          SendFlow() => flow.offerSent || flow.viaGet,
          ReceiveFlow() => flow.hasOpenFile || flow.requestSent,
          _ => false,
        };
        if (peerKnows) _sendMsg(Cancel(flow.transfer.xid));
      }
    }
    _closed = true;
    _failEverything(TransferError.closed);
    _disposed = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    // A never-answering acceptIncoming hook must not block shutdown.
    await _inbox.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  // --------------------------------------------------------------------------
  // Dispatch (runs inside the serial inbox)
  // --------------------------------------------------------------------------

  Future<void> _dispatch(FileMsg message) async {
    if (_closed) return;
    _enforcePermission();
    switch (message) {
      case Put():
        await _onPut(message);
      case Get():
        await _onGet(message);
      case Accept():
        final f = _flows[message.xid];
        if (f is SendFlow && f.offerSent && f.accept == null) {
          f.accept = message;
          f.poke();
        }
      case Reject():
        _onReject(message);
      case Ok():
        final f = _flows[message.xid];
        if (f is SendFlow && f.offerSent) {
          f.ok = true;
          f.poke();
        }
      case Fail():
        final f = _flows[message.xid];
        if (f is SendFlow && f.offerSent) _peerEndedSend(f, message);
      case Done():
        await _onDone(message);
      case Cancel():
        await _onCancel(message);
      default:
        break;
    }
  }

  void _onReject(Reject message) {
    final f = _flows[message.xid];
    if (f is SendFlow && f.offerSent) {
      _peerEndedSend(f, message);
    } else if (f is ReceiveFlow && f.awaitingPut) {
      _conclude(f, TransferStatus.failed, error: _errorForReject(message.reason), byPeer: true);
    }
  }

  /// The peer ended a send with `cancel`, `reject` or `fail`.
  void _peerEndedSend(SendFlow flow, FileMsg terminal) {
    flow.terminal = terminal;
    final abort = _abortForTerminal(terminal);
    _conclude(flow, abort.status, error: abort.error, byPeer: true);
    flow.poke();
  }

  static TransferAbort _abortForTerminal(FileMsg terminal) {
    if (terminal is Reject) {
      return TransferAbort(TransferStatus.failed, error: _errorForReject(terminal.reason), byPeer: true);
    }
    if (terminal is Fail) {
      return TransferAbort(
        TransferStatus.failed,
        error: terminal.reason == FailReason.hash ? TransferError.hash : TransferError.io,
        byPeer: true,
      );
    }
    return const TransferAbort(TransferStatus.cancelled, byPeer: true);
  }

  Future<void> _onCancel(Cancel message) async {
    final f = _flows[message.xid];
    if (f is SendFlow) {
      _peerEndedSend(f, message);
    } else if (f is ReceiveFlow) {
      await _abortReceive(f, TransferStatus.cancelled, byPeer: true);
    }
  }

  /// Host only: the viewer wants a file.
  Future<void> _onGet(Get message) async {
    final fs = hostFs;
    if (!isHost || fs == null || !_peerOwnsXid(message.xid) || _flows.containsKey(message.xid)) {
      _sendMsg(Reject(message.xid, RejectReason.denied));
      return;
    }
    if (!_permitted) {
      _sendMsg(Reject(message.xid, RejectReason.denied));
      return;
    }
    if (_flows.length >= config.maxTransfers) {
      _sendMsg(Reject(message.xid, RejectReason.io));
      return;
    }
    final HostFile file;
    try {
      file = await fs.resolveFile(message.path);
    } on HostFsException catch (e) {
      _sendMsg(Reject(message.xid, e.code == FsErrCode.denied ? RejectReason.denied : RejectReason.io));
      return;
    }
    final t = Transfer(
      xid: message.xid,
      direction: TransferDirection.send,
      name: file.name,
      size: file.size,
      localPath: file.path,
    );
    final flow = SendFlow(t, path: file.path, viaGet: true);
    _register(flow);
    _sendQueue.add(flow);
    _changed(immediate: true);
    _kickSend();
  }

  /// Host only: the viewer lost the permission mid-session.
  void _enforcePermission() {
    if (!isHost || _permitted || _flows.isEmpty) return;
    for (final flow in List<TransferFlow>.of(_flows.values)) {
      if (flow is SendFlow) {
        flow.poke();
      } else if (flow is ReceiveFlow && flow.hasOpenFile) {
        unawaited(_abortReceive(
          flow,
          TransferStatus.failed,
          error: TransferError.denied,
          peerMessage: Cancel(flow.transfer.xid),
        ));
      }
    }
  }

  // --------------------------------------------------------------------------
  // Bookkeeping
  // --------------------------------------------------------------------------

  void _serial(Future<void> Function() job) {
    _inbox = _inbox.then((_) async {
      if (_disposed) return;
      await job();
    }).catchError((Object e, StackTrace s) {
      _log.w('message handling failed: ${errorTag(e)}');
    });
  }

  void _sendMsg(FileMsg message) {
    if (_closed || !channel.isOpen) return;
    channel.sendText(message.encode());
  }

  void _requireCapacity() {
    if (_flows.length >= config.maxTransfers) {
      throw const FileTransferException(TransferError.io, 'too_many_transfers');
    }
  }

  void _register(TransferFlow flow) {
    transfers.add(flow.transfer);
    _flows[flow.transfer.xid] = flow;
  }

  /// Moves [flow] to a final state. Idempotent.
  void _conclude(
    TransferFlow flow,
    TransferStatus status, {
    TransferError? error,
    bool byPeer = false,
  }) {
    final t = flow.transfer;
    if (t.isFinished) return;
    t.status = status;
    t.error = error;
    t.endedByPeer = byPeer;
    t.finishedAt = DateTime.now();
    t.eta = null;
    t.bytesPerSecond = 0;
    if (status == TransferStatus.completed) t.transferred = t.size;
    _flows.remove(t.xid);
    if (identical(_activeReceive, flow)) _activeReceive = null;
    if (flow is SendFlow) flow.poke();
    if (!flow.done.isCompleted) flow.done.complete();
    _trimHistory();
    _emit(
      switch (status) {
        TransferStatus.completed => flow.transfer.isSend ? FileTransferEventKind.sent : FileTransferEventKind.received,
        TransferStatus.cancelled => FileTransferEventKind.cancelled,
        _ => FileTransferEventKind.failed,
      },
      t,
    );
    _changed(immediate: true);
    if (_isIdle) {
      final waiters = List<Completer<void>>.of(_idleWaiters);
      _idleWaiters.clear();
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
  }

  void _failEverything(TransferError error) {
    for (final flow in List<TransferFlow>.of(_flows.values)) {
      if (flow is ReceiveFlow) {
        unawaited(_closeReceiveFile(flow));
      }
      _conclude(flow, TransferStatus.failed, error: error);
    }
    _sendQueue.clear();
    _getQueue.clear();
  }

  void _trimHistory() {
    var finished = 0;
    for (final t in transfers) {
      if (t.isFinished) finished++;
    }
    if (finished <= config.maxHistory) return;
    var toDrop = finished - config.maxHistory;
    transfers.removeWhere((t) {
      if (toDrop > 0 && t.isFinished) {
        toDrop--;
        return true;
      }
      return false;
    });
  }

  void _emit(FileTransferEventKind kind, Transfer transfer) {
    final handler = onEvent;
    if (handler == null) return;
    try {
      handler(FileTransferEvent(kind, transfer));
    } catch (e) {
      _log.w('event handler failed: ${errorTag(e)}');
    }
  }

  /// Progress notifications are rate limited; state changes are immediate.
  void _changed({bool immediate = false}) {
    if (_disposed) return;
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      onChanged();
      return;
    }
    _notifyTimer ??= Timer(config.progressInterval, () {
      _notifyTimer = null;
      if (!_disposed) onChanged();
    });
  }

  /// Updates throughput figures after [delta] more bytes moved.
  void _credit(TransferFlow flow, int delta) {
    final t = flow.transfer;
    flow.meter.add(delta, flow.clock.elapsed);
    t.bytesPerSecond = flow.meter.bytesPerSecond;
    t.eta = flow.meter.eta(t.size - t.transferred);
    _changed();
  }

  static TransferError _errorForReject(RejectReason r) => switch (r) {
        RejectReason.denied => TransferError.denied,
        RejectReason.exists => TransferError.exists,
        RejectReason.noSpace => TransferError.noSpace,
        RejectReason.io => TransferError.io,
      };

  static bool isDiskFull(FileSystemException e) {
    final code = e.osError?.errorCode;
    return code == 28 || code == 112 || code == 39; // ENOSPC, ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL
  }
}
