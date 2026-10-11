import '../core/thelxis_id.dart';
import '../l10n/strings.dart';
import 'net_address.dart';

/// What the user asked to connect to, parsed from the Connect field, an
/// invite link or a command-palette entry (PROTOCOL.md section 3).
class ConnectTarget {
  const ConnectTarget({this.id, this.name, this.addresses = const []});

  /// Expected Thelxis ID (normalised); null for a bare address (TOFU).
  final String? id;

  /// Display name hint from an invite link.
  final String? name;
  final List<NetAddress> addresses;

  bool get hasId => id != null;

  /// Only an ID was given: addresses must come from the address book or LAN
  /// discovery.
  bool get needsResolution => addresses.isEmpty;
}

class ConnectParseResult {
  const ConnectParseResult.ok(ConnectTarget this.target) : error = null;
  const ConnectParseResult.error(String this.error) : target = null;

  final ConnectTarget? target;
  final String? error;

  bool get isOk => target != null;
}


/// Accepted forms:
/// * `thelxis://connect?id=<ID>&n=<name>&a=<addr>,<addr>`
/// * `ID@host[:port]` (also `ID@[v6]:port`, several comma-separated addresses)
/// * `host[:port]` / `[v6]:port` (trust on first use)
/// * a bare Thelxis ID (resolved through the address book / LAN)
ConnectParseResult parseConnectInput(String input) {
  final text = input.trim();
  if (text.isEmpty) return ConnectParseResult.error(S.current.t('parse.unrecognised'));

  if (text.toLowerCase().startsWith('thelxis:')) return _parseInvite(text);

  final at = text.indexOf('@');
  if (at >= 0) {
    final id = parseThelxisId(text.substring(0, at));
    if (id == null) {
      return ConnectParseResult.error(S.current.t('parse.badId'));
    }
    final addrs = parseAddressList(text.substring(at + 1).split(','));
    if (addrs.isEmpty) {
      return ConnectParseResult.error(S.current.t('parse.badAddress'));
    }
    return ConnectParseResult.ok(ConnectTarget(id: id, addresses: addrs));
  }

  final id = parseThelxisId(text);
  if (id != null) return ConnectParseResult.ok(ConnectTarget(id: id));

  // A single word that is nearly an ID is far more likely a typo than a host.
  if (_looksLikeBrokenId(text)) {
    return ConnectParseResult.error(S.current.t('parse.brokenId'));
  }

  final addr = NetAddress.parse(text);
  if (addr != null) return ConnectParseResult.ok(ConnectTarget(addresses: [addr]));

  return ConnectParseResult.error(S.current.t('parse.unrecognised'));
}

bool _looksLikeBrokenId(String text) {
  if (text.contains('.') || text.contains(':')) return false;
  final compact = text.replaceAll(RegExp(r'[-\s]'), '');
  if (compact.length < 12 || compact.length > 20 || compact.length == kThelxisIdLength) {
    return false;
  }
  return RegExp(r'^[0-9A-Za-z]+$').hasMatch(compact) && RegExp(r'\d').hasMatch(compact);
}

ConnectParseResult _parseInvite(String text) {
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return ConnectParseResult.error(S.current.t('parse.badInvite'));
  }
  if (uri.scheme.toLowerCase() != 'thelxis' || uri.host.toLowerCase() != 'connect') {
    return ConnectParseResult.error(S.current.t('parse.notInvite'));
  }
  final id = parseThelxisId(uri.queryParameters['id']);
  if (id == null) {
    return ConnectParseResult.error(S.current.t('parse.inviteNoId'));
  }
  final a = uri.queryParameters['a'] ?? '';
  final name = uri.queryParameters['n'];
  return ConnectParseResult.ok(ConnectTarget(
    id: id,
    name: (name == null || name.trim().isEmpty) ? null : name.trim(),
    addresses: parseAddressList(a.split(',')),
  ));
}

/// Builds `thelxis://connect?id=…&n=…&a=…` for sharing access.
String buildInviteLink({
  required String id,
  required String name,
  required List<String> addresses,
}) {
  final parts = <String>[
    'id=$id',
    'n=${Uri.encodeComponent(name)}',
    if (addresses.isNotEmpty) 'a=${_encodeAddresses(addresses)}',
  ];
  return 'thelxis://connect?${parts.join('&')}';
}

/// Keeps `: [ ] ,` readable (they are safe inside a query value here and are
/// the address/list syntax) while escaping everything else.
String _encodeAddresses(List<String> addresses) {
  return Uri.encodeComponent(addresses.join(','))
      .replaceAll('%3A', ':')
      .replaceAll('%5B', '[')
      .replaceAll('%5D', ']')
      .replaceAll('%2C', ',');
}

/// `ID@address` form for copy/paste, using the best advertised address.
String buildIdAtAddress(String id, String? address) =>
    address == null ? formatThelxisId(id) : '${formatThelxisId(id)}@$address';
