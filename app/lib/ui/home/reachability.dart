import 'package:flutter/material.dart';

import '../../net/connectivity/connectivity.dart';
import '../widgets/common.dart';

/// What the pill on Home should say about incoming connectivity.
class ReachabilitySummary {
  const ReachabilitySummary(this.label, this.tone, this.detail);

  final String label;
  final PillTone tone;

  /// One sentence for the diagnostics header.
  final String detail;
}

ReachabilitySummary summarizeReachability({
  required bool allowIncoming,
  required ReachabilityReport report,
}) {
  if (!allowIncoming) {
    return const ReachabilitySummary(
      'Not accepting',
      PillTone.neutral,
      'Incoming connections are switched off. Nobody can connect to this device.',
    );
  }
  if (!report.listening) {
    return const ReachabilitySummary(
      'Listener unavailable',
      PillTone.bad,
      'The signaling port could not be opened. Another program may be using port 47100.',
    );
  }
  if (report.reachableIPv4 || report.reachableIPv6) {
    return const ReachabilitySummary(
      'Reachable from internet',
      PillTone.good,
      'Devices on the internet can connect directly to this one.',
    );
  }
  if (report.cgnat) {
    return const ReachabilitySummary(
      'LAN only',
      PillTone.warn,
      'Your provider shares one public address between customers (CGNAT), so '
          'inbound IPv4 is not possible. IPv6, a VPN, or a reverse connection can still work.',
    );
  }
  return const ReachabilitySummary(
    'LAN only',
    PillTone.warn,
    'Devices on your network can connect. For internet access, enable UPnP '
        'or forward ports 47100 (TCP and UDP) and 47101 (TCP) on your router.',
  );
}

/// Pill + optional "why?" action; reads the live connectivity report.
class ReachabilityPill extends StatelessWidget {
  const ReachabilityPill({
    super.key,
    required this.connectivity,
    required this.allowIncoming,
    required this.onWhy,
  });

  final Connectivity connectivity;
  final bool allowIncoming;
  final VoidCallback onWhy;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReachabilityReport>(
      valueListenable: connectivity.report,
      builder: (context, report, _) {
        final s = summarizeReachability(allowIncoming: allowIncoming, report: report);
        return StatusPill(
          label: s.label,
          tone: s.tone,
          onTap: onWhy,
          trailing: Icon(
            Icons.help_outline_rounded,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
