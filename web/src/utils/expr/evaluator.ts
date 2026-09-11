/**
 * REQ-293 — direct port of `eval/2` (expr.ex lines 1121-1468) and its private
 * helpers (`apply_arith`/`apply_int_arith`/`apply_float_arith`/`apply_neg`/
 * `apply_ordering`/`apply_builtin`/`resolve_var`/`check_arity`).
 *
 * See `lib/letflow/design/req293-typescript-expr-evaluator.md` §6 for the full
 * semantics list, and §6.1/§6.2/§6.3/§6.4 for the three explicit divergence-prone
 * semantics this port must preserve byte-for-value-identically against
 * `expr.ex`, plus the one open, deliberately-unresolved divergence (§6.2,
 * int-variable arithmetic provenance).
 */

import { ASCII_WHITESPACE } from './types'
import type { ArithOp, Ast, BuiltinName, CmpOp, EvalErrorReason, EvalOutcome, Value } from './types'

function ok(value: Value): EvalOutcome {
  return { ok: true, value }
}

function err(error: EvalErrorReason): EvalOutcome {
  return { ok: false, error }
}

/** §6.2 — an operand's numeric provenance is "known int" only for a direct
 * `{kind:'lit', numericKind:'int'}` AST node; every other node (var, call, arith,
 * neg, or a float literal) is float-promotion-eligible. This port does not
 * recursively propagate int-provenance through nested arithmetic results — see
 * the design doc's own flagged, unresolved divergence for the concrete case
 * this can affect (int-variable division), which the corpus does not exercise. */
function isIntLiteralNode(node: Ast): boolean {
  return node.kind === 'lit' && node.numericKind === 'int'
}

export function evalAst(ast: Ast, variables: Record<string, unknown>): EvalOutcome {
  switch (ast.kind) {
    case 'lit':
      return ok(ast.value)

    case 'var':
      return resolveVar(ast.path, variables, ast.path)

    case 'not': {
      const v = evalAst(ast.sub, variables)
      if (!v.ok) return v
      if (typeof v.value !== 'boolean') {
        return err({ kind: 'type_mismatch', op: 'not', operands: [v.value] })
      }
      return ok(!v.value)
    }

    case 'and': {
      const lv = evalAst(ast.left, variables)
      if (!lv.ok) return lv
      const rv = evalAst(ast.right, variables)
      if (!rv.ok) return rv
      if (typeof lv.value !== 'boolean' || typeof rv.value !== 'boolean') {
        return err({ kind: 'type_mismatch', op: 'and', operands: [lv.value, rv.value] })
      }
      return ok(lv.value && rv.value)
    }

    case 'or': {
      const lv = evalAst(ast.left, variables)
      if (!lv.ok) return lv
      const rv = evalAst(ast.right, variables)
      if (!rv.ok) return rv
      if (typeof lv.value !== 'boolean' || typeof rv.value !== 'boolean') {
        return err({ kind: 'type_mismatch', op: 'or', operands: [lv.value, rv.value] })
      }
      return ok(lv.value || rv.value)
    }

    case 'cmp':
      return evalCmp(ast.op, ast.left, ast.right, variables)

    case 'arith':
      return evalArith(ast.op, ast.left, ast.right, variables)

    case 'neg': {
      const v = evalAst(ast.sub, variables)
      if (!v.ok) return v
      return applyNeg(v.value)
    }

    case 'call':
      return evalCall(ast.name, ast.args, variables)

    default:
      return err({ kind: 'unsupported_at_eval' })
  }
}

function evalCmp(op: CmpOp, leftNode: Ast, rightNode: Ast, variables: Record<string, unknown>): EvalOutcome {
  const lv = evalAst(leftNode, variables)
  if (!lv.ok) return lv
  const rv = evalAst(rightNode, variables)
  if (!rv.ok) return rv

  if (op === 'eq' || op === 'neq') {
    // REQ-197 §4.6 parity: real IEEE 754 NaN self-inequality — checked before the
    // generic equality fallback, which would otherwise treat two 'nan' string
    // literals as equal.
    if (lv.value === 'nan' || rv.value === 'nan') {
      return ok(op === 'neq')
    }
    return ok(op === 'eq' ? lv.value === rv.value : lv.value !== rv.value)
  }

  // lt/lte/gt/gte
  if (lv.value === null || rv.value === null) {
    // §4.5 asymmetry vs. arithmetic — null propagates, not an error.
    return ok(null)
  }
  if (lv.value === 'nan' || rv.value === 'nan') {
    return ok(false)
  }
  const lok = typeof lv.value === 'number' || lv.value === 'infinity' || lv.value === 'neg_infinity'
  const rok = typeof rv.value === 'number' || rv.value === 'infinity' || rv.value === 'neg_infinity'
  if (lok && rok) {
    return ok(applyOrdering(op, lv.value as number | 'infinity' | 'neg_infinity', rv.value as number | 'infinity' | 'neg_infinity'))
  }
  return err({ kind: 'type_mismatch', op, operands: [lv.value, rv.value] })
}

