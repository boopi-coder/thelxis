// Fake NAT-PMP / PCP router (UDP on 127.0.0.1) for tests.

import 'dart:io';
import 'dart:typed_data';

class FakePmpGateway {
  FakePmpGateway._(this.socket);

  final RawDatagramSocket socket;
  int get port => socket.port;

  InternetAddress externalIp = InternetAddress('93.184.216.34');
  int resultCode = 0;

  /// Added to the requested external port in replies (router "chooses" another).
  int portShift = 0;
  int lifetimeCap = 0; // 0 = echo the requested lifetime
  bool silent = false;
  bool sendBogusFirst = false;
  final List<Uint8List> requests = [];

  static Future<FakePmpGateway> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final g = FakePmpGateway._(s);
    s.listen(g._onEvent);
    return g;
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    requests.add(d.data);
    if (silent) return;
    final req = d.data;
    if (req.isEmpty || req[0] != 0) {
      // Version mismatch (e.g. a PCP packet): reply "unsupported version".
      socket.send(
        [0, 128 | (req.length > 1 ? req[1] & 0x7f : 0), 0, 1, 0, 0, 0, 0],
        d.address,
        d.port,
      );
      return;
    }
    final op = req[1];
    final reply = BytesBuilder();
    final view = ByteData(16);
    if (op == 0) {
      final out = Uint8List(12);
      out[1] = 128;
      ByteData.sublistView(out).setUint16(2, resultCode);
      ByteData.sublistView(out).setUint32(4, 1000);
      out.setRange(8, 12, externalIp.rawAddress);
      reply.add(out);
    } else {
      final r = ByteData.sublistView(req);
      final internal = r.getUint16(4);
      final suggested = r.getUint16(6);
      final lifetime = r.getUint32(8);
      view.setUint8(0, 0);
      view.setUint8(1, 128 + op);
      view.setUint16(2, resultCode);
      view.setUint32(4, 1000);
      view.setUint16(8, internal);
      view.setUint16(10, lifetime == 0 ? 0 : suggested + portShift);
      view.setUint32(
        12,
        lifetimeCap != 0 && lifetime > lifetimeCap ? lifetimeCap : lifetime,
      );
      reply.add(view.buffer.asUint8List());
    }
    if (sendBogusFirst) {
      // A reply from another source port must be ignored by the client.
      RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0).then((s) {
        s.send(Uint8List(16), d.address, d.port);
        s.close();
      });
    }
    socket.send(reply.takeBytes(), d.address, d.port);
  }

  void close() => socket.close();
}

class FakePcpGateway {
  FakePcpGateway._(this.socket);

  final RawDatagramSocket socket;
  int get port => socket.port;

  InternetAddress externalIp = InternetAddress('93.184.216.34');
  int resultCode = 0;
  int portShift = 0;
  bool silent = false;

  /// Only answer in NAT-PMP style (version 0), like a NAT-PMP-only router.
  bool natPmpOnly = false;
  bool corruptNonce = false;
  final List<Uint8List> requests = [];

  static Future<FakePcpGateway> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final g = FakePcpGateway._(s);
    s.listen(g._onEvent);
    return g;
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    requests.add(d.data);
    if (silent) return;
    final req = d.data;
    if (natPmpOnly || req[0] != 2) {
      socket.send([0, 128, 0, 1, 0, 0, 0, 0], d.address, d.port);
      return;
    }
    final out = BytesBuilder();
    final header = Uint8List(24);
    header[0] = 2;
    header[1] = 0x80 | (req[1] & 0x7f);
    final reqView = ByteData.sublistView(req);
    // ADDRESS_MISMATCH when the client address field is not the packet source.
    final clientIp = req.sublist(20, 24);
    var result = resultCode;
    if (!_eq(clientIp, d.address.rawAddress)) result = 12;
    header[3] = result;
    ByteData.sublistView(header).setUint32(4, reqView.getUint32(4));
    ByteData.sublistView(header).setUint32(8, 1000);
    out.add(header);
    if ((req[1] & 0x7f) == 1) {
      final body = Uint8List(36);
      body.setRange(0, 12, req.sublist(24, 36));
      if (corruptNonce) body[0] ^= 0xff;
      body[12] = req[36];
      body.setRange(16, 18, req.sublist(40, 42));
      final suggested = reqView.getUint16(42);
      final lifetime = reqView.getUint32(4);
      ByteData.sublistView(body)
          .setUint16(18, lifetime == 0 ? 0 : suggested + portShift);
      body[30] = 0xff;
      body[31] = 0xff;
      body.setRange(32, 36, externalIp.rawAddress);
      out.add(body);
    }
    socket.send(out.takeBytes(), d.address, d.port);
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void close() => socket.close();
}
