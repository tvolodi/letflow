# Design: ISS-0048 (sandbox half) — `Letflow.SandboxPool` owner-crash/kill reclaim

**Issue:** `docs/issues/ISS-0048.yaml`, scoped per ISSUE-FIXER's diagnosis
(`handoffs/WF03-ISS0048-20260818/step-01-issue-fixer.json`'s `result.summary`, read in
full for this design) to the one part of ISS-0048 that is live-reproducible and
structurally real: `Letflow.SandboxPool`'s claim-through-release span has no safety net
for an `exit` signal (a hard process kill, an ExUnit test-timeout kill, or a
linked-crash propagation) hitting the *owning* process between `claim/2` and
`release/2`. `try/rescue` — the only safety net that exists today, both inside
`SandboxPool.provision_sandbox/0` and inside `Letflow.Definitions.run_replay_span/8` —
does not run on an `exit` signal, only on a raised exception. This document is
design-only: interfaces/`@spec`s, GenServer state shape, and algorithm steps in prose.
**No implementation code** — no `.ex`/`.exs` code blocks with real function bodies.
Pseudocode blocks (`IF`/`CASE`/`END`) are logic-shape descriptions only, matching this
project's `req018-jit-provisioning.md` §3.3 / `iss-0047-username-race-conflict-target.md`
§2.2 convention for this kind of surgical, non-full-module design.

**Owner (implementer):** ELIXIR-DEV
**Run:** `WF03-ISS0048-20260818`, WF-03 Step 2

**REWORK NOTICE (2026-08-18, rework iteration 1):** §§1-12 below are the original design,
implemented byte-for-byte by ELIXIR-DEV in commit `ef1e4c8` and confirmed structurally
correct — but ELIXIR-DEV found a genuine ambiguity the original design did not consider:
the owner-monitor mechanism (`Process.monitor(elem(from, 0))`, §5.1/§5.2) cannot
distinguish "the calling process died without releasing (a real leak)" from "the calling
process was a short-lived helper (e.g. `Task.async`) that legitimately handed the claim
off to a longer-lived process before exiting `:normal`" — and
`test/letflow/sandbox_pool_test.exs:192-221`'s existing "a queued waiter is served"
test does exactly the latter (claims via `Task.async`, releases from the test process),
so it now fails deterministically (3/3 reproductions;
`handoffs/WF03-ISS0048-20260818/step-03-elixir-dev.json`'s `result.summary` has the full
trace). **§13 below resolves this — read §13 as authoritative wherever it overrides
anything in §§1-12; §§1-12 are left unedited in place as the historical record of what
was validated and implemented before this gap was found, not because they are still
fully accurate on their own.** In particular, §13 supersedes: §1's scope-boundary table
(test-file ownership), §9's cross-module dependency table (test file moves from
"TEST-DESIGNER's own scope" to "in scope for this fix"), and §10's TEST-DESIGNER guidance
item 2 (now a mandatory rework, not an optional judgment call).

---

## 0. Sources read in full for this design

- `handoffs/WF03-ISS0048-20260818/step-01-issue-fixer.json` (`result.summary`, full) —
  ISSUE-FIXER's diagnosis: the tenant_*-schema half of ISS-0048's original title could
  not be reproduced against the live test DB (0 orphans, and the 5 originally-suspected
  identity/role_registry test files were read directly and confirmed to already register
  `on_exit` cleanup *before* their risky provisioning call, so a raise there still fires
  cleanup — no gap found). The one *live, reproduced* orphan
  (`sandbox_5050499590a9426186656f72f7296622` in `letflow_test`) belongs to
  `Letflow.SandboxPool`, and the mechanism is confirmed structurally: `try/rescue` does
  not catch `exit` signals, and both `lib/letflow/sandbox_pool.ex`'s own moduledoc and
  `lib/letflow/definitions.ex`'s moduledoc/`apply_promotion_assertion_rerun/6` `@doc`
  already *disclose* this gap as a deferred, never-built reaper follow-up. This design
  builds the deferred safety net for the specific case ISSUE-FIXER demonstrated: the
  *caller's* process dying, not `SandboxPool`'s own process dying (that is the
  separate, already-accepted OQ-3 in `req039-sandbox-pool-fixture-loader.md`, restated
  in §7 below).
- `docs/issues/ISS-0048.yaml` (full) — original finding text; per ISSUE-FIXER's own
  note, its "likely candidates" prose about the 5 identity/role_registry test files did
  not hold up under direct reading, and this design does not touch those 5 files (task
  instruction, restated in §1).
