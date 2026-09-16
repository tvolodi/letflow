/**
 * Unit tests — REQ-362 `web/tests/support/visual-baseline.ts` (baseline
 * persistence helpers: accept action, re-baseline action, sidecar shape).
 *
 * Design: lib/letflow/design/req362-visual-regression-testing.md §2/§4.
 *
 * Why this file exists alongside `web/tests/e2e/req362-visual-regression.e2e.spec.ts`:
 * that spec is the real-exercise PROOF against a live page (Playwright's
 * actual `toHaveScreenshot()` pixel comparison, AC-2/AC-3/AC-5). This file
 * covers the PURE logic in `visual-baseline.ts` — no browser needed, so it
 * runs as part of `npm test` (vitest) on every CI invocation, fast, and
 * against a disposable temp directory via `__setBaselineRootForTests` rather
 * than the real committed baseline tree, so it is safe to re-run without
 * mutating durable fixture data.
 *
 * Runs each of these against a concrete, plausible wrong implementation
 * (stated per case) so they are real falsifiable claims, not tautologies.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import * as crypto from 'crypto'
import {
  acceptBaseline,
  baselineExists,
  baselinePngPath,
  baselineSidecarPath,
  rebaseline,
  readSidecarForTest,
  snapshotName,
  __setBaselineRootForTests,
  __resetBaselineRootForTests,
  type BaselineKey,
} from '../support/visual-baseline'

const KEY: BaselineKey = {
  companyId: 'platform',
  scenarioId: 'unit-test-scenario',
  step: 1,
  eoId: 'EO-001',
  environment: 'local',
}

let tmpRoot: string

function writePng(name: string, bytes: number[] = [1, 2, 3, 4]): string {
  const p = path.join(tmpRoot, name)
  fs.writeFileSync(p, Buffer.from(bytes))
  return p
}

beforeEach(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'req362-visual-baseline-unit-'))
  __setBaselineRootForTests(tmpRoot)
})

afterEach(() => {
  __resetBaselineRootForTests()
  fs.rmSync(tmpRoot, { recursive: true, force: true })
})

describe('REQ-362 visual-baseline.ts — path/naming (AC-1)', () => {
  it('snapshotName returns the [company, scenario, stem.png] segments Playwright needs as an array', () => {
    // Would fail against an implementation that returns a single joined
    // string (the exact prior bug this module's own comment documents —
    // Playwright flattens a string into one filename instead of nested dirs).
    expect(snapshotName(KEY)).toEqual(['platform', 'unit-test-scenario', '01-EO-001.local.png'])
  })

  it('baselinePngPath and baselineSidecarPath are keyed to company+scenario+step+EO+environment, zero-padded', () => {
    const png = baselinePngPath(KEY)
    const sidecar = baselineSidecarPath(KEY)
    expect(png.endsWith(path.join('platform', 'unit-test-scenario', '01-EO-001.local.png'))).toBe(true)
    expect(sidecar.endsWith(path.join('platform', 'unit-test-scenario', '01-EO-001.local.yaml'))).toBe(true)
    // Step 1 must render as "01", not "1" — would fail against an
    // implementation that skips zero-padding, breaking lexical ordering past
    // step 9 (design §1.1).
    expect(png).toContain('01-EO-001')
  })

  it('a different environment produces a distinct path (AC-1: keyed to environment too)', () => {
    const other: BaselineKey = { ...KEY, environment: 'qa' }
    expect(baselinePngPath(KEY)).not.toBe(baselinePngPath(other))
  })
})

describe('REQ-362 visual-baseline.ts — accept action (AC-2)', () => {
  it('accepts a first baseline: copies the PNG and writes a sidecar with empty history', () => {
    expect(baselineExists(KEY)).toBe(false)
    const src = writePng('captured.png')

    acceptBaseline(
      KEY,
      src,
      { acceptedBy: 'TEST-DESIGNER', acceptedInRun: 'unit-test-run', judgmentDetail: 'looks correct', sourceScreenshotPath: src },
      'unit-test-run',
    )

    expect(baselineExists(KEY)).toBe(true)
    const sidecar = readSidecarForTest(KEY) as {
      accepted_by: string
      history: unknown[]
      judgment_detail: string
    }
    expect(sidecar.accepted_by).toBe('TEST-DESIGNER')
    expect(sidecar.judgment_detail).toBe('looks correct')
    // Would fail against an implementation that pre-seeds history with a
    // phantom entry, or omits the field entirely (design §2.3: "empty on
    // first accept").
    expect(sidecar.history).toEqual([])
  })

  it('rejects a second accept when a baseline already exists — this is re-baseline territory, not accept (design §2.2 step 4)', () => {
    const src = writePng('captured.png')
    acceptBaseline(KEY, src, { acceptedBy: 'A', acceptedInRun: 'r1', judgmentDetail: 'ok', sourceScreenshotPath: src }, 'r1')

    // Would fail (silently overwrite, corrupting audit trail) against an
    // implementation that lets accept double as an unconditional overwrite —
    // exactly the "backdoor around phase 2" the design's §2.2 step 4
    // explicitly forbids.
    expect(() =>
      acceptBaseline(KEY, src, { acceptedBy: 'B', acceptedInRun: 'r2', judgmentDetail: 'ok again', sourceScreenshotPath: src }, 'r2'),
    ).toThrow(/already exists/)

    // And the original provenance must be untouched by the rejected call.
    const sidecar = readSidecarForTest(KEY) as { accepted_by: string }
    expect(sidecar.accepted_by).toBe('A')
  })
})

describe('REQ-362 visual-baseline.ts — re-baseline action (AC-5)', () => {
  it('rejects rebaseline when no baseline exists yet — must accept first', () => {
    const src = writePng('new.png')
    expect(() =>
      rebaseline(KEY, src, { rebaselinedBy: 'X', rebaselinedInRun: 'r1', justification: 'a real justification text here', relatedIssueRef: null }),
    ).toThrow(/no baseline exists/)
  })

  it.each(['', 'ok', 'fine', 'lgtm', 'LGTM', 'looks fine now', 'Looks Fine', 'accept', '   '])(
    'rejects a blank/generic justification: %j',
    (bad) => {
      const src = writePng('base.png')
      acceptBaseline(KEY, src, { acceptedBy: 'A', acceptedInRun: 'r1', judgmentDetail: 'ok', sourceScreenshotPath: src }, 'r1')
      const newShot = writePng('altered.png', [9, 9, 9])

      // Each of these strings is a plausible real rubber-stamp an agent might
      // type under time pressure — would fail against an implementation that
      // only checks the exact literal "looks fine now" the module's own
      // negative test in the e2e spec exercises, missing the rest of the
      // GENERIC list or the length/whitespace check.
      expect(() =>
        rebaseline(KEY, newShot, { rebaselinedBy: 'X', rebaselinedInRun: 'r1', justification: bad, relatedIssueRef: null }),
      ).toThrow(/real justification/)
    },
  )

  it('accepts a real, specific justification and appends (never overwrites) sidecar history', () => {
    const src = writePng('base.png', [1, 1, 1])
    acceptBaseline(KEY, src, { acceptedBy: 'A', acceptedInRun: 'r1', judgmentDetail: 'ok', sourceScreenshotPath: src }, 'r1')

    const firstPngBytes = fs.readFileSync(baselinePngPath(KEY))

    const newShot1 = writePng('altered1.png', [2, 2, 2])
    rebaseline(KEY, newShot1, {
      rebaselinedBy: 'X',
      rebaselinedInRun: 'r2',
      justification: 'REQ-999 changed the header layout intentionally; new baseline reflects that',
      relatedIssueRef: 'ISS-9001',
    })

    const newShot2 = writePng('altered2.png', [3, 3, 3])
    rebaseline(KEY, newShot2, {
      rebaselinedBy: 'Y',
      rebaselinedInRun: 'r3',
      justification: 'REQ-998 changed the footer copy intentionally; new baseline reflects that',
      relatedIssueRef: null,
    })

    const sidecar = readSidecarForTest(KEY) as {
      history: Array<{ justification: string; related_issue_ref: string | null; superseded_baseline_hash: string }>
    }
    // Would fail against an implementation that overwrites history[0] on the
    // second rebaseline instead of appending — the append-only discipline
    // design §4.3 requires, same as the requirement-status volumes.
    expect(sidecar.history).toHaveLength(2)
    expect(sidecar.history[0].related_issue_ref).toBe('ISS-9001')
    expect(sidecar.history[1].related_issue_ref).toBeNull()
    // The first rebaseline's recorded superseded hash must be the hash of
    // the PNG that existed *before* it overwrote it (the original accept),
    // not the hash of its own replacement.
    expect(sidecar.history[0].superseded_baseline_hash).toBe(
      crypto.createHash('sha256').update(firstPngBytes).digest('hex'),
    )

    // Final on-disk PNG is the *second* rebaseline's content.
    expect(fs.readFileSync(baselinePngPath(KEY))).toEqual(Buffer.from([3, 3, 3]))
  })
})

describe('REQ-362 visual-baseline.ts — malformed/edge fixture states', () => {
  it('a malformed (non-JSON) sidecar surfaces a real parse error on rebaseline rather than silently proceeding', () => {
    const src = writePng('base.png')
    acceptBaseline(KEY, src, { acceptedBy: 'A', acceptedInRun: 'r1', judgmentDetail: 'ok', sourceScreenshotPath: src }, 'r1')

    // Corrupt the sidecar in place — simulates a hand-edited or partially
    // written YAML/JSON sidecar file on disk.
    fs.writeFileSync(baselineSidecarPath(KEY), 'not: [valid, json,,,', 'utf8')

    const newShot = writePng('altered.png', [7, 7, 7])
    // Would fail (silently write a new baseline PNG with no readable
    // provenance, or crash with an unhelpful stack trace) against an
    // implementation that does not read/validate the existing sidecar before
    // appending to its history.
    expect(() =>
      rebaseline(KEY, newShot, { rebaselinedBy: 'X', rebaselinedInRun: 'r2', justification: 'a real justification text here', relatedIssueRef: null }),
    ).toThrow()
  })

  it('baselineExists is false for a key whose PNG was never accepted, even if a stray sidecar-shaped file exists elsewhere', () => {
    // Write a sidecar-looking file WITHOUT ever calling acceptBaseline (no
    // PNG) — baselineExists must key off the PNG, not the sidecar, since the
    // PNG is what phase 2's comparison actually reads (design §1.3).
    fs.mkdirSync(path.dirname(baselineSidecarPath(KEY)), { recursive: true })
    fs.writeFileSync(baselineSidecarPath(KEY), '{}', 'utf8')
    expect(baselineExists(KEY)).toBe(false)
  })
})
