import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/address_book.dart';
import '../../l10n/strings.dart';
import '../../net/discovery.dart';
import '../shell_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/surface.dart';
import 'connect_card.dart';
import 'device_card.dart';
import 'devices_grid.dart';
import 'diagnostics_screen.dart';
import 'setup_card.dart';

/// Home: "This device" and "Connect" side by side, a compact "Setup needed"
/// card when something is missing, and the grid of known devices filling the
/// rest of the window. One column on phones.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.active = true});

  /// True while the page is visible: LAN discovery only broadcasts then.
  final bool active;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LanDiscovery? _lan;
  bool _browsing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lan ??= context.read<LanDiscovery>();
    _syncBrowsing();
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    _syncBrowsing();
  }

  void _syncBrowsing() {
    final lan = _lan;
    if (lan == null) return;
    if (widget.active && !_browsing) {
      _browsing = true;
      lan.acquireBrowsing();
    } else if (!widget.active && _browsing) {
      _browsing = false;
      lan.releaseBrowsing();
    }
  }

  @override
  void dispose() {
    if (_browsing) _lan?.releaseBrowsing();
    super.dispose();
  }

  void _diagnostics() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final devices = homeDevices(context.watch<AddressBook>(), context.watch<LanDiscovery>());
    return LayoutBuilder(
      builder: (context, box) {
        final gutter = pageGutter(box.maxWidth);
        final phone = box.maxWidth < kRailMinWidth;
        final contentWidth = box.maxWidth - 2 * gutter;
        final sideBySide = contentWidth >= 640;
        final device = DeviceCard(onShowDiagnostics: _diagnostics);
        final connect = const ConnectCard();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, phone ? 16 : 24, gutter, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SetupCard(),
                    if (sideBySide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: device),
                          const SizedBox(width: Gap.l),
                          Expanded(child: connect),
                        ],
                      )
                    else ...[
                      device,
                      const SizedBox(height: Gap.l),
                      connect,
                    ],
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xl, bottom: Gap.m),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(s.t('nav.devices'), style: Theme.of(context).textTheme.titleMedium),
                          ),
                          TextButton(
                            onPressed: () => context.read<ShellController>().goTo(ShellController.pageDevices),
                            child: Text(s.t('home.devices.all')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (devices.isEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
                sliver: SliverToBoxAdapter(
                  child: AppCard(
                    child: EmptyState(
                      logo: true,
                      icon: Icons.devices_other_outlined,
                      title: s.t('home.devices.empty'),
                      message: s.t('home.devices.empty.hint'),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
                sliver: DevicesGridSliver(devices: devices, maxTileWidth: phone ? 480 : 280),
              ),
          ],
        );
      },
    );
  }
}
