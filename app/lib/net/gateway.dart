import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import 'connectivity/connectivity.dart';
import 'discovery.dart';
import 'ws_peer.dart' show kMaxFrameChars;

const _log = Logger('gateway');

/// Looks up a device on the local network by (normalised) Thelxis ID.
typedef TargetLookup = Future<DiscoveredPeer?> Function(String id);

/// Accepts a `/thelxis/via/<ID>` connection from [OfficeGateway].
typedef GatewayHandler = Future<void> Function(WebSocket socket, String targetId, String remoteIp);

/// Whether [host] is an address on a local network (loopback, link-local,
/// RFC 1918, IPv6 unique-local). The gateway never connects anywhere else:
/// a spoofed discovery reply must not turn it into a proxy for the internet.
bool isLocalNetworkHost(String host) {
  final a = InternetAddress.tryParse(host);
  if (a == null) return false;
  if (a.isLoopback || a.isLinkLocal) return true;
  final raw = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return raw[0] == 10 ||
        (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) ||
        (raw[0] == 192 && raw[1] == 168);
  }
  return raw.isNotEmpty && (raw[0] & 0xFE) == 0xFC;
}

/// The office gateway (PROTOCOL.md section 11): a blind pipe from an outside
/// viewer to a Thelxis device on this machine's local network.
///
/// The viewer still performs the signed handshake with the target and the
/// media stays DTLS-encrypted end to end; the gateway only sees ciphertext and
/// signaling. Frames are forwarded verbatim in both directions, except that
/// `session.turn` coming from the target is replaced by a gateway grant
/// (the target's own relay is not reachable from outside).
class OfficeGateway {
  OfficeGateway({
    required this.connectivity,
    required this.findTarget,
    this.maxPipes = 16,
    this.maxPipesPerIp = 4,
    this.helloTimeout = const Duration(seconds: 10),
    this.connectTimeout = const Duration(seconds: 5),
    this.allowTarget = isLocalNetworkHost,
  });

  final Connectivity connectivity;
  final TargetLookup findTarget;
  final int maxPipes;
  final int maxPipesPerIp;
  final Duration helloTimeout;
  final Duration connectTimeout;
  final bool Function(String host) allowTarget;

  final Map<String, int> _pipesByIp = {};
  int _pipes = 0;

  /// Pipes currently open.
  int get activePipes => _pipes;

  /// Handles one viewer connection until either side closes.
  Future<void> handle(WebSocket viewer, String targetId, String remoteIp) async {
    if (_pipes >= maxPipes || (_pipesByIp[remoteIp] ?? 0) >= maxPipesPerIp) {
      _sendError(viewer, 'rate_limited', 'Too many connections');
      unawaited(viewer.close(WebSocketStatus.policyViolation, 'rate_limited'));
      return;
    }
    _pipes++;
    _pipesByIp[remoteIp] = (_pipesByIp[remoteIp] ?? 0) + 1;
    try {
      await _Pipe(this, viewer, targetId).run();
    } on Object catch (e, st) {
      _log.e('pipe crashed', e, st);
    } finally {
      _pipes--;
      final n = (_pipesByIp[remoteIp] ?? 1) - 1;
      if (n <= 0) {
        _pipesByIp.remove(remoteIp);
      } else {
        _pipesByIp[remoteIp] = n;
      }
    }
  }
}

void _sendError(WebSocket socket, String code, String message) {
  try {
    socket.add(jsonEncode({'t': 'error', 'code': code, 'message': message}));
  } on Object {
    // The viewer is already gone.
  }
}

class _Pipe {
  _Pipe(this.gateway, this.viewer, this.targetId);

  final OfficeGateway gateway;
  final WebSocket viewer;
  final String targetId;

  WebSocket? _target;
  final Completer<void> _done = Completer<void>();
  final Completer<String> _hello = Completer<String>();
  final Queue<String> _early = Queue();
  final List<TurnGrant> _grants = [];
  String? _dialed;
  bool _finished = false;

