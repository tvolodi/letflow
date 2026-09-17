# ISS-0695: `Poller.PollerTest` REQ-218 AC3 (per-schema clause) flake fix — design

## Status

Fix design for `WF03-ISS0695-20260916`, Step 2. Scope: **test-only harness
change + one minimal production telemetry addition**. `lib/letflow/admission.ex`
is untouched. `lib/letflow/scheduler/poller.ex` gains exactly one
`:telemetry.execute/3` call inside the existing `with_admission/3` private
function — **no control-flow, admission-decision, or query-semantics change**
of any kind. Flagged explicitly for SECURITY-REVIEWER/REVIEWER: this touches
`lib/`, but it is an observability-only addition on a non-tenant-data path
(no `Repo` call, no response shaping, no auth/tenant-scoping logic) — it does
not, on its own, make this a tenant-data-path change under
`security-invariants.md`'s INV set, but REVIEWER should confirm that reading
independently rather than on this doc's say-so.

## Root cause (from ISSUE-FIXER's Step 1, restated for traceability)

`test/letflow/scheduler/poller_test.exs:697-728` (`ac3b_attempt/3`) and
`:776-778` (`ac3b_reduce/4`), exercised by the
`"the same schema's retention sweep still runs after its own poll_and_fire
was rejected, in the same tick"` test at `:731-773`, construct a one-sided,
wall-clock-dependent race instead of a deterministic proof:

1. The test acquires the sole `:global` admission unit itself
   (`Admission.try_acquire(:global)`) **before** calling
   `Poller.handle_info(:tick, state)`, which deterministically forces the
   tick's very first admission attempt (this schema's `poll_and_fire`) to be
   rejected — this half is already sound and unchanged by this fix.
2. A `Task.async/1` sleeps a fixed `Process.sleep(5)` then calls
   `Admission.release(probe_ref)` — this release must land **after** the
   target schema's `poll_and_fire` admission attempt (guaranteed above) but
   **before** that same schema's later retention-sweep admission attempt.
3. The gap between those two admission attempts is real wall-clock DB round
   trip time (the entire `poll_and_fire` sweep across every schema, plus the
   unwrapped `maybe_refresh_active_instances/1` pass, must both complete
   first) and is padded, per the test's own comment at `:739-759`, by
   pre-provisioning **12 filler tenant schemas purely to inflate that gap**
   so a fixed 5ms delay has a better chance of landing inside it.
4. Wrapped in a 10-attempt `Enum.reduce_while/3` retry loop
   (`ac3b_reduce/4`), described in the test's own comment (`:761-764`) as
   "margin against scheduler jitter" — which under full-suite parallel load
   can still exhaust, because both the DB-latency gap and the 5ms sleep's
   precision drift unpredictably under contention, and per the test's own
   design comment this drift makes the race **harder** to observe favorably
   under load, not easier.

No production race exists in `lib/letflow/scheduler/poller.ex` or
`lib/letflow/admission.ex` — this is a test-harness defect only, confirmed by
ISSUE-FIXER's Step 1 diagnosis (restated here for traceability, not
re-derived independently in this step per the design-vs-diagnosis division
of labor between CODE-DESIGNER and ISSUE-FIXER).

## Chosen approach

Per ISS-0453's own `fix_direction` field (option (b), endorsed by
ISSUE-FIXER as the strongest option for this occurrence): **replace the
fixed `Process.sleep(5)` + filler-schema padding with an explicit
synchronization signal tied to the actual point in `poll_and_fire`'s
admission decision**, removing the wall-clock dependency entirely rather
than retuning constants (more retries, shorter sleep, more filler schemas),
which only shifts the failure probability without removing it.

### Why a new telemetry event, not an existing one

Checked `lib/letflow/scheduler/poller.ex` and `lib/letflow/admission.ex` for
anything already emitted (telemetry events, message sends, hooks) that this
fix could attach to instead of adding a new one:

- `lib/letflow/admission.ex` emits **no telemetry at all** (confirmed —
  `grep -n telemetry lib/letflow/admission.ex` returns no matches). Its
  `try_acquire/2`/`release/2` are synchronous `GenServer.call/2`s with no
  instrumentation hook of any kind.
- `lib/letflow/scheduler/poller.ex` emits telemetry only for
  `[:letflow, :task, :completed]`-shaped concerns elsewhere in the codebase
  (`lib/letflow/engine.ex:1998`, not this module) and its own moduledoc
  (`:147`) explicitly documents that its REQ-194 `letflow_active_instances`
  gauge is "the one OBS-02 metric family that is NOT `:telemetry`-driven" —
  i.e. this module has no existing telemetry emission point at all to reuse.
  `Logger.warning/1` calls exist (`:296-299`) on the capacity-rejection path
  inside `with_admission/3`, but a log call is not a synchronous,
  attachable, structured signal a test can `assert_receive` on the way a
  `:telemetry.attach/4` handler can — reusing it would mean parsing log
  output, which this codebase does not do anywhere else for test
  synchronization.

