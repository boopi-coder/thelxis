// Connectivity service: embedded STUN/TURN, router port mapping and the
// reachability report (PROTOCOL.md §2, §3, §4.3, §8).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/log.dart';
import 'connectivity.dart';
import 'interfaces.dart';
import 'port_mapper.dart';
import 'turn_grants.dart';
import 'turn_server.dart';

const Logger _log = Logger('connectivity');

Connectivity createConnectivity() => ConnectivityService();

/// Ports and timings; overridable so tests can run on ephemeral ports.
class ConnectivityConfig {
  const ConnectivityConfig({
    this.signalingPort = ThelxisPorts.signalingTcp,
    this.turnUdpPort = ThelxisPorts.turnUdp,
    this.turnTcpPort = ThelxisPorts.turnTcp,
    this.networkWatchInterval = const Duration(seconds: 30),
    this.minRenewalDelay = const Duration(seconds: 30),
    this.retryDelay = const Duration(minutes: 2),
  });

  final int signalingPort;
  final int turnUdpPort;
  final int turnTcpPort;

  /// How often interfaces are re-read to notice a network change on our own.
  final Duration networkWatchInterval;

  /// Floor for the lease-renewal timer (leases are renewed at 50 %).
  final Duration minRenewalDelay;

  /// Pause before retrying router discovery after a failure.
  final Duration retryDelay;
}

class ConnectivityService implements Connectivity {
  ConnectivityService({
    this.config = const ConnectivityConfig(),
    this.interfaceLister,
    PortMapper? mapper,
    Clock? clock,
    this.allowLoopbackRouters = false,
  }) : _mapper = mapper ?? PortMapper(),
       _clock = clock ?? DateTime.now,
       _grants = TurnGrantStore(clock: clock);

  final ConnectivityConfig config;

  /// Test hook: replaces the OS interface enumeration.
  final InterfaceLister? interfaceLister;

  /// Test hook: lets SSDP/NAT-PMP/PCP talk to loopback fakes.
  final bool allowLoopbackRouters;
  final PortMapper _mapper;
  final Clock _clock;
  final TurnGrantStore _grants;

  final ValueNotifier<ReachabilityReport> _report = ValueNotifier(
    const ReachabilityReport(),
  );

  bool _running = false;
  bool _portMapping = false;
  bool _listening = false;
  ManualForwarding? _manual;

  LocalAddresses _locals = const LocalAddresses();
  DateTime _lastScan = DateTime.fromMillisecondsSinceEpoch(0);
  String _ipv4Signature = '';

  TurnServer? _turn;
  List<String> _turnErrors = const [];

  MapperOutcome? _outcome;
  InternetAddress? _externalAddress;
  bool _gatewayFound = false;
  List<String> _mappingProblems = const [];

  Timer? _renewTimer;
  Timer? _watchTimer;
  Future<void> _tail = Future.value();

  // ------------------------------------------------------------ public API

  @override
  ValueListenable<ReachabilityReport> get report => _report;

  @override
  Future<void> start({required bool portMapping}) => _guarded(
    'start',
    () async {
      _portMapping = portMapping;
      if (_running) {
        // A busy port may be free now.
        if (_turn?.isRunning != true) {
          await _startTurn();
        }
      } else {
        _running = true;
        await _scanAsBaseline();
        await _startTurn();
        _watchTimer = Timer.periodic(config.networkWatchInterval, (_) {
          _guarded('network watch', _watchNetwork);
        });
      }
      _publish(); // LAN addresses and TURN are usable before the router answers
      if (portMapping) {
        if (_outcome == null) await _establish();
      } else {
        await _dropMapping(unmap: true);
      }
      _scheduleRenewal();
      _publish();
    },
  );

  @override
  Future<void> stop() => _guarded('stop', () async {
    _renewTimer?.cancel();
    _renewTimer = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    await _dropMapping(unmap: true);
    await _turn?.stop();
    _grants.clear();
    _running = false;
    _portMapping = false;
    _turnErrors = const [];
    _locals = const LocalAddresses();
    _ipv4Signature = '';
    _publish();
  });

  @override
  Future<void> refresh() => _guarded('refresh', () async {
    if (!_running) return;
    await _scanAsBaseline();
    if (_turn?.isRunning != true) await _startTurn();
    if (_portMapping) {
      await _establish();
      _scheduleRenewal();
    }
    _publish();
  });

  @override
  void setListening(bool listening) {
    if (_listening == listening) return;
    _listening = listening;
    _publish();
  }

  @override
  void setManualForwarding(ManualForwarding? forwarding) {
    _manual = forwarding;
    if (_running) _publish();
  }

