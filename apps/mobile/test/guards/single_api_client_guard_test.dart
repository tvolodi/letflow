// Static guard (REQ-425 design §4, MOB-6): the only directory under `lib/`
// permitted to import a raw HTTP transport package (`package:dio`,
// `package:http`) or construct a `dart:io` `HttpClient` is `lib/api/` — the
// Dart-side counterpart of `web/tests/guards/forbidlist.ts`'s
// `raw-fetch-outside-client` pattern. Modeled directly on
// `token_storage_boundary_guard_test.dart`'s three-part idiom (pure checker
// over an in-memory file map + a real-tree test + a self-test fixture).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The one sanctioned directory for raw HTTP-transport imports.
const String sanctionedApiDirectory = 'lib/api/';

/// One detected single-api-client-boundary violation.
class SingleApiClientViolation {
  SingleApiClientViolation(this.file, this.kind);

  final String file;
  final String kind;

  @override
  String toString() => '$file: $kind';
}

final RegExp _dioImport = RegExp(r'''import\s+['"]package:dio/[^'"]+['"]''');
final RegExp _httpImport = RegExp(r'''import\s+['"]package:http/[^'"]+['"]''');
final RegExp _dartIoImport = RegExp(r'''import\s+['"]dart:io['"]''');
final RegExp _httpClientConstruction = RegExp(r'''\bHttpClient\s*\(''');

/// Checks a set of in-memory Dart files (`{relativePath: content}`) for
/// single-api-client-boundary violations (design §4.1). Pure function so the
/// self-test can exercise it without touching the real tree.
List<SingleApiClientViolation> checkSingleApiClientBoundary({
  required Map<String, String> libFiles,
}) {
  final violations = <SingleApiClientViolation>[];

  for (final entry in libFiles.entries) {
    final path = entry.key;
    final content = entry.value;

    if (path.startsWith(sanctionedApiDirectory)) {
      continue;
    }

    if (_dioImport.hasMatch(content)) {
      violations.add(
        SingleApiClientViolation(
          path,
          'imports package:dio outside $sanctionedApiDirectory',
        ),
      );
    }
    if (_httpImport.hasMatch(content)) {
      violations.add(
        SingleApiClientViolation(
          path,
          'imports package:http outside $sanctionedApiDirectory',
        ),
      );
    }
    if (_dartIoImport.hasMatch(content) &&
        _httpClientConstruction.hasMatch(content)) {
      violations.add(
        SingleApiClientViolation(
          path,
          'imports dart:io and constructs an HttpClient(...) outside'
          ' $sanctionedApiDirectory',
        ),
      );
    }
  }

  return violations;
}

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
  test('real lib/ tree has zero single-api-client-boundary violations', () {
    final files = _readRealLibFiles(Directory('lib'));

    final violations = checkSingleApiClientBoundary(libFiles: files);

    expect(
      violations,
      isEmpty,
      reason: violations.map((v) => v.toString()).join('\n'),
    );
  });

  test('self-test: checker fires on a fixture importing package:dio outside'
      ' lib/api/', () {
    final violations = checkSingleApiClientBoundary(
      libFiles: {
        'lib/features/exam/leaky_client.dart':
            "import 'package:dio/dio.dart';\n",
      },
    );

    expect(violations, hasLength(1));
    expect(violations.single.file, 'lib/features/exam/leaky_client.dart');
    expect(violations.single.kind, contains('package:dio'));
  });

  test('self-test: checker fires on a fixture importing package:http outside'
      ' lib/api/', () {
    final violations = checkSingleApiClientBoundary(
      libFiles: {
        'lib/features/exam/leaky_http.dart':
            "import 'package:http/http.dart';\n",
      },
    );

    expect(violations, hasLength(1));
    expect(violations.single.file, 'lib/features/exam/leaky_http.dart');
    expect(violations.single.kind, contains('package:http'));
  });

  test('self-test: checker fires on a fixture constructing a dart:io'
      ' HttpClient( outside lib/api/', () {
    final violations = checkSingleApiClientBoundary(
      libFiles: {
        'lib/renderers/leaky_renderer.dart':
            "import 'dart:io';\nfinal c = HttpClient();\n",
      },
    );

    expect(violations, hasLength(1));
    expect(violations.single.file, 'lib/renderers/leaky_renderer.dart');
    expect(violations.single.kind, contains('HttpClient'));
  });

  test('self-test: a package:dio import INSIDE lib/api/ fires zero'
      ' violations (the sanctioned directory is exempt)', () {
    final violations = checkSingleApiClientBoundary(
      libFiles: {'lib/api/leaky.dart': "import 'package:dio/dio.dart';\n"},
    );

    expect(violations, isEmpty);
  });
}
