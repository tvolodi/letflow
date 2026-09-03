# REQ-216 — Admission-control core: `Letflow.Admission`

Closes ISS-0431 part 1 (GH#835, queue task 431). Core module only — no HTTP or
Poller wiring (that is REQ-217/REQ-218). This document specifies interfaces,
`@spec`/`@type` shapes, state shapes, the supervision-tree child spec, and
crash-recovery semantics. It contains no implementation code.

## 0. Decisions this design inherits, not re-litigates

Per `docs/requirements.yaml` REQ-216 (see also ISS-0431 diagnosis), the
following are already resolved and are not reopened here:

1. Hand-rolled, pure-BEAM GenServer-based counting semaphore(s) — no new
   dependency (decision 0014's method applied).
2. BOTH a global cap and per-tenant caps, composing (not either alone). A
   `{:tenant, _}` acquisition consumes the SAME global budget as `:global`
   acquisitions.
3. Global cap = `pool_size - reserved_headroom`, read from the SAME
   `config :letflow, Letflow.Repo, pool_size:` key `config/runtime.exs`
   already writes. `reserved_headroom` is a separate config key, default 2.
4. Response-shape mapping (`Letflow.Api.Response.service_unavailable/2`) is
   out of scope for this module — it returns a typed outcome, callers
   (REQ-217/218) do the mapping.
5. Tier-weighted per-tenant caps are OUT OF SCOPE — `Letflow.Identity.Tenant`
   (`lib/letflow/identity/tenant.ex`, read in full) has only `slug`,
   `display_name`, `status`, `idp_realm_id` — no tier/plan field. Equal
   fair-share is the only defensible default absent a data model to weight
   by. Recorded as a genuinely open product question (§9 Open Questions).

## 1. Process shape: one GenServer, not one-per-pool

**Decision: a single supervised `GenServer` (`Letflow.Admission`) holds BOTH
the global counter and the map of per-tenant counters in one state term.**

Rejected alternative: a `GenServer` per pool (one process owning the global
counter, one-per-tenant processes or a `DynamicSupervisor` owning per-tenant
counters).

**Atomicity algorithm (stated once, here, as the single source of truth —
§8's traceability table for AC3 refers back to this paragraph rather than
restating or hedging it):** a `{:tenant, schema}` call is handled as ONE
`handle_call/3` clause that first EVALUATES both admission conditions as a
pure, read-only computation against the current state — `global_in_use <
global_cap` AND `tenant.in_use < per_tenant_cap` — WITHOUT mutating
`global_in_use`, the tenant's `in_use`, or `refs` yet. Only if BOTH
conditions hold does the same `handle_call/3` clause then mutate BOTH
counters (increment `global_in_use`, increment the tenant's `in_use`) and
insert the new ref into `refs`, all in that one callback invocation before
returning `{:ok, ref}`. If either condition is false, the clause returns
`{:error, :capacity}` immediately with ZERO mutation of any counter or of
`refs` — neither counter was ever incremented, so **there is no rollback
step anywhere in this design**: nothing is ever provisionally granted and
then undone. (This design deliberately rejects the alternative two-phase
"grant the per-tenant slot, then check global, then roll back the per-tenant
grant if global fails" sequence — that shape is strictly more complex than
check-both-then-mutate-both for no additional correctness benefit, since
single-process atomicity already makes the read of both conditions and the
mutation of both counters indivisible within one `handle_call/3`; a rollback
step would only be needed if some observer could see the per-tenant grant
before the global check ran, which cannot happen when both conditions are
evaluated before either counter is touched.) This same order applies
identically to `:global` calls, minus the per-tenant half of the condition.

Reasoning for the single-process shape that makes this possible:

- AC3 requires a `{:tenant, schema}` acquisition to check AND decrement
  (`:global` cap and per-tenant cap) as a single atomic unit, with no
  observable window in which one counter reflects the grant and the other
  does not. Two separate processes checking two counters cannot make this
  atomic without a second coordination mechanism (a lock, a two-phase
  commit, or funnelling one call through the other) — which would just
  relocate the single serialization point this design already gets for free
  from one `GenServer`'s mailbox.
- `Letflow.SandboxPool` (REQ-039/ISS-0224, read in full) is itself prior art
  for exactly this reasoning: it is one process precisely because two callers
  racing for the last slot must never both win, and a single mailbox is what
  provides that arbitration natively. The same argument applies here, with
  one addition (two nested resources instead of one), which only strengthens
  the case for one process — splitting them is what would introduce the
  cross-process coordination hazard SandboxPool's own design deliberately
  avoided for a simpler, single-resource case.
- State size is small and bounded in the common case (one integer for global
  usage, one map entry per currently-tracked tenant — see §3 for the
  unbounded-growth question), so there is no throughput argument for
  sharding across processes: the mailbox serialization cost of one more
  `GenServer.call/3` per admission decision is the same order of magnitude
  REQ-039's own SandboxPool already accepts for the identical reason.
- Unlike `Letflow.InstanceSupervisor` (one process **per** long-lived,
  autonomous workflow instance, for crash isolation between them), admission
  bookkeeping is not an autonomous actor with its own lifecycle — it is inert
  counter state, the same category SandboxPool's own moduledoc already
  distinguishes ("a claimed sandbox is inert data between `claim` and
  `release`, unlike an `InstanceSupervisor` actor"). That distinction argues
  against a process-per-tenant shape here for the same reason it argued
  against a process-per-claim shape in SandboxPool.

**No wait queue.** REQ-216 requires immediate rejection
(`{:error, :capacity}`) on exhaustion, not queueing. `Letflow.SandboxPool`'s
`waiting` FIFO-of-monitored-callers-with-per-waiter-timeout shape (its
`handle_queue_or_reject/3`, `:claim_timeout` message, `Process.monitor/1` on
the caller) is cited by ISS-0431 only as prior art for a wait-queue SHAPE
this module MAY reuse if a future requirement adds queueing — it is
explicitly NOT part of this design. `try_acquire/1` is a single
synchronous decision made against current state with no parking, no
`Process.send_after/3` timer, and no `waiting` field in state.

## 2. Public API

Module: `Letflow.Admission`.

- `@type pool_selector :: :global | {:tenant, tenant_schema :: String.t()}`
- `@type admission_ref :: opaque term()` — see §2.1 for its concrete shape
  (documented here as a private implementation detail callers must not
  pattern-match on; only `release/1` consumes it).
- `@spec try_acquire(pool_selector(), server :: GenServer.server()) :: {:ok, admission_ref()} | {:error, :capacity}`
  — `server` defaults to `__MODULE__`, matching `Letflow.SandboxPool.claim/2`'s
  own `pool \\ __MODULE__` convention, so tests can start an isolated instance
  under a distinct name without touching the globally-registered one.
- `@spec release(admission_ref(), server :: GenServer.server()) :: :ok`
  — `server` also defaults to `__MODULE__`. `release/1` (arity-1, `server`
  defaulted) is the primary documented arity per REQ-216's own text; arity-2
  exists for test isolation, mirroring SandboxPool's `release/2`.
- `@spec start_link(opts :: keyword()) :: GenServer.on_start()` — accepts
  `:name` (default `__MODULE__`), `:pool_size` and `:reserved_headroom`
  overrides for tests (mirrors `SandboxPool.start_link/1`'s
  `Keyword.get_lazy/3` pattern: absent options fall back to
  `Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]` and
  `Application.get_env(:letflow, :admission, [])[:reserved_headroom]`,
  default `2`).

No HTTP-path or Poller-specific vocabulary anywhere in this module or its
`@doc`/`@moduledoc` strings — `pool_selector()`'s two variants are named
generically (`:global`, `{:tenant, schema}`), never e.g. `:http_request` or
`:poller_tick`.

### 2.1 `admission_ref()` shape

`release/1` must be able to free EXACTLY the budget(s) a given `try_acquire/1`
call consumed, with no ambiguity and no re-derivation from mutable state (a
tenant's cap can change between acquire and release as the tracked-tenant set
changes — see §3 — so `admission_ref()` must carry everything `release/1`
needs, not a key to look something up that may have since changed shape).

Specified as a tagged struct (or equivalently a tagged tuple; struct chosen
for pattern-match clarity and to make an accidental cross-module literal
construction visible in review — mirrors `SandboxPool.SandboxClaim`'s own
"plain struct, not persisted" precedent). `Letflow.Admission.Ref` carries
exactly two fields:

- `id` — a fresh, unique `reference()` minted per successful `try_acquire/1`
  call (via `make_ref/0`). This is also the key the server-side `refs` map
  (§2.2) stores that admission's bookkeeping under internally.
- `pool` — the same `pool_selector()` (`:global` or `{:tenant, schema}`) the
  call was made with, i.e. which budget(s) this ref must free on `release/1`.

Rationale for carrying `pool` on the ref rather than requiring `release/1` to
be told separately: it makes `release(ref)` a true single-argument free
operation (matching REQ-216's own literal `release(admission_ref()) :: :ok`
signature) with no possibility of the caller passing a mismatched selector.
`id` (a fresh `reference()`, from `make_ref/0`) is what the server-side state
is actually keyed by — see §2.2 — never a caller-visible or caller-derivable
sequence number, so a caller cannot forge or guess a ref for a slot it never
acquired.

`release/1` is defined as: **idempotent up to the ref's own state
membership** — releasing a ref whose `id` is not present in the
server's live-refs set (already released, or never acquired, e.g. a
hand-constructed struct) is a documented no-op (`:ok`, no counter
mutation), never a raise. This mirrors `SandboxPool.release/2`'s own contract
(`{:error, :not_found}` there — the difference here is `release/1`'s REQ-216
literal signature is `:ok`-only, so REQ-216's contract is a strict subset
that treats "already gone" as success rather than as an error return REQ-216
does not have a value shape for).

### 2.2 Server state shape

The GenServer's state term holds four fields:

- `global_cap` — a positive integer, computed exactly once, at `init/1`
  time: `pool_size - reserved_headroom`, floored at 1 (a computed value
  below 1 is clamped rather than left negative or zero — see §9 OQ-1 for
  whether this should instead be a boot-time error). Fixed for the life of
  the process; recomputed only by a restart (§5).
- `global_in_use` — a non-negative integer counter, the number of currently
  held admissions across both `:global` and `{:tenant, _}` acquisitions
  combined.
- `tenants` — a map from tenant-schema string to a small record holding that
  tenant's own `in_use` count only. Deliberately holds NO stored per-tenant
  cap: the cap is recomputed on demand (see below) from the live tenant
  count, so it cannot drift from `map_size(tenants)` the way a cached value
  could.
- `refs` — a map from each currently-live admission's `id` (the same
  `reference()` value carried on its `Letflow.Admission.Ref`, §2.1) to the
  `pool_selector()` it was acquired against. This is the authoritative
  membership set `release/1` checks against, and the single source of truth
  the two counters above are a running summary of: `global_in_use` always
  equals the number of entries in `refs`, and a given tenant's `in_use`
  always equals the number of `refs` entries whose selector names that
  tenant. The counters are kept as separate running totals — rather than
  recomputed from `refs` on every call — purely so an admission decision is
  an O(1) comparison; `refs` exists so `release/1` and crash bookkeeping have
  an authoritative membership check, and so a mismatched or forged ref
  cannot under- or over-release (§2.1).

**Per-tenant cap is computed, not stored.** On every `{:tenant, _}`
admission decision, the per-tenant cap for that tenant is derived fresh as:
the global cap divided by the number of currently-tracked tenants (integer
division, discarding the remainder), with a floor of 1 if that division
would otherwise yield 0. Deriving it fresh on every call — rather than
caching a value per tenant entry and invalidating it when the tracked set
changes — is what makes AC5's requirement (the cap recomputes as the tracked
set changes) true by construction, with no second code path that could let a
cached value drift out of sync with the live tenant count.

**Invariant: recomputed caps gate only FUTURE decisions, never retroactively
revoke an already-held admission.** Because the per-tenant cap is derived
fresh on every `{:tenant, _}` `try_acquire/1` call rather than stored, the
divisor (`map_size(tenants)`) can grow between two admissions held by the
SAME tenant, shrinking that tenant's computed share below its current
`in_use` count — e.g. tenant A holds 3 refs under a 3-tenant/10-cap split
(`floor(10/3) = 3`); a 4th tenant then makes its own first attempt, and A's
NEXT computed cap is `floor(10/4) = 2`, one below A's current `in_use`. This
design states explicitly: a newly-recomputed cap is consulted ONLY at the
moment of a NEW `try_acquire/1` decision for that tenant — it is never
compared against, and never used to forcibly revoke, close, or invalidate,
any `admission_ref()` issued under a previously-larger cap. Concretely:
there is no mechanism anywhere in this design that walks `refs` after a
recomputation and releases entries to bring a tenant back under its new
cap, no error raised on that holder's own eventual `release/1` call (§2.1's
ordinary idempotent-release rule applies to it exactly as to any other ref,
with no "was this cap exceeded when issued" check), and no forced-release
message sent to the holder's process. A tenant already sitting over its
newly-shrunk share simply cannot successfully call `try_acquire/1` again
(the `in_use < per_tenant_cap` condition in §1 evaluates false for it) until
enough of its own `release/1` calls bring `in_use` back under the new,
smaller cap — but every ref it already holds remains valid and freely
releasable for its full natural lifetime. This is a deliberate design
property (fairness is enforced prospectively, on new admission decisions
only, never by retroactively clawing back a grant already made), not an
unconsidered gap.

