// PCP client (RFC 6887), UDP port 5351 on the default gateway. Only the MAP
// opcode (and ANNOUNCE for discovery) is implemented.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'connectivity.dart';
import 'interfaces.dart';
import 'port_mapping.dart';
import 'udp_exchange.dart';

const int pcpPort = 5351;

const Map<int, String> _resultNames = {
  1: 'unsupported version',
  2: 'not authorized',
  3: 'malformed request',
  4: 'unsupported opcode',
  7: 'network failure',
  8: 'no resources',
  9: 'unsupported protocol',
  10: 'quota exceeded',
  11: 'cannot provide external port',
  12: 'address mismatch',
};

class PcpClient implements MappingClient {
  PcpClient(
    this.gateway,
    this.localAddress, {
    this.port = pcpPort,
    this.retries = defaultUdpRetries,
  });

  final InternetAddress gateway;

  /// Our IPv4 address toward [gateway]. The socket is bound to it so the
  /// packet's source matches the "PCP client address" field (RFC 6887 §8.1).
  final InternetAddress localAddress;
  final int port;
  final List<Duration> retries;

  final Map<String, Uint8List> _nonces = {};
  final Random _random = Random.secure();
  InternetAddress? _external;

  @override
  MappingMethod get method => MappingMethod.pcp;

  @override
  String get gatewayId => 'pcp@${gateway.address}';

  /// Returns a client when [gateway] answers a PCP ANNOUNCE with success.
  static Future<PcpClient?> probe(
    InternetAddress gateway,
    InternetAddress localAddress, {
    int port = pcpPort,
    List<Duration> retries = defaultUdpRetries,
  }) async {
    final client =
        PcpClient(gateway, localAddress, port: port, retries: retries);
    final request = client._header(opcode: 0, lifetime: 0);
    final reply = await udpRequest(
      gateway: gateway,
      port: port,
      bindAddress: localAddress,
      retries: retries,
      request: request,
      // Version 0 means a NAT-PMP-only router answered: give up quickly.
      accept: (r) => r.length >= 4 && (r[0] == 2 || r[0] == 0),
    );
    if (reply == null || reply[0] != 2 || (reply[1] & 0x7f) != 0) return null;
    if (reply.length < 24 || reply[3] != 0) return null;
    return client;
  }

  /// 24-byte common request header with the IPv4-mapped client address.
  Uint8List _header({required int opcode, required int lifetime, int extra = 0}) {
    final out = Uint8List(24 + extra);
    out[0] = 2; // version
    out[1] = opcode; // R bit = 0 (request)
    ByteData.sublistView(out).setUint32(4, lifetime);
    out[18] = 0xff;
    out[19] = 0xff;
    out.setRange(20, 24, localAddress.rawAddress);
    return out;
  }

  @override
  Future<InternetAddress?> externalAddress() async => _external;

  Uint8List _nonceFor(MappingProtocol protocol, int internalPort) =>
      _nonces.putIfAbsent(
        '${protocol.name}:$internalPort',
        () => Uint8List.fromList(List.generate(12, (_) => _random.nextInt(256))),
      );

  Future<({int externalPort, Duration lifetime, InternetAddress? external})>
      _map(MappingProtocol protocol, int internalPort, int externalPort,
          int lifetimeSeconds) async {
    final nonce = _nonceFor(protocol, internalPort);
    final protocolNumber = protocol == MappingProtocol.tcp ? 6 : 17;
    final request = _header(opcode: 1, lifetime: lifetimeSeconds, extra: 36);
    final view = ByteData.sublistView(request);
    request.setRange(24, 36, nonce);
    request[36] = protocolNumber;
    view.setUint16(40, internalPort);
    view.setUint16(42, externalPort);
    // Suggested external address: all zero = "any".
    final reply = await udpRequest(
      gateway: gateway,
      port: port,
      bindAddress: localAddress,
      retries: retries,
      request: request,
      accept: (r) {
        if (r.length < 60 || r[0] != 2 || (r[1] & 0x7f) != 1) return false;
        for (var i = 0; i < 12; i++) {
          if (r[24 + i] != nonce[i]) return false;
        }
        return true;
      },
    );
    if (reply == null) throw MappingException('PCP gateway did not answer');
    final result = reply[3];
    if (result != 0) {
      throw MappingException(
          'PCP mapping failed: ${_resultNames[result] ?? 'result $result'}',
          code: result);
    }
    final r = ByteData.sublistView(reply);
    final external = _ipv4FromMapped(reply, 44);
    if (external != null) _external = external;
    return (
      externalPort: r.getUint16(42),
      lifetime: Duration(seconds: r.getUint32(4)),
      external: external,
    );
  }

  /// IPv4 address stored as ::ffff:a.b.c.d at [offset]; null for anything else.
  InternetAddress? _ipv4FromMapped(Uint8List data, int offset) {
    for (var i = 0; i < 10; i++) {
      if (data[offset + i] != 0) return null;
    }
    if (data[offset + 10] != 0xff || data[offset + 11] != 0xff) return null;
    final raw = Uint8List.fromList(data.sublist(offset + 12, offset + 16));
    if (raw.every((b) => b == 0)) return null;
    return InternetAddress.fromRawAddress(raw);
  }

  @override
  Future<MappingGrant> map({
    required MappingProtocol protocol,
    required int internalPort,
    required int suggestedExternalPort,
    required Duration lifetime,
  }) async {
    final r = await _map(
        protocol, internalPort, suggestedExternalPort, lifetime.inSeconds);
    return MappingGrant(externalPort: r.externalPort, lifetime: r.lifetime);
  }

  @override
  Future<void> unmap({
    required MappingProtocol protocol,
    required int internalPort,
    required int externalPort,
  }) async {
    // Lifetime 0 with the same nonce deletes the mapping (RFC 6887 §15).
    await _map(protocol, internalPort, externalPort, 0);
    _nonces.remove('${protocol.name}:$internalPort');
  }

  @override
  void close() {}
}

/// All local candidates for PCP toward [gateway], best match first. Exposed
/// so the orchestrator can retry on ADDRESS_MISMATCH with another address.
List<InternetAddress> pcpLocalCandidates(
    InternetAddress gateway, Iterable<InternetAddress> locals) {
  final best = pickLocalFor(gateway, locals);
  return [
    ?best,
    for (final l in locals)
      if (best == null || l != best) l,
  ];
}
