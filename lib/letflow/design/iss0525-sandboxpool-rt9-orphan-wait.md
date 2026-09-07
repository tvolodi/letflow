# ISS-0525: SandboxPoolTest RT-9 orphaned provisioning-task fix

## 1. Problem recap (from ISSUE-FIXER's diagnosis, `handoffs/WF03-ISS0525-20260907/step-01-issue-fixer-diagnosis.json`)

RT-9 (`test/letflow/sandbox_pool_test.exs:1286-1320`, describe block "ISS-0227
regression") deliberately drives a real `SandboxPool.claim/2` into the in-flight
provisioning state (a real `Task.Supervisor.async_nolink/3` worker running
`Ecto.Migrator.run/4` inside `Letflow.SandboxPool`, dispatched from `pump/1` at
`lib/letflow/sandbox_pool.ex:606`) and stops observing as soon as
`provision_in_flight?/1` becomes true. It never waits for that task to finish and
never releases the resulting claim.

`ExUnit` runs a test's `on_exit/1` callbacks in LIFO order. RT-9 registers, in this
order: (1) its own `drop_sandbox_schemas_created_since!/1` cleanup, (2)
`start_pool!/1`'s `GenServer.stop(pid)` (registered when the pool is started), (3)
`spawn_claimer/3`'s `Process.exit(pid, :kill)` guard on the claimer process. LIFO
execution therefore runs (3), then (2), then (1). `SandboxPool` has no
`terminate/2` callback and the worker was started `async_nolink`, so stopping the
pool at step (2) does nothing to the still-running migration `Task` — it is now a
fully orphaned process still executing DDL/DML inside the sandbox schema. Step (1)'s
`DROP SCHEMA ... CASCADE` then races that live orphan, can hit a Postgres lock the
orphan holds, gets `query_canceled` even after `retry_query_once/1`'s single retry,
and leaves the schema behind mid-write — where the next test (RT-2, unrelated and
correct on its own terms) can straddle it in a baseline/final schema-set diff.

The fix ISSUE-FIXER recommends, and this design implements: make RT-9 genuinely wait
for the provisioning it starts to finish, so by the time either `on_exit` callback
runs, no worker Task exists for them to race against. No production code in
`lib/letflow/sandbox_pool.ex` needs to change — the task pid is already present in
test-observable state (see §2). No further arithmetic is to be added to
`resilient_drop_schema/1` / `retry_query_once/1` (`lib/letflow/sandbox_pool_test.exs`
lines ~546-637) — ISS-0292's history already carries three prior
CODE-DESIGN-VALIDATOR FAILs for that shape of fix; this design does not reopen it.

## 2. Confirmed facts about existing state shape (no production change needed)

- `lib/letflow/sandbox_pool.ex:602-619` (`pump/1`): when a `{:provision, _}` op is
  dequeued, the pool calls `Task.Supervisor.async_nolink/3` and stores the result as
  `state.in_flight = %{op: op, task_ref: task.ref, task_pid: task.pid}`. `task_pid` is
  the real OS-level pid of the spawned worker process — the one running
  `Ecto.Migrator.run/4` inside `provision_sandbox/2`.
- RT-9 already reads this exact map. Its assertion at line 1312 (`assert
  Enum.sort(Map.keys(state.in_flight)) == [:op, :task_pid, :task_ref]`) is itself proof
  that `task_pid` is present and stable in the `state.in_flight` shape RT-9 already
  captures via `wait_until_pool_state(pool, "O's provisioning is in flight",
  &provision_in_flight?/1)` (line 1294-1295). ISSUE-FIXER's belief that the pid is
  "already visible in the asserted key-set" is confirmed exactly: the RT-9-local
  binding is `state`, and `state.in_flight.task_pid` is the pid.
- `complete_op/3`'s `{:provision, p}` / `{:ok, %SandboxClaim{}}` clause
  (`lib/letflow/sandbox_pool.ex:672-699`) does **not** drop or release anything on a
  successful provisioning — it either enqueues a compensating drop (only if the owner
  already died, which is not RT-9's case: `o`, the claimer process spawned by
  `spawn_claimer/3`, stays alive throughout RT-9's body) or converts the reservation
  into a `state.active` entry and replies `{:ok, claim}` to the caller. So a
  successfully completed provisioning leaves a **live, unreleased** sandbox schema and
  an **active** pool entry — provisioning's own completion path does not perform any
  release. This is the fact that answers §4's claim-release question.
- `Task.Supervisor.async_nolink/3`'s `task.ref` is a monitor reference already held by
  the **pool** process (established when the pool itself called `async_nolink`), not
  by the test process. The test process has no monitor on `task_pid` today. To observe
  the worker's own termination independently of the pool's internal bookkeeping, the
  test must establish its own monitor via `Process.monitor/1` on the `task_pid` value
  it already reads out of `state.in_flight`.

## 3. RT-9 test-body design

Scope: only the body of the test named `"RT-9 (ISS-0227): the in-flight provision op
and the in_flight record carry no duplicate of a derivable value"`
(`test/letflow/sandbox_pool_test.exs:1286-1320`). No changes to RT-2, to
`resilient_drop_schema/1`/`retry_query_once/1`/`drop_sandbox_schemas_created_since!/1`,
or to any file under `lib/letflow/`.

### 3.1 Ordering constraint (must hold)

The existing ISS-0227 key-set assertions (today's lines 1300-1319) read
`state.in_flight`, which only exists **while** the provisioning is still running
(`provision_in_flight?/1` requires `in_flight.op` to match `{:provision, _}` —
`complete_op/3` clears `in_flight` to `nil` on completion). Any wait for the task's
completion must therefore run strictly **after** all of today's existing assertions,
never interleaved with or before them — waiting first would make `state.in_flight`
stale-but-still-inspectable (a captured map, not a live view) so the existing
assertions would not actually break, but it would defeat the reason RT-9 captures
`state` at the in-flight instant at all, and would stop being a faithful
reproduction of the exact hazard being fixed (the orphan must still be observed
in flight before the test moves on to draining it). The new step is strictly
additive, appended after the current final assertion (`assert is_binary(n)`, current
line 1319), never a replacement for anything already there.

### 3.2 New step: monitor and await the real worker's termination

Immediately after the existing block of assertions:

1. Bind the worker pid already available on the captured `state`:
   `state.in_flight.task_pid`. This is the same map RT-9 already destructured for its
   key-set assertions — no new pool call, no new helper needed to obtain it.
2. Establish a fresh monitor from the **test process** on that pid via
   `Process.monitor/1`, capturing the returned reference. This is intentionally a
   second, independent monitor from the pool's own pre-existing one — the test must
   not depend on or inspect the pool's internal `task_ref`/monitor bookkeeping, only
   observe the worker process's real OS-level termination for itself.
3. Await exactly one `:DOWN` message tagged with that fresh reference, for the
   worker pid captured in step 1, via `assert_receive/2` (this file's established
   idiom for message-based rendezvous — see `await_claiming!/1`, lines 684-694, and
   RT-2's own `assert_receive {:claimed, ...}` calls). Accept **either** exit reason
   on that `:DOWN` — `:normal` (the common, successful-migration path) or any other
   reason (a crashed migration). Justification: RT-9's purpose (the ISS-0227 key-set
   regression) is about the **shape** of in-flight state while a provisioning is
   running, not about provisioning outcome; a migration failure is already exercised
   and asserted precisely by other cases in this file (e.g. the `{:error,
   :provision_failed}` path covered elsewhere). Constraining this `:DOWN` wait to only
   accept `:normal` would make RT-9 spuriously fail on an unrelated, already-covered
   failure mode and would not serve RT-9's own regression target. What must be
   guaranteed, in every case, is only that the worker process is no longer alive by
   the time the wait returns — this is exactly what a monitor's `:DOWN` message
   proves, regardless of reason, since a process cannot generate a `:DOWN` from a
   monitor before it has fully exited.
4. Timeout for this `assert_receive/2`: reuse `pool_op_rendezvous_timeout/0` (this
   file's existing helper, line 92-94), which evaluates to
   `SandboxPool.release_call_timeout() + @rendezvous_slack_ms`, and
   `release_call_timeout/0` is defined as exactly `provision_timeout_ms/0`
   (`lib/letflow/sandbox_pool.ex:265-266`) — i.e. this timeout already is "the
   pool's own provisioning budget plus this file's one-hop rendezvous slack," which
   is precisely the correct bound for "wait for one provisioning-cost worker to
   finish." No new constant is introduced, consistent with this file's established
   convention (design doc references throughout: "derived... rather than
   hand-picked").

### 3.3 Claim-release decision: do NOT add an explicit release call as part of the required fix; document why, and separately recommend it as an optional strengthening

Per §2, a successful provisioning's own completion path does not release or drop
anything — `o`'s claim becomes a normal `active` entry with a live owner monitor.
Two options were considered:

- **Option A (minimal, required fix only):** add only the monitor/await step from
  §3.2 and change nothing else. Once the worker's `:DOWN` is observed, no process is
  still writing to the schema, so `start_pool!/1`'s later `GenServer.stop(pid)` and
  RT-9's own `drop_sandbox_schemas_created_since!/1` fallback (registered via
  `on_exit/1` at the top of RT-9, line 1288) can run in whatever order LIFO gives them
  without racing anything — the fallback's `DROP SCHEMA ... CASCADE` now targets an
  idle schema. This is sufficient to close the exact race ISSUE-FIXER diagnosed:
  the orphan no longer exists by the time either `on_exit` runs.
- **Option B (Option A plus an explicit release):** additionally have the test send
  `o` a `:release` instruction (the same `claimer_loop/4` protocol RT-1/RT-2/RT-3 and
  others already use) and await the `{:released, :o, :ok}` confirmation, then assert
  the schema set is back to `baseline`, before the test function returns.

**Decision: implement Option A as the required fix. Option B is not required, and is
listed only as an optional follow-up left to ELIXIR-DEV/TEST-DESIGNER's discretion,
not mandated by this design.** Justification:

- Option A alone provably eliminates the reported defect: the orphan-vs-cleanup race
  is a race against a *live process*, not against a *live Postgres row/entry*. Once
  the worker is confirmed dead, `drop_sandbox_schemas_created_since!/1`'s CASCADE drop
  has nothing left to contend with, regardless of whether the pool's own `active` map
  still lists the schema as claimed at the moment `GenServer.stop/1` tears the pool
  down. `GenServer.stop/1` does not talk to Postgres at all; only the (now-dead)
  worker Task and the schema-dropping helpers touch Postgres, so an unresolved
  `active` entry in a process that is about to be discarded carries no Postgres-level
  risk.
- Option B introduces scope beyond what ISS-0525 asks this design to fix (the task
  explicitly says "keep scope tight: only RT-9's test body and any minimal shared
  test-helper additions needed to monitor+await the task pid"), and adds assertion
  surface (an extra `assert_receive`, an extra baseline-diff assertion) that is not
  needed to prove the race is closed — RT-9's job (per its own comment block, lines
  1277-1285) is the ISS-0227 key-set regression, not a full claim/release lifecycle
  proof; every other test in this file (RT-1 through RT-8) already carries that
  lifecycle proof for the scenarios where it matters.
- Recording Option B here (rather than silently doing or silently omitting it) is
  deliberate, per this agent's instruction not to silently resolve an open question by
  guessing: if a later reviewer prefers symmetry with RT-1..RT-8's full
  claim-then-release shape, Option B is a strict superset of Option A and can be added
  without touching the §3.2 fix.

### 3.4 Does this defeat RT-9's purpose?

No. RT-9's documented purpose (lines 1277-1285) is the ISS-0227 dead-field-removal
regression: proving the exact key set of `state.in_flight` and `state.in_flight.op`
while a provisioning is in flight, and that the two fields ISS-0227 removed stay
removed while their replacements (`elem(p.from, 0)`, the op's own `schema_name`) still
resolve. Nothing in §3.2 touches, reorders, or weakens any of the existing key-set
assertions (current lines 1300-1319) — the new step is appended strictly after all of
them, per §3.1's ordering constraint, so the exact in-flight snapshot RT-9 depends on
is captured and asserted on exactly as before. (Note: the task prompt that produced
this design describes RT-9's purpose partly in terms of "the pool's mailbox isn't
blocked during provisioning" — that is in fact RT-2's regression target for ISS-0224,
not RT-9's; RT-9's own comment block is unambiguous that its target is ISS-0227's
key-set defect. This design treats RT-9's own stated purpose, lines 1277-1285, as
authoritative, and confirms the fix does not disturb it. The mailbox-not-blocked
property RT-2 guards is untouched — RT-2 needs no changes and none are made.)

## 4. New test coverage needed: none beyond the RT-9 body change itself

This is a test-only fix to an existing test's own body, not a production-code change,
and the defect is a **race against a live orphaned process**, not a deterministic
logic error reachable by a fixed input. A traditional fail-then-pass regression test
(a *new*, separate test proven red pre-fix and green post-fix, in the style of RT-2's
own fail-first design, §10.1-§10.3 referenced in that test's comments) is not a good
fit here for two reasons:

- The defect's own manifestation is already exactly RT-9 as it stands today — RT-9's
  current body **is** the reproduction vector (confirmed by ISSUE-FIXER against live
  CI evidence, one failure in two observed runs). Modifying RT-9 to close the race is
  therefore modifying the reproduction itself, not adding a parallel case; there is no
  separate "old broken behavior" to keep alive for a second test to exercise, since
  keeping it alive would just reintroduce the flake into the suite on some fraction of
  runs.
- Deterministically forcing the race window open (e.g. artificially delaying
  `provision_sandbox/2`'s migration step so the orphaned Task is still guaranteed to
  be running at `on_exit` time) would require adding test-only instrumentation or
  timing hooks to `lib/letflow/sandbox_pool.ex` production code, which is explicitly
  out of scope for this design (no production code changes) and is a heavier
  intervention than the fix itself for a race the design in §3.2 already closes by
  construction (a monitored `:DOWN` cannot fire before the worker has actually
  exited — there is no timing window left to hit, not merely a narrowed one).

**What this design specifies instead, as the closure proof:**

1. Structural proof (this document, §3.2-§3.3): the fix removes the orphan by
   construction — the worker Task cannot outlive the `:DOWN` wait, and both `on_exit`
   callbacks that used to race it run strictly after that wait returns. This is a
   proof about the code's shape, not a probabilistic test outcome, and is the
   appropriate form of evidence for a race whose old form cannot be deterministically
   re-triggered without production instrumentation this design declines to add.
2. Empirical proof, to be gathered by TEST-RUNNER once ELIXIR-DEV (or whichever role
   implements this design) lands the RT-9 body change: run
   `test/letflow/sandbox_pool_test.exs` in isolation repeatedly (a simple shell loop
   around `mix test test/letflow/sandbox_pool_test.exs`, on the order of 20-50
   iterations) to gain empirical confidence beyond the n=2 CI sample ISSUE-FIXER's
   diagnosis already flagged as small. A single green run is expected and necessary
   but, per this project's own stated sample-size caveat in the diagnosis, not
   sufficient on its own to certify a race fix — repeated runs are the right
   substitute here for a fail-then-pass pair that cannot be constructed
   deterministically.
3. No change to RT-2 is needed or made; RT-2's own body (`test/letflow/
   sandbox_pool_test.exs:849-961`) already asserts a clean `baseline` schema set at
   its own end (line 959) and needs nothing further to prove it is no longer affected
   by a leaked schema from RT-9, once RT-9 no longer leaks one.

## 5. Summary of the concrete diff shape (prose only, no implementation code)

Within RT-9's test body, after the final currently-existing assertion (`assert
is_binary(n)`) and before the test function's closing `end`:

- Read the worker pid already present as `state.in_flight.task_pid`.
- Call `Process.monitor/1` on that pid to obtain a fresh reference scoped to the test
  process.
- Use `assert_receive/2` to await a `:DOWN` message for that reference and that pid,
  with any exit reason, bounded by `pool_op_rendezvous_timeout/0`.
- Add a short comment explaining the ISS-0525 rationale (mirroring this file's
  existing convention of citing the issue and design doc inline), pointing at this
  design document.

No other line in the file changes.

## 6. Open questions

None outstanding for the required fix (§3.2/Option A). Option B (§3.3) is recorded as
an explicit, non-mandated follow-up rather than silently decided either way, per this
agent's standing instruction not to resolve an open design choice by silent guessing.
