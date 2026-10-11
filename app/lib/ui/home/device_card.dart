import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity.dart';
import '../../core/settings.dart';
import '../../core/thelxis_id.dart';
import '../../net/connectivity/connectivity.dart';
import '../../platform/host_platform.dart';
import '../../session/host_credentials.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/hover_tint.dart';
import '../widgets/thelxis_logo.dart';
import '../widgets/rows.dart';
import '../widgets/surface.dart';
import '../../net/discovery.dart';
import 'reachability.dart';
import 'reachability_advice.dart';
import 'share_access_dialog.dart';
import '../../l10n/strings.dart';

/// "This device": the Thelxis ID, the one-time password, reachability, the
/// allow-incoming switch and Share access, in one flat card.
class DeviceCard extends StatefulWidget {
  const DeviceCard({super.key, required this.onShowDiagnostics});

  final VoidCallback onShowDiagnostics;

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool _showOtp = false;
  LanDiscovery? _lan;
  Connectivity? _connectivity;
  AppSettings? _settings;
  bool _browsing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lan ??= context.read<LanDiscovery>();
    final c = context.read<Connectivity>();
    if (!identical(c, _connectivity)) {
      _connectivity?.report.removeListener(_syncBrowsing);
      _connectivity = c..report.addListener(_syncBrowsing);
    }
    _settings ??= context.read<AppSettings>()..addListener(_syncBrowsing);
    _syncBrowsing();
  }

  /// While this device is not reachable from the internet by itself, look for
  /// an office gateway on the network (PROTOCOL.md section 11): the answer
  /// decides the status shown here and the `g=` addresses in invites.
  void _syncBrowsing() {
    final lan = _lan;
    final c = _connectivity;
    final st = _settings;
    if (lan == null || c == null || st == null) return;
    final direct = adviseReachability(
      allowIncoming: st.allowIncoming,
      report: c.report.value,
      upnpEnabled: st.upnp,
    );
    final need = st.allowIncoming && !direct.reachable;
    if (need && !_browsing) {
      _browsing = true;
      lan.acquireBrowsing();
    } else if (!need && _browsing) {
      _browsing = false;
      lan.releaseBrowsing();
    }
  }

  @override
  void dispose() {
    _connectivity?.report.removeListener(_syncBrowsing);
    _settings?.removeListener(_syncBrowsing);
    if (_browsing) _lan?.releaseBrowsing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final c = context.c;
    final t = Theme.of(context).textTheme;
    final identity = context.read<Identity>();
    final settings = context.watch<AppSettings>();
    final connectivity = context.read<Connectivity>();
    final platform = context.read<HostPlatform>();
    final id = formatThelxisId(identity.id);
    final compact = MediaQuery.sizeOf(context).width < 480;

    return AppCard(
      padding: EdgeInsets.all(compact ? Gap.l : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, compact, settings, connectivity),
          const SizedBox(height: Gap.l),
          Text(s.t('home.yourId'), style: t.labelMedium?.copyWith(color: c.textSecondary)),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SelectableText(id, style: context.idStyle),
                ),
              ),
              const SizedBox(width: Gap.xs),
              IconButton(
                tooltip: s.t('home.copyId'),
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => copyToClipboard(context, id, s.t('home.idNoun')),
              ),
            ],
          ),
          ReachabilityHint(
            connectivity: connectivity,
            allowIncoming: settings.allowIncoming,
            upnpEnabled: settings.upnp,
            onTap: widget.onShowDiagnostics,
          ),
          const SizedBox(height: Gap.l),
          _OneTimePassword(
            visible: _showOtp,
            onToggle: () => setState(() => _showOtp = !_showOtp),
          ),
          const SizedBox(height: Gap.s),
          _IncomingSwitch(
            value: settings.allowIncoming,
            supported: platform.hostSupported,
            onChanged: settings.setAllowIncoming,
          ),
          const SizedBox(height: Gap.m),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              style: context.secondaryButton,
              onPressed: () => showShareAccessDialog(context),
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(s.t('home.share')),
            ),
          ),
        ],
      ),
    );
  }
}

extension on _DeviceCardState {
  Widget _header(BuildContext context, bool compact, AppSettings settings, Connectivity connectivity) {
    final s = context.s;
    final c = context.c;
    final t = Theme.of(context).textTheme;
    final pill = ReachabilityPill(
      connectivity: connectivity,
      allowIncoming: settings.allowIncoming,
      upnpEnabled: settings.upnp,
      onWhy: widget.onShowDiagnostics,
    );
    final names = Row(
      children: [
        const ThelxisLogo(size: 32),
        const SizedBox(width: Gap.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('home.thisDevice'), style: t.labelMedium?.copyWith(color: c.textSecondary)),
              const SizedBox(height: 2),
              Text(settings.deviceName, style: t.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
    // On a phone the status pill gets its own line so the name is not cut.
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [names, const SizedBox(height: Gap.s), pill],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: names),
        const SizedBox(width: Gap.m),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: pill),
      ],
    );
  }
}

class _IncomingSwitch extends StatelessWidget {
  const _IncomingSwitch({required this.value, required this.supported, required this.onChanged});

  final bool value;
  final bool supported;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final c = context.c;
    return HoverTint(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(Radii.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.t('home.allowIncoming'),
                    style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    supported ? s.t('home.allowIncoming.hint') : s.t('home.allowIncoming.unsupported'),
                    style: t.bodySmall?.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.m),
            AppSwitch(value: value, onChanged: onChanged),
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
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final c = context.c;
    final creds = context.watch<HostCredentials>();
    final pw = creds.oneTimePassword;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.inset, borderRadius: BorderRadius.circular(Radii.control)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, 6, Gap.xs, 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.t('home.otp'), style: t.labelSmall?.copyWith(color: c.textSecondary)),
                  const SizedBox(height: 1),
                  Text(
                    visible ? pw : '••••••••',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleMedium?.copyWith(
                      fontFamilyFallback: visible ? const ['Menlo', 'Consolas', 'Roboto Mono'] : null,
                      letterSpacing: 2,
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: visible ? s.t('home.otp.hide') : s.t('home.otp.show'),
              icon: Icon(visible ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
              onPressed: onToggle,
            ),
            IconButton(
              tooltip: s.t('home.otp.copy'),
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () => copyToClipboard(context, pw, s.t('home.otp.noun')),
            ),
            IconButton(
              tooltip: s.t('home.otp.refresh'),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: creds.rotate,
            ),
          ],
        ),
      ),
    );
  }
}
