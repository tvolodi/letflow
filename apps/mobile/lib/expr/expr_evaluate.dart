/// REQ-294 §6.5 — the composed pipeline entry points, mirroring `expr.ex`'s
/// own `evaluate_condition/2` composition (`translate_cel_to_expr/1` ->
/// `parse/1` -> `eval/2`), via `web/src/utils/expr/index.ts` as the direct
/// structural model.
///
/// Factored into its own file (not named in the design's module-layout
/// table, which lists `expr.dart` as a pure re-export barrel) purely to
/// avoid a circular import between the barrel and `expr_field_outcome.dart`
/// (which also needs these types/functions) -- `expr.dart` re-exports this
/// file's public surface unchanged, so the public API shape matches the
/// design exactly; only the internal file boundary differs.
library;

import 'expr_evaluator.dart';
import 'expr_parser.dart';
import 'expr_translate_cel.dart';
import 'expr_types.dart';

sealed class EvaluateExpressionResult {
  const EvaluateExpressionResult();
}

final class EvaluateOk extends EvaluateExpressionResult {
  const EvaluateOk(this.value);
  final ExprValue value;
}

final class EvaluateTranslateFailure extends EvaluateExpressionResult {
  const EvaluateTranslateFailure(this.reason);
  final TranslateErrorReason reason;
}

final class EvaluateParseFailure extends EvaluateExpressionResult {
  const EvaluateParseFailure(this.failure);
  final ParseFailure failure;
}

final class EvaluateEvalFailure extends EvaluateExpressionResult {
  const EvaluateEvalFailure(this.error);
  final EvalErrorReason error;
}

/// Composition: `translateCelToExpr` -> `parse` -> `evalAst`, each stage's
/// failure surfaced distinctly (never collapsed to one boolean) -- direct
/// counterpart of `expr.ex`'s own composition (`evaluate_condition/2`)
/// MINUS its collapse-to-false rule. This is the function the conformance-
/// corpus test and any future form-renderer caller both use, because both
/// need distinguishable failure stages.
EvaluateExpressionResult evaluateExpression(String celCondition, Map<String, Object?> variables) {
  final translated = translateCelToExpr(celCondition);
  if (translated is TranslateErr) {
    return EvaluateTranslateFailure(translated.reason);
  }
  final exprSource = (translated as TranslateOk).exprSource;

  final parsed = parse(exprSource);
  if (parsed is ParseErr) {
    return EvaluateParseFailure(parsed.failure);
  }
  final ast = (parsed as ParseOk).ast;

  final evaluated = evalAst(ast, variables);
  if (evaluated is EvalErr) {
    return EvaluateEvalFailure(evaluated.error);
  }

  return EvaluateOk((evaluated as EvalOk).value);
}

/// The composed, always-boolean, never-distinguishable-failure entry point
/// -- direct counterpart of `expr.ex`'s `evaluate_condition/2` (one
/// catch-false rule for every stage's failure). Included for parity/
/// completeness (mirrors REQ-293's `index.ts` sibling function), not used
/// by [evaluateVisibility]/[evaluateComputed], which need
/// [evaluateExpression]'s distinguishable failure stages.
bool evaluateCondition(String celCondition, Map<String, Object?> variables) {
  final result = evaluateExpression(celCondition, variables);
  return result is EvaluateOk && result.value == true;
}
