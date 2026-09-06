# REQ-185 — Scheduler timer-firing architecture (decision + design)

Status: decision artefact. Owner: CODE-DESIGNER. Gates REQ-186/187/188 (S6's
scheduler half). This requirement is **decision-and-design-only** — no
migration, no `lib/letflow/engine/` file, no `mix.exs` change. `git diff
--stat` scoped to this requirement's commits must show only this file (and
the handoff/status bookkeeping files the pipeline itself writes).

## 0. Source-verification note (read this before trusting any R-Co citation below)

This session ran with R-Co's source tree unreachable: `c:\Users\tvolo\dev\ai-dala\R-Co\`
is a Windows path and does not exist inside this Linux sandbox (verified —
`ls` against both the literal Windows path and the `/mnt/c/...` WSL-style
mount both failed with "No such file or directory"). Per the handoff's
instruction, **every claim below attributed to
`src/design/scheduler-concurrency-epic3.md`'s ISS-301 section or
`src/design/iss0618-scheduler-lock-and-error-signaling.md` is carried
forward from `docs/requirements.yaml`'s REQ-185 entry as unverified-but-plausible
source material, not independently confirmed fact.** The REQ-185 entry itself
states it was "verified fresh against R-Co this batch" by whoever wrote it,
and separately states it corrects an earlier CODE-DESIGNER/REQ-ANALYST error
(SCH-02's literal advisory-lock text), which is evidence someone did check
R-Co directly at least once — but this session had no way to re-check that
work. A later session with R-Co reachable should re-verify these two citations
directly before this artefact is treated as fully closed:

- PROVENANCE (historical, not current decision authority):
  ISS-301's four stated grounds for removing the per-timer
  `pg_try_advisory_xact_lock` (scheduler.zig L207-242).
- ISS-0618's account of the due-but-locked/nothing-due collapse and the
  swallowed non-retryable error, and ISS-303's fix.

Everything else in this artefact (the Letflow-side facts: supervision tree
contents, `mix.exs` dependencies, `dlq_entries`' schema, Decision 0003) **was**
independently verified this session by reading the actual files in this repo,
not taken on the requirement text's word — see each section below for what
was read.

## 1. Letflow-side facts verified this session

- **`lib/letflow/application.ex`** (read in full): the supervision tree is
  `Repo`, `Ecto.Migrator`, the `Oidcc.ProviderConfiguration.Worker`, a
  `Registry`, `InstanceSupervisor`, `SandboxPool` (+ its own
  `Task.Supervisor`), and five more `Task.Supervisor`s (Engine plugin, Lua,
  Wasm module registry, Wasm capability gate, Wasm module version registry),
  plus `http_child/0`'s conditional `Bandit` listener. **No periodic process
  of any kind exists** — no `Process.send_after`-driven `GenServer`, no
  `:timer.send_interval`, nothing resembling a ticker. Confirms the
  requirement's claim.
- **`mix.exs`**'s `deps/0`: `ecto_sql`, `postgrex`, `plug`, `bandit`, `jason`,
  `stream_data` (test-only), `ueberauth_oidcc`, `lua`, `wasmex`. **No Oban, no
  Quantum, no job-queue library of any kind.** Confirms the requirement's
  claim.
- **`lib/letflow/dlq.ex`** and its migration
  (`priv/repo/migrations/20260829000001_create_dlq_entries.exs`, REQ-176):
  `entry_type` is a plain `:string` column, deliberately **not** an
  `Ecto.Enum` — the migration's own header states this is because the value
  set is extensible ("event"/"timer"/"webhook" today, more later). No DB
  CHECK constrains it to a fixed list. `Letflow.Dlq.enqueue/2` accepts any
  `entry_type` string in its `enqueue_attrs()` map, tenant-scoped via
  `opts[:prefix]`, with `tenant_id` derived server-side (never
  caller-supplied) — matching Decision 0003's addendum. There is nothing
  structurally blocking `entry_type: "timer"`; the column was reserved for
  exactly this case (REQ-176's own text, cited in the REQ-185 requirement,
  names "scheduler/timer entries" as not-yet-populated).
- **`docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B**: table
  placement is schema-per-tenant (Postgres schema-per-tenant via Ecto
  `:prefix`), with `tenant_id` retained as an intra-schema column, not the
  isolation boundary itself. This binds where a `timers` table's *rows* live;
  it says nothing about how a poller *finds* rows across many tenant schemas
  from one BEAM node, which is exactly the open question this artefact
  answers in §4.
- **`lib/letflow/tenant_provisioning.ex`**: a global `tenant_schemas` registry
  table exists (`Letflow.TenantProvisioning.Registration`), populated by
  `provision_tenant_schema/1`, living in the public/default schema (it must,
  structurally — schema identity has to be resolvable before any tenant
  schema is known). This is the enumeration mechanism §4's poller design
  relies on: it is the only existing source of "the list of all provisioned
  tenant schema names," and REQ-186 does not need to invent one.

## 2. Decision 1 — poll-loop firing mechanism

Three candidates, each evaluated on the three survival properties the
requirement names: **node restart**, **multi-node deployment**, and **a
single timer's firing raising**.

### 2a. Oban (new `mix.exs` dependency)

- *Node restart*: survives by construction — jobs are rows in Oban's own
  Postgres-backed job table; a restarted node's Oban supervisor resumes
  polling that table immediately, no separate recovery path needed.
- *Multi-node*: Oban's queue-fetch already does `FOR UPDATE SKIP LOCKED`
  row-claiming across every connected node by design — this is the exact
  claim mechanism this artefact needs (§3), already built and battle-tested.
  Native multi-node fan-out with per-queue concurrency limits.
  Cron-equivalent (Oban Cron / periodic worker) or a single always-scheduled
  recurring job can drive the poll tick itself.
  Oban is also gen_statem/OTP-native: it starts its own supervision subtree
  inside the host application's supervisor, no bespoke ticker code at all.
- *A firing timer raising*: Oban isolates each job in its own supervised
  `Task`; a raise in one job is caught by Oban's own executor, recorded as a
  job failure/retry, and does not affect any other job or halt Oban's own
  poll loop. This exactly matches the property §5 requires the recommended
  design to have natively.
- Cost: a new top-level Hex dependency, its own migration (`oban_jobs` table
  — global, not schema-per-tenant, which interacts with Decision B's
  tenant-scoping discipline, see below), a new supervision child, and a
  runtime dependency this project has not needed for anything else yet.
  Oban's job table is *not* tenant-scoped by default; each Oban job's `args`
  map would need to carry the identifying tenant/timer information itself,
  and Oban's own retry/backoff semantics would sit alongside (not replace)
  the domain-level `fire_error_count`/`failed`/DLQ machinery REQ-186 already
  specifies bit-for-bit from R-Co's SCH-05 behaviour — meaning Oban's own
  retry policy would either have to be disabled (`max_attempts: 1`, letting
  the domain-level `fire_error_count` be the only retry counter) or the two
  retry counters would drift out of sync. This is a real integration
  question, not a blocker, but it is duplicated bookkeeping this artefact
  would have to specify carefully if Oban were adopted.

### 2b. Supervised `GenServer` ticker (`Process.send_after/3`, added to `lib/letflow/application.ex`'s tree)

- *Node restart*: the ticker starts fresh on every boot with no in-memory
  state to recover — its very first tick immediately runs the same
  `status = pending AND fire_at <= now` claim query REQ-186 specifies, so
  every timer that came due while the node was down is picked up on the
  first tick after restart. No separate "catch-up" logic needed; the claim
  query itself is restart-safe because due timers are a property of the
  `timers` *table*, not of in-memory ticker state.
- *Multi-node*: **not free** — one ticker per BEAM node means N nodes each
  firing their own tick concurrently against the same tenant's `timers` rows
  unless a claim mechanism prevents double-firing. This is exactly why §3
  (claim mechanism) is a separate, load-bearing decision underneath this one:
  the ticker only decides *when* a node asks "what's due"; `FOR UPDATE SKIP
  LOCKED` (§3) is what makes concurrent nodes asking that question at the
  same moment safe rather than a double-fire hazard.
- *A firing timer raising*: the ticker's own tick handler must catch
  per-timer exceptions itself (§5 specifies exactly how: each timer fires in
  its own transaction, a raise there rolls back only that transaction and is
  caught before it can propagate to the `GenServer`'s own `handle_info/2`
  return, so one bad timer never crashes the ticker process or skips
  remaining due timers in the same tick).
- Cost: a small, fully-owned module (~one `GenServer`, using
  `Process.send_after/3` for the next tick, matching SCH-06's per-node
  independent jitter requirement directly — each node's ticker rolls its own
  jitter with no shared seed, which is trivially expressible as
  `:rand.uniform` at each `Process.send_after/3` call). No new dependency, no
  new migration for scheduler-internal bookkeeping (`timers` itself is
  REQ-186's own table, needed regardless of which mechanism wins here). Fits
  the existing `Task.Supervisor`-per-concern idiom this project's
  supervision tree already establishes (five separate `Task.Supervisor`s for
  five separate concerns, per `application.ex`'s own comments) — a sixth,
  scheduler-owned `Task.Supervisor` for the per-tick fire attempts is the
  same idiom, not a new one.

### 2c. Per-timer process (one process per pending timer, holding its own `Process.send_after/1` to its own `fire_at`)

- *Node restart*: **structurally the weakest option.** Every in-flight timer
  process is BEAM in-memory state; a node restart loses all of them
  instantly, and every one must be re-hydrated from the `timers` table on
  boot by re-scanning `status = pending` and re-spawning a process per row —
  which is itself a poll-shaped operation, so this option doesn't eliminate
  polling, it just relocates one polling pass to boot time and otherwise
  tries to avoid polling for everything after. It does not naturally handle
  SCH-05 (missed-timer catch-up while down) any better than 2b — the boot
  rescan has to do exactly the same `fire_at <= now()` catch-up query 2b's
  first tick does.
- *Multi-node*: worse than 2b, not better — now the claim mechanism has to
  arbitrate not just "which node's poll tick claims this row" but "which
  node's long-lived process for this specific timer ID is the canonical
  one," a second coordination problem (avoiding two nodes each spawning a
  live process for the same timer) layered on top of the first.
  `Letflow.Registry` (already in the supervision tree) could enforce
  uniqueness, but that only prevents two *processes on the same node*; a
  cluster-wide unique-registration mechanism across nodes is materially more
  machinery than SCH-02's row-claim story needs.
- *A firing timer raising*: contained to that one process (a crash there is
  isolated by the BEAM's own process boundary, matching Letflow's existing
  per-instance-process design precedent), which is a genuine strength — but
  it is bought at the cost of one live process per pending timer, which for
  a workload with (say) tens of thousands of pending reminder/escalation
  timers across many tenants is a materially heavier standing footprint than
  a single ticker process plus row locks, for no behavioural gain SCH-01/05/06
  actually need (nothing in SCH-01/02/05/06's specified behaviour requires
  sub-poll-interval firing precision — the spec's own maximum-latency bound
  is "one interval plus jitter").
- Cost: highest of the three, and it reproduces (at boot) the same polling
  operation the other two options do as their steady-state mechanism, while
  adding a live-process-per-timer memory/registration cost the spec's own
  latency bound does not require.

### Recommendation: 2b, a supervised `GenServer` ticker

**Adopted.** It satisfies all three survival properties (node restart via a
stateless first-tick catch-up; multi-node via the claim mechanism decided in
§3, which is needed regardless of which mechanism wins here; a single
timer's raise via a per-timer transaction boundary decided in §5) with no new
dependency, fits the project's existing `Task.Supervisor`-per-concern idiom,
and matches SCH-02's own specified behaviour ("a background poller at a
configurable interval") literally — SCH-02 already describes a ticker, not a
job queue or a process-per-timer design. 2a (Oban) is rejected per §3's own
explicit REVIEWER-gated decision below, not because it fails any of the three
survival properties (it does not) but because it is unneeded machinery for a
behaviour this codebase can implement natively at lower operational cost, and
it introduces a second, overlapping retry-counting mechanism (Oban's own
`max_attempts` vs. REQ-186's domain `fire_error_count`) that would need
careful reconciliation for no corresponding behavioural gain. 2c (per-timer
process) is rejected because it is strictly costlier than 2b on both node
restart and multi-node while buying isolation 2b already gets for free via
per-timer transactions.

## 3. Decision 2 — Oban adoption (explicit YES/NO, REVIEWER sign-off)

**Decision: NO. Oban is not adopted as a `mix.exs` dependency.**

Reasoning (restated concisely from §2a/§2b above, as this decision's own
record independent of the mechanism comparison):

1. SCH-02's specified behaviour — a single configurable-interval poller,
   `SELECT ... FOR UPDATE SKIP LOCKED`-claiming due rows, firing each in one
   transaction — is exactly what a supervised `GenServer` ticker plus a plain
   SQL claim query implements, with no gap Oban's extra machinery closes.
   Oban is designed for a materially larger problem (arbitrary background job
   types, queues, priorities, cron scheduling, telemetry/web dashboard,
   unique jobs, batches) than "poll one table on an interval and fire due
   rows," and this requirement's own scope (§SCOPE point 1) asks for the
   *poll loop*, not a general job-processing subsystem.
2. Oban's job table is not schema-per-tenant by construction, which would
   require `timers`' tenant-scoped identity to be smuggled through Oban job
   `args` rather than living in the row the poller directly claims — an
   impedance mismatch against Decision 0003 Decision B's schema-per-tenant
   model that a native ticker + direct SQL claim does not have.
3. Oban's own attempt/retry counting would sit alongside, not replace,
   REQ-186's domain-specified `fire_error_count`/`failed`/DLQ machinery
   (ported deliberately from R-Co's ISS-303 fix, not something this project
   is free to redesign), producing two overlapping retry counters that would
   need explicit reconciliation with no stated behavioural benefit.
4. Following this project's own precedent (`docs/migration/decisions/0003`
   and the REQ-148 tv-labs/lua precedent this requirement is explicitly
   modelled on): a new top-level dependency is adopted only when it closes a
   gap the existing toolchain cannot close natively at comparable cost. This
   gap does not qualify — mix.exs already has `ecto_sql`/`postgrex`, which is
   sufficient for a `FOR UPDATE SKIP LOCKED` claim query and a `GenServer`
   ticker to implement SCH-02 fully.

**REVIEWER sign-off:** ✅ **RECORDED, 2026-08-29, WF02-REQ185-20260829 Step
2d.**

> **REVIEWER SIGN-OFF: AGREE with NO — Oban is not adopted.** Grounds 1, 3
> and 4 above are independently sufficient and I concur with each on their
> own terms, not as a rubber stamp: (1) SCH-02's specified behaviour is
> materially narrower than what Oban is built for, and this project's own
> standing precedent (decision 0003's dependency-adoption reasoning, the
> REQ-148 tv-labs/lua precedent this artefact cites) already commits to
> "a new top-level dependency earns its place only when the existing
> toolchain cannot close the gap natively at comparable cost" — that bar is
> not met here, since `ecto_sql`/`postgrex` alone implement a `FOR UPDATE
> SKIP LOCKED` claim query and a supervised ticker with no gap left over;
> (3) is the strongest single ground on its own: Oban's own
> attempt/backoff counter would either have to be neutered
> (`max_attempts: 1`, the entire point of adopting a job-queue library for
> its retry semantics thrown away) or run in parallel with REQ-186's
> domain-specified `fire_error_count`/`failed`/DLQ state machine — ported
> deliberately, bit-for-bit, from R-Co's own ISS-303 fix, not a mechanism
> this project is free to redesign — producing two overlapping,
> hard-to-reconcile sources of truth for the same "how many times has this
> failed" question; (4) is not new reasoning invented for this decision,
> it is this project's own existing dependency-adoption norm applied
> consistently. Ground (2), the tenant-scoping impedance, I find real but
> only partially dispositive on its own — Oban could in principle be used
> purely as a cluster-wide "run this tick once" driver (Oban Cron) while
> the actual per-tenant-schema `FOR UPDATE SKIP LOCKED` claim query stays
> custom against `timers` directly, which would blunt the args-smuggling
> objection considerably; I note this so a future reader doesn't treat
> ground 2 as air-tight in isolation. It does not change the verdict,
> because grounds 1/3/4 do not depend on it and are sufficient alone. I
> also independently confirm the design's own claim that Oban is rejected
> on cost/duplication grounds, not because it fails any of the three
> survival properties (node restart, multi-node, per-timer isolation) —
> the artefact is honest about this distinction (§2a, §3 point 1) rather
> than overstating the case against Oban, which is itself a point in this
> artefact's favour as a decision record.
>
> **Supervision-idiom check (task acceptance criterion 2):** the
> recommended 2b design (a supervised `GenServer` ticker added to
> `lib/letflow/application.ex`'s tree, with a sixth `Task.Supervisor` for
> per-tick fire attempts) is consistent with this project's existing
> `Task.Supervisor`-per-concern idiom, confirmed directly against
> `lib/letflow/application.ex`'s current five `Task.Supervisor`s
> (`SandboxPool`, Engine plugin, Lua, Wasm module registry, Wasm capability
> gate, Wasm module version registry) — a sixth for scheduler fire attempts
> follows the same established pattern, not a new one. One
> non-blocking note for REQ-186 to resolve concretely, not a defect in
> this artefact: §2b's "sixth Task.Supervisor" line and §7's "each timer
> fires in its own transaction, caught locally via `Repo.transaction/1`"
> line describe two different isolation mechanisms (a process boundary vs.
> a transaction/rescue boundary) without stating whether REQ-186 uses one,
> the other, or both together — this is appropriately left to REQ-186 (this
> artefact decides the claim/error-taxonomy/DLQ questions, not fire-loop
> implementation shape), but REQ-186's own design should state explicitly
> which isolation mechanism(s) it uses and why, rather than silently
> picking one.
>
> **Decision-record consistency confirmed:** §1, §6 and §8 correctly treat
> `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B as
> binding table placement (schema-per-tenant, `tenant_id` retained
> intra-schema) without silently reopening it — §6 explicitly rejects the
> global-queue alternative *because* it would conflict with Decision B,
> and §8's DLQ write path is correctly tenant-scoped via
> `Letflow.Dlq.enqueue/2`'s `opts[:prefix]`, matching Decision 0003's
> addendum on `tenant_id` derivation from the resolved schema rather than a
> caller-supplied field. No decision in this artefact contradicts or
> quietly re-decides 0003 or any other `docs/migration/decisions/` record.

## 4. Decision 3 — claim mechanism, and the ISS-301 correction

PROVENANCE (historical, not current decision authority):
**Decision: `SELECT ... FOR UPDATE SKIP LOCKED` is the claim mechanism.**
This departs from SCH-02's literal text ("the scheduler MUST acquire a
PostgreSQL advisory lock on the timer's ID") — that per-timer advisory lock
is **not** carried into Letflow's design, on the strength of the correction
this requirement's own source material states R-Co itself made:
`src/design/scheduler-concurrency-epic3.md`'s ISS-301 section is cited (see
§0's verification caveat — not independently re-checked against R-Co this
session, but recorded here per the requirement text's own instruction) as
having **removed** R-Co's per-timer `pg_try_advisory_xact_lock` block
(`scheduler.zig` L207-242) as redundant, on four stated grounds: the row is
already exclusively locked by `FOR UPDATE SKIP LOCKED` in the same
transaction; the advisory key was UUID-derived and so had identical
per-timer granularity to the row lock; the transaction-scoped advisory lock
had identical lifetime to the row lock; and its failure path returned a
contention outcome `FOR UPDATE SKIP LOCKED` already produces natively (the
row silently isn't selected by the skipping node). **A later reader of this
artefact must not "restore" that per-timer advisory lock** — it is a
deliberately-removed redundant mechanism, not an oversight in this design.

Concretely, REQ-186's poll query (the shape this artefact hands to REQ-186,
not implemented here) is: for a given tenant schema, select up to the
configured `max_timers_per_cycle` rows where `status = 'pending' AND fire_at
<= now()`, ordered by `fire_at`, using `FOR UPDATE SKIP LOCKED` inside the
firing transaction, so that two nodes polling the same tenant schema
concurrently each get disjoint row sets — neither blocks the other, and
neither double-fires a row the other has already claimed.

The one advisory lock this artefact's source material says survives R-Co's
own design is **session-level**, not per-timer: `pg_try_advisory_lock` with a
fixed, non-runtime-derived constant, held on a dedicated connection for the
duration of a startup sweep, so exactly one node in a multi-node deployment
runs that sweep. Whether Letflow needs an equivalent is §5's own decision,
not this one — this section's decision is the per-timer claim mechanism
only, and it is `FOR UPDATE SKIP LOCKED`, full stop.

## 5. Decision 4 — startup-sweep lock (ISS-302 equivalent)

**Decision: NO, Letflow does not need a session-level startup-sweep advisory
lock equivalent to R-Co's ISS-302 mechanism.**

Reasoning: ISS-302's lock exists (per this requirement's source material) to
prevent two nodes in an HA deployment from *both* running a
missed-timer-catch-up sweep on simultaneous restart. In R-Co's design that
sweep is described as a distinct operation from steady-state polling — a
special "sweep overdue timers" pass gated by its own session-level lock, run
once at startup. **Letflow's design does not have a separate sweep pass to
gate**, because of a property already established in §2b: the recommended
ticker's ordinary steady-state poll query — `status = 'pending' AND fire_at
<= now()` — is *already* the correct query for catch-up. A timer that became
overdue while every node was down is simply a `pending` row whose `fire_at`
is in the past by more than one poll interval; it is claimed by the very
first ordinary tick after any node comes back up, via the exact same `FOR
UPDATE SKIP LOCKED` claim query every other tick uses. There is no separate
"sweep mode" query whose concurrent-execution-by-two-nodes needs a session
lock to prevent, because there is no separate sweep code path at all — SCH-05
("every overdue timer fires, none skipped, none double-fired") is achieved
by the *ordinary* poll query being restart-tolerant by construction, not by
a dedicated recovery pass.

**What actually prevents double-firing on simultaneous multi-node restart**
is therefore the same mechanism as always: §4's `FOR UPDATE SKIP LOCKED`
claim inside each node's own poll transaction. If two nodes' tickers both
fire their first tick within the same instant after a simultaneous restart,
each executes its own `SELECT ... FOR UPDATE SKIP LOCKED`-guarded claim
query concurrently; Postgres row-level locking guarantees each due row is
claimed by exactly one of the two transactions, with the other seeing it
skipped (not blocked, not erroring) rather than double-claimed. This is
identical to steady-state concurrent polling from §4 — "simultaneous
restart" is not a distinct hazard from "two nodes polling at the same
moment," which the claim mechanism already covers unconditionally, at every
tick, forever, not just at startup. A dedicated startup lock would therefore
be solving a problem the per-tick claim mechanism already solves generally;
adding one would be duplicate machinery with no additional safety property.

## 6. Decision 5 — poller vs. multi-tenancy, with a quantified cost

**Decision: the poller iterates tenant schemas per tick** (not one global
queue), using the existing `tenant_schemas` registry
(`Letflow.TenantProvisioning.Registration`, verified to exist in §1) as the
enumeration source, running its `FOR UPDATE SKIP LOCKED`-guarded claim query
once per tenant schema per tick, under that schema's `:prefix`.

Rejected alternative — **one global queue**: would require a single
cross-tenant `timers`-equivalent table living outside any tenant schema, in
direct conflict with Decision 0003 Decision B, which already places
`timers` inside each tenant's own Postgres schema (matching R-Co's own
migration 081 note that "timers lives in per-tenant schemas only," restated
in REQ-186's own SCOPE). Decision B is out of scope to reopen here (the
handoff explicitly excludes it — "Decision 0003 Decision B binds the TABLE
placement; it does not decide the POLLER's iteration strategy"), so a global
queue is not an available option without contradicting an already-decided
record; per-tenant-schema iteration is the only strategy consistent with
where the row-level source of truth (`timers`) actually lives.

**Quantified cost at 500 tenants** (the requirement's own stated example
count): each tick issues one `SELECT ... FOR UPDATE SKIP LOCKED LIMIT
<max_timers_per_cycle>` query per tenant schema, so **500 queries per tick**,
against 500 different Postgres schemas over the same physical connection
pool (`Letflow.Repo`'s existing pool — no new pool is introduced). At the
default 5000 ms poll interval (REQ-186's stated default, unmodified by this
artefact), that is 500 queries every 5 seconds = **100 queries/second**
sustained against the primary database, purely from scheduler polling, before
any tenant has a single due timer. Each such query is a single-table
indexed lookup (REQ-186 specifies a `(fire_at) WHERE status = 'pending'`
partial index — the poller's only hot query, per that requirement's own
text) against a schema whose `timers` table is expected to hold at most a
few thousand pending rows per tenant in realistic usage (deferred-task/
reminder/escalation counts, not a high-volume event stream) — so each query
is a fast partial-index range scan, not a sequential scan, and the 100
qps figure is 500 short (millisecond-scale) queries per second, not 500
expensive ones. This is comparable in shape to any other per-tenant
maintenance sweep this architecture would need regardless of the timer
feature (i.e., paying an O(tenant count) query cost per tick is inherent to
schema-per-tenant plus "poll everything periodically," not specific to a bad
choice made here) — the requirement does not ask this artefact to eliminate
that cost, only to state it, which this section does: **100 qps at 500
tenants, one lightweight indexed query per tenant per 5-second tick,
scaling linearly with tenant count** (1000 tenants ⇒ ~200 qps, etc.). If this
linear-in-tenant-count cost becomes a real operational concern at some future
tenant count, the natural mitigation (sharding the tenant list across
multiple ticker instances/nodes, or batching several tenant schemas'
`search_path`s behind a single query via a `UNION ALL` across schemas) is
available but is explicitly **not decided here** — it is not needed at the
500-tenant scale this artefact is asked to quantify, and inventing it now
would be speculative machinery this requirement's own SCOPE (point 4) does
not ask for.

## 7. Decision 6 — locked / nothing-due / hard-error, and why "propagate everything" is wrong

**Decision: the recommended design distinguishes the three outcomes as three
structurally different results of the same per-tenant claim-and-fire pass,
never collapsed into one:**

1. **"No timer due"** — the `SELECT ... FOR UPDATE SKIP LOCKED` claim query
   for a given tenant schema returns **zero rows**. This is a normal,
   silent, expected outcome on the overwhelming majority of ticks (most
   tenants have no timer due most of the time) — nothing is logged, nothing
   is counted, the ticker simply moves to the next tenant schema (or the next
   tick if this was the last one).
2. **"Timer locked by another node"** — a row exists with `fire_at <= now()
   AND status = 'pending'`, but it is currently locked by another
   transaction (another node's concurrent poll of the same tenant schema, or
   — per §5 — the same row being claimed by two nodes' simultaneous
   post-restart first tick). `SKIP LOCKED` means this row is simply **absent
   from this node's result set** for this tick, exactly as if it weren't
   due yet. Structurally, from this node's point of view, a locked row and
   no-row-at-all are indistinguishable inside the claim query itself — and
   per this artefact's source material (§0's caveat noted), ISS-0618
   documents this exact collapse as a bug in R-Co's *original* implementation
   ("a due-but-locked timer and 'no due timer exists' both collapsed to the
   same `PollOutcome`"). Restated precisely: **this collapse between (1) and
   (2) is intentional and correct at the per-row level** (SKIP LOCKED's own
   semantics are what makes concurrent polling safe at all, per §4) — the bug
   ISS-0618 records is not that individual locked rows look like absent rows
   to the query (that's required for correctness), it is that a *hard error
   during firing* (item 3, next) was **also** being folded into that same
   "nothing to report" bucket at the *cycle-outcome* level, which is the
   actually-wrong collapse this design must not repeat.
3. **"Hard non-retryable error"** — a claimed row's own fire transaction
   raises for a reason unrelated to contention (the requirement's own
   example: a unique-constraint violation on the event idempotency key). This
   is **not** the same thing as "not claimed" — the row *was* successfully
   claimed and locked by this node; the failure happened afterward, inside
   the attempt to fire it. This outcome must be **visible and counted**,
   never silently swallowed: per §5's failure-accounting shape (REQ-186's own
   SCOPE point 4, which this artefact's design must be consistent with), a
   raise during a single timer's fire transaction rolls back *only that
   timer's transaction*, then in a *separate* transaction increments that
   timer's `fire_error_count`, and — critically — **the poll cycle continues
   to the next due timer in the same tick**, it does not stop.

**Why "propagate every error out of the fire path" is the wrong fix,** stated
directly per the requirement's own instruction: if a fire attempt's
exception is allowed to propagate out of the per-timer fire step and up
through the tenant-schema poll loop (e.g. letting it crash the `GenServer`
tick's `handle_info/2`, or letting it bubble out of an `Enum.each`/`for` over
the claimed batch without being caught per-item), the **entire remaining
batch for that tick — every other due timer, in every other tenant schema
not yet visited — never gets attempted**, because the loop that would have
reached them already died. Concretely, this means: the *first* timer whose
firing hits a genuine hard error (say, a unique-constraint violation) not
only fails to increment its own `fire_error_count` on that attempt (the
crash happens before or during the accounting step, depending on exactly
where it's caught) but also **prevents every other due timer behind it in
the same cycle from being attempted at all** — so `fire_error_count` for
*those* timers doesn't advance either, because they were never even tried.
Since REQ-186's terminal-state transition (`pending` → `failed`, landing in
the DLQ per §7 below) is gated on `fire_error_count` reaching a configured
maximum via repeated *attempts*, an approach that stops the loop on the first
error means `fire_error_count` can never climb past whatever it reached
before the crashing attempt — the timer never reaches `failed`, never reaches
the DLQ, and (per ISS-0618, as this requirement's source material describes
it) this is exactly the ISS-303 bug: a single bad timer permanently stalls
recovery/accounting for every timer that would otherwise have been polled
after it, not just itself. The recommended design avoids this by making the
unit of failure isolation the **single timer's own transaction**, caught
locally (each per-timer fire attempt wrapped so a raise there is trapped
before it can escape the per-timer step — e.g. `Repo.transaction/1`'s own
return-value contract already turns an inner raise into a normal `{:error,
_}`-shaped rollback rather than letting it propagate, when the raise
originates from application code called inside the `Repo.transaction/1`
fun and is caught with a `rescue`/`try` there before re-raising anything),
so that one bad timer's failure is recorded and the loop unconditionally
continues to the next claimed timer, then the next tenant schema, then the
next tick — matching REQ-186's own acceptance-criterion framing ("a fire
attempt that raises increments `fire_error_count` and leaves the timer
'pending', AND the remaining due timers in that same poll cycle are still
attempted").

## 8. Decision 7 — exhausted-retry timer and `dlq_entries`

**Decision: YES.** An exhausted-retry timer (one whose `fire_error_count`
reaches the configured maximum, per §6/REQ-186's own `max_fire_retries`
default of 3) lands in REQ-176's `dlq_entries` table with `entry_type =
"timer"`, at the same moment it transitions to `status = "failed"` with
`failed_at` set. This is not left open for REQ-186 to decide.

Grounds, verified in §1: `dlq_entries.entry_type` is a plain `:string`
column with no DB-level enum/CHECK restricting its values (confirmed by
reading the migration directly — comment states this is deliberate,
"extensible"), `Letflow.Dlq.enqueue/2` already accepts an arbitrary
`entry_type` string in its typed `enqueue_attrs()` map with no allow-list
gate in the function itself, and REQ-176's own requirement text (cited in
REQ-185's own description) already reserves the literal value `"timer"` and
names "scheduler/timer entries" as a not-yet-populated category — meaning
REQ-176 was filed with this exact use in mind, not a general "any string
works" affordance being opportunistically repurposed. There is no competing
mechanism in this codebase for "a thing that needs human/operator attention
after exhausting automatic retries" — `dlq_entries` is that mechanism for
every other domain that has needed it so far (SERVICE_TASK dispatch
failures, per the requirement's own cross-references), and a timer that
exhausts `fire_error_count` is the same shape of problem: an automatic
process gave up, a human needs visibility and a retry/discard action, and
`Letflow.Dlq.list/2`'s existing `entry_type` filter already supports
narrowing a listing to just `"timer"` rows with no further work.

REQ-186's own moduledoc (per its acceptance criteria, which already
anticipate this — "produces exactly one `dlq_entries` row with `entry_type
\"timer\"` (or whatever REQ-185's artefact decided, quoted in the
moduledoc)") should quote this section's decision verbatim: **exhausted-retry
timers enqueue into `dlq_entries` with `entry_type: "timer"`**, via
`Letflow.Dlq.enqueue/2`, in the same transaction (or an immediately
subsequent one under the same `prefix`) as the `pending` → `failed`
transition, using the tenant schema the timer's own row already lives in
(no cross-schema write — `Letflow.Dlq.enqueue/2` is itself tenant-scoped via
`opts[:prefix]`, matching where `dlq_entries` itself lives per Decision B).
What specific fields populate `enqueue_attrs()`'s optional keys
(`reference_id`, `reason`, `error_detail`, `error_chain`, etc.) for a timer
entry is left to REQ-186 to specify concretely against its own knowledge of
what error information is available at the point `fire_error_count` reaches
its maximum — this artefact decides the yes/no and the `entry_type` value
only, per the acceptance criterion's own scope ("answering yes or no rather
than leaving it to REQ-186").

