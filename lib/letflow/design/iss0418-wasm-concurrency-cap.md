# ISS-0418 — Operator-configurable cap on concurrently in-flight WASM invocations (OQ-5 candidate (a))

**Issue:** ISS-0418 (MAJOR, eleven-plus recurrences of the `wasm_hang` CI flake, root
cause diagnosed live by ISSUE-FIXER in `handoffs/WF03-ISS0418-20260905/step-01-issue-fixer-diagnosis.json`)
**Related:** ISS-0352 (original CI reproduction, six recurrences absorbed into the
current isolation architecture), REQ-170 (`lib/letflow/design/req170-wasm-wallclock-timeout.md`,
the wall-clock caller bound this design does not duplicate), decision 0014 OQ-5,
REQ-216 (`Letflow.Admission`, reused here — see §3 for why and how), ISS-0437 (per-tenant
retention gap — see §3.4 for why this design does not trigger it)
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-09-05

This is a design artefact — `@spec`/`@type` signatures, `@moduledoc`/`@doc` prose, and
supervision-tree wiring only. No function bodies, no `.ex` code blocks with real
implementation logic. See `docs/agents/workflows/WF-02_requirement_implementation.md`
Step 1 / `.claude/agents/code-designer.md`.

---

## 0 — Read this first: what this design does and does not guarantee

**ISSUE-FIXER's diagnosis (step-01 handoff) is treated as verified fact, not
re-derived here** — it read wasmex 0.15.1's real Rust source directly and live-reproduced
pool exhaustion on this host (16 concurrent hangs exhaust `TOKIO_RUNTIME`; a subsequent
trivial call did not return at 20s or 90s; no recovery observed). Three corrections/
findings from that diagnosis are load-bearing for every decision below and are not
re-argued:

1. The leak is **one permanently-blocked Tokio task per `Store`** (not per raw
   invocation as a NIF primitive) — but because `PluginHandler.start_instance/1` creates
   a fresh `Store` per call with no pooling (REQ-174 declined), in this codebase's actual
   call pattern this distinction is moot: **every hung `PluginInterface.invoke/2,3` call
   still leaks exactly one thread-equivalent, unbounded by call count.**
2. **Store pooling is mechanistically ruled out** (§2 of the diagnosis) — a pooled
   Store that ever receives one hang is permanently wedged forever, so pooling would not
   bound the leak, only add false confidence. This design does not propose it.
3. **The leak is confirmed unbounded and unrecoverable within the BEAM** over at least a
   90-second observation window. Nothing this design builds changes that fact.

**Given (3), stated as plainly as ISSUE-FIXER's own diagnosis states it:**

> **A semaphore admitting callers into `PluginHandler.run_guest/3` bounds the number of
> WASM invocations that may be simultaneously IN FLIGHT. It does NOT bound, reclaim, or
> even observe the number of PERMANENTLY LEAKED executor tasks already stuck in
> wasmex's shared `TOKIO_RUNTIME`. Every hang that occurs, whether one at a time under a
> cap of one or many at once under no cap at all, consumes one pool slot forever. The cap
> changes the RATE and the WORST-CASE INSTANTANEOUS BLAST RADIUS of exhaustion — it slows
> time-to-exhaustion and bounds how many hangs can pile up in one moment — but it cannot
> prevent eventual exhaustion if hangs keep occurring over a long enough time window,
> because the pool never grows back. The only two things that ever reclaim a leaked
> thread are killing the OS process it lives in, or restarting the BEAM node — both
> outside this design's scope (§4).**

This is an honestly-scoped **harm-reduction** mechanism, not harm-elimination, and
this document's own `@moduledoc` requirement (§7) mandates that this exact paragraph's
substance ship in the production module's documentation, not just here.

**What the cap DOES concretely guarantee, and why that is still worth building:**

- **Bounds simultaneous blast radius.** Without a cap, N concurrent hung invocations
  (e.g. a burst of adversarial or merely slow guests across several tenants) can consume
  up to N pool slots in one moment, exhausting an `available_parallelism()`-sized pool
  (as few as 4 slots on a small CI runner, per ISS-0418's own recurrence evidence)
  almost immediately. With a cap of `C`, no more than `C` invocations can be
  simultaneously dispatched at all, so no single burst can consume more than `C` slots
  before the admission gate itself starts rejecting/queuing new attempts.
- **Gives an operator a real dial.** Per OQ-5's own wording ("operator-configurable"),
  §5 below names the config key, default, and justification.
- **Does NOT, by itself, fix the isolated `mix test --only wasm_hang` CI flake —
  corrected in rework, see §6.** Every `:wasm_hang`-tagged test calls
  `PluginInterface.invoke/2,3`/`PluginHandler.handle_node/1` directly, and this design's
  own §1/§8.1 scope boundary keeps those call sites unmodified, deferring the actual
  lease-acquiring call site to a future, unbuilt dispatch-integration requirement
  (OQ-C). §6 states this plainly and names what this design delivers instead: a
  correctly-specified, independently-testable primitive and a contract that future
  caller must follow — not a fix to the flake this run was selected to address. An
  earlier revision of this document claimed the opposite; that claim was false and is
  retracted, not softened, in §6.
- **Does not require solving reclamation to ship.** §4 states plainly that reclamation
  (subprocess isolation, periodic node-health-triggered restart) is out of scope here,
  named as follow-up, and that without it the cap's guarantee is bounded-rate, not
  bounded-total, over the lifetime of a long-running node.

---

## 1 — Scope boundary: what this module is, and what it explicitly is not

**New module: `Letflow.Engine.Wasm.InvocationLease`**, `lib/letflow/engine/wasm/invocation_lease.ex`.

This is **not** an extension of `Letflow.Admission` (REQ-216) — §3 argues this choice
explicitly, since ISSUE-FIXER's diagnosis left it as an open decision point (item 5 of
its "what the design must decide" list). `Letflow.Admission` remains completely
unmodified by this design.

**This module owns exactly two things:**

1. A single global counting semaphore, sized by an operator-configurable cap, gating
   entry to a WASM guest dispatch.
2. A **lease** primitive whose release does not depend on cooperation from the process
   that acquired it — because that process is exactly the one the existing
   `PluginInterface.invoke/2,3` brutal-kills on timeout (§2 states why this is
   necessary, not optional).

**This module does NOT:**

- Dispatch a guest call itself (`PluginHandler`'s job, §5 states the one call site it
  gains).
- Touch `PluginInterface.invoke/2,3`'s crash-safety algorithm (unmodified, per REQ-170's
  own precedent of reusing it as-is).
