// Static guard (REQ-430, MOB-8): v1 is online-first with a read-through
// definition cache. Two checkers enforce the two static-checkable pieces of
// that boundary:
//
//  - Checker A: no push/messaging or background-task-scheduling dependency
//    in pubspec.yaml/pubspec.lock (the on-ramp to push-based cache
//    invalidation and to an offline-write-queue flush scheduler).
//  - Checker B: no `.record(...).put(...)` call persisting a value shaped
//    like an outgoing HTTP request (method/url/body) -- the shape of an
//    offline write-queue entry.
//
// The on-device form builder, MOB-8's third exclusion, has no dependency or
// code-shape signature to scan and is therefore not guarded here; it is
// enforced by requirement scope alone (see docs/mobile/architecture.md §4).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Checker A -- forbidden push/background-task dependency
// ---------------------------------------------------------------------------

/// Package names forbidden by exact (case-insensitive) match: push/
/// messaging SDKs and background-task schedulers. MOB-8 forbids "push-based
/// cache invalidation" and implicitly anything that would let the device
/// receive a background wake/message or run code while not foregrounded,
/// since that is the on-ramp to both push invalidation and a write-queue
/// flush scheduler.
const List<String> _forbiddenExact = [
  // Push / messaging
  'firebase_messaging', // the canonical "push" SDK named in MOB-8's text
  'onesignal_flutter', // a common third-party push SDK -- "or equivalent"
  'flutter_fcm',
  // Background task / scheduling
  'workmanager', // named explicitly in REQ-430's task text
  'android_alarm_manager_plus',
  'background_fetch',
  'flutter_background_service',
];

/// Substrings forbidden anywhere in a package name (case-insensitive),
/// catching adjacent/platform-interface packages the same way
/// `forbidden_dependencies_guard_test.dart` already does for
/// `lua`/`wasm`/`cel`.
const List<String> _forbiddenSubstrings = [
  'workmanager', // catches workmanager_android, workmanager_platform_interface, etc.
  'alarm_manager',
  'background_fetch',
  'onesignal',
  'firebase_messaging',
];

/// One detected v1-scope dependency violation.
class ScopeDependencyViolation {
  ScopeDependencyViolation(this.packageName, this.reason);

  final String packageName;
  final String reason;

  @override
  String toString() => '$packageName: $reason';
}

/// Extracts dependency package names from raw `pubspec.yaml` content: keys
/// directly under a `dependencies:` or `dev_dependencies:` block (2-space
/// indented, `name:` or `name: <value>`).
///
/// Duplicated verbatim from `forbidden_dependencies_guard_test.dart` per the
/// design doc's OQ-1 (precedent already set between guard files for
/// tree-scanning helpers like `_relativeTo`/`_readRealLibFiles`, rather than
/// sharing private helpers cross-file).
List<String> extractPubspecYamlDependencyNames(String yamlContent) {
  final names = <String>[];
  var inDepsBlock = false;
  for (final rawLine in yamlContent.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line == 'dependencies:' || line == 'dev_dependencies:') {
      inDepsBlock = true;
      continue;
    }
    if (line.isEmpty) continue;
    if (!line.startsWith(' ') && line.trimRight().endsWith(':')) {
      // A new top-level block started.
      inDepsBlock = false;
      continue;
    }
    if (!inDepsBlock) continue;
    final match = RegExp(r'^  ([A-Za-z0-9_]+):').firstMatch(line);
    if (match != null) {
      names.add(match.group(1)!);
    }
  }
  return names;
}

/// Extracts package names from raw `pubspec.lock` content: top-level
/// (2-space-indented) keys under the `packages:` block.
///
/// Duplicated verbatim from `forbidden_dependencies_guard_test.dart` (see
/// doc comment on `extractPubspecYamlDependencyNames` above).
List<String> extractPubspecLockPackageNames(String lockContent) {
  final names = <String>[];
  var inPackagesBlock = false;
  for (final rawLine in lockContent.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line == 'packages:') {
      inPackagesBlock = true;
      continue;
    }
    if (!inPackagesBlock) continue;
    final match = RegExp(r'^  ([A-Za-z0-9_]+):\s*$').firstMatch(line);
    if (match != null) {
      names.add(match.group(1)!);
    }
  }
  return names;
}

