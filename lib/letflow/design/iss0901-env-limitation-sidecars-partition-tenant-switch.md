# Design: ISS-0901 — env_limitation sidecars for docker-compose-Postgres-only platform scenarios

Status: draft, for CODE-DESIGN-VALIDATOR
Issue: `docs/issues/ISS-0901.yaml` (split off `docs/issues/ISS-0890.yaml` triage)
Related precedent: `lib/letflow/design/iss0895-swiftroute-uat-scenario-slug-conflict.md`
(built the `env_limitation` sidecar mechanism this design reuses), ISS-0894 (the
preflight actor/realm checks), `lib/letflow/design/req384-tenant-switcher-cache-isolation.md`
(§1.1 `tenant_memberships`, OQ-2 — no HTTP write path for it)

## Problem restated

Two platform scenarios are fully built (backend + frontend shipped, specs
authored, both drivable against a real running instance) but are permanently
BLOCKED against QA specifically, confirmed by `test/uat-reports/uat-2026-09-29-WF05-FULL-20260929-PLATFORM.yaml`:

1. `platform-partition-retention-drop` — REQ-376 (backend)/REQ-377 (frontend)
   both `status: done`. `web/tests/e2e/pipelines/platform-partition-retention-drop.pipeline.e2e.spec.ts`
   exists and backdates event-history partitions via helpers imported from
   `web/tests/e2e/db-exec.ts`, which shells out to `docker compose exec postgres
   psql` against the local dev Postgres. No HTTP surface exists (or should
   exist — backdating retention history is a test-fixture-only need, not a
   product capability) to do the same thing against real QA.
2. `platform-tenant-switch-cache-isolation` — its pipeline_test,
   `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts`, contains three
   `test()` blocks named `EO-001`, `EO-002`, `EO-003`. Only `EO-001` needs a
   direct SQL `INSERT INTO tenant_memberships` (via `db-exec.ts`'s
   `insertTenantMembershipSql` / `runSqlAgainstDevPostgres`, the same
   docker-compose-psql technique) because REQ-384 ships no HTTP write path for
   that table (`req384-tenant-switcher-cache-isolation.md` §1.1, OQ-2). `EO-002`
   (sign-out clears `bpm_realm_slug` residue) and `EO-003` (a task shows the
   form version it was created against) need no such write and already **PASS**
   against real QA (confirmed twice: `uat-2026-09-22-WF02-REQ384-EO001-20260922.yaml`
   and `uat-2026-09-29-WF05-FULL-20260929-PLATFORM.yaml`).