## 3. Lazy tenant-entry creation and unbounded-growth handling

**Creation:** a `{:tenant, schema}` entry is created in `state.tenants` the
first time `try_acquire({:tenant, schema})` is called for a schema not
already present, with `in_use: 0`, BEFORE the admission decision is
evaluated (so that tenant is immediately counted in `map_size(state.tenants)`
for the fair-share division — AC5's "3 tracked tenants... each gets
floor(10/3)" scenario requires the acting tenant to already be one of the 3
at decision time, not added after). This entry is created regardless of
whether the ensuing admission succeeds or is rejected — an attempt itself is
what REQ-216's decision-2 text ties tracking to ("tenants that have made an
admission attempt in a rolling window"), not only a successful one, since a
rejected tenant is exactly the case fair-share exists to keep counted against
its own share rather than silently dropped from the divisor.

**Cleanup — addressed explicitly, not left unbounded:** a tenant that stops
making admission attempts leaves a `%{in_use: 0}` entry in `state.tenants`
indefinitely under this design. This is a real, acknowledged bound: state
growth is bounded by the count of DISTINCT tenant schemas that have EVER
made at least one admission attempt since the last process restart, not by
concurrently-active tenants. Accepted for this requirement, not deferred
silently, for two reasons:

1. Removing a zero-`in_use` entry the moment it hits zero would make
   fair-share division unstable in exactly the pathological way decision-2's
   own text warns against for the opposite case: a tenant idling between
   bursts (a normal, expected pattern for scheduled/periodic tenant workloads)
   would flip out of the divisor and back in on every burst boundary,
   making every OTHER tenant's cap oscillate on a schedule unrelated to their
   own behavior. A stable divisor across a tenant's idle periods is more
   correct than a shrinking one, at the cost of the bound below.
