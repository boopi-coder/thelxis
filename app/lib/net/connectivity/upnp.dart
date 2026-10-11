// UPnP Internet Gateway Device client: SSDP discovery, device description,
// SOAP port mapping. Written against sloppy real-world routers: tolerant XML,
// bounded timeouts everywhere, no proxy, no persistent connections.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/log.dart';
import 'connectivity.dart';
import 'interfaces.dart';
import 'port_mapping.dart';
import 'socket_util.dart';
import 'xml_lite.dart';

const Logger _log = Logger('upnp');

const List<String> ssdpSearchTargets = [
  'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
  'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
  'urn:schemas-upnp-org:service:WANIPConnection:1',
  'urn:schemas-upnp-org:service:WANIPConnection:2',
  'urn:schemas-upnp-org:service:WANPPPConnection:1',
];

const int _maxBody = 512 * 1024;

/// Distinct device descriptions probed per discovery (a noisy or hostile LAN
/// must not make us fetch hundreds of URLs).
const int _maxLocations = 8;

Uint8List buildMSearch(String searchTarget, {int mx = 2}) => Uint8List.fromList(
    ascii.encode('M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: $mx\r\n'
        'ST: $searchTarget\r\n'
        '\r\n'));

/// Header map (lower-case names) of an SSDP "200 OK" reply; null for anything
/// else (NOTIFY traffic from other devices, garbage).
Map<String, String>? parseSsdpResponse(List<int> data) {
  final text = utf8.decode(data, allowMalformed: true);
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || !RegExp(r'^HTTP/1\.[01]\s+200').hasMatch(lines.first)) {
    return null;
  }
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] =
        line.substring(colon + 1).trim();
  }
  return headers;
}

class IgdService {
  const IgdService(this.serviceType, this.controlUrl);

  final String serviceType;
  final Uri controlUrl;
}

int _serviceRank(String type) {
  final t = type.toLowerCase();
  if (t.contains(':wanipconnection:2')) return 0;
  if (t.contains(':wanipconnection:')) return 1;
  if (t.contains(':wanpppconnection:')) return 2;
  return -1;
}

/// WANIPConnection / WANPPPConnection services of a device description with
/// their absolute control URLs, preferred first. URLs that do not point at a
/// LAN host are dropped (a hostile device must not steer us to the internet).
List<IgdService> parseIgdDescription(String xml, Uri location,
    {bool allowLoopback = false}) {
  final doc = parseXmlLenient(xml);
  final urlBase = Uri.tryParse(doc.textOf('URLBase') ?? '');
  final base = urlBase != null &&
          urlBase.hasAuthority &&
          _isLanHost(urlBase.host, allowLoopback)
      ? urlBase
      : location;

  final ranked = <(int, IgdService)>[];
  for (final service in doc.findAll('service')) {
    final type = (service.child('serviceType') ?? service.find('serviceType'))
        ?.text;
    final control = (service.child('controlURL') ?? service.find('controlURL'))
        ?.text;
    if (type == null || control == null || control.isEmpty) continue;
    final rank = _serviceRank(type);
    if (rank < 0) continue;
    var url = base.resolve(control);
    if (!_isLanHost(url.host, allowLoopback)) {
      // Broken URLBase: keep the path, trust the address that answered us.
      url = location.replace(path: url.path, query: url.query);
      if (url.query.isEmpty) url = url.replace(query: null);
    }
    if (!_isLanHost(url.host, allowLoopback) ||
        (url.scheme != 'http' && url.scheme != 'https')) {
      continue;
    }
    ranked.add((rank, IgdService(type, url)));
  }
  ranked.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final r in ranked) r.$2];
}

bool _isLanHost(String host, bool allowLoopback) {
  final address = InternetAddress.tryParse(host);
  return address != null && isLanAddress(address, allowLoopback: allowLoopback);
}

/// A bounded HTTP/1.1 client for router control endpoints.
class UpnpHttp {
  UpnpHttp({this.timeout = const Duration(seconds: 5)})
      : _client = HttpClient()
          ..connectionTimeout = timeout
          ..idleTimeout = const Duration(seconds: 2)
          ..userAgent = 'Thelxis/0.1 UPnP/1.1'
          // System proxy settings must never apply to a router on the LAN.
          ..findProxy = ((_) => 'DIRECT');

  final Duration timeout;
  final HttpClient _client;

  Future<({int status, String body})> get(Uri url) =>
      _send(() => _client.getUrl(url), null, null);

  Future<({int status, String body})> post(
          Uri url, String soapAction, String body) =>
      _send(() => _client.postUrl(url), soapAction, body);

