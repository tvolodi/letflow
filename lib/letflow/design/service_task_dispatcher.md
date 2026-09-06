# Design: REQ-214 — SERVICE_TASK dispatch orchestration core

**Requirement:** REQ-214 (`docs/requirements.yaml`, stage S3, `depends_on: [REQ-056, REQ-204]`,
`impl_order: 415`, GH#812) — closes ISS-0411/GH#807 part 1.
**Owner (implementer):** ELIXIR-DEV
**Run:** WF02-REQ214-20260902, WF-02 Step 1
**This document produces:** module/function signatures, data-structure shapes, the migration's
table/column/index/constraint spec, the `Letflow.Application` supervision-tree diff, and the
poll-claim-decide algorithm (as tables and pseudocode, not code) — **no implementation code**. No
function bodies, no `.ex` files.

---

## 0. Sources read for this design

**Letflow project docs:**
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.3 (one supervised process — not
  applicable here, no per-instance process; this is a singleton poller, same class as
  `Letflow.Scheduler.Poller`), §3.5 (error shapes), §3.6 (SQL), §3.7 (migrations).
- `docs/agents/instructions/security-invariants.md` INV-9 (full text) — the SSRF gate this design
  must satisfy at **every** `:httpc.request/4` call site, for **both** `route_kind` values.
- `docs/requirements.yaml` REQ-214's own entry (full description + acceptance criteria, read
  directly since this is the requirement in scope) and REQ-215's entry (read only to confirm the
  exact boundary line — REQ-215 owns `dispatch_node/4`, `dispatch_service_task/4`,
  `advance_after_service_task_outcome/N`, and the activation-time INSERT into the table this
  design defines; none of that is built here).
- REQ-183/REQ-204's established SSRF/webhook precedent (`docs/requirements.yaml`, read for
  cross-reference only — REQ-204 already shipped `UrlValidator`, reused verbatim, §3.5 below).

**Letflow shipped code, read directly:**
- `lib/letflow/engine/service_task.ex` (full file) — `Letflow.Engine.ServiceTask`'s real,
  shipped `@spec`s for `parse_config_from_node_attributes/1`, `classify_failure_kind/1`,
  `is_retriable_failure/1`, `decide_failure/3`, `compute_service_task_backoff_ms/3`,
  `build_idempotency_key/4`, `build_service_task_give_up_error_attrs/1`,
  `build_empty_url_error_attrs/1`, and the `Config.t()`/`failure_kind()`/`raw_outcome()`/
  `transport_fun()`/`catalog_lookup_fun()`/`service_task_give_up_context()` types — this design's
  binding contract, verified against the actual module, not the design doc's prose.
- `lib/letflow/design/service_task.md` (full file) — §3.4 (transport_fun contract), §3.5
  (catalog_lookup_fun contract), §5.3 (`:request_build_error`'s non-retriable rationale, the
  precedent this design's SSRF-block routing follows), §6 (ERROR-path routing statement naming
  "a future dispatch-orchestration caller" as the intended caller of
  `build_service_task_give_up_error_attrs/1`/`set_instance_error/2` — this module is that caller,
  for the give-up half only; the empty-URL half stays REQ-215's, since URL rendering happens at
  activation time, before any row this design's table holds exists).
- `lib/letflow/webhooks.ex` lines 373-413 — `dispatch_http/3,4`'s exact two-arity/four-arity
  split (`dispatch_http/3` reads the `:webhook_ssrf_validation_enabled` flag, delegates to
  `dispatch_http/4` with the real or bypass path; `dispatch_http/4` is the test-injectable variant
  taking a `dns_resolver`) and `do_dispatch_http/3`'s literal `:httpc.request/4` call shape:
  `{String.to_charlist(url), headers, content_type_charlist, body}`, options
  `[{:timeout, @http_timeout_ms}]`, empty http-options list, classifying the 3-tuple result into
  `{:SUCCESS, status, nil} | {:FAILED, status_or_nil, reason_string}`.
- `lib/letflow/webhooks/url_validator.ex` (full file) — `UrlValidator.validate/2`'s real
  signature: `validate(url :: String.t(), dns_resolver()) :: :ok | {:error, :target_url_not_allowed}`,
  plus the 1-arity convenience clause `validate/1` defaulting to `&default_resolver/1`. Both
  reused verbatim; zero changes to this module.
- `lib/letflow/scheduler.ex` (full file) — the complete architecture mirrored: module-level
  `@default_*` constants read through `Application.get_env(:letflow, :scheduler, [])`-shaped
  accessors; `poll_and_fire/1` (schema-scoped, never raises, folds per-row outcomes into a summary
  map); `claim_due_timer_ids/2` (`FOR UPDATE SKIP LOCKED`, `status == "pending"`, ordered, limited,
  returns bare ids not rows); `fire_timer/2` (one `Repo.transaction/1` per claimed id,
  re-fetches+`FOR UPDATE` locks by id inside the transaction, `try/rescue`-wrapped by the caller
  rather than internally); `attempt_fire/2` (the outer `try/rescue` boundary, SCH-03's
  `{:instance_not_active, _}` matched and folded into `:already_final` **before** the generic
  `{:error, _}` catch-all, exactly the ordering this design's own claim-time skip must mirror);
  `poll_interval_ms/0` etc.'s config-accessor pattern.
- `lib/letflow/scheduler/poller.ex` (full file) — `Letflow.Scheduler.Poller`'s `GenServer` shape:
  `start_link/1` ignores its arg, registers under its own module name; `init/1` sends `:tick` with
  zero delay; `handle_info(:tick, state)` iterates `tenant_schemas/0`'s result defensively
  (`fetch_tenant_schemas/0` wraps DB unreachability), calls the context module's poll function per
  schema, then `schedule_next_tick/0` re-arms via `Process.send_after/3` using
  `poll_interval_ms() + jitter_extra_ms()`. This design's own Poller mirrors the **shape**, not
  every REQ-188/194/199/201 feature bolted onto Scheduler.Poller since (retention, metrics, alerts,
  ordering) — none of those are this requirement's concern.
- `lib/letflow/scheduler/timer.ex` (full file) — `Letflow.Scheduler.Timer`'s plain-`Ecto.Schema`
  shape (`@primary_key {:id, :binary_id, autogenerate: false}`, no `@schema_prefix`, `status` as
  plain `:string` backed by a DB CHECK rather than `Ecto.Enum`, no `timestamps/1`, one changeset
  per distinct write path) — the direct precedent `ServiceTaskDispatch`'s schema (§4 below) copies
  field-shape-for-field-shape where the two tables' contracts overlap.
- `priv/repo/migrations/20260829020001_create_timers.exs` (full file) — the tenant-scoped
  migration idiom: `if prefix() do ... end` guard (MANDATORY per Decision 0003 B), no FK on
  `instance_id`/`token_id` (a row may outlive assumptions about the referenced row), plain
  `:string` not `Ecto.Enum` for the extensible-status column, partial index on the poller's hot
  sort key `WHERE status = 'pending'`, `create constraint/3` for CHECK constraints, no
  `tenant_id`-alone index (the Postgres schema is the isolation boundary), no `timestamps/1`.
- `lib/letflow/application.ex` (full file) — **read carefully per this run's own instruction.**
  `scheduler_children/0`'s exact boot-gating shape: `Application.get_env(:letflow, :start_scheduler, true)`
  gates `[{Letflow.Scheduler.Poller, []}]` vs. `[]`, appended into the top-level `children` list via
  `++ scheduler_children() ++ http_child()`. The inline comment (lines 126-144) states the concrete
  hazard this gate exists for: the Poller's own first tick runs with **zero delay** and queries
  `Letflow.Repo` from a process no test process is an ancestor of — under
  `Ecto.Adapters.SQL.Sandbox`'s default `:manual` mode this raises `DBConnection.OwnershipError` on
  every tick, repeatedly, until the supervisor's restart intensity is exceeded and the **whole
  application** (including `Letflow.Repo`) shuts down — verified live via a full `mix test` run
  before that gate was added. `config/test.exs` sets `start_scheduler: false` to avoid this. This
  design's own `ServiceTaskDispatcher.Poller` entry carries the **identical** hazard (same
  zero-delay-first-tick `GenServer` shape, same `Letflow.Repo` query from an unrelated process) and
  MUST use the identical gating convention — a **new**, distinct config key (§7 below), not reuse
  of `:start_scheduler` (the two pollers are independent concerns per REQ-214's own text — "do not
  overload `Letflow.Scheduler.Poller` with a second responsibility" — so their boot gates are
  independent too, letting a future host disable one without the other).
- `lib/letflow/engine.ex` lines 3518-3595 — `standalone_error_attrs()`'s exact field set (7
  required + 1 optional key: `instance_id`, `error_type`, `affected`, `reason`, `variables`,
  `details` (optional), `actor_id`, `idempotency_key`) and `set_instance_error/2`'s own `@spec` —
  read to confirm `build_service_task_give_up_error_attrs/1`'s return type matches it field-for-
  field (it does, verified against the shipped module directly). **This design's own module does
  NOT call `set_instance_error/2`** (§1, §6 below) — read only to confirm the shape the poller's
  `:give_up` outcome hands back to its (future, REQ-215) caller is exactly this type, so REQ-215
  can call it without any adapting.
