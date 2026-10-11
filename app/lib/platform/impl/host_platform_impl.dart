// Selects the HostPlatform for the running operating system. The only entry
// point core code reaches (through HostPlatform.instance).

import 'dart:io' show Platform;

import '../host_platform.dart';
import 'android_host.dart';
import 'impl_log.dart';
import 'linux_host.dart';
import 'macos_host.dart';
import 'unsupported_host.dart';
import 'windows_host.dart';

HostPlatform createHostPlatform() {
  try {
    if (Platform.isWindows) return WindowsHostPlatform();
    if (Platform.isMacOS) return MacosHostPlatform();
    if (Platform.isLinux) return LinuxHostPlatform();
    if (Platform.isAndroid) return AndroidHostPlatform();
  } catch (e) {
    implLog('creating the host platform failed', e);
  }
  return UnsupportedHostPlatform();
}
