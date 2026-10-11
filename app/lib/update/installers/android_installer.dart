import 'dart:io';

import 'package:flutter/services.dart';

import '../manifest.dart';
import '../update_exception.dart';
import 'installer.dart';

/// Android: hands the APK to the system package installer through the native
/// `io.thelxis/updater` MethodChannel.
///
/// ```
/// canRequestInstalls() -> bool      REQUEST_INSTALL_PACKAGES granted ("install unknown apps")
/// openInstallSettings() -> void     opens ACTION_MANAGE_UNKNOWN_APP_SOURCES for this package
/// installApk({path: String}) -> bool  ACTION_VIEW/INSTALL on a FileProvider uri; true = installer UI shown
/// ```
/// `path` is inside `getApplicationSupportDirectory()/updates/`.
class AndroidInstaller implements UpdateInstaller {
  AndroidInstaller({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'io.thelxis/updater';

  final MethodChannel _channel;

  /// The system installer dialog needs the app in the foreground.
  @override
  bool get requiresUserConfirmation => true;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) async {
    try {
      final allowed = await _channel.invokeMethod<bool>('canRequestInstalls') ?? false;
      if (!allowed) {
        await _channel.invokeMethod<void>('openInstallSettings');
        return InstallResult.manual(ManualInstallReason.installPermission, location: file.path);
      }
      final started = await _channel.invokeMethod<bool>('installApk', {'path': file.path}) ?? false;
      if (!started) {
        throw const UpdateException(UpdateErrorKind.install, 'system installer could not be started');
      }
      return const InstallResult.handedOff();
    } on PlatformException catch (e) {
      throw UpdateException(UpdateErrorKind.install, 'updater channel: ${e.code}', cause: e);
    } on MissingPluginException catch (e) {
      throw UpdateException(UpdateErrorKind.install, 'updater channel is not implemented', cause: e);
    }
  }
}
