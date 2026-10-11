// Contract between the app core and the connectivity module (serverless NAT
// traversal). See docs/PROTOCOL.md §2, §3, §4.3, §8.
//
// OWNERSHIP: this file is owned by the architect. The connectivity agent
// implements it under lib/net/connectivity/ and returns the implementation
// from createConnectivity(); core code depends only on this file.

import 'package:flutter/foundation.dart' show ValueListenable;

import 'connectivity_impl.dart' as impl;

/// Well-known local ports (PROTOCOL.md §2).
abstract final class ThelxisPorts {
  static const int signalingTcp = 47100;
  static const int turnUdp = 47100;
  static const int turnTcp = 47101;
  static const int discoveryUdp = 47102;
}

enum MappingMethod { upnp, natPmp, pcp }

enum MappingProtocol { tcp, udp }

class PortMapping {
  const PortMapping({
    required this.protocol,
    required this.internalPort,
    required this.externalPort,
    required this.method,
  });

  final MappingProtocol protocol;
  final int internalPort;
  final int externalPort;
  final MappingMethod method;
}

/// Snapshot of how reachable this device is. Shown in Settings → Diagnostics
/// and used to build advertised addresses.
class ReachabilityReport {
  const ReachabilityReport({
    this.lanIPv4 = const [],
    this.globalIPv6 = const [],
    this.gatewayFound = false,
    this.mappingMethod,
    this.externalIPv4,
    this.externalIsPublic = false,
    this.externalIsDirect = false,
    this.cgnat = false,
    this.mappings = const [],
    this.listening = false,
    this.turnRunning = false,
    this.problems = const [],
  });

  final List<String> lanIPv4;
  final List<String> globalIPv6;

  /// A UPnP/NAT-PMP/PCP-capable router answered.
  final bool gatewayFound;
  final MappingMethod? mappingMethod;

  /// The router's WAN address as reported by UPnP/NAT-PMP/PCP.
  final String? externalIPv4;

  /// [externalIPv4] is globally routable (not RFC1918 / 100.64.0.0/10 / etc.).
  final bool externalIsPublic;

  /// [externalIPv4] is assigned directly to one of our interfaces (VPS,
  /// bridged modem) — reachable without any router mapping.
  final bool externalIsDirect;

  /// The router's WAN address is itself private/shared → carrier-grade NAT;
  /// inbound IPv4 is impossible without a third party.
  final bool cgnat;

  final List<PortMapping> mappings;

  /// The signaling listener (TCP 47100) is bound (set by core via
  /// [Connectivity.setListening]).
  final bool listening;
  final bool turnRunning;

  /// Human-readable problems for the diagnostics screen (English; UI may map).
  final List<String> problems;

  /// True when a peer on the internet can most likely reach us over IPv4.
  bool get reachableIPv4 =>
      externalIsPublic &&
      (externalIsDirect ||
          mappings.any((m) =>
              m.protocol == MappingProtocol.tcp &&
              m.internalPort == ThelxisPorts.signalingTcp));

  bool get reachableIPv6 => globalIPv6.isNotEmpty;
}

/// One-time TURN credentials for a single session (PROTOCOL.md §4.1 `turn`).
class TurnGrant {
  const TurnGrant({
    required this.username,
    required this.credential,
    required this.udpPort,
    required this.tcpPort,
    required this.expiresAt,
  });

  final String username;
  final String credential;
  final int udpPort;
  final int tcpPort;
  final DateTime expiresAt;

  Map<String, Object> toJson() => {
        'username': username,
        'credential': credential,
        'udp_port': udpPort,
        'tcp_port': tcpPort,
      };
}

abstract class Connectivity {
  static final Connectivity instance = impl.createConnectivity();

  /// Starts the embedded STUN/TURN responder (UDP 47100, TCP 47101) and, if
  /// [portMapping] is true, discovers the router and maps TCP 47100, UDP 47100
  /// and TCP 47101 (renewing leases until [stop]). Idempotent; re-calling with
  /// different flags reconfigures. Never throws; failures go to the report.
  /// May take several seconds (router discovery): don't block the UI on it —
  /// an interim [report] is published as soon as interfaces and TURN are up.
  Future<void> start({required bool portMapping});

  /// Removes mappings and stops STUN/TURN.
  Future<void> stop();

  /// Re-scans interfaces and the router (e.g. after a network change).
  Future<void> refresh();

  ValueListenable<ReachabilityReport> get report;

  /// Core reports whether its signaling listener is currently bound.
  void setListening(bool listening);

  /// Addresses of our signaling port to advertise (PROTOCOL.md §3), best
  /// first: "ip:port" or "[v6]:port".
  List<String> advertisedAddresses();

  /// Issues credentials for one session; valid until [revokeTurnGrant] + 60 s
  /// or [ttl]. Returns null when TURN is not running. [dialedAddress] is the
  /// `dialed` field of the dialer's hello: when it matches our external
  /// mapping the grant carries the *external* TURN ports, otherwise the local
  /// ones.
  TurnGrant? issueTurnGrant({
    String? dialedAddress,
    Duration ttl = const Duration(hours: 12),
  });

  void revokeTurnGrant(TurnGrant grant);
}