  @override
  List<String> advertisedAddresses() {
    if (!_running) return const [];
    final r = _report.value;
    final port = config.signalingPort;
    final out = <String>[];
    void add(String address) {
      if (!out.contains(address)) out.add(address);
    }

    final external = r.externalIPv4;
    final mappedPort = _signalingMapping(r)?.externalPort;
    final routerExternal = r.externalIsPublic ? external : null;
    // Hand-made forwarding is the user's explicit statement of how to reach
    // this machine, so it leads.
    final manual = _manual;
    if (manual != null) {
      final host = manual.externalHost ?? routerExternal;
      if (host != null && host.isNotEmpty) {
        add(formatHostPort(host, manual.signalingTcp));
      }
    }
    if (routerExternal != null && mappedPort != null) {
      add(formatHostPort(routerExternal, mappedPort));
    }
    for (final a in _locals.publicIPv4) {
      add(formatHostPort(a.address, port));
    }
    for (final v6 in r.globalIPv6) {
      add(formatHostPort(v6, port));
    }
    // The router reported a public WAN address but would not map: the user
    // may have forwarded the port by hand, so it is worth offering.
    if (routerExternal != null && mappedPort == null) {
      add(formatHostPort(routerExternal, port));
    }
    for (final lan in r.lanIPv4) {
      add(formatHostPort(lan, port));
    }
    return out;
  }

  @override
  TurnGrant? issueTurnGrant({
    String? dialedAddress,
    Duration ttl = const Duration(hours: 12),
    bool gateway = false,
  }) {
    final turn = _turn;
    if (!_running || turn == null || !turn.isRunning) return null;
    final record = _grants.issue(ttl: ttl, gateway: gateway);

    var udpPort = turn.boundUdpPort ?? config.turnUdpPort;
    var tcpPort = turn.boundTcpPort ?? config.turnTcpPort;
    final manual = _manual;
    if (_dialedViaManualForwarding(dialedAddress)) {
      udpPort = manual!.turnUdp;
      tcpPort = manual.turnTcp;
    } else if (_dialedViaExternalMapping(dialedAddress)) {
      final r = _report.value;
      for (final m in r.mappings) {
        if (m.protocol == MappingProtocol.udp && m.internalPort == udpPort) {
          udpPort = m.externalPort;
        } else if (m.protocol == MappingProtocol.tcp &&
            m.internalPort == (turn.boundTcpPort ?? config.turnTcpPort)) {
          tcpPort = m.externalPort;
        }
      }
    }
    return TurnGrant(
      username: record.username,
      credential: record.password,
      udpPort: udpPort,
      tcpPort: tcpPort,
      expiresAt: record.expiresAt,
    );
  }

  @override
  void revokeTurnGrant(TurnGrant grant) => _grants.revoke(grant.username);

  // ----------------------------------------------------------- internals

  /// Serialises operations and keeps the "never throws" promise.
  Future<void> _guarded(String what, Future<void> Function() op) {
    final result = _tail.then((_) async {
      try {
        await op();
      } on Object catch (e, s) {
        _log.e('$what failed', e, s);
      }
    });
    _tail = result;
    return result;
  }

  PortMapping? _signalingMapping(ReachabilityReport r) {
    for (final m in r.mappings) {
      if (m.protocol == MappingProtocol.tcp &&
          m.internalPort == config.signalingPort) {
        return m;
      }
    }
    return null;
  }

  bool _dialedViaExternalMapping(String? dialed) {
    final parsed = parseIpPort(dialed);
    if (parsed == null) return false;
    final r = _report.value;
    final mapping = _signalingMapping(r);
    return mapping != null &&
        r.externalIPv4 == parsed.host &&
        mapping.externalPort == parsed.port;
  }

  /// The dialer came in from outside on the hand-forwarded signaling port.
  /// A dialed address that is one of ours (LAN, loopback) never qualifies,
  /// even when the manual port happens to equal the local one.
  bool _dialedViaManualForwarding(String? dialed) {
    final manual = _manual;
    final parsed = parseHostPort(dialed);
    if (manual == null || parsed == null) return false;
    if (parsed.port != manual.signalingTcp) return false;
    final ip = InternetAddress.tryParse(parsed.host);
    if (ip == null) return true; // a DNS name: reached us from outside
    return !_locals.isLocal(ip) && !isLanAddress(ip);
  }

  Future<void> _scan() async {
    _locals = await scanLocalAddresses(interfaceLister);
    _lastScan = _clock();
    await _turn?.setUdpIpv6Addresses(_locals.globalIPv6);
  }

