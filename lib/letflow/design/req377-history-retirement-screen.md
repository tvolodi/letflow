# REQ-377 — History retirement operator screen

Owner: CODE-DESIGNER (draft), CODE-DESIGN-VALIDATOR (gate), ELIXIR-DEV +
FRONTEND-DEV (implement). Depends on REQ-376 (merged to `main`,
`Letflow.EventStore.PartitionMaintenance`).

## 0. Scope decision — backend HTTP surface is IN SCOPE for this requirement

REQ-376 built the retirement *mechanism*
(`Letflow.EventStore.PartitionMaintenance.retire_month/3` and
`ensure_future_partitions/2`) but shipped **zero** HTTP API surface — confirmed by
grep, no router/controller anywhere calls either function
(REVIEWER's own MINOR note on decision 0037: *"`retire_month/3` has no live caller
anywhere in this diff... REQ-377's own design is what will decide who/what calls it
and how often"*). REQ-377's acceptance criteria require wiring the frontend to
"REQ-376's real endpoints", which do not exist. Per this session's established
precedent (REQ-399 naming its own required backend route as in-scope, citing
REQ-291/REQ-288 and REQ-398/REQ-397) and per ORCH's own dispatch instructions for
this run, **the backend HTTP route(s) below are designed and implemented as part of
REQ-377**, not treated as a blocker on a new backend requirement. No new permission
atom is introduced — `:TenantsManage` (`Letflow.Api.Authorization`, granted to
`PLATFORM_ADMIN` only via the existing catch-all `role_allows?(:PLATFORM_ADMIN, _)`
clause) is reused, following `lib/letflow/routers/platform_migrations.ex`'s own
precedent for an identical risk class (a platform-wide, cross-tenant action with no
single tenant `:prefix` to scope by).

## 1. Why this is a platform-wide fanout, not a single-schema call — and why it's async

`retire_month(schema_name, year, month)` operates on **one tenant schema at a
time**. The UAT scenario (`test/fixtures/uat/scenarios/platform/partition-retention-drop.yaml`)
frames this as a single platform-level operator action ("retire the oldest month of
expired history"), not a per-tenant selection screen — matching
`Letflow.Routers.PlatformMigrations`' own `MigrationRollout` fanout shape (one
operator action → iterate every tenant schema → aggregate a rollout + per-tenant
outcomes). This design reuses that shape rather than inventing a new one:
**"retire the oldest eligible month" fans out `retire_month/3` across every
provisioned tenant schema** (`tenant_schemas` table, `migrations_applied_at` not
nil — same source `Letflow.Scheduler.Poller.tenant_schemas/0` already reads),
computing the platform-wide oldest eligible month as the minimum across every
schema's own oldest eligible month, then retiring that month in every schema where
it is eligible (a schema where that month is already retired or doesn't exist is
skipped, not an error — same "already_current"-style tolerance
`MigrationRollout` already established).

**Why async, not synchronous like `MigrationRollout`:** read `partition_maintenance.ex`
in full (done for this design), and re-checked against the migrations after
CODE-DESIGN-VALIDATOR's rework note. `retire_month/3`'s steps are not all
metadata-only. Correcting a prior claim in this design: `count_protected_rows/2`
(`partition_maintenance.ex:787`, `SELECT count(*) ... WHERE event_type = ANY($1)`) is
**not** an unindexed table scan — `idx_events_type_p` (on `events_p`,
`priv/repo/migrations/20260922000001_create_events_partitioned.exs:114`) and
`idx_archive_type_p` (on `events_archive_p`,
`priv/repo/migrations/20260922000005_create_events_archive_partitioned.exs:52`) are
both declared on the partitioned parent tables, and Postgres ≥11 propagates a
parent-level index to every partition automatically (that migration's own comment
says so) — so this is an index/bitmap scan, and it is additionally scoped to the one
partition being retired (`count_protected_rows(schema_name, partition)` takes the
specific partition table as its target, not the whole `events` hierarchy), making it
cheap regardless of index use.

The genuine cost driver is `ensure_bounds_constraint!/5`'s `VALIDATE CONSTRAINT` step
(`partition_maintenance.ex:540-552`): this **is** a full sequential scan of the
retiring partition's every row, and Postgres does not skip it for a
`NOT VALID` ADD CONSTRAINT → `VALIDATE CONSTRAINT` pattern — that idiom only avoids
holding an `ACCESS EXCLUSIVE` lock for the scan's duration, it does not avoid the scan
itself. That scan's cost scales with the retiring partition's own row count (a full
month of platform event history for one tenant schema — unbounded by this design,
since nothing caps how large a tenant's monthly event volume can grow), and this
design's §1 fanout multiplies that by **every provisioned tenant schema** run
sequentially or with bounded concurrency. A single schema's scan may well be
sub-second; the fanout's total is not bounded by anything in this design and grows
linearly with tenant-schema count — exactly the shape a synchronous `POST` cannot
safely absorb (an operator population large enough to make the platform-wide fanout
run into multiple seconds is neither prevented nor unlikely, and `MigrationRollout`'s
own synchronous precedent covers metadata-only work, not a per-partition
sequential-scan DDL step). This is sufficient justification for the async
202+poll architecture on its own — the index fix above narrows *which* step is the
bottleneck, it does not remove the need for async. EO-001's own text ("the platform
stays responsive to other work throughout") and this run's explicit instruction both
point the same direction: **the HTTP request that kicks off retirement must return
immediately; the retirement itself runs out-of-band, tracked by a durable, pollable
status record** — not a synchronous call, and not an in-memory-only background task
(a second `GET` from a different request/process must be able to observe progress). This mirrors
`Letflow.Scheduler.Poller`'s own established pattern of running tenant-schema fanout
work via `Task.async_stream/3` under a dedicated `Task.Supervisor`
(`lib/letflow/supervisor/infrastructure.ex`'s "one dedicated `Task.Supervisor` per
independent async concern" convention — `SandboxPool.TaskSupervisor`,
`Obs.Alerts.TaskSupervisor`, etc.) — this design adds one more,
`Letflow.EventStore.RetirementTaskSupervisor`, rather than reusing an unrelated one.

This is a plain async job progressing to completion, not a named-state workflow with
caller-driven transitions — no `:gen_statem` (matches decision 0037's own REVIEWER
sign-off classification of `PartitionMaintenance` as maintenance/DDL work, not a
process state machine; REQ-045's Process-vs-row precedent applies the same way
`MigrationRollout` already applied it: a DB row is the source of truth, a
`Task.Supervisor.async_nolink/3` call does the work, no supervised
per-operation process).

## 2. Backend — new context module

### 2.1 `Letflow.EventStore.RetentionOperations` (new, `lib/letflow/event_store/retention_operations.ex`)

Plain context module (no process), calling `PartitionMaintenance` and
`Repo`/`Ecto.Query` directly — same shape as `Letflow.Platform.MigrationRollout`.

#### `Letflow.EventStore.PartitionMaintenance.eligible_months/1` (new public function,
added to the existing `partition_maintenance.ex` rather than to
`RetentionOperations` — this module already owns partition-boundary/catalog
knowledge, e.g. `catalog_state/2`'s `pg_inherits` query shape and
`min_partition_age_days/0`'s aging constant, so the "list this schema's
`events_y%m%` partitions and filter to aging-eligible ones" logic belongs beside
them, not duplicated in a caller. This resolves former OQ5.)

```
@spec eligible_months(schema_name :: String.t()) :: [{year :: pos_integer(), month :: 1..12}]
```

- Queries `pg_inherits`/`pg_class` (same catalog-query shape `catalog_state/2`
  already uses, generalized from "this one partition" to "every `events_y%m%`
  child of `events` attached under `schema_name`") to list that schema's
  currently-attached monthly partitions, ascending `(year, month)` order.
- Filters to months whose age (per each partition's own month-end boundary)
  exceeds `min_partition_age_days/0` — i.e. "eligible to retire", the same aging
  test `retire_month/3`'s own precondition already applies.
- Returns `[]` (never an error tuple) for a schema with no partitions or no
  eligible month yet — this is an expected, common state (a fresh or
  low-volume tenant schema), not a failure.
- No side effects, no locks beyond the catalog query's own implicit
  `AccessShareLock` — read-only, matching `catalog_state/2`'s existing
  discipline.

`RetentionOperations.retention_summary/0` and
`RetentionOperations.retire_oldest_eligible_month/1` **both** call this single
function (via one shared private helper in `RetentionOperations`, see below) —
there is exactly one code path that computes "oldest eligible month for a
schema," so the two call sites cannot diverge.

```
@type retirement_status :: :running | :completed | :failed

@type tenant_outcome :: %{
  tenant_id: Ecto.UUID.t(),
  schema_name: String.t(),
  status: :succeeded | :skipped | :failed,
  retired_partition: String.t() | nil,
  protected_rows_relocated: non_neg_integer() | nil,
  resumed_from: PartitionMaintenance.resumed_from() | nil,
  reason: String.t() | nil,       # set on :skipped / :failed only
  completed_at: NaiveDateTime.t() | nil
}

@type retirement :: %{
  id: Ecto.UUID.t(),
  year: pos_integer() | nil,      # nil only if no schema had an eligible month
  month: 1..12 | nil,
  status: retirement_status(),
  requested_by: Ecto.UUID.t(),    # actor's user id, from the authenticated ctx
  started_at: NaiveDateTime.t(),
  completed_at: NaiveDateTime.t() | nil
}

@type retirement_result :: %{retirement: retirement(), outcomes: [tenant_outcome()]}
```

#### `retention_summary/0`

```
@spec retention_summary() ::
  {:ok, %{
    oldest_eligible_month: %{year: pos_integer(), month: 1..12} | nil,
    protected_record_count: non_neg_integer(),
    tenant_schema_count: non_neg_integer(),
    computed_at: NaiveDateTime.t()
  }}
```

- `tenant_schema_count`: `count(*)` over `tenant_schemas` where
  `migrations_applied_at is not null` (same predicate as
  `Poller.tenant_schemas/0`).
- `oldest_eligible_month`: for every such schema, calls
  `PartitionMaintenance.eligible_months(schema_name)` and takes its `List.first/1`
  (already ascending) as that schema's own oldest eligible month, then takes the
  minimum `(year, month)` across all schemas that returned at least one entry.
  `nil` if no schema currently has an eligible month (maps to AC1's "retire the
  oldest eligible month" having nothing to do — see §2.3 error case). This
  minimum-across-schemas computation lives in one private helper,
  `RetentionOperations.oldest_eligible_month_platform_wide/0` (private,
  `@spec` `() :: {pos_integer(), 1..12} | nil`), called by both
  `retention_summary/0` and `retire_oldest_eligible_month/1` below — neither
  function re-derives it independently.
- `protected_record_count`: `SELECT count(*)` of rows whose `event_type` is in
  `Letflow.EventStore.RetentionPolicy`'s `:keep_forever` set, summed across
  `events` UNION `events_archive` for **every** tenant schema (cross-schema
  aggregate query, one `Repo.query!/2` per schema — not a single cross-schema
  SQL statement, since Postgres has no cross-schema wildcard `FROM`; this
  mirrors `count_protected_rows/2`'s own per-schema, per-table query shape).
  This is what EO-002 captures "before" and "after" — it is **retirement-count
  invariant by construction** (decision 0037: retirement never deletes a row,
  only reparents a whole partition), so a correct frontend/backend implementation
  must show the identical number before and after any retirement. Explicitly not
  scoped to the retiring month's own partition — it is the platform-wide
  protected-record count, which is what the UAT scenario's EO-002 evidence
  ("the operator console retention summary, captured before and after") reads
  as: a summary card, not a per-retirement report.

#### `retire_oldest_eligible_month/1`

```
@spec retire_oldest_eligible_month(requested_by :: Ecto.UUID.t()) ::
  {:ok, retirement()} | {:error, :no_eligible_month}
```

- Computes `oldest_eligible_month` via the same
  `oldest_eligible_month_platform_wide/0` private helper `retention_summary/0`
  uses (never two divergent derivations of "oldest eligible month").
- `{:error, :no_eligible_month}` if none exists — the router maps this to 409,
  see §2.3.
- On success: inserts one `event_history_retirements` row
  (`status: "running"`, `year`/`month` set, `requested_by`, `started_at:
  NaiveDateTime.utc_now()`), then calls
  `Task.Supervisor.async_nolink(Letflow.EventStore.RetirementTaskSupervisor, fn ->
  run_retirement(retirement_id, year, month) end)` and returns
  `{:ok, retirement}` **immediately**, before the task completes — the DB
  insert (not the task) is what the caller gets back, so a `GET` issued the
  instant after this returns can already find the `"running"` row.
- `run_retirement/3` (private, runs inside the spawned task): iterates every
  `tenant_schemas` row via `Task.Supervisor.async_stream/4` (bounded
  concurrency — reuses `Letflow.Scheduler.Admission.global_cap/0`, the same
  cap `Poller` already applies, rather than inventing a second concurrency
  knob), calling `PartitionMaintenance.retire_month(schema_name, year, month)`
  per schema and writing one `event_history_retirement_outcomes` row per
  schema (`:succeeded` on `{:ok, result}`, `:skipped` on
  `{:error, :partition_not_eligible}` / `{:error, :partition_not_found}`
  — expected/benign, a schema that doesn't hold that month or aged out of
  eligibility between the summary computation and this run is not a failure —
  `:failed` on any other error, with `reason` set to `inspect(error)`,
  never a raw exception message per INV-4's spirit). When every schema has an
  outcome, updates the `event_history_retirements` row to
  `status: "completed"`, `completed_at: NaiveDateTime.utc_now()`. A crash
  inside `run_retirement/3` itself (not an individual schema's error, which is
  already caught per-schema) is caught by the task's own `rescue` and marks the
  retirement row `status: "failed"` with a generic reason — never left stuck at
  `"running"` forever; `async_nolink` means this crash does not propagate to
  the caller or to `RetirementTaskSupervisor` itself.

#### `retirement_status/1`

```
@spec retirement_status(id :: Ecto.UUID.t()) ::
  {:ok, retirement_result()} | {:error, :retirement_not_found}
```

Reads the `event_history_retirements` row plus its
`event_history_retirement_outcomes` rows (same `rollout_status/1` shape
`MigrationRollout` already established) — this is what the frontend polls.

### 2.2 New tables (migration, e.g. `priv/repo/migrations/20260922000010_create_event_history_retirements.exs`)

Global (public-schema) tables, same tier as `platform_migration_rollouts` /
`platform_migration_rollout_outcomes` — these track a platform-wide operation, not
per-tenant business data, so they live outside any tenant `:prefix`, following that
exact precedent.

```
create table(:event_history_retirements, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :year, :integer, null: false
  add :month, :integer, null: false
  add :status, :string, size: 32, null: false, default: "running"
  add :requested_by, references(:users, type: :binary_id, on_delete: :nothing), null: false
  add :started_at, :naive_datetime, null: false
  add :completed_at, :naive_datetime
end

create table(:event_history_retirement_outcomes, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :retirement_id, references(:event_history_retirements, type: :binary_id, on_delete: :delete_all), null: false
  add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
  add :status, :string, size: 32, null: false, default: "pending"
  add :retired_partition, :string
  add :protected_rows_relocated, :integer
  add :resumed_from, :string
  add :reason, :string
  add :completed_at, :naive_datetime
end

create index(:event_history_retirement_outcomes, [:retirement_id])
create index(:event_history_retirements, [:status])
```

(References `:users` for `requested_by` — confirm this table name matches
whatever S1 identity table actually holds the authenticated actor's id;
ELIXIR-DEV should verify against `Letflow.Api.AuthorizedRouter`'s `ctx` shape
before implementing — flagged as OQ1, §7.)

### 2.3 New router — `Letflow.Routers.EventRetention` (new,
`lib/letflow/routers/event_retention.ex`), mounted at `/event-retention` by
`Letflow.Plugs.ApiPipeline` (`forward("/event-retention", to:
Letflow.Routers.EventRetention)`, alongside the existing
`forward("/platform-migrations", ...)` line) — full paths under `/api/v1`:
`/api/v1/event-retention/summary`, `/api/v1/event-retention/retirements`,
`/api/v1/event-retention/retirements/:id`.

| Handler | Method/path | Domain fn | Auth | Response |
|---|---|---|---|---|
| summary | `GET /event-retention/summary` | `RetentionOperations.retention_summary/0` | `:TenantsManage` | 200, summary map |
| start | `POST /event-retention/retirements` | `RetentionOperations.retire_oldest_eligible_month/1` | `:TenantsManage` | 202, `retirement` map; 409 on `:no_eligible_month` |
| status | `GET /event-retention/retirements/:id` | `RetentionOperations.retirement_status/1` | `:TenantsManage` | 200, `%{retirement:, outcomes:}`; 404 on `:retirement_not_found` |

- `start` responds **202 Accepted**, not 200/201 — the operation is not
  complete when the response is sent (§1's async design). Uses
  `Letflow.Api.Response.send_json(conn, 202, body)` (the existing generalized
  primitive `ok/2`/`created/2` already share — no new helper needed).
- `start`'s request body is **empty** (`POST` with no JSON body, or `{}`) —
  "oldest eligible month" is always system-computed, never caller-supplied
  `year`/`month`. This is a deliberate simplification versus a
  caller-specified-month endpoint: it removes any need to validate a
  caller-supplied year/month against eligibility (no INV-7-relevant
  identifier-injection surface at all — every DDL identifier
  `PartitionMaintenance` builds is already system-derived per its own
  moduledoc, and this endpoint doesn't add a new caller-controlled input to
  that derivation), and it matches the UAT scenario's own framing ("Retires
  the oldest eligible month... in one action" — no month picker in the
  scenario's `steps[2].input`, just `period: the oldest month held`, which is
  system-determined, not operator-chosen).
- `requested_by` comes from `conn.assigns` / the authenticated `ctx`
  `Letflow.Plugs.Authorize` already populates (same source
  `Letflow.Routers.PlatformMigrations`'s siblings use for actor attribution
  elsewhere in this codebase — ELIXIR-DEV: confirm the exact assign key,
  e.g. `conn.assigns.current_user.id`, against `Letflow.Plugs.Authorize`'s
  actual implementation; not verified in this design pass, OQ2 §7).
- No `authz_post "/retirements/:id/resume"` — unlike `MigrationRollout`, a
  failed/partial retirement is not resumed by re-POSTing a specific id;
  `PartitionMaintenance.retire_month/3` is itself idempotent/resumable
  (§4.3.1), so simply calling `POST /retirements` again naturally resumes any
  schema left mid-detach by a prior crashed run, exactly the way decision
  0037 already designed `retire_month/3` to self-heal. No new resume verb
  needed — flagged explicitly rather than silently omitted.

## 3. Frontend — `web/`

### 3.1 New API client — `web/src/api/eventRetention.ts` (new, mirrors
`web/src/api/platformMigrations.ts`'s shape/field-name-verbatim convention)

```ts
export interface RetentionSummary {
  oldest_eligible_month: { year: number; month: number } | null
  protected_record_count: number
  tenant_schema_count: number
  computed_at: string // ISO 8601
}

export interface RetirementOutcome {
  tenant_id: string
  status: 'succeeded' | 'skipped' | 'failed' | 'pending'
  retired_partition: string | null
  protected_rows_relocated: number | null
  resumed_from: 'not_started' | 'pending_detach' | 'detached_standalone' | 'already_retired' | null
  reason: string | null
  completed_at: string | null
}

export interface Retirement {
  id: string
  year: number | null
  month: number | null
  status: 'running' | 'completed' | 'failed'
  requested_by: string
  started_at: string
  completed_at: string | null
}

export interface RetirementResult {
  retirement: Retirement
  outcomes: RetirementOutcome[]
}

export const eventRetentionApi = {
  summary: () => client.get<RetentionSummary>('/api/v1/event-retention/summary'),

  start: () => client.post<Retirement>('/api/v1/event-retention/retirements', {}),

  status: (retirementId: string) =>
    client.get<RetirementResult>(`/api/v1/event-retention/retirements/${encodeURIComponent(retirementId)}`),
}
```

(`start` returns just `Retirement`, not `RetirementResult` — the 202 response body
per §2.3 has no `outcomes` yet, matching the backend's own response shape exactly;
the frontend switches to polling `status/1` for outcomes.)

### 3.2 `queryKeys.ts` — new section, same pattern as `platformMigrations`

```ts
eventRetention: {
  all: ['event-retention'] as const,
  summary: () => [...queryKeys.eventRetention.all, 'summary'] as const,
  retirement: (id: string) => [...queryKeys.eventRetention.all, 'retirement', id] as const,
},
```

### 3.3 New hooks — `web/src/hooks/useEventRetention.ts` (new)

```ts
export function useRetentionSummary() {
  return useQuery<RetentionSummary, ApiError>({
    queryKey: queryKeys.eventRetention.summary(),
    queryFn: eventRetentionApi.summary,
  })
}

export function useStartRetirement() {
  const qc = useQueryClient()
  return useMutation<Retirement, ApiError, void>({
    mutationFn: () => eventRetentionApi.start(),
    onSuccess: (data) => {
      qc.invalidateQueries({ queryKey: queryKeys.eventRetention.retirement(data.id) })
    },
  })
}

// §1's async design's frontend half: poll while status === 'running',
// stop polling once 'completed'/'failed' — this IS the "no full-page
// blocking spinner tied to the retirement's own duration" requirement
// (EO-001) realized in the UI: the page stays interactive, this hook's
// own refetchInterval callback just checks in periodically.
export function useRetirementStatus(retirementId: string | null) {
  return useQuery<RetirementResult, ApiError>({
    queryKey: queryKeys.eventRetention.retirement(retirementId ?? ''),
    queryFn: () => eventRetentionApi.status(retirementId as string),
    enabled: !!retirementId,
    refetchInterval: (query) =>
      query.state.data?.retirement.status === 'running' ? 2000 : false,
  })
}
```

Polling interval (2000ms) is an explicit, tunable choice — flagged as OQ3 (§7),
no production-latency data behind it yet (same honesty precedent
`PartitionMaintenance`'s own `min_partition_age_days`/`reconciliation_batch_size`
OQ4/OQ7 already set for this requirement's backend half).

### 3.4 New page — `web/src/pages/admin/event-retention/EventRetentionPage.tsx`
(new directory, mirrors `pages/admin/platform-migrations/`'s layout)

Structure (component responsibilities, not implementation):

- `EventRetentionPage` (default export) — role-gates on `PLATFORM_ADMIN` exactly
  like `PlatformMigrationConsolePage` does (`session.roles.includes('PLATFORM_ADMIN')`,
  `<Navigate to="/instances" replace />` otherwise) — satisfies **AC3** ("reachable
  only to a PLATFORM_ADMIN-equivalent role"), in addition to the nav-entry gate
  (§3.5) and the router-level authz already enforced server-side (§2.3's
  `:TenantsManage`, which is the actual security boundary — the frontend gate is
  UX, not the enforcement point, same division of responsibility
  `PlatformMigrationConsolePage` already establishes).
- `RetentionSummaryCard(props: { summary: RetentionSummary | undefined; isLoading: boolean })`
  — renders `oldest_eligible_month` (or "No month currently eligible"),
  `protected_record_count` (prominently — this is EO-002's evidence),
  `tenant_schema_count`, `computed_at`. Rendered **twice** conceptually on this
  page: once as the live "current" summary (refetched independently before and
  after a retirement — not cached across the retirement action, so its own
  `useRetentionSummary()` call is invalidated in `onSuccess`/status-completion,
  see below), satisfying **AC2** ("capturable before and after a retirement").
  A `data-testid="retention-summary-protected-count"` element specifically
  carries the protected count so the E2E spec (§3.6) can assert its value is
  unchanged across the retirement action, matching EO-002's verification
  method directly.
- `RetireOldestMonthButton(props: { disabled: boolean; onRetire: () => void; loading: boolean })`
  — a single button, no form (no caller-supplied year/month, per §2.3). Disabled
  when `summary.oldest_eligible_month === null` (nothing eligible) — this
  satisfies **AC1**'s "lets a PLATFORM_ADMIN retire the oldest eligible month
  and displays the resulting retirement record" by being the one action on the
  page; success writes `retirementId` into local state (and into
  `useSearchParams`, mirroring `PlatformMigrationConsolePage`'s own
  `?rollout=` deep-link convention — `?retirement=<id>`) which mounts the
  status panel below.
- `RetirementStatusPanel(props: { result: RetirementResult })` — renders the
  `retirement` record (id, year/month, status badge via the existing
  `StatusBadge` component with a new `domain="event-retirement"` — see §3.5
  OQ, `StatusBadge.tsx` already keys its palette by domain per
  `PlatformMigrationConsolePage`'s own `rollout`/`rollout-outcome` precedent)
  and an outcome table (tenant → succeeded/skipped/failed, retired partition
  name, protected rows counted, reason if failed) — **this table itself is the
  "resulting retirement record" AC1 requires displayed**. **Not** gated behind a
  `QueryStateBoundary`'s loading state for the *retirement's own duration* —
  while `status === 'running'`, the panel renders the partial state (whatever
  outcomes exist so far, a "Retiring… N of M tenants done" line) rather than a
  full-page spinner tied to completion; only the *initial* fetch of the first
  status response uses `QueryStateBoundary`'s ordinary loading affordance
  (matching `PlatformMigrationConsolePage`'s existing `statusState`
  classification pattern), never re-entering a blocking loading state on each
  2-second poll tick (`useRetirementStatus`'s `enabled`/cached-`data` behavior
  already keeps prior data visible during a background refetch — React Query's
  default `keepPreviousData`-equivalent for a query re-run with the same key —
  so no extra flag is needed to prevent flicker). **This is the concrete
  mechanism satisfying EO-001's "no full-page blocking spinner tied to the
  retirement's own duration"**: the button click's own mutation is a fast
  202-returning `POST` (not held open for the retirement), and the subsequent
  polling never re-blocks the page — the rest of the console (nav, other
  pages) is untouched by any of this, since nothing here holds a global
  loading lock.
- On `retirement.status` transitioning to `"completed"` (or `"failed"`),
  invalidate `queryKeys.eventRetention.summary()` so the "after" summary
  reflects the just-finished retirement — implemented as a `useEffect` keyed on
  `result.retirement.status` inside the page component (not inside the hook
  itself, keeping `useRetirementStatus` a pure read like
  `useRolloutStatus`/`useDefinitions`'s existing hooks).

### 3.5 Navigation entry — `web/src/components/layout/AppShell.tsx`

Add one entry to the existing `roles`-gated nav array (same list §-quoted
above), immediately after the `platform-migrations` entry:

```ts
// REQ-377: operator-facing history-retirement screen for REQ-376's
// whole-partition retirement mechanism. Same :TenantsManage
// (PLATFORM_ADMIN-only) risk class as admin/platform-migrations,
// admin/tenants.
{ to: '/admin/event-retention', label: 'Event Retention', roles: ['PLATFORM_ADMIN'] },
```

### 3.6 Router entry — `web/src/router.tsx`

```tsx
import EventRetentionPage from '@/pages/admin/event-retention/EventRetentionPage'
// ...
{ path: 'admin/event-retention', element: <EventRetentionPage /> },
```

### 3.7 E2E spec — `web/tests/e2e/pipelines/platform-partition-retention-drop.pipeline.e2e.spec.ts` (AC4)

Authored against the real screen (no mocks, per the frontend guide's guard
suite — no `msw`/raw `fetch` anywhere). Drives:

1. Log in as `actor-platform-admin` (existing fixture actor per
   `web/tests/e2e`'s established login helper), navigate to
   `/admin/event-retention`.
2. Capture the "before" protected-record count from
   `data-testid="retention-summary-protected-count"`.
3. Click the retire-oldest-month button; assert the button becomes disabled/
   loading momentarily but the page (e.g. the nav sidebar, a `data-testid`
   on an unrelated element) remains interactive immediately after — this is
   the E2E-observable form of EO-001 ("platform stays responsive"): no
   full-page overlay blocks interaction, not merely "the button eventually
   re-enables".
4. Poll (Playwright's own `expect(...).toPoll`/`waitFor`, not this page's own
   polling) until `retirement.status` reaches `"completed"`; assert the
   outcome table renders a `retirement_id`/retirement record — **AC1**.
5. Re-read the protected-record count; assert it equals the "before" value
   captured in step 2 — **AC2**/EO-002.
6. Assert a non-`PLATFORM_ADMIN` session (an existing fixture actor with a
   different role) navigating directly to `/admin/event-retention` is
   redirected away — **AC3**.
7. EO-003 (replay of a retired month's process instance) is **not** this
   spec's responsibility to newly prove — `EventStore.read/2`'s
   `events`/`events_archive` union already shipped and is tested under
   REQ-376's own test suite (decision 0037: "closes [req026 §11 OQ-3] as a
   side effect"); this spec only needs to confirm the retirement completed
   without error, which is sufficient evidence that no row was dropped
   (nothing in `retire_month/3` deletes rows — see §1).

## 4. Acceptance-criteria coverage map

| AC | Design element |
|---|---|
| AC1 (retire oldest eligible month, display resulting retirement record) | `POST /event-retention/retirements` (§2.3) → `RetireOldestMonthButton` + `RetirementStatusPanel`'s outcome table (§3.4) |
| AC2 (retention summary incl. protected-record count, before/after) | `GET /event-retention/summary` (§2.3) → `RetentionSummaryCard`, re-fetched on retirement completion (§3.4) |
| AC3 (PLATFORM_ADMIN-only reachability) | `:TenantsManage` authz on all 3 routes (§2.3) + frontend role-gate/redirect (§3.4) + nav entry role filter (§3.5) |
| AC4 (E2E pipeline spec passes against the real screen) | §3.7 |

## 5. Invariants

- **INV-7 (no user input into DDL identifiers):** unaffected — this design adds
  no new caller-controlled input to any `PartitionMaintenance` call.
  `retire_oldest_eligible_month/1`'s only "input" is `requested_by` (an actor id,
  used only as a stored attribution value, never interpolated into SQL text).
- **INV-4/INV-5 (no raw error/stacktrace leakage):** `tenant_outcome.reason` is
  `inspect(error)` of an **already-typed** `PartitionMaintenance` error tuple
  (`:partition_not_eligible`, `:partition_not_found`, `{:stuck_pending_detach,
  _}`), never a caught exception's raw message — same discipline
  `Letflow.Api.Response`'s moduledoc requires.
- **Idempotent re-POST:** calling `POST /event-retention/retirements` again
  while a prior retirement is `"running"` is **not prevented** by this design —
  flagged as OQ4 (§7): two concurrent fanouts computing the same "oldest
  eligible month" would both dispatch `retire_month/3` for the same
  `(schema, year, month)` per tenant, which `PartitionMaintenance` itself
  tolerates (idempotent/resumable, §4.3.1) but wastes a full table scan twice.
  Not blocking for AC coverage; noted for REVIEWER to decide whether a
  simple "reject a new POST while any retirement row is `running`" guard
  belongs in this pass or a follow-up.

## 6. Ecto schemas (new)

```
defmodule Letflow.EventStore.EventHistoryRetirement do
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_history_retirements" do
    field :year, :integer
    field :month, :integer
    field :status, :string          # "running" | "completed" | "failed"
    field :requested_by, Ecto.UUID
    field :started_at, :naive_datetime
    field :completed_at, :naive_datetime
    has_many :outcomes, Letflow.EventStore.EventHistoryRetirementOutcome, foreign_key: :retirement_id
  end
end

defmodule Letflow.EventStore.EventHistoryRetirementOutcome do
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_history_retirement_outcomes" do
    field :retirement_id, Ecto.UUID
    field :tenant_id, Ecto.UUID
    field :status, :string          # "pending" | "succeeded" | "skipped" | "failed"
    field :retired_partition, :string
    field :protected_rows_relocated, :integer
    field :resumed_from, :string
    field :reason, :string
    field :completed_at, :naive_datetime
  end
end
```

No `changeset/2` shown here (structural shape only, per this design step's own
scope fence — no implementation code). ELIXIR-DEV writes casts/validations
matching `Letflow.Platform.MigrationRollout`'s existing schema-pair style.

## 7. Open questions (do not silently resolve — flag to REVIEWER/ELIXIR-DEV)

- **OQ1:** `requested_by` references `:users` — confirm the actual S1 identity
  table name (`users` vs. something else) before writing the migration.
- **OQ2:** exact `conn.assigns` key for the authenticated actor's id —
  confirm against `Letflow.Plugs.Authorize`'s real implementation (not read in
  this design pass; the design assumes an equivalent of
  `conn.assigns.current_user.id` exists, matching whatever attribution
  mechanism other `PLATFORM_ADMIN`-gated writes already use).
- **OQ3:** the frontend's 2000ms poll interval is picked with no
  production-latency data behind it — revisit once real retirement durations
  (across a realistic tenant count) are observed, same category of
  provisional-default gap as `PartitionMaintenance`'s own OQ4/OQ7.
- **OQ4:** no guard against two concurrent `POST /event-retention/retirements`
  calls both racing to retire the same month — see §5's "Idempotent re-POST"
  note. Not required for AC coverage; flagged for REVIEWER to decide scope.
- **OQ5 (resolved):** `oldest_eligible_month` computation (§2.1) is backed by a
  new public function, `PartitionMaintenance.eligible_months/1` (full `@spec`
  given in §2.1), added to `partition_maintenance.ex` since that module already
  owns partition-catalog knowledge. Both `retention_summary/0` and
  `retire_oldest_eligible_month/1` call it through one shared private helper,
  `RetentionOperations.oldest_eligible_month_platform_wide/0` — no duplicated
  or divergent derivation. Nothing left for ELIXIR-DEV to decide here.
