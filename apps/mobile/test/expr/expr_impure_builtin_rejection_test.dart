// REQ-294 AC5, design §5.3 — `now`/`date_add`/`date_diff` must be
// structurally absent (not merely runtime-blocklisted): the closed
// 8-member `BuiltinName` enum has no member for them, so they tokenize as
// bare, unrecognized variables, and referencing one as a call
// (`now()`, `date_add(x, 1)`, `date_diff(x, y)`) must be REJECTED as a
// parse failure, never evaluated.
//
// FINDING (reported to ORCH, not silently corrected in expr.ex): the design
// doc (`lib/letflow/design/req294-dart-expr-evaluator.md` §5.2/§5.3) claims
// the rejection shape is `ParseErr(reason: UnexpectedToken(text: "("))`.
// Empirically re-verified against the actual grammar authority
// (`lib/letflow/engine/expr.ex`, `mix run --no-start` against
// `Letflow.Engine.Expr.parse/1` directly) this is incorrect: a bare
// identifier like `now`/`date_add`/`date_diff` parses successfully as a
// `{:var, [...]}` primary expression (the grammar's `parse_primary/1` has a
// clause for a bare variable, and nothing downstream expects a `(` to
// follow one), leaving `(...)` as unconsumed trailing tokens -- `parse/1`'s
// outer `with` then reports `{:error, {:parse_error, {:trailing_input,
// leftover}}}`, not `{:unexpected_token, _}`. Verified for both `now()` and
// `date_add(x, 1)`:
//   parse("now()")            -> {:error, {:parse_error, {:trailing_input, [{:lparen}, {:rparen}]}}}
//   parse("date_add(x, 1)")   -> {:error, {:parse_error, {:trailing_input, [{:lparen}, {:var, ["x"]}, {:comma}, {:lit, 1}, {:rparen}]}}}
// This Dart port matches `expr.ex`'s real, verified behaviour
// (`TrailingInput`), per this requirement's own instruction to treat
// `expr.ex` as the single source of truth over a design doc that
// disagrees with it -- the rejection is still a structured parse failure,
// never a silent pass-through to evaluation, which is AC5's actual
// substance.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/expr/expr.dart';

ParseResult _parseCondition(String celCondition) {
  final translated = translateCelToExpr(celCondition);
  expect(translated, isA<TranslateOk>(), reason: 'expected the condition to translate cleanly: $celCondition');
  return parse((translated as TranslateOk).exprSource);
}

void main() {
  group('impure builtins (now/date_add/date_diff) are structurally absent', () {
    test('now() is rejected as a parse failure (TrailingInput), never evaluated', () {
      final result = _parseCondition('now()');
      expect(result, isA<ParseErr>());
      expect((result as ParseErr).failure.reason, isA<TrailingInput>());
    });

    test('date_add(x, 1) is rejected as a parse failure (TrailingInput), never evaluated', () {
      final result = _parseCondition('date_add(variables.x, 1)');
      expect(result, isA<ParseErr>());
      expect((result as ParseErr).failure.reason, isA<TrailingInput>());
    });

    test('date_diff(x, y) is rejected as a parse failure (TrailingInput), never evaluated', () {
      final result = _parseCondition('date_diff(variables.x, variables.y)');
      expect(result, isA<ParseErr>());
      expect((result as ParseErr).failure.reason, isA<TrailingInput>());
    });

    test('BuiltinName has exactly 8 members, none named now/date_add/date_diff', () {
      const forbiddenNames = {'now', 'date_add', 'dateAdd', 'date_diff', 'dateDiff'};
      final actualNames = BuiltinName.values.map((v) => v.name).toSet();

      expect(BuiltinName.values.length, 8);
      expect(actualNames.intersection(forbiddenNames), isEmpty);
    });

    test(
      'self-test: the string "now" appears in expr_types.dart source only inside comments, '
      'never as a BuiltinName member or tokenizer case (structural drift guard, design §5.3)',
      () {
        final typesSource = File('lib/expr/expr_types.dart').readAsStringSync();
        final tokenizerSource = File('lib/expr/expr_tokenizer.dart').readAsStringSync();

        // Strip comment lines (leading `//` after trimming) before
        // checking for a bare "now" word -- prose in doc comments
        // referencing "now()" is fine; a live enum member or switch case
        // named `now` is not.
        bool hasLiveNowReference(String source) {
          final nowWordRe = RegExp(r'\bnow\b');
          for (final rawLine in source.split('\n')) {
            final line = rawLine.trim();
            if (line.startsWith('//')) continue;
            if (nowWordRe.hasMatch(line)) return true;
          }
          return false;
        }

        expect(
          hasLiveNowReference(typesSource),
          isFalse,
          reason: 'expr_types.dart must not reference "now" outside a comment',
        );
        expect(
          hasLiveNowReference(tokenizerSource),
          isFalse,
          reason: 'expr_tokenizer.dart must not reference "now" outside a comment',
        );
      },
    );
  });
}
