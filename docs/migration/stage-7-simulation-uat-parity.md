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

**`tests/differential/`'s corpus is ported as a regression suite, not a
differential one** (REQ-209). R-Co's `differential_test.zig` diffed a
vendored CEL library against `src/expr` as its own now-completed EXP-102
cutover gate. Letflow never had two condition-evaluator implementations —
`lib/letflow/engine/expr.ex` is the direct port of R-Co's post-cutover
`src/expr` only — so the corpus's remaining value is as golden-value
regression coverage for `expr.ex`, not a live differential.

## Decisions

None expected — this stage validates prior decisions rather than
making new ones.

## REVIEWER sign-off

(Pending — REQ-210 records this stage's REVIEWER sign-off entry once
the batch completes.)