- Attempt to reclaim, count, or observe already-leaked native `Tokio` tasks in any way
  (§0/§4 — not possible from the BEAM side, per ISSUE-FIXER's live-reproduced finding).
- Provide per-tenant fair-share tracking. §3.4 states why a single global budget is the
  right shape here, unlike `Letflow.Admission`'s HTTP/poller use case.

---

## 2 — The admission-ref leak problem, and why a plain semaphore is self-defeating

**Restating ISSUE-FIXER's finding precisely, since the fix must close exactly this
gap.** `PluginInterface.invoke/2,3`'s existing algorithm:

```
task = Task.Supervisor.async_nolink(PluginTaskSupervisor, fn -> handler.handle_node(context) end)
task |> Task.yield(timeout_ms) |> handle_yield_result(task, handler, timeout_ms)
```

On the `nil` branch (outer timeout), `handle_yield_result/4` calls
`Task.shutdown(task, :brutal_kill)` — the task process that ran `handle_node/1` (and
therefore, transitively, `PluginHandler.run_guest/3`, `Wasmex.start_link/1`, and
`Wasmex.call_function/4`) is **killed**, not given a chance to run any further code
inside itself. If that same task process were the one that had called
`try_acquire/2` on entry and were relying on itself calling `release/2` on exit, the
brutal-kill path skips `release/2` entirely — for exactly the hangs this cap exists to
bound. **A cap wired this way would leak one admission unit per hang, at exactly the
rate the underlying native leak occurs, degrading the cap itself to zero available
slots after enough hangs — the identical failure shape one layer up**, which
ISSUE-FIXER's diagnosis calls out explicitly as the reason this is a real design
decision, not mechanical wiring.

**This design's answer: the lease is acquired and released from a process that is
never the one killed.**

- The **acquiring process is the caller of `PluginInterface.invoke/2,3`** (i.e.
  whatever engine code calls `invoke/2,3` to dispatch to `PluginHandler`) — not the
  inner `Task.Supervisor.async_nolink/2`-spawned task. This caller process is never
  brutal-killed by `invoke/2,3`'s own algorithm; it is the process that *calls*
  `Task.shutdown/2`, never the process shut down.
- Release is **monitor-driven**, not cooperation-driven, mirroring
  `Letflow.SandboxPool`'s own established `Process.monitor/1` +
  `handle_info({:DOWN, ...})` idiom (`plugin_interface.ex`'s own moduledoc names this
  exact precedent for "observe termination via a monitor, not by trusting the
  terminated process to clean up after itself"). Concretely: the lease-holding process
  (the `invoke/2,3` caller) monitors nothing extra — it does not need to, because it is
  never killed. The lease itself is released **synchronously by that same caller once
  `invoke/2,3` returns**, on every possible return path (`{:complete, _}`, `{:error,
  _}` for a deliberate handler error, `{:error, _}` for a crash, and `{:error, _}` for
  an outer timeout) — `invoke/2,3` always returns one of these `outcome()` values,
  never leaves its caller hanging (per its own AC3 guarantee, already live-verified by
  REQ-170 §1.6), so "release once `invoke/2,3` returns" is unconditionally reachable
  from the lease-holder's own code with a bare `try/after` or an equivalent
  guaranteed-cleanup construct — no monitor needed for THIS half, because the acquiring
  process's own liveness is never at risk from the hang.
- **The one remaining risk this must still cover:** what if the CALLER of
  `invoke/2,3` itself crashes or is killed after acquiring the lease but before
  `invoke/2,3` returns (e.g. its own supervisor restarts it, an unrelated crash in
  sibling code inside the same process)? This is where a monitor genuinely is needed —
  not on the killed inner task (irrelevant, per above), but as a backstop against the
  **lease-holder** itself dying uncleanly. `InvocationLease` therefore monitors the
  acquiring process's pid at acquire time (mirroring `SandboxPool`'s
  `owner_ref = Process.monitor(owner_pid)`, `sandbox_pool.ex:566`) and releases the
  lease automatically on that pid's own `:DOWN`, exactly once, idempotently with an
  explicit `release/1` call (matching `Letflow.Admission.release/2`'s own idempotent-
  no-op-on-unknown-ref contract, so a `:DOWN`-triggered auto-release racing an explicit
  `release/1` call from the same process's own `after` block can never double-release
  or crash).

**Net effect:** a lease is released either (a) explicitly, by the acquiring process,
once `invoke/2,3` returns by any path, or (b) automatically, by `InvocationLease`
itself, if the acquiring process dies before doing (a). There is no path by which a
lease outlives both its holder and its own `invoke/2,3` call — including the exact
brutal-kill scenario ISSUE-FIXER's diagnosis identified, because that kill lands on the
*inner* task, never the lease-holding *caller*.

---

## 3 — Why a new module, not an extension of `Letflow.Admission`

ISSUE-FIXER's diagnosis leaves this as an explicit, un-defaulted decision (item 5).
This design chooses **new, purpose-built module**, for four independent reasons, each
sufficient on its own:

### 3.1 — Admission's core assumption is caller cooperation; this caller cannot cooperate

`Letflow.Admission`'s own moduledoc states its crash semantics plainly: "this module
does not monitor callers... a leaked ref stays counted against its budget until this
process itself restarts or the ref is explicitly released." That is not a bug in
Admission — it is a correct design for REQ-216's actual callers (HTTP request-handling
processes and `Letflow.Scheduler.Poller` sweeps), which always run to completion or
crash in the ordinary BEAM sense (an exit that terminates the *whole* calling process,
not a targeted `Task.shutdown(:brutal_kill)` of an *inner* task while the outer,
ref-holding process survives and keeps running). **Retrofitting monitor-based release
onto `Letflow.Admission` to serve this one new caller shape would change a documented
invariant of a shipped, gate-approved module for every existing and future caller of
it** — REQ-217's HTTP wiring and REQ-218's poller wiring both currently rely on
Admission's simple, non-monitoring semantics; adding monitoring changes crash-recovery
behavior for those call sites too, and REVIEWER would need to re-examine both against a
changed invariant. A new, smaller module with the monitor built in from the start avoids
retroactively complicating an already-shipped design for a use case it was never built
for.

### 3.2 — Different exhaustion semantics: capacity vs. blast-radius

`Letflow.Admission` returns `{:error, :capacity}` synchronously, with no queue — correct
for an HTTP request (fail fast, let the client retry) and a poller sweep (skip this
tick, try next tick). A WASM invocation inside engine dispatch has a different natural
shape: **the caller already has `PluginInterface.invoke/2,3`'s own outer
`timeout_ms`-bounded wait as its existing "don't wait forever" mechanism** (REQ-170,
unmodified). §5.2 below discusses whether admission at cap should fail fast
(`{:error, :capacity}`, mirroring Admission) or block briefly — this design recommends
fail-fast, for consistency with Admission's own precedent and because blocking here
would just relocate the "how long do we wait" question without adding value, given
`invoke/2,3`'s own bound already exists one layer up.

### 3.3 — Global-only, not per-tenant fair-share

