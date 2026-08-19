# Design: REQ-055 — Concurrent instance isolation guarantees (EE-12)

**Requirement:** REQ-055 (stage S3, per this run's handoff `context.requirement_text`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ055-20260819`, WF-02 Step 1
**This document produces:** the moduledoc additions each write-path module needs (AC3),
the concurrency test module(s) to add (AC1/AC2/AC4/AC5), any new test-only fixture
helpers, and the acceptance-criteria-to-design-element map. **No new production code
signatures are introduced by this requirement** — see Finding below and §0.1. No
implementation code appears in this document — signatures, moduledoc-content
descriptions, and test-case descriptions only.

---

## 0. Sources read for this design

- This run's handoff — `context.requirement_text` (REQ-055's full description) and
  `task.acceptance_criteria`.
- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's procedure.
- `docs/guides/backend_developer_guide.md`.
- `docs/anti-patterns.md` — the Docker-based Postgres verification path ("No
  Elixir/mix toolchain on PATH in this sandbox" entry), the "Running `docker compose up`
  from a secondary worktree checkout" entry (this run's worktree must NOT run
  `docker compose up`; Postgres is already running, shared with the primary checkout).
- `docs/migration/stage-3-instance-engine.md` — the two Early findings this requirement
  is scoped by name to ("idiomatic OTP, confirmed" / "process-per-instance's actual
  value, and its limits"), and the "REQ-046 and REQ-055 hold the first finding's bar
  concretely" sentence (L217-220) that names this requirement specifically as the one
  that verifies real supervised isolation wherever REQ-045 resolved to a process.
- `lib/letflow/engine.ex` (full, current `main`) — read directly to resolve the
  process-vs-row question (§1 below), and to enumerate every `lock("FOR UPDATE")` call
  site across `create/2`, `complete_task/3`, `cancel_instance/3` (§2 below).
- `lib/letflow/instance_supervisor.ex` (full) — confirms it supervises zero children
  today.
- `lib/letflow/event_store.ex` — `assign_sequence/3`'s own `FOR UPDATE` lock on
  `InstanceSequence` (§2.4 below; in `complete_task/3`'s and `create/2`'s write path via
  `EventStore.append/2`, so in scope for AC3 even though `EventStore.append/2` itself was
  not one of REQ-045/047/048/052's own deliverables).
- `lib/letflow/engine/task_activation.ex` — confirms no additional lock acquisition
  beyond what `Ecto.Multi.run` steps already inherit from the enclosing transaction
  (§2.5 below).
- `lib/letflow/engine/reconstruction.ex` — `reconstruct_instance/2`'s existing
  `@spec`, used unmodified by AC4's design (§4 below); confirms it is read-only by
  default (INV-RC-1) and never touches `instance_projections` except opt-in
  `write_back` (irrelevant here — the design does not set `write_back: true`).
- `test/letflow/engine_complete_task_test.exs` (full) — the established
  `provisioned_tenant/0` + `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` +
  `async: false` fixture pattern this design reuses for the new concurrency test file
  (§3.1 below), plus its graph/definition/task fixture helpers, reused rather than
  reinvented.
- `test/support/tenant_slug.ex`, `test/support/data_case.ex` — the two sandbox-mode
  options actually available in this codebase, and why `:auto` (not `Letflow.DataCase`'s
  default `{:shared, self()}`) is the one that supports real cross-process concurrency
  (§3.1 below).
- `docs/requirements.yaml` — read only the REQ-053 entry (`depends_on`), to confirm
  `Letflow.Engine.Reconstruction.reconstruct_instance/2`'s status is `done` and its
  signature matches what `reconstruction.ex` ships.

---

## 1. Finding: REQ-045 resolved to row-based state, not a supervised process

**This is a plain transactional context module (`Letflow.Engine`), not a
`:gen_statem`/`DynamicSupervisor`-per-instance design.** Confirmed directly from
`lib/letflow/engine.ex`'s own moduledoc ("Process-vs-row decision (AC5, AC6)" section):

> "Whether a running instance is a supervised `:gen_statem` process or a plain
> transactional context module was this stage's largest open design question ...
> This module resolves it for EE-01's own scope only: `create/2` is a plain function,
> no process."

And from `lib/letflow/instance_supervisor.ex`'s own moduledoc:

> "Currently supervises no children. REQ-045 resolved the S3 running-instance shape to
> a plain transactional context module (`Letflow.Engine.create/2`), not a supervised
> process, so there is nothing for this supervisor to own yet ... `start_instance/1` was
> removed by REQ-046 alongside `Letflow.ProcessInstance`'s own deletion (its only
> caller)."

`README.md`'s "What's here today" section corroborates: "`Letflow.InstanceSupervisor` is
retained, with `start_instance/1` removed, reserved for REQ-056/057." REQ-047, REQ-048,
and REQ-052 (`complete_task/3`, `cancel_instance/3`) all build on the same
`Letflow.Engine` row/`Ecto.Multi` shape `create/2` established — none of them introduces
a process either (confirmed by their own moduledoc sections in `lib/letflow/engine.ex`,
read in full for this design; no `GenServer`/`:gen_statem`/`DynamicSupervisor.start_child`
call appears anywhere in `lib/letflow/engine.ex` or `lib/letflow/engine/task_activation.ex`
— the two modules REQ-045/047/048/052's own write paths actually live in). This does
**not** extend to every file under `lib/letflow/engine/*.ex` as a wildcard claim:
`lib/letflow/engine/plugin_registry.ex` (`Letflow.Engine.PluginRegistry`) is `use
GenServer` — a real singleton process. It is out of scope for this finding and for
AC3's lock inventory (§2) on purpose, not by oversight: it is REQ-057's plugin
registry, not one of REQ-045/047/048/052's per-instance write paths (REQ-055's own
scope, per its description, is explicitly "the engine paths REQ-045/047/048/052
build"), and it holds no `instance_id`-scoped row lock at all — it is a registry
lookup process, not a `Repo.transaction/1` participant. Its existence does not weaken
the row-based finding for `create/2`/`complete_task/3`/`cancel_instance/3` themselves,
which still resolve to zero processes per their own moduledoc text quoted above.

**Consequence for this requirement's own acceptance criteria:**

- **AC5 is NOT APPLICABLE.** There is no per-instance process to kill. The
  supervised-isolation half of REQ-055's own description text ("If REQ-045 resolved to
  supervised processes, this requirement also verifies supervised isolation
  concretely... If REQ-045 resolved to row-based state, state that this half is not
  applicable rather than silently skipping it") is satisfied by this finding plus the
  moduledoc statement in §2.6 below — not by a process-kill test, because no such
  process exists to kill.
- Isolation for row-based state instead rests entirely on **row-level locking
  discipline** (§2) plus **schema-level scoping** (`instance_id`/`token_id`/`task_id`
  foreign keys, tenant-schema-per-tenant `prefix`) — this is exactly what AC1-AC4 test.
- `stage-3-instance-engine.md`'s "REQ-046 and REQ-055 hold the first finding's bar
  concretely — real supervised isolation via a `DynamicSupervisor`" sentence describes
  the *general* stage-3 bar (applicable when a later requirement, e.g. REQ-056/REQ-057,
  does introduce a process); it does not assert REQ-045 itself produced a process. This
  is a distinction worth flagging explicitly (see §6 Open Questions) since a literal
  reading of that one sentence in isolation could be misread as requiring a process-kill
  test today.

---

## 2. AC3 — moduledoc additions naming every lock acquisition and its scope

AC3 requires: "No global or table-level lock is held across instance boundaries anywhere
in the engine's write paths — confirmed by inspecting every lock acquisition in
REQ-045/047/048/052's code and naming each one's scope in the moduledoc."

### 2.1 Every lock acquisition found (inspected directly, `lib/letflow/engine.ex` +
`lib/letflow/event_store.ex`, current `main`)

| # | Function (module) | Lock statement | Table locked | Filter (scope) | Scope classification |
|---|---|---|---|---|---|
| L1 | `fetch_and_lock_task/3` (`Letflow.Engine`, `complete_task/3`) | `lock("FOR UPDATE")` | `tasks` | `where t.id == ^task_id` | **single-row** — exactly the one `tasks` row named by `task_id`, which FK-scopes to exactly one `instance_id` |
| L2 | `fetch_and_lock_instance_projection/3` (`Letflow.Engine`, `complete_task/3`) | `lock("FOR UPDATE")` | `instance_projections` | `where p.instance_id == ^instance_id` | **single-row** — exactly the one projection row for this instance |
| L3 | `fetch_and_lock_open_tasks/3` (`Letflow.Engine`, `cancel_instance/3`) | `lock("FOR UPDATE")` | `tasks` | `where t.instance_id == ^instance_id and t.status == :pending`, `order_by asc: t.id` | **row-set, single-instance** — every row this query locks carries the same `instance_id`; deterministic `order_by` prevents a lock-ordering deadlock against a concurrent multi-row locker on the same instance, never touches another instance's rows |
| L4 | `fetch_and_lock_instance_projection_for_cancel/3` (`Letflow.Engine`, `cancel_instance/3`) | `lock("FOR UPDATE")` | `instance_projections` | `where p.instance_id == ^instance_id` | **single-row** — same shape as L2, scoped to this instance only |
| L5 | `fetch_and_lock_live_tokens/3` (`Letflow.Engine`, `cancel_instance/3`) | `lock("FOR UPDATE")` | `tokens` (`TokenRecord`) | `where t.instance_id == ^instance_id and t.status in [:active, :waiting]`, `order_by asc: t.id` | **row-set, single-instance** — same shape as L3, scoped to this instance's own tokens only |
| L6 | `lock_and_increment_sequence/3` (`Letflow.EventStore`, called by `EventStore.append/2` — reached from every `create/2`/`complete_task/3`/`cancel_instance/3` event append) | `lock("FOR UPDATE")` | `instance_sequences` (`InstanceSequence`) | `where s.instance_id == ^instance_id` | **single-row, single-instance** — the row is keyed 1:1 by `instance_id` (`on_conflict: :nothing, conflict_target: :instance_id` on the preceding insert-if-absent step); a concurrent `EventStore.append/2` call for a *different* `instance_id` locks a disjoint row and is never blocked by this one |

`create/2` (REQ-045/EE-01) itself acquires **no `lock("FOR UPDATE")` at all** in
`lib/letflow/engine.ex` — its own `Ecto.Multi` (`persist/8`) only `Multi.run(:instance_projection, ...)` inserts a brand-new row (no prior row to lock; a fresh `instance_id` cannot collide with any concurrent operation except via the `uq_instance_correlation` unique index, which is a constraint, not a lock) and inserts fresh `tokens`/`tasks` rows the same way. `create/2`'s only shared contention point is L6, reached transitively via its own `INSTANCE_STARTED` event append.

`lib/letflow/engine/task_activation.ex` (REQ-047, `append_multi/5` and
`append_multi_from_existing_records/6`) acquires **no lock of its own** — every step it
contributes runs as an `Ecto.Multi.run/3` step inside the caller's (`create/2`'s or
`complete_task/3`'s) already-open transaction, operating only on rows already
locked/owned by that same transaction (freshly-inserted `tasks` rows it is itself
inserting, or a `token_id` already resolved by the caller). No new lock acquisition
site to document for this module.

### 2.2 No global or table-level lock anywhere (AC3's core claim)

Every lock in §2.1 is acquired via a `where` clause keyed on `instance_id` (directly, or
transitively via `task_id`/`token_id` FK-scoped to one `instance_id`) — Postgres's
`SELECT ... FOR UPDATE` locks exactly the row(s) the query's `WHERE` clause matches, not
the table. None of L1-L6 omits a `where`, and none locks by any column that could span
more than one instance (e.g. no lock keyed on `tenant_id`, `definition_id`, or
unconditional table scan). **No `Repo.transaction/1` call in `lib/letflow/engine.ex` or
`lib/letflow/event_store.ex` locks any row outside the `instance_id` it was given.**
Cross-instance operations (e.g. `Task.async` bodies for two different `instance_id`s in
the AC4 test, §3.4 below) therefore never contend on the same lock and can commit fully
in parallel, gated only by ordinary Postgres MVCC and connection-pool concurrency — never
by a Letflow-side mutex, singleton `GenServer`, or table lock. Confirmed absent from
every module actually in REQ-045/047/048/052's write paths — `lib/letflow/engine.ex`,
`lib/letflow/engine/task_activation.ex`, `lib/letflow/event_store.ex` — no `:global`, no
`Registry`-backed singleton, no `Mutex`/`:mutex` dependency, no `LOCK TABLE`, no
`GenServer`/`:gen_statem`/`DynamicSupervisor.start_child` call anywhere in those three
files, `grep`-confirmed during this design's own source reading. **This does not extend
to every file under `lib/letflow/engine/*.ex`**: `lib/letflow/engine/plugin_registry.ex`
(`Letflow.Engine.PluginRegistry`, REQ-057) is `use GenServer` — a real singleton
process. It is correctly out of scope for this claim and for AC3's lock inventory
(§2.1-§2.2 below): it is REQ-057's plugin registry, not one of REQ-045/047/048/052's
per-instance write paths, it holds no `instance_id`-scoped row lock at all (it is a
registry lookup process, not a `Repo.transaction/1` participant), and REQ-055's own
scope (per its description) is explicitly the engine paths REQ-045/047/048/052 build,
not REQ-057. Its existence does not weaken §1's row-based finding for `create/2`/
`complete_task/3`/`cancel_instance/3` — those three functions still resolve to zero
processes, confirmed directly from their own moduledoc text quoted above — but it means
"no process anywhere under `lib/letflow/engine/`" would be a false, broader claim than
this design actually needs or makes.

### 2.3 Lock ordering (deadlock-avoidance note, restated here since AC3 asks for
"scope," and the *order* two locks are acquired in is part of why cross-instance
contention stays zero even for the SAME-instance case AC2 exercises)

