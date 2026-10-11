import 'package:flutter/material.dart';

import '../../session/link_stats.dart';
import '../../session/session_base.dart';
import '../theme.dart';
import 'connection_level.dart';

/// Green / yellow / red dot with RTT and path, e.g. `24 ms · LAN`.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key, required this.session});

  final SessionBase session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.stats]),
      builder: (context, _) {
        final s = context.status;
        final level = connectionLevel(session.phase, session.stats.value);
        final color = switch (level) {
          ConnectionLevel.good => s.good,
          ConnectionLevel.degraded => s.warn,
          ConnectionLevel.bad => s.bad,
        };
        final text = switch (session.phase) {
          SessionPhase.reconnecting => 'Reconnecting',
          SessionPhase.active => connectionSummary(session.stats.value),
          _ => 'Connecting',
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 8),
            Text(text, style: Theme.of(context).textTheme.labelLarge),
          ],
        );
      },
    );
  }
}

/// Small panel with the numbers behind the indicator.
class StatsOverlay extends StatelessWidget {
  const StatsOverlay({super.key, required this.stats});

  final ValueNotifier<LinkStats> stats;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ValueListenableBuilder<LinkStats>(
      valueListenable: stats,
      builder: (context, s, _) {
        String fmt(double? v, String unit, {int digits = 0}) =>
            v == null ? '—' : '${v.toStringAsFixed(digits)} $unit';
        final bitrate = s.bitrateBps == null
            ? '—'
            : (s.bitrateBps! >= 1e6
                ? '${(s.bitrateBps! / 1e6).toStringAsFixed(1)} Mbps'
                : '${(s.bitrateBps! / 1e3).round()} kbps');
        final rows = <(String, String)>[
          ('RTT', fmt(s.rttMs, 'ms')),
          ('FPS', fmt(s.fps, '')),
          ('Bitrate', bitrate),
          ('Loss', fmt(s.lossPercent, '%', digits: 1)),
          ('Resolution', s.width == null ? '—' : '${s.width}×${s.height}'),
          ('Codec', s.codec ?? '—'),
          ('Path', s.pathLabel),
        ];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(14),
          ),
          child: DefaultTextStyle(
            style: t.textTheme.bodySmall!.copyWith(
              color: Colors.white,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 78,
                          child: Text(r.$1, style: const TextStyle(color: Colors.white60)),
                        ),
                        Text(r.$2),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
