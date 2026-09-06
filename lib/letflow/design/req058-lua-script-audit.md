PROVENANCE (historical, not current decision authority):
# Design: REQ-058 — Lua script execution audit path (`lua_script_audit.zig`, LUA-07)

**Requirement:** REQ-058 (handoff `context.requirement_text`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ058-20260818`, WF-02 Step 1
**This document produces:** the `Letflow.Engine.LuaScriptAudit.AuditRecord` Ecto schema,
the `lua_script_execution_audit` migration spec, the injected `Executor` behaviour
contract, `execute_script_for_audit/N`'s signature and validation ordering, the
manifest-hash-mismatch error shape, invariants, and open questions — **no implementation
code**. No function bodies, no `.ex` files.

---

## 0. Sources read for this design

**Letflow project docs:**

- Handoff `context.requirement_text["REQ-058"]` and `task.acceptance_criteria` (this
  design's sole source for requirement scope — `docs/requirements.yaml` not opened, per
  `core-directives.md`'s "Load Scoped Context, Not Whole Files").
- `docs/guides/backend_developer_guide.md` §2 (project structure), §3.1 (naming), §3.5
  (error shapes), §3.6 (parameterized SQL), §3.7 (migration shape).
PROVENANCE (historical, not current decision authority):
- `docs/migration/stage-3-instance-engine.md` — confirms `lua_script_audit.zig` (201
  lines, R-Co) maps to REQ-058, "LUA-07's minimal audit path," and that S3 covers only
  the non-EE engine files including this one.
- `docs/migration/stage-5-scripting-plugins.md` — confirms `src/lua/` (29 files,
  including `host_api/`) is wholly S5 scope, "not started," and needs its own
  build-vs-bind decision record before any S5 requirement is expanded. This is the
  authority for this design's scope boundary (§1 below).
- `docs/anti-patterns.md` — no entry directly applicable to this module's own
  construction; the migration-numbering-collision entries are noted for Step 2a's
  awareness but don't change this design.

**Letflow shipped code, read directly (not assumed):**

- `priv/repo/migrations/20260818090001_create_promotion_assertion_runs.exs` — concrete,
  current precedent for a schema-per-tenant migration: `if prefix() do ... end` guard,
  `create table(..., primary_key: false, prefix: prefix())`, `add :id, :binary_id,
  primary_key: true`, `create index(..., prefix: prefix())`, header comment naming the
  design doc, the `@tenant_scoped_migration_manifest` registration requirement, and the
  "MUST SORT AFTER" ordering note this design's own migration must carry (§4).
- `lib/letflow/tenant_provisioning.ex` (`@tenant_scoped_migration_manifest`, lines
  283-355 area) — confirms **both halves are mandatory**: a migration file with the
  `if prefix() do` guard that is *not* also added to this manifest is inert forever
  (never selected by `replay_migrations/2`, so a freshly provisioned tenant schema never
  gets the table); the reverse (registered but unguarded) corrupts `public` on a plain
  `mix ecto.migrate` run. This module is **not** in this requirement's `owned_modules`,
  but per `core-directives.md`'s Unblock-Everything rule this addition is a hard
  prerequisite for AC1 ("applying cleanly against a provisioned tenant schema") and must
  be made by ELIXIR-DEV at Step 2a regardless — flagged explicitly here so it is not
  missed as an "unowned file, skip it."
- `lib/letflow/definitions/promotion_assertion_run.ex` and `lib/letflow/engine/task.ex` —
  concrete precedent for the schema-per-tenant `Ecto.Schema` module shape: `@primary_key
  {:id, :binary_id, autogenerate: true}`, no `@schema_prefix` (with the moduledoc stating
  why — every read/write passes `prefix:` explicitly), no `tenant_id` column (Decision
  0006 D2 — the per-tenant Postgres schema boundary alone provides tenant isolation, a
  redundant column was actively *removed* project-wide, most recently by
  `20260820000008_drop_tenant_id_promotion_assertion_runs.exs`), a `read_after_writes:
  true` timestamp field for a DB-defaulted column (`(now() AT TIME ZONE 'utc')`
  fragment), plain `field(:review_id/:instance_id, Ecto.UUID)` rather than `belongs_to`
  for a cross-row reference the module isn't designed to preload.
- `lib/letflow/definitions/service_scope_validator.ex` and its design doc
  `lib/letflow/design/req031-service-scope-validator.md` — REQ-031's injectable-lookup
  precedent. Read in full for the injection *shape* this requirement's text explicitly
  invokes ("exactly the injectable-lookup pattern REQ-031 established"): a caller-passed
  dependency the core function calls through, with no `Application.get_env/2`
  config-resolution and no hardcoded concrete implementation, so a test-double is
  substitutable per call. REQ-031 itself used a struct-of-two-closures rather than a
  `@behaviour`, for reasons specific to its own multi-different-return-value-per-test
  shape (design doc §3.1) — this requirement's own text is more specific and asks for "a
  behaviour with an execute-with-manifest callback" directly, so this design uses a
  `@behaviour` (§3.2 below), not a struct of functions; the *injection* discipline (no
  config resolution, no hardcoded implementation, caller supplies it explicitly) is what
  carries over from REQ-031, not the exact struct-vs-behaviour mechanism.
- `lib/letflow/oidc/token_verifier.ex` — the codebase's other `@behaviour` precedent
  (`@callback verify_bearer_token/2`), read for callback-declaration style (one-line
  `@callback` with a typed input/output spec, PascalCase implementation modules nested or
  sibling). Not reused verbatim: that module is config-resolved
  (`Application.get_env(:letflow, :oidc)[:token_verifier]`), which does not fit this
  requirement's per-call test-double substitution need any better than REQ-031's
  config-avoidance reasoning already established — so this design's `Executor` behaviour
  is passed as an explicit function argument (a module atom implementing the behaviour),
  never read from application config.
- `lib/letflow/design/req063-identity-tables-schema-per-tenant.md` /
  `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` (referenced from
  the schema precedents above, not re-read in full — the "no `tenant_id` column"
  consequence is what this design needs and is already confirmed by the shipped schema
  files themselves).

PROVENANCE (historical, not current decision authority):
**R-Co source of truth**, per the requirement text's own quotation (not independently
re-read — the handoff's `requirement_text` already carries the load-bearing quotation
verbatim): `src/engine/lua_script_audit.zig` (201 lines), its header's narrowness
statement, and its `../lua/executor.zig` / `../lua/manifest.zig` / `../lua/errors.zig`
imports (all `src/lua/`, confirmed S5 scope by `stage-5-scripting-plugins.md`).

---

## 1. Scope boundary

**In scope (this requirement):** one new file, `lib/letflow/engine/lua_script_audit.ex`,
containing:

1. `Letflow.Engine.LuaScriptAudit` — the public module, `execute_script_for_audit/6` (§5).
2. `Letflow.Engine.LuaScriptAudit.AuditRecord` — nested `Ecto.Schema` for
   `lua_script_execution_audit` (§3).
3. `Letflow.Engine.LuaScriptAudit.Executor` — nested `@behaviour`, one `@callback` (§4).

Plus one migration, `priv/repo/migrations/<timestamp>_create_lua_script_execution_audit.exs`
(§6), and the required addition to `lib/letflow/tenant_provisioning.ex`'s
`@tenant_scoped_migration_manifest` (§6.3, not in `owned_modules` but a hard prerequisite
per Unblock-Everything — see §0).

**Explicitly NOT built here, not silently papered over (AC5, AC6):**

PROVENANCE (historical, not current decision authority):
| Not built here | Real dependency | Belongs to |
|---|---|---|
| A real Lua interpreter/host that actually runs a Lua script and produces a manifest hash | `src/lua/executor.zig`, `src/lua/manifest.zig`, `src/lua/errors.zig` — all of `src/lua/` (29 files) | **S5** (scripting & plugins) — `docs/migration/stage-5-scripting-plugins.md` states this stage "has not started" and "needs its own decision record before requirements are expanded: build-vs-bind — Elixir NIFs/Ports/Rustler wrapping existing Lua/WASM runtimes, vs. reimplementing." This design does not choose, imply, or partially pre-build either option. |
| Any `mix.exs` dependency addition (a NIF/Port library, a Lua-in-Erlang package, anything scripting-related) | — | Zero. The `Executor` behaviour (§4) is satisfied entirely by test-doubles until S5 ships a real adapter module. `mix.exs` is not in this requirement's `owned_modules` and this design adds no reason to touch it. |
| The `SERVICE_TASK`-with-script integration described in R-Co's `src/design/lua-integration.md` §25 | — | Unbuilt anywhere yet; per the requirement text, "when it lands, that work supersedes this function rather than building on it." No call site in this design touches `processServiceTaskRuntimeInTx` or any instance-execution flow — `execute_script_for_audit/6` is called only by whatever future admin/audit-triggering path a later requirement builds (none exists yet; this design adds no caller). |
| Any HTTP/Plug route exposing this function | — | Not in scope for any S3 requirement seen so far; no route module is touched. |

**DB schema:** one new table, `lua_script_execution_audit` (§6) — schema-per-tenant, no
`tenant_id` column (Decision 0006 D2 precedent, §0).

---

## 2. Module and file layout

| Module | File | Kind |
|---|---|---|
| `Letflow.Engine.LuaScriptAudit` | `lib/letflow/engine/lua_script_audit.ex` | **New.** Public `execute_script_for_audit/6`. |
| `Letflow.Engine.LuaScriptAudit.AuditRecord` | same file, nested | **New.** `Ecto.Schema` for `lua_script_execution_audit`. |
| `Letflow.Engine.LuaScriptAudit.Executor` | same file, nested | **New.** `@behaviour`, one `@callback`. |

Mirrors `Letflow.Definitions.ServiceScopeValidator`'s file layout (§0): one new file under
the relevant subdirectory (`engine/`, matching `lib/letflow/engine/task.ex`,
`lib/letflow/engine/token.ex`), main logic module plus nested schema/behaviour submodules
in the same file rather than three separate top-level files — this requirement's
`owned_modules` names exactly one `.ex` file, confirming this shape.

---

## 3. `AuditRecord` — the `Ecto.Schema`

```
defmodule Letflow.Engine.LuaScriptAudit.AuditRecord do
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "lua_script_execution_audit" do
    field(:instance_id, Ecto.UUID)
    field(:manifest_hash, :string)
    field(:actor_id, Ecto.UUID)
    field(:executed_at, :utc_datetime_usec, read_after_writes: true)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
```

Field-level detail:

| Field | Type | Null? | Notes |
|---|---|---|---|
| `id` | `:binary_id` | PK, autogenerate | Matches every other tenant-scoped table's PK convention (§0 precedents). |
| `instance_id` | `Ecto.UUID` | `false` | The already-validated (§5 step 1) workflow instance id this execution is attributed to. Plain field, not `belongs_to` — mirrors `PromotionAssertionRun.review_id`/`Task.instance_id`'s own "no preload coupling needed" choice (§0). |
| `manifest_hash` | `:string` | `false` | The **executor-reported** hash — i.e. the value returned by `Executor.execute_with_manifest/2`'s `{:ok, %{manifest_hash: ...}}` on the success path (§5 step 3), which by construction equals the caller-supplied `registered_hash` on every row that gets written (a mismatch never reaches the insert — §5 step 3, AC4). Storing the executor's own reported value (not blindly the caller's `registered_hash` input) is deliberate: it's the actually-verified value, and identical to `registered_hash` on every path that writes a row, so there is no behavioral difference — stated explicitly here rather than left for ELIXIR-DEV to pick either way. |
| `actor_id` | `Ecto.UUID` | `false` | The identity attributed for this execution — see §8 Open Question OQ-1 on whether this should carry a `foreign_key_constraint` against `users.id`. |
| `executed_at` | `:utc_datetime_usec` | `false`, DB-defaulted | `read_after_writes: true`, default `(now() AT TIME ZONE 'utc')` fragment — same pattern as `PromotionAssertionRun.started_at`/`InstanceDefinitionSnapshot.snapshotted_at` (§0). This is **the timestamp** AC2 requires ("instance_id, manifest_hash, actor_id and a timestamp") — a purpose-named column distinct from the bookkeeping `inserted_at`/`updated_at` `timestamps()` pair, so a reader querying "when was this script executed" doesn't have to infer it from row-creation bookkeeping. |
| `inserted_at`/`updated_at` | `:utc_datetime_usec` | via `timestamps/1` | Standard bookkeeping, not read for audit semantics. |

No `tenant_id` column (Decision 0006 D2 — the per-tenant Postgres schema alone provides
isolation; every other table in this codebase had this column actively removed, most
recently `20260820000008_...promotion_assertion_runs.exs`). No `@schema_prefix` — every
`Repo` call passes `prefix: schema_name` explicitly (§5's `opts[:prefix]`), matching
every precedent's own moduledoc note (§0).

**One changeset, `insert_changeset/2`** (structural only, does no I/O — mirrors
`PromotionAssertionRun.insert_changeset/2`'s framing):

```
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```

Casts `[:instance_id, :manifest_hash, :actor_id]`; `validate_required/2` on all three.
`executed_at` is never cast — it is DB-defaulted (`read_after_writes: true`), matching
`PromotionAssertionRun.started_at`'s identical convention. No `unique_constraint` — this
table is a pure append-only audit log (every execution, even a repeat of the same
`instance_id`, gets its own row; unlike `promotion_assertion_runs`' idempotency-key
uniqueness, nothing about "audit trail of what ran" should ever silently collapse two
distinct executions into one row).

---

## 4. `Executor` — the injected behaviour contract

```
defmodule Letflow.Engine.LuaScriptAudit.Executor do
  @type script_ref :: term()
  @type manifest_result :: %{manifest_hash: String.t()}

  @callback execute_with_manifest(script_ref(), registered_hash :: String.t()) ::
              {:ok, manifest_result()} | {:error, term()}
end
```

- **`script_ref/0` is deliberately opaque (`term()`).** S5's build-vs-bind decision
  (`docs/migration/stage-5-scripting-plugins.md`) has not been made, so this design
  cannot know whether a real executor will expect a script body string, a compiled
  bytecode reference, a file path, or something else — pinning a concrete type here
  would silently pre-empt that decision, which the requirement text explicitly forbids
  ("do NOT pre-empt S5's build-vs-bind decision by implicitly choosing a runtime").
  Whatever S5 supplies as its real `Executor` implementation defines what it accepts as
  `script_ref`; `execute_script_for_audit/6` (§5) passes it through unexamined.
- **`registered_hash` is passed to the callback, not just compared after the fact.**
  This lets a real (or test-double) executor short-circuit its own execution if it can
  cheaply detect a mismatch before running anything — but `execute_script_for_audit/6`
  (§5) does **not** rely on the executor doing this; it always independently compares
  the callback's returned `manifest_hash` against the caller-supplied `registered_hash`
  itself (§5 step 3), so a lazy/non-conforming executor implementation cannot bypass the
  mismatch check.
- **Implementations are ordinary modules `use`ing `@behaviour
  Letflow.Engine.LuaScriptAudit.Executor`**, passed to `execute_script_for_audit/6` as a
  plain module atom (§5) — never resolved via `Application.get_env/2`. This is the
  concrete difference from `Letflow.Oidc.TokenVerifier` (§0): that behaviour is
  config-resolved for an environment-wide swap (dev/prod/test); this one is
  call-site-injected so a test can supply a different test-double module (or the same
  module configured with different `Process`/`Agent`-backed state) per test case, exactly
  the substitutability property AC2/AC3/AC4 each require ("a test-double executor").
- **No default/no-op implementation ships in this file.** Exactly like
  `ServiceScopeValidator`'s `Lookup` has no built-in production-ready value (§0), there is
  no `Letflow.Engine.LuaScriptAudit.Executor.Stub` or similar shipped here — TEST-DESIGNER
  builds its own test-double module(s) implementing this behaviour; S5 builds the real
  one.

---

## 5. `execute_script_for_audit/6` — signature and ordering

```
@type error_reason ::
        :invalid_instance_id
        | {:manifest_hash_mismatch, registered_hash :: String.t(), actual_hash :: String.t()}
        | {:executor_failed, term()}
        | {:insert_failed, Ecto.Changeset.t()}

@spec execute_script_for_audit(
        executor :: module(),
        instance_id :: String.t() | nil,
        script_ref :: Executor.script_ref(),
        registered_hash :: String.t(),
        actor_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, AuditRecord.t()} | {:error, error_reason()}
```

`opts` carries `:prefix` (the tenant Postgres schema name) as a **required** key — no
default, matching every other tenant-scoped write path in this codebase (§0's "no
`@schema_prefix`" note); `execute_script_for_audit/6` never guesses or falls back to a
`public`-schema write.

**Ordering (the requirement text's own stated rationale — "the function's entire purpose
is producing an ATTRIBUTABLE audit row, so an unparseable instance_id is rejected up
front rather than after a script has already run"):**

1. **Validate `instance_id` first, before the executor is touched at all.**
   `instance_id` must be a well-formed UUID string (`Ecto.UUID.cast/1` returning `{:ok,
   _}`) and non-`nil`. If validation fails (absent, `nil`, or `Ecto.UUID.cast/1` returns
   `:error`): return `{:error, :invalid_instance_id}` immediately. **`executor` is never
   called on this path** — no `execute_with_manifest/2` invocation occurs, no audit row
   is written. This is the literal AC3 demonstration surface: a test-double `Executor`
   implementation records (via `Agent`/`send`-to-test-process/similar) whether its
   callback was ever invoked, and this design's step-1-before-step-2 ordering is what
   that test asserts against.
2. **Invoke the executor.** Call `executor.execute_with_manifest(script_ref,
   registered_hash)` (the injected module's callback, §4). This is the sole I/O this
   function delegates to something outside itself — no other script-running logic exists
   in this module (mirrors `ServiceScopeValidator`'s "all I/O delegated to the injected
   dependency, treated as opaque" purity note, §0, adapted: this module's own write to
   `Letflow.Repo` in step 3 is its own I/O, not delegated — unlike `ServiceScopeValidator`,
   which does no I/O of its own at all).
   - `{:error, reason}` → return `{:error, {:executor_failed, reason}}` immediately. No
     audit row is written.
3. **Compare the executor's reported hash against `registered_hash` — the
   distinct, pattern-matchable mismatch error (AC4).** On `{:ok, %{manifest_hash:
   actual_hash}}`:
   - `actual_hash != registered_hash` → return `{:error, {:manifest_hash_mismatch,
     registered_hash, actual_hash}}`. **No audit row is written on this path** — this is
     the requirement text's own stated point of the feature ("this is the whole point of
     persisting a manifest hash" — a mismatch must never be silently recorded as if it
     were a normal, trusted execution). The 3-tuple carries both hashes so a caller/test
     can assert on the specific values, not just the fact of a mismatch.
   - `actual_hash == registered_hash` → build `AuditRecord.insert_changeset/2` with
     `%{instance_id: instance_id, manifest_hash: actual_hash, actor_id: actor_id}` and
     `Letflow.Repo.insert(changeset, prefix: opts[:prefix])`.
     - `{:ok, record}` → return `{:ok, record}`.
     - `{:error, changeset}` (a DB-level constraint failure, e.g. a malformed
       `actor_id`/`instance_id` that passed step 1's format check but fails a DB-level
       constraint, or a connection error surfaced as a changeset) → return `{:error,
       {:insert_failed, changeset}}`.

**Demonstration shape for TEST-DESIGNER (prose, not a test itself):**

- AC2: call `execute_script_for_audit/6` with a test-double `Executor` whose
  `execute_with_manifest/2` returns `{:ok, %{manifest_hash: h}}` and a matching
  `registered_hash: h`; assert `{:ok, %AuditRecord{instance_id: ^iid, manifest_hash: ^h,
  actor_id: ^aid}}`, then independently `Repo.get(AuditRecord, id, prefix: schema)` (or
  `Repo.all` count `== 1` scoped to that schema) to confirm exactly one row landed and its
  columns read back as written — not just trusting the function's own return value.
- AC3: a test-double `Executor` module that increments an `Agent`/records a message to
  the test process inside `execute_with_manifest/2`; call
  `execute_script_for_audit/6` with `instance_id: nil` (or a non-UUID string, e.g.
  `"not-a-uuid"`); assert `{:error, :invalid_instance_id}` **and** assert the
  double's call-recorder shows zero invocations.
- AC4: a test-double `Executor` returning `{:ok, %{manifest_hash: "actual-hash"}}`
  against a `registered_hash: "different-hash"`; assert `{:error,
  {:manifest_hash_mismatch, "different-hash", "actual-hash"}}` and assert (via `Repo.all`
  scoped to the tenant schema) that zero rows exist in `lua_script_execution_audit`.

---

## 6. Migration — `lua_script_execution_audit`

**File:** `priv/repo/migrations/20260820000011_create_lua_script_execution_audit.exs`
(next free timestamp after the current tail, `20260820000010_drop_tenant_id_groups.exs` —
ELIXIR-DEV must re-check `ls priv/repo/migrations/ | tail -5` at Step 2a in case a
concurrent run landed a later timestamp first, per the migration-numbering-collision
class `docs/anti-patterns.md` documents).

**Module name:** `Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit`.

### 6.1 Shape (per `promotion_assertion_runs`' precedent, §0)

```
if prefix() do
  create table(:lua_script_execution_audit, primary_key: false, prefix: prefix()) do
    add :id, :binary_id, primary_key: true
    add :instance_id, :binary_id, null: false
    add :manifest_hash, :string, null: false
    add :actor_id, :binary_id, null: false

    add :executed_at, :utc_datetime_usec,
      null: false,
      default: fragment("(now() AT TIME ZONE 'utc')")

    timestamps(type: :utc_datetime_usec)
  end

  create index(:lua_script_execution_audit, [:instance_id],
           name: :idx_lua_script_execution_audit_instance,
           prefix: prefix()
         )
end
```

### 6.2 Column/index rationale

| Column | Type | Null? | Notes |
|---|---|---|---|
| `id` | `:binary_id` | PK | Matches §3. |
| `instance_id` | `:binary_id` | `false` | No FK — `instance_projections`/`tokens`/`tasks` all key on the same `instance_id` UUID space but this table intentionally carries no `references(...)` constraint, since an audit row's purpose (attributing a script execution) must not be blocked by, e.g., a since-completed-and-archived instance no longer having a live projection row; matches this codebase's general pattern of *not* FK-ing audit/event tables back to mutable projection state (`events`/`events_archive` carry no such FK either). |
| `manifest_hash` | `:string` | `false` | No length/format CHECK constraint — unlike `promotion_assertion_runs.plan_digest`'s `validate_length(is: 64)` + hex-format `validate_format`, this design does not assume a specific hash algorithm/digest length, since S5 has not chosen the Lua runtime that produces this value yet (§1's scope boundary). Flagged as §8 OQ-2, not silently pinned to SHA-256-shaped validation. |
| `actor_id` | `:binary_id` | `false` | No FK — see §8 OQ-1. |
| `executed_at` | `:utc_datetime_usec` | `false`, DB default | Matches §3. |

**Index:** `idx_lua_script_execution_audit_instance` on `[:instance_id]` — the
requirement text's own framing ("persisting the resulting manifest_hash to a **queryable**
audit record") names `instance_id` as the natural lookup key (AC1's "queryable" language,
and the everyday query shape: "show me every audited script execution for instance X").
No uniqueness constraint on any column combination — this is a pure append-only log (§3).

### 6.3 Required registration in `tenant_provisioning.ex` (§0 — not `owned_modules`, still mandatory)

Add one entry to `@tenant_scoped_migration_manifest`
(`lib/letflow/tenant_provisioning.ex`), sorted after
`20_260_820_000_010` (the current tail):

```
{20_260_820_000_011, Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit,
 "20260820000011_create_lua_script_execution_audit.exs"}
```

Both the migration file's own `if prefix() do` guard **and** this manifest entry are
required — either alone is insufficient (§0's citation of the "both halves mandatory"
rule, already stated in `promotion_assertion_runs`' own migration header).

---

## 7. Required moduledoc text (AC5, AC6)

Per the requirement text's own framing: *"R-Co's own file header is unusually explicit
about the narrowness, and porting it without carrying that framing across would
misrepresent what ships"* and *"Carry that statement into the Elixir moduledoc verbatim
in substance -- a future reader must not mistake this for the real scripting
integration."* ELIXIR-DEV may add surrounding prose but must not omit the substance of
these two blocks (CODE-DESIGN-VALIDATOR and REVIEWER can check them literally against
the requirement text's own quotation):

**Block 1 — the narrowness statement (AC6), substance of R-Co's own file header:**

```
This module is a MINIMAL, deliberately narrow engine-side call path that (a) invokes an
injected script executor and (b) persists the resulting manifest hash to a queryable
audit record.

It is NOT the SERVICE_TASK script-execution handler and must not be called from
processServiceTaskRuntimeInTx or any other normal process-execution flow. The general
SERVICE_TASK-with-script integration (R-Co's src/design/lua-integration.md section 25)
remains unbuilt; when it lands, that work supersedes this function rather than building
on it.
```

**Block 2 — the S5-deferred scope note (AC5):**

```
The LUA EXECUTION RUNTIME ITSELF is S5 scope (docs/migration/stage-5-scripting-plugins.md).
This module ports only the audit-persistence path, against an injected Executor behaviour
(see Executor below) -- not a real Lua interpreter. mix.exs gains no Lua/NIF dependency
here. S5's own build-vs-bind decision record (Elixir NIF/Port wrapping a real Lua runtime
vs. reimplementing) is a prerequisite for whoever supplies a real Executor implementation;
this module does not pre-empt that choice.
```

Both blocks belong in `Letflow.Engine.LuaScriptAudit`'s top-level `@moduledoc`, not
buried in a function `@doc` — matching how `ServiceScopeValidator`'s own required
moduledoc text (its design doc §7) was verified as present at the module level, not a
function level, by that requirement's CODE-DESIGN-VALIDATOR/REVIEWER pass.

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-LSA-1 | `instance_id` is validated (non-`nil`, well-formed UUID) **before** `executor.execute_with_manifest/2` is ever called. An invalid `instance_id` never results in an executor invocation. | §5 step 1 |
| INV-LSA-2 | A `manifest_hash` mismatch (`actual_hash != registered_hash`) returns a distinct, pattern-matchable `{:manifest_hash_mismatch, registered_hash, actual_hash}` error and writes **no** audit row. | §5 step 3 |
| INV-LSA-3 | Exactly one `AuditRecord` row is written per successful call — the insert happens on exactly one code path (the hash-match branch), never speculatively before the executor/hash-check completes. | §5 step 3 |
| INV-LSA-4 | `mix.exs` gains no new dependency from this requirement. `Executor` is a pure `@behaviour` — no NIF, Port, or external Lua library is referenced anywhere in this module. | §4, §7 Block 2 |
| INV-LSA-5 | No `tenant_id` column on `lua_script_execution_audit` (Decision 0006 D2) — tenant isolation is the Postgres schema boundary alone, via the mandatory `opts[:prefix]`. | §3, §5, §6.1 |
| INV-LSA-6 | `execute_script_for_audit/6`'s `opts[:prefix]` has no default — every call must supply the tenant schema explicitly; there is no "write to `public`" fallback path. | §5 |
| INV-LSA-7 | This module is called from nowhere else in this codebase as of this requirement — no edit to `lib/letflow/engine/instance.ex`-equivalent process-execution code, no new route. | §1, §7 Block 1 |

---

## 9. Open questions — not silently resolved

**OQ-1 (MINOR):** should `actor_id` carry a `foreign_key_constraint`/DB-level
`references(:users, ...)` against the (now schema-per-tenant, per Decision 0006)
`users` table? This design leaves it as a bare `:binary_id` with no FK, since the
requirement text doesn't specify whether every possible actor is necessarily a `users`
row (a future system/service-triggered audit call might not have one) — flagged for
REVIEWER at Step 2d rather than silently deciding either way.

**OQ-2 (MINOR):** `manifest_hash` has no length/format CHECK constraint (unlike
`promotion_assertion_runs.plan_digest`'s SHA-256-shaped `validate_length(is:
64)`/hex-format `validate_format`), because S5's build-vs-bind decision (which
determines what hash algorithm a real Lua manifest hash actually is) has not been made.
Once S5 picks a concrete manifest-hashing scheme, a follow-up migration/changeset
tightening should be considered — not added speculatively here, since guessing the wrong
algorithm's digest length now would require an later migration to loosen or fix a wrong
constraint.

**OQ-3 (MINOR):** whether `execute_script_for_audit/6`'s `script_ref` parameter should be
narrowed to a smaller, better-documented type once a real `Executor` exists is
intentionally left open (§4) — narrowing it now would be exactly the "implicitly
choosing a runtime" the requirement text forbids.

**OQ-4 (MINOR):** no caller/route/CLI entry point that would actually invoke
`execute_script_for_audit/6` in a running system exists yet, anywhere in this design or
the current codebase — this requirement builds the audit-path function and its storage
only, per its own explicit "not the real integration" framing (§7 Block 1). Whichever
future requirement adds a real caller (post-S5, or an S6 admin/ops tool) should re-read
this module's moduledoc narrowness statement before wiring it in, so as not to
accidentally promote this into the "real" SERVICE_TASK script-execution path the
requirement text explicitly disclaims.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Repo` | this design → `Letflow.Repo` | `Repo.insert/2` with `prefix: opts[:prefix]` (§5 step 3). Standard `Ecto.Repo` usage, no new dependency. |
| `lib/letflow/tenant_provisioning.ex` | this design → `TenantProvisioning` | New `@tenant_scoped_migration_manifest` entry (§6.3) — required for `replay_migrations/2` to ever apply this table to a provisioned tenant schema. |
| A future S5 real `Executor` implementation | future S5 → this design | Would `use @behaviour Letflow.Engine.LuaScriptAudit.Executor` and implement `execute_with_manifest/2` against a real Lua host, per whichever build-vs-bind choice S5's own decision record makes. Not built here (§1, §4, §7 Block 2). |
| A future SERVICE_TASK-with-script integration (R-Co `lua-integration.md` §25) | future, unscheduled | Would supersede — not extend — this module, per the requirement text's own framing (§7 Block 1). No dependency exists today. |

---

## 11. Acceptance-criteria traceability

| REQ-058 acceptance criterion | Concrete design element |
|---|---|
| 1. `priv/repo/migrations` gains a `lua_script_execution_audit` migration, schema-per-tenant per REQ-022, applying cleanly against a provisioned tenant schema | §6 (full migration spec, `if prefix() do` guard, `prefix: prefix()` on table/index) + §6.3 (mandatory `tenant_provisioning.ex` manifest registration, without which "applying cleanly against a provisioned tenant schema" is impossible since `replay_migrations/2` would never select it) |
| 2. `execute_script_for_audit` with a test-double executor writes exactly one audit row carrying `instance_id`, `manifest_hash`, `actor_id` and a timestamp, verified by reading the row back | §3 (`AuditRecord` schema, all four fields) + §5 step 3 (single insert path) + §5's AC2 demonstration-shape note (explicit "read the row back independently" check) |
| 3. An unparseable or absent `instance_id` is rejected BEFORE the injected executor is invoked, demonstrated by a test-double that records whether it was called at all | §5 step 1 (validation strictly precedes step 2's executor call) + §5's AC3 demonstration-shape note (call-recorder double) + INV-LSA-1 |
| 4. A manifest hash differing from the supplied `registered_hash` returns a distinct, pattern-matchable mismatch error and writes no audit row | §5 step 3 (`{:manifest_hash_mismatch, registered_hash, actual_hash}`, insert only on the match branch) + INV-LSA-2 + §5's AC4 demonstration-shape note |
| 5. `mix.exs` gains no Lua/NIF dependency, and the moduledoc states that the Lua execution runtime is S5 scope pending `stage-5-scripting-plugins.md`'s build-vs-bind decision record | §7 Block 2 (required verbatim moduledoc text) + INV-LSA-4 + §1's "not built here" table |
| 6. The moduledoc carries R-Co's own narrowness statement in substance: this is not the SERVICE_TASK script-execution handler, must not be called from normal process-execution flow, and will be superseded (not extended) by the real scripting integration when it lands | §7 Block 1 (required verbatim moduledoc text, sourced directly from the requirement text's own quotation) |
