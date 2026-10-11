import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

/// Tiny leveled logger. Never pass secrets (passwords, tokens, proofs, SDP
/// with credentials, clipboard contents) to it.
class Logger {
  const Logger(this.tag);

  /// Minimum level that is emitted. Debug builds log everything; release
  /// builds keep warnings and errors so field reports are still diagnosable.
  static LogLevel minLevel = kDebugMode ? LogLevel.debug : LogLevel.warn;

  /// Test hook: receives every emitted line instead of `debugPrint`.
  static void Function(LogLevel level, String line)? sink;

  final String tag;

  void d(String message) => _emit(LogLevel.debug, message);
  void i(String message) => _emit(LogLevel.info, message);
  void w(String message, [Object? error]) => _emit(LogLevel.warn, message, error);
  void e(String message, [Object? error, StackTrace? stack]) =>
      _emit(LogLevel.error, message, error, stack);

  void _emit(LogLevel level, String message, [Object? error, StackTrace? stack]) {
    if (level.index < minLevel.index) return;
    final buffer = StringBuffer('[${level.name}] $tag: $message');
    if (error != null) buffer.write(' ($error)');
    if (stack != null && kDebugMode) buffer.write('\n$stack');
    final line = buffer.toString();
    final s = sink;
    if (s != null) {
      s(level, line);
    } else {
      debugPrint(line);
    }
  }
}
