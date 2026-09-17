# REQ-362 — Design: Two-phase visual regression testing (AI-accepted baselines,
# then mechanical Playwright pixel-diff, dual-tracked auto-fail issue filing)

Stage S7. Owner: `TEST-DESIGNER` (implementation); this document is `CODE-DESIGNER`'s
design-only artefact per WF-02 Step 1. Depends on REQ-358 (scenario `scope`/branching +
UAT-RUNNER environment-target — already landed, see
`lib/letflow/design/req358-uat-scope-branching-env.md`).

**Not in scope here:** no new external visual-testing dependency (the requirement
explicitly forbids introducing one without a decision record — Playwright's own
built-in comparison, already a dependency via `web/playwright.config.ts` /
`@playwright/test`, is the only mechanism designed here); no new issue-filing
mechanism (reuses `docs/agents/protocols/ISSUE_QUEUE.md` verbatim); no change to
phase-1 judgment itself (UAT-RUNNER/BA-persona screenshot review is unchanged — only
its *persistence* as a baseline is new).

---

## 0. Premises re-verified against the tree (2026-09-16)

- Neither `lib/`, `web/`, nor `docs/` contains any pixel-diff/visual-regression
  tooling today (grepped `screenshot` across `web/tests/e2e/*.e2e.spec.ts` — every
  hit is `page.screenshot({ path: ... })` used as evidence-capture, never compared
  against a prior image; grepped `toHaveScreenshot` project-wide — zero hits).
- `web/playwright.config.ts` already depends on `@playwright/test`, which ships
  `expect(page).toHaveScreenshot(name, options)` / `expect(locator).toHaveScreenshot(...)`
  as a built-in assertion — no new package, no new `package.json` dependency. Verified
  by reading the installed `@playwright/test` version's public API surface via
  `web/node_modules/@playwright/test/types/test.d.ts` is NOT re-derived here (design
  step only) — ELIXIR-DEV/TEST-DESIGNER confirms the exact installed version's flag
  names against `npx playwright --version` before implementing §3.
- `.claude/agents/uat-runner.md`'s "Reading the scenario corpus" section already
  defines `verification: {method: gui_screen, detail: ...}` on `expected_outcomes[]`
  as the existing prose-judgment hook (e.g.
  `test/fixtures/uat/scenarios/platform/definition-promotion-conflict-rejected.yaml`
  EO-001..EO-005). This is phase 1's existing judgment mechanism this requirement does
  not reimplement — it only adds persistence and a phase-2 mechanical gate around it.
- `docs/agents/AGENT_SYSTEM.md` §6's artifact-locations table has no row for
  visual-regression baselines today — §5 below adds one, per AC-1.
- `docs/agents/protocols/ISSUE_QUEUE.md`'s dual-track mechanism (`register_task` →
  `issue_ref`/`queue_ref`/`github_ref`, `docs/issues/<issue_ref>.yaml`) is unchanged by
  this design; §6 states exactly which existing step the auto-fail plugs into.
- `web/tests/e2e/f5-admin-users.e2e.spec.ts` shows the project's existing
  `SCREENSHOTS_DIR = 'tests/screenshots'` convention for **transient**, per-run,
  evidence screenshots (git-ignored, not compared to anything) — §1 below deliberately
  places baselines in a **different**, permanent, committed directory so the two
  purposes (transient evidence vs. durable comparison baseline) are never confused or
  overwritten by each other.

---

## 1. Baseline storage location and naming convention (AC-1)

### 1.1 Location

```
test/fixtures/uat/visual-baselines/<company_id>/<scenario_id>/<step>-<eo_id>.<environment>.png
```

- `test/fixtures/uat/` already exists (`scenarios/` sibling) and is the established
  home for durable UAT fixtures — baselines are a durable UAT fixture, not a test
  report or transient artefact, so they belong beside `scenarios/`, not under
  `test/uat-reports/` (which is UAT-RUNNER's per-run report *output*, append-only by
  run) or `web/tests/screenshots` (transient, git-ignored, per-run evidence).
- `<company_id>`: the scenario file's own top-level `company_id` field (`platform`,
  `meridian`, `swiftroute`, `vortex`, ...) — mirrors the existing `scenarios/<company>/`
  split so the two trees stay parallel and a reader can find a scenario's baselines by
  the same path segment they already use to find its script.
