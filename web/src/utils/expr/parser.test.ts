import { describe, it, expect } from 'vitest'
import { parse } from './parser'

describe('parse', () => {
  it('gives multiplication higher precedence than addition', () => {
    const result = parse('2 + 3 * 4')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.ast).toEqual({
        kind: 'arith',
        op: 'add',
        left: { kind: 'lit', value: 2, numericKind: 'int' },
        right: {
          kind: 'arith',
          op: 'mul',
          left: { kind: 'lit', value: 3, numericKind: 'int' },
          right: { kind: 'lit', value: 4, numericKind: 'int' },
        },
      })
    }
  })

  it('does not chain comparison operators (one cmp_op per level, not a fold)', () => {
    const result = parse('a == b')
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.ast.kind).toBe('cmp')
  })

  it('right-recurses through nested unary minus', () => {
    const result = parse('- - 5')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.ast).toEqual({ kind: 'neg', sub: { kind: 'neg', sub: { kind: 'lit', value: 5, numericKind: 'int' } } })
    }
  })

  it('right-recurses through nested not', () => {
    const result = parse('not not true')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.ast).toEqual({ kind: 'not', sub: { kind: 'not', sub: { kind: 'lit', value: true } } })
    }
  })

  it('left-folds and/or chains', () => {
    const result = parse('a and b and c')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.ast).toEqual({
        kind: 'and',
        left: { kind: 'and', left: { kind: 'var', path: ['a'] }, right: { kind: 'var', path: ['b'] } },
        right: { kind: 'var', path: ['c'] },
      })
    }
  })

  it('parses a builtin call with multiple comma-separated arguments', () => {
    const result = parse('contains("hello world", "wor")')
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.ast).toEqual({
        kind: 'call',
        name: 'contains',
        args: [
          { kind: 'lit', value: 'hello world' },
          { kind: 'lit', value: 'wor' },
        ],
      })
    }
  })

  it('parses a zero-argument builtin call', () => {
    const result = parse('coalesce()')
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.ast).toEqual({ kind: 'call', name: 'coalesce', args: [] })
  })

  it('parses parenthesised sub-expressions', () => {
    const result = parse('(a or b) and c')
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.ast.kind).toBe('and')
  })

  it('fails when a binary operator has no right operand', () => {
    const result = parse('amount +')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure.reason.kind).toBe('unexpected_end_of_input')
  })

  it('fails on an expression made only of keywords', () => {
    const result = parse('and and and')
    expect(result.ok).toBe(false)
  })

  it('fails on trailing input after a complete expression', () => {
    const result = parse('a b')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure.reason.kind).toBe('trailing_input')
  })

  it('fails when a parenthesised expression is missing its closing paren', () => {
    const result = parse('(a and b')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure.reason.kind).toBe('expected_rparen')
  })
})
