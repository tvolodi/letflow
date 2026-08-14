# Stage 7 — Simulation & UAT parity

Status: not started. Depends on: S4, S5, S6. Requirements: none
expanded yet.

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

## Decisions

None expected — this stage validates prior decisions rather than
making new ones.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
