/**
 * REQ-362 — Two-phase visual regression testing: baseline persistence helpers.
 *
 * Design: lib/letflow/design/req362-visual-regression-testing.md
 *
 * Owns the baseline PNG + sidecar YAML naming convention (design §1), the
 * phase-1 accept action (design §2), and the re-baseline action (design §4).
 * Phase-2 comparison itself is NOT here — it is a direct call to Playwright's
 * own `expect(page).toHaveScreenshot()` at the call site (design §3), driven
 * through `web/playwright.config.ts`'s `snapshotPathTemplate` override so
 * Playwright reads/writes baselines at exactly the path this module computes
 * (design §3.2's "Chosen" option) rather than its own default `-snapshots/`
 * layout.
 *
 * Sidecar files are written as pretty-printed JSON with a `.yaml` extension.
 * This is deliberate, not an oversight: JSON is valid YAML 1.2, so the file
 * is genuinely YAML (readable by any YAML parser, including Elixir's), and
 * this avoids taking a new YAML-parsing dependency into web/ for a single
 * sidecar shape (project's "don't add abstractions the requirement doesn't
 * need yet" rule, CLAUDE.md). Re-derive this call if a general YAML need
 * shows up elsewhere in web/ — it does not exist today (checked
 * package.json: no `yaml`/`js-yaml` dependency).
 */
import * as fs from 'fs'
import * as path from 'path'
import * as crypto from 'crypto'
import { fileURLToPath } from 'url'

const THIS_DIR = path.dirname(fileURLToPath(import.meta.url))
/** repo root, resolved from this file's location (web/tests/support/) */
const REPO_ROOT = path.resolve(THIS_DIR, '..', '..', '..')
const DEFAULT_BASELINE_ROOT = path.join(REPO_ROOT, 'test', 'fixtures', 'uat', 'visual-baselines')

/**
 * `test/fixtures/uat/visual-baselines/` is committed, durable fixture data
 * (design §1.3) — a real accept/re-baseline there is meant to persist across
 * runs. A formal regression-test suite that calls `acceptBaseline`/
 * `rebaseline` on every CI invocation must NOT write through to that real
 * tree, or every run would rewrite committed PNGs/sidecar timestamps and
 * leave the working tree permanently dirty (found during REQ-362 TEST-DESIGNER
 * review, WF02-REQ362-20260916 — the original real-exercise spec did exactly
 * this against its own real evidence directory, which is fine for the
 * one-time manual proof run it was, but not for an every-CI-run formal
 * suite). `__setBaselineRootForTests` is a test-only escape hatch — mutable
 * module state read lazily by every path/exists/accept/rebaseline call below,
 * never called by production code (UAT-RUNNER at runtime always uses the
 * default). Test code must call `__resetBaselineRootForTests()` (or
 * re-invoke this with the default) once done, since the override is
 * process/module-global for the life of the test worker.
 */
let BASELINE_ROOT = DEFAULT_BASELINE_ROOT

export function __setBaselineRootForTests(root: string): void {
  BASELINE_ROOT = root
}

export function __resetBaselineRootForTests(): void {
  BASELINE_ROOT = DEFAULT_BASELINE_ROOT
}

export interface BaselineKey {
  companyId: string
  scenarioId: string
  step: number
  eoId: string
  environment: string
}

export interface AcceptProvenance {
  acceptedBy: string
  acceptedInRun: string
  judgmentDetail: string
  sourceScreenshotPath: string
}

export interface RebaselineEntry {
  rebaselinedBy: string
  rebaselinedInRun: string
  justification: string
  relatedIssueRef: string | null
}

interface Sidecar {
  scenario_id: string
  company_id: string
  step: number
  expected_outcome_id: string
  environment: string
  accepted_by: string
  accepted_in_run: string
  accepted_at: string
  judgment_detail: string
  source_screenshot: string
  history: Array<{
    rebaselined_by: string
    rebaselined_in_run: string
    rebaselined_at: string
    justification: string
    superseded_baseline_hash: string
    related_issue_ref: string | null
  }>
}

function pad2(n: number): string {
  return String(n).padStart(2, '0')
}

/** design §1.1's `<step>-<eo_id>.<environment>` stem, without extension. */
function stem(key: BaselineKey): string {
  return `${pad2(key.step)}-${key.eoId}.${key.environment}`
}

/**
 * The relative "name" to pass to `expect(page).toHaveScreenshot(name)` so
 * that, combined with playwright.config.ts's `snapshotPathTemplate`, the
 * comparison reads/writes exactly the design §1.1 path. Includes `.png` —
 * `{arg}` in the template strips it back off and `{ext}` re-adds it, so the
 * final resolved path is unchanged either way.
 */
