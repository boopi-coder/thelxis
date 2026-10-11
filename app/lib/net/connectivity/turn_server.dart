// Embedded STUN/TURN responder (RFC 5389 + RFC 5766 subset sufficient for
// libwebrtc), listening on UDP 47100 and TCP 47101 (PROTOCOL.md §2, §4.3).
//
// It is a traversal aid for the device it runs on, never an open relay:
//  * credentials exist only for live sessions (see [TurnGrantStore]);
//  * permissions and channels are granted only for peers that are addresses
//    of this very machine ([isLocalPeer]);
//  * UDP relay only, at most [maxAllocationsPerGrant] allocations per grant.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/base64url.dart';
import '../../core/log.dart';
import 'interfaces.dart';
import 'socket_util.dart';
import 'stun_crypto.dart';
import 'stun_message.dart';
import 'turn_allocation.dart';
import 'turn_grants.dart';

const Logger _log = Logger('turn');

/// What [TurnServer.start] managed to bind.
class TurnBindResult {
  const TurnBindResult({
    this.udp = false,
    this.tcp = false,
    this.errors = const [],
  });

  final bool udp;
  final bool tcp;

  /// Human-readable failures (port busy ...) for the diagnostics screen.
  final List<String> errors;

  bool get anyBound => udp || tcp;
}

class TurnServer {
  TurnServer({
    required this.grants,
    required this.relayAddress,
    required this.isLocalPeer,
    this.isGatewayPeer,
    this.udpPort = 47100,
    this.tcpPort = 47101,
    this.realm = 'thelxis',
    this.maxAllocationsPerGrant = 4,
    this.maxAllocations = 64,
    this.maxTcpConnections = 64,
    this.defaultLifetime = const Duration(seconds: 600),
    this.maxLifetime = const Duration(seconds: 3600),
    Clock? clock,
  }) : _clock = clock ?? DateTime.now;

  final TurnGrantStore grants;

  /// Address reported in XOR-RELAYED-ADDRESS: this machine's LAN address, so
  /// the listener's own ICE agent can send to the relay port.
  final InternetAddress Function() relayAddress;

  /// Whether [peer] is an address of this machine (async so the caller may
  /// re-scan interfaces on a cache miss).
  final Future<bool> Function(InternetAddress peer) isLocalPeer;

  /// Extra peers that [TurnGrantRecord.gateway] grants may relay to (private
  /// addresses in our own subnets). Null: gateway grants get no extra reach.
  final Future<bool> Function(InternetAddress peer)? isGatewayPeer;

  final int udpPort;
  final int tcpPort;
  final String realm;
  final int maxAllocationsPerGrant;
  final int maxAllocations;
  final int maxTcpConnections;
  final Duration defaultLifetime;
  final Duration maxLifetime;
  final Clock _clock;

  static const int _maxTcpPerIp = 16;
  static const Duration _tcpIdleUnallocated = Duration(seconds: 30);
  static const Duration _tcpIdleMax = Duration(minutes: 15);
  static const Duration _nonceLifetime = Duration(minutes: 10);

  final List<RawDatagramSocket> _udpSockets = [];
  final Map<String, RawDatagramSocket> _udp6 = {};
  final Set<String> _udp6Failed = {};
  final List<ServerSocket> _tcpServers = [];
  final Set<_TcpLink> _tcpLinks = {};
  final Map<String, TurnAllocation> _allocations = {};
  final Set<String> _pendingAllocations = {};
  Timer? _sweeper;
  bool _running = false;

  // Secret that makes nonces unforgeable; regenerated per start.
  Uint8List _nonceSecret = Uint8List(0);

  bool get isRunning => _running;

  /// Port actually bound (differs from [udpPort] only when that is 0).
  int? boundUdpPort;
  int? boundTcpPort;

  int get allocationCount => _allocations.length;

