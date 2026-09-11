/**
 * REQ-293 — direct structural port of `parse_or_p`/`parse_and_p`/`parse_not_p`/
 * `parse_cmp_p`/`parse_additive_p`/`parse_multiplicative_p`/`parse_unary_p`/
 * `parse_primary_p`/`parse_call_args_p`/`parse_call_args_rest_p` (expr.ex lines
 * 792-961) — same 8-level precedence chain (lowest->highest: or, and, not,
 * comparison, +/-, * / %, unary -, primary), same left-associative folding, same
 * right-recursive not/unary -.
 *
 * | `.ts` function        | `.ex` function              | Precedence level |
 * |-----------------------|------------------------------|-------------------|
 * | parseOr               | parse_or_p/2                 | or (lowest)       |
 * | parseAnd              | parse_and_p/2                 | and               |
 * | parseNot              | parse_not_p/2                 | not               |
 * | parseCmp               | parse_cmp_p/2                 | comparison (non-chaining) |
 * | parseAdditive           | parse_additive_p/2            | +/-               |
 * | parseMultiplicative     | parse_multiplicative_p/2      | * / %             |
 * | parseUnary              | parse_unary_p/2               | unary -           |
 * | parsePrimary            | parse_primary_p/2             | literal/var/(...)/builtin call (highest) |
 * | parseCallArgs           | parse_call_args_p/2           | comma-separated builtin-call arg list |
 */

import { tokenize, type Token } from './tokenizer'
import type { Ast, BuiltinName, CmpOp, ParseFailure, ParseResult, Value } from './types'

function fail(reason: ParseFailure['reason'], tok?: Token, eofPos?: { line: number; column: number }): { ok: false; failure: ParseFailure } {
  if (tok) {
    return { ok: false, failure: { line: tok.line, column: tok.column, tokenText: tok.text, reason } }
  }
  return {
    ok: false,
    failure: { line: eofPos?.line ?? 1, column: eofPos?.column ?? 1, tokenText: '', reason },
  }
}

type PResult<T> = { ok: true; value: T; rest: Token[] } | { ok: false; failure: ParseFailure }

function parseOr(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const left = parseAnd(tokens, eofPos)
  if (!left.ok) return left
  return parseOrRest(left.value, left.rest, eofPos)
}

function parseOrRest(left: Ast, tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  if (tokens[0]?.kind === 'or') {
    const right = parseAnd(tokens.slice(1), eofPos)
    if (!right.ok) return right
    return parseOrRest({ kind: 'or', left, right: right.value }, right.rest, eofPos)
  }
  return { ok: true, value: left, rest: tokens }
}

function parseAnd(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const left = parseNot(tokens, eofPos)
  if (!left.ok) return left
  return parseAndRest(left.value, left.rest, eofPos)
}

function parseAndRest(left: Ast, tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  if (tokens[0]?.kind === 'and') {
    const right = parseNot(tokens.slice(1), eofPos)
    if (!right.ok) return right
    return parseAndRest({ kind: 'and', left, right: right.value }, right.rest, eofPos)
  }
  return { ok: true, value: left, rest: tokens }
}

function parseNot(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  if (tokens[0]?.kind === 'not') {
    const sub = parseNot(tokens.slice(1), eofPos)
    if (!sub.ok) return sub
    return { ok: true, value: { kind: 'not', sub: sub.value }, rest: sub.rest }
  }
  return parseCmp(tokens, eofPos)
}

function parseCmp(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const left = parseAdditive(tokens, eofPos)
  if (!left.ok) return left
  const [head, ...tail] = left.rest
  if (head?.kind === 'cmpOp') {
    const right = parseAdditive(tail, eofPos)
    if (!right.ok) return right
    return {
      ok: true,
      value: { kind: 'cmp', op: head.value as CmpOp, left: left.value, right: right.value },
      rest: right.rest,
    }
  }
  return { ok: true, value: left.value, rest: left.rest }
}

function parseAdditive(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const left = parseMultiplicative(tokens, eofPos)
  if (!left.ok) return left
  return parseAdditiveRest(left.value, left.rest, eofPos)
}

