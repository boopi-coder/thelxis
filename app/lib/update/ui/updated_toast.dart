import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'update_links.dart';
import 'update_strings.dart';

/// Floating confirmation shown once after the app restarted into a new
/// version (the `--updated` launch flag). Does nothing without a Scaffold.
void showUpdatedToast(BuildContext context, String version) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final strings = UpdateStrings.of(context);
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: context.status.good, size: 20),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(strings.updatedTo(version))),
          ],
        ),
        action: SnackBarAction(
          label: strings.whatsNew,
          textColor: scheme.inversePrimary,
          onPressed: () => openUpdateLink(releaseUrl(version)),
        ),
      ),
    );
}
