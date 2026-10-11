import 'dart:convert';
import 'dart:typed_data';

/// Wire format of the `files` data channel (PROTOCOL §6.4).
///
/// Decoding is deliberately forgiving about *unknown* fields and message
/// types (forward compatibility) and strict about the *known* ones: a message
/// with a wrong type or out-of-range number decodes to `null` and is ignored.

/// Largest payload of one binary frame.
const int kMaxChunkBytes = 65536;

/// Binary frame header: big-endian uint32 xid.
const int kFrameHeaderBytes = 4;

/// Longest text frame we are willing to parse. SCTP in libwebrtc caps
/// messages at 256 KiB anyway; anything bigger is hostile or broken.
const int kMaxTextFrameBytes = 256 * 1024;

/// Soft cap for one `fs_list_r` so a huge folder never exceeds the SCTP limit.
const int kListReplyBudgetBytes = 180 * 1024;

const int _maxXid = 0xFFFFFFFF;

/// `fs_err.code`.
enum FsErrCode {
  notFound('not_found'),
  denied('denied'),
  io('io');

  const FsErrCode(this.wire);
  final String wire;

  static FsErrCode parse(Object? v) => values.firstWhere((e) => e.wire == v, orElse: () => io);
}

/// `reject.reason`.
enum RejectReason {
  denied('denied'),
  exists('exists'),
  noSpace('no_space'),
  io('io');

  const RejectReason(this.wire);
  final String wire;

  static RejectReason parse(Object? v) => values.firstWhere((e) => e.wire == v, orElse: () => io);
}

/// `fail.reason`.
enum FailReason {
  hash('hash'),
  io('io');

  const FailReason(this.wire);
  final String wire;

  static FailReason parse(Object? v) => values.firstWhere((e) => e.wire == v, orElse: () => io);
}

/// One entry of `fs_roots_r`. [kind] is an optional hint (`home`, `desktop`,
/// `documents`, `downloads`, `drive`, `storage`) so a viewer can localise the
/// label; unknown kinds fall back to [name].
class FsRoot {
  const FsRoot({required this.name, required this.path, this.kind});

  final String name;
  final String path;
  final String? kind;

  Map<String, Object?> toJson() => {'name': name, 'path': path, if (kind != null) 'kind': kind};

  static FsRoot? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final path = json['path'];
    if (name is! String || path is! String || name.isEmpty || path.isEmpty) return null;
    final kind = json['kind'];
    return FsRoot(name: name, path: path, kind: kind is String ? kind : null);
  }

  @override
  bool operator ==(Object other) =>
      other is FsRoot && other.name == name && other.path == path && other.kind == kind;

  @override
  int get hashCode => Object.hash(name, path, kind);
}