`complete_task/3` always locks `tasks` (L1) before `instance_projections` (L2).
`cancel_instance/3` always locks `tasks` (L3) before `instance_projections` (L4) before
`tokens` (L5) — `Letflow.Engine`'s own moduledoc for `cancel_instance/3` already states
this explicitly ("locked before `instance_projections`, matching `complete_task/3`'s own
global lock-ordering rule"). This ordering is same-instance-scoped already (both locks
in any given call carry the same `instance_id`), so it is a same-instance
deadlock-avoidance discipline, not a cross-instance one — restated here because AC2's
test (§3.3) is exactly the scenario ("two concurrent task completions on the SAME
instance") this ordering rule protects.

### 2.4 Moduledoc additions to write (documentation only — no code changes)

Two moduledoc sections, both inside `lib/letflow/engine.ex` (the only module needing an
addition — `event_store.ex`'s `assign_sequence/3` already documents its own lock inline
per §2.1's L6 finding above, and `task_activation.ex` needs no addition since it
acquires no lock of its own, per §2.1):

1. **New subsection under `Letflow.Engine`'s existing moduledoc, titled `## EE-12
   (REQ-055) — lock inventory and cross-instance isolation`.** Placed after the existing
   `cancel_instance/3` section (end of the moduledoc, preserving the moduledoc's existing
   one-section-per-requirement structure). Content: restates the L1-L6 table from §2.1
   in prose (function name, table, filter, single-row-vs-row-set-vs-table-vs-global
   classification), plus the §2.2 "no global/table lock" claim and the §2.3 lock-ordering
   note, plus one sentence naming this design doc and the new test file (§3) as where the
   claim is verified under real concurrency rather than by code reading alone.
2. No changes needed to `complete_task/3`'s or `cancel_instance/3`'s own `@doc` strings
   — both already state their own lock's scope correctly (quoted in this document's §0
   source list); AC3's "naming each one's scope in the moduledoc" is satisfied by the
   new `Letflow.Engine`-level subsection consolidating all six sites in one place, not by
   duplicating the same statement redundantly into each function's own `@doc` a second
   time.

### 2.5 `task_activation.ex` moduledoc addition

None required, per §2.1's finding that it acquires no lock of its own. If
ELIXIR-DEV's implementation finds this module *does* acquire a lock not visible from
this design's own reading of current `main` (e.g. a future rebase introduces one), flag
it back to CODE-DESIGNER rather than silently documenting it inline — do not resolve
this design's own §2.1 finding by guessing at implementation time.

### 2.6 AC5 statement — where it goes

The row-based finding (§1) and its AC5 "not applicable" statement belong in the same new
`## EE-12 (REQ-055) — lock inventory and cross-instance isolation` moduledoc subsection
(§2.4 item 1), as its closing paragraph: one sentence stating REQ-045 resolved to
row-based state (citing this design doc §1), therefore AC5's supervised-process-kill
scenario does not apply to any of `create/2`/`complete_task/3`/`cancel_instance/3`, and
isolation instead rests on the row-locking discipline this same subsection documents.

---

## 3. Concurrency test module(s)

### 3.1 File and fixture pattern

**New file: `test/letflow/engine_concurrency_test.exs`** (module
`Letflow.EngineConcurrencyTest`), `use Letflow.DataCase, async: false`, mirroring
`test/letflow/engine_complete_task_test.exs`'s exact established pattern — not
`Letflow.DataCase`'s own default setup, which checks out a *single* sandboxed connection
per test and (for `async: false` tests) puts it in `{:shared, self()}` mode. Shared mode
routes every DB call from every process back through the one checked-out connection,
serializing all of them through a single connection-level lock — that would make
`Task.async` bodies queue behind each other regardless of what Postgres-level row
locking is or isn't held, defeating the entire point of AC1/AC4 (proving genuine
cross-instance parallelism) and corrupting AC2's own "run concurrently, not
sequentially" requirement (a shared-mode sandbox would serialize the two
`complete_task/3` calls at the connection layer before either reaches Postgres, so the
test would never actually exercise L1/L2's row lock — it would pass for the wrong
reason).

