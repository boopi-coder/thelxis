import 'dart:io';

import '../manifest.dart';
import '../update_exception.dart';
import 'installer.dart';
import 'windows_shell.dart';

/// Starts the program elevated; returns the ShellExecute result code.
typedef ElevatedLauncher = Future<int> Function(String file, String parameters);

/// Windows: runs the Inno Setup installer.
///
/// ```
/// Thelxis-X.Y.Z-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH
/// ```
/// started through `ShellExecute` with the `runas` verb (the per-machine
/// installer needs administrator rights, so Windows shows a UAC prompt).
/// `/RELAUNCH` is our own switch: Setup waits for the app's single-instance
/// mutex to disappear, installs, then starts `thelxis.exe --updated` as the
/// original user. The service exits the app right after this returns.
///
/// If the user declines UAC, ShellExecute fails *before* anything is started,
/// the call reports [UpdateErrorKind.elevationDenied] and the app keeps
/// running.
class WindowsInstaller implements UpdateInstaller {
  WindowsInstaller({ElevatedLauncher? launch}) : _launch = launch ?? shellExecuteRunAs;

  final ElevatedLauncher _launch;

  static const List<String> setupArguments = [
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/RELAUNCH',
  ];

  /// SE_ERR_ACCESSDENIED: what ShellExecute returns when the UAC prompt is
  /// declined (any other value up to 32 is a different failure).
  static const int _seErrAccessDenied = 5;

  @override
  bool get requiresUserConfirmation => true;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) async {
    final code = await _launch(file.path, setupArguments.join(' '));
    if (code > 32) return const InstallResult.restart();
    if (code == _seErrAccessDenied) {
      throw const UpdateException(UpdateErrorKind.elevationDenied, 'UAC prompt declined');
    }
    throw UpdateException(UpdateErrorKind.install, 'ShellExecute failed with code $code');
  }
}
