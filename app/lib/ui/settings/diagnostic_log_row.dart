import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/log_file.dart';
import '../../files/files.dart' show revealInFolder;
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/rows.dart';

/// Opens the folder that contains a file; injectable for tests.
typedef RevealFolder = Future<void> Function(BuildContext context, String filePath);

/// "Diagnostic log" row in About: show the logs folder (desktop), copy the
/// recent lines (the main route on Android, where the folder is private),
/// or clear the log. Hidden when file logging is off.
class DiagnosticLogRow extends StatelessWidget {
  const DiagnosticLogRow({super.key, this.log, this.showFolder, this.reveal = revealInFolder});

  /// Defaults to [LogFile.instance].
  final LogFile? log;

  /// Defaults to desktop platforms; Android has no file manager for app data.
  final bool? showFolder;
  final RevealFolder reveal;

  static const copyLines = 200;

  @override
  Widget build(BuildContext context) {
    final log = this.log ?? LogFile.instance;
    if (log == null) return const SizedBox.shrink();
    final s = context.s;
    final folder = showFolder ?? (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    return SettingsRow(
      icon: Icons.receipt_long_outlined,
      title: s.t('settings.log'),
      subtitle: s.t('settings.log.hint'),
      stackTrailingBelow: 560,
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (folder)
            TextButton(
              key: const ValueKey('log-folder'),
              onPressed: () async {
                await log.flush();
                if (context.mounted) await reveal(context, log.current.path);
              },
              child: Text(s.t('settings.log.folder')),
            ),
          TextButton(
            key: const ValueKey('log-copy'),
            onPressed: () => _copy(context, log),
            child: Text(s.t('settings.log.copy')),
          ),
          TextButton(
            key: const ValueKey('log-clear'),
            style: TextButton.styleFrom(foregroundColor: context.c.danger),
            onPressed: () async {
              await log.clear();
              if (context.mounted) showMessage(context, context.s.t('settings.log.cleared'));
            },
            child: Text(s.t('settings.log.clear')),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, LogFile log) async {
    final text = await log.tail(lines: copyLines);
    if (!context.mounted) return;
    final s = context.s;
    if (text.isEmpty) {
      showMessage(context, s.t('settings.log.empty'));
    } else {
      await copyToClipboard(context, text, s.t('settings.log'));
    }
  }
}
