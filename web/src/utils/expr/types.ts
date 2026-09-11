/**
 * REQ-293 — TypeScript port of `Letflow.Engine.Expr`'s type surface.
 *
 * Direct structural counterpart of `expr.ex`'s `ast()`, `value()`, and `eval/2`'s
 * `{:ok, value()} | {:error, {:eval_error, reason}}` return shape — same node set,
 * same operator closed unions, same 3-way infinity marker. No node kind exists here
 * that `expr.ex` does not have (design doc §3, D1a constraint 1: no local extension
 * of the grammar). See `lib/letflow/design/req293-typescript-expr-evaluator.md`.
 */

/** Branded 3-member string union — never native JS Infinity/-Infinity/NaN (§6.1). */
export type InfinityMarker = 'infinity' | 'neg_infinity' | 'nan'

export type Value = number | string | boolean | null | InfinityMarker

export type CmpOp = 'eq' | 'neq' | 'lt' | 'lte' | 'gt' | 'gte'
export type ArithOp = 'add' | 'sub' | 'mul' | 'div' | 'mod'
export type BuiltinName =
  | 'length'
  | 'lower'
  | 'upper'
  | 'trim'
  | 'contains'
  | 'startsWith'
  | 'endsWith'
  | 'coalesce'

/** Numeric-literal provenance (§6.2) — present only when `value` is a `number`. */
export type NumericKind = 'int' | 'float'

export type Ast =
  | { kind: 'lit'; value: Value; numericKind?: NumericKind }
  | { kind: 'var'; path: string[] }
  | { kind: 'not'; sub: Ast }
  | { kind: 'and'; left: Ast; right: Ast }
  | { kind: 'or'; left: Ast; right: Ast }
  | { kind: 'cmp'; op: CmpOp; left: Ast; right: Ast }
  | { kind: 'arith'; op: ArithOp; left: Ast; right: Ast }
  | { kind: 'neg'; sub: Ast }
  | { kind: 'call'; name: BuiltinName; args: Ast[] }

// Mirrors expr.ex's parse_error_reason() / internal_parse_error() (§6.2/§6.3 of the
// design doc) — this port has exactly one parse-error entry point (no unstructured
// parse/1 vs. structured parse_strict/1 split).
export type ParseErrorReason =
  | { kind: 'invalid_number'; text: string }
  | { kind: 'invalid_identifier'; text: string }
  | { kind: 'unexpected_char'; char: string }
  | { kind: 'unterminated_string'; text: string }
  | { kind: 'expected_rparen' }
  | { kind: 'unexpected_end_of_input' }
  | { kind: 'unexpected_token'; text: string }
  | { kind: 'trailing_input' }
  | { kind: 'unsupported_construct'; tag: string } // this port's own addition, see §5.2

export interface ParseFailure {
  line: number
  column: number
  tokenText: string
  reason: ParseErrorReason
}

export type ParseResult = { ok: true; ast: Ast } | { ok: false; failure: ParseFailure }

// Mirrors expr.ex's {:eval_error, reason} shapes (eval/2's own error tuples).
export type EvalErrorReason =
  | { kind: 'type_mismatch'; op: string; operands: Value[] }
  | { kind: 'undefined_variable'; path: string[] }
  | { kind: 'null_in_arithmetic'; op: ArithOp | 'neg' }
  | { kind: 'division_by_zero' }
  | { kind: 'modulo_by_zero' }
  | { kind: 'wrong_arity'; name: BuiltinName; got: number }
  // this port's own addition: defence-in-depth only, see design doc §3.
  | { kind: 'unsupported_at_eval' }

export type EvalOutcome = { ok: true; value: Value } | { ok: false; error: EvalErrorReason }

export type TranslateResult =
  | { ok: true; exprSource: string }
  | { ok: false; reason: 'unsupported_cel_feature' | 'translate_error' }

/** The 4-ASCII-char whitespace set shared by the tokenizer and the `trim` builtin —
 * one constant, so the two can never drift relative to each other (design doc §4). */
export const ASCII_WHITESPACE = new Set<string>([' ', '\t', '\n', '\r'])