/// One entry of `fs_list_r`. [mtime] is seconds since the Unix epoch.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.mtime,
    this.hidden = false,
  });

  final String name;
  final bool isDir;
  final int size;
  final int? mtime;
  final bool hidden;

  DateTime? get modified =>
      mtime == null ? null : DateTime.fromMillisecondsSinceEpoch(mtime! * 1000);

  Map<String, Object?> toJson() => {
        'name': name,
        'dir': isDir,
        'size': size,
        if (mtime != null) 'mtime': mtime,
        if (hidden) 'hidden': true,
      };

  static RemoteEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    final dir = json['dir'];
    return RemoteEntry(
      name: name,
      isDir: dir == true,
      size: _nonNegInt(json['size']) ?? 0,
      mtime: _nonNegInt(json['mtime']),
      hidden: json['hidden'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteEntry &&
      other.name == name &&
      other.isDir == isDir &&
      other.size == size &&
      other.mtime == mtime &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(name, isDir, size, mtime, hidden);
}

/// A text frame of the `files` channel.
sealed class FileMsg {
  const FileMsg();

  /// Wire value of the `t` field.
  String get type;

  Map<String, Object?> toJson();

  String encode() => jsonEncode({'t': type, ...toJson()});

  /// Parses a text frame. Returns `null` for anything malformed or unknown.
  static FileMsg? decode(String text) {
    if (text.length > kMaxTextFrameBytes) return null;
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final t = json['t'];
    if (t is! String) return null;
    switch (t) {
      case 'fs_roots':
        final rid = _rid(json);
        return rid == null ? null : FsRoots(rid);
      case 'fs_roots_r':
        final rid = _rid(json);
        final items = json['items'];
        if (rid == null || items is! List) return null;
        return FsRootsReply(rid, [for (final i in items) ?FsRoot.fromJson(i)]);
      case 'fs_list':
        final rid = _rid(json);
        final path = json['path'];
        if (rid == null || path is! String || path.isEmpty) return null;
        return FsList(rid, path, offset: _nonNegInt(json['offset']) ?? 0, limit: _nonNegInt(json['limit']));
      case 'fs_list_r':
        final rid = _rid(json);
        final path = json['path'];
        final items = json['items'];
        if (rid == null || path is! String || items is! List) return null;
        return FsListReply(
          rid,
          path,
          [for (final i in items) ?RemoteEntry.fromJson(i)],
          offset: _nonNegInt(json['offset']) ?? 0,
          total: _nonNegInt(json['total']),
        );
      case 'fs_err':
        final rid = _rid(json);
        if (rid == null) return null;
        final message = json['message'];
        return FsErr(rid, FsErrCode.parse(json['code']), message is String ? _clip(message, 300) : '');
      case 'put':
        final xid = _xid(json);
        final name = json['name'];
        final size = _nonNegInt(json['size']);
        if (xid == null || name is! String || name.isEmpty || name.length > 4096 || size == null) {
          return null;
        }
        final dest = json['dest'];
        return Put(
          xid,
          name: name,
          size: size,
          mtime: _nonNegInt(json['mtime']),
          dest: dest is String && dest.isNotEmpty ? dest : null,
        );
      case 'get':
        final xid = _xid(json);
        final path = json['path'];
        if (xid == null || path is! String || path.isEmpty) return null;
        return Get(xid, path);
      case 'accept':
        final xid = _xid(json);
        if (xid == null) return null;
        return Accept(xid, offset: _nonNegInt(json['offset']) ?? 0);
      case 'reject':
        final xid = _xid(json);
        return xid == null ? null : Reject(xid, RejectReason.parse(json['reason']));
      case 'done':
        final xid = _xid(json);
        final sha = json['sha256'];
        if (xid == null || sha is! String || !_hex64.hasMatch(sha)) return null;
        return Done(xid, sha.toLowerCase());
      case 'ok':
        final xid = _xid(json);
        return xid == null ? null : Ok(xid);
      case 'fail':
        final xid = _xid(json);
        return xid == null ? null : Fail(xid, FailReason.parse(json['reason']));
      case 'cancel':
        final xid = _xid(json);
        return xid == null ? null : Cancel(xid);
    }
    return null;
  }

  /// Messages that belong to the transfer state machine (as opposed to the
  /// remote-browsing request/response pairs).
  bool get isTransfer =>
      this is Put ||
      this is Get ||
      this is Accept ||
      this is Reject ||
      this is Done ||
      this is Ok ||
      this is Fail ||
      this is Cancel;
}

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

class FsRoots extends FileMsg {
  const FsRoots(this.rid);
  final int rid;
  @override
  String get type => 'fs_roots';
  @override
  Map<String, Object?> toJson() => {'rid': rid};
}

class FsRootsReply extends FileMsg {
  const FsRootsReply(this.rid, this.items);
  final int rid;
  final List<FsRoot> items;
  @override
  String get type => 'fs_roots_r';
  @override
  Map<String, Object?> toJson() => {'rid': rid, 'items': [for (final i in items) i.toJson()]};
}

/// `offset`/`limit` are optional paging extensions: an old peer ignores them
/// and answers with the whole listing, which this side also understands.
class FsList extends FileMsg {
  const FsList(this.rid, this.path, {this.offset = 0, this.limit});
  final int rid;
  final String path;
  final int offset;
  final int? limit;
  @override
  String get type => 'fs_list';
  @override
  Map<String, Object?> toJson() => {
        'rid': rid,
        'path': path,
        if (offset > 0) 'offset': offset,
        if (limit != null) 'limit': limit,
      };
}

class FsListReply extends FileMsg {
  const FsListReply(this.rid, this.path, this.items, {this.offset = 0, this.total});
  final int rid;
  final String path;
  final List<RemoteEntry> items;

  /// Index of the first item within the whole (sorted) directory.
  final int offset;

  /// Entries in the whole directory; `null` from peers that do not page.
  final int? total;
  @override
  String get type => 'fs_list_r';
  @override
  Map<String, Object?> toJson() => {
        'rid': rid,
        'path': path,
        'items': [for (final i in items) i.toJson()],
        if (offset > 0) 'offset': offset,
        if (total != null) 'total': total,
      };
}

class FsErr extends FileMsg {
  const FsErr(this.rid, this.code, [this.message = '']);
  final int rid;
  final FsErrCode code;
  final String message;
  @override
  String get type => 'fs_err';
  @override
  Map<String, Object?> toJson() => {'rid': rid, 'code': code.wire, if (message.isNotEmpty) 'message': message};
}

/// Offer to send a file. [name] may be a relative path (`folder/sub/a.txt`).
/// [dest] is honoured only by a host receiving from its viewer.
class Put extends FileMsg {
  const Put(this.xid, {required this.name, required this.size, this.mtime, this.dest});
  final int xid;
  final String name;
  final int size;
  final int? mtime;
  final String? dest;
  @override
  String get type => 'put';
  @override
  Map<String, Object?> toJson() => {
        'xid': xid,
        'name': name,
        'size': size,
        'mtime': mtime,
        'dest': dest,
      };
}

class Get extends FileMsg {
  const Get(this.xid, this.path);
  final int xid;
  final String path;
  @override
  String get type => 'get';
  @override
  Map<String, Object?> toJson() => {'xid': xid, 'path': path};
}

class Accept extends FileMsg {
  const Accept(this.xid, {this.offset = 0});
  final int xid;
  final int offset;
  @override
  String get type => 'accept';
  @override
  Map<String, Object?> toJson() => {'xid': xid, 'offset': offset};
}

class Reject extends FileMsg {
  const Reject(this.xid, this.reason);
  final int xid;
  final RejectReason reason;
  @override
  String get type => 'reject';
  @override
  Map<String, Object?> toJson() => {'xid': xid, 'reason': reason.wire};
}

class Done extends FileMsg {
  const Done(this.xid, this.sha256);
  final int xid;

  /// Lower-case hex SHA-256 of the whole file.
  final String sha256;
  @override
  String get type => 'done';
  @override
  Map<String, Object?> toJson() => {'xid': xid, 'sha256': sha256};
}

class Ok extends FileMsg {
  const Ok(this.xid);
  final int xid;
  @override
  String get type => 'ok';
  @override
  Map<String, Object?> toJson() => {'xid': xid};
}

class Fail extends FileMsg {
  const Fail(this.xid, this.reason);
  final int xid;
  final FailReason reason;
  @override
  String get type => 'fail';
  @override
  Map<String, Object?> toJson() => {'xid': xid, 'reason': reason.wire};
}

class Cancel extends FileMsg {
  const Cancel(this.xid);
  final int xid;
  @override
  String get type => 'cancel';
  @override
  Map<String, Object?> toJson() => {'xid': xid};
}

/// A decoded binary frame; [payload] is a view into the received buffer.
class FileFrame {
  const FileFrame(this.xid, this.payload);
  final int xid;
  final Uint8List payload;

  /// Parses `[uint32 BE xid][payload ≤ 65 536]`. Returns `null` for frames
  /// that are too short (no header) or carry an oversized payload.
  static FileFrame? decode(Uint8List frame) {
    if (frame.length < kFrameHeaderBytes) return null;
    final payloadLength = frame.length - kFrameHeaderBytes;
    if (payloadLength > kMaxChunkBytes) return null;
    final xid = ByteData.sublistView(frame).getUint32(0);
    return FileFrame(xid, Uint8List.sublistView(frame, kFrameHeaderBytes));
  }

  /// Allocates a frame buffer for [payloadLength] bytes with the xid header
  /// already written; the caller fills `buffer[kFrameHeaderBytes..]`.
  static Uint8List allocate(int xid, int payloadLength) {
    assert(payloadLength >= 0 && payloadLength <= kMaxChunkBytes);
    final frame = Uint8List(kFrameHeaderBytes + payloadLength);
    ByteData.sublistView(frame).setUint32(0, xid);
    return frame;
  }

  static Uint8List encode(int xid, List<int> payload) {
    final frame = allocate(xid, payload.length);
    frame.setRange(kFrameHeaderBytes, frame.length, payload);
    return frame;
  }
}

int? _xid(Map<dynamic, dynamic> json) {
  final v = _nonNegInt(json['xid']);
  return v != null && v > 0 && v <= _maxXid ? v : null;
}

int? _rid(Map<dynamic, dynamic> json) {
  final v = _nonNegInt(json['rid']);
  return v != null && v <= 0x7FFFFFFF ? v : null;
}

/// JSON numbers from other implementations may arrive as `1.0`.
int? _nonNegInt(Object? v) {
  if (v is int) return v >= 0 ? v : null;
  if (v is double && v.isFinite && v >= 0 && v == v.truncateToDouble() && v < 9007199254740992) {
    return v.toInt();
  }
  return null;
}

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);
