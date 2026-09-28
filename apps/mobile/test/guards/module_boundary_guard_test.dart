// Static guard (REQ-419 §6a): enforces the core/module import boundary
// (decision 0039 D3, restated in docs/mobile/architecture.md §6):
//
//   Rule 1: no file outside lib/features/<id>/ may import from inside it,
//           except the one sanctioned navigation-bootstrap file.
//   Rule 2: lib/features/a/ may import from lib/features/b/ only if b is
//           declared in a's depends_on list in module_manifest.json.
//
// Must fail the build (a normal `test()` assertion), not merely warn.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Path (relative to the Flutter project root) of the one file allowed to
/// import across feature boundaries — the navigation bootstrap.
const String sanctionedNavigationBootstrapPath =
    'lib/bootstrap/navigation_bootstrap.dart';

/// One detected boundary violation.
class BoundaryViolation {
  BoundaryViolation(this.importingFile, this.rule, this.detail);

  final String importingFile;
  final int rule;
  final String detail;

  @override
  String toString() => 'Rule $rule violation in $importingFile: $detail';
}

/// Regex matching a single-line Dart import of a quoted string literal,
/// e.g. `import 'package:letflow_mobile/features/a/thing.dart';` or
/// `import '../b/other.dart';`. Dart import statements are always
/// single-line quoted string literals, so a plain-text scan (no
/// `analyzer` package dependency) is sufficient.
final RegExp _importRegex = RegExp('''import\\s+['"]([^'"]+)['"]''');

/// Extracts the feature id from a normalized (`/`-separated) path if it
/// points inside `lib/features/<id>/`, else null.
String? _featureIdOf(String normalizedPath) {
  final match = RegExp(r'lib/features/([^/]+)/').firstMatch(normalizedPath);
  return match?.group(1);
}

/// Resolves an import target (which may be relative, or a
/// `package:<name>/...` URI) against the importing file's own directory,
/// returning a normalized `/`-separated path relative to the project
/// root, or the raw target if it cannot be resolved as a project-relative
/// path (e.g. a third-party package import, which can never point inside
/// `lib/features/`, so it's safe to leave unresolved).
String _resolveImportTarget(String importingFileRelPath, String target) {
  if (target.startsWith('package:')) {
    // `package:letflow/features/...` (any package name) -> strip the
    // `package:<name>/` prefix so it reads like a `lib/`-relative path.
    final withoutScheme = target.substring('package:'.length);
    final slash = withoutScheme.indexOf('/');
    if (slash == -1) return target;
    return 'lib/${withoutScheme.substring(slash + 1)}';
  }
  if (target.startsWith('dart:')) return target;
  // Relative import: resolve against the importing file's directory.
  final importingDir = importingFileRelPath.contains('/')
      ? importingFileRelPath.substring(0, importingFileRelPath.lastIndexOf('/'))
      : '';
  final segments = <String>[
    ...importingDir.split('/'),
    ...target.split('/'),
  ].where((s) => s.isNotEmpty).toList();
  final resolved = <String>[];
  for (final segment in segments) {
    if (segment == '.') continue;
    if (segment == '..') {
      if (resolved.isNotEmpty) resolved.removeLast();
      continue;
    }
    resolved.add(segment);
  }
  return resolved.join('/');
}

/// Reads `module_manifest.json` at [manifestPath] and returns
/// `{ featureId: depends_on list }`.
Map<String, List<String>> _readManifest(String manifestContent) {
  final decoded = jsonDecode(manifestContent) as Map<String, dynamic>;
  final features = (decoded['features'] as Map<String, dynamic>?) ?? {};
  return features.map((id, value) {
    final deps =
        (value as Map<String, dynamic>)['depends_on'] as List<dynamic>?;
    return MapEntry(id, deps?.cast<String>() ?? const <String>[]);
  });
}

