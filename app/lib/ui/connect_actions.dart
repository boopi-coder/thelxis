import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../net/connect_target.dart';
import '../session/session_manager.dart';
import 'shell_controller.dart';
import 'widgets/common.dart';

/// Connects to [target] and brings the new session to the front, or (reverse)
/// offers control of this device. Returns a user-facing error message, or null
/// on success or when the user cancelled.
Future<String?> runConnect(
  BuildContext context,
  ConnectTarget target, {
  bool viewOnly = false,
  bool reverse = false,
}) async {
  final manager = context.read<SessionManager>();
  final shell = context.read<ShellController>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (reverse) {
      await manager.offerControl(target);
      messenger?.showSnackBar(SnackBar(content: Text(S.current.t('connect.offered'))));
    } else {
      final session = await manager.connect(target, viewOnly: viewOnly);
      shell.showSession(session);
    }
    return null;
  } on ConnectException catch (e) {
    return e.cancelled ? null : e.message;
  }
}

/// Like [runConnect] but reports failures in a snackbar.
Future<void> runConnectWithFeedback(
  BuildContext context,
  ConnectTarget target, {
  bool viewOnly = false,
  bool reverse = false,
}) async {
  final error = await runConnect(context, target, viewOnly: viewOnly, reverse: reverse);
  if (error != null && context.mounted) showMessage(context, error);
}
