// Local interface enumeration and IP address classification (PROTOCOL.md §3).
//
// Classification is pure (bytes in, enum out) so it can be tested without a
// network; only [scanLocalAddresses] touches the OS.

import 'dart:io';
import 'dart:typed_data';

enum Ipv4Kind {
  /// RFC 1918: 10/8, 172.16/12, 192.168/16.
  private,

  /// RFC 6598 carrier-grade NAT space 100.64/10. Also what overlay VPNs such
  /// as Tailscale use, so it is a valid LAN-like address but never "public".
  shared,
  linkLocal,
  loopback,

  /// 0.0.0.0/8.
  unspecified,
  multicast,

  /// Class E, documentation, benchmarking and other non-routable blocks.
  reserved,
  publicRoutable,
}

enum Ipv6Kind {
  /// 2000::/3 minus the tunnel and documentation prefixes below.
  globalUnicast,

  /// fc00::/7
  uniqueLocal,
  linkLocal,
  loopback,
  unspecified,
  multicast,

  /// ::ffff:0:0/96 — really an IPv4 address.
  v4Mapped,

  /// 6to4 (2002::/16) and Teredo (2001::/32): unreliable tunnels, never advertised.
  tunnel,

  /// Documentation (2001:db8::/32) and everything outside 2000::/3.
  reserved,
}

Ipv4Kind classifyIpv4Bytes(List<int> b) {
  assert(b.length == 4);
  final a0 = b[0], a1 = b[1], a2 = b[2];
  if (a0 == 0) return Ipv4Kind.unspecified;
  if (a0 == 10) return Ipv4Kind.private;
  if (a0 == 172 && a1 >= 16 && a1 <= 31) return Ipv4Kind.private;
  if (a0 == 192 && a1 == 168) return Ipv4Kind.private;
  if (a0 == 100 && a1 >= 64 && a1 <= 127) return Ipv4Kind.shared;
  if (a0 == 127) return Ipv4Kind.loopback;
  if (a0 == 169 && a1 == 254) return Ipv4Kind.linkLocal;
  if (a0 >= 224 && a0 <= 239) return Ipv4Kind.multicast;
  if (a0 >= 240) return Ipv4Kind.reserved;
  if (a0 == 192 && a1 == 0 && a2 == 0) return Ipv4Kind.reserved;
  if (a0 == 192 && a1 == 0 && a2 == 2) return Ipv4Kind.reserved;
  if (a0 == 192 && a1 == 88 && a2 == 99) return Ipv4Kind.reserved;
  if (a0 == 198 && (a1 == 18 || a1 == 19)) return Ipv4Kind.reserved;
  if (a0 == 198 && a1 == 51 && a2 == 100) return Ipv4Kind.reserved;
  if (a0 == 203 && a1 == 0 && a2 == 113) return Ipv4Kind.reserved;
  return Ipv4Kind.publicRoutable;
}

Ipv6Kind classifyIpv6Bytes(List<int> b) {
  assert(b.length == 16);
  var allZeroPrefix = true;
  for (var i = 0; i < 15; i++) {
    if (b[i] != 0) {
      allZeroPrefix = false;
      break;
    }
  }
  if (allZeroPrefix) {
    if (b[15] == 0) return Ipv6Kind.unspecified;
    if (b[15] == 1) return Ipv6Kind.loopback;
  }
  if (b[0] == 0xff) return Ipv6Kind.multicast;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return Ipv6Kind.linkLocal;
  if ((b[0] & 0xfe) == 0xfc) return Ipv6Kind.uniqueLocal;
  var mappedPrefix = true;
  for (var i = 0; i < 10; i++) {
    if (b[i] != 0) {
      mappedPrefix = false;
      break;
    }
  }
  if (mappedPrefix && b[10] == 0xff && b[11] == 0xff) return Ipv6Kind.v4Mapped;
  if ((b[0] & 0xe0) != 0x20) return Ipv6Kind.reserved;
  if (b[0] == 0x20 && b[1] == 0x02) return Ipv6Kind.tunnel;
  if (b[0] == 0x20 && b[1] == 0x01) {
    if (b[2] == 0 && b[3] == 0) return Ipv6Kind.tunnel;
    if (b[2] == 0x0d && b[3] == 0xb8) return Ipv6Kind.reserved;
  }
  return Ipv6Kind.globalUnicast;
}

