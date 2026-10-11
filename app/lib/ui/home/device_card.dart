import 'dart:io' show Platform;

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
import '../widgets/thelxis_logo.dart';
import '../../net/discovery.dart';
import 'reachability.dart';
import 'reachability_advice.dart';
import 'share_access_dialog.dart';
import '../../l10n/strings.dart';

/// "This device": a violet hero card with the Thelxis ID, the one-time
/// password, reachability, the allow-incoming switch and Share access.
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
    final brand = context.brand;
    final t = Theme.of(context);
    final identity = context.read<Identity>();
    final settings = context.watch<AppSettings>();
    final connectivity = context.read<Connectivity>();
    final platform = context.read<HostPlatform>();
    final id = formatThelxisId(identity.id);
    final compact = MediaQuery.sizeOf(context).width < 420;
    final pad = compact ? Gap.l : Gap.xl;

    return Container(
      decoration: BoxDecoration(
        gradient: brand.hero,
        borderRadius: BorderRadius.circular(28),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Decorative frosted discs behind the content.
          Positioned(right: -60, top: -70, child: _Disc(size: 220, alpha: 0.10)),
          Positioned(left: -50, bottom: -80, child: _Disc(size: 200, alpha: 0.07)),
          Padding(
            padding: EdgeInsets.all(pad),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: brand.onHero),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: brand.glass,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: brand.glassBorder),
                        ),
                        child: const ThelxisLogo(size: 40),
                      ),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.t('home.thisDevice'),
                              style: t.textTheme.labelMedium?.copyWith(color: brand.onHeroMuted),
                            ),
                            Text(
                              settings.deviceName,
                              style: t.textTheme.titleMedium?.copyWith(color: brand.onHero),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.m),
                  ReachabilityPill(
                    connectivity: connectivity,
                    allowIncoming: settings.allowIncoming,
                    upnpEnabled: settings.upnp,
                    onWhy: widget.onShowDiagnostics,
                    onGradient: true,
                  ),
                  ReachabilityHint(
                    connectivity: connectivity,
                    allowIncoming: settings.allowIncoming,
                    upnpEnabled: settings.upnp,
                    onTap: widget.onShowDiagnostics,
                    color: brand.onHeroMuted,
                  ),
                  SizedBox(height: compact ? Gap.xl : Gap.xxl),
                  Text(
                    s.t('home.yourId').toUpperCase(),
                    style: t.textTheme.labelSmall?.copyWith(
                      color: brand.onHeroMuted,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
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
                              color: brand.onHero,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.6,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: s.t('home.copyId'),
                        color: brand.onHero,
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () => copyToClipboard(context, id, s.t('home.idNoun')),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.l),
                  _OneTimePassword(
                    visible: _showOtp,
                    onToggle: () => setState(() => _showOtp = !_showOtp),
                  ),
                  const SizedBox(height: Gap.l),
                  _IncomingSwitch(
                    value: settings.allowIncoming,
                    supported: platform.hostSupported,
                    onChanged: settings.setAllowIncoming,
                  ),
                  const SizedBox(height: Gap.l),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF4A2FC9),
                      ),
                      onPressed: () => showShareAccessDialog(context),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: Text(s.t('home.share')),
                    ),
                  ),
                  _PermissionsNotice(platform: platform),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Disc extends StatelessWidget {
  const _Disc({required this.size, required this.alpha});

  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: alpha),
        ),
      ),
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
    final brand = context.brand;
    final t = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('home.allowIncoming'), style: t.textTheme.titleSmall?.copyWith(color: brand.onHero)),
              const SizedBox(height: 2),
              Text(
                supported ? s.t('home.allowIncoming.hint') : s.t('home.allowIncoming.unsupported'),
                style: t.textTheme.bodySmall?.copyWith(color: brand.onHeroMuted),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeTrackColor: Colors.white,
          activeThumbColor: const Color(0xFF4A2FC9),
          inactiveTrackColor: Colors.white24,
          onChanged: onChanged,
        ),
      ],
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
    final brand = context.brand;
    final t = Theme.of(context);
    final creds = context.watch<HostCredentials>();
    final pw = creds.oneTimePassword;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.xs, Gap.s),
      radius: 16,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.t('home.otp'),
                  style: t.textTheme.labelMedium?.copyWith(color: brand.onHeroMuted),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                  child: Text(
                    visible ? pw : '••••••••',
                    key: ValueKey(visible ? pw : 'hidden'),
                    style: t.textTheme.titleLarge?.copyWith(
                      color: brand.onHero,
                      fontFamily: 'monospace',
                      letterSpacing: 3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: visible ? s.t('home.otp.hide') : s.t('home.otp.show'),
            color: brand.onHero,
            icon: Icon(visible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: onToggle,
          ),
          IconButton(
            tooltip: s.t('home.otp.copy'),
            color: brand.onHero,
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => copyToClipboard(context, pw, s.t('home.otp.noun')),
          ),
          IconButton(
            tooltip: s.t('home.otp.refresh'),
            color: brand.onHero,
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
  Future<List<HostPermission>>? _missing;

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

  Future<List<HostPermission>> _load() async {
    if (!widget.platform.hostSupported) return const [];
    final out = <HostPermission>[];
    for (final p in [HostPermission.screenCapture, HostPermission.inputControl]) {
      try {
        if (await widget.platform.permissionStatus(p) == PermissionStatus.denied) out.add(p);
      } on Object {
        // An unavailable status check is not worth bothering the user about.
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<HostPermission>>(
      future: _missing,
      builder: (context, snap) {
        final missing = snap.data ?? const [];
        if (missing.isEmpty) return const SizedBox.shrink();
        final s = context.s;
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
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: context.status.warn),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m == HostPermission.screenCapture
                                  ? s.t('perm.screen')
                                  : s.t('perm.input'),
                              style: t.textTheme.bodyMedium?.copyWith(color: Colors.black87),
                            ),
                            if (m == HostPermission.inputControl && Platform.isAndroid)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  s.t('perm.android.restricted'),
                                  style: t.textTheme.bodySmall?.copyWith(color: Colors.black54),
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await widget.platform.requestPermission(m);
                          if (mounted) setState(() => _missing = _load());
                        },
                        child: Text(s.t('perm.grant')),
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
