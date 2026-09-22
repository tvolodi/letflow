# REQ-376 — Postgres-native partitioning of `events`/`events_archive` + whole-partition retirement

Design only — no implementation code. Read alongside
`docs/migration/decisions/0037-event-store-partitioning-and-whole-partition-retirement.md`
(the decision this design implements — read that first for the *why* and the
`archive/1` relationship; this file is the *how*).

## 0. Sources read

`docs/guides/backend_developer_guide.md`, `docs/migration/decisions/0003-ecto-schema-strategy.md`
(full), `docs/issues/ISS-0014.yaml`, `lib/letflow/event_store.ex` (full — `append/2`,
`read/2`, `archive/1` and all private helpers), `priv/repo/migrations/20260816120001_create_events.exs`,
`.../20260816120005_create_events_archive.exs`, `.../20260817181240_create_event_retention_policies.exs`,
`.../20260820000001_drop_tenant_id_events.exs` and `.../...002_drop_tenant_id_events_archive.exs`
(confirm `tenant_id` no longer exists on either table, per REQ-064/Decision 0006-D2),
`lib/letflow/event_store/event.ex`, `.../archived_event.ex`, `.../retention_policy.ex`,
`lib/letflow/design/req023-event-store-schema.md`, `.../req026-event-read-archive-platform-sentinels.md`
(§11 OQ-3 specifically — the pre-existing "nothing reads `events_archive` back out"
gap this design closes), `lib/letflow/tenant_provisioning.ex` (`tenant_scoped_migrations/0`,
`schema_name_for_tenant/1`, the `if prefix() do` guard idiom), `lib/letflow/scheduler/poller.ex`
and `lib/letflow/scheduler.ex` (`retention_due?/1`, `run_retention_sweep/1`, the
per-tenant `Task.async_stream/3` sweep idiom this design's pre-creation/retirement
sweeps reuse), `lib/letflow/scheduler/record_deadline_sweep.ex` (a recent "plain
context module called by Poller" precedent), `docs/anti-patterns.md`.

## 1. Scope recap

In scope: partitioning `events`/`events_archive` (both tenant-scoped tables, one
partition set per tenant schema); the pre-creation mechanism; the whole-partition
retirement function; the protected-record (`keep_forever`) exemption; making EO-003
replay work. Out of scope: REQ-377's operator screen; any change to `archive/1`'s
existing behavior (only its *relationship* is stated, per decision 0037); a general
partition-any-table framework; any literal `DROP` of a partition (decision 0037
rejects that path — see its EO-003 reasoning).

## 2. Migration DDL shape

Ecto's `Ecto.Migration` DSL has no `PARTITION BY` primitive — this migration set uses
`execute/1,2` for the partition-specific DDL, which is not a violation of
`backend_developer_guide.md`'s raw-SQL avoidance (INV-7 concerns tenant/user-supplied
data in query construction, not DDL with no external input; `0003-ecto-schema-strategy.md`
Dimension A already names `execute/1` as the intended escape hatch "for anything the
DSL can't express directly"). Postgres cannot convert an existing table to partitioned
in place — the shape below is create-new-partitioned-parent + backfill + atomic
rename, run inside the same tenant-schema guard idiom every event-store migration
already uses (`if prefix() do ... end`, registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`).

### 2.1 New migration files (six, mirroring the existing six-migration event-store set's numbering convention)

1. **`create_events_partitioned.exs`** — `if prefix() do ... end`, tenant-scoped.
   - `execute("CREATE TABLE #{prefix()}.events_p (event_id uuid NOT NULL, created_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'), instance_id uuid NOT NULL, event_type varchar NOT NULL, payload jsonb NOT NULL DEFAULT '{}', actor_id uuid NOT NULL, sequence_number bigint NOT NULL, idempotency_key varchar NOT NULL, metadata jsonb NOT NULL DEFAULT '{}', global_seq bigint NOT NULL, PRIMARY KEY (event_id, created_at)) PARTITION BY RANGE (created_at)")` —
     column list is byte-for-byte `events`' current column list minus `tenant_id`
     (already dropped, migration 20260820000001) plus `PARTITION BY RANGE (created_at)`.
     `global_seq` is plain `bigint` here, NOT `bigserial` — see §2.4 note on why the
     sequence must be created and owned separately for a partitioned parent.
   - `execute("CREATE SEQUENCE #{prefix()}.events_global_seq_seq OWNED BY #{prefix()}.events_p.global_seq")`,
     then `execute("ALTER TABLE #{prefix()}.events_p ALTER COLUMN global_seq SET DEFAULT nextval('#{prefix()}.events_global_seq_seq')")`
     — replicates the identical sequence name/ownership the original `:bigserial`
     column produced, so nothing downstream that might reference it by name breaks
     (design doc for REQ-023 §3.1.1 already states nothing does; this preserves that
     fact rather than re-opening it).
   - Indexes created on the *parent* (Postgres ≥11 propagates a parent-level
     `CREATE INDEX` to every current and future partition automatically — no
     per-partition index DDL needed): `uq_event_sequence` (unique, `instance_id,
     sequence_number`), `idx_events_global_seq` (`global_seq`), `idx_events_instance_time`
     (`instance_id, created_at`), `idx_events_type` (`event_type`) — same four indexes,
     same names, as the current table.
2. **`create_events_p_initial_partitions.exs`** — tenant-scoped, `execute/1` only.
   Computes the partition window at migration-run time from the tenant schema's own
   existing `events` table (`SELECT min(created_at), max(created_at) FROM
   #{prefix()}.events`), then issues one `CREATE TABLE #{prefix()}.events_yYYYYmMM
   PARTITION OF #{prefix()}.events_p FOR VALUES FROM ('YYYY-MM-01') TO
   ('<next-month>-01')` per calendar month in `[min_month, max_month + N]` where `N`
   is the pre-creation lookahead (§3 — default 2 months ahead of "now", not just of
   the data's own max, so a tenant with no recent activity still gets near-future
   partitions). Also creates exactly one `CREATE TABLE #{prefix()}.events_default
   PARTITION OF #{prefix()}.events_p DEFAULT` — a catch-all for any `created_at` this
   migration's window didn't anticipate (clock skew, a backdated event). The default
   partition is expected to stay empty in steady state (§3.3 open question on
   monitoring it).
3. **`backfill_events_partitioned.exs`** — tenant-scoped. `execute("INSERT INTO
   #{prefix()}.events_p SELECT event_id, created_at, instance_id, event_type, payload,
   actor_id, sequence_number, idempotency_key, metadata, global_seq FROM
   #{prefix()}.events ORDER BY created_at")`, then `execute("SELECT
   setval('#{prefix()}.events_global_seq_seq', (SELECT COALESCE(max(global_seq), 0)
   FROM #{prefix()}.events_p))")` to re-seed the sequence past the copied high-water
   mark (the copied rows carry their original `global_seq` values verbatim; the
   sequence itself must be advanced manually since `INSERT ... SELECT` bypasses the
   column default). **Open question §7-OQ1** on whether this single-transaction
   backfill is acceptable at current data volumes or needs a batched/online approach —
   flagged, not resolved, here.
4. **`swap_events_partitioned.exs`** — tenant-scoped, one transaction:
   `execute("ALTER TABLE #{prefix()}.events RENAME TO events_pre_partition_20260922")`,
   `execute("ALTER TABLE #{prefix()}.events_p RENAME TO events")`. The renamed-aside
   original table is NOT dropped by this migration (kept as a rollback safety net);
   a follow-up operational step (§7-OQ2, explicitly left open) drops it once the
   partitioned table has been verified in production for a stated soak period.
5. **`create_events_archive_partitioned.exs`** — identical shape to migration 1, for
   `events_archive`: same column list (`events_archive`'s current columns minus
   `tenant_id`, plus `archived_at`), `PARTITION BY RANGE (created_at)`, three indexes
   preserved on the parent (`idx_archive_instance`, `idx_archive_type`,
   `idx_archive_time` — no unique index here, matching the current table exactly;
   `events_archive`'s PK is still `(event_id, created_at)`). `global_seq` here stays
   plain `bigint` with no default, matching the current table (values are always
   copied, never generated).
6. **`create_events_archive_p_initial_partitions.exs`**, **`backfill_events_archive_partitioned.exs`**,
   **`swap_events_archive_partitioned.exs`** — same three-step shape as migrations
   2/3/4, applied to `events_archive`, but **only for calendar months that already
   have historical rows in `events_archive` at migration time** — this migration set
   does not pre-create any *future* dedicated month partition for `events_archive`.
   `events_archive`'s own default partition (`events_archive_default`) is the
   deliberate destination for every row `archive/1` moves into `events_archive` for a
   month that has not yet been whole-month-retired — see §3.2 (revised) for why no
   ongoing sweep pre-creates a dedicated `events_archive` month partition ahead of
   retirement, and §4.4 for how rows that accumulated in `events_archive_default` are
   reconciled at retirement time. This is a correction from this design's prior
   revision, which described the pre-creation sweep as covering `events_archive`'s
   future months the same way it covers `events`' — that was inconsistent with
   `retire_month/3`'s own `ATTACH` step (§4.3), which requires the destination range to
   be *unclaimed* by any existing `events_archive` partition at attach time, not
   already occupied by a pre-created one.

### 2.2 Partition-naming convention

`events_yYYYYmMM` / `events_archive_yYYYYmMM` (e.g. `events_y2026m09`), lower-case,
zero-padded month — chosen for lexical sortability and to avoid a leading digit
(`2026_09_events` would be a legal but non-idiomatic Postgres identifier; leading with
the table name matches this codebase's existing index-naming convention of
`<table>_<qualifier>` seen throughout `20260816120001_create_events.exs`).

### 2.3 Registration

All six new migrations are added to `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s
manifest, in file order, immediately after the existing six event-store migrations —
both halves (the `if prefix() do` guard and the manifest registration) are mandatory,
per every existing tenant-scoped migration's own header comment.

### 2.4 Why `global_seq` can't stay `:bigserial` on the partitioned parent

A `bigserial`/`SERIAL`-backed default is Postgres sugar for "create a sequence owned by
this column, default to `nextval(...)`" — that sugar works identically whether or not
the table is later partitioned, **but** creating it via the Ecto DSL's `:bigserial`
column type against a table created through raw `execute/1` DDL (not the DSL's `create
table`) has no clean expression, so migration 1 spells out the equivalent
`CREATE SEQUENCE` + `ALTER COLUMN ... SET DEFAULT nextval(...)` + `ALTER SEQUENCE ...
OWNED BY` explicitly. End behavior is identical to today's column; only the DDL
authoring mechanism differs, purely because the table itself isn't created via
`create table(...)`'s DSL macro any more once `PARTITION BY` is needed.

## 3. Pre-creation mechanism (satisfies AC5 — no write ever waits on partition creation)

### 3.1 Where it runs

A new context module, `Letflow.EventStore.PartitionMaintenance`, with one public
function:

```
@spec ensure_future_partitions(schema_name :: String.t(), opts :: [months_ahead: pos_integer()]) ::
        {:ok, %{events_created: [String.t()], archive_created: [String.t()]}}
        | {:error, :invalid_schema_name}
        | {:error, term()}
```

Called from a new eighth-or-ninth per-tenant sweep in `Letflow.Scheduler.Poller`
(`maybe_run_partition_maintenance/1`, following the exact `maybe_run_deadline_sweep/1`
shape already in that module — config-gated, cadence-gated via a new
`Letflow.Scheduler.partition_maintenance_due?/1` mirroring `retention_due?/1`'s
existing pattern, iterated per tenant schema via `Task.async_stream/3` at the same
`Admission.global_cap()` bound as the other Admission-gated sweeps). Default cadence:
once per day (partition creation is cheap and infrequent relative to the poller's
sub-minute tick; no reason to check every tick). `months_ahead` default: `2`.

### 3.2 What it does, per tenant schema, per call

**Revised** (was: "for each of `events`/`events_archive`, symmetrically" — corrected
here because that symmetry is what produced §4.3's original `ATTACH`-target
contradiction; see §2.1 item 6's note):

- **For `events`:** compute the set of calendar months from the current month through
  `current_month + months_ahead`; for each month with no existing partition
  (`information_schema`/`pg_inherits`-based existence check — a `SELECT EXISTS`
  query, not a DDL attempt-and-catch), issue one `CREATE TABLE ... PARTITION OF ...
  FOR VALUES FROM (...) TO (...)` (`IF NOT EXISTS` is not valid syntax for `PARTITION
  OF` in Postgres, so the existence check must precede the `CREATE TABLE`, not follow
  a failed attempt). This is a metadata-only operation against an as-yet-empty
  relation — sub-millisecond, and it takes no lock that conflicts with concurrent DML
  on any *other* partition (only a lock on the parent's own DDL-relevant catalog
  state, held briefly). No write path (`append/2`) ever creates a partition itself or
  waits on one — by construction, since this sweep always runs far enough ahead
  (`months_ahead: 2`) that the partition an `append/2` call would need already exists
  by the time that month starts, provided the sweep has run at least once in the
  preceding ~28 days (its daily cadence gives wide margin).
- **For `events_archive`: this sweep does nothing.** `events_archive` gets no
  forward-looking dedicated month partitions from `PartitionMaintenance`. Its only
  partitions are created by (a) the one-time migration backfill (§2.1 item 6, historical
  months only) and (b) `retire_month/3`'s own `ATTACH` step (§4.3), each exactly once,
  for exactly the month being retired, at the moment it retires. Until a month is
  retired, every row `archive/1` moves into `events_archive` for that month routes into
  `events_archive_default` — this is the DEFAULT partition doing exactly the job a
  DEFAULT partition exists for (a catch-all for ranges with no dedicated partition
  yet), not a soft-failure case as §3.3's `events`-side default-partition discussion
  is. `archive/1` itself is unchanged by this (per decision 0037's scope fence) — it
  already just `INSERT`s into `events_archive` the parent table; which physical
  partition Postgres routes that into is entirely a function of which partitions
  exist, which this design controls without touching `archive/1`'s own code.

### 3.3 Open question — OQ1 (pre-creation)

What happens if the poller sweep is down (crashed, tenant schema deprovisioned mid-
flight, etc.) for long enough that `months_ahead`'s buffer is exhausted and a real
`append/2` call lands in a month with no partition? Postgres routes it into the
`events_default` DEFAULT partition (§2.1 migration 2) rather than erroring — the write
still succeeds, just not into the expected monthly partition. This is a soft-failure
safety net, not a silent one: **left open** whether `PartitionMaintenance` should also
emit a metric/alert when it finds rows in a `*_default` partition (indicating the
lookahead was insufficient at some point), or whether that's covered by REQ-377's
operator screen instead. Not resolved here.

## 4. Whole-partition retirement function (AC2, AC3, AC4)

### 4.1 Public interface

New function, same module as the pre-creation mechanism family —
`Letflow.EventStore.PartitionMaintenance.retire_month/3`:

```
@spec retire_month(schema_name :: String.t(), year :: pos_integer(), month :: 1..12) ::
        {:ok, %{retired_partition: String.t(), protected_rows_relocated: non_neg_integer(),
                default_partition_rows_reconciled: non_neg_integer(), resumed_from: atom()}}
        | {:error, :invalid_schema_name}
        | {:error, :partition_not_eligible}
        | {:error, :partition_not_found}
        | {:error, {:stuck_pending_detach, term()}}
        | {:error, term()}
```

`:partition_not_eligible` — the month is not yet past `min_partition_age_days`
(§4.2). `:partition_not_found` — no `events_y<year>m<month>` partition exists under
`events`, under `events_archive`, or standalone, for that schema/month (never created
— eligibility implies it should exist; this is a real error, distinct from "already
fully retired," which is a success no-op per §4.3.1 State 3). `:destination_partition_missing`
is **removed** from this revision — it described a precondition that no longer
applies now that `events_archive` never has a pre-existing dedicated partition for an
unretired month (§3.2 revised, §2.1 item 6); `retire_month/3`'s own `ATTACH` step is
what creates that destination, so "missing" was never a real failure mode once §3.2
stopped pre-creating it. `{:stuck_pending_detach, reason}` — new in this revision
(§4.3.1 State 1): the catalog shows an interrupted `DETACH ... CONCURRENTLY` left in
Postgres's own "pending detach" state, and the recovery `FINALIZE` statement itself
failed (e.g. blocked by a concurrent conflicting operation) — this is the one case
that needs operator attention rather than resolving itself on the next retry, and is
surfaced as its own error shape rather than folded into the catch-all `{:error,
term()}` specifically so callers/alerts can distinguish "transient, retry" from
"routine, already retried and it's still stuck."

`resumed_from` in the success map names which §4.3.1 state the call actually started
from (`:not_started` | `:pending_detach` | `:detached_standalone` |
`:already_retired`) — included so a caller (or a test) can assert which recovery path
a given call exercised, not just that it returned `:ok`.

### 4.2 Eligibility rule

A month `M` is eligible once `today >= last_day(M) + min_partition_age_days`.
`min_partition_age_days` is a new `Application.get_env(:letflow, :event_retention,
min_partition_age_days: N)` key (config-driven, matching every other retention knob
in this codebase — `Letflow.Scheduler`'s existing `retention_days` accessor pattern),
deliberately conservative by default and operator-tunable, **not** derived
automatically from the max `keep_days` across `event_retention_policies` rows —
0037's relationship statement already establishes that whole-month retirement is
allowed to move a row into `events_archive` "early" relative to its own `keep_days`
policy without violating that policy's meaning (§ below, "why an early move is not a
policy violation"). The eligibility check is intentionally the *only* selectivity
this function applies at the whole-month level — it does not evaluate individual
rows' policies (that is `archive/1`'s job, at finer grain, ahead of this point) except
for the one explicit `keep_forever` exemption in §4.4.

**Why an early move is not a policy violation:** `keep_forever`/`keep_days`/
`keep_count` describe when a row becomes *eligible* to leave the hot `events` table,
not a floor guaranteeing it stays there that long. Moving a `keep_days: 400` row into
`events_archive` after 190 days (because its whole month retired) is not observable as
incorrect by anything that reads through `Letflow.EventStore.read/2` — §6 makes
`read/2` union both tables transparently, so the row is still found, still replays,
regardless of which table currently holds it. The only row class this function must
never treat this way is `keep_forever`, because `keep_forever` events are the
platform's actual audit-retention obligation (§4.4) — a `keep_days`/`keep_count`
row that leaves `events` "early" is merely an implementation-visible detail; a
`keep_forever` row's *disposition* is the audited invariant.

### 4.3 Retirement sequence (AC2 — whole-partition operations, not row-by-row; crash-recoverable)

**Honest framing, replacing this design's prior (internally inconsistent) header:**
`retire_month/3` is a short SEQUENCE of DDL statements, not literally one Postgres
statement — `DETACH ... CONCURRENTLY` cannot run inside a transaction block (a
documented Postgres restriction), so this cannot be collapsed into a single atomic
statement or a single transaction. AC2's actual requirement — read from its own text,
"single DDL operation, no secret row-by-row work" — is satisfied in the sense that
matters: **every statement in the sequence operates on the whole partition as one
unit; none of them iterates or issues a `DELETE`/`UPDATE` per row of ordinary event
data.** (§4.4's protected-row/default-partition reconciliation is the one place
genuinely-row-scoped work happens, and it is explicitly carved out below as a small,
bounded, separately-tested pre-step — not part of AC2's "no per-row DELETE" claim,
exactly as this design already distinguished for `keep_forever` in the prior
revision.)

Because the sequence spans multiple statements outside one transaction, and
`DETACH ... CONCURRENTLY` is itself a Postgres two-phase primitive that can be left
mid-flight by a crash, `retire_month/3` **must be idempotent and resumable**: a second
call against a month already partway through retirement must detect exactly which
step completed — via catalog state, never via its own bookkeeping table — and resume
from there, rather than erroring or re-attempting (and potentially double-running) a
completed step.

#### 4.3.1 State machine (catalog-detected, not stored)

`retire_month/3` always starts by querying catalog state (§4.3.2) for
`events_y<year>m<month>` and dispatches on what it finds. State is never persisted by
this design — every call, first or resumed, re-derives it, which is what makes every
call idempotent by construction.

| State | Catalog signature | Action |
|---|---|---|
| `:not_started` | child of `events` via `pg_inherits`, `inhdetachpending = false` | run step 1 (§4.4), then step 2 |
| `:pending_detach` | child of `events` via `pg_inherits`, `inhdetachpending = true` | Postgres's own documented recovery path for an interrupted concurrent detach: `ALTER TABLE events DETACH PARTITION events_y<year>m<month> FINALIZE`; on success, continue at step 3; on failure, return `{:error, {:stuck_pending_detach, reason}}` (§4.1) |
| `:detached_standalone` | exists in the schema, appears in no `pg_inherits` row as a child of either `events` or `events_archive` | resume at step 3 — check for `chk_partition_bounds_<year>_<month>` by name (existence check, not attempt-and-catch) before (re-)issuing `ADD CONSTRAINT`/`VALIDATE CONSTRAINT`, since a prior crash may have completed one but not the other |
| `:already_retired` | child of `events_archive` via `pg_inherits` | fully done already — drop `chk_partition_bounds_<year>_<month>` if it still exists (idempotent cleanup, step 5), and return `{:ok, ...}` with `default_partition_rows_reconciled: 0` and `resumed_from: :already_retired`: **a successful no-op, not an error** |
| (none of the above) | no matching relation under any name | `{:error, :partition_not_found}` |

#### 4.3.2 Catalog checks used

- Child-of-`events`, and its pending-detach flag: `SELECT i.inhdetachpending FROM
  pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE c.relname =
  'events_y<year>m<month>' AND i.inhparent = '#{prefix()}.events'::regclass`.
- Child-of-`events_archive`: same shape, `i.inhparent =
  '#{prefix()}.events_archive'::regclass`.
- Exists but is nobody's child (standalone): a positive `SELECT 1 FROM pg_class WHERE
  relnamespace = '#{prefix()}'::regnamespace AND relname =
  'events_y<year>m<month>'` with both `pg_inherits` queries above returning no row.

`pg_inherits.inhdetachpending` is the Postgres-14+-documented column this design
relies on for the pending-detach signal — cited, not re-derived, per this project's
"don't re-litigate what's already established" discipline applied to Postgres's own
documented catalog behavior (same discipline §5 already applies to `DETACH ...
CONCURRENTLY`'s non-blocking guarantee).

#### 4.3.3 The steps themselves

1. **Protected-row and default-partition reconciliation** (§4.4, revised) — runs only
   from `:not_started`; skipped entirely (zero row-level queries beyond the two
   `SELECT EXISTS`/count checks) if there is nothing to reconcile.
2. `ALTER TABLE #{prefix()}.events DETACH PARTITION
   #{prefix()}.events_y<year>m<month> CONCURRENTLY` — Postgres 14+ (this project runs
   Postgres 16, per `docker-compose.yml`'s `image: postgres:16`). `CONCURRENTLY` is
   what makes AC2's "the platform accepts a concurrent write throughout" provable: a
   plain (non-`CONCURRENTLY`) `DETACH PARTITION` takes an `ACCESS EXCLUSIVE` lock on
   the parent for its (brief but nonzero) duration, blocking concurrent DML on *other*
   partitions of the same parent too; `DETACH ... CONCURRENTLY` instead takes a lock
   that permits concurrent DML throughout, at the cost of running in the two internal
   phases this section's state machine is built around.
3. `ALTER TABLE #{prefix()}.events_y<year>m<month> ADD CONSTRAINT
   chk_partition_bounds_<year>_<month> CHECK (created_at >= '<month-start>' AND
   created_at < '<next-month-start>') NOT VALID`, then `ALTER TABLE ... VALIDATE
   CONSTRAINT chk_partition_bounds_<year>_<month>` — `VALIDATE CONSTRAINT` takes only
   `SHARE UPDATE EXCLUSIVE` (blocks neither reads nor writes, even on the table being
   validated) and scans only the standalone table itself, never `events` or
   `events_archive`'s live partitions. Standard Postgres fast-attach idiom: with this
   exact constraint pre-validated, step 4's `ATTACH PARTITION` skips its own default
   full-table validation scan.
4. `ALTER TABLE #{prefix()}.events_archive ATTACH PARTITION
   #{prefix()}.events_y<year>m<month> FOR VALUES FROM ('<month-start>') TO
   ('<next-month-start>')` — metadata-only given step 3's pre-validated constraint.
   Requires the target range to be unclaimed by any existing `events_archive`
   partition, which §3.2 (revised) now guarantees by construction: `events_archive`
   never has a pre-created dedicated partition for a not-yet-retired month, so this
   `ATTACH` is always the first (and only) time that range gets a dedicated
   `events_archive` partition. It also requires `events_archive_default` to hold no
   row matching the target range at the moment of `ATTACH` — a documented Postgres
   precondition whenever a default partition exists — which is exactly what step 1's
   reconciliation guarantees ahead of this step.
5. `ALTER TABLE #{prefix()}.events_y<year>m<month> DROP CONSTRAINT
   chk_partition_bounds_<year>_<month>` — cleanup; `events_archive`'s own partition
   bound enforces the same range going forward, so the standalone CHECK is redundant
   once attached.

No `DROP` of the partition or its rows anywhere in this sequence — the physical table
persists throughout, first as `events`'s partition, then (after step 1's reconciliation
folds in whatever had accumulated in `events_archive_default` for that month) as
`events_archive`'s. This is what makes EO-003 hold by construction (§6).

**AC2 test shape (evidence, not code):**
- *No per-row work in the retirement steps themselves:* a test asserting zero
  `DELETE`/row-level statements ran during steps 2–5 of a `retire_month/3` call
  against a month fixture with nothing to reconcile (no `keep_forever` rows, no
  `events_archive_default` rows in range) — e.g. via `Postgrex.Telemetry`/query-log
  capture scoped to exclude step 1's queries, asserting no `DELETE FROM`/row-scoped
  `INSERT` appears for steps 2–5.
- *Concurrent-write, non-blocking:* a second process performs an `append/2` call (or a
  raw insert into an unrelated partition/month) concurrently with the `retire_month/3`
  call and is proven to complete without blocking (bounded by a short timeout, or by
  asserting the concurrent write's own wall-clock duration is not inflated by the
  retirement call's presence).
- *Crash-recovery / idempotent resume (new in this revision):* three sub-cases, each
  simulating a crash by stopping the sequence after a given step (e.g. running steps
  1..N directly against the test database, outside `retire_month/3`, then calling
  `retire_month/3` fresh) and asserting the resumed call completes correctly and
  `resumed_from` names the expected state:
  1. Stop after step 2 (DETACH completed) but before step 3 → call `retire_month/3`
     again → asserts it detects `:detached_standalone` and completes steps 3–5,
     `resumed_from: :detached_standalone`.
  2. Simulate a Postgres-level pending-detach (cancel/interrupt a `DETACH ...
     CONCURRENTLY` mid-flight against a Postgres 16 test instance, or directly assert
     against `pg_inherits.inhdetachpending` if the test harness can't reliably induce
     the interrupted state) → call `retire_month/3` → asserts it issues `FINALIZE` and
     completes, `resumed_from: :pending_detach`.
  3. Call `retire_month/3` a second time against a month that already fully retired
     (state `:already_retired`) → asserts `{:ok, ...}` with
     `default_partition_rows_reconciled: 0`, `resumed_from: :already_retired`, and no
     `ATTACH`/`DETACH` statement is re-issued (query-log assertion, same technique as
     the no-per-row-work case above).

### 4.4 Step 1, in full: `events_archive_default` reconciliation + protected-record (`keep_forever`) relocation

This step now does two things, both before step 2's `DETACH`, both required for step
4's `ATTACH` to succeed cleanly, both using the same insert-then-confirmed-delete
idiom. **Order matters and is fixed: 4.4b runs before 4.4a.** Running 4.4a
(`keep_forever` relocation into `events_archive_default`) before 4.4b (sweeping
`events_archive_default` back into the partition) would move the just-relocated
`keep_forever` rows right back out again on the very next sub-step — harmless but
wasteful. Running 4.4b first means it only ever sweeps `archive/1`'s pre-existing
early-moved rows; 4.4a's `keep_forever` rows then land in
`events_archive_default` and simply stay there (still `events_archive`, still
counted by EO-002, §4.5) rather than round-tripping.

**4.4b — `events_archive_default` reconciliation, batched (revised in this rework —
was an unbounded single transaction; required for §4.3 step 4's `ATTACH` to succeed;
runs first):** Postgres refuses to `ATTACH` a new partition whose range overlaps rows
already sitting in the parent's `DEFAULT` partition — it scans `events_archive_default`
as part of the `ATTACH` DDL and errors if any row there falls in `[month-start,
next-month-start)`. Rows are there because `archive/1`'s ordinary early per-row moves
for this month always land in `events_archive_default` until this month is retired
(§3.2 revised).

**Why this population is not assumed small (unlike 4.4a's `keep_forever` rows):**
`keep_forever`'s smallness (4.4a) is justified by design — `keep_forever` is
deliberately the exception, not the common case, among retention policies. No
equivalent argument holds for 4.4b: `events_archive_default` receives *every* row
`archive/1` moves for this month, for the entire span between whatever `keep_days`/
`keep_count` made each row eligible and this month's own (deliberately conservative,
§4.2) `min_partition_age_days` retirement eligibility. That span is designed to be
long, and the reconciled set scales with this tenant's actual archived-event volume
for the month — a quantity this design has no basis to bound as "small" at design
time (see OQ7 below). The mechanism must therefore be bounded by construction, not by
assumption about the data.

**Mechanism — fixed-size batches, one `Repo.transaction/1` per batch:** a new config
knob, `Application.get_env(:letflow, :event_retention, reconciliation_batch_size:
5000)` (same config location/pattern as `min_partition_age_days`, §4.2). Loop:

- `SELECT event_id, created_at FROM #{prefix()}.events_archive_default WHERE
  created_at >= '<month-start>' AND created_at < '<next-month-start>' ORDER BY
  created_at, event_id LIMIT <reconciliation_batch_size>` (no `OFFSET` — each
  iteration's `DELETE` removes exactly the rows just processed, so the next `SELECT`
  naturally advances over what remains; `ORDER BY` gives deterministic, resumable
  batch boundaries).
- For the batch returned (possibly `[]`, ending the loop): relocate it **out of
  `events_archive_default` and into the still-standalone (at this point, still
  attached to `events`) `events_y<year>m<month>` table** — `INSERT INTO
  #{prefix()}.events_y<year>m<month> (...) SELECT ...` then `DELETE FROM
  #{prefix()}.events_archive_default WHERE event_id = ANY(...) AND created_at =
  ANY(...)`, same insert-then-confirmed-delete idiom as `archive_phase1_insert`/
  `archive_phase2_delete` — including their own already-established pattern of
  splitting insert and delete across separate transaction boundaries where needed;
  here insert+delete share one transaction per batch since both target disjoint
  tables from `events`/`events_archive`'s live partitions and the row set is
  batch-bounded.
- Loop terminates when a `SELECT` returns fewer than `reconciliation_batch_size`
  rows. `default_partition_rows_reconciled` in the `{:ok, ...}` return (§4.1) reports
  the summed count across all batches.

This looks like moving rows from `events_archive` back into `events`, but it is not a
policy reversal: these rows are about to become part of `events_archive` again,
permanently, the moment step 4's `ATTACH` runs — moving them into the not-yet-detached
partition first is what lets the whole-partition `DETACH`+`ATTACH` carry them across in
one motion instead of a second per-row `INSERT`/`DELETE` pair after `ATTACH`.

**Bound checked against §5's EO-001 non-blocking claim:** each batch transaction
takes only row-level locks — on the `reconciliation_batch_size` rows being deleted
from `events_archive_default` and the matching rows being inserted into
`events_y<year>m<month>` — never a lock on the `events` or `events_archive` parent
relations, and never a lock that conflicts with concurrent DML against any other
month's partition, any other tenant's schema, or (in steady state) this same month's
partition, since a month only becomes retirement-eligible once
`min_partition_age_days` has passed and ordinary `append/2` traffic writes rows with
`created_at` close to "now", not backdated into an already-aging month. This per-batch
lock footprint is **constant, independent of the reconciled set's total size** —
running 1 batch or 500 batches makes the same EO-001 claim per batch; a larger total
population lengthens step 1's overall wall-clock duration (more batches, run
sequentially, each its own bounded transaction) but never lengthens any single lock's
duration beyond one `reconciliation_batch_size`-row transaction. This is the load-bearing
difference from the prior (failed) revision: that version's bound was an unsubstantiated
claim about total size; this version's bound is structural (per-transaction, not
per-month) and holds regardless of total size.

**Crash-recovery consistency (§4.3.1):** a crash mid-loop leaves the partition still
attached to `events` with `inhdetachpending = false` — catalog state still reads
`:not_started` on the next call, so `retire_month/3` resumes by re-entering this same
loop; already-relocated batches are no longer in `events_archive_default` (moved, not
copied), so the next `SELECT` naturally picks up only what remains. No separate
crash-recovery bookkeeping is needed for the batch loop itself, consistent with
§4.3.1's general "catalog-detected, never self-persisted" state design.

**4.4a — `keep_forever` relocation (mechanism unchanged from the prior revision,
corrected only in destination):** `SELECT event_id, created_at FROM
#{prefix()}.events_y<year>m<month> WHERE event_type IN (<event_types with a global
event_retention_policies row where policy = 'keep_forever'>)`. If this returns rows,
they are relocated — `INSERT INTO #{prefix()}.events_archive (...) SELECT ...`
(routes to `events_archive_default`, per §3.2 revised — **not** "a dedicated
partition that already exists," which was this design's prior, now-corrected,
assumption) followed by `DELETE FROM #{prefix()}.events_y<year>m<month> WHERE
event_id = ANY(<relocated ids>) AND created_at = ANY(<relocated created_ats>)`, both
inside one `Repo.transaction/1`, matching `archive_phase1_insert`/`archive_phase2_delete`'s
existing insert-then-confirmed-delete idiom (`lib/letflow/event_store.ex` around line
1490).

Both 4.4a and 4.4b are bounded per-row pre-steps — **not** part of AC2's "no per-row
DELETE" claim, which is specifically about steps 2–5 (§4.3.3), exactly as this design
already distinguished for `keep_forever` alone in the prior revision; 4.4b extends the
same exception category to the newly-identified default-partition precondition, but on
different grounds: 4.4a is bounded because `keep_forever` rows are rare by design
(argued above); 4.4b is bounded because its batched mechanism caps each transaction's
row count and lock duration by construction, independent of how large the total
reconciled set turns out to be (argued in the "Bound checked against §5's EO-001"
paragraph above) — not because the total is assumed small.

This relocation is bounded to however many `keep_forever`-policy rows the target
month actually contains — expected to be small (the whole reason `keep_forever` exists
is that it's the *exception*, not the common case) — and is a **distinct operation
from the whole-month retirement DDL itself**, not a violation of AC2's "no per-row
DELETE" claim: AC2's claim is about the *retirement* step (§4.3 steps 2–5, which never
issue a DELETE), while this relocation is a separate, explicitly-scoped, and
explicitly-tested (EO-002) pre-step that only runs when protected rows are actually
present. **This distinction is stated explicitly here, not left for a reader to infer**,
per this design's own obligation not to leave an open question unstated: a test
proving AC2's "no per-row DELETE" claim must use a month fixture with zero
`keep_forever` rows; a test proving EO-002 must use a month fixture with at least one,
and both are legitimate, non-contradictory tests of the same function.

**Why relocation (not "never dropped" alone) is still needed despite §4.3 never
dropping anything:** even though the whole-month DETACH+ATTACH sequence never
destroys data, a `keep_forever` row landing in `events_archive` via the *general*
whole-partition path is not itself wrong — but leaving the exemption unimplemented
would mean this design has no mechanism that specifically *proves* a `keep_forever`
row's continued existence is a first-class, load-bearing invariant rather than an
accidental byproduct of "we happen not to drop things." Decision 0037 reserves the
right to add a second-tier `events_archive`-own-partition purge-by-DROP later (out of
this decision's scope, door deliberately left open) — when that lands, its own DROP
step will need exactly this relocation mechanism to keep `keep_forever` rows safe, so
building it now, and proving it with EO-002, is not speculative: it is the one piece
of this decision's design that a *future*, DROP-capable retirement tier will directly
depend on.

### 4.5 EO-002 test shape (evidence, not code)

`SELECT count(*) FROM <schema>.event_retention_policies-joined-events-by-type-in-target-month
WHERE policy = 'keep_forever'` (or equivalently, a fixture-seeded known count) before
`retire_month/3`; the same count, now summed across `events` ∪ `events_archive` (both
now covered by `read/2`'s union, §6, or a direct query against both tables), after —
asserted equal. The count must be taken *across both tables*, not just `events`,
since a successful relocation moves rows out of `events` by design; asserting the
count in `events` alone before/after would incorrectly read as "records lost."

## 5. EO-001 (non-blocking, concurrent-write-safe) — consolidated statement

Already argued piecewise in §3.2 (pre-creation) and §4.3 (retirement); consolidated
here as the design's single non-blocking claim: no step in either the pre-creation
sweep or `retire_month/3` ever takes a lock stronger than `SHARE UPDATE EXCLUSIVE`
against a *live* (still-attached, currently-written-to) partition or against the
parent table in a way that blocks DML on other partitions. `DETACH ... CONCURRENTLY`
is the one step whose non-blocking behavior is a documented Postgres 14+ guarantee
rather than this design's own derivation — cited, not re-derived, per this project's
"don't re-litigate what's already established" discipline applied to Postgres's own
documented behavior. `FINALIZE` (§4.3.1 State `:pending_detach`) is the one step this
claim does not extend to unconditionally: Postgres finalizes an interrupted concurrent
detach by briefly taking a stronger lock than routine `DETACH ... CONCURRENTLY`
does — acceptable here because it only ever runs on the rare crash-recovery path
(§4.3.1), never on a first, uninterrupted call, so it does not weaken EO-001's claim
about the routine case. The catalog reads in §4.3.2 that every call opens with
(idempotency dispatch) are plain `SELECT`s against system catalogs — no lock beyond
what any ordinary read already takes.

## 6. EO-003 — replay after retirement (architectural mechanism)

**What makes an already-retired month's data still readable:** `retire_month/3`
never removes rows from existence (§4.3) — it moves a whole partition from being a
child of `events` to being a child of `events_archive`, in place, with no row copy.
The only change EO-003 requires beyond that is closing the pre-existing gap
`req026-event-read-archive-platform-sentinels.md` §11 OQ-3 already flagged and left
open ("no function reads events back out of `events_archive`"): **`Letflow.EventStore.read/2`
is extended to query both `events` and `events_archive` and merge the results**,
ordered by `sequence_number ASC` exactly as today (INV-RD-2, unchanged) — concretely,
`query_instance_events/3` (the private helper at `event_store.ex` around line 1259)
changes from a single `Repo.all/2` against `Event` to two queries (against `Event`
and `ArchivedEvent`, both scoped by `instance_id` and the same `apply_read_filter/2`)
whose results are concatenated and re-sorted by `sequence_number` before return —
correctness here does not depend on either query being individually sorted, since the
merge step re-sorts the combined set. `ensure_instance_started/2`'s existing
`instance_sequence`-based existence check (STEP 1, unchanged) is unaffected — it
already only asserts the instance has ever had a successful append, not where its
events currently live.

This is a **change to `read/2`'s existing behavior**, not to `archive/1` — explicitly
in scope per this requirement's own text ("Proof that a process instance... still
replays its full history... EO-003" is one of REQ-376's own five numbered
sub-requirements) and consistent with the scope fence (the fence only restricts
touching `archive/1`'s row-level move path, not `read/2`). Stated explicitly because
it is the one piece of this design that touches an already-shipped, non-partitioning
function: `read/2` was arguably already incorrect for the pre-existing row-level
`archive/1` case too (any instance with even one already-archived event before this
requirement would already have hit OQ-3's gap) — this design closes that gap for
both mechanisms at once, not just the new partition-retirement one.

**EO-003 test shape (evidence, not code):** seed an instance with events spanning two
months; retire the older month via `retire_month/3`; call `read/2` for that instance
with no filter; assert every originally-seeded event is present, in the correct
`sequence_number` order, with no error and no gap — proving the union-read change
closes the loop `retire_month/3`'s DETACH+ATTACH design opened.

## 7. Open questions (explicit, not silently resolved)

- **OQ1 (§2.1 migration 3):** is a single-transaction `INSERT ... SELECT` backfill
  acceptable at this project's current `events`/`events_archive` row counts, or does
  it need a batched/chunked approach to avoid a long-held lock during the schema
  migration itself? Not measured as part of this design — ELIXIR-DEV should check
  actual row counts per tenant schema before implementing and flag back if a chunked
  backfill is needed instead of the single-statement version described in §2.1.
- **OQ2 (§2.1 migration 4):** the renamed-aside pre-partition original tables
  (`events_pre_partition_20260922`, `events_archive_pre_partition_20260922`) are
  never dropped by any migration in this design — left as a deliberate rollback
  safety net with no stated expiry. A follow-up requirement or an explicit ops
  decision should set a soak period and a cleanup migration; not decided here.
- **OQ3 (§3.3, revised):** whether `PartitionMaintenance` should alert when `events`'s
  own `events_default` partition receives any rows (a sign the `events`-side lookahead
  window was insufficient at some point) — left for REQ-377 or a follow-up to decide,
  not resolved here. **Not applicable to `events_archive_default`** any more: per §3.2
  (revised), `events_archive_default` holding rows is the expected, designed-for
  steady state for any not-yet-retired month (every `archive/1` early move lands
  there by construction), so its row count is not itself a signal of anything wrong —
  only §4.4b's reconciliation count (`default_partition_rows_reconciled`) at
  retirement time is a meaningful metric, and whether *that* should be
  alerted/tracked operationally is folded into this same open question rather than
  treated separately.
- **OQ4:** `min_partition_age_days`'s actual default value is left unspecified by
  this design (a config key exists, §4.2, but no default number is proposed) —
  ELIXIR-DEV/REVIEWER should set one grounded in this platform's actual expected
  `keep_days` policy ranges once `event_retention_policies` has real production rows
  to reason from; an arbitrary number picked here with no data behind it would be
  exactly the kind of unstated assumption this design is supposed to avoid guessing
  at.
- **OQ5:** this design does not specify how an operator (or REQ-377's screen)
  discovers which months are currently eligible-but-not-yet-retired, nor whether
  `retire_month/3` is invoked by a new Poller sweep (automatic) or only ever called
  on demand (operator/REQ-377-triggered). Left open deliberately — REQ-377's own
  design should decide this, since "who/what calls `retire_month/3`, and how often"
  is squarely an operator-facing-screen design question this requirement's scope
  fence excludes.
- **OQ6 (new, §4.3.1):** `{:error, {:stuck_pending_detach, reason}}` (§4.1) is
  surfaced as a return value, but this design does not specify what, if anything,
  automatically retries it (a Poller re-sweep? manual operator re-invocation only?)
  nor what alerting/visibility a stuck pending-detach state gets in the interim
  (a month stuck here is not silently wrong — `events`' own read/write path is
  entirely unaffected, per Postgres's own two-phase design — but it does block that
  month's retirement indefinitely until resolved). Left for REQ-377/a follow-up,
  same as OQ3/OQ5, rather than guessed at here.
- **OQ7 (new, §4.4b):** `reconciliation_batch_size`'s default (5000, proposed in
  §4.4b) is picked with no production data behind it, same category of gap as OQ4's
  `min_partition_age_days` — this design has no basis to estimate how many rows
  actually accumulate in `events_archive_default` per tenant per month in practice
  (that population scales with archived-event volume over the entire
  `min_partition_age_days` window, which itself has no chosen default yet per OQ4),
  so neither the batch size nor the resulting number-of-batches/step-1-wall-clock-time
  for a real tenant is known until this ships. The per-batch lock/duration bound
  (§4.4b) holds regardless of this number, so this open question is about tuning and
  operational visibility (should step 1 emit a metric for batch count/total
  reconciled per call? should very large counts alert, analogous to OQ3's
  `events_default` alerting question?), not about correctness — ELIXIR-DEV/REVIEWER
  should revisit the default once real `archive/1`/`events_archive_default` volumes
  are observable, matching how OQ1 treats the analogous single-transaction-backfill
  sizing question as open rather than guessed at.

## 8. Acceptance-criteria coverage map

| AC | Design element |
|----|----|
| 1 | `docs/migration/decisions/0037-...md` (this design's companion decision record), pending REVIEWER sign-off |
| 2 (EO-001) | §4.3 retirement sequence (whole-partition DDL only in steps 2–5, honest "sequence not single-statement" framing, §4.3.1 crash-recovery state machine, §5); crash-recovery/idempotent-resume test shape in §4.3.3 |
| 3 (EO-002) | §4.4 (4.4a `keep_forever` relocation + 4.4b `events_archive_default` reconciliation), §4.5 test shape |
| 4 (EO-003) | §6 `read/2` union extension |
| 5 | §3 pre-creation mechanism, `months_ahead: 2` default (revised to `events`-only, §3.2) |
| 6 | Decision 0037's "Relationship to `archive/1`" section, restated in §4.2/§4.3/§3.2 here |
| 7 | Not a design-time concern — ELIXIR-DEV runs `mix letflow.check` at implementation time and quotes real output |
