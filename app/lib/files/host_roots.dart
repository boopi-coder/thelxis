import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import 'log_safe.dart';
import 'protocol.dart';
import 'safe_path.dart';

const Logger _log = Logger('files.roots');

/// The places a viewer may start browsing from: Home, Desktop, Documents,
/// Downloads (those that exist), every present drive letter on Windows, and
/// the app's external storage on Android.
Future<List<FsRoot>> discoverFsRoots() async {
  final roots = <FsRoot>[];
  final seen = <String>{};

  Future<void> add(String name, String kind, String? path) async {
    if (path == null || path.isEmpty || !seen.add(path)) return;
    try {
      if (await FileSystemEntity.type(path) != FileSystemEntityType.directory) {
        seen.remove(path);
        return;
      }
    } on FileSystemException {
      seen.remove(path);
      return;
    }
    roots.add(FsRoot(name: name, path: path, kind: kind));
  }

  if (Platform.isAndroid) {
    await add('App files', 'storage', await _safe(getExternalStorageDirectory));
    await add('Downloads', 'downloads', await _safe(getDownloadsDirectory));
    return roots;
  }

  final env = Platform.environment;
  final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  final xdg = Platform.isLinux && home != null ? await _readXdgDirs(home) : const <String, String>{};

  await add('Home', 'home', home);
  await add('Desktop', 'desktop', xdg['DESKTOP'] ?? await _desktop(home));
  await add(
    'Documents',
    'documents',
    xdg['DOCUMENTS'] ?? await _safe(getApplicationDocumentsDirectory) ?? _under(home, 'Documents'),
  );
  await add(
    'Downloads',
    'downloads',
    xdg['DOWNLOAD'] ?? await _safe(getDownloadsDirectory) ?? _under(home, 'Downloads'),
  );

  if (Platform.isWindows) {
    final drives = await Future.wait([
      for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) _driveIfPresent(String.fromCharCode(c)),
    ]);
    for (final d in drives) {
      if (d != null && seen.add(d)) roots.add(FsRoot(name: d, path: d, kind: 'drive'));
    }
  }
  return roots;
}

/// Plugin lookups fail in tests and on unusual platforms; roots just shrink.
Future<String?> _safe(Future<Directory?> Function() lookup) async {
  try {
    return (await lookup())?.path;
  } catch (e) {
    _log.d('directory lookup failed: ${errorTag(e)}');
    return null;
  }
}

String? _under(String? home, String name) => home == null ? null : SafePath.join(home, name);

Future<String?> _desktop(String? home) async {
  if (home == null) return null;
  final plain = SafePath.join(home, 'Desktop');
  if (await Directory(plain).exists()) return plain;
  // Windows folder redirection into OneDrive is common.
  final oneDrive = Platform.environment['OneDrive'];
  if (oneDrive != null) {
    final redirected = SafePath.join(oneDrive, 'Desktop');
    if (await Directory(redirected).exists()) return redirected;
  }
  return plain;
}

/// A disconnected network drive can block for seconds, so each probe is capped.
Future<String?> _driveIfPresent(String letter) async {
  final root = '$letter:\\';
  try {
    final exists = await Directory(root).exists().timeout(const Duration(milliseconds: 1500), onTimeout: () => false);
    return exists ? root : null;
  } catch (_) {
    return null;
  }
}

/// `~/.config/user-dirs.dirs` holds localised folder names on Linux
/// (`XDG_DESKTOP_DIR="$HOME/Рабочий стол"`).
Future<Map<String, String>> _readXdgDirs(String home) async {
  final result = <String, String>{};
  try {
    final lines = await File(SafePath.join(home, '.config/user-dirs.dirs')).readAsLines();
    final pattern = RegExp(r'^XDG_(DESKTOP|DOCUMENTS|DOWNLOAD)_DIR="(.*)"\s*$');
    for (final line in lines) {
      final m = pattern.firstMatch(line.trim());
      if (m == null) continue;
      final value = m.group(2)!.replaceFirst(r'$HOME', home);
      if (value.startsWith('/')) result[m.group(1)!] = value;
    }
  } on FileSystemException {
    // No user-dirs file: fall back to the English defaults.
  }
  return result;
}
