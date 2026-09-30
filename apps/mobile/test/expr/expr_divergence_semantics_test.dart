// REQ-294 AC7 — explicit tests for the 3 divergence-prone semantics (design
// §4), beyond the corpus run: each test proves this evaluator's behaviour
// diverges from the naive Dart built-in it deliberately avoids, not merely
// that it happens to match the corpus's expected value. Mirrors
// `web/src/utils/expr/divergenceSemantics.test.ts` (REQ-293) one-for-one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/expr/expr.dart';
import 'package:path/path.dart' as p;

String get _corpusPath =>
    p.normalize(p.join(Directory.current.path, '..', '..', 'priv', 'expr_conformance', 'corpus.json'));

Map<String, Object?> _corpusEntry(String id) {
  final raw = File(_corpusPath).readAsStringSync();
  final corpus = (jsonDecode(raw) as List<Object?>).cast<Map<String, Object?>>();
  return corpus.firstWhere((e) => e['id'] == id, orElse: () => throw StateError('corpus entry $id not found'));
}

EvalOutcome _evalSource(String source) {
  final parsed = parse(source);
  if (parsed is! ParseOk) {
    throw StateError('parse failed for "$source": $parsed');
  }
  return evalAst(parsed.ast, const {});
}

void main() {
  group('divergence-prone semantic 1: ASCII-only lower/upper', () {
    test('lower("CAFÉ") matches the corpus expr-026 expectation, not Dart .toLowerCase()', () {
      final entry = _corpusEntry('expr-026');
      final expression = entry['expression'] as String;
      final expected = entry['outcome'] as Map<String, Object?>;
      final result = _evalSource(expression);

      expect(result, isA<EvalOk>());
      expect((result as EvalOk).value, 'cafÉ');
      expect(expected['value'], 'cafÉ');

      // Prove the divergence is real: native Dart .toLowerCase() would
      // produce a DIFFERENT, Unicode-aware result for the same input.
      expect('CAFÉ'.toLowerCase(), 'café');
      expect('CAFÉ'.toLowerCase(), isNot('cafÉ'));
    });

    test('upper("café") matches the corpus expr-027 expectation, not Dart .toUpperCase()', () {
      final entry = _corpusEntry('expr-027');
      final expression = entry['expression'] as String;
      final result = _evalSource(expression);

      expect(result, isA<EvalOk>());
      expect((result as EvalOk).value, 'CAFé');

      expect('café'.toUpperCase(), 'CAFÉ');
      expect('café'.toUpperCase(), isNot('CAFé'));
    });

    test('a Turkish İ (U+0130, outside ASCII) is left byte-for-byte unchanged by lower/1', () {
      // 'İ' (LATIN CAPITAL LETTER I WITH DOT ABOVE) is outside the ASCII
      // 0x41-0x5A range this evaluator's asciiLower map covers, so it must
      // pass through unchanged regardless of what a Unicode-aware casing
      // routine would do with it (some produce a 2-code-unit "i" +
      // combining-dot-above expansion for this exact character).
      final lowerResult = _evalSource('lower("İSTANBUL")');
      expect(lowerResult, isA<EvalOk>());
      // Only the ASCII letters (S,T,A,N,B,U,L) are lowercased; İ is
      // untouched.
      expect((lowerResult as EvalOk).value, 'İstanbul');
    });
  });

  group('divergence-prone semantic 2: 4-ASCII-char trim, never Unicode trim', () {
    test('trim(" \\thi there\\r\\n ") strips exactly the 4 ASCII whitespace chars', () {
      final entry = _corpusEntry('expr-028');
      final expression = entry['expression'] as String;
      final result = _evalSource(expression);

      expect(result, isA<EvalOk>());
      expect((result as EvalOk).value, 'hi there');
    });

    test('leaves a Unicode-whitespace character (NBSP / EM SPACE) in place at either end', () {
      const nbsp = ' hello ';
      const emSpace = ' world ';

      final nbspResult = _evalSource('trim("$nbsp")');
      final emSpaceResult = _evalSource('trim("$emSpace")');

      expect(nbspResult, isA<EvalOk>());
      expect((nbspResult as EvalOk).value, nbsp);
      expect(emSpaceResult, isA<EvalOk>());
      expect((emSpaceResult as EvalOk).value, emSpace);

      // Prove the divergence is real: Dart's native .trim() WOULD strip
      // these Unicode whitespace characters.
      expect(nbsp.trim(), isNot(nbsp));
      expect(emSpace.trim(), isNot(emSpace));
    });
  });

  group('divergence-prone semantic 3: signed-infinity/NaN marker, never native double.infinity/NaN', () {
    test('1.0 / 0.0 -> InfinityMarker.infinity, never Dart double.infinity', () {
      final result = _evalSource('1.0 / 0.0');
      expect(result, isA<EvalOk>());
      final value = (result as EvalOk).value;
      expect(value, InfinityMarker.infinity);
      expect(value, isNot(double.infinity));
      expect(value is double, isFalse);

      // Prove the divergence is real: Dart's native `/` on doubles WOULD
      // produce a real IEEE 754 infinity for the same operands.
      expect(1.0 / 0.0, double.infinity);
    });

    test('- 1.0 / 0.0 -> InfinityMarker.negInfinity', () {
      final result = _evalSource('- 1.0 / 0.0');
      expect(result, isA<EvalOk>());
      expect((result as EvalOk).value, InfinityMarker.negInfinity);
    });

    test('0.0 / 0.0 -> InfinityMarker.nan, never Dart double.nan', () {
      final result = _evalSource('0.0 / 0.0');
      expect(result, isA<EvalOk>());
      final value = (result as EvalOk).value;
      expect(value, InfinityMarker.nan);
      expect(value is double, isFalse);

      // InfinityMarker.nan == InfinityMarker.nan is ordinary Dart enum
      // identity equality (true) -- correct for comparing "both sides
      // encode this entry's expected nan", a distinct concern from real
      // IEEE 754 NaN self-inequality, which the evaluator's own `eq`/`neq`
      // comparison operators implement explicitly (see the corpus's own
      // eq/neq-over-nan cases and evalCmp's dedicated nan branch).
      expect(value, InfinityMarker.nan);
      // Prove the divergence is real: Dart's native 0.0/0.0 IS a real
      // double NaN, and real NaN self-inequality holds for it.
      expect(double.nan.isNaN, isTrue);
      expect(0.0 / 0.0, isNaN);
    });
  });
}
