import 'models.dart';

/// Messages on the reliable `control` data channel (PROTOCOL.md sections 5.1
/// and 5.2). Parsing returns null for unknown `t` values so callers can ignore
/// them as the protocol requires.
sealed class ControlMessage {
  const ControlMessage();

  Map<String, dynamic> toJson();

  static ControlMessage? parse(Object? json) {
    if (json is! Map) return null;
    switch (json['t']) {
      case 'hello':
        return HelloMessage.fromJson(json);
      case 'auth':
        return AuthMessage.fromJson(json);
      case 'auth_result':
        return AuthResultMessage.fromJson(json);
      case 'displays':
        return DisplaysMessage.fromJson(json);
      case 'select_display':
        final id = json['id'];
        return id == null ? null : SelectDisplayMessage(id.toString());
      case 'quality':
        final p = QualityPreset.tryParse(json['preset']);
        return p == null ? null : QualityMessage(p);
      case 'clipboard':
        final text = json['text'];
        return text is String ? ClipboardMessage(text) : null;
      case 'chat':
        final text = json['text'];
        return text is String ? ChatMessage(text) : null;
      case 'permissions':
        return PermissionsMessage(Permissions.fromJson(json['permissions']));
      case 'bye':
        return ByeMessage(json['reason'] is String ? json['reason'] as String : 'user');
    }
    return null;
  }
}

class HelloMessage extends ControlMessage {
  const HelloMessage({
    required this.methods,
    required this.nonce,
    this.version = 2,
  });

  final List<String> methods;
  final String nonce;
  final int version;

  factory HelloMessage.fromJson(Map json) {
    final methods = json['methods'];
    return HelloMessage(
      version: json['v'] is int ? json['v'] as int : 2,
      methods: methods is List ? methods.whereType<String>().toList() : const [],
      nonce: json['nonce'] is String ? json['nonce'] as String : '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        't': 'hello',
        'v': version,
        'methods': methods,
        'nonce': nonce,
      };
}

/// `auth` from the viewer: method `trusted`, `password` (with [proof]) or
/// `request` (with [user]).
class AuthMessage extends ControlMessage {
  const AuthMessage.trusted()
      : method = 'trusted',
        proof = null,
        user = null;

  const AuthMessage.password(String this.proof)
      : method = 'password',
        user = null;

  const AuthMessage.request(String this.user)
      : method = 'request',
        proof = null;

  const AuthMessage._(this.method, this.proof, this.user);

  final String method;
  final String? proof;
  final String? user;

  factory AuthMessage.fromJson(Map json) {
    return AuthMessage._(
      json['method'] is String ? json['method'] as String : '',
      json['proof'] is String ? json['proof'] as String : null,
      json['user'] is String ? json['user'] as String : null,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        't': 'auth',
        'method': method,
        if (proof != null) 'proof': proof,
        if (user != null) 'user': user,
      };
}

class AuthResultMessage extends ControlMessage {
  const AuthResultMessage.ok(Permissions this.permissions, {this.trusted = false})
      : ok = true,
        reason = null,
        retry = false;

  const AuthResultMessage.fail(String this.reason, {this.retry = false})
      : ok = false,
        trusted = false,
        permissions = null;

  const AuthResultMessage._(
    this.ok,
    this.permissions,
    this.reason,
    this.retry,
    this.trusted,
  );

  final bool ok;

  /// True when the host added the viewer to its Trusted Devices.
  final bool trusted;
  final Permissions? permissions;
  final String? reason;
  final bool retry;

  factory AuthResultMessage.fromJson(Map json) {
    final ok = json['ok'] == true;
    return AuthResultMessage._(
      ok,
      ok ? Permissions.fromJson(json['permissions']) : null,
      ok ? null : (json['reason'] is String ? json['reason'] as String : 'denied'),
      json['retry'] == true,
      ok && json['trusted'] == true,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        't': 'auth_result',
        'ok': ok,
        if (ok) 'trusted': trusted,
        if (ok) 'permissions': permissions!.toJson(),
        if (!ok) 'reason': reason,
        if (!ok) 'retry': retry,
      };
}

class DisplaysMessage extends ControlMessage {
  const DisplaysMessage({required this.items, required this.active});

  final List<DisplayInfo> items;
  final String active;

  factory DisplaysMessage.fromJson(Map json) {
    final items = json['items'];
    return DisplaysMessage(
      items: items is List ? items.map(DisplayInfo.fromJson).toList() : const [],
      active: json['active']?.toString() ?? '0',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        't': 'displays',
        'items': items.map((d) => d.toJson()).toList(),
        'active': active,
      };
}

class SelectDisplayMessage extends ControlMessage {
  const SelectDisplayMessage(this.id);
  final String id;

  @override
  Map<String, dynamic> toJson() => {'t': 'select_display', 'id': id};
}

class QualityMessage extends ControlMessage {
  const QualityMessage(this.preset);
  final QualityPreset preset;

  @override
  Map<String, dynamic> toJson() => {'t': 'quality', 'preset': preset.name};
}

class ClipboardMessage extends ControlMessage {
  const ClipboardMessage(this.text);
  final String text;

  @override
  Map<String, dynamic> toJson() => {'t': 'clipboard', 'text': text};
}

class ChatMessage extends ControlMessage {
  const ChatMessage(this.text);
  final String text;

  @override
  Map<String, dynamic> toJson() => {'t': 'chat', 'text': text};
}

class PermissionsMessage extends ControlMessage {
  const PermissionsMessage(this.permissions);
  final Permissions permissions;

  @override
  Map<String, dynamic> toJson() =>
      {'t': 'permissions', 'permissions': permissions.toJson()};
}

class ByeMessage extends ControlMessage {
  const ByeMessage(this.reason);
  final String reason;

  @override
  Map<String, dynamic> toJson() => {'t': 'bye', 'reason': reason};
}
