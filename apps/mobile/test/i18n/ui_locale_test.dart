// Unit tests -- REQ-429 tier (b): UI-string-locale resolver.
//
// AC1(b): mobile's kEntitiesUiLocales must equal ENTITIES_UI_LOCALES,
// verified by parsing entitiesMessages.ts's source directly.
// AC1(c, UI half): kEntitiesUiFallbackLocale == 'en'.
// AC1(d): one ARB file per ENTITIES_UI_LOCALES entry, exactly.
// AC2(b): table asserting resolveUiLocale matches resolveUiLocale's
// base-tag rule, including the two named examples.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/i18n/ui_locale.dart';

/// Reads `web/src/i18n/entitiesMessages.ts` relative to `apps/mobile` and
/// regex-extracts the `ENTITIES_UI_LOCALES` array literal's string entries,
/// in source order.
List<String> _parseEntitiesUiLocalesFromSpaSource() {
  final source = File(
    '../../web/src/i18n/entitiesMessages.ts',
  ).readAsStringSync();
  final arrayMatch = RegExp(
    r'export const ENTITIES_UI_LOCALES = \[([\s\S]*?)\]',
  ).firstMatch(source);
  if (arrayMatch == null) {
    fail('ENTITIES_UI_LOCALES array literal not found in entitiesMessages.ts');
  }
  final body = arrayMatch.group(1)!;
  return RegExp(r"'([^']+)'")
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toList();
}

void main() {
  test(
    'AC1b: kEntitiesUiLocales == ENTITIES_UI_LOCALES (parsed from entitiesMessages.ts)',
    () {
      final spaList = _parseEntitiesUiLocalesFromSpaSource();
      expect(kEntitiesUiLocales, equals(spaList));
    },
  );

  test('AC1c (UI half): kEntitiesUiFallbackLocale == "en"', () {
    expect(kEntitiesUiFallbackLocale, 'en');
  });

  test(
    'kEntitiesUiFallbackLocale is a member of kEntitiesUiLocales',
    () {
      expect(kEntitiesUiLocales, contains(kEntitiesUiFallbackLocale));
    },
  );

  test(
    'AC1d: exactly one ARB file under lib/i18n/l10n/ per kEntitiesUiLocales entry',
    () {
      final dir = Directory('lib/i18n/l10n');
      expect(dir.existsSync(), isTrue, reason: 'lib/i18n/l10n must exist');

      final arbFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.arb'))
          .toList();

      final locales = arbFiles.map((f) {
        final decoded =
            json.decode(f.readAsStringSync()) as Map<String, dynamic>;
        return decoded['@@locale'] as String;
      }).toList();

      expect(
        locales.toSet(),
        equals(kEntitiesUiLocales.toSet()),
        reason: 'ARB @@locale set must equal kEntitiesUiLocales exactly',
      );
      expect(
        locales.length,
        kEntitiesUiLocales.length,
        reason: 'exactly one ARB file per entry, no duplicates/extras',
      );
    },
  );

  group('AC2b: resolveUiLocale table (base-tag rule, incl. named examples)', () {
    test("['ru-RU'] -> 'ru' (named example)", () {
      expect(resolveUiLocale(['ru-RU']), 'ru');
    });

    test("['de-DE'] -> 'en' (named example -- 'de' is not a member)", () {
      expect(resolveUiLocale(['de-DE']), 'en');
    });

    test("['kk-KZ'] -> 'kk'", () {
      expect(resolveUiLocale(['kk-KZ']), 'kk');
    });

    test("['en-US'] -> 'en'", () {
      expect(resolveUiLocale(['en-US']), 'en');
    });

    test("['EN'] -> 'en' (base-tag match is case-insensitive via lowercasing)", () {
      expect(resolveUiLocale(['EN']), 'en');
    });

    test(
      "['xx-XX', 'ru-RU'] -> 'ru' (first candidate unsupported, second matches)",
      () {
        expect(resolveUiLocale(['xx-XX', 'ru-RU']), 'ru');
      },
    );

    test('[] -> kEntitiesUiFallbackLocale (empty candidate list)', () {
      expect(resolveUiLocale([]), kEntitiesUiFallbackLocale);
    });
  });
}
