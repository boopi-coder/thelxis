// In-memory router for mapper and service tests.

import 'dart:io';

import 'package:thelxis/net/connectivity/connectivity.dart';
import 'package:thelxis/net/connectivity/port_mapper.dart';
import 'package:thelxis/net/connectivity/port_mapping.dart';

class FakeRouter implements MappingClient {
  FakeRouter(
    this.method, {
    this.id = 'router-1',
    this.external = '93.184.216.34',
  });

  @override
  final MappingMethod method;
  final String id;
  String? external;

  /// Mappings that must be refused: "tcp:47100".
  final Set<String> refuse = {};

  /// Added to the external port the router hands out.
  int portShift = 0;
  Duration lifetime = const Duration(hours: 1);

  /// While true every map() call fails (router rebooting / gone).
  bool failMaps = false;

  final List<String> mapCalls = [];
  final List<String> unmapCalls = [];
  bool closed = false;

  @override
  String get gatewayId => id;

  @override
  Future<InternetAddress?> externalAddress() async =>
      external == null ? null : InternetAddress(external!);

  @override
  Future<MappingGrant> map({
    required MappingProtocol protocol,
    required int internalPort,
    required int suggestedExternalPort,
    required Duration lifetime,
  }) async {
    final key = '${protocol.name}:$internalPort';
    mapCalls.add(key);
    if (failMaps || refuse.contains(key)) {
      throw MappingException('refused', code: 2);
    }
    return MappingGrant(
      externalPort: suggestedExternalPort + portShift,
      lifetime: this.lifetime,
    );
  }

  @override
  Future<void> unmap({
    required MappingProtocol protocol,
    required int internalPort,
    required int externalPort,
  }) async {
    unmapCalls.add('${protocol.name}:$internalPort->$externalPort');
  }

  @override
  void close() => closed = true;
}

/// A probe that returns [router] (or throws / returns null) and counts calls.
class CountingProbe {
  CountingProbe(this.method, {this.router, this.throws = false});

  final MappingMethod method;
  FakeRouter? router;
  bool throws;
  int calls = 0;

  MappingProbe get probe => MappingProbe(method, (ctx) async {
    calls++;
    if (throws) throw StateError('probe exploded');
    return router;
  });
}
