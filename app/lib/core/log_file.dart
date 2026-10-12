import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'log.dart';
import 'system_info.dart';

/// Private on-device diagnostic log: every emitted [Logger] line, timestamped,
/// in `<application support>/logs/thelxis.log`, rotated to `thelxis.1.log`
/// past [maxBytes]. Release builds otherwise log nowhere, which makes field
/// bugs undiagnosable. Nothing here ever sends the log anywhere; the user
/// copies or attaches it themselves from Settings.
///
/// Lines are buffered and written asynchronously so logging never blocks the
/// UI isolate on disk IO, and every IO failure is swallowed: a broken log
/// must never break the app.
class LogFile {
  LogFile(
    this.directory, {
    this.maxBytes = defaultMaxBytes,
    this.flushInterval = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const fileName = 'thelxis.log';
  static const previousFileName = 'thelxis.1.log';
  static const defaultMaxBytes = 1024 * 1024;

  final Directory directory;
  final int maxBytes;
  final Duration flushInterval;
  final DateTime Function() _clock;

  File get current => File('${directory.path}${Platform.pathSeparator}$fileName');
  File get previous => File('${directory.path}${Platform.pathSeparator}$previousFileName');

  final _buffer = StringBuffer();
  Timer? _timer;
  Future<void> _pending = Future.value();
  bool _dirReady = false;
  AppLifecycleListener? _lifecycle;

  static LogFile? _instance;

  /// The app-wide log, or null when file logging is off (tests, or the
  /// support directory is unavailable).
  static LogFile? get instance => _instance;

  /// Starts the app-wide log. Off under `flutter test` so tests never write
  /// into the developer's real support directory; a test that wants a log
  /// creates a [LogFile] on a temp dir and calls [install].
  static Future<LogFile?> start() async {
    if (_instance != null) return _instance;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    try {
      final support = await getApplicationSupportDirectory();
      final log = LogFile(Directory('${support.path}${Platform.pathSeparator}logs'));
      install(log);
      log._listenLifecycle();
      return log;
    } on Object {
      return null;
    }
  }

  /// Makes [log] the app-wide log and routes [Logger] output into it.
  static void install(LogFile? log) {
    _instance = log;
    Logger.fileSink = log?.add;
  }

  /// Buffers one already-formatted logger line. Never throws.
  void add(LogLevel level, String line) {
    try {
      final ts = _clock().toUtc().toIso8601String();
      // Continuation lines are indented so a multi-line error stays visibly
      // one entry.
      _buffer
        ..write(ts)
        ..write(' ')
        ..write(redact(line).replaceAll('\n', '\n    '))
        ..write('\n');
      // If the disk stalls, keep memory bounded rather than the history.
      if (_buffer.length > maxBytes) {
        _buffer
          ..clear()
          ..write('$ts [warn] log: buffer overflow, lines dropped\n');
      }
      if (level == LogLevel.error) {
        // Errors often precede a crash; get them out without waiting.
        unawaited(flush());
      } else {
        _timer ??= Timer(flushInterval, () => unawaited(flush()));
      }
    } on Object {
      // Logging must never break the caller.
    }
  }

  /// Writes the buffered lines. Calls are serialised; never throws.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _pending = _pending.then((_) => _drain());
  }

  Future<void> _drain() async {
    if (_buffer.isEmpty) return;
    final chunk = _buffer.toString();
    _buffer.clear();
    try {
      await _ensureDir();
      final file = current;
      await file.writeAsString(chunk, mode: FileMode.append);
      if (await file.length() > maxBytes) await _rotate();
    } on Object {
      // Disk full, permissions, removed directory: drop the chunk.
    }
  }

  Future<void> _ensureDir() async {
    if (_dirReady && directory.existsSync()) return;
    await directory.create(recursive: true);
    _dirReady = true;
  }

  Future<void> _rotate() async {
    // Delete first: Windows refuses to rename onto an existing file.
    if (await previous.exists()) await previous.delete();
    await current.rename(previous.path);
  }

  /// Synchronous last-chance write for process exit, when an async flush
  /// would never complete. Never throws.
  void flushSync() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty) return;
    final chunk = _buffer.toString();
    _buffer.clear();
    try {
      directory.createSync(recursive: true);
      current.writeAsStringSync(chunk, mode: FileMode.append);
    } on Object {
      // Nothing more can be done at exit.
    }
  }

  /// The last [lines] lines across the rotated and the current file, after
  /// flushing what is buffered. Empty when there is no log yet.
  Future<String> tail({int lines = 200}) async {
    await flush();
    final all = <String>[];
    for (final f in [previous, current]) {
      try {
        if (!await f.exists()) continue;
        final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
        all.addAll(const LineSplitter().convert(text));
      } on Object {
        // An unreadable file contributes nothing.
      }
    }
    final start = all.length > lines ? all.length - lines : 0;
    return all.sublist(start).join('\n');
  }

  /// Deletes both log files and anything still buffered. Never throws.
  Future<void> clear() {
    _timer?.cancel();
    _timer = null;
    _buffer.clear();
    return _pending = _pending.then((_) async {
      for (final f in [current, previous]) {
        try {
          if (await f.exists()) await f.delete();
        } on Object {
          // Leave what cannot be removed.
        }
      }
    });
  }

  void _listenLifecycle() {
    try {
      _lifecycle = AppLifecycleListener(
        onStateChange: (state) {
          if (state == AppLifecycleState.detached) {
            flushSync();
          } else if (state != AppLifecycleState.resumed) {
            unawaited(flush());
          }
        },
      );
    } on Object {
      // No binding (headless use): the timer still flushes.
    }
  }

  /// Flushes and stops listening. The instance stays usable for reads.
  Future<void> dispose() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    await flush();
  }

  static final _redactions = <RegExp>[
    // SDP credential attribute, e.g. `a=ice-pwd:abc`.
    RegExp(r'(a=ice-pwd:)\S+', caseSensitive: false),
    // `key=value`, `key: value`, `"key":"value"` where the key names a secret.
    RegExp(
      r'''(\b[\w-]*(?:ice[-_]?pwd|passw(?:or)?d|passphrase|pwd|secret|token|proof|credential|otp|private[-_]?key|api[-_]?key|authorization)[\w-]*["']?\s*[:=]\s*["']?)(?:(?:Bearer|Basic)\s+)?[^\s"',;&}\])]+''',
      caseSensitive: false,
    ),
    // HTTP-style bearer tokens.
    RegExp(r'(\bBearer\s+)\S+', caseSensitive: false),
  ];

  /// Masks values that look like secrets. Defence in depth only: callers
  /// must still never log secrets in the first place.
  static String redact(String line) {
    var out = line;
    for (final re in _redactions) {
      out = out.replaceAllMapped(re, (m) => '${m[1]}***');
    }
    return out;
  }
}

/// One line that makes a report self-describing: version, OS, CPU and the
/// permissions that decide whether capture and remote input can work.
String environmentHeader(SystemInfo info, Map<String, String> permissions) {
  final perms = permissions.entries.map((e) => '${e.key}=${e.value}').join(' ');
  return 'Thelxis ${info.appVersion} on ${info.os} ${info.osVersion} (${info.arch})'
      '${perms.isEmpty ? '' : '; permissions: $perms'}';
}
