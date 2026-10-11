import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/hashing.dart';
import 'package:thelxis/files/protocol.dart';

import 'support/raw_peer.dart';

String sha(List<int> bytes) => (FileHasher()..add(bytes)).finish();

void main() {
  late RawPeer peer;

  setUp(() async {
    peer = await RawPeer.create();
  });

  tearDown(() => peer.dispose());

  Future<void> expectRejected(Put put, {RejectReason reason = RejectReason.denied}) async {
    peer.send(put);
    final r = await peer.next<Reject>(where: (r) => r.xid == put.xid);
    expect(r.reason, reason, reason: put.name);
  }

  group('malicious file names are rejected and write nothing', () {
    test('traversal, absolute, drive, UNC, control characters, device names', () async {
      final before = await peer.snapshot();
      final names = [
        '../evil.txt',
        '../../evil.txt',
        'a/../../evil.txt',
        r'..\evil.txt',
        '/etc/cron.d/evil',
        r'\Windows\evil.dll',
        r'C:\Windows\evil.dll',
        'C:evil',
        r'\\server\share\evil',
        'evil\x00.txt',
        'a\x00/../b',
        'new\nline',
        'CON',
        'nul.txt',
        'COM1.log',
        'x/aux',
        'invoice\u202Egpj.exe',
        'a//b',
        './x',
        'x/',
        'foo.thelxis-part',
        'a' * 300,
      ];
      var xid = 1;
      for (final name in names) {
        await expectRejected(Put(xid, name: name, size: 3));
        xid += 2;
      }
      await peer.settle();
      expect(await peer.snapshot(), before, reason: 'nothing may be created');
      expect(peer.host.transfers.length, names.length);
      expect(peer.host.transfers.every((t) => t.status == TransferStatus.failed && t.error == TransferError.unsafeName), isTrue);
    });

    test('a well-behaved name is accepted (control)', () async {
      peer.send(const Put(1, name: 'ok/sub/file.txt', size: 3));
      final a = await peer.next<Accept>();
      expect(a.offset, 0);
      peer.sendFrame(1, [1, 2, 3]);
      peer.send(Done(1, sha([1, 2, 3])));
      await peer.next<Ok>();
      expect(await File('${peer.incoming.path}/ok/sub/file.txt').readAsBytes(), [1, 2, 3]);
    });

    test('traversal never escapes even when it targets a real sibling folder', () async {
      await File('${peer.outside.path}/victim.txt').writeAsString('safe');
      await expectRejected(const Put(1, name: '../outside/victim.txt', size: 4));
      expect(await File('${peer.outside.path}/victim.txt').readAsString(), 'safe');
    });
  });

  group('symlinks planted in the destination', () {
    test('a folder symlink pointing outside is refused', () async {
      await Link('${peer.incoming.path}/escape').create(peer.outside.path);
      await expectRejected(const Put(1, name: 'escape/pwned.txt', size: 3));
      await expectRejected(const Put(3, name: 'escape/deeper/pwned.txt', size: 3));
      expect(await peer.outside.list().toList(), isEmpty);
    });

    test('a symlink on the final name is skipped, never written through', () async {
      final target = File('${peer.outside.path}/target.txt')..writeAsStringSync('keep');
      await Link('${peer.incoming.path}/file.txt').create(target.path);
      peer.send(const Put(1, name: 'file.txt', size: 2));
      await peer.next<Accept>();
      peer.sendFrame(1, [7, 8]);
      peer.send(Done(1, sha([7, 8])));
      await peer.next<Ok>();
      expect(target.readAsStringSync(), 'keep');
      expect(await File('${peer.incoming.path}/file (1).txt').readAsBytes(), [7, 8]);
    });

    test('a symlink squatting on the .part name is refused', () async {
      final target = File('${peer.outside.path}/part_target')..writeAsStringSync('keep');
      await Link('${peer.incoming.path}/x.bin.thelxis-part').create(target.path);
      await expectRejected(const Put(1, name: 'x.bin', size: 4), reason: RejectReason.io);
      expect(target.readAsStringSync(), 'keep');
    });

    test('a directory squatting on the .part name is refused', () async {
      await Directory('${peer.incoming.path}/x.bin.thelxis-part').create();
      await expectRejected(const Put(1, name: 'x.bin', size: 4), reason: RejectReason.io);
    });

    test('a file in the way of a folder segment is refused', () async {
      await File('${peer.incoming.path}/folder').writeAsString('i am a file');
      await expectRejected(const Put(1, name: 'folder/x.txt', size: 1), reason: RejectReason.io);
    });
  });

  group('dest (host receiving from the viewer)', () {
    test('an existing absolute directory is honoured, names stay inside it', () async {
      final dir = await Directory('${peer.tmp.path}/chosen').create();
      peer.send(Put(1, name: 'x.txt', size: 1, dest: dir.path));
      await peer.next<Accept>();
      peer.sendFrame(1, [5]);
      peer.send(Done(1, sha([5])));
      await peer.next<Ok>();
      expect(await File('${dir.path}/x.txt').readAsBytes(), [5]);
      await expectRejected(Put(3, name: '../x.txt', size: 1, dest: dir.path));
    });

    test('relative, missing, traversing and UNC destinations are rejected', () async {
      await expectRejected(const Put(1, name: 'a', size: 1, dest: 'relative/dir'));
      await expectRejected(Put(3, name: 'a', size: 1, dest: '${peer.tmp.path}/missing'), reason: RejectReason.io);
      await expectRejected(Put(5, name: 'a', size: 1, dest: '${peer.incoming.path}/../outside'));
      await expectRejected(const Put(7, name: 'a', size: 1, dest: '//evil/share'));
      await expectRejected(Put(9, name: 'a', size: 1, dest: '${peer.incoming.path}/a\x00b'));
      expect(await peer.outside.list().toList(), isEmpty);
    });

    test('a destination that is a file is rejected', () async {
      final f = File('${peer.tmp.path}/afile')..writeAsStringSync('x');
      await expectRejected(Put(1, name: 'a', size: 1, dest: f.path), reason: RejectReason.io);
    });
  });

  group('protocol abuse', () {
    test('xids with the wrong parity are ignored', () async {
      peer.send(const Put(2, name: 'even.txt', size: 1)); // a viewer must use odd xids
      await peer.settle();
      expect(peer.received.whereType<Accept>(), isEmpty);
      expect(peer.received.whereType<Reject>(), isEmpty);
      expect(peer.host.transfers, isEmpty);
    });

    test('a duplicate xid does not disturb the running transfer', () async {
      peer.send(const Put(1, name: 'a.txt', size: 4));
      await peer.next<Accept>();
      peer.send(const Put(1, name: 'b.txt', size: 4));
      peer.sendFrame(1, [1, 2]);
      peer.sendFrame(1, [3, 4]);
      peer.send(Done(1, sha([1, 2, 3, 4])));
      await peer.next<Ok>();
      expect(await File('${peer.incoming.path}/a.txt').readAsBytes(), [1, 2, 3, 4]);
      expect(await File('${peer.incoming.path}/b.txt').exists(), isFalse);
    });

    test('a second concurrent offer is rejected while the first keeps going', () async {
      peer.send(const Put(1, name: 'a.txt', size: 2));
      await peer.next<Accept>();
      await expectRejected(const Put(3, name: 'b.txt', size: 2), reason: RejectReason.io);
      peer.sendFrame(1, [1, 2]);
      peer.send(Done(1, sha([1, 2])));
      await peer.next<Ok>();
      expect(await File('${peer.incoming.path}/a.txt').exists(), isTrue);
    });

    test('more data than announced aborts the transfer and leaves nothing', () async {
      peer.send(const Put(1, name: 'a.txt', size: 3));
      await peer.next<Accept>();
      peer.sendFrame(1, [1, 2, 3]);
      peer.sendFrame(1, [4]);
      final f = await peer.next<Fail>();
      expect(f.reason, FailReason.io);
      await peer.settle();
      expect(peer.host.transfers.single.status, TransferStatus.failed);
      expect(peer.host.transfers.single.error, TransferError.protocol);
      expect(await peer.incoming.list().toList(), isEmpty);
    });

    test('done before all data arrived fails the transfer', () async {
      peer.send(const Put(1, name: 'a.txt', size: 10));
      await peer.next<Accept>();
      peer.sendFrame(1, [1, 2, 3]);
      peer.send(Done(1, sha([1, 2, 3])));
      expect((await peer.next<Fail>()).reason, FailReason.io);
      expect(await peer.incoming.list().toList(), isEmpty);
    });

    test('a wrong digest fails with hash and removes the part file', () async {
      peer.send(const Put(1, name: 'a.txt', size: 3));
      await peer.next<Accept>();
      peer.sendFrame(1, [1, 2, 3]);
      peer.send(Done(1, sha([9, 9, 9])));
      expect((await peer.next<Fail>()).reason, FailReason.hash);
      expect(await peer.incoming.list().toList(), isEmpty);
    });

    test('frames for unknown xids, short frames and oversized frames are ignored', () async {
      peer.sendFrame(99, [1, 2, 3]);
      peer.sendRawBinary(Uint8List(0));
      peer.sendRawBinary(Uint8List(2));
      peer.sendRawBinary(Uint8List(4 + 65537));
      peer.sendFrame(0, [1]);
      await peer.settle();
      expect(peer.host.transfers, isEmpty);
      // Still fully functional afterwards.
      peer.send(const Put(1, name: 'a.txt', size: 1));
      await peer.next<Accept>();
    });

    test('an absurd modification time does not stop the transfer from completing', () async {
      peer.send(const Put(1, name: 'a.txt', size: 1, mtime: 9007199254740991));
      await peer.next<Accept>();
      peer.sendFrame(1, [1]);
      peer.send(Done(1, sha([1])));
      await peer.next<Ok>();
      expect(await File('${peer.incoming.path}/a.txt').readAsBytes(), [1]);
      expect(peer.host.transfers.single.status, TransferStatus.completed);
    });

    test('garbage, unknown types and unknown fields are ignored', () async {
      peer.sendRawText('not json at all');
      peer.sendRawText('[1,2,3]');
      peer.sendRawText(jsonEncode({'t': 'launch_missiles', 'xid': 1}));
      peer.sendRawText(jsonEncode({'t': 'put', 'xid': 'seven', 'name': 'x', 'size': 1}));
      peer.sendRawText(jsonEncode({'t': 'put', 'xid': 1, 'name': 'x', 'size': -5}));
      peer.sendRawText(jsonEncode({'t': 'put', 'xid': 1, 'name': 'x', 'size': 1, 'surprise': {'nested': true}}));
      final a = await peer.next<Accept>();
      expect(a.xid, 1);
    });

    test('accept / ok / fail / cancel for transfers that do not exist are ignored', () async {
      peer.send(const Accept(5));
      peer.send(const Ok(5));
      peer.send(const Fail(5, FailReason.hash));
      peer.send(const Cancel(5));
      peer.send(const Reject(5, RejectReason.denied));
      peer.send(Done(5, sha([])));
      await peer.settle();
      expect(peer.host.transfers, isEmpty);
      expect(peer.received, isEmpty);
    });

    test('a get from a peer is denied when it uses a host-owned xid or an unsafe path', () async {
      peer.send(const Get(2, '/etc/hosts'));
      expect((await peer.next<Reject>()).xid, 2);
      peer.send(const Get(1, 'relative/path'));
      expect((await peer.next<Reject>()).reason, RejectReason.io);
      peer.send(Get(3, '${peer.tmp.path}/../../etc/passwd'));
      expect((await peer.next<Reject>()).reason, RejectReason.io);
    });

    test('flooding offers does not grow the history without bound', () async {
      for (var i = 0; i < 400; i++) {
        peer.send(Put(1 + 2 * i, name: '../x$i', size: 1));
      }
      await peer.settle();
      await peer.settle();
      expect(peer.host.transfers.length, lessThanOrEqualTo(300));
    });
  });

  group('viewer side', () {
    test('a malicious host cannot redirect a push with dest or a bad name', () async {
      final viewerPeer = await RawPeer.create(isHost: false);
      addTearDown(viewerPeer.dispose);
      final evil = await Directory('${viewerPeer.tmp.path}/evil_dest').create();
      viewerPeer.send(Put(2, name: 'safe.txt', size: 1, dest: evil.path));
      await viewerPeer.next<Accept>();
      viewerPeer.sendFrame(2, [1]);
      viewerPeer.send(Done(2, sha([1])));
      await viewerPeer.next<Ok>();
      expect(await File('${viewerPeer.incoming.path}/safe.txt').exists(), isTrue);
      expect(await evil.list().toList(), isEmpty);

      viewerPeer.send(const Put(4, name: '../../escape.txt', size: 1));
      expect((await viewerPeer.next<Reject>()).reason, RejectReason.denied);
    });

    test('a viewer never serves get requests', () async {
      final viewerPeer = await RawPeer.create(isHost: false);
      addTearDown(viewerPeer.dispose);
      viewerPeer.send(const Get(2, '/etc/hosts'));
      expect((await viewerPeer.next<Reject>()).reason, RejectReason.denied);
    });

    test('an unsolicited put reusing one of the viewer own xids is ignored', () async {
      final viewerPeer = await RawPeer.create(isHost: false);
      addTearDown(viewerPeer.dispose);
      viewerPeer.send(const Put(1, name: 'x', size: 1));
      await viewerPeer.settle();
      expect(viewerPeer.received, isEmpty);
    });
  });
}