- `lib/letflow/engine.ex` lines 1746-1759, 1889-1975 — `fetch_and_lock_instance_projection/3`'s
  `{:error, {:instance_not_active, status}}` shape and `advance_after_timer_fired/3`'s full
  `with`-chain shape — read for the SCH-03-style precedent this design's own claim-time active-
  check (§5.4) must mirror at the **join** level (a SQL join against `instance_projections.status`
  at claim time), not the lock-then-check level `advance_after_timer_fired/3` uses (that function
  belongs to REQ-215's future `advance_after_service_task_outcome/N`, not this module).
- `lib/letflow/event_store/instance_projection.ex` line 137-140 — confirms
  `instance_projections.status` is an `Ecto.Enum` with DB string values
  `"ACTIVE"/"COMPLETED"/"CANCELLED"/"ERROR"` (Elixir atoms `:active/:completed/:cancelled/:error`)
  — the exact column/value this design's claim query joins against (§5.4).
- `lib/letflow/dlq.ex` — read only to confirm the "plain Ecto context module, no process" shape
  `Letflow.Scheduler`'s own moduledoc cites as its sibling precedent; not otherwise used here (this
  design's give-up path does NOT enqueue into `Letflow.Dlq` — §1's NOT IN THIS REQUIREMENT list,
  and REQ-056 design §1's own table, both already establish DLQ landing happens via
  `instance_projections.status = :error`, not a queue-table write, and that this module is not the
  one calling `set_instance_error/2` at all).

PROVENANCE (historical, not current decision authority):
**R-Co source of truth:** not read directly for this design — REQ-214's own requirement text is
explicit that this is new orchestration scope with no direct R-Co analogue module (R-Co's
`service_task.zig` covers the pure logic REQ-056 already ported; the poller/table pairing is a
Letflow-native architectural choice mirroring `Letflow.Scheduler`, per the requirement's own SCOPE
item 4). Nothing in this design depends on an unverified R-Co behavioral claim.

---

## 1. Scope boundary

