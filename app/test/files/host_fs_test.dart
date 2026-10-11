import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/host_fs.dart';
import 'package:thelxis/files/protocol.dart';

import 'support/rig.dart';

void main() {
  late Directory tmp;
  late bool allowed;
  late HostFs fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('thelxis_hostfs_');
    allowed = true;
    fs = HostFs(
      filesAllowed: () => allowed,
      roots: () async => [FsRoot(name: 'Home', path: tmp.path, kind: 'home')],
      pageSize: 10,
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<FileMsg?> list(String path, {int offset = 0, int rid = 1}) =>
      fs.handle(FsList(rid, path, offset: offset));

  group('permission gate', () {
    test('everything is denied while files are not allowed', () async {
      allowed = false;
      expect(await fs.handle(const FsRoots(1)), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.denied));
      expect(await list(tmp.path), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.denied));
      await expectLater(
        fs.resolveFile('${tmp.path}/x'),
        throwsA(isA<HostFsException>().having((e) => e.code, 'code', FsErrCode.denied)),
      );
    });

    test('the callback is re-evaluated on every request', () async {
      expect(await fs.handle(const FsRoots(1)), isA<FsRootsReply>());
      allowed = false;
      expect(await fs.handle(const FsRoots(2)), isA<FsErr>());
      allowed = true;
      expect(await fs.handle(const FsRoots(3)), isA<FsRootsReply>());
    });

    test('non-browsing messages are not handled', () async {
      expect(await fs.handle(const Cancel(1)), isNull);
    });
  });

  group('fs_roots', () {
    test('returns what the provider found', () async {
      final r = await fs.handle(const FsRoots(7)) as FsRootsReply;
      expect(r.rid, 7);
      expect(r.items.single, FsRoot(name: 'Home', path: tmp.path, kind: 'home'));
    });

    test('a failing provider becomes an io error, not a crash', () async {
      final broken = HostFs(filesAllowed: () => true, roots: () async => throw StateError('boom'));
      expect(await broken.handle(const FsRoots(1)), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.io));
    });
  });

  group('fs_list', () {
    test('directories first, then files, case-insensitive; hidden flagged; sizes and times', () async {
      await Directory('${tmp.path}/Zeta').create();
      await Directory('${tmp.path}/alpha').create();
      await File('${tmp.path}/b.txt').writeAsString('hello');
      await File('${tmp.path}/A.txt').writeAsString('hi');
      await File('${tmp.path}/.secret').writeAsString('x');
      await Directory('${tmp.path}/.config').create();

      final r = await list(tmp.path, rid: 5) as FsListReply;
      expect(r.rid, 5);
      expect(r.path, tmp.path);
      expect(r.total, 6);
      expect(r.items.map((e) => e.name), ['.config', 'alpha', 'Zeta', '.secret', 'A.txt', 'b.txt']);
      expect(r.items.map((e) => e.isDir), [true, true, true, false, false, false]);
      expect(r.items.where((e) => e.hidden).map((e) => e.name), ['.config', '.secret']);
      final b = r.items.firstWhere((e) => e.name == 'b.txt');
      expect(b.size, 5);
      expect(b.mtime, closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000, 30));
      expect(r.items.firstWhere((e) => e.name == 'alpha').size, 0);
    });

    test('an empty directory', () async {
      final r = await list(tmp.path) as FsListReply;
      expect(r.items, isEmpty);
      expect(r.total, 0);
    });

    test('symlinks show the type of their target and broken links are omitted', () async {
      await Directory('${tmp.path}/real').create();
      await File('${tmp.path}/f.txt').writeAsString('x');
      await Link('${tmp.path}/to_dir').create('${tmp.path}/real');
      await Link('${tmp.path}/to_file').create('${tmp.path}/f.txt');
      await Link('${tmp.path}/broken').create('${tmp.path}/nowhere');
      final r = await list(tmp.path) as FsListReply;
      final byName = {for (final e in r.items) e.name: e};
      expect(byName['to_dir']!.isDir, isTrue);
      expect(byName['to_file']!.isDir, isFalse);
      expect(byName['to_file']!.size, 1);
      expect(byName.containsKey('broken'), isFalse);
    });

    test('unicode names survive', () async {
      await File('${tmp.path}/Отчёт.pdf').writeAsString('x');
      final r = await list(tmp.path) as FsListReply;
      expect(r.items.single.name, 'Отчёт.pdf');
    });

    test('a missing directory is not_found', () async {
      expect(await list('${tmp.path}/nope'), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.notFound));
    });

    test('a file is not a directory', () async {
      await File('${tmp.path}/f.txt').writeAsString('x');
      expect(await list('${tmp.path}/f.txt'), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.notFound));
    });

    test('relative, traversing and UNC paths are refused', () async {
      for (final p in ['relative', '.', '${tmp.path}/../x', '//server/share', '/a/./b']) {
        expect(await list(p), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.io), reason: p);
      }
    });

    test('an unreadable directory is denied', () async {
      if (Platform.isWindows) return;
      final locked = await Directory('${tmp.path}/locked').create();
      await Process.run('chmod', ['000', locked.path]);
      addTearDown(() => Process.run('chmod', ['755', locked.path]));
      if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') return; // root ignores modes
      expect(await list(locked.path), isA<FsErr>().having((e) => e.code, 'code', FsErrCode.denied));
    });

    test('big directories come in pages that tile the whole listing', () async {
      for (var i = 0; i < 35; i++) {
        await File('${tmp.path}/f${i.toString().padLeft(2, '0')}.txt').writeAsString('$i');
      }
      final seen = <String>[];
      var offset = 0;
      var pages = 0;
      while (true) {
        final r = await list(tmp.path, offset: offset) as FsListReply;
        pages++;
        expect(r.items.length, lessThanOrEqualTo(10));
        expect(r.offset, offset);
        expect(r.total, 35);
        seen.addAll(r.items.map((e) => e.name));
        offset += r.items.length;
        if (offset >= r.total!) break;
      }
      expect(pages, 4);
      expect(seen.length, 35);
      expect(seen.toSet().length, 35);
      expect(seen, [...seen]..sort());
    });

    test('offset beyond the end yields an empty page', () async {
      await File('${tmp.path}/a').writeAsString('x');
      final r = await list(tmp.path, offset: 99) as FsListReply;
      expect(r.items, isEmpty);
      expect(r.total, 1);
    });

    test('a reply never exceeds the SCTP message budget, even with huge names', () async {
      final wide = HostFs(filesAllowed: () => true, roots: () async => const [], pageSize: 1000);
      final longName = 'ж' * 110; // 220 bytes of UTF-8
      for (var i = 0; i < 900; i++) {
        await File('${tmp.path}/$longName$i').writeAsString('x');
      }
      var offset = 0;
      var pages = 0;
      var total = 0;
      while (true) {
        final r = await wide.handle(FsList(1, tmp.path, offset: offset)) as FsListReply;
        expect(utf8.encode(r.encode()).length, lessThan(256 * 1024));
        pages++;
        total += r.items.length;
        offset += r.items.length;
        if (offset >= r.total!) break;
      }
      expect(total, 900);
      expect(pages, greaterThan(1), reason: 'the byte budget, not the item limit, must have split it');
    });

    test('limit from the request caps the page', () async {
      for (var i = 0; i < 8; i++) {
        await File('${tmp.path}/$i').writeAsString('x');
      }
      final r = await fs.handle(FsList(1, tmp.path, limit: 3)) as FsListReply;
      expect(r.items.length, 3);
      expect(r.total, 8);
    });
  });

  group('resolveFile (get)', () {
    test('a regular file', () async {
      await File('${tmp.path}/a.bin').writeAsBytes([1, 2, 3]);
      final f = await fs.resolveFile('${tmp.path}/a.bin');
      expect(f.size, 3);
      expect(f.name, 'a.bin');
    });

    test('directories, missing files and bad paths are refused', () async {
      await Directory('${tmp.path}/d').create();
      await expectLater(fs.resolveFile('${tmp.path}/d'), throwsA(isA<HostFsException>()));
      await expectLater(
        fs.resolveFile('${tmp.path}/ghost'),
        throwsA(isA<HostFsException>().having((e) => e.code, 'code', FsErrCode.notFound)),
      );
      await expectLater(fs.resolveFile('relative/x'), throwsA(isA<HostFsException>()));
      await expectLater(fs.resolveFile('${tmp.path}/../etc/passwd'), throwsA(isA<HostFsException>()));
    });
  });

  group('remote browse through two endpoints', () {
    test('viewer lists roots and folders; errors map to typed exceptions', () async {
      final tmp2 = await Directory.systemTemp.createTemp('thelxis_browse_');
      final rig = await Rig.create(hostRoots: () async => [FsRoot(name: 'Home', path: tmp2.path, kind: 'home')]);
      addTearDown(() async {
        await rig.dispose();
        await tmp2.delete(recursive: true);
      });
      await Directory('${tmp2.path}/Docs').create();
      await File('${tmp2.path}/Docs/a.pdf').writeAsBytes([1, 2, 3]);

      final roots = await rig.viewer.remote.roots();
      expect(roots.single.path, tmp2.path);

      final entries = await rig.viewer.remote.list(tmp2.path);
      expect(entries.single.name, 'Docs');
      expect(entries.single.isDir, isTrue);
      final docs = await rig.viewer.remote.list('${tmp2.path}/Docs');
      expect(docs.single.name, 'a.pdf');
      expect(docs.single.size, 3);

      await expectLater(
        rig.viewer.remote.list('${tmp2.path}/missing'),
        throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.notFound)),
      );
    });

    test('all pages of a big folder are stitched together', () async {
      final tmp2 = await Directory.systemTemp.createTemp('thelxis_browse_');
      final rig = await Rig.create();
      addTearDown(() async {
        await rig.dispose();
        await tmp2.delete(recursive: true);
      });
      for (var i = 0; i < 2500; i++) {
        await File('${tmp2.path}/file_$i.txt').writeAsBytes([1]);
      }
      final entries = await rig.viewer.remote.list(tmp2.path);
      expect(entries.length, 2500);
      expect(entries.map((e) => e.name).toSet().length, 2500);
    });

    test('the host cannot browse the viewer', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      expect(rig.host.remote.list('/'), throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.unsupported)));
    });

    test('a viewer that asks the viewer side to browse gets denied', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      // The host sends fs_list to the viewer; the viewer endpoint must refuse.
      rig.pair.b.sendText(const FsList(77, '/').encode());
      await Rig.until(() => rig.viewerSent.whereType<FsErr>().isNotEmpty);
      expect(rig.viewerSent.whereType<FsErr>().single.code, FsErrCode.denied);
    });
  });
}