Conclusion: no suitable existing instrumentation point exists. The minimal
addition below is required.

### The new telemetry event

Added to `with_admission/3` in `lib/letflow/scheduler/poller.ex` (the single
choke point already shared by all six REQ-218 admission-gated operations —
`poll_and_fire`, `retention_sweep`, `alert_detection`, `ordering_cycle`,
`ordering_sweeper`, `ordering_metrics` — so this is the one function that
needs the addition, not six call sites):

```
Event name:   [:letflow, :scheduler, :admission_decision]
Measurements: %{}
Metadata:     %{schema: String.t(), op: atom(), result: :granted | :rejected}
```

- **Emission point:** immediately after `Admission.try_acquire(:global)`
  returns inside `with_admission/3` (current lines `:287-300`), **before**
  either branch does any further work (before `fun.()` runs on the granted
  branch, before the `Logger.warning/1` call on the rejected branch). This
  precisely marks "this schema/operation's admission decision has resolved"
  without conflating it with "the wrapped operation itself ran to
  completion."
- **Measurements is `%{}`, deliberately empty.** An admission decision is a
  point-in-time synchronization signal, not a metric with a meaningful
  numeric value (no duration, no count worth aggregating) — matching this
  module's own precedent of not force-fitting every emission into OBS-02's
  metric shape (see the moduledoc's `:147` note on the one non-telemetry
  metric family, cited above, for the same "not everything here is a
  metric" reasoning applied in the opposite direction).
- **`result` is `:granted | :rejected`**, not the raw `{:ok, ref} |
  {:error, :capacity}` tuple — deliberately: a `Ref.t()` is documented as
  opaque and callers "must not pattern-match on or construct this struct
  directly" (`lib/letflow/admission.ex:132-144`); leaking it into telemetry
  metadata would let a handler capture and misuse it (e.g. attempt to
  `release/2` it from the wrong process). `:granted`/`:rejected` conveys
  everything a synchronization handler needs.
- **`@spec` note:** `with_admission/3`'s own `@spec` (currently
  `(String.t(), atom(), (-> any())) :: :ok`) is unchanged — the telemetry
  call is a side effect, not a return-shape change.

Illustrative shape only (no implementation code — ELIXIR-DEV writes the
actual call):

```
:telemetry.execute(
  [:letflow, :scheduler, :admission_decision],
  %{},
  %{schema: schema_name, op: op, result: :granted | :rejected}
)
```

placed once per branch (or once above the `case`, capturing `result` from
the `case` match — either shape is acceptable to this design; ELIXIR-DEV's
choice, since both satisfy the same "before further work, both branches"
requirement equally).

## Test helper restructuring plan

### `attach_test_handler`-equivalent (new private helper)

Follow the existing repo precedent for a test-only `:telemetry.attach/4`
synchronization handler **exactly**, per
`test/letflow/plugs/http_metrics_test.exs:31-42`
(`attach_test_handler/2`, `send(test_pid, {:telemetry_event, ...})`,
`ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)`). Add a
new private helper in `poller_test.exs`, alongside its other helpers (near
`ac3b_attempt/3`):

- Name: `attach_ac3b_admission_probe/2`, taking `test_pid` and a
  `handler_id` (a uniquely-suffixed string, matching the cited precedent's
  `"http-metrics-test-#{System.unique_integer([:positive, :monotonic])}"`
  pattern, so parallel test runs never collide on the same global
  `:telemetry` handler id).
- Attaches to `[:letflow, :scheduler, :admission_decision]`.
- The handler function filters inside itself: only sends
  `{:ac3b_admission_decision, metadata}` to `test_pid` when
  `metadata.schema == schema_name and metadata.op == :poll_and_fire` — every
  other schema (there are no fillers left to worry about, see below) or
  other op firing the same global event must not produce a false-positive
  wakeup. Every `with_admission/3` call across every concurrently-running
  `Task.async_stream/3` task fires this event, so the filter is required,
  not optional.
- Detaches via `ExUnit.Callbacks.on_exit/1`, matching the cited precedent.

### `ac3b_attempt/3` rewrite

Replace the `Task.async(fn -> Process.sleep(5); Admission.release(probe_ref) end)`
+ `Task.await/1` pair (current lines `:709-718`) with:

