import '../l10n/strings.dart';

/// Groups a 9-digit device id as `482 913 057`. Other strings pass through.
String formatDeviceId(String? id) {
  if (id == null || id.isEmpty) return '—';
  final digits = id.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^\d{9}$').hasMatch(digits)) return id;
  return '${digits.substring(0, 3)} ${digits.substring(3, 6)} ${digits.substring(6)}';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// `12.3 Mbps` / `640 kbps` style rate from bits per second.
String formatBitrate(double bitsPerSecond) {
  if (bitsPerSecond >= 1e6) return '${(bitsPerSecond / 1e6).toStringAsFixed(1)} Mbps';
  return '${(bitsPerSecond / 1e3).round()} kbps';
}

/// Short relative time such as `just now`, `5 min ago`, `3 h ago`, `2 d ago`
/// in the current UI language.
String formatLastSeen(DateTime? time, {DateTime? now, S? strings}) {
  final s = strings ?? S.current;
  if (time == null) return s.t('time.never');
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inSeconds < 45) return s.t('time.justNow');
  if (diff.inMinutes < 60) return s.plural('time.min', diff.inMinutes);
  if (diff.inHours < 24) return s.plural('time.hour', diff.inHours);
  return s.plural('time.day', diff.inDays);
}