/// Checks a set of in-memory Dart files (`{relativePath: content}`)
/// against the module boundary rules, given a manifest
/// (`{featureId: depends_on}`) and the set of feature ids that actually
/// have a directory on disk. Pure function so the self-test can exercise
/// it without touching the real tree.
List<BoundaryViolation> checkModuleBoundaries({
  required Map<String, String> files,
  required Map<String, List<String>> manifest,
  required Set<String> featureDirsPresent,
}) {
  final violations = <BoundaryViolation>[];

  // Fail closed: any feature directory missing from the manifest is
  // itself a violation.
  for (final featureId in featureDirsPresent) {
    if (!manifest.containsKey(featureId)) {
      violations.add(
        BoundaryViolation(
          'lib/features/$featureId/',
          0,
          'feature directory has no entry in module_manifest.json',
        ),
      );
    }
  }

  for (final entry in files.entries) {
    final path = entry.key;
    final content = entry.value;
    final importingFeatureId = _featureIdOf(path);

    for (final match in _importRegex.allMatches(content)) {
      final target = match.group(1)!;
      final resolvedTarget = _resolveImportTarget(path, target);
      final targetFeatureId = _featureIdOf(resolvedTarget);
      if (targetFeatureId == null) continue; // not a features/ import

      final isSanctionedFile = path == sanctionedNavigationBootstrapPath;
      final importerInsideSameFeature = importingFeatureId == targetFeatureId;

      if (!importerInsideSameFeature && !isSanctionedFile) {
        if (importingFeatureId == null) {
          violations.add(
            BoundaryViolation(
              path,
              1,
              'imports lib/features/$targetFeatureId/ from outside features/'
              ' and is not the sanctioned navigation-bootstrap file',
            ),
          );
        } else {
          final allowedDeps = manifest[importingFeatureId] ?? const <String>[];
          if (!allowedDeps.contains(targetFeatureId)) {
            violations.add(
              BoundaryViolation(
                path,
                2,
                'lib/features/$importingFeatureId/ imports lib/features/'
                '$targetFeatureId/ which is not in its depends_on list',
              ),
            );
          }
        }
      }
    }
  }

  return violations;
}

/// Walks [libDir] recursively and returns `{relativePath: content}` for
/// every `.dart` file, with paths relative to the Flutter project root
/// (i.e. prefixed with `lib/`) and `/`-separated regardless of platform.
Map<String, String> _readRealLibFiles(Directory libDir) {
  final files = <String, String>{};
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final relPath =
          'lib/${_relativeTo(libDir, entity).replaceAll('\\', '/')}';
      files[relPath] = entity.readAsStringSync();
    }
  }
  return files;
}

String _relativeTo(Directory base, File file) {
  final basePath = base.path.replaceAll('\\', '/');
  final filePath = file.path.replaceAll('\\', '/');
  return filePath.substring(basePath.length + 1);
}

Set<String> _realFeatureDirs(Directory libDir) {
  final featuresDir = Directory('${libDir.path}/features');
  if (!featuresDir.existsSync()) return {};
  return featuresDir
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.replaceAll('\\', '/').split('/').last)
      .toSet();
}

void main() {
  test('real lib/ tree has zero module boundary violations', () {
    final libDir = Directory('lib');
    final files = _readRealLibFiles(libDir);
    final manifestFile = File('lib/features/module_manifest.json');
    final manifest = _readManifest(manifestFile.readAsStringSync());
    final featureDirs = _realFeatureDirs(libDir);

    final violations = checkModuleBoundaries(
      files: files,
      manifest: manifest,
      featureDirsPresent: featureDirs,
    );

    expect(
      violations,
      isEmpty,
      reason: violations.map((v) => v.toString()).join('\n'),
    );
  });

  test('self-test: checker fires on a violating fixture (Rule 2)', () {
    // Two fake feature dirs, a.depends_on == [], and a file in a/ that
    // imports from b/ without declaring the dependency.
    final fixtureFiles = <String, String>{
      'lib/features/a/thing.dart': "import '../b/other.dart';\n",
    };
    final fixtureManifest = <String, List<String>>{
      'a': const [],
      'b': const [],
    };

    final violations = checkModuleBoundaries(
      files: fixtureFiles,
      manifest: fixtureManifest,
      featureDirsPresent: {'a', 'b'},
    );

    expect(violations, isNotEmpty);
    expect(violations.single.rule, 2);
    expect(violations.single.importingFile, 'lib/features/a/thing.dart');
  });
}