`Letflow.Admission`'s defining feature is composing a global budget with **per-tenant**
fair-share budgets (`{:tenant, schema}`), because REQ-216's own text is about HTTP/poller
admission fairness *across tenants competing for the same node*. This cap's actual
threat model, per ISSUE-FIXER's diagnosis and REQ-170 §1.5/§8, is a **single, node-global,
cross-tenant native resource** (`wasmex`'s `TOKIO_RUNTIME`) that has no per-tenant
partition at all — one tenant's hang consumes a slot indistinguishable from any other
tenant's hang, at the native layer. A per-tenant fair-share division here would be
**actively misleading**: it would suggest tenant isolation that the underlying resource
does not have. This design uses only a single **global** counter — no `{:tenant, _}`
variant — stated explicitly so a future reader does not expect per-tenant WASM fairness
from this mechanism.

### 3.4 — Sidesteps ISS-0437 entirely, by construction

ISS-0437 tracks `Letflow.Admission`'s per-tenant-entry unbounded-retention gap
(`state.tenants` never evicts). Because this design has no per-tenant tracking at all
(§3.3), it has no tenant-keyed map, and therefore no analogous retention concern —
confirmed here explicitly per ISSUE-FIXER's request to check the interaction, not left
implicit. State size for `InvocationLease` is bounded by `cap` (the number of
concurrently-outstanding leases, which by construction never exceeds the configured
cap) — not by tenant cardinality.

### 3.5 — What IS reused, deliberately, rather than re-invented

The **shape** of `Letflow.Admission`'s design is reused as precedent, not its code: a
single supervised `GenServer` holding counter + `refs` map in one state term (so
acquire/release stay atomic for free via mailbox serialization); an opaque
`Ref`-style struct callers must not construct or pattern-match into; idempotent
`release/2` on an unknown/already-released ref (`:ok`, never a raise); `try_acquire`-style
naming. This design deliberately keeps naming/shape parallel to `Letflow.Admission` so
a future reader recognizes the pattern immediately, while keeping the module boundary
separate for the reasons above.

---

## 4 — Reclamation: not possible from inside the BEAM; stated plainly, scoped out

Direct answer to ISSUE-FIXER's diagnosis item 4/Option D: **no mechanism inside this
design, or reachable from the BEAM at all today, reclaims an already-leaked
`TOKIO_RUNTIME` executor task.** This is not a limitation of this design specifically —
per ISSUE-FIXER's own live reproduction (90-second no-recovery window) and REQ-170
§1.4's source-level explanation (the per-`Store` executor task's `JoinHandle` is
discarded by `wasmex` itself; nothing in the dependency retains a handle capable of
cancelling it), **no BEAM-reachable API exists to reclaim it, full stop** — this is not
a gap this design chooses to leave for later engineering convenience; it is a closed
question given the dependency's current internals, short of patching or forking
`wasmex`.

**What that implies, stated rather than left implicit (per ISSUE-FIXER's item 4
instruction):**

- **The cap is sufficient to fix the immediate CI flake** (§6) because the CI subprocess
  is short-lived and exits shortly after its own test file's hangs run — the leaked
  threads die with that process, which is ISS-0352's own already-shipped isolation
  architecture (isolating the flake to a fresh, short-lived `mix test --only wasm_hang`
  BEAM node), unaffected and unduplicated by this design.
- **The cap is NOT sufficient, alone, to make a long-running production node immune to
  eventual exhaustion** if genuinely adversarial or merely slow guests keep occurring
  over the node's full uptime — every hang under the cap still permanently consumes one
  pool slot, and nothing ever gives one back. Two options exist to close that residual
  gap, named as **out-of-scope follow-up, not designed here**, matching ISSUE-FIXER's
  own recommendation:
  1. **Subprocess-per-invocation isolation**, generalizing ISS-0352's own CI-isolation
     trick to production traffic — a leaked thread dies when its OS process is killed.
     This is a materially larger architectural change (an IPC boundary on every guest
     call) than "a cap," and is not designed here.
  2. **A periodic health-probe-triggered node restart** — dispatch a cheap, known-
     non-hanging synthetic guest call on an interval; if it fails to return within a
     generous bound, infer pool exhaustion and restart the node under supervision. This
     is the only mechanism ISSUE-FIXER's diagnosis found that actually reclaims already-
     leaked capacity (by paying for a full node restart), and it composes with this
     cap rather than replacing it. Not designed here — named for whoever picks up OQ-5's
     wider scope, per the same "file it, don't build it" discipline REQ-170 §8 already
     used for this very cap.
- **This design's own moduledoc (§7) must state this limitation permanently**, mirroring
  `CallTimeout`'s own precedent of shipping an honest "what this does NOT provide"
  section rather than letting the limitation live only in a design doc nobody re-reads.

---

## 5 — Public contract: `Letflow.Engine.Wasm.InvocationLease`

### 5.1 Process shape and supervision

A single supervised `GenServer`, added as a child of `Letflow.Application`'s
supervision tree, alongside `Letflow.Engine.PluginTaskSupervisor` (both are WASM/plugin-
dispatch infrastructure with no start-order dependency on each other or on `Repo` —
mirrors `Letflow.Admission`'s own "no ordering dependency" precedent: `init/1` reads
only static application config, makes no `Repo` call, no `Registry` lookup, and no call
to any other supervised process).

```
@typedoc "An opaque lease handle returned by try_acquire/0. Callers must not
pattern-match on or construct this struct directly -- only release/1 (or the
automatic monitor-triggered release, S2) consumes it."
@type lease :: %Letflow.Engine.Wasm.InvocationLease.Lease{id: reference()}
```

### 5.2 Client API

```
@doc """
Attempts to acquire one lease against the global WASM-invocation cap
(S5.3's config key). Monitors `self()` at acquire time (S2) so the lease
is automatically released if the calling process dies before an explicit
release/1 call. Never parks the caller -- returns {:error, :capacity}
immediately if the cap is already fully leased, mirroring
Letflow.Admission.try_acquire/2's own non-queuing precedent (S3.2's
rationale: the caller already has PluginInterface.invoke/2,3's own
outer timeout as its "how long to wait" mechanism one layer up; this
gate does not duplicate that decision).
"""
@spec try_acquire() :: {:ok, lease()} | {:error, :capacity}

@doc """
Releases a previously-acquired lease. Idempotent: releasing an unknown,
already-released, or hand-constructed lease is a documented no-op --
always :ok, never a raise (mirrors Letflow.Admission.release/2's own
idempotency contract, S3.5). Safe to call from the same process that
acquired the lease (the expected, primary path, S2) -- calling it from
a different process is not a supported usage and is not guaranteed to
behave sensibly, since the automatic monitor-based release (S2) is keyed
to the ACQUIRING process's pid, not the caller of release/1.
"""
@spec release(lease()) :: :ok

@doc """
Returns the currently configured global cap, live from GenServer state
-- for observability/tests, mirroring Letflow.Admission.global_cap/1's
own precedent.
"""
@spec cap() :: pos_integer()
```

