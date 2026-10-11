import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'update_links.dart';
import 'update_strings.dart';

/// Floating confirmation shown once after the app restarted into a new
/// version (the `--updated` launch flag). Does nothing without a Scaffold.
///
/// It closes by itself after a few seconds and has a close button: a
/// snackbar that carries an action would otherwise stay until swiped away
/// (Flutter's default for snackbars with an action), which left "what's new"
/// stuck on screen with no way to dismiss it.
void showUpdatedToast(BuildContext context, String version) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final strings = UpdateStrings.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        persist: false,
        showCloseIcon: true,
        duration: const Duration(seconds: 8),
        content: Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, color: context.c.success, size: 20),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(strings.updatedTo(version))),
          ],
        ),
        action: SnackBarAction(
          label: strings.whatsNew,
          onPressed: () => openUpdateLink(releaseUrl(version)),
        ),
      ),
    );
}
