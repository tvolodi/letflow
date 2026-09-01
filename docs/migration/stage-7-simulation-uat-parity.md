# Stage 7 — Simulation & UAT parity

Status: active. Depends on: S4, S5, S6. Requirements: `REQ-205` …
`REQ-210` (initial batch, expanded 2026-08-31). Covers the 11
tenant-business scenarios (SwiftRoute/Vortex/Meridian) and the
15-entry condition-evaluation regression corpus; the 18-file
`tests/simulation/scenarios/platform/` corpus is explicitly out of
scope for this batch — see REQ-210's own scope note and its own
future-follow-up recording in this file's REVIEWER sign-off section
once that requirement runs.

## Scope

Port what's portable from R-Co's `tests/simulation/` (including
`tests/simulation/companies/`, `tests/simulation/scenarios/`),
`tests/differential/` (including `tests/differential/corpus/`), and
`tests/uat-reports/` — enough to re-run R-Co's existing business
scenarios against the Elixir backend as a correctness gate.

R-Co's own business-owner scenario agents give the concrete scenarios
to reproduce: SwiftRoute Ltd (logistics), Vortex Manufacturing (ISO
9001 quality/manufacturing), Meridian Capital (BaFin-regulated
lending, quorum 2-of-3) — see R-Co's `.claude/agents/bo-swiftroute.md`,
`bo-vortex.md`, `bo-meridian.md` for what each tenant's scenarios
actually exercise.

This stage is explicitly a correctness gate on S4/S5/S6's combined
output, not new functionality — it should be scoped after those
stages, not before.

**REQ-205's harness is not `Letflow.Routers.SimulationTest`.** R-Co's
`src/api/routes/simulation_test.zig` / `src/simulation/scenario_runner.zig`
(the source `Letflow.Router`'s own "Deferred routes" table names against
that module) is a design-time dry-run tool for validating a candidate
process *definition* against a schema/event-trace assertion set — a
different subsystem from the business-scenario corpus this stage runs.
REQ-205 states this distinction explicitly in its own moduledoc; that
router slot stays unmounted until whichever future requirement actually
builds it.

**REQ-205 done (2026-08-31, WF02-REQ205-20260831).** `Letflow.Simulation.Seed`
and `Letflow.Simulation.Runner` (test-support) ship the harness this stage's
remaining requirements run scenarios through, with the `api`/`gui` execution
split working (real HTTP for `api` steps, `DEFERRED_TO_S8` recorded — never
silently skipped, never run as an `api` step — for `gui` steps). All 8
acceptance criteria independently re-verified by RELEASE-VALIDATOR; full
detail in `handoffs/WF02-REQ205-20260831/release-validation-report-20260831.md`.

