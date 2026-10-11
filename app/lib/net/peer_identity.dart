import '../core/base64url.dart';
import '../core/thelxis_id.dart';

/// A peer whose key has been proven by the signed handshake. [id] is derived
/// from [key], never taken from the wire.
class PeerIdentity {
  const PeerIdentity({
    required this.key,
    required this.id,
    required this.name,
    required this.os,
    this.app = '',
    this.addresses = const [],
  });

  /// base64url public key.
  final String key;

  /// Normalised 16-character Thelxis ID.
  final String id;
  final String name;
  final String os;
  final String app;
  final List<String> addresses;

  String get formattedId => formatThelxisId(id);

  /// Builds an identity from handshake fields; null if [key] is not a valid
  /// 32-byte public key.
  static PeerIdentity? fromHello({
    required String key,
    required String name,
    required String os,
    required String app,
    required List<String> addresses,
  }) {
    final raw = tryB64uDecode(key);
    if (raw == null || raw.length != 32) return null;
    return PeerIdentity(
      key: key,
      id: thelxisIdFromPublicKey(raw),
      name: name,
      os: os,
      app: app,
      addresses: addresses,
    );
  }
}

/// Name/OS/version this device announces about itself.
class LocalPeerInfo {
  const LocalPeerInfo({required this.name, required this.os, required this.app});
  final String name;
  final String os;
  final String app;
}
