// Common shape of the three router port-mapping protocols (UPnP-IGD, PCP,
// NAT-PMP) so the orchestrator can treat them alike.

import 'dart:io';

import 'connectivity.dart';

class MappingException implements Exception {
  MappingException(this.message, {this.code});

  final String message;

  /// Protocol specific result/error code, when the router sent one.
  final int? code;

  @override
  String toString() => code == null ? message : '$message (code $code)';
}

class MappingGrant {
  const MappingGrant({required this.externalPort, required this.lifetime});

  final int externalPort;

  /// How long the router will keep the mapping. [Duration.zero] means
  /// "until removed" (UPnP permanent lease).
  final Duration lifetime;
}

abstract class MappingClient {
  MappingMethod get method;

  /// Stable identity of the router behind this client ("upnp@192.168.1.1:5000/ctl").
  /// Compared across refreshes to tell whether the network changed.
  String get gatewayId;

  /// The WAN address of the router, or null when it cannot tell (PCP only
  /// learns it from a MAP response, so call [map] first).
  Future<InternetAddress?> externalAddress();

  /// Asks for `protocol internalPort -> externalPort`; routers may answer with
  /// a different external port.
  Future<MappingGrant> map({
    required MappingProtocol protocol,
    required int internalPort,
    required int suggestedExternalPort,
    required Duration lifetime,
  });

  Future<void> unmap({
    required MappingProtocol protocol,
    required int internalPort,
    required int externalPort,
  });

  void close();
}

/// Lease length requested from routers (seconds); renewed at 50 %.
const Duration defaultMappingLifetime = Duration(hours: 1);
