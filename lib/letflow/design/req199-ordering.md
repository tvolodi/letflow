# Design: REQ-199 — Correlated effect re-entry ordering (ORD-01/02/03/04)

**Requirement:** REQ-199 (`docs/requirements.yaml`, stage S6,
`depends_on: [REQ-025, REQ-176, REQ-186, REQ-194]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ199-20260831`, WF-02 Step 1
**This document produces:** two Ecto schema shapes, two migration specs, all public
`@spec`s for six new modules, transaction boundary definitions, advisory-lock key
derivation, gap-sweeper algorithm, DLQ integration contract, ORD-04 metric names, and
scheduler wiring. **No implementation code** — no function bodies, no `.ex`/`.exs` code
blocks. ELIXIR-DEV writes those from this document at Step 2a.

---

## 0. Sources read for this design

- `lib/letflow/scheduler/poller.ex` (REQ-186, REQ-188, REQ-194, REQ-201 additions) — read
  in full. Confirms the `handle_info(:tick)` extension pattern: each cross-cutting
  feature adds one private `maybe_run_*/1` helper called after the timer-poll loop and
  the active-instances refresh, reusing the `schemas` list already computed for that tick.
  **No new supervision child; no `application.ex` change.** This is the wiring target for
  REQ-199's consumer and sweeper.
- `lib/letflow/dlq.ex` (REQ-176) — confirmed `Letflow.Dlq.enqueue/2` signature:
  `enqueue(enqueue_attrs(), opts()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}`.
  Confirmed `enqueue_attrs()` fields: `:entry_type`, `:reference_id`, `:reason`,
  `:full_reason`, `:error_detail`, `:context_json`, and `:source_payload` (nullable
  key-value pairs), among others. `tenant_id` is derived from `opts[:prefix]`, never
  accepted from attrs.
- `lib/letflow/event_store.ex` (REQ-025) — confirmed `append/2` contract: accepts
  `{event_type, instance_id, payload, opts}`, derives `tenant_id` from `opts[:prefix]`,
  performs registry validation before the transaction opens. The `effect_applied` event
  type must be registered in the per-tenant `event_type_registry` for ES-05 to pass.
- `lib/letflow/metrics/registry.ex` (REQ-194) — confirmed ETS-backed registry pattern.
  New gauge families are written directly as `:ets.insert(@table, {{:gauge, family, labels}, value})`.
  The `set_active_instances/1` precedent confirms writing gauges directly from
  `Letflow.Scheduler.Poller` is the established exception for metrics that are scheduler-
  driven rather than `:telemetry`-event-driven.
- `test/support/tenant_fixture.ex` — confirmed `@expected_tenant_tables` at line 122.
  The list currently has 31 entries (ending with `"webhook_subscriptions"`). Both
  new tables (`effect_completions`, `correlation_cursors`) must be added in alphabetical
  order per the list's existing sort order; failure to do so causes the oracle test to
  fail (established anti-pattern, see `docs/anti-patterns.md`).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — confirmed Decision B:
  schema-per-tenant, `tenant_id` retained intra-schema. Both new tables follow this
  decision. R-Co's own per-tenant classification for `effect_completions` and
  `correlation_cursors` is confirmed in the requirement text.
- `docs/migration/stage-6-operational-cross-cutting.md` — stage context read; REQ-199
  is the last of the six S6 subsystems.
- `docs/anti-patterns.md` — reviewed before writing.
- `docs/agents/instructions/core-directives.md`,
  `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.

---

## 1. Module names

| Module | Role | File |
|---|---|---|
| `Letflow.Ordering` | Public context API: `insert_completion/2`, `run_cycle/2`, `compute_lag/2` | `lib/letflow/ordering.ex` |
| `Letflow.Ordering.Completion` | Ecto schema for `effect_completions` | `lib/letflow/ordering/completion.ex` |
| `Letflow.Ordering.Cursor` | Ecto schema for `correlation_cursors` | `lib/letflow/ordering/cursor.ex` |
| `Letflow.Ordering.Consumer` | Claim-and-apply cycle (ORD-01/02/03) | `lib/letflow/ordering/consumer.ex` |
| `Letflow.Ordering.Sweeper` | Gap sweeper (ORD-02 timeout) | `lib/letflow/ordering/sweeper.ex` |
| `Letflow.Ordering.Metrics` | ORD-04 lag surface | `lib/letflow/ordering/metrics.ex` |

---

## 2. Per-tenant placement decision

Both `effect_completions` and `correlation_cursors` are **per-tenant tables**, created
inside each tenant's Postgres schema by migrations 20260831000001 and 20260831000002
respectively. Reason: this matches R-Co's own per-tenant classification for both tables
(confirmed in the requirement text) and is required by decision 0003 Decision B — all
business tables that operate per-correlation-per-tenant must be schema-isolated so a
bug that forgets a `tenant_id` predicate fails loudly (row not found in the wrong schema)
rather than silently leaking rows across tenants. `tenant_id` is also retained as an
intra-schema column on both tables for query-predicate discipline, derived from
`opts[:prefix]` via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` — never
accepted from caller-supplied attrs.

---

## 3. Schema: `Letflow.Ordering.Completion`

Table: `effect_completions` (per-tenant, migration `20260831000001`)

### Fields

| Column | Ecto type | Postgres type | Constraints |
|---|---|---|---|
| `completion_id` | `:binary_id` | `uuid` | primary key |
| `tenant_id` | `:binary_id` | `uuid` | not null |
| `correlation_id` | `:string` | `varchar` | not null |
| `sequence_no` | `:integer` (bigint) | `bigint` | not null |
| `status` | `Ecto.Enum` values `[:pending, :applied, :dead]` | `varchar` | not null, default `"PENDING"`, CHECK `IN ('PENDING','APPLIED','DEAD')` |
| `payload` | `:map` | `jsonb` | not null, default `'{}'` |
| `received_at` | `:utc_datetime_usec` | `timestamptz` | nullable |
| `applied_at` | `:utc_datetime_usec` | `timestamptz` | nullable |
| `created_at` | `:utc_datetime_usec` | `timestamptz` | not null |

### Constraints and indexes

- `UNIQUE (correlation_id, sequence_no)` — idempotent re-insert: inserting the same
  pair twice results in exactly one row (AC2).
- `PARTIAL INDEX ON effect_completions (correlation_id, sequence_no) WHERE status = 'PENDING'`
  — matches the claim query shape for ORD-01 (correlated-subset scan over pending rows only).
- Primary key index on `completion_id`.
- Index on `(correlation_id, sequence_no)` (also satisfies the unique constraint above).

### Ecto schema shape (types only — no source)

```
schema "effect_completions" do
  field :tenant_id, :binary_id
  field :correlation_id, :string
  field :sequence_no, :integer
  field :status, Ecto.Enum, values: [:pending, :applied, :dead], default: :pending
  field :payload, :map, default: %{}
  field :received_at, :utc_datetime_usec
  field :applied_at, :utc_datetime_usec
  timestamps(type: :utc_datetime_usec, updated_at: false)
end
```

Note: `timestamps(updated_at: false)` provides `created_at` only; `applied_at` is a
separate nullable column updated by the apply step, not by Ecto's auto-timestamp.

---

## 4. Schema: `Letflow.Ordering.Cursor`

Table: `correlation_cursors` (per-tenant, migration `20260831000002`)

### Fields

| Column | Ecto type | Postgres type | Constraints |
|---|---|---|---|
| `correlation_id` | `:string` | `varchar` | primary key |
| `tenant_id` | `:binary_id` | `uuid` | not null |
| `applied_seq` | `:integer` (bigint) | `bigint` | not null, default `0`, CHECK `>= 0` |
| `updated_at` | `:utc_datetime_usec` | `timestamptz` | not null |
| `created_at` | `:utc_datetime_usec` | `timestamptz` | not null |

### Notes

- Primary key is `correlation_id` (string), not a UUID — matches R-Co's own primary key
  shape for this table (confirmed in requirement text).
- No separate `id` column; `correlation_id` IS the primary key.
- `applied_seq` starts at `0`, representing "no completions applied yet for this
  correlation."
- A correlation row is initialised (upserted) when the first completion for that
  correlation is successfully applied (AC6). Initial value is `applied_seq = 0`.

### Ecto schema shape (types only — no source)

```
@primary_key {:correlation_id, :string, autogenerate: false}
schema "correlation_cursors" do
  field :tenant_id, :binary_id
  field :applied_seq, :integer, default: 0
  timestamps(type: :utc_datetime_usec)
end
```

---

## 5. Migrations

### 5.1 Migration `20260831000001` — `effect_completions`

Wrapped in `if prefix() do ... end` (per-tenant, Decision B pattern from REQ-181/REQ-195).

DDL sequence:
1. `create table(:effect_completions, primary_key: false) do ... end`
2. `create unique_index(:effect_completions, [:correlation_id, :sequence_no])`
3. Partial index:
   `execute "CREATE INDEX effect_completions_pending_idx ON effect_completions (correlation_id, sequence_no) WHERE status = 'PENDING'"`
4. CHECK constraint on `status`:
   `execute "ALTER TABLE effect_completions ADD CONSTRAINT effect_completions_status_check CHECK (status IN ('PENDING','APPLIED','DEAD'))"`
5. CHECK constraint on `sequence_no >= 0` (sequence numbers are non-negative):
   `execute "ALTER TABLE effect_completions ADD CONSTRAINT effect_completions_seq_nonneg CHECK (sequence_no >= 0)"`

### 5.2 Migration `20260831000002` — `correlation_cursors`

Wrapped in `if prefix() do ... end`.

DDL sequence:
1. `create table(:correlation_cursors, primary_key: false) do ... end`
2. CHECK constraint on `applied_seq >= 0`:
   `execute "ALTER TABLE correlation_cursors ADD CONSTRAINT correlation_cursors_applied_seq_check CHECK (applied_seq >= 0)"`

---

## 6. Public function signatures

### 6.1 `Letflow.Ordering` (context module)

Maps AC1–AC18 to external entry points. No function bodies.

```
@type opts :: [prefix: String.t()]

@type insert_error ::
  :invalid_schema_name
  | Ecto.Changeset.t()

@type cycle_result ::
  :applied
  | :not_next          # sequence not applied_seq + 1 — silent rollback, row stays PENDING
  | :lock_contention   # pg_try_advisory_xact_lock returned false — caller re-claims
  | :cursor_race       # conditional cursor update returned 0 rows — caller re-claims
  | :no_pending        # no PENDING rows found for this schema
  | {:error, term()}

@spec insert_completion(
        attrs :: %{
          required(:correlation_id) => String.t(),
          required(:sequence_no) => non_neg_integer(),
          optional(:payload) => map(),
          optional(:received_at) => DateTime.t()
        },
        opts()
      ) :: {:ok, Letflow.Ordering.Completion.t()} | {:error, insert_error()}
```

`insert_completion/2` — idempotent: a conflict on `(correlation_id, sequence_no)` returns
`{:ok, existing_row}` rather than an error (AC2). `tenant_id` is derived from
`opts[:prefix]`, never accepted from attrs.

```
@spec run_cycle(schema_name :: String.t(), opts()) :: cycle_result()
```

`run_cycle/2` — executes one claim-and-apply cycle (§7 below) for one schema. Called by
`Letflow.Scheduler.Poller` via `maybe_run_ordering_cycle/1`. Acquires and releases a
database connection within this single call — never held across the poll sleep (AC10,
GH-654/ISS-0649 fix).

```
@spec sweep_gaps(schema_name :: String.t(), opts()) :: :ok
```

`sweep_gaps/2` — runs the gap sweeper for one schema (§8). Called by
`Letflow.Scheduler.Poller` via `maybe_run_ordering_sweeper/1`.

```
@spec emit_lag_metrics(schema_name :: String.t(), opts()) :: :ok
```

`emit_lag_metrics/2` — computes per-correlation lag and oldest-pending age, writes to
`Letflow.Metrics.Registry`, and emits a lag-threshold-exceeded event via
`Letflow.EventStore.append_platform_event/2` when lag crosses the configured threshold
(AC13–AC15). Called by `Letflow.Scheduler.Poller` via `maybe_run_ordering_metrics/1`.

---

### 6.2 `Letflow.Ordering.Consumer`

```
@type claim_result ::
  {:ok, Letflow.Ordering.Completion.t()}
  | :no_pending

@spec claim(opts()) :: claim_result()
```

Claims the lowest-sequence PENDING row with `FOR UPDATE SKIP LOCKED`, ordered by
`(correlation_id, sequence_no)` (ORD-01). Returns `:no_pending` when the table is empty
or all PENDING rows are locked by other consumers.

```
@spec try_apply(
        completion :: Letflow.Ordering.Completion.t(),
        opts()
      ) :: :applied | :not_next | :lock_contention | :cursor_race | {:error, term()}
```

`try_apply/2` — executes the full claim→lock→order-check→apply transaction (§7). This
function IS the per-cycle unit; `run_cycle/2` in the context module calls `claim/1`
then `try_apply/2`.

---

### 6.3 `Letflow.Ordering.Sweeper`

```
@spec run(schema_name :: String.t(), opts()) :: :ok
```

Runs the gap sweeper for one schema (§8).

---

### 6.4 `Letflow.Ordering.Metrics`

```
@type lag_info :: %{
  correlation_id: String.t(),
  lag: non_neg_integer(),
  oldest_pending_age_seconds: non_neg_integer() | nil
}

@spec compute_all_lags(opts()) :: [lag_info()]
```

Returns per-correlation lag and oldest-pending age for every correlation in the given
tenant schema. A correlation with no PENDING rows has `oldest_pending_age_seconds: nil`
(not `0`) to distinguish "fully applied" from "just-inserted" (AC14).

```
@spec write_to_registry(lags :: [lag_info()], opts()) :: :ok
```

Writes gauge values to `Letflow.Metrics.Registry`'s ETS table and emits
lag-threshold-exceeded events for any correlation that crosses the configured threshold
(AC13–AC15).

---

### 6.5 `Letflow.Ordering.Cursor`

```
@spec upsert_init(correlation_id :: String.t(), opts()) ::
  {:ok, Letflow.Ordering.Cursor.t()} | {:error, term()}
```

Upsert-initialises a cursor row at `applied_seq = 0` if it does not exist (AC6). Called
inside the apply transaction — not a standalone public entry point for callers.

```
@spec advance_conditional(
        correlation_id :: String.t(),
        expected_current :: non_neg_integer(),
        opts()
      ) :: :ok | :race
```

Executes `UPDATE correlation_cursors SET applied_seq = $new WHERE correlation_id = $id
AND applied_seq = $expected_current`. Returns `:ok` on 1 row updated, `:race` on 0 rows
(AC5).

---

## 7. Claim-and-apply transaction (ORD-01/02/03)

This section defines the exact transaction boundary — every operation listed here is
inside ONE database transaction. No Repo connection is held between transactions.

### 7.1 Overview (maps to AC2, AC3, AC4, AC5, AC6, AC7)

```
Transaction T:
  M1. SELECT ... FOR UPDATE SKIP LOCKED (ORD-01 claim guard)
      ORDER BY (correlation_id, sequence_no) ASC LIMIT 1
      WHERE status = 'PENDING'
      -- No row found: commit empty transaction, return :no_pending
  M2. pg_try_advisory_xact_lock(hash_integer(correlation_id)) (ORD-02 execute guard)
      -- Returns false: rollback, return :lock_contention (no error, no retry increment)
  M3. Upsert-initialise cursor row at applied_seq=0 if not exists
  M4. Read cursor.applied_seq
  M5. if completion.sequence_no != cursor.applied_seq + 1 then
        rollback silently, return :not_next  (AC4)
      end
  M6. EventStore.append(effect_applied_event, platform_instance_id, payload, opts)
      -- AC12: event_type "effect_applied" must be in event_type_registry
  M7. UPDATE effect_completions SET status='APPLIED', applied_at=now()
      WHERE completion_id = $id
  M8. Cursor.advance_conditional(correlation_id, cursor.applied_seq, opts)
      -- 0 rows updated: rollback, return :cursor_race (AC5)
      -- 1 row updated: continue
  M9. COMMIT → return :applied
```

All eight steps are inside ONE `Repo.transaction/2` call. The Repo connection is
acquired at transaction open and released at commit or rollback. It is NEVER held
across the poll sleep between cycle calls (AC10, GH-654/ISS-0649 fix — R-Co held a
pooled connection across the sleep, starving small pools in production).

### 7.2 Advisory lock key derivation (ORD-02)

`pg_try_advisory_xact_lock` takes a 64-bit signed integer. The key is derived from
`correlation_id` as:

```
key = :erlang.phash2(correlation_id, 2_147_483_647)
```

This produces a non-negative integer in `[0, 2_147_483_646]`, which fits comfortably
in PostgreSQL's `bigint` advisory lock space. The hash is deterministic per
`correlation_id` value and consistent across BEAM restarts (`:erlang.phash2` uses a
stable algorithm).

**Open question OQ-1:** Should a stronger hash (e.g. `:crypto.hash(:sha256, correlation_id)`)
be used to reduce collision probability at high correlation-count tenants? `:erlang.phash2`
has a 31-bit range, yielding a birthday-collision probability of ~50% at ~55,000
distinct correlations. If a tenant can have more than ~10,000 active correlations
concurrently, a collision means two different correlations share an advisory lock and
are serialised — correct but suboptimal. `:erlang.phash2` is chosen here as the
simplest stable primitive; ELIXIR-DEV may substitute a wider hash if the tenant
scale warrants it.

### 7.3 Silent rollback for out-of-order completions (AC4)

When `completion.sequence_no != cursor.applied_seq + 1` at step M5:
- The transaction is rolled back.
- The `effect_completions` row status REMAINS `'PENDING'` — no mutation.
- No error is raised to the caller.
- No event is appended.
- No retry-count increment occurs (there is no retry count on this table).
- `run_cycle/2` returns `:not_next`.

This is the correct behavior: the row is merely waiting for its predecessor, not failed.

### 7.4 Cursor race rollback (AC5)

When `advance_conditional/3` at step M8 updates 0 rows:
- The transaction is rolled back.
- The `effect_completions` row status REMAINS `'PENDING'`.
- `run_cycle/2` returns `:cursor_race`.
- The caller (scheduler) may immediately re-claim on the next tick.

### 7.5 ORD-04 parallel execution (AC7)

Different correlations use different advisory lock keys (derived from their distinct
`correlation_id` values). Two consumers holding locks for different correlations
proceed fully in parallel — neither blocks the other. This is the ORD-04 guarantee.

---

## 8. Gap sweeper algorithm (AC8, AC9)

The sweeper runs once per scheduler tick, per tenant schema, via
`maybe_run_ordering_sweeper/1` in `Letflow.Scheduler.Poller`.

### 8.1 Predicate — strict greater-than (AC8, AC9)

A correlation is sweep-eligible if AND ONLY IF ALL of the following hold:

1. It has at least one `PENDING` row.
2. Its lowest `sequence_no` among PENDING rows is **strictly greater than**
   `cursor.applied_seq + 1`.
3. The oldest `PENDING` row in that correlation has `created_at` older than
   `gap_timeout_seconds` seconds ago.

**STRICT GREATER-THAN rule (AC8 explicit test):** a correlation whose lowest PENDING
sequence is exactly `applied_seq + 1` is merely slow. It must NOT be swept regardless
of age. The check is `min_pending_seq > applied_seq + 1`, not `>=`.

A cursor row that does not exist is treated as `applied_seq = 0` for this computation
(consistent with the upsert-init in §7 — a new correlation with no cursor row is
assumed to be at position 0).

### 8.2 Sweep action — all-or-nothing per correlation (AC8)

For each sweep-eligible correlation, in a single database transaction:

1. `UPDATE effect_completions SET status='DEAD' WHERE correlation_id=$c AND status='PENDING'`
   — moves EVERY PENDING row of the correlation to DEAD as one unit.
2. Collect all `sequence_no` values that were updated (via `RETURNING sequence_no`).
3. Call `Letflow.Dlq.enqueue/2` with:
   ```
   entry_type: "ordering_gap",
   reference_id: correlation_id,
   reason: "gap timeout — no predecessor",
   context_json: %{
     "correlation_id" => correlation_id,
     "unapplied_sequence_numbers" => [list of sequence_nos, sorted ascending],
     "applied_seq" => cursor.applied_seq,
     "oldest_pending_age_seconds" => <computed age>
   }
   ```
   Exactly ONE DLQ entry per correlation per sweep (AC8). The `context_json` names all
   unapplied sequence numbers in that correlation.

If the `Dlq.enqueue/2` call fails (e.g. changeset error), the whole transaction is
rolled back — no DEAD rows are committed without a corresponding DLQ entry. This keeps
the DLQ and the `effect_completions` table consistent.

### 8.3 Gap timeout configuration (AC9)

Config key: `:letflow, :ordering, :gap_timeout_seconds`
Default: `300` (5 minutes).

Read via `Application.get_env(:letflow, :ordering, [])` on every sweeper run (not
cached at startup), so a runtime override (e.g. in a test via
`Application.put_env/3`) takes effect on the very next tick — same discipline as the
scheduler's own config reading.

---

## 9. DLQ integration

Function called: `Letflow.Dlq.enqueue/2`

Arguments shape:
```
@spec sweep_enqueue_attrs() :: %{
  required(:entry_type) => String.t(),         # "ordering_gap"
  required(:reference_id) => String.t(),        # correlation_id
  required(:reason) => String.t(),              # human-readable gap description
  required(:context_json) => map()              # see §8.2 for keys
}
```

The `opts` passed to `Letflow.Dlq.enqueue/2` use the same `[prefix: schema_name]` as
every other per-tenant Dlq call — `tenant_id` is derived by `Letflow.Dlq` from the
prefix, not supplied by the sweeper.

---

## 10. ORD-04 lag surface (AC13, AC14, AC15, AC16)

### 10.1 Metric names and types

New gauge families added to `Letflow.Metrics.Registry`'s ETS table:

| Prometheus family name | Kind | Labels | Description |
|---|---|---|---|
| `letflow_ordering_correlation_lag` | gauge | none | Platform-wide max lag (max(sequence_no) - applied_seq) across all correlations across all tenant schemas |
| `letflow_ordering_oldest_pending_age_seconds` | gauge | none | Platform-wide max age in seconds of the oldest PENDING row across all correlations across all tenant schemas |

**Label allow-list: none.** No `correlation_id`, `tenant_id`, or any per-entity
identifier is ever used as a label value. This preserves the
tenant-safety invariant established by `Letflow.Metrics.Registry` (AC16 / design §1
Axis 2/3): `GET /metrics` is a global, unauthenticated endpoint and must never carry
per-tenant identifiers.

**Per-correlation lag detail is NOT exposed as a Prometheus metric** (no per-correlation
label). It IS computed internally (§10.2) and used for threshold detection and event
emission (AC15). The platform-wide max is the only surface exposed to Prometheus.

### 10.2 Lag computation (AC13)

For each tenant schema:
```
SELECT
  ec.correlation_id,
  MAX(ec.sequence_no) - COALESCE(cc.applied_seq, 0) AS lag,
  MIN(ec.received_at) AS oldest_pending_age_ref
FROM effect_completions ec
LEFT JOIN correlation_cursors cc USING (correlation_id)
WHERE ec.status = 'PENDING'
GROUP BY ec.correlation_id, cc.applied_seq
```

A correlation with no PENDING rows contributes `lag = 0` and `oldest_pending_age_seconds = nil`.
A fully-applied correlation (no PENDING rows) reports `0` lag (AC13 explicit test for
`lag = 0`).

### 10.3 Writing to registry (AC13)

Platform-wide max lag (across all correlations, all schemas) is written once per tick:
```
:ets.insert(:letflow_metrics, {{:gauge, :ordering_correlation_lag, %{}}, max_lag})
:ets.insert(:letflow_metrics, {{:gauge, :ordering_oldest_pending_age_seconds, %{}}, max_age_or_nil})
```

When no PENDING rows exist in any schema, both gauges are written as `0` and `nil`
respectively. `nil` oldest age means "no pending rows" — `Letflow.Metrics.Exposition`
must omit or write a sentinel for this gauge when the value is nil.

**Open question OQ-2:** Should the exposition layer write `NaN` or omit the age gauge
when no PENDING rows exist? Prometheus convention allows omitting a gauge between
scrapes; writing `0` is misleading (indistinguishable from a just-inserted row, AC14
concern). ELIXIR-DEV should resolve with the Exposition module author (REQ-194's
implementation).

### 10.4 Lag threshold event emission (AC15)

Config key: `:letflow, :ordering, :lag_threshold`
Default: `10` (10 completions behind).

When any correlation's lag exceeds this threshold, emit via
`Letflow.EventStore.append_platform_event/2`:

```
event_type:   "ordering_lag_threshold_exceeded"
payload: %{
  "correlation_id"             => correlation_id,
  "lag"                        => lag_value,
  "oldest_pending_age_seconds" => age_value_or_nil
}
opts: [prefix: schema_name]
```

One event per correlation per tick (not per excess row). If multiple correlations
exceed the threshold in one tick, one event per correlation is emitted.

---

## 11. Event type registration (AC12)

Event type string: `"effect_applied"`

Must be present in the per-tenant `event_type_registry` table before `run_cycle/2`
can successfully apply any completion. `Letflow.EventStore.append/2` validates this
via `Letflow.EventStore.Registry.validate_payload/3` before opening the transaction
(ES-05 check).

ELIXIR-DEV must add a seed migration or an upsert in `TenantProvisioning.replay_migrations/1`
that inserts `"effect_applied"` into `event_type_registry` for each tenant schema. The
exact mechanism matches REQ-140's precedent for `"instance_promoted"` /
`"instance_promotion_failed"` / `"instance_promotion_deferred"`.

Also: event type string `"ordering_lag_threshold_exceeded"` (§10.4) must be registered
by the same mechanism.

**Open question OQ-3:** Does `event_type_registry` allow free-form event types (any
string registered at migration time), or is there a closed enum in the schema that must
be expanded? Confirm against `lib/letflow/event_store/registry.ex` before
implementing. REQ-140's approach (seed upsert in a migration) is the assumed precedent.

---

## 12. Wiring into REQ-186's scheduler (AC11)

### 12.1 Function in `poller.ex` to extend

`handle_info(:tick, state)` in `Letflow.Scheduler.Poller` — the same function extended
by REQ-188 (retention sweep), REQ-194 (active instances), and REQ-201 (alert detection).

### 12.2 New private helpers to add (three, not one)

The consumer, sweeper, and metrics are independent concerns. Each gets its own
`maybe_run_*` helper following the REQ-201 `maybe_run_alert_detection/3` precedent:
isolated via `try/rescue`, noop when disabled, no crash of the whole scheduler.

```
# Called after maybe_run_alert_detection — reuses `schemas` list already computed
defp maybe_run_ordering_cycle(schemas)
defp maybe_run_ordering_sweeper(schemas)
defp maybe_run_ordering_metrics(schemas)
```

Each iterates `schemas` and calls the corresponding `Letflow.Ordering.*` function per
schema, wrapped in `try/rescue _ -> :ok end` so a single tenant's failure does not
affect others or crash the scheduler.

Config key for enable/disable: `:letflow, :ordering, :enabled` (default `true`).
All three helpers check this flag; if `false`, all three are noops.

### 12.3 `application.ex` — NO CHANGE (AC11)

No new child is added to `lib/letflow/application.ex`. The consumer, sweeper, and
metrics each run as private helpers on the existing `Letflow.Scheduler.Poller` process.
This is confirmed by the requirement's own AC11: "confirmed by git diff of
application.ex."

---

## 13. Connection pool discipline (AC10, GH-654/ISS-0649 fix)

R-Co's ordering subsystem held a pooled database connection across the poll sleep between
cycle calls, starving small pools under high consumer counts (GH-654/ISS-0649). Letflow
does NOT port this defect.

**Rule:** A `Repo` connection is acquired exactly at `Repo.transaction/2` open and
released exactly at commit or rollback. Between calls to `run_cycle/2` — i.e., between
individual tick invocations — no connection is held. The scheduler tick completes, the
process goes idle, and the connection is fully returned to the pool before the next tick
fires.

ELIXIR-DEV must ensure no `Repo.checkout/2` or explicit connection-pinning call wraps
multiple cycle invocations.

---

## 14. `test/support/tenant_fixture.ex` update (anti-pattern note)

`@expected_tenant_tables` at line 122 must be extended with both new tables, in
alphabetical position within the existing sorted list:

- `"correlation_cursors"` (between `"definition_sequence"` and `"dlq_entries"`)
- `"effect_completions"` (between `"dlq_entries"` and `"event_idempotency"`)

Failure to add these causes the oracle test (ISS-0109 guard, design §3.3 INV-F-7) to
fail at runtime even when the migrations run cleanly. This is an established anti-pattern
(see `docs/anti-patterns.md`): REQ-181 (`webhook_subscriptions`/`webhook_delivery_attempts`),
REQ-195 (`audit_entries`), and REQ-202 (`repository_artifacts`/`artifact_versions`) all
required the same fix.

---

## 15. Deferred item: ORD-04 dynamic consumer-count reduction (AC16)

**Explicitly deferred, NOT in this requirement.**

ORD-04's full design in R-Co has two halves:
1. **Lag measurement** — implemented here (§10).
2. **Dynamic consumer-count reduction under contention** — deferred.

The moduledoc of `Letflow.Ordering` must state:

> ORD-04's dynamic consumer-count reduction under contention is deliberately deferred
> and NOT implemented here. R-Co itself left this half unimplemented in production
> (its ordering subsystem was unwired — Letflow corrects that gap, but does not add
> the deferred reduction). The deferred half depends on REQ-194's metrics registry
> being established (which it now is), but the reduction algorithm itself (backoff
> heuristics, consumer-count configuration source) requires a separate design. See
> REQ-199's acceptance criterion 16 for the exact scope boundary.

---

## 16. Cross-module dependencies

| This module | Calls | Purpose |
|---|---|---|
| `Letflow.Ordering` | `Letflow.Ordering.Consumer` | claim-and-apply cycle |
| `Letflow.Ordering` | `Letflow.Ordering.Sweeper` | gap sweeper |
| `Letflow.Ordering` | `Letflow.Ordering.Metrics` | lag surface |
| `Letflow.Ordering.Consumer` | `Letflow.EventStore` (`append/2`) | effect-applied event |
| `Letflow.Ordering.Consumer` | `Letflow.Ordering.Cursor` | cursor upsert-init and advance |
| `Letflow.Ordering.Consumer` | `Letflow.Repo` | transaction, FOR UPDATE SKIP LOCKED |
| `Letflow.Ordering.Sweeper` | `Letflow.Dlq` (`enqueue/2`) | gap DLQ entry |
| `Letflow.Ordering.Sweeper` | `Letflow.Repo` | bulk DEAD update + RETURNING |
| `Letflow.Ordering.Metrics` | `Letflow.Metrics.Registry` (ETS) | lag gauge writes |
| `Letflow.Ordering.Metrics` | `Letflow.EventStore` (`append_platform_event/2`) | lag-exceeded event |
| `Letflow.Ordering.Metrics` | `Letflow.Repo` | lag query |
| `Letflow.Scheduler.Poller` | `Letflow.Ordering` | `run_cycle/2`, `sweep_gaps/2`, `emit_lag_metrics/2` |
| `Letflow.TenantProvisioning` | — | `tenant_id_for_schema_name/1` used in all opts-accepting functions |

---

## 17. Acceptance criteria mapping

| AC# | Design element |
|---|---|
| AC1 — per-tenant tables | §2 (placement decision), §5 (migrations wrapped in `if prefix() do`), §14 (tenant_fixture oracle) |
| AC2 — idempotent insert | §3 UNIQUE constraint + `insert_completion/2` ON CONFLICT DO NOTHING, §7.1 M7 (one APPLIED row) |
| AC3 — strict sequence order | §7.1 M5 order check + §7.3 silent rollback, sequence 6 stays PENDING until 5 is applied |
| AC4 — silent rollback for non-next | §7.3 — row stays PENDING, no error, no event appended, `:not_next` returned |
| AC5 — conditional cursor advance | §6.5 `advance_conditional/3`, §7.4 cursor-race rollback → `:cursor_race`, exactly one `applied_seq` advance |
| AC6 — missing cursor initialises at 0 | §7.1 M3 upsert-init, §6.5 `upsert_init/2`, §4 default `applied_seq = 0` |
| AC7 — different correlations parallel | §7.5 — different advisory lock keys, no cross-correlation serialisation |
| AC8 — sweeper all-or-nothing + strict > | §8.1 strict-greater-than predicate, §8.2 single transaction, one DLQ entry naming all sequence numbers |
| AC9 — gap timeout configurable | §8.3 `:letflow, :ordering, :gap_timeout_seconds`, default 300 |
| AC10 — no cross-sleep connection hold | §13 — connection acquired/released per transaction, not per tick |
| AC11 — wired, no new app.ex child | §12.2 three private helpers, §12.3 no application.ex change |
| AC12 — event type registered | §11 — `"effect_applied"` in `event_type_registry`, seed migration pattern |
| AC13 — lag computed and exposed | §10.1–§10.3 — `letflow_ordering_correlation_lag` gauge, lag = max(seq) - applied_seq |
| AC14 — oldest pending age, nil for no-PENDING | §10.2 `oldest_pending_age_seconds: nil` when no PENDING rows |
| AC15 — lag-exceeded event | §10.4 — `"ordering_lag_threshold_exceeded"` event with correlation, lag, age in payload |
| AC16 — moduledoc states deferral | §15 — exact moduledoc wording prescribed |
| AC17 — no route/controller changes | No route or controller listed in cross-module dependencies (§16); confirmed by git diff scope |
| AC18 — mix test + mix compile pass | No design element — runtime gate on ELIXIR-DEV's implementation; not a design artefact |

---

## 18. Open questions

**OQ-1 (advisory lock hash width):** `:erlang.phash2(correlation_id, 2_147_483_647)`
has a 31-bit range. Birthday-collision probability reaches ~50% at ~55,000 distinct
active correlations. If a tenant can have more than ~10,000 concurrent active
correlations, a stronger hash (e.g. first 8 bytes of `:crypto.hash(:sha256, correlation_id)`)
reduces collision probability to negligible at the cost of a `:crypto` dependency call.
ELIXIR-DEV should confirm the expected tenant scale before choosing.

**OQ-2 (Prometheus exposition of nil age gauge):** When no PENDING rows exist, should
`letflow_ordering_oldest_pending_age_seconds` be omitted from the scrape, written as `0`,
or written as `NaN`? Omitting avoids confusing `0` with "fresh row"; `NaN` is supported
by Prometheus but may confuse dashboards. Resolution depends on REQ-194's
`Letflow.Metrics.Exposition` module's nil-gauge handling convention.

**OQ-3 (event_type_registry mechanism):** Confirm whether `"effect_applied"` and
`"ordering_lag_threshold_exceeded"` can be inserted via a seed migration (REQ-140
precedent) or require a different registration mechanism. Read
`lib/letflow/event_store/registry.ex` before implementing §11.

**OQ-4 (consumer count):** REQ-199 defers dynamic consumer-count reduction but does
not specify a static consumer count. The current design wires a single `run_cycle/2`
call per schema per tick (one consumer). If higher throughput is needed, multiple
`run_cycle/2` calls per tick could be issued sequentially. ELIXIR-DEV should confirm
the intended single-vs-multiple-cycle-per-tick behavior with ORCH before implementing.

**OQ-5 (lag threshold default):** The design proposes a default of `10` for
`:letflow, :ordering, :lag_threshold`. This is an arbitrary round number; the real
appropriate value depends on expected effect completion latency and downstream
sensitivity. ORCH/REVIEWER should confirm or adjust this default.
