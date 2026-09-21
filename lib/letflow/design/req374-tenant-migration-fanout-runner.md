# REQ-374 — Platform-wide tenant-migration fanout runner

**Status:** design, pre-implementation. **Owner:** ELIXIR-DEV (next step). **Stage:** S6.
**Depends on:** REQ-022 (`Letflow.TenantProvisioning`), REQ-297
(`run_column_promotion/1`, `run_column_promotion_for_all_tenants/1`), REQ-298
(`ConstraintActivation`/`references_entity` FK resolution).

## 0. Scope fence (restated from the requirement)

In scope: a rollout record, per-company enumeration/apply with failure isolation, a
per-company outcome record (SUCCEEDED+timestamp / FAILED+timestamp+reason) queryable per
`rollout_id`, a resume operation (outstanding companies only), idempotent re-run (zero
writes once every company is current), and permission-gated HTTP endpoints.

Out of scope (do not build): a general plugin/registry of "kinds of platform-wide
change" — this design proves the mechanism against exactly **one** concrete, real change
(§2). REQ-375's operator-facing screen (frontend, separate requirement).

## 1. Process-vs-row decision (mirrors REQ-045 / `Letflow.Engine`'s "Process-vs-row
decision", CLAUDE.md's explicit pointer)

**Decision: a plain transactional context module, `Letflow.Platform.MigrationRollout`.
No `gen_statem`, no supervised process, no new supervisor child.**

Applying the same test `Letflow.Engine`'s moduledoc uses for EE-01: is there a
multi-step conversation a caller holds open across several calls, a timer, backpressure,
or an external-plugin call? No. Every write this module performs is already
transactional at the point it happens:

- Per-company apply is one Postgres transaction (`run_column_promotion/1`, reused
  unchanged — see §5), already wrapped in `pg_advisory_xact_lock` exactly like every
  other `Letflow.TenantProvisioning` DDL path.