/// Checks a list of package names against the v1-scope-boundary forbidden
/// set. Pure function so the self-test can exercise it without touching the
/// real files.
List<ScopeDependencyViolation> checkV1ScopeDependencies(
  List<String> packageNames,
) {
  final violations = <ScopeDependencyViolation>[];
  for (final name in packageNames) {
    final lower = name.toLowerCase();
    if (_forbiddenExact.any((f) => f.toLowerCase() == lower)) {
      violations.add(
        ScopeDependencyViolation(
          name,
          'push/messaging or background-task package forbidden by MOB-8',
        ),
      );
      continue;
    }
    for (final substring in _forbiddenSubstrings) {
      if (lower.contains(substring)) {
        violations.add(
          ScopeDependencyViolation(
            name,
            'name contains forbidden substring "$substring" (MOB-8)',
          ),
        );
        break;
      }
    }
  }
  return violations;
}

// ---------------------------------------------------------------------------
// Checker B -- persisted outgoing-request shape (write-queue detector)
// ---------------------------------------------------------------------------

/// One detected outgoing-request-persistence violation.
class OutgoingRequestPersistenceViolation {
  OutgoingRequestPersistenceViolation(
    this.file,
    this.approxLine,
    this.matchedKeys,
  );

  final String file;
  final int approxLine;
  final List<String> matchedKeys;

  @override
  String toString() => '$file:$approxLine: matched keys $matchedKeys';
}

final RegExp _recordPutCall = RegExp(r'\.record\([^)]*\)\.put\(');

/// Key-name tokens that, when two or more appear together near a
/// `.record(...).put(...)` call, indicate the persisted value is shaped
/// like an outgoing HTTP request (a write-queue entry) rather than a
/// definition/cache envelope. `request` alone counts as two of its own,
/// since it names the whole outgoing-request shape directly.
const Map<String, int> _requestShapeKeyWeights = {
  'method': 1,
  'httpmethod': 1,
  'url': 1,
  'uri': 1,
  'body': 1,
  'payload': 1,
  'request': 2,
};

/// Window of source text scanned around each `.record(...).put(...)`
/// call-site. This guard uses a fixed-size preceding-character window
/// (design doc OQ-2's simpler option) rather than a true smallest-
/// enclosing-`{...}`-block scan, because a naive brace counter can be
/// desynced by `{`/`}` characters inside string literals or comments. This
/// is documented as a known, accepted false-negative boundary below.
const int _scanWindowChars = 400;

/// Checks a set of in-memory Dart files (`{relativePath: content}`) for the
/// outgoing-request-persistence shape (REQ-430 §1.2). Pure function so the
/// self-test can exercise it without touching the real tree.
///
/// Known, documented limitations (static textual heuristic, not an AST or
/// type-level check -- same honesty standard as
/// `token_storage_boundary_guard_test.dart`):
///
///  - Does NOT catch a write-queue built from renamed fields (e.g.
///    `verb`/`endpoint`/`data` instead of `method`/`url`/`body`). This is a
///    lint-level static gate, not a type system; MOB-8's real backstop is
///    architectural (no conflict model exists server-side to resolve a
///    replayed write), not this guard.
///  - Does NOT catch a write-queue assembled across multiple statements
///    (e.g. building a `Map` field-by-field across several lines outside
///    the scanned window, then passing a single pre-built variable into
///    `.put()`) if the key literals fall outside the fixed window.
///  - Does NOT evaluate semantics -- a map legitimately named
///    `method`/`url` for an unrelated reason would be a false positive.
///    None of the current definition/cache schemas
///    (`sembast_cache_repository.dart`,
///    `sembast_pinned_form_cache_repository.dart`) use these key names, so
///    this is not expected to fire today.
///  - Only intended to scan `.dart` files under `apps/mobile/lib/` (callers
///    pass that file set in; the function itself is tree-agnostic).
List<OutgoingRequestPersistenceViolation> checkNoPersistedOutgoingRequests({
  required Map<String, String> libFiles,
}) {
  final violations = <OutgoingRequestPersistenceViolation>[];

  for (final entry in libFiles.entries) {
    final path = entry.key;
    final content = entry.value;

    for (final match in _recordPutCall.allMatches(content)) {
      final windowStart = (match.start - _scanWindowChars).clamp(
        0,
        content.length,
      );
      // Extend forward a little past the `.put(` opening paren too, so a
      // map literal written entirely as the `.put(...)` argument (the
      // common case) is captured even when the window start lands exactly
      // on the call-site.
      final windowEnd = (match.end + _scanWindowChars).clamp(
        0,
        content.length,
      );
      final window = content.substring(windowStart, windowEnd);

      final matchedKeys = <String>[];
      var score = 0;
      for (final keyEntry in _requestShapeKeyWeights.entries) {
        final key = keyEntry.key;
        final quotedKey = RegExp(
          '''['"]${RegExp.escape(key)}['"]\\s*:''',
          caseSensitive: false,
        );
        final namedArgKey = RegExp(
          '''(?<![.\\w])${RegExp.escape(key)}\\s*:''',
          caseSensitive: false,
        );
        if (quotedKey.hasMatch(window) || namedArgKey.hasMatch(window)) {
          matchedKeys.add(key);
          score += keyEntry.value;
        }
      }

      if (score >= 2) {
        final approxLine = '\n'.allMatches(content.substring(0, match.start)).length + 1;
        violations.add(
          OutgoingRequestPersistenceViolation(path, approxLine, matchedKeys),
        );
      }
    }
  }

  return violations;
}

