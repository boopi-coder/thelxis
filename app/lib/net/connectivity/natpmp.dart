// NAT-PMP client (RFC 6886), UDP port 5351 on the default gateway.

import 'dart:io';
import 'dart:typed_data';

import 'connectivity.dart';
import 'port_mapping.dart';
import 'udp_exchange.dart';

const int natPmpPort = 5351;

const Map<int, String> _resultNames = {
  1: 'unsupported version',
  2: 'not authorized / refused',
  3: 'network failure',
  4: 'out of resources',
  5: 'unsupported opcode',
};

class NatPmpClient implements MappingClient {
  NatPmpClient(
    this.gateway, {
    this.port = natPmpPort,
    this.bindAddress,
    this.retries = defaultUdpRetries,
  });

  final InternetAddress gateway;
  final int port;
  final InternetAddress? bindAddress;
  final List<Duration> retries;

  @override
  MappingMethod get method => MappingMethod.natPmp;

  @override
  String get gatewayId => 'natpmp@${gateway.address}';

  /// Returns a client when [gateway] answers a NAT-PMP external-address
  /// request, null otherwise.
  static Future<NatPmpClient?> probe(
    InternetAddress gateway, {
    int port = natPmpPort,
    InternetAddress? bindAddress,
    List<Duration> retries = defaultUdpRetries,
  }) async {
    final client = NatPmpClient(
      gateway,
      port: port,
      bindAddress: bindAddress,
      retries: retries,
    );
    try {
      final address = await client.externalAddress();
      return address == null ? null : client;
    } on MappingException {
      return null;
    }
  }

  @override
  Future<InternetAddress?> externalAddress() async {
    final reply = await udpRequest(
      gateway: gateway,
      port: port,
      bindAddress: bindAddress,
      retries: retries,
      request: Uint8List.fromList([0, 0]),
      accept: (r) => r.length >= 12 && r[0] == 0 && r[1] == 128,
    );
    if (reply == null) return null;
    final result = ByteData.sublistView(reply).getUint16(2);
    if (result != 0) throw _error('external address request', result);
    final raw = reply.sublist(8, 12);
    if (raw.every((b) => b == 0)) return null;
    return InternetAddress.fromRawAddress(Uint8List.fromList(raw));
  }

  @override
  Future<MappingGrant> map({
    required MappingProtocol protocol,
    required int internalPort,
    required int suggestedExternalPort,
    required Duration lifetime,
  }) async {
    final reply = await _mapRequest(
      protocol,
      internalPort,
      suggestedExternalPort,
      lifetime.inSeconds,
    );
    final view = ByteData.sublistView(reply);
    return MappingGrant(
      externalPort: view.getUint16(10),
      lifetime: Duration(seconds: view.getUint32(12)),
    );
  }

  @override
  Future<void> unmap({
    required MappingProtocol protocol,
    required int internalPort,
    required int externalPort,
  }) async {
    // RFC 6886 §3.4: lifetime 0 and external port 0 delete the mapping.
    await _mapRequest(protocol, internalPort, 0, 0);
  }

  Future<Uint8List> _mapRequest(
    MappingProtocol protocol,
    int internalPort,
    int externalPort,
    int lifetimeSeconds,
  ) async {
    final opcode = protocol == MappingProtocol.udp ? 1 : 2;
    final request = Uint8List(12);
    final view = ByteData.sublistView(request);
    request[1] = opcode;
    view.setUint16(4, internalPort);
    view.setUint16(6, externalPort);
    view.setUint32(8, lifetimeSeconds);
    final reply = await udpRequest(
      gateway: gateway,
      port: port,
      bindAddress: bindAddress,
      retries: retries,
      request: request,
      accept: (r) =>
          r.length >= 16 &&
          r[0] == 0 &&
          r[1] == 128 + opcode &&
          ByteData.sublistView(r).getUint16(8) == internalPort,
    );
    if (reply == null) throw MappingException('NAT-PMP gateway did not answer');
    final result = ByteData.sublistView(reply).getUint16(2);
    if (result != 0) throw _error('mapping request', result);
    return reply;
  }

  MappingException _error(String what, int result) => MappingException(
    'NAT-PMP $what failed: ${_resultNames[result] ?? 'result $result'}',
    code: result,
  );

  @override
  void close() {}
}