### 5.3 State shape

```
# %{
#   cap:     pos_integer(),                          # fixed at init/1, from config (S5's key)
#   in_use:  non_neg_integer(),
#   leases:  %{optional(reference()) => %{monitor_ref: reference(), pid: pid()}}
# }
```

`leases` is keyed by the same opaque `id` the `Lease` struct carries (mirrors
`Letflow.Admission`'s `refs` map keyed by `Ref.id`) and additionally stores the
`Process.monitor/1` reference and the acquiring pid, so a `:DOWN` for that monitor ref
can look up and release exactly the right lease entry, and so an explicit `release/1`
call can `Process.demonitor(monitor_ref, [:flush])` to avoid a stale `:DOWN` arriving
after an already-completed explicit release (mirrors `SandboxPool`'s own documented
"flush so a normally-returning worker never ALSO delivers a `:DOWN`" precedent,
`sandbox_pool.ex:407`).

### 5.4 GenServer-internal behavior (prose, not code)

- `init/1` reads `cap` from config (§5.5) and starts with `in_use: 0`, `leases: %{}`.
- `try_acquire` (`handle_call`): if `in_use < cap`, monitor the calling pid
  (`elem(_from, 0)`, the standard `GenServer.call/2` caller-pid extraction — the same
  pattern used wherever a `GenServer` needs the caller's pid rather than the process
  it happens to run in, since `self()` inside `handle_call/3` is the server itself, not
  the caller), mint a new `id = make_ref()`, insert into `leases`, increment `in_use`,
  reply `{:ok, %Lease{id: id}}`. If `in_use >= cap`, reply `{:error, :capacity}` with
  zero mutation — same "evaluate before mutating, no rollback" discipline
  `Letflow.Admission`'s own moduledoc documents.
- `release` (`handle_call`): look up `id` in `leases`. Present — demonitor+flush,
  remove the entry, decrement `in_use`, reply `:ok`. Absent — reply `:ok`, no mutation
  (idempotent no-op, §5.2).
- `handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state)`: find the lease
  entry whose `monitor_ref` matches (an O(map-size) scan over `leases`, which is bounded
  by `cap` and therefore small — a linear scan here is the same tradeoff
  `Letflow.SandboxPool`/`Letflow.Supervisor.PollersBreaker` already accept for their own
  bounded-size `:DOWN`-keyed lookups), remove it, decrement `in_use`. A `:DOWN` for a
  monitor ref no longer present (already explicitly released and demonitored) is a
  documented no-op, matching the "stale ref" precedent
  `pollers_breaker.ex:167` already establishes in this codebase for the identical
  race shape.
- On this `GenServer`'s own crash/restart, `init/1` starts fresh
  (`in_use: 0`, `leases: %{}`) — same safe-failure direction as `Letflow.Admission`'s
  own documented crash semantics: can only under-count (transiently widen admission
  after a restart), never over-count (permanently wedge admission shut). Stated
  explicitly as an accepted tradeoff, not a gap: a restart of this GenServer does not,
  and cannot, affect any already-leaked `wasmex` native thread either way (§4) — this
  GenServer's own state has never had any relationship to native pool occupancy beyond
  bounding how many NEW invocations may be dispatched at once.

### 5.5 Configuration surface: key, default, and justification (OQ-5's own "operator-configurable" wording)

**Config key:** `Application.get_env(:letflow, :invocation_lease, [])[:cap]`, read once
at `init/1` — mirrors `Letflow.Admission.start_link/1`'s own
`Application.get_env(:letflow, :admission, [])` / `Keyword.get_lazy/3` idiom exactly
(§3.5), including the same `opts`-override-for-test-isolation convention
(`start_link(opts \\ [])` accepts a `:cap` override, taking precedence over the
application-env value, matching `Letflow.Admission.start_link/1`'s own `:pool_size`/
`:reserved_headroom` overrides).

**Default:** `max(div(System.schedulers_online(), 2), 1)`.

**REWORK NOTE (CODE-DESIGN-VALIDATOR step-02b, MAJOR finding), read before the
justification below.** The prior revision of this section recommended
`max(System.schedulers_online() - 2, 1)` and, in the same paragraph, quoted this exact
host's own numbers (`available_parallelism()` = 8 per REQ-170 §1.5, `schedulers_online()`
= 16) as illustration — without checking its own formula against those numbers. Checked
now: `max(16 - 2, 1) = 14`, which is **greater than** the cited pool size of 8. That is a
non-protective default on the design's own worked example, exactly the "a cap at or
above the actual native pool size bounds nothing" failure this same section warns
against one paragraph earlier. This was a real design defect, not a wording slip, and is
fixed by replacing the fixed-subtraction formula with a fixed-fraction one (below), which
degrades far more gracefully when the two counts diverge, plus an explicit
operator-facing warning (last bullet) rather than a buried caveat.

**Justification, stated explicitly per OQ-5's own "operator-configurable" wording
(the number must be justified, not merely picked):**

- **The core problem, stated first because it drives every choice below: there is no
  BEAM-side API that reads `wasmex`'s own native `TOKIO_RUNTIME` pool size directly**
  (confirmed absent by ISSUE-FIXER's grep of the full native/lib source trees, per its
  diagnosis §1 — no NIF parameter, env var, or `Wasmex.EngineConfig` field exposes it;
  this design's own review of the codebase found no existing `:erlang.system_info/1`-
  based proxy for it either, so nothing already in this codebase can be reused here).
  `wasmex`'s pool is sized to `std::thread::available_parallelism()`, a Rust-side OS
  query with **no Elixir/BEAM equivalent surfaced anywhere in this dependency or the
  standard library** — `System.schedulers_online()` is the nearest BEAM-side number,
  but it counts BEAM schedulers, not OS logical cores, and the two are configured
  independently (`+S`/`+SDcpu` VM flags can set BEAM's scheduler count to anything,
  unrelated to what `available_parallelism()` reports). **This design cannot compute an
  exact answer and does not claim to; it computes a deliberately conservative one.**
- **Corrected figures for this host, re-measured directly this session (not assumed
  from a different host's numbers, which was the prior revision's own error):
  `nproc` = 16 and `System.schedulers_online()` = 16 on the CODE-DESIGN-VALIDATOR's
  and this rework's own host** — i.e. on THIS host the two counts agree, unlike
  REQ-170's original design-session host (`available_parallelism()` = 8 against
  `schedulers_online()` = 16, a 2x divergence). Both real, both cited accurately now:
  REQ-170 §1.5's host is a genuine, documented case where the two diverge sharply, and
  this rework's own host is a case where they do not — the formula below is chosen to
  survive the divergent case, since that is the one that can silently fail to protect.
