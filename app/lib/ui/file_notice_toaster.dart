import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../files/files.dart';
import '../session/session_manager.dart';

/// Shows file-transfer events ("Alice sent report.pdf") as snackbars. A burst
/// (a folder with many files) is thinned out to at most one toast per kind
/// every 700 ms so the screen does not flicker.
class FileNoticeToaster extends StatefulWidget {
  const FileNoticeToaster({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<FileNoticeToaster> createState() => _FileNoticeToasterState();
}

class _FileNoticeToasterState extends State<FileNoticeToaster> {
  StreamSubscription<FileNotice>? _sub;
  SessionManager? _manager;
  final Map<FileTransferEventKind, DateTime> _lastShown = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final m = context.read<SessionManager>();
    if (!identical(m, _manager)) {
      unawaited(_sub?.cancel());
      _manager = m;
      _sub = m.fileNotices.listen(_onNotice);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _onNotice(FileNotice notice) {
    final manager = _manager;
    if (manager == null) return;
    final text = notice.text(FilesStrings.forLanguage(manager.languageCode));
    if (text == null) return;
    final now = DateTime.now();
    final last = _lastShown[notice.event.kind];
    if (last != null && now.difference(last) < const Duration(milliseconds: 700)) return;
    _lastShown[notice.event.kind] = now;
    // The Scaffold's messenger lives above the navigator's overlay.
    final ctx = widget.navigatorKey.currentState?.overlay?.context;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          duration: const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