function applyOrdering(
  op: 'lt' | 'lte' | 'gt' | 'gte',
  l: number | 'infinity' | 'neg_infinity',
  r: number | 'infinity' | 'neg_infinity',
): boolean {
  if (l === 'infinity' || l === 'neg_infinity' || r === 'infinity' || r === 'neg_infinity') {
    if (l === r) return op === 'lte' || op === 'gte'
    if (l === 'infinity') return op === 'gt' || op === 'gte'
    if (l === 'neg_infinity') return op === 'lt' || op === 'lte'
    if (r === 'infinity') return op === 'lt' || op === 'lte'
    if (r === 'neg_infinity') return op === 'gt' || op === 'gte'
  }
  const ln = l as number
  const rn = r as number
  switch (op) {
    case 'lt':
      return ln < rn
    case 'lte':
      return ln <= rn
    case 'gt':
      return ln > rn
    case 'gte':
      return ln >= rn
  }
}

function evalArith(op: ArithOp, leftNode: Ast, rightNode: Ast, variables: Record<string, unknown>): EvalOutcome {
  const lv = evalAst(leftNode, variables)
  if (!lv.ok) return lv
  const rv = evalAst(rightNode, variables)
  if (!rv.ok) return rv

  // §4.2 clause order: null check first, before any type/promotion logic.
  if (lv.value === null || rv.value === null) {
    return err({ kind: 'null_in_arithmetic', op })
  }

  if (typeof lv.value !== 'number' || typeof rv.value !== 'number') {
    return err({ kind: 'type_mismatch', op, operands: [lv.value, rv.value] })
  }

  const bothIntLiteral = isIntLiteralNode(leftNode) && isIntLiteralNode(rightNode)
  if (bothIntLiteral) {
    return applyIntArith(op, lv.value, rv.value)
  }
  return applyFloatArith(op, lv.value, rv.value)
}

function applyIntArith(op: ArithOp, l: number, r: number): EvalOutcome {
  switch (op) {
    case 'add':
      return ok(l + r)
    case 'sub':
      return ok(l - r)
    case 'mul':
      return ok(l * r)
    case 'div':
      if (r === 0) return err({ kind: 'division_by_zero' })
      return ok(Math.trunc(l / r))
    case 'mod':
      if (r === 0) return err({ kind: 'modulo_by_zero' })
      return ok(l % r)
  }
}

function applyFloatArith(op: ArithOp, l: number, r: number): EvalOutcome {
  switch (op) {
    case 'add':
      return ok(l + r)
    case 'sub':
      return ok(l - r)
    case 'mul':
      return ok(l * r)
    case 'div':
      if (r === 0) {
        // Never native JS division here — explicit sign check, per §6.1/§6.4.
        if (l === 0) return ok('nan')
        if (l > 0) return ok('infinity')
        return ok('neg_infinity')
      }
      return ok(l / r)
    case 'mod':
      // Float modulo is never attempted, zero divisor or not — ported literally.
      return err({ kind: 'modulo_by_zero' })
  }
}

function applyNeg(v: Value): EvalOutcome {
  if (v === null) return err({ kind: 'null_in_arithmetic', op: 'neg' })
  if (v === 'infinity') return ok('neg_infinity')
  if (v === 'neg_infinity') return ok('infinity')
  if (v === 'nan') return ok('nan')
  if (typeof v === 'number') return ok(-v)
  return err({ kind: 'type_mismatch', op: 'neg', operands: [v] })
}

function resolveVar(path: string[], root: unknown, fullPath: string[]): EvalOutcome {
  let current: unknown = root
  for (const key of path) {
    if (
      current !== null &&
      typeof current === 'object' &&
      !Array.isArray(current) &&
      Object.prototype.hasOwnProperty.call(current, key)
    ) {
      current = (current as Record<string, unknown>)[key]
    } else {
      return err({ kind: 'undefined_variable', path: fullPath })
    }
  }
  return ok(current as Value)
}

