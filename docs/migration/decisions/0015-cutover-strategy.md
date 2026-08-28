# 0015 — Frontend cutover strategy is deferred pending S7 parity evidence

Status: decided (2026-08-28). Owner: REVIEWER.

## Question

`docs/migration/stage-8-frontend-cutover.md` leaves one open decision:

- Big-bang cutover from Zig backend to Letflow backend, or
- gradual/dual-running cutover.

`REQ-123` requires this to be decided from S7's correctness signal, not from
preferences.

## Decision

**S7's signal is currently insufficient to choose big-bang or gradual/dual-running.**
The recorded decision is to defer selecting either path until S7 parity evidence
exists.

This is an explicit decision, not a placeholder: do not run cutover while this
record stands in this state.

## Evidence Used

The decision is based on concrete, named S7 artifacts:

1. `docs/migration/stage-7-simulation-uat-parity.md` currently states:
   - `Status: not started`
   - `Requirements: none expanded yet`
   - `REVIEWER sign-off: (None yet)`
2. `docs/migration/stage-8-frontend-cutover.md` still marks cutover strategy as
   open and explicitly says it needs a real S7 correctness signal.

No simulation/uat parity output exists yet that can distinguish cutover risk
between big-bang and dual-running. Choosing either now would be guessing.

## Zig Backend Fate (Condition, Not Date)

The Zig backend is deprecated when all of the following are true:

1. S7 parity evidence is produced for the stage's named simulation/UAT scope.
2. The parity outcome is accepted by REVIEWER/RELEASE-VALIDATOR as sufficient for
   cutover.
3. S8 integration gates remain green against Letflow's API for the cutover path
   selected in the follow-on decision.

Until those conditions are met, Zig remains the fallback implementation and is not
decommissioned.

## Missing Evidence Required To Settle Big-Bang vs Dual-Running

The follow-on decision must include, at minimum:

1. S7 replay results for the stage's simulation/UAT corpus against Letflow,
   including pass/fail outcomes and parity deltas.
2. A route/behavior delta inventory showing any remaining contract mismatches
   relevant to frontend traffic.
3. Operational rollback evidence for the chosen cutover mode, validated in a
   reproducible run.

When that evidence exists, this record is revised to pick either big-bang or
gradual/dual-running explicitly.
