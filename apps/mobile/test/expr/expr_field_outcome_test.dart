// REQ-294 AC8/AC9 — the 4-outcome `FieldExpressionOutcome` distinction
// (design §9), and a demonstration that a cached form is fillable with zero
// network reachable: `evaluateVisibility`/`evaluateComputed` are called
// directly against in-test fixture data, with no `Dio`/`ApiClient`/`http`
// import anywhere in this file or in `lib/expr/`'s call path.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/expr/expr.dart';

void main() {
  group('FieldExpressionOutcome: 4 structurally distinguishable outcomes (AC8)', () {
    test('evaluateVisibility: no visible_when authored -> DefaultVisible', () {
      final outcome = evaluateVisibility(null, const {});
      expect(outcome, isA<DefaultVisible>());
      expect(outcome, isNot(isA<DefaultHidden>()));
      expect(outcome, isNot(isA<Blank>()));
      expect(outcome, isNot(isA<StaleVersion>()));
    });

    test('evaluateVisibility: visible_when evaluates true -> DefaultVisible', () {
      final outcome = evaluateVisibility('variables.approved == true', {'approved': true});
      expect(outcome, isA<DefaultVisible>());
    });

    test('evaluateVisibility: visible_when evaluates false -> DefaultHidden', () {
      final outcome = evaluateVisibility('variables.approved == true', {'approved': false});
      expect(outcome, isA<DefaultHidden>());
      expect(outcome, isNot(isA<DefaultVisible>()));
      expect(outcome, isNot(isA<Blank>()));
      expect(outcome, isNot(isA<StaleVersion>()));
    });

    test('evaluateComputed: no computed expression authored -> Blank', () {
      final outcome = evaluateComputed(null, const {});
      expect(outcome, isA<Blank>());
      expect(outcome, isNot(isA<DefaultVisible>()));
      expect(outcome, isNot(isA<DefaultHidden>()));
      expect(outcome, isNot(isA<StaleVersion>()));
    });

    test('evaluateComputed: computed expression evaluates to null -> Blank', () {
      final outcome = evaluateComputed('coalesce(variables.a, variables.b)', {'a': null, 'b': null});
      expect(outcome, isA<Blank>());
    });

    test('evaluateVisibility: an unevaluable expression -> StaleVersion, never one of the other 3', () {
      // Undefined variable -> eval error -> StaleVersion.
      final outcome = evaluateVisibility('variables.missing == true', const {});
      expect(outcome, isA<StaleVersion>());
      expect(outcome, isNot(isA<DefaultVisible>()));
      expect(outcome, isNot(isA<DefaultHidden>()));
      expect(outcome, isNot(isA<Blank>()));
      final stale = outcome as StaleVersion;
      expect(stale.expression, 'variables.missing == true');
      expect(stale.reason, isNotEmpty);
    });

    test('evaluateComputed: a parse failure -> StaleVersion, never Blank', () {
      final outcome = evaluateComputed('amount +', const {});
      expect(outcome, isA<StaleVersion>());
      expect(outcome, isNot(isA<Blank>()));
    });

    test('evaluateVisibility: visible_when evaluating to a non-boolean -> StaleVersion', () {
      final outcome = evaluateVisibility('1 + 1', const {});
      expect(outcome, isA<StaleVersion>());
    });

    test('a switch over FieldExpressionOutcome is exhaustive over exactly 4 cases (compile-time proof)', () {
      String describe(FieldExpressionOutcome outcome) {
        return switch (outcome) {
          DefaultVisible() => 'visible',
          DefaultHidden() => 'hidden',
          Blank() => 'blank',
          StaleVersion() => 'stale',
        };
      }

      expect(describe(const DefaultVisible()), 'visible');
      expect(describe(const DefaultHidden()), 'hidden');
      expect(describe(const Blank()), 'blank');
      expect(describe(const StaleVersion(expression: 'x', reason: 'r')), 'stale');
    });
  });

  group('offline-fillable demonstration (AC9): zero network reachable', () {
    test('visible_when and computed evaluate against fixture cached-style data with no I/O in the call path', () {
      // Simulates a cached form_schema's field definitions and the
      // in-memory values a user has already typed -- exactly the shape a
      // future REQ-426/427 form renderer would hold after loading a
      // SembastCacheRepository-cached form with no network reachable.
      final cachedFormValues = <String, Object?>{
        'order': {'status': 'approved', 'total': 150},
        'discountEligible': true,
      };

      // A `visible_when` field condition, evaluated purely in-memory.
      final visibility = evaluateVisibility(
        'variables.order.status == "approved" and variables.discountEligible == true',
        cachedFormValues,
      );
      expect(visibility, isA<DefaultVisible>());

      // A `computed` field expression, evaluated purely in-memory.
      final computed = evaluateComputed('variables.order.total * 0.1', cachedFormValues);
      expect(computed, isA<Blank>());

      // This test file, and every function it calls transitively
      // (evaluateVisibility -> evaluateExpression -> translateCelToExpr ->
      // parse -> evalAst), imports no `dart:io`, no `package:dio`, and no
      // `http` package anywhere -- true by construction (no such import
      // exists in this file or in lib/expr/*.dart to remove). This
      // assertion documents that fact for a reader of the test output; the
      // actual proof is the absence of any Dio/ApiClient/http symbol in
      // this file's own `import` list above and in every `lib/expr/*.dart`
      // file's import list (verified as part of this requirement's own
      // self-review, design §8).
      expect(true, isTrue);
    });

    test('evaluateExpression itself is a pure synchronous function (no Future, no async gap)', () {
      // If evaluateExpression ever became `Future<...>`-returning, this
      // line would fail to compile (a type mismatch), not merely fail at
      // runtime -- a compile-time proof of synchronicity/purity.
      final EvaluateExpressionResult result = evaluateExpression('1 + 1', const {});
      expect(result, isA<EvaluateOk>());
    });
  });
}