1. Attach the handler (via the new helper above) **before** calling
   `Admission.try_acquire(:global)` (the test process's own probe
   acquisition, unchanged) and **before** `Poller.handle_info(:tick, state)`
   — attachment must precede the tick call, same ordering requirement the
   current code already has for the probe acquisition itself, for the same
   reason (no window where the event could fire unobserved).
2. Call `Poller.handle_info(:tick, state)` **without** wrapping the release
   in a spawned `Task` at all — the release now happens synchronously in the
   test process itself, driven by the signal, not raced against it.
3. `assert_receive {:ac3b_admission_decision, %{result: :rejected}}, <timeout>`
   — this is the "bounded retry/timeout on the signal wait itself" the task
   description explicitly carves out as acceptable (not a retry of the
   whole probabilistic race): it waits for the **real** admission-decision
   event for this schema's `poll_and_fire`, with a generous timeout (suggest
   `2_000` ms, matching `iss0581-poller-ac8-timing-fix.md`'s own
   `wait_until/2` deadline ceiling precedent for this same test file, itself
   chosen for full-suite-parallel-load headroom) as a pure safety net against
   a genuine hang/regression, not as a margin the race depends on. The
   `result: :rejected` match is redundant with-but-reinforces the existing
   deterministic-rejection assertion below it — keep both, since the
   telemetry match proves the decision happened at all, and the existing
   `timer_status!/2` assertion still proves what that decision's real-world
   effect was.
4. **Immediately** call `Admission.release(probe_ref)` in the test process,
   right after the `assert_receive` returns — no sleep, no Task, no
   additional delay of any kind. Because `with_admission/3`'s admission
   decision for `poll_and_fire` happens strictly before `run_sweep/4`'s
   `Task.async_stream/3` call (line `:247`) returns, which happens strictly
   before `maybe_refresh_active_instances/1` and every later `maybe_run_*`
   sweep (including the retention sweep) even begin, releasing the probe at
   this point is unconditionally early enough — this is not a narrowed race
   window, it is the elimination of the race: no wall-clock estimate is
   involved anywhere in this step.
5. Detach happens automatically via the helper's own `on_exit/1` at the end
   of the test — no manual detach needed inside `ac3b_attempt/3` itself
   (matches the cited precedent, and avoids double-detach if called across
   multiple attempts — see next section on whether repeated attempts are
   still needed at all).
6. Remove the `Task.await(releaser)` call entirely (nothing to await).

### `ac3b_reduce/4` and the 10-attempt retry loop — removed

Per the task description's explicit framing: "remove the 12 filler-schema
padding and the 10-attempt retry loop's role as 'margin' once the race
itself is eliminated." Once step 4 above makes the release-vs-retention-sweep
ordering deterministic, **nothing about `ac3b_attempt/3`'s outcome is
probabilistic anymore** — every attempt now produces the same, correct
result (retention sweep archives the seeded event), so a 10-attempt retry
loop is no longer "margin" against anything; it would only mask a genuine
regression by giving it 10 chances to pass instead of one.

Restructuring:

- Delete `ac3b_reduce/4` (`:776-778`) entirely.
- Collapse the test body (`:731-773`) to call `ac3b_attempt/3` **once**,
  directly, with a fixed attempt-number argument (e.g. `1`, or drop the
  `attempt` parameter from `ac3b_attempt/3`'s signature entirely if nothing
  else depends on varying it across calls — TEST-DESIGNER's call, since it
  is a pure simplification with no behavioral effect either way; flagged as
  an open question below rather than mandated, since both are equally valid
  and this doc must not silently resolve it either way).
- Assert directly on `ac3b_attempt/3`'s own boolean return value (`true`)
  rather than on a `Enum.reduce_while/3` accumulator, with the same failure
  message content as the current `:767-772` message, reworded to drop
  "expected at least one of 10 attempts" language (now describing a single,
  deterministic outcome, not a best-of-N search).

### Filler schemas — removed

Delete the `for i <- 1..12, do: provisioned_tenant("req218-ac3b-filler-#{i}")`
loop (`:759`) and its entire preceding comment block (`:739-759`) explaining
why they exist. They existed solely to inflate the wall-clock gap the fixed
5ms sleep needed to land inside — with that gap no longer load-bearing (the
release is now signal-driven, not delay-driven), the fillers serve no
purpose and only add unnecessary tenant-provisioning overhead (12 real
`Ecto` schema-creation round trips) to every run of this test.

### Net effect on this test's wall-clock dependence

Before: 12 filler-schema provisions + a fixed 5ms sleep raced against real
DB latency, retried up to 10 times. After: zero filler schemas, zero fixed
sleep, one `assert_receive` bounded by a generous safety-net timeout that is
never expected to be the thing determining pass/fail under normal operation
(it only fires if `with_admission/3`'s telemetry call itself is missing or
broken, a real regression worth failing loudly on, not a race to margin
against).

