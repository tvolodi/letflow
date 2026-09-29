// Static guard (REQ-422 §1.3, MOB-5, AC1): the only file under `lib/`
// permitted to import `flutter_secure_storage` is `lib/auth/auth.dart`, and
// no file under `lib/auth/` or `lib/api/` uses `shared_preferences` or a
// `dart:io` `File(...)` persistence path.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The one sanctioned `flutter_secure_storage` import site.
const String sanctionedSecureStorageFile = 'lib/auth/auth.dart';

/// One detected token-storage-boundary violation.
class TokenStorageBoundaryViolation {
  TokenStorageBoundaryViolation(this.file, this.kind);

  final String file;
  final String kind;

  @override
  String toString() => '$file: $kind';
}

final RegExp _secureStorageImport = RegExp(
  r'''import\s+['"]package:flutter_secure_storage/[^'"]+['"]''',
);
final RegExp _sharedPreferencesImport = RegExp(
  r'''import\s+['"]package:shared_preferences/[^'"]+['"]''',
);
final RegExp _dartIoImport = RegExp(r'''import\s+['"]dart:io['"]''');
final RegExp _fileConstruction = RegExp(r'''File\(''');

/// Checks a set of in-memory Dart files (`{relativePath: content}`) for the
/// token-storage-boundary violations (REQ-422 §1.3). Pure function so the
/// self-test can exercise it without touching the real tree.
List<TokenStorageBoundaryViolation> checkTokenStorageBoundary({
  required Map<String, String> libFiles,
}) {
  final violations = <TokenStorageBoundaryViolation>[];

  for (final entry in libFiles.entries) {
    final path = entry.key;
    final content = entry.value;

    if (_secureStorageImport.hasMatch(content) &&
        path != sanctionedSecureStorageFile) {
      violations.add(
        TokenStorageBoundaryViolation(
          path,
          'imports flutter_secure_storage outside $sanctionedSecureStorageFile',
        ),
      );
    }

    final isAuthOrApi = path.startsWith('lib/auth/') || path.startsWith('lib/api/');
    if (isAuthOrApi && _sharedPreferencesImport.hasMatch(content)) {
      violations.add(
        TokenStorageBoundaryViolation(
          path,
          'imports shared_preferences in lib/auth/ or lib/api/',
        ),
      );
    }
    if (isAuthOrApi &&
        _dartIoImport.hasMatch(content) &&
        _fileConstruction.hasMatch(content)) {
      violations.add(
        TokenStorageBoundaryViolation(
          path,
          'imports dart:io and constructs a File(...) in lib/auth/ or lib/api/',
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
  test('real lib/ tree has zero token-storage-boundary violations', () {
    final files = _readRealLibFiles(Directory('lib'));

    final violations = checkTokenStorageBoundary(libFiles: files);

    expect(
      violations,
      isEmpty,
      reason: violations.map((v) => v.toString()).join('\n'),
    );
  });

  test('self-test: checker fires on a fixture importing flutter_secure_storage'
      ' outside lib/auth/auth.dart', () {
    final violations = checkTokenStorageBoundary(
      libFiles: {
        'lib/renderers/form/x.dart':
            "import 'package:flutter_secure_storage/flutter_secure_storage.dart';\n",
      },
    );

    expect(violations, hasLength(1));
    expect(violations.single.file, 'lib/renderers/form/x.dart');
  });

  test('self-test: checker fires on a fixture with dart:io File(...) under'
      ' lib/api/', () {
    final violations = checkTokenStorageBoundary(
      libFiles: {'lib/api/leaky.dart': "import 'dart:io';\nfinal f = File('x');\n"},
    );

    expect(violations, hasLength(1));
    expect(violations.single.file, 'lib/api/leaky.dart');
  });

  test('self-test: the sanctioned file itself fires zero violations', () {
    final violations = checkTokenStorageBoundary(
      libFiles: {
        'lib/auth/auth.dart':
            "import 'package:flutter_secure_storage/flutter_secure_storage.dart';\n",
      },
    );

    expect(violations, isEmpty);
  });
}
