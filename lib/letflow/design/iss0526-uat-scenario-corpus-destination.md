# ISS-0526 — Destination, format, and UAT-RUNNER consumption of R-Co's real
# narrative UAT scenario corpus

**Issue:** ISS-0526 (correctly-scoped successor to ISS-0393; related ISS-0388,
REQ-206/207/208, github #1062).
**Stage:** S7 (`docs/migration/stage-7-simulation-uat-parity.md`).
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV.
**Depends on:** REQ-205's harness (`test/support/simulation/{seed,runner}.ex`),
REQ-206/207/208's disclosed-synthetic fixtures (`test/fixtures/simulation/`), ISS-0388's
porting precedent and header convention.

**Provenance for everything ported under this design:** R-Co,
`https://github.com/tvolodi/R-Co`, commit `d19bfec4a9ec492345346bfccd8e389bd9cd92db`.
No local filesystem path to any R-Co clone is to appear in any file this design
produces — cite the URL+sha only, same discipline as ISS-0388.

---

## §0 — Verified source-of-truth facts

Read directly from the R-Co clone at the pinned commit (URL+sha above), not assumed:

- **`tests/simulation/scenarios/*.yaml`** — 11 files, confirmed: 4 SwiftRoute
  (`swiftroute-tenant-onboarding-happy`, `swiftroute-shipment-high-value-happy`,
  `swiftroute-shipment-ops-timeout-escalation`, `swiftroute-shipment-attach-delivery-note`),
  4 Vortex (`vortex-production-order-above-threshold`,
  `vortex-supplier-quality-deviation-critical`,
  `vortex-supplier-quality-deviation-false-positive`,
  `vortex-entity-list-filter-and-page`), 3 Meridian
  (`meridian-loan-origination-above-threshold`, `meridian-loan-origination-below-threshold`,
  `meridian-regulatory-compliance-review-bafin`).
- **`tests/simulation/scenarios/platform/*.yaml`** — **18 files**, not "~15" as this
  issue's own task framing estimated. Confirmed by direct `find` against the pinned
  commit and cross-checked against `docs/migration/stage-7-simulation-uat-parity.md`'s
  own already-recorded inventory (REQ-210, verified 2026-09-02), which lists all 18 by
  name and confirms each carries `platform_workflow: PW-NN` and `company_id: platform`.
  This design corrects the task-framing count; §4 below addresses scope.
- **Real shape, confirmed by reading full file bodies** (not excerpts) of
  `swiftroute-shipment-attach-delivery-note.yaml`,
  `vortex-supplier-quality-deviation-critical.yaml`, and
  `platform-tenant-branding-applied.yaml`: every file carries `id`, `company_id`,
  `process_id`, `title`, `version`, `tags`, a prose `description:`, an `actors:` map
  (role → `actor-<company>-<name>` id), `preconditions:` (each with `description:` +
  `check:` naming a check-kind, sometimes `check: custom` with a prose `detail:`),
  `steps:` (each with `step:`, `actor:`, prose `action:`, `via: gui|api`, optional
  `input:`, optional `produces:` naming what evidence the step yields in prose, optional
  `sla_context:`), `expected_outcomes:` (each with `id`, prose `description:`, a
  `verification:` block with `method:` — observed values `gui_screen`, `audit_event`,
  `task_assigned`, `instance_state` — plus prose `detail:` and, for `gui_screen`
  outcomes, prose `evidence:` naming what screenshot/observation proves the outcome, and
  an `on_fail:` block with `severity`, prose `business_impact:`, `suggested_action:`),
  and a `cleanup:` block. **None of these fields are machine-executable** — no step
  carries a `params` map for an HTTP client to send verbatim, no verification carries an
  `args` map for a query function to dispatch. This confirms ISS-0526's own premise:
  this format is written for a reader (human or an agent standing in for one) to
  interpret and perform, not for `Letflow.Simulation.Runner.run/1` to execute.
- **`pipeline_test:` field — present in exactly 3 of the 11 named scenarios**
  (`swiftroute-shipment-attach-delivery-note.yaml` →
  `web/tests/e2e/pipelines/shipment-attach-delivery-note.pipeline.e2e.spec.ts`;
  `swiftroute-tenant-onboarding-happy.yaml` →
  `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts`;
  `vortex-entity-list-filter-and-page.yaml` →
  `web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts`), plus 7 of the 18
  platform scenarios (out of this pass's scope per §4).
- **Cross-check against R-Co's own `web/tests/e2e/pipelines/` directory** (same pinned
  commit): it contains exactly 4 files — `sim-company-onboarding.pipeline.e2e.spec.ts`,
  `sim-admin-processes.pipeline.e2e.spec.ts`, `onboarding-wizard.pipeline.e2e.spec.ts`,
  `admin-user-lifecycle.pipeline.e2e.spec.ts`. These are the same 4 filenames that exist
  in letflow's own `web/tests/e2e/pipelines/` today (confirmed by directory listing).
  So:
  - `onboarding-wizard.pipeline.e2e.spec.ts` (referenced by
    `swiftroute-tenant-onboarding-happy.yaml`) **exists in both R-Co's own web/ tree and
    letflow's** — already ported, already resolvable. This matches
    `docs/migration/stage-7-simulation-uat-parity.md`'s own REQ-210 sign-off entry,
    which already states this file is "confirmed present in `web/` but not yet
    exercised."
  - `shipment-attach-delivery-note.pipeline.e2e.spec.ts` and
    `entity-list-query.pipeline.e2e.spec.ts` **do not exist in R-Co's own web/ tree
    either** — these are not unported R-Co frontend files waiting to be copied; they are
    references to Playwright specs that were never written in R-Co itself, gated on
    frontend features (document/attachment upload; entity list/filter/paging) that
    §0's earlier stage-7 findings already record as `UNBUILT_FEATURE` /
    `BLOCKED_ON_DEPENDENCY` on the backend side. Porting them is not a smaller
    file-copy job hiding in this issue's scope — it would mean *authoring new
    Playwright specs from scratch* against features that don't exist yet in either
    codebase, which is FRONTEND-DEV/backend work gated on other requirements, not a
    fixture-porting task.

---

## §1 — Decision 1: destination location and format

**Location:** `test/fixtures/uat/scenarios/<company>/*.yaml`, one subdirectory per
company (`swiftroute/`, `vortex/`, `meridian/`), each holding that company's named
files with `-`-joined basenames unchanged except for the company prefix already being
implied by the directory (mirrors `test/fixtures/simulation/<company>/scenarios/`'s
existing directory shape, so the two corpora read as siblings under `test/fixtures/`,
distinguished only by the top-level `simulation/` vs `uat/` segment). Concrete mapping,
one example per company:

- `swiftroute-shipment-high-value-happy.yaml` (R-Co) →
  `test/fixtures/uat/scenarios/swiftroute/shipment-high-value-happy.yaml` (letflow)
- `vortex-supplier-quality-deviation-critical.yaml` (R-Co) →
  `test/fixtures/uat/scenarios/vortex/supplier-quality-deviation-critical.yaml`
- `meridian-regulatory-compliance-review-bafin.yaml` (R-Co) →
  `test/fixtures/uat/scenarios/meridian/regulatory-compliance-review-bafin.yaml`

**Rejected alternatives, with reasons:**

- `docs/uat/scenarios/` — rejected. This content is a test input consumed by an agent
  role during a workflow step, exactly the same category of artifact as
  `test/fixtures/simulation/**/*.yaml`, not narrative documentation *about* the
  project. `docs/` is for prose describing decisions/requirements/status, not raw
  fixture data an agent reads and acts on line-by-line. Putting it under `docs/`
  would also put it in scope for REQ-VALIDATOR/DOC-UPDATER-style doc-consistency
  sweeps it has no business being subject to.
- `test/uat-reports/scenarios/` — this is WF-05's own tentative guess
  (`docs/agents/workflows/WF-05_uat_run.md` Step 1, "or wherever S7's own requirements
  land it"), rejected on inspection: `test/uat-reports/` is UAT-RUNNER's **output**
  directory (`test/uat-reports/uat-<date>-<run-id>.yaml`, one file per run). Mixing a
  static input corpus into the same directory as dated run-output files invites an
  accidental `rm`/glob operation on run cleanup to catch the corpus, and makes `ls
  test/uat-reports/` produce a confusing mix of "things UAT-RUNNER wrote" and "things
  UAT-RUNNER reads." Input and output belong in visibly distinct trees.
- `test/fixtures/simulation/<company>/scenarios/` (same directory as the existing
  synthetic files, different filenames) — rejected. ISS-0526's own acceptance criteria
  require the existing synthetic fixtures to stay "completely untouched," and while
  same-directory-different-filename wouldn't literally touch those files' *content*,
  it would make `ls` on that directory return two fundamentally different kinds of
  artifact (machine-executable-shape synthetic fixtures for `Letflow.Simulation.Runner`
  vs. narrative prose for a human/agent reader) with no signal in the path itself to
  tell them apart. A distinct `test/fixtures/uat/` top-level segment makes the two
  corpora's different consumers and different shape visible from the path alone,
  exactly the distinction ISS-0526's own description asks for ("a new
  `test/fixtures/uat/` or `docs/uat/` location distinct from `test/fixtures/simulation/`").

**Format: byte-identical port, plus a leading YAML-comment provenance header —
not a wrapper.** Every field, key, and value below the header comment block is copied
verbatim from the R-Co source file — no field renaming, no schema translation (unlike
`test/fixtures/simulation/<company>/company.yaml`'s ISS-0388-era port, which *did* need
to translate into `Letflow.Simulation.Seed`'s narrower schema; this format has no
Letflow-side consumer schema to translate into, since UAT-RUNNER reads it as prose, not
as typed input to a function — see §2). The header block, prepended before the YAML
document's `---` line, follows the same convention already established by ISS-0388's
port (`test/fixtures/simulation/swiftroute/company.yaml`'s header) and REQ-206's
disclosed-synthetic header, adapted for "this IS the real thing" instead of "this is a
disclosed synthetic stand-in":

```
# Ported verbatim from R-Co tests/simulation/scenarios/<real-filename>.yaml
# (https://github.com/tvolodi/R-Co, commit d19bfec4a9ec492345346bfccd8e389bd9cd92db).
# Byte-identical below this header except for this comment block itself and the
# pipeline_test annotation noted below, if present. Read by UAT-RUNNER as a narrative
# scenario script (prose action/detail/evidence fields) -- NOT consumed by
# Letflow.Simulation.Runner.run/1, which requires the differently-shaped, disclosed-
# synthetic fixtures under test/fixtures/simulation/<company>/scenarios/ instead. Do
# not edit the ported content below except to keep it byte-identical to a re-pull of
# the same commit.
```

Every ported file carries this same header (only the filename in line 1 changes),
naming the exact R-Co source path and the fixed commit sha so a future diff against a
newer R-Co commit is mechanical. This is a comment block, not a structural wrapper —
the YAML document itself (starting at `---`) is untouched, so no reader (human or
UAT-RUNNER) needs a different parser than "read this YAML file" plus "skip the leading
`#` lines."

---

## §2 — Decision 2: `pipeline_test:` field handling

**Keep the field, annotate it, do not strip it — but only for the one file where it
already resolves; for the two that don't, add an explicit non-resolving note.**

Per §0's findings: `pipeline_test:` names a genuinely different resource per file, so
this is not a single blanket policy — it is three files needing two different
treatments.

- **`swiftroute-tenant-onboarding-happy.yaml`** — `pipeline_test:` points at
  `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts`, which **exists**
  in letflow's own `web/` tree today. Keep the field verbatim, plus the R-Co
  source file's own explanatory comment ("UAT-RUNNER drives this Playwright pipeline
  test for all steps...") verbatim below it — both are already accurate for letflow as
  written, no change needed. `docs/migration/stage-7-simulation-uat-parity.md`'s own
  REQ-210 sign-off already records this file as present-but-not-yet-exercised (S8
  integration work not yet landed against it) — this design changes nothing about that
  status, it just makes the pointer resolvable once UAT-RUNNER is dispatched against a
  live instance with `web/` wired in.
- **`swiftroute-shipment-attach-delivery-note.yaml`** and
  **`vortex-entity-list-filter-and-page.yaml`** — `pipeline_test:` points at a spec
  file that does not exist in R-Co's own `web/` tree either (§0), gated on backend
  features already recorded elsewhere as `UNBUILT_FEATURE`
  (`swiftroute-shipment-attach-delivery-note`, ISS-0390-class) and
  `BLOCKED_ON_DEPENDENCY` (`vortex-entity-list-filter-and-page`, on
  `Letflow.Routers.Entities`). **Do not silently strip the field** — that would erase
  the information that a GUI-driven UAT path was always intended for this scenario.
  Instead, append one comment line directly below the `pipeline_test:` key in the
  ported file:
  ```
  # NOTE (ISS-0526): this spec file does not exist in R-Co's own web/ tree at the
  # pinned commit either -- it is an aspirational forward-reference to a Playwright
  # test that was never authored anywhere, gated on the same missing feature this
  # scenario's own steps exercise. UAT-RUNNER cannot drive this pipeline_test yet;
  # treat any run of this scenario as BLOCKED/UNBUILT_FEATURE on the frontend leg
  # until FRONTEND-DEV authors it against a real shipped feature.
  ```
  This preserves the field (so nothing is dropped) while making it unambiguous to a
  future UAT-RUNNER invocation that following the pointer will fail, and why — matching
  this project's "no silent re-decision, no silent drop" discipline
  (`docs/anti-patterns.md`, `core-directives.md`).

No file's `pipeline_test:` field is deleted under this design.

---

## §3 — Decision 3: UAT-RUNNER instruction update

Two edits to `.claude/agents/uat-runner.md`:

**Edit A — replace the "location TBD" line** (current line 18):

```
- The scenario corpus for the stage under test (location TBD by S7's own requirements —
  see `docs/migration/stage-7-simulation-uat-parity.md`)
```

with:

```
- The scenario corpus for the stage under test —
  `test/fixtures/uat/scenarios/<company>/*.yaml` (11 files: 4 SwiftRoute, 4 Vortex, 3
  Meridian; a `platform/` subdirectory covering an additional 18 platform-level
  scenarios is deferred, see `docs/migration/stage-7-simulation-uat-parity.md`'s own
  scope note and ISS-0526's design doc §4). Ported verbatim from R-Co
  (`https://github.com/tvolodi/R-Co`) at the commit named in each file's own header
  comment.
```

**Edit B — add a new subsection distinguishing this corpus's shape from
`Letflow.Simulation.Runner`'s**, inserted after the existing "What you do" section:

```
## Reading the scenario corpus

Each scenario file is narrative, not machine-executable: `steps[].action` is prose
describing what a person does, `preconditions[].detail`/`expected_outcomes[].detail`
and `.evidence` are prose describing what to check and what proves it, not a `params`
or `args` map for a function to dispatch. This is a deliberately different format from
`Letflow.Simulation.Runner`'s fixtures under `test/fixtures/simulation/<company>/
scenarios/*.yaml`, which DO carry machine-executable `params`/`args` and are consumed
by `Letflow.Simulation.Runner.run/1` in the test suite, not by you — do not confuse the
two corpora or assume either supersedes the other (`docs/issues/ISS-0526.yaml`'s own
scope note (5) is explicit that they remain separate artifacts serving separate test
layers).

Read each narrative field as an instruction to *you*: perform the `action` for real
(real HTTP call, or real GUI interaction via `pipeline_test:` once wired in), then
check the state described in each `expected_outcomes[].detail`/`.evidence` against the
real running instance, same discipline as your "no mocks, no absence-of-error as pass"
rule above. A `pipeline_test:` key names a Playwright spec to drive for GUI-only
scenarios; if that file does not exist or carries a `NOTE (ISS-0526)` comment marking
it unresolved, record the scenario BLOCKED/UNBUILT_FEATURE on its frontend leg rather
than skipping it silently or inventing a substitute API-only path.
```

No other passage in `uat-runner.md` needs updating — the "no mocks," "record actual
observed evidence," and "don't invent scenario coverage" rules already apply correctly
to this format as written.

`docs/agents/workflows/WF-05_uat_run.md` Step 1's line 2 ("or wherever S7's own
requirements land it") should also be tightened to name the resolved path directly,
since it currently reads as still-open:

```
2. Confirm the scenario corpus for this stage exists under
   `test/fixtures/uat/scenarios/<company>/*.yaml` (see `.claude/agents/uat-runner.md`
   and ISS-0526's design doc for the full shape).
```

---

## §4 — Decision 4: scope for this issue's implementation pass

**In scope for this pass: the 11 named tenant-business scenario files only**
(4 SwiftRoute + 4 Vortex + 3 Meridian). **Out of scope: the 18-file `platform/`
subdirectory** — recommend a follow-up issue.

Justification:

- ISS-0526's own task description and acceptance-criteria framing (per the handoff:
  "destination determined, real content ported verbatim, existing synthetic fixtures
  confirmed untouched") names the 11 files by tenant/count explicitly and treats the
  `platform/` corpus as something to "confirm exists," not something to port in the
  same pass.
- `docs/migration/stage-7-simulation-uat-parity.md` has **already made this exact
  scoping decision once**, independently, for REQ-210: the platform corpus is recorded
  as "explicitly out of scope for this batch," with the reasoning that it is a
  different-origin scenario set (platform-operator/cross-tenant concerns — migration
  safety, outbox backpressure, tenant-isolation probes — rather than a single tenant's
  business workflow) that "was never named in ORCH's own scoping of this batch" and
  should be "sized as its own batch when S7 is revisited or extended." Silently folding
  18 more files into this pass would re-decide a scope boundary the project has already
  recorded once, which `core-directives.md`'s "don't silently re-decide what a decision
  record already settled" rule advises against without a fresh REVIEWER sign-off.
- Practically, the platform corpus is a different-shaped verification job: 7 of its 18
  files carry `pipeline_test:` references that need the same three-way existence check
  §0 did for the 11 named files (does the spec exist in R-Co's web/ tree, does it exist
  in letflow's), and several (`platform-sandbox-cross-tenant-probe`,
  `platform-attachment-cross-tenant-probe`) plausibly touch security-invariant
  territory (`docs/agents/instructions/security-invariants.md`) that would want
  SECURITY-REVIEWER's eyes on the port, not just CODE-DESIGN-VALIDATOR's. Sizing that
  properly is its own design pass, not a rider on this one.

**Recommended follow-up issue** (to be filed by ORCH at Step Final, not by this
design): "Port R-Co's 18-file `tests/simulation/scenarios/platform/*.yaml`
platform-operator UAT corpus," `related: [ISS-0526, REQ-210]`, scoped to repeat this
design's §0-§3 process (inventory `pipeline_test:` resolution per file, same header
convention, same `test/fixtures/uat/scenarios/platform/` destination) against the
18-file set, flagging the 2 cross-tenant-probe files for SECURITY-REVIEWER attention
specifically.

---

## §5 — Decision 5: what "confirmed able to consume it" means for this pass

**Structural verification is sufficient for this pass. A real UAT-RUNNER dry-run
against a live instance is explicitly NOT required as part of this issue's
implementation, and should not be attempted as a way to over-deliver.**

Justification:

- This project's "no speculation, run it for real" directive
  (`core-directives.md`) governs claims about *behavior* — "the code works," "the test
  passes." It does not require every fixture-porting change to be exercised
  end-to-end the moment it lands, when the thing being changed is test-input data, not
  code or behavior. The analogous precedent is REQ-205/206/207/208's own scenario work:
  each of those requirements DID run their scenarios for real against a live
  instance — but that was those requirements' own stated purpose (S7's own
  correctness-gate work), not a porting task's purpose. ISS-0526 is scoped as "port the
  real content and confirm UAT-RUNNER can consume it," not "re-run S7's UAT gate,"
  and folding a full live UAT run into a fixture-relocation issue would silently
  expand scope beyond what REQ-ANALYST/ORCH sized it as.
- A real dry-run also has a hard practical blocker independent of scope discipline:
  `docs/migration/stage-7-simulation-uat-parity.md`'s own REQ-210 sign-off records that
  every `via: gui` step across all 11 scenarios is `DEFERRED_TO_S8` because S8's
  `web/`-to-Letflow integration work has not shipped — meaning a live run of, e.g.,
  `swiftroute-tenant-onboarding-happy` would still hit the same GUI-deferred wall this
  design doesn't change. There is no live-instance improvement to demonstrate yet for
  the GUI-heavy scenarios in this corpus regardless of where the fixture files live.
- "Structural verification" for this pass concretely means: (a) all 11 files present
  at the destination named in §1, each YAML-parseable (a plain `YAML.decode_file!/1` –
  or equivalent load — round-trip, not a Runner invocation) and byte-identical to the
  R-Co source below the header comment (diff check); (b) `.claude/agents/uat-runner.md`
  and `WF-05_uat_run.md` updated per §3 and internally consistent (no remaining
  "location TBD" text); (c) `test/fixtures/simulation/**/*.yaml`'s existing 12
  company/org/process + 11 scenario synthetic files confirmed byte-unchanged (`git diff`
  showing zero lines touched in that tree) as ISS-0526's own acceptance criteria
  require. None of this requires a running Letflow instance.
- The first REAL UAT run against this corpus is correctly left to whenever S7's own
  UAT-parity work actually needs one — i.e., whenever a future requirement dispatches
  WF-05 for real (per `WF-05_uat_run.md`'s own trigger: "a running Letflow instance
  exists and a stage's scenario corpus is ready to validate against"). That is a
  distinct, larger-scoped future run, not part of relocating fixture files.

---

## Open questions

- **OQ-1.** Whether letflow's `onboarding-wizard.pipeline.e2e.spec.ts` (already present
  in `web/tests/e2e/pipelines/`) is itself byte-identical to R-Co's own copy of the same
  filename, or diverged during whatever earlier porting work landed it — not verified by
  this design (out of scope: this design only inventories the scenario YAML corpus, not
  the Playwright spec files it references). A future run driving that pipeline_test for
  real should confirm this before trusting it as equivalent to R-Co's own UAT coverage.
- **OQ-2.** No decision is made here about whether the recommended platform-corpus
  follow-up (§4) should be filed as one issue covering all 18 files or split further
  (e.g. isolating the 2 cross-tenant-probe files into their own
  SECURITY-REVIEWER-gated issue from the start). Left for ORCH/REQ-ANALYST to size at
  filing time.
