// AC6: docs/mobile/requirements.md MOB-2 and docs/mobile/architecture.md §3
// each carry the dated client_id note, with the original five-key text
// still present (the additive-only edit itself is verified by `git diff`
// at review time; this test guards against a future accidental removal of
// either the original text or the added note).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('requirements.md keeps the original five-key bullet and gained the'
      ' dated client_id note', () {
    final content = File(
      '../../docs/mobile/requirements.md',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      content,
      contains(
        '`GET /tenant-config` returns `{ realm_url, locales, default_locale, branding,\n'
        '  environment_kind }` **without a bearer token**.',
      ),
    );
    expect(content, contains('Added 2026-09-28 (`REQ-418`)'));
    expect(
      content,
      contains(
        '{ realm_url, locales,\n'
        '  default_locale, branding, environment_kind, client_id }',
      ),
    );
  });

  test('architecture.md keeps the original five-key row and gained the'
      ' dated client_id note', () {
    final content = File(
      '../../docs/mobile/architecture.md',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      content,
      contains(
        'An **unauthenticated** `tenant-config` endpoint returning `{ realm_url, '
        'locales, default_locale, branding, environment_kind }`, for slug-based '
        'bootstrap before any token exists.',
      ),
    );
    expect(content, contains('Added 2026-09-28 (`REQ-418`)'));
    expect(content, contains('The response now returns six keys, not\nfive'));
  });
}
