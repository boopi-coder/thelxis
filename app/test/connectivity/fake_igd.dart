// A fake UPnP Internet Gateway Device for tests: an SSDP responder (UDP), a
// device-description endpoint and a SOAP control endpoint (HTTP), all on
// 127.0.0.1.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:thelxis/net/connectivity/xml_lite.dart';

const String wanIpService = 'urn:schemas-upnp-org:service:WANIPConnection:1';

String igdDescription({
  String serviceType = wanIpService,
  String controlUrl = '/ctl/IPConn',
  String urlBase = '',
}) =>
    '<?xml version="1.0"?>\n'
    '<root xmlns="urn:schemas-upnp-org:device-1-0">'
    '<specVersion><major>1</major><minor>0</minor></specVersion>'
    '$urlBase'
    '<device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>'
    '<friendlyName>Fake Router</friendlyName>'
    '<deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>'
    '<deviceList><device><deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>'
    '<serviceList><service><serviceType>$serviceType</serviceType>'
    '<serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>'
    '<controlURL>$controlUrl</controlURL><eventSubURL>/evt/IPConn</eventSubURL>'
    '<SCPDURL>/WANIPCn.xml</SCPDURL></service></serviceList>'
    '</device></deviceList></device></deviceList></device></root>';

class SoapCall {
  SoapCall(this.action, this.args, this.soapAction);

  final String action;
  final Map<String, String> args;
  final String soapAction;
}

class FakeIgd {
  FakeIgd._(this._udp, this._http, this.descriptionBuilder);

  final RawDatagramSocket _udp;
  final HttpServer _http;
  String Function(Uri base) descriptionBuilder;

  int get ssdpPort => _udp.port;
  int get httpPort => _http.port;
  Uri get location => Uri.parse('http://127.0.0.1:$httpPort/rootDesc.xml');

  String externalIp = '93.184.216.34';

  /// Error codes returned (in order) by successive AddPortMapping calls;
  /// once empty the call succeeds. Entries that are null mean "succeed".
  final List<int?> addPortMappingErrors = [];

  /// Error code for DeletePortMapping, if any.
  int? deleteError;

  /// LOCATION header sent in SSDP replies (defaults to [location]).
  String? locationOverride;

  /// Answer SSDP at all?
  bool answerSsdp = true;

  final List<SoapCall> calls = [];
  final List<String> searchTargets = [];

  /// "TCP:47100" -> owner of that external port.
  final Map<String, ({String client, int internalPort})> entries = {};

  /// "TCP:47100" -> internal port (compat view for assertions).
  Map<String, int> get mappings => {
    for (final e in entries.entries) e.key: e.value.internalPort,
  };

  /// Like many cheap routers: AddPortMapping replaces a foreign entry
  /// instead of answering 718.
  bool overwriteForeign = false;

  /// Does the router implement GetSpecificPortMappingEntry? When not, the
  /// action answers with [getSpecificFault].
  bool supportsGetSpecific = true;
  int getSpecificFault = 401;

  /// Another PC behind the same router owns this port.
  void preload(
    String protocol,
    int externalPort, {
    String client = '192.168.1.99',
    int internalPort = 47100,
  }) {
    entries['$protocol:$externalPort'] = (
      client: client,
      internalPort: internalPort,
    );
  }

  static Future<FakeIgd> start({String Function(Uri base)? description}) async {
    final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final igd = FakeIgd._(udp, http, description ?? (_) => igdDescription());
    udp.listen(igd._onSsdp);
    http.listen(igd._onHttp);
    return igd;
  }

  void _onSsdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final d = _udp.receive();
    if (d == null) return;
    final text = utf8.decode(d.data, allowMalformed: true);
    if (!text.startsWith('M-SEARCH')) return;
    final st = RegExp(
      r'^ST:\s*(.+)$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text)?.group(1)?.trim();
    if (st != null) searchTargets.add(st);
    if (!answerSsdp) return;
    final reply =
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=120\r\n'
        'LOCATION: ${locationOverride ?? location}\r\n'
        'SERVER: FakeOS/1.0 UPnP/1.1 fakeigd/1.0\r\n'
        'ST: ${st ?? 'upnp:rootdevice'}\r\n'
        'USN: uuid:fake-igd::${st ?? 'upnp:rootdevice'}\r\n\r\n';
    _udp.send(utf8.encode(reply), d.address, d.port);
  }

  Future<void> _onHttp(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path == '/rootDesc.xml') {
      request.response
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(descriptionBuilder(location));
      await request.response.close();
      return;
    }
    if (request.method == 'POST') {
      final body = await utf8.decodeStream(request);
      final soapAction = (request.headers.value('soapaction') ?? '').replaceAll(
        '"',
        '',
      );
      final action = soapAction.split('#').last;
      final doc = parseXmlLenient(body);
      final actionNode = doc.find(action);
      final args = <String, String>{
        for (final c in actionNode?.children ?? <XmlNode>[]) c.name: c.text,
      };
      calls.add(SoapCall(action, args, soapAction));
      await _respond(request, action, args);
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<void> _respond(
    HttpRequest request,
    String action,
    Map<String, String> args,
  ) async {
    int? error;
    final key = '${args['NewProtocol']}:${args['NewExternalPort']}';
    String? specificBody;
    switch (action) {
      case 'AddPortMapping':
        if (addPortMappingErrors.isNotEmpty) {
          error = addPortMappingErrors.removeAt(0);
        }
        final clientIp = args['NewInternalClient'] ?? '';
        final existing = entries[key];
        if (error == null &&
            existing != null &&
            existing.client != clientIp &&
            !overwriteForeign) {
          error = 718;
        }
        if (error == null) {
          entries[key] = (
            client: clientIp,
            internalPort: int.parse(args['NewInternalPort']!),
          );
        }
      case 'GetSpecificPortMappingEntry':
        if (!supportsGetSpecific) {
          error = getSpecificFault;
        } else if (entries[key] == null) {
          error = 714;
        } else {
          final e = entries[key]!;
          specificBody =
              '<NewInternalPort>${e.internalPort}</NewInternalPort>'
              '<NewInternalClient>${e.client}</NewInternalClient>'
              '<NewEnabled>1</NewEnabled>'
              '<NewPortMappingDescription>x</NewPortMappingDescription>'
              '<NewLeaseDuration>0</NewLeaseDuration>';
        }
      case 'DeletePortMapping':
        error = deleteError;
        if (error == null) entries.remove(key);
    }
    if (error != null) {
      request.response.statusCode = 500;
      request.response.write(
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><s:Fault><faultcode>s:Client</faultcode>'
        '<faultstring>UPnPError</faultstring><detail>'
        '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
        '<errorCode>$error</errorCode><errorDescription>test fault</errorDescription>'
        '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
      );
      await request.response.close();
      return;
    }
    final inner = action == 'GetExternalIPAddress'
        ? '<NewExternalIPAddress>$externalIp</NewExternalIPAddress>'
        : specificBody ?? '';
    request.response
      ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
      ..write(
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:${action}Response xmlns:u="$wanIpService">$inner'
        '</u:${action}Response></s:Body></s:Envelope>',
      );
    await request.response.close();
  }

  Future<void> close() async {
    _udp.close();
    await _http.close(force: true);
  }
}
