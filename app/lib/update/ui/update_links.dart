import 'package:url_launcher/url_launcher.dart';

import '../update_trust.dart';

/// Opens an https link in the system browser. Anything else is ignored; link
/// targets come from the signed manifest but are still validated.
Future<void> openUpdateLink(Uri? uri) async {
  if (uri == null || uri.scheme != 'https') return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    // No browser available: nothing sensible to show for a convenience link.
  }
}

/// GitHub release page of [version].
Uri releaseUrl(String version) => Uri.parse('https://github.com/${UpdateTrust.repo}/releases/tag/v$version');

/// GitHub page listing the latest release.
Uri latestReleaseUrl() => Uri.parse('https://github.com/${UpdateTrust.repo}/releases/latest');