- `<scenario_id>`: the scenario file's own top-level `id` field (e.g.
  `platform-definition-promotion-conflict-rejected`), not the filename — the two are
  conventionally identical today but the field is the authoritative key per
  `docs/agents/uat-scenario-schema.md`, and this keys off the same field REQ-358's
  branch-evaluation design already treats as authoritative.
- `<step>`: the `steps[].step` integer the screenshot was captured after (e.g. `1`,
  `3`), zero-padded to 2 digits (`01`, `03`) so lexical and numeric directory listing
  order agree past step 9.
- `<eo_id>`: the `expected_outcomes[].id` whose `verification.method: gui_screen`
  produced this screenshot (e.g. `EO-002`) — a single step can back more than one
  `gui_screen` expected outcome (see EO-002/EO-005 both keying off different points in
  the same scenario in §0's example file), so the pairing must be explicit rather than
  inferred from step number alone.
- `<environment>`: a short, dispatch-supplied slug for the target instance (e.g. `qa`,
  `local`, `staging`) — **not** derived from `base_url` by parsing (a URL is not a
  stable identity across ports/hosts pointing at logically "the same" environment).
  §7 Open Question OQ-1 covers where this slug is declared.

Full worked example:
`test/fixtures/uat/visual-baselines/platform/platform-definition-promotion-conflict-rejected/01-EO-002.qa.png`

### 1.2 Why keyed to all four segments, not fewer

- Scenario+step+EO alone would collide across environments whose real rendered pixels
  legitimately differ (different seed data, different environment banner/watermark) —
  the environment segment is what AC-1 explicitly requires ("keyed to scenario id +
  step + environment").
- Company+scenario+step+EO (dropping environment) was considered and rejected for the
  same reason: it would force a single baseline to be "correct" simultaneously for
  `qa` and `local`, which is false whenever environment-specific chrome exists.

### 1.3 Distinctness from transient screenshots (AC-1's explicit requirement)

Transient per-run screenshots stay exactly where they are today
(`web/tests/screenshots/`, per `f5-admin-users.e2e.spec.ts`'s existing
`SCREENSHOTS_DIR`, or wherever a given `.e2e.spec.ts`/pipeline test already writes
its evidence capture) — git-ignored, one per run, never read back by anything.
Baselines live under `test/fixtures/uat/visual-baselines/`, are **committed to git**
(this is durable fixture data, same discipline as `test/fixtures/uat/scenarios/`), and
are the only images phase 2's comparison reads as the "expected" side. Nothing in this
design routes a transient screenshot into the baseline tree except the explicit accept
action in §2 and the explicit re-baseline action in §4 — never an implicit copy.

### 1.4 AGENT_SYSTEM.md artifact-locations table update

`docs/agents/AGENT_SYSTEM.md` §6's table (currently: Elixir source, migrations,
frontend source, frontend spec, mobile source/spec, design artefacts, test specs, test
source, test reports, UAT reports, handoff files, requirement queue, requirement event
history, issue registry, release decisions, migration decisions, stage docs, role
files, instructions, protocols, workflows, guides, scratch) gets one new row, inserted
directly below the existing `UAT reports` row since it is the same subsystem:

| Type | Location | Owner | Format |
|---|---|---|---|
| UAT visual-regression baselines | `test/fixtures/uat/visual-baselines/` | `UAT-RUNNER` (accept/re-baseline actions) | `.png` (+ one `.yaml` sidecar per baseline, §2.3) |

This row is this design's own deliverable per AC-1 ("that table updated if new") —
`ELIXIR-DEV`/`TEST-DESIGNER` applies this literal row addition as part of implementing
this requirement; it is not implemented by CODE-DESIGNER itself (design-only role).

### 1.5 Data-sensitivity policy for baseline content (binding, not an open question)

**Decision, stated as an invariant of this mechanism:** any `gui_screen` expected
outcome accepted (§2) or re-baselined (§4) through this mechanism must be captured
against **synthetic/disclosed-fictional actor and tenant data only — never real
tenant PII** (real candidate names, emails, phone numbers, or any other genuinely
tenant-identifying on-screen data). This is a precondition of calling the accept
action (§2.2) and the re-baseline action (§4.1), not a suggestion.

**Existing baseline checked against this policy (fact, verified — not an open
question).** `test/fixtures/uat/visual-baselines/` is not empty: it already contains a
baseline committed by REQ-362's own self-check —
`platform/req362-visual-regression-selfcheck/01-EO-001.local.png` and its sidecar
`01-EO-001.local.yaml`, landed in commit `242ae72c` (PR #1460, merged to `main`, an
ancestor of every branch built on this design). That baseline has been checked against
this policy and found compliant: the sidecar's own `judgment_detail` records that it
captures "the root route (GET /) ... for an unauthenticated session, the real Keycloak
login form" — a static, unauthenticated screen carrying no actor data, no tenant data,
and no PII of any kind. This is not a case of the policy applying retroactively to
content that predates it; the baseline was independently inspected against §1.5's
invariant while writing this section and confirmed to contain nothing the invariant
forbids. No accept (§2) or re-baseline (§4) call has yet produced a baseline that
required this check to actually reject anything — the one baseline in the tree today
simply never carried tenant data to begin with.

**Why this needs to be said here, explicitly, even though it is not a new practice.**
Every scenario file under `test/fixtures/uat/scenarios/` already follows exactly this
discipline today — spot-checked directly against
`test/fixtures/uat/scenarios/swiftroute/tenant-onboarding-happy.yaml`, whose actor
`Alice Bauer` (`alice.bauer@swiftroute.example` at hostname `swiftroute.bpm.example`)
is disclosed-fictional per that file's own header-comment provenance discipline
("Ported verbatim from R-Co... disclosed-synthetic fixtures"), the same discipline
already established for `Letflow.Simulation.Runner` fixtures. So this section asks
nothing new of scenario authors. What is new is that, unlike a transient screenshot
(§1.3 — git-ignored, one per run, discarded), a baseline accepted here is **permanently
retained** — committed to git, with every superseded version still recoverable from git
history even after a re-baseline overwrites the working-tree file (§1.3, §4.3). That
permanence is exactly what turns an already-synthetic-by-convention screen into a
standing risk the moment a future scenario happens to be seeded with real data instead:
nothing before this section stopped that. Section 1.5 exists to make the corpus's
existing, already-followed practice a binding, checked invariant specifically for this
one mechanism, so no future authenticated `gui_screen` scenario can slip real PII into
a permanent artifact by omission.

**Why synthetic/disclosed-fictional data, and not redaction or accepted-risk (the two
alternatives this design considered and rejected):**

- **Not redaction** (masking or blurring regions of the PNG before persist). Phase 2
  (§3.4) is deliberately an *unconditional, mechanical* pixel-diff with no loosened
  tolerance — that is the requirement's own explicit point. A redaction mask would have
  to render bit-for-bit identically on every future run forever, or it becomes a second,
  self-inflicted source of spurious diffs, directly undermining §3.4's "auto-fail is
  unconditional" intent. Synthetic data has no such failure mode: the screen simply
  never contains real data in the first place, so pixel stability is unaffected by this
  policy at all.
- **Not accepted-risk.** A screenshot containing real tenant PII would be a permanent,
  git-history-retained artifact (§1.3) — exactly the class of tenant-data exposure this
  project's security invariants exist to prevent (this is the finding SECURITY-REVIEWER
  raised, not a marginal concern to wave through). There is no operational benefit to
  accepting that risk that offsets it.
