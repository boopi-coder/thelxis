import '../../platform/host_platform.dart';
import '../../platform/impl/android_host.dart';

/// The OS permissions a host needs before others can see and control it.
const kHostPermissions = [HostPermission.screenCapture, HostPermission.inputControl];

/// One reading of [kHostPermissions], shared by the home "Setup needed" card
/// and the Settings permissions row so both always agree.
class HostPermissionCheck {
  const HostPermissionCheck({this.status = const {}, this.restrictedLikely = false});

  /// Null for a permission whose status could not be read.
  final Map<HostPermission, PermissionStatus?> status;

  /// Android only: the accessibility switch is probably blocked as a
  /// "Restricted setting" (see AccessibilityGuide).
  final bool restrictedLikely;

  /// Permissions known to be denied. An unreadable status is not counted:
  /// it is not worth bothering the user about.
  List<HostPermission> get missing => [
        for (final p in kHostPermissions)
          if (status[p] == PermissionStatus.denied) p,
      ];
}

Future<HostPermissionCheck> checkHostPermissions(HostPlatform platform) async {
  if (!platform.hostSupported) return const HostPermissionCheck();
  final status = <HostPermission, PermissionStatus?>{};
  for (final p in kHostPermissions) {
    try {
      status[p] = await platform.permissionStatus(p);
    } on Object {
      status[p] = null;
    }
  }
  final restricted = platform is AndroidHostPlatform &&
      status[HostPermission.inputControl] == PermissionStatus.denied &&
      await platform.isRestrictedSettingsLikely();
  return HostPermissionCheck(status: status, restrictedLikely: restricted);
}
