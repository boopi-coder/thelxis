import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import 'host_roots.dart';
import 'log_safe.dart';
import 'protocol.dart';
import 'safe_path.dart';

const Logger _log = Logger('files.host');

typedef FsRootsProvider = Future<List<FsRoot>> Function();

class HostFsException implements Exception {
  const HostFsException(this.code, [this.message = '']);
  final FsErrCode code;
  final String message;

  @override
  String toString() => 'HostFsException(${code.wire}${message.isEmpty ? '' : ': $message'})';
}

/// A regular file the viewer asked for with `get`.
class HostFile {
  const HostFile({required this.path, required this.name, required this.size, required this.mtime});
  final String path;
  final String name;
  final int size;
  final int mtime;
}

/// Host side of remote browsing (`fs_roots`, `fs_list`) and the file lookup
/// for `get`. Every entry point re-evaluates [filesAllowed] because the host
/// user can revoke the permission while a session is running.
class HostFs {
  HostFs({
    required this.filesAllowed,
    FsRootsProvider? roots,
    this.maxEntries = 20000,
    this.pageSize = 1000,
    this.cacheTtl = const Duration(seconds: 10),
  }) : _roots = roots ?? discoverFsRoots;

  final bool Function() filesAllowed;
  final FsRootsProvider _roots;

  /// A directory with more entries is truncated to this many.
  final int maxEntries;
  final int pageSize;
  final Duration cacheTtl;

  // Consecutive pages of one big directory would otherwise re-list and
  // re-stat it every time.
  String? _cachedPath;
  List<RemoteEntry>? _cachedEntries;
  DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Answers a browsing request; `null` if [request] is not one.
  Future<FileMsg?> handle(FileMsg request) async {
    switch (request) {
      case FsRoots():
        if (!filesAllowed()) return FsErr(request.rid, FsErrCode.denied, 'files_not_permitted');
        try {
          return FsRootsReply(request.rid, await _roots());
        } catch (e) {
          _log.w('listing roots failed: ${errorTag(e)}');
          return FsErr(request.rid, FsErrCode.io);
        }
      case FsList():
        if (!filesAllowed()) return FsErr(request.rid, FsErrCode.denied, 'files_not_permitted');
        try {
          return await _list(request);
        } on HostFsException catch (e) {
          return FsErr(request.rid, e.code, e.message);
        }
      default:
        return null;
    }
  }

  /// Validates [path] for a `get`: it must be an absolute path to a regular
  /// file. Throws [HostFsException].
  Future<HostFile> resolveFile(String path) async {
    if (!filesAllowed()) throw const HostFsException(FsErrCode.denied, 'files_not_permitted');
    final String clean;
    try {
      clean = SafePath.checkAbsolute(path);
    } on UnsafePathException catch (e) {
      throw HostFsException(FsErrCode.io, e.reason);
    }
    try {
      final stat = await File(clean).stat();
      if (stat.type == FileSystemEntityType.notFound) {
        throw const HostFsException(FsErrCode.notFound);
      }
      if (stat.type != FileSystemEntityType.file) {
        throw const HostFsException(FsErrCode.io, 'not_a_file');
      }
      return HostFile(
        path: clean,
        name: SafePath.baseName(clean),
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
      );
    } on FileSystemException catch (e) {
      throw HostFsException(fsErrCodeFor(e));
    }
  }

  Future<FsListReply> _list(FsList request) async {
    final String path;
    try {
      path = SafePath.checkAbsolute(request.path);
    } on UnsafePathException catch (e) {
      throw HostFsException(FsErrCode.io, e.reason);
    }

    final cached = _cachedEntries;
    final fresh = request.offset > 0 &&
        cached != null &&
        _cachedPath == path &&
        DateTime.now().difference(_cachedAt) < cacheTtl;
    final entries = fresh ? cached : await _readDirectory(path);

    final start = request.offset.clamp(0, entries.length);
    final limit = (request.limit ?? pageSize).clamp(1, pageSize);
    final page = <RemoteEntry>[];
    var budget = kListReplyBudgetBytes - utf8.encode(path).length;
    for (var i = start; i < entries.length && page.length < limit; i++) {
      final cost = utf8.encode(jsonEncode(entries[i].toJson())).length + 1;
      if (budget - cost < 0 && page.isNotEmpty) break;
      budget -= cost;
      page.add(entries[i]);
    }
    return FsListReply(request.rid, path, page, offset: start, total: entries.length);
  }

  Future<List<RemoteEntry>> _readDirectory(String path) async {
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) throw const HostFsException(FsErrCode.notFound);
      if (type != FileSystemEntityType.directory) {
        throw const HostFsException(FsErrCode.notFound, 'not_a_directory');
      }
      final children = <FileSystemEntity>[];
      await for (final child in Directory(path).list(followLinks: false)) {
        children.add(child);
        if (children.length >= maxEntries) break;
      }
      final entries = <RemoteEntry>[];
      // Stat in small parallel batches: sequential awaits are slow on big
      // folders, unbounded parallelism exhausts file handles.
      for (var i = 0; i < children.length; i += 64) {
        final batch = children.sublist(i, i + 64 > children.length ? children.length : i + 64);
        final stats = await Future.wait(batch.map(_entryFor));
        for (final e in stats) {
          if (e != null) entries.add(e);
        }
      }
      entries.sort(_compareEntries);
      _cachedPath = path;
      _cachedEntries = entries;
      _cachedAt = DateTime.now();
      return entries;
    } on FileSystemException catch (e) {
      throw HostFsException(fsErrCodeFor(e));
    }
  }

  Future<RemoteEntry?> _entryFor(FileSystemEntity entity) async {
    final name = SafePath.baseName(entity.path);
    try {
      // `stat` follows links, so a link shows the type of its target.
      final stat = await entity.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      final isDir = stat.type == FileSystemEntityType.directory;
      return RemoteEntry(
        name: name,
        isDir: isDir,
        size: isDir ? 0 : stat.size,
        mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
        hidden: name.startsWith('.'),
      );
    } on FileSystemException {
      return null;
    }
  }

  static int _compareEntries(RemoteEntry a, RemoteEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return c != 0 ? c : a.name.compareTo(b.name);
  }
}

/// Maps a `dart:io` failure to the wire error code.
FsErrCode fsErrCodeFor(FileSystemException e) {
  if (e is PathNotFoundException) return FsErrCode.notFound;
  if (e is PathAccessException) return FsErrCode.denied;
  final code = e.osError?.errorCode;
  if (code == null) return FsErrCode.io;
  if (Platform.isWindows) {
    if (code == 2 || code == 3 || code == 267) return FsErrCode.notFound;
    if (code == 5) return FsErrCode.denied;
  } else {
    if (code == 2 || code == 20) return FsErrCode.notFound;
    if (code == 1 || code == 13) return FsErrCode.denied;
  }
  return FsErrCode.io;
}