- **Synthetic/disclosed-fictional data costs nothing new to adopt**, because the
  existing UAT scenario corpus is already entirely synthetic by convention (verified
  above) — this section only makes an existing, already-universal practice explicit and
  binding for this specific mechanism, rather than introducing a new authoring burden.

**Enforcement note (see §7):** this is a content/authoring-discipline invariant, not
something `acceptBaseline`/`rebaseline` in `web/tests/support/visual-baseline.ts` can
mechanically verify from a PNG buffer or a `BaselineKey` — "is the on-screen data
synthetic" is a judgment made by the scenario author and the accepting agent
(UAT-RUNNER today), not a property derivable from image bytes. No code change is
required to state this policy; it is deliberately not deferred as an open question in
§8 — the decision is made here, now, as a binding invariant.

---

## 2. Phase 1: baseline-accept action

### 2.1 Trigger

Fires when a `gui_screen`-method expected outcome's screenshot is judged correct by
the executing agent (UAT-RUNNER today; a BA persona once REQ-359/REQ-361 land) **and**
no baseline file currently exists at the §1.1 path for that
scenario+step+EO+environment. This is the *only* new trigger this requirement adds —
the judgment step itself (an agent looking at the screenshot and forming the verdict
"this looks right") is `.claude/agents/uat-runner.md`'s existing, unmodified
discipline; nothing about *how* that judgment is formed changes.

