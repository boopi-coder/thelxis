part of 'transfer_engine.dart';

/// Sender half of the engine: one stream at a time, in queue order.
extension _SendSide on TransferEngine {
  void _kickSend() {
    if (_sendLoopRunning || _sendQueue.isEmpty || _disposed) return;
    _sendLoopRunning = true;
    unawaited(_sendLoop());
  }

  Future<void> _sendLoop() async {
    try {
      while (_sendQueue.isNotEmpty && !_disposed) {
        final flow = _sendQueue.removeFirst();
        if (flow.transfer.isFinished) continue;
        flow.started = true;
        try {
          await _runSend(flow);
        } catch (e) {
          // _runSend concludes its own failures; this is the last resort so
          // one bad transfer cannot kill the queue.
          _log.w('send routine crashed: ${errorTag(e)}');
          _conclude(flow, TransferStatus.failed, error: TransferError.io);
        }
      }
    } finally {
      _sendLoopRunning = false;
    }
    // A transfer queued while the last one was wrapping up.
    if (_sendQueue.isNotEmpty) _kickSend();
  }

  Future<void> _runSend(SendFlow flow) async {
    final t = flow.transfer;
    RandomAccessFile? raf;
    try {
      _checkSend(flow);
      final file = File(flow.path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const TransferAbort(TransferStatus.failed, error: TransferError.notFound, notifyPeer: true);
      }
      t.size = stat.size;
      raf = await file.open();
      _checkSend(flow);

      t.status = TransferStatus.waiting;
      flow.offerSent = true;
      channel.sendText(Put(
        t.xid,
        name: t.name,
        size: t.size,
        mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
        dest: flow.dest,
      ).encode());
      _changed(immediate: true);

      await _awaitReply(flow, () => flow.accept != null);
      final offset = flow.accept!.offset;
      if (offset > t.size) {
        throw const TransferAbort(TransferStatus.failed, error: TransferError.protocol, notifyPeer: true);
      }

      final hasher = FileHasher();
      // The digest in `done` covers the whole file, so a resumed transfer
      // still has to read (but not send) the part the peer already has.
      if (offset > 0) await _hashPrefix(flow, raf, offset, hasher);
      flow.clock.reset();
      flow.clock.start();
      flow.meter.start(flow.clock.elapsed);
      t.transferred = offset;
      t.status = TransferStatus.active;
      _changed(immediate: true);

      var sent = offset;
      while (sent < t.size) {
        _checkSend(flow);
        await channel.waitBufferedBelow(config.highWaterBytes);
        _checkSend(flow);

        final n = math.min(config.chunkBytes, t.size - sent);
        final frame = FileFrame.allocate(t.xid, n);
        final read = await _readFully(raf, frame, kFrameHeaderBytes, n);
        if (read < n) {
          throw const TransferAbort(TransferStatus.failed, error: TransferError.io, notifyPeer: true);
        }
        hasher.add(Uint8List.sublistView(frame, kFrameHeaderBytes));
        channel.sendBinary(frame);
        sent += n;

        // Count only what already left the send buffer, so the bar tracks the
        // network instead of racing ahead of it by up to a megabyte.
        final shown = (sent - channel.bufferedAmount).clamp(offset, sent);
        if (shown > t.transferred) {
          final delta = shown - t.transferred;
          t.transferred = shown;
          _credit(flow, delta);
        }
      }

      _checkSend(flow);
      channel.sendText(Done(t.xid, hasher.finish()).encode());
      final remaining = t.size - t.transferred;
      t.transferred = t.size;
      t.status = TransferStatus.verifying;
      if (remaining > 0) _credit(flow, remaining);
      _changed(immediate: true);

      await _awaitReply(flow, () => flow.ok);
      _conclude(flow, TransferStatus.completed);
    } on TransferAbort catch (a) {
      _finishSendAbort(flow, a);
    } on FileSystemException catch (e) {
      _log.d('send io error: ${errorTag(e)}');
      _finishSendAbort(
        flow,
        const TransferAbort(TransferStatus.failed, error: TransferError.io, notifyPeer: true),
      );
    } catch (e) {
      // Whatever else went wrong, the transfer must still end, or the queue
      // would stall behind it forever.
      _log.w('send failed: ${errorTag(e)}');
      _finishSendAbort(
        flow,
        const TransferAbort(TransferStatus.failed, error: TransferError.io, notifyPeer: true),
      );
    } finally {
      await raf?.close();
    }
  }

