// Trust anchor for over-the-air updates (PROTOCOL.md §10).
//
// OWNERSHIP: architect. The matching private key exists only in the GitHub
// Actions secret UPDATE_SIGNING_KEY (and the owner's offline backup); CI signs
// update.json with it. An update whose manifest signature does not verify
// against this key is never installed — even if GitHub or TLS were
// compromised.

abstract final class UpdateTrust {
  /// Ed25519 public key, raw 32 bytes, base64url without padding.
  static const String publicKey = 'CCI7L8D_i2lGhmSZvtjKdTP76EbtWRipgrIw3_Cdgvk';

  /// Where release manifests are fetched from (the only non-peer network
  /// endpoint the app ever contacts, and only when updates are enabled).
  static const String repo = 'boopi-coder/thelxis';

  static const String manifestUrl =
      'https://github.com/$repo/releases/latest/download/update.json';
  static const String signatureUrl =
      'https://github.com/$repo/releases/latest/download/update.json.sig';
}
