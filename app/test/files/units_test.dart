import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/hashing.dart';
import 'package:thelxis/files/local_files.dart';
import 'package:thelxis/files/remote_path.dart';
import 'package:thelxis/files/transfer.dart';

void main() {
  group('SpeedMeter', () {
    test('first window sets the speed directly', () {
      final m = SpeedMeter()..start(Duration.zero);
      m.add(500000, const Duration(milliseconds: 100));
      expect(m.bytesPerSecond, 0, reason: 'window not complete yet');
      m.add(500000, const Duration(milliseconds: 300));
      expect(m.bytesPerSecond, closeTo(1000000 / 0.3, 1));
    });

    test('later windows are smoothed', () {
      final m = SpeedMeter(alpha: 0.5);
      m.add(1000, Duration.zero);
      m.add(0, const Duration(seconds: 1)); // 1000 B/s
      expect(m.bytesPerSecond, closeTo(1000, 1));
      m.add(3000, const Duration(seconds: 2)); // instant 3000 -> 2000
      expect(m.bytesPerSecond, closeTo(2000, 1));
    });

    test('eta follows the speed and is unknown at speed zero', () {
      final m = SpeedMeter();
      expect(m.eta(1000), isNull);
      m.add(1000, Duration.zero);
      m.add(1000, const Duration(seconds: 1));
      expect(m.eta(4000), const Duration(seconds: 2)); // 2000 B/s
      expect(m.eta(0), Duration.zero);
    });

    test('reset forgets everything', () {
      final m = SpeedMeter()
        ..add(10, Duration.zero)
        ..add(10, const Duration(seconds: 1))
        ..reset();
      expect(m.bytesPerSecond, 0);
      expect(m.eta(100), isNull);
    });
  });

  group('Transfer', () {
    test('progress is clamped and complete means 1', () {
      final t = Transfer(xid: 1, direction: TransferDirection.send, name: 'a', size: 200);
      expect(t.progress, 0);
      t.transferred = 50;
      expect(t.progress, 0.25);
      t.transferred = 500;
      expect(t.progress, 1);
      final empty = Transfer(xid: 3, direction: TransferDirection.send, name: 'e', size: 0);
      expect(empty.progress, 0);
      empty.status = TransferStatus.completed;
      expect(empty.progress, 1);
    });

    test('final states', () {
      final t = Transfer(xid: 1, direction: TransferDirection.receive, name: 'a', size: 1);
      expect(t.isRunning, isTrue);
      for (final s in [TransferStatus.completed, TransferStatus.failed, TransferStatus.cancelled]) {
        t.status = s;
        expect(t.isFinished, isTrue);
      }
      t.status = TransferStatus.verifying;
      expect(t.isFinished, isFalse);
    });
  });

  group('FileHasher', () {
    test('matches known SHA-256 vectors, also when fed in odd chunks', () {
      expect((FileHasher()).finish(), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      final h = FileHasher()
        ..add('a'.codeUnits)
        ..add('bc'.codeUnits)
        ..add(const []);
      expect(h.finish(), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(h.finish(), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', reason: 'idempotent');
    });

    test('a million a-characters', () {
      final h = FileHasher();
      final chunk = List<int>.filled(1000, 0x61);
      for (var i = 0; i < 1000; i++) {
        h.add(chunk);
      }
      expect(h.finish(), 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });
  });

  group('RemotePath', () {
    test('POSIX', () {
      expect(RemotePath.join('/Users/bob', 'a.txt'), '/Users/bob/a.txt');
      expect(RemotePath.join('/', 'etc'), '/etc');
      expect(RemotePath.parent('/Users/bob'), '/Users');
      expect(RemotePath.parent('/Users'), '/');
      expect(RemotePath.parent('/'), isNull);
      expect(RemotePath.baseName('/Users/bob/a.txt'), 'a.txt');
      expect(RemotePath.baseName('/Users/bob/'), 'bob');
      expect(RemotePath.isRoot('/'), isTrue);
      expect(RemotePath.crumbs('/Users/bob').map((c) => c.label), ['/', 'Users', 'bob']);
      expect(RemotePath.crumbs('/Users/bob').last.path, '/Users/bob');
      expect(RemotePath.crumbs('/').single.path, '/');
    });

    test('Windows', () {
      expect(RemotePath.isWindowsStyle(r'C:\Users'), isTrue);
      expect(RemotePath.join(r'C:\Users\bob', 'a.txt'), r'C:\Users\bob\a.txt');
      expect(RemotePath.join(r'C:\', 'Windows'), r'C:\Windows');
      expect(RemotePath.parent(r'C:\Users\bob'), r'C:\Users');
      expect(RemotePath.parent(r'C:\Users'), r'C:\');
      expect(RemotePath.parent(r'C:\'), isNull);
      expect(RemotePath.baseName(r'C:\Users\bob\a.txt'), 'a.txt');
      expect(RemotePath.baseName(r'C:\'), 'C');
      expect(RemotePath.isRoot(r'D:\'), isTrue);
      expect(RemotePath.crumbs(r'C:\Users\bob').map((c) => c.path), [r'C:\', r'C:\Users', r'C:\Users\bob']);
    });
  });

  group('LocalFiles.expand', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('thelxis_expand_'));
    tearDown(() => tmp.delete(recursive: true));

    test('files, folders (sorted, recursive), missing paths; symlinks inside folders are skipped', () async {
      await File('${tmp.path}/solo.txt').writeAsString('1');
      await Directory('${tmp.path}/d/sub').create(recursive: true);
      await File('${tmp.path}/d/b.txt').writeAsString('22');
      await File('${tmp.path}/d/a.txt').writeAsString('3');
      await File('${tmp.path}/d/sub/c.txt').writeAsString('4');
      await Link('${tmp.path}/d/link').create('${tmp.path}/solo.txt');
      await Link('${tmp.path}/picked_link').create('${tmp.path}/solo.txt');

      final r = await LocalFiles.expand([
        '${tmp.path}/solo.txt',
        '${tmp.path}/d',
        '${tmp.path}/nope',
        '${tmp.path}/picked_link',
      ]);
      expect(r.items.map((i) => i.name), ['solo.txt', 'd/a.txt', 'd/b.txt', 'd/sub/c.txt', 'picked_link']);
      expect(r.items.map((i) => i.size), [1, 1, 2, 1, 1]);
      expect(r.items.every((i) => i.mtime != null), isTrue);
      expect(r.missing, ['nope']);
    });

    test('a trailing separator on a folder is fine', () async {
      await Directory('${tmp.path}/d').create();
      await File('${tmp.path}/d/a.txt').writeAsString('x');
      final r = await LocalFiles.expand(['${tmp.path}/d/']);
      expect(r.items.single.name, 'd/a.txt');
    });
  });
}
