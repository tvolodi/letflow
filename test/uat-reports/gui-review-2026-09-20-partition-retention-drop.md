# GUI review: `partition-retention-drop` (PW-06)

Date: 2026-09-20
Agent: ORCH
Sweep position: 8th of ~15 scenarios in today's systematic GUI-review sweep.
Scenario: `test/fixtures/uat/scenarios/platform/partition-retention-drop.yaml`
Process applied: "review real screens before writing a blind Playwright spec"
(same process as `gui-review-2026-09-20-migration-partial-failure-resume.md` and
the earlier scenarios in this sweep).

## Outcome: BLOCKED / UNBUILT_FEATURE

The scenario's own stale NOTE (ISS-0527) already flagged its `pipeline_test`
(`web/tests/e2e/pipelines/platform-partition-retention-drop.pipeline.e2e.spec.ts`)
as an aspirational forward-reference to a Playwright spec that was never
authored, gated on the same missing feature the scenario's steps exercise.
Per this run's instructions, that note was verified independently rather than
trusted — by reading current `lib/letflow/` source, migrations, and every
relevant decision/design/issue record — not assumed.

## What was checked, and what it showed

**Does an events table partitioning mechanism exist?**
No. `priv/repo/migrations/20260816120001_create_events.exs` and
`20260816120005_create_events_archive.exs` both create plain, unpartitioned
tables — no `PARTITION BY RANGE`, no monthly partitions, confirmed by grepping
every migration file for `PARTITION BY`/`partition_by`/`pg_partman`/
`DROP PARTITION` (case-insensitive, whole repo) — no functional hits outside
design-doc prose and a design-decision file discussing the *deferral*.

**Does a single-step (DROP/DETACH-style) retirement operation exist?**
No. `lib/letflow/event_store.ex`'s `archive/1` (around line 1090) computes a
target `event_id` set from `event_retention_policies` and moves matching rows
with a row-level insert-then-delete (`archive_phase1_insert`/
`archive_phase2_delete`) — the exact row-by-row mechanism this scenario's
description explicitly contrasts against ("until now retiring it meant moving
records one at a time... this scenario checks that a month of expired history
is retired in a single step").

**Is this an oversight, or a deliberate, already-recorded decision?**
Deliberate and already recorded, twice over:
- `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision C point 2
  explicitly defers partitioning ("unpartitioned first ... rather than
  speculatively partitioning a table with no rows yet").
- `docs/issues/ISS-0014.yaml` (resolved 2026-08-17) already weighed three
  options for retention mechanics and explicitly rejected porting R-Co's
  whole-partition `PartitionRetention.runArchivalAging()`/`runEphemeralDrop()`
  model *at that time*, specifically "because it would force partitioning
  early, contradicting 0003 Decision C's deliberate deferral, and would need
  REVIEWER sign-off / a new decision record" — i.e. flagged as a real future
  item, not closed off.
- `lib/letflow/design/req188-recurring-timers-and-retention.md` restates the
  same deferral on the scheduler side (R-Co's `partition_maintenance.zig`/
  `partition_retention.zig` are explicitly NOT ported).

**Protected-record exemption logic?**
Partially modeled, not implemented for partition-level retirement:
`Letflow.EventStore.RetentionPolicy` already has a `:keep_forever` policy
value per `event_type` (global, not per-tenant), but nothing in `archive/1`
or elsewhere implements the *partition*-level protected-record exemption this
scenario's EO-002 requires (a protected record surviving a whole-partition
drop is a materially different mechanism than surviving a row-level DELETE
loop that already respects the policy).

**Operator-facing retention/retirement screen in `web/src/`?**
No. Grepping `web/src/` for retention/retirement/partition-drop screens
returned no functional hits (the three files matched by a broad grep were
unrelated: `BrandingProvider.test.tsx`, `DefinitionEditorPage.tsx`,
`definitionDraftStore.ts` — false positives on generic substring matches, not
a retirement screen).

## Conclusion

The feature genuinely does not exist, in whole or in part, and building it
would require reversing/extending a standing decision record (0003 Decision C)
— explicitly the kind of change CLAUDE.md's "don't silently re-decide what a
decision record already settled" rule reserves for REVIEWER sign-off and
likely a new/amending decision record, not something to build inline during a
UAT-GUI-review dispatch. No screens exist to review, so no screenshots were
taken and no flow was driven against `https://qa.bizdala.com` — there was
nothing real to drive.

## Filed

- `docs/requirements.yaml` **REQ-376** (owner `ELIXIR-DEV`, stage S2, status
  `pending`, `depends_on: [REQ-023, REQ-026]`) — resolve the deferred
  partitioning decision (new/amending decision record + REVIEWER sign-off),
  the partitioned migration(s) with ahead-of-need next-partition creation, the
  single-DDL retirement function (EO-001), protected-record exemption
  (EO-002), and post-retirement instance-replay proof (EO-003). Explicit scope
  fence against inventing a general "partition any table" framework, and an
  explicit requirement to state `archive/1`'s relationship to the new
  mechanism (coexist or be retired/replaced) rather than leaving both silently
  in place.
- `docs/requirements.yaml` **REQ-377** (owner `FRONTEND-DEV`, stage S8, status
  `pending`, `depends_on: [REQ-376]`) — the operator-facing retirement screen,
  including authoring and passing this scenario's own named `pipeline_test`
  once the screen exists.

## Fixed vs filed

Nothing was fixed in this dispatch — there is no existing broken screen or
small defect to patch; the entire mechanism is absent by deliberate design
choice. Both gaps (backend mechanism, frontend screen) are filed as
appropriately-sized requirements rather than attempted inline, matching this
sweep's own precedent for architecturally significant gaps
(REQ-374/REQ-375).

## Status housekeeping

- Scenario fixture's `pipeline_test` NOTE block extended (not removed — the
  feature is not real) with a dated addendum citing REQ-376/REQ-377 and this
  report.
- `docs/status/requirement_status.v20.yaml` — appended a `SCOPE-CHANGE` done
  event (`2026-09-20T01:20:44Z`) recording this finding; volume stays at 12
  entries / 786 lines / 50187 bytes, well under the roll ceiling.
- `docs/status/requirement_status.index.yaml` — volume 20's entry count and
  note updated to reflect the new append.
- Verified `mix letflow.check_req_id_collision` (OK, no collision) and
  `mix letflow.check_requirements_registration` (344 entries = 342 registered
  + 2 deferred + 0 neither + 0 unclassified, no new gate failures) both pass
  with REQ-376/REQ-377 in place.

## Spec status

No permanent Playwright regression spec was authored — there is no shipped
screen to write one against. `web/tests/e2e/pipelines/
platform-partition-retention-drop.pipeline.e2e.spec.ts` remains unauthored,
now explicitly the responsibility of REQ-377's acceptance criteria once the
feature ships.
