import 'dart:convert';
import 'dart:io';

/// Name sanitisation and destination resolution (PROTOCOL §6.4).
///
/// Everything a peer sends — file names, `dest` directories, paths to browse
/// or fetch — is attacker-controlled. This file is the single choke point that
/// turns such strings into something safe to hand to `dart:io`.

enum UnsafePathKind {
  /// The name itself is not acceptable (absolute, `..`, control chars, ...).
  name,

  /// The name is fine but resolving it would leave the destination folder.
  escapes,

  /// Something that is not a directory is in the way of a folder segment.
  conflict,
}

class UnsafePathException implements Exception {
  const UnsafePathException(this.kind, this.reason);

  final UnsafePathKind kind;

  /// Short machine-ish reason, safe to log (contains no path data).
  final String reason;

  @override
  String toString() => 'UnsafePathException(${kind.name}: $reason)';
}

/// Extension of the file a transfer is written to until it is verified.
const String kPartSuffix = '.thelxis-part';

abstract final class SafePath {
  static const int maxNameChars = 4096;

  /// UTF-8 bytes per path segment. Filesystems allow 255, but the `.part`
  /// suffix and a ` (n)` clash suffix are appended to the final segment.
  static const int maxSegmentBytes = 200;
  static const int maxDepth = 64;

  static final RegExp _driveLetter = RegExp(r'^[A-Za-z]:');
  static final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');
  static const String _windowsInvalidChars = '<>:"|?*';

  static const Set<String> _reserved = {
    'CON', 'PRN', 'AUX', 'NUL', 'CONIN\$', 'CONOUT\$', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
    // Superscript digits are reserved too on current Windows releases.
    'COM\u00B9', 'COM\u00B2', 'COM\u00B3', 'LPT\u00B9', 'LPT\u00B2', 'LPT\u00B3',
  };

  static bool get _hostIsWindows => Platform.isWindows;

  // --------------------------------------------------------------------------
  // Peer-supplied relative names (`put.name`)
  // --------------------------------------------------------------------------

  /// Validates a peer-supplied relative file name and returns its segments
  /// (`"a\\b/c.txt"` -> `[a, b, c.txt]`). Throws [UnsafePathException].
  ///
  /// Rejected everywhere: absolute paths, drive letters, UNC, empty / `.` /
  /// `..` segments, NUL and other control characters, invisible formatting
  /// characters that spoof extensions (bidi overrides), Windows device names
  /// (also with extensions: `aux.txt`), over-long names, our own `.part`
  /// suffix. Additionally on Windows ([windows]): trailing dots/spaces and
  /// the characters `<>:"|?*`.
  static List<String> splitRelative(String name, {bool? windows}) {
    final win = windows ?? _hostIsWindows;
    if (name.isEmpty) throw const UnsafePathException(UnsafePathKind.name, 'empty');
    if (name.length > maxNameChars) throw const UnsafePathException(UnsafePathKind.name, 'too_long');
    _rejectBadCharacters(name);

    final normalized = name.replaceAll('\\', '/');
    if (normalized.startsWith('/')) {
      throw const UnsafePathException(UnsafePathKind.name, 'absolute');
    }
    if (_driveLetter.hasMatch(normalized)) {
      throw const UnsafePathException(UnsafePathKind.name, 'drive_letter');
    }

    final segments = normalized.split('/');
    if (segments.length > maxDepth) throw const UnsafePathException(UnsafePathKind.name, 'too_deep');
    for (final segment in segments) {
      checkSegment(segment, windows: win);
    }
    return segments;
  }

  /// Validates a single path segment. See [splitRelative] for the rules.
  static void checkSegment(String segment, {bool? windows}) {
    final win = windows ?? _hostIsWindows;
    if (segment.isEmpty) throw const UnsafePathException(UnsafePathKind.name, 'empty_segment');
    if (segment == '.' || segment == '..') {
      throw const UnsafePathException(UnsafePathKind.name, 'dot_segment');
    }
    _rejectBadCharacters(segment);
    if (utf8.encode(segment).length > maxSegmentBytes) {
      throw const UnsafePathException(UnsafePathKind.name, 'segment_too_long');
    }
    if (isReservedWindowsName(segment)) {
      throw const UnsafePathException(UnsafePathKind.name, 'reserved_name');
    }
    if (segment.toLowerCase().endsWith(kPartSuffix)) {
      throw const UnsafePathException(UnsafePathKind.name, 'part_suffix');
    }
    if (win) {
      final last = segment.codeUnitAt(segment.length - 1);
      if (last == 0x2E || last == 0x20) {
        throw const UnsafePathException(UnsafePathKind.name, 'trailing_dot_or_space');
      }
      for (var i = 0; i < segment.length; i++) {
        if (_windowsInvalidChars.contains(segment[i])) {
          throw const UnsafePathException(UnsafePathKind.name, 'invalid_character');
        }
      }
    }
  }

