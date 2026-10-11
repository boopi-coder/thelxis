import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where users can support the author.
const kBoostyUrl = 'https://boosty.to/boopi_coder';

/// Opens [uri] outside the app. Replaced in tests, which must never reach a
/// real browser.
typedef ExternalLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

ExternalLauncher _launcher = _launchExternal;

@visibleForTesting
set externalLauncher(ExternalLauncher? launcher) =>
    _launcher = launcher ?? _launchExternal;

/// Opens the Boosty page in the system browser. Failure (no browser) is
/// ignored: it is a convenience link with nothing sensible to report.
Future<void> openBoosty() async {
  try {
    await _launcher(Uri.parse(kBoostyUrl));
  } on Object {
    // See above.
  }
}