function evalCall(name: BuiltinName, argNodes: Ast[], variables: Record<string, unknown>): EvalOutcome {
  const values: Value[] = []
  for (const argNode of argNodes) {
    const v = evalAst(argNode, variables)
    if (!v.ok) return v
    values.push(v.value)
  }

  const arityError = checkArity(name, values.length)
  if (arityError) return arityError

  return applyBuiltin(name, values)
}

function checkArity(name: BuiltinName, got: number): EvalOutcome | null {
  const requirement = requiredArity(name)
  const okArity = requirement.kind === 'exactly' ? got === requirement.n : got >= requirement.n
  if (okArity) return null
  return err({ kind: 'wrong_arity', name, got })
}

function requiredArity(name: BuiltinName): { kind: 'exactly' | 'atLeast'; n: number } {
  switch (name) {
    case 'length':
    case 'lower':
    case 'upper':
    case 'trim':
      return { kind: 'exactly', n: 1 }
    case 'contains':
    case 'startsWith':
    case 'endsWith':
      return { kind: 'exactly', n: 2 }
    case 'coalesce':
      return { kind: 'atLeast', n: 1 }
  }
}

const ASCII_LOWER = new Map<string, string>()
const ASCII_UPPER = new Map<string, string>()
for (let code = 65; code <= 90; code += 1) {
  const upper = String.fromCharCode(code)
  const lower = String.fromCharCode(code + 32)
  ASCII_LOWER.set(upper, lower)
  ASCII_UPPER.set(lower, upper)
}

/** ASCII-only lower — never `String.prototype.toLowerCase()` (§6.3). Iterates
 * Unicode code points via `Array.from`, not UTF-16 code units, so a
 * multi-code-unit character is visited once and left unchanged. */
function asciiLower(s: string): string {
  return Array.from(s)
    .map((ch) => ASCII_LOWER.get(ch) ?? ch)
    .join('')
}

function asciiUpper(s: string): string {
  return Array.from(s)
    .map((ch) => ASCII_UPPER.get(ch) ?? ch)
    .join('')
}

/** Strips only the 4 ASCII whitespace chars, never `String.prototype.trim()`. */
function asciiTrim(s: string): string {
  const chars = Array.from(s)
  let start = 0
  let end = chars.length
  while (start < end && ASCII_WHITESPACE.has(chars[start])) start += 1
  while (end > start && ASCII_WHITESPACE.has(chars[end - 1])) end -= 1
  return chars.slice(start, end).join('')
}

function stringPredicate(name: BuiltinName, a: Value, b: Value, fn: (a: string, b: string) => boolean): EvalOutcome {
  if (a === null || b === null) return ok(null)
  if (typeof a === 'string' && typeof b === 'string') return ok(fn(a, b))
  return err({ kind: 'type_mismatch', op: name, operands: [a, b] })
}

function applyBuiltin(name: BuiltinName, values: Value[]): EvalOutcome {
  switch (name) {
    case 'length': {
      const [s] = values
      if (s === null) return ok(null)
      if (typeof s === 'string') return ok(new TextEncoder().encode(s).length)
      return err({ kind: 'type_mismatch', op: 'length', operands: [s] })
    }
    case 'lower': {
      const [s] = values
      if (s === null) return ok(null)
      if (typeof s === 'string') return ok(asciiLower(s))
      return err({ kind: 'type_mismatch', op: 'lower', operands: [s] })
    }
    case 'upper': {
      const [s] = values
      if (s === null) return ok(null)
      if (typeof s === 'string') return ok(asciiUpper(s))
      return err({ kind: 'type_mismatch', op: 'upper', operands: [s] })
    }
    case 'trim': {
      const [s] = values
      if (s === null) return ok(null)
      if (typeof s === 'string') return ok(asciiTrim(s))
      return err({ kind: 'type_mismatch', op: 'trim', operands: [s] })
    }
    case 'contains':
      return stringPredicate('contains', values[0], values[1], (a, b) => a.includes(b))
    case 'startsWith':
      return stringPredicate('startsWith', values[0], values[1], (a, b) => a.startsWith(b))
    case 'endsWith':
      return stringPredicate('endsWith', values[0], values[1], (a, b) => a.endsWith(b))
    case 'coalesce':
      return ok(values.find((v) => v !== null) ?? null)
  }
}
