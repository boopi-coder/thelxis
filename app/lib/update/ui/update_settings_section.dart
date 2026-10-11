import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../update_service.dart';
import 'update_links.dart';
import 'update_strings.dart';

/// Settings -> About block for updates: version, last check, "Check now",
/// the two switches, current state / error and a link to the release notes.
///
/// Renders inside its own [Card] like the other settings sections; pass
/// `card: false` to get the bare rows for embedding into an existing card.
class UpdateSettingsSection extends StatelessWidget {
  const UpdateSettingsSection({super.key, required this.service, this.card = true});

  final UpdateService service;
  final bool card;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final rows = _Rows(service: service, strings: UpdateStrings.of(context));
        return card ? Card(clipBehavior: Clip.antiAlias, child: rows) : rows;
      },
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.service, required this.strings});

  final UpdateService service;
  final UpdateStrings strings;

  bool get _checking => service.state == UpdateState.checking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = service.error;
    final showError = error != null &&
        (service.state == UpdateState.error || service.errorPhase == UpdatePhase.check);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(_statusIcon(context), color: _statusColor(context)),
          title: Text(strings.version(service.currentVersion)),
          subtitle: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(_status(), key: ValueKey(_status())),
          ),
          trailing: _action(),
        ),
        if (showError)
          ListTile(
            dense: true,
            leading: Icon(Icons.error_outline_rounded, color: scheme.error),
            title: Text(
              strings.errorMessage(error.kind),
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.autorenew_rounded),
          title: Text(strings.autoCheckTitle),
          subtitle: Text(strings.autoCheckSubtitle),
          value: service.autoCheck,
          onChanged: service.setAutoCheck,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.download_done_rounded),
          title: Text(strings.autoInstallTitle),
          subtitle: Text(strings.autoInstallSubtitle),
          value: service.autoInstall,
          onChanged: service.autoCheck ? service.setAutoInstall : null,
        ),
        ListTile(
          leading: const Icon(Icons.notes_rounded),
          title: Text(strings.releaseNotes),
          subtitle: Text(strings.releaseNotesSubtitle),
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => openUpdateLink(service.notesUrl ?? latestReleaseUrl()),
        ),
      ],
    );
  }

  Widget _action() {
    final busy = _checking ||
        service.state == UpdateState.downloading ||
        service.state == UpdateState.verifying ||
        service.state == UpdateState.installing;
    final version = service.availableVersion;
    if (service.state == UpdateState.available && version != null) {
      return FilledButton(onPressed: service.downloadAndInstall, child: Text(strings.update));
    }
    return FilledButton.tonal(
      onPressed: busy ? null : service.checkNow,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: _checking
            ? const SizedBox(
                key: ValueKey('spinner'),
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(strings.checkNow, key: const ValueKey('label')),
      ),
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

  Color? _statusColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (service.state) {
      case UpdateState.upToDate:
        return context.status.good;
      case UpdateState.error:
        return scheme.error;
      case UpdateState.available:
      case UpdateState.downloading:
      case UpdateState.verifying:
      case UpdateState.ready:
      case UpdateState.installing:
      case UpdateState.manualInstallRequired:
        return scheme.primary;
      case UpdateState.checking:
      case UpdateState.idle:
        return null;
    }
  }
}
