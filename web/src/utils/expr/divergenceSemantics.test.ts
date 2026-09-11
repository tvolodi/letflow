// @vitest-environment node
/**
 * REQ-293 AC4 — explicit tests for the 3 divergence-prone semantics (design doc
 * §6.4), beyond the corpus run: each test proves this evaluator's behaviour
 * diverges from the naive JS built-in it deliberately avoids, not merely that
 * it happens to match the corpus's expected value.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parse } from './parser'
import { evalAst } from './evaluator'

const CORPUS_PATH = join(__dirname, '..', '..', '..', '..', 'priv', 'expr_conformance', 'corpus.json')

function evalSource(source: string) {
  const parsed = parse(source)
  if (!parsed.ok) throw new Error('parse failed')
  return evalAst(parsed.ast, {})
}

function corpusEntry(id: string) {
  const corpus = JSON.parse(readFileSync(CORPUS_PATH, 'utf-8')) as Array<{
    id: string
    expression: string
    outcome: { status: string; value: unknown }
  }>
  const entry = corpus.find((e) => e.id === id)
  if (!entry) throw new Error(`corpus entry ${id} not found`)
  return entry
}

describe('divergence-prone semantic 1: ASCII-only lower/upper', () => {
  it('lower("CAFÉ") matches the corpus expr-026 expectation, not JS .toLowerCase()', () => {
    const entry = corpusEntry('expr-026')
    const result = evalSource(entry.expression)
    expect(result).toEqual({ ok: true, value: entry.outcome.value })
    expect(entry.outcome.value).toBe('cafÉ')

    // Prove the divergence is real: native JS .toLowerCase() would produce a
    // DIFFERENT, Unicode-aware result for the same input.
    expect('CAFÉ'.toLowerCase()).toBe('café')
    expect('CAFÉ'.toLowerCase()).not.toBe(entry.outcome.value)
  })

  it('upper("café") matches the corpus expr-027 expectation, not JS .toUpperCase()', () => {
    const entry = corpusEntry('expr-027')
    const result = evalSource(entry.expression)
    expect(result).toEqual({ ok: true, value: entry.outcome.value })
    expect(entry.outcome.value).toBe('CAFé')

    expect('café'.toUpperCase()).toBe('CAFÉ')
    expect('café'.toUpperCase()).not.toBe(entry.outcome.value)
  })
})

describe('divergence-prone semantic 2: 4-ASCII-char trim, never Unicode trim', () => {
  it('trim(" \\thi there\\r\\n ") strips exactly the 4 ASCII whitespace chars', () => {
    const entry = corpusEntry('expr-028')
    const result = evalSource(entry.expression)
    expect(result).toEqual({ ok: true, value: 'hi there' })
    expect(entry.outcome.value).toBe('hi there')
  })

  it('leaves a Unicode-whitespace character (NBSP / EM SPACE) in place at either end', () => {
    const nbsp = ' hello '
    const emSpace = ' world '
    expect(evalSource(`trim("${nbsp}")`)).toEqual({ ok: true, value: nbsp })
    expect(evalSource(`trim("${emSpace}")`)).toEqual({ ok: true, value: emSpace })
    // Prove the divergence is real: native JS .trim() WOULD strip these.
    expect(nbsp.trim()).not.toBe(nbsp)
    expect(emSpace.trim()).not.toBe(emSpace)
  })
})

describe('divergence-prone semantic 3: signed-infinity/NaN marker, never native JS Infinity/NaN', () => {
  it('1.0 / 0.0 -> "infinity" (branded string), strictly !== native JS Infinity', () => {
    const result = evalSource('1.0 / 0.0')
    expect(result).toEqual({ ok: true, value: 'infinity' })
    if (result.ok) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expect(result.value as any).not.toBe(Infinity)
      expect(typeof result.value).toBe('string')
    }
    expect(1.0 / 0.0).toBe(Infinity)
  })

  it('-1.0 / 0.0 -> "neg_infinity"', () => {
    expect(evalSource('- 1.0 / 0.0')).toEqual({ ok: true, value: 'neg_infinity' })
  })

  it('0.0 / 0.0 -> "nan", strictly !== native JS NaN', () => {
    const result = evalSource('0.0 / 0.0')
    expect(result).toEqual({ ok: true, value: 'nan' })
    if (result.ok) {
      expect(Number.isNaN(result.value)).toBe(false) // it's the string 'nan', not NaN
    }
  })
})
