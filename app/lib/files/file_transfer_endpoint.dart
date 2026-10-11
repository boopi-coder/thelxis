/// File transfer for one side of a session — the only class the app core talks
/// to.
///
/// ```dart
/// // Wrap the `files` data channel the moment it exists (host: right after
/// // createDataChannel; viewer: inside pc.onDataChannel) — frames that arrive
/// // before the wrapper exists are lost.
/// final endpoint = FileTransferEndpoint(
///   channel: RtcFileChannel(filesDataChannel),
///   isHost: true,
///   filesAllowed: () => auth?.permissions.files ?? false, // viewer: () => true
///   onEvent: (e) { /* e.kind, e.transfer.name -> "Alice sent report.pdf" */ },
/// );
/// await endpoint.sendFiles(['/home/me/a.pdf'], remoteDir: '/Users/bob/Docs');
/// await endpoint.download('/Users/bob/Docs/b.pdf');            // viewer only
/// final entries = await endpoint.remote.list('/Users/bob');     // viewer only
/// endpoint.cancel(xid);
/// await endpoint.dispose();                                      // closes the channel
/// ```
///
/// * [transfers] lists queued / active / finished transfers; the endpoint is a
///   [ChangeNotifier] (progress updates are throttled to ~10 Hz).
/// * `filesAllowed` is re-evaluated on every request and every chunk, so a
///   revoked permission aborts running transfers at once. On the host it MUST
///   return false until the viewer is authorized: the channel is open before
///   that.
/// * A viewer's `dest` and a host's file names are never trusted: see
///   `safe_path.dart`. Only a host honours `dest`; a viewer always writes to
///   its own incoming folder (or the folder the user picked for a download).
/// * Partial downloads stay as `<name>.thelxis-part` when the connection drops
///   and are resumed by the next transfer of the same file; user-cancelled or
///   corrupt ones are deleted.
/// * `acceptIncoming` (optional) lets the app veto or confirm a peer's offer
///   (for example a viewer asking before accepting files pushed by a host).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import 'file_channel.dart';
import 'host_fs.dart';
import 'local_files.dart';
import 'log_safe.dart';
import 'protocol.dart';
import 'remote_fs.dart';
import 'remote_path.dart';
import 'safe_path.dart';
import 'transfer.dart';
import 'transfer_engine.dart';
import 'transfer_flows.dart';

export 'file_channel.dart' show FileChannel, FileChannelPair, FileChannelMessage, RtcFileChannel;
export 'host_fs.dart' show FsRootsProvider;
export 'protocol.dart' show FsRoot, RemoteEntry;
export 'remote_fs.dart' show RemoteFs, RemoteFsErrorKind, RemoteFsException;
export 'transfer.dart';
export 'transfer_flows.dart' show TransferConfig;

const Logger _log = Logger('files.endpoint');

class FileTransferEndpoint extends ChangeNotifier {
  FileTransferEndpoint({
    required FileChannel channel,
    required this.isHost,
    required bool Function() filesAllowed,
    Future<Directory> Function()? incomingDir,
    void Function(FileTransferEvent event)? onEvent,
    FutureOr<bool> Function(IncomingOffer offer)? acceptIncoming,
    FsRootsProvider? rootsProvider,
    TransferConfig config = const TransferConfig(),
  })  : _channel = channel,
        _filesAllowed = filesAllowed {
    _hostFs = isHost ? HostFs(filesAllowed: filesAllowed, roots: rootsProvider) : null;
    remote = isHost
        ? RemoteFs.unsupported()
        : RemoteFs(transmit: (m) => _channel.sendText(m.encode()));
    _engine = TransferEngine(
      channel: channel,
      isHost: isHost,
      filesAllowed: filesAllowed,
      incomingDir: incomingDir ?? defaultIncomingDir,
      onChanged: _notify,
      onEvent: onEvent,
      hostFs: _hostFs,
      acceptIncoming: acceptIncoming,
      config: config,
    );
    _subscription = channel.messages.listen(_onMessage, onDone: _onChannelClosed);
  }

  final bool isHost;
  final FileChannel _channel;
  final bool Function() _filesAllowed;
  late final TransferEngine _engine;
  late final HostFs? _hostFs;
  late final StreamSubscription<FileChannelMessage> _subscription;
  bool _disposed = false;

  /// Browse the host's filesystem (viewer only; on a host every call throws
  /// [RemoteFsErrorKind.unsupported]).
  late final RemoteFs remote;

  /// Queued, running and finished transfers, oldest first.
  List<Transfer> get transfers => UnmodifiableListView(_engine.transfers);

  bool get isClosed => _engine.isClosed;

  /// Whether files may currently be exchanged (host: `permissions.files`).
  bool get allowed => _filesAllowed();

