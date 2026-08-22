# Design: ISS-0226 — `Letflow.SandboxPool`'s worker result must be a closed, validated type

**Run:** `WF03-ISS0226-20260822` (queue task 226) · **Author:** CODE-DESIGNER · **Status:** proposed

## 0. Sources read in full before writing this

| Source | Why |
|---|---|
| `lib/letflow/sandbox_pool.ex` (909 lines, current `HEAD` of `fix/WF03-ISS0226-20260822`) | the module under change |
| `lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md` (1903 lines) | the architecture this bug lives in — async worker, `db_queue`/`in_flight`, INV-SP-A1..A5, clause B's ordered `:DOWN` dispatch |
| `docs/agents/instructions/core-directives.md` | mandatory — design-doc discipline, no implementation code |
| `docs/anti-patterns.md` | mandatory |
| `docs/guides/backend_developer_guide.md` | mandatory reading for this role |

No R-Co source or migration-stage doc is relevant here: this is a pure defensive-programming
fix inside a module ISS-0224 already fully designed, not new product behavior.

## 1. The defect, re-derived from source

`pump/1` (`sandbox_pool.ex:562-580`) spawns exactly one worker per DB operation:

```elixir
task = Task.Supervisor.async_nolink(@task_supervisor, fn -> run_op(op) end)
```

`run_op/1` (`:586-590`) dispatches to `provision_sandbox/2` (returns `{:ok, %SandboxClaim{}}` or
`{:error, :provision_failed}`) or `drop_schema/1` (returns `:ok` or `{:error, :release_failed}`).
**Nothing enforces that these are the only four values `run_op/1` can return.** Its own `@spec`
is absent; nothing marks the union closed.

`handle_info({ref, result}, state) when is_reference(ref)` (`:391-407`, "clause A") receives the
worker's message and, once it confirms `ref == state.in_flight.task_ref`, calls straight through
to `complete_op(state, state.in_flight.op, result)`. `complete_op/3` (`:597-665`) is defined as
**four clauses, each an exact pattern match on one `(op-kind, result)` pairing, with no catch-all
clause**:

```elixir
defp complete_op(state, {:provision, p}, {:ok, %SandboxClaim{} = claim}), do: ...
defp complete_op(state, {:provision, p}, {:error, :provision_failed}), do: ...
defp complete_op(state, {:drop, d}, :ok), do: ...
defp complete_op(state, {:drop, d}, {:error, :release_failed}), do: ...
```

If `run_op/1` — directly, or transitively via a future change to `provision_sandbox/2` /
`drop_schema/1` — ever returns any fifth shape (a stray `{:error, :timeout}`, a raw exception
struct from a `rescue` clause someone adds later, `nil`, anything), `complete_op/3` has no
matching clause. Elixir raises `FunctionClauseError` **inside `handle_info/2`**, which is a
GenServer callback: an uncaught exception inside a callback crashes the process. `SandboxPool`
is one supervised `GenServer` holding **every** slot's bookkeeping (`active`, `waiting`,
`db_queue`, `in_flight` — moduledoc §"Process-per-instance vs. row-based state" `:13-31`), so this
single crash discards every in-flight claim, every parked waiter, and the entire `db_queue` —
with no reclaim, no compensating drop, no reply to any blocked caller. A restart under its
supervisor comes back with **empty** state (design doc §11 OQ-3: "pool state does not survive a
`SandboxPool` process restart" is an accepted trade-off for the *normal* case; an unhandled
crash is not the normal case this trade-off was scoped to accept).

**This is a real, reachable gap, not a hypothetical one.** `provision_sandbox/2`'s own `rescue`
clause (`:887-893`) already demonstrates that this code path is not immune to producing an
unanticipated value under a future edit — it exists precisely because `Repo.query!/2` and
`Ecto.Migrator.run/4` can each raise in ways a maintainer might not enumerate correctly the next
time this function is touched.

## 2. Scope boundary

### 2.1 In scope
- A closed type for `run_op/1`'s return value.
- A total `handle_info/2` clause-A body: every legal value routed to today's `complete_op/3`
  path unchanged; every illegal value routed to an explicit, non-crashing recovery path.
- The recovery mechanism for an illegal value, and the reasoning for choosing it.
- A regression test that drives an illegal worker return and asserts the pool survives with
  sane bookkeeping.

