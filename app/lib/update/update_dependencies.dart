import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'downloader.dart';
import 'installers/installer.dart';
import 'installers/installer_factory.dart';
import 'manifest_loader.dart';
import 'update_http.dart';
import 'update_target.dart';

/// Everything [UpdateService] needs from the outside world, so tests can swap
/// in fakes and no test ever touches the network or installs anything.
class UpdateDependencies {
  const UpdateDependencies({
    required this.currentVersion,
    required this.loader,
    required this.downloader,
    required this.installer,
    required this.target,
    required this.downloadDir,
  });

  /// `x.y.z` of the running app (package_info).
  final String currentVersion;
  final ManifestLoader loader;
  final UpdateDownloader downloader;
  final UpdateInstaller installer;
  final UpdateTarget target;
  final Directory downloadDir;

  /// The real thing. Downloads go to `<application support>/updates/`, which
  /// is also the directory the Android FileProvider exposes (`updates/`).
  static Future<UpdateDependencies> system() async {
    final info = await PackageInfo.fromPlatform();
    final http = UpdateHttp(userAgent: 'Thelxis/${info.version}');
    final target = await UpdateTarget.detect();
    final support = await getApplicationSupportDirectory();
    return UpdateDependencies(
      currentVersion: info.version,
      loader: ManifestLoader(http: http),
      downloader: UpdateDownloader(http: http),
      installer: createInstaller(target),
      target: target,
      downloadDir: Directory('${support.path}${Platform.pathSeparator}updates'),
    );
  }
}