2. The realistic bound is the platform's own tenant count (schema-per-tenant
   provisioning, decision 0006), which is an operationally-controlled,
   low-cardinality number (tenant creation is an explicit administrative
   act, `Letflow.Identity`), not attacker- or request-volume-controlled —
   unlike e.g. an unbounded per-IP or per-request-id map, this cannot be
   driven to unbounded size by request traffic alone, only by actually
   provisioning that many tenants.

REQ-216's own "rolling window" phrase in decision-2 text is NOT implemented
as a real time-decay mechanism in this core module — no window, no expiry
timer, no last-seen timestamp is tracked. This is a deliberate, flagged
narrowing: implementing actual time-windowed eviction (with its own decision
about window length, sweep interval, and what "currently tracked" means
under concurrent expiry) is exactly the kind of independent product/tuning
decision decision-2's own text defers for tier-weighting, and REQ-216's
acceptance criteria test only the STATIC equal-split arithmetic (AC5), not
eviction behavior — so implementing it now would be scope invented beyond
what AC5 tests, per this project's anti-pattern of inventing unrequested
mechanism. Recorded as Open Question OQ-2 (§9): a real cardinality bound
(time-windowed eviction, or an LRU cap on `map_size(state.tenants)`) is left
for a follow-up requirement if unbounded growth is later observed to matter
in practice.