### 2.2 Explicitly NOT in scope, and why (acceptance criterion 4)

**INV-SP-A1 (reservation/quota), INV-SP-A2 (exactly-one-reply), INV-SP-A3 (ref
classification), and the owner-monitor reclaim semantics (§6.5/§6.6 of the ISS-0224 design)
are untouched by this design.** Concretely:

- `state`'s shape (`active`, `waiting`, `db_queue`, `in_flight`) is not modified.
- `complete_op/3` is not modified — its four existing clauses are **not** given a catch-all,
  and are not reordered or rewritten. See §4.3 for why this is possible and correct.
- `handle_worker_death/1` (`:669-700`) is not modified — it is **reused**, not re-implemented,
  by the new recovery path (§5).
- Clause B's six-case `:DOWN` dispatch (`:420-505`) is untouched.
- No public `@spec` changes (`start_link/1`, `claim/2`, `release/2`,
  `provision_timeout_ms/0`, `claim_call_timeout/1`, `release_call_timeout/0`).

If implementing this design turned out to require touching any of the above, that would be a
blocking finding requiring REVIEWER sign-off before proceeding, per this run's constraints —
it does not, and §4.3 states exactly why.

## 3. The closed type

### 3.1 Choice: a closed union of tagged tuples/atoms, not a new struct

```elixir
@typep provision_result :: {:ok, SandboxClaim.t()} | {:error, :provision_failed}
@typep drop_result :: :ok | {:error, :release_failed}
@typep worker_result :: provision_result() | drop_result()
```

**Why a tagged-tuple union and not a wrapping struct (e.g. `%WorkerResult{op_kind:, payload:}`):**
the four legal values are *already* exactly what `provision_sandbox/2` and `drop_schema/1`
return today, byte-for-byte — `{:ok, %SandboxClaim{}}`, `{:error, :provision_failed}`, `:ok`,
`{:error, :release_failed}`. A struct wrapper would require rewriting `provision_sandbox/2`,
`drop_schema/1`, **and** all four of `complete_op/3`'s existing clauses just to unwrap it — that
is exactly the kind of touch to already-correct, already-invariant-bearing code this fix's scope
boundary (§2.2) rules out for no behavioral gain. The tagged-tuple union is *already* closed in
the sense that matters (a fixed, enumerable set of shapes) — it only lacked an enforcement point
before this fix, not a better shape. `@typep` (not `@type`) because these are internal to the
module, matching the module's existing `provision_op`/`drop_op`/`op` convention (`:158-182`).

### 3.2 Where enforcement lives: a boundary function, not a change to `complete_op/3`

The type is enforced by a new function that runs **before** `complete_op/3` is ever called,
classifying `result` against the specific `op` kind it belongs to (a `{:provision, _}` op's
result must be a `provision_result()`; a `{:drop, _}` op's result must be a `drop_result()` —
these are two different, non-overlapping constraints, and validating them together with the op
they belong to is what makes it possible for `complete_op/3` to stay exactly as it is):

```elixir
@spec classify_worker_result(op :: op(), result :: term()) ::
        {:ok, worker_result()} | :invalid
```

Five clauses, in order: the four legal `(op-kind, result)` pairings return `{:ok, result}`
unchanged; a final catch-all clause matching any `(op, result)` not covered by the first four
returns `:invalid`. This is what makes the function **total** — every possible `term()` for
`result`, paired with every possible `op()`, resolves to exactly one of the five clauses, with
no way to fall through uncaught.

## 4. `handle_info/2` — the total rewrite of clause A

### 4.1 Current shape (`:391-407`, for reference — not to be preserved verbatim)

```elixir
def handle_info({ref, result}, state) when is_reference(ref) do
  if state.in_flight == nil or ref != state.in_flight.task_ref do
    {:noreply, state}
  else
    Process.demonitor(ref, [:flush])

    new_state =
      state
      |> complete_op(state.in_flight.op, result)
      |> service_next_waiter()
      |> pump()

    {:noreply, new_state}
  end
end
```

### 4.2 New shape

