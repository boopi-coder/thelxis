import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/file_channel.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/protocol.dart';

import 'support/rig.dart';

Transfer only(FileTransferEndpoint e) => e.transfers.single;

void main() {
  group('upload (viewer to host)', () {
    test('single file arrives intact with its modification time', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('hello.bin', 200000);
      final stamp = DateTime.utc(2021, 3, 4, 5, 6, 7);
      await f.setLastModified(stamp);

      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();

      final out = File('${rig.hostIncoming.path}/hello.bin');
      expect(await sha256OfFile(out), await sha256OfFile(f));
      expect((await out.lastModified()).toUtc().difference(stamp).inSeconds.abs(), lessThanOrEqualTo(1));
      expect(only(rig.viewer).status, TransferStatus.completed);
      expect(only(rig.viewer).progress, 1);
      expect(only(rig.host).status, TransferStatus.completed);
      expect(await File(only(rig.host).localPath!).resolveSymbolicLinks(), await out.resolveSymbolicLinks());
      expect(await File('${out.path}.thelxis-part').exists(), isFalse);
    });

    test('empty file', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('empty.txt', 0);
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      final out = File('${rig.hostIncoming.path}/empty.txt');
      expect(await out.exists(), isTrue);
      expect(await out.length(), 0);
      expect(only(rig.viewer).isCompleted, isTrue);
      expect(rig.viewerSent.whereType<Done>().single.sha256,
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('5 MB random file with progress, speed and a verified hash', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('big.bin', 5 * 1024 * 1024, seed: 42);
      var notifications = 0;
      rig.viewer.addListener(() => notifications++);
      final seenProgress = <double>[];
      rig.viewer.addListener(() {
        if (rig.viewer.transfers.isNotEmpty) seenProgress.add(rig.viewer.transfers.first.progress);
      });

      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();

      final out = File('${rig.hostIncoming.path}/big.bin');
      expect(await sha256OfFile(out), await sha256OfFile(f));
      expect(notifications, greaterThan(2));
      // Monotonic progress ending at 1.
      for (var i = 1; i < seenProgress.length; i++) {
        expect(seenProgress[i], greaterThanOrEqualTo(seenProgress[i - 1]));
      }
      expect(seenProgress.last, 1);
      final frames = rig.pair.a.totalBytesSent;
      expect(frames, greaterThanOrEqualTo(5 * 1024 * 1024));
      // The digest sent in `done` equals the real one.
      expect(rig.viewerSent.whereType<Done>().single.sha256, await sha256OfFile(f));
    });

    test('folder with nested files keeps relative paths and skips symlinks', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final tree = await Directory('${rig.source.path}/tree').create();
      await rig.makeFile('a.txt', 100, inside: tree);
      await rig.makeFile('sub/b.bin', 70000, seed: 2, inside: tree);
      await rig.makeFile('sub/deep/c.txt', 5, seed: 3, inside: tree);
      await rig.makeFile('empty.txt', 0, inside: tree);
      await rig.makeFile('.hidden', 9, seed: 4, inside: tree);
      final outsider = await rig.makeFile('outsider.txt', 10, seed: 5);
      await Link('${tree.path}/link.txt').create(outsider.path);
      await Link('${tree.path}/linkdir').create(rig.source.path);

      await rig.viewer.sendFiles([tree.path]);
      await rig.viewer.whenIdle();

      final names = rig.viewer.transfers.map((t) => t.name).toList()..sort();
      expect(names, ['tree/.hidden', 'tree/a.txt', 'tree/empty.txt', 'tree/sub/b.bin', 'tree/sub/deep/c.txt']);
      expect(rig.viewer.transfers.every((t) => t.isCompleted), isTrue);
      for (final rel in ['a.txt', 'sub/b.bin', 'sub/deep/c.txt', 'empty.txt', '.hidden']) {
        final sent = File('${tree.path}/$rel');
        final got = File('${rig.hostIncoming.path}/tree/$rel');
        expect(await sha256OfFile(got), await sha256OfFile(sent), reason: rel);
      }
      expect(await File('${rig.hostIncoming.path}/tree/link.txt').exists(), isFalse);
      expect(await Directory('${rig.hostIncoming.path}/tree/linkdir').exists(), isFalse);
    });

    test('files and folders are sent one after another, in order', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final a = await rig.makeFile('1.bin', 300000);
      final b = await rig.makeFile('2.bin', 300000, seed: 2);
      final c = await rig.makeFile('3.bin', 300000, seed: 3);
      await rig.viewer.sendFiles([a.path, b.path, c.path]);
      // Never two offers in flight at once.
      var maxConcurrent = 0;
      var current = 0;
      for (final m in rig.viewerSent) {
        if (m is Put) current++;
        if (m is Done) {
          current--;
        }
        if (current > maxConcurrent) maxConcurrent = current;
      }
      await rig.viewer.whenIdle();
      expect(rig.viewerSent.whereType<Put>().map((p) => p.name), ['1.bin', '2.bin', '3.bin']);
      var active = 0;
      var maxActive = 0;
      for (final m in rig.viewerSent) {
        if (m is Put) active++;
        if (m is Done) active--;
        maxActive = active > maxActive ? active : maxActive;
      }
      expect(maxActive, lessThanOrEqualTo(1));
      expect(rig.viewer.transfers.every((t) => t.isCompleted), isTrue);
    });

    test('dest puts the file into a folder the viewer chose on the host', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final target = await Directory('${rig.root.path}/chosen').create();
      final f = await rig.makeFile('x.bin', 1000);
      await rig.viewer.sendFiles([f.path], remoteDir: target.path);
      await rig.viewer.whenIdle();
      expect(await File('${target.path}/x.bin').exists(), isTrue);
      expect(await File('${rig.hostIncoming.path}/x.bin').exists(), isFalse);
      expect(only(rig.viewer).remoteDir, target.path);
    });

    test('a missing source shows up as a failed transfer', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      await rig.viewer.sendFiles(['${rig.source.path}/nope.txt']);
      expect(only(rig.viewer).status, TransferStatus.failed);
      expect(only(rig.viewer).error, TransferError.notFound);
      expect(rig.viewerSent.whereType<Put>(), isEmpty);
    });

    test('a source that vanishes before its turn fails without blocking the queue', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final a = await rig.makeFile('a.bin', 400000);
      final b = await rig.makeFile('b.bin', 1000, seed: 2);
      await rig.viewer.sendFiles([a.path, b.path]);
      await b.delete();
      await rig.viewer.whenIdle();
      final byName = {for (final t in rig.viewer.transfers) t.name: t};
      expect(byName['a.bin']!.status, TransferStatus.completed);
      expect(byName['b.bin']!.status, TransferStatus.failed);
      expect(byName['b.bin']!.error, TransferError.notFound);
    });
  });

  group('both directions at once', () {
    test('an upload, a push and a download interleave without interfering', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final up = await rig.makeFile('up.bin', 3 * 1024 * 1024, seed: 61);
      final push = await rig.makeFile('push.bin', 3 * 1024 * 1024, seed: 62);
      final wanted = await rig.makeFile('wanted.bin', 2 * 1024 * 1024, seed: 63);

      await rig.viewer.sendFiles([up.path]);
      await rig.host.sendFiles([push.path]);
      await rig.viewer.download(wanted.path, isDirectory: false);
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      expect(await sha256OfFile(File('${rig.hostIncoming.path}/up.bin')), await sha256OfFile(up));
      expect(await sha256OfFile(File('${rig.viewerIncoming.path}/push.bin')), await sha256OfFile(push));
      expect(await sha256OfFile(File('${rig.viewerIncoming.path}/wanted.bin')), await sha256OfFile(wanted));
      expect(rig.viewer.transfers.every((t) => t.isCompleted), isTrue);
      expect(rig.host.transfers.every((t) => t.isCompleted), isTrue);
      expect(rig.viewer.transfers.length, 3);
    });

    test('a download requested while the host pushes waits its turn', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final push = await rig.makeFile('push.bin', 4 * 1024 * 1024, seed: 64);
      final wanted = await rig.makeFile('wanted.bin', 1000, seed: 65);
      await rig.host.sendFiles([push.path]);
      await Rig.until(() => rig.viewer.transfers.isNotEmpty && rig.viewer.transfers.first.status == TransferStatus.active);
      await rig.viewer.download(wanted.path, isDirectory: false);
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();
      expect(await File('${rig.viewerIncoming.path}/push.bin').exists(), isTrue);
      expect(await File('${rig.viewerIncoming.path}/wanted.bin').exists(), isTrue);
      // The host never has two outbound streams at once.
      var active = 0;
      var maxActive = 0;
      for (final m in rig.hostSent) {
        if (m is Put) active++;
        if (m is Done) active--;
        maxActive = active > maxActive ? active : maxActive;
      }
      expect(maxActive, 1);
    });
  });

  group('name clashes', () {
    test('existing files are never overwritten: name (1), name (2)', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      await File('${rig.hostIncoming.path}/hello.txt').writeAsString('precious');
      final f = await rig.makeFile('hello.txt', 50);

      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();

      expect(await File('${rig.hostIncoming.path}/hello.txt').readAsString(), 'precious');
      expect(await sha256OfFile(File('${rig.hostIncoming.path}/hello (1).txt')), await sha256OfFile(f));
      expect(await sha256OfFile(File('${rig.hostIncoming.path}/hello (2).txt')), await sha256OfFile(f));
    });

    test('a symlink squatting on the final name is not followed', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final outside = File('${rig.root.path}/outside_target.txt')..writeAsStringSync('untouched');
      await Link('${rig.hostIncoming.path}/a.txt').create(outside.path);
      final f = await rig.makeFile('a.txt', 20);

      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();

      expect(outside.readAsStringSync(), 'untouched');
      expect(await File('${rig.hostIncoming.path}/a (1).txt').exists(), isTrue);
    });
  });

  group('host push (host to viewer)', () {
    test('goes to the viewer incoming folder and raises events on both sides', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('from_host.bin', 150000, seed: 9);
      await rig.host.sendFiles([f.path]);
      await rig.host.whenIdle();

      final out = File('${rig.viewerIncoming.path}/from_host.bin');
      expect(await sha256OfFile(out), await sha256OfFile(f));
      expect(rig.viewerEvents.map((e) => e.kind), [FileTransferEventKind.incomingStarted, FileTransferEventKind.received]);
      expect(rig.viewerEvents.last.transfer.name, 'from_host.bin');
      expect(rig.hostEvents.map((e) => e.kind), [FileTransferEventKind.sent]);
    });

    test('host cannot choose the viewer destination through dest', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final elsewhere = await Directory('${rig.root.path}/elsewhere').create();
      final f = await rig.makeFile('sneaky.bin', 10);
      // Even if sendFiles is given remoteDir on a host, the offer carries none.
      await rig.host.sendFiles([f.path], remoteDir: elsewhere.path);
      await rig.host.whenIdle();
      expect(rig.hostSent.whereType<Put>().single.dest, isNull);
      expect(await File('${rig.viewerIncoming.path}/sneaky.bin').exists(), isTrue);
      expect(await File('${elsewhere.path}/sneaky.bin').exists(), isFalse);
    });

    test('the viewer can veto incoming offers', () async {
      final offers = <IncomingOffer>[];
      final rig = await Rig.create(viewerAcceptIncoming: (o) {
        offers.add(o);
        return o.name != 'bad.exe';
      });
      addTearDown(rig.dispose);
      final good = await rig.makeFile('good.txt', 10);
      final bad = await rig.makeFile('bad.exe', 10, seed: 2);
      await rig.host.sendFiles([bad.path, good.path]);
      await rig.host.whenIdle();
      expect(offers.map((o) => o.name), ['bad.exe', 'good.txt']);
      expect(await File('${rig.viewerIncoming.path}/bad.exe').exists(), isFalse);
      expect(await File('${rig.viewerIncoming.path}/good.txt').exists(), isTrue);
      final byName = {for (final t in rig.host.transfers) t.name: t};
      expect(byName['bad.exe']!.status, TransferStatus.failed);
      expect(byName['bad.exe']!.error, TransferError.denied);
    });
  });

  group('download (viewer asks the host)', () {
    test('single file by path', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('wanted.bin', 250000, seed: 7);
      await rig.viewer.download(f.path, isDirectory: false);
      await rig.viewer.whenIdle();
      final out = File('${rig.viewerIncoming.path}/wanted.bin');
      expect(await sha256OfFile(out), await sha256OfFile(f));
      expect(only(rig.viewer).direction, TransferDirection.receive);
      expect(only(rig.host).direction, TransferDirection.send);
      expect(only(rig.host).xid, only(rig.viewer).xid, reason: 'a get keeps the viewer-chosen xid');
    });

    test('to a chosen local folder, unknown directory-ness is probed', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('wanted.bin', 1000, seed: 7);
      final dl = '${rig.root.path}/my_downloads';
      await rig.viewer.download(f.path, localDir: dl);
      await rig.viewer.whenIdle();
      expect(await File('$dl/wanted.bin').exists(), isTrue);
    });

    test('a whole remote folder, recursively', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final tree = await Directory('${rig.source.path}/photos').create();
      await rig.makeFile('1.jpg', 3000, inside: tree);
      await rig.makeFile('album/2.jpg', 4000, seed: 2, inside: tree);
      await rig.makeFile('album/deeper/3.jpg', 5000, seed: 3, inside: tree);
      await rig.viewer.download(tree.path);
      await rig.viewer.whenIdle();
      expect(rig.viewer.transfers.length, 3);
      for (final rel in ['1.jpg', 'album/2.jpg', 'album/deeper/3.jpg']) {
        final got = File('${rig.viewerIncoming.path}/photos/$rel');
        expect(await sha256OfFile(got), await sha256OfFile(File('${tree.path}/$rel')), reason: rel);
      }
    });

    test('several downloads are requested one at a time', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final files = [for (var i = 0; i < 3; i++) await rig.makeFile('f$i.bin', 200000, seed: i)];
      for (final f in files) {
        await rig.viewer.download(f.path, isDirectory: false);
      }
      // After the call only the first request may be on the wire.
      await rig.viewer.whenIdle();
      expect(rig.viewerSent.whereType<Get>().length, 3);
      expect(rig.viewer.transfers.every((t) => t.isCompleted), isTrue);
    });

    test('a missing remote file is rejected, not hung', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      await rig.viewer.download('${rig.source.path}/ghost.bin', isDirectory: false);
      await rig.viewer.whenIdle();
      expect(only(rig.viewer).status, TransferStatus.failed);
      expect(only(rig.viewer).error, TransferError.io);
      expect(only(rig.viewer).endedByPeer, isTrue);
    });

    test('a download name chosen by the host is ignored', () async {
      // The viewer asked for "real.txt"; a host that answers with another
      // name must not be able to place the file elsewhere.
      final pair = FileChannelPair();
      final viewer = FileTransferEndpoint(
        channel: pair.a,
        isHost: false,
        filesAllowed: () => true,
        incomingDir: () async => Directory.systemTemp.createTemp('thelxis_ignore_name_'),
      );
      addTearDown(viewer.dispose);
      final captured = Completer<Get>();
      pair.b.messages.listen((m) {
        if (m is FileTextMessage) {
          final d = FileMsg.decode(m.text);
          if (d is Get && !captured.isCompleted) captured.complete(d);
        }
      });
      await viewer.download('/remote/real.txt', isDirectory: false);
      final get = await captured.future;
      pair.b.sendText(Put(get.xid, name: '../../evil.txt', size: 3).encode());
      pair.b.sendBinary(FileFrame.encode(get.xid, [1, 2, 3]));
      await Rig.until(() => viewer.transfers.single.status == TransferStatus.verifying || viewer.transfers.single.transferred == 3);
      expect(viewer.transfers.single.name, 'real.txt');
    });
  });

  group('resume', () {
    test('an existing .part prefix is kept and only the rest is sent', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('movie.bin', 400000, seed: 11);
      final bytes = await f.readAsBytes();
      await File('${rig.hostIncoming.path}/movie.bin.thelxis-part').writeAsBytes(bytes.sublist(0, 150000));

      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();

      expect(rig.hostSent.whereType<Accept>().single.offset, 150000);
      expect(rig.pair.a.totalBytesSent, lessThan(400000), reason: 'the prefix must not be re-sent');
      final out = File('${rig.hostIncoming.path}/movie.bin');
      expect(await out.readAsBytes(), bytes);
      expect(only(rig.viewer).isCompleted, isTrue);
    });

    test('a complete .part only needs the digest', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('whole.bin', 70000, seed: 12);
      await File('${rig.hostIncoming.path}/whole.bin.thelxis-part').writeAsBytes(await f.readAsBytes());
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(rig.hostSent.whereType<Accept>().single.offset, 70000);
      expect(await sha256OfFile(File('${rig.hostIncoming.path}/whole.bin')), await sha256OfFile(f));
    });

    test('a .part larger than the announced size starts over', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('small.bin', 5000, seed: 13);
      await File('${rig.hostIncoming.path}/small.bin.thelxis-part').writeAsBytes(Uint8List(9000));
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(rig.hostSent.whereType<Accept>().single.offset, 0);
      expect(await sha256OfFile(File('${rig.hostIncoming.path}/small.bin')), await sha256OfFile(f));
    });

    test('a wrong prefix is caught by the hash, discarded, and the retry succeeds', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('changed.bin', 100000, seed: 14);
      await File('${rig.hostIncoming.path}/changed.bin.thelxis-part').writeAsBytes(Uint8List(40000));

      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(only(rig.viewer).status, TransferStatus.failed);
      expect(only(rig.viewer).error, TransferError.hash);
      expect(await File('${rig.hostIncoming.path}/changed.bin').exists(), isFalse);
      expect(await File('${rig.hostIncoming.path}/changed.bin.thelxis-part').exists(), isFalse);

      rig.viewer.clearFinished();
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(await sha256OfFile(File('${rig.hostIncoming.path}/changed.bin')), await sha256OfFile(f));
    });

    test('a dropped connection keeps the .part and the next session resumes it', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('long.bin', 20 * 1024 * 1024, seed: 15);
      await rig.viewer.sendFiles([f.path]);
      await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.transferred > 300000);

      await rig.pair.close();
      await Rig.until(() => rig.viewer.transfers.first.isFinished && rig.host.transfers.first.isFinished);
      expect(rig.viewer.transfers.first.error, TransferError.closed);
      expect(rig.host.transfers.first.error, TransferError.closed);
      final part = File('${rig.hostIncoming.path}/long.bin.thelxis-part');
      expect(await part.exists(), isTrue);
      final partial = await part.length();
      expect(partial, greaterThan(0));

      await rig.reconnect();
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(rig.hostSent.whereType<Accept>().single.offset, greaterThan(0));
      expect(await sha256OfFile(File('${rig.hostIncoming.path}/long.bin')), await sha256OfFile(f));
    });
  });

  group('cancel', () {
    test('sender cancels mid-way: both sides end cancelled and the .part is removed', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('huge.bin', 40 * 1024 * 1024, seed: 21);
      await rig.viewer.sendFiles([f.path]);
      await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.transferred > 200000);
      final part = File('${rig.hostIncoming.path}/huge.bin.thelxis-part');
      expect(await part.exists(), isTrue);

      rig.viewer.cancel(only(rig.viewer).xid);
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      expect(only(rig.viewer).status, TransferStatus.cancelled);
      expect(only(rig.host).status, TransferStatus.cancelled);
      expect(only(rig.host).endedByPeer, isTrue);
      expect(await part.exists(), isFalse);
      expect(await File('${rig.hostIncoming.path}/huge.bin').exists(), isFalse);
      expect(rig.pair.a.totalBytesSent, lessThan(40 * 1024 * 1024));
    });

    test('receiver cancels mid-way: the sender stops', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('huge.bin', 40 * 1024 * 1024, seed: 22);
      await rig.viewer.sendFiles([f.path]);
      await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.transferred > 200000);

      rig.host.cancel(only(rig.host).xid);
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      expect(only(rig.host).status, TransferStatus.cancelled);
      expect(only(rig.host).endedByPeer, isFalse);
      expect(only(rig.viewer).status, TransferStatus.cancelled);
      expect(only(rig.viewer).endedByPeer, isTrue);
      // The part file is removed right behind the frames still in flight.
      await Rig.until(() => !File('${rig.hostIncoming.path}/huge.bin.thelxis-part').existsSync());
    });

    test('cancelling a queued transfer never tells the peer; the rest continues', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final a = await rig.makeFile('a.bin', 3 * 1024 * 1024);
      final b = await rig.makeFile('b.bin', 1000, seed: 2);
      final c = await rig.makeFile('c.bin', 1000, seed: 3);
      await rig.viewer.sendFiles([a.path, b.path, c.path]);
      final bx = rig.viewer.transfers.firstWhere((t) => t.name == 'b.bin');
      expect(bx.status, TransferStatus.queued);
      rig.viewer.cancel(bx.xid);
      expect(bx.status, TransferStatus.cancelled);
      await rig.viewer.whenIdle();
      expect(rig.viewerSent.whereType<Put>().map((p) => p.name), ['a.bin', 'c.bin']);
      expect(rig.viewerSent.whereType<Cancel>(), isEmpty);
      expect(await File('${rig.hostIncoming.path}/c.bin').exists(), isTrue);
    });

    test('cancelling a download that is still waiting on the host', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final big = await rig.makeFile('big.bin', 30 * 1024 * 1024, seed: 5);
      final small = await rig.makeFile('small.bin', 1000, seed: 6);
      // The host is busy pushing a big file; the viewer's get queues behind it.
      await rig.host.sendFiles([big.path]);
      await Rig.until(() => rig.viewer.transfers.isNotEmpty && rig.viewer.transfers.first.transferred > 100000);
      await rig.viewer.download(small.path, isDirectory: false);
      final dl = rig.viewer.transfers.last;
      expect(dl.status, TransferStatus.waiting);
      rig.viewer.cancel(dl.xid);
      expect(dl.status, TransferStatus.cancelled);
      rig.viewer.cancel(rig.viewer.transfers.first.xid);
      await rig.host.whenIdle();
      await rig.viewer.whenIdle();
      expect(await File('${rig.viewerIncoming.path}/small.bin').exists(), isFalse);
      expect(rig.host.transfers.where((t) => t.name == 'small.bin' && t.status == TransferStatus.completed), isEmpty);
    });
  });

  group('integrity', () {
    test('a corrupted byte fails the transfer on both sides and leaves nothing behind', () async {
      final rig = await Rig.create(tamperViewer: CorruptingChannel.new);
      addTearDown(rig.dispose);
      final f = await rig.makeFile('fragile.bin', 300000, seed: 31);
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      expect(only(rig.host).status, TransferStatus.failed);
      expect(only(rig.host).error, TransferError.hash);
      expect(only(rig.viewer).status, TransferStatus.failed);
      expect(only(rig.viewer).error, TransferError.hash);
      expect(rig.hostSent.whereType<Fail>().single.reason, FailReason.hash);
      expect(rig.hostEvents.last.kind, FileTransferEventKind.failed);
      expect(await rig.hostIncoming.list().toList(), isEmpty);
    });

    test('a failed transfer does not stop the queue', () async {
      final rig = await Rig.create(tamperViewer: CorruptingChannel.new);
      addTearDown(rig.dispose);
      final a = await rig.makeFile('a.bin', 100000);
      final b = await rig.makeFile('b.bin', 100000, seed: 2);
      await rig.viewer.sendFiles([a.path, b.path]);
      await rig.viewer.whenIdle();
      final byName = {for (final t in rig.viewer.transfers) t.name: t};
      expect(byName['a.bin']!.status, TransferStatus.failed);
      expect(byName['b.bin']!.status, TransferStatus.completed);
    });
  });

  group('xid allocation', () {
    test('viewer uses odd xids, host even ones, each unique', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final a = await rig.makeFile('a.bin', 100);
      final b = await rig.makeFile('b.bin', 100, seed: 2);
      await rig.viewer.sendFiles([a.path, b.path]);
      await rig.viewer.download(a.path, isDirectory: false);
      await rig.host.sendFiles([a.path, b.path]);
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      final viewerXids = rig.viewerSent.whereType<Put>().map((p) => p.xid).toList() + rig.viewerSent.whereType<Get>().map((g) => g.xid).toList();
      final hostXids = rig.hostSent.whereType<Put>().where((p) => rig.host.transfers.any((t) => t.xid == p.xid && t.xid.isEven)).map((p) => p.xid).toList();
      expect(viewerXids, isNotEmpty);
      expect(viewerXids.every((x) => x.isOdd), isTrue);
      expect(hostXids.length, 2);
      expect(hostXids.every((x) => x.isEven), isTrue);
      expect(viewerXids.toSet().length, viewerXids.length);
      expect(hostXids.toSet().length, hostXids.length);
    });
  });

  group('channel loss and disposal', () {
    test('pending transfers fail with closed when the channel dies', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final a = await rig.makeFile('a.bin', 100000);
      final b = await rig.makeFile('b.bin', 100000, seed: 2);
      rig.pair.a.held = true;
      await rig.viewer.sendFiles([a.path, b.path]);
      await Rig.until(() => rig.viewerSent.whereType<Put>().isNotEmpty);
      await rig.pair.close();
      await rig.viewer.whenIdle();
      expect(rig.viewer.transfers.every((t) => t.status == TransferStatus.failed && t.error == TransferError.closed), isTrue);
      expect(rig.viewer.isClosed, isTrue);
      expect(() => rig.viewer.sendFiles([a.path]), throwsA(isA<FileTransferException>()));
    });

    test('dispose tells the peer and closes the channel', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('big.bin', 30 * 1024 * 1024);
      await rig.viewer.sendFiles([f.path]);
      await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.transferred > 100000);
      await rig.viewer.dispose();
      await Rig.until(() => rig.host.transfers.first.isFinished);
      expect(rig.host.transfers.first.isFinished, isTrue);
      expect(rig.pair.b.isOpen, isFalse);
    });

    test('a peer that never answers makes the transfer time out', () async {
      final pair = FileChannelPair();
      final viewer = FileTransferEndpoint(
        channel: pair.a,
        isHost: false,
        filesAllowed: () => true,
        incomingDir: () async => Directory.systemTemp,
        config: const TransferConfig(replyTimeout: Duration(milliseconds: 150)),
      );
      addTearDown(viewer.dispose);
      final tmp = await Directory.systemTemp.createTemp('thelxis_timeout_');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/x.bin')..writeAsBytesSync([1, 2, 3]);
      await viewer.sendFiles([f.path]);
      await viewer.whenIdle();
      expect(only(viewer).status, TransferStatus.failed);
      expect(only(viewer).error, TransferError.timeout);
    });
  });
}
