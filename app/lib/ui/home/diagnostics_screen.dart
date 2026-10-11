import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../net/connectivity/connectivity.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reachability.dart';

/// Connectivity diagnostics: LAN IPs, IPv6, router / UPnP status, external IP,
/// CGNAT warning, mapped ports, problems.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final connectivity = context.read<Connectivity>();
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connectivity diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Re-scan',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: connectivity.refresh,
          ),
        ],
      ),
      body: ValueListenableBuilder<ReachabilityReport>(
        valueListenable: connectivity.report,
        builder: (context, r, _) {
          final summary = summarizeReachability(allowIncoming: settings.allowIncoming, report: r);
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
              const SectionHeader('This device'),
              Card(
                child: Column(
                  children: [
                    _row('Listening on TCP 47100', r.listening ? 'Yes' : 'No', ok: r.listening),
                    _row('Embedded STUN/TURN', r.turnRunning ? 'Running' : 'Stopped', ok: r.turnRunning),
                    _row('LAN IPv4', r.lanIPv4.isEmpty ? 'None' : r.lanIPv4.join(', ')),
                    _row('Global IPv6', r.globalIPv6.isEmpty ? 'None' : r.globalIPv6.join(', '), ok: r.globalIPv6.isNotEmpty),
                  ],
                ),
              ),
              const SectionHeader('Router'),
              Card(
                child: Column(
                  children: [
                    _row(
                      'UPnP / NAT-PMP / PCP gateway',
                      r.gatewayFound ? 'Found (${_method(r.mappingMethod)})' : 'Not found',
                      ok: r.gatewayFound,
                    ),
                    _row('External IPv4', r.externalIPv4 ?? 'Unknown'),
                    _row('Public address', r.externalIsPublic ? 'Yes' : 'No', ok: r.externalIsPublic),
                    if (r.cgnat)
                      _row('Carrier-grade NAT', 'Detected', ok: false),
                    _row(
                      'Port mappings',
                      r.mappings.isEmpty
                          ? 'None'
                          : r.mappings
                              .map((m) =>
                                  '${m.protocol.name.toUpperCase()} ${m.internalPort} → ${m.externalPort}')
                              .join(', '),
                    ),
                  ],
                ),
              ),
              if (r.problems.isNotEmpty) ...[
                const SectionHeader('Problems'),
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
              const SectionHeader('How connections work'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Thelxis has no server. A device is reachable when it has a public '
                  'IPv6 address, a router mapping (UPnP / NAT-PMP), or a manual port '
                  'forward of 47100 (TCP and UDP) and 47101 (TCP). If only the other '
                  'side is reachable, use "Let them control this device" to connect '
                  'in reverse.',
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

  static String _method(MappingMethod? m) => switch (m) {
        MappingMethod.upnp => 'UPnP',
        MappingMethod.natPmp => 'NAT-PMP',
        MappingMethod.pcp => 'PCP',
        null => 'unknown',
      };

  Widget _row(String label, String value, {bool? ok}) {
    return Builder(builder: (context) {
      final s = context.status;
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
                    color: ok ? s.good : s.warn,
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