  String _signatureOf(LocalAddresses a) => [
    ...a.lanIPv4.map((x) => x.address),
    ...a.publicIPv4.map((x) => x.address),
  ].join(',');

  /// Scan used by start/refresh: the result becomes the new baseline for
  /// change detection.
  Future<void> _scanAsBaseline() async {
    await _scan();
    _ipv4Signature = _signatureOf(_locals);
  }

  /// Polls interfaces so a network change is noticed even if nobody calls
  /// [refresh].
  Future<void> _watchNetwork() async {
    if (!_running) return;
    final v6Before = _locals.globalIPv6.map((a) => a.address).join(',');
    await _scan();
    await _applyNetworkChange();
    if (_locals.globalIPv6.map((a) => a.address).join(',') != v6Before) {
      _publish();
    }
  }

  /// A changed IPv4 set means a new network, so the router is looked up
  /// again. IPv6-only changes just refresh the report.
  Future<void> _applyNetworkChange() async {
    if (!_running) return;
    final now = _signatureOf(_locals);
    if (now == _ipv4Signature) return;
    _log.i('network change detected');
    _ipv4Signature = now;
    if (_portMapping) {
      await _establish();
      _scheduleRenewal();
    }
    _publish();
  }

  Future<void> _startTurn() async {
    final turn = _turn ??= TurnServer(
      grants: _grants,
      udpPort: config.turnUdpPort,
      tcpPort: config.turnTcpPort,
      relayAddress: _relayAddress,
      isLocalPeer: _isLocalPeer,
      isGatewayPeer: _isGatewayPeer,
      clock: _clock,
    );
    final result = await turn.start();
    await turn.setUdpIpv6Addresses(_locals.globalIPv6);
    _turnErrors = result.errors;
    for (final e in result.errors) {
      _log.w(e);
    }
  }

  /// XOR-RELAYED-ADDRESS: our primary LAN address, so the local ICE agent can
  /// reach relay ports.
  InternetAddress _relayAddress() {
    if (_locals.lanIPv4.isNotEmpty) return _locals.lanIPv4.first;
    if (_locals.publicIPv4.isNotEmpty) return _locals.publicIPv4.first;
    return InternetAddress.loopbackIPv4;
  }

  /// Is [peer] an address of this machine? A miss re-reads the interfaces
  /// (rate limited) so a freshly joined network does not cause spurious 403s.
  Future<bool> _isLocalPeer(InternetAddress peer) =>
      _checkPeer(peer, (l) => l.isLocal(peer));

  /// Office-gateway grants: private addresses in our directly connected
  /// subnets (PROTOCOL.md §11).
  Future<bool> _isGatewayPeer(InternetAddress peer) =>
      _checkPeer(peer, (l) => l.isInDirectPrivateSubnet(peer));

  Future<bool> _checkPeer(
    InternetAddress peer,
    bool Function(LocalAddresses) test,
  ) async {
    if (test(_locals)) return true;
    if (_clock().difference(_lastScan) < const Duration(seconds: 5)) {
      return false;
    }
    await _scan();
    _publish();
    // A new IPv4 set also means the router mapping may be stale.
    _guarded('network change', _applyNetworkChange);
    return test(_locals);
  }

  List<MappingTarget> _targets() {
    final turn = _turn;
    return [
      MappingTarget(MappingProtocol.tcp, config.signalingPort),
      if (turn?.boundUdpPort != null)
        MappingTarget(MappingProtocol.udp, turn!.boundUdpPort!),
      if (turn?.boundTcpPort != null)
        MappingTarget(MappingProtocol.tcp, turn!.boundTcpPort!),
    ];
  }

  /// Discovers the router and maps the ports from scratch. A previous mapping
  /// on the same router is simply renewed by the new requests; one on a
  /// router we have left is abandoned without sending deletes (an unmap on a
  /// different router could remove somebody else's forward).
  Future<void> _establish() async {
    final previous = _outcome;
    _outcome = null;
    _externalAddress = null;
    _gatewayFound = false;
    _mappingProblems = const [];

    if (_locals.lanIPv4.isEmpty) {
      previous?.client?.close();
      return;
    }
    final outcome = await _mapper.establish(
      DiscoveryContext(locals: _locals, allowLoopback: allowLoopbackRouters),
      _targets(),
    );
    final oldClient = previous?.client;
    if (oldClient != null && oldClient != outcome.client) oldClient.close();
    _gatewayFound = outcome.gatewayFound;
    _mappingProblems = outcome.problems;
    _externalAddress = outcome.externalAddress;
    if (outcome.mapped) _outcome = outcome;
  }

