/// Path arithmetic for paths that live on the *other* machine. The viewer does
/// not know the host's OS, so the style (POSIX `/` or Windows `\`) is inferred
/// from the path itself.
class RemoteCrumb {
  const RemoteCrumb(this.label, this.path);
  final String label;
  final String path;
}

abstract final class RemotePath {
  static final RegExp _drive = RegExp(r'^[A-Za-z]:');

  static bool isWindowsStyle(String path) => _drive.hasMatch(path) || path.startsWith('\\\\');

  static String separatorOf(String path) => isWindowsStyle(path) ? '\\' : '/';

  static String join(String dir, String name) {
    final sep = separatorOf(dir);
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  /// Last segment; a drive root is named by its letter, `/` by `root`.
  static String baseName(String path) {
    if (isRoot(path)) return isWindowsStyle(path) ? path.substring(0, 1) : 'root';
    final sep = separatorOf(path);
    var end = path.length;
    while (end > 1 && path[end - 1] == sep) {
      end--;
    }
    final trimmed = path.substring(0, end);
    final i = trimmed.lastIndexOf(sep);
    if (i < 0) return trimmed;
    final name = trimmed.substring(i + 1);
    return name.isEmpty ? trimmed : name;
  }

  static bool isRoot(String path) {
    if (isWindowsStyle(path)) return RegExp(r'^[A-Za-z]:[\\/]?$').hasMatch(path);
    return path == '/';
  }

  /// Parent directory, or `null` at a root.
  static String? parent(String path) {
    if (isRoot(path)) return null;
    final sep = separatorOf(path);
    var end = path.length;
    while (end > 1 && path[end - 1] == sep) {
      end--;
    }
    final i = path.lastIndexOf(sep, end - 1);
    if (i < 0) return null;
    if (i == 0) return sep;
    if (isWindowsStyle(path) && i == 2) return path.substring(0, 3);
    return path.substring(0, i);
  }

  /// Breadcrumb trail from the root down to [path].
  static List<RemoteCrumb> crumbs(String path) {
    final sep = separatorOf(path);
    final crumbs = <RemoteCrumb>[];
    String current;
    String rest;
    if (isWindowsStyle(path) && path.length >= 2) {
      current = '${path.substring(0, 2)}\\';
      crumbs.add(RemoteCrumb(current, current));
      rest = path.length > 3 ? path.substring(3) : '';
    } else {
      current = '/';
      crumbs.add(const RemoteCrumb('/', '/'));
      rest = path.startsWith('/') ? path.substring(1) : path;
    }
    for (final part in rest.split(sep)) {
      if (part.isEmpty) continue;
      current = join(current, part);
      crumbs.add(RemoteCrumb(part, current));
    }
    return crumbs;
  }
}