- **Why a fixed FRACTION, not a fixed SUBTRACTION, of `schedulers_online()`:** a fixed
  subtraction (the prior `- 2`) shrinks the cap by a constant amount regardless of how
  large `schedulers_online()` gets relative to the real pool size — exactly why it
  failed on the 16-vs-8 case (16 - 2 = 14, still far above 8). A fixed **fraction**
  shrinks proportionally, so it degrades gracefully as the divergence widens instead of
  becoming a no-op past some threshold. `div(schedulers_online(), 2)` on the two
  concretely known cases: REQ-170's divergent host, `div(16, 2) = 8`, exactly equal to
  the cited real pool size of 8 (not strictly below it — see the explicit caveat below,
  this is not claimed as a proof of protection, only as no longer a proven no-op); this
  rework's own convergent host, `div(16, 2) = 8`, comfortably below the real pool size
  of 16. A small CI runner (~4 vCPU, ISS-0418's own recurrence evidence, where the two
  counts typically track 1:1 on a dedicated runner): `div(4, 2) = 2`, below a pool of
  ~4. `max(_, 1)` floors at 1 rather than 0 or a negative number on a 1-2 core host,
  mirroring `Letflow.Admission.init/1`'s own identical `max(pool_size - reserved_headroom, 1)`
  floor shape (though the operation before the floor now differs, per above).
- **Explicit caveat, stated plainly rather than buried, per the validator's own
  required fix:** this formula is a **heuristic over an unmeasurable quantity, not a
  guarantee.** On REQ-170's own cited host it lands exactly AT the real pool size
  (`div(16,2)=8` vs. an actual 8) — the boundary case, not strictly below it — so it is
  not proven protective there either, only no longer proven non-protective as the prior
  `-2` formula was. **An operator whose BEAM scheduler count is set (via `+S`/`+SDcpu`)
  to significantly exceed the host's actual logical core count — the specific
  divergence this default cannot detect or correct for — must override `cap` manually
  to a value measured against that host's real `available_parallelism()`** (obtainable
  operationally outside the BEAM, e.g. `nproc` on Linux, since no in-BEAM read exists).
  This is not a hypothetical: REQ-170's own design-session host is a real, already-
  measured instance of exactly this divergence.
- **This default is deliberately NOT tight enough to fully prevent exhaustion under a
  sufficiently large burst** — per §0/§4, no default can, since the cap bounds
  concurrent callers, not leaked threads, and this default is sized for ordinary
  production headroom, not adversarial-burst safety. An operator running WASM plugins
  under a threat model where many simultaneous tenant-supplied hangs are expected
  should configure a tighter value explicitly; this default optimizes for "do not
  throttle ordinary traffic too aggressively" over "survive a deliberate burst,"
  consistent with this being a harm-reduction mechanism (§0), not a hard security
  boundary.
- **This is explicitly separate from and smaller in scope than the `:test`-environment
  override (§6.1, now superseded by §6's rework below — see that section)** — a test
  or CI-specific override is not this production default, and must not replace it in
  non-test environments.

---

## 6 — Test strategy, and an honest correction: this design does NOT, by itself, fix the `wasm_hang` CI flake

**REWORK NOTE (CODE-DESIGN-VALIDATOR step-02b, BLOCKER finding).** The prior revision
of this section claimed the cap made `wasm_hang` admission "structurally impossible…
by construction, not probabilistic," resting on a `cap: 1` test-environment override.
**That claim was false, and the validator's finding is accepted in full without
qualification:** every real `:wasm_hang`-tagged test
(`test/letflow/engine/wasm/plugin_handler_test.exs:152,353,393,472`;
`call_timeout_test.exs:76,155`; `host_api_write_test.exs:458`) calls
`PluginInterface.invoke/2,3` or `PluginHandler.handle_node/1` **directly from the test
process**. This design's own §1 and §8.1 forbid modifying `PluginInterface.invoke/2,3`,
`PluginHandler`, and `handle_node/1`, and defer the only specified
lease-acquiring call site (§8.1) to a **future, unbuilt** dispatch-integration
requirement (OQ-C). The former §6.2 explicitly did not rewrite the existing
`wasm_hang` tests to call `try_acquire/0`/`release/1` either. **Net effect: nothing this
design specifies building is ever called from the actual flaking tests' call graph.** A
`cap: 1` override on a `GenServer` nothing in that call path invokes gates nothing —
the determinism claim was unsupported by the design's own scope boundary, visible on a
straight read of the (former) §6.1 against §1/§8.1/§6.2 in the same document. This
rework takes **route (b)** from the gate's own two offered options: the scope boundary
in §1/§8.1 is kept (see §6.4 below for why), and the false claim is deleted rather than
patched around.

**Stated plainly, per the gate's own instruction: this design, as scoped, does NOT fix
ISS-0418's CI flake.** The `mix test --only wasm_hang` subprocess will continue to
exercise real hangs through `PluginInterface.invoke/2,3` exactly as it does today,
uninfluenced by `InvocationLease`, until a future dispatch-integration requirement (1)
builds the real call site §8.1 specifies and (2) that call site's caller is what the
`wasm_hang` tests exercise instead of calling `invoke/2,3`/`handle_node/1` directly —
neither of which this design builds. ORCH selected this issue on the premise that the
fix here would move the CI gate off its measured 44% pass rate; **on this design's own
honest scope, it does not, by itself, do that**, and ORCH must decide, informed by this
correction, whether shipping the primitive alone (without wiring) is worth doing now or
whether the wiring must be pulled into this same run's scope (§6.4 discusses the
tradeoff but does not decide it — that is ORCH's call, not CODE-DESIGNER's to make
unilaterally by silently widening scope).

### 6.1 What this design DOES deliver, stated affirmatively and precisely

- A correctly-specified admission primitive (§5) whose placement (§2/§8.1) genuinely
  solves the never-released-ref-on-brutal-kill problem — this part of the gate's
  check-by-check review passed independently, and is not touched by this correction.
