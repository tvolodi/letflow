import { describe, it, expect } from 'vitest'
import { parse } from './parser'
import { evalAst } from './evaluator'
import { translateCelToExpr } from './translateCel'

function evalSource(source: string, variables: Record<string, unknown> = {}) {
  const parsed = parse(source)
  if (!parsed.ok) throw new Error(`parse failed: ${JSON.stringify(parsed.failure)}`)
  return evalAst(parsed.ast, variables)
}

describe('evalAst', () => {
  it('evaluates a literal', () => {
    expect(evalSource('42')).toEqual({ ok: true, value: 42 })
  })

  it('resolves a dotted variable path', () => {
    expect(evalSource('order.status', { order: { status: 'approved' } })).toEqual({ ok: true, value: 'approved' })
  })

  it('errors on an undefined variable', () => {
    const result = evalSource('missing', {})
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error.kind).toBe('undefined_variable')
  })

  it('errors when a non-map is indexed mid-path', () => {
    const result = evalSource('a.b', { a: 5 })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error.kind).toBe('undefined_variable')
  })

  describe('comparison', () => {
    it(':nan never equals itself', () => {
      const nanResult = evalSource('0.0 / 0.0')
      expect(nanResult).toEqual({ ok: true, value: 'nan' })
      expect(evalSource('(0.0 / 0.0) == (0.0 / 0.0)')).toEqual({ ok: true, value: false })
      expect(evalSource('(0.0 / 0.0) != (0.0 / 0.0)')).toEqual({ ok: true, value: true })
    })

    it('null propagates through ordering comparison rather than erroring', () => {
      expect(evalSource('amount < 100', { amount: null })).toEqual({ ok: true, value: null })
    })

    it(':nan compares as false through every ordering operator, including against itself', () => {
      for (const op of ['<', '<=', '>', '>=']) {
        expect(evalSource(`(0.0 / 0.0) ${op} 1`)).toEqual({ ok: true, value: false })
      }
    })

    it('infinity is the greatest possible value, neg_infinity the least', () => {
      expect(evalSource('(1.0 / 0.0) > 999999')).toEqual({ ok: true, value: true })
      expect(evalSource('(-1.0 / 0.0) < -999999', {})).toEqual({ ok: true, value: true })
    })

    it('errors on a type mismatch in ordering comparison', () => {
      const result = evalSource('name > 5', { name: 'bob' })
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('type_mismatch')
    })
  })

  describe('arithmetic', () => {
    it('null on either operand is an error, not a propagation (asymmetric vs. comparison)', () => {
      const result = evalSource('amount + 1', { amount: null })
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('null_in_arithmetic')
    })

    it('truncates both-integer-literal division toward zero', () => {
      expect(evalSource('7 / 2')).toEqual({ ok: true, value: 3 })
    })

    it('promotes to float division when either literal is a float', () => {
      expect(evalSource('7 / 2.0')).toEqual({ ok: true, value: 3.5 })
    })

    it('errors on both-integer-literal division by zero', () => {
      const result = evalSource('5 / 0')
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('division_by_zero')
    })

    it('errors on both-integer-literal modulo by zero', () => {
      const result = evalSource('5 % 0')
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('modulo_by_zero')
    })

    it('float modulo is unconditionally an error, zero divisor or not', () => {
      const result = evalSource('5.0 % 2.0')
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('modulo_by_zero')
    })

    it('negating infinity/neg_infinity flips the marker; negating nan stays nan', () => {
      expect(evalSource('- (1.0 / 0.0)')).toEqual({ ok: true, value: 'neg_infinity' })
      expect(evalSource('- (- 1.0 / 0.0)')).toEqual({ ok: true, value: 'infinity' })
      expect(evalSource('- (0.0 / 0.0)')).toEqual({ ok: true, value: 'nan' })
    })
  })

  describe('builtins', () => {
    it('nil argument to any of the 8 builtins propagates as null before any type check', () => {
      expect(evalSource('length(x)', { x: null })).toEqual({ ok: true, value: null })
      expect(evalSource('lower(x)', { x: null })).toEqual({ ok: true, value: null })
      expect(evalSource('contains(x, "a")', { x: null })).toEqual({ ok: true, value: null })
    })

    it('checks arity before dispatching', () => {
      const result = evalSource('length("a", "b")')
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('wrong_arity')
    })

    it('coalesce is variadic, at least 1 argument', () => {
      expect(evalSource('coalesce(null, null, 3)')).toEqual({ ok: true, value: 3 })
      const result = evalSource('coalesce()')
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.error.kind).toBe('wrong_arity')
    })
  })

  describe('REQ-293 AC2 — now/date_add/date_diff are absent, not merely unlisted', () => {
    it('rejects date_add(...) at parse time (tokenizes as a bare var, not a builtin call)', () => {
      const translated = translateCelToExpr('date_add(x, 1)')
      expect(translated.ok).toBe(true)
      if (translated.ok) {
        const parsed = parse(translated.exprSource)
        expect(parsed.ok).toBe(false)
      }
    })

    it('rejects now() the same way', () => {
      const translated = translateCelToExpr('now()')
      expect(translated.ok).toBe(true)
      if (translated.ok) {
        const parsed = parse(translated.exprSource)
        expect(parsed.ok).toBe(false)
      }
    })

    it('rejects date_diff(...) the same way', () => {
      const translated = translateCelToExpr('date_diff(a, b)')
      expect(translated.ok).toBe(true)
      if (translated.ok) {
        const parsed = parse(translated.exprSource)
        expect(parsed.ok).toBe(false)
      }
    })
  })
})
