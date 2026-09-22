# 0037 — Event-store monthly partitioning and whole-partition retirement

Status: **DRAFT — pending REVIEWER sign-off** (see sign-off block at the end of this
file). Owner: CODE-DESIGNER (draft), REVIEWER (sign-off), ELIXIR-DEV (implements).
Filed for REQ-376.

Amends: `0003-ecto-schema-strategy.md` Decision C point 2 (the partitioning
deferral). Cross-references: `docs/issues/ISS-0014.yaml` (resolved 2026-08-17,
adopted option (a) — port row-level `archive/1` — and explicitly left partitioning
itself as a future, undecided item). This record is the "later" this decision was
deferred to.

## Question

ISS-0014 identified that R-Co's PAR-03 replaced its row-level `Store.archive()` with
`PartitionRetention.runArchivalAging()`/`runEphemeralDrop()`, a whole-partition
`DETACH`/`DROP` mechanism that only works on a partitioned `events`/`events_archive`.
0003 Decision C point 2 deliberately deferred partitioning ("unpartitioned first").
That deferral was reasonable while the tables had "no rows yet"; it is no longer
free — the platform has been live since 2026-08 and both tables now carry real rows
via REQ-025's `append/2` and REQ-026's row-level `archive/1`. This record ends the
deferral: does Letflow adopt Postgres-native monthly `PARTITION BY RANGE (created_at)`
partitioning for `events`/`events_archive`, and if so, what is the retirement
mechanism and how does it relate to `archive/1`?

## Decision

**Yes — both `events` and `events_archive` become Postgres-native monthly-partitioned
tables (`PARTITION BY RANGE (created_at)`), one partition per calendar month, per
tenant schema** (0003 Decision B's schema-per-tenant mechanism is unaffected —
partitioning is an intra-schema concern, orthogonal to the tenant-isolation
boundary). Full mechanics in `lib/letflow/design/req376-partition-event-retirement.md`;
this record states the decision and its consequences, not the implementation.

### Primary-key / idempotency-sidecar consequences (the question 0003 Decision C
point 2(a)/(b) flagged in advance)

- **No primary-key change needed.** `events`/`events_archive` were already given the
  composite `(event_id, created_at)` primary key from their first migration
  (`20260816120001_create_events.exs`, `20260816120005_create_events_archive.exs`),
  specifically so this future retrofit would not also be a PK-shape migration.
  `created_at` is the chosen partition key, and it is already part of every unique
  index on both tables (the PK itself; neither table has any other unique index) —
  Postgres's requirement that a partition key be part of every unique/primary-key
  index is already satisfied. Confirmed nothing else about the PK needs to change.
- **The `event_idempotency` sidecar table (0003 Decision C point 2(b)) is unaffected
  and stays exactly as shipped.** It is not itself partitioned by this decision (its
  own key is `idempotency_key`, unrelated to `created_at`); global idempotency
  uniqueness continues to be enforced there, not via a per-partition unique index on
  `events`. Nothing here reopens that choice.
- **`event_retention_policies` stays global/unpartitioned**, per its own migration's
  documented classification — unaffected by this decision; it is consulted by both
  the row-level and whole-partition mechanisms (see below), not restructured by
  either.

### Relationship to `Letflow.EventStore.archive/1` (AC6 — stated explicitly, per this
requirement's scope fence)

**Both mechanisms coexist, at two different granularities, feeding the same
destination (`events_archive`). `archive/1` is NOT retired or replaced.**

- `archive/1` (ISS-0014's already-shipped row-level move) remains the mechanism for
  **fine-grained, per-`event_type` early archival** — honoring `keep_days`/`keep_count`
  policies that select individual rows ahead of their containing month becoming old
  enough for whole-partition retirement. It continues to run from
  `Letflow.Scheduler.Poller`'s existing per-tick retention sweep, unchanged.
- The new whole-partition retirement function (`req376` design, §4) is a **coarser,
  calendar-month-granularity** mechanism: once an entire month is old enough that no
  `event_retention_policies` consideration below `keep_forever` plausibly still wants
  it hot (an operator-configured `min_partition_age_days`, deliberately conservative —
  see req376 design §4.2 for the exact cutoff rule), the whole month is retired in one
  DDL step rather than row-by-row. Any row `archive/1` has not already individually
  moved travels with its partition when the whole month retires — this is not a
  conflict: both mechanisms only ever move rows in the same direction (`events` →
  `events_archive`), and `archive/1`'s per-row phase 1 (`INSERT ... ON CONFLICT DO
  NOTHING` keyed on `(event_id, created_at)`) is naturally idempotent against a row
  that arrives in `events_archive` by the partition-retirement path instead — no
  double-write, no conflict, whichever mechanism gets to a given row first.
- **Chosen retirement primitive: `DETACH PARTITION` from `events`, followed by
  `ATTACH PARTITION` onto `events_archive` for the same month — never `DROP`.** This
  is the resolution to AC2's "DETACH (or DROP)" phrasing: DROP is rejected outright,
  not merely deprioritized, because it would permanently destroy the physical rows a
  still-referenced process instance's replay path depends on, which is exactly what
  EO-003 (a process instance with history in an already-retired month must still
  replay with no gap) forbids. Detach+reattach costs no more DDL-locking time than
  detach+drop would (`req376` design §4.3), preserves every row, and requires only
  that the read path also consult `events_archive` (req376 design §6) — which is a
  strict improvement over the status quo, where `read/2` already had a standing,
  previously-flagged gap (`req026-event-read-archive-platform-sentinels.md` §11 OQ-3:
  "no function reads events back out of `events_archive`") that this decision closes
  as a side effect rather than leaving open indefinitely.

### What this decision does NOT do

- Does not change 0003 Decision B (schema-per-tenant) or Decision C points 1/3
  (append-only enforcement, projection-table migration treatment) — untouched.
- Does not introduce a general "partition any table" framework — scoped to
  `events`/`events_archive` only, per REQ-376's own scope fence.
- Does not add a literal `DROP` path for any partition, ever, within this decision's
  scope — see EO-003 reasoning above. A future decision may add a second-tier
  purge-by-DROP for `events_archive`'s own oldest partitions once a real compliance
  requirement calls for it; this decision deliberately leaves that door open without
  walking through it.

## Reasoning summary (full detail in the design doc)

The deferral was correct when made (no rows, no pressure) and remains correct to end
now, on the same "the row count now justifies it" logic 0003 Decision C point 2
itself anticipated ("deferred... but the future retrofit's known costs are designed
around now"). This decision is that retrofit, arriving with the PK/idempotency
groundwork already in place exactly as 0003 intended, at effectively zero rework cost
to either.

## Sign-off

REVIEWER sign-off pending — to be added by REVIEWER at WF-02 Step 2d, as a dated line
appended directly below this one, before REQ-376's acceptance criterion 1 is
considered met. Do not backfill or simulate a sign-off line here.
