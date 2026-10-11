import 'dart:io';

import '../manifest.dart';
import '../update_exception.dart';
import 'installer.dart';

/// Linux, installed from the .deb (`/opt/thelxis`, `/usr/bin/thelxis`).
///
/// ```
/// pkexec /bin/sh -c '<script>' sh <file.deb> <sha256>
/// ```
/// where the script, running as root, copies the .deb into a root-owned
/// temp dir, re-checks its SHA-256 against the signed manifest value (so the
/// user-writable download cannot be swapped while the password prompt is
/// open) and runs `dpkg -i` on the copy. Afterwards a detached `/bin/sh`
/// waits for this PID to exit and runs `/usr/bin/thelxis --updated`.
///
/// Without `pkexec` the containing folder is opened (`xdg-open`) and the
/// result is [ManualInstallReason.noPolkit].
class LinuxDebInstaller implements UpdateInstaller {
  LinuxDebInstaller({ProcessLauncher? process, int? ownPid, String? launcher})
      : _proc = process ?? const SystemProcessLauncher(),
        _pid = ownPid ?? pid,
        _launcher = launcher ?? '/usr/bin/thelxis';

  final ProcessLauncher _proc;
  final int _pid;
  final String _launcher;

  static const String rootScript = r'''
set -e
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
cp -- "$1" "$d/thelxis.deb"
printf '%s  %s\n' "$2" "$d/thelxis.deb" | sha256sum -c - >/dev/null
dpkg -i "$d/thelxis.deb"
''';

  /// Waits for `$1` (our PID) to exit, then execs the remaining arguments.
  static const String relaunchScript = r'''
pid="$1"; shift
n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 300 ]; do
  n=$((n + 1))
  sleep 0.2
done
exec "$@"
''';

  @override
  bool get requiresUserConfirmation => true;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) async {
    if (!await _hasPkexec()) {
      await _openFolder(file.parent);
      return InstallResult.manual(ManualInstallReason.noPolkit, location: file.path);
    }
    final ProcessResult result;
    try {
      result = await _proc.run('pkexec', ['/bin/sh', '-c', rootScript, 'sh', file.path, asset.sha256]);
    } on ProcessException catch (e) {
      throw UpdateException(UpdateErrorKind.install, 'cannot run pkexec: ${e.message}', cause: e);
    }
    // pkexec: 126 = the user dismissed the dialog, 127 = authentication failed.
    if (result.exitCode == 126 || result.exitCode == 127) {
      throw const UpdateException(UpdateErrorKind.elevationDenied, 'administrator prompt declined');
    }
    if (result.exitCode != 0) {
      throw UpdateException(UpdateErrorKind.install, 'dpkg failed (exit ${result.exitCode}): ${tail(result.stderr)}');
    }
    await _proc.startDetached('/bin/sh', ['-c', relaunchScript, 'sh', '$_pid', _launcher, '--updated']);
    return const InstallResult.restart();
  }

  Future<bool> _hasPkexec() async {
    try {
      final r = await _proc.run('pkexec', ['--version']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  Future<void> _openFolder(Directory dir) async {
    try {
      await _proc.run('xdg-open', [dir.path]);
    } on ProcessException {
      // The path is shown in the UI anyway.
    }
  }
}

/// Linux, portable tar.gz install: replaces the bundle directory.
///
/// ```
/// tar -xzf <file> -C <bundle parent>/.thelxis-update-XXXX
/// ```
/// then a detached `/bin/sh` waits for this PID to exit,
/// `mv bundle bundle.bak && mv <extracted top dir> bundle && rm -rf bundle.bak`
/// (rolled back on failure) and `exec bundle/thelxis --updated`. When the
/// bundle's parent is not writable the folder with the archive is opened and
/// the result is [ManualInstallReason.notWritable].
class LinuxTarInstaller implements UpdateInstaller {
  LinuxTarInstaller({
    ProcessLauncher? process,
    String? resolvedExecutable,
    int? ownPid,
    Directory? tempRoot,
  })  : _proc = process ?? const SystemProcessLauncher(),
        _executable = resolvedExecutable ?? Platform.resolvedExecutable,
        _pid = ownPid ?? pid,
        _tempRoot = tempRoot ?? Directory.systemTemp;

  final ProcessLauncher _proc;
  final String _executable;
  final int _pid;
  final Directory _tempRoot;

  static const String swapScript = '''
#!/bin/sh
# Thelxis Linux updater. Arguments: pid, bundle dir, staged dir, staging dir, executable name.
pid="\$1"; bundle="\$2"; staged="\$3"; stage="\$4"; exe="\$5"
$kWaitForExitSh
backup="\$bundle.bak"
rm -rf "\$backup"
flag=""
if mv "\$bundle" "\$backup"; then
  if mv "\$staged" "\$bundle"; then
    rm -rf "\$backup"
    flag="--updated"
  else
    mv "\$backup" "\$bundle"
  fi
fi
rm -rf "\$stage"
rm -f "\$0"
exec "\$bundle/\$exe" \$flag
''';

  @override
  bool get requiresUserConfirmation => false;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) async {
    final executable = File(_executable);
    final bundle = executable.parent;
    final Directory staging;
    try {
      staging = await bundle.parent.createTemp('.thelxis-update-');
    } on FileSystemException {
      try {
        await _proc.run('xdg-open', [file.parent.path]);
      } on ProcessException {
        // The path is shown in the UI anyway.
      }
      return InstallResult.manual(ManualInstallReason.notWritable, location: file.path);
    }

    var handedOver = false;
    try {
      final exeName = executable.uri.pathSegments.last;
      await runChecked(_proc, 'unpacking the archive', 'tar', ['-xzf', file.path, '-C', staging.path]);
      final staged = await _extractedBundle(staging, exeName);

      final script = File('${_tempRoot.path}/thelxis-update-$_pid.sh');
      await script.writeAsString(swapScript);
      await _proc.startDetached(
        '/bin/sh',
        [script.path, '$_pid', bundle.path, staged.path, staging.path, exeName],
      );
      handedOver = true;
      return const InstallResult.restart();
    } finally {
      if (!handedOver) await deleteDirQuietly(staging);
    }
  }

  /// The archive has one top-level directory (`Thelxis-X.Y.Z-linux-x64/`) that
  /// holds the Flutter bundle; accept any single directory containing the
  /// executable.
  Future<Directory> _extractedBundle(Directory staging, String exeName) async {
    await for (final entity in staging.list(followLinks: false)) {
      if (entity is Directory && await File('${entity.path}/$exeName').exists()) return entity;
    }
    throw UpdateException(UpdateErrorKind.install, 'archive does not contain $exeName');
  }
}
