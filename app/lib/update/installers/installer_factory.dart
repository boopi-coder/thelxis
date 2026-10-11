import 'dart:io';

import '../manifest.dart';
import '../update_exception.dart';
import '../update_target.dart';
import 'android_installer.dart';
import 'installer.dart';
import 'linux_installer.dart';
import 'macos_installer.dart';
import 'windows_installer.dart';

/// The installer matching [target].
UpdateInstaller createInstaller(UpdateTarget target) {
  switch (target.os) {
    case UpdateOs.windows:
      return WindowsInstaller();
    case UpdateOs.macos:
      return MacosInstaller();
    case UpdateOs.linux:
      return target.linuxDeb ? LinuxDebInstaller() : LinuxTarInstaller();
    case UpdateOs.android:
      return AndroidInstaller();
    case UpdateOs.unsupported:
      return _UnsupportedInstaller();
  }
}

class _UnsupportedInstaller implements UpdateInstaller {
  @override
  bool get requiresUserConfirmation => false;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) =>
      throw const UpdateException(UpdateErrorKind.install, 'updates are not supported on this platform');
}
