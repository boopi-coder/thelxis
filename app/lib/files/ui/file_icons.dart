import 'package:flutter/material.dart';

import '../../ui/theme.dart';

enum FileKind { folder, image, video, audio, archive, pdf, document, spreadsheet, presentation, code, text, app, other }

/// What a file looks like in lists: an icon and an accent colour that reads
/// well on both light and dark surfaces.
class FileKindStyle {
  const FileKindStyle(this.icon, this.hue);
  final IconData icon;

  /// Base hue in degrees; saturation / lightness are derived per brightness.
  final double hue;

  Color accent(Brightness b) => HSLColor.fromAHSL(1, hue, b == Brightness.dark ? 0.62 : 0.58, b == Brightness.dark ? 0.68 : 0.42).toColor();

  Color container(Brightness b) => accent(b).withValues(alpha: b == Brightness.dark ? 0.16 : 0.12);
}

const Map<FileKind, FileKindStyle> _styles = {
  FileKind.folder: FileKindStyle(Icons.folder_rounded, 42),
  FileKind.image: FileKindStyle(Icons.image_rounded, 330),
  FileKind.video: FileKindStyle(Icons.movie_rounded, 280),
  FileKind.audio: FileKindStyle(Icons.audiotrack_rounded, 24),
  FileKind.archive: FileKindStyle(Icons.folder_zip_rounded, 36),
  FileKind.pdf: FileKindStyle(Icons.picture_as_pdf_rounded, 4),
  FileKind.document: FileKindStyle(Icons.description_rounded, 215),
  FileKind.spreadsheet: FileKindStyle(Icons.table_chart_rounded, 140),
  FileKind.presentation: FileKindStyle(Icons.slideshow_rounded, 20),
  FileKind.code: FileKindStyle(Icons.code_rounded, 175),
  FileKind.text: FileKindStyle(Icons.article_rounded, 210),
  FileKind.app: FileKindStyle(Icons.apps_rounded, 255),
  FileKind.other: FileKindStyle(Icons.insert_drive_file_rounded, 230),
};

const Map<String, FileKind> _byExtension = {
  'jpg': FileKind.image, 'jpeg': FileKind.image, 'png': FileKind.image, 'gif': FileKind.image,
  'webp': FileKind.image, 'bmp': FileKind.image, 'svg': FileKind.image, 'heic': FileKind.image,
  'tif': FileKind.image, 'tiff': FileKind.image, 'raw': FileKind.image, 'ico': FileKind.image,
  'mp4': FileKind.video, 'mkv': FileKind.video, 'mov': FileKind.video, 'avi': FileKind.video,
  'webm': FileKind.video, 'wmv': FileKind.video, 'flv': FileKind.video, 'm4v': FileKind.video,
  'mp3': FileKind.audio, 'wav': FileKind.audio, 'flac': FileKind.audio, 'ogg': FileKind.audio,
  'm4a': FileKind.audio, 'aac': FileKind.audio, 'opus': FileKind.audio,
  'zip': FileKind.archive, 'rar': FileKind.archive, '7z': FileKind.archive, 'tar': FileKind.archive,
  'gz': FileKind.archive, 'bz2': FileKind.archive, 'xz': FileKind.archive, 'tgz': FileKind.archive,
  'pdf': FileKind.pdf,
  'doc': FileKind.document, 'docx': FileKind.document, 'odt': FileKind.document, 'rtf': FileKind.document,
  'pages': FileKind.document,
  'xls': FileKind.spreadsheet, 'xlsx': FileKind.spreadsheet, 'ods': FileKind.spreadsheet,
  'csv': FileKind.spreadsheet, 'numbers': FileKind.spreadsheet,
  'ppt': FileKind.presentation, 'pptx': FileKind.presentation, 'odp': FileKind.presentation,
  'key': FileKind.presentation,
  'dart': FileKind.code, 'js': FileKind.code, 'ts': FileKind.code, 'py': FileKind.code,
  'java': FileKind.code, 'kt': FileKind.code, 'c': FileKind.code, 'cpp': FileKind.code,
  'h': FileKind.code, 'cs': FileKind.code, 'go': FileKind.code, 'rs': FileKind.code,
  'swift': FileKind.code, 'html': FileKind.code, 'css': FileKind.code, 'json': FileKind.code,
  'xml': FileKind.code, 'yaml': FileKind.code, 'yml': FileKind.code, 'sh': FileKind.code,
  'txt': FileKind.text, 'md': FileKind.text, 'log': FileKind.text, 'ini': FileKind.text,
  'exe': FileKind.app, 'msi': FileKind.app, 'dmg': FileKind.app, 'apk': FileKind.app,
  'app': FileKind.app, 'deb': FileKind.app, 'rpm': FileKind.app, 'pkg': FileKind.app,
  'appimage': FileKind.app,
};

FileKind fileKindOf(String name, {bool isDir = false}) {
  if (isDir) return FileKind.folder;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return FileKind.other;
  return _byExtension[name.substring(dot + 1).toLowerCase()] ?? FileKind.other;
}

FileKindStyle styleOf(FileKind kind) => _styles[kind]!;

/// Rounded tinted tile with the file-type icon; [badge] overlays a small
/// corner marker (e.g. transfer direction).
class FileIconTile extends StatelessWidget {
  const FileIconTile({super.key, required this.name, this.isDir = false, this.size = 40, this.badge});

  final String name;
  final bool isDir;
  final double size;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    // One accent only: folders are blue, every other type is a neutral icon
    // (the type is told by the glyph, not by a rainbow of colours).
    final c = context.c;
    final kind = fileKindOf(name, isDir: isDir);
    final style = styleOf(kind);
    final tile = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: kind == FileKind.folder ? c.accentSoft : c.inset,
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      child: Icon(
        style.icon,
        size: size * 0.55,
        color: kind == FileKind.folder ? c.accent : c.textSecondary,
      ),
    );
    if (badge == null) return tile;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          tile,
          Positioned(right: -4, bottom: -4, child: badge!),
        ],
      ),
    );
  }
}
