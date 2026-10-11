import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/models.dart';
import 'base64url.dart';

/// User preferences, persisted in SharedPreferences. Every setter notifies
/// listeners and writes through immediately.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs, {required this.defaultDeviceName});

  final SharedPreferences _prefs;

  /// Used until the user picks a name (hostname / device model).
  final String defaultDeviceName;

  static const _kDeviceName = 'device_name';
  static const _kAllowIncoming = 'allow_incoming';
  static const _kUpnp = 'upnp';
  static const _kLan = 'lan_discovery';
  static const _kPublicStun = 'public_stun';
  static const _kRequireApproval = 'require_approval';
  static const _kRotateOtp = 'rotate_otp';
  static const _kUnattendedKey = 'unattended_key';
  static const _kPerms = 'default_permissions';
  static const _kTheme = 'theme_mode';
  static const _kStartup = 'launch_at_startup';
  static const _kTouchMode = 'touch_mode';
  static const _kClipboardSync = 'clipboard_sync';
  static const _kHistory = 'history';

  String get deviceName {
    final v = _prefs.getString(_kDeviceName);
    return (v == null || v.trim().isEmpty) ? defaultDeviceName : v;
  }

  /// Accept incoming connections: runs the listener, embedded TURN and port
  /// mappings (PROTOCOL.md section 8).
  bool get allowIncoming => _prefs.getBool(_kAllowIncoming) ?? true;

  /// Ask the router for port mappings (UPnP / NAT-PMP / PCP).
  bool get upnp => _prefs.getBool(_kUpnp) ?? true;

  bool get lanDiscovery => _prefs.getBool(_kLan) ?? true;

  /// Opt-in: add a public STUN server to ICE (reveals IPs to that server).
  bool get publicStun => _prefs.getBool(_kPublicStun) ?? false;

  bool get requireApproval => _prefs.getBool(_kRequireApproval) ?? false;

  bool get rotateOneTimePassword => _prefs.getBool(_kRotateOtp) ?? true;

  /// PBKDF2 key of the permanent password (base64url) or null when unset.
  /// Only the derived key is stored, never the password.
  List<int>? get unattendedKey => tryB64uDecode(_prefs.getString(_kUnattendedKey));

  bool get hasPermanentPassword => unattendedKey != null;

  Permissions get defaultPermissions {
    final raw = _prefs.getString(_kPerms);
    if (raw == null) return const Permissions();
    final parts = raw.split(',').toSet();
    return Permissions(
      view: true,
      control: parts.contains('control'),
      clipboard: parts.contains('clipboard'),
    );
  }

  ThemeMode get themeMode {
    switch (_prefs.getString(_kTheme)) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }

  bool get launchAtStartup => _prefs.getBool(_kStartup) ?? false;

  /// `touchpad` or `direct` (Android viewer).
  String get touchMode => _prefs.getString(_kTouchMode) ?? 'touchpad';

  bool get clipboardSync => _prefs.getBool(_kClipboardSync) ?? true;

  /// Raw JSON of the local session history (managed by SessionHistory).
  String? get historyJson => _prefs.getString(_kHistory);

  Future<void> setDeviceName(String v) => _set(() => _prefs.setString(_kDeviceName, v.trim()));
  Future<void> setAllowIncoming(bool v) => _set(() => _prefs.setBool(_kAllowIncoming, v));
  Future<void> setUpnp(bool v) => _set(() => _prefs.setBool(_kUpnp, v));
  Future<void> setLanDiscovery(bool v) => _set(() => _prefs.setBool(_kLan, v));
  Future<void> setPublicStun(bool v) => _set(() => _prefs.setBool(_kPublicStun, v));
  Future<void> setRequireApproval(bool v) => _set(() => _prefs.setBool(_kRequireApproval, v));
  Future<void> setRotateOneTimePassword(bool v) => _set(() => _prefs.setBool(_kRotateOtp, v));
  Future<void> setLaunchAtStartup(bool v) => _set(() => _prefs.setBool(_kStartup, v));
  Future<void> setTouchMode(String v) => _set(() => _prefs.setString(_kTouchMode, v));
  Future<void> setClipboardSync(bool v) => _set(() => _prefs.setBool(_kClipboardSync, v));
  Future<void> setHistoryJson(String v) => _prefs.setString(_kHistory, v);

  Future<void> setThemeMode(ThemeMode mode) => _set(() => _prefs.setString(_kTheme, mode.name));

  Future<void> setUnattendedKey(List<int>? key) => _set(() async {
        if (key == null) return _prefs.remove(_kUnattendedKey);
        return _prefs.setString(_kUnattendedKey, b64uEncode(key));
      });

  Future<void> setDefaultPermissions(Permissions p) => _set(() => _prefs.setString(
        _kPerms,
        [if (p.control) 'control', if (p.clipboard) 'clipboard'].join(','),
      ));

  Future<void> _set(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }
}