/// Parses a dotted-quad IPv4 literal; null for anything else.
InternetAddress? tryParseIpv4(String? text) {
  if (text == null) return null;
  final parts = text.trim().split('.');
  if (parts.length != 4) return null;
  final bytes = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    final p = parts[i];
    if (p.isEmpty || p.length > 3) return null;
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return null;
    bytes[i] = v;
  }
  return InternetAddress.fromRawAddress(bytes);
}

/// Turns ::ffff:a.b.c.d into the plain IPv4 address; everything else is
/// returned unchanged. Dual-stack sockets report IPv4 peers this way.
InternetAddress unmapIpv4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv6) return address;
  final raw = address.rawAddress;
  if (classifyIpv6Bytes(raw) != Ipv6Kind.v4Mapped) return address;
  return InternetAddress.fromRawAddress(
    Uint8List.fromList(raw.sublist(12, 16)),
    type: InternetAddressType.IPv4,
  );
}

/// Stable lookup key for an address (ignores IPv6 scope ids and v4-mapping).
String addressKey(InternetAddress address) {
  final raw = unmapIpv4(address).rawAddress;
  final sb = StringBuffer();
  for (final byte in raw) {
    sb.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Ipv4Kind? ipv4KindOf(InternetAddress address) {
  final a = unmapIpv4(address);
  if (a.type != InternetAddressType.IPv4) return null;
  return classifyIpv4Bytes(a.rawAddress);
}

/// True when [ip] is an IPv4 literal that peers on the internet can reach.
bool isPublicIpv4(String? ip) {
  final a = tryParseIpv4(ip);
  return a != null &&
      classifyIpv4Bytes(a.rawAddress) == Ipv4Kind.publicRoutable;
}

/// Kind of an IPv4 literal, or null when [ip] is not one.
Ipv4Kind? classifyIpv4(String? ip) {
  final a = tryParseIpv4(ip);
  return a == null ? null : classifyIpv4Bytes(a.rawAddress);
}

/// Addresses a home router or IGD may legitimately have on our network.
bool isLanAddress(InternetAddress address, {bool allowLoopback = false}) {
  final a = unmapIpv4(address);
  if (a.type == InternetAddressType.IPv4) {
    final kind = classifyIpv4Bytes(a.rawAddress);
    return kind == Ipv4Kind.private ||
        kind == Ipv4Kind.shared ||
        kind == Ipv4Kind.linkLocal ||
        (allowLoopback && kind == Ipv4Kind.loopback);
  }
  final kind = classifyIpv6Bytes(a.rawAddress);
  return kind == Ipv6Kind.uniqueLocal ||
      kind == Ipv6Kind.linkLocal ||
      (allowLoopback && kind == Ipv6Kind.loopback);
}

/// "ip:port" or "[v6]:port".
String formatHostPort(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

/// Inverse of [formatHostPort]; null when [text] is not a literal IP + port.
({String host, int port})? parseIpPort(String? text) {
  if (text == null) return null;
  final s = text.trim();
  String host;
  String portText;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end < 0 || end + 1 >= s.length || s[end + 1] != ':') return null;
    host = s.substring(1, end);
    portText = s.substring(end + 2);
  } else {
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    host = s.substring(0, colon);
    portText = s.substring(colon + 1);
  }
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) return null;
  if (InternetAddress.tryParse(host) == null) return null;
  return (host: host, port: port);
}

