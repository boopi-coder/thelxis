/// Extracts the DTLS fingerprint (`a=fingerprint:` value) from an SDP, e.g.
/// `sha-256 AB:CD:...`. Normalised to lowercase algorithm and uppercase hex so
/// both peers feed identical strings into the password proof.
///
/// With `max-bundle` all m-sections share one fingerprint; when several are
/// present the `sha-256` one is preferred.
String? extractDtlsFingerprint(String? sdp) {
  if (sdp == null || sdp.isEmpty) return null;
  String? first;
  for (final raw in sdp.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (!line.startsWith('a=fingerprint:')) continue;
    final normalised = _normalise(line.substring('a=fingerprint:'.length));
    if (normalised == null) continue;
    if (normalised.startsWith('sha-256 ')) return normalised;
    first ??= normalised;
  }
  return first;
}

String? _normalise(String value) {
  final parts = value.trim().split(RegExp(r'\s+'));
  if (parts.length != 2) return null;
  return '${parts[0].toLowerCase()} ${parts[1].toUpperCase()}';
}