```elixir
def handle_info({ref, result}, state) when is_reference(ref) do
  if state.in_flight == nil or ref != state.in_flight.task_ref do
    {:noreply, state}
  else
    # Demonitor BEFORE branching on validity -- unconditionally, exactly as today. A
    # pending :DOWN(:normal) for this same ref will otherwise arrive right after this
    # callback returns and be misread by clause B case 1 as a SECOND worker death for
    # an in_flight that this callback is about to clear -- see INV-SP-A3(ii)'s existing
    # "flush, so a normally-returning worker never ALSO delivers a :DOWN" reasoning,
    # which applies identically whether the returned value was legal or not.
    Process.demonitor(ref, [:flush])

    case classify_worker_result(state.in_flight.op, result) do
      {:ok, validated_result} ->
        # UNCHANGED from today: legal shapes reach complete_op/3 exactly as before.
        new_state =
          state
          |> complete_op(state.in_flight.op, validated_result)
          |> service_next_waiter()
          |> pump()

        {:noreply, new_state}

      :invalid ->
        # NEW: the worker returned a value complete_op/3 was never written to accept.
        # See §5 for why handle_worker_death/1 is the correct, already-proven recovery
        # for exactly this uncertainty, rather than a new bespoke branch.
        Logger.error(
          "Letflow.SandboxPool worker returned an unrecognized result for " <>
            "#{inspect(op_kind(state.in_flight.op))} op " <>
            "(sandbox_id=#{inspect(op_sandbox_id(state.in_flight.op))}): #{inspect(result)}"
        )

        new_state =
          state
          |> handle_worker_death()
          |> service_next_waiter()
          |> pump()

        {:noreply, new_state}
    end
  end
end
```

**Totality argument.** Clause A's own head (`{ref, result}` guarded `is_reference(ref)`) already
accepts *any* term as `result` — that part was never the gap. The `if/else` branches on whether
this message belongs to the current `in_flight` op — also already total (two branches, nothing
falls through). Inside the `else` branch, `classify_worker_result/2` is total by construction
(§3.2), and its two possible tags (`{:ok, _}` / `:invalid`) are both handled by the `case`, with
no third case possible. So the full clause-A body has no path that reaches an unmatched clause
anywhere — this is what "total over the type" means for acceptance criterion 4, expressed
mechanically rather than asserted.

### 4.3 Why `complete_op/3` needs no catch-all of its own

`classify_worker_result/2`'s four legal-pairing clauses are, term-for-term, the same four
`(op-kind, result)` pairings `complete_op/3`'s four existing clauses already match on. Once
`classify_worker_result/2` has returned `{:ok, validated_result}`, `validated_result` is
guaranteed (by construction, not by hope) to be one of exactly those four shapes, paired with
the exact op-kind `complete_op/3` is about to be called with. `complete_op/3`'s existing four
clauses therefore already cover 100% of what can reach them post-validation — adding a catch-all
there would be dead code, and rewriting its four clauses would be exactly the kind of touch to
correct, invariant-bearing code §2.2 rules out. This is *why* the scope-boundary constraint is
satisfiable at all: the fix is additive (one new function, one new branch in clause A), not a
rewrite of the completion logic.

## 5. Recovery mechanism for an invalid result, and why

**Decision: route an invalid result to `handle_worker_death/1` (`:669-700`), the same function
clause B case 1 already calls when the worker crashes without returning anything.**

**Reasoning, not just mechanism.** From the pool's own point of view, "the worker sent back a
value I don't recognize" and "the worker died before sending back anything" are the *same kind
of uncertainty*: in both cases, the pool cannot trust that it knows what happened to the DB side
effect (did the schema get created? did the drop actually run?) — the one thing it does know,
in both cases, is that no *legal* completion happened. `handle_worker_death/1` already encodes
exactly the conservative recovery that uncertainty calls for, per op kind:

- **`{:provision, p}` in flight:** the schema *may* have been created (the pre-minted
  `schema_name` is the only handle on it either way — design doc §5 "pre-minted by the pool"),
  so it enqueues a compensating `{:drop, purpose: :orphan}` for that exact schema name, and
  replies `{:error, :provision_failed}` to the caller (unless the owner already died, in which
  case no reply is sent — same `owner_down?` branch as today).
- **`{:drop, d}` in flight:** if `d.purpose == :release`, the caller is waiting on a definite
  answer and is told `{:error, :release_failed}` — the honest answer, since the DROP's real
  outcome is now unknown to the pool; the other three purposes have no `from` to reply to.
