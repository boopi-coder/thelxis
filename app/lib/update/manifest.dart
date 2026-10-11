import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../core/base64url.dart';
import 'update_exception.dart';
import 'update_target.dart';
import 'update_trust.dart';

/// Largest manifest accepted (PROTOCOL.md section 10 is a few KiB in practice).
const int kMaxManifestBytes = 256 * 1024;

/// Largest single asset accepted; a sanity bound against a runaway download.
const int kMaxAssetBytes = 2 * 1024 * 1024 * 1024;

/// Verifies [signature] (raw 64 bytes) over the exact [message] bytes.
typedef SignatureVerifier = Future<bool> Function(List<int> message, List<int> signature);

/// Ed25519 verifier for the release key. Defaults to the key embedded in
/// `update_trust.dart`; tests pass their own key.
SignatureVerifier ed25519Verifier({String publicKey = UpdateTrust.publicKey}) {
  final keyBytes = tryB64uDecode(publicKey);
  final algorithm = Ed25519();
  return (message, signature) async {
    if (keyBytes == null || keyBytes.length != 32 || signature.length != 64) return false;
    try {
      return await algorithm.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  };
}

/// Semantic version, reduced to what the updater needs.
class SemVer {
  const SemVer(this.major, this.minor, this.patch, {this.preRelease});

  final int major;
  final int minor;
  final int patch;

  /// `rc.1` in `0.2.0-rc.1`; null for a final release.
  final String? preRelease;

  static final _pattern = RegExp(
    r'^v?(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// Parses `1.2.3`, `v1.2.3`, `1.2.3-rc.1`, `1.2.3+4`.
  static SemVer? tryParse(String? text) {
    final m = text == null ? null : _pattern.firstMatch(text.trim());
    if (m == null) return null;
    return SemVer(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), preRelease: m[4]);
  }

  bool get isPreRelease => preRelease != null;

  /// Compares `major.minor.patch` numerically (0.1.9 < 0.1.10). Pre-release
  /// tags are deliberately ignored: the updater never offers a pre-release,
  /// and a pre-release build counts as its base version.
  int compareCore(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.preRelease == preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);
}

/// One downloadable file of a release.
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
  });

  final String name;
  final Uri url;
  final int size;

  /// Lowercase hex SHA-256 of the file.
  final String sha256;

  /// [name] reduced to a safe single path component. The manifest is signed,
  /// but a file name must never be able to leave the update directory.
  String get fileName {
    final cleaned = name.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^\.+'), '');
    return trimmed.isEmpty ? 'update.bin' : trimmed;
  }

  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  static UpdateAsset? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = json['url'];
    final size = json['size'];
    final hash = json['sha256'];
    if (name is! String || name.isEmpty || url is! String || size is! int || hash is! String) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (size <= 0 || size > kMaxAssetBytes || !_hex64.hasMatch(hash)) return null;
    return UpdateAsset(name: name, url: uri, size: size, sha256: hash.toLowerCase());
  }
}

/// The parsed, already signature-verified release manifest.
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.assets,
    this.published,
    this.notesUrl,
  });

  final SemVer version;
  final DateTime? published;
  final Uri? notesUrl;

  /// Keyed by asset id (`windows-x64`, `android-arm64-v8a`, ...). Entries that
  /// are malformed are dropped, so a bad entry can only make its own platform
  /// "have no build".
  final Map<String, UpdateAsset> assets;

  /// Parses manifest bytes. Call only after the signature verified.
  static UpdateManifest parse(List<int> bytes) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const UpdateException(UpdateErrorKind.manifest, 'manifest is not valid JSON');
    }
    if (json is! Map) {
      throw const UpdateException(UpdateErrorKind.manifest, 'manifest is not an object');
    }
    if (json['v'] != 1) {
      throw UpdateException(UpdateErrorKind.manifest, 'unsupported manifest format ${json['v']}');
    }
    final version = SemVer.tryParse(json['version'] is String ? json['version'] as String : null);
    if (version == null) {
      throw const UpdateException(UpdateErrorKind.manifest, 'manifest has no valid version');
    }
    final rawAssets = json['assets'];
    final assets = <String, UpdateAsset>{};
    if (rawAssets is Map) {
      rawAssets.forEach((key, value) {
        final asset = UpdateAsset.tryParse(value);
        if (key is String && asset != null) assets[key] = asset;
      });
    }
    final notes = json['notes_url'] is String ? Uri.tryParse(json['notes_url'] as String) : null;
    return UpdateManifest(
      version: version,
      assets: assets,
      published: json['published'] is String ? DateTime.tryParse(json['published'] as String) : null,
      notesUrl: (notes != null && notes.scheme == 'https') ? notes : null,
    );
  }

  /// True when this release should be offered to a device running [current]:
  /// a final release (pre-releases are ignored) with a higher version.
  bool isNewerThan(SemVer current) => !version.isPreRelease && version.compareCore(current) > 0;

  /// The asset for [target], or null when the release has no matching build.
  /// Android prefers the device's own ABIs in order, then the universal APK.
  UpdateAsset? assetFor(UpdateTarget target) {
    for (final key in target.assetKeys) {
      final asset = assets[key];
      if (asset != null) return asset;
    }
    return null;
  }
}
