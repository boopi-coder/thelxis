import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/log.dart';

const _log = Logger('clipboard');

/// PROTOCOL.md 5.2: clipboard messages carry at most 1 MiB.
const int kMaxClipboardBytes = 1 << 20;

/// What this build will actually send. The SCTP data channel of libwebrtc
/// rejects messages beyond ~256 KiB, so larger clipboards are skipped rather
/// than killing the control channel.
const int kMaxClipboardSendBytes = 200 * 1024;

/// Polls the system clipboard once per second and forwards changes, while
/// suppressing the echo of text that was just received from the peer.
class ClipboardSync {
  ClipboardSync({
    required this.onLocalChange,
    this.interval = const Duration(seconds: 1),
    Future<String?> Function()? readClipboard,
    Future<void> Function(String text)? writeClipboard,
  })  : _read = readClipboard ?? _systemRead,
        _write = writeClipboard ?? _systemWrite;

  final void Function(String text) onLocalChange;
  final Duration interval;
  final Future<String?> Function() _read;
  final Future<void> Function(String text) _write;

  Timer? _timer;
  String? _last;
  bool _busy = false;

  bool get running => _timer != null;

  /// Starts polling. The current clipboard content is taken as the baseline so
  /// it is not sent just because sync was switched on.
  Future<void> start() async {
    if (_timer != null) return;
    try {
      _last = await _read();
    } on Object catch (e) {
      _log.w('clipboard baseline read failed', e);
    }
    _timer = Timer.periodic(interval, (_) => poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One poll step; public so tests can drive it.
  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final text = await _read();
      if (text == null || text.isEmpty || text == _last) return;
      _last = text;
      if (utf8.encode(text).length > kMaxClipboardSendBytes) {
        _log.w('clipboard too large to sync, skipped');
        return;
      }
      onLocalChange(text);
    } on Object catch (e) {
      _log.w('clipboard poll failed', e);
    } finally {
      _busy = false;
    }
  }

  /// Applies text received from the peer without echoing it back.
  Future<void> applyRemote(String text) async {
    if (utf8.encode(text).length > kMaxClipboardBytes) {
      _log.w('remote clipboard exceeds limit, ignored');
      return;
    }
    _last = text;
    try {
      await _write(text);
    } on Object catch (e) {
      _log.w('clipboard write failed', e);
    }
  }

  void dispose() => stop();

  static Future<String?> _systemRead() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  static Future<void> _systemWrite(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