- A **contract** (§8.1) that a future dispatch-integration call site (OQ-C — most
  plausibly REQ-056, per `plugin_interface.ex`'s own moduledoc, still `pending`) must
  follow to actually gate production WASM dispatch. That future requirement's
  CODE-DESIGNER does not need to re-derive the brutal-kill hazard or the monitor-backstop
  design — it is done here, once, correctly.
- Full, independently-verifiable unit coverage of the primitive itself (§6.2, unchanged
  by this correction) — `try_acquire/0`, `release/1`, and the monitor-based auto-release
  under an ordinary process kill (the non-WASM-dependent stand-in for
  `PluginInterface.invoke/2,3`'s own brutal-kill), all provable today with zero
  dependency on `wasmex` or on the future call site existing.
- Nothing else. In particular: **no change to the `wasm_hang` tests' own pass/fail
  behavior, no change to CI's measured pass rate, and no claim of either.**

### 6.2 What test asserts what this design DOES deliver (design-level test plan, not test code — unchanged in substance from the prior revision, since this part was never the finding)

- **New test, `test/letflow/engine/wasm/invocation_lease_test.exs`** (ELIXIR-DEV/
  TEST-DESIGNER scope): starts an isolated `InvocationLease` instance (mirrors
  `Letflow.Admission`'s own `start_link/1` test-isolation `opts` override convention,
  §5.1/`admission.ex`'s own `:name`/`:pool_size` overrides). Asserts:
  (a) a first `try_acquire/0` succeeds; (b) a second, concurrent `try_acquire/0` (from a
  second process) against a `cap: 1` instance returns `{:error, :capacity}` while the
  first lease is held; (c) after the first lease's holder process is killed
  (`Process.exit(pid, :kill)`) WITHOUT calling `release/1`, a subsequent `try_acquire/0`
  succeeds within a bounded wait — this is the direct proof of §2's monitor-based
  auto-release, using an ordinary process kill as the cheap, non-WASM-dependent stand-in
  for `PluginInterface.invoke/2,3`'s own brutal-kill; (d) an explicit `release/1`
  followed immediately by that same process exiting does not double-decrement `in_use`
  (proves the demonitor+flush race is closed, §5.3).
- **This test suite proves the PRIMITIVE is correct in isolation. It does not, and
  cannot, prove anything about the `wasm_hang` CI flake**, since (per §6 above) nothing
  in that flake's own call graph calls this primitive yet. Stated here explicitly so a
  future reader does not mistake a green `invocation_lease_test.exs` for evidence the
  flake is fixed.
- **Existing `:wasm_hang`-tagged tests are unmodified by this design** — they continue
  exercising `PluginInterface.invoke/2,3`/`PluginHandler.handle_node/1` directly, exactly
  as they do today, and will continue to flake exactly as ISS-0418 already documents
  until the future dispatch-integration work (§6.4) exists and is wired into their call
  path (or they are themselves rewritten to go through it — a decision for that future
  work, not this one).

### 6.3 Honesty clause, mirroring REQ-170 §5.2 item 3's precedent

Any new test or moduledoc content this design's implementation produces must not claim
the underlying native leak is prevented or reclaimed, and — per this rework — must not
claim the `wasm_hang` CI flake is fixed or made deterministic by this design alone. Per
§0/§7, this is a comment/documentation obligation carried into implementation, not a
design element with its own separate artifact.

### 6.4 Why route (b) — keeping the scope boundary — rather than route (a) — widening scope to touch the flaking call path

The gate offered two honest routes: widen scope so the lease sits on the actual flaking
path (route (a)), or keep the boundary and state the limitation plainly (route (b),
taken here). Reasoning for (b), not asserted by default:

- **Route (a) would require modifying `PluginInterface.invoke/2,3` and/or
  `PluginHandler`/`handle_node/1`, or rewriting all seven `wasm_hang`-tagged tests to
  call a new wrapper instead of `invoke/2,3` directly.** Either sub-option re-opens
  exactly the scope boundary §1 stated as deliberate: `invoke/2,3` is REQ-057/165's own
  shipped, gate-approved crash-safety algorithm, reused unmodified by REQ-170 already;
  changing it now to accept a lease parameter (or wrapping every call site, test and
  future-production alike, in a new required entry point) is a materially larger and
  differently-shaped change than "add an admission primitive," and was not what
  ISSUE-FIXER's diagnosis characterized as the missing piece — its own diagnosis
  described the gap as "no bound on how many such abandoned native executions can
  accumulate concurrently," which is what §5's primitive answers, not "the tests
  themselves need reshaping."
- **Widening scope to rewrite the `wasm_hang` tests specifically (a narrower version of
  route (a)) is plausible and is not rejected outright** — it would mean each
  `wasm_hang` test acquires/releases a lease around its own direct `invoke/2,3` call,
  using the SAME crash-safety reasoning §2 already worked out (the test process itself
  is never the process `Task.shutdown(:brutal_kill)` targets, exactly like a real
  future caller, so the reasoning transfers without re-deriving it). **This was not
  chosen in this rework because it silently answers OQ-C's own open question (which
  future requirement owns the real call site) by making the TEST SUITE the only caller
  that ever exists** — a fix that only tests exercise, with no production call site
  built, is a different and lesser deliverable than "the cap protects production
  traffic," and shipping it under this issue's own title ("operator-configurable cap on
  concurrently in-flight WASM invocations... so the isolated subprocess... cannot
  exhaust the pool") without also building the production path risks exactly the kind
  of "protection that looks real but isn't where it matters" finding this gate's own
  brief was watching for, just relocated from "gates nothing" to "gates only tests, not
  the traffic the issue is actually about." **This is flagged explicitly as a
  legitimate smaller-scope alternative ORCH may choose instead of full route (a) or (b)
  as written here** — a test-only wiring would genuinely fix the CI flake (this issue's
  proximate, measured pain) faster than waiting for OQ-C's production caller, at the
  cost of leaving production WASM dispatch unprotected by any cap until that caller
  exists. This design does not choose that path unilaterally; it names it as a third
  option for ORCH alongside the gate's original (a)/(b), since (b) as strictly stated
  leaves the 44% CI pass rate unresolved, which is the outcome ORCH's own dispatch
  flagged as unacceptable to leave silently unaddressed.
- **Given the ambiguity above, this design commits to (b) literally** (keep §1/§8.1's
  boundary, state the limitation) **and surfaces the test-only-wiring alternative to
  ORCH explicitly** rather than picking it silently — consistent with core-directives'
  "two or more genuinely equivalent options requiring a decision no agent can infer"
  rule: whether to accept a slower, fully-correct fix (wait for OQ-C's real dispatch
  integration) or a faster, narrower one (wire only the tests now, production later) is
  a real prioritization call about this issue's own urgency (44% CI pass rate, ORCH's
  own stated binding constraint) that this design does not have standing to make for
  ORCH.

---

## 7 — Required moduledoc content for `Letflow.Engine.Wasm.InvocationLease` (mirrors `CallTimeout`'s own precedent, §6 of req170's design)

Required moduledoc content, verbatim in substance (ELIXIR-DEV may adjust prose flow but
must preserve every factual clause):

> Bounds how many WASM guest invocations (`Letflow.Engine.Wasm.PluginHandler.run_guest/3`)
> may be simultaneously dispatched, admitted via a global counting semaphore
> (`try_acquire/0`/`release/1`). Filed against decision 0014's OQ-5 and
> `docs/issues/ISS-0418.yaml` (eleven-plus recurrences of a CI flake caused by the
> mechanism this module bounds). See
> `lib/letflow/design/iss0418-wasm-concurrency-cap.md` for the full design and its live
> diagnosis (`handoffs/WF03-ISS0418-20260905/step-01-issue-fixer-diagnosis.json`).
>
> **WHAT THIS MODULE DOES NOT GUARANTEE, STATED PLAINLY.** `wasmex` (Wasmtime via a Rust
> NIF) permanently leaks one native worker-thread-pool slot (`TOKIO_RUNTIME`, node-global,
> sized to `available_parallelism()`) per genuinely-hanging guest invocation, with no
> BEAM-side mechanism able to reclaim it, live-verified up to a 90-second observation
> window with zero recovery. This module bounds how many invocations may be
> **simultaneously in flight** — it does **not**, and cannot, reclaim an already-leaked
> thread, observe how many threads are currently leaked, or prevent eventual pool
> exhaustion if hangs keep occurring over a long enough time window at any nonzero rate.
> Every hang, admitted one at a time or many at once, permanently consumes one pool slot
> forever; this module changes the RATE and worst-case INSTANTANEOUS blast radius of
> exhaustion, not whether exhaustion can ultimately occur on a sufficiently
> long-lived, sufficiently abused node. The only mechanisms that reclaim a leaked
> thread are killing the OS process it lives in or restarting the BEAM node — both
> outside this module's scope; see the design doc §4 for named, unbuilt follow-up
> options (subprocess-per-invocation isolation; a periodic health-probe-triggered
> restart).
>
> **What this module DOES guarantee:** no more than the configured cap
> (`try_acquire/0`) of WASM invocations are ever simultaneously dispatched through
> `PluginHandler.run_guest/3`, admitted synchronously with no queue
> (`{:error, :capacity}` immediately on exhaustion, mirroring `Letflow.Admission`'s own
> non-queuing precedent) — bounding simultaneous worst-case damage from a burst of
> concurrent hangs to at most `cap` leaked slots at a time, rather than unboundedly many.
>
> **Why this is a new module, not an extension of `Letflow.Admission` (REQ-216):** see
> design doc §3. In short — `Letflow.Admission`'s documented crash semantics assume a
> caller that either cooperates (calls `release/2` itself) or crashes as a whole
> process; `PluginInterface.invoke/2,3`'s own brutal-kill-on-timeout mechanism kills
> only an INNER task while the outer caller survives, so this module acquires/releases
> its lease from that surviving outer caller and additionally monitors it, automatically
> releasing on that caller's own death — a shape `Letflow.Admission` does not have and
> was not built for. This module also has no per-tenant fair-share dimension, since the
> underlying leaked resource (`TOKIO_RUNTIME`) has no per-tenant partition at all.

---

## 8 — Call-site wiring: the one change to `PluginHandler`

**`PluginHandler.handle_node/1` gains a `try_acquire/0` at its very start and a
`release/1` guaranteeing cleanup on every return path** — this is the ONE integration
point this design specifies; no other module changes.

```
@spec handle_node(ExecutionContext.t()) :: Letflow.Engine.PluginInterface.outcome()
# Same signature/contract as today (REQ-165/170, unchanged). New behavior, stated
# in prose since this is a design doc: on entry, calls
# Letflow.Engine.Wasm.InvocationLease.try_acquire/0. {:error, :capacity} maps to
# this callback's own {:error, reason} outcome shape (a new, distinctly-worded
# reason string -- e.g. containing a stable substring such as
# "wasm invocation cap reached" -- so a future caller can distinguish this
# admission-rejection shape from CallTimeout's :wall_clock_timeout shape and from
# ResourceLimits'/HostApi's own shapes, by the same substring-matching convention
# CallTimeout.classify/1 already established; this design does not build that
# classifier itself, since no acceptance criterion here asks for one -- named as
# an open question, S9 OQ-A). {:ok, lease} proceeds to today's existing
# run_guest/3 call exactly as before, and releases the lease via the guaranteed-
# cleanup path described in S2/S8's own text below, regardless of which of
# run_guest/3's outcomes results -- {:ok, _}, {:error, _}, or an uncaught
# raise/exit inside this SAME process (handle_node/1's own process, which is the
# lease-acquiring process per S2 -- note this is DIFFERENT from S2's framing of
# "the invoke/2,3 CALLER" in the abstract; S8.1 below reconciles this precisely,
# since it changes which process actually holds the monitor).
```

### 8.1 — Precisely which process holds the lease: reconciling §2's framing with the real call graph

**§2 spoke of "the caller of `PluginInterface.invoke/2,3`" in the abstract to state the
general principle (acquire outside the process that can be brutal-killed). This
section pins down the concrete call graph, since `PluginHandler.handle_node/1` itself
runs INSIDE the very task `Task.Supervisor.async_nolink/2` spawns and
`Task.shutdown(:brutal_kill)` can kill** — i.e. `handle_node/1`'s own process is
**not** safe from the kill, contradicting a naive reading of §2.

**Resolution: the lease is acquired one level further out — by `invoke/2,3`'s own
caller, before `invoke/2,3` is even called, not inside `handle_node/1`.** This changes
§8's call-site wiring from what a first reading might suggest:

- **`PluginInterface.invoke/2,3` is NOT modified** (§1's own stated scope boundary,
  preserved) — it does not know about leases at all.
- **The actual new call site is one level up: wherever engine/dispatch code calls
  `PluginInterface.invoke(Letflow.Engine.Wasm.PluginHandler, context, opts)`** (per
  decision 0014/`plugin_interface.ex`'s own moduledoc, this call site does not exist
  yet in the shipped codebase today — REQ-057's own moduledoc states runtime dispatch
  wiring is future work, "most plausibly REQ-056, pending"). **This design therefore
  states the contract that future dispatch-integration call site must follow, rather
  than building a call site that does not exist yet** — mirroring REQ-170 §4.4's own
  precedent of stating a future composition point without building it prematurely:
  that caller must (a) call `InvocationLease.try_acquire/0` before calling
  `PluginInterface.invoke/2,3` **at all**, (b) map `{:error, :capacity}` to its own
  appropriate outcome without ever calling `invoke/2,3` in that case (so a
  capacity-rejected invocation never reaches `PluginHandler`, never starts a `Wasmex`
  instance, and therefore adds zero native-pool pressure), and (c) release the lease
  in a `try/after`-equivalent wrapped around the `invoke/2,3` call, guaranteeing
  release regardless of `invoke/2,3`'s returned `outcome()` shape.
- **§8's `handle_node/1` code-shape sketch above is corrected by this section: strike
  it.** `PluginHandler.handle_node/1` itself is NOT where `try_acquire/0`/`release/1`
  are called — that was this design's own first-draft error, caught and corrected in
  this same authoring pass rather than shipped, per this project's own
  "verify against the real source, don't assume" discipline. The correct, single
  integration point is the **future dispatch-integration call site** named above.
- **Why this is still safe against the exact brutal-kill scenario §2 exists for:**
  the process that calls `PluginInterface.invoke/2,3` (and therefore holds the lease)
  is, by construction of `invoke/2,3`'s own algorithm, never the process
  `Task.shutdown(:brutal_kill)` targets — that call always targets the INNER task
  `invoke/2,3` itself spawns via `Task.Supervisor.async_nolink/2`, one level below
  `invoke/2,3`'s own caller. The lease-holder is therefore always exactly one level
  outside the kill radius, regardless of how many internal layers `handle_node/1`'s own
  call graph has. `invoke/2,3`'s own AC3 guarantee (already live-verified, REQ-170
  §1.6) — the caller is reliably unblocked within a bound, by a mechanism outside the
  killed task — is exactly what makes the lease-holder's own `try/after`-equivalent
  release reachable no matter what the guest does.

