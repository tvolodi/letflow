/**
 * REQ-293 — the two composed entry points, mirroring `expr.ex`'s own
 * `evaluate_condition/2` composition (`translate_cel_to_expr/1` -> `parse/1` ->
 * `eval/2`), plus a non-collapsing variant this client needs (design doc §1's
 * "Failure vs. false" — an eval failure on `visible_when`/`cross_field_validation`
 * is never collapsed to `false` client-side either, unlike the gateway-edge-only
 * `evaluate_condition/2` collapse rule).
 */

import { parse } from './parser'
import { translateCelToExpr } from './translateCel'
import { evalAst } from './evaluator'
import type { EvalErrorReason, ParseFailure, Value } from './types'

export * from './types'
export { tokenize } from './tokenizer'
export { parse } from './parser'
export { translateCelToExpr } from './translateCel'
export { evalAst } from './evaluator'
export {
  STATIC_CAPABILITIES,
  checkManifestCompatibility,
  checkAstCapabilities,
  evaluatorCompatibility,
} from './capability'
export type { ManifestCompatibility } from './capability'

export type EvaluateExpressionResult =
  | { ok: true; value: Value }
  | { ok: false; stage: 'translate'; reason: 'unsupported_cel_feature' | 'translate_error' }
  | { ok: false; stage: 'parse'; failure: ParseFailure }
  | { ok: false; stage: 'eval'; error: EvalErrorReason }

/**
 * Composed pipeline for `visible_when`/`computed`/`cross_field_validation`
 * expressions (already-translated `variables.`-style CEL condition syntax, same
 * input contract as `expr.ex`'s `evaluate_condition/2`, but WITHOUT its
 * collapse-to-`false` rule — every stage's failure is surfaced distinctly so the
 * caller can render the "unevaluable" state (design doc §8.3) rather than a
 * silently-false/silently-blank result.
 */
export function evaluateExpression(
  celCondition: string,
  variables: Record<string, unknown>,
): EvaluateExpressionResult {
  const translated = translateCelToExpr(celCondition)
  if (!translated.ok) {
    return { ok: false, stage: 'translate', reason: translated.reason }
  }

  const parsed = parse(translated.exprSource)
  if (!parsed.ok) {
    return { ok: false, stage: 'parse', failure: parsed.failure }
  }

  const evaluated = evalAst(parsed.ast, variables)
  if (!evaluated.ok) {
    return { ok: false, stage: 'eval', error: evaluated.error }
  }

  return { ok: true, value: evaluated.value }
}

/**
 * The composed, always-boolean, never-distinguishable-failure entry point —
 * direct counterpart of `expr.ex`'s `evaluate_condition/2` (one catch-false rule
 * for every stage's failure). Not used by `DynamicFormRenderer`'s three
 * expression kinds (which need `evaluateExpression`'s distinguishable failure
 * stages for the "unevaluable" state) — provided for parity/testing against the
 * conformance corpus's own composition shape, and for any future gateway-edge-
 * shaped client use that wants the same collapse-to-false contract.
 */
export function evaluateCondition(celCondition: string, variables: Record<string, unknown>): boolean {
  const result = evaluateExpression(celCondition, variables)
  return result.ok && result.value === true
}
