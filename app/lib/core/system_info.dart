import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'log.dart';

const _log = Logger('system');

/// Facts about this machine announced to peers and shown in About.
class SystemInfo {
  const SystemInfo({
    required this.os,
    required this.osVersion,
    required this.arch,
    required this.hostname,
    required this.appVersion,
    required this.defaultDeviceName,
  });

  /// `windows|macos|linux|android|ios`.
  final String os;
  final String osVersion;

  /// `x64|arm64|x86|arm`.
  final String arch;
  final String hostname;
  final String appVersion;
  final String defaultDeviceName;

  static SystemInfo fallback({String appVersion = '0.1.0'}) => SystemInfo(
        os: osName(),
        osVersion: Platform.operatingSystemVersion,
        arch: parseArch(Platform.version),
        hostname: 'device',
        appVersion: appVersion,
        defaultDeviceName: 'My device',
      );

  static Future<SystemInfo> load() async {
    var appVersion = '0.1.0';
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } on Object catch (e) {
      _log.w('package info unavailable', e);
    }
    var osVersion = Platform.operatingSystemVersion;
    var hostname = 'device';
    var deviceName = 'My device';
    try {
      hostname = Platform.localHostname;
      deviceName = hostname;
    } on Object catch (e) {
      _log.w('hostname unavailable', e);
    }
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        osVersion = a.version.release;
        final model = a.model.trim();
        deviceName = model.isEmpty ? 'Android' : '${a.manufacturer} $model'.trim();
      } else if (Platform.isMacOS) {
        osVersion = (await plugin.macOsInfo).osRelease;
      } else if (Platform.isWindows) {
        final w = await plugin.windowsInfo;
        osVersion = '${w.productName} (${w.buildNumber})';
      } else if (Platform.isLinux) {
        final l = await plugin.linuxInfo;
        osVersion = l.prettyName;
      }
    } on Object catch (e) {
      _log.w('device info unavailable', e);
    }
    return SystemInfo(
      os: osName(),
      osVersion: osVersion,
      arch: parseArch(Platform.version),
      hostname: hostname,
      appVersion: appVersion,
      defaultDeviceName: deviceName,
    );
  }

  static String osName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'linux';
  }
}

/// Extracts the CPU architecture from `Platform.version`
/// (`... on "macos_x64"`) and maps it to `x64|arm64|x86|arm`.
String parseArch(String platformVersion) {
  final m = RegExp(r'on "[a-z]+_([a-z0-9]+)"').firstMatch(platformVersion);
  switch (m?.group(1)) {
    case 'arm64':
      return 'arm64';
    case 'ia32':
      return 'x86';
    case 'arm':
      return 'arm';
    default:
      return 'x64';
  }
}