`docs/agents/workflows/WF-05_uat_run.md` ("Letflow never changes QA
infrastructure directly") and ISS-0895's `env_limitation` sidecar mechanism
(`test/fixtures/uat/scenario-env-limitations/<scenario_id>.yaml`,
`classification: ENV_NOT_SUPPORTED`, consumed by `scripts/uat_preflight.sh`'s
`env_limitation` check column) are the right existing mechanism to reuse
per ISS-0901's own instruction. The open design question ISSUE-FIXER flagged:
the sidecar is `scenario_id` granularity — one file marks a whole scenario
env-limited — but scenario 2 needs only one of its three tested expected
outcomes marked, without falsely silencing continued verification of the
other two.

## Findings from reading the actual mechanism (not paraphrased)

### `scripts/uat_preflight.sh` is scenario-level only — confirmed by reading it

- `CHECKS = ["spec", "local_deps", "feature", "tenant", "realm", "actors",
  "app_roles", "definitions", "env_limitation"]` (line 341) — every column is
  one status per **scenario**. Nothing in the script parses a scenario
  file's `expected_outcomes:` list, and nothing in the gap table
  (`== GAP TABLE (scenario x check) ==`, line 503) or the JSON `--out` summary
  (line 538, `"scenarios": {s["id"]: {k: {...} for k in CHECKS} for s, c in
  rows}`) has a per-`expected_outcomes`/per-EO axis at all. The script has
  zero notion of "EO-001" as a concept.
- `parse_env_limitation` (line 180) keys sidecars by `scenario_id` only
  (`env_limitations[sid] = d`, line 200) and the per-scenario lookup at line
  470 (`lim = env_limitations.get(s["id"])`) can only produce one
  `("OK"|"GAP", reason, owner)` triple for the entire scenario row (lines
  471–479).
- **Conclusion, stated plainly:** `uat_preflight.sh` cannot be made to report
  per-expected-outcome granularity today without a real schema change (parsing
  `expected_outcomes:` out of each scenario file and adding a second axis to
  `rows`/the gap table/the JSON summary). That is a materially bigger change
  than this issue's scope ("1-2 new sidecar YAML files... any necessary
  `scripts/uat_preflight.sh` changes") and is not attempted here — see Open
  Questions. This design's mechanism therefore keeps the **scenario-level**
  `env_limitation` GAP row for scenario 2 (which is factually correct — the
  scenario, as a whole pipeline_test file, does have an unclosable env
  limitation), and pushes the **EO-level** distinction to metadata the sidecar
  carries for whichever agent actually executes and narrates the scenario
  (UAT-RUNNER), not to `uat_preflight.sh`'s own report shape.

### `local_deps` (the other existing local-tooling check) has a false-negative gap on both specs — confirmed by reading the spec files

`local_deps` (line 363–366) does `re.search(r"docker[ -]compose|docker exec|\bpsql\b",
txt)` against the **spec file's own text**. Grepped both specs directly:

```
grep -in "psql\|docker" web/tests/e2e/pipelines/platform-partition-retention-drop.pipeline.e2e.spec.ts   -> no hits
grep -in "psql\|docker" web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts                          -> no hits (only "tenant_memberships"/db-exec.ts imports)
```

Neither spec file contains the literal strings the regex looks for — both
call helper functions imported from `web/tests/e2e/db-exec.ts`
(`pickEligibleBackdatedMonth` and friends; `insertTenantMembershipSql`,
`runSqlAgainstDevPostgres`), and it is `db-exec.ts` itself (not scanned by
`local_deps`, which only reads `spec_path(s)`) that contains the actual
`docker compose exec -T <service> psql ...` invocation (`db-exec.ts` line 74).
So **`local_deps` reports `OK` (false negative) for both scenarios today** —
without the sidecars this design adds, `uat_preflight.sh` would incorrectly
show both scenarios as environment-ready. This makes the `env_limitation`
sidecar not merely "additive corroboration" here (as it is for the swiftroute
precedent, where `local_deps` never applied at all) but **the only mechanism
that correctly flags these two scenarios** — reinforcing that this design
should not skip it or treat it as optional documentation-only scaffolding.

(Out of scope for this issue: `local_deps`'s regex could be extended to also
scan a spec's local `import ... from '../db-exec'` and grep the imported
helper file, so this false-negative doesn't recur for the next spec that uses
`db-exec.ts` helpers without inlining `psql`/`docker` text. Flagged as an open
question below, not fixed here — it's a `local_deps` correctness fix
independent of the sidecar-granularity question ISS-0901 was filed to answer.)

## Scenario 1 — `platform-partition-retention-drop`: whole-scenario case (matches ISS-0895 precedent exactly)

This is the simple case: the entire pipeline_test file is one BLOCKED unit —
there is no expected outcome within it that can pass independently of the
docker-compose-psql backdating step (`step: 1`/scheduler's `next_period`
setup in `test/fixtures/uat/scenarios/platform/partition-retention-drop.yaml`
feeds all three of EO-001/EO-002/EO-003). No new sidecar field is needed.

**New file:** `test/fixtures/uat/scenario-env-limitations/platform-partition-retention-drop.yaml`

```yaml
scenario_id: platform-partition-retention-drop
applies_to_environments: [qa]
classification: ENV_NOT_SUPPORTED
reason: >
  The pipeline_test (web/tests/e2e/pipelines/platform-partition-retention-drop.pipeline.e2e.spec.ts)
  backdates event-history partitions using helpers imported from
  web/tests/e2e/db-exec.ts (pickEligibleBackdatedMonth and related setup),
  which shell out via `docker compose exec postgres psql` against the local
  dev Postgres instance. There is no HTTP surface in Letflow for a test to
  backdate a partition's period against a real database, and none is planned
  -- constructing an artificially-aged partition is a test-fixture need only,
  not a legitimate product write path. uat_preflight.sh's local_deps check
  does NOT catch this: the spec file's own text contains no literal "docker
  compose"/"psql" string (confirmed by direct grep), only imports from
  db-exec.ts, whose docker/psql invocation lives in that helper file, which
  local_deps does not scan. This sidecar is therefore the mechanism that
  correctly reports this scenario ENV_NOT_SUPPORTED on qa; without it,
  preflight falsely shows OK. Confirmed BLOCKED/ENV_NOT_SUPPORTED against real
  QA in WF05-FULL-20260929
  (test/uat-reports/uat-2026-09-29-WF05-FULL-20260929-PLATFORM.yaml): "Spec
  backdates partitions with `docker compose exec postgres psql`... The
  command failed in this environment. Not a defect in the target."
recorded_by: CODE-DESIGNER
recorded_at: "2026-09-30"
issue_ref: ISS-0901
review: >
  Revisit if Letflow ever ships an admin/test-only HTTP endpoint for
  backdating event-history partitions (unlikely -- deliberately not a product
  capability), or if a disposable per-run QA-equivalent Postgres lane becomes
  available for this one spec's setup step.
```

Field shapes are unchanged from ISS-0895's precedent (`scenario_id`,
`applies_to_environments`, `classification`, `reason`, `recorded_by`,
`recorded_at`, `issue_ref`, `review` — all required except `review`).