- The rollout-level state (which companies are outstanding, which succeeded/failed, the
  rollout's own `completed_at`) lives entirely in two Postgres tables (§3), not in any
  process's memory. A "rollout in progress" is not a live process an operator resumes by
  talking to — it is a durable row set an operator re-queries and re-drives by calling a
  function again (`start_rollout/3`, `resume_rollout/1`), exactly the same shape
  `run_column_promotion_for_all_tenants/1` (REQ-297, already shipped) already uses for
  its own narrower single-tenant-DDL fan-out.
- Concurrency is arbitrated by the same mechanism REQ-045 names for this project's whole
  architecture stance: Postgres row/advisory locks, not a supervised process per
  instance. `Letflow.InstanceSupervisor` stays untouched by this requirement, same as
  `Letflow.Engine`'s own note that it "does not modify `instance_supervisor.ex` at all."
- A rollout spanning many companies is simply a loop over independent per-company
  transactions, driven synchronously by the caller (the HTTP handler, in turn driven by
  a human operator action per the UAT scenario's own `via: gui` steps). Nothing about
  fan-out over N companies needs restart semantics or an in-memory worklist — the
  worklist **is** the outcome table's `status = "pending" OR "failed"` rows, re-derived
  fresh on every call.

This also directly extends REQ-297's own precedent: `run_column_promotion_for_all_tenants/1`
already fans out over every tenant's `pending` `ColumnPromotion` row as a plain function,
no process, "does not abort on the first failure" per its own `@doc`. REQ-374 is that
same shape, one layer up: a rollout record plus an explicit resume/idempotent-rerun API
surface REQ-297 doesn't need for its own narrower "one entity attribute" scope.

## 2. The concrete "change" fixture used to prove the mechanism

Per the scope fence, this requirement proves the fanout/resume/idempotent-rerun
mechanism against **one** real, concrete change — it reuses REQ-297/REQ-298's existing
column-promotion machinery unchanged rather than inventing a second DDL-execution path:

> **The change:** promoting one new column onto one entity type, tenant-schema by
> tenant-schema — i.e. exactly what `Letflow.TenantProvisioning.register_column_promotion/4`
> + `run_column_promotion/1` already do for a single `(tenant_id, entity_type,
> attribute)` triple. `Letflow.Platform.MigrationRollout` adds the platform-wide
> orchestration layer on top: it enumerates every active company, registers one
> `ColumnPromotion` row per company for the same `(entity_type, attribute)` pair, and
> drives `run_column_promotion/1` for each — recording a rollout-level outcome around
> REQ-297's own already-correct single-tenant DDL execution and its own already-correct
> `column_type_conflict`/`ddl_failed` error taxonomy.

This module does **not** know how to apply any other kind of change. `entity_type` and
`attribute` and `column_spec` are the only identifiers `start_rollout/3` accepts; there
is no dispatch table, no behaviour callback, no "kind" enum beyond the one path this
module implements. A future requirement that needs a second kind of platform-wide
change is exactly the "not invented here" case the scope fence names — it would extend
this module's single apply path or add a second one at that time, not be pre-built now.

**Why this choice satisfies EO-001/EO-002 without a mock.** REQ-297's
`check_additive_only/3` already inspects `information_schema.columns` and returns
`{:error, {:column_type_conflict, existing, requested}}` when a tenant's physical table
already has a same-named column of a different type — a real, deterministic Postgres
condition, not a fault injected via test doubles. The regression tests (§8) exploit this
directly: pre-seed one target company's entity table with a column of the *same name*
but a *conflicting type* before starting the rollout, so that company's `ALTER TABLE`
genuinely fails via the real DDL path while every other company's genuinely succeeds.

## 3. Schema / table design

Two new, global (non-tenant-scoped) tables, same convention as `entity_column_promotions`
(REQ-297) and `tenant_schemas` (REQ-022): plain `binary_id` primary key, no
`belongs_to` association on `tenant_id`, `foreign_key_constraint(:tenant_id)` declared
in the changeset for the DB-level FK.

### 3.1 `platform_migration_rollouts`

| Column | Type | Constraints |
|---|---|---|
| `id` | `binary_id` | PK, autogenerate |
| `entity_type` | `string` | not null |
| `attribute` | `string` | not null |
| `column_spec` | `map` (`:map`, stored as `jsonb`) | not null — the exact `column_spec` map `start_rollout/3` was first called with (`pg_type`, `nullable`, optional `references_entity`/`generated_as`), persisted so a repeat `start_rollout/3` call can detect a caller passing a *different* spec for the same `(entity_type, attribute)` pair (§6, open question OQ-2) and so `resume_rollout/1` never needs the caller to resupply it |
| `status` | `string` | not null, enum `~w(running completed)`, default `"running"` |
| `started_at` | `naive_datetime` | not null |
| `completed_at` | `naive_datetime` | nullable — set exactly once, the moment zero outcome rows for this rollout remain `status != "succeeded"`; never unset once set |

Indexes/constraints: unique index on `(entity_type, attribute)` — this is what makes
"starting the identical rollout again" (EO-005) resolve to the *same* row instead of
creating a duplicate rollout, and is the natural key for "the identical rollout" the UAT
scenario's step 6 means by that phrase.

### 3.2 `platform_migration_rollout_outcomes`

| Column | Type | Constraints |
|---|---|---|
| `id` | `binary_id` | PK, autogenerate |
| `rollout_id` | `binary_id` | not null, FK -> `platform_migration_rollouts.id` |
| `tenant_id` | `binary_id` (`Ecto.UUID`) | not null, FK -> `tenants.id` |
| `column_promotion_id` | `binary_id` (`Ecto.UUID`) | not null, FK -> `entity_column_promotions.id` — the underlying REQ-297 row this outcome wraps; the rollout layer never duplicates DDL-execution state, only summarizes it |
| `status` | `string` | not null, enum `~w(pending succeeded failed)`, default `"pending"` |
| `completed_at` | `naive_datetime` | nullable — set the instant `status` transitions away from `"pending"`; **never written again once set** (this is the literal mechanism behind EO-004's "original completion timestamp is unchanged") |
| `reason` | `string` | nullable — set only when `status == "failed"`, a plain-language sentence (§5.3), `nil` otherwise |

Indexes/constraints: unique index on `(rollout_id, tenant_id)` (one outcome row per
company per rollout — this is also what makes a repeat `start_rollout/3` call detect
"this company already has an outcome for this rollout" instead of inserting a second
one); index on `rollout_id` alone (the query surface AC3 asks for — "queryable per
rollout_id").

### 3.3 Migration file

New migration `priv/repo/migrations/20260921000001_create_platform_migration_rollouts.exs`
creates both tables in the default (public) schema — these are global bookkeeping
tables, not tenant-schema tables, matching `entity_column_promotions`'s own placement.

## 4. Public API — `Letflow.Platform.MigrationRollout`

```
@type rollout :: %{
        id: Ecto.UUID.t(),
        entity_type: String.t(),
        attribute: String.t(),
        status: String.t(),
        started_at: NaiveDateTime.t(),
        completed_at: NaiveDateTime.t() | nil
      }

@type outcome :: %{
        tenant_id: Ecto.UUID.t(),
        status: String.t(),
        completed_at: NaiveDateTime.t() | nil,
        reason: String.t() | nil,
        already_current: boolean()
      }

@type rollout_result :: %{rollout: rollout(), outcomes: [outcome()]}
```

`already_current` is a field on the *returned* outcome summary only (not persisted) —
true for a company whose outcome row was already `"succeeded"` *before this call ran*
and was therefore left untouched by this call. This is the field REQ-375's screen (and
this requirement's own tests) use to render/assert EO-005's "reports every company as
already-current" language without needing to diff two full snapshots.

### 4.1 `start_rollout/3`

```
@spec start_rollout(
        entity_type :: String.t(),
        attribute :: String.t(),
        column_spec :: %{
          required(:pg_type) => String.t(),
          required(:nullable) => true,
          optional(:references_entity) => String.t(),
          optional(:generated_as) => String.t() | nil
        }
      ) :: {:ok, rollout_result()} | {:error, term()}
```

Behavior:

1. Resolve target scope: `active_company_tenant_ids/0` (§4.5) — every tenant currently
   `status == :active` (`Letflow.Identity.Tenant`) **and** provisioned (has a
   `Letflow.TenantProvisioning.Registration` row). Scope is evaluated fresh at call
   time, matching `resolve_tenant_ids(:all)`'s own existing at-call-time semantics
   elsewhere in `Letflow.TenantProvisioning`.
2. Look up an existing `platform_migration_rollouts` row for `{entity_type, attribute}`.
   - **No existing row (first call — the common "start a new rollout" path):** insert
     one rollout row (`status: "running"`, `started_at: now`, `column_spec` stored
     verbatim). For every tenant in scope, call
     `Letflow.TenantProvisioning.register_column_promotion/4` with that **single**
     tenant_id (not `:all` — scope is frozen at this call, not re-derived from
     `ColumnPromotion`'s own broader tenant list), then insert one
     `platform_migration_rollout_outcomes` row (`status: "pending"`,
     `column_promotion_id` = the new row's id). Then call `apply_outstanding/1` (§4.4,
     private, shared with `resume_rollout/1`) to drive every `"pending"` outcome to a
     terminal `"succeeded"`/`"failed"` state. Recompute and persist the rollout's own
     `status`/`completed_at` (§4.6). Return `{:ok, rollout_result}`.
   - **Existing row (a repeat call for the same `{entity_type, attribute}` — the
     EO-005 / "start the identical rollout again" path):** do **not** call
     `register_column_promotion/4` again for any tenant that already has an outcome row
     for this rollout (the unique `(rollout_id, tenant_id)` index would reject a
     duplicate insert anyway — this is a belt-and-braces read-first check, not reliance
     on the constraint to signal "nothing to do"). For each tenant currently in scope:
     - has an outcome row with `status == "succeeded"` → leave it **untouched**, report
       it in the result with `already_current: true`. No DB write for this tenant.
     - has an outcome row with `status in ["pending", "failed"]` → genuinely
       outstanding; apply exactly as `resume_rollout/1` would (shared helper,
       `apply_outstanding/1`).
     - has **no** outcome row yet (a tenant that became active/provisioned after the
       rollout first started) → register + apply for it now, extending the rollout's
       scope. See OQ-1 (§9) — this is a genuine, explicitly-flagged design choice, not
       silently assumed.
   If every tenant in scope falls in the first bucket (already `"succeeded"`) — exactly
   EO-005's precondition ("every company already holds the change") — this call performs
   **zero writes**: no rollout row update (its `completed_at` was already set on the
   pass that finished it), no outcome row update, only `SELECT`s. This is the literal
   mechanism behind "identical rollout again ... performs zero writes."

### 4.2 `resume_rollout/1`

```
@spec resume_rollout(rollout_id :: Ecto.UUID.t()) ::
        {:ok, rollout_result()} | {:error, :rollout_not_found}
```

Loads the rollout row by id. Calls `apply_outstanding/1` (§4.4) scoped to exactly this
`rollout_id`'s outcome rows whose `status in ["pending", "failed"]` — **never** touches
a row whose `status == "succeeded"`: no re-fetch-and-resave, no second call into
`run_column_promotion/1` for it, nothing that could disturb its stored `completed_at`.
This is EO-004's literal contract, enforced structurally by the query `apply_outstanding/1`
runs (`WHERE status != "succeeded"`), not by an application-level "skip if already done"
branch that a future edit could accidentally weaken.

### 4.3 `rollout_status/1`

```
@spec rollout_status(rollout_id :: Ecto.UUID.t()) ::
        {:ok, %{rollout: rollout(), outcomes: [outcome()]}} | {:error, :rollout_not_found}
```

Pure read: the rollout row plus every outcome row for it, ordered by `tenant_id` (stable
ordering for the screen and for tests). This is AC3's "queryable per rollout_id" —
REQ-375's screen calls this and nothing else to render its per-company table.

### 4.4 `apply_outstanding/1` (private, shared by `start_rollout/3` and `resume_rollout/1`)

```
@spec apply_outstanding(rollout_id :: Ecto.UUID.t()) :: :ok
```

Queries every `platform_migration_rollout_outcomes` row for `rollout_id` where
`status != "succeeded"`, and for each, in turn (sequential — no `Task.async_stream`,
matching REQ-297's own sequential `Enum.reduce` in `run_column_promotion_for_all_tenants/1`,
since per-company DDL contention is already arbitrated by the per-schema advisory lock
and there is no throughput requirement in this requirement's acceptance criteria):

1. Drives the underlying `ColumnPromotion` row to a terminal state, branching on the
   row's own `status` — **three** branches, not two, the third covering the
   crash-recovery window §5.2 names explicitly:
   - `"pending"` → `Letflow.TenantProvisioning.run_column_promotion/1`.
   - `"ddl_failed"` → `Letflow.TenantProvisioning.retry_failed_column_promotion/1`.
   - `"ddl_applied"` / `"backfilling"` / `"backfilled"` / `"active"` (terminal-success
     states this column-promotion lifecycle can reach, per
     `Letflow.TenantProvisioning.ColumnPromotion`'s own status enum, REQ-297/298 §0) →
     **do not call any DDL function.** The DDL already succeeded (this is exactly the
     state a crash between step 1's commit and step 2's write, §5.2, leaves behind); the
     only work left is catching the outcome row up to reality. Treat this branch
     identically to a `{:ok, _column_promotion}` result from `run_column_promotion/1` in
     step 2 below — write `status: "succeeded"`, `completed_at: now`, `reason: nil`,
     without ever re-entering the advisory-locked DDL path for a column that is already
     there. Calling `run_column_promotion/1` again here would also be safe in practice
     (`check_additive_only/3`'s real `information_schema` check produces its own
     `:idempotent_skip` branch), but this design does not rely on that as the stated
     mechanism — it names the direct catch-up explicitly so the crash-recovery path
     never depends on an incidental idempotency property of a different function's
     internals.
   - `"suspended"` — the seventh and last value in the schema's own `@statuses` list
     (`lib/letflow/tenant_provisioning/column_promotion.ex:100`) — is **not** a fourth
     branch here, and this is a deliberate omission, not an oversight: verified directly
     against source (not taken on trust) that no function anywhere in
     `Letflow.TenantProvisioning` ever writes `status: "suspended"`.
     `suspend_column_promotion/2` (`lib/letflow/tenant_provisioning.ex:2073-2085`) is the
     only function whose name suggests it would, and its own `@doc` states the real
     behavior plainly: it requires `status == "active"` as a precondition and, on
     success, writes only `query_eligible: false` and `suspend_reason` — `status` is
     left at `"active"` by design (0024 §4, "preserves 'reached active at least once'"),
     never changed to `"suspended"`. A grep of `lib/letflow/` for the literal string
     `"suspended"` confirms this: every hit is in a design-doc's prose or the enum
     declaration itself, none in a write path. So a `ColumnPromotion` row reaching
     `apply_outstanding/1` can structurally never have `status == "suspended"` today —
     the value exists in the enum as a forward reservation, not as a state this design's
     own call path can observe. If a future requirement ever adds a real
     `status: "suspended"` write, that requirement is responsible for widening this
     branch too; this design does not pre-empt work nothing here creates a need for.
   For the first two branches, **this call is exactly REQ-297's existing, unchanged,
   already-tested transactional-per-tenant DDL path** — `apply_outstanding/1` adds no
   new DDL of its own; it only reacts to that call's result.
2. In a **separate** transaction from step 1 (deliberately — see §5.2 for why), updates
   this one outcome row:
   - on `{:ok, _column_promotion}` → `status: "succeeded"`, `completed_at: now`,
     `reason: nil`.
   - on `{:error, reason}` → `status: "failed"`, `completed_at: now`,
     `reason: describe_failure_reason(reason)` (§5.3).

One company's outcome-row update failing to change its terminal status is not possible
by construction here (a plain `Repo.update` against a row already loaded by id, no
constraint that can be violated by a same-row update) — no compensating logic is
needed for this step itself, only for the DDL step, which REQ-297 already handles.

### 4.5 `active_company_tenant_ids/0` (private)

```
@spec active_company_tenant_ids() :: [Ecto.UUID.t()]
```

`Ecto` query joining `tenants` (`status == :active`) to `tenant_schemas`
(`Letflow.TenantProvisioning.Registration`, i.e. provisioned tenants only) on
`tenant_id`, returning the tenant_id list. This is new — REQ-297's own
`resolve_tenant_ids(:all)` uses *every* registration regardless of `Tenant.status`,
which is correct for REQ-297's own scope (a promotion registered against `:all`
tenants is an explicit, one-shot operator action) but not what "every active company"
in REQ-374's acceptance criteria means; `:migrating`/`:inactive` tenants are excluded
here deliberately.

### 4.6 `recompute_rollout_completion/1` (private)

```
@spec recompute_rollout_completion(rollout_id :: Ecto.UUID.t()) :: :ok
```

After `apply_outstanding/1` runs, counts outcome rows for `rollout_id` with
`status != "succeeded"`. If zero, and the rollout's own `completed_at` is still `nil`,
sets `status: "completed"`, `completed_at: now` (one write). If nonzero, leaves the
rollout row exactly as it was (`status` stays `"running"`, `completed_at` stays `nil`) —
this is what leaves a rollout "resumable."

## 5. Failure isolation and the "no partial DDL" guarantee (EO-001, EO-002)

### 5.1 One company's failure never touches another's

`apply_outstanding/1` iterates outcome rows independently, one `run_column_promotion/1`
call (itself one Postgres transaction) per company. There is no enclosing transaction
across companies — this is the direct mechanism behind EO-001: a `{:error, _}` return
from one company's `run_column_promotion/1` call does not raise, does not abort the
loop, and cannot roll back a sibling company's already-committed transaction, because
that transaction already committed before this company's attempt even began.

### 5.2 The failing company is left exactly as it was pre-attempt (EO-002)

`run_column_promotion/1` (REQ-297, unchanged) already wraps its own DDL attempt in
`Repo.transaction/1`: a failing `ALTER TABLE` inside that transaction rolls back
automatically (Postgres DDL is transactional), so no partial column, no partial index,
no partial FK exists in that company's schema afterward. The *only* durable effect of a
failed attempt is `run_column_promotion/1`'s own follow-up write recording
`ColumnPromotion.status = "ddl_failed"` + `last_error` — a write against the **global**
`entity_column_promotions` bookkeeping table, never against the failing tenant's own
schema. `apply_outstanding/1`'s own outcome-row write (§4.4 step 2) is, by the same
reasoning, also against a global table only. **Neither of this design's two new tables
is tenant-schema-prefixed** (§3) — this requirement introduces no new write path into
any tenant's own schema beyond the single `ALTER TABLE` `run_column_promotion/1` already
issues and already rolls back correctly on failure. This is also why step 1 and step 2
in `apply_outstanding/1` are deliberately separate transactions (§4.4): if they were one
transaction and the DDL attempt aborted the connection (a genuinely raised Postgres
error, not just an ordinary `{:error, _}` return — see `run_column_promotion/1`'s own
`mark_ddl_failed_and_return/3` comment on this exact hazard), the outcome-row write
would be lost along with it. Keeping them separate is what makes the FAILED outcome
durable regardless of how the DDL attempt failed.

The regression test for EO-002 (§8) does not stop at asserting the outcome row reads
`"failed"` — it also queries `information_schema.columns` for the failing company's own
schema directly, asserting the promoted column is absent, and performs a real write
(case creation — reusing whatever helper the existing test suite already uses to create
a case in a given tenant schema; not a new helper this design invents) immediately
afterward in that same schema, asserting it succeeds. This is the literal mechanism
requested by the requirement text ("verified via a real write... succeeding
immediately").

### 5.3 `describe_failure_reason/1` (private)

```
@spec describe_failure_reason(term()) :: String.t()
```

Maps `run_column_promotion/1`'s `{:error, reason}` term to a plain-language sentence:

- `{:column_type_conflict, existing, requested}` → `"Could not apply the change to this
  workspace: an existing column already has a conflicting type (existing: #{existing},
  requested: #{requested})."`
- `{:ddl_failed, exception}` → `"Could not apply the change to this workspace: " <>
  Exception.message(exception)` — `run_column_promotion/1` already derives
  `Exception.message/1` from the real Postgres error, so this only adds a
  human-oriented prefix, not a new derivation.
- `:tenant_not_provisioned` → `"This workspace is not yet provisioned and cannot
  receive platform changes."`
- any other/unrecognized reason → `"Could not apply the change to this workspace: " <>
  inspect(reason)` — a safety net, not expected to be exercised by this requirement's
  own single change type, but named so no `{:error, reason}` value is ever dropped
  silently.

This satisfies "a human-readable reason string, derived from the actual error, not a
generic code" — the reason text always names the real mechanism (existing/requested
types, or the underlying exception message), never a bare atom or error code.

## 6. Idempotent re-run — extended reasoning (EO-005)

Two independent layers already make re-running the identical rollout a no-op, and the
design relies on both rather than one:

1. **`ColumnPromotion` layer (REQ-297, unchanged):** once a `ColumnPromotion` row is
   `"ddl_applied"` (or later), `run_column_promotion/1` is never called on it again by
   this design — `apply_outstanding/1`'s query only ever selects outcome rows
   `status != "succeeded"`, and an outcome only reaches `"succeeded"` once its
   underlying `ColumnPromotion` is already `"ddl_applied"`. So there is no code path in
   this design that re-invokes DDL against an already-promoted column.
2. **Rollout layer (new, this design):** `start_rollout/3`'s repeat-call branch (§4.1)
   explicitly separates "already succeeded" (zero writes, `already_current: true`) from
   "still outstanding" (apply again) *before* touching any row, rather than relying on
   `run_column_promotion/1`'s own idempotent-skip behavior as the only backstop — this
   is what lets `start_rollout/3` report "already-current" per company (AC/EO-005
   requires the *report*, not merely the absence of writes) without a spurious
   `Repo.transaction` + advisory-lock round trip per company on every re-run.

## 7. Permission decision

**Reused, not new: `:TenantsManage`** (`Letflow.Api.Authorization`, granted to
`PLATFORM_ADMIN` only via the existing catch-all `role_allows?(:PLATFORM_ADMIN, _)`
clause). Same risk class as the two existing precedents that already reuse this exact
permission for a platform-wide, cross-tenant-touching action outside any single tenant's
own `:prefix` scope: `POST /tenants` (REQ-075) and `POST /onboarding` (REQ-076,
moduledoc: "same risk class and same PLATFORM_ADMIN-only intent as
`Letflow.Routers.Tenants`. No new permission added for onboarding."). A platform-wide
migration rollout is the same shape again — an action with no single tenant context to
scope by, gated purely on role — so this design follows the same precedent rather than
adding a fourth permission atom for an identical risk class. This decision, and the
reasoning above, must be restated in `Letflow.Routers.PlatformMigrations`' own moduledoc
verbatim in substance (per this requirement's own acceptance criterion), not merely
cross-referenced.

### 7.1 New router — `Letflow.Routers.PlatformMigrations`

Top-level sibling router (same shape as `Letflow.Routers.Tenants`/`Onboarding`), mounted
at `/platform-migrations` by `Letflow.Plugs.ApiPipeline` (full paths under `/api/v1`).

| Handler | Method/path | Domain fn | Auth | Response |
|---|---|---|---|---|
| start | `POST /platform-migrations/rollouts` | `MigrationRollout.start_rollout/3` | `:TenantsManage` | 200 (200, not 201 — a repeat call returns the same logical resource, not a new one; the response body's `rollout.status` and per-company `already_current` flags are what distinguish a fresh run from a no-op re-run), `rollout_result` map |
| status | `GET /platform-migrations/rollouts/:id` | `MigrationRollout.rollout_status/1` | `:TenantsManage` | 200, `%{rollout:, outcomes:}` map, 404 on `:rollout_not_found` |
| resume | `POST /platform-migrations/rollouts/:id/resume` | `MigrationRollout.resume_rollout/1` | `:TenantsManage` | 200, `rollout_result` map, 404 on `:rollout_not_found` |

`endpoint_policy_key/2` gains three new clauses in `Letflow.Api.Authorization`, all
returning `:TenantsManage` — no new `role_allows?/2` clause, matching REQ-076's own
"no new role clauses added anywhere" precedent.

Request/response JSON shape (field-level, not implementation): `start` request body
`%{"entity_type" => string, "attribute" => string, "column_spec" => %{"pg_type" =>
string, "references_entity" => string | nil, "generated_as" => string | nil}}`
(`nullable` is not caller-supplied — REQ-297's own `register_column_promotion/4` already
treats it as always `true`, so this router never accepts it as input, matching that
function's existing contract). Response bodies serialize `rollout`/`outcome` maps
field-for-field as named in §4's types, `tenant_id`/`rollout_id`/timestamps as strings
(this project's existing JSON convention — see any other router's response-shaping
helper for the exact encoding, not restated here since it is not a new decision).

## 8. Regression-test design — mapped to every acceptance criterion

All tests live in `test/letflow/platform/migration_rollout_test.exs` (context-module
level) plus `test/letflow/routers/platform_migrations_test.exs` (HTTP/permission level).
Each test provisions at least 3 real tenant schemas via the existing
`Letflow.TenantProvisioning` test-support helpers already used by REQ-297/298's own test
suite (grep `test/support/` for the fixture already used there — reused, not
reinvented).

- **EO-001** (`migration_rollout_test.exs`): provision ≥3 tenants; in exactly one
  target tenant's schema, pre-create the entity table with a same-named,
  conflicting-type column (§2) so the real `check_additive_only/3` path fails
  deterministically. Call `start_rollout/3` targeting all active companies. Assert: the
  other ≥2 companies' outcome rows are `"succeeded"`; the poisoned company's outcome row
  is `"failed"` with a non-nil `reason` containing the plain-language conflict text
  (§5.3); `rollout.completed_at` is `nil` (still resumable) since one outcome is
  outstanding.
- **EO-002** (same file): immediately after the EO-001 setup, query
  `information_schema.columns` in the poisoned tenant's own schema directly (not via the
  rollout API) and assert the promoted column does not exist. Then perform a real case
  creation (or whatever the existing suite's real-write helper is) against that same
  tenant schema and assert it succeeds without error, proving the schema was left fully
  usable, not partially altered.
- **Outcome queryability** (AC3): call `rollout_status/1` with the rollout's id from the
  EO-001 setup; assert every outcome row is present, each with a non-nil `completed_at`,
  and the failed one carries a non-nil, non-empty `reason` string; assert calling it with
  a random/nonexistent id returns `{:error, :rollout_not_found}`.
- **EO-004**: from the EO-001 setup, record the succeeded companies' `completed_at`
  values. "Correct" the poisoned company (drop/retype its conflicting column so the real
  DDL will now succeed). Call `resume_rollout/1`. Assert: the poisoned company's outcome
  is now `"succeeded"` with a fresh `completed_at`; every already-succeeded company's
  outcome row — `status`, `completed_at`, `reason` — is byte-identical to its pre-resume
  value (asserted by direct equality on the loaded struct, not just "still succeeded");
  `rollout.completed_at` is now non-nil.
- **EO-005**: from the post-resume state (every company `"succeeded"`), call
  `start_rollout/3` again with the identical `entity_type`/`attribute`/`column_spec`.
  Assert: the returned `rollout_result.outcomes` list has every entry
  `already_current: true`; every outcome row's `completed_at` is unchanged from
  post-resume (same technique as EO-004); assert via `Ecto.Adapters.SQL.query!`
  (or an equivalent count-before/count-after check) that no row in either new table
  changed — the literal "zero writes" claim, not just "results look the same."
- **Permission gate** (`platform_migrations_test.exs`): assert all three endpoints
  return 403 for a non-`PLATFORM_ADMIN` caller (reuse an existing non-admin role fixture
  already used by `Letflow.Routers.Tenants`' own test suite) and succeed for a
  `PLATFORM_ADMIN` caller; assert `Letflow.Routers.PlatformMigrations`' moduledoc states
  `:TenantsManage` by name (a `String.contains?/2` check against the compiled
  moduledoc, or an equivalent doc-content assertion — matching how this project already
  verifies "the permission is stated in the moduledoc" elsewhere, not reinvented here).
- **`mix letflow.check`**: run as the final step before Step Final; real output quoted
  in the ELIXIR-DEV handoff, per this requirement's own acceptance criterion — not this
  design step's job to run, but named here so ELIXIR-DEV does not treat it as optional.

## 9. Open questions (not silently resolved)

- **OQ-1 — scope drift on a repeat `start_rollout/3` call.** §4.1's repeat-call branch
  chooses to register+apply a newly-active/newly-provisioned tenant that had no outcome
  row when the rollout first ran, rather than freezing the rollout's target scope
  forever at its first call. This is the more useful behavior operationally (a company
  onboarded mid-rollout should still receive the change), but it means a "zero writes"
  re-run (EO-005) is only literally zero-write when *no new company became eligible*
  since the rollout completed — which is true in this requirement's own test scenario
  (a fixed company set) but may not hold in general platform operation. Flagging this
  rather than asserting it is definitely the right call generally; REVIEWER should
  confirm this reading of "every active company" (evaluated fresh vs. frozen at
  first call) matches the requirement's intent before ELIXIR-DEV builds it.
- **OQ-2 — a repeat `start_rollout/3` call with a *different* `column_spec` for the same
  `(entity_type, attribute)`.** §3.1 stores the original `column_spec` specifically so
  this can be detected, but this design does not specify what happens if a caller
  supplies a conflicting spec (different `pg_type`, say) on a later call — reject with a
  new `{:error, :column_spec_conflict}`, or silently ignore the new spec and proceed
  against the stored one? Not exercised by any of this requirement's acceptance
  criteria (all of which reuse the identical spec across repeat calls), so left
  explicit rather than guessed. Suggested default if ELIXIR-DEV needs to pick one to
  keep moving: reject with `{:error, :column_spec_conflict}}`, since silently ignoring a
  caller-supplied spec change is the more surprising failure mode.
- **OQ-3 — `apply_outstanding/1`'s sequential-per-tenant execution time.** For a
  platform with a very large active-company count, sequential (§4.4) means a single
  `start_rollout/3`/`resume_rollout/1` HTTP call's latency scales linearly with company
  count. No acceptance criterion in this requirement names a latency bound, and REQ-297's
  own `run_column_promotion_for_all_tenants/1` already made the same sequential choice
  at its own smaller scale — so this design keeps parity with it rather than introducing
  concurrent fan-out (and its own new failure-isolation questions) unprompted. If a
  future requirement needs bounded latency at large company counts, that is its own
  scoped change, not silently pre-built here.