**This is a self-acknowledged narrowing of REQ-216's own requirement text,
not a pre-existing exclusion the requirement text itself already carved
out** (unlike OQ-5/tier-weighting, which ISS-0431's own decision text names
as out of scope in its own words). The requirement text's decision-2
paragraph explicitly says per-tenant tracking is scoped to "tenants that
have made an admission attempt in a ROLLING WINDOW," and this design
knowingly implements a permanent-retention approximation instead (§3
above) with no time-decay mechanism at all. Per
`docs/agents/instructions/core-directives.md`'s "No Issue Left Local-Only"
rule, a self-acknowledged scope-narrowing like this may not be left as a
design-doc-only Open Question with no further tracking — CODE-DESIGNER
does not have the authority to register a queue/GitHub issue directly
(`docs/agents/protocols/ISSUE_QUEUE.md` reserves `register_task` to ORCH).
**This finding is therefore being reported to ORCH in this rework's
handoff (`result.summary`) for `register_task` issue registration** —
title/description/severity/affected-files to be filed as: "REQ-216's
`Letflow.Admission` design implements permanent per-tenant-entry retention
instead of the requirement text's own 'rolling window' semantics; no
time-decay/eviction exists," severity minor (bounded by administratively-
controlled tenant cardinality per §3's reasoning, not attacker- or
request-volume-controlled), affected file
`lib/letflow/design/req216-admission-control-core.md` (and, once
implemented, `lib/letflow/admission.ex`). OQ-2 below records the technical
open question for ELIXIR-DEV/a future requirement; this paragraph records
that the SAME finding is also being escalated to ORCH as required by
core-directives.md, so it does not stay local-only to this design doc.

