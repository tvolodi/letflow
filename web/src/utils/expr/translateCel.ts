/**
 * REQ-293 — direct port of `translate_cel_to_expr/1` (expr.ex lines 215-304).
 *
 * Copied constant-for-constant from `@unsupported_call_markers` and
 * `unsupported_cel_feature?/1`, not re-derived (design doc §5.3).
 */

import type { TranslateResult } from './types'

const UNSUPPORTED_CALL_MARKERS: readonly string[] = [
  'has(',
  'matches(',
  'all(',
  'exists_one(',
  'exists(',
  'int(',
  'uint(',
  'double(',
  'string(',
  'bool(',
  'bytes(',
  'duration(',
  'timestamp(',
  'size(',
  'map(',
  'map{',
  'filter(',
]

const IN_OPERATOR_RE = /(?<![A-Za-z0-9_."'])in(?![A-Za-z0-9_])/

function stripVariablesPrefix(celCondition: string): string {
  return celCondition.split('variables.').join('')
}

function rewriteNot(exprSource: string): string {
  // `!` not immediately followed by `=` becomes `not ` — negative lookahead,
  // matches rewrite_not/1's regex exactly.
  return exprSource.replace(/!(?!=)/g, 'not ')
}

function stripStringLiterals(celCondition: string): string {
  return celCondition
    .replace(/"([^"\\]|\\.)*"/g, '""')
    .replace(/'([^'\\]|\\.)*'/g, "''")
}

function containsInOperator(celCondition: string): boolean {
  return IN_OPERATOR_RE.test(stripStringLiterals(celCondition))
}

function containsBareQuestionMark(celCondition: string): boolean {
  return stripStringLiterals(celCondition).includes('?')
}

function unsupportedCelFeature(celCondition: string): boolean {
  return (
    UNSUPPORTED_CALL_MARKERS.some((marker) => celCondition.includes(marker)) ||
    containsInOperator(celCondition) ||
    containsBareQuestionMark(celCondition)
  )
}

export function translateCelToExpr(celCondition: string): TranslateResult {
  if (typeof celCondition !== 'string') {
    return { ok: false, reason: 'translate_error' }
  }

  const trimmed = celCondition.trim()

  if (trimmed === '') {
    return { ok: false, reason: 'translate_error' }
  }

  if (unsupportedCelFeature(celCondition)) {
    return { ok: false, reason: 'unsupported_cel_feature' }
  }

  const exprSource = rewriteNot(
    stripVariablesPrefix(celCondition).replaceAll('&&', ' and ').replaceAll('||', ' or '),
  )

  if (exprSource.trim() === '') {
    return { ok: false, reason: 'translate_error' }
  }

  return { ok: true, exprSource }
}
