/**
 * REQ-293 — port of `do_tokenize/2`/`do_tokenize_positioned/4` (expr.ex lines
 * 342-747). Always position-tracking (line/column) — this port has no non-positioned
 * variant (design doc §4).
 */

import { ASCII_WHITESPACE, type ArithOp, type BuiltinName, type CmpOp, type NumericKind, type ParseFailure, type Value } from './types'

export type TokenKind =
  | 'lparen'
  | 'rparen'
  | 'comma'
  | 'cmpOp'
  | 'arithOp'
  | 'and'
  | 'or'
  | 'not'
  | 'lit'
  | 'var'
  | 'builtinCall'

export interface Token {
  kind: TokenKind
  value?: CmpOp | ArithOp | Value | BuiltinName | string[]
  numericKind?: NumericKind
  text: string
  line: number
  column: number
}

export type TokenizeResult =
  | { ok: true; tokens: Token[]; eofPos: { line: number; column: number } }
  | { ok: false; failure: ParseFailure }

const BUILTIN_NAMES: ReadonlySet<string> = new Set<BuiltinName>([
  'length',
  'lower',
  'upper',
  'trim',
  'contains',
  'startsWith',
  'endsWith',
  'coalesce',
])

const NUMBER_RE = /^-?\d+(\.\d+)?/
const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/

function advancePos(line: number, column: number, text: string): { line: number; column: number } {
  let l = line
  let c = column
  for (const ch of text) {
    if (ch === '\n') {
      l += 1
      c = 1
    } else {
      c += 1
    }
  }
  return { line: l, column: c }
}

function identifierToken(ident: string): { kind: TokenKind; value?: Value | string[] } {
  switch (ident) {
    case 'and':
      return { kind: 'and' }
    case 'or':
      return { kind: 'or' }
    case 'not':
      return { kind: 'not' }
    case 'true':
      return { kind: 'lit', value: true }
    case 'false':
      return { kind: 'lit', value: false }
    case 'null':
      return { kind: 'lit', value: null }
    default:
      if (BUILTIN_NAMES.has(ident)) {
        return { kind: 'builtinCall', value: ident as unknown as Value }
      }
      return { kind: 'var', value: ident.split('.') }
  }
}

/**
 * Scans a string literal body up to its closing, un-escaped `quote` character. A
 * backslash immediately followed by `quote` is consumed as one escaped-quote unit;
 * any other backslash sequence passes through unchanged (matches `scan_string_literal/3`).
 */
function scanStringLiteral(
  source: string,
  start: number,
  quote: string,
): { ok: true; content: string; nextIndex: number } | { ok: false } {
  let content = ''
  let i = start
  while (i < source.length) {
    const c = source[i]
    if (c === quote) {
      return { ok: true, content, nextIndex: i + 1 }
    }
    if (c === '\\' && source[i + 1] === quote) {
      content += quote
      i += 2
      continue
    }
    content += c
    i += 1
  }
  return { ok: false }
}

export function tokenize(source: string): TokenizeResult {
  const tokens: Token[] = []
  let line = 1
  let column = 1
  let i = 0

  while (i < source.length) {
    const c = source[i]

    if (ASCII_WHITESPACE.has(c)) {
      const pos = advancePos(line, column, c)
      line = pos.line
      column = pos.column
      i += 1
      continue
    }

    if (c === '(') {
      tokens.push({ kind: 'lparen', text: '(', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === ')') {
      tokens.push({ kind: 'rparen', text: ')', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === ',') {
      tokens.push({ kind: 'comma', text: ',', line, column })
      column += 1
      i += 1
      continue
    }

    const two = source.slice(i, i + 2)
    if (two === '==') {
      tokens.push({ kind: 'cmpOp', value: 'eq', text: '==', line, column })
      column += 2
      i += 2
      continue
    }
    if (two === '!=') {
      tokens.push({ kind: 'cmpOp', value: 'neq', text: '!=', line, column })
      column += 2
      i += 2
      continue
    }
    if (two === '<=') {
      tokens.push({ kind: 'cmpOp', value: 'lte', text: '<=', line, column })
      column += 2
      i += 2
      continue
    }
    if (two === '>=') {
      tokens.push({ kind: 'cmpOp', value: 'gte', text: '>=', line, column })
      column += 2
      i += 2
      continue
    }
    if (c === '<') {
      tokens.push({ kind: 'cmpOp', value: 'lt', text: '<', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === '>') {
      tokens.push({ kind: 'cmpOp', value: 'gt', text: '>', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === '+') {
      tokens.push({ kind: 'arithOp', value: 'add', text: '+', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === '-') {
      tokens.push({ kind: 'arithOp', value: 'sub', text: '-', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === '*') {
      tokens.push({ kind: 'arithOp', value: 'mul', text: '*', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === '/') {
      tokens.push({ kind: 'arithOp', value: 'div', text: '/', line, column })
      column += 1
      i += 1
      continue
    }
    if (c === '%') {
      tokens.push({ kind: 'arithOp', value: 'mod', text: '%', line, column })
      column += 1
      i += 1
      continue
    }

    if (c === '"' || c === "'") {
      const startLine = line
      const startColumn = column
      const scanned = scanStringLiteral(source, i + 1, c)
      if (!scanned.ok) {
        return {
          ok: false,
          failure: {
            line: startLine,
            column: startColumn,
            tokenText: source.slice(i + 1),
            reason: { kind: 'unterminated_string', text: source.slice(i + 1) },
          },
        }
      }
      const consumed = source.slice(i, scanned.nextIndex)
      tokens.push({ kind: 'lit', value: scanned.content, text: consumed, line: startLine, column: startColumn })
      const pos = advancePos(startLine, startColumn, consumed)
      line = pos.line
      column = pos.column
      i = scanned.nextIndex
      continue
    }

    if (c >= '0' && c <= '9') {
      const rest = source.slice(i)
      const match = NUMBER_RE.exec(rest)
      if (!match) {
        return {
          ok: false,
          failure: {
            line,
            column,
            tokenText: rest,
            reason: { kind: 'invalid_number', text: rest },
          },
        }
      }
      const text = match[0]
      const isFloat = text.includes('.')
      const value = isFloat ? Number.parseFloat(text) : Number.parseInt(text, 10)
      tokens.push({
        kind: 'lit',
        value,
        numericKind: isFloat ? 'float' : 'int',
        text,
        line,
        column,
      })
      const pos = advancePos(line, column, text)
      line = pos.line
      column = pos.column
      i += text.length
      continue
    }

    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_') {
      const rest = source.slice(i)
      const match = IDENT_RE.exec(rest)
      if (!match) {
        return {
          ok: false,
          failure: {
            line,
            column,
            tokenText: rest,
            reason: { kind: 'invalid_identifier', text: rest },
          },
        }
      }
      const text = match[0]
      const { kind, value } = identifierToken(text)
      tokens.push({ kind, value, text, line, column })
      const pos = advancePos(line, column, text)
      line = pos.line
      column = pos.column
      i += text.length
      continue
    }

    return {
      ok: false,
      failure: {
        line,
        column,
        tokenText: c,
        reason: { kind: 'unexpected_char', char: c },
      },
    }
  }

  return { ok: true, tokens, eofPos: { line, column } }
}