  Future<({int status, String body})> _send(
    Future<HttpClientRequest> Function() open,
    String? soapAction,
    String? body,
  ) async {
    try {
      return await (() async {
        final request = await open();
        request.persistentConnection = false;
        // A router has no business redirecting us anywhere else.
        request.followRedirects = false;
        if (body != null) {
          final bytes = utf8.encode(body);
          // preserveHeaderCase: some firmware compares header names verbatim.
          request.headers.set('Content-Type', 'text/xml; charset="utf-8"',
              preserveHeaderCase: true);
          request.headers
              .set('SOAPAction', '"$soapAction"', preserveHeaderCase: true);
          request.contentLength = bytes.length;
          request.add(bytes);
        }
        final response = await request.close();
        final chunks = BytesBuilder(copy: false);
        await for (final chunk in response) {
          chunks.add(chunk);
          if (chunks.length > _maxBody) break;
        }
        return (
          status: response.statusCode,
          body: utf8.decode(chunks.takeBytes(), allowMalformed: true),
        );
      })()
          .timeout(timeout);
    } on TimeoutException {
      throw MappingException('router did not answer in time');
    } on SocketException catch (e) {
      throw MappingException('router unreachable: ${e.message}');
    } on HttpException catch (e) {
      throw MappingException('bad HTTP reply: ${e.message}');
    } on TlsException catch (e) {
      throw MappingException('TLS error: ${e.message}');
    }
  }

  void close() => _client.close(force: true);
}

String buildSoapEnvelope(
    String serviceType, String action, List<(String, String)> arguments) {
  final args = StringBuffer();
  for (final (name, value) in arguments) {
    args.write('<$name>${xmlEscape(value)}</$name>');
  }
  return '<?xml version="1.0"?>\r\n'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$serviceType">$args</u:$action></s:Body>'
      '</s:Envelope>\r\n';
}

class UpnpGateway implements MappingClient {
  UpnpGateway({
    required this.http,
    required this.controlUrl,
    required this.serviceType,
    required this.localAddress,
    this.description = 'Thelxis',
  });

  final UpnpHttp http;
  final Uri controlUrl;
  final String serviceType;

  /// Our address on the router's subnet: becomes NewInternalClient.
  final InternetAddress localAddress;
  final String description;

  /// Set once the router has refused leases: later requests skip the failing
  /// first attempt.
  bool _permanentLeasesOnly = false;

  @override
  MappingMethod get method => MappingMethod.upnp;

  @override
  String get gatewayId =>
      'upnp@${controlUrl.host}:${controlUrl.port}${controlUrl.path}';

  InternetAddress get routerAddress => InternetAddress(controlUrl.host);

  /// Runs a SOAP action; returns the response body element tree. UPnP faults
  /// surface as [MappingException] with the UPnP error code.
  Future<XmlNode> _call(String action, List<(String, String)> args) async {
    final reply = await http.post(controlUrl, '$serviceType#$action',
        buildSoapEnvelope(serviceType, action, args));
    final doc = parseXmlLenient(reply.body);
    if (reply.status >= 200 && reply.status < 300) return doc;
    final fault = doc.textOf('errorCode');
    final code = int.tryParse(fault ?? '');
    final text = doc.textOf('errorDescription');
    throw MappingException(
      'UPnP $action failed${text == null || text.isEmpty ? '' : ': $text'}'
      '${code == null ? ' (HTTP ${reply.status})' : ''}',
      code: code ?? reply.status,
    );
  }

  @override
  Future<InternetAddress?> externalAddress() async {
    try {
      final doc = await _call('GetExternalIPAddress', const []);
      final address = tryParseIpv4(doc.textOf('NewExternalIPAddress'));
      if (address == null || address.rawAddress.every((b) => b == 0)) return null;
      return address;
    } on MappingException catch (e) {
      // A router that answers with a SOAP fault is still alive; only a
      // transport failure means "no router here".
      if (e.code != null) return null;
      rethrow;
    }
  }

  Future<void> _addPortMapping(MappingProtocol protocol, int externalPort,
      int internalPort, int leaseSeconds) async {
    await _call('AddPortMapping', [
      ('NewRemoteHost', ''),
      ('NewExternalPort', '$externalPort'),
      ('NewProtocol', protocol == MappingProtocol.tcp ? 'TCP' : 'UDP'),
      ('NewInternalPort', '$internalPort'),
      ('NewInternalClient', localAddress.address),
      ('NewEnabled', '1'),
      ('NewPortMappingDescription', description),
      ('NewLeaseDuration', '$leaseSeconds'),
    ]);
  }

