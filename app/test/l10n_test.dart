import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/l10n/strings.dart';
import 'package:thelxis/l10n/strings_table.dart';

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    // Modules owned by other agents bring their own strings.
    .where((f) => !f.path.contains('/l10n/') && !f.path.contains('/files/') && !f.path.contains('/update/'));

final _placeholder = RegExp(r'\{(\w+)\}');

void main() {
  test('every key used in the source exists in the table', () {
    final used = <String>{};
    final usedPlurals = <String>{};
    final re = RegExp(r"""\b(t|plural)\(\s*'([^'$]+)'""");
    for (final f in _dartFiles()) {
      for (final m in re.allMatches(f.readAsStringSync())) {
        (m.group(1) == 'plural' ? usedPlurals : used).add(m.group(2)!);
      }
    }
    expect(used, isNotEmpty);
    final missing = [
      for (final k in used)
        if (!kStrings.containsKey(k)) k,
      for (final k in usedPlurals)
        for (final form in ['one', 'few', 'many', 'other'])
          if (!kStrings.containsKey('$k.$form')) '$k.$form',
    ];
    expect(missing, isEmpty, reason: 'missing keys: $missing');
  });

  test('dynamic key families are complete', () {
    for (final k in ['nav.home', 'nav.devices', 'nav.sessions', 'nav.settings']) {
      expect(kStrings.containsKey(k), isTrue, reason: k);
    }
    for (final r in ['denied', 'remote', 'timeout', 'error', 'security']) {
      expect(kStrings.containsKey('reason.$r'), isTrue, reason: r);
    }
  });

  test('no entry is empty and placeholders agree between languages', () {
    kStrings.forEach((key, v) {
      expect(v.$1.trim(), isNotEmpty, reason: '$key (en)');
      expect(v.$2.trim(), isNotEmpty, reason: '$key (ru)');
      final en = _placeholder.allMatches(v.$1).map((m) => m.group(1)!).toSet();
      final ru = _placeholder.allMatches(v.$2).map((m) => m.group(1)!).toSet();
      expect(ru, en, reason: 'placeholders differ for $key');
    });
  });

  test('Russian text is actually Russian where English is, and English is not Cyrillic', () {
    final cyr = RegExp('[А-Яа-яЁё]');
    // Names and technical tokens may legitimately match in both languages.
    const same = {
      'home.idNoun', 'session.idLine', 'stats.fps', 'common.ok', 'diag.ipv6',
    };
    kStrings.forEach((key, v) {
      expect(cyr.hasMatch(v.$1), isFalse, reason: 'English text of $key contains Cyrillic');
      if (!same.contains(key) && v.$1.length > 3) {
        expect(cyr.hasMatch(v.$2), isTrue, reason: 'Russian text of $key is not translated: ${v.$2}');
      }
    });
  });

  group('S lookup', () {
    final en = S.forLanguage(AppLanguage.english);
    final ru = S.forLanguage(AppLanguage.russian);

    test('translates and interpolates', () {
      expect(en.t('prompt.accept.title', {'who': 'Alice'}), 'Alice wants to connect');
      expect(ru.t('prompt.accept.title', {'who': 'Alice'}), 'Alice хочет подключиться');
      expect(ru.t('badge.stop'), 'Отключить');
      expect(ru.t('badge.one', {'name': 'Alice'}), 'Подключён: Alice');
    });

    test('Russian plural rule', () {
      String f(int n) => ru.plural('badge.many', n);
      expect(f(1), 'Подключён: 1');
      expect(f(2), 'Подключено: 2');
      expect(f(4), 'Подключено: 4');
      expect(f(5), 'Подключено: 5');
      expect(f(11), 'Подключено: 11');
      expect(f(21), 'Подключён: 21');
      expect(f(22), 'Подключено: 22');
      expect(f(112), 'Подключено: 112');
      expect(f(0), 'Подключено: 0');
    });

    test('English plural rule', () {
      expect(en.plural('import.done', 1), 'Imported 1 device');
      expect(en.plural('import.done', 3), 'Imported 3 devices');
      expect(en.plural('import.done', 0), 'Imported 0 devices');
    });
  });

  test('language follows the system locale: Russian for ru, English otherwise', () {
    expect(languageForLocale(const Locale('ru', 'RU')), AppLanguage.russian);
    expect(languageForLocale(const Locale('ru')), AppLanguage.russian);
    expect(languageForLocale(const Locale('en', 'US')), AppLanguage.english);
    expect(languageForLocale(const Locale('de')), AppLanguage.english);
    expect(languageForLocale(const Locale('uk')), AppLanguage.english);
    expect(languageForLocale(null), AppLanguage.english);
  });
}
