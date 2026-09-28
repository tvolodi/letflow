// Static guard (REQ-419 §6b): pubspec.yaml and pubspec.lock must contain
// no script runtime, no CEL package (REQ-294 forbids one on-device), and
// no webview package (MOB-2 forbids embedded webview OIDC).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Package names forbidden by exact (case-insensitive) match.
const List<String> _forbiddenExact = [
  'flutter_js',
  'webview_flutter',
  'flutter_inappwebview',
];

/// Substrings forbidden anywhere in a package name (case-insensitive) —
/// deliberately broader than exact-name match to catch adjacent packages
/// (`webview_flutter_android`, `flutter_inappwebview_platform_interface`,
/// a hypothetical `cel_dart`, etc.).
const List<String> _forbiddenSubstrings = ['lua', 'wasm', 'cel'];

/// One detected forbidden-dependency violation.
class ForbiddenDependencyViolation {
  ForbiddenDependencyViolation(this.packageName, this.reason);

  final String packageName;
  final String reason;

  @override
  String toString() => '$packageName: $reason';
}

/// Extracts dependency package names from raw `pubspec.yaml` content:
/// keys directly under a `dependencies:` or `dev_dependencies:` block
/// (2-space indented, `name:` or `name: <value>`).
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

/// Checks a list of package names against the forbidden set. Pure
/// function so the self-test can exercise it without touching the real
/// files.
List<ForbiddenDependencyViolation> checkForbiddenDependencies(
  List<String> packageNames,
) {
  final violations = <ForbiddenDependencyViolation>[];
  for (final name in packageNames) {
    final lower = name.toLowerCase();
    if (_forbiddenExact.any((f) => f.toLowerCase() == lower)) {
      violations.add(
        ForbiddenDependencyViolation(name, 'exact-match forbidden package'),
      );
      continue;
    }
    for (final substring in _forbiddenSubstrings) {
      if (lower.contains(substring)) {
        violations.add(
          ForbiddenDependencyViolation(
            name,
            'name contains forbidden substring "$substring"',
          ),
        );
        break;
      }
    }
  }
  return violations;
}

void main() {
  test(
    'real pubspec.yaml and pubspec.lock contain no forbidden dependency',
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

      final violations = checkForbiddenDependencies(names);

      expect(
        violations,
        isEmpty,
        reason: violations.map((v) => v.toString()).join('\n'),
      );
    },
  );

  test('self-test: checker fires on a pubspec containing webview_flutter', () {
    const fixtureYaml = 'dependencies:\n  webview_flutter: ^3.0.0\n';
    final names = extractPubspecYamlDependencyNames(fixtureYaml);

    final violations = checkForbiddenDependencies(names);

    expect(violations, isNotEmpty);
    expect(violations.single.packageName, 'webview_flutter');
  });
}