  Future<TurnBindResult> start() async {
    if (_running) {
      return TurnBindResult(
        udp: boundUdpPort != null,
        tcp: boundTcpPort != null,
      );
    }
    final rng = Random.secure();
    _nonceSecret = Uint8List.fromList(
      List.generate(32, (_) => rng.nextInt(256)),
    );
    final errors = <String>[];

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: false,
      );
      boundUdpPort = socket.port;
      _attachUdp(socket);
    } on SocketException catch (e) {
      errors.add(
        'Port $udpPort (UDP) in use: STUN/TURN over UDP is disabled'
        '${_osError(e)}',
      );
    }

    try {
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
      boundTcpPort = server.port;
      _attachTcp(server);
      await _tryBindOptional(() async {
        final v6 = await ServerSocket.bind(
          InternetAddress.anyIPv6,
          boundTcpPort!,
          v6Only: true,
        );
        _attachTcp(v6);
      });
    } on SocketException catch (e) {
      errors.add(
        'Port $tcpPort (TCP) in use: TURN over TCP is disabled'
        '${_osError(e)}',
      );
    }

    _running = boundUdpPort != null || boundTcpPort != null;
    if (_running) {
      _sweeper = Timer.periodic(const Duration(seconds: 5), (_) => _sweep());
    }
    return TurnBindResult(
      udp: boundUdpPort != null,
      tcp: boundTcpPort != null,
      errors: errors,
    );
  }

  String _osError(SocketException e) {
    final code = e.osError?.errorCode;
    return code == null || code <= 0 ? '' : ' (error $code)';
  }

  /// Binds the UDP port on each of [addresses] (this machine's global IPv6
  /// addresses) and closes sockets of addresses that went away.
  ///
  /// A wildcard `::` bind is not usable: on Linux and macOS it is dual-stack
  /// and collides with the IPv4 wildcard socket (EADDRINUSE), on Windows it
  /// is v6-only. Binding each concrete address works everywhere and makes
  /// replies leave from the address the client sent to.
  Future<void> setUdpIpv6Addresses(Iterable<InternetAddress> addresses) async {
    final port = boundUdpPort;
    if (!_running || port == null) return;
    final wanted = {for (final a in addresses) a.address: a};
    _udp6Failed.retainAll(
      wanted.keys,
    ); // retry an address only after it left once
    for (final key in _udp6.keys.toList()) {
      if (!wanted.containsKey(key)) {
        final socket = _udp6.remove(key)!;
        _udpSockets.remove(socket);
        socket.close();
      }
    }
    for (final entry in wanted.entries) {
      if (_udp6.containsKey(entry.key) || _udp6Failed.contains(entry.key)) {
        continue;
      }
      await _tryBindOptional(() async {
        try {
          final socket = await RawDatagramSocket.bind(
            entry.value,
            port,
            reuseAddress: false,
          );
          _udp6[entry.key] = socket;
          _attachUdp(socket);
        } on SocketException {
          _udp6Failed.add(entry.key);
          rethrow;
        }
      });
    }
  }

  /// IPv6 listeners are best effort: hosts without IPv6 simply skip them.
  Future<void> _tryBindOptional(Future<void> Function() bind) async {
    try {
      await bind();
    } on SocketException catch (e) {
      _log.d('IPv6 listener not available${_osError(e)}');
    }
  }

  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
    _running = false;
    for (final a in _allocations.values) {
      a.close();
    }
    _allocations.clear();
    _pendingAllocations.clear();
    for (final s in _udpSockets) {
      s.close();
    }
    _udpSockets.clear();
    _udp6.clear();
    _udp6Failed.clear();
    for (final s in _tcpServers) {
      await s.close();
    }
    _tcpServers.clear();
    for (final link in _tcpLinks.toList()) {
      link.destroy();
    }
    _tcpLinks.clear();
    boundUdpPort = null;
    boundTcpPort = null;
  }

  // ---------------------------------------------------------------- sockets

  void _attachUdp(RawDatagramSocket socket) {
    _udpSockets.add(socket);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var i = 0; i < 64; i++) {
        final datagram = safeReceive(socket);
        if (datagram == null) break;
        _onPacket(
          _UdpLink(socket, unmapIpv4(datagram.address), datagram.port),
          datagram.data,
        );
      }
    }, onError: (Object e) => _log.d('udp socket error: $e'));
  }

  void _attachTcp(ServerSocket server) {
    _tcpServers.add(server);
    server.listen((socket) {
      InternetAddress remote;
      int remotePort;
      try {
        remote = unmapIpv4(socket.remoteAddress);
        remotePort = socket.remotePort;
      } on SocketException {
        socket.destroy(); // the peer already hung up
        return;
      }
      final fromSameIp = _tcpLinks
          .where((l) => addressKey(l.address) == addressKey(remote))
          .length;
      if (_tcpLinks.length >= maxTcpConnections || fromSameIp >= _maxTcpPerIp) {
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      final link = _TcpLink(socket, remote, remotePort, _clock);
      _tcpLinks.add(link);
      link.start(
        onPacket: (data) => _onPacket(link, data),
        onClosed: () {
          _tcpLinks.remove(link);
          _removeAllocation(link.id);
        },
      );
    }, onError: (Object e) => _log.w('tcp accept error', e));
  }

  // --------------------------------------------------------------- dispatch

  void _onPacket(TurnClientLink link, Uint8List data) {
    if (data.isEmpty) return;
    if (StunMessage.looksLikeStun(data)) {
      final message = StunMessage.parse(data);
      if (message == null) return;
      if (message.hasFingerprint && !message.verifyFingerprint()) return;
      _handleStun(link, message).catchError((Object e, StackTrace s) {
        _log.e('stun handler failed', e, s);
      });
    } else if (ChannelData.looksLikeChannelData(data)) {
      _handleChannelData(link, data);
    }
  }

  Future<void> _handleStun(TurnClientLink link, StunMessage m) async {
    if (m.isIndication) {
      if (m.method == StunMethod.send) _handleSend(link, m);
      return;
    }
    if (!m.isRequest) return;

    if (m.method == StunMethod.binding) {
      _sendSuccess(link, m, [
        StunAttribute.xorAddress(
          StunAttr.xorMappedAddress,
          link.address,
          link.port,
          m.transactionId,
        ),
      ]);
      return;
    }

    if (m.method != StunMethod.allocate &&
        m.method != StunMethod.refresh &&
        m.method != StunMethod.createPermission &&
        m.method != StunMethod.channelBind) {
      _sendError(link, m, StunError.badRequest, 'Unsupported method');
      return;
    }

    final auth = _authenticate(link, m);
    if (auth == null) return;
    switch (m.method) {
      case StunMethod.allocate:
        await _handleAllocate(link, m, auth);
      case StunMethod.refresh:
        _handleRefresh(link, m, auth);
      case StunMethod.createPermission:
        await _handleCreatePermission(link, m, auth);
      case StunMethod.channelBind:
        await _handleChannelBind(link, m, auth);
    }
  }

  // ------------------------------------------------------------------- auth

  /// Long-term credential check (RFC 5389 §10.2). Sends the 401/438/400
  /// answer itself and returns null when the request must not proceed.
  _Auth? _authenticate(TurnClientLink link, StunMessage m) {
    if (!m.hasIntegrity) {
      _sendChallenge(link, m, StunError.unauthorized, 'Unauthorized');
      return null;
    }
    final username = m.stringAttribute(StunAttr.username);
    final nonce = m.stringAttribute(StunAttr.nonce);
    if (username == null ||
        nonce == null ||
        m.attribute(StunAttr.realm) == null) {
      _sendError(link, m, StunError.badRequest, 'Missing credentials');
      return null;
    }
    if (!_nonceValid(nonce)) {
      _sendChallenge(link, m, StunError.staleNonce, 'Stale Nonce');
      return null;
    }
    final grant = grants.lookupValid(username);
    if (grant == null) {
      _sendChallenge(link, m, StunError.unauthorized, 'Unauthorized');
      return null;
    }
    final key = grant.longTermKeyFor(realm);
    if (!m.verifyIntegrity(key)) {
      _sendChallenge(link, m, StunError.unauthorized, 'Unauthorized');
      return null;
    }
    return _Auth(grant, key);
  }

  /// nonce = b64u(timestamp_ms (8 bytes) || HMAC-SHA1(secret, timestamp)[0..16])
  String _newNonce() {
    final ts = Uint8List(8);
    ByteData.sublistView(ts).setUint64(0, _clock().millisecondsSinceEpoch);
    final mac = hmacSha1(_nonceSecret, ts);
    return b64uEncode([...ts, ...mac.sublist(0, 16)]);
  }

  bool _nonceValid(String nonce) {
    final bytes = tryB64uDecode(nonce);
    if (bytes == null || bytes.length != 24) return false;
    final ts = Uint8List.fromList(bytes.sublist(0, 8));
    final mac = hmacSha1(_nonceSecret, ts).sublist(0, 16);
    if (!constantTimeEquals(mac, bytes.sublist(8))) return false;
    final issued = DateTime.fromMillisecondsSinceEpoch(
      ByteData.sublistView(ts).getUint64(0),
    );
    final age = _clock().difference(issued);
    return !age.isNegative && age < _nonceLifetime;
  }

  // ---------------------------------------------------------------- replies

  void _sendSuccess(
    TurnClientLink link,
    StunMessage request,
    List<StunAttribute> attributes, {
    Uint8List? key,
  }) {
    link.send(
      StunMessage(
        method: request.method,
        messageClass: StunClass.success,
        transactionId: request.transactionId,
        attributes: attributes,
      ).encode(integrityKey: key, fingerprint: true),
    );
  }

  /// Error answer for an authenticated request (carries integrity when the
  /// credentials were accepted).
  void _sendError(
    TurnClientLink link,
    StunMessage request,
    int code,
    String reason, {
    Uint8List? key,
  }) {
    link.send(
      StunMessage(
        method: request.method,
        messageClass: StunClass.error,
        transactionId: request.transactionId,
        attributes: [StunAttribute.errorCode(code, reason)],
      ).encode(integrityKey: key, fingerprint: true),
    );
  }

  /// 401 / 438: error plus a fresh REALM and NONCE, never integrity-protected.
  void _sendChallenge(
    TurnClientLink link,
    StunMessage request,
    int code,
    String reason,
  ) {
    link.send(
      StunMessage(
        method: request.method,
        messageClass: StunClass.error,
        transactionId: request.transactionId,
        attributes: [
          StunAttribute.errorCode(code, reason),
          StunAttribute.string(StunAttr.realm, realm),
          StunAttribute.string(StunAttr.nonce, _newNonce()),
        ],
      ).encode(fingerprint: true),
    );
  }

  // --------------------------------------------------------------- Allocate

  /// RFC 5766 §6.2: min(requested, max), but never below the default.
  Duration _lifetimeFor(StunMessage m) {
    final requested = m.uint32Attribute(StunAttr.lifetime);
    if (requested == null) return defaultLifetime;
    var d = Duration(seconds: requested);
    if (d > maxLifetime) d = maxLifetime;
    return d < defaultLifetime ? defaultLifetime : d;
  }

  int _allocationsOf(TurnGrantRecord grant) => _allocations.values
      .where((a) => a.grant.username == grant.username)
      .length;

  Future<void> _handleAllocate(
    TurnClientLink link,
    StunMessage m,
    _Auth auth,
  ) async {
    final existing = _allocations[link.id];
    if (existing != null) {
      if (_sameBytes(existing.allocateTransactionId, m.transactionId)) {
        _sendAllocateSuccess(link, m, existing, auth.key); // retransmission
      } else {
        _sendError(
          link,
          m,
          StunError.allocationMismatch,
          'Allocation Mismatch',
          key: auth.key,
        );
      }
      return;
    }
    if (_pendingAllocations.contains(link.id)) return; // retransmit in flight

    final transport = m.attribute(StunAttr.requestedTransport);
    if (transport == null || transport.value.isEmpty) {
      _sendError(
        link,
        m,
        StunError.badRequest,
        'Missing REQUESTED-TRANSPORT',
        key: auth.key,
      );
      return;
    }
    if (transport.value[0] != 17) {
      _sendError(
        link,
        m,
        StunError.unsupportedTransport,
        'Unsupported Transport Protocol',
        key: auth.key,
      );
      return;
    }
    final family = m.attribute(StunAttr.requestedAddressFamily);
    if (family != null && family.value.isNotEmpty && family.value[0] != 0x01) {
      _sendError(
        link,
        m,
        StunError.addressFamilyNotSupported,
        'Address Family not Supported',
        key: auth.key,
      );
      return;
    }
    if (_allocations.length >= maxAllocations) {
      _sendError(
        link,
        m,
        StunError.insufficientCapacity,
        'Insufficient Capacity',
        key: auth.key,
      );
      return;
    }
    if (_allocationsOf(auth.grant) >= maxAllocationsPerGrant) {
      _sendError(
        link,
        m,
        StunError.allocationQuotaReached,
        'Allocation Quota Reached',
        key: auth.key,
      );
      return;
    }

    _pendingAllocations.add(link.id);
    RawDatagramSocket relay;
    try {
      relay = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException catch (e) {
      _pendingAllocations.remove(link.id);
      _log.w('cannot bind relay socket', e);
      _sendError(
        link,
        m,
        StunError.insufficientCapacity,
        'Insufficient Capacity',
        key: auth.key,
      );
      return;
    }
    _pendingAllocations.remove(link.id);

    if (!_running || !grants.isValid(auth.grant)) {
      relay.close();
      return;
    }
    final allocation = TurnAllocation(
      link: link,
      grant: auth.grant,
      relay: relay,
      allocateTransactionId: m.transactionId,
      expiresAt: _clock().add(_lifetimeFor(m)),
    );
    _allocations[link.id] = allocation;
    relay.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var i = 0; i < 64; i++) {
        final datagram = safeReceive(relay);
        if (datagram == null) break;
        _onPeerDatagram(allocation, datagram);
      }
    }, onError: (Object e) => _log.w('relay socket error', e));
    _sendAllocateSuccess(link, m, allocation, auth.key);
  }

  void _sendAllocateSuccess(
    TurnClientLink link,
    StunMessage m,
    TurnAllocation allocation,
    Uint8List key,
  ) {
    final remaining = allocation.expiresAt.difference(_clock()).inSeconds;
    _sendSuccess(link, m, [
      StunAttribute.xorAddress(
        StunAttr.xorRelayedAddress,
        relayAddress(),
        allocation.relay.port,
        m.transactionId,
      ),
      StunAttribute.uint32(StunAttr.lifetime, max(remaining, 1)),
      StunAttribute.xorAddress(
        StunAttr.xorMappedAddress,
        link.address,
        link.port,
        m.transactionId,
      ),
    ], key: key);
  }

  // ---------------------------------------------------------------- Refresh

  void _handleRefresh(TurnClientLink link, StunMessage m, _Auth auth) {
    final allocation = _ownAllocation(link, m, auth);
    if (allocation == null) return;
    final requested = m.uint32Attribute(StunAttr.lifetime);
    if (requested == 0) {
      _removeAllocation(link.id);
      _sendSuccess(link, m, [
        StunAttribute.uint32(StunAttr.lifetime, 0),
      ], key: auth.key);
      return;
    }
    final lifetime = _lifetimeFor(m);
    allocation.expiresAt = _clock().add(lifetime);
    _sendSuccess(link, m, [
      StunAttribute.uint32(StunAttr.lifetime, lifetime.inSeconds),
    ], key: auth.key);
  }

  /// The allocation of this 5-tuple, or null after sending 437 / 441.
  TurnAllocation? _ownAllocation(
    TurnClientLink link,
    StunMessage m,
    _Auth auth,
  ) {
    final allocation = _allocations[link.id];
    if (allocation == null) {
      _sendError(
        link,
        m,
        StunError.allocationMismatch,
        'Allocation Mismatch',
        key: auth.key,
      );
      return null;
    }
    if (allocation.grant.username != auth.grant.username) {
      _sendError(
        link,
        m,
        StunError.wrongCredentials,
        'Wrong Credentials',
        key: auth.key,
      );
      return null;
    }
    return allocation;
  }

  // ------------------------------------------------------- CreatePermission

  /// Validates a peer address for permissions/channels: IPv4 only (the relay
  /// socket is IPv4) and a local address of this machine. Sends the error and
  /// returns null otherwise.
  Future<StunAddress?> _checkPeer(
    TurnClientLink link,
    StunMessage m,
    StunAddress? peer,
    _Auth auth,
  ) async {
    if (peer == null) {
      _sendError(
        link,
        m,
        StunError.badRequest,
        'Bad XOR-PEER-ADDRESS',
        key: auth.key,
      );
      return null;
    }
    final address = unmapIpv4(peer.address);
    if (address.type != InternetAddressType.IPv4) {
      _sendError(
        link,
        m,
        StunError.peerAddressFamilyMismatch,
        'Peer Address Family Mismatch',
        key: auth.key,
      );
      return null;
    }
    final allowed =
        await isLocalPeer(address) ||
        (auth.grant.gateway &&
            isGatewayPeer != null &&
            await isGatewayPeer!(address));
    if (!allowed) {
      _sendError(link, m, StunError.forbidden, 'Forbidden', key: auth.key);
      return null;
    }
    return StunAddress(address, peer.port);
  }

  Future<void> _handleCreatePermission(
    TurnClientLink link,
    StunMessage m,
    _Auth auth,
  ) async {
    if (_ownAllocation(link, m, auth) == null) return;
    final raw = m.attributesOf(StunAttr.xorPeerAddress).toList();
    if (raw.isEmpty) {
      _sendError(
        link,
        m,
        StunError.badRequest,
        'Missing XOR-PEER-ADDRESS',
        key: auth.key,
      );
      return;
    }
    final peers = <StunAddress>[];
    for (final attr in raw) {
      final peer = await _checkPeer(
        link,
        m,
        decodeXorAddress(attr.value, m.transactionId),
        auth,
      );
      if (peer == null) return;
      peers.add(peer);
    }
    final allocation = _ownAllocation(
      link,
      m,
      auth,
    ); // may be gone after awaits
    if (allocation == null) return;
    final now = _clock();
    for (final peer in peers) {
      allocation.addPermission(peer.address, now);
    }
    _sendSuccess(link, m, const [], key: auth.key);
  }

  // ------------------------------------------------------------ ChannelBind

  Future<void> _handleChannelBind(
    TurnClientLink link,
    StunMessage m,
    _Auth auth,
  ) async {
    if (_ownAllocation(link, m, auth) == null) return;
    final channelAttr = m.attribute(StunAttr.channelNumber);
    if (channelAttr == null || channelAttr.value.length < 2) {
      _sendError(
        link,
        m,
        StunError.badRequest,
        'Missing CHANNEL-NUMBER',
        key: auth.key,
      );
      return;
    }
    final number = ByteData.sublistView(channelAttr.value).getUint16(0);
    if (number < ChannelData.minChannel || number > ChannelData.maxChannel) {
      _sendError(
        link,
        m,
        StunError.badRequest,
        'Invalid channel number',
        key: auth.key,
      );
      return;
    }
    final peer = await _checkPeer(
      link,
      m,
      m.xorAddress(StunAttr.xorPeerAddress),
      auth,
    );
    if (peer == null) return;
    final allocation = _ownAllocation(link, m, auth);
    if (allocation == null) return;
    final result = allocation.bindChannel(
      number,
      peer.address,
      peer.port,
      _clock(),
    );
    if (result != ChannelBindResult.ok) {
      _sendError(
        link,
        m,
        StunError.badRequest,
        'Channel conflict',
        key: auth.key,
      );
      return;
    }
    _sendSuccess(link, m, const [], key: auth.key);
  }

  // --------------------------------------------------------------- data path

  void _handleSend(TurnClientLink link, StunMessage m) {
    final allocation = _allocations[link.id];
    final peer = m.xorAddress(StunAttr.xorPeerAddress);
    final data = m.attribute(StunAttr.data);
    if (allocation == null || peer == null || data == null) return;
    final address = unmapIpv4(peer.address);
    if (address.type != InternetAddressType.IPv4) return;
    if (!allocation.hasPermission(address, _clock())) return;
    safeSend(allocation.relay, data.value, address, peer.port);
  }

  void _handleChannelData(TurnClientLink link, Uint8List raw) {
    final allocation = _allocations[link.id];
    if (allocation == null) return;
    final frame = ChannelData.parse(raw);
    if (frame == null) return;
    final channel = allocation.channelByNumber(frame.channel, _clock());
    if (channel == null) return;
    safeSend(allocation.relay, frame.payload, channel.address, channel.port);
  }

  void _onPeerDatagram(TurnAllocation allocation, Datagram datagram) {
    final now = _clock();
    final peer = unmapIpv4(datagram.address);
    if (!allocation.hasPermission(peer, now)) return;
    final channel = allocation.channelByPeer(peer, datagram.port, now);
    if (channel != null) {
      allocation.link.send(
        ChannelData.encode(
          channel.number,
          datagram.data,
          pad: allocation.link.isStream,
        ),
      );
      return;
    }
    final tid = randomTransactionId();
    allocation.link.send(
      StunMessage(
        method: StunMethod.data,
        messageClass: StunClass.indication,
        transactionId: tid,
        attributes: [
          StunAttribute.xorAddress(
            StunAttr.xorPeerAddress,
            peer,
            datagram.port,
            tid,
          ),
          StunAttribute(StunAttr.data, datagram.data),
        ],
      ).encode(),
    );
  }

  // ------------------------------------------------------------- housekeeping

  /// Runs the periodic cleanup immediately (also used by tests).
  @visibleForTesting
  void sweepNow() => _sweep();

  void _removeAllocation(String linkId) {
    _allocations.remove(linkId)?.close();
  }

  void _sweep() {
    final now = _clock();
    for (final entry in _allocations.entries.toList()) {
      final a = entry.value;
      if (!now.isBefore(a.expiresAt) || !grants.isValid(a.grant)) {
        _removeAllocation(entry.key);
      } else {
        a.prune(now);
      }
    }
    for (final link in _tcpLinks.toList()) {
      final idle = now.difference(link.lastActivity);
      final limit = _allocations.containsKey(link.id)
          ? _tcpIdleMax
          : _tcpIdleUnallocated;
      if (idle > limit) link.destroy();
    }
    grants.purge();
  }
}

