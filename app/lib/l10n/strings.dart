import 'package:flutter/widgets.dart';

import 'strings_table.dart';

/// The two UI languages. Russian is chosen for `ru` locales, English for
/// everything else, unless the user picks one in Settings → Appearance.
enum AppLanguage {
  english('en'),
  russian('ru');

  const AppLanguage(this.code);
  final String code;

  static AppLanguage fromCode(String? code) =>
      code == 'ru' ? AppLanguage.russian : AppLanguage.english;
}

/// Setting values: follow the system, or force one language.
const String kLanguageSystem = 'system';

/// Maps a locale to a supported language.
AppLanguage languageForLocale(Locale? locale) =>
    locale?.languageCode == 'ru' ? AppLanguage.russian : AppLanguage.english;

/// The UI language for a stored setting (`system`, `en`, `ru`) and the
/// device's locale.
AppLanguage resolveLanguage(String setting, Locale systemLocale) {
  if (setting == 'ru') return AppLanguage.russian;
  if (setting == 'en') return AppLanguage.english;
  return languageForLocale(systemLocale);
}

/// Looks up UI strings. Map-based on purpose: no code generation, both
/// languages side by side in `strings_table.dart`, and a unit test verifies
/// that every key used in the source exists and that placeholders match.
class S {
  const S._(this.language);

  final AppLanguage language;

  /// Language-independent default for code without a [BuildContext] (session
  /// and network layers produce user-facing notices). The app keeps this in
  /// sync with the effective UI language.
  static S current = const S._(AppLanguage.english);

  static S forLanguage(AppLanguage language) => S._(language);

  static S forLocale(Locale? locale) => S._(languageForLocale(locale));

  /// Strings for the language of the nearest [Localizations].
  static S of(BuildContext context) => S.forLocale(Localizations.maybeLocaleOf(context));

  /// Translates [key], replacing `{name}` placeholders from [args].
  String t(String key, [Map<String, Object?> args = const {}]) {
    final entry = kStrings[key];
    if (entry == null) {
      assert(false, 'Missing string key: $key');
      return key;
    }
    var text = language == AppLanguage.russian ? entry.$2 : entry.$1;
    if (args.isNotEmpty) {
      args.forEach((name, value) {
        text = text.replaceAll('{$name}', '$value');
      });
    }
    return text;
  }

  /// Picks `key.one` / `key.few` / `key.many` / `key.other` by the language's
  /// plural rule for [n]; `{n}` is filled in automatically.
  String plural(String key, int n, [Map<String, Object?> args = const {}]) {
    return t('$key.${_form(n)}', {'n': n, ...args});
  }

  String _form(int n) {
    final abs = n.abs();
    if (language == AppLanguage.russian) {
      final m10 = abs % 10;
      final m100 = abs % 100;
      if (m10 == 1 && m100 != 11) return 'one';
      if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'few';
      return 'many';
    }
    return abs == 1 ? 'one' : 'other';
  }
}

extension LocalizedContext on BuildContext {
  /// `context.s.t('home.title')`
  S get s => S.of(this);
}