- `lib/letflow/sandbox_pool.ex` (full, 276 lines, current shipped state, quoted
  extensively below) — `SandboxClaim` struct, `start_link/1`, `claim/2`, `release/2`,
  `init/1`'s state shape (`%{max_concurrent, active, waiting}`), `handle_call({:claim,
  ...})`, `handle_call({:release, ...})`, `handle_info({:claim_timeout, ...})`,
  `handle_info({:DOWN, ...})` (the **existing** waiting-queue-only monitor precedent this
  design extends to active claims), `handle_provision_now/1`, `handle_queue_or_reject/3`,
  `service_next_waiter/1`, `find_waiter/2`, `remove_waiter/2`, `provision_sandbox/0`,
  `drop_schema/1`.
- `lib/letflow/definitions.ex` lines ~1466-1650 and moduledoc lines ~55-88,
  `apply_promotion_assertion_rerun/6`'s `@doc` (~lines 755-786) — confirmed
  `apply_promotion_assertion_rerun/6` runs **synchronously in its caller's own process**
  (no `Task.async`/`spawn` anywhere in `claim_sandbox_and_proceed/8` or
  `run_replay_span/8`) — so the process that calls `SandboxPool.claim/2` (via
  `claim_sandbox_and_proceed/8`) is exactly the same process ISSUE-FIXER's diagnosed
  kill scenario targets (a test process killed by an ExUnit timeout, or a future HTTP
  request-handling process once S4 routes exist). This is load-bearing for §3's design:
  monitoring `claim/2`'s caller pid inside `SandboxPool` directly observes the process
  whose death actually causes the leak — no relay through `Letflow.Definitions` is
  needed.
- `lib/letflow/design/req039-sandbox-pool-fixture-loader.md` §2 (the GenServer-not-a-row
  decision this design does not revisit), §4.3 (existing state shape), §4.4 steps 3/6/7
  (the existing waiting-queue monitor precedent), §4.7 INV-SP-6 (the analogous
  already-solved problem for *queued* callers), and **§11 OQ-2** — which already named
  this exact gap ("owner-crash detection for an already-provisioned... claim... left
  for REQ-040 or a dedicated follow-up") and floated exactly this design's mechanism
  ("a `Process.monitor/1` on every already-provisioned claim's owning pid, not just
  queued waiters"). This design is that follow-up, closing OQ-2.
- `docs/agents/instructions/core-directives.md` (session-start mandatory reading) —
  "Every producing step has a validating step," "No Speculation," instruction
  precedence, file placement rules (`lib/letflow/design/`).
- `docs/guides/backend_developer_guide.md` §3.2-3.7 — GenServer-vs-row discipline (not
  revisited here, §2.3 below states why), `{:ok, _} | {:error, atom()}` error
  convention (preserved, §5), SQL parameterization/`prefix:` discipline (unaffected —
  this design adds no new SQL beyond the existing `drop_schema/1` call site, reused
  as-is).
- `docs/anti-patterns.md` — read in full; no entry directly applicable, no new entry
  proposed by this design (unlike `iss-0047-...`'s design, which did propose one).

---

## 1. Scope boundary (restated from the handoff, precisely)

**In scope:** `Letflow.SandboxPool`'s crash/kill safety gap for the claim-through-release
span, i.e. what happens when the process that called `SandboxPool.claim/2` dies (by any
`exit` reason — kill, timeout, linked-crash propagation) before calling
`SandboxPool.release/2`.

**Explicitly out of scope, not silently dropped:**

| Not built here | Why | Where it's tracked |
|---|---|---|
| The 5 originally-suspected identity/role_registry test files (`test/letflow/identity_test.exs`, `identity/user_test.exs`, `identity/group_test.exs`, `identity/tenant_role_test.exs`, `role_registry_test.exs`) | ISSUE-FIXER read all 5 directly and confirmed correct `on_exit` ordering (registered before the risky call) — no gap found, and the task instruction says not to touch them | Handoff task description; ISSUE-FIXER's `result.summary` |
| `SandboxPool`'s own process crashing/restarting (not the *caller's* process) | A distinct, already-accepted limitation — `active` is pure in-memory state and resets on a `SandboxPool` restart regardless of any owner-monitor mechanism | `req039-sandbox-pool-fixture-loader.md` §11 OQ-3 (unchanged by this design) |
| A hard BEAM node crash / `System.halt/0` | No Erlang-level signal fires in this case either — `:DOWN` messages require the monitoring process (here, `SandboxPool`) to survive to receive them | `lib/letflow/definitions.ex` moduledoc (~line 69-70), unchanged, still an accurate disclosure |
| A periodic/background reaper sweeping `information_schema.schemata` | Considered and rejected in favor of the owner-monitor mechanism — §2 below is the full justification | N/A — this design's own §2 |
| Any change to `Letflow.Definitions.apply_promotion_assertion_rerun/6`'s or `run_replay_span/8`'s own `try/rescue` | Not needed — this fix lives entirely inside `SandboxPool`, transparent to every existing caller (§4) | §4 |

---

## 2. Fix mechanism selected: (a) supervised owner-monitor inside `SandboxPool`

Two mechanisms were named in the handoff task; this design picks **(a)**, not (b) the
standalone periodic reaper, and justifies the choice against `SandboxPool`'s actual
current architecture (not an assumed one).

### 2.1 `SandboxPool` already has exactly this mechanism, half-built, for a different half of its own lifecycle

`SandboxPool`'s `handle_queue_or_reject/3` (sandbox_pool.ex:186-191) already does
`Process.monitor(caller_pid)` on every **waiting** caller, and
`handle_info({:DOWN, caller_ref, :process, _pid, _reason}, state)`
(sandbox_pool.ex:155-164) already reclaims that waiter's queue slot — with a timer
(`Process.cancel_timer/1`) cleaned up alongside — the moment that caller dies before a
sandbox slot ever reaches it. This is the *identical* problem this design solves, one
lifecycle stage later: a caller that already *received* its claim can die too, and today
nothing detects that. Extending the existing monitor discipline from "queued caller" to
"claim-holding caller" is a natural, symmetric extension of a pattern this module
already owns and already tests reason about — not a new mechanism being introduced.

### 2.2 Why not (b), the standalone periodic reaper — against this module's real architecture, not an assumed one

A periodic reaper (`information_schema.schemata` sandbox_*/tenant_* scan vs. an active-
claims table, dropping true orphans past an age threshold) was explicitly considered and
rejected for three concrete, architecture-specific reasons:

1. **It requires exactly the DB-backed "active-claims table" `req039`'s own §2 already
   rejected.** `req039-sandbox-pool-fixture-loader.md` §2.2-§2.3 chose a pure in-memory
   `GenServer` specifically because the arbitration property (`claim/1`'s
   at-most-one-winner blocking-quota-wait) is free from a single process's mailbox and
   would otherwise require a DB-level lock to re-derive. A periodic reaper comparing
   live Postgres schemas against "an active-claims table" needs that table to exist
   *somewhere* — either a new persistent table (reintroducing the exact row-based
   state `req039` reasoned away), or the reaper re-deriving "which schemas are
   legitimately still claimed" from `SandboxPool`'s own in-memory `active` map anyway
   (in which case it is just a slower, polling-interval-bounded version of what an
   owner-monitor gets for free, immediately, with zero polling latency).
2. **ISSUE-FIXER's own diagnosis flags the false-positive risk a reaper inherits from
   ISS-0048's own detection methodology.** ISS-0048's own query
   (`schema NOT IN (SELECT schema_name FROM tenant_schemas)`) flags every `sandbox_*`
   schema as "orphaned," including ones correctly mid-lifecycle — `sandbox_pool.ex:
   239-243`'s own comment states sandboxes are deliberately never registered in
   `tenant_schemas`. A reaper built on the same "not in `tenant_schemas`" shape would
   need its own separate, correct notion of "currently active" to avoid dropping a
   sandbox that is mid-replay (a live, correct claim, not a leak) — which is exactly
   the active-claims-table problem in (1), not a simpler one.
3. **An owner-monitor reclaims immediately; a reaper's age threshold is a tuning
   parameter with no correct default.** `SandboxPool` sandboxes are designed for
   short-lived, single-call claim/release spans (per `req039`'s own OQ-3 reasoning,
   restated in §7) — a reaper's "past an age threshold" necessarily either reclaims too
   eagerly (racing a legitimately slow-but-still-running replay) or too late (leaving
   the leaked schema, and its consumed quota slot, live for the full threshold window
   every time). An owner-monitor has no such trade-off: it reclaims the instant Erlang
   itself observes the owning process is gone, which is the earliest correct moment by
   construction.

**Decision: (a).** Extend `SandboxPool`'s existing `Process.monitor`/`handle_info(:DOWN,
...)` discipline (currently scoped to *waiting* callers only) to also cover
*claim-holding* callers. Zero new DB objects, zero new supervised processes, zero new
public API surface (§4) — a state-shape and internal-handler extension only.

---

## 3. GenServer state shape — before and after

**Before** (current, sandbox_pool.ex:111-113):

```
%{
  max_concurrent: pos_integer(),
  active: %{optional(sandbox_id :: String.t()) => schema_name :: String.t()},
  waiting: :queue.queue({from :: GenServer.from(), caller_ref :: reference(), timer_ref :: reference()})
}
```

**After** — `active`'s value type changes from a bare `schema_name` string to a small map
carrying the schema name plus the new owner-monitor reference:

```
%{
  max_concurrent: pos_integer(),
  active: %{optional(sandbox_id :: String.t()) => %{
    schema_name: String.t(),
    owner_ref: reference()
  }},
  waiting: :queue.queue({from :: GenServer.from(), caller_ref :: reference(), timer_ref :: reference()})
}
```

- `owner_ref` is the `reference()` returned by `Process.monitor/1` on the pid that
  received this claim (extracted from `handle_call`'s own `from :: GenServer.from()`,
  i.e. `elem(from, 0)` — the calling process's pid; `GenServer.from()` is
  `{pid(), tag :: term()}` per OTP's own documented shape, so no new mechanism is
  needed to obtain it).
- No new top-level state field, no new reverse-lookup map. `handle_info({:DOWN, ref,
  :process, _pid, _reason}, state)` scans `state.active`'s (small — bounded by
  `max_concurrent`, an operator-set quota expected to be a small integer, per
  `req039`'s own `config :letflow, :sandbox_pool, max_concurrent_sandboxes: 5` default)
  values for a matching `owner_ref`, exactly mirroring the existing `find_waiter/2`'s
  own linear-scan style against `waiting` (sandbox_pool.ex:219-221) — consistent with
  this module's own established idiom for "small bounded collection, scan it," not a
  new data-structure choice needing separate justification.
- `waiting`'s shape is **unchanged** — this design does not touch the queued-waiter
  path at all (§2.1's existing mechanism there is already correct and complete).

---

## 4. Public interface — `@spec`s, all unchanged

**No new public function. No changed public `@spec`.** This is a deliberate, load-bearing
property of the fix, restated explicitly per the handoff's acceptance criterion:

```
@spec claim(max_wait_ms :: non_neg_integer(), pool :: GenServer.server()) ::
        {:ok, SandboxClaim.t()}
        | {:error, :sandbox_unavailable}
        | {:error, :provision_failed}
        | {:error, term()}