class _Auth {
  const _Auth(this.grant, this.key);

  final TurnGrantRecord grant;
  final Uint8List key;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _UdpLink implements TurnClientLink {
  _UdpLink(this._socket, this.address, this.port);

  final RawDatagramSocket _socket;

  @override
  final InternetAddress address;
  @override
  final int port;

  @override
  late final String id = 'udp|${address.address}|$port';

  @override
  bool get isStream => false;

  @override
  void send(Uint8List bytes) {
    safeSend(_socket, bytes, address, port);
  }
}

/// TCP transport: STUN messages and ChannelData frames share one byte stream
/// (RFC 5766 §11.5), so incoming bytes are re-framed before dispatch.
class _TcpLink implements TurnClientLink {
  _TcpLink(this._socket, this.address, this.port, this._clock)
    : lastActivity = _clock();

  final Socket _socket;
  final Clock _clock;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  DateTime lastActivity;

  @override
  final InternetAddress address;
  @override
  final int port;

  @override
  late final String id = 'tcp|${address.address}|$port';

  @override
  bool get isStream => true;

  void Function()? _onClosed;
  bool _closed = false;

  void start({
    required void Function(Uint8List packet) onPacket,
    required void Function() onClosed,
  }) {
    _onClosed = onClosed;
    // Writes to a reset connection fail on `done`, not at the call site.
    _socket.done.then<void>((_) {}, onError: (Object _) => destroy());
    _socket.listen(
      (chunk) {
        lastActivity = _clock();
        _buffer.add(chunk);
        if (!_drain(onPacket)) destroy();
      },
      onError: (Object _) => destroy(),
      onDone: destroy,
      cancelOnError: true,
    );
  }

