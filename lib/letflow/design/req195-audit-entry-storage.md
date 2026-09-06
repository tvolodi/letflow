# REQ-195 — Audit-entry storage with before/after capture and tamper-evident chaining

Design for `docs/requirements.yaml` REQ-195 (OBS-03, XC-02; queue task 368; GH#714).
Core storage/capture/chaining only — **no route or controller change** (REQ-196
serves `GET /api/v1/audit` from this store later). This closes the gap
`lib/letflow/routers/audit.ex`'s own moduledoc records: `resource_type` hardcoded
`"instance"`, `before_state`/`after_state` always `null`, because Letflow has "no such
table" as R-Co's `audit_entries`.

PROVENANCE (historical, not current decision authority):
Ported from R-Co `migrations/020_obs03_audit_entries.sql` plus `050` (trace_id) and
`051` (chain columns), and `src/obs/audit.zig`. Two R-Co defects are deliberately NOT
ported (Decision 1 below; the hash-recompute weakness under "Chain verification").

## 0. Traceability matrix (AC → design element)

| AC | Design element |
|---|---|
| AC1 (UPDATE/DELETE rejected by DB) | §2 Immutability triggers |
| AC2 (activate/cancel/complete each write 1 row with real before/after) | §3 Capture mechanism, §3.2 per-operation table |
| AC3 (audit-write failure rolls back the mutation) | §4 Same-transaction guarantee |
| AC4 (tenant-scoped rows) | §1 schema (`prefix`-scoped table, Decision 0003-B) |
| AC5 (prev_chain_hash linkage, first entry null) | §5 canonical form + §3.3 append algorithm step 4 |
| AC6 (verification recomputes, catches tampered after_state) | §6 `verify_chain/2` contract |
| AC7 (canonical form documented: field order, missing-optional encoding, timestamp repr) | §5 |
| AC8 (moduledoc states chosen capture mechanism + trade-off of the other) | §3.1 Decision 2 |
| AC9 (resource_id type stated + reason; non-uuid test or "none exists" statement) | §1.2 Decision 1 |
| AC10 (lua_script_execution_audit stays separate) | §7 |
| AC11 (no route/controller file touched) | §8 |
| AC12 (`mix test`/`mix compile --warnings-as-errors` pass) | ELIXIR-DEV execution gate, not a design element — noted in §8 |

## 1. Schema: `audit_entries`

Tenant-scoped per Decision 0003-B: lives in each tenant's own Postgres schema
(`prefix: prefix()`), created via the same `if prefix() do ... end`-guarded,
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`-registered migration pattern
already used by `20260823000001_create_api_tokens_tenant_scoped.exs` and
`20260819000002_create_tenant_role_tenant_scoped.exs` — this is a **new manifest
entry**, not a bare migration file; ELIXIR-DEV must add `{version, __MODULE__,
filename}` to `@tenant_scoped_migration_manifest` in `lib/letflow/tenant_provisioning.ex`
or the table never exists in any tenant schema provisioned after this lands (existing
tenants additionally need a one-off replay, same operational step every prior
tenant-scoped-table addition has required — out of this design's scope to re-derive,
follow the existing pattern precedent).

### 1.1 Columns

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `id` | `binary_id` (Ecto), `uuid` (PG) | NOT NULL, PK | `autogenerate: true`, matching every other schema in this codebase. This is `audit_id` in the requirement's field list — see naming note below. |
| `tenant_id` | `binary_id` | NOT NULL | Decision 0003-B intra-schema invariant. Populated per the 0003 addendum: derived from `opts[:prefix]` via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` inside the capturing context function — never accepted as a caller-supplied field. |
| `actor_id` | `binary_id` | NULL | Nullable: some writes (e.g. a system/timer-fired transition) have no human/API-token actor. |
| `action` | `:string` | NOT NULL | Free-form action tag, e.g. `"definition.activate"`, `"instance.cancel"`, `"task.complete"`, `"task.assign"`, `"user.create"` — dotted `resource.verb` convention, one literal per capture call site (§3.2 table gives the exact literal for each). |
| `resource_type` | `:string` | NOT NULL | One of `"definition"`, `"instance"`, `"task"`, `"user"`, `"group"`, `"api_token"` for this requirement's covered operations. Not an `Ecto.Enum` — the requirement anticipates further resource types (REQ-196, future work) and a comment-documented set (matching Decision 0003-A's precedent of `Ecto.Enum` only where the set is closed; this set is explicitly open-ended per R-Co's own `resource_type` column being plain `TEXT`). |
| `resource_id` | `:string` (PG `text`) | NOT NULL | **Decision 1** — see §1.2. |
| `timestamp` | `:utc_datetime_usec` | NOT NULL | When the audited mutation happened — stamped by the capturing context function with the current time truncated to microsecond precision at the point of capture (the same `DateTime.utc_now/0`-then-`DateTime.truncate/2` idiom `cancel_instance/3`/`complete_task/3` already use for their own `cancelled_at`/`completed_at`). |
| `before_state` | `:map` (PG `jsonb`) | NULL | The prior row's field map, or `nil` for a create (there is no "before"). See §3.2 for exact per-operation content. |
| `after_state` | `:map` (PG `jsonb`) | NULL | The resulting row's field map, or `nil` for a hard delete (not in this requirement's covered operation set — no covered operation produces a null `after_state`; see AC2's own three named examples, all of which have a real `after_state`). |
| `trace_id` | `:string` | NULL | XC-01's database half. Populated from `opts[:trace_id]` when the capturing context function's caller supplies one; `nil` when it doesn't. This requirement does not add trace-id propagation to any call site that lacks it today — a call site with no trace context simply records `nil` here, same disposition as `pipeline_run_id` in `routers/audit.ex`. |
| `chain_hash` | `:string` | NOT NULL | Lowercase-hex SHA-256 digest, §5. |
| `prev_chain_hash` | `:string` | NULL | `nil` only for the first entry in a given tenant's chain (AC5). |
| `inserted_at` | `:utc_datetime_usec` | NOT NULL | `timestamps(updated_at: false)` — matches `api_tokens`' own append-only convention. Distinct from `timestamp`: `inserted_at` is wall-clock write time (server clock at INSERT), `timestamp` is the audited event's own logical time as stamped by the capturing function before the `Multi` runs. In every covered operation the two are the same transaction and differ only by sub-millisecond scheduling jitter, but they are not defined to be identical, and `timestamp` — not `inserted_at` — is the field that participates in the canonical hashed form (§5) and in the three required indexes (§1.3), because it is the field the R-Co schema and the SPA (`web/src/api/audit.ts`'s `timestamp` field) both key on. |

**Naming note:** the requirement's own field list calls the primary key `audit_id`.
This design keeps Ecto's own `id` primary-key field name (matching every other schema
in this codebase — `users.id`, `tasks.id`, `api_tokens.id`), and REQ-196's route layer
is responsible for rendering it under the `"audit_id"` JSON key exactly as
`routers/audit.ex`'s existing `audit_item/1` already does for `event.event_id` →
`"audit_id"`. This is not a REQ-195 concern (no route change, AC11) — noted here only
so ELIXIR-DEV does not misread the requirement text as requiring a column literally
named `audit_id`.

### 1.2 Decision 1 — `resource_id` column type: `:string` (PG `text`)

**R-Co's hazard, stated in the requirement:** R-Co declared `resource_id` as `UUID`
and later had to widen it to `TEXT` in some schemas but not others; a leftover
`::uuid` cast on an un-widened path made every filtered `/audit` call fail in
production once a non-UUID resource type appeared.

**Checked against Letflow's actual schemas** (this session, `@primary_key {:id,
:binary_id, ...}` grepped across `lib/letflow/identity/*.ex`, `lib/letflow/engine/*.ex`,
and `lib/letflow/definitions/*.ex`): every resource type this requirement covers —
`process_definitions.id`, `tasks.id`, `users.id`, `groups.id`, `api_tokens.id`, and the
instance id engine-side (`Letflow.Engine.cancel_instance/3`'s `instance_id ::
Ecto.UUID.t()`) — is a `binary_id` (UUID). **No non-UUID resource id exists in Letflow
today**, satisfying AC9's second disjunct as a factual statement, not a deferral.

**Decision, made anyway, forward-looking:** `resource_id` is `:string` (PG `text`),
not `:uuid`/`binary_id`. Reasoning:

1. A UUID's canonical string form round-trips through `:string` with zero information
   loss and no query-shape cost — every filter this table needs (`WHERE resource_id =
   $1`) is a plain equality on indexed text, identical cost to equality on indexed
   `uuid`.
2. Declaring `:uuid` today would reproduce R-Co's exact hazard the moment any future
   resource type with a non-UUID natural key needs auditing (e.g. `tenant_role`'s
   `name`-keyed upsert, or a future config-key-scoped resource) — a leftover `::uuid`
   cast anywhere in a later query built against this column would then fail exactly
   as R-Co's did. `:string` forecloses that failure class permanently, at zero cost
   today.
3. This is consistent with `resource_type` also being plain `:string` rather than a
   closed `Ecto.Enum` (§1.1) — both columns are deliberately kept open for resource
   kinds this requirement doesn't yet cover, rather than typed narrowly around only
   the six kinds in scope now.

Stated in the migration's header comment per AC9's first clause.

### 1.3 Indexes (R-Co's three, the route's three filter shapes)

1. `create index(:audit_entries, [desc: :timestamp, desc: :id], prefix: prefix())` —
   time-range listing, newest first (matches `routers/audit.ex`'s `from`/`to` filters
   once REQ-196 wires them).
2. `create index(:audit_entries, [:actor_id, desc: :timestamp, desc: :id], prefix: prefix())`
   — the `actor_id` filter.
3. `create index(:audit_entries, [:resource_type, :resource_id, desc: :timestamp, desc: :id], prefix: prefix())`
   — the `resource_type`+`resource_id` filter.

`(timestamp desc, id desc)` as the trailing tiebreak in all three, matching the
requirement's own index spec and this codebase's established keyset-pagination
tiebreak convention (`Letflow.Definitions.list_paginated/2`, `Letflow.Identity.list_users/2`).

## 2. Immutability — enforced in the database

Ecto's migration DSL has no "reject UPDATE/DELETE" primitive (Decision 0003-C notes
this explicitly for event tables, which handle it at the *application* layer instead
— audit_entries cannot rely on that weaker guarantee, because AC1 requires the
rejection to happen "going around the Ecto schema," i.e. survive a caller that never
goes through `Letflow.Audit` at all). This is the one place in this design that uses
raw SQL via `execute/1`/`execute/2` inside the `Ecto.Migration` DSL — the same escape
hatch Decision 0003-A names for "anything the DSL can't express directly."

Per tenant schema (the trigger function and trigger must both be created with
`prefix: prefix()` context, i.e. inside the same `if prefix() do ... end`-guarded
migration as the table, so every tenant schema gets its own copy — there is no shared
`public`-schema trigger function to reference across schemas per Decision 0003-B's
physical-isolation model):

* A trigger function (schema-qualified to the tenant's own schema, not `public`)
  that unconditionally raises an exception with a fixed message
  `"audit_entries is immutable"` — the same message text R-Co uses, preserved for any
  future support/incident-response grep continuity.
* `BEFORE UPDATE ON audit_entries FOR EACH ROW EXECUTE FUNCTION <fn>()` — fires on
  every UPDATE attempt, whole-row, no column exclusion (an UPDATE that only touches an
  unrelated column, if one existed, is still rejected — there are no columns on this
  table for which an update would ever be legitimate).
* `BEFORE DELETE ON audit_entries FOR EACH ROW EXECUTE FUNCTION <fn>()` — same
  function, same message; `BEFORE DELETE` triggers don't need a differently-worded
  message since "immutable" already covers both mutation kinds.

AC1's two explicit tests exercise this directly with a raw `Repo.query!/3` (or
`Ecto.Adapters.SQL.query!/3`) `UPDATE`/`DELETE` against `audit_entries`, asserting the
query raises/returns a Postgres error carrying `"audit_entries is immutable"` —
"going around the Ecto schema" per AC1's own wording, i.e. not via any
`Ecto.Changeset`-based `Repo.update/1` call, which would never reach the DB with a
row to update to have this tested against.

## 3. Capture mechanism

### 3.1 Decision 2 — Elixir context-function-boundary capture, not a Postgres trigger

**The two options, as the requirement frames them:** (a) R-Co's own approach —
`BEFORE`-trigger-derived capture on eight business tables, deriving the action name
from status transitions and reading the actor from a Postgres session variable; (b)
capture inside the Elixir context-function boundary (`Letflow.Definitions.activate/2`,
`Letflow.Engine.cancel_instance/3`, etc.), as an extra `Ecto.Multi` step alongside the
mutation it accompanies.

**Decision: (b), Elixir context-function-boundary capture.**

**Trade-off, stated per AC8:**

* *What the trigger approach (R-Co's) would buy:* it cannot miss a write — any INSERT/
  UPDATE reaching the table via ANY path (a future direct-SQL admin script, a bug that
  bypasses the context module) still gets audited, because the trigger fires at the
  storage layer regardless of caller.
* *What it costs, and why that cost is not worth paying here:* (1) it requires a
  session-level mechanism to make the acting user's id visible to a trigger function —
  Postgres session GUC (`SET LOCAL app.actor_id = ...`) or equivalent — and Decision
  0003's 2026-08-17 addendum **already considered and explicitly rejected** exactly
  this kind of session-level tenant/actor context as out of scope for Letflow's
  architecture ("a new cross-cutting mechanism touching every tenant-scoped table...
  not needed to unblock [the work] today"); introducing it now, solely for this
  requirement, would re-open a question Decision 0003 deliberately deferred rather
  than ruled out, and do so unilaterally. (2) It puts business logic (deriving an
  `action` string from a status transition) in SQL, in a codebase whose only precedent
  for cross-cutting side effects on a mutation is `Ecto.Multi` composed inline in the
  same Elixir module as the mutation (`Letflow.Engine`, `Letflow.Definitions`,
  `Letflow.Webhooks`, `Letflow.Dlq`, `Letflow.Scheduler` all follow this shape — none
  of this codebase's 30+ migrations use `CREATE TRIGGER` for anything, grepped this
  session). (3) **[Superseded note, rework iteration 1 — see §3.1a below for the full
  corrected reasoning]** The original text of this point claimed every one of this
  requirement's covered call sites already receives `actor_id` as an explicit
  Elixir-level argument, citing `Letflow.Definitions.activate/2`'s
  `opts[:service_scope_validator]`-adjacent context as one of four supporting
  examples. **That citation is false** — verified directly against
  `lib/letflow/definitions.ex` this session: `activate/2`'s `activate_opts()` type
  (`[prefix: String.t(), service_scope_validator: service_scope_validator_fun() |
  nil]`) has no `actor_id` field, and neither does `deprecate/2`'s/`archive/2`'s
  narrower `opts() :: [prefix: String.t()]` — both delegate to a private
  `transition/4` that never reads or threads an actor. The claim holds for
  `Letflow.Tasks.claim_attrs`/`assign_attrs`'s `attrs.actor_id`,
  `Letflow.Engine.cancel_instance/3`'s `attrs[:actor_id]`, and
  `Letflow.Engine.complete_task/3`'s `attrs[:actor_id]` — all three genuinely already
  receive it — but **not** for Definitions' three lifecycle functions. §3.1a below
  states the corrected, explicit disposition for those three; this point (3) is
  otherwise still valid support for Decision 2 as applied to the three call sites it
  correctly describes.
* *The residual risk this decision accepts:* a write that bypasses the context module
  entirely (e.g. a future raw `Repo.insert_all/3` against `tasks` from some
  as-yet-unwritten code path) would not be audited. This is the named cost of option
  (b) and is accepted because (i) it mirrors this codebase's existing convention that
  business invariants live in context-module boundaries, not the storage layer (every
  `Ecto.Multi` composition cited above already carries this same residual-bypass risk
  for its *other* side effects, e.g. event emission), and (ii) REVIEWER's idiom gate
  (WF-02 step 2d) already screens for exactly this class of bypass on every future
  change touching these tables.

**Moduledoc requirement (AC8):** `Letflow.Audit`'s moduledoc must state this decision
and this trade-off in its own words — not merely cross-reference this design doc —
since AC8 is checked against the shipped module, not this file.

### 3.1a `actor_id` disposition for `Definitions.activate/2`/`deprecate/2`/`archive/2` — added in rework iteration 1

**The gap (CODE-DESIGN-VALIDATOR, step 1b):** unlike `cancel_instance/3`,
`complete_task/3`, and `assign_task/3`, none of `Letflow.Definitions.activate/2`,
`deprecate/2`, `archive/2` receives `actor_id` today — confirmed against
`lib/letflow/definitions.ex`'s `activate_opts()`/`opts()` types and the functions'
actual bodies (§3.1 point 3, corrected above). Something has to be decided for these
three specifically, since AC2 names definition activation as one of its three
required audited operations.

**The two live options, and why one is foreclosed by this requirement's own scope:**

* **(a) Widen the API** — add an `actor_id: Ecto.UUID.t() | nil` field to
  `activate_opts()` and a new shared `opts()` (or per-function `deprecate_opts()`/
  `archive_opts()`), thread it into the `Multi`'s `:audit` step. Checked this session:
  the acting human's identity is available today, but **only inside the router
  layer** — `conn.assigns.auth_context.user_id`, the same assign
  `Letflow.Routers.Definitions`'s own `handle_import/1` (line ~1003) and
  `handle_rollback/2` (line ~1121) already read and pass into their respective
  context-function calls as an explicit argument. Populating a new `opts[:actor_id]`
  for `activate/2`/`deprecate/2`/`archive/2` with a real value therefore requires
  editing `handle_activate/1`, `handle_deprecate/1`, `handle_archive/1`, and
  `handle_delete/2`'s deprecate/archive branch in `lib/letflow/routers/definitions.ex`
  to read `conn.assigns.auth_context.user_id` and pass it through. **This requirement's
  own AC11 forbids exactly that** — "no route/controller file touched," enforced by
  ELIXIR-DEV's own `git diff --stat` check at Step 2a (§8). Widening the opts type
  alone, without also editing the router to populate it, would ship a field no caller
  ever sets — a worse outcome than not adding the field, since it invites a future
  reader to assume it's wired up when it isn't. **Option (a) is therefore not
  available inside this requirement's own scope**, not merely undesirable.
* **(b) Record `actor_id: nil` for these three operations, as this requirement's
  explicit, stated disposition.** This is schema-legal (`actor_id` is nullable, §1.1,
  precisely for the "no human/API-token actor" case) and does not violate AC2 — AC2's
  three required test cases (one of which is definition activation) are about
  `before_state`/`after_state` containing "the actual prior and resulting values,"
  not about `actor_id`; a `nil` actor_id alongside a fully real `before_state`/
  `after_state` pair satisfies AC2 as written.

**Decision: (b).** `actor_id: nil` for all three of `Letflow.Definitions.activate/2`,
`deprecate/2`, `archive/2`'s audit rows, in this requirement's initial cut.
Justification, stated explicitly and distinctly from the other covered operations
(which capture a real actor because the data is already in hand at zero cost — §3.1
point 3):

1. AC11 rules out the one change (a router edit) that would let these three obtain a
   real actor_id today, as shown above — this is not a case of "we could easily
   thread it through but chose not to," it is a hard scope boundary this requirement
   does not have the authority to cross.
2. **[Superseded note, rework iteration 2 — see corrected point below.]** The original
   text of this point claimed `grep` confirms `Definitions.activate/2` is "also called
   from system/scheduler-initiated paths with no HTTP request and no human actor at
   all," citing `test/letflow/scheduler_test.exs:135` and
   `test/letflow/scheduler/poller_test.exs:100` as evidence. **That claim overstates
   what those citations show, verified directly this session:**
   `grep -rn "Definitions.activate(" lib/` (excluding this design doc) returns exactly
   **one** production call site — `lib/letflow/routers/definitions.ex:926`, inside
   `handle_activate/1`, i.e. the router/HTTP path itself. There is no production
   scheduler-driven or otherwise system-driven caller of `activate/2` anywhere in
   `lib/`. The two cited test lines are test-fixture setup helpers (`active_definition!/1`
   in `scheduler_test.exs`, an equivalent helper in `poller_test.exs`) that call
   `Definitions.activate/2` directly from test code to build a fixture an unrelated
   scheduler/poller test then exercises against — they demonstrate that `activate/2`
   *can* be invoked with no actor context available (test-harness evidence of shape),
   not that any real production system-driven path already does so. Point 2 is
   therefore dropped as a justification for Decision (b): it is not load-bearing —
   point 1 above (the AC11 scope boundary) is on its own a sufficient, fully-verified
   basis for `actor_id: nil` on these three functions, without needing a second,
   unverifiable "already system-driven" argument.
3. This is a stated, scoped completeness gap, not a silent one — tracked as OQ-4
   (§9) for a follow-up requirement to widen `activate_opts()`/`opts()` **and** update
   the three router handlers **together, atomically**, once a requirement exists whose
   scope permits touching `lib/letflow/routers/definitions.ex` (this one AC11's
   deliberately doesn't).

**§3.2's per-operation table** (below) states `actor_id: nil` explicitly for these
three rows so ELIXIR-DEV does not need to infer it from this subsection.

### 3.1b `actor_id` disposition for six `Letflow.Identity` functions — added in rework iteration 2

**The gap (CODE-DESIGN-VALIDATOR, step 1b, second recheck):** checked directly against
`lib/letflow/identity.ex` this session — `create_user/2` (line 218),
`update_user_profile/3` (line 291), `update_user_status/3` (line 312),
`create_group/2` (line 347), `create_token/3` (line 842), `revoke_token/2` (line 929)
all take only `opts :: opts()` where `opts() :: [prefix: String.t()]` (or an
equivalent narrow prefix-only shape) — none has an `actor_id` parameter, keyword
option, or field anywhere in its signature or body. This is the identical gap §3.1a
resolves for `Definitions.activate/2`/`deprecate/2`/`archive/2`, in a different
module.

**Checked this session — where these six are called from:** `grep -rn` for each of
the six across `lib/` (excluding `lib/letflow/identity.ex` itself) shows every call
site is in `lib/letflow/routers/identity.ex`: `create_user/2` (line 250),
`update_user_profile/3` (line 361), `update_user_status/3` (line 394),
`create_group/2` (line 436), `create_token/3` (line 592), `revoke_token/2` (line 636).
No non-router caller of any of the six exists in `lib/`. The router file additionally
does not read `conn.assigns.auth_context.user_id` anywhere today (`grep -n
"auth_context" lib/letflow/routers/identity.ex` returns no match) — so even the one
channel that supplies a real actor id elsewhere in this codebase (the pattern
`handle_import/1`/`handle_rollback/2` use in `routers/definitions.ex`, and that
§3.1a's option (a) describes) is not merely unused here but not wired into this
router at all today.

**The same two live options as §3.1a, and the same scope boundary:**

* **(a) Widen the API** — add an `actor_id: Ecto.UUID.t() | nil` field to each of the
  six functions' opts, thread it through to the `Multi`'s `:audit` step. Doing so with
  a real value requires editing `lib/letflow/routers/identity.ex` (the only caller of
  all six) to read `conn.assigns.auth_context.user_id` (or wherever this router's
  authenticated actor is actually held — not yet established, since the router
  doesn't read `auth_context` today) and pass it through. **This requirement's own
  AC11 forbids exactly that** — "no route/controller file touched." As with
  Definitions, widening the opts type without also editing the router to populate it
  would ship a field no caller ever sets. **Option (a) is not available inside this
  requirement's own scope.**
* **(b) Record `actor_id: nil` for these six operations, as this requirement's
  explicit, stated disposition.** Schema-legal (`actor_id` is nullable, §1.1) and does
  not conflict with any acceptance criterion: **AC2 names only definition activation,
  instance cancellation, and task completion as its three required audited
  operations — no Identity operation appears in AC2 at all** — so there is no AC2
  disjunct to reconcile here, unlike the Definitions-activate case where AC2 directly
  names the operation. There is accordingly even less tension in choosing `nil` here
  than for §3.1a's three functions.

**Decision: (b).** `actor_id: nil` for all six of `Letflow.Identity.create_user/2`,
`update_user_profile/3`, `update_user_status/3`, `create_group/2`, `create_token/3`,
`revoke_token/2`'s audit rows, in this requirement's initial cut. Justification:

1. AC11 rules out the one change (a router edit to `lib/letflow/routers/identity.ex`)
   that could let these six obtain a real actor_id today — a hard scope boundary, not
   a discretionary choice, exactly as §3.1a's point 1 establishes for Definitions.
2. Confirmed this session (grep, above): no caller of any of the six exists outside
   `lib/letflow/routers/identity.ex`, and that router does not currently read any
   actor-identifying assign — so there is no unverified "maybe it's already threaded
   somewhere" ambiguity left open; the gap is fully characterized, not partially
   deferred.
3. This does not conflict with AC2 (point (b) above) and does not conflict with any
   other acceptance criterion — none of AC1/AC3–AC12 names a specific Identity
   function this design must supply a non-nil `actor_id` for.
4. Tracked as **OQ-5** (§9) alongside OQ-4, for a follow-up requirement scoped to
   touch `lib/letflow/routers/identity.ex` to widen these six functions' opts **and**
   update the router to populate `actor_id` from a real authenticated-actor source,
   together, atomically — the same "widen the type and wire the caller in the same
   change" constraint OQ-4 states for Definitions.

**§3.2's per-operation table** (below) states `actor_id: nil` explicitly for all six
rows, referencing this subsection, rather than repeating the reasoning six times.

### 3.2 New module: `Letflow.Audit`

```
Letflow.Audit
  @moduledoc  -- states: capture mechanism decision + trade-off (AC8), canonical
                 hashed form (AC7), lua_script_execution_audit separation (AC10)

  @type entry_attrs :: %{
    required(:actor_id)     => Ecto.UUID.t() | nil,
    required(:action)       => String.t(),
    required(:resource_type)=> String.t(),
    required(:resource_id)  => String.t(),
    required(:before_state) => map() | nil,
    required(:after_state)  => map() | nil,
    optional(:trace_id)     => String.t() | nil
  }

  @spec append_multi(multi :: Ecto.Multi.t(), step_name :: atom(), attrs :: entry_attrs(), prefix :: String.t()) ::
          Ecto.Multi.t()
  # Appends one Ecto.Multi.run/3 step named `step_name` that:
  #   1. derives tenant_id from `prefix` via
  #      Letflow.TenantProvisioning.tenant_id_for_schema_name/1
  #   2. reads the tenant's current chain tail (see append algorithm below)
  #   3. computes chain_hash per canonical form (§5)
  #   4. inserts one Letflow.Audit.Entry row via Repo.insert/2 (prefix: prefix)
  # Returns {:ok, %Letflow.Audit.Entry{}} on success from the Multi step, or
  # {:error, reason} which — being inside the caller's own Multi — aborts and rolls
  # back every other step in that same Multi (§4).

  @spec verify_chain(prefix :: String.t(), opts :: [limit: pos_integer() | :all]) ::
          {:ok, :valid} | {:error, {:hash_mismatch, entry_id :: Ecto.UUID.t()}}
          | {:error, {:chain_broken, entry_id :: Ecto.UUID.t()}}
  # §6.
```

`Letflow.Audit.Entry` (Ecto schema module for `audit_entries`, `@primary_key {:id,
:binary_id, autogenerate: true}`, fields per §1.1) — a plain schema module, no public
functions beyond `changeset/2` (structural cast/validate_required only, matching this
codebase's convention of keeping domain rules in the context module, not the schema).

### 3.2 Per-operation capture — where the call fires, what before/after contain

`append_multi/4` is called as one additional step inside the `Ecto.Multi` each covered
context function already builds (or a newly-introduced single-step `Multi` for a
function that doesn't already use one, e.g. `Letflow.Definitions.create/2`, which
today runs a plain `with`/insert, not a `Multi` — REQ-195 introduces the `Multi` there
specifically to get the same-transaction guarantee, §4).

| Operation | Context function | `action` | `resource_type` | `resource_id` | `actor_id` | `before_state` | `after_state` |
|---|---|---|---|---|---|---|---|
| Definition create | `Letflow.Definitions.create/2` | `"definition.create"` | `"definition"` | new `ProcessDefinition.id` | `nil` — see §3.1a; `create/2`'s own `opts()` has no `actor_id` field either, same gap, same disposition | `nil` (no prior row) | the inserted `ProcessDefinition` struct, `Map.from_struct/1`'d and stripped of the Ecto metadata field (`:__meta__`) |
| Definition activate | `Letflow.Definitions.activate/2` | `"definition.activate"` | `"definition"` | the definition's `id` | **`nil` — §3.1a Decision (b), stated explicitly, not an oversight** | the DRAFT row's field map, fetched inside the same transaction before the status flip (the existing `run_activate_transaction/4` already loads the row — this design reuses that already-fetched struct rather than an extra query) | the now-ACTIVE row's field map after update |
| Definition deprecate | `Letflow.Definitions.deprecate/2` (→ private `transition/4`) | `"definition.deprecate"` | `"definition"` | the definition's `id` | **`nil` — §3.1a Decision (b)** | the ACTIVE row's field map | the DEPRECATED row's field map |
| Definition archive | `Letflow.Definitions.archive/2` (→ private `transition/4`) | `"definition.archive"` | `"definition"` | the definition's `id` | **`nil` — §3.1a Decision (b)** | the DEPRECATED row's field map | the ARCHIVED row's field map (includes the newly-stamped `archived_at`) |
| Instance create | `Letflow.Engine.create/2` | `"instance.create"` | `"instance"` | new instance id | `attrs[:actor_id]` — already an explicit argument (`Letflow.Routers.Instances.handle_create/1` sources it from `conn.assigns.auth_context.user_id`) | `nil` | the created instance's field map (the `instance_projections` row, or the equivalent in-memory `InstanceState` snapshotted to a map — whichever this function already returns as its `{:ok, result}` payload; ELIXIR-DEV uses that same shape, not a second independent read) |
| Instance cancel | `Letflow.Engine.cancel_instance/3` | `"instance.cancel"` | `"instance"` | `instance_id` | `attrs[:actor_id]` — already an explicit argument | the pre-cancel row/state map | the post-cancel row/state map (status `CANCELLED`, `cancelled_at` stamped) |
| Task create | wherever `Letflow.Engine.Task` rows are first inserted (engine dispatch — the same site that already creates a `tasks` row when a user-task node activates; ELIXIR-DEV locates this exact call inside `lib/letflow/engine.ex`'s dispatch path, since `Letflow.Tasks` itself is read/claim/assign-only and has no `create` entrypoint of its own) | `"task.create"` | `"task"` | new `Task.id` | whatever actor context this engine-dispatch call site already has in scope (typically the actor who advanced the preceding node, if any) — not independently verified this session (OQ-1 already covers this call site's exact location); `nil` when no such context is in scope | `nil` | the created `Task` row's field map |
| Task complete | `Letflow.Engine.complete_task/3` | `"task.complete"` | `"task"` | `task_id` | `attrs[:actor_id]` — already an explicit argument | the pre-complete `Task` row | the post-complete `Task` row (status `COMPLETED`, output variables applied) |
| Task assign | `Letflow.Tasks.assign_task/3` | `"task.assign"` | `"task"` | `task_id` | `attrs.actor_id` — already an explicit, required field of `assign_attrs` | the pre-assign `Task` row (previous `assignee_type`/assignee reference) | the post-assign `Task` row |
| User create | `Letflow.Identity.create_user/2` | `"user.create"` | `"user"` | new `User.id` | **`nil` — §3.1b Decision (b), stated explicitly, not an oversight** | `nil` | the created `User` row's field map, **with `password_hash`/any credential-bearing field excluded** — same allowlist discipline `routers/audit.ex`'s own `audit_item/1` uses (INV-2); `before_state`/`after_state` are never the raw Ecto struct, always an explicit field allowlist |
| User status/profile change | `Letflow.Identity.update_user_status/3`, `update_user_profile/3` | `"user.update_status"` / `"user.update_profile"` | `"user"` | `User.id` | **`nil` — §3.1b Decision (b)** | pre-update allowlisted map | post-update allowlisted map |
| Group create | `Letflow.Identity.create_group/2` | `"group.create"` | `"group"` | new `Group.id` | **`nil` — §3.1b Decision (b)** | `nil` | created `Group` row's field map |
| Token issue | `Letflow.Identity.create_token/3` | `"token.create"` | `"api_token"` | new `ApiToken.id` | **`nil` — §3.1b Decision (b)** | `nil` | the created row's field map **excluding `token_hash`** (INV-4 — the plaintext is never captured anywhere, per `ApiToken`'s own moduledoc, and `token_hash` itself is excluded from `after_state` too, since a hash is still a credential-adjacent secret with no audit value and this table already treats it as security-sensitive) |
| Token revoke | `Letflow.Identity.revoke_token/2` | `"token.revoke"` | `"api_token"` | `ApiToken.id` | **`nil` — §3.1b Decision (b)** | pre-revoke row (`revoked_at: nil`) minus `token_hash` | post-revoke row minus `token_hash` |

**On the six Identity rows above:** resolved explicitly in rework iteration 2, §3.1b
— `actor_id: nil` for all six, verified (not inferred) against `lib/letflow/identity.ex`'s
actual signatures and `lib/letflow/routers/identity.ex`'s actual call sites this
session. This is no longer a deferral; see §3.1b for the full reasoning.

**On the Task-create row's `actor_id` note:** left as-is — it remains tied to OQ-1
(the exact `task.create` call site inside `lib/letflow/engine.ex` is not pinned to a
line number; checked again this session and no single unambiguous insertion site was
found either, so this is a genuinely open question, not a resolvable gap like the
Identity rows were). "Not independently verified this session" is accurate there in a
way it was not for the six Identity functions above, whose signatures were fully
knowable and simply had not been read before this rework.

Every `before_state`/`after_state` map is a **plain map of scalar/string/nested-map
values**, never a bare JSON scalar at the top level — this is an invariant the
canonical-form spec (§5) depends on (its `null`-sentinel collision analysis assumes
a present `before_state`/`after_state` is always a JSON object, never the JSON literal
`null`/a bare string/number).

### 3.3 Append algorithm (inside `append_multi/4`'s `Multi.run/3` body)

1. Resolve `tenant_id` from `prefix`.
2. Fetch the tenant's current chain tail: `SELECT chain_hash FROM audit_entries WHERE
   ORDER BY timestamp DESC, id DESC LIMIT 1` (scoped by `prefix`) inside the same
   transaction — this is a `FOR UPDATE`-free plain read; concurrent-append ordering is
   guaranteed by both writers being inside the same DB transaction as their own
   business mutation, and Postgres's MVCC snapshot semantics for a `SELECT` immediately
   followed by an `INSERT` in the same transaction are sufficient here because there is
   no read-modify-write update happening on the *previous* row (previous rows are
   immutable, §2) — only a new row is appended, so there is no lost-update hazard to
   guard against, unlike a normal counter-increment race.
3. `prev_chain_hash` := the fetched value, or `nil` if the tenant has zero existing
   entries (AC5's "first entry ... null").
4. Build the canonical string (§5) over this entry's own field values plus the fetched
   `prev_chain_hash`, compute `chain_hash` = lowercase-hex SHA-256 of that string.
5. Insert the built `Letflow.Audit.Entry` struct via `Repo.insert/2`, scoped to the tenant's schema (`prefix: prefix`).

## 4. Same-transaction guarantee

**Mechanism: `Ecto.Multi`**, matching this codebase's only precedent for "an
accompanying side-effect must roll back the primary mutation with it"
(`Letflow.Webhooks`, `Letflow.Dlq`, `Letflow.Scheduler`, `Letflow.Engine`'s own
event-emission steps all compose additional `Multi.insert`/`Multi.run` steps into the
same `Multi` pipeline, submitted to `Repo.transaction/1` once, as the row they
accompany, rather than opening a second transaction or calling `Repo.transaction/1`
twice).

Each covered context function's existing (or newly-introduced, for `create/2`, which
has none today) `Multi` gains one more named step, added via `Multi.run/3` under the
step name `:audit`, whose runner function delegates to `Letflow.Audit.append_multi/4`.
This step is placed **after** the step that performs the actual state mutation (so the
accumulated `Multi` changes already contain the resulting row to build `after_state`
from) and **before** the `Multi` is submitted to `Repo.transaction/1`. If the `:audit`
step's insert fails for any reason (a changeset error,
`chain_hash` malformed, a DB-level rejection), `Ecto.Multi`'s own all-or-nothing
transaction semantics roll back every prior step in the same `Multi` — the definition/
instance/task mutation included — exactly matching AC3's own test description ("a test
that forces the audit insert to fail leaves the definition/instance/task unchanged").
No new supervision or retry mechanism is introduced; this is `Ecto.Multi`'s existing,
already-relied-upon guarantee, applied to one more step.

**Why not two transactions (mutation, then a separate audit-insert transaction)?**
That shape cannot satisfy AC3 — a second transaction failing after the first commits
leaves the mutation applied with no accompanying audit row, the exact "audit-write
failure doesn't roll back the mutation" outcome AC3 forbids.

## 5. Canonical hashed form (XC-02)

**Fully specified — no field is optional to interpret.** Any two independent
implementations following this section byte-for-byte produce identical `chain_hash`
values for identical row content.

### 5.1 Encoding primitive: length-prefixed fields ("netstring" form)

Each field's value is encoded as `<decimal-byte-length>:<raw-UTF-8-bytes>`, except a
SQL-`NULL` field, which is encoded as the fixed 3-byte literal `-1:` (no length, no
bytes — `-1` can never be a valid byte length, so this cannot collide with any real
field's encoding, including an empty string, which is `0:` distinct from `-1:`). This
avoids **every** delimiter-collision question a fixed-separator scheme (e.g.
`key=value` joined by `|`) would otherwise have to answer field-by-field, which is the
exact ambiguity the requirement calls out as needing an explicit, agreed answer.

The full canonical string is the concatenation of the 11 fields below, in this exact
order, with no bytes between them beyond what each field's own `<len>:<bytes>`
encoding already contributes:

| # | Field | Source | Textual encoding before length-prefixing |
|---|---|---|---|
| 1 | `id` | this entry's own (pre-generated, client-side) `binary_id` | canonical lowercase-hyphenated UUID string, e.g. `"3fa8...b1"` — **never NULL** |
| 2 | `tenant_id` | derived from `prefix` | canonical lowercase-hyphenated UUID string — **never NULL** |
| 3 | `actor_id` | `attrs.actor_id` | canonical lowercase-hyphenated UUID string, or `NULL`-encoded (`-1:`) when the actor is `nil` |
| 4 | `action` | `attrs.action` | the literal string as-is — **never NULL** |
| 5 | `resource_type` | `attrs.resource_type` | the literal string as-is — **never NULL** |
| 6 | `resource_id` | `attrs.resource_id` | the literal string as-is — **never NULL** |
| 7 | `timestamp` | this entry's `timestamp` | decimal ASCII integer: `DateTime.to_unix(timestamp, :microsecond)` formatted with `Integer.to_string/1` (no leading zeros, no sign for any post-1970 value, which every real timestamp is) — **never NULL** |
| 8 | `before_state` | `attrs.before_state` | canonical JSON string (§5.2), or `NULL`-encoded when `attrs.before_state` is `nil` |
| 9 | `after_state` | `attrs.after_state` | canonical JSON string (§5.2), or `NULL`-encoded when `attrs.after_state` is `nil` |
| 10 | `trace_id` | `attrs.trace_id` | the literal string as-is, or `NULL`-encoded when absent |
| 11 | `prev_chain_hash` | the fetched chain tail (§3.3 step 3) | the literal lowercase-hex string as-is, or `NULL`-encoded for the tenant's first entry |

`id` (field 1) must be generated **before** hashing, not left to Postgres's
`gen_random_uuid()` default — `Repo.insert/2` is called with an explicit
`id: Ecto.UUID.generate()` already set on the struct, so the hash can include it. This
mirrors this codebase's own "client-generated binary_id PKs" precedent already named
in `tenant_provisioning.ex`'s `insert_or_fetch_registration/2` comment.

### 5.2 Canonical JSON encoding for `before_state`/`after_state`

`Jason.encode!/1` over the map, with two additional canonicalization rules a plain
`Jason.encode!/1` call does not itself guarantee:

1. **Object keys sorted lexicographically** (byte-wise ascending over each key's UTF-8
   encoding) at every nesting level, not insertion order. Concretely: before encoding,
   recursively rebuild every map in the structure as a list of `{key, value}` pairs
   sorted by `key`, then encode via `Jason.encode!/1` with `Jason.OrderedObject` (or
   equivalent) so key order in the output byte string is deterministic regardless of
   the map's internal representation order.
2. **No insignificant whitespace** — `Jason.encode!/1`'s default output already has
   none (no pretty-printing), so no extra option is needed beyond ensuring it is never
   called with `pretty: true`.

Every value inside `before_state`/`after_state` is itself already JSON-representable
(string, number, bool, `nil`→JSON `null`, nested map/list) because these maps are
built from allowlisted Ecto struct fields (§3.2), never from arbitrary Elixir terms
(atoms other than `nil`/`true`/`false`, tuples, etc. never appear).

### 5.3 Digest

`chain_hash` is the SHA-256 digest of the canonical string's UTF-8 bytes (`:crypto.hash/2`
with the `:sha256` algorithm), rendered as lowercase hexadecimal (`Base.encode16/2` with
its case option set to lowercase) — 64 characters.

### 5.4 What must be documented in `Letflow.Audit`'s moduledoc (AC7)

The exact field order (the 11-row table above), the missing-optional encoding (the
`-1:` netstring sentinel, §5.1), and the timestamp representation (integer
microseconds since Unix epoch, decimal ASCII, §5.1 row 7) — copied into the shipped
module's `@moduledoc`, not merely cross-referenced to this file.

## 6. Chain verification — recompute, not linkage-only (AC6, the critical fix)

PROVENANCE (historical, not current decision authority):
**The defect this must not repeat:** R-Co's `validateAuditChain` (`src/obs/audit.zig`
L312-373) selects every content column per entry but only ever compares
`entry.prev_chain_hash == predecessor.chain_hash` — it never recomputes a digest from
the content it just read, so an operator who edits a persisted `after_state` directly
(bypassing the application, e.g. via a superuser connection or by disabling the
immutability trigger, §2) while leaving both hash columns untouched passes R-Co's
check. That defeats the entire purpose of a tamper-evident chain.

**`Letflow.Audit.verify_chain/2` contract:**

```
@spec verify_chain(prefix :: String.t(), opts :: [limit: pos_integer() | :all]) ::
        {:ok, :valid}
      | {:error, {:hash_mismatch, entry_id :: Ecto.UUID.t()}}
      | {:error, {:chain_broken, entry_id :: Ecto.UUID.t()}}
```

Algorithm:

1. Load every `audit_entries` row for the tenant named by `prefix` (or the most recent
   `opts[:limit]`, oldest-first within that window — `:all` is the default, matching
   AC6's test which needs to see the whole chain), ordered `timestamp ASC, id ASC` —
   the append order (§3.3).
2. For each entry in order:
   a. **Recompute** `chain_hash` from that entry's own *currently-stored* column
      values, applying the exact canonical form in §5 (the same function `append_multi/4`
      uses internally — this is the same code path, not a reimplementation that could
      independently drift out of sync with it). If the recomputed digest does not
      equal the entry's stored `chain_hash` column, return
      `{:error, {:hash_mismatch, entry.id}}` immediately — **this is the check R-Co's
      own function never performs**, and it is what AC6's test (a directly-modified
      `after_state` with hashes left alone) exercises.
   b. Compare the entry's stored `prev_chain_hash` against the *previous entry's
      recomputed-and-verified* `chain_hash` (not that previous entry's own stored
      `prev_chain_hash` — chaining off the value just re-verified in step (a) means a
      hash-mismatch on entry N is caught at N itself, not deferred to a
      chain-linkage failure reported against N+1). A mismatch here (or a non-`nil`
      `prev_chain_hash` on what should be the tenant's first entry, or a `nil`
      `prev_chain_hash` on any non-first entry) returns
      `{:error, {:chain_broken, entry.id}}`.
3. If every entry passes both checks, return `{:ok, :valid}`.

**On any detected mismatch, `verify_chain/2` stops at the first bad entry and reports
its `id`** — it does not continue scanning past a known-broken point (a `chain_hash`
computed over corrupted content has no meaning for verifying anything chained after
it), and it distinguishes *which* invariant broke (`:hash_mismatch` — content was
altered — versus `:chain_broken` — linkage was altered/an entry was deleted-and-
reinserted/reordered) so a caller/incident-responder knows which failure mode to
investigate.

AC6's test: insert several entries via `append_multi/4` normally, then — using a raw
`Repo.query!/3` (or a test-only trigger-disable step, per AC6's own wording) — modify
one persisted `after_state` value directly, leaving `chain_hash`/`prev_chain_hash`
untouched, then assert `verify_chain/2` returns `{:error, {:hash_mismatch, that_id}}`.

## 7. `lua_script_execution_audit` remains separate (AC10)

`lib/letflow/engine/lua_script_audit.ex` (REQ-058/153/158) is a narrow, single-purpose
trail for Lua script executions inside `SERVICE_TASK` nodes — it records an
`instance_id`, an executor-reported `manifest_hash`, and execution outcome, with no
`before_state`/`after_state`/chain concept at all. This requirement's `audit_entries`
table is the general, tenant-wide, resource-typed compliance trail covering
definition/instance/task/identity mutations. **`Letflow.Audit` does not read, write,
call, or get called by `Letflow.Engine.LuaScriptAudit`; `audit_entries` does not
replace or absorb `lua_script_execution_audit`, and no migration in this requirement
touches that table.** This statement is required verbatim-in-substance in
`Letflow.Audit`'s own `@moduledoc` per AC10 (a cross-reference to this design file
alone does not satisfy AC10, same rule as AC7/AC8 — the shipped module must say it,
this file documents the reasoning ELIXIR-DEV copies from).

## 8. No route/controller change (AC11)

This requirement's `artifacts_out` are limited to: `lib/letflow/audit.ex` (new
`Letflow.Audit` context module), `lib/letflow/audit/entry.ex` (new
`Letflow.Audit.Entry` schema), one new tenant-scoped migration (§1/§2), the
`tenant_provisioning.ex` manifest-registration edit (§1), and edits to the covered
context modules (`Letflow.Definitions`, `Letflow.Engine`, `Letflow.Tasks`,
`Letflow.Identity`) to add the `:audit` `Multi` step (§3.2/§4). **No file under
`lib/letflow/routers/` is added or modified** — ELIXIR-DEV's own `git diff --stat`
against this requirement's commits is the AC11 check, run at Step 2a, not deferred to
a later gate. `mix test` and `mix compile --warnings-as-errors` (AC12) are ELIXIR-DEV/
TEST-RUNNER execution-gate concerns, not design elements — no further design content
applies to them beyond ensuring nothing in this design requires a dependency this
codebase doesn't already have (`Jason`, `:crypto`, `Ecto.Multi` are all already used
elsewhere in `lib/letflow/`, confirmed this session).

## 9. Open questions

* **OQ-1 — exact `task.create` call site.** This design names the engine dispatch path
  that inserts the first `tasks` row for a `USER_TASK`/`SERVICE_TASK` node as the
  capture point (§3.2), but does not cite an exact line number in `lib/letflow/engine.ex`
  — ELIXIR-DEV must locate the precise `Repo.insert`/`Multi.insert` call that creates a
  `Task` row during graph advancement and add the `:audit` step there. Not resolved
  here because pinning a line number in a 3000+-line file this design didn't
  exhaustively read end-to-end risks citing a call site that moves before
  implementation lands; the *function-level* location (engine dispatch, not
  `Letflow.Tasks`, which has no create entrypoint) is unambiguous and given above.
* **OQ-2 — user/group/token update coverage completeness.** The requirement's own
  scope list names "user/group/token changes" without enumerating every mutating
  function on `Letflow.Identity`. This design covers `create_user/2`,
  `update_user_status/3`, `update_user_profile/3`, `create_group/2`, `create_token/3`,
  `revoke_token/2` (§3.2) as the representative set matching R-Co's own eight
  trigger-audited tables' identity-side coverage. `add_group_member/3`,
  `remove_group_member/3`, `delete_group/2` are group-*membership*/deletion operations
  the requirement text does not explicitly name; ELIXIR-DEV should audit them too for
  consistency (same `Multi`-step pattern, `action` literals `"group.add_member"`/
  `"group.remove_member"`/`"group.delete"`), but this is a completeness
  recommendation, not a distinct AC — no acceptance criterion names a specific
  Identity function this design must map 1:1, unlike AC2's three named operations.
