import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../net/connectivity/connectivity.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reachability.dart';
import '../../l10n/strings.dart';

/// Connectivity diagnostics: LAN IPs, IPv6, router / UPnP status, external IP,
/// CGNAT warning, mapped ports, problems.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final connectivity = context.read<Connectivity>();
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('diag.title')),
        actions: [
          IconButton(
            tooltip: s.t('diag.rescan'),
            icon: const Icon(Icons.refresh_rounded),
            onPressed: connectivity.refresh,
          ),
        ],
      ),
      body: ValueListenableBuilder<ReachabilityReport>(
        valueListenable: connectivity.report,
        builder: (context, r, _) {
          final summary = summarizeReachability(allowIncoming: settings.allowIncoming, report: r, strings: s);
          String yesNo(bool v) => v ? s.t('common.yes') : s.t('common.no');
          return PageScroll(
            maxWidth: 720,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusPill(label: summary.label, tone: summary.tone),
                      const SizedBox(height: Gap.m),
                      Text(summary.detail),
                    ],
                  ),
                ),
              ),
              SectionHeader(s.t('diag.section.device')),
              Card(
                child: Column(
                  children: [
                    _row(s.t('diag.listening'), yesNo(r.listening), ok: r.listening),
                    _row(s.t('diag.relay'), r.turnRunning ? s.t('diag.running') : s.t('diag.stopped'), ok: r.turnRunning),
                    _row(s.t('diag.lanIPv4'), r.lanIPv4.isEmpty ? s.t('common.none') : r.lanIPv4.join(', ')),
                    _row(
                      s.t('diag.ipv6'),
                      r.globalIPv6.isEmpty ? s.t('common.none') : r.globalIPv6.join(', '),
                      ok: r.globalIPv6.isNotEmpty,
                    ),
                  ],
                ),
              ),
              SectionHeader(s.t('diag.section.router')),
              Card(
                child: Column(
                  children: [
                    _row(
                      s.t('diag.gateway'),
                      r.gatewayFound
                          ? s.t('diag.gateway.found', {'method': _method(s, r.mappingMethod)})
                          : s.t('diag.gateway.none'),
                      ok: r.gatewayFound,
                    ),
                    _row(s.t('diag.externalIp'), r.externalIPv4 ?? s.t('common.unknown')),
                    _row(s.t('diag.publicAddress'), yesNo(r.externalIsPublic), ok: r.externalIsPublic),
                    if (r.externalIsDirect) _row(s.t('diag.directAddress'), s.t('diag.directAddress.yes'), ok: true),
                    if (r.cgnat) _row(s.t('diag.cgnat'), s.t('diag.detected'), ok: false),
                    _row(
                      s.t('diag.mappings'),
                      r.mappings.isEmpty
                          ? s.t('common.none')
                          : r.mappings
                              .map((m) => '${m.protocol.name.toUpperCase()} ${m.internalPort} → ${m.externalPort}')
                              .join(', '),
                    ),
                  ],
                ),
              ),
              if (r.problems.isNotEmpty) ...[
                SectionHeader(s.t('diag.section.problems')),
                Card(
                  child: Column(
                    children: [
                      for (final p in r.problems)
                        ListTile(
                          leading: Icon(Icons.warning_amber_rounded, color: context.status.warn),
                          title: Text(p),
                        ),
                    ],
                  ),
                ),
              ],
              SectionHeader(s.t('diag.section.how')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  s.t('diag.how'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _method(S s, MappingMethod? m) => switch (m) {
        MappingMethod.upnp => 'UPnP',
        MappingMethod.natPmp => 'NAT-PMP',
        MappingMethod.pcp => 'PCP',
        null => s.t('common.unknown'),
      };

  Widget _row(String label, String value, {bool? ok}) {
    return Builder(builder: (context) {
      final st = context.status;
      return ListTile(
        title: Text(label),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ok != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 18,
                    color: ok ? st.good : st.warn,
                  ),
                ),
              Flexible(child: Text(value, textAlign: TextAlign.end)),
            ],
          ),
        ),
      );
    });
  }
}
