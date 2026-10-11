import 'dart:async';
import 'dart:io';

import 'hashing.dart';
import 'protocol.dart';
import 'transfer.dart';

/// Tunables of the transfer engine; tests shorten the timeouts.
class TransferConfig {
  const TransferConfig({
    this.chunkBytes = kMaxChunkBytes,
    this.highWaterBytes = 1 << 20,
    this.replyTimeout = const Duration(minutes: 2),
    this.progressInterval = const Duration(milliseconds: 100),
    this.maxTransfers = 20000,
    this.maxHistory = 300,
  });

  /// Payload per binary frame (≤ [kMaxChunkBytes]).
  final int chunkBytes;

  /// Sender pauses above this many buffered bytes.
  final int highWaterBytes;

  /// How long to wait for the peer's `accept` / `ok`.
  final Duration replyTimeout;

  /// Minimum gap between progress notifications.
  final Duration progressInterval;

  /// Upper bound on live (unfinished) transfers, against a flooding peer.
  final int maxTransfers;

  /// How many finished transfers stay in the list.
  final int maxHistory;
}

/// Unwinds a send/receive routine to its single exit point, which concludes
/// the transfer with the given outcome.
class TransferAbort implements Exception {
  const TransferAbort(this.status, {this.error, this.notifyPeer = false, this.byPeer = false});

  final TransferStatus status;
  final TransferError? error;

  /// The peer does not know yet that this ended and must be told.
  final bool notifyPeer;
  final bool byPeer;
}

/// Runtime state behind one [Transfer].
abstract class TransferFlow {
  TransferFlow(this.transfer);

  final Transfer transfer;
  final Stopwatch clock = Stopwatch()..start();
  final SpeedMeter meter = SpeedMeter();

  /// Completes when the transfer reaches a final state.
  final Completer<void> done = Completer<void>();

  /// The local user asked to cancel.
  bool cancelled = false;
}

/// We are the sender.
class SendFlow extends TransferFlow {
  SendFlow(super.transfer, {required this.path, this.dest, this.viaGet = false});

  final String path;

  /// `put.dest` — the folder to use on the receiving host.
  final String? dest;

  /// The peer asked for this file with `get` (so it can be told `reject`).
  final bool viaGet;

  /// The send routine took this flow off the queue.
  bool started = false;
  bool offerSent = false;

  Accept? accept;
  bool ok = false;

  /// Peer message that ends the transfer: [Cancel], [Reject] or [Fail].
  FileMsg? terminal;

  Completer<void>? _wake;

  /// Wakes the send routine so it re-evaluates its conditions.
  void poke() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> sleep(Duration max) {
    final w = _wake = Completer<void>();
    return w.future.timeout(max, onTimeout: () {});
  }
}

/// We are the receiver (either of a peer's `put` or of our own `get`).
class ReceiveFlow extends TransferFlow {
  ReceiveFlow(super.transfer, {this.requestPath, this.localDir});

  /// Remote path for a download we requested; `null` for peer-initiated
  /// pushes.
  final String? requestPath;

  /// Local folder the user picked for a requested download.
  final String? localDir;

  bool get isRequested => requestPath != null;

  bool requestSent = false;
  bool awaitingPut = false;

  // Filled in once the peer's offer was accepted.
  RandomAccessFile? raf;
  String? partPath;
  String? parentPath;
  String? fileName;
  FileHasher? hasher;
  int received = 0;
  int? mtime;

  bool get hasOpenFile => raf != null;
}