- **Both cases:** `in_flight` is unconditionally cleared, exactly what "recover slot bookkeeping"
  requires — the next `pump/1` call (already chained after `handle_worker_death/1` in clause A's
  new `:invalid` branch, same as clause B case 1) starts the next queued op.

Reusing this function rather than writing a new, parallel recovery path also means the invalid
case gets covariance with clause B's ordering guarantees for free: `handle_worker_death/1` makes
no assumption about *why* it was called (a crash vs. a garbage return), only about which op kind
is `in_flight` — so its correctness proof (design doc §7 step 3, §8.4's INV-SP-A4) already covers
this new call site without modification.

**Nothing here treats an invalid result as fatal, and nothing here silently drops it** — it is
logged (`Logger.error/1`, with the op kind, the sandbox id, and the raw unexpected value) before
recovery runs, so an operator can find the root cause (which of `provision_sandbox/2` or
`drop_schema/1` started returning something new) without needing the crash dump a
`FunctionClauseError` would have produced.

## 6. Signatures (design-only — no implementation bodies)

```elixir
# New module attribute, alongside the existing @task_supervisor etc.
require Logger

# New closed types.
@typep provision_result :: {:ok, SandboxClaim.t()} | {:error, :provision_failed}
@typep drop_result :: :ok | {:error, :release_failed}
@typep worker_result :: provision_result() | drop_result()

# Existing function, spec ADDED (was unspecced): declares the closed contract run_op/1
# must honor. No behavioral change to its body.
@spec run_op(op :: op()) :: worker_result()
defp run_op(op)

# NEW. Total over (op(), term()) -- see §3.2/§4.3 for why five clauses suffice.
@spec classify_worker_result(op :: op(), result :: term()) ::
        {:ok, worker_result()} | :invalid
defp classify_worker_result(op, result)

# NEW. Small accessors for the Logger.error/1 call in §4.2 -- mirrors the existing
# op_schema_name/1 accessor (:592-593) rather than inventing a new idiom.
@spec op_kind(op :: op()) :: :provision | :drop
defp op_kind(op)

@spec op_sandbox_id(op :: op()) :: String.t()
defp op_sandbox_id(op)

# CHANGED (body, not signature): handle_info({ref, result}, state) when is_reference(ref) --
# see §4.2 for the full new body. Public contract (message shape matched, {:noreply, state}
# return) is unchanged.
```

`handle_worker_death/1`, `complete_op/3`, `pump/1`, `enqueue_op/2`, and every other existing
private function keep their current `@spec`s and bodies verbatim.

## 7. Test design

**File:** `test/letflow/sandbox_pool_test.exs` (existing file — a new `describe` block, not a
new file; this bug lives entirely inside behavior that file already exercises).

### 7.1 Primary case — invalid result during a `{:provision, _}` op

**Goal:** prove the pool survives an unrecognized worker return and that its slot bookkeeping
is fully recovered afterward — not merely that the process is still alive.

**Mechanism — direct state injection via `:sys.replace_state/2`, no production code changed
for testability.** This project's own `promotion_assertion_rerun_test.exs` already reads pool
state via `:sys.get_state/1` (ISS-0224 design doc §9); `:sys.replace_state/2` is the same
technique's natural write-side sibling, and using it here avoids adding any test-only hook,
mock-injection option, or new public surface to `Letflow.SandboxPool` — which §4.4 (I) and item
15 of the ISS-0224 design's "do not" list already establish this project rejects for this exact
module. It also makes the test **deterministic**: a fabricated `task_ref` that no real `Task`
will ever message means there is no race between the injected message and a real worker's own
reply.

Test-case steps (signature/behavior only — TEST-DESIGNER writes the actual ExUnit code):

1. Start a pool with `max_concurrent: 1` under a unique registered name (existing
   `start_pool/1`-style helper already used elsewhere in this file).
2. Read `state = :sys.get_state(pool)` to obtain the real, empty initial state.
3. Construct a well-formed `{:provision, provision_op()}` op by hand: a real `from` (a
   `GenServer.from()`-shaped tuple built from `self()`), a real `owner_ref` from
   `Process.monitor(self())`, and a `sandbox_id`/`schema_name` pair from the same
   `mint_sandbox_identity/0`-style construction the module already uses (or a literal
   `"sandbox_" <> Ecto.UUID.generate()`-shaped string — no DB access needed for this step).
4. Build an `in_flight` map around it with a **fabricated** `task_ref = make_ref()` (never
   attached to any real `Task`) and `task_pid = self()`.
5. `:sys.replace_state(pool, fn s -> %{s | in_flight: injected_in_flight} end)`.
6. `send(pool, {task_ref, :not_a_recognized_shape})` — the garbage message, sent directly, as
   if a worker had returned this value.
7. **Assert the pool is still alive:** `assert Process.alive?(pool)`.
8. **Assert bookkeeping recovered:** `assert :sys.get_state(pool).in_flight == nil` — the
   invalid-result path cleared `in_flight` exactly as a real worker death would.
9. **Assert a subsequent `claim/2` still works end-to-end** (real DB, real schema, no further
   mocking): `assert {:ok, %SandboxClaim{}} = SandboxPool.claim(1_000, pool)`, and
   `SandboxPool.release/2` on the returned `sandbox_id` returns `:ok` — proving `active` and
   `db_queue`/`pump/1` are in a state that admits new work correctly, not merely "not crashed."
10. Assert no unexpected message remains in the pool's mailbox that would double-process this
    event (e.g. via `Process.info(pool, :message_queue_len) == {:message_queue_len, 0}` after
    a short `:sys.get_state/1` round-trip, which serializes on the pool's own mailbox).

### 7.2 Companion case — invalid result during a `{:drop, purpose: :release}` op

Same mechanism, with the injected `in_flight` built around a `{:drop, %{purpose: :release, ...}}`
op instead, and a real blocked caller reference so the test can additionally assert that caller
receives `{:error, :release_failed}` (mirroring `handle_worker_death/1`'s existing `:release`
branch, `:690-697`) rather than being left to time out — this is the same reply-on-uncertainty
behavior §5 argues for, exercised on the other op kind so both of `handle_worker_death/1`'s
branches are covered by this issue's regression tests, not just one.

### 7.3 What this does NOT need to test again

`classify_worker_result/2`'s four legal-pairing clauses are exercised for free by every existing
passing test in this file (every successful `claim/2`/`release/2` already round-trips a legal
`worker_result()` through clause A) — no new positive-path test is needed; only the negative
(fifth) path is new coverage.

## 8. Invariant-preservation checklist (acceptance criterion 4)

- **INV-SP-A1 (reservation/quota):** untouched. `slots_in_use/1`, `provision_ops_pending/1`,
  `reserve_slot/2` are not modified; the invalid-result path clears `in_flight` via the same
  `handle_worker_death/1` call clause B case 1 already uses, so quota accounting follows the
  identical, already-proven path.
- **INV-SP-A2 (exactly-one-reply):** untouched. The invalid-result path reaches the same two
  conditional-reply sites inside `handle_worker_death/1` that clause B case 1 already reaches;
  no new reply site is introduced.
- **INV-SP-A3 (ref classification):** untouched. `task_ref` is still written to exactly one
  place and demonitored at exactly the same point (§4.2's ordering note); classifying the
  *result*, not the *ref*, is an orthogonal concern this fix adds.
- **Owner-monitor reclaim semantics:** untouched. Nothing about `owner_ref`, clause B's six
  `:DOWN` cases, or `orphan_release_drop/3` is touched by this design.

## 9. Open questions

- **OQ-1.** Should the `Logger.error/1` call in §4.2 also emit a `:telemetry` event, matching
  whatever observability convention (if any) other unexpected-shape paths in this codebase use?
  Not resolved here — no existing telemetry convention was found for this module, and adding one
  is a product/observability decision, not a defect-fix decision. Left for REVIEWER to flag if
  a convention exists elsewhere that should be matched.
- **OQ-2.** `provision_sandbox/2`'s own `rescue` clause (`:887-893`) is the most likely future
  source of a fifth shape (e.g. if a future edit adds a second `rescue` branch with a different
  error atom). This design does not change `provision_sandbox/2` itself — only the boundary that
  now catches whatever it might someday return that isn't already accounted for. Not a defect to
  fix now; named so a future editor of `provision_sandbox/2` knows the boundary exists and why.
