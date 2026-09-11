import { describe, it, expect } from 'vitest'
import { translateCelToExpr } from './translateCel'

describe('translateCelToExpr', () => {
  it('strips the variables. prefix', () => {
    const result = translateCelToExpr('variables.amount > 100')
    expect(result).toEqual({ ok: true, exprSource: 'amount > 100' })
  })

  it('rewrites && to padded " and " (double-spaced when the source already had spaces, matching expr.ex\'s String.replace exactly — harmless, the tokenizer skips whitespace)', () => {
    const result = translateCelToExpr('a&&b')
    expect(result).toEqual({ ok: true, exprSource: 'a and b' })
    expect(translateCelToExpr('a && b')).toEqual({ ok: true, exprSource: 'a  and  b' })
  })

  it('rewrites || to padded " or "', () => {
    const result = translateCelToExpr('a||b')
    expect(result).toEqual({ ok: true, exprSource: 'a or b' })
    expect(translateCelToExpr('a || b')).toEqual({ ok: true, exprSource: 'a  or  b' })
  })

  it('rewrites a standalone ! to "not " but leaves != untouched', () => {
    const result = translateCelToExpr('!a != b')
    expect(result).toEqual({ ok: true, exprSource: 'not a != b' })
  })

  it('rejects a CEL macro call as unsupported_cel_feature', () => {
    const result = translateCelToExpr('has(x.y)')
    expect(result).toEqual({ ok: false, reason: 'unsupported_cel_feature' })
  })

  it('rejects the CEL `in` membership operator as a bare word', () => {
    const result = translateCelToExpr('x in y')
    expect(result).toEqual({ ok: false, reason: 'unsupported_cel_feature' })
  })

  it('does not false-positive on "in" inside a longer identifier', () => {
    const result = translateCelToExpr('printer == "x"')
    expect(result.ok).toBe(true)
  })

  it('rejects a bare ternary "?" outside a string literal', () => {
    const result = translateCelToExpr('a ? b : c')
    expect(result).toEqual({ ok: false, reason: 'unsupported_cel_feature' })
  })

  it('does not false-positive on a "?" inside a string literal', () => {
    const result = translateCelToExpr('name == "who?"')
    expect(result.ok).toBe(true)
  })

  it('rejects an empty condition as translate_error', () => {
    const result = translateCelToExpr('   ')
    expect(result).toEqual({ ok: false, reason: 'translate_error' })
  })

  it('rejects every one of the 17 unsupported call markers', () => {
    const markers = [
      'has(', 'matches(', 'all(', 'exists_one(', 'exists(', 'int(', 'uint(', 'double(',
      'string(', 'bool(', 'bytes(', 'duration(', 'timestamp(', 'size(', 'map(', 'map{', 'filter(',
    ]
    for (const marker of markers) {
      const result = translateCelToExpr(`${marker}x)`)
      expect(result).toEqual({ ok: false, reason: 'unsupported_cel_feature' })
    }
  })
})
