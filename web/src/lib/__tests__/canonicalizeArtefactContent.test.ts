/**
 * REQ-381 design §2.1 — cross-language golden-fixture cross-check, TS half.
 *
 * Loads the SAME checked-in fixture file the Elixir-side ExUnit test
 * (`test/letflow/definitions/solution_pack_canonicalize_golden_test.exs`)
 * loads, and asserts `canonicalizeArtefactContent(input) === expected` for
 * every case. `expected` was captured by round-tripping each `input` through
 * the real `Letflow.Definitions.SolutionPack.capture_artefact_bases/5` (see
 * that file's own header comment for how it was generated) — not hand-typed,
 * so this test proves byte-for-byte equivalence against the real algorithm,
 * not against a second guess at what it should produce.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { canonicalizeArtefactContent, type JsonValue } from '../canonicalizeArtefactContent'

const __dirname = dirname(fileURLToPath(import.meta.url))

interface GoldenCase {
  name: string
  input: JsonValue
  expected: string
}

const goldenPath = resolve(__dirname, '..', '..', '..', '..', 'test', 'fixtures', 'canonical_json', 'golden_cases.json')
const goldenCases: GoldenCase[] = JSON.parse(readFileSync(goldenPath, 'utf-8'))

describe('canonicalizeArtefactContent — cross-language golden fixture', () => {
  it('loaded a non-empty golden fixture set', () => {
    expect(goldenCases.length).toBeGreaterThan(0)
  })

  it.each(goldenCases.map((c) => [c.name, c] as const))('%s matches the real Elixir output', (_name, c) => {
    expect(canonicalizeArtefactContent(c.input)).toBe(c.expected)
  })
})

describe('canonicalizeArtefactContent — unit behaviour', () => {
  it('sorts object keys recursively', () => {
    expect(canonicalizeArtefactContent({ b: 1, a: { z: 1, y: 2 } })).toBe('{"a":{"y":2,"z":1},"b":1}')
  })

  it('preserves array element order', () => {
    expect(canonicalizeArtefactContent({ items: [3, 1, 2] })).toBe('{"items":[3,1,2]}')
  })

  it('produces identical output regardless of input key insertion order', () => {
    const a = canonicalizeArtefactContent({ zeta: 1, alpha: 2 })
    const b = canonicalizeArtefactContent({ alpha: 2, zeta: 1 })
    expect(a).toBe(b)
  })
})