  @override
  Future<MappingGrant> map({
    required MappingProtocol protocol,
    required int internalPort,
    required int suggestedExternalPort,
    required Duration lifetime,
  }) async {
    var lease = _permanentLeasesOnly ? 0 : lifetime.inSeconds;
    var external = suggestedExternalPort;
    var conflicts = 0;
    var leaseFallbackUsed = false;
    for (;;) {
      try {
        await _addPortMapping(protocol, external, internalPort, lease);
        return MappingGrant(
            externalPort: external, lifetime: Duration(seconds: lease));
      } on MappingException catch (e) {
        final code = e.code;
        // 725 OnlyPermanentLeasesSupported (402/501 on some firmware for the
        // same reason): retry once with an unlimited lease.
        if ((code == 725 || code == 402 || code == 501) &&
            lease != 0 &&
            !leaseFallbackUsed) {
          leaseFallbackUsed = true;
          lease = 0;
          _permanentLeasesOnly = true;
          continue;
        }
        // 718 ConflictInMappingEntry: another host owns that external port.
        if (code == 718 && conflicts < 4) {
          conflicts++;
          external = suggestedExternalPort + 10 * conflicts;
          if (external > 65535) rethrow;
          continue;
        }
        rethrow;
      }
    }
  }

  @override
  Future<void> unmap({
    required MappingProtocol protocol,
    required int internalPort,
    required int externalPort,
  }) async {
    try {
      await _call('DeletePortMapping', [
        ('NewRemoteHost', ''),
        ('NewExternalPort', '$externalPort'),
        ('NewProtocol', protocol == MappingProtocol.tcp ? 'TCP' : 'UDP'),
      ]);
    } on MappingException catch (e) {
      if (e.code == 714) return; // NoSuchEntryInArray: already gone
      rethrow;
    }
  }

  @override
  void close() => http.close();
}

/// SSDP search plus description fetch. Returns the first router that proves
/// usable (answers GetExternalIPAddress).
class UpnpDiscovery {
  UpnpDiscovery({
    required this.interfaces,
    this.unicastTargets = const [],
    InternetAddress? multicastAddress,
    this.ssdpPort = 1900,
    this.ssdpTimeout = const Duration(seconds: 3),
    this.httpTimeout = const Duration(seconds: 5),
    this.allowLoopback = false,
  }) : multicastAddress = multicastAddress ?? InternetAddress('239.255.255.250');

  final List<LocalInterface> interfaces;

  /// Gateway candidates that additionally get a unicast M-SEARCH: many routers
  /// answer those even when multicast is filtered (Wi-Fi isolation, Android
  /// without a multicast lock).
  final List<InternetAddress> unicastTargets;
  final InternetAddress multicastAddress;
  final int ssdpPort;
  final Duration ssdpTimeout;
  final Duration httpTimeout;
  final bool allowLoopback;

  /// LAN addresses that answered SSDP (usable as NAT-PMP/PCP gateway hints
  /// even if their UPnP service turns out unusable). Filled during [discover].
  final List<InternetAddress> respondingRouters = [];

