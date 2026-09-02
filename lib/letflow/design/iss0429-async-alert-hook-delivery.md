# ISS-0429: async alert-hook delivery off `Scheduler.Poller`

Design for the fix ISSUE-FIXER's diagnosis (`handoffs/WF03-ISS0429-20260902/step-01-issue-fixer-diagnosis.json`)
sized as fixable now with existing supervision primitives. Root cause: `Letflow.Obs.Alerts.deliver_with_retry/4`
calls `Process.sleep/1` on every non-terminal delivery failure, and it runs synchronously on
`Letflow.Scheduler.Poller`'s own `handle_info(:tick, _)` — a slow/unreachable alert-hook endpoint therefore
blocks the platform-wide timer engine for the sum of that hook's retry backoffs, per hook, per tenant, per tick.

## 0. Non-goals (explicit, matching ISSUE-FIXER's scope)

- Does **not** change `backoff_delay/2`, `RetryPolicy` defaults, or any retry/backoff timing value.
- Does **not** change `check_and_record_emission/4`'s semantics, its call order relative to delivery, or the
  emission-dedupe row's write (`on_conflict: :replace_all`, `conflict_target: [:hook_id, :trigger_key]`).
- Does **not** touch `lib/letflow/webhooks.ex`'s `deliver/3` (confirmed currently latent — no production caller
  outside `webhooks.ex` itself). Out of scope per ISSUE-FIXER's diagnosis and ISS-0429's own text.
- Does **not** presuppose or block any ISS-0425 outcome (supervision-tree layering, `:rest_for_one`, restart
  intensity, or Task.Supervisor consolidation). This change is additive to `Letflow.Application`'s existing flat
  child list, following the same pattern as the six existing domain-scoped `Task.Supervisor`s.
- Does **not** introduce a DLQ, a return-value/result-tracking mechanism, or an `async_nolink` +
  `handle_info({ref, result}, ...)` correlation pattern (see §3 for why `SandboxPool`'s heavier shape is not
  needed here).

## 1. New supervision child: `Letflow.Obs.Alerts.TaskSupervisor`

**Naming:** `Letflow.Obs.Alerts.TaskSupervisor`, following the existing convention of naming each dedicated
`Task.Supervisor` after the module whose background work it isolates
(`Letflow.SandboxPool.TaskSupervisor`, `Letflow.Engine.PluginTaskSupervisor`, `Letflow.Engine.Lua.TaskSupervisor`,
`Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor`, `Letflow.Engine.Wasm.CapabilityGateTaskSupervisor`,
`Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor`). `Letflow.Obs.Alerts` is the module whose delivery
work is being isolated, so `Letflow.Obs.Alerts.TaskSupervisor` is the direct analog, not a generic
`Letflow.AlertsTaskSupervisor` or a reuse of an existing one — mirroring `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor`'s
own stated reasoning ("module registration ... is an independent concern from Lua/Plugin") applied to alert
delivery being an independent concern from every existing Task.Supervisor's domain (sandbox provisioning, plugin
execution, Lua wall-clock kill, Wasm instantiation).

**Placement in `lib/letflow/application.ex`'s `children` list:** append as a new entry in the main flat list
(alongside the six existing `Task.Supervisor` children), positioned **after** `Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor`
and **before** the `++ scheduler_children() ++ http_child()` tail. Rationale for "before scheduler_children(),
not after": `scheduler_children()` conditionally starts `Letflow.Scheduler.Poller`, and the Poller's `handle_info(:tick, _)`
is what will dispatch to this new supervisor starting on its very first tick (`init/1` schedules that first tick
with zero delay). If `Letflow.Obs.Alerts.TaskSupervisor` were ordered after `scheduler_children()`, a tick firing
before this supervisor exists would make `Task.Supervisor.start_child/2` return `{:error, :noproc}` (or fail with
a `noproc` exit if not handled) on that first tick — the exact ordering hazard SandboxPool.TaskSupervisor's own
comment (application.ex:59-63) already documents for its analogous case. Unlike SandboxPool's constraint, this
ordering-dependency comment applies only relative to `scheduler_children()`, not relative to any other
Task.Supervisor in the list; order among the seven Task.Supervisors themselves is not load-bearing, matching the
`ModuleVersionRegistry`/`ModuleVersionRegistryTaskSupervisor` pair's own "order between these two is not
load-bearing" note.