A first-ever run of a scenario against a given environment therefore always takes this
path (no baseline can exist yet) — this is expected and is how a baseline population
run establishes the whole corpus.

### 2.2 What the accept action does

**Precondition (§1.5):** the screen being captured must be seeded with
synthetic/disclosed-fictional actor and tenant data only — never real tenant PII. This
is checked by the scenario author and the accepting agent before step 1 below, not by
the accept action's own code (§1.5's enforcement note).

1. UAT-RUNNER captures the `gui_screen` screenshot exactly as it already does today
   (`page.screenshot({ path: ..., fullPage: true })` or equivalent, into the
   transient `web/tests/screenshots/`-style location per §1.3).
2. UAT-RUNNER forms its existing prose judgment against `expected_outcomes[].verification.detail`.
3. If judged correct **and** no baseline exists yet at the §1.1 path: copy the
   captured screenshot to that path and commit it, plus write the sidecar (§2.3).
4. If judged correct and a baseline **already** exists: this is not phase 1 territory
   any more — control passes to phase 2 (§3), since an existing baseline means this
   scenario+step+EO+environment has graduated to mechanical comparison. Phase 1's
   accept action never silently overwrites an existing baseline; overwriting an
   existing baseline is exclusively the re-baseline action (§4), which requires
   justification. This separation is what keeps phase 1's "no baseline yet" path from
   ever becoming a backdoor around phase 2's unconditional auto-fail.

### 2.3 Sidecar metadata file

Each baseline PNG is paired with a same-named `.yaml` sidecar recording provenance —
required because a bare PNG carries no audit trail of who accepted it or why:

```
test/fixtures/uat/visual-baselines/<company_id>/<scenario_id>/<step>-<eo_id>.<environment>.yaml
```

Fields (shape, not implementation):

- `scenario_id` — string, matches the scenario file's `id`.
- `company_id` — string.
- `step` — integer, matches `steps[].step`.
- `expected_outcome_id` — string, matches `expected_outcomes[].id`.
- `environment` — string slug, matches §1.1's `<environment>` segment.
- `accepted_by` — string, the `AGENT_ID` (or BA-persona role id once REQ-359/361 land)
  that performed the accept.
- `accepted_in_run` — string, the run-id of the WF-05/UAT run the accept happened in.
- `accepted_at` — UTC timestamp, from the clock per core-directives.md's bookkeeping
  rule — never from memory.
- `judgment_detail` — string, the prose judgment text the accepting agent recorded
  against `expected_outcomes[].verification.detail` (i.e. *why* this screenshot was
  judged correct) — this is phase 1's existing judgment output, persisted rather than
  discarded after the run.
- `source_screenshot` — string, path to the transient screenshot this baseline was
  copied from, for traceability (not a promise that file still exists after the run).
- `history` — list, append-only, one entry per re-baseline event (§4.3) — empty on
  first accept.

### 2.4 What AC-2 requires ELIXIR-DEV/TEST-DESIGNER to exercise for real

A real UAT run (or a scoped harness run against one `gui_screen` expected outcome)
must actually produce a committed baseline PNG + sidecar under §1.1/§2.3's real paths,
with the actual `mix`/`npm`/shell command and resulting file path quoted in that
step's handoff — this design only specifies the shape; it does not itself run
anything (CODE-DESIGNER produces no implementation code or executed commands).

---

## 3. Phase 2: mechanical pixel-diff comparison

### 3.1 Mechanism — Playwright's own built-in capability, no new dependency

`expect(page).toHaveScreenshot(name, options)` (or the `locator` form, for a
sub-element `gui_screen` check where the existing scenario's `detail` names a specific
region rather than the full page) is Playwright's built-in visual comparison
assertion, already available via the project's existing `@playwright/test` dependency
declared for `web/` (see `web/playwright.config.ts`). It:

