import 'manual_forwarding_section.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity.dart';
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
import 'permanent_password_dialog.dart';
import 'trusted_devices_section.dart';

/// Security, connectivity, appearance, startup and about.
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

    return PageScroll(
      maxWidth: 760,
      children: [
        PageTitle(s.t('settings.title')),
        SectionHeader(s.t('settings.device')),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: _DeviceNameField(initial: st.deviceName, onSaved: st.setDeviceName),
          ),
        ),
        SectionHeader(s.t('settings.security')),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.password_rounded),
                title: Text(s.t('settings.permanent')),
                subtitle: Text(st.hasPermanentPassword ? s.t('settings.permanent.set') : s.t('settings.permanent.unset')),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => showPermanentPasswordDialog(context, creds),
                      child: Text(st.hasPermanentPassword ? s.t('settings.permanent.change') : s.t('settings.permanent.setBtn')),
                    ),
                    if (st.hasPermanentPassword)
                      TextButton(
                        onPressed: creds.clearPermanentPassword,
                        child: Text(s.t('settings.permanent.remove')),
                      ),
                  ],
                ),
              ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.how_to_reg_outlined),
                title: Text(s.t('settings.approval')),
                subtitle: Text(s.t('settings.approval.hint')),
                value: st.requireApproval,
                onChanged: st.setRequireApproval,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.autorenew_rounded),
                title: Text(s.t('settings.rotate')),
                value: st.rotateOneTimePassword,
                onChanged: st.setRotateOneTimePassword,
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, 0),
                child: Align(alignment: Alignment.centerLeft, child: Text(s.t('settings.defaults'))),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.mouse_outlined),
                title: Text(s.t('settings.defaults.control')),
                subtitle: Text(s.t('settings.defaults.control.hint')),
                value: perms.control,
                onChanged: (v) => st.setDefaultPermissions(perms.copyWith(control: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.content_paste_rounded),
                title: Text(s.t('settings.defaults.clipboard')),
                value: perms.clipboard,
                onChanged: (v) => st.setDefaultPermissions(perms.copyWith(clipboard: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.folder_copy_outlined),
                title: Text(s.t('settings.defaults.files')),
                value: perms.files,
                onChanged: (v) => st.setDefaultPermissions(perms.copyWith(files: v)),
              ),
            ],
          ),
        ),
        SectionHeader(s.t('settings.trusted')),
        const Card(child: TrustedDevicesSection()),
        SectionHeader(s.t('settings.connectivity')),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.login_rounded),
                title: Text(s.t('settings.incoming')),
                subtitle: Text(s.t('settings.incoming.hint')),
                value: st.allowIncoming,
                onChanged: st.setAllowIncoming,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.router_outlined),
                title: Text(s.t('settings.upnp')),
                subtitle: Text(s.t('settings.upnp.hint')),
                value: st.upnp,
                onChanged: st.allowIncoming ? st.setUpnp : null,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.wifi_find_rounded),
                title: Text(s.t('settings.lan')),
                subtitle: Text(s.t('settings.lan.hint')),
                value: st.lanDiscovery,
                onChanged: st.setLanDiscovery,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.public_rounded),
                title: Text(s.t('settings.stun')),
                subtitle: Text(s.t('settings.stun.hint')),
                value: st.publicStun,
                onChanged: st.setPublicStun,
              ),
              const ManualForwardingSection(),
              ListTile(
                leading: const Icon(Icons.network_check_rounded),
                title: Text(s.t('settings.diagnostics')),
                subtitle: Text(s.t('settings.diagnostics.hint')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
                ),
              ),
            ],
          ),
        ),
        SectionHeader(s.t('settings.appearance')),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.t('settings.theme'), style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: Gap.s),
                SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode_outlined), label: Text(s.t('settings.theme.dark'))),
                    ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode_outlined), label: Text(s.t('settings.theme.light'))),
                    ButtonSegment(value: ThemeMode.system, icon: const Icon(Icons.brightness_auto_outlined), label: Text(s.t('settings.theme.system'))),
                  ],
                  selected: {st.themeMode},
                  onSelectionChanged: (v) => st.setThemeMode(v.first),
                ),
                const SizedBox(height: Gap.l),
                Text(s.t('settings.language'), style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: Gap.s),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: kLanguageSystem, icon: const Icon(Icons.translate_rounded), label: Text(s.t('settings.language.system'))),
                    const ButtonSegment(value: 'en', label: Text('English')),
                    const ButtonSegment(value: 'ru', label: Text('Русский')),
                  ],
                  selected: {st.language},
                  onSelectionChanged: (v) => st.setLanguage(v.first),
                ),
              ],
            ),
          ),
        ),
        if (desktop.isDesktop) ...[
          SectionHeader(s.t('settings.startup')),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.power_settings_new_rounded),
              title: Text(s.t('settings.autostart')),
              subtitle: Text(s.t('settings.autostart.hint')),
              value: st.launchAtStartup,
              onChanged: (v) async {
                await st.setLaunchAtStartup(v);
                await desktop.setLaunchAtStartup(v);
              },
            ),
          ),
        ],
        SectionHeader(s.t('settings.updates')),
        UpdateSettingsSection(service: context.read<UpdateService>()),
        SectionHeader(s.t('settings.about')),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('Thelxis'),
                subtitle: Text(s.t('settings.version', {'version': info.appVersion, 'os': info.os, 'arch': info.arch})),
              ),
              ListTile(
                leading: const Icon(Icons.fingerprint_rounded),
                title: Text(s.t('home.yourId')),
                subtitle: Text(identity.formattedId),
                trailing: IconButton(
                  tooltip: s.t('common.copy'),
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => copyToClipboard(context, identity.formattedId, s.t('home.idNoun')),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline_rounded),
                title: Text(s.t('settings.noServers')),
                subtitle: Text(s.t('settings.noServers.hint')),
              ),
            ],
          ),
        ),
      ],
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
        prefixIcon: const Icon(Icons.badge_outlined),
      ),
    );
  }
}