function parseAdditiveRest(left: Ast, tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const head = tokens[0]
  if (head?.kind === 'arithOp' && (head.value === 'add' || head.value === 'sub')) {
    const right = parseMultiplicative(tokens.slice(1), eofPos)
    if (!right.ok) return right
    return parseAdditiveRest({ kind: 'arith', op: head.value, left, right: right.value }, right.rest, eofPos)
  }
  return { ok: true, value: left, rest: tokens }
}

function parseMultiplicative(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const left = parseUnary(tokens, eofPos)
  if (!left.ok) return left
  return parseMultiplicativeRest(left.value, left.rest, eofPos)
}

function parseMultiplicativeRest(left: Ast, tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const head = tokens[0]
  if (head?.kind === 'arithOp' && (head.value === 'mul' || head.value === 'div' || head.value === 'mod')) {
    const right = parseUnary(tokens.slice(1), eofPos)
    if (!right.ok) return right
    return parseMultiplicativeRest({ kind: 'arith', op: head.value, left, right: right.value }, right.rest, eofPos)
  }
  return { ok: true, value: left, rest: tokens }
}

function parseUnary(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const head = tokens[0]
  if (head?.kind === 'arithOp' && head.value === 'sub') {
    const sub = parseUnary(tokens.slice(1), eofPos)
    if (!sub.ok) return sub
    return { ok: true, value: { kind: 'neg', sub: sub.value }, rest: sub.rest }
  }
  return parsePrimary(tokens, eofPos)
}

function parsePrimary(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast> {
  const head = tokens[0]

  if (head?.kind === 'builtinCall' && tokens[1]?.kind === 'lparen') {
    const args = parseCallArgs(tokens.slice(2), eofPos)
    if (!args.ok) return args
    return {
      ok: true,
      value: { kind: 'call', name: head.value as BuiltinName, args: args.value },
      rest: args.rest,
    }
  }

  if (head?.kind === 'lparen') {
    const inner = parseOr(tokens.slice(1), eofPos)
    if (!inner.ok) return inner
    const closing = inner.rest[0]
    if (closing?.kind === 'rparen') {
      return { ok: true, value: inner.value, rest: inner.rest.slice(1) }
    }
    if (closing) {
      return fail({ kind: 'expected_rparen' }, closing)
    }
    return fail({ kind: 'expected_rparen' }, undefined, eofPos)
  }

  if (head?.kind === 'lit') {
    return { ok: true, value: { kind: 'lit', value: head.value as Value, numericKind: head.numericKind }, rest: tokens.slice(1) }
  }

  if (head?.kind === 'var') {
    return { ok: true, value: { kind: 'var', path: head.value as string[] }, rest: tokens.slice(1) }
  }

  if (!head) {
    return fail({ kind: 'unexpected_end_of_input' }, undefined, eofPos)
  }

  return fail({ kind: 'unexpected_token', text: head.text }, head)
}

function parseCallArgs(tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast[]> {
  if (tokens[0]?.kind === 'rparen') {
    return { ok: true, value: [], rest: tokens.slice(1) }
  }
  const first = parseOr(tokens, eofPos)
  if (!first.ok) return first
  return parseCallArgsRest([first.value], first.rest, eofPos)
}

function parseCallArgsRest(acc: Ast[], tokens: Token[], eofPos: { line: number; column: number }): PResult<Ast[]> {
  const head = tokens[0]
  if (head?.kind === 'comma') {
    const next = parseOr(tokens.slice(1), eofPos)
    if (!next.ok) return next
    return parseCallArgsRest([...acc, next.value], next.rest, eofPos)
  }
  if (head?.kind === 'rparen') {
    return { ok: true, value: acc, rest: tokens.slice(1) }
  }
  if (head) {
    return fail({ kind: 'expected_rparen' }, head)
  }
  return fail({ kind: 'expected_rparen' }, undefined, eofPos)
}

export function parse(source: string): ParseResult {
  const tokenized = tokenize(source)
  if (!tokenized.ok) {
    return { ok: false, failure: tokenized.failure }
  }

  const result = parseOr(tokenized.tokens, tokenized.eofPos)
  if (!result.ok) {
    return { ok: false, failure: result.failure }
  }

  if (result.rest.length > 0) {
    const tok = result.rest[0]
    return { ok: false, failure: { line: tok.line, column: tok.column, tokenText: tok.text, reason: { kind: 'trailing_input' } } }
  }

  return { ok: true, ast: result.value }
}