**HARD BLOCKING PREREQUISITE for REQ-206 (flagged by RELEASE-VALIDATOR at
REQ-205's Step 5, not a deferrable cleanup).** The 12 company/org/process
fixture files under `test/fixtures/simulation/{swiftroute,vortex,meridian}/`
are **SYNTHETIC, self-authored data**, honestly disclosed in each file's own
header comment — NOT a byte-for-byte port of R-Co's
`tests/simulation/companies/` tree. ELIXIR-DEV found that source genuinely
unreachable from the Linux sandbox this run executed in (no `/mnt/c` mount,
no filesystem trace anywhere on the box), independently reconfirmed by
RELEASE-VALIDATOR's own fresh search — even though some earlier session/host
*did* have R-Co filesystem access when REQ-ANALYST drafted REQ-205's own
requirement text (which cites literal file/line counts from it), so this is a
routing gap, not permanently lost data. `Letflow.Simulation.Seed`/`Runner`
depend only on fixture **shape** (never on specific R-Co values, confirmed by
reading both modules directly), so swapping in real content is a data-only
change requiring **zero code changes** to either module. REQ-206/207/208 all
carry real R-Co scenario YAML referencing specific `actor_id` values (e.g.
`actor-swiftroute-lena`) — those references will **not resolve** against the
current synthetic fixtures. **REQ-206 must not start until the real 12 fixture
files are ported** from a host with `c:\Users\tvolo\dev\ai-dala\R-Co\` access
(not this sandbox) — tracked as a follow-up in `docs/issues/ISS-0382.yaml`
("Port REQ-205's 12 simulation fixture files from real R-Co source (blocks
REQ-206)"), registered by ORCH at Step Final.

**`tests/differential/`'s corpus is ported as a regression suite, not a
differential one** (REQ-209). R-Co's `differential_test.zig` diffed a
vendored CEL library against `src/expr` as its own now-completed EXP-102
cutover gate. Letflow never had two condition-evaluator implementations —
`lib/letflow/engine/expr.ex` is the direct port of R-Co's post-cutover
`src/expr` only — so the corpus's remaining value is as golden-value
regression coverage for `expr.ex`, not a live differential.

**REQ-206 done (2026-09-01, WF02-REQ206-20260901).** All 4 SwiftRoute
scenarios run via REQ-205's harness: `swiftroute-tenant-onboarding-happy`
(all 5 steps `DEFERRED_TO_S8`, disposition `:executed`), `swiftroute-
shipment-high-value-happy` (5 real API steps, all 4 expected outcomes
evaluated against real queried state), `swiftroute-shipment-ops-timeout-
escalation` (step 2 recorded `:skip`/severity `:minor` — the scenario's
own documented fallback — because `POST /api/v1/instances/:id/advance-timer`
does not exist in `Letflow.Router` today; steps 1 and 3 ran for real), and
`swiftroute-shipment-attach-delivery-note` (disposition `:unbuilt_feature`,
zero steps executed — no attachment/document-upload API exists in either
Letflow or R-Co's own `src/`). `Letflow.Simulation.Runner` extended
additively with the `:skip`/`:unbuilt_feature` dispositions to support
these; REQ-205's own 15 pre-existing simulation tests re-run unchanged
(15/15 pass) to confirm no regression. The 4 scenario YAMLs are disclosed-
synthetic (each file's own header names the exact unreachable R-Co source
path), matching REQ-205's established disclosure convention — RELEASE-
VALIDATOR independently re-verified all 6 acceptance criteria and recorded
a non-blocking caveat: the design doc's own recommendation to file a
follow-up issue mirroring `ISS-0388` (port the real
`tests/simulation/scenarios/*.yaml` scenario content once R-Co access is
available) reached only the design doc and step-01 handoffs, not any
later handoff — re-elevated for ORCH to act on at Step 6/Final. Two
findings reported to ORCH: the missing `advance-timer` endpoint (already
tracked, referenced by REQ-208/209) and the missing attachment/document
subsystem. Full detail:
`handoffs/WF02-REQ206-20260901/release-validation-report-20260901.md`.

**REQ-207 done (2026-09-01, WF02-REQ207-20260901).** All 4 Vortex
Manufacturing scenarios run via REQ-205's harness:
`vortex-production-order-budget-threshold` (4 expected outcomes evaluated
against real queried state, including `assignee_ref: role-controller`
controller-approval routing on the budget-exceeded path — not a silent
fallback to plain line-assignment), `vortex-supplier-quality-deviation-
critical` (disposition `:executed`; a new `:audit_event_ordering`
`Letflow.Simulation.Runner` verification method asserts two audit events'
real `DateTime.compare/2` ordering rather than inferring order from final
status — EO-001 quarantine-before-severity-escalation confirmed),
`vortex-false-positive-compensation` (disposition `:executed`, confirmed
reaching `end-false-positive` specifically, not merely `end-closed`), and
`vortex-entity-list-filter-and-page` (disposition `BLOCKED_ON_DEPENDENCY`,
citing the specific missing subsystem — `lib/letflow/entities.ex` and
`entity_query.ex` do not exist, `Letflow.Router` still reserves them). A
genuine AC3 coverage gap was found and fixed during design/test authoring:
`lib/letflow/engine/transition.ex`'s `dispatch_end/3` unconditionally
drops the completed token, so `activated_nodes` derived from remaining
tokens is `[]` for every terminal END node alike and cannot by itself
distinguish `end-false-positive` from `end-closed` — fixed with a
structural cross-check against the seeded graph's own edge target instead.
RELEASE-VALIDATOR independently re-verified all 6 acceptance criteria
(own `scripts/test_parallel.sh` re-run, own reproduction of the AC3
mutation check by editing the expected end-node id and confirming a
genuine, non-vacuous failure, then reverting; own read of `transition.ex`
confirming the structural cross-check is load-bearing) and PASSED. 2
follow-up findings confirmed real, flagged for ORCH to file at Step Final:
(1) a pre-existing Engine defect — `Ecto.Multi` `:task_records` key
collision on synchronously-completing `SUB_PROCESS` children within the
same hop-chain transaction, attributed to REQ-062, affecting
`lib/letflow/engine.ex` / `lib/letflow/engine/sub_process.ex` (confirmed
pre-existing: `git diff main...HEAD -- lib/` shows zero lines changed in
either file); (2) OQ-5 — R-Co scenario-corpus reachability for the 4 real
Vortex scenario YAMLs under `test/fixtures/simulation/vortex/scenarios/
*.yaml`, same class as `ISS-0388` but not yet fixed for scenario-
definition files specifically (`ISS-0388`'s resolution covered only the
12 `company/org_structure/process_*.yaml` fixture files; this diff's 4
scenario YAMLs are self-authored/synthetic, disclosed in the design doc's
own §0.2).

**REQ-208 done (2026-09-01, WF02-REQ208-20260901).** All 3 Meridian
Capital scenarios run via REQ-205's harness:
`meridian-loan-origination-above-threshold` (real 3-way
`PARALLEL_GATEWAY` fork confirmed created from real queried task state
-- both non-KYC branches confirmed real, queried, PENDING `HUMAN_TASK`s
-- then genuinely truncated on a real HTTP 500 reproducing a
pre-existing Engine defect: `join_counters: %{}` is hardcoded
unconditionally in `lib/letflow/engine.ex`'s `build_instance_state/3`
(confirmed byte-for-byte identical on `origin/main` before this
branch's work; root cause: REQ-054/SnapshotWriter serializes
`join_counters` into `instance_state_snapshots`, but
`Engine.complete_task/3`'s own state-rebuild hot path never reads it
back), so no `PARALLEL_GATEWAY` split can currently converge across two
separate task-completion HTTP calls), `meridian-loan-origination-below-
threshold` (identical genuine reproduction), and `meridian-regulatory-
compliance-review-bafin` (steps 1/2 real against real queried state;
step 3 recorded BLOCKED citing REQ-206's already-filed `ISS-0389`
advance-timer finding rather than a duplicate -- the report states this
same gap now blocks scenarios in two different tenant batches).
`Letflow.Simulation.Runner` extended additively with a new
`:no_task_of_type` verification method (queries every task status, no
filter -- confirmed non-vacuous via the BaFin scenario's own positive
control asserting `:fail` against a task that DOES exist and is
COMPLETED, not pending) and a new `:blocked` disposition (requires
`blocked_by`, raises loudly if absent, same discipline as the
pre-existing `:skip` branch); REQ-205's own simulation tests re-run
unchanged, full `test/letflow/simulation/` at 28/28. RELEASE-VALIDATOR
verdict: **ACCEPT WITH CAVEAT** -- AC1 and AC2 are recorded **PARTIALLY
MET**, not blanket MET: the fork/task-creation portion of AC1 and the
defect reproduction itself are genuinely verified (post-failure state
re-queried and confirmed uncorrupted -- task still PENDING, instance
still ACTIVE), but the committee-vote route, quorum 2-of-3, disbursement
(AC1) and EO-002's negative committee-task assertion (AC2) are honestly
reported as unverified rather than fabricated, since the defect
truncates both scenarios before those paths become reachable -- not
fixable within this test/test-support-only requirement's own scope
(zero `lib/` files touched, confirmed by `git diff`). AC3/AC4/AC5/AC6
all fully MET (AC4: REQ-199 independently re-confirmed `status: done` at
execution time, no caveat needed). Two new Engine defects found and
deferred to ORCH for filing at Step Final (per `ISSUE_QUEUE.md`,
confirmed neither self-assigned an ISS id): (1) the `join_counters`
defect above, BLOCKER severity, `affected_files`
[`lib/letflow/engine.ex`, `lib/letflow/engine/transition.ex`],
`related: [REQ-054, REQ-208]` -- a platform-wide gap blocking any future
requirement needing a real cross-call parallel join; (2)
`walk_to_gateway/3` fails a fork branch containing a multi-outgoing-edge
node (e.g. an `EXCLUSIVE_GATEWAY`) before reaching its join, reproduced
at `test/letflow/simulation/req208_meridian_test.exs` lines 117-134.
Full detail:
`handoffs/WF02-REQ208-20260901/release-validation-report-20260901.md`.

## Decisions

None expected — this stage validates prior decisions rather than
making new ones.

## REVIEWER sign-off

(Pending — REQ-210 records this stage's REVIEWER sign-off entry once
the batch completes.)