export function snapshotName(key: BaselineKey): string[] {
  // Playwright's snapshotPathTemplate only treats "/" as a directory
  // separator in {arg} when the name is passed as an array of segments —
  // a single string containing "/" gets sanitized into one flattened
  // filename instead (verified live against the installed 1.60.0 API:
  // a string name produced
  // `platform-req362-visual-regression-selfcheck-01-EO-001-local.png` in one
  // flat file, not the nested tree design §1.1 requires). So this returns
  // the array form.
  return [key.companyId, key.scenarioId, `${stem(key)}.png`]
}

export function baselinePngPath(key: BaselineKey): string {
  return path.join(BASELINE_ROOT, key.companyId, key.scenarioId, `${stem(key)}.png`)
}

export function baselineSidecarPath(key: BaselineKey): string {
  return path.join(BASELINE_ROOT, key.companyId, key.scenarioId, `${stem(key)}.yaml`)
}

export function baselineExists(key: BaselineKey): boolean {
  return fs.existsSync(baselinePngPath(key))
}

function ensureDir(filePath: string): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
}

function utcNow(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
}

function readSidecar(key: BaselineKey): Sidecar {
  const raw = fs.readFileSync(baselineSidecarPath(key), 'utf8')
  return JSON.parse(raw) as Sidecar
}

function writeSidecar(key: BaselineKey, data: Sidecar): void {
  const p = baselineSidecarPath(key)
  ensureDir(p)
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + '\n', 'utf8')
}

function sha256File(filePath: string): string {
  const buf = fs.readFileSync(filePath)
  return crypto.createHash('sha256').update(buf).digest('hex')
}

/**
 * Phase 1 accept action (design §2.2). Never called when a baseline already
 * exists for this key — callers must check `baselineExists` first (design
 * §2.2 step 4: an existing baseline routes to phase 2, never a silent
 * overwrite here).
 *
 * Data-sensitivity precondition (design §1.5): callers must only invoke this
 * against a screenshot captured from a screen seeded with synthetic/
 * disclosed-fictional actor and tenant data — never real tenant PII. This is
 * not something this function can check from the PNG bytes; it is the
 * caller's (scenario author's / accepting agent's) responsibility.
 */
export function acceptBaseline(key: BaselineKey, sourcePngPath: string, prov: AcceptProvenance, runId: string): void {
  if (baselineExists(key)) {
    throw new Error(
      `acceptBaseline called but a baseline already exists at ${baselinePngPath(key)} — ` +
        'this is re-baseline territory (design §2.2 step 4), not accept. Use rebaseline() instead.',
    )
  }
  const dest = baselinePngPath(key)
  ensureDir(dest)
  fs.copyFileSync(sourcePngPath, dest)

  writeSidecar(key, {
    scenario_id: key.scenarioId,
    company_id: key.companyId,
    step: key.step,
    expected_outcome_id: key.eoId,
    environment: key.environment,
    accepted_by: prov.acceptedBy,
    accepted_in_run: runId,
    accepted_at: utcNow(),
    judgment_detail: prov.judgmentDetail,
    source_screenshot: prov.sourceScreenshotPath,
    history: [],
  })
}

/**
 * Re-baseline action (design §4.3). Requires an existing baseline and a
 * non-blank, non-generic `justification`. Appends to the sidecar's
 * append-only `history` list and overwrites the baseline PNG.
 *
 * Data-sensitivity precondition (design §1.5): same as `acceptBaseline` —
 * the replacement screenshot must be synthetic/disclosed-fictional data
 * only, never real tenant PII. Not enforceable from the PNG bytes here.
 */
export function rebaseline(key: BaselineKey, newPngPath: string, entry: RebaselineEntry): void {
  if (!baselineExists(key)) {
    throw new Error(`rebaseline called but no baseline exists yet at ${baselinePngPath(key)} — use acceptBaseline first.`)
  }
  const justification = entry.justification.trim()
  const GENERIC = ['looks fine now', 'looks fine', 'ok', 'fine', 'accept', 'lgtm', '']
  if (justification.length < 15 || GENERIC.includes(justification.toLowerCase())) {
    throw new Error(
      `rebaseline requires a real justification naming the requirement/change that caused the visual change ` +
        `(design §4.3) — got: ${JSON.stringify(entry.justification)}`,
    )
  }

  const dest = baselinePngPath(key)
  const supersededHash = sha256File(dest)

  const sidecar = readSidecar(key)
  sidecar.history.push({
    rebaselined_by: entry.rebaselinedBy,
    rebaselined_in_run: entry.rebaselinedInRun,
    rebaselined_at: utcNow(),
    justification,
    superseded_baseline_hash: supersededHash,
    related_issue_ref: entry.relatedIssueRef,
  })

  fs.copyFileSync(newPngPath, dest)
  writeSidecar(key, sidecar)
}

export function readSidecarForTest(key: BaselineKey): unknown {
  return readSidecar(key)
}