  void _finishSendAbort(SendFlow flow, TransferAbort abort) {
    if (abort.notifyPeer && !flow.transfer.isFinished) {
      if (flow.offerSent) {
        _sendMsg(Cancel(flow.transfer.xid));
      } else if (flow.viaGet) {
        final reason = abort.error == TransferError.denied ? RejectReason.denied : RejectReason.io;
        _sendMsg(Reject(flow.transfer.xid, reason));
      }
    }
    _conclude(flow, abort.status, error: abort.error, byPeer: abort.byPeer);
  }

  /// Throws [TransferAbort] if the transfer must stop now.
  void _checkSend(SendFlow flow) {
    final terminal = flow.terminal;
    if (terminal != null) throw TransferEngine._abortForTerminal(terminal);
    if (flow.cancelled) throw const TransferAbort(TransferStatus.cancelled);
    if (_closed) throw const TransferAbort(TransferStatus.failed, error: TransferError.closed);
    if (!_permitted) {
      throw const TransferAbort(TransferStatus.failed, error: TransferError.denied, notifyPeer: true);
    }
  }

  /// Sleeps until [ready], re-checking abort conditions on every wake-up.
  Future<void> _awaitReply(SendFlow flow, bool Function() ready) async {
    final waited = Stopwatch()..start();
    while (true) {
      _checkSend(flow);
      if (ready()) return;
      final remaining = config.replyTimeout - waited.elapsed;
      if (remaining <= Duration.zero) {
        throw const TransferAbort(TransferStatus.failed, error: TransferError.timeout, notifyPeer: true);
      }
      await flow.sleep(remaining);
    }
  }

  Future<void> _hashPrefix(SendFlow flow, RandomAccessFile raf, int length, FileHasher hasher) async {
    var remaining = length;
    while (remaining > 0) {
      _checkSend(flow);
      final chunk = await raf.read(math.min(remaining, 1 << 20));
      if (chunk.isEmpty) {
        throw const TransferAbort(TransferStatus.failed, error: TransferError.io, notifyPeer: true);
      }
      hasher.add(chunk);
      remaining -= chunk.length;
    }
  }

  static Future<int> _readFully(RandomAccessFile raf, Uint8List buffer, int start, int count) async {
    var total = 0;
    while (total < count) {
      final n = await raf.readInto(buffer, start + total, start + count);
      if (n <= 0) break;
      total += n;
    }
    return total;
  }

  void _kickGet() {
    if (_getLoopRunning || _getQueue.isEmpty || _disposed) return;
    _getLoopRunning = true;
    unawaited(_getLoop());
  }

  /// Viewer: requests queued downloads one by one; the next `get` goes out
  /// only after the previous transfer reached a final state, which keeps the
  /// host's single outbound stream from piling up requests.
  Future<void> _getLoop() async {
    try {
      while (_getQueue.isNotEmpty && !_disposed && !_closed) {
        final flow = _getQueue.removeFirst();
        if (flow.transfer.isFinished) continue;
        flow.requestSent = true;
        flow.awaitingPut = true;
        flow.transfer.status = TransferStatus.waiting;
        _changed(immediate: true);
        _sendMsg(Get(flow.transfer.xid, flow.requestPath!));
        await flow.done.future;
      }
    } finally {
      _getLoopRunning = false;
    }
    if (_getQueue.isNotEmpty && !_closed) _kickGet();
  }
}
