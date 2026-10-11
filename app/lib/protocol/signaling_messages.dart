/// Messages of the signaling WebSocket (PROTOCOL.md section 4). Parsing is
/// tolerant: unknown `t` values yield null and unknown fields are ignored.
sealed class SignalingMessage {
  const SignalingMessage();

  Map<String, dynamic> toJson();

  static SignalingMessage? parse(Object? json) {
    if (json is! Map) return null;
    switch (json['t']) {
      case 'hello':
        return HsHello.fromJson(json);
      case 'hello_ack':
        final sig = json['sig'];
        return sig is String ? HsAck(sig) : null;
      case 'session':
        final sid = json['sid'];
        return sid is String ? HsSession(sid, TurnInfo.tryParse(json['turn'])) : null;
      case 'error':
        return SigError(
          json['code'] is String ? json['code'] as String : 'error',
          json['message'] is String ? json['message'] as String : '',
        );
      case 'signal':
        final data = json['data'];
        return data is Map ? SigSignal(Map<String, dynamic>.from(data)) : null;
      case 'bye':
        return SigBye(json['reason'] is String ? json['reason'] as String : 'user');
      case 'ping':
        return const SigPing();
      case 'pong':
        return const SigPong();
    }
    return null;
  }
}

/// How the dialer wants the session to be oriented.
enum HelloWant {
  /// Dialer controls the listener (dialer = viewer).
  control('control'),

  /// Reverse mode: dialer offers control of itself (dialer = host).
  beControlled('be_controlled');

  const HelloWant(this.wire);
  final String wire;

  static HelloWant? tryParse(Object? v) {
    for (final w in HelloWant.values) {
      if (w.wire == v) return w;
    }
    return null;
  }
}

/// `hello` of either role. Dialer-only fields: [want], [dialed], [resume].
class HsHello extends SignalingMessage {
  const HsHello({
    required this.isListener,
    required this.key,
    required this.name,
    required this.os,
    required this.app,
    required this.nonce,
    this.addresses = const [],
    this.want,
    this.dialed,
    this.resume,
    this.sig,
    this.version = 2,
  });

  final int version;
  final bool isListener;
  final String key;
  final String name;
  final String os;
  final String app;
  final String nonce;
  final List<String> addresses;
  final HelloWant? want;
  final String? dialed;
  final String? resume;

  /// Listener only: signature over the handshake transcript.
  final String? sig;

  factory HsHello.fromJson(Map json) {
    String s(String k, [String fallback = '']) =>
        json[k] is String ? json[k] as String : fallback;
    final addrs = json['addresses'];
    return HsHello(
      version: json['v'] is int ? json['v'] as int : 0,
      isListener: json['role'] == 'listener',
      key: s('key'),
      name: _clip(s('name', 'Unknown'), 64),
      os: _clip(s('os', 'unknown'), 16),
      app: _clip(s('app'), 32),
      nonce: s('nonce'),
      addresses: addrs is List
          ? addrs.whereType<String>().take(16).map((a) => _clip(a, 80)).toList()
          : const [],
      want: HelloWant.tryParse(json['want']),
      dialed: json['dialed'] is String ? _clip(json['dialed'] as String, 80) : null,
      resume: json['resume'] is String ? _clip(json['resume'] as String, 64) : null,
      sig: json['sig'] is String ? json['sig'] as String : null,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        't': 'hello',
        'v': version,
        'role': isListener ? 'listener' : 'dialer',
        'key': key,
        'name': name,
        'os': os,
        'app': app,
        if (want != null) 'want': want!.wire,
        'nonce': nonce,
        'addresses': addresses,
        if (dialed != null) 'dialed': dialed,
        if (resume != null) 'resume': resume,
        if (sig != null) 'sig': sig,
      };
}

class HsAck extends SignalingMessage {
  const HsAck(this.sig);
  final String sig;

  @override
  Map<String, dynamic> toJson() => {'t': 'hello_ack', 'sig': sig};
}

/// TURN credentials of the listener's embedded relay (`session.turn`).
class TurnInfo {
  const TurnInfo({
    required this.username,
    required this.credential,
    required this.udpPort,
    required this.tcpPort,
  });

  final String username;
  final String credential;
  final int udpPort;
  final int tcpPort;

  static TurnInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final u = json['username'];
    final c = json['credential'];
    final up = json['udp_port'];
    final tp = json['tcp_port'];
    if (u is! String || c is! String || up is! int || tp is! int) return null;
    return TurnInfo(username: u, credential: c, udpPort: up, tcpPort: tp);
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'credential': credential,
        'udp_port': udpPort,
        'tcp_port': tcpPort,
      };
}

class HsSession extends SignalingMessage {
  const HsSession(this.sid, this.turn);
  final String sid;
  final TurnInfo? turn;

  @override
  Map<String, dynamic> toJson() => {'t': 'session', 'sid': sid, 'turn': turn?.toJson()};
}

class SigError extends SignalingMessage {
  const SigError(this.code, [this.message = '']);
  final String code;
  final String message;

  @override
  Map<String, dynamic> toJson() => {'t': 'error', 'code': code, 'message': message};
}

/// `signal` carrying an offer, answer or ICE candidate in [data].
class SigSignal extends SignalingMessage {
  const SigSignal(this.data);
  final Map<String, dynamic> data;

  String? get type => data['type'] is String ? data['type'] as String : null;

  @override
  Map<String, dynamic> toJson() => {'t': 'signal', 'data': data};
}

class SigBye extends SignalingMessage {
  const SigBye(this.reason);
  final String reason;

  @override
  Map<String, dynamic> toJson() => {'t': 'bye', 'reason': reason};
}

class SigPing extends SignalingMessage {
  const SigPing();

  @override
  Map<String, dynamic> toJson() => {'t': 'ping'};
}

class SigPong extends SignalingMessage {
  const SigPong();

  @override
  Map<String, dynamic> toJson() => {'t': 'pong'};
}

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);
