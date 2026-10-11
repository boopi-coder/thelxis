import 'manual_forwarding_section.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity.dart';
import '../../core/links.dart';
import '../../core/settings.dart';
import '../../core/system_info.dart';
import '../../desktop/desktop_integration.dart';
import '../../l10n/strings.dart';
import '../../session/host_credentials.dart';
import '../home/diagnostics_screen.dart';
import '../../update/ui/update_settings_section.dart';
import '../../update/update_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/rows.dart';
import '../widgets/thelxis_logo.dart';
import 'permanent_password_dialog.dart';
import 'trusted_devices_section.dart';

/// Security, connectivity, appearance, startup and about, as grouped cards
/// of rows in the manner of System Settings.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final st = context.watch<AppSettings>();
    final creds = context.watch<HostCredentials>();
    final desktop = context.read<DesktopIntegration>();
    final info = context.read<SystemInfo>();
    final identity = context.read<Identity>();
    final perms = st.defaultPermissions;
    const gap = SizedBox(height: Gap.xl);

    return PageScroll(
      maxWidth: 820,
      children: [
        PageTitle(s.t('settings.title')),
        const SizedBox(height: Gap.l),
        SettingsGroup(
          title: s.t('settings.device'),
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: _DeviceNameField(initial: st.deviceName, onSaved: st.setDeviceName),
            ),
          ],
        ),
        gap,
        SettingsGroup(
          title: s.t('settings.security'),
          children: [
            SettingsRow(
              icon: Icons.password_rounded,
              title: s.t('settings.permanent'),
              subtitle: st.hasPermanentPassword ? s.t('settings.permanent.set') : s.t('settings.permanent.unset'),
              trailing: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => showPermanentPasswordDialog(context, creds),
                    child: Text(
                      st.hasPermanentPassword ? s.t('settings.permanent.change') : s.t('settings.permanent.setBtn'),
                    ),
                  ),
                  if (st.hasPermanentPassword)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: context.c.danger),
                      onPressed: creds.clearPermanentPassword,
                      child: Text(s.t('settings.permanent.remove')),
                    ),
                ],
              ),
            ),
            SwitchRow(
              icon: Icons.how_to_reg_outlined,
              title: s.t('settings.approval'),
              subtitle: s.t('settings.approval.hint'),
              value: st.requireApproval,
              onChanged: st.setRequireApproval,
            ),
            SwitchRow(
              icon: Icons.autorenew_rounded,
              title: s.t('settings.rotate'),
              value: st.rotateOneTimePassword,
              onChanged: st.setRotateOneTimePassword,
            ),
          ],
        ),
        gap,
        SettingsGroup(
          title: s.t('settings.defaults'),
          children: [
            SwitchRow(
              icon: Icons.mouse_outlined,
              title: s.t('settings.defaults.control'),
              subtitle: s.t('settings.defaults.control.hint'),
              value: perms.control,
              onChanged: (v) => st.setDefaultPermissions(perms.copyWith(control: v)),
            ),
            SwitchRow(
              icon: Icons.content_paste_rounded,
              title: s.t('settings.defaults.clipboard'),
              value: perms.clipboard,
              onChanged: (v) => st.setDefaultPermissions(perms.copyWith(clipboard: v)),
            ),
            SwitchRow(
              icon: Icons.folder_copy_outlined,
              title: s.t('settings.defaults.files'),
              value: perms.files,
              onChanged: (v) => st.setDefaultPermissions(perms.copyWith(files: v)),
            ),
          ],
        ),
        gap,
        SettingsGroup(title: s.t('settings.trusted'), children: const [TrustedDevicesSection()]),
        gap,
        SettingsGroup(
          title: s.t('settings.connectivity'),
          children: [
            SwitchRow(
              icon: Icons.login_rounded,
              title: s.t('settings.incoming'),
              subtitle: s.t('settings.incoming.hint'),
              value: st.allowIncoming,
              onChanged: st.setAllowIncoming,
            ),
            SwitchRow(
              icon: Icons.router_outlined,
              title: s.t('settings.upnp'),
              subtitle: s.t('settings.upnp.hint'),
              value: st.upnp,
              onChanged: st.allowIncoming ? st.setUpnp : null,
            ),
            SwitchRow(
              icon: Icons.wifi_find_rounded,
              title: s.t('settings.lan'),
              subtitle: s.t('settings.lan.hint'),
              value: st.lanDiscovery,
              onChanged: st.setLanDiscovery,
            ),
            SwitchRow(
              icon: Icons.public_rounded,
              title: s.t('settings.stun'),
              subtitle: s.t('settings.stun.hint'),
              value: st.publicStun,
              onChanged: st.setPublicStun,
            ),
            const ManualForwardingSection(),
            SwitchRow(
              key: const ValueKey('gateway-switch'),
              icon: Icons.hub_outlined,
              title: s.t('settings.gateway'),
              subtitle: s.t('settings.gateway.hint'),
              value: st.officeGateway,
              onChanged: st.allowIncoming ? st.setOfficeGateway : null,
            ),
            SettingsRow(
              icon: Icons.network_check_rounded,
              title: s.t('settings.diagnostics'),
              subtitle: s.t('settings.diagnostics.hint'),
              trailing: Icon(Icons.chevron_right_rounded, color: context.c.textMuted),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
              ),
            ),
          ],
        ),
        gap,
        SettingsGroup(
          title: s.t('settings.appearance'),
          children: [
            SettingsRow(
              icon: Icons.contrast_rounded,
              title: s.t('settings.theme'),
              stackTrailingBelow: 460,
              trailing: AppSegmented<ThemeMode>(
                options: [
                  (ThemeMode.system, s.t('settings.theme.system'), null),
                  (ThemeMode.light, s.t('settings.theme.light'), null),
                  (ThemeMode.dark, s.t('settings.theme.dark'), null),
                ],
                selected: st.themeMode,
                onChanged: st.setThemeMode,
              ),
            ),
            SettingsRow(
              icon: Icons.translate_rounded,
              title: s.t('settings.language'),
              stackTrailingBelow: 460,
              trailing: AppSegmented<String>(
                options: [
                  (kLanguageSystem, s.t('settings.language.system'), null),
                  ('en', 'English', null),
                  ('ru', 'Русский', null),
                ],
                selected: st.language,
                onChanged: st.setLanguage,
              ),
            ),
          ],
        ),
        if (desktop.isDesktop) ...[
          gap,
          SettingsGroup(
            title: s.t('settings.startup'),
            children: [
              SwitchRow(
                icon: Icons.power_settings_new_rounded,
                title: s.t('settings.autostart'),
                subtitle: s.t('settings.autostart.hint'),
                value: st.launchAtStartup,
                onChanged: (v) async {
                  await st.setLaunchAtStartup(v);
                  await desktop.setLaunchAtStartup(v);
                },
              ),
            ],
          ),
        ],
        gap,
        UpdateSettingsSection(service: context.read<UpdateService>(), title: s.t('settings.updates')),
        gap,
        SettingsGroup(
          title: s.t('settings.about'),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xl),
              child: Column(
                children: [
                  const ThelxisLogo(size: 64),
                  const SizedBox(height: Gap.m),
                  Text('Thelxis', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                    s.t('settings.version', {'version': info.appVersion, 'os': info.os, 'arch': info.arch}),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.c.textSecondary),
                  ),
                ],
              ),
            ),
            SettingsRow(
              icon: Icons.fingerprint_rounded,
              title: s.t('home.yourId'),
              subtitle: identity.formattedId,
              trailing: IconButton(
                tooltip: s.t('common.copy'),
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => copyToClipboard(context, identity.formattedId, s.t('home.idNoun')),
              ),
            ),
            SettingsRow(
              icon: Icons.lock_outline_rounded,
              title: s.t('settings.noServers'),
              subtitle: s.t('settings.noServers.hint'),
            ),
            const _SupportCard(),
          ],
        ),
      ],
    );
  }
}