## Scenario 2 — `platform-tenant-switch-cache-isolation`: per-expected-outcome case

### The schema extension

Add one **optional** field to the sidecar schema:
`applies_to_expected_outcomes: [<EO-id>, ...]` (list of string, matching the
`id:` values under the scenario's own `expected_outcomes:`, e.g. `EO-001`).

- **Absent** (the field is simply not in the YAML document) → means "applies
  to the whole scenario," identical to today's behavior. This is why the
  existing `swiftroute-tenant-onboarding-happy.yaml` sidecar (no such field)
  and scenario 1's new sidecar above both continue to work unmodified: the
  extension is purely additive, no existing sidecar or reader needs to change
  to stay correct.
- **Present** → scopes the limitation to only the named expected-outcome
  id(s) within that scenario. Every other `expected_outcomes[].id` in the same
  scenario file is understood to be unaffected by this sidecar and must keep
  being executed and verified on every run.

This reuses the existing sidecar file's shape/loader as instructed — no
parallel mechanism, no second sidecar directory, no second classification
vocabulary. It is one new optional key read the same way every other key in
the sidecar dict already is (`yaml.safe_load(raw)` in the PyYAML branch loads
whatever keys are present; nothing needs to change there for the field to be
parseable — see "`scripts/uat_preflight.sh` changes" below for the one caveat,
the non-PyYAML tolerant fallback reader).

### New file: `test/fixtures/uat/scenario-env-limitations/platform-tenant-switch-cache-isolation.yaml`

```yaml
scenario_id: platform-tenant-switch-cache-isolation
applies_to_environments: [qa]
applies_to_expected_outcomes: [EO-001]
classification: ENV_NOT_SUPPORTED
reason: >
  Only EO-001 (cross-tenant cache isolation across a mid-session company
  switch) is env-blocked on qa. Its test block
  (web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts,
  test('EO-001: switching tenants via the in-app control never shows stale
  tenant-A data', ...)) provisions a second tenant's tenant_memberships row
  via db-exec.ts's insertTenantMembershipSql/runSqlAgainstDevPostgres, a
  direct SQL write against the local dev Postgres (itself backed by `docker
  compose exec postgres psql`, per db-exec.ts's own moduledoc) -- REQ-384
  ships no HTTP write path for tenant_memberships
  (lib/letflow/design/req384-tenant-switcher-cache-isolation.md SS1.1, OQ-2).
  EO-002 (test('EO-002: sign-out clears same-tab tenant-selection residue
  (bpm_realm_slug)')) and EO-003 (test('EO-003: a task shows the form it was
  created against, not a later published version')) are independent test
  blocks in the same spec file that write no such row and already PASS
  against real QA (test/uat-reports/uat-2026-09-22-WF02-REQ384-EO001-20260922.yaml;
  test/uat-reports/uat-2026-09-29-WF05-FULL-20260929-PLATFORM.yaml: "EO-002
  (sign-out clears bpm_realm_slug residue) PASS; EO-003 (task shows the form
  version it was created against) PASS"). uat_preflight.sh's local_deps check
  does not catch this spec either, for the same reason as
  platform-partition-retention-drop (the literal docker/psql text lives in
  db-exec.ts, not in this spec file). Do NOT read this sidecar as "the whole
  scenario is blocked" -- EO-002/EO-003 must keep being executed and reported
  on every run; only EO-001 is permanently unrunnable against qa.
recorded_by: CODE-DESIGNER
recorded_at: "2026-09-30"
issue_ref: ISS-0901
review: >
  Revisit if REQ-384 (or a successor requirement) ships an HTTP write path
  for tenant_memberships that a test could call against real QA instead of
  direct SQL (closing OQ-2 in req384-tenant-switcher-cache-isolation.md would
  be the natural trigger), or if a disposable per-run QA-equivalent Postgres
  lane becomes available for this one test block.
```

## `scripts/uat_preflight.sh` changes

**Required change: none.** Both sidecars above are correctly consumed by the
existing loader and existing `env_limitation` check with **zero code
changes** to `scripts/uat_preflight.sh`:

- The PyYAML branch of `parse_env_limitation` (line 182–186) does
  `d = yaml.safe_load(raw) or {}` — it already returns every key present in
  either sidecar file's YAML, including the new
  `applies_to_expected_outcomes` list; nothing needs to change for that key
  to survive parsing.
- The per-scenario check at lines 470–479 only ever reads
  `lim.get("classification")` and `lim.get("reason")` (plus `issue_ref` in
  the owner string) to build the `("GAP", reason, owner)` triple. It ignores
  keys it doesn't know about — `applies_to_expected_outcomes` passing through
  unread is not an error, and the scenario row still correctly reports `GAP`
  for `env_limitation` on `qa` for scenario 2, exactly as it should (the
  scenario, as a whole pipeline_test file, is genuinely not fully green on
  qa — one of its three tests cannot run there). This matches the honest
  scenario-level nature of the gap table established above: the row's `GAP`
  is correct; it is the **reason text and the narrative report** that need to
  carry the "only EO-001" nuance, not the row's status.

**Recommended, optional, non-blocking enhancement** (does not change any
status/exit-code behavior, purely improves the printed reason string so a
human/agent skimming `== DETAIL (non-OK) ==` isn't misled into thinking the
whole scenario was untested): when building the `env_limitation` reason
string at line 474–479, if the matched sidecar has a non-empty
`applies_to_expected_outcomes`, append a short scope note to the reason
(e.g. "(scope: <ids> only; other expected outcomes in this scenario are
unaffected and must still be verified)") before the existing
`"%s: %s" % (classification, reason)` formatting. This is a same-shape,
backward-compatible edit — guarded by `.get("applies_to_expected_outcomes")`
being falsy for every sidecar that doesn't set it (both the existing
swiftroute sidecar and this design's own scenario-1 sidecar), so their
printed reason text is byte-identical to today's. Left to ELIXIR-DEV's
discretion whether to pick this up now or defer; it changes no test/gate
outcome.

**One real gap in the non-PyYAML tolerant fallback reader** (only relevant on
a host without PyYAML installed — `parse_env_limitation`'s `if not d:` branch,
lines 189–196): it hand-regexes only `scenario_id`, `classification`,
`issue_ref`, `recorded_by`, `recorded_at`, plus `applies_to_environments` and
`reason` with dedicated patterns. It does **not** generically capture
arbitrary keys, so `applies_to_expected_outcomes` would be silently dropped in
that fallback path — the sidecar would still correctly produce a `GAP` (since
`classification`/`reason` are captured), but the optional reason-scoping
enhancement above would not have the field available to append in a
no-PyYAML environment. Not fixed here since it is upstream of, not caused by,
this design (ISS-0895's regex fallback already didn't generalize to
arbitrary keys); flagged for whoever picks up the optional enhancement to
extend the fallback regex to also capture `applies_to_expected_outcomes`
(same bracket-list pattern already used for `applies_to_environments`).

## What UAT-RUNNER / WF-05 documentation needs (fixture/doc scaffolding, since `uat_preflight.sh` cannot act on per-EO data itself)

The per-EO nuance is real and load-bearing, but the agent positioned to *act*
on it is UAT-RUNNER (it actually executes each `test()` block and narrates
per-EO verdicts), not `uat_preflight.sh` (which only gates Step 0 readiness at
scenario granularity). Two existing documents need a small, additive wording
update so UAT-RUNNER reads the new field correctly instead of over-applying
the existing whole-scenario rule:

1. **`.claude/agents/uat-runner.md`** (lines ~162–165). Current text: "A
   scenario whose report shows `env_limitation: GAP` must be recorded BLOCKED
   with the sidecar's `reason` and `issue_ref` verbatim... and must not be
   executed against that environment." This is correct for a sidecar with no
   `applies_to_expected_outcomes` (scenario 1, and the existing swiftroute
   sidecar) but would be wrong applied verbatim to scenario 2 — it would tell
   UAT-RUNNER to skip running `EO-002`/`EO-003` too, which is the exact
   failure mode ISS-0901 was filed to prevent. Needs one added sentence: when
   the matched sidecar sets `applies_to_expected_outcomes`, only the named
   expected-outcome id(s) are BLOCKED and skipped; every other
   `expected_outcomes[].id` in the same scenario must still be executed and
   reported with its own real verdict, same as any run where no limitation
   applies. The scenario's overall `verdict:` in the UAT-RUNNER report still
   reads `BLOCKED` (per WF-05's `result_overall: ENV_NOT_READY` rule — one
   BLOCKED EO makes the scenario BLOCKED-by-environment as a whole), but the
   report's `evidence:` must break out each EO's own outcome by id (this is
   not a new convention — `uat-2026-09-29-WF05-FULL-20260929-PLATFORM.yaml`'s
   own entry for this scenario already did exactly this by hand: "3 tests:
   EO-001 blocked at step 03 ...; EO-002 ... PASS; EO-003 ... PASS." This
   design formalizes that existing narrative practice via the sidecar rather
   than introducing a new one).
2. **`docs/agents/workflows/WF-05_uat_run.md`** Step 0 item 3's
   "environment-structural (permanent)" bullet (lines 78–85). Add one
   sentence: a sidecar's `applies_to_environments`/`review` condition
   (existing text) may additionally be scoped to specific expected outcomes
   via `applies_to_expected_outcomes`; when present, only those expected
   outcomes are exempted from Step 0 remediation and are reported
   BLOCKED-by-environment — every other expected outcome in the same scenario
   is not exempted and must be verified normally by UAT-RUNNER.

Both are prose/documentation edits, not code — DOC-UPDATER's usual territory,
flagged here so the change doesn't get silently dropped between this design
and implementation, per ISS-0895's own precedent of listing doc-only edits
alongside code ones in "Files touched."

## Files touched by this design (for the next agent)

- NEW: `test/fixtures/uat/scenario-env-limitations/platform-partition-retention-drop.yaml`
- NEW: `test/fixtures/uat/scenario-env-limitations/platform-tenant-switch-cache-isolation.yaml`
- OPTIONAL/RECOMMENDED (non-blocking): `scripts/uat_preflight.sh` — fold
  `applies_to_expected_outcomes` into the `env_limitation` reason string
  (lines ~474–479); no behavior/status/exit-code change, purely cosmetic
  reason-text improvement.
- RECOMMENDED (doc scaffolding, prose only): `.claude/agents/uat-runner.md`
  (~lines 162–165) and `docs/agents/workflows/WF-05_uat_run.md` (Step 0 item
  3, ~lines 78–85) — both get one added sentence about
  `applies_to_expected_outcomes`, per "What UAT-RUNNER / WF-05 documentation
  needs" above.
- NOT touched: `lib/letflow/` (nothing here is backend code — both scenarios'
  gaps are test-fixture-tooling gaps, not product gaps)
- NOT touched: `test/fixtures/uat/scenarios/platform/partition-retention-drop.yaml`
  and `test/fixtures/uat/scenarios/platform/tenant-switch-cache-isolation.yaml`
  (both carry the same "ported verbatim... do not edit the ported content"
  header as the swiftroute scenario ISS-0895 respected; this design does not
  touch either)
- NOT touched: `web/tests/e2e/pipelines/platform-partition-retention-drop.pipeline.e2e.spec.ts`
  and `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts` (the specs
  themselves are correct as authored — real, intended env-only limitations,
  not spec bugs)

## Invariants

- `applies_to_expected_outcomes` is optional and purely additive — its
  absence means "whole scenario," preserving byte-for-byte backward
  compatibility with every sidecar written before this design (the existing
  `swiftroute-tenant-onboarding-happy.yaml` and this design's own scenario-1
  sidecar both omit it and behave exactly as before).
- `scripts/uat_preflight.sh`'s gap table stays scenario-level; this design
  does not claim or fake per-EO columns there. The row-level `GAP` for
  `env_limitation` on scenario 2 is correct precisely because the scenario as
  a whole genuinely has an env limitation (one of its tests cannot run) — the
  field's job is to prevent the *narrative*/execution layer from
  over-generalizing that row-level `GAP` into "skip the whole spec," not to
  change what the row itself reports.
- A sidecar's `applies_to_expected_outcomes`, when present, must list ids
  that literally match `expected_outcomes[].id` values in the corresponding
  ported scenario YAML (`EO-001`, not e.g. the pipeline_test's own `test()`
  title text) — this is what lets UAT-RUNNER cross-reference the sidecar
  against both the scenario file's `expected_outcomes:` and its own executed
  test-block names without inventing a third id vocabulary.
- Every sidecar still carries `issue_ref` (ISS-0901 for both new files here)
  so a recurring GAP row is traceable to a filed decision, per WF-05 Step 0's
  existing rule ("do not re-file it as a new issue — cite the sidecar's
  issue_ref instead").
- Neither ported scenario YAML nor either pipeline_test spec file is edited
  by this design.

## Open questions

1. **Should `scripts/uat_preflight.sh` eventually gain real per-expected-outcome
   check granularity** (parse each scenario file's `expected_outcomes:` list,
   add a second axis to the gap table / JSON summary keyed by
   `<scenario_id>/<EO-id>`)? That would let the script itself report "GAP:
   EO-001 only" instead of relying on the reason string's prose. This is a
   materially larger schema change (new parsing, new report columns, a
   decision about how "3 of 5 defined `expected_outcomes` don't correspond to
   any authored `test()` block" — see next question — should even be
   represented) than this issue's scope. Flag for a future issue if repeat
   cases like scenario 2 become common enough that scenario-level-only
   reporting stops being adequate.
2. **`tenant-switch-cache-isolation.yaml`'s own `expected_outcomes:` defines
   five ids (`EO-001`..`EO-005`), but `tenant-cache.pipeline.e2e.spec.ts` only
   contains three `test()` blocks (`EO-001`, `EO-002`, `EO-003`)** — the
   spec's own header comment (lines 104–133) states EO-004 and EO-005 "already
   have working, existing coverage" elsewhere, but this design did not verify
   that claim by locating that other coverage. Whether EO-004/EO-005 are
   genuinely covered by some other spec, or are silently untested, is outside
   ISS-0901's scope (which was specifically about the docker-compose-psql
   env limitation, not overall EO coverage completeness) — worth a separate
   issue if not already tracked.
3. **The `local_deps` false-negative** (neither spec's own text contains
   `docker compose`/`psql`; both only import helpers from `db-exec.ts` which
   does) is a real, independent correctness gap in `uat_preflight.sh` that
   this design's sidecars work around rather than fix. Extending `local_deps`
   to also scan a spec's local relative imports (e.g. `../db-exec`) for the
   same pattern would make this class of false-negative self-detecting for
   future specs, instead of requiring a human/agent to notice and hand-author
   a sidecar every time. Not fixed here — flagged as a candidate follow-up
   issue.
4. **The recommended reason-string enhancement and the two doc-wording
   updates are not strictly required for correctness** (the sidecars work,
   and produce a correct `GAP` row, without them) — they exist purely so a
   future ORCH/UAT-RUNNER run reading the preflight report or
   `.claude/agents/uat-runner.md` doesn't misapply the existing
   whole-scenario "must not be executed" rule to scenario 2's EO-002/EO-003.
   Left to CODE-DESIGN-VALIDATOR/ELIXIR-DEV's judgment whether all three are
   picked up together with the two new sidecar files or deferred — but
   deferring the two doc-wording updates carries real risk (a future run
   could otherwise skip re-verifying EO-002/EO-003 by over-reading today's
   uat-runner.md text), so this design recommends they ship together with the
   sidecars rather than being treated as separately schedulable polish.
