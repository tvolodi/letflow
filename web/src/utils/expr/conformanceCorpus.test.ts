// @vitest-environment node
/**
 * REQ-293 AC1 — reads REQ-289's actual conformance corpus file itself (never a
 * hand-copied subset) and asserts the entry count matches the corpus's own
 * length BEFORE running a single case, so a truncated read cannot pass.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { evaluateExpression } from './index'
import type { InfinityMarker, Value } from './types'

interface CorpusEntry {
  id: string
  description: string
  grammar_constructs: string[]
  expression: string
  variables: Record<string, unknown>
  outcome:
    | { status: 'ok'; value: unknown }
    | { status: 'error'; error_kind: 'parse_failure' | 'eval_failure' }
}

const CORPUS_PATH = join(__dirname, '..', '..', '..', '..', 'priv', 'expr_conformance', 'corpus.json')
const MANIFEST_PATH = join(__dirname, '..', '..', '..', '..', 'priv', 'expr_conformance', 'manifest.json')

function decodeExpectedValue(raw: unknown): Value {
  if (raw && typeof raw === 'object' && '$marker' in (raw as Record<string, unknown>)) {
    return (raw as { $marker: InfinityMarker }).$marker
  }
  return raw as Value
}

describe('REQ-289 conformance corpus (read directly, not hand-copied)', () => {
  const corpusRaw = readFileSync(CORPUS_PATH, 'utf-8')
  const corpus = JSON.parse(corpusRaw) as CorpusEntry[]
  const manifestRaw = readFileSync(MANIFEST_PATH, 'utf-8')
  const manifest = JSON.parse(manifestRaw) as { corpus_schema_version: string; capabilities: string[] }

  it('has exactly 40 entries (a truncated read fails this before any case runs)', () => {
    expect(corpus.length).toBe(40)
  })

  it('manifest capabilities is non-empty (sanity: real file read, not a stub)', () => {
    expect(manifest.capabilities.length).toBeGreaterThan(0)
  })

  for (const entry of corpus) {
    it(`${entry.id}: ${entry.description}`, () => {
      const result = evaluateExpression(entry.expression, entry.variables)

      if (entry.outcome.status === 'ok') {
        expect(result.ok).toBe(true)
        if (result.ok) {
          expect(result.value).toEqual(decodeExpectedValue(entry.outcome.value))
        }
      } else {
        expect(result.ok).toBe(false)
        if (!result.ok) {
          const expectedStage = entry.outcome.error_kind === 'parse_failure' ? 'parse' : 'eval'
          expect(result.stage).toBe(expectedStage)
        }
      }
    })
  }
})
