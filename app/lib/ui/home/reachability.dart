import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
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
  S? strings,
}) {
  final s = strings ?? S.current;
  if (!allowIncoming) {
    return ReachabilitySummary(
      s.t('reach.off'),
      PillTone.neutral,
      s.t('reach.off.detail'),
    );
  }
  if (!report.listening) {
    return ReachabilitySummary(
      s.t('reach.noListener'),
      PillTone.bad,
      s.t('reach.noListener.detail'),
    );
  }
  if (report.reachableIPv4 || report.reachableIPv6) {
    return ReachabilitySummary(
      s.t('reach.internet'),
      PillTone.good,
      s.t('reach.internet.detail'),
    );
  }
  if (report.cgnat) {
    return ReachabilitySummary(
      s.t('reach.lan'),
      PillTone.warn,
      s.t('reach.cgnat.detail'),
    );
  }
  return ReachabilitySummary(
    s.t('reach.lan'),
    PillTone.warn,
    s.t('reach.lan.detail'),
  );
}

/// Pill + "why?" affordance; reads the live connectivity report.
class ReachabilityPill extends StatelessWidget {
  const ReachabilityPill({
    super.key,
    required this.connectivity,
    required this.allowIncoming,
    required this.onWhy,
    this.onGradient = false,
  });

  final Connectivity connectivity;
  final bool allowIncoming;
  final VoidCallback onWhy;
  final bool onGradient;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReachabilityReport>(
      valueListenable: connectivity.report,
      builder: (context, report, _) {
        final summary = summarizeReachability(
          allowIncoming: allowIncoming,
          report: report,
          strings: context.s,
        );
        return StatusPill(
          label: summary.label,
          tone: summary.tone,
          onTap: onWhy,
          onGradient: onGradient,
          trailing: Icon(
            Icons.help_outline_rounded,
            size: 16,
            color: onGradient
                ? Colors.white70
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