**Design decision: this test file's `provisioned_tenant/0` fixture calls
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`** immediately, exactly as
`engine_complete_task_test.exs`'s own `provisioned_tenant/0` already does. `:auto` mode
takes every connection in `Letflow.Repo`'s pool out of sandbox/rollback semantics
entirely — each `Task.async` body checks out its own ordinary pooled connection and
commits for real, so `Task.async`/`Task.await_many` bodies genuinely run concurrently
against real Postgres with real row-level locks in effect, which is exactly what AC1's
"real Postgres" and AC2's "run concurrently rather than sequentially" require. The
tradeoff (real, non-rolled-back commits) is already accepted precedent in this codebase
(`test/support/tenant_slug.ex`'s own moduledoc documents exactly this tradeoff and its
cleanup discipline) — this file's `on_exit` callback must therefore do real cleanup
(`DROP SCHEMA ... CASCADE` for the tenant schema, `Repo.delete_all` for the `Tenant`/
`Registration` rows), not rely on sandbox rollback, matching
`engine_complete_task_test.exs`'s own `on_exit` block verbatim in shape.

`async: false` at the `ExUnit.Case` level (this file does not run concurrently with
other *test files* — `:auto` mode is global per `Letflow.Repo`, so two `async: true`
test files both flipping it at the same time would race each other's mode). This
matches `engine_complete_task_test.exs`'s own `async: false` choice for the identical
reason.

### 3.2 Reused fixtures (no new signatures — same shapes as `engine_complete_task_test.exs`)

- `insert_tenant!/0`, `drop_schema!/1`, `provisioned_tenant/0` — copied with the same
  signatures and bodies as `engine_complete_task_test.exs`'s own (that file's own
  moduledoc states each test file provisions its own tenant schema rather than sharing
  fixtures — this file follows the same "no test pollution" convention, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-4, restated there).
- `register_task_completed_event_type!/1` — copied unchanged (same `TASK_COMPLETED`
  permissive-schema registration `complete_task/3`'s own event append requires).
- `active_definition!/2`, `create_definition_attrs/1`, `graph_human_task_end/0` — copied
  unchanged from `engine_complete_task_test.exs` (the plainest
  `START -> task(HUMAN_TASK) -> END` graph; sufficient for every test case below, none
  of which needs gateway/parallel-split structure).
- `start_attrs/2`, `complete_attrs/1`, `unique_name/1`, `unique_idempotency_key/1` —
  copied unchanged.

### 3.3 New test-only fixture: `start_n_instances!/3`

A concurrency-specific fixture not present in `engine_complete_task_test.exs` (which
only ever starts one instance per test) — needed by AC1/AC4's "100 distinct instances"
setup.

```
@spec start_n_instances!(schema_name :: String.t(), definition :: Definitions.Definition.t(), n :: pos_integer()) ::
        [%{instance_id: Ecto.UUID.t(), task_id: Ecto.UUID.t()}]