- takes a screenshot of the current page/locator,
- compares it byte-for-byte-adjacent (pixel comparison with anti-aliasing tolerance,
  Playwright's own internal default) against a reference image it reads from disk,
- passes if the diff is within its own default threshold, fails otherwise, and
- (relevant nuance for this design) natively expects the reference image to live at a
  path *it* derives from the test file's own location and the `name` argument
  (`<test file>-snapshots/<name>-<platform>.png` by default) — **this default
  discovery path is not reused here**, because it does not match §1.1's scenario-keyed
  convention. §3.2 below is how this design reconciles the two.

### 3.2 Reconciling Playwright's default snapshot path with §1.1's convention

Two options exist; this design picks the first and records the second as the
alternative considered, per this project's "don't silently resolve an open question"
discipline:

- **Chosen: pass an explicit reference image via `toHaveScreenshot`'s path-override
  option** (Playwright's `toHaveScreenshot(nameOrOptions)` accepts a path directly,
  or the comparison can be done manually via `page.screenshot()` + Playwright's
  underlying `PNG`-comparison primitive if the installed version's typed API does not
  expose a direct path override — ELIXIR-DEV/TEST-DESIGNER confirms the exact
  call-shape against the installed `@playwright/test` version, since this is
  implementation, not design). Either way, the *reference* image supplied to
  Playwright's comparison is always read from the §1.1 baseline path — Playwright
  never gets to pick its own default `-snapshots/` location for this project's
  baselines, so the two directory conventions never fight each other.
- **Considered, not chosen: use Playwright's own default `<test>-snapshots/` layout
  and rename UAT-RUNNER's directory convention to match it instead.** Rejected
  because it would put baselines under `web/tests/e2e/<spec>-snapshots/`, coupled to
  a specific spec file's location rather than to the scenario id — this breaks the
  scenario+step+EO+environment key AC-1 requires (a baseline must be locatable from
  the scenario file alone, independent of which spec happens to drive it), and it
  would mix baselines into `web/`'s own tree rather than the durable UAT-fixture tree
  used by the rest of the corpus.

### 3.3 Threshold — kept at Playwright's own default, unconditionally (AC-3, AC-6)

**This design does not loosen Playwright's default pixel/anti-aliasing tolerance.**
This is a direct, explicit design decision restating the requirement's own explicit
user direction (`docs/requirements.yaml` REQ-362 description: *"ANY pixel difference
(starting threshold: the tool's own sane default, not a loosened tolerance chosen to
reduce noise — tune only if real operational experience shows the default is
unworkably noisy, and record that as a finding if it happens rather than silently
loosening it up front)"*). Concretely:

- No `maxDiffPixels`, `maxDiffPixelRatio`, or `threshold` option is set away from
  Playwright's shipped default anywhere in this design.
- If a future implementer or operator finds the default too noisy in real operation,
  the correct response is: **record a finding** (a new issue via ISSUE_QUEUE.md,
  or a decision-record draft if it is a durable policy change) with the actual
  false-positive evidence — never a silent tolerance bump in the comparison call
  itself. This is stated here explicitly so a future reader does not "fix" perceived
  flakiness by quietly loosening the threshold without that record existing.

### 3.4 Auto-fail is unconditional — no LLM judgment gate (AC-6)

**Explicit statement, as AC-6 requires:** once a baseline exists for a given
scenario+step+EO+environment, **any** pixel difference Playwright's comparison
detects (at its own default threshold, per §3.3) fails that expected outcome
immediately and mechanically. No agent — UAT-RUNNER, a BA persona, or any other
role — is consulted to decide whether the detected diff "counts," "looks
intentional," or "is probably fine" before the fail is recorded. This is deliberate,
per this session's explicit user direction (restated verbatim in REQ-362's own
description): *"the fail is unconditional and mechanical."*

**Why, stated so a future reader does not soften this:** the entire value of phase 2
over phase 1 is that it catches regressions phase 1's own judgment already proved
unreliable at catching consistently (that is *why* phase 1 alone was judged
insufficient and this requirement exists) — a judgment gate re-inserted at the
pixel-diff step would collapse phase 2 back into a second copy of phase 1 with extra
steps, defeating the requirement's own stated purpose. The judgment that intentional
change vs. regression happens **downstream**, in WF-03's issue-resolution pipeline
(§6), by a role actually equipped to reason about it with full context (linked
requirement, author intent) — not inline, under time pressure, at the moment a diff
is first detected.

### 3.5 What phase 2 does on PASS vs FAIL

- **No diff (within default threshold):** expected outcome recorded PASS in the UAT
  report exactly as today (`.claude/agents/uat-runner.md`'s existing report
  discipline) — no baseline change, no issue filed.
- **Diff detected:** expected outcome recorded FAIL. The scenario's overall verdict
  follows existing `on_fail.severity` handling (unchanged by this design). §6 below
  is what additionally happens on this specific failure class.

### 3.6 What AC-3 requires exercised for real

Two real runs, both with the actual Playwright output quoted:

1. **Pass case:** a `gui_screen` expected outcome with an existing baseline, run
   again against an unchanged screen — `toHaveScreenshot` (or equivalent) passes, no
   issue filed.
2. **Fail case:** the same expected outcome, run against a deliberately altered
   screen (e.g. a CSS/copy tweak introduced on a throwaway branch/fixture for this
   exercise only, per this project's "exercised for real" bar, not a fabricated
   assertion) — the comparison fails, and §6's issue-filing path actually fires.

This design specifies the mechanism; TEST-DESIGNER/ELIXIR-DEV performs the two real
runs and quotes the actual output in their own handoffs.

---

## 4. Re-baseline action (AC-5)

### 4.1 Who performs it

**Precondition (§1.5):** exactly as for the accept action (§2.2), the replacement
screenshot being re-baselined must be seeded with synthetic/disclosed-fictional actor
and tenant data only — never real tenant PII. A re-baseline does not get a pass on this
invariant merely because the baseline it replaces was already accepted.

The **same role tier that performs phase-1 accept** — UAT-RUNNER today, or (once
REQ-359/REQ-361 land) the BA-persona/PRODUCT-OWNER-equivalent role reviewing UAT
evidence — **never** an automated/unattended step, and never the same run that
detected the phase-2 failure. This is deliberate: the run that observed the diff is
not the run that decides the diff is intentional (§3.4's separation of detection from
judgment) — re-baselining happens in a **later**, human-directed-equivalent run, after
whatever WF-03 issue-resolution triage in §6 concluded the visual change is
intentional.

### 4.2 Trigger

An explicit re-baseline request — never automatic. Concretely, one of:

- A WF-03 issue-resolution run (per §6) concludes the detected diff reflects an
  intentional, already-shipped UI change (not a regression), and its own resolution
  step includes re-baselining as part of closing the issue.
- An agent/persona is directly dispatched to re-baseline a named
  scenario+step+EO+environment (e.g. after a deliberate design change lands and the
  team already knows the old baseline is stale) — this still requires the same
  justification recording as the WF-03 path; there is no "known stale, skip the
  paperwork" shortcut.

### 4.3 What it records (the explicit, auditable part AC-5 requires)

Re-baselining is **not** a bare "accept the new image" call. It must record, in the
existing sidecar's `history` list (§2.3) as a new entry (never overwriting prior
entries — append-only, same discipline as the requirement-status volumes):

