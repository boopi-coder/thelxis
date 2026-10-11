import 'package:cryptography/dart.dart';

/// Streaming SHA-256 over a file's chunks.
///
/// Uses the pure-Dart implementation explicitly: its sink really is
/// incremental, whereas the generic `HashAlgorithm.newHashSink()` of other
/// `cryptography` backends buffers the whole input in memory.
class FileHasher {
  FileHasher() : _sink = const DartSha256().newHashSink();

  final DartHashSink _sink;
  String? _digest;

  void add(List<int> chunk) => _sink.add(chunk);

  /// Closes the hash and returns the lower-case hex digest. Idempotent.
  String finish() {
    final cached = _digest;
    if (cached != null) return cached;
    _sink.close();
    final bytes = _sink.hashSync().bytes;
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return _digest = buffer.toString();
  }
}
