import { describe, it, expect } from 'vitest'
import { tokenize } from './tokenizer'

describe('tokenize', () => {
  it('tokenizes comparison operators', () => {
    const result = tokenize('a == b != c <= d >= e < f > g')
    expect(result.ok).toBe(true)
  })

  it('tokenizes arithmetic operators as arithOp regardless of unary/binary position', () => {
    const result = tokenize('- 5 + 3')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.tokens.map((t) => t.kind)).toEqual(['arithOp', 'lit', 'arithOp', 'lit'])
    }
  })

  it('tags integer literals with numericKind int', () => {
    const result = tokenize('42')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.tokens[0].numericKind).toBe('int')
    }
  })

  it('tags decimal literals with numericKind float', () => {
    const result = tokenize('3.14')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.tokens[0].numericKind).toBe('float')
    }
  })

  it('maps dotted identifiers to a var token with a split path', () => {
    const result = tokenize('order.status')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.tokens[0]).toMatchObject({ kind: 'var', value: ['order', 'status'] })
    }
  })

  it('maps the 8 builtin names to builtinCall tokens', () => {
    for (const name of ['length', 'lower', 'upper', 'trim', 'contains', 'startsWith', 'endsWith', 'coalesce']) {
      const result = tokenize(name)
      expect(result.ok).toBe(true)
      if (result.ok) expect(result.tokens[0].kind).toBe('builtinCall')
    }
  })

  it('handles an escaped-quote string literal', () => {
    const result = tokenize('"she said \\"hi\\""')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.tokens[0]).toMatchObject({ kind: 'lit', value: 'she said "hi"' })
    }
  })

  it('fails on an unterminated string literal', () => {
    const result = tokenize('"unterminated')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure.reason.kind).toBe('unterminated_string')
  })

  it('fails on an unrecognised character', () => {
    const result = tokenize('a @ b')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure.reason.kind).toBe('unexpected_char')
  })

  it('tracks line/column across newlines', () => {
    const result = tokenize('a\nb')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.tokens[0]).toMatchObject({ line: 1, column: 1 })
      expect(result.tokens[1]).toMatchObject({ line: 2, column: 1 })
    }
  })
})
