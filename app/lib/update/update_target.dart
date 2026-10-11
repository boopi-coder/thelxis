import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// Operating system as far as release assets are concerned.
enum UpdateOs { windows, macos, linux, android, unsupported }

/// Runs a command; injectable so detection can be tested.
typedef CommandRunner = Future<ProcessResult> Function(String executable, List<String> args);

/// Everything needed to pick the right asset from a manifest (PROTOCOL.md
/// section 10).
class UpdateTarget {
  const UpdateTarget({
    required this.os,
    this.androidAbis = const [],
    this.linuxDeb = false,
  });

  final UpdateOs os;

  /// Android `supportedAbis`, most preferred first.
  final List<String> androidAbis;

  /// Linux only: the app was installed from the .deb (under /opt/thelxis).
  final bool linuxDeb;

  /// Manifest asset keys acceptable for this device, best match first.
  List<String> get assetKeys {
    switch (os) {
      case UpdateOs.windows:
        return const ['windows-x64'];
      case UpdateOs.macos:
        return const ['macos-universal'];
      case UpdateOs.linux:
        return [linuxDeb ? 'linux-x64-deb' : 'linux-x64-tar'];
      case UpdateOs.android:
        return [for (final abi in androidAbis) 'android-$abi', 'android-universal'];
      case UpdateOs.unsupported:
        return const [];
    }
  }

  /// Detects the running platform.
  static Future<UpdateTarget> detect({
    UpdateOs? os,
    Future<List<String>> Function()? androidAbis,
    Future<bool> Function()? linuxDeb,
  }) async {
    final detected = os ?? _currentOs();
    switch (detected) {
      case UpdateOs.android:
        final abis = await (androidAbis ?? _deviceAbis)();
        return UpdateTarget(os: detected, androidAbis: abis);
      case UpdateOs.linux:
        final deb = await (linuxDeb ?? isInstalledFromDeb)();
        return UpdateTarget(os: detected, linuxDeb: deb);
      case UpdateOs.windows:
      case UpdateOs.macos:
      case UpdateOs.unsupported:
        return UpdateTarget(os: detected);
    }
  }

  static UpdateOs _currentOs() {
    if (Platform.isWindows) return UpdateOs.windows;
    if (Platform.isMacOS) return UpdateOs.macos;
    // Only an x64 Linux build is published.
    if (Platform.isLinux) return Abi.current() == Abi.linuxX64 ? UpdateOs.linux : UpdateOs.unsupported;
    if (Platform.isAndroid) return UpdateOs.android;
    return UpdateOs.unsupported;
  }

  static Future<List<String>> _deviceAbis() async {
    final info = await DeviceInfoPlugin().androidInfo;
    return List<String>.of(info.supportedAbis);
  }
}

/// True when the running executable lives under /opt/thelxis and the package
/// manager owns it (installed from `thelxis_<version>_amd64.deb`).
Future<bool> isInstalledFromDeb({
  String? executable,
  CommandRunner? run,
  bool Function(String path)? fileExists,
}) async {
  final exe = executable ?? Platform.resolvedExecutable;
  if (!exe.startsWith('/opt/thelxis/')) return false;
  final exists = fileExists ?? (p) => File(p).existsSync();
  if (exists('/var/lib/dpkg/info/thelxis.list')) return true;
  try {
    final result = await (run ?? Process.run)('dpkg', ['-S', exe]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