## 9. Summary table (all seven decisions, one place)

| # | Question | Decision |
|---|---|---|
| 1 | Firing mechanism | Supervised `GenServer` ticker (§2), not Oban, not per-timer processes |
| 2 | Adopt Oban? | **NO** — reasoning recorded §3; REVIEWER sign-off **RECORDED** (2026-08-29, agree) |
| 3 | Claim mechanism | `FOR UPDATE SKIP LOCKED`; R-Co's per-timer advisory lock is deliberately NOT restored (ISS-301) |
| 4 | Startup-sweep lock (ISS-302 equivalent) | **NO** — ordinary poll query is catch-up-safe by construction; `SKIP LOCKED` alone prevents double-sweep on simultaneous restart |
| 5 | Poller vs. multi-tenancy | Iterates tenant schemas per tick via the `tenant_schemas` registry; ~100 qps at 500 tenants (5000 ms interval, one indexed query per tenant per tick) |
| 6 | locked / nothing-due / hard-error | Three distinct outcomes (§7); per-timer transaction isolation lets the loop continue; "propagate everything" is wrong because it stalls `fire_error_count` for every timer behind the crashing one |
| 7 | Exhausted timer → DLQ? | **YES** — `dlq_entries` with `entry_type: "timer"` |

## 10. What REQ-186/187/188 inherit, unmodified