// ---------------------------------------------------------------------------
// Real-tree wiring
// ---------------------------------------------------------------------------

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

void main() {
  test(
    'real pubspec.yaml/pubspec.lock and lib/ tree have zero v1-scope-boundary'
    ' violations',
    () {
      final yamlContent = File('pubspec.yaml').readAsStringSync();
      final lockFile = File('pubspec.lock');
      final lockContent = lockFile.existsSync()
          ? lockFile.readAsStringSync()
          : '';

      final names = <String>{
        ...extractPubspecYamlDependencyNames(yamlContent),
        ...extractPubspecLockPackageNames(lockContent),
      }.toList();

      final depViolations = checkV1ScopeDependencies(names);
      expect(
        depViolations,
        isEmpty,
        reason: depViolations.map((v) => v.toString()).join('\n'),
      );

      final libFiles = _readRealLibFiles(Directory('lib'));
      final persistViolations = checkNoPersistedOutgoingRequests(
        libFiles: libFiles,
      );
      expect(
        persistViolations,
        isEmpty,
        reason: persistViolations.map((v) => v.toString()).join('\n'),
      );
    },
  );

  test('self-test: checker fires on a pubspec containing firebase_messaging', () {
    const fixtureYaml = 'dependencies:\n  firebase_messaging: ^15.0.0\n';
    final names = extractPubspecYamlDependencyNames(fixtureYaml);

    final violations = checkV1ScopeDependencies(names);

    expect(violations, hasLength(1));
    expect(violations.single.packageName, 'firebase_messaging');
  });

  test('self-test: checker fires on a pubspec containing workmanager', () {
    const fixtureYaml = 'dependencies:\n  workmanager: ^0.5.2\n';
    final names = extractPubspecYamlDependencyNames(fixtureYaml);

    final violations = checkV1ScopeDependencies(names);

    expect(violations, hasLength(1));
    expect(violations.single.packageName, 'workmanager');
  });

  test(
    'self-test: checker fires on a Dart file writing a request'
    ' method/url/body map to a store',
    () {
      const fixture = '''
Future<void> enqueue() async {
  await _store.record(id).put(db, {
    'method': 'POST',
    'url': '/api/v1/instances/42/submit',
    'body': formValues,
  });
}
''';

      final violations = checkNoPersistedOutgoingRequests(
        libFiles: {'lib/sync/outbox_fixture.dart': fixture},
      );

      expect(violations, hasLength(1));
      expect(violations.single.file, 'lib/sync/outbox_fixture.dart');
      expect(violations.single.matchedKeys, containsAll(['method', 'url', 'body']));
    },
  );

  test(
    'self-test: a definition-cache-shaped .put() with unrelated keys fires'
    ' zero violations (boundary is shape-specific, not every .put() call)',
    () {
      const fixture = '''
Future<void> cacheDefinition() async {
  await _store.record(id).put(db, {
    'definition_id': id,
    'version': version,
    'schema': schemaJson,
  });
}
''';

      final violations = checkNoPersistedOutgoingRequests(
        libFiles: {'lib/definitions/sembast_cache_repository_fixture.dart': fixture},
      );

      expect(violations, isEmpty);
    },
  );
}
