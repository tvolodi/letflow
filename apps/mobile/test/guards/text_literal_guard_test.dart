// Static guard (REQ-429/MOB-7 design §5, AC5): no `Text(...)` widget under
// `apps/mobile/lib` constructs its first positional argument from a
// hardcoded string literal — every user-visible string must come from the
// ARB message catalogue (`tr(id)`, `lib/i18n/catalogue.dart`) instead.
//
// Plain text scan (no `analyzer` dependency), matching this test suite's
// existing convention (`forbidden_dependencies_guard_test.dart`,
// `module_boundary_guard_test.dart`).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One detected hardcoded-literal violation.
class TextLiteralViolation {
  TextLiteralViolation(this.filePath, this.lineNumber, this.snippet);

  final String filePath;
  final int lineNumber;
  final String snippet;

  @override
  String toString() => '$filePath:$lineNumber: $snippet';
}

/// Matches a `Text(` widget constructor call -- the literal token `Text(`
/// preceded by a non-identifier character (so `TextField(`, `TextButton(`,
/// `TextSpan(`, `TextStyle(`, `TextFormField(` etc. are never matched) --
/// whose first positional argument is a quoted string literal (single or
/// double quotes), captured into group 1.
///
/// A string containing `$` (interpolation) never satisfies this pattern as
/// a *plain* literal in the sense this guard cares about, but the regex
/// itself does not need to special-case that: `Text('$x ...')` is still a
/// quoted string token syntactically. Interpolated/variable/function-call
/// arguments are excluded by the separate `_hasLetter`/call-site checks
/// below only for the "contains at least one letter, not an
/// interpolation" rule — see `checkTextLiterals`'s own filtering.
final RegExp _textLiteralCall = RegExp(
  r'''(?:^|[^A-Za-z0-9_])Text\(\s*(?:\r?\n\s*)?(['"])((?:\\.|(?!\1).)*)\1''',
  multiLine: true,
);

/// True if [value] contains at least one Unicode letter -- a purely
/// symbolic literal (`'—'`, `''`, `'·'`) is not user-visible language
/// content and is not a violation (design §5's allowlist, first bullet).
bool _hasLetter(String value) => RegExp(r'[A-Za-zÀ-ɏЀ-ӿ]')
    .hasMatch(value);

/// True if [value] contains a `$` -- an interpolated string
/// (`Text('$x')`, `Text('${tr('id')}: $x')`) is definitionally not a
/// hardcoded literal (design §5, third allowlist bullet) even though the
/// raw regex above still matches its surrounding quotes.
bool _isInterpolated(String value) => value.contains(r'$');

/// Scans [content] (one file's raw text) for `Text(...)` calls whose first
/// positional argument is a hardcoded, non-interpolated string literal
/// containing at least one letter. Pure function so the self-test can
/// exercise it against in-memory fixtures (AC5a).
List<TextLiteralViolation> checkTextLiterals(String filePath, String content) {
  final violations = <TextLiteralViolation>[];
  final lines = content.split('\n');
  // Precompute line-start offsets so a match's character offset maps back
  // to a 1-based line number for reporting.
  final lineStarts = <int>[0];
  for (final line in lines) {
    lineStarts.add(lineStarts.last + line.length + 1);
  }

  for (final match in _textLiteralCall.allMatches(content)) {
    final literal = match.group(2)!;
    if (!_hasLetter(literal)) continue;
    if (_isInterpolated(literal)) continue;

    var lineNumber = 1;
    for (var i = 0; i < lineStarts.length; i++) {
      if (lineStarts[i] > match.start) {
        lineNumber = i; // 1-based: lineStarts[0] is the start of line 1.
        break;
      }
    }

    violations.add(
      TextLiteralViolation(filePath, lineNumber, match.group(0)!.trim()),
    );
  }

  return violations;
}

/// Checks every `.dart` file under [libDir], excluding none (this guard has
/// no file-path exclusion today -- `apps/mobile/test/**` is a separate
/// directory tree entirely, never passed to this function; design §5's
/// "test fixtures excluded" bullet is therefore satisfied structurally by
/// only ever calling this against `lib/`, not by a path check inside it).
List<TextLiteralViolation> checkRealLibTree(Directory libDir) {
  final violations = <TextLiteralViolation>[];
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final relPath = 'lib/${_relativeTo(libDir, entity).replaceAll('\\', '/')}';
      violations.addAll(
        checkTextLiterals(relPath, entity.readAsStringSync()),
      );
    }
  }
  return violations;
}

String _relativeTo(Directory base, File file) {
  final basePath = base.path.replaceAll('\\', '/');
  final filePath = file.path.replaceAll('\\', '/');
  return filePath.substring(basePath.length + 1);
}

void main() {
  test('real lib/ tree has zero hardcoded Text() literal violations', () {
    final violations = checkRealLibTree(Directory('lib'));

    expect(
      violations,
      isEmpty,
      reason: violations.map((v) => v.toString()).join('\n'),
    );
  });

  test('self-test: checker fires on a real hardcoded-literal violation', () {
    const fixture = '''
import 'package:flutter/material.dart';

class Fixture extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text('Hardcoded literal');
  }
}
''';

    final violations = checkTextLiterals('lib/fixture.dart', fixture);

    expect(violations, hasLength(1));
    expect(violations.single.snippet, contains('Hardcoded literal'));
  });

  test(
    'self-test: checker does not fire on a catalogue-lookup/variable '
    'argument (not a hardcoded literal)',
    () {
      const fixture = '''
import 'package:flutter/material.dart';

Widget build(BuildContext context) {
  return Text(someCatalogueLookup('id'));
}
''';

      expect(checkTextLiterals('lib/fixture.dart', fixture), isEmpty);
    },
  );

  test(
    'self-test: checker does not fire on an empty/no-letter literal '
    '(a glyph, not language content)',
    () {
      const fixture = '''
import 'package:flutter/material.dart';

Widget build(BuildContext context) {
  return Text('—');
}
''';

      expect(checkTextLiterals('lib/fixture.dart', fixture), isEmpty);
    },
  );

  test(
    'self-test: checker does not fire on an interpolated string literal',
    () {
      const fixture = '''
import 'package:flutter/material.dart';

Widget build(BuildContext context, String x) {
  return Text('\$x');
}
''';

      expect(checkTextLiterals('lib/fixture.dart', fixture), isEmpty);
    },
  );

  test(
    'self-test: checker does not fire on TextField/TextButton/TextStyle/'
    'TextSpan/TextFormField -- never matches the widget, not the string',
    () {
      const fixture = '''
import 'package:flutter/material.dart';

Widget build(BuildContext context) {
  return Column(
    children: [
      TextField(decoration: InputDecoration(hintText: 'hidden on purpose')),
      TextButton(onPressed: null, child: TextSpan(text: 'also hidden')),
      TextFormField(),
      Text(''),
    ],
  );
}

const TextStyle fixtureStyle = TextStyle();
''';

      expect(checkTextLiterals('lib/fixture.dart', fixture), isEmpty);
    },
  );
}