/// Like [parseIpPort] but the host may also be a DNS name.
({String host, int port})? parseHostPort(String? text) {
  final ip = parseIpPort(text);
  if (ip != null) return ip;
  if (text == null) return null;
  final s = text.trim();
  final colon = s.lastIndexOf(':');
  if (colon <= 0 || s.contains('[') || s.indexOf(':') != colon) return null;
  final port = int.tryParse(s.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  return (host: s.substring(0, colon), port: port);
}

/// Picks the local address that most likely sits on the same subnet as
/// [gateway]: same /24 first, otherwise the longest common prefix. Dart does
/// not expose netmasks, so this is a heuristic; callers that hold a real
/// connection to the gateway should prefer its local address.
InternetAddress? pickLocalFor(
  InternetAddress gateway,
  Iterable<InternetAddress> locals,
) {
  final g = unmapIpv4(gateway);
  if (g.type != InternetAddressType.IPv4) return null;
  InternetAddress? best;
  var bestBits = -1;
  for (final local in locals) {
    final l = unmapIpv4(local);
    if (l.type != InternetAddressType.IPv4) continue;
    final bits = _commonPrefixBits(g.rawAddress, l.rawAddress);
    if (bits > bestBits) {
      bestBits = bits;
      best = l;
    }
  }
  return best;
}

/// Number of leading bits two IPv4 addresses share (0 when either is not IPv4).
int commonPrefixBits(InternetAddress a, InternetAddress b) {
  final x = unmapIpv4(a), y = unmapIpv4(b);
  if (x.type != InternetAddressType.IPv4 ||
      y.type != InternetAddressType.IPv4) {
    return 0;
  }
  return _commonPrefixBits(x.rawAddress, y.rawAddress);
}

int _commonPrefixBits(List<int> a, List<int> b) {
  var bits = 0;
  for (var i = 0; i < 4; i++) {
    final x = a[i] ^ b[i];
    if (x == 0) {
      bits += 8;
      continue;
    }
    for (var bit = 7; bit >= 0; bit--) {
      if ((x >> bit) & 1 != 0) return bits;
      bits++;
    }
  }
  return bits;
}

/// One network interface as seen by the OS (decoupled from `dart:io` so tests
/// can feed synthetic machines).
class LocalInterface {
  const LocalInterface(
    this.name,
    this.addresses, {
    this.prefixLengths = const {},
  });

  final String name;
  final List<InternetAddress> addresses;

  /// Subnet prefix length per `address.address`, when the OS reported it.
  /// Missing entries are treated as /24 for IPv4.
  final Map<String, int> prefixLengths;
}

typedef InterfaceLister = Future<List<LocalInterface>> Function();

/// Names of bridges/tunnels that only exist inside this machine (containers,
/// hypervisors, Apple wireless direct links). Addressing them to a remote peer
/// is useless and can even point it at *its own* docker0.
const List<String> _virtualPrefixes = [
  'docker', 'br-', 'veth', 'virbr', 'vmnet', 'vboxnet', 'lxc', 'lxd', 'cni', //
  'flannel', 'cali', 'awdl', 'llw', 'anpi', 'podman',
];

bool isVirtualInterfaceName(String name) {
  final n = name.toLowerCase();
  return _virtualPrefixes.any(n.startsWith);
}

Future<List<LocalInterface>> listSystemInterfaces() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: true,
    type: InternetAddressType.any,
  );
  return [
    for (final i in interfaces)
      LocalInterface(
        i.name,
        List.of(i.addresses),
        prefixLengths: {for (final a in i.addresses) a.address: a.prefixLength},
      ),
  ];
}

/// Everything the rest of the module needs to know about this machine's
/// addresses.
class LocalAddresses {
  const LocalAddresses({
    this.lanIPv4 = const [],
    this.publicIPv4 = const [],
    this.globalIPv6 = const [],
    this.all = const {},
    this.interfaces = const [],
    this.privateSubnets = const [],
  });

  /// RFC 1918 and 100.64/10 addresses on real (non-virtual) interfaces,
  /// most useful first.
  final List<InternetAddress> lanIPv4;

  /// Public IPv4 assigned directly to an interface (VPS, bridged modem).
  final List<InternetAddress> publicIPv4;
  final List<InternetAddress> globalIPv6;

  /// [addressKey] of every address of every interface (also virtual and
  /// link-local ones, plus loopback): the set of "peers on this machine".
  final Set<String> all;

  /// The raw interfaces, for components that bind per interface (SSDP).
  final List<LocalInterface> interfaces;

  /// Directly connected RFC 1918 subnets of this machine (all interfaces).
  final List<Ipv4Subnet> privateSubnets;

