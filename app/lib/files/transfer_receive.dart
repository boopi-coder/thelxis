part of 'transfer_engine.dart';

/// Receiver half of the engine. Everything here runs inside the serial inbox,
/// so it never races with the next message from the peer.
extension _ReceiveSide on TransferEngine {
  Future<void> _onPut(Put offer) async {
    final known = _flows[offer.xid];
    final requested = known is ReceiveFlow && known.awaitingPut ? known : null;
    final answersGet = requested != null;
    if (!answersGet) {
      // Our own xids are only valid as answers to our `get`; anything else
      // with a duplicate or wrongly-owned xid is noise or an attack.
      if (_flows.containsKey(offer.xid) || !_peerOwnsXid(offer.xid)) {
        _log.d('ignored put with unexpected xid');
        return;
      }
    }

    final ReceiveFlow flow;
    if (requested != null) {
      flow = requested;
      flow.awaitingPut = false;
      flow.transfer.size = offer.size;
    } else {
      flow = ReceiveFlow(
        Transfer(xid: offer.xid, direction: TransferDirection.receive, name: offer.name, size: offer.size),
      );
    }
    flow.mtime = offer.mtime;

    Future<void> refuse(RejectReason reason, TransferError error) async {
      _sendMsg(Reject(offer.xid, reason));
      if (!_flows.containsKey(offer.xid)) {
        // A peer-initiated offer we never registered: still show it so the
        // user can see what was turned away.
        flow.transfer.status = TransferStatus.failed;
        flow.transfer.error = error;
        flow.transfer.endedByPeer = false;
        flow.transfer.finishedAt = DateTime.now();
        transfers.add(flow.transfer);
        _trimHistory();
        _emit(FileTransferEventKind.failed, flow.transfer);
        _changed(immediate: true);
      } else {
        _conclude(flow, TransferStatus.failed, error: error);
      }
    }

    if (!_permitted) return refuse(RejectReason.denied, TransferError.denied);
    // The peer sends one stream at a time; a second one means it is broken.
    if (_activeReceive != null) return refuse(RejectReason.io, TransferError.protocol);
    if (!answersGet && _flows.length >= config.maxTransfers) {
      return refuse(RejectReason.io, TransferError.io);
    }

    if (!answersGet && acceptIncoming != null) {
      bool allowed;
      try {
        allowed = await acceptIncoming!(IncomingOffer(xid: offer.xid, name: offer.name, size: offer.size));
      } catch (_) {
        allowed = false;
      }
      if (!allowed) return refuse(RejectReason.denied, TransferError.denied);
    }

    // For our own requests the name is the one we asked for; a peer cannot
    // choose where a download lands.
    final requestedName = answersGet ? flow.transfer.name : offer.name;
    try {
      final segments = SafePath.splitRelative(requestedName);
      final root = await _destinationRoot(flow, offer, answersGet);
      final parent = await SafePath.prepareParent(root, segments.sublist(0, segments.length - 1));
      final fileName = segments.last;
      final partPath = SafePath.join(parent.path, '$fileName$kPartSuffix');

      final offset = await _preparePart(partPath, offer.size);
      final hasher = FileHasher();
      if (offset > 0) await _hashFile(partPath, offset, hasher);
      final raf = await File(partPath).open(mode: offset > 0 ? FileMode.append : FileMode.write);

      if (flow.transfer.isFinished) {
        // Cancelled while we were preparing.
        await raf.close();
        if (offset == 0) await File(partPath).delete();
        return;
      }
      flow
        ..raf = raf
        ..partPath = partPath
        ..parentPath = parent.path
        ..fileName = fileName
        ..hasher = hasher
        ..received = offset;
      flow.transfer
        ..status = TransferStatus.active
        ..transferred = offset;
      if (!answersGet) _register(flow);
      _activeReceive = flow;
      flow.clock
        ..reset()
        ..start();
      flow.meter.start(flow.clock.elapsed);
      _sendMsg(Accept(offer.xid, offset: offset));
      _emit(FileTransferEventKind.incomingStarted, flow.transfer);
      _changed(immediate: true);
    } on UnsafePathException catch (e) {
      _log.d('refused offer: ${e.reason}');
      final unsafeName = e.kind == UnsafePathKind.name;
      await refuse(
        e.kind == UnsafePathKind.conflict ? RejectReason.io : RejectReason.denied,
        unsafeName ? TransferError.unsafeName : TransferError.denied,
      );
    } on _DestinationMissing {
      await refuse(RejectReason.io, TransferError.notFound);
    } on FileSystemException catch (e) {
      final full = TransferEngine.isDiskFull(e);
      await refuse(
        full ? RejectReason.noSpace : (fsErrCodeFor(e) == FsErrCode.denied ? RejectReason.denied : RejectReason.io),
        full ? TransferError.noSpace : TransferError.io,
      );
    } catch (e) {
      _log.w('offer handling failed: ${errorTag(e)}');
      await refuse(RejectReason.io, TransferError.io);
    }
  }