  /// Emits every complete frame; false on a framing violation.
  bool _drain(void Function(Uint8List packet) onPacket) {
    var data = _buffer.takeBytes();
    var offset = 0;
    while (data.length - offset >= 4) {
      final first = data[offset];
      int frameLength;
      int consumed;
      final view = ByteData.sublistView(data, offset);
      if ((first & 0xC0) == 0) {
        if (data.length - offset < stunHeaderLength) break;
        frameLength = stunHeaderLength + view.getUint16(2);
        consumed = frameLength;
      } else if ((first & 0xC0) == 0x40) {
        frameLength = 4 + view.getUint16(2);
        consumed = (frameLength + 3) & ~3;
      } else {
        return false;
      }
      if (data.length - offset < consumed) break;
      onPacket(Uint8List.fromList(data.sublist(offset, offset + frameLength)));
      offset += consumed;
    }
    if (offset < data.length) _buffer.add(data.sublist(offset));
    return _buffer.length <= 70 * 1024;
  }

  @override
  void send(Uint8List bytes) {
    try {
      _socket.add(bytes);
    } on Object {
      destroy();
    }
  }

  /// Idempotent; also fires the close callback directly because a destroyed
  /// socket does not always deliver a done event to its subscription.
  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _onClosed?.call();
  }
}