  Future<UpnpGateway?> discover() async {
    final endpoints = <InternetAddress>[];
    for (final iface in interfaces) {
      if (isVirtualInterfaceName(iface.name)) continue;
      for (final address in iface.addresses) {
        final a = unmapIpv4(address);
        if (a.type != InternetAddressType.IPv4) continue;
        if (isLanAddress(a, allowLoopback: allowLoopback)) {
          endpoints.add(a);
        }
      }
    }
    if (endpoints.isEmpty) return null;

    final winner = Completer<UpnpGateway?>();
    final sockets = <RawDatagramSocket>[];
    final seen = <String>{};
    var active = 0;
    var searching = true;

    void maybeFinish() {
      if (!searching && active == 0 && !winner.isCompleted) {
        winner.complete(null);
      }
    }

    void tryLocation(Uri location, InternetAddress responder) {
      active++;
      _probeLocation(location, responder).then((gateway) {
        if (gateway == null) return;
        if (winner.isCompleted) {
          gateway.close();
        } else {
          winner.complete(gateway);
        }
      }).catchError((Object e) {
        _log.d('location probe failed: $e');
      }).whenComplete(() {
        active--;
        maybeFinish();
      });
    }

    void onDatagram(Datagram d) {
      if (!isLanAddress(d.address, allowLoopback: allowLoopback)) return;
      final headers = parseSsdpResponse(d.data);
      final location = Uri.tryParse(headers?['location'] ?? '');
      if (location == null ||
          location.scheme != 'http' ||
          !_isLanHost(location.host, allowLoopback)) {
        return;
      }
      if (!respondingRouters.any((r) => r == d.address)) {
        respondingRouters.add(d.address);
      }
      if (seen.length < _maxLocations && seen.add(location.toString())) {
        tryLocation(location, d.address);
      }
    }

    final queries = [for (final st in ssdpSearchTargets) buildMSearch(st)];
    void sendAll() {
      for (final socket in sockets) {
        for (final q in queries) {
          // A failed send (no route on this interface) is not fatal: the
          // other interfaces may still reach the router.
          safeSend(socket, q, multicastAddress, ssdpPort);
          for (final target in unicastTargets) {
            safeSend(socket, q, target, ssdpPort);
          }
        }
      }
    }

    for (final local in endpoints) {
      try {
        final socket = await RawDatagramSocket.bind(local, 0);
        try {
          // Pin outgoing multicast to this interface (IP_MULTICAST_IF);
          // without it the routing table picks one and VPNs can win.
          socket.setRawOption(RawSocketOption(RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface, local.rawAddress));
        } on Object {
          // Not supported everywhere; the routing table decides then.
        }
        sockets.add(socket);
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          for (var i = 0; i < 16; i++) {
            final d = safeReceive(socket);
            if (d == null) break;
            onDatagram(d);
          }
          // Failed multicast sends (interface without a route) surface as
          // stream errors; other interfaces may still work.
        }, onError: (Object _) {});
      } on SocketException catch (e) {
        _log.d('SSDP bind on ${local.address} failed: ${e.message}');
      }
    }
    if (sockets.isEmpty) return null;

    sendAll();
    final resend = Timer(const Duration(milliseconds: 700), sendAll);
    final stop = Timer(ssdpTimeout, () {
      searching = false;
      for (final s in sockets) {
        s.close();
      }
      maybeFinish();
    });

    try {
      return await winner.future;
    } finally {
      resend.cancel();
      stop.cancel();
      for (final s in sockets) {
        s.close();
      }
    }
  }

  /// Our address on the network that reaches [url]'s host: exactly what the
  /// router must see as NewInternalClient. dart:io cannot report the local
  /// address of a client socket, so candidates are tried best subnet match
  /// first, each pinned as the connection's source address; the first one
  /// the router accepts a TCP connection from wins.
  Future<InternetAddress?> _localAddressToward(Uri url) async {
    final router = InternetAddress.tryParse(url.host);
    if (router == null) return null;
    final candidates = <InternetAddress>[
      for (final i in interfaces)
        for (final a in i.addresses)
          if (a.type == InternetAddressType.IPv4 && !isVirtualInterfaceName(i.name)) a,
    ]..sort((a, b) => commonPrefixBits(router, b).compareTo(commonPrefixBits(router, a)));
    for (final candidate in candidates.take(3)) {
      try {
        final socket = await Socket.connect(url.host, url.hasPort ? url.port : 80,
            sourceAddress: candidate, timeout: const Duration(seconds: 2));
        socket.destroy();
        return candidate;
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<UpnpGateway?> _probeLocation(Uri location, InternetAddress responder) async {
    final http = UpnpHttp(timeout: httpTimeout);
    UpnpGateway? keep;
    try {
      final description = await http.get(location);
      if (description.status != 200) return null;
      final services = parseIgdDescription(description.body, location,
          allowLoopback: allowLoopback);
      if (services.isEmpty) return null;
      final locals = <InternetAddress>[
        for (final i in interfaces)
          for (final a in i.addresses)
            if (a.type == InternetAddressType.IPv4) a,
      ];
      final local = await _localAddressToward(location) ??
          pickLocalFor(responder, locals);
      if (local == null) return null;

      UpnpGateway? fallback;
      for (final service in services) {
        final gateway = UpnpGateway(
          http: http,
          controlUrl: service.controlUrl,
          serviceType: service.serviceType,
          localAddress: local,
        );
        try {
          final external = await gateway.externalAddress();
          if (external != null) {
            keep = gateway;
            return gateway;
          }
          fallback ??= gateway; // answered, but no WAN address yet
        } on MappingException catch (e) {
          _log.d('control URL ${service.controlUrl.path} unusable: $e');
        }
      }
      keep = fallback;
      return fallback;
    } on MappingException catch (e) {
      _log.d('description fetch failed: $e');
      return null;
    } finally {
      if (keep == null) http.close();
    }
  }
}