  /// `CON`, `nul.txt`, `Com1.tar.gz`, `lpt9 .x` ... — Windows device names,
  /// with or without an extension, any case.
  static bool isReservedWindowsName(String segment) {
    final dot = segment.indexOf('.');
    var stem = dot < 0 ? segment : segment.substring(0, dot);
    // Windows ignores trailing spaces of the stem ("CON .txt").
    stem = stem.replaceFirst(RegExp(r' +$'), '');
    return _reserved.contains(stem.toUpperCase());
  }

  static void _rejectBadCharacters(String s) {
    final units = s.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final c = units[i];
      if (c < 0x20 || c == 0x7F || (c >= 0x80 && c <= 0x9F)) {
        throw const UnsafePathException(UnsafePathKind.name, 'control_character');
      }
      // Zero-width / bidi formatting characters make "gpj.exe" look like
      // "exe.jpg" and the like.
      if ((c >= 0x200B && c <= 0x200F) ||
          (c >= 0x202A && c <= 0x202E) ||
          (c >= 0x2060 && c <= 0x2064) ||
          (c >= 0x2066 && c <= 0x2069) ||
          c == 0x061C ||
          c == 0xFEFF) {
        throw const UnsafePathException(UnsafePathKind.name, 'formatting_character');
      }
      if (c >= 0xD800 && c <= 0xDBFF) {
        if (i + 1 >= units.length || units[i + 1] < 0xDC00 || units[i + 1] > 0xDFFF) {
          throw const UnsafePathException(UnsafePathKind.name, 'invalid_utf16');
        }
        i++;
      } else if (c >= 0xDC00 && c <= 0xDFFF) {
        throw const UnsafePathException(UnsafePathKind.name, 'invalid_utf16');
      }
    }
  }

  // --------------------------------------------------------------------------
  // Absolute paths coming from the peer (`dest`, `fs_list.path`, `get.path`)
  // --------------------------------------------------------------------------

  /// Validates an absolute path chosen by the peer and returns it unchanged
  /// (minus a trailing separator). Rejects relative paths, `..` / `.`
  /// segments, control characters and UNC / device paths (`\\server\share`,
  /// `\\?\C:\`): touching those on Windows makes the OS authenticate to a
  /// host of the attacker's choosing.
  static String checkAbsolute(String path, {bool? windows}) {
    final win = windows ?? _hostIsWindows;
    if (path.isEmpty) throw const UnsafePathException(UnsafePathKind.name, 'empty');
    if (path.length > maxNameChars) throw const UnsafePathException(UnsafePathKind.name, 'too_long');
    _rejectBadCharacters(path);

    final String rest;
    final String prefix;
    if (win) {
      if (!_windowsAbsolute.hasMatch(path)) {
        throw UnsafePathException(
          UnsafePathKind.name,
          path.startsWith('\\\\') || path.startsWith('//') ? 'unc' : 'not_absolute',
        );
      }
      prefix = path.substring(0, 2);
      rest = path.substring(3);
    } else {
      if (!path.startsWith('/')) throw const UnsafePathException(UnsafePathKind.name, 'not_absolute');
      if (path.startsWith('//')) throw const UnsafePathException(UnsafePathKind.name, 'unc');
      prefix = '';
      rest = path.substring(1);
    }

    final sep = win ? RegExp(r'[\\/]') : RegExp('/');
    final segments = rest.split(sep);
    // A single trailing separator is just a spelling of the directory.
    if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
    for (final s in segments) {
      if (s.isEmpty) throw const UnsafePathException(UnsafePathKind.name, 'empty_segment');
      if (s == '.' || s == '..') throw const UnsafePathException(UnsafePathKind.name, 'dot_segment');
      if (win && s.contains(':')) {
        throw const UnsafePathException(UnsafePathKind.name, 'stream_or_device');
      }
    }
    if (win) {
      return segments.isEmpty ? '$prefix\\' : '$prefix\\${segments.join('\\')}';
    }
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  // --------------------------------------------------------------------------
  // Destination resolution
  // --------------------------------------------------------------------------

  /// Walks the directory [segments] below [root], creating missing folders,
  /// and returns the (symlink-resolved) directory the file belongs in.
  ///
  /// Existing symlinked folders are followed only if they resolve to a
  /// location inside [root]; otherwise [UnsafePathException] with
  /// [UnsafePathKind.escapes]. [root] itself must exist.
  static Future<Directory> prepareParent(
    Directory root,
    List<String> segments, {
    bool? windows,
  }) async {
    final win = windows ?? _hostIsWindows;
    final realRoot = await root.resolveSymbolicLinks();
    var current = realRoot;
    for (final segment in segments) {
      final next = join(current, segment);
      var type = await FileSystemEntity.type(next, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        try {
          await Directory(next).create();
        } on FileSystemException {
          // Lost a creation race; re-examine whatever is there now.
        }
        type = await FileSystemEntity.type(next, followLinks: false);
      }
      switch (type) {
        case FileSystemEntityType.directory:
          current = next;
        case FileSystemEntityType.link:
          final String resolved;
          try {
            resolved = await Directory(next).resolveSymbolicLinks();
          } on FileSystemException {
            throw const UnsafePathException(UnsafePathKind.escapes, 'dangling_link');
          }
          if (!isWithin(realRoot, resolved, windows: win) ||
              await FileSystemEntity.type(resolved) != FileSystemEntityType.directory) {
            throw const UnsafePathException(UnsafePathKind.escapes, 'link_leaves_destination');
          }
          current = resolved;
        default:
          throw const UnsafePathException(UnsafePathKind.conflict, 'not_a_directory');
      }
    }
    if (!isWithin(realRoot, current, windows: win)) {
      throw const UnsafePathException(UnsafePathKind.escapes, 'outside_destination');
    }
    return Directory(current);
  }

  /// Reserves the first free name for [fileName] in [dir] — `a.txt`,
  /// `a (1).txt`, `a (2).txt`... — by creating it exclusively, so two
  /// concurrent transfers (or a racing local process) can never get the same
  /// path and an existing file or symlink is never opened or replaced.
  static Future<File> claimUniqueFile(Directory dir, String fileName) async {
    for (var n = 0; n < 10000; n++) {
      final candidate = File(join(dir.path, uniqueName(fileName, n)));
      try {
        return await candidate.create(exclusive: true);
      } on PathExistsException {
        continue;
      } on FileSystemException {
        // Some platforms report "exists" with a generic exception; if the name
        // really is taken try the next one, otherwise surface the error.
        if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        rethrow;
      }
    }
    throw const UnsafePathException(UnsafePathKind.conflict, 'no_free_name');
  }

  /// `report.pdf` -> `report (1).pdf` for [n] = 1. [n] = 0 returns the name
  /// unchanged. Dotfiles keep their leading dot (`.env (1)`), and `.tar.gz`
  /// style double extensions stay together (`a (1).tar.gz`).
  static String uniqueName(String fileName, int n) {
    if (n <= 0) return fileName;
    final dot = fileName.lastIndexOf('.');
    var stemEnd = dot <= 0 ? fileName.length : dot;
    if (dot > 0) {
      final stem = fileName.substring(0, dot);
      if (stem.toLowerCase().endsWith('.tar')) stemEnd = dot - 4;
    }
    return '${fileName.substring(0, stemEnd)} ($n)${fileName.substring(stemEnd)}';
  }

  // --------------------------------------------------------------------------
  // Tiny path helpers (package:path is not a direct dependency)
  // --------------------------------------------------------------------------

  static String get separator => Platform.pathSeparator;

  static String join(String dir, String name) {
    final sep = separator;
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  /// Last path segment, whichever separator style the path uses.
  static String baseName(String path) {
    var end = path.length;
    while (end > 1 && (path[end - 1] == '/' || path[end - 1] == '\\')) {
      end--;
    }
    final trimmed = path.substring(0, end);
    final i = trimmed.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? trimmed : trimmed.substring(i + 1);
  }

  /// True if [child] is [parent] or lies below it. Both must already be
  /// canonical (symlink-resolved) absolute paths.
  static bool isWithin(String parent, String child, {bool? windows}) {
    final win = windows ?? _hostIsWindows;
    var p = parent;
    var c = child;
    if (win) {
      p = p.toLowerCase();
      c = c.toLowerCase();
    }
    final sep = win ? '\\' : '/';
    if (c == p) return true;
    final prefix = p.endsWith(sep) ? p : '$p$sep';
    return c.startsWith(prefix);
  }
}
