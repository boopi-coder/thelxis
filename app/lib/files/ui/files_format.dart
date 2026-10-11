import 'package:flutter/material.dart';

import 'files_strings.dart';

/// Number / date formatting for the file UI. Kept here (rather than reusing
/// the app's `core/format.dart`) so the module has no dependency on files
/// owned by the core.

/// `1.4 MB`, `812 B`, `3,25 ГБ`.
String formatBytes(int bytes, FilesStrings s) {
  if (bytes < 0) bytes = 0;
  final units = s.sizeUnits;
  if (bytes < 1024) return '$bytes ${units[0]}';
  var value = bytes / 1024;
  var unit = 1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit >= 3 ? 2 : (value >= 100 ? 0 : 1);
  return '${value.toStringAsFixed(digits).replaceAll('.', s.decimalSeparator)} ${units[unit]}';
}

String formatSpeed(double bytesPerSecond, FilesStrings s) =>
    '${formatBytes(bytesPerSecond.round(), s)}${s.perSecond}';

/// `12 s`, `3 min 05 s`, `1 h 12 min`.
String formatEta(Duration d, FilesStrings s) {
  final total = d.inSeconds < 1 ? 1 : d.inSeconds;
  if (total < 60) return '$total ${s.seconds}';
  if (total < 3600) {
    final m = total ~/ 60;
    final sec = (total % 60).toString().padLeft(2, '0');
    return '$m ${s.minutes} $sec ${s.seconds}';
  }
  final h = total ~/ 3600;
  final m = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  return '$h ${s.hours} $m ${s.minutes}';
}

/// `2026-03-12 14:05` (English) / `12.03.2026 14:05` (Russian).
String formatModified(DateTime t, FilesStrings s) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  return s.ru
      ? '${two(t.day)}.${two(t.month)}.${t.year} $time'
      : '${t.year}-${two(t.month)}-${two(t.day)} $time';
}

/// Monospace figures for sizes, speeds and times so columns do not jitter.
TextStyle monoStyle(BuildContext context, {Color? color, double? size, FontWeight? weight}) {
  final base = Theme.of(context).textTheme.bodySmall!;
  return base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono', 'DejaVu Sans Mono'],
    fontFeatures: const [FontFeature.tabularFigures()],
    color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    fontSize: size ?? 12,
    fontWeight: weight,
    height: 1.3,
  );
}
