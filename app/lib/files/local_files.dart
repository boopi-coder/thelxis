import 'dart:io';

import 'safe_path.dart';

/// One regular file to send, with the name the receiver will see.
class LocalFileItem {
  const LocalFileItem({required this.path, required this.name, required this.size, this.mtime});

  final String path;

  /// Forward-slash relative name (`folder/sub/a.txt`, or just `a.txt`).
  final String name;
  final int size;

  /// Seconds since the Unix epoch.
  final int? mtime;
}

class LocalExpansion {
  const LocalExpansion(this.items, this.missing);
  final List<LocalFileItem> items;

  /// Base names of inputs that vanished or could not be read.
  final List<String> missing;
}

abstract final class LocalFiles {
  static const int maxFiles = 100000;

  /// Turns user-picked paths into the flat list of files to send. Folders are
  /// walked recursively and symlinks inside them are skipped (a link could
  /// point anywhere, including back up the tree); a symlink the user picked
  /// directly is followed because that is what they meant.
  static Future<LocalExpansion> expand(List<String> paths) async {
    final items = <LocalFileItem>[];
    final missing = <String>[];
    for (final raw in paths) {
      if (items.length >= maxFiles) break;
      final type = await FileSystemEntity.type(raw);
      final base = SafePath.baseName(raw);
      if (type == FileSystemEntityType.file) {
        final item = await _describe(raw, base);
        if (item == null) {
          missing.add(base);
        } else {
          items.add(item);
        }
      } else if (type == FileSystemEntityType.directory) {
        await _walk(Directory(raw), base, items, missing);
      } else {
        missing.add(base);
      }
    }
    return LocalExpansion(items, missing);
  }

  static Future<void> _walk(
    Directory dir,
    String relative,
    List<LocalFileItem> out,
    List<String> missing,
  ) async {
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      missing.add(SafePath.baseName(dir.path));
      return;
    }
    children.sort((a, b) => SafePath.baseName(a.path).compareTo(SafePath.baseName(b.path)));
    for (final child in children) {
      if (out.length >= maxFiles) return;
      final name = SafePath.baseName(child.path);
      final rel = '$relative/$name';
      if (child is File) {
        final item = await _describe(child.path, rel);
        if (item == null) {
          missing.add(name);
        } else {
          out.add(item);
        }
      } else if (child is Directory) {
        await _walk(child, rel, out, missing);
      }
      // Links and special files are skipped on purpose.
    }
  }

  static Future<LocalFileItem?> _describe(String path, String name) async {
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return LocalFileItem(
        path: path,
        name: name,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
      );
    } on FileSystemException {
      return null;
    }
  }
}
