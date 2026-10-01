// Unit tests -- REQ-429 tier (a): formatting-locale resolver.
//
// AC1(a): mobile's kPlatformSupportedLocales must equal
// PLATFORM_SUPPORTED_LOCALES, verified by parsing the .ts source directly
// (not hand-copying the list) so drift between the two files fails this
// test, not silently.
// AC1(c, formatting half): kFormattingFallbackLocale == 'en'.
// AC2(a): >=6 table-driven cases for resolveFormattingLocale, mirroring
// resolveSessionLocale, sourced from web/tests/unit/sessionLocale.test.ts's
// TC-1..TC-5 plus its 'pt-BR' exact-match case (design doc §0/§6).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/i18n/formatting_locale.dart';

/// Reads `web/src/i18n/sessionLocale.ts` relative to `apps/mobile` (the
/// `flutter test` working directory -- confirmed by
/// `forbidden_dependencies_guard_test.dart`'s own `File('pubspec.yaml')`
/// relative read) and regex-extracts the `PLATFORM_SUPPORTED_LOCALES` array
/// literal's string entries, in source order.
List<String> _parsePlatformSupportedLocalesFromSpaSource() {
  final source = File(
    '../../web/src/i18n/sessionLocale.ts',
  ).readAsStringSync();
  final arrayMatch = RegExp(
    r'export const PLATFORM_SUPPORTED_LOCALES = \[([\s\S]*?)\]',
  ).firstMatch(source);
  if (arrayMatch == null) {
    fail('PLATFORM_SUPPORTED_LOCALES array literal not found in sessionLocale.ts');
  }
  final body = arrayMatch.group(1)!;
  return RegExp(r"'([^']+)'")
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toList();
}

void main() {
  test(
    'AC1a: kPlatformSupportedLocales == PLATFORM_SUPPORTED_LOCALES (parsed from sessionLocale.ts)',
    () {
      final spaList = _parsePlatformSupportedLocalesFromSpaSource();
      expect(kPlatformSupportedLocales, equals(spaList));
    },
  );

  test('AC1c (formatting half): kFormattingFallbackLocale == "en"', () {
    expect(kFormattingFallbackLocale, 'en');
  });

  test(
    'kFormattingFallbackLocale is a member of kPlatformSupportedLocales',
    () {
      expect(kPlatformSupportedLocales, contains(kFormattingFallbackLocale));
    },
  );

  group('AC2a: resolveFormattingLocale table (>=6 cases, sourced from '
      'sessionLocale.test.ts)', () {
    test('TC-1: supported device locale, no tenant default -> that locale', () {
      expect(
        resolveFormattingLocale(
          tenantDefaultLocale: null,
          deviceLocales: ['es-ES', 'en'],
        ),
        'es-ES',
      );
    });

    test(
      'TC-2: unsupported device locale list, no tenant default -> fallback',
      () {
        expect(
          resolveFormattingLocale(
            tenantDefaultLocale: null,
            deviceLocales: ['xx-XX', 'ja'],
          ),
          kFormattingFallbackLocale,
        );
      },
    );

    test('TC-3: no tenant default, empty device locales -> fallback', () {
      expect(
        resolveFormattingLocale(tenantDefaultLocale: null, deviceLocales: []),
        kFormattingFallbackLocale,
      );
    });

    test('TC-4: tenant default wins over device preference', () {
      expect(
        resolveFormattingLocale(
          tenantDefaultLocale: 'fr-FR',
          deviceLocales: ['de-DE'],
        ),
        'fr-FR',
      );
    });

    test('TC-5: no tenant default -> device preference used', () {
      expect(
        resolveFormattingLocale(
          tenantDefaultLocale: null,
          deviceLocales: ['de-DE'],
        ),
        'de-DE',
      );
    });

    test(
      'unsupported tenant default does not win -- falls through to device preference',
      () {
        expect(
          resolveFormattingLocale(
            tenantDefaultLocale: 'xx-XX',
            deviceLocales: ['de-DE'],
          ),
          'de-DE',
        );
      },
    );

    test(
      "'pt-BR' exact match: tenant default 'pt-BR' resolves to 'pt-BR' "
      '(sourced from sessionLocale.test.ts\'s setTenantDefaultLocale(\'pt-BR\') case)',
      () {
        expect(
          resolveFormattingLocale(tenantDefaultLocale: 'pt-BR'),
          'pt-BR',
        );
      },
    );
  });
}