- `rebaselined_by` — the performing agent/role id.
- `rebaselined_in_run` — the run-id.
- `rebaselined_at` — UTC timestamp from the clock.
- `justification` — free-text, **mandatory**, stating *why* the visual change is
  intentional — must name the requirement/change that caused it (e.g. "REQ-XXX
  changed the header layout; new baseline reflects that, not a regression") per the
  requirement's own "linking back to whatever requirement caused the visual change"
  language. A `justification` field left blank or generic ("looks fine now") is not
  a legal re-baseline per this design — TEST-DESIGN-VALIDATOR/CODE-DESIGN-VALIDATOR-
  equivalent checks for this at implementation-review time.
- `superseded_baseline_hash` — a content hash (e.g. SHA-256) of the PNG being
  replaced, recorded before overwrite, so the prior baseline's identity is verifiable
  even after the file itself is overwritten in the working tree (git history also
  retains it, since baselines are committed per §1.3 — this field is a
  human/agent-readable convenience on top of that, not a replacement for it).
- `related_issue_ref` — the `ISS-NNNN` (per ISSUE_QUEUE.md numbering) this
  re-baseline resolves, or `null` with a comment if performed outside an issue-driven
  flow (§4.2's second bullet).

The PNG at the §1.1 path is then overwritten with the new, accepted screenshot.

### 4.4 What AC-5 requires exercised for real

One real re-baseline: an existing baseline, a recorded justification quoting the
actual text written, and confirmation the sidecar's `history` list gained the new
entry (not a fabricated description) — ELIXIR-DEV/TEST-DESIGNER's job at a later WF-02
step, not this design step's.

---

## 5. Integration point in UAT-RUNNER's existing flow

`.claude/agents/uat-runner.md`'s "Reading the scenario corpus" section, for a
`verification.method: gui_screen` expected outcome, gains this decision point
(described here as behavior to add, not as code):

```
On reaching a gui_screen expected outcome:
  1. Capture the screenshot (unchanged from today).
  2. Look up whether a baseline exists at the §1.1 path for this
     scenario_id + step + expected_outcome_id + environment.
  3. If NO baseline exists  -> PHASE 1 (§2): judge as today, and if judged
     correct, accept as the new baseline.
  4. If a baseline EXISTS   -> PHASE 2 (§3): run Playwright's built-in
     comparison against it. PASS/FAIL is mechanical from here — no judgment
     call. On FAIL, route to §6.
```

This is the only change to UAT-RUNNER's own procedure; WF-05 Steps 2-3
(`docs/agents/workflows/WF-05_uat_run.md`) are otherwise unchanged — the branch above
slots into WF-05 Step 2's existing per-scenario execution loop, and a phase-2 FAIL is
reported in WF-05 Step 3's existing report exactly like any other expected-outcome
FAIL, with the addition of the §6 issue-filing side effect.

---

## 6. Issue routing on auto-fail (AC-4) — reusing the existing mechanism, not a new one

On a phase-2 FAIL (§3.5), UAT-RUNNER follows `docs/agents/protocols/ISSUE_QUEUE.md`'s
existing procedure **exactly as written**, with these concrete parameter choices
(no new mechanism, only what this design supplies as the *content* of an existing
call):

1. UAT-RUNNER reports the finding to ORCH (per ISSUE_QUEUE.md step 2) — title,
   description, severity, affected_files — same as any other incidentally-discovered
   defect, except this is not incidental to the run, it *is* the run's own scenario
   failure, so it is reported as part of this scenario's FAIL verdict in the same
   turn, not deferred.
   - `title`: e.g. "Visual regression: <scenario_id> step <N> (<eo_id>) diverges from
     accepted baseline on <environment>".
   - `severity`: inherited from the expected outcome's own `on_fail.severity` in the
     scenario file (BLOCKER/MAJOR/MINOR) — this design does not invent a new severity
     scale; it reuses the one the scenario author already assigned.
   - `affected_files`: the scenario file path, the baseline PNG path, and the newly
     captured screenshot path.
2. ORCH calls `register_task` per ISSUE_QUEUE.md step 2a, exactly as for any other
   finding — this yields `issue_ref`/`queue_ref`/`github_ref`, with GitHub mirroring
   best-effort as already specified there. No new call, no new field.
3. `docs/issues/<issue_ref>.yaml` is written per ISSUE_QUEUE.md step 3, with one
   addition specific to this finding class: the `description` field's evidence
   section names both image paths explicitly, and both images are attached as the
   issue's evidence. **Attachment mechanism**: `gh issue create`/`register_task`'s
   underlying GitHub-mirroring step attaches the two PNGs the same way any other
   agent-filed GitHub issue attaches evidence today (Letflow's existing GitHub
   issue-filing convention for embedding images — this design does not invent a new
   attachment transport; it supplies the two file paths as the artefacts to attach).
   If the concrete attachment mechanism ISS-registration uses today cannot carry
   binary attachments directly, the fallback is: commit both images under
   `test/fixtures/uat/visual-baselines/<...>/_disputed/<issue_ref>/` (new-baseline
   and baseline-at-time-of-failure, both named unambiguously) and link that path in
   the issue body — see OQ-2.
4. The issue does **not** itself judge intentional-change-vs-regression (per the
   requirement's own explicit statement — "this requirement does NOT itself decide
   that; it only detects and reports the divergence"). Whoever picks up the issue via
   WF-03 (or this project's current equivalent) makes that call, and if the verdict is
   "intentional," that WF-03 run performs (or dispatches) the §4 re-baseline action as
   part of its resolution, citing `related_issue_ref` back to this same `ISS-NNNN`.

### 6.1 What AC-4 requires confirmed for real

The fail-case exercise in §3.6 must be followed through to a real `register_task`
call and a real `docs/issues/<issue_ref>.yaml` file landing on disk, with the actual
`issue_ref`/`queue_ref`/`github_ref` values quoted — not merely asserted that filing
"would" happen. TEST-DESIGNER/ELIXIR-DEV's job at implementation.

---

## 7. Acceptance-criteria map

| AC | Design element |
|---|---|
| AC-1 (baseline location/naming keyed to scenario+step+environment, distinct from transient, table updated) | §1 (path scheme), §1.4 (AGENT_SYSTEM.md row) |
| AC-2 (phase-1 accept implemented and exercised for real) | §2 (accept action shape), §2.4 (real-exercise requirement handed to next step) |
| AC-3 (phase-2 pixel-diff via Playwright built-in, exercised pass+fail) | §3.1-§3.3 (mechanism, no new dependency, default threshold), §3.6 (real-exercise requirement) |
| AC-4 (auto-filed issue lands in local+queue+GitHub via existing mechanism, carries both screenshots) | §6 (reuse of ISSUE_QUEUE.md verbatim), §6.1 (real-exercise requirement) |
| AC-5 (re-baseline action with mandatory recorded justification, exercised for real) | §4 (action shape, mandatory `justification` field), §4.4 (real-exercise requirement) |
| AC-6 (design states auto-fail is unconditional, and why) | §3.4 (explicit statement + reasoning) |
| (data-handling scope implicit in AC-1/AC-2 — what may be captured into a permanent baseline) | §1.5 (binding synthetic/disclosed-fictional-data-only policy, cross-referenced from §2.2 and §4.1) |

---

## 8. Open questions (not silently resolved)

- **OQ-1 — where the `<environment>` slug is declared.** This design requires a
  short, stable slug (`qa`, `local`, `staging`) distinct from `base_url`, but does not
  pick where it is sourced from: a new field on WF-05's existing dispatch `context`
  (alongside `base_url`/`credential_source`, per `.claude/agents/uat-runner.md`'s
  "Environment target" section) is the natural fit, but that section's exact schema
  is UAT-RUNNER's/WF-05's own file to amend, not this design's to presume without
  ORCH/REVIEWER sign-off on the dispatch-contract change. TEST-DESIGNER should flag
  this explicitly when implementing rather than inventing a default.
- **OQ-2 — exact binary-attachment mechanism for GitHub issue images.** §6 step 3
  names a fallback (commit disputed images under a `_disputed/<issue_ref>/` path and
  link it) but does not confirm whether `register_task`'s GitHub-mirroring path
  already supports direct image attachment today. This needs a check against
  `docs/agents/protocols/TASK_QUEUE.md`'s actual `register_task` capabilities before
  implementation — if it does not support attachments, the fallback becomes the
  actual mechanism, not a fallback, and this document's §6 step 3 should be updated
  to say so plainly rather than implemented as written.
- **OQ-3 — Playwright's exact installed-version API shape for a path-overridden
  `toHaveScreenshot`.** §3.2 states the intended reconciliation but explicitly defers
  confirming the literal option name/call shape to implementation, since the
  installed `@playwright/test` version was not re-verified against its typed API
  surface as part of this design pass (see §0's premise note) — this is a genuine
  gap, not a guessed answer.
- **OQ-4 — locator-scoped vs full-page comparison per expected outcome.** Some
  `gui_screen` `detail` text names a specific region ("the editor shows...") rather
  than the whole page; this design allows either `toHaveScreenshot` form (§3.1) but
  does not specify which expected outcomes should use which — left to
  TEST-DESIGNER's judgment per scenario, informed by each `detail` field's own
  wording, since a blanket rule would misfit at least some existing scenarios.
