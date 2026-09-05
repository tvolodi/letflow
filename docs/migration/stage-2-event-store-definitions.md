# Stage 2 — Event store & workflow definitions

Status: in progress. Depends on: S1. Requirements: REQ-022, REQ-023,
REQ-024, REQ-025, REQ-026, REQ-027, REQ-028, REQ-029, REQ-030, REQ-031,
REQ-032, REQ-033, REQ-034, REQ-035, REQ-036, REQ-037, REQ-038, REQ-039,
REQ-040, REQ-041, REQ-042 (`docs/requirements.yaml`) all done.

## Scope

PROVENANCE (historical, not current decision authority):
Port `src/event_store/` (3 files: `store.zig`, `platform.zig`,
`registry.zig`) and `src/definition/` (16 files, corrected from an
earlier stale 12-file count — confirmed directly against
`C:\Users\tvolo\dev\ai-dala\R-Co\src\definition\`: `graph.zig`,
`promotion.zig`, `promotion_conflict.zig`, `promotion_digest.zig`,
`promotion_plan.zig`, `promotion_review.zig`, `rollback.zig`,
`sandbox_pool.zig`, `export_import.zig`,
`service_scope_validator.zig`, `snapshot.zig`, `store.zig`,
`fixture_loader.zig`, `assertion_rerun.zig`, `pack_update.zig`,
`sub_process_interface.zig`). The prior list omitted
`promotion_conflict.zig`, `promotion_digest.zig`,
`promotion_review.zig`, and `sub_process_interface.zig`.

## Early findings to keep in mind while designing

Two findings from early development (their full write-ups have since
been retired, see `docs/status/requirement_status.yaml` for the
removal record) still apply directly here:

- **Process-per-instance vs. row-based state:** for a low-complexity
  approval feature (two booleans and a status flag), a plain Postgres
  row with a state column was operationally simpler than a supervised
  `:gen_statem` process per instance, and provided a *stronger*
  durability guarantee (survives a crash, not just "the id stays
  reachable") for less code and no supervision surface. The
  process-per-instance case gets stronger specifically for workflows
  with expensive-to-reconstruct in-memory state, timers/scheduled
  work, backpressure between steps, or ownership of an OS-level
  resource with no natural row representation — properties the event
  store and workflow-definition data (versioning, promotion, rollback,
  snapshots) plausibly do have, unlike the earlier approval feature.
  Weigh this stage's process-vs-row choices against which side of that
  line each piece of state actually falls on, not by default.
- **Static-typing gap:** with a small early codebase and unusually
  high review intensity, zero bugs were caught only by property tests
  or at runtime that a stricter type system would have caught at
  compile time — the property test read as a nice-to-have safety net,
  not load-bearing infrastructure, under those conditions. That
  conclusion was explicitly conditioned on the codebase staying small
  and review staying intensive; event/definition schema design is
  exactly the kind of larger, more complex surface where that
  conclusion may not hold. Don't assume the property test is
  sufficient here without re-checking as the schema grows.

## Decisions

Inherits `docs/migration/decisions/0003-ecto-schema-strategy.md` from
S0 for the event-store table shape specifically. Add a stage-specific
decision file if workflow-definition versioning/promotion needs a
choice 0003 didn't cover.

## REVIEWER sign-off

(None yet — S2 is in progress; the full per-requirement REVIEWER sign-off
section is populated at the S2 stage gate (WF-04), same as
`stage-1-identity.md`'s was for S1, not incrementally per requirement.)
