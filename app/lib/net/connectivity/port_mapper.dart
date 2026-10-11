// Router discovery and port mapping orchestration.
//
// Order: UPnP-IGD first (most home routers), then PCP, then NAT-PMP. The
// first method that maps the signaling port wins; the others are not tried.

import 'dart:async';
import 'dart:io';

import '../../core/log.dart';
import 'connectivity.dart';
import 'gateway.dart';
import 'interfaces.dart';
import 'natpmp.dart';
import 'pcp.dart';
import 'port_mapping.dart';
import 'upnp.dart';

const Logger _log = Logger('mapper');

/// One local port to expose.
class MappingTarget {
  const MappingTarget(this.protocol, this.internalPort);

  final MappingProtocol protocol;
  final int internalPort;

  String get label => '${protocol.name.toUpperCase()} $internalPort';
}

class ActiveMapping {
  ActiveMapping({
    required this.protocol,
    required this.internalPort,
    required this.externalPort,
    required this.lifetime,
  });

  final MappingProtocol protocol;
  final int internalPort;
  int externalPort;

  /// Zero = permanent (UPnP lease 0): never needs renewal.
  Duration lifetime;

  PortMapping toPortMapping(MappingMethod method) => PortMapping(
    protocol: protocol,
    internalPort: internalPort,
    externalPort: externalPort,
    method: method,
  );
}

/// Shared inputs of the discovery probes.
class DiscoveryContext {
  DiscoveryContext({
    required this.locals,
    this.run = runCommand,
    this.allowLoopback = false,
  });

  final LocalAddresses locals;
  final CommandRunner run;
  final bool allowLoopback;

  /// Routers that answered SSDP; they become gateway hints for PCP/NAT-PMP.
  final List<InternetAddress> routerHints = [];

  Future<List<InternetAddress>>? _osGateways;

  Future<List<InternetAddress>> gateways() async {
    _osGateways ??= readOsDefaultGateways(run: run);
    final os = await _osGateways!;
    final seen = <String>{};
    final result = <InternetAddress>[];
    for (final a in [...routerHints, ...os, ...guessGateways(locals.lanIPv4)]) {
      if (!isLanAddress(a, allowLoopback: allowLoopback)) continue;
      if (seen.add(a.address)) result.add(a);
    }
    return result;
  }
}

/// Discovers a router speaking one protocol; null when none answers.
typedef ProbeFn = Future<MappingClient?> Function(DiscoveryContext ctx);

class MappingProbe {
  const MappingProbe(this.method, this.run);

  final MappingMethod method;
  final ProbeFn run;
}

Future<T?> _firstNonNull<T>(List<Future<T?>> futures) {
  if (futures.isEmpty) return Future.value(null);
  final done = Completer<T?>();
  var pending = futures.length;
  for (final f in futures) {
    f
        .then((value) {
          if (value != null && !done.isCompleted) done.complete(value);
        }, onError: (Object _) {})
        .whenComplete(() {
          if (--pending == 0 && !done.isCompleted) done.complete(null);
        });
  }
  return done.future;
}

List<MappingProbe> defaultProbes() => [
  MappingProbe(MappingMethod.upnp, (ctx) async {
    final discovery = UpnpDiscovery(
      interfaces: ctx.locals.interfaces,
      unicastTargets: await ctx.gateways(),
      allowLoopback: ctx.allowLoopback,
    );
    final gateway = await discovery.discover();
    ctx.routerHints.addAll(discovery.respondingRouters);
    return gateway;
  }),
  MappingProbe(MappingMethod.pcp, (ctx) async {
    final gateways = await ctx.gateways();
    return _firstNonNull<MappingClient>([
      for (final gw in gateways)
        () async {
          final local = pickLocalFor(gw, ctx.locals.lanIPv4);
          return local == null ? null : PcpClient.probe(gw, local);
        }(),
    ]);
  }),
  MappingProbe(MappingMethod.natPmp, (ctx) async {
    final gateways = await ctx.gateways();
    return _firstNonNull<MappingClient>([
      for (final gw in gateways) NatPmpClient.probe(gw),
    ]);
  }),
];

class MapperOutcome {
  const MapperOutcome({
    this.client,
    this.gatewayFound = false,
    this.mappings = const [],
    this.externalAddress,
    this.problems = const [],
  });

  /// Router that holds [mappings]; null when nothing was mapped.
  final MappingClient? client;

  /// Some router answered, even if it refused to map.
  final bool gatewayFound;
  final List<ActiveMapping> mappings;
  final InternetAddress? externalAddress;
  final List<String> problems;

  bool get mapped => client != null && mappings.isNotEmpty;
}