```

Behavior (description, not code): calls `Engine.create/2` sequentially `n` times against
the same already-`active_definition!/2`-provisioned `definition` (each call gets its own
`unique_idempotency_key/1` and `start_attrs/2`), asserts `{:ok, result}` each time,
reads back the single `:pending` `Letflow.Engine.Task` row for that `instance_id`
(`Repo.all(EngineTask, prefix: schema_name) |> Enum.filter(&(&1.instance_id ==
result.instance_id))` — filtered, since by the time this runs for instance 50, the
`tasks` table already holds 49 other instances' own pending rows), and returns the list
of `%{instance_id: ..., task_id: ...}` maps. Sequential (not itself concurrent) — this
fixture is 100 ordinary, uncontended `create/2` calls setting up the fixture state; the
concurrency under test is the *task completion* step (AC1/AC4), performed separately by
`Task.async`.

### 3.4 Test cases

All four cases below live in `test/letflow/engine_concurrency_test.exs`. AC5's
process-kill case is **omitted, not skipped-and-unlabeled** — its absence is explained
by a `@moduledoc` paragraph in this test file itself (not just this design doc) stating
the §1 finding and cross-referencing this design doc's §1/§2.6, so a future reader of
the test file alone (without this design doc open) still sees why no such test exists.

**Case AC1 — `describe "AC1 -- 100 concurrent task completions across 100 distinct instances"`**

- Setup: `provisioned_tenant/0`, `active_definition!/2` with `graph_human_task_end/0`,
  `start_n_instances!/3` with `n: 100` — 100 instances, each with exactly one `:pending`
  task on the same `"task"` node_id, each on its own `instance_id`.
- Action: `instances |> Enum.map(fn %{task_id: task_id} -> Task.async(fn ->
  Engine.complete_task(task_id, complete_attrs(), prefix: schema_name) end) end) |>
  Task.await_many(30_000)` — one `Task.async` per instance, all launched before any
  `await`, so the 100 calls genuinely overlap in-flight rather than running one at a
  time.
- Assertions:
  - Every result in the awaited list matches `{:ok, %{instance_status: :completed}}` —
    zero deadlock (an actual Postgres deadlock surfaces as `{:error, %Postgrex.Error{...
    postgres: %{code: :deadlock_detected}}}` inside the `Ecto.Multi` result, which would
    fail this pattern match) and zero task rejected as `:task_not_pending` (which would
    indicate the 100 completions were not actually isolated onto 100 distinct rows).
  - Cross-instance corruption check: for each of the 100 `instance_id`s, re-read its
    `InstanceProjection` and assert `projection.variables` contains only that instance's
    own `output_variables` merge result (each `Task.async` body uses a distinct,
    instance-tagged `output_variables` map, e.g. `%{"instance_seed" => instance_id}`, so
    a cross-instance write would show up as instance A's projection holding instance B's
    tag) and `projection.status == :completed`.
  - No-cross-contention (portable proxy for "no global lock," since asserting on
    Postgres's internal lock table is not portably assertable from ExUnit): assert
    total wall-clock time for the `Task.await_many/2` call is `< `some multiple (e.g.
    3x) of a single, independently-measured `complete_task/3` call's own wall-clock time
    against a freshly-started 101st instance measured immediately before the concurrent
    batch — a single cross-instance mutex/singleton-GenServer/table-lock design would
    make total time scale roughly linearly with the number of instances (each
    completion queued behind the previous one), while genuine per-row locking allows
    them to overlap; this assertion is deliberately loose (a multiple, not a tight
    bound) to avoid CI flakiness from ordinary scheduler/connection-pool variance, while
    still failing decisively against an accidentally-reintroduced global serialization
    point (which would show close to 100x, not ~1-3x).
- This is AC1's own literal "real Postgres, actual test output quoted" requirement —
  TEST-RUNNER's Step 4 report and RELEASE-VALIDATOR's Step 5 re-run both quote this
  test's actual `mix test` output per `docs/anti-patterns.md`'s Docker-based
  verification path if no local toolchain is available.

**Case AC2 — `describe "AC2 -- two concurrent task completions on the SAME instance"`**

- Setup: `provisioned_tenant/0`, `active_definition!/2` with `graph_human_task_end/0`,
  `start_instance_with_pending_task!/2` (single instance, single pending task —
  reused unchanged from `engine_complete_task_test.exs`).
- Action: **both** `complete_task/3` calls launched via `Task.async` against the
  **same** `task_id`, both started before either is awaited (`[Task.async(fn ->
  Engine.complete_task(task_id, complete_attrs(...), prefix: schema_name) end), Task.async(fn
  -> Engine.complete_task(task_id, complete_attrs(...), prefix: schema_name) end)] |>
  Task.await_many(5_000)` — genuinely concurrent, not `t1 = Task.async(...); Task.await(t1);
  t2 = Task.async(...)`, which REQ-055's own acceptance text explicitly calls out as
  insufficient ("run concurrently rather than sequentially").
- Assertions: exactly one of the two results matches `{:ok, %{instance_status:
  :completed}}` and the other matches `{:error, {:task_not_pending, :completed}}` (L1's
  `FOR UPDATE` lock is what serializes the two transactions onto this outcome — the
  first to acquire the lock commits `:completed`, the second's own `fetch_and_lock_task/3`
  re-reads the now-`:completed` row after the first transaction commits and returns the
  typed conflict per `Letflow.Engine`'s own `complete_task/3` moduledoc, already quoted in
  §0). `Enum.count(results, &match?({:ok, _}, &1)) == 1` and
  `Enum.count(results, &match?({:error, {:task_not_pending, :completed}}, &1)) == 1`.
  Also asserts exactly one `TASK_COMPLETED` event exists for the instance afterward
  (`task_completed_events/2`, reused from `engine_complete_task_test.exs`) — the losing
  call must not have appended a duplicate/partial event.

**Case AC4 — `describe "AC4 -- reconstruction matches projection for all 100 instances after the concurrent run"`**

- Depends on AC1's own 100-instance concurrent completion having run (either as a
  `setup` shared with the AC1 `describe` block via a common private helper
  `provision_and_complete_100!/1` returning the schema_name/instance list, or as its own
  independent 100-instance setup+run — **design leaves this as an implementation choice
  for TEST-DESIGNER**, not an open question requiring resolution here, since both shapes
  satisfy AC4's actual assertion; flagged only so ELIXIR-DEV/TEST-DESIGNER doesn't need
  to guess whether reuse is required).
- Action: for each of the 100 `instance_id`s, call `Letflow.Engine.Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)` (REQ-053, unmodified — this design adds no
  new call shape).
- Assertions, per instance (per `reconstruction.ex`'s own documented "what 'same tokens'
  means for AC1" — reused terminology, not this requirement's own AC1, to avoid
  confusion, this design calls it "the reconstruction module's own AC1" when citing it):
  - `{:ok, %{instance_state: instance_state}} = reconstruct_instance(...)`
  - The reconstructed `instance_state.status` matches the live `InstanceProjection.status`
    for that same `instance_id`.
  - The reconstructed `instance_state.variables` matches the live projection's
    `variables` exactly — this is the specific check that proves no instance absorbed
    another's variables (AC4's literal "matching its own projection" text): if
    instance A's reconstruction ever showed instance B's `"instance_seed"` tag (AC1's
    own fixture, §3.4 above), this assertion catches it.
  - The reconstructed token positions (`instance_state.tokens` node-id multiset) match
    the live projection's `current_nodes` — proves no instance absorbed another's token
    positions.
  - This loop is the concrete verification for AC4's "every one of the 100 instances
    reconstructs ... to a state matching its own projection" text — run once per
    instance rather than once in aggregate, so a single corrupted instance among the 100
    fails with that instance's own `instance_id` visible in the assertion failure,
    not merely "some instance somewhere failed."

**Case AC5 — omitted, documented as N/A** (§1, §3's own opening paragraph). No test
case. The `@moduledoc` of `test/letflow/engine_concurrency_test.exs` states this
explicitly, per REQ-055's own text ("state that this half is not applicable rather than
silently skipping it") and per this project's "no acceptance criterion left
unaddressed... no 'TBD'" design-gate rule — the *design element* satisfying AC5 is this
stated moduledoc paragraph plus §1/§2.6 of this document, not a test.

### 3.5 Timeouts

`Task.await_many/2`'s default timeout (5000ms) is almost certainly too tight for a
100-way concurrent AC1 case against a real (not in-memory) Postgres instance under
Docker — this design specifies an explicit `30_000`ms timeout for AC1's
`Task.await_many/2` call (§3.4) and leaves AC2's two-way case at a shorter explicit
`5_000`ms (still generous for two calls). If TEST-RUNNER's actual run needs a different
value, that is a test-tuning decision within TEST-DESIGNER's/TEST-RUNNER's own latitude,
not a design change — noted here only so the initial value isn't invented ad hoc without
rationale.

---

## 4. Acceptance criteria → design element map

| AC | Text (summary) | Design element |
|---|---|---|
| AC1 | 100 concurrent task completions across 100 distinct instances, no deadlock/corruption, real Postgres, actual output quoted | §3.4 Case AC1 (`describe "AC1 -- 100 concurrent..."` in `test/letflow/engine_concurrency_test.exs`), using `start_n_instances!/3` (§3.3) and the `:auto`-sandbox `provisioned_tenant/0` (§3.1) against real Postgres per `docs/anti-patterns.md`'s Docker path |
| AC2 | Two concurrent completions on the SAME instance: exactly one success, one conflict, run concurrently not sequentially | §3.4 Case AC2, both `Task.async` calls launched before either is awaited, asserting the exact `{:ok,...}`/`{:error,{:task_not_pending,:completed}}` split, backed by L1's `FOR UPDATE` lock (§2.1) |
| AC3 | No global/table lock across instance boundaries anywhere in REQ-045/047/048/052's write paths; every lock's scope named in the moduledoc | §2.1 lock inventory (L1-L6), §2.2 no-global/table-lock finding, §2.3 lock-ordering note, §2.4 moduledoc placement/content (new `Letflow.Engine` moduledoc subsection), §2.5 (`task_activation.ex` needs no addition — no lock of its own) |
| AC4 | After the concurrent run, all 100 instances reconstruct to a state matching their own projection | §3.4 Case AC4, per-instance `reconstruct_instance/2` call + status/variables/token-position comparison against that same instance's own `InstanceProjection` |
| AC5 | If REQ-045 resolved to processes: kill-one-instance test. If row-based: state N/A explicitly | §1 Finding (row-based, confirmed from `engine.ex`/`instance_supervisor.ex`/`README.md` moduledocs), §2.6 (moduledoc placement of the N/A statement), §3.4 Case AC5 (test file's own `@moduledoc` states N/A — no test written) |

No acceptance criterion is left as "TBD" or silently resolved.

---

## 5. Cross-module dependencies

- `Letflow.Engine.create/2`, `complete_task/3`, `cancel_instance/3` — read, not
  modified (this requirement adds documentation only, per §2.4/§2.5 — flagged again
  here since "cross-module dependencies" conventionally lists modules a design
  *changes*; this design changes exactly one, `lib/letflow/engine.ex`'s moduledoc text,
  and touches zero others).
- `Letflow.Engine.Reconstruction.reconstruct_instance/2` (REQ-053, `done`) — called
  unmodified by the new AC4 test.
- `Letflow.EventStore.append/2` / `assign_sequence/3` (§2.1 L6) — read-only reference
  for the lock inventory; not modified.
- `Letflow.Engine.TaskActivation` — read-only reference (§2.1, §2.5); not modified.
- `Letflow.DataCase`, `Letflow.TenantProvisioning`, `Letflow.TenantSlugFixture` — reused
  test-support modules, unmodified.
- `test/letflow/engine_complete_task_test.exs` — fixture-pattern source (§3.1-3.2);
  this design's new test file does not `import`/share code with it directly (matching
  that file's own "no test pollution... each test file provisions its own tenant
  schema" convention) — it *copies* the same fixture shapes, per that file's own stated
  precedent, not a shared helper module. If ELIXIR-DEV/TEST-DESIGNER judges a shared
  `test/support/engine_fixtures.ex` extraction is warranted instead (three now-similar
  files: `engine_test.exs`, `engine_complete_task_test.exs`, and this new one), that is
  a legitimate simplification within their own discretion — not required by this design,
  and not a scope change either way since the fixture *shapes* are unchanged.

---

## 6. Open questions

1. **Stage-3 doc's "REQ-046 and REQ-055 hold the first finding's bar concretely — real
   supervised isolation via a `DynamicSupervisor`" sentence** (`stage-3-instance-engine.md`
   L217-220) reads, in isolation, as if it expects REQ-055 to demonstrate supervised
   isolation. §1 above resolves this as describing the *general* stage-3 bar (satisfied
   today by REQ-046's retirement of the old `ParallelApproval`/`ApprovalSupervisor` split
   plus `InstanceSupervisor`'s retained-for-later shape), not a mandate that REQ-055
   itself must exercise a process that REQ-045 never created. This design does not
   silently resolve the tension by ignoring it — flagging it explicitly for
   CODE-DESIGN-VALIDATOR and REVIEWER to confirm this reading is correct, since it
   affects whether AC5's test is legitimately omittable. If CODE-DESIGN-VALIDATOR
   disagrees, the correct fix is a `docs/migration/decisions/000x-*.md` draft
   reconciling the stage doc's wording with REQ-045's actual resolution — not a
   test written against a process that does not exist.
2. **AC1's wall-clock "no global lock" proxy assertion (§3.4)** uses a loose multiple
   (~3x) rather than a tight bound, to avoid CI flakiness. This is a judgment call, not
   a value taken from any existing precedent in this codebase (no prior test in this
   repo asserts on `Task.await_many/2` wall-clock time). If TEST-DESIGN-VALIDATOR or
   TEST-RUNNER finds this threshold too loose to be a meaningful assertion, or too tight
   and flaky in the actual Docker/CI environment, that is expected tuning latitude within
   their own step — not a design defect requiring rework, provided the assertion's
   *purpose* (catch an accidentally-reintroduced global/singleton serialization point)
   is preserved.
3. **`start_n_instances!/3`'s sequential 100-call setup cost** (§3.3) is not itself
   under concurrency test — only the subsequent task-completion step is. If a future
   requirement wants instance *creation* itself verified under concurrency (100
   concurrent `create/2` calls, not just 100 concurrent `complete_task/3` calls), that
   is out of REQ-055's own literal AC text (which names "100 concurrent task
   completions," not instance creation) and is not added here — noted so it isn't
   silently assumed to already be covered.
