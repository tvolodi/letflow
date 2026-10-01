// Unit tests -- REQ-429 tier (c): tenant-content {locale: value} resolver.
//
// AC3(a-e): each sub-clause gets its own distinct, independently-failing
// test case (ISS-0880 lesson -- a combined test would silently under-cover
// a multi-clause AC).
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/i18n/localized_text.dart';

void main() {
  test('AC3a: UI-locale-key hit resolves to that value', () {
    expect(
      resolveLocalizedText({'en': 'Hello', 'ru': 'Привет', 'kk': 'Сәлем'}, 'ru'),
      'Привет',
    );
  });

  test('AC3b: fallback to "en" key when UI-locale key is absent', () {
    expect(
      resolveLocalizedText({'en': 'Hello', 'kk': 'Сәлем'}, 'ru'),
      'Hello',
    );
  });

  test(
    'AC3c: fallback to first non-empty value when neither UI-locale nor "en" present',
    () {
      expect(
        resolveLocalizedText({'kk': 'Сәлем', 'fr': 'Bonjour'}, 'ru'),
        'Сәлем',
      );
    },
  );

  test('AC3d: fallback to "" when the whole map is empty/all-blank', () {
    expect(resolveLocalizedText(<String, String>{}, 'ru'), '');
    expect(resolveLocalizedText({'en': '', 'ru': ''}, 'ru'), '');
  });

  test('AC3e: a plain string value passes through unchanged', () {
    expect(resolveLocalizedText('just a string', 'ru'), 'just a string');
  });

  test('null value resolves to "" (totality, not an AC3 sub-clause itself)', () {
    expect(resolveLocalizedText(null, 'ru'), '');
  });
}
