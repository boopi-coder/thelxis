import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/identity.dart';
import '../../core/settings.dart';
import '../../core/system_info.dart';
import '../../desktop/desktop_integration.dart';
import '../../session/host_credentials.dart';
import '../home/diagnostics_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'permanent_password_dialog.dart';
import 'trusted_devices_section.dart';

/// Security, connectivity, appearance, startup and about.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final creds = context.watch<HostCredentials>();
    final desktop = context.read<DesktopIntegration>();
    final info = context.read<SystemInfo>();
    final identity = context.read<Identity>();
    final perms = s.defaultPermissions;

    return PageScroll(
      maxWidth: 760,
      children: [
        const SectionHeader('Device'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: _DeviceNameField(initial: s.deviceName, onSaved: s.setDeviceName),
          ),
        ),
        const SectionHeader('Security'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.password_rounded),
                title: const Text('Permanent password'),
                subtitle: Text(s.hasPermanentPassword ? 'Set — for unattended access' : 'Not set'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => showPermanentPasswordDialog(context, creds),
                      child: Text(s.hasPermanentPassword ? 'Change' : 'Set'),
                    ),
                    if (s.hasPermanentPassword)
                      TextButton(onPressed: creds.clearPermanentPassword, child: const Text('Remove')),
                  ],
                ),
              ),
              const Divider(),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.how_to_reg_outlined),
                title: const Text('Ask before every connection'),
                subtitle: const Text('Even with the right password, someone here must accept.'),
                value: s.requireApproval,
                onChanged: s.setRequireApproval,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.autorenew_rounded),
                title: const Text('New one-time password after each session'),
                value: s.rotateOneTimePassword,
                onChanged: s.setRotateOneTimePassword,
              ),
              const Divider(),
              const Padding(
                padding: EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, 0),
                child: Align(alignment: Alignment.centerLeft, child: Text('Default permissions')),
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.mouse_outlined),
                title: const Text('Allow control (mouse and keyboard)'),
                subtitle: const Text('Off means viewers can only watch.'),
                value: perms.control,
                onChanged: (v) => s.setDefaultPermissions(perms.copyWith(control: v)),
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.content_paste_rounded),
                title: const Text('Allow clipboard sync'),
                value: perms.clipboard,
                onChanged: (v) => s.setDefaultPermissions(perms.copyWith(clipboard: v)),
              ),
            ],
          ),
        ),
        const SectionHeader('Trusted devices'),
        const Card(child: TrustedDevicesSection()),
        const SectionHeader('Connectivity'),
        Card(
          child: Column(
            children: [
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.login_rounded),
                title: const Text('Allow incoming connections'),
                subtitle: const Text('Turning this off also stops UPnP mapping and the embedded relay.'),
                value: s.allowIncoming,
                onChanged: s.setAllowIncoming,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.router_outlined),
                title: const Text('Automatic port mapping (UPnP, NAT-PMP)'),
                subtitle: const Text('Asks your router to make this device reachable from the internet.'),
                value: s.upnp,
                onChanged: s.allowIncoming ? s.setUpnp : null,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.wifi_find_rounded),
                title: const Text('Show this device on the local network'),
                subtitle: const Text('Answers discovery requests from other Thelxis apps on your LAN.'),
                value: s.lanDiscovery,
                onChanged: s.setLanDiscovery,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.public_rounded),
                title: const Text('Use a public STUN server'),
                subtitle: const Text(
                  'Off by default. Helps when both sides are behind NAT, but tells the '
                  'STUN server (Google) your IP address. No media or content is sent.',
                ),
                value: s.publicStun,
                onChanged: s.setPublicStun,
              ),
              ListTile(
                leading: const Icon(Icons.network_check_rounded),
                title: const Text('Diagnostics'),
                subtitle: const Text('Why can or can\'t others reach this device?'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
                ),
              ),
            ],
          ),
        ),
        const SectionHeader('Appearance'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) => s.setThemeMode(v.first),
            ),
          ),
        ),
        if (desktop.isDesktop) ...[
          const SectionHeader('Startup'),
          Card(
            child: SwitchListTile.adaptive(
              secondary: const Icon(Icons.power_settings_new_rounded),
              title: const Text('Start Thelxis when I sign in'),
              subtitle: const Text('Keeps this device reachable after a restart.'),
              value: s.launchAtStartup,
              onChanged: (v) async {
                await s.setLaunchAtStartup(v);
                await desktop.setLaunchAtStartup(v);
              },
            ),
          ),
        ],
        const SectionHeader('About'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('Thelxis'),
                subtitle: Text('Version ${info.appVersion} · ${info.os} ${info.arch}'),
              ),
              ListTile(
                leading: const Icon(Icons.fingerprint_rounded),
                title: const Text('Your Thelxis ID'),
                subtitle: Text(identity.formattedId),
                trailing: IconButton(
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => copyToClipboard(context, identity.formattedId, 'ID'),
                ),
              ),
              const ListTile(
                leading: Icon(Icons.lock_outline_rounded),
                title: Text('No servers, no accounts'),
                subtitle: Text(
                  'Devices connect directly and everything is end-to-end encrypted. '
                  'Your identity key never leaves this device.',
                ),
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
    return TextField(
      controller: _c,
      maxLength: 48,
      onSubmitted: widget.onSaved,
      onTapOutside: (_) => widget.onSaved(_c.text),
      decoration: const InputDecoration(
        labelText: 'Device name',
        helperText: 'Shown to the people who connect to this device.',
        counterText: '',
        prefixIcon: Icon(Icons.badge_outlined),
      ),
    );
  }
}
