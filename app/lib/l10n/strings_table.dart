import 'strings_connectivity.dart';
import 'strings_core.dart';
import 'strings_devices.dart';
import 'strings_session.dart';
import 'strings_settings.dart';

/// Every UI string as `key: (English, Russian)`. Placeholders are `{name}`.
/// Plural groups use `.one/.few/.many/.other` suffixes (English uses `one` and
/// `other`; its `few`/`many` repeat `other`).
final Map<String, (String, String)> kStrings = {
  ...kCoreStrings,
  ...kConnectivityStrings,
  ...kDevicesStrings,
  ...kSessionStrings,
  ...kSettingsStrings,
};
