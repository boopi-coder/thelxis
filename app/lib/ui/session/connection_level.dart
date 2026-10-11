import '../../l10n/strings.dart';
import '../../session/link_stats.dart';
import '../../session/session_base.dart';

/// Traffic-light quality of a session link (green / yellow / red dot).
enum ConnectionLevel { good, degraded, bad }

ConnectionLevel connectionLevel(SessionPhase phase, LinkStats stats) {
  switch (phase) {
    case SessionPhase.reconnecting:
    case SessionPhase.ended:
      return ConnectionLevel.bad;
    case SessionPhase.connecting:
    case SessionPhase.authenticating:
    case SessionPhase.awaitingApproval:
      return ConnectionLevel.degraded;
    case SessionPhase.active:
      break;
  }
  final rtt = stats.rttMs;
  final loss = stats.lossPercent ?? 0;
  if ((rtt != null && rtt >= 400) || loss >= 8) return ConnectionLevel.bad;
  if ((rtt != null && rtt >= 150) || loss >= 2) return ConnectionLevel.degraded;
  return ConnectionLevel.good;
}

/// `24 ms · LAN`, or just the path when RTT is not known yet.
String connectionSummary(LinkStats stats) {
  final rtt = stats.rttMs;
  final parts = <String>[
    if (rtt != null) '${rtt.round()} ms',
    if (stats.path != LinkPath.unknown) stats.pathLabel,
  ];
  return parts.isEmpty ? S.current.t('session.connecting') : parts.join(' · ');
}