  Future<void> _dropMapping({required bool unmap}) async {
    final outcome = _outcome;
    _outcome = null;
    _externalAddress = null;
    _gatewayFound = false;
    _mappingProblems = const [];
    if (outcome != null && unmap) {
      await _mapper.remove(outcome);
    } else {
      outcome?.client?.close();
    }
  }

  void _scheduleRenewal() {
    _renewTimer?.cancel();
    _renewTimer = null;
    if (!_running || !_portMapping) return;

    final outcome = _outcome;
    Duration delay;
    if (outcome != null && outcome.mapped) {
      final leases = outcome.mappings
          .map((m) => m.lifetime)
          .where((d) => d > Duration.zero);
      if (leases.isEmpty) {
        delay = const Duration(minutes: 30); // permanent leases: just re-verify
      } else {
        final shortest = leases.reduce((a, b) => a < b ? a : b);
        delay = shortest ~/ 2; // renew at 50 % of the lease
      }
      if (delay < config.minRenewalDelay) delay = config.minRenewalDelay;
    } else {
      delay = config.retryDelay;
    }
    _renewTimer = Timer(delay, () => _guarded('renewal', _renewOnce));
  }

  Future<void> _renewOnce() async {
    if (!_running || !_portMapping) return;
    final outcome = _outcome;
    if (outcome != null && outcome.mapped) {
      try {
        await _mapper.renew(outcome);
        final external = await outcome.client!.externalAddress();
        if (external != null) _externalAddress = external;
      } on Object catch (e) {
        _log.i('lease renewal failed, looking for the router again: $e');
        await _establish();
      }
    } else {
      await _establish();
    }
    _scheduleRenewal();
    _publish();
  }

  // -------------------------------------------------------------- report

  void _publish() {
    final turn = _turn;
    if (!_running) {
      _report.value = ReachabilityReport(listening: _listening);
      return;
    }

    final outcome = _outcome;
    final mappings = outcome == null
        ? const <PortMapping>[]
        : [
            for (final m in outcome.mappings)
              m.toPortMapping(outcome.client!.method),
          ];

    // Router WAN address wins; otherwise an address assigned straight to an
    // interface (VPS, bridged modem) counts as the external one.
    String? external = _externalAddress?.address;
    if (external == null && _locals.publicIPv4.isNotEmpty) {
      external = _locals.publicIPv4.first.address;
    }
    final isPublic = isPublicIpv4(external);
    final cgnat = external != null && !isPublic;

    final problems = <String>[..._turnErrors];
    if (_portMapping) {
      if (_locals.lanIPv4.isEmpty && _locals.publicIPv4.isEmpty) {
        problems.add('No local IPv4 network found');
      } else if (!_gatewayFound &&
          outcome == null &&
          _locals.lanIPv4.isNotEmpty &&
          _manual == null) {
        // With manual forwarding configured, a missing UPnP router is
        // expected, not a problem.
        problems.add('No UPnP/NAT-PMP/PCP router found');
      }
      problems.addAll(_mappingProblems);
    }
    final routerExternal = _externalAddress?.address;
    if (cgnat && routerExternal != null) {
      problems.add(
        _manual == null
            ? _cgnatMessage(routerExternal)
            : "Router's external address $routerExternal looks like a shared "
                  'or private address; manual forwarding only works if the '
                  'provider also forwards to this router',
      );
    }
    if (_locals.lanIPv4.isEmpty &&
        _locals.publicIPv4.isEmpty &&
        _locals.globalIPv6.isEmpty) {
      problems.add('No network connection');
    }

    _report.value = ReachabilityReport(
      lanIPv4: [for (final a in _locals.lanIPv4) a.address],
      globalIPv6: [for (final a in _locals.globalIPv6) a.address],
      gatewayFound: _gatewayFound,
      mappingMethod: outcome?.client?.method,
      externalIPv4: external,
      externalIsPublic: isPublic,
      externalIsDirect:
          external != null &&
          _locals.publicIPv4.any((a) => a.address == external),
      manualForwarding: _manual != null,
      cgnat: cgnat,
      mappings: mappings,
      listening: _listening,
      turnRunning: turn?.isRunning ?? false,
      problems: problems,
    );
  }

  String _cgnatMessage(String external) {
    return switch (classifyIpv4(external)) {
      Ipv4Kind.shared =>
        "Router's external address $external is carrier-grade NAT (CGNAT): "
            'inbound IPv4 connections are impossible',
      Ipv4Kind.private =>
        "Router's external address $external is a private address: the router "
            'sits behind another NAT (double NAT)',
      _ => "Router's external address $external is not publicly routable",
    };
  }
}
