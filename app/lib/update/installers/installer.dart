import 'dart:io';

import '../manifest.dart';
import '../update_exception.dart';

enum InstallOutcome {
  /// A helper was started that swaps/relaunches the app; the app must exit now.
  restartRequired,

  /// The OS installer UI was opened (Android); the app keeps running.
  handedOff,

  /// The user has to finish the installation by hand.
  manualRequired,
}

enum ManualInstallReason {
  /// Android: "install unknown apps" is not allowed for Thelxis yet.
  installPermission,

  /// The app's own folder cannot be written (macOS /Applications as a standard
  /// user, Linux tar install in a root-owned directory).
  notWritable,

  /// Linux .deb: no `pkexec` to ask for administrator rights.
  noPolkit,
}

class InstallResult {
  const InstallResult.restart()
      : outcome = InstallOutcome.restartRequired,
        reason = null,
        location = null;
  const InstallResult.handedOff()
      : outcome = InstallOutcome.handedOff,
        reason = null,
        location = null;
  const InstallResult.manual(ManualInstallReason this.reason, {this.location})
      : outcome = InstallOutcome.manualRequired;

  final InstallOutcome outcome;
  final ManualInstallReason? reason;

  /// Where the downloaded file is, for the user (manual installs).
  final String? location;
}

/// Installs a verified release file. Implementations never exit the app; the
/// service does that after [InstallOutcome.restartRequired].
abstract class UpdateInstaller {
  /// True when starting the install makes the OS show an elevation/installer
  /// prompt (UAC, polkit, Android installer) that needs someone at the screen.
  /// The service then waits for an explicit "Install now" instead of popping
  /// the prompt up unannounced after an automatic download.
  bool get requiresUserConfirmation => false;

  Future<InstallResult> install(File file, UpdateAsset asset);
}

/// Runs external programs; faked in tests so nothing is ever really installed.
abstract class ProcessLauncher {
  Future<ProcessResult> run(String executable, List<String> args);

  /// Starts [executable] so that it survives this process exiting.
  Future<void> startDetached(String executable, List<String> args);
}

class SystemProcessLauncher implements ProcessLauncher {
  const SystemProcessLauncher();

  @override
  Future<ProcessResult> run(String executable, List<String> args) => Process.run(executable, args);

  @override
  Future<void> startDetached(String executable, List<String> args) async {
    try {
      await Process.start(executable, args, mode: ProcessStartMode.detached);
    } on ProcessException catch (e) {
      throw UpdateException(UpdateErrorKind.install, 'cannot start $executable: ${e.message}', cause: e);
    }
  }
}

/// Shell snippet shared by the swap helpers: wait (at most 60 s) until the
/// process with PID `$pid` is gone, otherwise clean up and give up.
const String kWaitForExitSh = r'''
n=0
while kill -0 "$pid" 2>/dev/null; do
  n=$((n + 1))
  if [ "$n" -gt 300 ]; then
    rm -rf "$stage"
    rm -f "$0"
    exit 1
  fi
  sleep 0.2
done
''';

/// Runs [exe] with [args] and fails with [UpdateErrorKind.install] when it
/// exits non-zero or cannot be started.
Future<ProcessResult> runChecked(ProcessLauncher proc, String what, String exe, List<String> args) async {
  final ProcessResult result;
  try {
    result = await proc.run(exe, args);
  } on ProcessException catch (e) {
    throw UpdateException(UpdateErrorKind.install, '$what: cannot run $exe (${e.message})', cause: e);
  }
  if (result.exitCode != 0) {
    throw UpdateException(
      UpdateErrorKind.install,
      '$what failed (exit ${result.exitCode}): ${tail(result.stderr)}',
    );
  }
  return result;
}

/// Last ~300 characters of process output, for log lines and error details.
String tail(Object? output) {
  final text = '$output'.trim();
  return text.length <= 300 ? text : text.substring(text.length - 300);
}

Future<void> deleteDirQuietly(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException {
    // Leftover temp data only.
  }
}
