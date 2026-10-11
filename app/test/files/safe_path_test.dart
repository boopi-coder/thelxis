import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/safe_path.dart';

void rejects(String name, {bool windows = false, String? why}) {
  try {
    SafePath.splitRelative(name, windows: windows);
  } on UnsafePathException catch (e) {
    if (why != null) expect(e.reason, why, reason: 'for "$name"');
    return;
  }
  fail('expected "${name.replaceAll('\x00', r'\0')}" to be rejected (windows=$windows)');
}

void main() {
  group('splitRelative accepts normal names', () {
    test('plain file', () => expect(SafePath.splitRelative('report.pdf'), ['report.pdf']));

    test('nested folders, both separators', () {
      expect(SafePath.splitRelative('folder/sub/file.txt'), ['folder', 'sub', 'file.txt']);
      expect(SafePath.splitRelative(r'folder\sub\file.txt'), ['folder', 'sub', 'file.txt']);
      expect(SafePath.splitRelative(r'a/b\c'), ['a', 'b', 'c']);
    });

    test('unicode, spaces, dots inside names', () {
      expect(SafePath.splitRelative('Отчёт за год.xlsx'), ['Отчёт за год.xlsx']);
      expect(SafePath.splitRelative('日本語/ファイル.txt'), ['日本語', 'ファイル.txt']);
      expect(SafePath.splitRelative('a b/..c/d..e/.hidden'), ['a b', '..c', 'd..e', '.hidden']);
      expect(SafePath.splitRelative('emoji 😀.png'), ['emoji 😀.png']);
    });

    test('names that merely resemble reserved ones', () {
      expect(SafePath.splitRelative('console.log'), ['console.log']);
      expect(SafePath.splitRelative('com10.txt'), ['com10.txt']);
      expect(SafePath.splitRelative('lpt.txt'), ['lpt.txt']);
      expect(SafePath.splitRelative('nulled'), ['nulled']);
      expect(SafePath.splitRelative('auxiliary.txt'), ['auxiliary.txt']);
    });

    test('POSIX allows characters Windows does not', () {
      expect(SafePath.splitRelative('ab:c?.txt', windows: false), ['ab:c?.txt']);
      expect(SafePath.splitRelative('trailing.', windows: false), ['trailing.']);
      expect(SafePath.splitRelative('trailing ', windows: false), ['trailing ']);
    });
  });

  group('splitRelative rejects malicious names', () {
    test('empty', () => rejects(''));

    test('absolute POSIX paths', () {
      rejects('/etc/passwd', why: 'absolute');
      rejects('/', why: 'absolute');
      rejects('//server/share/x', why: 'absolute');
    });

    test('absolute / UNC Windows paths', () {
      rejects(r'\Windows\System32\x.dll', why: 'absolute');
      rejects(r'\\server\share\x', why: 'absolute');
      rejects(r'\\?\C:\x', why: 'absolute');
      rejects(r'\\.\pipe\evil', why: 'absolute');
    });

    test('drive letters in every spelling', () {
      rejects(r'C:\Windows\x', why: 'drive_letter');
      rejects('C:/Windows/x', why: 'drive_letter');
      rejects('c:x', why: 'drive_letter');
      rejects('Z:', why: 'drive_letter');
    });

    test('parent traversal', () {
      rejects('..', why: 'dot_segment');
      rejects('../evil', why: 'dot_segment');
      rejects('a/../../evil', why: 'dot_segment');
      rejects(r'a\..\evil', why: 'dot_segment');
      rejects('a/b/..', why: 'dot_segment');
      rejects('./evil', why: 'dot_segment');
      rejects('a/./b', why: 'dot_segment');
      rejects('.', why: 'dot_segment');
    });

    test('empty segments', () {
      rejects('a//b', why: 'empty_segment');
      rejects('a/', why: 'empty_segment');
      rejects(r'a\\b', why: 'empty_segment');
    });

    test('NUL and control characters', () {
      rejects('evil\x00.txt', why: 'control_character');
      rejects('a\x00/../../b', why: 'control_character');
      rejects('line\nbreak', why: 'control_character');
      rejects('tab\there', why: 'control_character');
      rejects('bell\x07', why: 'control_character');
      rejects('esc\x1b[31m', why: 'control_character');
      rejects('del\x7f', why: 'control_character');
      rejects('c1\u0085', why: 'control_character');
    });

    test('bidi / zero-width spoofing characters', () {
      rejects('invoice\u202Egpj.exe', why: 'formatting_character');
      rejects('a\u200Bb', why: 'formatting_character');
      rejects('a\u2066b', why: 'formatting_character');
      rejects('\uFEFFa', why: 'formatting_character');
    });

    test('lone surrogates', () {
      rejects(String.fromCharCodes([0x61, 0xD800, 0x62]), why: 'invalid_utf16');
      rejects(String.fromCharCodes([0xDC00]), why: 'invalid_utf16');
    });

    test('Windows device names with any case and extension', () {
      for (final base in ['CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM9', 'LPT1', 'LPT9', 'con', 'Nul', 'cOm3']) {
        rejects(base, why: 'reserved_name');
        rejects('$base.txt', why: 'reserved_name');
        rejects('$base.tar.gz', why: 'reserved_name');
        rejects('dir/$base', why: 'reserved_name');
        rejects('$base/file', why: 'reserved_name');
      }
      rejects('CONIN\$', why: 'reserved_name');
      rejects('con .txt', why: 'reserved_name');
      rejects('COM\u00B9', why: 'reserved_name');
    });

    test('Windows-only: trailing dots and spaces', () {
      rejects('file.', windows: true, why: 'trailing_dot_or_space');
      rejects('file ', windows: true, why: 'trailing_dot_or_space');
      rejects('dir./file', windows: true, why: 'trailing_dot_or_space');
      rejects('file...', windows: true, why: 'trailing_dot_or_space');
    });

    test('Windows-only: invalid characters and streams', () {
      for (final bad in ['a<b', 'a>b', 'a"b', 'a|b', 'a?b', 'a*b', 'file.txt:stream', 'dir/ab:c']) {
        rejects(bad, windows: true, why: 'invalid_character');
      }
      // A single letter before the colon already reads as a drive.
      rejects('a:b', windows: true, why: 'drive_letter');
    });

    test('our own temp suffix', () {
      rejects('movie.mkv.thelxis-part', why: 'part_suffix');
      rejects('a/b.THELXIS-PART', why: 'part_suffix');
    });

    test('length limits', () {
      rejects('a' * 201, why: 'segment_too_long');
      rejects('я' * 101, why: 'segment_too_long'); // 202 UTF-8 bytes
      rejects('${'a/' * 70}x', why: 'too_deep');
      rejects('a' * 5000, why: 'too_long');
      expect(SafePath.splitRelative('a' * 200), ['a' * 200]);
    });
  });

  group('checkAbsolute', () {
    test('accepts normal paths', () {
      expect(SafePath.checkAbsolute('/Users/bob', windows: false), '/Users/bob');
      expect(SafePath.checkAbsolute('/Users/bob/', windows: false), '/Users/bob');
      expect(SafePath.checkAbsolute('/', windows: false), '/');
      expect(SafePath.checkAbsolute(r'C:\Users\bob', windows: true), r'C:\Users\bob');
      expect(SafePath.checkAbsolute('C:/Users/bob', windows: true), r'C:\Users\bob');
      expect(SafePath.checkAbsolute(r'D:\', windows: true), r'D:\');
    });

    test('rejects relative paths', () {
      for (final p in ['', 'relative/path', './x', '~/x', 'x']) {
        expect(() => SafePath.checkAbsolute(p, windows: false), throwsA(isA<UnsafePathException>()), reason: p);
      }
      expect(() => SafePath.checkAbsolute(r'Users\bob', windows: true), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute('C:', windows: true), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute(r'C:foo', windows: true), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute('/x', windows: true), throwsA(isA<UnsafePathException>()));
    });

    test('rejects traversal and dot segments', () {
      for (final p in ['/a/../b', '/..', '/a/./b', '/a/b/..']) {
        expect(() => SafePath.checkAbsolute(p, windows: false), throwsA(isA<UnsafePathException>()), reason: p);
      }
      expect(() => SafePath.checkAbsolute(r'C:\a\..\b', windows: true), throwsA(isA<UnsafePathException>()));
    });

    test('rejects UNC and device paths (SMB credential leak)', () {
      expect(() => SafePath.checkAbsolute(r'\\evil\share', windows: true),
          throwsA(isA<UnsafePathException>().having((e) => e.reason, 'reason', 'unc')));
      expect(() => SafePath.checkAbsolute('//evil/share', windows: true), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute(r'\\?\C:\x', windows: true), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute('//evil/share', windows: false),
          throwsA(isA<UnsafePathException>().having((e) => e.reason, 'reason', 'unc')));
    });

    test('rejects NUL / control characters, empty segments, alternate streams', () {
      expect(() => SafePath.checkAbsolute('/a\x00b', windows: false), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute('/a//b', windows: false), throwsA(isA<UnsafePathException>()));
      expect(() => SafePath.checkAbsolute(r'C:\a:stream', windows: true), throwsA(isA<UnsafePathException>()));
    });
  });

  group('uniqueName', () {
    test('first candidate is the name itself', () => expect(SafePath.uniqueName('a.txt', 0), 'a.txt'));
    test('inserts the counter before the extension', () {
      expect(SafePath.uniqueName('report.pdf', 1), 'report (1).pdf');
      expect(SafePath.uniqueName('report.pdf', 12), 'report (12).pdf');
    });
    test('no extension', () => expect(SafePath.uniqueName('Makefile', 2), 'Makefile (2)'));
    test('dotfiles keep their dot', () => expect(SafePath.uniqueName('.env', 1), '.env (1)'));
    test('only the last extension moves', () => expect(SafePath.uniqueName('a.b.c', 1), 'a.b (1).c'));
    test('tar archives keep both parts', () {
      expect(SafePath.uniqueName('backup.tar.gz', 1), 'backup (1).tar.gz');
      expect(SafePath.uniqueName('BACKUP.TAR.XZ', 3), 'BACKUP (3).TAR.XZ');
    });
  });

  group('isWithin / baseName', () {
    test('isWithin', () {
      expect(SafePath.isWithin('/a/b', '/a/b', windows: false), isTrue);
      expect(SafePath.isWithin('/a/b', '/a/b/c/d', windows: false), isTrue);
      expect(SafePath.isWithin('/a/b', '/a/bc', windows: false), isFalse);
      expect(SafePath.isWithin('/a/b', '/a', windows: false), isFalse);
      expect(SafePath.isWithin('/', '/etc', windows: false), isTrue);
      expect(SafePath.isWithin(r'C:\Data', r'c:\data\x', windows: true), isTrue);
      expect(SafePath.isWithin(r'C:\Data', r'C:\Database', windows: true), isFalse);
    });

    test('baseName handles both separator styles', () {
      expect(SafePath.baseName('/a/b/c.txt'), 'c.txt');
      expect(SafePath.baseName(r'C:\a\b\c.txt'), 'c.txt');
      expect(SafePath.baseName('/a/b/'), 'b');
      expect(SafePath.baseName('plain'), 'plain');
    });
  });

  group('destination resolution on disk', () {
    late Directory tmp;
    late Directory root;
    late Directory outside;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('thelxis_safepath_');
      root = await Directory('${tmp.path}/dest').create();
      outside = await Directory('${tmp.path}/outside').create();
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('creates missing folders inside the destination', () async {
      final parent = await SafePath.prepareParent(root, ['a', 'b', 'c']);
      expect(await Directory('${root.path}/a/b/c').exists(), isTrue);
      expect(parent.path.endsWith('c'), isTrue);
    });

    test('no segments means the destination itself', () async {
      final parent = await SafePath.prepareParent(root, const []);
      expect(await parent.resolveSymbolicLinks(), await root.resolveSymbolicLinks());
    });

    test('a symlinked folder pointing outside is refused', () async {
      await Link('${root.path}/escape').create(outside.path);
      expect(
        () => SafePath.prepareParent(root, ['escape', 'sub']),
        throwsA(isA<UnsafePathException>().having((e) => e.kind, 'kind', UnsafePathKind.escapes)),
      );
      expect(await Directory('${outside.path}/sub').exists(), isFalse);
    });

    test('a nested symlink chain leaving the destination is refused', () async {
      await Directory('${root.path}/inner').create();
      await Link('${root.path}/inner/hop').create('../../outside');
      expect(
        () => SafePath.prepareParent(root, ['inner', 'hop']),
        throwsA(isA<UnsafePathException>().having((e) => e.kind, 'kind', UnsafePathKind.escapes)),
      );
    });

    test('a dangling symlink is refused', () async {
      await Link('${root.path}/dangling').create('${tmp.path}/nowhere');
      expect(
        () => SafePath.prepareParent(root, ['dangling']),
        throwsA(isA<UnsafePathException>().having((e) => e.kind, 'kind', UnsafePathKind.escapes)),
      );
    });

    test('a symlink that stays inside the destination is fine', () async {
      await Directory('${root.path}/real').create();
      await Link('${root.path}/alias').create('${root.path}/real');
      final parent = await SafePath.prepareParent(root, ['alias', 'x']);
      expect(await Directory('${root.path}/real/x').exists(), isTrue);
      expect(SafePath.isWithin(await root.resolveSymbolicLinks(), parent.path), isTrue);
    });

    test('a file in the way of a folder is a conflict', () async {
      await File('${root.path}/taken').writeAsString('x');
      expect(
        () => SafePath.prepareParent(root, ['taken', 'x']),
        throwsA(isA<UnsafePathException>().having((e) => e.kind, 'kind', UnsafePathKind.conflict)),
      );
    });

    test('a destination that is itself a symlink is resolved, not escaped', () async {
      final alias = Link('${tmp.path}/alias_root');
      await alias.create(root.path);
      final parent = await SafePath.prepareParent(Directory(alias.path), ['sub']);
      expect(await Directory('${root.path}/sub').exists(), isTrue);
      expect(parent.path.contains('alias_root'), isFalse);
    });

    test('claimUniqueFile never reuses an existing name or follows a symlink', () async {
      await File('${root.path}/a.txt').writeAsString('mine');
      await Link('${root.path}/a (1).txt').create('${outside.path}/target.txt');
      final claimed = await SafePath.claimUniqueFile(root, 'a.txt');
      expect(claimed.path.endsWith('a (2).txt'), isTrue);
      expect(await File('${root.path}/a.txt').readAsString(), 'mine');
      expect(await File('${outside.path}/target.txt').exists(), isFalse);
    });

    test('claimUniqueFile hands out distinct names under concurrency', () async {
      final files = await Future.wait([for (var i = 0; i < 8; i++) SafePath.claimUniqueFile(root, 'x.bin')]);
      expect(files.map((f) => f.path).toSet().length, 8);
    });
  });
}