* **OQ-3 — existing tenants' migration replay.** §1 notes that tenants provisioned
  before this migration lands need a one-off `replay_migrations/2` re-run to gain the
  `audit_entries` table; this design does not specify an operational runbook for that
  (out of scope — REQ-195 is schema+capture+chaining, not an ops procedure), following
  the same precedent every prior tenant-scoped-table-addition requirement in this
  codebase has left to standard deployment practice.
* **OQ-4 — added in rework iteration 1, real `actor_id` for Definitions lifecycle
  operations.** §3.1a decides `actor_id: nil` for `Letflow.Definitions.activate/2`,
  `deprecate/2`, `archive/2`'s audit rows in this requirement's initial cut, because
  the one channel that could supply a real human actor (`conn.assigns.auth_context.user_id`,
  read at the router) requires editing `lib/letflow/routers/definitions.ex`, which
  this requirement's own AC11 forbids. A follow-up requirement — scoped to touch that
  router file — should widen `activate_opts()`/`opts()` with an `actor_id` field
  **and** update `handle_activate/1`, `handle_deprecate/1`, `handle_archive/1`, and
  `handle_delete/2`'s deprecate/archive branch to populate it, together, in the same
  change (widening the type without the router edit, or vice versa, is not a valid
  partial step — either leaves a field nothing populates, or populates nothing new).
* **OQ-5 — added in rework iteration 2, real `actor_id` for six `Letflow.Identity`
  functions.** §3.1b decides `actor_id: nil` for `create_user/2`, `update_user_profile/3`,
  `update_user_status/3`, `create_group/2`, `create_token/3`, `revoke_token/2`'s audit
  rows in this requirement's initial cut, because the only caller of all six —
  `lib/letflow/routers/identity.ex` — would need editing to supply a real actor id
  (and does not even read an actor-identifying assign today), which AC11 forbids. A
  follow-up requirement — scoped to touch that router file — should widen these six
  functions' opts with an `actor_id` field **and** update
  `lib/letflow/routers/identity.ex` to source and populate it, together, in the same
  change, the same atomicity constraint OQ-4 states for Definitions.