```

```
@spec release(sandbox_id :: String.t(), pool :: GenServer.server()) ::
        :ok
        | {:error, :not_found}
        | {:error, :release_failed}
```

Both signatures, both return-value taxonomies, and `start_link/1`'s `@spec` are
byte-for-byte unchanged from the currently shipped `sandbox_pool.ex`. Every existing
caller — `Letflow.Definitions.claim_sandbox_and_proceed/8`,
`run_replay_span/8`/`safe_release/2`, `handle_fixture_load_failure/7`, and any test
calling `SandboxPool.claim/2`/`release/2` directly — continues to compile and behave
identically for every path it already exercises. The only externally observable
*behavioral* addition is new: a claim whose owning process dies before `release/2` is
called now gets its schema dropped and its quota slot freed automatically, where today
it does neither. No existing caller can observe this as a behavior change, because no
existing caller relies on (or tests for) the leak persisting.

---

## 5. Algorithm changes (steps, not code)

### 5.1 `handle_call({:claim, max_wait_ms}, from, state)` — immediate-provisioning path

Current `handle_provision_now/1` takes only `state`; it must now also receive `from`, so
the newly successful claim can be attributed to its caller's pid for monitoring.

**New shape of `handle_provision_now(from, state)`:**

1. `provision_sandbox/0` runs exactly as today (unchanged: mints `sandbox_id`, `CREATE
   SCHEMA`, replays `tenant_scoped_migrations/0`, best-effort `drop_schema/1` +
   `{:error, :provision_failed}` on any failure in that span — this design does not
   touch `provision_sandbox/0` at all).
2. On `{:ok, %SandboxClaim{} = claim}`:
   - Extract the caller's pid: `caller_pid = elem(from, 0)`.
   - `owner_ref = Process.monitor(caller_pid)`.
   - `new_active = Map.put(state.active, claim.sandbox_id, %{schema_name:
     claim.schema_name, owner_ref: owner_ref})`.
   - Reply `{:reply, {:ok, claim}, %{state | active: new_active}}` — same reply shape
     and same `{:reply, ...}` return convention as today; only the stored `active`
     entry's shape changed (§3).
3. On `{:error, :provision_failed}`: reply unchanged, no monitor established (nothing
   was claimed).

### 5.2 `service_next_waiter/1` — the hand-off-to-a-waiter path (sandbox_pool.ex:197-217)

Same extension as §5.1, applied at the other call site that successfully mints a claim.
On `provision_sandbox/0` returning `{:ok, %SandboxClaim{} = claim}` for the popped
waiter: `caller_pid = elem(from, 0)` (the popped waiter's own `from`, already available
in this function's existing `{from, caller_ref, timer_ref}` destructure — `caller_ref`
here is the *waiting*-monitor reference, already demonitored/flushed one line earlier
per the existing code at sandbox_pool.ex:200-201, and is a distinct reference from the
new `owner_ref` this step establishes), `owner_ref = Process.monitor(caller_pid)`, store
`%{schema_name: claim.schema_name, owner_ref: owner_ref}` in `active` under
`claim.sandbox_id`, then `GenServer.reply(from, {:ok, claim})` exactly as today.

### 5.3 `handle_call({:release, sandbox_id}, from, state)` — the release path (sandbox_pool.ex:124-140)

1. `Map.fetch(state.active, sandbox_id)`:
   - `:error` → reply `{:error, :not_found}`, unchanged.
   - `{:ok, %{schema_name: schema_name, owner_ref: owner_ref}}` → continue (was `{:ok,
     schema_name}` before; destructure updated for the new value shape, no behavioral
     change to this branch's decision logic).
2. `drop_schema(schema_name)` — unchanged, same function, same call.
   - `:ok` → **new step:** `Process.demonitor(owner_ref, [:flush])` before removing the
     entry — the caller releasing its own claim normally must not leave a stale monitor
     that could otherwise deliver a late, harmless-but-wasteful `:DOWN` message after
     the entry is already gone. (`[:flush]` matches the existing `demonitor` call for
     waiting-queue entries at sandbox_pool.ex:161/201 — same idiom, same option.) Then:
     reply `:ok`, remove the entry from `active`, run `service_next_waiter/1` — all
     exactly as today.
   - `{:error, :release_failed}` → reply unchanged, entry (including `owner_ref`) is
     **retained**, exactly matching today's "a schema whose DROP failed is still
     occupying its quota slot in reality" reasoning (sandbox_pool.ex's own inline
     comment, unchanged) — the monitor stays live too, which is correct: if the
     *caller* that got `{:error, :release_failed}` back also dies without ever
     successfully retrying `release/2`, §5.4 below still reclaims it.

### 5.4 `handle_info({:DOWN, ref, :process, _pid, reason}, state)` — dispatch extended

Today this clause only ever matches a *waiting*-queue `caller_ref` (sandbox_pool.ex:
155-164; a `:DOWN` for any other reference the process didn't itself set up would
already just fall through unmatched — this module currently has no `handle_info` clause
for an unmatched `:DOWN` at all, meaning today an active-claim owner's death is silently
dropped as an unhandled message under OTP's default `handle_info` behavior... **not
correct: `use GenServer` without a catch-all `handle_info` raises a `FunctionClauseError`
in the GenServer process on any unmatched message** — this is itself part of the bug
surface ISSUE-FIXER's diagnosis implies but does not call out by name: today, if a
`SandboxPool`'s active-claim owner dies, `SandboxPool` receives a `:DOWN` message it has
no clause for, and (absent a catch-all) **crashes the `SandboxPool` GenServer itself**,
which would then be restarted by its supervisor with `active` reset to empty — losing
*every* other concurrently-held claim's bookkeeping too, a strictly worse outcome than
the single-schema leak ISS-0048 describes. This is confirmed by direct reading of
`sandbox_pool.ex`'s `handle_info` clauses (only `{:claim_timeout, _}` and `{:DOWN,
caller_ref, ...}` restricted implicitly to whatever the compiler allows to pattern-match
— since `{:DOWN, ref, :process, pid, reason}` is a fixed 5-tuple shape, the *existing*
clause already matches syntactically for an active-claim owner's `:DOWN` too, and then
`find_waiter(state.waiting, caller_ref)` returns `nil` since that ref isn't a waiter,
falling into the existing `nil -> {:noreply, state}` no-op branch (sandbox_pool.ex:
156-157) — so today's actual behavior is a **silent no-op**, not a crash; correcting the
above: the existing `nil` branch already prevents a `FunctionClauseError`, it just also
means an active-claim owner's death is currently observed and silently discarded, which
is the precise, confirmed mechanism of the leak).

**New shape**, replacing the current two-clause body with a three-way dispatch:

```
CASE find_waiter(state.waiting, ref) OF
  {from, ^ref, timer_ref} ->
    # unchanged existing behavior (sandbox_pool.ex:148-151, still ok/queued-waiter path)
    Process.cancel_timer(timer_ref)
    new_waiting = remove_waiter(state.waiting, ref)
    {:noreply, %{state | waiting: new_waiting}}

  nil ->
    CASE find_active_by_owner_ref(state.active, ref) OF
      {sandbox_id, %{schema_name: schema_name}} ->
        # NEW: the owner of an already-granted claim died before release/2.
        drop_schema(schema_name)
        new_active = Map.delete(state.active, sandbox_id)
        new_state = service_next_waiter(%{state | active: new_active})
        {:noreply, new_state}

      nil ->
        # Neither a waiter nor an active-claim owner -- unchanged no-op
        # (e.g. a stray :DOWN for an already-demonitor([:flush])'d ref racing
        # its own flush, which [:flush] is specifically documented to prevent,
        # or a :DOWN this process never asked for).
        {:noreply, state}
    END
