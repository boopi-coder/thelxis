// State of one TURN allocation (RFC 5766): the relay socket plus the
// permissions and channel bindings installed through it. I/O-free apart from
// owning the socket, so the bookkeeping rules are easy to reason about.

import 'dart:io';
import 'dart:typed_data';

import 'interfaces.dart';
import 'turn_grants.dart';

/// Permission lifetime (RFC 5766 §8): 5 minutes.
const Duration turnPermissionLifetime = Duration(minutes: 5);

/// Channel binding lifetime (RFC 5766 §11): 10 minutes.
const Duration turnChannelLifetime = Duration(minutes: 10);

/// The transport peer that owns an allocation (the 5-tuple's client side).
abstract class TurnClientLink {
  /// Unique while the transport lives: protocol + client ip + port.
  String get id;
  InternetAddress get address;
  int get port;

  /// TCP: ChannelData must be padded to a multiple of four bytes.
  bool get isStream;
  void send(Uint8List bytes);
}

/// IPv4 address as an integer. Relay peers are always IPv4 (the relay socket
/// is), and integer keys keep the per-packet lookups allocation-free.
int ipv4Key(InternetAddress address) {
  final b = unmapIpv4(address).rawAddress;
  return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

int _peerKey(InternetAddress address, int port) =>
    (ipv4Key(address) << 16) | port;

class TurnChannel {
  TurnChannel(this.number, this.address, this.port, this.expiresAt)
      : peerKey = _peerKey(address, port);

  final int number;
  final InternetAddress address;
  final int port;
  final int peerKey;
  DateTime expiresAt;
}

enum ChannelBindResult { ok, numberTaken, peerAlreadyBound }

class TurnAllocation {
  TurnAllocation({
    required this.link,
    required this.grant,
    required this.relay,
    required this.allocateTransactionId,
    required this.expiresAt,
  });

  final TurnClientLink link;
  final TurnGrantRecord grant;
  final RawDatagramSocket relay;

  /// Lets a retransmitted Allocate request be answered idempotently.
  final Uint8List allocateTransactionId;
  DateTime expiresAt;

  final Map<int, DateTime> _permissions = {};
  final Map<int, TurnChannel> _channelsByNumber = {};
  final Map<int, TurnChannel> _channelsByPeer = {};

  void addPermission(InternetAddress peer, DateTime now) {
    _permissions[ipv4Key(peer)] = now.add(turnPermissionLifetime);
  }

  bool hasPermission(InternetAddress peer, DateTime now) {
    final expiry = _permissions[ipv4Key(peer)];
    return expiry != null && now.isBefore(expiry);
  }

  TurnChannel? channelByNumber(int number, DateTime now) {
    final channel = _channelsByNumber[number];
    return channel != null && now.isBefore(channel.expiresAt) ? channel : null;
  }

  TurnChannel? channelByPeer(InternetAddress peer, int port, DateTime now) {
    final channel = _channelsByPeer[_peerKey(peer, port)];
    return channel != null && now.isBefore(channel.expiresAt) ? channel : null;
  }

  /// RFC 5766 §11.2: a number maps to one peer and a peer to one number.
  ChannelBindResult bindChannel(
      int number, InternetAddress peer, int port, DateTime now) {
    final key = _peerKey(peer, port);
    final byNumber = channelByNumber(number, now);
    if (byNumber != null && byNumber.peerKey != key) {
      return ChannelBindResult.numberTaken;
    }
    final byPeer = _channelsByPeer[key];
    if (byPeer != null &&
        now.isBefore(byPeer.expiresAt) &&
        byPeer.number != number) {
      return ChannelBindResult.peerAlreadyBound;
    }
    final expiry = now.add(turnChannelLifetime);
    final channel = byNumber ?? TurnChannel(number, unmapIpv4(peer), port, expiry);
    channel.expiresAt = expiry;
    _channelsByNumber[number] = channel;
    _channelsByPeer[key] = channel;
    addPermission(peer, now);
    return ChannelBindResult.ok;
  }

  void prune(DateTime now) {
    _permissions.removeWhere((_, expiry) => !now.isBefore(expiry));
    _channelsByNumber.removeWhere((_, c) => !now.isBefore(c.expiresAt));
    _channelsByPeer.removeWhere((_, c) => !now.isBefore(c.expiresAt));
  }

  void close() {
    _permissions.clear();
    _channelsByNumber.clear();
    _channelsByPeer.clear();
    relay.close();
  }
}
