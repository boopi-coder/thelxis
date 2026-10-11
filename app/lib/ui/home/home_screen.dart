import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../update/ui/update_banner.dart';
import '../../update/update_service.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'connect_card.dart';
import 'device_card.dart';
import 'diagnostics_screen.dart';

/// "This device" hero card plus the Connect card; two columns when there is
/// room.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _diagnostics(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final device = DeviceCard(onShowDiagnostics: () => _diagnostics(context));
        const connect = ConnectCard();
        return PageScroll(
          maxWidth: 1080,
          children: [
            const SizedBox(height: Gap.s),
            UpdateBanner(service: context.read<UpdateService>()),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: device),
                  const SizedBox(width: Gap.l),
                  const Expanded(child: connect),
                ],
              )
            else ...[
              device,
              const SizedBox(height: Gap.l),
              connect,
            ],
          ],
        );
      },
    );
  }
}
