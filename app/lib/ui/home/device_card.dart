import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../core/thelxis_id.dart';
import '../../net/connectivity/connectivity.dart';
import '../../platform/host_platform.dart';
import '../../session/host_credentials.dart';
import '../../core/identity.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/thelxis_logo.dart';
import 'reachability.dart';
import 'share_access_dialog.dart';

/// "This device": Thelxis ID, one-time password, reachability, allow-incoming
/// switch and the Share access button.
class DeviceCard extends StatefulWidget {
  const DeviceCard({super.key, required this.onShowDiagnostics});

  final VoidCallback onShowDiagnostics;

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool _showOtp = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final identity = context.read<Identity>();
    final settings = context.watch<AppSettings>();
    final connectivity = context.read<Connectivity>();
    final platform = context.read<HostPlatform>();
    final id = formatThelxisId(identity.id);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const ThelxisLogo(size: 40),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('This device', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      Text(settings.deviceName, style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.m),
            ReachabilityPill(
              connectivity: connectivity,
              allowIncoming: settings.allowIncoming,
              onWhy: widget.onShowDiagnostics,
            ),
            const SizedBox(height: Gap.xl),
            Text('Your Thelxis ID', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            Row(
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      id,
                      style: t.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy ID',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => copyToClipboard(context, id, 'ID'),
                ),
              ],
            ),
            const SizedBox(height: Gap.l),
            _OneTimePassword(
              visible: _showOtp,
              onToggle: () => setState(() => _showOtp = !_showOtp),
            ),
            const SizedBox(height: Gap.l),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow incoming connections'),
              subtitle: Text(
                platform.hostSupported
                    ? 'Lets other devices connect with your ID and password.'
                    : 'This device can connect to others but cannot be controlled.',
              ),
              value: settings.allowIncoming,
              onChanged: (v) => settings.setAllowIncoming(v),
            ),
            const SizedBox(height: Gap.s),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => showShareAccessDialog(context),
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('Share access'),
              ),
            ),
            _PermissionsNotice(platform: platform),
          ],
        ),
      ),
    );
  }
}

class _OneTimePassword extends StatelessWidget {
  const _OneTimePassword({required this.visible, required this.onToggle});

  final bool visible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final creds = context.watch<HostCredentials>();
    final pw = creds.oneTimePassword;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, Gap.s),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('One-time password', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(
                  visible ? pw : '••••••••',
                  style: t.textTheme.titleLarge?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: visible ? 'Hide' : 'Show',
            icon: Icon(visible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: onToggle,
          ),
          IconButton(
            tooltip: 'Copy password',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => copyToClipboard(context, pw, 'Password'),
          ),
          IconButton(
            tooltip: 'New password',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: creds.rotate,
          ),
        ],
      ),
    );
  }
}

/// Shows missing OS permissions (macOS Screen Recording / Accessibility,
/// Android accessibility service) with a button to grant them.
class _PermissionsNotice extends StatefulWidget {
  const _PermissionsNotice({required this.platform});

  final HostPlatform platform;

  @override
  State<_PermissionsNotice> createState() => _PermissionsNoticeState();
}

class _PermissionsNoticeState extends State<_PermissionsNotice> with WidgetsBindingObserver {
  Future<List<(HostPermission, String)>>? _missing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _missing = _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just granted a permission in system settings.
    if (state == AppLifecycleState.resumed) setState(() => _missing = _load());
  }

  Future<List<(HostPermission, String)>> _load() async {
    if (!widget.platform.hostSupported) return const [];
    const labels = {
      HostPermission.screenCapture: 'Screen recording permission is needed to share this screen.',
      HostPermission.inputControl: 'Accessibility permission is needed to let others use the mouse and keyboard.',
    };
    final out = <(HostPermission, String)>[];
    for (final e in labels.entries) {
      try {
        if (await widget.platform.permissionStatus(e.key) == PermissionStatus.denied) {
          out.add((e.key, e.value));
        }
      } on Object {
        // An unavailable status check is not worth bothering the user about.
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<(HostPermission, String)>>(
      future: _missing,
      builder: (context, snap) {
        final missing = snap.data ?? const [];
        if (missing.isEmpty) return const SizedBox.shrink();
        final t = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(top: Gap.l),
          child: Column(
            children: [
              for (final m in missing)
                Container(
                  margin: const EdgeInsets.only(bottom: Gap.s),
                  padding: const EdgeInsets.all(Gap.m),
                  decoration: BoxDecoration(
                    color: context.status.warn.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: context.status.warn),
                      const SizedBox(width: Gap.m),
                      Expanded(child: Text(m.$2, style: t.textTheme.bodyMedium)),
                      TextButton(
                        onPressed: () async {
                          await widget.platform.requestPermission(m.$1);
                          if (mounted) setState(() => _missing = _load());
                        },
                        child: const Text('Grant'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