## 4. Supervision-tree placement

`Letflow.Admission` is added to `Letflow.Application`'s `children` list
(`lib/letflow/application.ex`) as a plain supervised child (no dedicated
`Task.Supervisor` — this module does no `Task.Supervisor.async_nolink/3`
dispatch; all work happens inline in its own `GenServer` callbacks, mirroring
`Letflow.SandboxPool`'s own single-child registration, minus the paired
`Task.Supervisor` SandboxPool needs specifically because IT offloads `Repo`
calls to worker tasks — `Letflow.Admission` makes no `Repo` call at all, so
that concern does not apply here).

Child spec: `{Letflow.Admission, []}`.

**Placement and ordering — no dependency, stated explicitly (AC6):**
`Letflow.Admission` has NO start-order dependency on any other child, and no
other child depends on it starting first, because:

- Its `init/1` reads `Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]`
  from static application config (already loaded before `start/2` runs at
  all — config is not itself a supervised child), never a runtime value
  another process must have produced.
- It makes no `Repo` call, no `Registry` lookup, no call to any other
  supervised process during `init/1` or in either callback.
- Nothing in this requirement's scope (REQ-217/218 are separate, later
  requirements) calls `try_acquire/1` during another child's own `init/1`, so
  there is no analogue to the `SandboxPool`/`SandboxPool.TaskSupervisor` or
  `Obs.Alerts.TaskSupervisor`/`scheduler_children()` ordering hazards
  documented elsewhere in `application.ex` (both of those exist because a
  DEPENDENT child's very first action, at zero delay, calls into the
  dependency — no such caller exists yet for `Letflow.Admission`).

