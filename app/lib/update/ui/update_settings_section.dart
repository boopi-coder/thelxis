import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/rows.dart';
import '../../ui/widgets/surface.dart';
import '../update_service.dart';
import 'update_links.dart';
import 'update_strings.dart';

/// Settings -> Updates block: version, last check, "Check now", the two
/// switches, current state / error and a link to the release notes.
///
/// Renders as its own [SettingsGroup] like the other settings sections; pass
/// `card: false` to get the bare rows for embedding into an existing card.
class UpdateSettingsSection extends StatelessWidget {
  const UpdateSettingsSection({super.key, required this.service, this.card = true, this.title});

  final UpdateService service;
  final bool card;

  /// Group heading (only with [card]).
  final String? title;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final rows = _Rows(service: service, strings: UpdateStrings.of(context)).build(context);
        if (card) return SettingsGroup(title: title, children: rows);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, r) in rows.indexed) ...[if (i > 0) const Hairline(indent: 16), r],
          ],
        );
      },
    );
  }
}

class _Rows {
  const _Rows({required this.service, required this.strings});

  final UpdateService service;
  final UpdateStrings strings;

  bool get _checking => service.state == UpdateState.checking;

  List<Widget> build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.c;
    final error = service.error;
    final showError = error != null &&
        (service.state == UpdateState.error || service.errorPhase == UpdatePhase.check);

    return [
      SettingsRow(
        icon: _statusIcon(context),
        title: strings.version(service.currentVersion),
        subtitle: _status(),
        trailing: _action(context),
      ),
      if (showError)
        SettingsRow(
          icon: Icons.error_outline_rounded,
          title: strings.errorMessage(error.kind),
          titleColor: c.danger,
        ),
      SwitchRow(
        icon: Icons.autorenew_rounded,
        title: strings.autoCheckTitle,
        subtitle: strings.autoCheckSubtitle,
        value: service.autoCheck,
        onChanged: service.setAutoCheck,
      ),
      SwitchRow(
        icon: Icons.download_done_rounded,
        title: strings.autoInstallTitle,
        subtitle: strings.autoInstallSubtitle,
        value: service.autoInstall,
        onChanged: service.autoCheck ? service.setAutoInstall : null,
      ),
      SettingsRow(
        icon: Icons.notes_rounded,
        title: strings.releaseNotes,
        subtitle: strings.releaseNotesSubtitle,
        trailing: Icon(Icons.open_in_new_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
        onTap: () => openUpdateLink(service.notesUrl ?? latestReleaseUrl()),
      ),
    ];
  }

  Widget _action(BuildContext context) {
    final busy = _checking ||
        service.state == UpdateState.downloading ||
        service.state == UpdateState.verifying ||
        service.state == UpdateState.installing;
    final version = service.availableVersion;
    if (service.state == UpdateState.available && version != null) {
      return FilledButton(onPressed: service.downloadAndInstall, child: Text(strings.update));
    }
    return FilledButton(
      style: context.secondaryButton,
      onPressed: busy ? null : service.checkNow,
      child: _checking
          ? const SizedBox(
              key: ValueKey('spinner'),
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(strings.checkNow, key: const ValueKey('label')),
    );
  }

  String _status() {
    final version = service.availableVersion;
    switch (service.state) {
      case UpdateState.checking:
        return strings.checking;
      case UpdateState.available:
      case UpdateState.downloading:
      case UpdateState.verifying:
      case UpdateState.ready:
      case UpdateState.installing:
      case UpdateState.manualInstallRequired:
        if (version != null) return strings.statusAvailable(version);
        return strings.checkedAt(service.lastCheck);
      case UpdateState.upToDate:
        return '${strings.statusUpToDate} · ${strings.checkedAt(service.lastCheck)}';
      case UpdateState.idle:
      case UpdateState.error:
        final skipped = service.skippedVersion;
        if (service.state == UpdateState.idle && skipped != null) return strings.statusSkipped(skipped);
        return strings.checkedAt(service.lastCheck);
    }
  }

  IconData _statusIcon(BuildContext context) {
    switch (service.state) {
      case UpdateState.upToDate:
        return Icons.check_circle_rounded;
      case UpdateState.error:
        return Icons.error_outline_rounded;
      case UpdateState.checking:
        return Icons.sync_rounded;
      case UpdateState.available:
      case UpdateState.downloading:
      case UpdateState.verifying:
      case UpdateState.ready:
      case UpdateState.installing:
      case UpdateState.manualInstallRequired:
        return Icons.system_update_alt_rounded;
      case UpdateState.idle:
        return Icons.info_outline_rounded;
    }
  }
}
