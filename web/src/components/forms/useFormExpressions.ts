/**
 * REQ-293 — `useFormExpressions` (design doc §8.2). Computes, per render, the
 * three-way `ExpressionFieldState` for every field carrying `visibleWhen`,
 * `computed`, or `crossFieldValidation`. Pure computation over its inputs (no
 * DOM/React-hook-form coupling beyond `useMemo`) — reads `variables` from the
 * form's own live, in-memory state only (no persistent client-side store, per
 * the design's scope fence §11).
 */

import { useMemo } from 'react'
import { translateCelToExpr } from '@/utils/expr/translateCel'
import { parse } from '@/utils/expr/parser'
import { evalAst } from '@/utils/expr/evaluator'
import { evaluatorCompatibility, type ManifestCompatibility } from '@/utils/expr/capability'
import type { Ast, Value } from '@/utils/expr/types'
import type { TaskFormField } from '@/types/forms'

export type ExpressionFieldState<T> =
  | { kind: 'evaluated'; value: T }
  | { kind: 'unevaluable'; reason: string }

export interface FormExpressionsResult {
  visibility: Record<string, ExpressionFieldState<boolean>>
  computedValues: Record<string, ExpressionFieldState<Value>>
  crossFieldErrors: Record<string, ExpressionFieldState<string | null>>
  manifestCompatibility: ManifestCompatibility
}

const MANIFEST_INCOMPATIBLE_REASON = 'this form uses expression features this client does not support'

function collectVarNames(ast: Ast, out: Set<string>): void {
  switch (ast.kind) {
    case 'var':
      out.add(ast.path[0])
      return
    case 'not':
    case 'neg':
      collectVarNames(ast.sub, out)
      return
    case 'and':
    case 'or':
    case 'cmp':
    case 'arith':
      collectVarNames(ast.left, out)
      collectVarNames(ast.right, out)
      return
    case 'call':
      for (const arg of ast.args) collectVarNames(arg, out)
      return
    case 'lit':
      return
  }
}

interface ParsedExpr {
  field: string
  ast: Ast | null
  unevaluableReason: string | null
}

function parseFieldExpression(field: string, source: string): ParsedExpr {
  const translated = translateCelToExpr(source)
  if (!translated.ok) {
    return { field, ast: null, unevaluableReason: `expression could not be translated (${translated.reason})` }
  }
  const parsed = parse(translated.exprSource)
  if (!parsed.ok) {
    return { field, ast: null, unevaluableReason: `expression failed to parse (${parsed.failure.reason.kind})` }
  }
  return { field, ast: parsed.ast, unevaluableReason: null }
}

/**
 * Topologically sorts `computed` fields by their cross-references (edge A->B
 * iff A's AST references B and B also carries `computed`), same
 * Kahn's-algorithm-with-sorted-ties approach `kahn_topological_sort/1` uses
 * server-side, so tie-breaking matches on the rare case more than one valid
 * order exists. Fields left over after the algorithm terminates are part of a
 * cycle — returned separately, never silently included in `order`.
 */
function topoSortComputed(
  computedFieldNames: string[],
  asts: Record<string, Ast | null>,
): { order: string[]; cyclic: string[] } {
  const nameSet = new Set(computedFieldNames)
  const dependsOn = new Map<string, Set<string>>() // field -> set of computed fields it references
  for (const name of computedFieldNames) {
    const ast = asts[name]
    const refs = new Set<string>()
    if (ast) collectVarNames(ast, refs)
    dependsOn.set(
      name,
      new Set(Array.from(refs).filter((r) => nameSet.has(r) && r !== name)),
    )
  }

  const inDegree = new Map<string, number>()
  for (const name of computedFieldNames) inDegree.set(name, dependsOn.get(name)?.size ?? 0)

  const order: string[] = []
  const remaining = new Set(computedFieldNames)

  for (;;) {
    const ready = Array.from(remaining)
      .filter((n) => (inDegree.get(n) ?? 0) === 0)
      .sort((a, b) => a.localeCompare(b))
    if (ready.length === 0) break
    const next = ready[0]
    order.push(next)
    remaining.delete(next)
    for (const other of remaining) {
      if (dependsOn.get(other)?.has(next)) {
        inDegree.set(other, (inDegree.get(other) ?? 1) - 1)
      }
    }
  }

  return { order, cyclic: Array.from(remaining) }
}

