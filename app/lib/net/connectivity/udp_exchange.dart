// One request/response exchange over UDP with retransmission, as used by
// NAT-PMP (RFC 6886 §3.1) and PCP (RFC 6887 §8.1.1).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'socket_util.dart';

/// Retransmission waits after each send. RFC 6886 starts at 250 ms and
/// doubles; three rounds (1.75 s) keep startup snappy on networks without a
/// NAT-PMP/PCP router, which is the common case.
const List<Duration> defaultUdpRetries = [
  Duration(milliseconds: 250),
  Duration(milliseconds: 500),
  Duration(milliseconds: 1000),
];

/// Sends [request] to [gateway]:[port] and returns the first reply from that
/// exact endpoint for which [accept] is true, or null on timeout. Replies from
/// anywhere else are ignored (a router is trusted only at its own address).
Future<Uint8List?> udpRequest({
  required InternetAddress gateway,
  required int port,
  required Uint8List request,
  required bool Function(Uint8List response) accept,
  InternetAddress? bindAddress,
  List<Duration> retries = defaultUdpRetries,
}) async {
  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(
        bindAddress ?? InternetAddress.anyIPv4, 0);
  } on SocketException {
    return null;
  }
  final done = Completer<Uint8List?>();
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    for (var i = 0; i < 16; i++) {
      final d = safeReceive(socket);
      if (d == null) break;
      if (d.address == gateway && d.port == port && accept(d.data)) {
        if (!done.isCompleted) done.complete(d.data);
        return;
      }
    }
    // Failed sends (no route) are reported as stream errors on some
    // platforms; the retry loop handles the silence.
  }, onError: (Object _) {});
  try {
    for (final wait in retries) {
      if (!safeSend(socket, request, gateway, port)) {
        return null; // no route to that gateway
      }
      final reply = await Future.any<Uint8List?>([
        done.future,
        Future<Uint8List?>.delayed(wait, () => null),
      ]);
      if (reply != null) return reply;
    }
    return null;
  } finally {
    await sub.cancel();
    socket.close();
  }
}