**This correction is recorded here, in the design itself, rather than silently fixed
without comment** — CODE-DESIGN-VALIDATOR should treat §8's original code-shape
sketch as superseded by this section, not as two conflicting instructions to choose
between.

---

## 9 — Open questions this design leaves for ELIXIR-DEV, stated rather than guessed

- **OQ-A — should `{:error, :capacity}` at this cap be distinguishable, by pattern
  match, from `CallTimeout`'s `:wall_clock_timeout` and `ResourceLimits`'
  fuel/memory-cap shapes?** No acceptance criterion in this issue asks for it. This
  design recommends a distinctly-worded, stable substring (e.g. `"wasm invocation cap
  reached"`) purely so a future classifier COULD be added without re-deriving the
  string, but does not build the classifier itself — genuinely new scope if wanted,
  not blocking.
- **OQ-B — the exact numeric default (§5.5) and its config key's final name.** §5.5
  recommends `System.schedulers_online()`-derived headroom below the actual native pool
  size, but the precise formula/value is ELIXIR-DEV's to finalize with a one-line
  justification, mirroring REQ-170 §9 OQ-1's identical precedent for
  `@default_wasmex_timeout_ms`.
- **OQ-C — where the future dispatch-integration call site (§8.1) actually lives.**
  This design states the CONTRACT that call site must follow; it does not know which
  future requirement builds it (REQ-057's own moduledoc names REQ-056 as the most
  plausible owner, still `pending` as of this writing). Whoever builds that requirement
  must read this design's §8.1 before wiring `PluginInterface.invoke/2,3` into a real
  dispatch path, so the lease is not silently omitted from the first real caller.
