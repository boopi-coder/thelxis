// Exception-safe UDP helpers. On Windows an ICMP "port unreachable" makes the
// next recv on an unconnected UDP socket fail with WSAECONNRESET, and sends
// can fail with "network unreachable" while an interface flaps. None of that
// may take a listener down.

import 'dart:io';

/// Next queued datagram, or null when none is waiting or the read failed.
Datagram? safeReceive(RawDatagramSocket socket) {
  try {
    return socket.receive();
  } on SocketException {
    return null;
  }
}

/// Sends [data]; false when the OS refused it.
bool safeSend(
  RawDatagramSocket socket,
  List<int> data,
  InternetAddress to,
  int port,
) {
  try {
    return socket.send(data, to, port) > 0;
  } on SocketException {
    return false;
  }
}
