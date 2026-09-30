// REQ-294 AC3/AC4/AC9/AC12 — reads REQ-289's actual conformance corpus file
// directly (never a hand-copied subset) and asserts the entry count matches
// the corpus's own length BEFORE running a single case, so a truncated read
// cannot pass. Mirrors `web/src/utils/expr/conformanceCorpus.test.ts`
// (REQ-293) one-for-one.
//
// `flutter test`, run from `apps/mobile/` (this package's root), has its
// process working directory set to `apps/mobile/` -- the relative path from
// there to the shared corpus is `../../priv/expr_conformance/corpus.json`
// (`apps/mobile` -> `apps` -> repo root -> `priv/...`), verified to resolve
// correctly by this test actually passing.
//
// This file uses `dart:io`'s `File` to read the corpus -- test-time-only
// I/O, confined to this file, never `lib/expr/`'s production code path
// (design §8, AC9).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/expr/expr.dart';
import 'package:path/path.dart' as p;

String get _corpusPath =>
    p.normalize(p.join(Directory.current.path, '..', '..', 'priv', 'expr_conformance', 'corpus.json'));

String get _manifestPath =>
    p.normalize(p.join(Directory.current.path, '..', '..', 'priv', 'expr_conformance', 'manifest.json'));

class CorpusEntry {
  const CorpusEntry({
    required this.id,
    required this.description,
    required this.grammarConstructs,
    required this.expression,
    required this.variables,
    required this.outcome,
  });

  final String id;
  final String description;
  final List<String> grammarConstructs;
  final String expression;
  final Map<String, Object?> variables;
  final CorpusOutcome outcome;

  factory CorpusEntry.fromJson(Map<String, Object?> json) {
    final outcomeJson = json['outcome'] as Map<String, Object?>;
    final CorpusOutcome outcome;
    if (outcomeJson['status'] == 'ok') {
      outcome = CorpusOkOutcome(_decodeExpectedValue(outcomeJson['value']));
    } else {
      final errorKind = outcomeJson['error_kind'] == 'parse_failure'
          ? CorpusErrorKind.parseFailure
          : CorpusErrorKind.evalFailure;
      outcome = CorpusErrorOutcome(errorKind);
    }

    return CorpusEntry(
      id: json['id'] as String,
      description: json['description'] as String,
      grammarConstructs: (json['grammar_constructs'] as List<Object?>).cast<String>(),
      expression: json['expression'] as String,
      variables: (json['variables'] as Map<Object?, Object?>).cast<String, Object?>(),
      outcome: outcome,
    );
  }
}

sealed class CorpusOutcome {
  const CorpusOutcome();
}

final class CorpusOkOutcome extends CorpusOutcome {
  const CorpusOkOutcome(this.expectedValue);
  final ExprValue expectedValue;
}

final class CorpusErrorOutcome extends CorpusOutcome {
  const CorpusErrorOutcome(this.errorKind);
  final CorpusErrorKind errorKind;
}

enum CorpusErrorKind { parseFailure, evalFailure }

class ManifestData {
  const ManifestData({required this.corpusSchemaVersion, required this.capabilities});
  final String corpusSchemaVersion;
  final List<String> capabilities;
}

/// The corpus's `outcome.value` field encodes an expected `InfinityMarker`
/// result as `{"$marker": "infinity" | "neg_infinity" | "nan"}` (REQ-289's
/// own corpus JSON encoding convention) -- otherwise returns `raw`
/// unchanged (already one of `num | String | bool | null`, all of which
/// `dart:convert` produces natively for the corpus's non-marker values).
ExprValue _decodeExpectedValue(Object? raw) {
  if (raw is Map<Object?, Object?> && raw.containsKey(r'$marker')) {
    return switch (raw[r'$marker']) {
      'infinity' => InfinityMarker.infinity,
      'neg_infinity' => InfinityMarker.negInfinity,
      'nan' => InfinityMarker.nan,
      _ => throw StateError('unknown \$marker value: ${raw[r'$marker']}'),
    };
  }
  return raw;
}

List<CorpusEntry> loadCorpus() {
  final raw = File(_corpusPath).readAsStringSync();
  final decoded = jsonDecode(raw) as List<Object?>;
  return decoded.map((e) => CorpusEntry.fromJson(e as Map<String, Object?>)).toList();
}

ManifestData loadManifest() {
  final raw = File(_manifestPath).readAsStringSync();
  final decoded = jsonDecode(raw) as Map<String, Object?>;
  return ManifestData(
    corpusSchemaVersion: decoded['corpus_schema_version'] as String,
    capabilities: (decoded['capabilities'] as List<Object?>).cast<String>(),
  );
}

void main() {
  group('REQ-289 conformance corpus (read directly, not hand-copied)', () {
    final corpus = loadCorpus();
    final manifest = loadManifest();

    // Mandatory first assertion, before any per-entry test's result is
    // trusted (mirrors conformanceCorpus.test.ts's own
    // `expect(corpus.length).toBe(40)`).
    test('has exactly 40 entries (a truncated read fails this before any case runs)', () {
      expect(corpus.length, 40);
    });

    test('manifest corpus_schema_version is 1.0.0 (AC4/AC12: matches REQ-293\'s suite)', () {
      expect(manifest.corpusSchemaVersion, '1.0.0');
    });

    test('manifest capabilities is non-empty (sanity: real file read, not a stub)', () {
      expect(manifest.capabilities, isNotEmpty);
    });

    // One test per corpus entry, generated by iterating loadCorpus()'s
    // returned list -- never a hand-copied subset.
    for (final entry in corpus) {
      test('${entry.id}: ${entry.description}', () {
        final result = evaluateExpression(entry.expression, entry.variables);

        switch (entry.outcome) {
          case CorpusOkOutcome(:final expectedValue):
            expect(result, isA<EvaluateOk>(), reason: 'expected ok, got $result');
            if (result is EvaluateOk) {
              expect(result.value, equals(expectedValue));
            }
          case CorpusErrorOutcome(:final errorKind):
            switch (errorKind) {
              case CorpusErrorKind.parseFailure:
                expect(
                  result,
                  anyOf(isA<EvaluateTranslateFailure>(), isA<EvaluateParseFailure>()),
                  reason: 'expected a translate/parse-stage failure, got $result',
                );
              case CorpusErrorKind.evalFailure:
                expect(result, isA<EvaluateEvalFailure>(), reason: 'expected an eval-stage failure, got $result');
            }
        }
      });
    }
  });
}
