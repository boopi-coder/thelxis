import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../net/connectivity/connectivity.dart';
import '../../net/discovery.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/hover_tint.dart';
import 'reachability_advice.dart';

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
  bool upnpEnabled = true,
  String? gatewayName,
  S? strings,
}) {
  final s = strings ?? S.current;
  final advice = adviseReachability(
    allowIncoming: allowIncoming,
    report: report,
    upnpEnabled: upnpEnabled,
    gatewayName: gatewayName,
  );
  return ReachabilitySummary(advice.label(s), advice.tone, advice.body(s));
}

/// Pill + "why?" affordance; reads the live connectivity report.
class ReachabilityPill extends StatelessWidget {
  const ReachabilityPill({
    super.key,
    required this.connectivity,
    required this.allowIncoming,
    required this.onWhy,
    this.upnpEnabled = true,
  });

  final Connectivity connectivity;
  final bool allowIncoming;
  final bool upnpEnabled;
  final VoidCallback onWhy;

  @override
  Widget build(BuildContext context) {
    final gatewayName = context.watch<LanDiscovery>().gateways.firstOrNull?.name;
    return ValueListenableBuilder<ReachabilityReport>(
      valueListenable: connectivity.report,
      builder: (context, report, _) {
        final summary = summarizeReachability(
          allowIncoming: allowIncoming,
          report: report,
          upnpEnabled: upnpEnabled,
          gatewayName: gatewayName,
          strings: context.s,
        );
        return StatusPill(
          label: summary.label,
          tone: summary.tone,
          onTap: onWhy,
          trailing: Icon(Icons.help_outline_rounded, size: 14, color: context.c.textMuted),
        );
      },
    );
  }
}

/// One line under the pill on Home explaining what to do when the device
/// cannot be reached from the internet; tapping it opens the diagnostics.
class ReachabilityHint extends StatelessWidget {
  const ReachabilityHint({
    super.key,
    required this.connectivity,
    required this.allowIncoming,
    required this.onTap,
    this.upnpEnabled = true,
    this.color,
  });

  final Connectivity connectivity;
  final bool allowIncoming;
  final bool upnpEnabled;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final gatewayName = context.watch<LanDiscovery>().gateways.firstOrNull?.name;
    return ValueListenableBuilder<ReachabilityReport>(
      valueListenable: connectivity.report,
      builder: (context, report, _) {
        final s = context.s;
        final hint = adviseReachability(
          allowIncoming: allowIncoming,
          report: report,
          upnpEnabled: upnpEnabled,
          gatewayName: gatewayName,
        ).hint(s);
        if (hint == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: HoverTint(
            key: const ValueKey('reach-hint'),
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color ?? context.c.textSecondary),
            ),
          ),
        );
      },
    );
  }
}