**In scope (per REQ-214's own SCOPE items 1-6):**

1. A concrete `transport_fun()` implementation using `:httpc.request/4`, mirroring
   `Letflow.Webhooks.dispatch_http/3,4`'s literal request-building shape.
2. The SSRF gate: `UrlValidator.validate/2` called immediately before **every**
   `:httpc.request/4` call, for **both** `route_kind` values (`:inline_url` and
   `:catalog_service` — once `:catalog_service` ever resolves a real URL; today it never reaches
   the gate at all, since the stub in item 3 always fails first).
3. A `catalog_lookup_fun()` stub returning `{:error, :not_registered}` unconditionally.
4. The `service_task_dispatches` table (migration + schema module) and the
   `Letflow.Engine.ServiceTaskDispatcher` context module (poll-claim-decide, one `Repo.transaction/1`
   per claimed row).
5. `Letflow.Engine.ServiceTaskDispatcher.Poller`, a supervised `GenServer` ticker, added to
   `Letflow.Application`'s supervision tree as its own entry, boot-gated the same way
   `Letflow.Scheduler.Poller` is.
6. The retry/backoff/give-up decision flow, calling REQ-056's already-shipped pure functions —
   `classify_failure_kind/1`, `decide_failure/3`, `compute_service_task_backoff_ms/3`,
   `build_idempotency_key/4`, `build_service_task_give_up_error_attrs/1` — never re-implementing
   any of them.

**Explicitly NOT in this requirement (REQ-214's own "NOT IN THIS REQUIREMENT, AND WHY" list,
restated here as binding scope boundary, not optional color):**

| Not built here | Belongs to |
|---|---|
| `dispatch_node/4`'s `:SERVICE_TASK` clause and `Transition.dispatch_service_task/4` (the async-park write when a token arrives at a SERVICE_TASK node) | **REQ-215** |
| The activation-time caller that parses config, renders the URL template, validates it via `validate_rendered_url/1`, and INSERTs the first `service_task_dispatches` row | **REQ-215** — this design's table exists and is ready to receive that INSERT, but no code in this requirement writes to it except the poller's own claim/update/give-up path (§5) |
| `Letflow.Engine.advance_after_service_task_outcome/N` (the re-entry function this module's poller calls **into**, on an `:advance` or `:give_up` outcome) | **REQ-215** — this module returns a typed outcome (§5.6) and stops; it never calls `Letflow.Engine.*` itself |
| `Letflow.Engine.set_instance_error/2` — this module never calls it directly (§6) | **REQ-215**, per REQ-056 design §6's own routing statement: a future dispatch-orchestration caller "is required to invoke" `set_instance_error/2`, not this module |
| The real `service_catalog` (S6) | future S6 requirement |
| HTTP request cancellation/abort on instance cancellation mid-flight | deferred indefinitely (REQ-187's own precedent for the identical TIMER-side gap); a dispatch row belonging to a since-cancelled instance is **skipped at claim time** (§5.4), never aborted mid-flight |
| Any change to `lib/letflow/engine/service_task.ex` itself | out of scope — REQ-056's pure functions are called as-is, verified against the real shipped module (§0) |

**This requirement does NOT touch `Letflow.Engine.Transition` or `Letflow.Engine` (`transition.ex`,
`engine.ex`) at all.** Every function this design adds lives in two new files:
`lib/letflow/engine/service_task_dispatcher.ex` and
`lib/letflow/engine/service_task_dispatcher/poller.ex`, plus the migration and its schema module.
`dispatch_node/4` at `lib/letflow/engine/transition.ex:334-339` still returns
`{:error, {:node_type_not_yet_implemented, :SERVICE_TASK, node_id}}` after this requirement ships —
closing that stub is REQ-215's entire job.

---

## 2. Module and file layout

| Module | File | Kind |
|---|---|---|
| `Letflow.Engine.ServiceTaskDispatcher` | `lib/letflow/engine/service_task_dispatcher.ex` | **New.** Context module — poll-claim-decide, transport, catalog stub, config accessors. No process. |
| `Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch` | same file, nested | **New.** Plain `Ecto.Schema` — the `service_task_dispatches` row. |
| `Letflow.Engine.ServiceTaskDispatcher.Poller` | `lib/letflow/engine/service_task_dispatcher/poller.ex` | **New.** Supervised `GenServer` ticker. |

Follows `Letflow.Scheduler`/`Letflow.Scheduler.Poller`/`Letflow.Scheduler.Timer`'s own three-piece
split exactly (context module + nested schema in one file, `Poller` in its own file under a
matching subdirectory) — one deliberate naming difference: `Timer`'s schema is a top-level sibling
module (`Letflow.Scheduler.Timer`, its own file) while this design nests
`ServiceTaskDispatch` inside `ServiceTaskDispatcher`'s own file, matching
`Letflow.Engine.ServiceTask.Config`'s nested-plain-struct convention (§0) instead — chosen because
`ServiceTaskDispatch` is a small, single-purpose row schema with no independent changeset surface
complex enough to justify its own file the way `Timer`'s five changesets do; flagged as a
deliberate, non-blocking deviation from the timers precedent, not an oversight (open question,
§10 OQ-1 — REVIEWER may direct a split file instead).

---

## 3. `service_task_dispatches` table

Tenant-scoped (Postgres schema-per-tenant, same isolation boundary as `timers`/`dlq_entries`/
`tasks` — Decision 0003 B). Migration file:
`priv/repo/migrations/<timestamp>_create_service_task_dispatches.exs`, module
`Letflow.Repo.Migrations.CreateServiceTaskDispatches`, guarded by `if prefix() do ... end`
(MANDATORY), and its name **added to**
`Letflow.TenantProvisioning.@tenant_scoped_migration_manifest` (`lib/letflow/tenant_provisioning.ex`,
verified: a literal list of `{integer_timestamp, ModuleName, "filename.exs"}` tuples in ascending
timestamp order — e.g. line 462-463's `{20_260_829_020_001, Letflow.Repo.Migrations.CreateTimers,
"20260829020001_create_timers.exs"}` — add one new tuple in the same shape, ordered by this
migration's own timestamp prefix) — both halves mandatory, per the `timers` migration's own header
comment (§0): a guarded-but-unregistered migration is inert forever.

### 3.1 Columns

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | — | primary key, caller-supplied (`Ecto.UUID.generate/0`), mirrors `timers.id`'s `autogenerate: false` |
| `tenant_id` | `:binary_id` | not null | — | intra-schema column, not itself the isolation boundary (mirrors `timers.tenant_id`) |
| `instance_id` | `:binary_id` | not null | — | no FK, mirrors `timers.instance_id` (a row may outlive assumptions about the referenced row) |
| `token_id` | `:binary_id` | not null | — | **not nullable**, unlike `timers.token_id` — every SERVICE_TASK dispatch is always token-scoped (REQ-214's own SCOPE item 4 names it as a required field; `timers.token_id` is nullable only because some timer types are instance-scoped, not token-scoped — no such case exists for SERVICE_TASK) |
| `node_id` | `:string` | not null | — | the SERVICE_TASK graph node id, mirrors `timers.node_id` |
| `config_snapshot` | `:map` (jsonb) | not null | — | the rendered dispatch config as of activation time: `route_kind`, `url_template` OR `service_id`, `method`, `body_template`, `headers`, `timeout_ms`, `retry_limit`, PLUS the already-rendered `rendered_url` (REQ-215's activation-time caller renders the URL template once, before the first INSERT — this poller re-renders nothing, ever, on any attempt including retries; it dispatches against the frozen snapshot on every attempt, re-validating but never re-rendering, mirroring `Letflow.Webhooks`' own established retry convention; see §5.2, §5.6 step 2, §10 OQ-3 — RESOLVED) |
| `attempt_index` | `:integer` | not null | `0` | REQ-056's `attempt_index()` — 0 = first attempt, never retried yet |
| `next_attempt_at` | `:utc_datetime_usec` | not null | — | the poller's hot sort/claim key, mirrors `timers.fire_at` exactly (microsecond precision for the identical same-wall-clock-second race-avoidance reason, §0) |
| `status` | `:string` | not null | `"pending"` | plain `:string`, DB CHECK-backed (mirrors `timers.status` — an `Ecto.Enum` would duplicate the DB guard for no additional benefit, §0) |
| `last_failure_kind` | `:string` | nullable | — | the most recent `ServiceTask.failure_kind()` atom (stored as its `to_string/1`), `nil` until the first failed attempt; carried into `build_service_task_give_up_error_attrs/1`'s context on give-up |
| `dispatched_at` | `:utc_datetime_usec` | nullable | — | set on the row's terminal claim attempt (the attempt that produced `:advance` or `:give_up`), mirrors `timers.fired_at`'s "specific, narrow timestamp column" convention (§0) |
| `created_at` | `:utc_datetime_usec` | not null | — | mirrors `timers.created_at`; no `timestamps/1` (§0's "specific, narrow timestamp columns" rationale, restated) |

**No `updated_at`/`inserted_at` from `timestamps/1`** — same rationale as `timers`/`dlq_entries`:
this table's contract names specific, narrow timestamp columns, not a generic last-modified column
no acceptance criterion requires.

**`status` domain (DB CHECK `chk_service_task_dispatches_status`):** `"pending"` (claimable),
`"advanced"` (terminal success — the outcome was handed to the, not-yet-built, REQ-215 caller as
`:advance`), `"given_up"` (terminal failure — handed to the REQ-215 caller as `:give_up`). Three
values, not `timers`' four — no `"cancelled"` value exists in this table's own domain (REQ-214's
own text, §1: a row belonging to a cancelled/completed instance is **skipped at claim time**, its
`status` stays `"pending"` forever rather than being flipped to a `"cancelled"` terminal value; no
acceptance criterion asks for one, and inventing one would be scope this requirement does not own
— REQ-215's own future cancellation wiring, if any, is the natural place to add it, mirroring
REQ-214's own text calling out that HTTP-abort/cancellation propagation is deferred).

### 3.2 Indexes

- `idx_service_task_dispatches_pending_next_attempt_at` — partial index on `(next_attempt_at)`
  `WHERE status = 'pending'`, mirroring `idx_timers_pending_fire_at` exactly — the poller's one hot
  query (`claim_due_dispatch_ids/2`, §5.4).
- No index on `tenant_id` alone (the Postgres schema is the isolation boundary, §0).
- No index on `instance_id` — no query in this design's own scope filters by it directly (the
  claim query joins `instance_projections` by `instance_id`, but that join uses
  `instance_projections`' own primary key on the right side; a left-side index on this table's
  `instance_id` would only help a query this requirement does not issue — not added speculatively).

### 3.3 Constraints

- `chk_service_task_dispatches_status` — `status IN ('pending', 'advanced', 'given_up')`.
- `chk_service_task_dispatches_attempt_index` — `attempt_index >= 0` (defensive; mirrors no
  existing `timers` constraint directly, but `attempt_index()`'s own type is `non_neg_integer()`
  per REQ-056 — the DB should not silently accept what the type forbids).

---

## 4. `ServiceTaskDispatch` schema

```
Module: Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch (nested in service_task_dispatcher.ex)
Kind: plain Ecto.Schema, @primary_key {:id, :binary_id, autogenerate: false}
No @schema_prefix -- every read/write passes prefix: schema_name explicitly (mirrors Timer, §0).
```

### 4.1 Field list (mirrors §3.1's column table 1:1)

```
@type t :: %__MODULE__{
  id: Ecto.UUID.t(),
  tenant_id: Ecto.UUID.t(),
  instance_id: Ecto.UUID.t(),
  token_id: Ecto.UUID.t(),
  node_id: String.t(),
  config_snapshot: config_snapshot(),
  attempt_index: non_neg_integer(),
  next_attempt_at: DateTime.t(),
  status: String.t(),
  last_failure_kind: String.t() | nil,
  dispatched_at: DateTime.t() | nil,
  created_at: DateTime.t()
}

@type config_snapshot :: %{
  required("route_kind") => String.t(),        # "inline_url" | "catalog_service"
  optional("url_template") => String.t() | nil,
  optional("service_id") => String.t() | nil,
  required("rendered_url") => String.t(),       # already-rendered by REQ-215's activation-time caller
  required("method") => String.t(),             # "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
  optional("body_template") => String.t() | nil,
  optional("headers") => %{optional(String.t()) => String.t()},
  required("timeout_ms") => pos_integer(),
  required("retry_limit") => non_neg_integer()
}
```

`config_snapshot` is stored as a `:map` (jsonb) column — string keys throughout, matching
`Graph.Node.attributes`'s own string-keyed convention (§0's `ServiceTask` read) rather than atom
keys, since it round-trips through jsonb. **This design's own poll/claim/decide functions (§5)
never write this column** — only the REQ-215 activation-time caller (not built here) does, at
INSERT time. This module only **reads** it back per claimed row (§5.5).

### 4.2 Changesets

Mirrors `Letflow.Scheduler.Timer`'s one-changeset-per-write-path discipline (§0):

```
@spec arm_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Structural changeset for the (REQ-215-owned) INSERT path. **Defined here** (this module owns the
schema) but **called only by REQ-215's future activation-time caller**, exactly the same
division-of-labor `Timer.rearm_changeset/2`'s own moduledoc note describes ("reserved for REQ-188,
not called by any REQ-186 function; the atom is defined here so REQ-188's own design does not have
to guess a name") — reused verbatim here for the symmetric REQ-214/REQ-215 split. Casts
`[:id, :tenant_id, :instance_id, :token_id, :node_id, :config_snapshot, :next_attempt_at, :created_at]`;
`attempt_index` and `status` are not castable through this changeset — always forced to `0` and
`"pending"` respectively by the caller, matching `Timer.arm_changeset/2`'s "status is not castable"
discipline.

```
@spec retry_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Structural changeset for the `:retry` decision's same-transaction update (§5.6). Casts
`[:attempt_index, :next_attempt_at, :last_failure_kind]`. `status` stays `"pending"` — not cast,
never changes on a retry.

```
@spec terminal_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Structural changeset for the `:advance`/`:give_up` terminal update (§5.6). Casts
`[:status, :last_failure_kind, :dispatched_at]`. `status` must be cast to exactly `"advanced"` or
`"given_up"` by the caller (validated via `validate_inclusion/3` against `["advanced", "given_up"]`
inside this changeset, mirroring `Timer.arm_changeset/2`'s `validate_inclusion/3` use for
`timer_type`).

---

## 5. `Letflow.Engine.ServiceTaskDispatcher` — function signatures

### 5.1 Config accessors (design mirrors `Letflow.Scheduler`'s §7 exactly, §0)

```
@spec poll_interval_ms() :: pos_integer()          # default 5_000, reads config :letflow, :service_task_dispatcher, [:poll_interval_ms]
@spec jitter_ms() :: non_neg_integer()              # default 0
@spec max_dispatches_per_cycle() :: pos_integer()   # default 64
@spec default_backoff_base_ms() :: pos_integer()    # default 1_000 -- passed to compute_service_task_backoff_ms/3's base_ms
@spec default_backoff_cap_ms() :: pos_integer()     # default 60_000 -- passed to compute_service_task_backoff_ms/3's cap_ms
```

All read through `Application.get_env(:letflow, :service_task_dispatcher, [])` — a **new**,
distinct config key from `:scheduler` (mirrors REQ-214's own "independent poll cadences" text,
§1). `default_backoff_base_ms/0`/`default_backoff_cap_ms/0` are new relative to `Letflow.Scheduler`
— `ServiceTask.compute_service_task_backoff_ms/3` takes `base_ms`/`cap_ms` as caller-supplied
arguments (it has no defaults of its own, per its real `@spec`, §0), so this module's config
surface must supply them; `Letflow.Scheduler`'s own timers have no analogous per-fire backoff
(a fired timer either fires or lands in `dlq_entries` after `max_fire_retries`, no exponential
delay between attempts), so there is no existing accessor to mirror for these two — new additions,
not omissions.

### 5.2 `transport_fun()` implementation

```
@spec http_transport(Config.t(), rendered_url :: String.t(), rendered_body :: String.t() | nil) ::
  ServiceTask.raw_outcome()
```

The concrete `Letflow.Engine.ServiceTask.transport_fun()` value (§0's type, verbatim) this module
supplies. Called with `rendered_url = row.config_snapshot["rendered_url"]` — the value frozen once
at this row's INSERT time by REQ-215's activation-time caller (§4.1, §10 OQ-3 — RESOLVED) — on
**every** attempt this row ever makes, first attempt and every retry alike; this function itself
never renders anything, it only ever receives an already-rendered string. **SSRF gate placement
(BLOCKER, INV-9) — stated explicitly per this run's own instruction, and — per §10 OQ-3's
resolution — run fresh on every attempt against that same frozen value, mirroring
`Letflow.Webhooks.dispatch_http/3,4`'s own re-validate-every-attempt behavior
(`lib/letflow/webhooks.ex:373-392`, verified directly):**

```
def http_transport(config, rendered_url, rendered_body) do
  case UrlValidator.validate(rendered_url) do
    {:error, :target_url_not_allowed} ->
      {:request_build_error, :target_url_not_allowed}

    :ok ->
      do_http_transport(config, rendered_url, rendered_body)   # the real :httpc.request/4 call
  end
end
```

`UrlValidator.validate/2` (1-arity convenience clause defaulting to `&default_resolver/1`, or the
2-arity form with an injected resolver for tests — both reused verbatim, §0) is called
**immediately before** the `do_http_transport/3` step that issues `:httpc.request/4` — no
intervening code path reaches `:httpc.request/4` without passing this check first. A blocked URL
maps to `{:request_build_error, :target_url_not_allowed}` — REQ-056's own `raw_outcome()` union
(§0) has no dedicated "blocked" member, so this reuses the existing `{:request_build_error, reason}`
shape (REQ-056 design §5.3's own precedent: "Deterministic given the same config/variables —
retrying without a config change cannot succeed," exactly true of an SSRF-blocked URL). This is
**the single call site** this requirement's `:httpc.request/4` usage has — there is no second
transport path for `:catalog_service` (§5.3's stub never reaches the transport at all, so the gate
only has one real caller today, but the gate's placement inside `http_transport/3` itself — not
duplicated per-`route_kind` — means it is structurally unbypassable by construction if
`:catalog_service` dispatch is ever wired to a real transport later, closing REQ-214's own "both
route_kind values" acceptance criterion for both the case that exists today and the case that will
exist once S6 ships).

```
@spec do_http_transport(Config.t(), rendered_url :: String.t(), rendered_body :: String.t() | nil) ::
  ServiceTask.raw_outcome()
```

Private. Mirrors `Letflow.Webhooks.do_dispatch_http/3`'s literal shape (§0) adapted to
`raw_outcome()`'s 3 relevant members instead of Webhooks' own `{:SUCCESS,_,_}/{:FAILED,_,_}` pair:

```
request = {String.to_charlist(rendered_url), headers_from(config), content_type_charlist(config), body_or_empty(rendered_body)}
:httpc.request(method_atom(config.method), request, [{:timeout, config.timeout_ms}], [])
|> case do
  {:ok, {{_http_version, status, _reason_phrase}, _resp_headers, resp_body}} ->
    {:http, status, resp_body |> to_string_or_nil()}

  {:error, :timeout} ->
    :timeout

  {:error, reason} ->
    {:network, reason}
end
```

`method_atom/1` maps `Config.t()`'s `:GET|:POST|:PUT|:PATCH|:DELETE` atom to the lowercase atom
`:httpc.request/4`'s method-arity form expects (`:get|:post|:put|:patch|:delete`) — `:httpc`'s
2-arity `request/2` is GET-only; this design always uses the 4-arity `request/4` form (matching
`Webhooks.do_dispatch_http/3`'s own choice, §0) so every method is expressible uniformly. `headers_from/1`
converts `config.headers` (a string-keyed map) to `:httpc`'s `[{charlist(), charlist()}]` shape,
always injecting `content-type` from `config.body_template`'s presence (mirrors Webhooks' own
`content-type: application/json` header, §0 — REQ-214's own text does not specify a different
content-type convention, so this reuses Webhooks' established one; flagged as an assumption, §10
OQ-2). `:timeout` from `:httpc`'s own literal `{:error, :timeout}` reason maps to `raw_outcome()`'s
bare `:timeout` atom (distinct from the generic `{:network, reason}` catch-all) — this is the one
place this design's classification differs structurally from Webhooks' own two-outcome
`{:SUCCESS,_,_}|{:FAILED,_,_}` shape, because `raw_outcome()`'s richer union (§0) is what
`ServiceTask.classify_failure_kind/1` requires as its input, and Webhooks predates REQ-056's
7-member `failure_kind()` taxonomy.

### 5.3 `catalog_lookup_fun()` stub

```
@spec catalog_lookup_stub(service_id :: String.t(), tenant_id :: Ecto.UUID.t()) ::
  {:error, :not_registered}
```

Unconditional `{:error, :not_registered}` for every input, matching REQ-056's `catalog_lookup_fun()`
type exactly (§0). This module's own poll/claim/decide flow (§5.5) never actually calls this
function against a live `service_id`, because `route_kind: :catalog_service` config snapshots
never carry a real, dispatchable URL today — REQ-215's activation-time caller is the one that
would need to resolve `service_id` before ever inserting a row (REQ-215's own future scope, not
this module's). This stub exists so the **type/contract** is concretely satisfied (REQ-056's
`catalog_lookup_fun()` has "no concrete implementation... in this codebase yet" per its own
moduledoc, §0) — a real caller wiring `route_kind: :catalog_service` through this module's poll
loop, whenever REQ-215 or a later requirement does so, gets a `:not_registered`-shaped outcome
immediately, never a crash from a missing function. Documented explicitly in this module's
moduledoc, matching REQ-214's own acceptance criterion wording ("the moduledoc states explicitly
that this is because S6's `service_catalog` does not exist yet, naming it as a future
requirement's job").

### 5.4 `claim_due_dispatch_ids/2` — the hot claim query

```
@spec claim_due_dispatch_ids(tenant_schema :: String.t(), limit :: pos_integer()) :: [Ecto.UUID.t()]
```

**Reworked per CODE-DESIGN-VALIDATOR's BLOCKER finding.** The original draft of this section
specified `lock("FOR UPDATE OF d0 SKIP LOCKED")` — a binding-qualified lock clause hardcoding `d0`
(Ecto's auto-generated join-binding alias) as a literal string. Grepped the entire codebase
(`lib/letflow/repository.ex:271`, `engine.ex:1737,1752,3345,3358,3404`, `definitions.ex:2229,2255,2516`,
`webhooks.ex:711`, `tasks.ex`, and `scheduler.ex:232` itself) and confirmed: **no `FOR UPDATE OF`
qualified lock exists anywhere in this codebase.** Every single existing `lock(...)` call in this
project is a bare `lock("FOR UPDATE")` or `lock("FOR UPDATE SKIP LOCKED")` on a query with **no
join** — including `Letflow.Scheduler.claim_due_timer_ids/2` itself
(`lib/letflow/scheduler.ex:219-235`, read directly), which this design cited as its mirror: that
function's query is `Timer |> where(...) |> order_by(...) |> limit(...) |> select([t], t.id) |>
lock("FOR UPDATE SKIP LOCKED")` — a single-table query with no join at all, so it never had a
double-lock hazard to solve in the first place. The `FOR UPDATE OF d0` syntax was invented, not
verified, and is corrected here.

**Chosen fix: two-step select-then-lock, no join present in the locking query at all** — the
safest option among the two the rework instruction offered, since it needs no
binding-qualification syntax of any kind, qualified or not, and every piece of it is a verified,
already-shipped Ecto idiom from this same codebase (`WHERE id IN (^ids)` + bare
`lock("FOR UPDATE SKIP LOCKED")` is exactly `Letflow.Scheduler.fetch_and_lock_timer/2`'s own
re-fetch-by-id-and-lock shape, used one step downstream of `claim_due_timer_ids/2` in the same
module, §0). No real, verified codebase or official-Ecto-doc precedent for join-then-selectively-lock
was found to cite instead, so option (a) is used, not a restated variant of option "cite a real
precedent for qualified locking":

```
# Step 1 -- SELECT eligible ids. Joins instance_projections for the status == :active filter.
# Locks NOTHING. No lock/1 call anywhere in this query.
eligible_ids =
  ServiceTaskDispatch
  |> join(:inner, [d], p in InstanceProjection, on: p.instance_id == d.instance_id)
  |> where([d, p], d.status == "pending" and d.next_attempt_at <= ^now and p.status == :active)
  |> order_by([d], asc: d.next_attempt_at)
  |> limit(^limit)
  |> select([d], d.id)
  |> Repo.all(prefix: tenant_schema)

# Step 2 -- lock ONLY service_task_dispatches rows, by id, in a second, single-table query.
# No join present here, so a bare, unqualified lock is unambiguous -- identical idiom to
# Letflow.Scheduler.claim_due_timer_ids/2's own lock("FOR UPDATE SKIP LOCKED") (scheduler.ex:232).
ServiceTaskDispatch
|> where([d], d.id in ^eligible_ids)
|> select([d], d.id)
|> lock("FOR UPDATE SKIP LOCKED")
|> Repo.all(prefix: tenant_schema)
```

Both queries run under the caller's own connection (not wrapped in a `Repo.transaction/1` here —
mirrors `claim_due_timer_ids/2`'s own shape exactly: the claim step itself is not transactional:
Step 2's `SKIP LOCKED` is what makes a concurrent claimant safe, not a surrounding transaction; the
row-level lock each returned id carries is released back on `Repo.all/2`'s own implicit commit, and
`attempt_dispatch/2`'s later `Repo.transaction/1` (§5.6) re-locks by id again inside its own
transaction the same way `Scheduler.fire_timer/2` does, §0). Step 1's join never appears inside a
locked query, so Postgres's per-joined-table `FOR UPDATE` semantics (which lock **every** joined
table's matching rows unless explicitly restricted) never come into play at all — there is no
ambiguity to resolve, because there is no lock on a multi-table query anywhere in this design.

A row whose instance is no longer `:active` (`:completed`, `:cancelled`, or `:error`) is **excluded
from `eligible_ids` at Step 1 entirely** — it is never selected, never reaches Step 2's lock, and
its own `status` column is left untouched (`"pending"` forever, per §3.1's note) — this is the
concrete mechanism behind the acceptance criterion "a dispatch row belonging to an instance that is
no longer ACTIVE... is skipped at claim time and never produces an `:httpc.request/4` call." A row
that races between Step 1 and Step 2 (claimed by a concurrent poll tick between the two queries) is
simply absent from Step 2's `SKIP LOCKED` result — indistinguishable from any other concurrent-claim
race this design already accepts, no new race introduced by the two-step split.

### 5.5 `poll_and_dispatch/1` — the tick entry point

```
@type dispatch_poll_result :: %{
  tenant_schema: String.t(),
  claimed: non_neg_integer(),
  advanced: non_neg_integer(),
  retried: non_neg_integer(),
  given_up: non_neg_integer()
}

@spec poll_and_dispatch(tenant_schema :: String.t()) :: dispatch_poll_result()
```

Called once per tenant schema per tick by `ServiceTaskDispatcher.Poller`, never by application
code directly — mirrors `Letflow.Scheduler.poll_and_fire/1`'s own contract (§0) exactly: **never
raises**, every per-row failure is caught internally and folded into the returned counts (mirrors
`Scheduler.attempt_fire/2`'s outer `try/rescue`, §0). Iterates `claim_due_dispatch_ids/2`'s result,
calling `attempt_dispatch/2` (§5.6) per id, folding `:advance | :retry | :give_up` outcomes into
the summary map.

### 5.6 `attempt_dispatch/2` — one row, one transaction

```
@type dispatch_outcome ::
  {:advance, decoded_body :: map()}
  | {:give_up, Letflow.Engine.standalone_error_attrs()}
  | :retry_scheduled

@spec attempt_dispatch(dispatch_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
  {:ok, dispatch_outcome()} | {:ok, :already_final} | {:error, term()}
```

Mirrors `Letflow.Scheduler.fire_timer/2`'s one-`Repo.transaction/1`-per-claimed-row shape (§0)
exactly:

```
Repo.transaction(fn ->
  case fetch_and_lock_dispatch(dispatch_id, tenant_schema) do
    nil -> {:ok, :already_final}
    %ServiceTaskDispatch{status: status} when status != "pending" -> {:ok, :already_final}
    %ServiceTaskDispatch{} = row -> do_attempt_dispatch(row, tenant_schema)
  end
  |> case do
    {:ok, result} -> result
    {:error, reason} -> Repo.rollback(reason)
  end
end)
```

`do_attempt_dispatch/2` (private) is the decision flow REQ-214's own SCOPE items 5-6 name,
step by step:

1. Rebuild a `Config.t()` (§0's shipped struct) from `row.config_snapshot` (a plain map-to-struct
   projection — this module does **not** call `parse_config_from_node_attributes/1` again, since
   the snapshot was already parsed once by REQ-215's activation-time caller; re-parsing here would
   silently duplicate that work against a JSON round-trip of the same data, not the original
   `Graph.Node.t()`).
2. Call `http_transport(config, row.config_snapshot["rendered_url"], rendered_body)` (§5.2) — the
   **one** `:httpc.request/4`-reaching call site in this module, always preceded by the SSRF gate
   inside `http_transport/3` itself (§5.2's own placement statement). `row.config_snapshot["rendered_url"]`
   is the **same frozen string on every attempt of this row**, first attempt and every `:retry`-driven
   re-claim alike (§10 OQ-3 — RESOLVED) — this step never renders a URL, it only ever reads the one
   value REQ-215's activation-time caller wrote once at INSERT; what changes attempt-to-attempt is
   only that `http_transport/3`'s own `UrlValidator.validate/2` call re-runs against that same frozen
   value each time, exactly matching `Letflow.Webhooks.attempt_loop/7`'s own retry shape
   (`lib/letflow/webhooks.ex:266-313`: `subscription.target_url` passed unchanged through every
   recursive retry call; `dispatch_http/3,4` re-validates it fresh on each one).
3. `outcome = ServiceTask.classify_failure_kind(raw_outcome)` — REQ-056's own function, unmodified.
4. **Success case** (`{:success, decoded_body}`): update the row via `terminal_changeset/2`
   (`status: "advanced"`, `dispatched_at: now`), in the **same transaction**, then return
   `{:ok, {:advance, decoded_body}}`. This module does **not** call `VariableMerge.merge/3` itself
   (§1 — that call, and the actual token-advancement, is REQ-215's job as the caller of this
   outcome).
5. **Failure case** (one of REQ-056's 7 `failure_kind()` atoms): call
   `ServiceTask.decide_failure(kind, row.attempt_index, row.config_snapshot["retry_limit"])`.
   - `:retry` → compute
     `next_delay_ms = ServiceTask.compute_service_task_backoff_ms(row.attempt_index, default_backoff_base_ms(), default_backoff_cap_ms())`,
     update the row via `retry_changeset/2`
     (`attempt_index: row.attempt_index + 1`, `next_attempt_at: DateTime.add(now, next_delay_ms, :millisecond)`,
     `last_failure_kind: to_string(kind)`) — **in the same transaction as the claim** (the
     acceptance criterion's own wording, verified by reading the row back afterward, not by
     trusting the return value) — then return `{:ok, :retry_scheduled}`. **No sleep** — the row's
     new `next_attempt_at` is the wait mechanism; the poller's own poll interval is what re-checks
     it on a later tick, exactly matching `Letflow.Scheduler` never sleeping inside `fire_timer/2`
     (§0).
   - `:give_up` → build the `service_task_give_up_context()` (REQ-056's own type, §0) from the
     row's own fields (`instance_id`, `node_id`, `last_failure_kind: kind`,
     `attempt_index: row.attempt_index`, `retry_limit: row.config_snapshot["retry_limit"]`) plus
     `actor_id`/`idempotency_key`/`variables` (§9 OQ-4 — this design's own open question on where
     `variables`/`actor_id` come from, since this module holds no `InstanceState`, only the frozen
     `config_snapshot`), call `ServiceTask.build_service_task_give_up_error_attrs/1` (unmodified),
     update the row via `terminal_changeset/2` (`status: "given_up"`, `dispatched_at: now`,
     `last_failure_kind: to_string(kind)`) in the same transaction, then return
     `{:ok, {:give_up, standalone_error_attrs}}`. **This module never calls
     `Letflow.Engine.set_instance_error/2`** — confirmed by construction: no call to that function,
     or to `ExecutionError.append_multi/3`, appears anywhere in `service_task_dispatcher.ex` or
     `service_task_dispatcher/poller.ex` (the acceptance criterion's own "confirmed by grep" check).

`build_idempotency_key/4` (REQ-056, unmodified) is called at step 5's `:give_up` branch (and would
be called again by a real dispatch attempt needing one for the outbound request itself — REQ-214's
own text does not require this design to attach an idempotency key to the outbound HTTP request
body; `EventStore.append/2`'s own idempotency key is a REQ-215-owned concern, since only REQ-215's
future caller appends an event) using `(row.instance_id, row.node_id, row.token_id, row.attempt_index)`.

### 5.7 Instance-terminal race during dispatch (mirrors Scheduler's SCH-03, §0)

`claim_due_dispatch_ids/2`'s join (§5.4) excludes a row whose instance is already non-`:active` at
**claim** time. A row whose instance becomes non-`:active` **between** claim and this same
transaction's own commit (a concurrent `cancel_instance/3`/completion racing the claimed row's own
transaction) is handled the same way `Letflow.Scheduler.attempt_fire/2` handles the timer-side
version of this race (§0): **not attempted here** — REQ-214's own acceptance criteria name only the
claim-time skip, not a second, in-transaction re-check. Flagged as a deliberate scope match to the
requirement's own stated test (§9 OQ-5): unlike `advance_after_timer_fired/3`, which re-locks and
re-checks `instance_projections.status` because it performs the actual token-advancement write,
this module's own transaction only ever writes to `service_task_dispatches` — it never writes to
`instance_projections`/`tokens`/`tasks` itself (that write happens in REQ-215's
`advance_after_service_task_outcome/N`, which — mirroring `advance_after_timer_fired/3` — is the
correct, and only necessary, place for that race to be caught, since it is the function that
actually advances state).

---

## 6. ERROR-path routing — restates REQ-056 design §6, does not re-decide it

This module's `:give_up` outcome (§5.6 step 5) produces exactly one
`Letflow.Engine.standalone_error_attrs()` value via `ServiceTask.build_service_task_give_up_error_attrs/1`
and returns it to its caller. **It never calls `Letflow.Engine.set_instance_error/2` itself** — no
`Ecto.Multi` targeting `instance_projections` is opened anywhere in this module, and no call to
`ExecutionError.append_multi/3` appears anywhere in it. This is the identical discipline REQ-056's
own design doc §6 states for `ServiceTask` itself (§0): "a future dispatch-orchestration caller...
is required to invoke" `set_instance_error/2` — this module **is** that dispatch-orchestration
caller, and it stops exactly where REQ-056 design §6 said the pure module's own callers would need
to continue. REQ-215's `advance_after_service_task_outcome/N` is that continuation — it receives
this module's `{:give_up, standalone_error_attrs}` tuple (or `{:advance, decoded_body}`) as its own
input and is the one that actually calls `set_instance_error/2` (give-up path) or
`VariableMerge.merge/3` plus token advancement (advance path).

**SSRF-block routing (REQ-214's own text, §1):** a blocked URL is classified by
`http_transport/3`'s `{:request_build_error, :target_url_not_allowed}` return value (§5.2),
`ServiceTask.classify_failure_kind/1` maps it to `:request_build_error` (§0's already-shipped
7-member union), `is_retriable_failure(:request_build_error)` is already `false` (§0's shipped
function, unmodified), so `decide_failure/3` gives up on attempt 0 regardless of `retry_limit` —
the identical mechanism REQ-056 design §5.3 already established for `:request_build_error`'s own
rationale ("Deterministic given the same config/variables — retrying without a config change
cannot succeed"), reused here verbatim rather than re-derived, exactly as REQ-214's own text
instructs ("exactly like `:request_build_error`'s own existing rationale in service_task.md §5.3").
No new failure-kind branch, no new retriability rule, no change to `ServiceTask` itself.

---

## 7. `Letflow.Engine.ServiceTaskDispatcher.Poller` — GenServer shape

Mirrors `Letflow.Scheduler.Poller`'s shape (§0) at the scope this requirement needs — no REQ-188/
194/199/201-style feature accretion (retention, metrics, alerts, ordering all belong to
`Letflow.Scheduler.Poller` specifically and are not duplicated here):

```
@type state :: %{last_tick_started_at: DateTime.t() | nil}

@spec start_link(keyword()) :: GenServer.on_start()
def start_link(_opts) do
  GenServer.start_link(__MODULE__, %{last_tick_started_at: nil}, name: __MODULE__)
end

@impl true
def init(state) do
  Process.send_after(self(), :tick, 0)
  {:ok, state}
end

@impl true
def handle_info(:tick, state) do
  # fetch tenant schemas defensively (mirrors Scheduler.Poller's fetch_tenant_schemas/0, §0) --
  # a DB-unreachable error must not crash this GenServer.
  # on success: Enum.each(schemas, &ServiceTaskDispatcher.poll_and_dispatch/1)
  # schedule_next_tick/0 always runs, success or failure
  {:noreply, new_state}
end
```

`tenant_schemas/0` is **not duplicated** as a second implementation — this design's Poller reads
tenant schemas the identical way `Letflow.Scheduler.Poller` already does (§0's
`Letflow.TenantProvisioning.Registration` query, `where migrations_applied_at is not nil`) — ELIXIR-DEV
may factor this into a small shared private helper local to each Poller module (copy, not extract
into a new shared module — REQ-214 does not ask for a `TenantProvisioning` API change) or literally
duplicate the four-line query, either is acceptable; not specified further since it is an
implementation detail with no acceptance-criterion consequence either way.

`schedule_next_tick/0` uses **this module's own** `poll_interval_ms()`/`jitter_ms()` (§5.1) — never
`Letflow.Scheduler`'s — satisfying the acceptance criterion "its own configurable poll interval
(mirroring `Letflow.Scheduler.poll_interval_ms/0`'s `Application.get_env` pattern)."

---

## 8. `Letflow.Application` supervision-tree addition — boot-gating convention carried forward

**Stated explicitly, per this run's own instruction: this design carries forward the exact
boot-gating convention `Letflow.Scheduler.Poller`'s own entry uses, for the identical documented
hazard.** `ServiceTaskDispatcher.Poller` is a `GenServer` whose `init/1` sends `:tick` with **zero**
delay and whose `:tick` handler queries `Letflow.Repo` — under `Ecto.Adapters.SQL.Sandbox`'s
default `:manual` mode (this project's test mode) that query runs from a process no test process is
an ancestor of, raising `DBConnection.OwnershipError` on every tick until the supervisor's restart
intensity is exceeded and `Letflow.Supervisor` (and everything under it, including `Letflow.Repo`)
shuts down — the **exact same mechanism** `application.ex`'s own inline comment names for
`Letflow.Scheduler.Poller` (§0, verified by reading that file directly, not inferred).

**Concrete diff to `lib/letflow/application.ex`:**

1. A **new** private function, `service_task_dispatcher_children/0`, structurally identical to
   `scheduler_children/0`:
   ```
   defp service_task_dispatcher_children do
     if Application.get_env(:letflow, :start_service_task_dispatcher, true) do
       [{Letflow.Engine.ServiceTaskDispatcher.Poller, []}]
     else
       []
     end
   end
   ```
2. The `children` list's trailing expression changes from
   `... ++ scheduler_children() ++ http_child()` to
   `... ++ scheduler_children() ++ service_task_dispatcher_children() ++ http_child()` — placed
   immediately after `scheduler_children()` (both are poller-shaped, boot-gated, order-independent
   of each other and of every other child above them — no child depends on either poller's start
   order, mirroring `scheduler_children()`'s own "no ordering dependency" note, §0) and before
   `http_child()` (an arbitrary but consistent placement — HTTP listening starting last is the
   existing convention this design does not disturb).
3. `config/test.exs` gains **one new line**: `config :letflow, start_service_task_dispatcher: false`
   — the direct analogue of `config/test.exs:45`'s existing `config :letflow, start_scheduler: false`
   line (verified directly), added immediately beside it.
4. **A distinct config key, `:start_service_task_dispatcher`, not a reuse of `:start_scheduler`.**
   REQ-214's own text is explicit that the two pollers are "independent concerns with independent
   poll cadences and independent per-tenant claim queries" and must not be overloaded onto one
   process — carrying that independence through to the boot gate (rather than gating both pollers
   off one shared flag) is this design's own extension of that principle, so a future host can
   disable SERVICE_TASK dispatch without also disabling TIMER firing, or vice versa.

No other change to `application.ex`. `oidc_config`, `Letflow.Repo`, `Ecto.Migrator`, and every
other existing child are untouched.

---

## 9. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-STD-1 | Every `:httpc.request/4` call in this module is preceded, in the same function's own call graph, by a `UrlValidator.validate/2` call whose result gates whether the request is made — for both `route_kind` values. | §5.2 (`http_transport/3`'s single, unbypassable gate placement) — SECURITY-REVIEWER's own sign-off checklist item (REQ-214's own acceptance criterion) |
| INV-STD-2 | This module never calls `Letflow.Engine.set_instance_error/2` or `ExecutionError.append_multi/3`. | §5.6 step 5, §6 — confirmed by grep, per the acceptance criterion's own wording |
| INV-STD-3 | A `:retry` decision's `attempt_index` increment and `next_attempt_at` advance happen in the SAME `Repo.transaction/1` as the row's own claim. | §5.6 step 5's `:retry` branch — `attempt_dispatch/2`'s single `Repo.transaction/1` wraps claim, transport call, classify, decide, and the row update together |
| INV-STD-4 | A row belonging to a non-`:active` instance is never selected by `claim_due_dispatch_ids/2`, and therefore never reaches `http_transport/3`. | §5.4's join condition `p.status == :active` |
| INV-STD-5 | `poll_and_dispatch/1` never raises — every per-row failure is caught and folded into its return value's counts. | §5.5, mirroring `Letflow.Scheduler.poll_and_fire/1`'s own contract (§0) |
| INV-STD-6 | No sleep-based retry anywhere in this module or its Poller — the poller's own poll interval is the sole wait mechanism. | §5.6 step 5's `:retry` branch; §7 |
| INV-STD-7 | `ServiceTaskDispatcher.Poller`'s supervision entry is boot-gated behind `:start_service_task_dispatcher` (default `true`, `false` in `config/test.exs`), mirroring `Letflow.Scheduler.Poller`'s own `:start_scheduler` gate. | §8 |
| INV-STD-8 | `route_kind: :catalog_service` dispatch never reaches a real transport call — `catalog_lookup_stub/2` (or the absence of any real resolution) causes such a row's dispatch to be classified `:request_build_error`/give up, never `:advance`. | §5.3 — no code path in this module resolves a `service_id` to a dispatchable URL |

---

## 10. Open questions — not silently resolved

**OQ-1 (MINOR):** `ServiceTaskDispatch` is nested inside `service_task_dispatcher.ex` rather than
given its own file the way `Letflow.Scheduler.Timer` has (§2). Chosen for schema simplicity (3
small changesets vs. `Timer`'s 5), but this is a naming-convention judgment call, not an
acceptance-criterion-driven one — REVIEWER may direct a split file to match the `timers` precedent
exactly; either way compiles and satisfies every acceptance criterion identically.

**OQ-2 (MINOR):** `http_transport/3`'s outbound `content-type` header (§5.2) is assumed to be
`application/json`, copying `Letflow.Webhooks.dispatch_http/4`'s own hardcoded choice (§0). REQ-214's
own text does not specify a content-type convention for SERVICE_TASK dispatch, and
`ServiceTask.Config.t()`'s `body_template` field (§0) carries no explicit content-type of its own.
Flagged rather than silently assumed — if a future SERVICE_TASK use case needs a non-JSON body, this
would need revisiting; no acceptance criterion in REQ-214 tests a non-JSON body shape, so this
design does not add a configurable content-type field speculatively.

**OQ-3 — RESOLVED (was MAJOR/open; resolved during rework per CODE-DESIGN-VALIDATOR's BLOCKER
finding):** `config_snapshot["rendered_url"]` (§4.1) is **frozen at INSERT time** (REQ-215's future
activation-time caller renders the URL template exactly once, before the first row exists) and is
**never re-rendered by this module on any subsequent attempt, including every `:retry`**. This is
not this design's own invention — it is the identical, already-shipped convention
`Letflow.Webhooks.deliver/3`/`attempt_loop/7` (`lib/letflow/webhooks.ex:249-360`) already
establishes for the structurally identical webhook-retry problem, verified directly against that
module (not inferred): `deliver/3` receives `subscription.target_url` as part of its `subscription`
argument once, at entry, and `attempt_loop/7` (lines 266-313) passes that same `subscription`
struct — and therefore the same `target_url` — unchanged through every recursive call across every
retry (the recursive call at lines 347-355 re-passes `subscription` verbatim; `target_url` is never
re-read from a definition, never re-rendered from a template, on any attempt after the first).
What **does** happen fresh on every attempt, retries included, is re-validation: `dispatch_http/3,4`
(lines 373-392) calls `UrlValidator.validate/2` **again** on every single call to `attempt_loop/7`,
including retry-driven calls — the frozen URL is re-checked against the SSRF gate each time, but
never re-derived.

This design's own `config_snapshot["rendered_url"]` follows the same split, by direct analogy:

- **Frozen once, at INSERT time.** REQ-215's activation-time caller renders the URL template a
  single time and writes the result into `config_snapshot["rendered_url"]` in the same INSERT that
  creates the row (via `arm_changeset/2`, §4.2). No function in this module (`§5`) ever writes
  `config_snapshot`, and no function in this module has access to a template-rendering function or
  to live instance variables at poll time (restated from the original OQ-3 text) — so re-rendering
  inside this module is not just undesired, it is structurally impossible as designed.
- **Re-validated fresh on every attempt, including every retry.** §5.2's `http_transport/3` calls
  `UrlValidator.validate/2` immediately before `do_http_transport/3` on **every** call to
  `http_transport/3` — and `attempt_dispatch/2` (§5.6) calls `http_transport/3` exactly once per
  claimed attempt, so a `:retry`-driven re-claim of the same row on a later tick re-runs the full
  `http_transport/3` call, gate included, against the same frozen `rendered_url` value. Nothing
  about the gate's placement changes between a row's first attempt and its Nth retry attempt — same
  call, same frozen input, same gate.

**Security rationale, stated explicitly (not merely "this is precedented"):** freezing the URL once
and re-validating the frozen value on every attempt is the *correct* choice on its own merits, not
only the convenient one — re-rendering mid-retry-sequence would mean a definition update or a
variable change landing **between** two attempts of the same dispatch row could silently swap in a
different URL that was never itself validated (the validation on attempt N would have run against
attempt N's freshly-rendered value, not attempt N+1's), reopening exactly the SSRF hole INV-9 exists
to close. Freezing at INSERT time and re-validating the same frozen value on every subsequent
attempt means the one artifact that was ever actually inspected by `UrlValidator.validate/2` is the
only artifact ever handed to `:httpc.request/4`, on every attempt, with no window for an unvalidated
substitution to slip through. `Letflow.Webhooks` reaches this same conclusion independently for the
same reason, which is why its shape is reused here rather than re-derived from scratch.

No open question remains on this point. If a future requirement wants variable-driven
re-rendering-per-attempt, that is new scope requiring its own SSRF-gate analysis (re-validating a
*newly rendered* value on every attempt, not reusing a frozen one) — out of REQ-214's and REQ-215's
combined scope as currently written, and not assumed here.

**OQ-4 (MAJOR, load-bearing for §5.6 step 5's `:give_up` branch):** `ServiceTask.service_task_give_up_context()`
(§0's shipped type) requires `actor_id`, `idempotency_key`, and `variables` — none of which this
table's own columns (§3.1) carry. `idempotency_key` this module can compute itself via
`build_idempotency_key/4` (§5.6, already-shipped, pure). `actor_id` and `variables` it cannot: this
module holds no `InstanceState` and makes no call to `Letflow.Engine.Reconstruction` or any
snapshot-reading function (doing so would pull this module into the same "read current instance
state" territory `advance_after_timer_fired/3` occupies, which REQ-214's own scope boundary — "THIS
module does not call `Letflow.Engine.set_instance_error/2` itself" — suggests is deliberately
REQ-215's job, not this one's). **Resolution proposed, not assumed:** `variables` is populated as
`%{}` (an empty map) and `actor_id` as `EventStore.platform_actor_id()` (the same "no human actor"
sentinel `Letflow.Scheduler`'s own `TIMER_FIRED` event append already uses for the structurally
identical "no human/API actor initiates this" case, §0) — both placeholder-shaped, both flagged
here rather than silently chosen, because `standalone_error_attrs()`'s own `variables` field
(§0) is documented as flowing through into the `ERROR`-transition event's payload, and an empty map
there means the resulting `ERROR` event carries no instance-variable context, which may or may not
be what REQ-215/REVIEWER wants. **If REQ-215 needs real `variables`/`actor_id` at give-up time, its
own `advance_after_service_task_outcome/N` — which DOES read the instance's current state, mirroring
`advance_after_timer_fired/3` — is the natural place to enrich or override this module's
placeholder-populated `standalone_error_attrs()` before calling `set_instance_error/2`,** not this
module. Flagged for CODE-DESIGN-VALIDATOR and REQ-215's own future design pass, not silently
resolved.

**OQ-5 (MINOR):** §5.7 notes this module does not re-check instance-active status inside its own
transaction (only at claim time, §5.4's join). A narrow race window exists: claim succeeds while the
instance is `:active`, the instance transitions to `:cancelled`/`:completed` mid-transaction (a
concurrent, unrelated transaction), and this module's own transaction still commits a `:retry` or
terminal update against `service_task_dispatches` for an instance that is no longer active by the
time it commits. This does not corrupt `instance_projections` (this module never writes there) and
does not produce a spurious `:httpc.request/4` call for an *already*-non-active instance (the
request itself, if any, was made **before** this race window closes, under the same-transaction
guarantee) — but a `:give_up` outcome returned to a not-yet-built REQ-215 caller, for an instance
that raced to `:cancelled` moments earlier, is a real edge case REQ-215's own design should account
for (e.g. by re-checking instance status again before calling `set_instance_error/2`, mirroring
`advance_after_timer_fired/3`'s SCH-03 handling exactly). Flagged, not fixed here — REQ-214's own
acceptance criteria test only the claim-time skip, not this narrower in-flight race.

---

## 11. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.ServiceTask` (REQ-056) | this design → REQ-056 | Calls `classify_failure_kind/1`, `is_retriable_failure/1` (transitively, via `decide_failure/3`), `decide_failure/3`, `compute_service_task_backoff_ms/3`, `build_idempotency_key/4`, `build_service_task_give_up_error_attrs/1` unmodified. Reads `Config.t()`, `raw_outcome()`, `transport_fun()`, `catalog_lookup_fun()`, `failure_kind()`, `service_task_give_up_context()` types. Zero code added to `service_task.ex`. |
| `Letflow.Webhooks.UrlValidator` (REQ-204) | this design → REQ-204 | Calls `validate/1` (or `/2` with an injected resolver, for tests) unmodified, immediately before every `:httpc.request/4` call (§5.2). Zero code added to `url_validator.ex`. |
| `Letflow.Engine` (`standalone_error_attrs()` type only, REQ-061) | this design → REQ-061 | `attempt_dispatch/2`'s `:give_up` outcome carries exactly this type as its second tuple element — this module never calls `set_instance_error/2` itself (§6). Zero code added to `engine.ex`. |
| `Letflow.EventStore.instance_projections` (via `InstanceProjection` schema) | this design → EventStore | `claim_due_dispatch_ids/2`'s join reads `instance_projections.status` only — no write. |
| `Letflow.TenantProvisioning.Registration` | this design → TenantProvisioning | `ServiceTaskDispatcher.Poller`'s tenant-schema enumeration (§7), same query `Letflow.Scheduler.Poller` already uses. |
| `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest` | this design → TenantProvisioning | The new migration's name must be added to this manifest (§3, mandatory per the `timers` migration's own precedent). |
| `Letflow.Application` | this design → Application | New supervision-tree entry, boot-gated (§8). |
| REQ-215 (`dispatch_node/4`'s SERVICE_TASK clause, `advance_after_service_task_outcome/N`) | REQ-215 → this design | The consumer of this module's `dispatch_outcome()` (§5.6) and the writer of the first `service_task_dispatches` row (via `arm_changeset/2`, §4.2) — not built here. |

---

## 12. Acceptance-criteria traceability

| REQ-214 acceptance criterion | Concrete design element |
|---|---|
| 1. A synthetic `:inline_url` row, claimed by `poll_and_dispatch/1`, results in exactly one `:httpc.request/4` call, correctly classifying a 2xx JSON-object response as `:advance` via `classify_failure_kind/1` | §5.2 (`http_transport/3`/`do_http_transport/3`), §5.6 steps 2-4 |
| 2. A row resolving to a blocked SSRF range is rejected by `UrlValidator.validate/2` BEFORE any `:httpc.request/4` call, producing `:give_up` | §5.2's gate placement; §6's SSRF-block routing statement; INV-STD-1 |
| 3. A `:catalog_service` row is rejected with a `:not_registered`-shaped `:give_up` outcome regardless of `service_id`, moduledoc states why | §5.3; INV-STD-8; §5.3's own moduledoc-content statement |
| 4. A retriable failure below `retry_limit` advances `next_attempt_at` per `compute_service_task_backoff_ms/3` and increments `attempt_index`, in the SAME transaction | §5.6 step 5's `:retry` branch; INV-STD-3 |
| 5. A non-retriable failure, or retriable-but-exhausted, produces `:give_up` carrying `build_service_task_give_up_error_attrs/1`'s exact shape; this module never calls `set_instance_error/2` | §5.6 step 5's `:give_up` branch; §6; INV-STD-2 |
| 6. `ServiceTaskDispatcher.Poller` is its own supervision-tree entry, distinct from and alongside `Scheduler.Poller`, with its own configurable poll interval | §8 (concrete `application.ex` diff); §7 (`poll_interval_ms/0`); §5.1 |
| 7. A row belonging to a no-longer-ACTIVE instance is skipped at claim time, never produces `:httpc.request/4` | §5.4's join condition; INV-STD-4 |
| 8. SECURITY-REVIEWER sign-off confirming every dispatch path (both `route_kind` values) gates via `UrlValidator.validate/2` before `:httpc.request/4` | §5.2 (single unbypassable gate); INV-STD-1 — the concrete inspection target |
| 9. `mix test` and `mix compile --warnings-as-errors` both pass | Verified at Step 2a (ELIXIR-DEV), not this design step — no design element blocks it structurally (all types close, all functions total over their documented domains) |
