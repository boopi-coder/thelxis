import 'dart:io';

import '../manifest.dart';
import '../update_exception.dart';
import 'installer.dart';

/// macOS: replaces the running `.app` bundle with the one from the DMG.
///
/// 1. The bundle is the `*.app` that contains `Platform.resolvedExecutable`.
///    If a scratch directory cannot be created next to it (standard user in
///    /Applications, App Translocation) the DMG is opened in Finder and the
///    result is [ManualInstallReason.notWritable].
/// 2. `hdiutil attach -nobrowse -readonly -noverify -noautoopen -mountpoint <tmp> <dmg>`
/// 3. `ditto <mount>/Thelxis.app <bundle parent>/.thelxis-update-XXXX/<bundle name>`
///    (same volume as the bundle, so the later `mv` is an atomic rename)
/// 4. `codesign --verify --deep --strict <staged bundle>` (a damaged ad-hoc
///    signature would make the new app unlaunchable on Apple Silicon)
/// 5. `hdiutil detach <tmp>` (`-force` as a fallback)
/// 6. a detached `/bin/sh` script waits for this PID to exit, then runs
///    `mv bundle bundle.bak && mv staged bundle && rm -rf bundle.bak` (rolled
///    back if the second `mv` fails), `xattr -dr com.apple.quarantine bundle`
///    and `open -n bundle --args --updated`.
class MacosInstaller implements UpdateInstaller {
  MacosInstaller({
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
# Thelxis macOS updater. Arguments: pid, current bundle, staged bundle, staging dir.
pid="\$1"; bundle="\$2"; staged="\$3"; stage="\$4"
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
xattr -dr com.apple.quarantine "\$bundle" 2>/dev/null
rm -rf "\$stage"
rm -f "\$0"
if [ -n "\$flag" ]; then open -n "\$bundle" --args "\$flag"; else open -n "\$bundle"; fi
''';

  @override
  bool get requiresUserConfirmation => false;

  @override
  Future<InstallResult> install(File file, UpdateAsset asset) async {
    final bundle = _currentBundle();
    final Directory staging;
    try {
      staging = await bundle.parent.createTemp('.thelxis-update-');
    } on FileSystemException {
      await _proc.run('open', [file.path]); // Finder mounts the image for a drag-and-drop install
      return InstallResult.manual(ManualInstallReason.notWritable, location: file.path);
    }

    var handedOver = false;
    Directory? mount;
    try {
      mount = await _tempRoot.createTemp('thelxis-dmg-');
      await runChecked(_proc, 'mounting the disk image', 'hdiutil', [
        'attach', '-nobrowse', '-readonly', '-noverify', '-noautoopen', '-mountpoint', mount.path, file.path,
      ]);
      final source = await _findApp(mount);
      final staged = '${staging.path}/${bundle.uri.pathSegments.where((s) => s.isNotEmpty).last}';
      await runChecked(_proc, 'copying the new app', 'ditto', [source.path, staged]);
      await runChecked(_proc, 'checking the new app', 'codesign', ['--verify', '--deep', '--strict', staged]);

      final script = File('${_tempRoot.path}/thelxis-update-$_pid.sh');
      await script.writeAsString(swapScript);
      await _proc.startDetached('/bin/sh', [script.path, '$_pid', bundle.path, staged, staging.path]);
      handedOver = true;
      return const InstallResult.restart();
    } finally {
      if (mount != null) {
        await _detach(mount);
        await deleteDirQuietly(mount);
      }
      if (!handedOver) await deleteDirQuietly(staging);
    }
  }

  /// `…/Thelxis.app` containing the running executable.
  Directory _currentBundle() {
    var dir = File(_executable).parent;
    for (var i = 0; i < 6; i++) {
      if (dir.path.endsWith('.app')) return dir;
      final up = dir.parent;
      if (up.path == dir.path) break;
      dir = up;
    }
    throw UpdateException(UpdateErrorKind.install, 'not running from an .app bundle: $_executable');
  }

  Future<Directory> _findApp(Directory mount) async {
    final preferred = Directory('${mount.path}/Thelxis.app');
    if (await preferred.exists()) return preferred;
    await for (final entity in mount.list(followLinks: false)) {
      if (entity is Directory && entity.path.endsWith('.app')) return entity;
    }
    throw const UpdateException(UpdateErrorKind.install, 'no .app inside the disk image');
  }

  Future<void> _detach(Directory mount) async {
    try {
      final result = await _proc.run('hdiutil', ['detach', mount.path]);
      if (result.exitCode != 0) {
        await _proc.run('hdiutil', ['detach', '-force', mount.path]);
      }
    } on ProcessException {
      // The image stays mounted hidden (-nobrowse); nothing else depends on it.
    }
  }
}