END
```

- `find_active_by_owner_ref/2` is a new private helper, same linear-scan idiom as
  `find_waiter/2`: `Enum.find(Map.to_list(active), fn {_sandbox_id, %{owner_ref: r}} ->
  r == ref end)`, returning `{sandbox_id, entry}` or `nil` — shown here as prose/shape,
  not literal Elixir source, per this document's no-code-blocks constraint (the
  `Enum.find`/`Map.to_list` naming is stated to make the algorithm's O() characteristics
  and its parallel to `find_waiter/2` unambiguous to ELIXIR-DEV, not as literal source to
  paste in).
- `drop_schema/1` is reused exactly as-is (sandbox_pool.ex:269-274) — its return value
  (`:ok` or `{:error, :release_failed}`) is **not** pattern-matched here, deliberately:
  there is no live caller to reply to (the caller that would have received a `release/2`
  reply is the same process that just died), so this path is unconditionally
  best-effort, matching `provision_sandbox/0`'s own "swallow its own failure — this is
  cleanup, not the primary error path" precedent (sandbox_pool.ex:256-262). If
  `drop_schema/1` itself fails here (e.g. Postgres unreachable at that moment), the
  `active` entry is still removed and the slot is still freed — an intentional,
  disclosed trade-off (§6, INV-SP-DOWN-3) rather than retaining a stale entry no live
  process can ever retry releasing.
- `service_next_waiter/1` is called on the *post-deletion* state exactly as `release/2`'s
  own success path already does (§5.3) — a slot freed by a dead owner is immediately
  eligible to be handed to a parked waiter, same as a slot freed by a normal `release/2`.
- `reason` (the `:DOWN` message's third positional field after `ref`/`:process`) is
  bound but unused in both the existing waiter branch and the new active-claim branch —
  matching the existing code's own `_reason` convention (sandbox_pool.ex:155) exactly;
  this design does not propose branching on `reason` (e.g. treating `:normal` differently
  from `:killed`) since a claim-holding process legitimately exiting `:normal` without
  ever calling `release/2` is exactly as much of a leak as one that was killed — both
  must reclaim identically.

### 5.5 `handle_info({:claim_timeout, caller_ref}, state)` — unchanged

Not touched by this design; still scoped to the `waiting` queue only, exactly as today.
An active-claim owner is never subject to a `claim_timeout` message (that timer is
cancelled the moment a claim is granted, per the existing `service_next_waiter/1`/
`handle_provision_now/1` code paths — unchanged).

---

## 6. New/changed invariants

Numbered to extend `req039-sandbox-pool-fixture-loader.md` §4.7's `INV-SP-*` series
without renumbering it (that document is not being edited by this change — these are
this design's own invariants, prefixed distinctly).

- **INV-SP-DOWN-1.** Every `sandbox_id` present in `state.active` has a live
  `owner_ref` monitoring the pid that currently holds that claim — established at the
  moment the claim is granted (§5.1, §5.2) and torn down (`demonitor/2` with `[:flush]`)
  only on that same claim's own successful `release/2` (§5.3). No claim exists in
  `active` without a corresponding monitor once this design ships (a strengthening of
  `req039`'s own INV-SP-2/INV-SP-4, which said nothing about monitoring).
- **INV-SP-DOWN-2.** A claim whose owning process exits for any reason (`:normal`,
  `:killed`, any other exit reason) before calling `release/2` is reclaimed — its schema
  is dropped (best-effort) and its quota slot is freed for the next `claim/2` or queued
  waiter — within one message-passing round-trip of Erlang delivering the `:DOWN`
  message, with no polling delay and no age-threshold tuning parameter (§2.2 point 3).
  This is the property that closes ISS-0048's live, reproduced gap.
- **INV-SP-DOWN-3.** Reclaiming a dead owner's claim (§5.4) never blocks or retries
  indefinitely on `drop_schema/1` failure — the `active` entry and its quota slot are
  freed unconditionally, even if the underlying `DROP SCHEMA` itself fails at that
  moment. This intentionally differs from `release/2`'s own `{:error, :release_failed}`
  path (§5.3, which *retains* the entry for a caller-driven retry) because there is no
  live caller left to retry on this path — retaining a permanently-unreclaimable entry
  here would itself become a second, unrecoverable form of quota leak (a slot stuck
  "occupied" forever, worse than the schema-only leak this design fixes), which this
  design judges strictly worse than a best-effort DROP that might occasionally leave a
  schema behind under a concurrent Postgres outage — a rarer and already-disclosed
  failure class (INV-SP-DOWN-4 below), not a new one this design introduces.
- **INV-SP-DOWN-4 (residual, disclosed, not fixed by this design).** If `drop_schema/1`
  fails during a dead-owner reclaim (§5.4) — e.g., Postgres itself is unreachable at that
  exact moment — the schema is not dropped, but the `active` entry is removed anyway
  (INV-SP-DOWN-3), so this occurrence becomes untracked by `SandboxPool` from that point
  on, indistinguishable from the case this design otherwise eliminates. This residual
  window is strictly narrower than today's gap (today, *every* owner-kill leaks; after
  this design, only an owner-kill that *also* coincides with a `DROP SCHEMA` failure
  leaks) — named explicitly per this project's "don't silently resolve an open question
  by guessing" discipline, not claimed as fully closed. A future reaper (§2.2's rejected
  mechanism, still legitimate as a *last-resort* sweep for this narrower residual case,
  should it ever prove operationally necessary) is the natural next layer, not
  contradicted by this design — just not needed for the case ISSUE-FIXER actually
  demonstrated.
- **INV-SP-DOWN-5.** This design adds no new invariant about `SandboxPool`'s own process
  surviving — `req039` §11 OQ-3's already-accepted limitation (a `SandboxPool` restart
  loses all bookkeeping, including every `owner_ref` this design adds) is unchanged and
  is not what ISSUE-FIXER's diagnosis is about (§1's scope table).

---

## 7. Interaction with `apply_promotion_assertion_rerun/6`'s existing `claim/2` → `release/2` contract

**No change required to `lib/letflow/definitions.ex` at all.** Restated precisely, per
the handoff's explicit acceptance criterion:

- `claim_sandbox_and_proceed/8` still calls `SandboxPool.claim(max_wait_ms,
  sandbox_pool)` and receives exactly the same `{:ok, %SandboxClaim{}}` /
  `{:error, :sandbox_unavailable}` / `{:error, :provision_failed}` shapes as today (§4)
  — it has no visibility into (and needs none) the new `owner_ref` bookkeeping, which is
  entirely internal to `SandboxPool`'s own state.
- `run_replay_span/8`'s existing `try/rescue` (definitions.ex:1532-1571) is completely
  unaffected — it still wraps Steps 3-6 exactly as today, still calls
  `safe_release/2` → `SandboxPool.release/2` in its `rescue` clause for a *raised
  exception* it catches. This design's fix activates on a *different, non-overlapping*
  failure class: an `exit` signal that kills the calling process outright, which by
  definition never reaches `run_replay_span/8`'s `rescue` clause (the process executing
  that `rescue` clause is the one being killed) — so there is no double-release race to
  reason about between the two mechanisms. If the calling process is killed, `rescue`
  simply never runs (the process is gone); `SandboxPool`'s own `:DOWN` handler runs
  instead, in `SandboxPool`'s process, independently.
- If the calling process instead merely **raises** (the case `try/rescue` already
  handles today) and `safe_release/2` successfully calls `SandboxPool.release/2`: §5.3's
  new `demonitor(owner_ref, [:flush])` step fires exactly as designed, and the owner
  monitor is torn down cleanly — no `:DOWN` message is ever generated for a normal
  `release/2`, so this design's new `handle_info` branch (§5.4) never fires for the
  already-handled "exception, not exit" case. The two safety nets are strictly
  layered, not redundant: `try/rescue` in `Letflow.Definitions` handles what it always
  could (raised exceptions, still releasing/finalizing the row with fail-closed
  accounting exactly as before); `SandboxPool`'s new owner-monitor handles what
  `try/rescue` structurally cannot (the calling process being killed outright), with no
  change to which mechanism handles which case.
- **One second-order effect worth naming, not silently assumed:** if
  `run_replay_span/8`'s `rescue` clause runs `safe_release/2` and that
  `SandboxPool.release/2` call itself times out or the calling process is killed
  *during* that very `GenServer.call`, the in-flight `release/2` request is abandoned
  mid-call — but the caller's pid dying is exactly what `SandboxPool`'s new `:DOWN`
  handler (§5.4) detects and reclaims independently, moments later, regardless of how
  far the abandoned `release/2` call had progressed. No scenario in this contract is left
  uncovered by neither mechanism.

---

## 8. What ELIXIR-DEV must NOT change

- `provision_sandbox/0` (sandbox_pool.ex:237-263) — unchanged in full; still returns
  `{:ok, %SandboxClaim{}}` / `{:error, :provision_failed}`, still does its own
  best-effort compensating `drop_schema/1` on a provisioning-time failure (a case that
  never reaches `active` at all, so it has no `owner_ref` to establish).
- `drop_schema/1` (sandbox_pool.ex:269-274) — unchanged, reused as-is at every call site
  this design adds (§5.3, §5.4).
- `claim/2`/`release/2`'s public `@spec`s and `start_link/1` — unchanged (§4).
- `handle_queue_or_reject/3`, `handle_info({:claim_timeout, ...})`, `find_waiter/2`,
  `remove_waiter/2` — unchanged; the waiting-queue mechanism is already correct (§2.1)
  and is not the target of this fix.
- Nothing in `lib/letflow/definitions.ex` (§7).

---

## 9. Cross-module dependencies (unchanged from `req039`'s own table, restated for completeness)

| Dependency | Direction | Kind |
|---|---|---|
| `Letflow.Definitions.claim_sandbox_and_proceed/8` / `run_replay_span/8` / `safe_release/2` | `Letflow.Definitions` → `SandboxPool.claim/2`, `SandboxPool.release/2` | Unchanged call sites, unchanged contract (§4, §7) |
| `Process.monitor/1`, `Process.demonitor/2`, `Map.to_list/1`, `Enum.find/2` | `SandboxPool` → Erlang/Elixir stdlib (existing dependencies — `Process.monitor/1`/`Process.demonitor/2` are already used by this module today for the waiting-queue path) | No new external dependency introduced |
| Test suite (`test/letflow/sandbox_pool_test.exs`, `test/letflow/definitions/promotion_assertion_rerun_test.exs`) | Both files are in `context.owned_modules` for this run — TEST-DESIGNER's step, not this design's own scope, but §10 below traces what new coverage this fix needs so TEST-DESIGNER isn't left guessing | See §10 |

---

## 10. What TEST-DESIGNER will need (named for the next step, not built here)

Not this design's own deliverable (CODE-DESIGNER produces design, not tests) — named so
TEST-DESIGNER has a concrete starting point per this project's acceptance-criteria
traceability convention:

1. A new test: claim a sandbox via `SandboxPool.claim/2` from a **separate, spawned
   process** (not the test process itself — matching this project's own
   `identity_test.exs`-style `Task.async`/spawn-based concurrency test precedent), kill
   that process (`Process.exit(pid, :kill)` or let it crash), then assert — via the same
   `refute schema_exists?(schema_name)`-style helper
   `promotion_assertion_rerun_test.exs`'s existing "try/rescue crash safety" describe
   block already uses (per ISSUE-FIXER's own citation of that block, line 824+) — that
   the schema no longer exists in `information_schema.schemata` shortly after, and that
   the freed slot is immediately claimable again (a subsequent `claim/2` against a
   pool at its quota ceiling, before the kill, succeeds after the kill).
2. A regression-style test confirming `release/2`'s normal success path still works
   identically post-fix (no new monitor-related error surfaces on the happy path) —
   likely already covered by `sandbox_pool_test.exs`'s existing suite, but worth an
   explicit assertion that a normal `release/2` does not leave a stray `:DOWN` message
   sitting in the `SandboxPool` process's mailbox (i.e., `[:flush]` is working) if
   TEST-DESIGNER judges that observable/valuable.
3. `apply_promotion_assertion_rerun_test.exs`'s own existing "try/rescue crash safety"
   describe block (raises, not a real kill, per ISSUE-FIXER's confirmation) needs **no
   change** — §7 already establishes this design's mechanism is layered underneath,
   not a replacement for, that existing coverage.

---

## 11. Open questions (explicit, not silently resolved)

**OQ-1 — should `find_active_by_owner_ref/2`'s linear scan be replaced with a
reverse-lookup map if `max_concurrent_sandboxes` is ever configured much larger than the
current default (5)?** Not built here — §3 explicitly chose the scan for parity with
`find_waiter/2`'s own existing idiom and because `max_concurrent` is an
operator-controlled quota expected to stay small (a large sandbox pool has real Postgres
connection/schema-count cost regardless of this design). Left for a future revision if
operational experience ever shows otherwise.

**OQ-2 — INV-SP-DOWN-4's residual gap (a `drop_schema/1` failure coinciding with an
owner kill).** §6 names this explicitly rather than claiming full closure. Whether this
residual sliver ever justifies building the periodic-reaper mechanism §2.2 rejected as
the *primary* fix — now potentially reconsidered as a much narrower, lower-frequency
*secondary* sweep — is left open, not decided here, since ISSUE-FIXER's diagnosis gives
no evidence this residual case has ever actually occurred (the one live orphan this
design's own motivating evidence is built from is explained by the primary gap this
design closes, not by a coincident DROP-SCHEMA failure).

---

## 12. Acceptance-criteria traceability

| Handoff acceptance criterion | Concrete design element |
|---|---|
| "Design artefact written under lib/letflow/design/ (design-only, no implementation code)" | This file: `lib/letflow/design/iss-0048-sandbox-pool-owner-crash-reclaim.md`; all code shown is pseudocode (`CASE`/`OF`/`END`) or `@spec`/type shapes, no `.ex` function bodies |
| "Covers exactly the SandboxPool crash/kill safety gap ISSUE-FIXER diagnosed — does not touch the 5 exonerated test files" | §1 scope table; §5 (all changes confined to `lib/letflow/sandbox_pool.ex`); no reference anywhere in this design to editing any of the 5 named test files |
| "States the interface (@spec-level) for any new/changed public function(s) on Letflow.SandboxPool" | §4 — explicitly states there are none, and why that is itself the correct, load-bearing answer (not an omission) |
| "Explains how the fix does not break apply_promotion_assertion_rerun/6's existing claim/2 -> release/2 contract" | §7, worked through for both the exit-signal case and the already-handled raised-exception case, plus the second-order in-flight-release-call case |
| "Justifies the chosen mechanism (owner-monitor vs. periodic reaper) against SandboxPool's actual current architecture, not assumed" | §2, citing `sandbox_pool.ex`'s own existing waiting-queue monitor precedent (2.1) and three concrete, architecture-specific reasons the reaper alternative was rejected (2.2), not a generic preference |

---

## 13. REWORK — resolving the Task.async claim/release-elsewhere ambiguity (2026-08-18, rework iteration 1)

### 13.0 Sources re-read for this revision

- `handoffs/WF03-ISS0048-20260818/step-02-code-designer-rework1.json` (`task.description`,
  full) — the rework instruction itself, both named directions (a)/(b), and the explicit
  requirement to re-verify against `apply_promotion_assertion_rerun/6`'s real call site
  again rather than re-assert the prior finding.
- `handoffs/WF03-ISS0048-20260818/step-03-elixir-dev.json` (`result.summary`/`issues`,
  full) — ELIXIR-DEV's diagnosis: `state.active` entries now `{schema_name, owner_ref}`
  (implemented as a two-key map, matching §3's design exactly); `owner_ref` established
  via `Process.monitor(elem(from, 0))` in `handle_provision_now/2` and
  `service_next_waiter/1`'s hand-off path; torn down via `Process.demonitor(owner_ref,
  [:flush])` on `release/2`'s success path — all exactly per §5. The one failure:
  `test/letflow/sandbox_pool_test.exs:192-221`'s "a queued waiter is served" test claims
  via `Task.async(fn -> SandboxPool.claim(2_000, pool) end)` (test line 205) and releases
  from the test process (test line 220) — a different pid from the one that actually
  called `claim/2`. The Task process replies and exits `:normal` immediately after
  `claim/2` returns, so `SandboxPool` observes that `:DOWN` and reclaims (per
  INV-SP-DOWN-2's own "any exit reason including `:normal`" clause) before the test
  process's own `release/2` call runs, which then correctly gets `{:error, :not_found}`.
  Reproduced 3/3 — not a race, an inherent consequence of `Task.async`'s semantics
  (the spawned process's job is to compute a value and exit; it is not meant to
  outlive its own return).
- `lib/letflow/sandbox_pool.ex` (current, post-`ef1e4c8`, re-read in full, quoted above in
  the tool output used to write this revision) — confirms the implementation matches §3-§5
  exactly; the gap is in the *design's* mechanism, not a deviation ELIXIR-DEV introduced.
- `lib/letflow/definitions.ex` — re-grepped for `Task.async`/`spawn` around
  `claim_sandbox_and_proceed/8` (line 1472), `run_replay_span/8` (line 1522), and their
  one call site (line 825, inside `apply_promotion_assertion_rerun/6`): **zero matches**.
  `claim_sandbox_and_proceed/8` calls `SandboxPool.claim/2` directly (not via
  `Task.async`/`spawn`) and `run_replay_span/8` calls `SandboxPool.release/2` directly
  (via `safe_release/2` in its `rescue` clause, definitions.ex:1817+) from the same
  process, in both the normal-completion and raised-exception paths. §7's original
  finding — `apply_promotion_assertion_rerun/6` is synchronous, single-process, from
  `claim/2` through `release/2` — is **reconfirmed unchanged** by this re-read, not
  merely re-asserted from the prior design pass.

### 13.1 Decision: (b) — same-process claim/release contract; test updated, no new primitive

**Chosen: (b).** `SandboxPool.claim/2`'s contract now explicitly requires that the SAME
process which called `claim/2` also calls the matching `release/2` for that
`sandbox_id` — a caller must not hand a live claim to a different process and expect
`SandboxPool` to treat that as anything other than an owner death. `(a)` (an explicit
ownership-transfer primitive) was considered and rejected, for reasons specific to this
module's actual call pattern, not a generic preference:

1. **The one real production caller already satisfies (b) natively, and has since the
   original design pass.** §13.0's re-verification confirms `apply_promotion_assertion_rerun/6`
   still calls `claim/2` and `release/2` from the same process, synchronously, with no
   `Task.async`/`spawn` anywhere in between. `(b)` costs this caller nothing — it already
   conforms. Choosing `(a)` would add a new public primitive that this module's only real
   caller would never use, built solely to accommodate a test's own concurrency-testing
   convenience rather than a genuine production need — the kind of speculative API surface
   `docs/anti-patterns.md`'s general "don't build for a caller that doesn't exist"
   discipline (and this design's own §4 "zero new public API surface" framing from the
   original pass) argues against.
2. **`(a)` does not actually make the Task.async pattern free — it just relocates the
   same-process requirement to a different call.** Any ownership-transfer primitive
   (e.g. a `SandboxPool.confirm_owner/2`-shaped function the *new* owning process would
   have to call after `Task.await/2`) still requires the test (or any future caller using
   this pattern) to know about and explicitly invoke a `SandboxPool`-specific API at
   exactly the right moment — it does not let the existing test's code stay as-is any more
   than `(b)` does. Given that neither direction leaves the existing test unmodified,
   `(b)` is the smaller, more legible change: a documented contract plus a same-process
   test fix, versus a documented contract *and* a new public function *and* a
   same-process-equivalent test fix (the new primitive still has to be called from the
   correct process at the correct time to avoid the identical race).
3. **A same-process claim/release contract is the same idiom OTP itself uses for its own
   `:global`/`:mutex`-shaped resources** (e.g. `:global.set_lock/3`'s note that the lock
   is tied to the calling process; ETS's `:ets.give_away/3` is the actual explicit-transfer
   primitive OTP provides *when* transfer is a real requirement — and it requires the
   sending and receiving processes to coordinate explicitly, which is exactly `(a)`'s cost
   without `(a)`'s benefit here). `SandboxPool.claim/2`'s own doc-comment already frames a
   claim as belonging to "the caller" (§4's original `@doc`: no plural, no hand-off
   language) — `(b)` formalizes an assumption the interface already implied, rather than
   introducing a new one.
4. **This does not quietly re-decide anything `Letflow.Definitions`' usage depends on.**
   Restated per the handoff's explicit instruction to confirm, not assume: `definitions.ex`
   has zero `Task.async`/`spawn` around any `claim/2`/`release/2` pair (§13.0). No
   production code path changes behavior under `(b)`. The only code that changes is the
   one test that was, itself, relying on an assumption (`claim` and `release` may happen
   from different processes) that no other part of this codebase — production or test —
   depends on. `grep -rn "Task.async" test/letflow/sandbox_pool_test.exs` confirms this
   is the *only* `Task.async` usage in this test file wrapping a `claim/2` call whose
   `release/2` happens elsewhere.

### 13.2 `claim/2`'s public `@spec` — explicitly does NOT change

Restated per the handoff's explicit acceptance criterion, not left ambiguous: **`claim/2`'s
and `release/2`'s public `@spec`s are unchanged by this revision** — byte-identical to
§4's original statement and to the currently-shipped `sandbox_pool.ex`. `(b)` is a
*contract* addition (a documented, enforced-by-mechanism precondition on which process
may call `release/2` for a given claim), not a *signature* addition — there is no new
parameter (e.g. no "expected owner pid" argument) and no new return-value variant. The
existing `owner_ref = Process.monitor(elem(from, 0))` mechanism (§5.1/§5.2, unchanged by
this revision) already **is** the enforcement: it was always implicitly a same-process
contract by construction (it monitors whichever pid happens to call `claim/2`) — this
revision's only change is naming that fact explicitly as the documented contract instead
of leaving it an unstated assumption discoverable only by an owner-monitor false-positive,
and updating the one test that violated it.

**One documentation-only change to `claim/2`'s `@doc` (not its `@spec`) is added:** a
sentence stating "the process that calls `claim/2` must be the same process that later
calls `release/2` for the returned `sandbox_id` — handing a claim to a different process
and releasing from there is indistinguishable, by design, from that process leaking the
claim (see moduledoc's owner-monitor section) and will be reclaimed automatically." This
is prose inside an existing `@doc` string, not a code change to any function body or
`@spec` — ELIXIR-DEV should add it as part of implementing this revision (a one-sentence
`@doc` edit, explicitly permitted since §8's "must not change" list only names `@spec`s
and `start_link/1`, not doc comments).

### 13.3 Moduledoc addition

`SandboxPool`'s moduledoc (sandbox_pool.ex:2-31) gains one short paragraph, placed after
the existing "Process-per-instance vs. row-based state" section, stating the same-process
contract from §13.2 plus the one-sentence reasoning from §13.1 point 3 (claim ownership is
tied to the claiming process, same idiom as `:global`'s lock semantics) — so a future
reader of the module encounters the contract before writing a new caller that violates it,
not only in a `@doc` string on one function.

### 13.4 Test file update — required, in scope for this fix

`test/letflow/sandbox_pool_test.exs:192-221`'s "a queued waiter is served once the held
slot frees, before its wait window elapses" test must be restructured so the process that
calls `SandboxPool.claim/2` (currently the `Task.async`-spawned process, test line 205) is
the same process that calls `SandboxPool.release/2` (currently the test process, test line
220). The test's actual intent — proving the *queueing/hand-off* mechanism
(`service_next_waiter/1`, `waiting` → `active` transition) works, which requires a second,
concurrently-blocked caller — is unaffected by this restructuring; only the release call's
process needs to move.

**Concrete restructuring shape (prose, not code, matching this document's own
no-implementation-code constraint):** the `Task.async` body should not return immediately
after `claim/2` succeeds. Instead it should rendezvous with the test process — e.g. send
its `{:ok, claim}` result to the test process via `send/2`, then block (`receive`) for a
"go ahead and release" message from the test process, then itself call `SandboxPool.release/2`
for that claim, then return whatever the test still needs asserted (e.g. the claim struct,
or `:ok`) as its own `Task.async` return value for `Task.await/2` to receive. The test
process's assertions (`waiter_id != held_id`, `schema_exists?(waiter_schema)`) still run
in the test process, using the claim data relayed via the rendezvous `send/2` — only the
literal `SandboxPool.release(waiter_id, pool)` call moves inside the `Task.async` body,
after the rendezvous, so it executes in the same process that called `claim/2`. This is a
standard Elixir test-synchronization idiom (send/receive rendezvous around an
otherwise-async `Task`), not a new mechanism.

This changes **`owned_modules`** for the implementation step that follows this design:
`test/letflow/sandbox_pool_test.exs` is now in scope alongside `lib/letflow/sandbox_pool.ex`
(and, per §13.2/§13.3, the moduledoc/`@doc` prose inside `sandbox_pool.ex` — no `.ex`
logic beyond what §§1-12 already specified). ELIXIR-DEV (or TEST-DESIGNER, per whichever
agent the next handoff assigns this to) must update this test as part of closing this
rework, not treat it as pre-existing, untouchable coverage — it is the one piece of
existing coverage this revision determines was asserting an unsupported contract.

### 13.5 Re-verification against `apply_promotion_assertion_rerun/6` (restated, not reused)

Per the handoff's explicit instruction not to merely re-assert the prior finding: §13.0
above re-read `definitions.ex` directly for this revision (fresh `grep` for
`Task.async`/`spawn` around both `claim_sandbox_and_proceed/8` and `run_replay_span/8`,
zero matches) and reconfirms §7's original conclusion still holds unchanged — `(b)`'s new
same-process contract does not break `apply_promotion_assertion_rerun/6` because that
function's call pattern already, natively, satisfies it. No change to
`lib/letflow/definitions.ex` is needed by this revision, consistent with §7/§8's original
"nothing in `definitions.ex`" scope, which this rework does not reopen.

### 13.6 Updated acceptance-criteria traceability (this rework's handoff)

| Rework acceptance criterion | Concrete design element |
|---|---|
| "Design revised to resolve the Task.async claim/release-across-processes ambiguity... with an explicit choice between (a)/(b) and stated reasoning" | §13.1 — `(b)` chosen, four concrete reasons against `(a)` |
| "If (b) is chosen: design explicitly states test file needs updating, and owned_modules is updated" | §13.4 |
| "Re-verified against apply_promotion_assertion_rerun/6's actual call site... that the chosen direction doesn't break it" | §13.0 (fresh re-read), §13.5 |
| "claim/2's public @spec may change only if strictly necessary... state explicitly whether it does or doesn't" | §13.2 — explicitly does NOT change; only `@doc` prose and moduledoc prose are added |
| "Design artefact updated in place... at lib/letflow/design/iss-0048-sandbox-pool-owner-crash-reclaim.md" | This §13, plus the REWORK NOTICE below the title |
