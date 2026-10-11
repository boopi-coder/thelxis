/// Shared value types for the wire protocol. All parsers are tolerant:
/// unknown fields are ignored and missing optional fields get defaults.
library;

/// What a viewer may do in a session (PROTOCOL.md section 5.1).
class Permissions {
  const Permissions({
    this.view = true,
    this.control = true,
    this.clipboard = true,
    this.files = false,
    this.audio = false,
  });

  static const Permissions viewOnly = Permissions(control: false, clipboard: false);
  static const Permissions none = Permissions(view: false, control: false, clipboard: false);

  final bool view;
  final bool control;
  final bool clipboard;
  final bool files;
  final bool audio;

  factory Permissions.fromJson(Object? json) {
    if (json is! Map) return Permissions.none;
    bool b(String key, bool fallback) {
      final v = json[key];
      return v is bool ? v : fallback;
    }

    return Permissions(
      view: b('view', false),
      control: b('control', false),
      clipboard: b('clipboard', false),
      files: b('files', false),
      audio: b('audio', false),
    );
  }

  Map<String, dynamic> toJson() => {
        'view': view,
        'control': control,
        'clipboard': clipboard,
        'files': files,
        'audio': audio,
      };

  Permissions copyWith({
    bool? view,
    bool? control,
    bool? clipboard,
    bool? files,
    bool? audio,
  }) {
    return Permissions(
      view: view ?? this.view,
      control: control ?? this.control,
      clipboard: clipboard ?? this.clipboard,
      files: files ?? this.files,
      audio: audio ?? this.audio,
    );
  }

  /// The permissions that both [this] and [other] grant.
  Permissions intersect(Permissions other) => Permissions(
        view: view && other.view,
        control: control && other.control,
        clipboard: clipboard && other.clipboard,
        files: files && other.files,
        audio: audio && other.audio,
      );

  @override
  bool operator ==(Object other) =>
      other is Permissions &&
      other.view == view &&
      other.control == control &&
      other.clipboard == clipboard &&
      other.files == files &&
      other.audio == audio;

  @override
  int get hashCode => Object.hash(view, control, clipboard, files, audio);

  @override
  String toString() => 'Permissions(${toJson()})';
}

/// What a peer announces about itself in the signaling handshake
/// (PROTOCOL.md section 4.1). Identity is the verified [key]; the rest is
/// informational.
class PeerInfo {
  const PeerInfo({
    required this.name,
    required this.os,
    this.app = '',
    this.addresses = const [],
  });

  final String name;
  final String os;
  final String app;
  final List<String> addresses;
}

/// One physical display as advertised in the `displays` message.
class DisplayInfo {
  const DisplayInfo({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    this.primary = false,
  });

  final String id;
  final String name;
  final int width;
  final int height;
  final bool primary;

  factory DisplayInfo.fromJson(Object? json) {
    final m = json is Map ? json : const <dynamic, dynamic>{};
    return DisplayInfo(
      id: _str(m['id']) ?? '0',
      name: _str(m['name']) ?? 'Display',
      width: _int(m['width']) ?? 0,
      height: _int(m['height']) ?? 0,
      primary: m['primary'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'width': width,
        'height': height,
        'primary': primary,
      };
}

/// Quality presets of PROTOCOL.md section 5.2.
enum QualityPreset {
  auto,
  speed,
  balanced,
  quality;

  static QualityPreset? tryParse(Object? v) {
    for (final p in QualityPreset.values) {
      if (p.name == v) return p;
    }
    return null;
  }
}

String? _str(Object? v) => v is String ? v : (v is num ? v.toString() : null);

int? _int(Object? v) => v is num ? v.toInt() : null;