class PortMapper {
  PortMapper({
    List<MappingProbe>? probes,
    this.lifetime = defaultMappingLifetime,
  }) : probes = probes ?? defaultProbes();

  final List<MappingProbe> probes;
  final Duration lifetime;

  /// Finds a router and maps [targets]. The first target is the one that must
  /// succeed (the signaling port); the rest are best effort.
  Future<MapperOutcome> establish(
    DiscoveryContext ctx,
    List<MappingTarget> targets,
  ) async {
    assert(targets.isNotEmpty);
    final problems = <String>[];
    var gatewayFound = false;
    InternetAddress? knownExternal;

    for (final probe in probes) {
      MappingClient? client;
      try {
        client = await probe.run(ctx);
      } on Object catch (e) {
        _log.w('${probe.method.name} discovery failed', e);
      }
      if (client == null) continue;
      gatewayFound = true;

      final mappings = <ActiveMapping>[];
      final local = <String>[];
      // The first mapping settles the offset between internal and external
      // ports (another PC behind the same router may own 47100); the others
      // ask for the same offset so one PC's ports stay a recognisable block.
      var offset = 0;
      for (var i = 0; i < targets.length; i++) {
        final target = targets[i];
        try {
          final wanted = target.internalPort + offset;
          final grant = await client.map(
            protocol: target.protocol,
            internalPort: target.internalPort,
            suggestedExternalPort: wanted >= 1 && wanted <= 65535
                ? wanted
                : target.internalPort,
            lifetime: lifetime,
          );
          if (i == 0) offset = grant.externalPort - target.internalPort;
          mappings.add(
            ActiveMapping(
              protocol: target.protocol,
              internalPort: target.internalPort,
              externalPort: grant.externalPort,
              lifetime: grant.lifetime,
            ),
          );
        } on MappingException catch (e) {
          local.add(
            '${_methodLabel(probe.method)} could not map '
            '${target.label}: ${e.message}'
            '${e.code == null ? '' : ' (code ${e.code})'}',
          );
          if (i == 0) break; // signaling port refused: this method is useless
        }
      }

      if (mappings.isNotEmpty &&
          mappings.first.internalPort == targets.first.internalPort &&
          mappings.first.protocol == targets.first.protocol) {
        InternetAddress? external;
        try {
          external = await client.externalAddress();
        } on MappingException catch (e) {
          _log.d('external address unavailable: $e');
        }
        return MapperOutcome(
          client: client,
          gatewayFound: true,
          mappings: mappings,
          externalAddress: external,
          problems: local,
        );
      }
      problems.addAll(local);
      // Even a router that refuses to map still tells us its WAN address,
      // which is what CGNAT detection and manual-forward hints rely on.
      try {
        knownExternal ??= await client.externalAddress();
      } on MappingException catch (e) {
        _log.d('external address unavailable: $e');
      }
      client.close();
    }
    return MapperOutcome(
      gatewayFound: gatewayFound,
      externalAddress: knownExternal,
      problems: problems,
    );
  }

  /// Re-requests every mapping (lease renewal). Updates [outcome]'s mappings
  /// in place when the router changes an external port. Throws when the
  /// signaling mapping cannot be renewed, so the caller can rediscover.
  Future<void> renew(MapperOutcome outcome) async {
    final client = outcome.client;
    if (client == null) return;
    for (var i = 0; i < outcome.mappings.length; i++) {
      final m = outcome.mappings[i];
      try {
        final grant = await client.map(
          protocol: m.protocol,
          internalPort: m.internalPort,
          suggestedExternalPort: m.externalPort,
          lifetime: lifetime,
        );
        m.externalPort = grant.externalPort;
        m.lifetime = grant.lifetime;
      } on MappingException {
        if (i == 0) rethrow;
        _log.w('renewing ${m.protocol.name} ${m.internalPort} failed');
      }
    }
  }

  /// Best-effort removal of everything in [outcome].
  Future<void> remove(MapperOutcome outcome) async {
    final client = outcome.client;
    if (client == null) return;
    await Future.wait([
      for (final m in outcome.mappings)
        client
            .unmap(
              protocol: m.protocol,
              internalPort: m.internalPort,
              externalPort: m.externalPort,
            )
            .timeout(const Duration(seconds: 5))
            .catchError((Object e) => _log.d('unmap failed: $e')),
    ]);
    client.close();
  }
}

String _methodLabel(MappingMethod m) => switch (m) {
  MappingMethod.upnp => 'UPnP',
  MappingMethod.natPmp => 'NAT-PMP',
  MappingMethod.pcp => 'PCP',
};