  Future<Directory> _destinationRoot(ReceiveFlow flow, Put offer, bool answersGet) async {
    if (answersGet && flow.localDir != null) {
      final dir = Directory(flow.localDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    // Only a host honours `dest`, and only for directories that exist; a
    // viewer always writes to its own incoming folder.
    if (isHost && !answersGet && offer.dest != null) {
      final path = SafePath.checkAbsolute(offer.dest!);
      if (await FileSystemEntity.type(path) != FileSystemEntityType.directory) {
        throw const _DestinationMissing();
      }
      return Directory(path);
    }
    final dir = await incomingDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Returns the offset to resume from (size of a usable `.part`), or 0 for a
  /// fresh start. A stale / oversized / non-regular leftover is cleared.
  Future<int> _preparePart(String partPath, int announcedSize) async {
    final type = await FileSystemEntity.type(partPath, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        return 0;
      case FileSystemEntityType.file:
        final size = await File(partPath).length();
        if (size <= announcedSize) return size;
        await File(partPath).delete();
        return 0;
      default:
        // A link or folder squatting on our temp name: never write through it.
        throw const UnsafePathException(UnsafePathKind.conflict, 'part_path_taken');
    }
  }

  Future<void> _hashFile(String path, int length, FileHasher hasher) async {
    final raf = await File(path).open();
    try {
      var remaining = length;
      while (remaining > 0) {
        final chunk = await raf.read(math.min(remaining, 1 << 20));
        if (chunk.isEmpty) throw const FileSystemException('part file shorter than expected');
        hasher.add(chunk);
        remaining -= chunk.length;
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> _onFrame(Uint8List bytes) async {
    if (_closed) return;
    final frame = FileFrame.decode(bytes);
    if (frame == null) return;
    final flow = _flows[frame.xid];
    if (flow is! ReceiveFlow || !flow.hasOpenFile || flow.cancelled) return;

    if (isHost && !_permitted) {
      await _abortReceive(
        flow,
        TransferStatus.failed,
        error: TransferError.denied,
        peerMessage: Cancel(frame.xid),
      );
      return;
    }
    final t = flow.transfer;
    if (flow.received + frame.payload.length > t.size) {
      await _abortReceive(
        flow,
        TransferStatus.failed,
        error: TransferError.protocol,
        peerMessage: Fail(frame.xid, FailReason.io),
      );
      return;
    }
    try {
      await flow.raf!.writeFrom(frame.payload);
    } catch (e) {
      await _abortReceive(
        flow,
        TransferStatus.failed,
        error: e is FileSystemException && TransferEngine.isDiskFull(e) ? TransferError.noSpace : TransferError.io,
        peerMessage: Fail(frame.xid, FailReason.io),
      );
      return;
    }
    flow.hasher!.add(frame.payload);
    flow.received += frame.payload.length;
    t.transferred = flow.received;
    _credit(flow, frame.payload.length);
  }

  Future<void> _onDone(Done message) async {
    final flow = _flows[message.xid];
    if (flow is! ReceiveFlow || !flow.hasOpenFile || flow.cancelled) return;
    final t = flow.transfer;
    t.status = TransferStatus.verifying;
    _changed(immediate: true);

    if (flow.received != t.size) {
      await _abortReceive(
        flow,
        TransferStatus.failed,
        error: TransferError.protocol,
        peerMessage: Fail(t.xid, FailReason.io),
      );
      return;
    }
    final digest = flow.hasher!.finish();
    try {
      await flow.raf!.flush();
      await _closeReceiveFile(flow);
    } on FileSystemException {
      await _abortReceive(flow, TransferStatus.failed,
          error: TransferError.io, peerMessage: Fail(t.xid, FailReason.io));
      return;
    }
    if (digest != message.sha256) {
      await _abortReceive(flow, TransferStatus.failed,
          error: TransferError.hash, peerMessage: Fail(t.xid, FailReason.hash));
      return;
    }

    File? claimed;
    try {
      claimed = await SafePath.claimUniqueFile(Directory(flow.parentPath!), flow.fileName!);
      await File(flow.partPath!).rename(claimed.path);
      await _restoreModified(claimed, flow.mtime);
    } catch (e) {
      if (claimed != null) {
        try {
          await claimed.delete();
        } on FileSystemException {
          // Best effort: an empty placeholder is harmless.
        }
      }
      await _abortReceive(
        flow,
        TransferStatus.failed,
        error: e is FileSystemException && TransferEngine.isDiskFull(e) ? TransferError.noSpace : TransferError.io,
        peerMessage: Fail(t.xid, FailReason.io),
      );
      return;
    }
    t.localPath = claimed.path;
    flow.partPath = null;
    _sendMsg(Ok(t.xid));
    _conclude(flow, TransferStatus.completed);
  }

  /// Applies the sender's modification time. Cosmetic, so out-of-range values
  /// (a hostile peer can send anything) and failures are simply ignored.
  Future<void> _restoreModified(File file, int? seconds) async {
    if (seconds == null || seconds <= 0 || seconds > 4102444800) return; // up to year 2100
    try {
      await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
    } on FileSystemException {
      // Not being able to restore the timestamp is harmless.
    }
  }

  /// Ends a receive: closes and (unless [keepPart]) deletes the `.part`,
  /// tells the peer via [peerMessage], and concludes the transfer.
  Future<void> _abortReceive(
    ReceiveFlow flow,
    TransferStatus status, {
    TransferError? error,
    FileMsg? peerMessage,
    bool byPeer = false,
    bool keepPart = false,
  }) async {
    if (flow.transfer.isFinished) return;
    await _closeReceiveFile(flow);
    final part = flow.partPath;
    if (part != null && !keepPart) {
      try {
        await File(part).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
    flow.partPath = null;
    if (peerMessage != null) _sendMsg(peerMessage);
    _conclude(flow, status, error: error, byPeer: byPeer);
  }

  /// Cleanup for a receive the user already cancelled: close and delete the
  /// part file (nothing else may touch it by now).
  Future<void> _discardPart(ReceiveFlow flow) async {
    await _closeReceiveFile(flow);
    final part = flow.partPath;
    flow.partPath = null;
    if (part == null) return;
    try {
      await File(part).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<void> _closeReceiveFile(ReceiveFlow flow) async {
    final raf = flow.raf;
    flow.raf = null;
    if (raf == null) return;
    try {
      await raf.close();
    } on FileSystemException {
      // Closing a file that is already broken.
    }
  }
}

class _DestinationMissing implements Exception {
  const _DestinationMissing();
}