export function useFormExpressions(
  formFields: Record<string, TaskFormField>,
  variables: Record<string, unknown>,
  manifest: { capabilities: string[] },
): FormExpressionsResult {
  return useMemo(() => {
    const manifestCompatibility = evaluatorCompatibility(manifest)

    const visibility: Record<string, ExpressionFieldState<boolean>> = {}
    const computedValues: Record<string, ExpressionFieldState<Value>> = {}
    const crossFieldErrors: Record<string, ExpressionFieldState<string | null>> = {}

    const fieldEntries = Object.entries(formFields)

    if (!manifestCompatibility.compatible) {
      for (const [name, field] of fieldEntries) {
        if (field.visibleWhen) visibility[name] = { kind: 'unevaluable', reason: MANIFEST_INCOMPATIBLE_REASON }
        if (field.computed) computedValues[name] = { kind: 'unevaluable', reason: MANIFEST_INCOMPATIBLE_REASON }
        if (field.crossFieldValidation) {
          crossFieldErrors[name] = { kind: 'unevaluable', reason: MANIFEST_INCOMPATIBLE_REASON }
        }
      }
      return { visibility, computedValues, crossFieldErrors, manifestCompatibility }
    }

    // --- computed fields, in dependency-topological order ------------------
    const computedFieldNames = fieldEntries.filter(([, f]) => f.computed).map(([name]) => name)
    const parsedComputed: Record<string, ParsedExpr> = {}
    for (const name of computedFieldNames) {
      parsedComputed[name] = parseFieldExpression(name, formFields[name].computed as string)
    }
    const asts: Record<string, Ast | null> = {}
    for (const name of computedFieldNames) asts[name] = parsedComputed[name].ast

    const { order, cyclic } = topoSortComputed(computedFieldNames, asts)

    const extendedVariables: Record<string, unknown> = { ...variables }
    const failedComputed = new Set<string>()

    for (const name of cyclic) {
      computedValues[name] = { kind: 'unevaluable', reason: 'circular computed-field dependency' }
      failedComputed.add(name)
    }

    for (const name of order) {
      const parsedExpr = parsedComputed[name]
      if (parsedExpr.unevaluableReason) {
        computedValues[name] = { kind: 'unevaluable', reason: parsedExpr.unevaluableReason }
        failedComputed.add(name)
        continue
      }

      // A downstream field whose own dependency already failed is unevaluable too.
      const refs = new Set<string>()
      collectVarNames(parsedExpr.ast as Ast, refs)
      const dependsOnFailed = Array.from(refs).some((r) => failedComputed.has(r))
      if (dependsOnFailed) {
        computedValues[name] = {
          kind: 'unevaluable',
          reason: 'depends on a computed field that is itself unevaluable',
        }
        failedComputed.add(name)
        continue
      }

      const outcome = evalAst(parsedExpr.ast as Ast, extendedVariables)
      if (!outcome.ok) {
        computedValues[name] = { kind: 'unevaluable', reason: `expression failed to evaluate (${outcome.error.kind})` }
        failedComputed.add(name)
        continue
      }

      computedValues[name] = { kind: 'evaluated', value: outcome.value }
      extendedVariables[name] = outcome.value
    }

    // --- visible_when, independent per field --------------------------------
    for (const [name, field] of fieldEntries) {
      if (!field.visibleWhen) continue
      const parsedExpr = parseFieldExpression(name, field.visibleWhen)
      if (parsedExpr.unevaluableReason || !parsedExpr.ast) {
        visibility[name] = { kind: 'unevaluable', reason: parsedExpr.unevaluableReason ?? 'expression could not be parsed' }
        continue
      }
      const outcome = evalAst(parsedExpr.ast, extendedVariables)
      if (!outcome.ok) {
        visibility[name] = { kind: 'unevaluable', reason: `expression failed to evaluate (${outcome.error.kind})` }
        continue
      }
      if (typeof outcome.value !== 'boolean') {
        visibility[name] = { kind: 'unevaluable', reason: 'expression did not evaluate to a boolean' }
        continue
      }
      visibility[name] = { kind: 'evaluated', value: outcome.value }
    }

    // --- cross_field_validation, one entry per field ------------------------
    for (const [name, field] of fieldEntries) {
      if (!field.crossFieldValidation) continue
      const parsedExpr = parseFieldExpression(name, field.crossFieldValidation.expression)
      if (parsedExpr.unevaluableReason || !parsedExpr.ast) {
        crossFieldErrors[name] = { kind: 'unevaluable', reason: parsedExpr.unevaluableReason ?? 'expression could not be parsed' }
        continue
      }
      const outcome = evalAst(parsedExpr.ast, extendedVariables)
      if (!outcome.ok) {
        crossFieldErrors[name] = { kind: 'unevaluable', reason: `expression failed to evaluate (${outcome.error.kind})` }
        continue
      }
      // "Failure vs. false" (design §1/§8.3 case 3) — a non-boolean result is
      // unevaluable, never coerced to a truthy/falsy JS boolean.
      if (typeof outcome.value !== 'boolean') {
        crossFieldErrors[name] = { kind: 'unevaluable', reason: 'expression did not evaluate to a boolean' }
        continue
      }
      crossFieldErrors[name] = {
        kind: 'evaluated',
        value: outcome.value === false ? field.crossFieldValidation.message : null,
      }
    }

    return { visibility, computedValues, crossFieldErrors, manifestCompatibility }
  }, [formFields, variables, manifest])
}