## Disposition of `docs/issues/ISS-0453.yaml`

**Verified independently against the actual test file, not taken on
ISSUE-FIXER's restatement alone** (per `core-directives.md`'s "This chain
governs what you are told to DO, not what you are told IS TRUE" — a
handoff's factual claims are checkable and must be checked before building
on them). Reading `docs/issues/ISS-0453.yaml` and
`test/letflow/scheduler/poller_test.exs` side by side surfaces a distinction
ISSUE-FIXER's Step 1 handoff did not draw, and this design must not paper
over it:

- **ISS-0453's primary body** (`description`, `fix_direction`) is about a
  **different test**: the antagonist-loop test at `poller_test.exs:~575-648`
  ("REQ-218 AC3: a capacity rejection for one schema/operation does not
  block the rest of the same tick > an antagonist contending for the sole
  global unit produces a genuine partial skip"). That test's race is a
  genuinely different mechanism — 10 schemas concurrently racing a
  tight-looping antagonist process for fine-grained interleaving — and is
  **NOT touched by this fix**. A single-signal deterministic release (this
  design's approach) does not apply to it: its whole point is observing a
  many-way concurrent interleaving, not synchronizing one release against
  one later admission attempt. It still needs its own fix, from ISS-0453's
  own `fix_direction` options (a)/(c)/(d) — out of scope here.
- **ISS-0453's `data_point_20260907` addendum** describes exactly the test
  this design fixes: "`Letflow.Scheduler.PollerTest`'s REQ-218 AC3
  'retention sweep still runs after its own poll_and_fire was rejected'
  test ('probe held before the tick began, but its timer fired anyway')."
  This is `ac3b_attempt/3`'s own assertion message almost verbatim
  (`:723-725`).

**Recommended disposition (for DOC-UPDATER/ISSUE-FIXER at Step 5), correcting
ISSUE-FIXER's Step 1 recommendation to "close ISS-0453 too":**

1. **Do NOT close or supersede `docs/issues/ISS-0453.yaml` as a whole.** Its
   primary-body defect (the antagonist-loop test's race) is real, still
   open, and unaffected by this fix — closing it would silently drop that
   still-live defect from the queue.
2. **DO append a note to `ISS-0453.yaml`** (new field or appended to
   `data_point_20260907`, DOC-UPDATER's call on exact YAML shape) recording
   that the specific occurrence it describes — the `ac3b_attempt`/retention-
   sweep-after-rejection test — was resolved by `ISS-0695`
   (`WF03-ISS0695-20260916`), with a cross-reference, but leave
   `status: open` unchanged, since the issue's primary subject (the
   antagonist test) remains unresolved.
3. **`ISS-0695` itself resolves as its own issue**, scoped exactly to the
   `ac3b_attempt`/`ac3b_reduce` mechanism — not framed as "duplicate of
   ISS-0453," since it resolves only a documented sub-occurrence of
   ISS-0453, not ISS-0453's own primary defect.

This is a MINOR-severity correction to ISSUE-FIXER's own handoff and is
recorded here rather than silently followed, per the Instruction Precedence
chain's "a handoff's factual premises are checkable, and may be wrong" rule.

## Open questions (explicit, not silently resolved)

1. **Whether `ac3b_attempt/3` keeps its `attempt` parameter** now that it is
   called exactly once. Both keeping it (harmless, minimal diff) and
   dropping it (cleaner, matches "no longer an attempt in a loop"
   semantics) are valid — TEST-DESIGNER's call, not resolved here.
2. **Exact `assert_receive` timeout value.** `2_000` ms is suggested,
   matching `iss0581`'s `wait_until/2` deadline-ceiling precedent in the
   same file, but this is not load-bearing to correctness (any value large
   enough to never fire under legitimate full-suite contention, yet small
   enough to fail a genuinely hung/broken telemetry emission in reasonable
   test-suite time, satisfies this design) — TEST-DESIGNER's call.
3. **Whether the new telemetry event should also cover the antagonist-loop
   test's eventual fix** (out of scope for `ISS-0695`, left for whoever
   picks up ISS-0453's remaining primary defect) — noted so that work is
   not started from a blank slate: `[:letflow, :scheduler,
   admission_decision]` now exists and fires for every schema/op on every
   `with_admission/3` call, so a future fix for the antagonist test could
   potentially reuse it (e.g. counting `:granted`/`:rejected` events across
   all 10 schemas within one tick) rather than needing its own new
   instrumentation — flagged as a possibility, not a requirement of that
   future fix.