  Future<void> run() async {
    viewer.listen(
      _onViewerFrame,
      onDone: () => _finish('viewer closed'),
      onError: (Object _) => _finish('viewer error'),
      cancelOnError: true,
    );

    final String helloFrame;
    try {
      helloFrame = await _hello.future.timeout(gateway.helloTimeout);
    } on Object {
      await _reject('error', 'No hello');
      return;
    }
    final dialed = _readHello(helloFrame);
    if (dialed == null) {
      await _reject('error', 'Expected dialer hello');
      return;
    }
    _dialed = dialed.isEmpty ? null : dialed;

    final target = await gateway.findTarget(targetId);
    if (target == null || !gateway.allowTarget(target.host)) {
      await _reject('not_found', 'No such device on this network');
      return;
    }
    final WebSocket socket;
    final client = HttpClient()
      ..connectionTimeout = gateway.connectTimeout
      ..findProxy = ((_) => 'DIRECT');
    try {
      final host = target.host.contains(':') ? '[${target.host}]' : target.host;
      socket = await WebSocket.connect(
        'ws://$host:${target.port}/thelxis',
        customClient: client,
        compression: CompressionOptions.compressionOff,
      ).timeout(gateway.connectTimeout);
    } on Object catch (e) {
      client.close(force: true);
      _log.d('target unreachable: $e');
      await _reject('not_found', 'The device did not answer');
      return;
    }
    client.close();
    if (_finished) {
      unawaited(socket.close());
      return;
    }
    _target = socket;
    socket.listen(
      _onTargetFrame,
      onDone: () => _finish('target closed'),
      onError: (Object _) => _finish('target error'),
      cancelOnError: true,
    );
    // The hello goes through exactly as the viewer wrote it.
    _forward(socket, helloFrame);
    while (_early.isNotEmpty) {
      _forward(socket, _early.removeFirst());
    }
    await _done.future;
  }

  /// Returns the `dialed` value ('' when absent) of a valid dialer hello, or
  /// null when the frame is not one.
  String? _readHello(String frame) {
    try {
      final j = jsonDecode(frame);
      if (j is! Map || j['t'] != 'hello' || j['role'] != 'dialer') return null;
      final d = j['dialed'];
      return d is String ? d : '';
    } on FormatException {
      return null;
    }
  }

  void _onViewerFrame(dynamic data) {
    if (data is! String || data.length > kMaxFrameChars) {
      _finish('bad frame from viewer');
      return;
    }
    final t = _target;
    if (t != null) {
      _forward(t, data);
    } else if (!_hello.isCompleted) {
      _hello.complete(data);
    } else if (_early.length < 64) {
      _early.add(data);
    } else {
      _finish('viewer flooded the pipe');
    }
  }

  void _onTargetFrame(dynamic data) {
    if (data is! String || data.length > kMaxFrameChars) {
      _finish('bad frame from target');
      return;
    }
    _forward(viewer, data.contains('"session"') ? _rewriteSession(data) : data);
  }

  /// Writes a frame; a socket that closed a moment ago ends the pipe instead
  /// of throwing into the event loop.
  void _forward(WebSocket to, String frame) {
    try {
      to.add(frame);
    } on StateError {
      _finish('write to a closed socket');
    }
  }

  /// Replaces `turn` of the target's `session` frame with a gateway grant.
  /// Any other frame (and anything that does not parse) passes unchanged.
  String _rewriteSession(String frame) {
    try {
      final j = jsonDecode(frame);
      if (j is! Map || j['t'] != 'session' || j['turn'] == null) return frame;
      final grant = gateway.connectivity.issueTurnGrant(dialedAddress: _dialed, gateway: true);
      if (grant != null) _grants.add(grant);
      return jsonEncode({...j, 'turn': grant?.toJson()});
    } on FormatException {
      return frame;
    }
  }

  Future<void> _reject(String code, String message) async {
    _sendError(viewer, code, message);
    _finish('rejected: $code');
    await _done.future;
  }

  void _finish(String why) {
    if (_finished) return;
    _finished = true;
    _log.d('pipe closed: $why');
    for (final g in _grants) {
      gateway.connectivity.revokeTurnGrant(g);
    }
    _grants.clear();
    // The subscriptions stay: dart:io needs the peer's close frame to come in
    // through them to finish the closing handshake. Closing is best effort:
    // both ends may already be gone.
    unawaited(viewer.close(WebSocketStatus.normalClosure, 'gateway').catchError((Object _) {}));
    unawaited(_target?.close(WebSocketStatus.normalClosure, 'gateway').catchError((Object _) {}));
    if (!_done.isCompleted) _done.complete();
  }
}
