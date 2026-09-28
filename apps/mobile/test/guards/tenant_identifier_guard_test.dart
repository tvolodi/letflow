// Static guard (REQ-419 §6c): no string literal in lib/ equals a tenant
// slug or realm name that exists in priv/keycloak/realms/*.json or
// test/support fixtures, and no asset under apps/mobile/assets/ is
// tenant-specific. `'bpm-default'` is the guaranteed floor.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Matches non-escaped single- or double-quoted string literal contents.
final RegExp _stringLiteralRegex = RegExp(''''([^'\\\\]*)'|"([^"\\\\]*)"''');

/// One detected compiled-in tenant identifier violation.
class TenantIdentifierViolation {
  TenantIdentifierViolation(this.location, this.slug);

  final String location;
  final String slug;

  @override
  String toString() => '$location contains forbidden literal "$slug"';
}

/// Extracts every quoted string-literal value found in [dartSource].
List<String> extractStringLiterals(String dartSource) {
  return _stringLiteralRegex
      .allMatches(dartSource)
      .map((m) => m.group(1) ?? m.group(2) ?? '')
      .toList();
}

/// Checks [dartSource] (attributed to [location] for reporting) for any
/// literal in [forbiddenSlugs]. Pure function so the self-test can
/// exercise it without touching the real tree.
List<TenantIdentifierViolation> checkTenantIdentifierLiterals({
  required String location,
  required String dartSource,
  required Set<String> forbiddenSlugs,
}) {
  final violations = <TenantIdentifierViolation>[];
  for (final literal in extractStringLiterals(dartSource)) {
    if (forbiddenSlugs.contains(literal)) {
      violations.add(TenantIdentifierViolation(location, literal));
    }
  }
  return violations;
}

/// Checks an asset path/name for a forbidden slug substring.
List<TenantIdentifierViolation> checkAssetPath({
  required String assetPath,
  required Set<String> forbiddenSlugs,
}) {
  final violations = <TenantIdentifierViolation>[];
  for (final slug in forbiddenSlugs) {
    if (assetPath.contains(slug)) {
      violations.add(TenantIdentifierViolation(assetPath, slug));
    }
  }
  return violations;
}

/// Reads every `priv/keycloak/realms/*.json` file's top-level `realm`
/// field, plus any slug literals declared in `test/support/` fixtures.
/// `'bpm-default'` is always included as the explicit floor.
Set<String> _realForbiddenSlugs() {
  final slugs = <String>{'bpm-default'};

  final realmsDir = Directory('../../priv/keycloak/realms');
  if (realmsDir.existsSync()) {
    for (final entity in realmsDir.listSync()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final decoded =
            jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
        final realm = decoded['realm'];
        if (realm is String) slugs.add(realm);
      }
    }
  }

  final supportDir = Directory('../../test/support');
  if (supportDir.existsSync()) {
    for (final entity in supportDir.listSync(recursive: true)) {
      if (entity is File &&
          (entity.path.endsWith('.json') ||
              entity.path.endsWith('.ex') ||
              entity.path.endsWith('.exs'))) {
        final content = entity.readAsStringSync();
        for (final match in RegExp('bpm-[a-z0-9-]+').allMatches(content)) {
          slugs.add(match.group(0)!);
        }
      }
    }
  }

  return slugs;
}

Map<String, String> _readRealLibFiles() {
  final libDir = Directory('lib');
  final files = <String, String>{};
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files[entity.path.replaceAll('\\', '/')] = entity.readAsStringSync();
    }
  }
  return files;
}

void main() {
  test(
    'real lib/ tree and assets/ contain no compiled-in tenant identifier',
    () {
      final forbiddenSlugs = _realForbiddenSlugs();
      expect(forbiddenSlugs, contains('bpm-default'));

      final violations = <TenantIdentifierViolation>[];
      for (final entry in _readRealLibFiles().entries) {
        violations.addAll(
          checkTenantIdentifierLiterals(
            location: entry.key,
            dartSource: entry.value,
            forbiddenSlugs: forbiddenSlugs,
          ),
        );
      }

      final assetsDir = Directory('assets');
      if (assetsDir.existsSync()) {
        for (final entity in assetsDir.listSync(recursive: true)) {
          violations.addAll(
            checkAssetPath(
              assetPath: entity.path.replaceAll('\\', '/'),
              forbiddenSlugs: forbiddenSlugs,
            ),
          );
        }
      }

      expect(
        violations,
        isEmpty,
        reason: violations.map((v) => v.toString()).join('\n'),
      );
    },
  );

  test('self-test: checker fires on a literal "bpm-default"', () {
    const fixtureSource = "const tenantSlug = 'bpm-default';";

    final violations = checkTenantIdentifierLiterals(
      location: 'fixture.dart',
      dartSource: fixtureSource,
      forbiddenSlugs: {'bpm-default'},
    );

    expect(violations, isNotEmpty);
    expect(violations.single.slug, 'bpm-default');
  });
}
