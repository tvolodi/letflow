PROVENANCE (historical, not current decision authority):
# Design: REQ-039 — Sandbox pool and fixture loader (`sandbox_pool.zig` + `fixture_loader.zig`)

**Requirement:** REQ-039 (`docs/requirements.yaml:1822-1873`, stage S2, `depends_on: [REQ-022]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ039-20260817`, WF-02 Step 1
**This document produces:** module/file plan, GenServer state shape, client-API
function signatures, algorithm steps (prose, not code), invariants, verbatim
`@moduledoc` text, error taxonomy, acceptance-criteria traceability, and the explicit
resolution of the process-vs-row open question this requirement names. **No
implementation code** — no function bodies, no `.ex`/`.exs` files, no migration files.
ELIXIR-DEV writes those from this document at Step 2a.

---

## 0. Sources read in full for this design

**Letflow project docs:** `docs/requirements.yaml` REQ-039 (1822-1873) and REQ-040
(1875-…, confirms `promotion_assertion_runs` is REQ-040's table, not this one's);
`docs/migration/stage-2-event-store-definitions.md` (Early findings — the
process-vs-row framing this design resolves); `docs/migration/decisions/
0003-ecto-schema-strategy.md` Dimension B (schema-per-tenant, `tenant_id` derived not
caller-supplied — the addendum's attribution-integrity reasoning is reused directly in
§6.4 below); `docs/guides/backend_developer_guide.md` §3.2 (`:gen_statem` vs. plain
Ecto — the same discipline this design applies to GenServer vs. plain row), §3.3 (one
supervised process per instance — and why SandboxPool is deliberately *not* shaped that
way), §3.6 (SQL parameterization), §3.7 (migrations); `docs/anti-patterns.md`;
`docs/agents/instructions/security-invariants.md` INV-1, INV-7, INV-8.

**Letflow shipped code, read directly:** `lib/letflow/tenant_provisioning.ex` (354
lines, in full) — `schema_name_for_tenant/1` (71-78), `provision_tenant_schema/1`
(94-137, including the identifier-injection safety argument at 111-122),
`replay_migrations/2` (139-196), `tenant_scoped_migrations/0` and the
`@tenant_scoped_migration_manifest` (198-287, confirming `process_definitions` and
`instance_definition_snapshots` are already entries 8-9 of 9); `lib/letflow/
instance_supervisor.ex`, `lib/letflow/approval_supervisor.ex`, `lib/letflow/
process_instance.ex`, `lib/letflow/parallel_approval.ex` (the DynamicSupervisor
one-process-per-instance precedent, read to determine whether it fits this problem —
§2 below explains why it does not); `lib/letflow/definitions/process_definition.ex`
(the `Ecto.Schema` this design's fixture allowlist targets, confirming the real column
set); `lib/letflow/application.ex` (the supervision tree this design adds one child
to); `config/dev.exs`, `config/test.exs` (existing `config :letflow, ...` key
conventions); `deps/ecto_sql/lib/ecto/migration/schema_migration.ex` (confirms
`Ecto.Migrator`'s `schema_migrations` bookkeeping table is created *inside* the
`:prefix` schema it migrates, lines 26-77 — load-bearing for §4.6's cleanup claim).

PROVENANCE (historical, not current decision authority):
**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly:**
`src/definition/sandbox_pool.zig` (300 lines, in full) — the moduledoc's "process-local
table" framing (6, quoted verbatim in §2), `SandboxPool.claim` (74-150, including the
mutex-guarded `active` list and the `setup_sql` block that creates empty copies of
fixture tables via `LIKE tenant_default.<table> INCLUDING DEFAULTS`, 119-133),
`SandboxPool.release` (155-191), `reclaimLeakedSandboxes` (200-266, confirmed **out of
REQ-039's scope** — it queries `promotion_assertion_runs`, which REQ-040 owns, per
`requirements.yaml`'s own REQ-040 title "…promotion_assertion_runs schema"); `src/
definition/fixture_loader.zig` (124 lines, in full) — `FixtureRow`, `FixtureLoadError`,
the `ALLOWLIST` (30-34: `process_definitions`, `variable_schemas`, `instances`),
`loadFixturesOnly` (45-123, including the `SET search_path` step at 65-69, the
distinct-table dedup at 71-85, the TRUNCATE loop at 99-105, and the
`jsonb_populate_record` INSERT pattern at 107-122); `src/design/
prm-batch1-promotion-assertion-rerun.md` (in full) — PRM-06 §3 "Sandbox fixture
isolation" (208-241, the canonical description of `loadFixturesOnly`'s isolation
rules), PRM-06 §7 HTTP integration (confirms `AlreadyRecorded`/`promotion_assertion_runs`
plumbing is REQ-040's, not this one's), Open question 2 "Fixture table allowlist scope"
(829-833, explicitly leaves allowlist extension to the implementer — §5.2 below is this
design's answer), Open question 3 "SandboxPool provisioning mechanics" (835-839,
explicitly defers *how* sandboxes are provisioned to the implementer — §4 below is this
design's answer).

---

## 1. Scope boundary

**In scope (this requirement, per its own acceptance criteria):**

1. `Letflow.SandboxPool` — a GenServer providing `claim/1` (+ `claim/2` for
   test-target flexibility, see §3.2) and `release/1` (+ `release/2`), enforcing
   `max_concurrent_sandboxes` and provisioning/dropping real Postgres schemas.
2. `Letflow.SandboxPool.FixtureLoader` — a stateless module providing
   `load_fixtures_only/3`, the allowlist-gated, TRUNCATE-then-INSERT fixture loader.
3. One child-spec addition to `lib/letflow/application.ex`'s supervision tree.
4. One new `config :letflow, :sandbox_pool, ...` key.
5. Zero new migrations (§6 explains why, in full).

**Explicitly NOT in scope, and not silently dropped:**

PROVENANCE (historical, not current decision authority):
| Not built here | Owned by | Citation |
|---|---|---|
| `promotion_assertion_runs` table, `applyPromotionAssertionRerun/…`, the idempotency-key check, frozen-clock/seeded-RNG injection, assertion replay | REQ-040 | `requirements.yaml:1875-…` ("…promotion_assertion_runs schema") |
| `reclaimLeakedSandboxes`-equivalent reaper (PRM-07 AC5) — sweeping `promotion_assertion_runs WHERE status='teardown_failed'` | REQ-040 (it owns the table this reaper reads) | `sandbox_pool.zig:193-266`; `prm-batch1-…md` PRM-07 §5 |
| `POST /api/v1/promotions/{review_id}/run-assertions` HTTP handler | S4 (no HTTP route work exists yet for S2) | `prm-batch1-…md` PRM-06 §7 |
| Rollback (PRM-08), solution-pack update (PRM-09) | Neither REQ-039 nor REQ-040 — separate requirements not yet expanded | `prm-batch1-…md` PRM-08/09 |
| Extending the fixture allowlist to tables beyond `process_definitions` /
  `instance_definition_snapshots` (e.g. a future `variable_schemas`-equivalent) | Whichever future requirement defines the concrete replay's fixture needs | §5.2 below, **OQ-1** |

REQ-039's own text is explicit that it ports "the claim/release/load_fixtures_only
CONTRACT (function signatures + behavior)" and nothing past that — this design holds
that boundary.

---

## 2. THE OPEN QUESTION — process-per-instance vs. row-based state, resolved

PROVENANCE (historical, not current decision authority):
REQ-039's own description flags this explicitly, citing `sandbox_pool.zig`'s own
moduledoc: *"The pool records every active claim in a process-local table"*
(`sandbox_pool.zig:6`) and asks CODE-DESIGNER to weigh it against
`stage-2-event-store-definitions.md`'s Early findings framing rather than silently
assume either direction. This section is that resolution.

### 2.1 What "process-local table" actually means (clearing up a term collision)

PROVENANCE (historical, not current decision authority):
Zig's own comment is a false cognate for anyone skimming this codebase's Postgres-heavy
vocabulary: `sandbox_pool.zig`'s `active: std.ArrayList(ActiveClaim)` (`sandbox_pool.
zig:47`) is an **in-process, in-memory list**, not a Postgres table. Nothing in
`sandbox_pool.zig` persists claim bookkeeping to any SQL table — the only SQL in the
file is `CREATE SCHEMA`/`DROP SCHEMA`/the fixture-table-scaffolding `DO` block. This
design's resolution below is therefore a choice between "in-memory state owned by a
supervised Elixir process" and "a Postgres row" — not a choice about whether R-Co
already has a DB table to port (it doesn't).

### 2.2 Applying `stage-2-event-store-definitions.md`'s own test

That file's Early findings section states the row-based side is *stronger* when state
is "two booleans and a status flag" with no expensive-to-reconstruct data, and the
process side gets stronger specifically for state with "timers/scheduled work,
backpressure between steps, or ownership of an OS-level resource with no natural row
representation." Applying each clause to `SandboxPool`, not by default:

| Property | Does `SandboxPool`'s state have it? |
|---|---|
| Expensive-to-reconstruct in-memory state | **No.** `sandbox_id`/`schema_name` pairs are trivial to regenerate; nothing here resembles a folded event-log projection. |
| Timers/scheduled work | **No**, in the sense of background/periodic work — `SandboxPool` runs no scheduler. |
| Backpressure between concurrent callers | **Yes.** `claim/1`'s AC2 explicitly requires *"blocks until either a slot frees or the wait window elapses"* under a hard concurrency ceiling — this is backpressure/queuing behaviour by definition. |
| Ownership of an OS-level (here: DB-level) resource with no natural row representation | **Partially.** The resource being owned is a Postgres *schema*, which is a real DB object — but *tracking who currently holds each of the `max_concurrent_sandboxes` slots, and making "does a slot exist right now" answerable without a query* is exactly a natural-row-representation gap: a row can *describe* a claim, but cannot, by itself, *arbitrate* concurrent claimants racing for the last slot without an additional locking primitive (`SELECT … FOR UPDATE SKIP LOCKED`, an advisory lock, or a unique-constraint-driven retry loop) layered on top. |

The single decisive property is **backpressure/arbitration**, not resource ownership
per se. AC2's blocking-wait-for-a-slot semantics is the crux: two callers racing for
the last of `max_concurrent_sandboxes` slots must never both succeed, and a caller that
loses the race must park (not busy-poll a table) until either a slot frees or its own
wait window elapses. A single supervised process, serializing every `claim`/`release`
through one mailbox, gets this "at most one winner" property *for free*, by construction
— no additional locking primitive is needed, because there is only ever one process
deciding "is a slot free." A plain-row design would need to re-invent that same
serialization point via a DB-level lock (row-level lock, advisory lock, or a
`SELECT … FOR UPDATE SKIP LOCKED` polling loop with backoff) to get the identical
guarantee — strictly more moving parts to produce the same property a GenServer's
mailbox already has natively.

### 2.3 Decision: single supervised `GenServer`, no `DynamicSupervisor`

**`Letflow.SandboxPool` is one `GenServer`** (a singleton, started once under
`Letflow.Supervisor` next to `Letflow.Repo`/`Registry`/the other application-scoped
services — see §4.5), **not** a `DynamicSupervisor`-owned process-per-claim, and
**not** a plain Ecto row/table. Both halves of that decision need justifying
separately, since the requirement's own text raised both possibilities
("a GenServer **or** DynamicSupervisor-backed pool"):

**Why a process at all (GenServer, not a row) — per §2.2:** the backpressure/quota
arbitration property is the deciding factor, not resource ownership or
expensive-to-reconstruct state (both of which point *away* from a process, in isolation
— this is exactly why REQ-039's own text says "no expensive-to-reconstruct state here"
while still leaning process-ward: the reason is arbitration, not reconstruction cost).

**Why one singleton `GenServer`, not one `DynamicSupervisor`-owned process per claimed
sandbox (the shape `Letflow.InstanceSupervisor`/`Letflow.ApprovalSupervisor` use):**
those two existing supervisors own one process *per workflow instance* because each
instance has genuinely independent lifecycle and behaviour that must survive a sibling
instance's crash — `docs/guides/backend_developer_guide.md` §3.3's "killing one
instance's process must never affect a sibling instance" is about crash isolation
between autonomous, long-lived actors. A claimed sandbox is not an autonomous actor: it
has no messages sent to it, no timers, no state transitions of its own after
provisioning — it is inert data (two strings) until `release/1` is called on it. Giving
each claim its own supervised process would add supervision surface
(`DynamicSupervisor.start_child/2`, a `child_spec/1`, `:transient` restart semantics)
that guards nothing, because there is no failure mode a per-claim process would isolate
that a map entry inside one GenServer does not already isolate equally well — a crash
handling claim A's release cannot corrupt claim B's map entry any more than a crash in
claim A's own process could, since Elixir's `handle_call`/`handle_cast` clauses for
different requests never share mutable state outside the single `%State{}` struct
either way. The one property a per-claim process *would* add — the claiming caller's
death being detected via a process link/monitor specific to that claim — is achievable
identically by the singleton GenServer monitoring the calling process's pid per claim
(§4.4's waiting-queue monitor does exactly this for *queued* waiters; §11 **OQ-2**
below discusses the analogous question for *already-provisioned* claims, which REQ-039
does not require and this design does not build).

**Why not a plain Ecto row, restated concretely:** a row-based design satisfying AC2
would need one of (a) `SELECT … FOR UPDATE SKIP LOCKED` against a `sandbox_slots` table
with pre-seeded slot rows, polled with backoff until the wait window elapses, or (b) a
Postgres advisory lock guarding a counter row. Both are strictly more code and more
failure modes (lock timeout tuning, poll-interval tuning, a slot-row seeding migration)
to reproduce a guarantee a GenServer mailbox already provides. Given REQ-039 states
explicitly there is no expensive-to-reconstruct state to justify a row's durability
advantage either, the row-based option has no offsetting benefit to weigh against that
cost. See §11 **OQ-3** for the one real durability trade-off this decision does accept
(state is lost across a pool-process restart) and why it's accepted rather than
designed around here.

---

## 3. Module and file plan

PROVENANCE (historical, not current decision authority):
| File | Module | Mirrors (R-Co) |
|---|---|---|
| `lib/letflow/sandbox_pool.ex` | `Letflow.SandboxPool` (GenServer + client API) and nested `Letflow.SandboxPool.SandboxClaim` (plain struct) | `src/definition/sandbox_pool.zig` |
| `lib/letflow/sandbox_pool/fixture_loader.ex` | `Letflow.SandboxPool.FixtureLoader` and nested `Letflow.SandboxPool.FixtureLoader.FixtureRow` (plain struct) | `src/definition/fixture_loader.zig` |

**Deviation from the handoff's `owned_modules` hint, called out explicitly:** the
WF-02 handoff context lists `owned_modules: ["lib/letflow/definitions", "priv/repo/
migrations"]`. This design places `Letflow.SandboxPool` at the **top level**
(`lib/letflow/sandbox_pool.ex`), not under `lib/letflow/definitions/`. Reasoning:
`lib/letflow/definitions/` (per `req027-definition-core-schema.md` §0 and the shipped
`process_definition.ex`/`instance_definition_snapshot.ex`/`graph.ex`) houses
**definition-domain schema and validation modules** — things that model or validate a
workflow definition's own data. `SandboxPool` is a **schema-provisioning
infrastructure primitive**, structurally identical in kind to `Letflow.
TenantProvisioning` (which itself lives at the top level, `lib/letflow/
tenant_provisioning.ex`, not under any subdirectory) — both mint/drop Postgres schemas
and both are consumed *by* the definitions domain (and, later, REQ-040's assertion-rerun
orchestration) rather than being part of it. Matching `TenantProvisioning`'s placement
is the more consistent precedent than matching `definitions/`'s. `priv/repo/
migrations` remains correctly listed as owned scope even though this design adds zero
files there (see §6) — no contradiction, just an empty allocation.

**Nested-struct convention, cited:** `SandboxClaim` and `FixtureRow` are plain structs
(no `Ecto.Schema`, no DB backing, no changeset) nested in their owning file, matching
`Letflow.Definitions.Graph`'s nested `Node`/`Edge`/`Violation` structs (same file, not
separate files) — the precedent for small non-persisted value types in this codebase.

---

## 4. `Letflow.SandboxPool` — the pool GenServer

### 4.1 `SandboxClaim` struct

```
defmodule Letflow.SandboxPool.SandboxClaim do
  @enforce_keys [:sandbox_id, :schema_name]
  defstruct [:sandbox_id, :schema_name]

  @type t :: %__MODULE__{sandbox_id: String.t(), schema_name: String.t()}
end
```

(Shown as a struct/type shape only — no functions, no logic — same status as the
`FixtureRow` shape in §5.1.)

### 4.2 Client API — function signatures

```
@spec start_link(opts :: keyword()) :: GenServer.on_start()
```
`opts` accepts `:name` (default `__MODULE__`) and `:max_concurrent` (default:
`Application.fetch_env!(:letflow, :sandbox_pool)[:max_concurrent_sandboxes]`).
Named-instance support exists so tests can start an isolated pool with its own small
quota rather than sharing the application's singleton instance across concurrent
`async: true` tests (matching this design's testability goal — see §4.7).

```
@spec claim(max_wait_ms :: non_neg_integer(), pool :: GenServer.server()) ::
        {:ok, Letflow.SandboxPool.SandboxClaim.t()}
        | {:error, :sandbox_unavailable}
        | {:error, :provision_failed}
        | {:error, term()}
```
`pool \\ __MODULE__` — this default argument means both `claim/1` (the arity REQ-039's
acceptance criteria name) and `claim/2` (explicit pool target, for test isolation) are
generated. AC5's request/response text ("returns SandboxUnavailable") maps to
`{:error, :sandbox_unavailable}` per this codebase's `{:ok, _} | {:error, atom()}`
convention (`backend_developer_guide.md` §3.5); `SandboxUnavailable` is REQ-039's own
literal name (not R-Co's `PoolExhausted`), preserved as the Elixir error atom.

PROVENANCE (historical, not current decision authority):
```
@spec release(sandbox_id :: String.t(), pool :: GenServer.server()) ::
        :ok
        | {:error, :not_found}
        | {:error, :release_failed}
```
`pool \\ __MODULE__`, same reasoning as `claim/2`. **Divergence from Zig's
`release(sandbox_id, schema_name)`, stated:** Zig's `release` takes both strings because
Zig's caller owns the heap-allocated strings and must hand them back for the pool to
free (`sandbox_pool.zig:155-159`, `187-190`) — a memory-management concern with no
Elixir analogue (Elixir strings are garbage-collected, not caller-owned). Elixir's
`release/1` looks `schema_name` up from the pool's own `active` map by `sandbox_id`
instead of trusting a caller-supplied second string. This is the same "derive, don't
trust a caller-supplied value that could disagree with internal state" principle
`0003-ecto-schema-strategy.md`'s 2026-08-17 addendum already established for `tenant_id`
population (§326-397 of that file) — applied here to `schema_name` instead. It also
naturally produces `{:error, :not_found}` for an unknown/already-released `sandbox_id`,
which a two-argument `release/2` trusting the caller's `schema_name` could not detect as
cleanly.

### 4.3 GenServer state shape

```
%{
  max_concurrent: pos_integer(),
  active: %{optional(sandbox_id :: String.t()) => schema_name :: String.t()},
  waiting: :queue.queue({from :: GenServer.from(), caller_ref :: reference(), timer_ref :: reference()})
}
```

PROVENANCE (historical, not current decision authority):
- `active` is the entire "process-local table" `sandbox_pool.zig:6`'s moduledoc
  describes — an in-memory map, not a Postgres table (§2.1). `map_size(active)` is the
  live count against which `max_concurrent` is enforced.
- `waiting` is a FIFO queue (Erlang `:queue`) of callers parked because `claim/1` found
  no free slot when it was evaluated. `caller_ref` is a `Process.monitor/1` reference on
  the *waiting caller's pid* (extracted from `from`), so a waiter that dies before a
  slot frees is dropped from the queue instead of having a sandbox provisioned for a
  dead recipient (§4.7 **INV-SP-6**). `timer_ref` is the `Process.send_after/3`
  reference for that waiter's own remaining wait window.

### 4.4 `claim/1` algorithm (steps, not code)

1. `handle_call({:claim, max_wait_ms}, from, state)` runs.
2. If `map_size(state.active) < state.max_concurrent`: provision synchronously (step 4
   below), insert the new `{sandbox_id => schema_name}` into `active`, reply
   `{:ok, %SandboxClaim{...}}`.
3. Else (no free slot right now):
   - If `max_wait_ms <= 0`: reply `{:error, :sandbox_unavailable}` immediately — a
     zero-or-negative wait window has already elapsed by definition, no need to queue.
   - Else: monitor the caller's pid, start a `Process.send_after(self(), {:claim_timeout,
     caller_ref}, max_wait_ms)` timer, append `{from, caller_ref, timer_ref}` to
     `waiting`, and return `{:noreply, state}` — the caller is now parked and does not
     receive a reply until either step 5 or step 6 fires.
PROVENANCE (historical, not current decision authority):
4. **Provisioning sequence** (used both by step 2 and by step 5 when a slot frees for a
   waiter):
   a. `sandbox_id = Ecto.UUID.generate()`.
   b. `schema_name = "sandbox_" <> String.replace(sandbox_id, "-", "")` — see §4.6 for
      why this mirrors `Letflow.TenantProvisioning.schema_name_for_tenant/1`'s
      `"tenant_" <> hex` shape rather than Zig's raw-hyphenated `"sandbox_" <>
      <uuid-with-hyphens>` (`sandbox_pool.zig:100-101`).
   c. `Repo.query!(~s(CREATE SCHEMA "#{schema_name}"))` — **no** `IF NOT EXISTS`
      (unlike `TenantProvisioning.provision_tenant_schema/1`'s idempotent form):
      every claim mints a fresh UUID, so a collision here indicates a genuine defect
      (broken RNG) and should fail loudly rather than silently reuse another claim's
      schema. `schema_name`'s injection safety rests on the same argument
      `tenant_provisioning.ex:111-122` already documents: it is never taken from an
      external caller, only ever the output of step (b)'s fixed `"sandbox_" <>
      Ecto.UUID.generate()`-derived construction, which by construction only ever
      produces `sandbox_[0-9a-f]{32}`.
   d. `Ecto.Migrator.run(Repo, Letflow.TenantProvisioning.tenant_scoped_migrations(),
      :up, all: true, prefix: schema_name, log: false)` — see §4.6 for why this
      replaces Zig's `LIKE tenant_default.<table> INCLUDING DEFAULTS` scaffolding
      (`sandbox_pool.zig:119-133`), which has no Letflow analogue (Letflow has no
      reserved `tenant_default` schema — `tenant_provisioning.ex`'s own moduledoc
      states this explicitly).
   e. On any failure in (c) or (d): best-effort compensating `DROP SCHEMA IF EXISTS
      "#{schema_name}" CASCADE` (swallow its own failure — this is cleanup, not the
      primary error path), then surface `{:error, :provision_failed}` from the overall
      operation. The slot was never counted as consumed (never inserted into `active`),
      so no quota "give-back" step is needed.
5. `handle_call({:release, sandbox_id}, from, state)` (§4.5) removes an entry from
   `active`. Immediately after, if `waiting` is non-empty: pop the oldest waiter,
   cancel its timer (`Process.cancel_timer/1`) and its monitor
   (`Process.demonitor/2` with `:flush`), run the step-4 provisioning sequence for
   that waiter, and `GenServer.reply/2` them with the result (`{:ok, claim}` on
   success or `{:error, :provision_failed}` on failure — a failed hand-off to a waiter
   does **not** retry against the next waiter in queue; it simply frees the slot back
   to "no one holds it," and the next `claim`/hand-off attempt (whether from a new
   caller or the next waiter's own timeout-vs-retry semantics) contends for it
   normally).
6. `handle_info({:claim_timeout, caller_ref}, state)`: if a waiter matching
   `caller_ref` is still in `waiting` (it may have already been serviced by step 5, in
   which case this is a no-op), remove it, demonitor, and `GenServer.reply(from,
   {:error, :sandbox_unavailable})`.
7. `handle_info({:DOWN, caller_ref, :process, _pid, _reason}, state)`: if a waiter
   matching `caller_ref` is still in `waiting`, cancel its timer and remove it from the
   queue **without replying** (the dead caller cannot receive a reply) — see
   §4.7 **INV-SP-6**.

### 4.5 `release/1` algorithm (steps, not code)

1. `handle_call({:release, sandbox_id}, from, state)` runs.
2. `Map.fetch(state.active, sandbox_id)`:
   - `:error` → reply `{:error, :not_found}` immediately, state unchanged.
   - `{:ok, schema_name}` → continue.
3. `Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))`. `schema_name`
   here is never caller-supplied — it was read from `active` in step 2, itself only
   ever populated by §4.4 step 4's fixed derivation — so this interpolation carries the
   identical safety argument as `tenant_provisioning.ex:111-122` and §4.4 step (c).
   - On failure: reply `{:error, :release_failed}`. The entry is **not** removed from
     `active` on this path — a schema whose DROP failed is still occupying its quota
     slot in reality (the schema may or may not still exist server-side), and removing
     the bookkeeping entry would let a new `claim/1` believe a slot is free when the
     physical schema might still be there. This mirrors PRM-07's own `teardown_failed`
     status concept in spirit (a failed teardown is a distinct, retryable outcome, not
     silently treated as success) even though REQ-039 builds no `promotion_assertion_
     runs` row to record it in (that bookkeeping is REQ-040's, per §1's scope table).
     A caller that receives `{:error, :release_failed}` may retry `release/1` again
     with the same `sandbox_id` — the `DROP SCHEMA IF EXISTS` is naturally idempotent
     for a retry.
4. On success: remove `sandbox_id` from `active`, reply `:ok` to the releaser, then run
   §4.4 step 5's waiter hand-off.

### 4.6 Why migration-replay, not `LIKE ... INCLUDING DEFAULTS`

PROVENANCE (historical, not current decision authority):
Zig's `claim()` scaffolds each sandbox's fixture-target tables by copying the shape of
a fixed reference schema, `tenant_default` (`sandbox_pool.zig:121-131`:
`CREATE TABLE "{s}".process_definitions (LIKE tenant_default.process_definitions
INCLUDING DEFAULTS)`, similarly for `variable_schemas` and `instances`). **Letflow has
no `tenant_default` schema to copy from** — `tenant_provisioning.ex`'s own moduledoc
states Letflow deliberately has no reserved default-tenant UUID/schema (every tenant,
including the one with `slug == "bpm-default"`, gets a normal randomly-generated
`binary_id`). A literal port of the `LIKE` pattern has no fixed schema name to target.

Two alternatives were weighed:

- **(a) Hardcode the fixture-target tables' DDL directly** inside `SandboxPool`'s
  provisioning step (duplicate `process_definitions`'/`instance_definition_snapshots`'
  column definitions as a second, sandbox-only `CREATE TABLE` literal). Rejected: this
  creates two sources of truth for the same table shape — REQ-027's migration files and
  this duplicate — that can silently drift the moment either one changes without the
  other being updated, with no compiler or test catching the divergence until a
  fixture-loading test fails against a sandbox whose table shape no longer matches a
  real tenant schema's.
- **(b) Reuse `Letflow.TenantProvisioning.tenant_scoped_migrations/0`** (already public,
  already the single source of truth every real tenant schema is built from) by calling
  `Ecto.Migrator.run/4` directly with `prefix: schema_name`, the same mechanism
  `TenantProvisioning.replay_migrations/2` itself uses internally
  (`tenant_provisioning.ex:182-187`). **Adopted.** A sandbox schema ends up
  byte-identical in table shape to a real tenant schema, with zero duplicated DDL and
  zero drift risk — any future migration added to the manifest (per that module's own
  "every future tenant-scoped migration must append its own entry" instruction,
  `tenant_provisioning.ex:241-246`) automatically extends to sandbox schemas too, with
  no change needed in this module.

**Why call `Ecto.Migrator.run/4` directly rather than calling
`TenantProvisioning.replay_migrations/2` as a black box:** `replay_migrations/2`
requires an existing `Letflow.TenantProvisioning.Registration` row
(`tenant_provisioning.ex:174-176`: returns `{:error, :tenant_not_provisioned}`
immediately if none exists) — and REQ-039's own text is explicit that "sandbox schemas
are NOT tenant schemas… since sandboxes aren't tied to a real tenant row." Creating a
`Registration` row for every ephemeral sandbox would be both semantically wrong (a
sandbox is not a tenant) and would permanently accumulate registry rows for schemas
that no longer exist after `release/1`. `SandboxPool` therefore depends on
`TenantProvisioning.tenant_scoped_migrations/0` (the pure migration-source function)
directly, and on `Ecto.Migrator.run/4` directly — **not** on `provision_tenant_schema/1`
or `replay_migrations/2`, both of which are registry-coupled and inappropriate here.
This is a cross-module dependency worth stating precisely (§9).

**Cleanup confirmation:** `deps/ecto_sql/lib/ecto/migration/schema_migration.ex:26-77`
confirms `Ecto.Migrator.run/4` creates/reads its own `schema_migrations` bookkeeping
table *inside* the `:prefix` schema passed to it (`prefix: opts[:prefix]` at both the
table-creation and version-read call sites) — so `release/1`'s `DROP SCHEMA … CASCADE`
removes that per-sandbox `schema_migrations` table along with everything else,
leaving no orphaned bookkeeping row in `public`.

### 4.7 Invariants

- **INV-SP-1.** `claim`/`release` for any two `sandbox_id`s are never processed
  concurrently with each other, because both are `GenServer.call`s against the same
  singleton process's single mailbox — this is the property §2.3 names as the reason a
  process (not a row) was chosen, and it holds by construction, not by an added lock.
- **INV-SP-2.** `map_size(active) <= max_concurrent` holds at every point in time (an
  entry is added only after successful provisioning inside a slot that was confirmed
  free in the same `handle_call`, per §4.4 step 2/5).
- **INV-SP-3.** A `claim/1` call that receives `{:ok, claim}` always corresponds to a
  real, already-`CREATE SCHEMA`'d Postgres schema with all `tenant_scoped_migrations/0`
  tables already applied to it — fixture loading against a freshly claimed sandbox
  never needs to create its own target tables.
- **INV-SP-4.** `schema_name` is never accepted as a directly caller-supplied value
  anywhere it is interpolated into DDL (§4.4 step (c), §4.5 step 3) — it is always
  either freshly derived in step 4(b) or read back out of `state.active` by
  `sandbox_id`. No function in this module takes a `schema_name` parameter from an
  external caller.
- **INV-SP-5.** `release/1` is idempotent against a `sandbox_id` that is not currently
  active (`{:error, :not_found}`, no SQL issued) and safe to retry after
  `{:error, :release_failed}` (the `active` entry is retained specifically so a retry
  is meaningful).
- **INV-SP-6.** A waiting caller (§4.4 step 3) that dies before a slot frees or its
  wait window elapses is removed from `waiting` without a sandbox ever being
  provisioned on its behalf — closes a resource-leak class a naive
  timer-only implementation would have (a slot silently handed to a caller that can
  never receive or release it).
- **INV-SP-7 (testability).** `start_link/1`'s `:name` option lets tests start an
  independent `SandboxPool` instance with its own small `:max_concurrent`, so AC2
  ("quota exhausted, blocks, times out") is exercisable with a small deliberate quota
  (e.g. `max_concurrent: 1`) and a short `max_wait_ms` in an isolated process, without
  serializing against or being polluted by any other concurrently running test's use of
  the application's own singleton pool.

---

## 5. `Letflow.SandboxPool.FixtureLoader`

### 5.1 `FixtureRow` struct

```
defmodule Letflow.SandboxPool.FixtureLoader.FixtureRow do
  @enforce_keys [:table_name, :row_json]
  defstruct [:table_name, :row_json]

  @type t :: %__MODULE__{table_name: String.t(), row_json: String.t()}
end
```

PROVENANCE (historical, not current decision authority):
`row_json` is a raw JSON text string (matching Zig's `row_json: []const u8`,
`fixture_loader.zig:15`), bound as a `$1::jsonb` parameter — never decoded into an
Elixir map by this module and never string-interpolated into SQL.

### 5.2 The allowlist — resolved, with the extension point named explicitly

```
@allowlist ["process_definitions", "instance_definition_snapshots"]
```

PROVENANCE (historical, not current decision authority):
**Divergence from Zig's `{process_definitions, variable_schemas, instances}`
(`fixture_loader.zig:30-34`), stated and justified:** two of Zig's three allowlisted
tables have no Letflow equivalent today. `variable_schemas` has never been ported (no
requirement has built it). `instances` is not even R-Co's own current name for its
instance table — R-Co's real instance table is `instance_projections`
(`001_event_store.sql`, ported by REQ-023) — so Zig's own `instances` entry is already
stale relative to R-Co's schema, not just relative to Letflow's. Letflow's allowlist
instead names the two tables that concretely exist in a Letflow tenant schema today and
are both already `tenant_scoped_migrations/0` members (confirmed manifest entries 8-9,
§0): `process_definitions` and `instance_definition_snapshots`. Both are exactly the
tables PRM-06's own design narrative describes seeding for an assertion-rerun sandbox
("load candidate definitions into sandbox schema," `prm-batch1-…md`'s data-flow
diagram) — `process_definitions` for the candidate definition rows themselves,
`instance_definition_snapshots` for any snapshot-shaped fixture a future assertion
scenario needs.

This list is deliberately **not** extended to include `instance_projections` (Letflow's
`instances` analogue) speculatively — see **OQ-1** (§11): whether the eventual
assertion-replay consumer (REQ-040 or later) needs it is not yet known from anything
REQ-039 itself states, and guessing wrong here either blocks that future requirement
(too narrow) or widens a hard SQL-injection boundary further than anything currently
justifies (too broad). Extending `@allowlist` is a one-line, low-risk change for
whichever future requirement defines its own concrete fixture needs.

### 5.3 `load_fixtures_only/3` — function signature

```
@spec load_fixtures_only(
        sandbox_schema :: String.t(),
        fixtures :: [Letflow.SandboxPool.FixtureLoader.FixtureRow.t()],
        opts :: keyword()
      ) ::
        :ok
        | {:error, :invalid_table_name}
        | {:error, :invalid_schema_name}
        | {:error, :insert_failed}
        | {:error, term()}
```

`opts \\ []` is the third positional parameter that gives this function its stated
arity-3 (REQ-039's acceptance criteria name `load_fixtures_only/3` explicitly, though
its own description prose names only the two semantically load-bearing parameters,
`sandbox_schema` and `fixtures`). `opts` currently reads no keys — it exists as a
forward-compatible extension point (e.g. a future `:repo` override for testing against
a non-default `Letflow.Repo`) rather than being invented busywork: passing `[]` today
is a complete no-op, so no caller is required to supply anything beyond the two
semantic arguments, and no behavior is hidden behind an undocumented option.

### 5.4 Algorithm (steps, not code)

PROVENANCE (historical, not current decision authority):
1. If `fixtures == []`: return `:ok` immediately (matches `fixture_loader.zig:51`; a
   no-op load issues no SQL at all, including no TRUNCATE).
2. **Schema-name shape validation (§5.5 INV-FL-1, an invariant this design adds beyond
   Zig's own source — see rationale there):** `sandbox_schema` must match
   `^sandbox_[0-9a-f]{32}$` exactly (the shape §4.4 step 4(b) always produces). If not:
   return `{:error, :invalid_schema_name}` without issuing any SQL.
PROVENANCE (historical, not current decision authority):
3. Compute the distinct `table_name` list from `fixtures`, preserving first-seen order
   (identical dedup algorithm to `fixture_loader.zig:71-85`).
PROVENANCE (historical, not current decision authority):
4. Validate every distinct `table_name` against `@allowlist` (§5.2). The **first**
   non-allowlisted name found short-circuits: return `{:error, :invalid_table_name}`
   without issuing any TRUNCATE or INSERT for *any* table, including ones that *are*
   allowlisted (matches Zig's own all-or-nothing validate-before-any-SQL ordering,
   `fixture_loader.zig:87-97` — validation is a separate pass that completes in full
   before the mutation pass begins).
PROVENANCE (historical, not current decision authority):
5. Open a `Repo.transaction/1` (see §5.6 for why this is a deliberate improvement over
   Zig's non-transactional sequence, not a silent behavior change):
   a. For each distinct table (in first-seen order): issue
      `TRUNCATE "<sandbox_schema>"."<table_name>" CASCADE` via `Repo.query!/2`, with
      both identifiers schema/table-qualified and double-quoted. Both identifiers are
      safe to interpolate here: `sandbox_schema` passed step 2's fixed-shape check,
      `table_name` passed step 4's fixed-allowlist check — neither is raw,
      unvalidated caller input at the point of interpolation.
   b. For each fixture row (in original, not deduplicated, order): issue
      `INSERT INTO "<sandbox_schema>"."<table_name>" SELECT * FROM
      jsonb_populate_record(NULL::"<sandbox_schema>"."<table_name>", $1::jsonb)` via
      `Repo.query!(sql, [row.row_json])` — `table_name` interpolated (same
      already-validated value as step 5a), `row_json` bound as `$1`, never
      interpolated. This is Zig's own pattern (`fixture_loader.zig:107-122`), carried
      over with the table name schema-qualified explicitly rather than relying on a
      mutated connection-level `search_path` (§5.6 explains this second divergence).
   c. Any `Repo.query!/2` failure inside the transaction raises, which
      `Repo.transaction/1` catches and rolls back automatically; the outer call
      catches that and returns `{:error, :insert_failed}`.
6. On full success: `Repo.transaction/1` commits; return `:ok`.

### 5.5 Invariants

PROVENANCE (historical, not current decision authority):
- **INV-FL-1 (added beyond Zig's own source, justified by INV-7).** Zig's
  `loadFixturesOnly` trusts its `sandbox_schema` parameter positionally with no shape
  check before interpolating it into `SET search_path TO "<schema>", public`
  (`fixture_loader.zig:65-68`) — safe in Zig's own call graph only because its sole
  caller, `applyPromotionAssertionRerun`, always passes a value it just received from
  `sandbox_pool.claim()` moments earlier. `Letflow.SandboxPool.FixtureLoader.
  load_fixtures_only/3` is a public function with no such caller guarantee enforced by
  the type system — `sandbox_schema` is a bare `String.t()`, callable with any string.
  Given `security-invariants.md` INV-7 is a BLOCKER-severity, always-applicable
  invariant, and given a schema name is exactly the same class of "identifier, not a
  bind-param-able value" problem the table-name allowlist already exists to solve,
  this design closes the same injection class on the schema-name dimension too, via
  the fixed-shape regex check in §5.4 step 2, rather than carrying Zig's implicit
  same-file-caller trust assumption into a differently-shaped Elixir call graph.
- **INV-FL-2.** No table name reaches a TRUNCATE or INSERT statement unless it appears
  verbatim in `@allowlist` — the allowlist check (§5.4 step 4) always completes, for
  every distinct table in the batch, before the first mutating statement is issued
  (§5.4 step 5).
- **INV-FL-3.** `row_json` values are always passed as a bound `$1::jsonb` parameter,
  never string-interpolated — the only interpolated identifiers in any statement this
  module issues are `sandbox_schema` (post-INV-FL-1 check) and `table_name`
  (post-INV-FL-2 check).
- **INV-FL-4.** Loading the identical `fixtures` list twice against the same
  `sandbox_schema` (a retry) leaves an identical final row set both times: step 5a's
  TRUNCATE always runs immediately before that table's rows are (re-)inserted within
  the same transaction, so no prior run's rows can survive alongside a retry's rows —
  this is AC5 (Acceptance criterion 5), traced in §8.
- **INV-FL-5.** A `load_fixtures_only/3` call either fully applies (all distinct
  tables truncated, all rows inserted) or has no effect on the target schema's data
  (transaction rollback on any failure) — see §5.6 for why this is a deliberate,
  reasoned divergence from Zig's own partial-application-on-error behavior.

### 5.6 Two stated divergences from Zig's fixture loader, justified

PROVENANCE (historical, not current decision authority):
1. **Transactional atomicity (added).** Zig's own comment states plainly: "On any
   error the function returns and leaves the sandbox in whatever state it reached; the
   defer in the assertion re-run pipeline still releases the sandbox"
   (`fixture_loader.zig:42-44`) — an accepted, explicit partial-application trade-off
   in Zig, not a hard requirement any AC depends on. None of REQ-039's six acceptance
   criteria require or forbid atomicity on failure; AC5 only requires idempotent
   *successful* retries (INV-FL-4). Wrapping the TRUNCATE+INSERT sequence in
   `Repo.transaction/1` removes an entire failure-mode class (a failed load leaving
   some tables truncated-but-not-reloaded, silently missing fixture rows the caller
   believes were loaded) at no cost this codebase doesn't already pay routinely
   (`TenantProvisioning.provision_tenant_schema/1` wraps its own multi-statement
   sequence in exactly the same primitive). Adopted as a strict improvement.
PROVENANCE (historical, not current decision authority):
2. **Explicit schema-qualification instead of `SET search_path` (changed mechanism,
   same behavior).** Zig mutates the borrowed connection's `search_path` for the
   duration of the load, then restores it (`fixture_loader.zig:61-69`) — a reasonable
   choice for Zig's own connection-pool model, where a connection is exclusively
   checked out for the call's duration. Ecto's `Repo` pools connections more opaquely
   (a `Repo.transaction/1` call may or may not reuse the same physical connection
   across retries/reconnects, and mutating session-level `search_path` state on a
   pooled connection risks that state leaking to whatever the connection is checked
   out for next if an error path skips the restore). Explicit
   `"<schema>"."<table>"`-qualified identifiers in every statement sidestep the whole
   class of connection-state-leak risk and match this codebase's established
   schema-per-tenant mechanism anyway (`0003-ecto-schema-strategy.md` Dimension B:
   `:prefix`-based per-query qualification, not a session-level default). Behavior at
   the SQL level is identical either way; only the mechanism changed.

---

## 6. DB objects — none (zero new migrations), stated precisely

**This design creates zero `priv/repo/migrations/*.exs` files.** Restated from §4.4/§4.6:
the only DB objects this design creates are **Postgres schemas**, minted and dropped at
runtime by `claim/1`/`release/1` via `CREATE SCHEMA`/`DROP SCHEMA` — not by
`Ecto.Migration`'s DSL, and not tracked in `public.schema_migrations` as a Letflow-owned
migration (each sandbox schema gets its *own* `schema_migrations` table via
`Ecto.Migrator.run/4`'s `:prefix` option, per §4.6's citation — this is Ecto's own
bookkeeping for what `tenant_scoped_migrations/0` applied to that ephemeral schema, not
a new migration file this requirement adds).

**Why this is correct, not a gap:** `promotion_assertion_runs` (the one table PRM-06's
design doc actually schemas out, `prm-batch1-…md` §1) is explicitly REQ-040's, not
REQ-039's (§1's scope table). REQ-039's own six acceptance criteria — reproduced and
traced in §8 — describe no persistent Letflow-owned table at all: `claim`/`release`
operate on ephemeral, dynamically-named Postgres schemas (verified via
`information_schema.schemata`, AC1/AC3's own words), and `load_fixtures_only` operates
on tables that already exist (§4.4 step 4d/§4.6) inside whatever sandbox schema it's
pointed at. The handoff's `owned_modules` lists `priv/repo/migrations` as in-scope
because ORCH could not know in advance whether this design would need a migration —
this design's own conclusion, reasoned in §2/§4.6, is that it does not.

---

## 7. Error taxonomy (both modules)

| Error | Function | HTTP (future, informational only — S4 not started) | Meaning |
|---|---|---|---|
| `{:error, :sandbox_unavailable}` | `claim/1` | 503 (matches PRM-06's own `SandboxUnavailable → 503` mapping, `prm-batch1-…md` §7) | No slot freed within `max_wait_ms` |
| `{:error, :provision_failed}` | `claim/1` | 500 | `CREATE SCHEMA` or the `tenant_scoped_migrations/0` replay failed; sandbox rolled back best-effort |
| `{:error, :not_found}` | `release/1` | n/a (internal contract, not an HTTP-facing error) | `sandbox_id` is not a currently active claim |
| `{:error, :release_failed}` | `release/1` | 500 | `DROP SCHEMA` failed; claim entry retained for a safe retry |
| `{:error, :invalid_table_name}` | `load_fixtures_only/3` | 422 | A fixture's `table_name` is not in `@allowlist` — the SQL-injection boundary (AC4) |
| `{:error, :invalid_schema_name}` | `load_fixtures_only/3` | 422 | `sandbox_schema` does not match `^sandbox_[0-9a-f]{32}$` — INV-FL-1, this design's added hardening |
| `{:error, :insert_failed}` | `load_fixtures_only/3` | 422 | TRUNCATE or INSERT failed inside the transaction; fully rolled back (INV-FL-5) |

No function in either module raises on a realistic external-input failure path —
every DB-facing step is wrapped so a Postgrex error becomes one of the tagged tuples
above, per `backend_developer_guide.md` §3.5 and INV-8.

---

## 8. Acceptance-criteria traceability

| # | Acceptance criterion (verbatim, `requirements.yaml:1867-1872`) | Design element |
|---|---|---|
| 1 | "claim/1 against an empty pool immediately succeeds and returns a sandbox_id + schema_name for a real, freshly-created Postgres schema" | §4.4 step 2 (empty `active` ⇒ `map_size(active) < max_concurrent` true ⇒ immediate provisioning path); §4.2's `claim/1` return shape `{:ok, %SandboxClaim{sandbox_id:, schema_name:}}`; §4.4 step 4c's real `CREATE SCHEMA` (verifiable via `information_schema.schemata`) |
| 2 | "claim/1 when max_concurrent_sandboxes slots are all in use blocks until either a slot frees or the wait window elapses, returning SandboxUnavailable in the latter case" | §4.4 steps 3/5/6: queued (`:noreply`) when no slot free, serviced via §4.4 step 5 on the next `release/1`, or replied `{:error, :sandbox_unavailable}` via §4.4 step 6 when `max_wait_ms` elapses; §4.7 INV-SP-7 for how a test exercises this without a huge quota |
| 3 | "release/1 on a claimed sandbox drops its schema (verified: the schema no longer appears in information_schema.schemata after release) and frees its quota slot for a subsequent claim/1" | §4.5 steps 3-4 (`DROP SCHEMA IF EXISTS … CASCADE`, then removal from `active`); §4.7 INV-SP-2 (quota re-check is always against live `map_size(active)`, so a freed slot is immediately claimable) |
| 4 | "load_fixtures_only/3 with a table_name not in the allowlist returns InvalidTableName without issuing any SQL against that table name" | §5.4 step 4 (`{:error, :invalid_table_name}`, full validation pass completes before any TRUNCATE/INSERT); §5.5 INV-FL-2 |
| 5 | "load_fixtures_only/3 loading the same fixtures twice against the same sandbox_schema (simulating a retry) leaves the same final row set both times, via the TRUNCATE-before-insert step" | §5.4 step 5a (TRUNCATE immediately precedes that table's inserts, every call); §5.5 INV-FL-4 |
| 6 | "the moduledoc names the process-per-instance-vs-row-based-state open question explicitly and states it is left for CODE-DESIGNER, per this requirement's description and stage-2-event-store-definitions.md's Early findings section" | §2 (full resolution) plus §10's verbatim `@moduledoc` text for `Letflow.SandboxPool`, which documents exactly this per the pattern already established by `Letflow.TenantProvisioning`'s own moduledoc's "Open question" sections |

---

## 9. Cross-module dependencies

| Dependency | Direction | Kind |
|---|---|---|
| `Letflow.TenantProvisioning.tenant_scoped_migrations/0` | `SandboxPool` → `TenantProvisioning` | Reused directly (§4.4 step 4d, §4.6) — **not** `provision_tenant_schema/1` or `replay_migrations/2` (both registry-coupled, deliberately not used, §4.6) |
| `Ecto.Migrator.run/4` | `SandboxPool` → `ecto_sql` (existing dependency) | Reused directly with `prefix: schema_name`, same call shape `tenant_provisioning.ex:182-187` already uses |
| `Letflow.Repo` | Both modules → `Letflow.Repo` | `Repo.query!/2` (schema/table DDL, TRUNCATE/INSERT), `Repo.transaction/1` (§5.4 step 5) |
| `Letflow.Application` | `Letflow.Application` → `SandboxPool` | One new child added to the supervision tree (§4.5 below in this table's own module, detailed in the next paragraph) |
| `Letflow.Definitions.ProcessDefinition` / `Letflow.Definitions.InstanceDefinitionSnapshot` schemas | `FixtureLoader`'s `@allowlist` names their tables | Referenced by table name only (string literal), no compile-time dependency on those modules |
| Future: REQ-040's assertion-rerun orchestration | `REQ-040 code` → `SandboxPool.claim/2`, `SandboxPool.release/2`, `FixtureLoader.load_fixtures_only/3` | Not built here; REQ-039 ships the contract REQ-040 will call |

**`Letflow.Application` change:** add `{Letflow.SandboxPool, []}` to the `children`
list in `lib/letflow/application.ex` (e.g. immediately after `Letflow.
ApprovalSupervisor`, matching that file's existing ordering of "infrastructure first,
then per-instance-process owners"). New config key, matching this file's existing
`config :letflow, :oidc, …`-style key shape:

```
config :letflow, :sandbox_pool, max_concurrent_sandboxes: 5
```

`5` is an arbitrary but reasonable operational default (no functional correctness
depends on the exact number — any positive integer satisfies every acceptance
criterion); `config/test.exs` should set a small value (e.g. `1`) for fast,
deterministic AC2 exercising, though per §4.7 INV-SP-7 a test may equally start its own
named `SandboxPool` instance with a custom `:max_concurrent` instead of relying on this
global default, which is the specific reason that option exists.

---

## 10. Verbatim `@moduledoc` text

Presented as literal documentation-string content ELIXIR-DEV copies verbatim inside
`@moduledoc """ … """` — prose only, no function bodies, no logic.

### 10.1 `Letflow.SandboxPool`

PROVENANCE (historical, not current decision authority):
```
Ephemeral Postgres-schema sandbox pool (ports R-Co's `src/definition/sandbox_pool.zig`
per PRM-06/PRM-07 — see `src/design/prm-batch1-promotion-assertion-rerun.md`).

`claim/1` provisions a fresh, empty Postgres schema (already scaffolded with every
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` table, so it looks exactly like
a real tenant schema) under a hard `max_concurrent_sandboxes` quota; `release/1` drops
it. Sandbox schemas are NOT tenant schemas — they carry no
`Letflow.TenantProvisioning.Registration` row and use their own `"sandbox_" <> hex`
naming scheme, never `"tenant_" <> hex`.

## Process-per-instance vs. row-based state (REQ-039's open question, resolved here)

PROVENANCE (historical, not current decision authority):
REQ-039 explicitly flagged this as an open question rather than assuming an answer,
citing `docs/migration/stage-2-event-store-definitions.md`'s "Early findings" section
(process-vs-row) and `sandbox_pool.zig`'s own moduledoc ("The pool records every active
claim in a process-local table"). CODE-DESIGNER resolved it in
`lib/letflow/design/req039-sandbox-pool-fixture-loader.md` §2: this module is a single
supervised `GenServer` (not a `DynamicSupervisor`-per-claim, and not a plain Ecto row),
because `claim/1`'s blocking-quota-wait requirement (two callers racing for the last
free slot must never both win, and a losing caller must park until either a slot frees
or its own wait window elapses) needs one serialization point to arbitrate correctly —
a property a single process's mailbox provides natively and a row-based design would
need to re-derive via an additional DB-level lock. This is distinct from why
`Letflow.InstanceSupervisor`/`Letflow.ApprovalSupervisor` use one process *per*
instance: those exist for crash isolation between autonomous, long-lived actors, which
a claimed sandbox (inert data between `claim` and `release`) is not. See the design
doc §2 for the full reasoning, including the accepted trade-off that pool state does
not survive a `SandboxPool` process restart (design doc §11 OQ-3).
```

### 10.2 `Letflow.SandboxPool.FixtureLoader`

PROVENANCE (historical, not current decision authority):
```
Loads a fixed list of fixture rows into a claimed sandbox schema's allowlisted tables,
TRUNCATE-ing each distinct target table first (ports R-Co's
`src/definition/fixture_loader.zig` per PRM-06 §3 — see
`src/design/prm-batch1-promotion-assertion-rerun.md`).

The allowlist is the SQL-injection boundary: a fixture's `table_name` is checked
against a hardcoded list (`process_definitions`, `instance_definition_snapshots`)
before any SQL is issued for it — see `lib/letflow/design/
req039-sandbox-pool-fixture-loader.md` §5.2 for why this list diverges from R-Co's own
(two of R-Co's three allowlisted tables have no Letflow equivalent yet), and §11 OQ-1
for how a future requirement extends it. `sandbox_schema` is independently validated
against the exact shape `Letflow.SandboxPool.claim/1` always produces before any
interpolation, closing the same injection class on the schema-name dimension (design
doc §5.5 INV-FL-1) — this hardening goes beyond what R-Co's own source validates, since
R-Co's caller-trust assumption does not carry over to this module's differently-shaped
Elixir call graph.
```

---

## 11. Open questions (explicit — not silently resolved)

**OQ-1 — Fixture allowlist extension for REQ-040's actual replay needs.** §5.2 commits
`@allowlist` to exactly `["process_definitions", "instance_definition_snapshots"]` —
the two tables that concretely exist in a Letflow tenant schema today. R-Co's own
"Fixture table allowlist scope" open question (`prm-batch1-…md` §829-833) already left
this to the implementer, and this design does the same rather than guessing which
additional tables (e.g. a `variable_schemas`-equivalent, or `instance_projections` as
the analogue of R-Co's stale `instances` entry) a not-yet-built assertion-replay
consumer will need. Extend `@allowlist` as a one-line change when that consumer's
concrete needs are known — do not extend it speculatively now.

**OQ-2 — Owner-crash detection for an already-provisioned (not merely queued) claim.**
§4.7 INV-SP-6 handles a *waiting* caller dying before a slot frees. It does **not**
handle a caller dying *after* successfully receiving a claim but *before* calling
`release/1` — that sandbox remains in `active`, consuming a quota slot indefinitely,
with no automatic reclamation. None of REQ-039's six acceptance criteria require this
(the closest R-Co analogue, `reclaimLeakedSandboxes`, is explicitly PRM-07/REQ-040's,
tied to a `promotion_assertion_runs` table this requirement does not build — §1). Left
for REQ-040 (or a dedicated follow-up) to decide whether the eventual caller pattern
(a single orchestration function that always claims-and-releases within one call,
matching PRM-06/07's `defer`-guaranteed release on every exit path) makes this
sufficiently unlikely to need active detection, or whether a `Process.monitor/1` on
every already-provisioned claim's owning pid (not just queued waiters) should be added.

**OQ-3 — Sandbox-leak-on-pool-restart, a known and accepted limitation of the
in-memory design.** §2.3 resolved the process-vs-row question in favor of a pure
in-memory `GenServer`. One real consequence: if `Letflow.SandboxPool`'s process
crashes and restarts (or the whole application restarts), `active` resets to empty —
any sandbox schemas that were genuinely claimed at that moment become permanently
untracked (still physically present in Postgres, no longer counted against the quota,
never automatically dropped). This is accepted, not overlooked, for two reasons: (a)
sandboxes are designed to be claimed and released within a single short-lived
orchestration call (per PRM-07's `defer`-on-every-exit-path pattern REQ-040 will
implement), not held long-term, so the exposure window during which a restart could
strand one is small; (b) per `core-directives.md`'s "Humanless operation" section, this
project is pre-S8 with no production deployment yet, so the operational cost of rare
restarts accumulating a handful of orphaned schemas is currently low. This is,
however, a genuine gap that a future reaper (mirroring `reclaimLeakedSandboxes`'s
spirit — sweep `information_schema.schemata` for `sandbox_%` schemas older than some
threshold with no corresponding live claim — but with no `promotion_assertion_runs`
row to key off, since that table isn't this requirement's) would need to close before
this pool is relied on under sustained production load. Not built here; named
explicitly so it is not later mistaken for an oversight.

PROVENANCE (historical, not current decision authority):
**OQ-4 — `max_concurrent_sandboxes` default value (5) is a placeholder tuning
number, not a derived one.** No source read for this design (R-Co's `src/config/
quota_policy.zig`, referenced only as a dependency name in `prm-batch1-…md`'s
Dependencies table, was not part of REQ-039's cited source material and was not read)
states a concrete default. §9's `config :letflow, :sandbox_pool, max_concurrent_
sandboxes: 5` is a reasonable placeholder with no functional-correctness weight behind
the specific number — left open for whoever tunes real sandbox-provisioning cost
(REQ-040's implementation, once real DB load from `tenant_scoped_migrations/0`'s
replay-per-claim cost is measurable) to revise.
