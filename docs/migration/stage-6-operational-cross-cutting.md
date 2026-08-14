# Stage 6 — Operational cross-cutting

Status: not started. Depends on: S4. Requirements: none expanded yet.

## Scope

Port the remaining cross-cutting subsystems not covered by earlier
stages:

- `src/scheduler` (5 files)
- `src/secrets` (7 files) + `src/secrets/integration`
- `src/obs` (5 files) — observability/metrics
- `src/webhook` (3 files)
- `src/dlq` (1 file) — dead-letter queue
- `src/repository` (6 files)
- `src/expr` (7 files) — expression evaluation
- `src/ordering` (4 files)

These are grouped together because each is relatively self-contained
and none blocks S3/S4's critical path, but each still needs its own
requirement(s) once this stage starts — "cross-cutting" describes
their relationship to the rest of the system, not that they're
interchangeable or low-effort individually.

## Decisions

Likely needs a decision file for `src/secrets` specifically (secret
storage/retrieval backend choice) — defer until this stage starts.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
