import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/connectivity/connectivity.dart' show ManualForwarding, ThelxisPorts;
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
  // 0.1.0 stored the opt-in under 'public_stun' (default off). The default is
  // now ON, so existing installs must not inherit the old explicit value: the
  // setting lives under a new key and the old one is ignored.
  static const _kPublicStun = 'public_stun_v2';
  static const _kGateway = 'office_gateway';
  static const _kManualFwd = 'manual_fwd';
  static const _kManualHost = 'manual_fwd_host';
  static const _kManualSignaling = 'manual_fwd_tcp';
  static const _kManualTurnUdp = 'manual_fwd_udp';
  static const _kManualTurnTcp = 'manual_fwd_turn_tcp';
  static const _kRequireApproval = 'require_approval';
  static const _kRotateOtp = 'rotate_otp';
  static const _kUnattendedKey = 'unattended_key';
  static const _kPerms = 'default_permissions';
  static const _kTheme = 'theme_mode';
  static const _kStartup = 'launch_at_startup';
  static const _kTouchMode = 'touch_mode';
  static const _kClipboardSync = 'clipboard_sync';
  static const _kMouseButtons = 'mouse_buttons';
  static const _kMouseButtonsX = 'mouse_buttons_x';
  static const _kMouseButtonsY = 'mouse_buttons_y';
  static const _kHistory = 'history';
  static const _kLanguage = 'language';
  static const _kSetupDismissed = 'setup_dismissed_perms';

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

  /// Add public STUN servers to ICE (PROTOCOL.md section 4.3). On by default:
  /// the servers learn the devices' IP:port, never any session data.
  bool get publicStun => _prefs.getBool(_kPublicStun) ?? true;

  /// Office gateway (PROTOCOL.md section 11): other Thelxis devices on this
  /// network become reachable from outside through this one. Off by default.
  bool get officeGateway => _prefs.getBool(_kGateway) ?? false;

  /// The user forwarded ports on the router by hand (Settings -> Connectivity).
  bool get manualForwardingEnabled => _prefs.getBool(_kManualFwd) ?? false;

  /// Public IP or DNS name of the router for manual forwarding; empty = use
  /// the router's address when known.
  String get manualForwardHost => (_prefs.getString(_kManualHost) ?? '').trim();

  /// Router ports forwarded to this device's 47100/TCP, 47100/UDP, 47101/TCP.
  int get manualSignalingPort => _prefs.getInt(_kManualSignaling) ?? ThelxisPorts.signalingTcp;
  int get manualTurnUdpPort => _prefs.getInt(_kManualTurnUdp) ?? ThelxisPorts.turnUdp;
  int get manualTurnTcpPort => _prefs.getInt(_kManualTurnTcp) ?? ThelxisPorts.turnTcp;

  /// What to hand to `Connectivity.setManualForwarding`; null when off.
  ManualForwarding? get manualForwarding => !manualForwardingEnabled
      ? null
      : ManualForwarding(
          externalHost: manualForwardHost.isEmpty ? null : manualForwardHost,
          signalingTcp: manualSignalingPort,
          turnUdp: manualTurnUdpPort,
          turnTcp: manualTurnTcpPort,
        );

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
      files: parts.contains('files'),
    );
  }

  ThemeMode get themeMode {
    switch (_prefs.getString(_kTheme)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        // Follows the OS until the user picks a theme in Settings.
        return ThemeMode.system;
    }
  }

  bool get launchAtStartup => _prefs.getBool(_kStartup) ?? false;

  /// `touchpad` or `direct` (Android viewer).
  String get touchMode => _prefs.getString(_kTouchMode) ?? 'touchpad';

  bool get clipboardSync => _prefs.getBool(_kClipboardSync) ?? true;

  /// Android viewer: floating left / right mouse buttons over the picture.
  bool get mouseButtons => _prefs.getBool(_kMouseButtons) ?? true;

  /// Where the floating buttons sit, each axis 0..1 across the free room
  /// (0 = left / top edge, 1 = right / bottom edge) so the spot survives
  /// rotation and a different screen size. Defaults to the lower right.
  Offset get mouseButtonsPosition => Offset(
        (_prefs.getDouble(_kMouseButtonsX) ?? 0.96).clamp(0.0, 1.0),
        (_prefs.getDouble(_kMouseButtonsY) ?? 0.72).clamp(0.0, 1.0),
      );

  /// `system` (follow the OS), `en` or `ru`.
  String get language {
    final v = _prefs.getString(_kLanguage);
    return v == 'en' || v == 'ru' ? v! : 'system';
  }

  /// Names of the host permissions whose "Setup needed" hint the user closed.
  /// The card stays hidden while every missing permission is in this set, so
  /// a viewer-only device is never nagged again; a permission that goes
  /// missing later and was never dismissed brings the card back.
  Set<String> get dismissedSetupPermissions =>
      (_prefs.getString(_kSetupDismissed) ?? '').split(',').where((p) => p.isNotEmpty).toSet();

  /// Raw JSON of the local session history (managed by SessionHistory).
  String? get historyJson => _prefs.getString(_kHistory);

  Future<void> setDeviceName(String v) => _set(() => _prefs.setString(_kDeviceName, v.trim()));
  Future<void> setAllowIncoming(bool v) => _set(() => _prefs.setBool(_kAllowIncoming, v));
  Future<void> setUpnp(bool v) => _set(() => _prefs.setBool(_kUpnp, v));
  Future<void> setLanDiscovery(bool v) => _set(() => _prefs.setBool(_kLan, v));
  Future<void> setPublicStun(bool v) => _set(() => _prefs.setBool(_kPublicStun, v));
  Future<void> setOfficeGateway(bool v) => _set(() => _prefs.setBool(_kGateway, v));
  Future<void> setManualForwardingEnabled(bool v) => _set(() => _prefs.setBool(_kManualFwd, v));

  /// Stores the manual forwarding details. Ports outside 1..65535 and hosts
  /// that are not an IP address or a DNS name are ignored (the old value stays).
  Future<void> setManualForwardingDetails({String? host, int? signalingTcp, int? turnUdp, int? turnTcp}) =>
      _set(() async {
        if (host != null) {
          final h = host.trim();
          if (h.isEmpty) {
            await _prefs.remove(_kManualHost);
          } else if (isValidForwardHost(h)) {
            await _prefs.setString(_kManualHost, h);
          }
        }
        if (isValidPort(signalingTcp)) await _prefs.setInt(_kManualSignaling, signalingTcp!);
        if (isValidPort(turnUdp)) await _prefs.setInt(_kManualTurnUdp, turnUdp!);
        if (isValidPort(turnTcp)) await _prefs.setInt(_kManualTurnTcp, turnTcp!);
        return true;
      });

  static bool isValidPort(int? p) => p != null && p >= 1 && p <= 65535;

  /// An IPv4/IPv6 literal or a DNS name (letters, digits, dots, hyphens).
  static bool isValidForwardHost(String h) {
    if (h.isEmpty || h.length > 253) return false;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) {
      return h.split('.').every((o) => int.parse(o) <= 255);
    }
    if (h.contains(':')) {
      return RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(h) && ':'.allMatches(h).length >= 2;
    }
    return RegExp(r'^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$').hasMatch(h);
  }

  Future<void> setRequireApproval(bool v) => _set(() => _prefs.setBool(_kRequireApproval, v));
  Future<void> setRotateOneTimePassword(bool v) => _set(() => _prefs.setBool(_kRotateOtp, v));
  Future<void> setLaunchAtStartup(bool v) => _set(() => _prefs.setBool(_kStartup, v));
  Future<void> setTouchMode(String v) => _set(() => _prefs.setString(_kTouchMode, v));
  Future<void> setClipboardSync(bool v) => _set(() => _prefs.setBool(_kClipboardSync, v));
  Future<void> setMouseButtons(bool v) => _set(() => _prefs.setBool(_kMouseButtons, v));
  Future<void> setMouseButtonsPosition(Offset p) => _set(() async {
        await _prefs.setDouble(_kMouseButtonsX, p.dx.clamp(0.0, 1.0));
        return _prefs.setDouble(_kMouseButtonsY, p.dy.clamp(0.0, 1.0));
      });
  Future<void> setHistoryJson(String v) => _prefs.setString(_kHistory, v);

  /// Adds [names] to [dismissedSetupPermissions] (a union, so closing the
  /// card for one permission never brings back another one closed earlier).
  Future<void> dismissSetupPermissions(Iterable<String> names) => _set(() => _prefs.setString(
        _kSetupDismissed,
        ({...dismissedSetupPermissions, ...names}.toList()..sort()).join(','),
      ));

  Future<void> setLanguage(String value) => _set(() => _prefs.setString(_kLanguage, value));

  Future<void> setThemeMode(ThemeMode mode) => _set(() => _prefs.setString(_kTheme, mode.name));

  Future<void> setUnattendedKey(List<int>? key) => _set(() async {
        if (key == null) return _prefs.remove(_kUnattendedKey);
        return _prefs.setString(_kUnattendedKey, b64uEncode(key));
      });

  Future<void> setDefaultPermissions(Permissions p) => _set(() => _prefs.setString(
        _kPerms,
        [if (p.control) 'control', if (p.clipboard) 'clipboard', if (p.files) 'files'].join(','),
      ));

  Future<void> _set(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }
}
