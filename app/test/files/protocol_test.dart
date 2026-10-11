import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/protocol.dart';

FileMsg? decode(Map<String, Object?> json) => FileMsg.decode(jsonEncode(json));

void main() {
  group('round trips', () {
    test('every message survives encode/decode', () {
      final messages = <FileMsg>[
        const FsRoots(1),
        const FsRootsReply(1, [FsRoot(name: 'Home', path: '/Users/bob', kind: 'home'), FsRoot(name: 'C:\\', path: 'C:\\')]),
        const FsList(2, '/Users/bob/Documents'),
        const FsList(3, '/x', offset: 1000, limit: 500),
        const FsListReply(2, '/x', [
          RemoteEntry(name: 'a.pdf', isDir: false, size: 1234, mtime: 1760000000),
          RemoteEntry(name: '.git', isDir: true, hidden: true, mtime: 1),
        ], offset: 0, total: 2),
        const FsErr(2, FsErrCode.notFound, 'gone'),
        const Put(7, name: 'folder/sub/file.txt', size: 123, mtime: 1760000000, dest: '/tmp'),
        const Put(9, name: 'a.bin', size: 0),
        const Get(9, '/Users/bob/a.pdf'),
        const Accept(7, offset: 4096),
        const Reject(7, RejectReason.noSpace),
        Done(7, 'ab' * 32),
        const Ok(7),
        const Fail(7, FailReason.hash),
        const Cancel(7),
      ];
      for (final m in messages) {
        final back = FileMsg.decode(m.encode());
        expect(back, isNotNull, reason: m.type);
        expect(back!.encode(), m.encode(), reason: m.type);
        expect(back.runtimeType, m.runtimeType);
      }
    });

    test('put has the documented shape', () {
      final json = jsonDecode(const Put(7, name: 'report.pdf', size: 123, mtime: 1760000000).encode()) as Map;
      expect(json, {'t': 'put', 'xid': 7, 'name': 'report.pdf', 'size': 123, 'mtime': 1760000000, 'dest': null});
    });

    test('fs_list_r items carry hidden only when true', () {
      final json = jsonDecode(const FsListReply(1, '/', [
        RemoteEntry(name: 'a', isDir: false, size: 1, mtime: 2),
        RemoteEntry(name: '.b', isDir: false, size: 1, mtime: 2, hidden: true),
      ]).encode()) as Map;
      final items = json['items'] as List;
      expect((items[0] as Map).containsKey('hidden'), isFalse);
      expect((items[1] as Map)['hidden'], isTrue);
    });
  });

  group('decoding is forgiving about unknown things', () {
    test('unknown fields are ignored', () {
      final m = decode({'t': 'accept', 'xid': 5, 'offset': 10, 'future': 'x', 'nested': {'a': 1}});
      expect(m, isA<Accept>().having((a) => a.offset, 'offset', 10));
    });

    test('unknown message types decode to null', () {
      expect(decode({'t': 'teleport', 'xid': 1}), isNull);
    });

    test('unknown reason strings fall back to io', () {
      expect(decode({'t': 'reject', 'xid': 3, 'reason': 'weather'}), isA<Reject>().having((r) => r.reason, 'reason', RejectReason.io));
      expect(decode({'t': 'fail', 'xid': 3, 'reason': '??'}), isA<Fail>().having((r) => r.reason, 'reason', FailReason.io));
      expect(decode({'t': 'fs_err', 'rid': 3, 'code': '??'}), isA<FsErr>().having((r) => r.code, 'code', FsErrCode.io));
    });

    test('accept without offset means 0', () {
      expect(decode({'t': 'accept', 'xid': 3}), isA<Accept>().having((a) => a.offset, 'offset', 0));
    });

    test('fs_list_r from a peer that does not page', () {
      final m = decode({'t': 'fs_list_r', 'rid': 1, 'path': '/x', 'items': [{'name': 'a', 'dir': false, 'size': 1, 'mtime': 2}]});
      expect(m, isA<FsListReply>().having((r) => r.total, 'total', isNull));
    });

    test('invalid list items are skipped, valid ones kept', () {
      final m = decode({
        't': 'fs_list_r',
        'rid': 1,
        'path': '/x',
        'items': [
          {'name': 'ok', 'dir': true},
          {'dir': true},
          'junk',
          {'name': '', 'dir': false},
          {'name': 'also ok', 'dir': false, 'size': 3},
        ],
      }) as FsListReply;
      expect(m.items.map((e) => e.name), ['ok', 'also ok']);
    });

    test('integral doubles are accepted as integers', () {
      expect(decode({'t': 'cancel', 'xid': 4.0}), isA<Cancel>());
    });
  });

  group('decoding is strict about known fields', () {
    test('non-JSON, wrong JSON types, and oversized frames', () {
      expect(FileMsg.decode('not json'), isNull);
      expect(FileMsg.decode('[1,2]'), isNull);
      expect(FileMsg.decode('"str"'), isNull);
      expect(FileMsg.decode('{"t":5}'), isNull);
      expect(FileMsg.decode('{}'), isNull);
      expect(FileMsg.decode('{"t":"cancel","xid":1,"pad":"${'x' * kMaxTextFrameBytes}"}'), isNull);
    });

    test('xid must be a positive uint32', () {
      expect(decode({'t': 'cancel', 'xid': 0}), isNull);
      expect(decode({'t': 'cancel', 'xid': -1}), isNull);
      expect(decode({'t': 'cancel', 'xid': 4294967296}), isNull);
      expect(decode({'t': 'cancel', 'xid': 4294967295}), isA<Cancel>());
      expect(decode({'t': 'cancel', 'xid': '7'}), isNull);
      expect(decode({'t': 'cancel', 'xid': 1.5}), isNull);
      expect(decode({'t': 'cancel'}), isNull);
    });

    test('put needs name and a non-negative size', () {
      expect(decode({'t': 'put', 'xid': 1, 'name': 'a', 'size': -1}), isNull);
      expect(decode({'t': 'put', 'xid': 1, 'name': 'a'}), isNull);
      expect(decode({'t': 'put', 'xid': 1, 'name': '', 'size': 1}), isNull);
      expect(decode({'t': 'put', 'xid': 1, 'name': 7, 'size': 1}), isNull);
      expect(decode({'t': 'put', 'xid': 1, 'name': 'x' * 5000, 'size': 1}), isNull);
      expect(decode({'t': 'put', 'xid': 1, 'name': 'a', 'size': 'big'}), isNull);
    });

    test('negative offsets and bad dest are dropped', () {
      expect(decode({'t': 'accept', 'xid': 1, 'offset': -5}), isA<Accept>().having((a) => a.offset, 'offset', 0));
      expect(decode({'t': 'put', 'xid': 1, 'name': 'a', 'size': 1, 'dest': 5}), isA<Put>().having((p) => p.dest, 'dest', isNull));
      expect(decode({'t': 'put', 'xid': 1, 'name': 'a', 'size': 1, 'dest': ''}), isA<Put>().having((p) => p.dest, 'dest', isNull));
    });

    test('done requires a 64-char hex digest and normalises case', () {
      expect(decode({'t': 'done', 'xid': 1, 'sha256': 'abc'}), isNull);
      expect(decode({'t': 'done', 'xid': 1, 'sha256': 'z' * 64}), isNull);
      expect(decode({'t': 'done', 'xid': 1}), isNull);
      expect(decode({'t': 'done', 'xid': 1, 'sha256': 'AB' * 32}), isA<Done>().having((d) => d.sha256, 'sha', 'ab' * 32));
    });

    test('rid and path rules for browsing', () {
      expect(decode({'t': 'fs_list', 'rid': 1}), isNull);
      expect(decode({'t': 'fs_list', 'rid': 1, 'path': ''}), isNull);
      expect(decode({'t': 'fs_list', 'path': '/x'}), isNull);
      expect(decode({'t': 'fs_roots', 'rid': -1}), isNull);
      expect(decode({'t': 'fs_roots_r', 'rid': 1, 'items': 'x'}), isNull);
    });
  });

  group('classification', () {
    test('transfer messages vs browsing', () {
      expect(const Put(1, name: 'a', size: 0).isTransfer, isTrue);
      expect(const Cancel(1).isTransfer, isTrue);
      expect(const Get(1, '/x').isTransfer, isTrue);
      expect(const FsRoots(1).isTransfer, isFalse);
      expect(const FsErr(1, FsErrCode.io).isTransfer, isFalse);
    });
  });

  group('binary frames', () {
    test('header is a big-endian uint32 xid followed by the payload', () {
      final frame = FileFrame.encode(0x01020304, [9, 8, 7]);
      expect(frame, [1, 2, 3, 4, 9, 8, 7]);
      final back = FileFrame.decode(frame)!;
      expect(back.xid, 0x01020304);
      expect(back.payload, [9, 8, 7]);
    });

    test('max payload is accepted, one more byte is not', () {
      final ok = FileFrame.encode(1, Uint8List(kMaxChunkBytes));
      expect(FileFrame.decode(ok)?.payload.length, kMaxChunkBytes);
      final tooBig = Uint8List(kFrameHeaderBytes + kMaxChunkBytes + 1);
      expect(FileFrame.decode(tooBig), isNull);
    });

    test('short frames are rejected, empty payload is fine', () {
      expect(FileFrame.decode(Uint8List(0)), isNull);
      expect(FileFrame.decode(Uint8List(3)), isNull);
      final empty = FileFrame.decode(Uint8List.fromList([0, 0, 0, 5]))!;
      expect(empty.xid, 5);
      expect(empty.payload, isEmpty);
    });

    test('xid up to 2^32-1 round-trips', () {
      final frame = FileFrame.encode(0xFFFFFFFF, [1]);
      expect(FileFrame.decode(frame)!.xid, 0xFFFFFFFF);
    });

    test('allocate writes the header and leaves room for the payload', () {
      final f = FileFrame.allocate(258, 4);
      expect(f.length, 8);
      expect(f.sublist(0, 4), [0, 0, 1, 2]);
    });

    test('decoded payload is a view, not a copy', () {
      final frame = FileFrame.encode(1, [1, 2, 3]);
      final back = FileFrame.decode(frame)!;
      frame[4] = 99;
      expect(back.payload[0], 99);
    });
  });
}