- **OQ-D (REWORK: superseded, restated) — does closing ISS-0418's own CI flake require
  pulling the `wasm_hang` tests onto this design's lease, ahead of OQ-C's production
  call site?** §6.4 names this explicitly as a real, undecided prioritization question
  for ORCH: (i) wait for OQ-C's real dispatch-integration requirement and accept the
  flake persists until then, or (ii) as a narrower, faster interim step, rewrite the
  seven `wasm_hang`-tagged tests to acquire/release a lease around their own existing
  direct `invoke/2,3` calls (reusing §2's crash-safety reasoning verbatim, since a test
  process is never the process `Task.shutdown(:brutal_kill)` targets, exactly like a
  real caller), closing the flake immediately at the cost of leaving production WASM
  dispatch itself uncapped until OQ-C's caller exists. This design does not choose (i)
  or (ii) — that decision belongs to ORCH, informed by this rework's correction, not to
  CODE-DESIGNER unilaterally widening or narrowing scope after a gate FAIL.

None of these open questions block implementation of §5/§8's actual contract. OQ-D
specifically DOES block whether this run, as currently scoped, resolves ISS-0418's own
selection criterion (the 44% CI pass rate) — see §6's own retraction.

---

## 10 — Traceability: ISS-0418's own decision points → design elements

| # | Decision point (from ISSUE-FIXER's step-01 handoff, §5) | Design element |
|---|---|---|
| 1 | Adopt Option A (admission gating) as primary mechanism; solve never-released-ref-on-brutal-kill | §2 (lease acquired/released one level outside the kill radius, monitor-backed); §8.1 (exact call-site correction) |
| 2 | Document plainly that the cap bounds concurrent invocations, not leaked threads, and the leak is confirmed unbounded | §0 (headline statement); §7 (required moduledoc content) |
| 3 | Name Option D (subprocess isolation / health-probe restart) as follow-up scope, not built here | §4 |
| 4 | The cap's numeric default and config surface | §5.5; OQ-B |
| 5 | Extend `Letflow.Admission` or build new — justified explicitly | §3 (four independent reasons) |
| — | Is reclamation possible at all (ISS-0418's own item 4 in the task description) | §4 (no — stated plainly, with the two named non-cap follow-ups) |
| — | Test strategy: deterministic vs. probabilistic fix for `wasm_hang` | §6 (REWORK: neither — this design does not fix the flake at all, since no code path it builds is called by the flaking tests; §6.1 states what it delivers instead, §6.4 names the undecided prioritization question for ORCH) |

---

## 11 — Confirmation: exactly which existing files this design touches, and which it does not

**New files:** `lib/letflow/engine/wasm/invocation_lease.ex` (§5/§7); one new test file,
`test/letflow/engine/wasm/invocation_lease_test.exs` (§6.2) — TEST-DESIGNER's scope, not
built here.

**Modified:** `lib/letflow/application.ex` (add `InvocationLease` as a new supervised
child, §5.1 — no ordering dependency on any existing child).

**NOT modified by this design (REWORK: this list grew — §6's correction removes the
`config/test.exs`/`letflow.check.test.ex` test-override entry the prior revision
claimed here, since that override gated nothing and is no longer proposed):**
`lib/letflow/admission.ex` (§3 — a new module is used instead, Admission stays exactly
as REQ-216/REQ-217/REQ-218 shipped it); `lib/letflow/engine/plugin_interface.ex` (§8.1 —
the lease is acquired/released by `invoke/2,3`'s future caller, never inside
`invoke/2,3` itself); `lib/letflow/engine/wasm/plugin_handler.ex` (§8.1's correction —
this design's first draft proposed a `handle_node/1` change and struck it in the same
pass once the actual brutal-kill boundary was traced precisely; `PluginHandler` needs no
change at all); `test/letflow/engine/wasm/{call_timeout,plugin_handler,host_api_write}_test.exs`
(§6 — the existing `:wasm_hang`-tagged tests are unmodified; this is the direct
consequence of this design's own scope boundary, stated here rather than only in §6, so
this file-touch inventory itself does not silently imply the flake was addressed);
`test/test_helper.exs`, `lib/mix/tasks/letflow.check.test.ex`, `config/test.exs` (§6 —
no test-environment override is specified by this design; ISS-0352's existing isolation
architecture is left exactly as it stands);
`lib/letflow/engine/wasm/call_timeout.ex`, `resource_limits.ex`, `capability_gate.ex`,
`module_registry.ex`, `memory_guard.ex` (untouched, no interaction with this design's
scope).