- `timers` schema/migration, poll-and-fire context function, missed-timer
  recovery, failure accounting, configuration defaults — all REQ-186's own
  SCOPE, built against the mechanism/claim/tenant-iteration/error-handling
  decisions recorded above.
- REQ-187's engine wiring (arm-on-arrival, cancel-on-completion, the
  `transition/3` purity constraint) is unaffected by any decision here — none
  of §§2-8 touch the engine's transition boundary.
- REQ-188's recurrence/escalation timer work builds on the same `timers`
  table and poller this artefact specifies; nothing here precludes it.

## 11. Open questions this artefact deliberately does NOT resolve (not silently assumed)

- **OQ-1**: The exact `enqueue_attrs()` field mapping for a timer's DLQ entry
  (§8's last paragraph) — left to REQ-186, as the acceptance criterion
  itself scopes it.
- **OQ-2**: Whether/when the 500-tenant-scale linear query cost (§6) needs a
  mitigation (sharded ticker instances, cross-schema batched queries) — not
  decided here; not needed at the scale this artefact was asked to quantify.
- **OQ-3**: This artefact's R-Co citations (ISS-301, ISS-0618) were not
  independently re-verified against R-Co source this session — see §0.
  Re-verify when R-Co is reachable; if either citation turns out to be
  inaccurate, this artefact's §4/§7 reasoning (not its decisions, which
  stand independently on Letflow-side reasoning) would need a citation
  correction, not necessarily a decision reversal.