**Moduledoc-comment convention to follow (per REQ-173/REQ-166 precedent the task brief names):** the inline
comment immediately above the new child tuple must state:
1. Which issue/requirement motivates it (ISS-0429).
2. What work runs under it (alert-hook delivery's HTTP POST + retry/backoff loop, `deliver_with_retry/4`).
3. Why it is not shared with any of the six existing Task.Supervisors (independent concern — alert delivery
   is I/O-bound HTTP dispatch to tenant-operator-configured external endpoints, unrelated to sandbox
   provisioning, plugin/Lua/Wasm execution).
4. The ordering constraint from the paragraph above (must precede `scheduler_children()`; no constraint relative
   to the other six Task.Supervisors).

**Supervisor child spec:** `{Task.Supervisor, name: Letflow.Obs.Alerts.TaskSupervisor}` — identical shape to all
six existing entries. No custom `:max_children`, `:max_restarts`, or `:max_seconds` override: none of the six
existing Task.Supervisor children customize these either, and ISSUE-FIXER's diagnosis found no unbounded-fan-out
risk here (fan-out is bounded by `hooks` — a small, operator-configured, application-config list — times
`schemas` — one dispatch per enabled hook per tenant schema per tick, not per retry attempt, since each
dispatched task owns its own full retry loop internally).

## 2. Call-site change: `Letflow.Obs.Alerts.fire_hooks/4`

**Current (alerts.ex:412-426):** `fire_hooks/4` iterates hooks; for each enabled hook, calls
`check_and_record_emission/4` synchronously, and on `:ok` calls `deliver_with_retry(hook, payload, trigger_key, 1)`
synchronously and discards its return value.

**New shape:**
- `check_and_record_emission/4`'s call stays exactly where it is: synchronous, on the calling process
  (the Poller, transitively through `build_context_and_detect/3` → `run_detection/2` → `do_run_detection/3` →
  `evaluate_*` → `fire_hooks/4`), still evaluated and committed **before** any dispatch decision for that hook.
  This is what preserves the at-most-once/dedupe invariant unchanged: the emission row is written (or the
  `:already_emitted` short-circuit taken) exactly as often and in exactly the same order as today, independent
  of how or where delivery itself later runs.
- On `check_and_record_emission/4` returning `:ok` (not `:already_emitted`), `fire_hooks/4` replaces its direct
  call to `deliver_with_retry/4` with a dispatch via `Task.Supervisor.start_child/2` against
  `Letflow.Obs.Alerts.TaskSupervisor`, running the entire existing `deliver_with_retry(hook, payload, trigger_key, 1)`
  call (verbatim, including its own internal recursive `Process.sleep`) inside the spawned task.
- `fire_hooks/4`'s own return value is unaffected: it still returns `:ok` per hook iteration (via `Enum.each`),
  now regardless of whether that hook's delivery has completed, is retrying, or has not yet started — this is the
  intended effect (the Poller's tick no longer waits on delivery at all).

**Fire-and-forget, not `start_child` + collected result, not `async_nolink` + `handle_info`:** use
`Task.Supervisor.start_child/2` with a zero-arity closure, not `Task.Supervisor.async_nolink/2`/`async/2`. No
caller reads `deliver_with_retry/4`'s return value today (alerts.ex:422's call site already discards it,
`fire_hooks/4`'s own `@spec` return is `:ok` unconditionally) and nothing needs to react to delivery's outcome —
its only externally-visible effect on exhaustion is the existing `Logger.error` call inside `deliver_with_retry/4`
itself (alerts.ex:504-513), which already runs regardless of who dispatched it. `async_nolink/2` exists
specifically to let a caller later `Task.await/2`/`Task.yield/2` a `%Task{}` handle; keeping the returned handle
here (or worse, `await`-ing it) would either be dead code or would re-introduce the exact blocking-mailbox hazard
this fix removes. `start_child/2`'s return value (`{:ok, pid}` / `{:ok, pid, info}` / `{:error, reason}`) is
itself discarded by `fire_hooks/4` — a `start_child/2` failure (e.g. the supervisor itself is down) is a
`Task.Supervisor` machinery failure, not an alert-delivery failure, and is out of scope for `deliver_with_retry/4`'s
own error handling to catch.

**`deliver_with_retry/4`'s own signature and body: unchanged.** Its `@spec` (`AlertHookConfig.t(), map(), String.t(),
pos_integer() :: :ok | {:error, :exhausted}`) stays as-is even though its return value is now read by nobody
(previously also read by nobody, since `fire_hooks/4` already discarded it) — the function is unit-testable in
isolation exactly as it is today, and CODE-DESIGN-VALIDATOR should confirm no change is proposed to `deliver_with_retry/4`,
`backoff_delay/2`, or `RetryPolicy` beyond the caller now being a dispatched `Task` instead of the Poller process.

## 3. Why fire-and-forget is sufficient and does not repeat ISS-0224's original hazard

ISS-0224's hazard class, as its own resolution states it: "a `GenServer` executing a callback processes no other
message," so a synchronous DB call inside a pool callback froze the pool's mailbox, including a parked waiter's
own timeout timer. That fix needed `async_nolink/3` **plus** `handle_info({ref, result}, state)` because it had to
carry mutable pool-slot bookkeeping (`db_queue`, `in_flight`) across the async boundary and reply to a `from`
held across callbacks — the pool's correctness depends on knowing exactly when a dispatched operation completed
and what it returned.

Alert-hook delivery has no analogous state to carry across the boundary:
- No `from` is parked waiting on delivery's outcome — the Poller's `handle_info(:tick, _)` never blocked on a
  caller expecting a reply keyed to delivery completing; it moves on to the next tick unconditionally once dispatched.
- No pool-slot-style bookkeeping needs updating when delivery finishes, succeeds, retries, or exhausts. There is
  no "quota" or "queue" concept for alert-hook dispatch analogous to `SandboxPool`'s `active`/`waiting`/`db_queue`.
- Nothing downstream reads `deliver_with_retry/4`'s return value even in the current synchronous shape (confirmed
  above) — so there is no result to correlate a `{ref, result}` message back to.

**Crash observability, not correlation, is the actual requirement**, and `Task.Supervisor.start_child/2` provides
it without `async_nolink`: a task spawned via `start_child/2` under a `Task.Supervisor` is supervised — if the
spawned function raises or exits abnormally, the `Task.Supervisor`'s own supervision (`:temporary` restart by
default for ad hoc `start_child/2` tasks, matching `Task.Supervisor`'s documented default) logs the crash via the
standard OTP `:logger`/SASL crash-report path (the task's exit reason and stacktrace are reported exactly as any
other supervised child crash is — this is a property of `Task.Supervisor` itself, not something this design must
add). This is the same "crash is logged, not silently swallowed" property `SandboxPool.TaskSupervisor` and every
other existing `Task.Supervisor` child in `application.ex` rely on for their own detached-work paths (e.g.
`Letflow.Engine.Lua.TaskSupervisor`'s wall-clock-kill tasks are not correlated back to a caller either). This is
distinct from — and does not reintroduce — ISS-0224's own **original** pre-fix hazard, which was never "the task
is unsupervised" (SandboxPool never used a bare unsupervised `Task.start/1`) but specifically "the operation runs
synchronously inside a `GenServer` callback, freezing that GenServer's mailbox." Fire-and-forget under a
`Task.Supervisor` avoids that hazard identically to `async_nolink` — the Poller's mailbox is never touched by the
dispatched work either way, because both `start_child/2` and `async_nolink/2` return immediately without waiting
for the spawned function.

One additional, deliberate observability note: because `deliver_with_retry/4`'s own crash paths are already fully
enumerated (an `:httpc.request/4` error becomes an `{:error, reason}` tuple handled inline, not a raise; the
`policy.max_attempts` exhaustion path already calls `Logger.error` explicitly), the only *new* crash surface this
relocation introduces is an unanticipated raise inside `deliver_with_retry/4` itself (e.g. a future code change,
or a currently-unhandled `Jason.EncodeError`, `ArgumentError` from malformed `hook.destination_url`, etc.) — today
such a raise would crash the Poller's own `handle_info(:tick, _)` clause, caught by `maybe_run_alert_detection/3`'s
`try/rescue` (poller.ex:153-157) since it is inside the same `try` block as `Alerts.build_context_and_detect/3`'s
whole call graph. After this change, that same raise instead crashes only the dispatched Task, which
`Letflow.Obs.Alerts.TaskSupervisor` observes and logs per the paragraph above, and the Poller's own tick is
wholly unaffected either way (it already returned before the raise happens). This is a strict improvement in
blast-radius containment, not a regression: pre-fix, such a raise was caught by the *Poller's* `try/rescue`,
correctly preventing the Poller from crashing, but at the cost of that catch depending on the raise happening on
the Poller's own process while it was already blocked on this same code path's `Process.sleep`; post-fix, the
raise is isolated per-hook-dispatch rather than per-tenant-schema-iteration.

## 4. `maybe_run_alert_detection/3`'s existing `try/rescue`: no change required

`maybe_run_alert_detection/3` (poller.ex:148-160) wraps `Alerts.build_context_and_detect/3` in `try/rescue`,
catching a raise anywhere in the detection call graph — including, today, a raise happening *while*
`deliver_with_retry/4` runs synchronously inside that same call stack. After this fix, `build_context_and_detect/3`
returns as soon as `fire_hooks/4`'s `Enum.each` finishes dispatching every hook (each dispatch itself being a fast,
non-blocking `Task.Supervisor.start_child/2` call) — no delivery work, successful or failed, happens inside the
`try` block any more. This `try/rescue` therefore continues to serve its original purpose (isolate one tenant
schema's detection-and-dispatch pass from crashing the whole tick's `Enum.each` over schemas) with **no code
change needed**: it was never specifically protecting against a `deliver_with_retry/4` failure (that path already
returns `{:error, :exhausted}` rather than raising, on exhaustion) — it protects the detection/dispatch call graph
as a whole, and that graph's shape (raise-or-return) is unchanged by this fix. The only behavioral shift is that
the `try` block's wall-clock duration shrinks dramatically (from "up to the sum of every hook's backoff schedule"
to "however long it takes to iterate hooks and call `Task.Supervisor.start_child/2` once per eligible hook") —
this is the fix's entire point, not a side effect requiring further design.

## 5. Sequence, before and after

**Before (synchronous, current):**
```
Poller (handle_info :tick)
  -> Enum.each schemas
       -> maybe_run_alert_detection (try/rescue)
            -> Alerts.build_context_and_detect
                 -> run_detection -> do_run_detection -> evaluate_* -> fire_hooks
                      -> Enum.each hooks
                           -> check_and_record_emission  (sync, commits)
                           -> deliver_with_retry (sync)  <-- Process.sleep here, ON THE POLLER
  -> schedule_next_tick   (only reached after ALL hooks/schemas above complete)
```

**After (this fix):**
```
Poller (handle_info :tick)
  -> Enum.each schemas
       -> maybe_run_alert_detection (try/rescue, now bounded to fast dispatch only)
            -> Alerts.build_context_and_detect
                 -> run_detection -> do_run_detection -> evaluate_* -> fire_hooks
                      -> Enum.each hooks
                           -> check_and_record_emission  (sync, commits -- UNCHANGED)
                           -> dispatch to Letflow.Obs.Alerts.TaskSupervisor: a task whose
                              sole job is to invoke deliver_with_retry with this hook's
                              (hook, payload, trigger_key, 1) arguments  <-- runs off the Poller
                           (fire_hooks/4 moves on immediately; does not wait for the task)
  -> schedule_next_tick   (reached promptly -- no longer gated on any hook's backoff schedule)

[detached, concurrently:]
Letflow.Obs.Alerts.TaskSupervisor
  -> Task (one per dispatched hook firing)
       -> deliver_with_retry (unchanged body, including its own Process.sleep/recursion)
            -> on exhaustion: Logger.error (unchanged)
            -> on raise: Task.Supervisor logs the crash (new observability point, per §3)
```

## 6. Test approach

**Goal:** prove the Poller's `handle_info(:tick, _)` returns promptly — and schedules/processes a subsequent tick
promptly — even while a dispatched hook delivery is mid-backoff, i.e. the regression this fix targets is actually
closed.

**Why the real Poller GenServer must be started for this specific test, and how, without weakening `start_scheduler: false`
elsewhere:** `application.ex`'s `scheduler_children/0` gates `{Letflow.Scheduler.Poller, []}` behind
`Application.get_env(:letflow, :start_scheduler, true)`, set to `false` in `config/test.exs` specifically because
the Poller's zero-delay first tick queries `Letflow.Repo` from a process no test process is an ancestor of, which
raises `DBConnection.OwnershipError` under `Ecto.Adapters.SQL.Sandbox`'s default `:manual` mode (application.ex's
own comment, lines 126-144). That default must stay `false` for the suite at large — this fix does not touch that
gate. Instead, this test:
1. Does **not** rely on the supervised child. It starts its own **unsupervised** `Letflow.Scheduler.Poller`
   instance directly via `Letflow.Scheduler.Poller.start_link/1` (a plain `GenServer.start_link/3` under the
   hood, `name: __MODULE__` — the test must therefore either pass a distinct registered name if `start_link/1`
   is extended to accept one, or, since `start_link/1` currently hardcodes `name: __MODULE__`, run this test
   `async: false` within its own module so no other test in the suite starts a competing `Letflow.Scheduler.Poller`
   concurrently). This mirrors `http_child/0`'s own documented precedent noted in application.ex: "exercised
   directly, not through the supervised child."
2. Sets the sandbox to `:shared` mode (or otherwise ensures the manually-started GenServer process is allowed
   `Repo` access) for the duration of this one test, exactly as any other test that starts a real background
   process needing `Repo` access already must — this is a standard `Ecto.Adapters.SQL.Sandbox` test technique,
   not a new pattern this fix introduces.
3. Configures `:alert_hooks` (via `Application.put_env/3`, restored in `on_exit/1`) with exactly one enabled hook
   whose `destination_url` points at a test-local HTTP endpoint (e.g. `Bandit`/`Plug` test server, or a `:httpc`-
   reachable port this test process controls) that **never responds within `timeout_ms`** (or always returns a
   retryable non-2xx status) — guaranteeing `deliver_with_retry/4` enters its `Process.sleep(backoff_delay(1, policy))`
   branch. Sets a short `base_backoff_ms` in the test's `RetryPolicy` override (test-local config, not the
   production default) so the mid-backoff window is on the order of a few hundred ms to a couple seconds, not
   the real 1_000/30_000 ms production defaults — bounding the test's own runtime while remaining unambiguously
   long enough to straddle a second `:tick`.
4. Sets `Letflow.Scheduler`'s poll interval (via its existing config-reading accessor, matching how
   `Letflow.Scheduler.poll_interval_ms/0` is already overridden in other Poller/Scheduler tests) to a short value
   so a second real `:tick` is scheduled and fires well inside the hook's backoff window from step 3.
5. Drives one tenant schema through the trigger condition needed to make `evaluate_trigger/6` fire (ARMED state,
   sample > threshold) so `fire_hooks/4` actually dispatches the slow hook on the first tick.
6. **Assertion (the regression proof):** after triggering the first `:tick` (e.g. via `send(poller_pid, :tick)`
   or waiting for the zero-delay initial tick), assert that a **second** `:tick` is processed — observable via
   `:sys.get_state/1` on the Poller reflecting `last_tick_started_at` having advanced a second time, or via a
   `Letflow.Scheduler.poll_and_fire/1` side effect (e.g. a metrics counter or a timer firing for an unrelated
   test-created workflow instance in a different, fast-path tenant schema included in `schemas`) — within a
   bounded wall-clock window that is **shorter than** the slow hook's still-in-progress backoff delay from step 3.
   This is the direct behavioral proof that `handle_info(:tick, _)` returned before delivery finished, which is
   only possible if delivery is no longer running synchronously on the Poller.
7. **Fail-first requirement (per WF-03 Step 4):** this test must be shown to fail against the pre-fix code (the
   current synchronous `deliver_with_retry/4` call site) — TEST-DESIGNER runs it against the pre-fix commit with
   only this test file added and confirms it times out / the second tick does not arrive within the bounded
   window (because the Poller is still sleeping inside `deliver_with_retry/4`), then confirms it passes on the
   post-fix branch.
8. **Cleanup:** the test's `on_exit/1` must stop the manually-started Poller GenServer, restore `:alert_hooks`
   and `:scheduler` config to their pre-test values, and restore the sandbox mode — so no state or config leaks
   into subsequent tests, preserving `start_scheduler: false`'s protection for the rest of the suite unchanged.

**Secondary test (unit-level, no Poller needed):** a `Letflow.Obs.Alerts` test asserting that `fire_hooks/4`
(or `deliver_with_retry/4`'s dispatch point) returns near-instantly even when configured against a slow/hanging
endpoint, by observing that the calling test process's own `fire_hooks/4` call completes in well under one
backoff cycle, and that `check_and_record_emission/4`'s row is written (queryable via `Repo.get_by/3` in the
test's own sandboxed connection) before that call returns — directly demonstrating the ordering invariant of §2
holds post-fix, independent of the Poller-level end-to-end test above.

## 7. Open questions

None load-bearing for this fix's correctness — the design above is fully determined by ISSUE-FIXER's diagnosis
and the existing `Task.Supervisor` precedent. One item flagged for REVIEWER's own judgement rather than resolved
here: whether the moduledoc `## No new periodic process` section in `lib/letflow/obs/alerts.ex` (lines 38-42,
stating "No new child is added to `Letflow.Application`'s supervision tree") and the `## OQ-4 resolution` section
(lines 65-69, "`application.ex` is unchanged") need updating now that this fix *does* add
`Letflow.Obs.Alerts.TaskSupervisor` to `application.ex` — ELIXIR-DEV implementing this design should update both
moduledoc sections to reflect the new child, since leaving them stating "unchanged" would be actively false after
this fix lands; noted here so it is not silently missed as a documentation-consistency requirement of the
implementation, not an open design question.