This mirrors REQ-173/REQ-166's own "no ordering dependency" precedent
comments in `application.ex` (`ModuleVersionRegistry`/
`ModuleVersionRegistryTaskSupervisor`: "order between these two is not
load-bearing"; `Obs.Alerts.TaskSupervisor`: "No ordering dependency relative
to the six Task.Supervisors above").

**Suggested list position:** immediately after `Letflow.Metrics.Registry` and
before `Letflow.InstanceSupervisor` — grouped with the other
leaf/independently-startable infrastructure children (`Registry`,
`Letflow.Metrics.Registry`) rather than interleaved with the
SandboxPool/Task.Supervisor pair or the Wasm registries, since it is
infrastructure state with no producer/consumer relationship to either group.
Since there is no ordering dependency in either direction, this placement is
a readability choice (grouping by "leaf infra with no dependencies" the same
way `Metrics.Registry`'s own comment already establishes that category), not
a correctness requirement — ELIXIR-DEV may place it elsewhere in the list
without violating this design, as long as the "no ordering dependency"
moduledoc statement itself is present per AC6.

## 5. Crash / restart semantics

**On a crash of the `Letflow.Admission` process itself** (default
`:one_for_one` supervisor strategy, matching every other child in
`Letflow.Application`'s `children` list — no restart-strategy override is
introduced): the process restarts via its own `start_link/1` → `init/1`,
which recomputes `global_cap` from current config and starts with
`global_in_use: 0`, `tenants: %{}`, `refs: %{}` — i.e. **all in-flight
admissions are silently forgotten**, not carried over.

**This is stated explicitly and judged acceptable** (mirroring
`SandboxPool`'s own accepted trade-off, design doc §11 OQ-3, that pool state
does not survive a restart), for the same class of reason:

- The failure direction is **under-counting**, never over-counting: a crash
  can only make the module BELIEVE fewer admissions are held than are
  actually still in flight (any caller that acquired a ref before the crash
  keeps running with a resource the crashed process no longer knows about,
  and its eventual `release/1` call on the restarted process is a no-op per
  §2.1's ref-membership rule, not an error). Under-counting after a crash
  temporarily WIDENS admission (fewer budgets appear consumed than really
  are), which is the SAFE direction for a broken accounting structure to
  fail in relative to its own purpose — it can transiently under-protect the
  `pool_size` budget for the brief window until in-flight callers finish and
  stop presenting stale refs, but it can never permanently WEDGE admission
  shut the way over-counting (believing slots are held forever) would.
- The alternative (persisting counter state across a crash — e.g. via a
  supervisor-held ETS table with `heir`, or DETS) would need its own
  reconciliation logic for exactly which of the crashed process's in-flight
  refs are still legitimately held by live callers vs. abandoned by a caller
  that ALSO died — a materially bigger mechanism that REQ-216's acceptance
  criteria do not ask for and that would duplicate the ownership-monitoring
  machinery `SandboxPool` already owns for its own, structurally similar
  problem (crash-reclaim, ISS-0048). Not introduced here; recorded as Open
  Question OQ-3 (§9) in case sustained under-protection after repeated
  crashes is later observed to matter operationally.
- A caller-side crash (the process that called `try_acquire/1` dies without
  calling `release/1`) is a DIFFERENT scenario this design does NOT solve:
  `Letflow.Admission` does not monitor callers (unlike `SandboxPool`'s
  owner-monitor mechanism) — a leaked, never-released ref stays counted
  against its budget until the `Letflow.Admission` process itself restarts
  (which clears it, per above) or the process explicitly calls `release/1`.
  This is a deliberate scope line, not an oversight: REQ-216's own
  acceptance criteria test `try_acquire`/`release` arithmetic only, and
  owner-crash reclaim is exactly the SandboxPool-shaped mechanism ISS-0431's
  own text says NOT to fold in ("a fifth ad hoc shape does not get
  invented" / "NOT ABSORBED" section). Recorded as Open Question OQ-4 (§9).

## 6. Config surface

- `config :letflow, Letflow.Repo, pool_size: n` — READ, never written, by
  this module. Same key `config/runtime.exs:113` already sets from
  `POOL_SIZE`.
- `config :letflow, :admission, reserved_headroom: n` — new key, default `2`
  when absent, read via `Application.get_env(:letflow, :admission, [])`.
  `start_link/1`'s `opts` may override both for test isolation (mirrors
  `SandboxPool.start_link/1`'s `Keyword.get_lazy/3` idiom — see §2).
- `global_cap` computed as `max(pool_size - reserved_headroom, 1)` — a
  computed value below 1 (e.g. `pool_size: 2, reserved_headroom: 2`) is
  clamped to 1 rather than producing a zero or negative cap that would
  reject every admission unconditionally; see OQ-1 (§9) for whether this
  should instead be a boot-time configuration error.

## 7. Errors / typed outcomes

- `try_acquire/2` returns exactly `{:ok, admission_ref()} | {:error, :capacity}`
  — no other error shape (no `{:error, :unknown_tenant}`, no validation
  error on a malformed `tenant_schema` string — schema-string validity is a
  caller concern, out of this module's scope; an empty-string or otherwise
  malformed schema is simply tracked as its own literal map key like any
  other).
- `release/2` returns exactly `:ok` — see §2.1's idempotency rule for what
  happens on an unknown/already-released ref.

## 8. Acceptance-criteria traceability

| AC (docs/requirements.yaml REQ-216) | Design element |
|---|---|
| AC1: `:global` admits up to `pool_size - reserved_headroom`, rejects beyond, both read from config, cap changes with `pool_size` override | §6 config surface; §2.2 `global_cap` computed once at `init/1` from `Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size]` and `reserved_headroom` |
| AC2: per-tenant cap enforced independently — A's exhaustion doesn't block B | §2.2 `tenants` map keyed by schema, each with its own `in_use`; §1 single-process atomicity keeps A's and B's counters independent within one admission decision |
| AC3: `{:tenant, _}` also gated by the SAME global cap — a fresh tenant is rejected once global is exhausted despite zero per-tenant usage | §1's atomicity algorithm paragraph: both conditions evaluated before either counter mutates; `global_in_use < global_cap` is checked unconditionally on every `{:tenant, _}` call as part of that same read-only evaluation, so exhausted global capacity rejects regardless of the tenant's own headroom |
| AC4: `release/1` frees exactly one global unit and (for `{:tenant, _}`) one per-tenant unit | §2.1 `admission_ref()` carries `pool` so `release/1` knows exactly which counter(s) to decrement; §2.2 `refs` map is the authoritative membership set |
| AC5: per-tenant cap = floor(global_cap / tracked_tenant_count), floor 1 (10/3→3, 2/5→1) | §2.2 per-tenant cap derivation: global cap divided (integer division) by the tracked-tenant count, floored at 1, recomputed fresh on every call, never cached |
| AC6: `Letflow.Admission` present in `Letflow.Application`'s supervision tree; moduledoc states ordering dependency (or none) | §4 — child spec `{Letflow.Admission, []}`, explicit "no ordering dependency" statement and reasoning to appear verbatim in the module's `@moduledoc` |
| AC7: `mix test` / `mix compile --warnings-as-errors` pass | Not a design element — verified at implementation/test-runner stage; this design introduces no dialyzer-hostile or warning-producing construct (no unused variables, no missing `@spec`) |

## 9. Open questions (explicitly not resolved here)

- **OQ-1:** should `pool_size - reserved_headroom <= 0` be a hard boot-time
  `raise` (misconfiguration) instead of the silent floor-of-1 clamp in §6?
  Left as a clamp for this requirement since no acceptance criterion
  exercises a misconfigured-to-zero scenario; a future requirement can
  tighten this if operational experience shows a clamp masks a real
  misconfiguration.
- **OQ-2:** `state.tenants` entries for schemas that stop attempting
  admission are never evicted (§3) — a real time-windowed or LRU eviction
  mechanism is not implemented. Left open pending evidence this matters in
  practice, given the low-cardinality bound described in §3. UNLIKE OQ-1,
  OQ-3, and OQ-4 below, this is a self-acknowledged NARROWING of REQ-216's
  own requirement text (its decision-2 paragraph's "rolling window"
  language), not a pre-existing exclusion the requirement text itself
  already stated — per core-directives.md's "No Issue Left Local-Only," it
  is being escalated to ORCH in this handoff's `result.summary` for
  `register_task` issue registration (see §3's full escalation paragraph for
  the proposed title/description/severity); it is not left as a design-doc-
  only note.
- **OQ-3:** a crash of `Letflow.Admission` forgets all in-flight admissions
  (§5) rather than persisting/reconciling them. Left open pending evidence
  that repeated crashes under load cause meaningful sustained
  under-protection of `pool_size`.
- **OQ-4:** no owner-crash reclaim for a caller that acquires a ref and then
  dies without releasing it (§5) — unlike `SandboxPool`'s monitor-based
  reclaim, this module does not monitor callers. Explicitly out of scope per
  ISS-0431's own "NOT ABSORBED" reasoning about not duplicating
  SandboxPool's differently-motivated mechanism; left open as a genuinely
  separate future concern if REQ-217/218's real callers are observed to leak
  refs on crash.
- **OQ-5 (inherited, not reopened):** tier-weighted per-tenant caps — no
  data model exists (`Letflow.Identity.Tenant` has no tier/plan field, §0).
  A genuine product decision, not an implementation detail this requirement
  resolves.