/// "Support the author" block at the end of About: a plain secondary button
/// in the app's own style.
class _SupportCard extends StatelessWidget {
  const _SupportCard();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final c = context.c;
    return Padding(
      key: const ValueKey('support-card'),
      padding: const EdgeInsets.all(Gap.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_border_rounded, size: 18, color: c.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.t('support.title'), style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Text(s.t('support.body'), style: t.bodySmall?.copyWith(color: c.textSecondary)),
          ),
          const SizedBox(height: Gap.m),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: FilledButton.icon(
              onPressed: openBoosty,
              style: context.secondaryButton,
              icon: const Icon(Icons.favorite_border_rounded),
              label: Text(s.t('support.button')),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceNameField extends StatefulWidget {
  const _DeviceNameField({required this.initial, required this.onSaved});

  final String initial;
  final Future<void> Function(String) onSaved;

  @override
  State<_DeviceNameField> createState() => _DeviceNameFieldState();
}

class _DeviceNameFieldState extends State<_DeviceNameField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return TextField(
      controller: _c,
      maxLength: 48,
      onSubmitted: widget.onSaved,
      onTapOutside: (_) => widget.onSaved(_c.text),
      decoration: InputDecoration(
        labelText: s.t('settings.deviceName'),
        helperText: s.t('settings.deviceName.hint'),
        counterText: '',
      ),
    );
  }
}