  /// Sends files and / or folders to the peer. Folders are walked recursively
  /// (symlinks inside are skipped) and arrive with their relative paths.
  /// [remoteDir] (viewer → host only) is a directory the viewer listed; the
  /// default is the host's incoming folder. Returns once everything is queued;
  /// follow progress through [transfers].
  Future<void> sendFiles(List<String> paths, {String? remoteDir}) async {
    _requireUsable();
    final expansion = await LocalFiles.expand(paths);
    if (_disposed || _engine.isClosed) throw const FileTransferException(TransferError.closed);
    for (final name in expansion.missing) {
      _engine.addFailed(name, TransferError.notFound);
    }
    for (final item in expansion.items) {
      _engine.queueSend(item, remoteDir: remoteDir);
    }
  }

  /// Viewer only: downloads a remote file, or a whole remote folder when
  /// [isDirectory] is true (probed when `null`), into [localDir] (default:
  /// `<Downloads>/Thelxis`).
  Future<void> download(String remotePath, {String? localDir, bool? isDirectory}) async {
    if (isHost) throw StateError('only a viewer can download from the host');
    _requireUsable();
    final directory = isDirectory ?? await _probeIsDirectory(remotePath);
    final name = RemotePath.baseName(remotePath);
    if (!directory) {
      _engine.queueGet(remotePath: remotePath, name: name, localDir: localDir);
      return;
    }
    var budget = LocalFiles.maxFiles;
    Future<void> walk(String dir, String prefix, int depth) async {
      if (depth > SafePath.maxDepth) return;
      final entries = await remote.list(dir);
      for (final e in entries) {
        if (budget <= 0 || _disposed) return;
        final childPath = RemotePath.join(dir, e.name);
        final childName = '$prefix/${e.name}';
        if (e.isDir) {
          await walk(childPath, childName, depth + 1);
        } else {
          budget--;
          _engine.queueGet(remotePath: childPath, name: childName, localDir: localDir, sizeHint: e.size);
        }
      }
    }

    await walk(remotePath, name, 0);
  }

  /// Cancels a queued or running transfer (both directions).
  void cancel(int xid) => _engine.cancel(xid);

  /// Removes finished transfers from [transfers].
  void clearFinished() => _engine.clearFinished();

  /// Completes when nothing is queued or running.
  Future<void> whenIdle() => _engine.whenIdle();

  /// Stops everything, tells the peer, and closes the channel. Partial
  /// downloads stay on disk for resuming.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    remote.failAll();
    await _engine.dispose();
    await _subscription.cancel();
    await _channel.close();
    super.dispose();
  }

  // --------------------------------------------------------------------------

  void _requireUsable() {
    if (_disposed || _engine.isClosed) throw const FileTransferException(TransferError.closed);
    if (isHost && !_filesAllowed()) throw const FileTransferException(TransferError.denied);
  }

  Future<bool> _probeIsDirectory(String path) async {
    try {
      await remote.list(path);
      return true;
    } on RemoteFsException catch (e) {
      if (e.kind == RemoteFsErrorKind.timeout || e.kind == RemoteFsErrorKind.closed) rethrow;
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onMessage(FileChannelMessage message) {
    if (_disposed) return;
    switch (message) {
      case FileBinaryMessage():
        _engine.handleFrame(message.bytes);
      case FileTextMessage():
        final msg = FileMsg.decode(message.text);
        if (msg == null) {
          _log.d('ignored undecodable frame');
          return;
        }
        if (msg.isTransfer) {
          _engine.handleMessage(msg);
        } else if (msg is FsRoots || msg is FsList) {
          unawaited(_serveBrowse(msg));
        } else {
          remote.handle(msg);
        }
    }
  }

  Future<void> _serveBrowse(FileMsg request) async {
    final rid = switch (request) {
      FsRoots() => request.rid,
      FsList() => request.rid,
      _ => 0,
    };
    final host = _hostFs;
    final reply = host == null
        ? FsErr(rid, FsErrCode.denied, 'not_a_host')
        : await host.handle(request) ?? FsErr(rid, FsErrCode.io);
    if (!_disposed && _channel.isOpen) _channel.sendText(reply.encode());
  }

  void _onChannelClosed() {
    if (_disposed) return;
    remote.failAll();
    _engine.onChannelClosed();
    _notify();
  }
}

/// `<Downloads>/Thelxis`, created on demand. Falls back to the documents or
/// temp directory on platforms without a downloads folder.
Future<Directory> defaultIncomingDir() async {
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (e) {
    _log.d('downloads directory unavailable: ${errorTag(e)}');
  }
  if (base == null) {
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (e) {
      _log.d('documents directory unavailable: ${errorTag(e)}');
    }
  }
  base ??= Directory.systemTemp;
  final dir = Directory(SafePath.join(base.path, 'Thelxis'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