  bool isLocal(InternetAddress address) => all.contains(addressKey(address));

  /// A private (RFC 1918) IPv4 address inside one of our own subnets: what an
  /// office-gateway grant may relay to besides this machine itself.
  bool isInDirectPrivateSubnet(InternetAddress address) {
    final a = unmapIpv4(address);
    if (a.type != InternetAddressType.IPv4) return false;
    if (classifyIpv4Bytes(a.rawAddress) != Ipv4Kind.private) return false;
    return privateSubnets.any((s) => s.contains(a));
  }
}

/// An IPv4 network (address masked to [prefix] bits).
class Ipv4Subnet {
  const Ipv4Subnet(this.network, this.prefix);

  factory Ipv4Subnet.of(InternetAddress address, int prefix) {
    final p = prefix >= 8 && prefix <= 32 ? prefix : 24;
    return Ipv4Subnet(_ipv4Int(address) & _mask(p), p);
  }

  final int network;
  final int prefix;

  bool contains(InternetAddress address) =>
      (_ipv4Int(address) & _mask(prefix)) == network;
}

int _ipv4Int(InternetAddress a) {
  final b = a.rawAddress;
  return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

int _mask(int prefix) =>
    prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;

/// Pure part of the scan.
LocalAddresses classifyInterfaces(List<LocalInterface> interfaces) {
  final lan = <InternetAddress>[];
  final pub = <InternetAddress>[];
  final v6 = <InternetAddress>[];
  final all = <String>{
    addressKey(InternetAddress.loopbackIPv4),
    addressKey(InternetAddress.loopbackIPv6),
  };
  final seen = <String>{};
  final subnets = <Ipv4Subnet>[];

  for (final iface in interfaces) {
    final virtual = isVirtualInterfaceName(iface.name);
    for (final raw in iface.addresses) {
      final address = unmapIpv4(raw);
      all.add(addressKey(address));
      if (address.type == InternetAddressType.IPv4 &&
          classifyIpv4Bytes(address.rawAddress) == Ipv4Kind.private) {
        subnets.add(
          Ipv4Subnet.of(address, iface.prefixLengths[raw.address] ?? 24),
        );
      }
      if (virtual || !seen.add(addressKey(address))) continue;
      if (address.type == InternetAddressType.IPv4) {
        switch (classifyIpv4Bytes(address.rawAddress)) {
          case Ipv4Kind.private || Ipv4Kind.shared:
            lan.add(address);
          case Ipv4Kind.publicRoutable:
            pub.add(address);
          default:
        }
      } else if (classifyIpv6Bytes(address.rawAddress) ==
          Ipv6Kind.globalUnicast) {
        // Strip a zone id if the platform reported one; global addresses
        // do not need it.
        v6.add(
          address.address.contains('%')
              ? InternetAddress.fromRawAddress(address.rawAddress)
              : address,
        );
      }
    }
  }

  // Stable bucket order (List.sort is not stable): 192.168/16, 10/8,
  // 172.16/12, then 100.64/10 overlay networks.
  int rank(InternetAddress a) {
    final b = a.rawAddress;
    if (b[0] == 192) return 0;
    if (b[0] == 10) return 1;
    if (b[0] == 172) return 2;
    return 3;
  }

  final ranked = [
    for (var r = 0; r < 4; r++) ...lan.where((a) => rank(a) == r),
  ];
  return LocalAddresses(
    lanIPv4: List.unmodifiable(ranked),
    publicIPv4: List.unmodifiable(pub),
    globalIPv6: List.unmodifiable(v6),
    all: Set.unmodifiable(all),
    interfaces: List.unmodifiable(interfaces),
    privateSubnets: List.unmodifiable(subnets),
  );
}

/// Enumerates the machine's interfaces. Never throws (some platforms refuse
/// enumeration without permissions); returns an empty result instead.
Future<LocalAddresses> scanLocalAddresses([InterfaceLister? lister]) async {
  try {
    return classifyInterfaces(await (lister ?? listSystemInterfaces)());
  } on Object {
    return classifyInterfaces(const []);
  }
}
