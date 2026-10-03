# ISS-0970 — Event-ordering decision (retroactive stub)

DOC-UPDATER, 2026-10-03, per ISS-0985. This file is cited by path in four
already-merged locations (`docs/issues/ISS-0970.yaml`'s resolution text
×2, `docs/status/requirement_status.v25.yaml`, and both vortex UAT
fixtures' exception headers) but was never actually committed when
ISS-0970 was resolved (PR #2145, commit 8f82d388) — confirmed via
`git log --all -- lib/letflow/design/iss0970-event-ordering-decision.md`
returning nothing prior to this commit. This stub retroactively captures
the decision those citations describe; it documents a decision already
made and shipped, not a new design, so no separate
CODE-DESIGN-VALIDATOR cycle applies (per ISS-0985's acceptance
criteria and ISS-0970's own resolution text, which already records that
CODE-DESIGN-VALIDATOR passed on this decision at the time).

## Decision: Option B — sequence-based ordering

Order history events by the already-existing, genuinely monotonic,
DB-assigned sequence columns on the events table —
`sequence_number` (per-instance, assigned under `FOR UPDATE` lock) and
`global_seq` (tenant-wide `bigserial`) — instead of introducing a new
timestamp/logical-clock mechanism. These columns are real schema
columns, not derived or computed at read time, and were already
correctly relied on by a sibling scenario (`sim-dev-fp-001` EO-001)
before this decision generalized the approach to
`supplier-quality-deviation-critical.yaml`'s EO-004 (and later,
mechanically, to `production-order-above-threshold.yaml`'s EO-004 per
ISS-0971).

Option A (stamp events with transaction-logical time, or emit a
`TASK_CREATED` event) was rejected: it would have required either a new
clock/stamping mechanism in `lib/letflow/engine.ex`'s write path or a new
seeded event type, for no benefit over the ordering primitive the schema
already provides.

## Confirmed facts this decision rests on

- `sequence_number` and `global_seq` are real, monotonic, DB-assigned
  columns on the events table (not application-computed) — `global_seq`
  is tenant-wide `bigserial`; `sequence_number` is assigned per-instance
  under a `FOR UPDATE` lock on the instance's sequence row, mirroring
  `Letflow.EventStore`'s insert-if-absent + `SELECT FOR UPDATE` pattern
  (the same precedent ISS-0979 later reused for
  `Letflow.Audit.ChainLock`).
- `TASK_CREATED` does not exist in the event-type registry at all.
  `TASK_COMPLETED` is a real, seeded event type, but was the wrong event
  type for the `SERVICE_TASK` node in question — the correct event type
  for a completed service task is `SERVICE_TASK_COMPLETED`, seeded at
  `lib/letflow/tenant_provisioning.ex:1149` and referenced in
  `lib/letflow/engine.ex:3766`.
- History event *timestamps* reflect insert time, which can land after a
  causally-later row's own insert within the same transaction (observed
  ~4ms inversion in the original UAT finding) — timestamps alone cannot
  prove ordering; `sequence_number`/`global_seq` can.

## Root cause and fix (restated from ISS-0970's resolution)

`supplier-quality-deviation-critical.yaml`'s EO-004 asserted
`TASK_COMPLETED`/`TASK_CREATED` event-type names that were either
nonexistent or the wrong type for the node being verified. Fix: reworded
EO-004's description/verification block to assert ordering via
`sequence_number`/`global_seq` instead of event-type name plus
timestamp, with an exception note added to the fixture's own
byte-identical-to-ported-R-Co header comment. Pure test-fixture change;
no `lib/letflow/` code touched, so SECURITY-REVIEWER was correctly ruled
not needed at the time.

## Scope note

This stub exists solely to satisfy ISS-0985's acceptance criterion that
no citation point to a design-doc path absent from disk. It is not a new
design and authorizes no new implementation work.
