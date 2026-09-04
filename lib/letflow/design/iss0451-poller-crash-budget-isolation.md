# ISS-0451 — Bound a PERSISTENT Poller fault so it cannot exhaust the
# top-level `Letflow.Supervisor`'s own restart budget

Design for closing ISS-0451 (`docs/issues/ISS-0451.yaml`), the residual gap
REVIEWER filed while gating REQ-219 (`handoffs/WF02-REQ219-20260903/step-02d-reviewer.json`):
REQ-219's layering correctly isolates a **single** Pollers-budget-exhaustion
event, but a **persistent** (never-clearing) Poller fault re-exhausts
Pollers' own budget almost immediately after every top-level-triggered
restart, and empirically cascades to take down the whole application —
`Letflow.Repo`, Bandit included — in well under one second. No implementation
code below — module shapes, exact config values/state machine, and prose
only, per this project's design-vs-implementation convention (see
`req219-supervision-layering.md` as the precedent this doc follows).

## 0. Inputs read in full before this design

* `handoffs/WF03-ISS0451-20260904/step-01-issue-fixer-diagnosis.json`
  `result.summary` — ISSUE-FIXER's empirically-verified root cause and
  arithmetic (§1 below quotes and builds on it directly; not re-derived from
  scratch, per `docs/agents/shared/HANDOFF_PROTOCOL.md`'s "a handoff's
  factual premises are checkable" — its numbers are treated here as
  independently-confirmed measurement, not re-verified a second time,
  because ISSUE-FIXER already ran a live throwaway probe on this project's
  own pinned toolchain, not merely arithmetic reasoning).
* `docs/issues/ISS-0451.yaml` — full description, both candidate options
  (neither prescribed), severity MAJOR.
* `lib/letflow/application.ex` (full, 54 lines) — top-level `Letflow.Supervisor`,
  `opts = [strategy: :one_for_one, name: Letflow.Supervisor]`, no
  `max_restarts`/`max_seconds` override anywhere — confirmed OTP default
  (3 restarts / 5 seconds) is what actually governs it today.
* `lib/letflow/supervisor/pollers.ex` (full, 163 lines) — `Supervisor.init(children,
  strategy: :one_for_one, max_restarts: 5, max_seconds: 60)`; the
  `@supervisor_test_hooks_enabled?`/`pollers_init_probe` double-gate
  precedent (compile-time `Application.compile_env(:letflow,
  :activation_test_hooks_enabled?, false)` folding to a literal `false` in
  every non-test build) this design reuses for its own new test seam (§5).
* `lib/letflow/supervisor/infrastructure.ex` (moduledoc + children list,
  lines 1-40+) — confirms Infrastructure's own intensity is OTP-default,
  unchanged, and is listed first in `Letflow.Application.start/2`'s 3-element
  children list (REQ-219 AC2, structural boot-order guarantee this design
  must not touch).
* `lib/letflow/supervisor/http.ex` — same OTP-default-intensity shape as
  Infrastructure, listed third.
* `lib/letflow/design/req219-supervision-layering.md` (full) — the design
  this one extends: §2 (`Letflow.Application.start/2`'s 3-element children
  list, no top-level intensity override, decision 3's rationale for why),
  §3 (Pollers' own `5/60` override rationale), §4 (AC2 cold-boot test
  mechanism and double-gate pattern), §5 (AC4 crash-loop-isolation test
  mechanism, including the "GENUINE TIMING HAZARD" comment in the test file
  itself — the exact mechanism this design's own regression test (§5 below)
  must NOT reproduce, since that hazard-avoidance is precisely the behavior
  under test here).
* `test/letflow/supervisor/pollers_test.exs` (full, 223 lines) — REQ-219's
  own AC4 test, in particular its inline comment (lines 127-143) explaining
  why it clears `:force_poller_crash` immediately after the first `:DOWN`:
  this is the existing "single-shot" test this design's new regression test
  is deliberately the persistent-fault counterpart to, sharing its
  `force_poller_crash`/`start_scheduler` env-var mechanism but never
  clearing the fault.
* `lib/letflow/scheduler/poller.ex` (moduledoc + REQ-219 addition section,
  lines 1-80+) — confirms the double-gated `force_poller_crash` guard clause
  already exists at the top of `handle_info(:tick, state)`, unconditionally
  raising when both the compile-time `@poller_test_hooks_enabled?` and the
  runtime `Application.get_env(:letflow, :force_poller_crash, false)` gates
  are open. This design's regression test (§5) reuses this existing seam
  unchanged — no new guard clause, no new gate, no new config key.

## 1. Restated arithmetic (from ISSUE-FIXER's diagnosis, not re-derived)

Quoted/summarized from `step-01-issue-fixer-diagnosis.json` `result.summary`,
part (c) and (d):

* Top level: `max_restarts: 3, max_seconds: 5` (OTP default, unmodified).
* Pollers: `max_restarts: 5, max_seconds: 60` (deliberate override).
* A PERSISTENT fault: Pollers exhausts its own 5/60 budget, exits, is
  restarted by the top level (1 top-level restart consumed) — then
  IMMEDIATELY re-enters the identical crash loop (nothing cleared it),
  re-exhausts its own budget, exits again (2nd top-level restart) — a 3rd
  and 4th such cycle exhausts the top level's own 3/5 budget: **on the 4th
  Pollers-level exit landing inside any rolling 5-second top-level window,
  the top level itself exits.**
* Live probe (Elixir 1.20.3 / OTP 29, this project's pinned toolchain):
  Pollers' `init/1` ran 4 times (1 initial + 3 top-level restarts), the
  crashy child raised 24 times total, and the **top-level supervisor
  received `:shutdown` at 96ms wall-clock** from probe start — several
  orders of magnitude faster than Pollers' own 60-second window, so there
  is no scenario where that window "rolls past" and resets before the
  cascade completes.

**The one arithmetic fact this design adds, not present in the diagnosis,
and the one that settles the architectural choice below:** the cadence at
which Pollers re-exhausts under a persistent fault (~24-30ms per full
5-restart Pollers-level cycle, from the probe's 96ms / 4 cycles) is a
property of the fault itself (a zero-delay first tick that raises
immediately, restarts immediately, raises again), not of either
supervisor's `max_restarts`/`max_seconds` values. **Raising the top level's
own `max_restarts` to any FINITE N only buys N-3 additional top-level
restarts before the identical exhaustion recurs — it cannot make the top
level survive a persistent fault *indefinitely*, only *longer*, because
nothing about a larger N changes the ~10-50ms-per-cycle rate at which
Pollers keeps re-arriving at the top level's door.** A window widened
instead of (or as well as) the count runs into the same wall: the fault
cadence is far faster than any window width that would still let a
`max_restarts` in the single-or-low-double-digits range mean anything
(see §2 for why this design does not chase that axis either). This is the
reason §3 below is not optional set-dressing alongside §2 — it is the only
lever in this design that can change the *rate*, and rate is what
"indefinitely" requires.

## 2. Chosen design: circuit-breaker/backoff in `Letflow.Supervisor.Pollers`
## is the primary fix; a modest top-level intensity raise is defense-in-depth

**Decision: BOTH levers, but not as equal partners.** The circuit-breaker
(§3) is the fix that actually closes ISS-0451 for a truly persistent fault —
it is the only mechanism that changes the re-exhaustion *rate*, which §1
just showed is the binding constraint. The top-level intensity raise (§4) is
kept as a secondary, cheap, and independently-justified defense-in-depth
measure: it costs nothing, it does not weaken anything, and it buys
additional margin against a *transient-but-bursty* fault pattern (below the
per-Poller-cycle exhaustion cadence but still faster than the breaker's own
first cool-down) that the breaker's own state machine has a narrow window to
not yet be engaged for. Neither lever is dropped; they are not redundant
with each other because they bound different things (§4's own paragraph
states exactly what its 2-restart increase covers that the breaker does
not, so this is not a "belt and suspenders because unsure" hedge).

**Why NOT top-level-intensity-alone (the option this design rejects as a
standalone fix):** per §1, no finite `max_restarts`/`max_seconds` choice at
the top level makes it survive a persistent fault *indefinitely* — it only
delays the identical cascade by a fixed, small number of additional
restarts, each consumed in the same double-digit-millisecond cadence the
probe measured. A reviewer might suggest a very large `max_restarts` (e.g.
1000) with a short window — but OTP's intensity check is `(max_restarts +
1)`-th restart *within* the window, and this project's own probe shows 4
top-level restarts alone (well below any such large N) already took 96ms;
a fault persisting for any real operational timescale (seconds, minutes)
would exhaust even a 1000-restart budget in well under a second at the
same cadence, since nothing bounds the RATE. Raising intensity alone also
has a real cost REQ-219's decision 3 flagged implicitly and this design
makes explicit: a larger top-level budget also loosens the top level's
protection against an UNRELATED infrastructure crash-loop (e.g. `Letflow.Repo`
itself repeatedly failing to reconnect) that decision 3 deliberately left at
the OTP default specifically because "a crash-looping infra child indicates
a fault severe enough that taking the app down is still correct"
(`infrastructure.ex`'s own moduledoc, quoted). The top-level `max_restarts`
is shared across ALL of Infrastructure/Pollers/Http as top-level children —
raising it to cover Pollers' persistent-fault scenario mechanically also
raises how many times Infrastructure or Http may crash-loop before the same
protection kicks in for THEM, since `Supervisor`'s intensity budget is a
single counter over all children's restarts, not per-child. This is exactly
why REQ-219 decision 3 chose the OTP default there and is why this design
does not chase a large top-level number as its primary lever — see §4 for
the specific, small, justified value chosen instead, scoped to stay
compatible with that decision.

**Why NOT circuit-breaker-alone (the option this design also does not take
in pure form):** the breaker (§3) has a startup transient — its own state
machine needs to observe Pollers' OWN budget being exhausted at least once
(the `:closed → :open` transition, §3.2) before it starts suppressing
further top-level-consuming restarts. During that one observation window,
the top-level supervisor experiences exactly the SAME restarts REQ-219's
existing AC4 test already proves it tolerates (a single Pollers exhaustion
cycle = 1 top-level restart, comfortably inside the OTP default's 3/5
budget) — so a breaker-alone design is not unsafe, but leaving the top
level at the bare OTP default provides zero margin if, e.g., an unrelated
transient Infrastructure or Http restart happens to land in the same
5-second window as the breaker's first observation cycle. §4's 2-restart
increase is sized exactly to cover that one coincidence case, not to do any
of the persistent-fault-bounding work itself.

## 3. `Letflow.Supervisor.Pollers` circuit-breaker — exact state machine

### 3.1 Scope: per-Pollers-supervisor, not per-individual-poller

**Applies to the whole `Letflow.Supervisor.Pollers` supervisor as one unit,
not to each of its two children (`Letflow.Scheduler.Poller`,
`Letflow.Engine.ServiceTaskDispatcher.Poller`) independently.** Rationale,
tied directly to this module's own existing, already-documented design
decision (`pollers.ex`'s moduledoc, "DELIBERATE, ACCEPTED CONSEQUENCE"
paragraph, quoted in §0 above): REQ-219 already established that when ONE
poller's crash-loop exhausts the SHARED `5/60` budget, the whole
`Letflow.Supervisor.Pollers` supervisor exits and restarts, taking the OTHER
poller down with it too, "since restarting the whole supervisor process
necessarily restarts everything under it" — an accepted consequence, not a
gap. A per-poller circuit breaker would need EITHER (a) each poller wrapped
in its own additional supervision layer with its own intensity budget
(a 4th nesting level, restructuring REQ-219's already-reviewed 2-poller
shared-supervisor shape, which this issue's own scope does not ask for and
which would need its own REQ, not a bug-fix design) or (b) a breaker that
tracks two independent pieces of per-poller state while still living inside
one supervisor's `init/1`, which only complicates the state shape below
without changing the actual observable property ISS-0451 cares about: does
the TOP-LEVEL supervisor ever exit. Tracking breaker state at the
`Pollers`-supervisor level, matching the granularity at which the actual
budget that matters (Pollers' own `5/60`) already lives, is the smaller,
consistent, no-new-supervision-layer choice. **Consequence, stated
explicitly so ELIXIR-DEV and REVIEWER see it as an accepted trade, not a
silent gap:** if `Letflow.Scheduler.Poller` alone develops a persistent
fault while `Letflow.Engine.ServiceTaskDispatcher.Poller` is healthy, the
breaker trips for BOTH — the healthy poller also stops running once the
breaker opens, exactly mirroring the ALREADY-ACCEPTED "both pollers restart
together" consequence from REQ-219 §3, just extended from "restart
together" to "stop together." This is consistent with, not a new departure
from, the existing accepted-consequence precedent.

### 3.2 States and transitions

Three states, held as process state inside `Letflow.Supervisor.Pollers`
itself (a `Supervisor` behaviour process does not carry ad-hoc state today —
see §3.4 for exactly where this state actually lives, since `Supervisor`
callbacks are stateless between `init/1` calls).

```
:closed  -- normal operation. Both gated pollers run as Pollers' children,
            exactly as today. Pollers' own max_restarts: 5, max_seconds: 60
            governs individual-poller-restart absorption exactly as REQ-219
            already specifies -- UNCHANGED.

:open    -- tripped. Pollers holds ZERO children (both pollers stopped, not
            crash-looping) for the duration of one backoff interval (§3.3).
            This is the "stopped, not crash-looping" state ISS-0451's own
            option (b) text asks for, verbatim.

:half_open -- probing. After one backoff interval elapses, Pollers restarts
            exactly the previously-running poller(s) ONE more time and
            watches: if a full max_restarts:5/max_seconds:60 cycle
            completes WITHOUT re-exhausting (i.e. the fault cleared), the
            breaker returns to :closed and normal operation resumes with no
            further restriction. If the SAME exhaustion is observed again,
            the breaker returns to :open with the NEXT backoff interval
            (see §3.3's growth schedule) -- never resets the schedule to
            its shortest value on a repeat trip.
```

Transition trigger for `:closed -> :open`: **Pollers' own supervisor
`terminate/2`-adjacent mechanism cannot observe "I am about to exceed my own
`max_restarts`" from inside `Supervisor`'s own callback contract — a
`Supervisor` process that exhausts its intensity budget simply exits; it
does not get a callback invocation to react to that fact before exiting.**
This is why §3.4 below does not implement the breaker AS `Letflow.
Supervisor.Pollers`'s own `init/1` logic reacting to its own exhaustion (it
structurally cannot — by the time `Supervisor`'s intensity check fires,
the process is already exiting) but as a SEPARATE, PARENT-LEVEL process
(§3.4) that observes Pollers' repeated exits from the outside and decides
when to stop letting the top-level supervisor's own automatic restart of
Pollers re-arm the crash loop at all.

### 3.3 Backoff schedule

Exponential, with a cap, expressed as the `:open`-state duration before the
NEXT `:half_open` probe:

| Consecutive trip # | `:open` duration |
|---|---|
| 1st | 1 second |
| 2nd | 5 seconds |
| 3rd | 30 seconds |
| 4th | 2 minutes |
| 5th and beyond | 5 minutes (cap, does not grow further) |

**Rationale for these five concrete numbers, since ISS-0451's AC2 demands
arithmetic, not merely a labelled schedule:** the 1st interval (1s) is
comfortably longer than the ~24-30ms empirically-measured full
Pollers-exhaustion cycle (§1), so even the very first `:half_open` probe
never lands inside the SAME rolling top-level-intensity window as the
trip that opened the breaker — it is a fresh, isolated restart attempt
roughly 40x further out in wall-clock time than the fault's own natural
cadence, giving the top level's 5-second window (§4) a full window's worth
of quiet before the next restart it might have to absorb. The schedule then
grows fast enough (1s -> 5s -> 30s -> 2m -> 5m) that a genuinely permanent
fault (a bad migration, a config typo, a permanently-unreachable dependency
-- ISS-0451's own examples) settles into a bounded worst case of **one
probe attempt every 5 minutes, forever** -- a finite, small, and
OPERATIONALLY OBSERVABLE (§3.5) steady-state cost, not an unbounded retry
storm. The cap is chosen at 5 minutes rather than growing without bound so
that a fault which DOES eventually clear (a downstream dependency recovers,
an ops fix lands) is picked back up again within a human-reasonable
window, not held open indefinitely by an ever-growing backoff.

### 3.4 Where the breaker actually lives: a new, small, always-`:closed`-shaped supervisor sibling — `Letflow.Supervisor.PollersBreaker`

**Not inside `Letflow.Supervisor.Pollers.init/1` itself** (§3.2 already
explained why that callback cannot observe its own impending exhaustion).
Instead: a new module, `Letflow.Supervisor.PollersBreaker`
(`lib/letflow/supervisor/pollers_breaker.ex`), `use GenServer`, started as
**Infrastructure's own responsibility is NOT touched** — it is a fourth
top-level child, inserted into `Letflow.Application.start/2`'s children
list, positioned AFTER `Letflow.Supervisor.Pollers` (so REQ-219 AC2's
"Infrastructure before Pollers" ordering guarantee is completely
unaffected — this module depends on neither Infrastructure's contents nor
Pollers' own boot completing before IT starts, only on being able to call
`Supervisor.terminate_child/2`/`restart_child/2` against the ALREADY-named
`Letflow.Supervisor.Pollers` and `Letflow.Supervisor` process names, which
resolve by name regardless of relative boot order once both exist).

`Letflow.Application.start/2`'s children list becomes: `[Letflow.
Supervisor.Infrastructure, Letflow.Supervisor.Pollers, Letflow.
Supervisor.PollersBreaker, Letflow.Supervisor.Http]` — Http stays last,
unaffected; the breaker sits between Pollers and Http.

**Mechanism, at the level of what state it holds and what triggers each
transition (signatures/types only, no bodies):**

* `Letflow.Supervisor.PollersBreaker.start_link/1` — same 1-arg,
  named-`start_link` shape as the other three supervisor-adjacent modules
  (`Letflow.InstanceSupervisor`'s established convention, per
  `req219-supervision-layering.md` §1's own precedent).
* Process state (a `@type t()`): `%{state: :closed | :open | :half_open,
  consecutive_trips: non_neg_integer(), pollers_monitor_ref: reference() |
  nil, backoff_timer_ref: reference() | nil}`.
* On `init/1`: `Process.monitor(Process.whereis(Letflow.Supervisor.Pollers))`
  — the breaker monitors the ALREADY-RUNNING `Letflow.Supervisor.Pollers`
  process (started just before it in the top-level children list), state
  starts `:closed`, `consecutive_trips: 0`.
* `handle_info({:DOWN, ref, :process, pollers_pid, reason}, state)` — fires
  every time `Letflow.Supervisor.Pollers` exits, for ANY reason (matches
  today's already-accepted "the whole supervisor exits and is restarted"
  event exactly — REQ-219's own AC4 test already asserts this `:DOWN`
  happens once per single-shot event; this handler is the multi-event
  extension). On EACH such `:DOWN`:
  * If current state is `:closed`: this is the FIRST observed exhaustion.
    Do NOT open the breaker yet on a single event — a single Pollers exit
    is exactly the ALREADY-ACCEPTED, ALREADY-TESTED (REQ-219 AC4) case that
    needs no additional handling; the top level's own default restart
    absorbs it exactly as today. Instead: re-monitor the NEW `Letflow.
    Supervisor.Pollers` pid (the top level has, by the time this handler
    runs, either already restarted it or is about to — see §3.6 for the
    exact race and why it is safe) and start a short observation timer
    (§3.6). If a SECOND `:DOWN` for the re-monitored pid arrives before
    that observation timer fires, THAT is what trips `:closed -> :open`
    (transition to `:open`, `consecutive_trips: 1`, call
    `Supervisor.terminate_child(Letflow.Supervisor, Letflow.
    Supervisor.Pollers)` so the top level does not even attempt a further
    automatic restart while the breaker holds it open — see §3.7 for why
    this call, not merely "let it keep restarting," is required),
    `Process.send_after(self(), :half_open_probe, 1_000)` (§3.3's 1st
    interval).
  * If current state is `:open`: should not observe a `:DOWN` here (Pollers
    is already terminated by this process itself) — a defensive no-op /
    log, not a crash, since `Supervisor.terminate_child/2` is itself
    request-response and this handler does not race against it.
  * If current state is `:half_open`: the probe restart (§3.2) itself
    crash-looped and re-exhausted — trip back to `:open`,
    `consecutive_trips: consecutive_trips + 1`, `terminate_child` again,
    schedule the NEXT backoff interval per §3.3's table indexed by the new
    `consecutive_trips` value.
* `handle_info(:half_open_probe, state)` (fires when a `:open`-state backoff
  timer elapses): transition to `:half_open`,
  `Supervisor.restart_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)`,
  re-monitor the resulting pid, start a fixed observation window (§3.6) to
  decide success vs. re-trip.
* On successful `:half_open` completion (the observation window in §3.6
  elapses with no further `:DOWN`): transition to `:closed`,
  `consecutive_trips: 0` (schedule resets to the 1st interval only on a
  GENUINE recovery, never merely on the passage of time while still
  crash-looping — this is why §3.3's table is indexed by
  `consecutive_trips`, which only increments on a repeat trip and only
  resets here).

### 3.5 Observability (so an operator can tell "stopped, not crash-looping" apart from "silently dead")

`Letflow.Supervisor.PollersBreaker` logs (via `Logger.warning/1`, matching
this codebase's existing skip-and-continue logging precedent cited in
`poller.ex`'s own moduledoc, e.g. `lib/letflow/tenant_provisioning/backfill.ex:37,44`)
on every `:closed -> :open` and `:open -> :half_open` transition, naming the
`consecutive_trips` count and the next backoff interval — an operator
grepping logs sees a clearly bounded, decreasing-frequency retry pattern
rather than an unbounded crash storm. A public read-only query function,
`@spec breaker_state() :: :closed | :open | :half_open` (calling
`GenServer.call(Letflow.Supervisor.PollersBreaker, :get_state)`), is exposed
for §5's regression test and for any future health-check/ops-visibility
endpoint (out of this issue's scope to wire one up, but the accessor is
cheap and test-load-bearing regardless — see §5).

### 3.6 Race-safety note: the two-`:DOWN`-events-vs-one-observation-timer mechanism, and why it does not double-count REQ-219's own AC4 single-shot case

**This is the one subtlety load-bearing enough to spell out arithmetically,
since a sloppy version of this mechanism could accidentally trip the
breaker on ordinary, already-tested single-shot behavior.** REQ-219's own
AC4 test (`pollers_test.exs`, `describe "AC4: crash-loop isolation"`)
already exercises exactly ONE Pollers-level exit-and-restart cycle and
explicitly, deliberately clears the fault right after — the breaker MUST
NOT open on that single event, or it would change AC4's own already-passing
behavior (Pollers restarting once, staying healthy afterward) into "Pollers
restarts once, then is immediately terminated by the breaker before its
own fault-cleared state has any chance to run" — a regression against
REQ-219, forbidden by this design's own §6 guarantee below.

The mechanism in §3.4 handles this correctly BECAUSE it requires TWO
`:DOWN` events with no successful settle in between, not one:

1. 1st `:DOWN` (Pollers exhausted its own 5/60 budget once, top level
   auto-restarts it) → breaker starts an observation timer, does NOT open.
2. If the fault was a SINGLE-SHOT (REQ-219 AC4's own scenario, and any
   ordinary transient burst): the re-monitored, freshly-restarted Pollers
   process keeps running — no 2nd `:DOWN` arrives before the observation
   timer's own deadline. The observation timer's `handle_info` clears the
   "watching for a 2nd `:DOWN`" flag and the breaker stays `:closed`,
   `consecutive_trips: 0` — REQ-219 AC4's exact scenario, unaffected.
3. If the fault is PERSISTENT (ISS-0451's scenario): per §1's own measured
   ~24-30ms full-cycle cadence, the 2nd `:DOWN` arrives well inside any
   reasonable observation-timer duration — set to **2 seconds** (comfortably
   longer than the top-level's own 5-second intensity window so a 2nd
   exhaustion that would ALSO threaten the top level's own budget is always
   caught before that budget could be threatened a 2nd time, and
   comfortably shorter than needing to wait out Pollers' full 60-second
   window, since — per §1 — a persistent fault's 2nd cycle arrives in
   milliseconds, not anywhere near 60s). This 2nd `:DOWN` is what actually
   opens the breaker.

**Arithmetic tying this back to the top level's own budget (§4):** in the
worst case this mechanism allows, the top level absorbs exactly 2 Pollers
exits (the 1st, which starts observation, and the 2nd, which trips the
breaker and is followed immediately by `terminate_child` — no 3rd automatic
restart is ever attempted, because `terminate_child` removes Pollers from
the top level's own restart-eligible state entirely, it is not a "crash"
event the top level's intensity counter even sees as a 3rd restart). **2
consumed restarts, inside the OTP-default 3-restart budget, with 1 full
restart of headroom remaining** — this is exactly why §4 only raises the
top level's own budget by a small, precisely-justified margin (to 5) rather
than needing a large one: the breaker itself already keeps the top level's
own consumption at 2, not the 4 ISSUE-FIXER's probe measured for the
NO-BREAKER case.

### 3.7 Why `terminate_child`, not merely "let the top level's own budget run out on its own after 2 attempts"

Calling `Supervisor.terminate_child(Letflow.Supervisor, Letflow.
Supervisor.Pollers)` immediately after the 2nd `:DOWN` (rather than passively
waiting for the top level to attempt and fail a 3rd automatic restart) is
what actually produces "stopped, not crash-looping" (ISS-0451's own
required end state) instead of merely "stopped once the top level's OWN
budget happens to run out too." Two independent reasons this matters, not
one: (a) it is what makes the top-level-intensity value chosen in §4
correct regardless of exactly how large or small it is — the breaker's
active intervention, not the top level's own arithmetic, is what stops the
retries, so §4's value is free to be chosen for its OWN, unrelated
defense-in-depth reason (§2's paragraph) without having to also be sized
to "survive exactly N breaker cycles"; (b) it produces a clean, deliberate
`:open` state the breaker's own `breaker_state/0` accessor (§3.5) can report
truthfully — a Pollers process left to exhaust the top level's OWN budget
would instead take the ENTIRE `:letflow` application down with it (back to
ISS-0451's original failure mode), since the top level itself has no
"stop trying, but stay up" state; only actively removing Pollers from
supervision before that budget is threatened again achieves "stay up AND
stop retrying."

## 4. Top-level `Letflow.Supervisor` intensity: `max_restarts: 5, max_seconds: 5` — defense-in-depth only, not the primary fix

**Exact value: raise `max_restarts` from the OTP default of 3 to 5;
`max_seconds` stays at the OTP default of 5** (i.e. `opts = [strategy:
:one_for_one, max_restarts: 5, max_seconds: 5, name: Letflow.Supervisor]` in
`Letflow.Application.start/2`).

**Arithmetic for why 5, not some other number, per ISS-0451's own AC2
requirement for concrete arithmetic (this paragraph is intentionally
narrower in scope than §1's "cannot survive indefinitely" finding — it is
not claiming to solve the persistent-fault case on its own, §3 does that;
this is the SEPARATE, smaller claim the raised value is actually sized
for):**

* §3.6 established the breaker's own worst-case top-level consumption for
  a PERSISTENT fault is exactly **2** restarts (1st `:DOWN` starts
  observation, 2nd `:DOWN` trips the breaker and `terminate_child` follows
  immediately — no further automatic restart is ever attempted after that).
* The OTP default (3) already covers 2 with 1 to spare — so the breaker
  ALONE, even at the bare default, would never itself exhaust the top
  level. The raise to 5 is NOT sized to cover the breaker's own worst
  case; it is sized for the residual, DIFFERENT risk §2 named explicitly:
  an UNRELATED transient restart (e.g. a single genuinely-transient
  Infrastructure or Http hiccup, of the ordinary kind the OTP default
  already tolerates today) landing in the SAME rolling 5-second window as
  the breaker's own 2-restart consumption from a persistent-Poller-fault
  episode. Without the raise, 2 (breaker) + 1 unrelated transient restart
  already equals the OTP default's ceiling of 3, leaving ZERO margin for a
  second unrelated coincidence in the same window — an operationally
  plausible coincidence (a bad tenant migration and, say, a brief Oidcc
  discovery-endpoint blip, both real, both already-tolerated-individually
  events) that would otherwise take the WHOLE application down for a
  reason having nothing to do with Pollers at all, which is precisely the
  failure mode REQ-219 exists to prevent.
* Raising to 5 (2 more than the default) restores that same 2-restart
  margin the OTP default originally provided for OTHER children, on top of
  the 2 the breaker's own mechanism now structurally consumes during a
  persistent-Poller-fault episode: `5 (new ceiling) - 2 (breaker's own
  worst-case consumption) = 3`, i.e. exactly the OTP default's own original
  margin, preserved rather than eroded by this design's addition of the
  breaker's own 2-restart cost. `max_seconds` is left at the OTP default
  (5s) unchanged, since nothing in this design's reasoning depends on a
  wider window — only on the count.
* This is a SMALL, JUSTIFIED, NON-ARBITRARY increase (2, not "raised until
  it works") — chosen specifically so it does not reopen the exact
  cross-child-budget-sharing risk §2 raised against a large top-level
  raise: a genuinely crash-looping Infrastructure or Http child (the
  scenario REQ-219 decision 3 deliberately wanted the OTP default to catch)
  still exhausts this only-slightly-larger 5-restart budget in the same
  order of magnitude of time the OTP default would have, and still brings
  the application down — decision 3's own stated correctness property
  ("a fault severe enough that taking the app down is still correct") is
  preserved, not weakened, by a 2-restart increase in a way it would not be
  by, say, raising to 50.

## 5. REQ-219 AC2/AC4 preservation — stated explicitly, both criteria

**AC2 (boot order: Infrastructure before Pollers, structural via list
order) — UNCHANGED, fully preserved.** `Letflow.Application.start/2`'s
children list gains exactly one new element
(`Letflow.Supervisor.PollersBreaker`), inserted AFTER `Letflow.
Supervisor.Pollers` and before `Letflow.Supervisor.Http`: `[Infrastructure,
Pollers, PollersBreaker, Http]`. Infrastructure is still listed first, still
starts (and, per `Supervisor.start_link/3`'s own sequential-startup
contract, still fully completes its own 17-child `init/1`) strictly before
Pollers starts — nothing about where the breaker sits in the list changes
that relative ordering. The breaker's own `init/1` (§3.4) does not depend
on Infrastructure's contents at all (it only calls
`Process.whereis(Letflow.Supervisor.Pollers)`, a name lookup independent of
list position beyond "Pollers must already be registered," which is
guaranteed by the breaker being listed strictly after Pollers). REQ-219's
own AC2 test (`pollers_test.exs`'s cold-boot ordering test, §4 of that
design) is untouched by this design and needs no modification — it asserts
a property entirely about Infrastructure-before-Pollers, which nothing here
touches.

**AC4 (single-crash isolation: Pollers exhausting its budget once must
still leave Infrastructure/Http alone) — UNCHANGED, fully preserved, and
explicitly analyzed in §3.6 above for why the breaker does not alter this
specific test's own already-passing behavior.** A single Pollers-budget
exhaustion event still: (a) leaves `Letflow.Repo` and `Letflow.
Supervisor.Infrastructure`'s pid untouched (nothing in this design's new
`PollersBreaker` process ever calls `terminate_child`/`restart_child`
against `Letflow.Supervisor.Infrastructure` or `Letflow.Supervisor.Http` —
its ENTIRE mechanism is scoped to monitoring and, only on a SECOND
consecutive exhaustion, terminating `Letflow.Supervisor.Pollers` alone);
(b) is restarted once by the top-level `Letflow.Supervisor`, exactly as
AC4's own text requires — the breaker's 1st-`:DOWN` handler does not
intervene in that restart at all, it only starts observing. REQ-219's own
AC4 test needs no modification for the SAME reason as AC2 above: it never
produces a 2nd `:DOWN` (its own fault is cleared immediately, per its
"GENUINE TIMING HAZARD" comment), so it never crosses this design's own
two-consecutive-`:DOWN` threshold (§3.6) and the breaker never leaves
`:closed` during that test.

## 6. What TEST-DESIGNER must write — exact test mechanism and observables

**New test file: `test/letflow/supervisor/pollers_breaker_test.exs`**
(mirrors `pollers_test.exs`'s own module/file placement convention).
`async: false` — mutates global `Application` config and the live
supervision tree, same class as `pollers_test.exs`'s own AC4 test, and must
not run concurrently with it (both terminate/restart the same named
`Letflow.Supervisor.Pollers` singleton) — ExUnit's own "async: false
modules run one at a time" guarantee (already leaned on by both
`pollers_test.exs` and `test/support/admission_test_helpers.ex`) is what
makes this safe without any new cross-file coordination.

### 6.1 Persistence mechanism: reuse `force_poller_crash` unchanged — do NOT clear it

The exact opposite of `pollers_test.exs`'s own AC4 test, and stated as
exactly that contrast so TEST-DESIGNER does not accidentally copy the
existing test's own clearing step: set `Application.put_env(:letflow,
:start_scheduler, true)` and `Application.put_env(:letflow,
:force_poller_crash, true)` (the SAME existing double-gated seam described
in `poller.ex`'s moduledoc §0 above — no new test hook, no new config key,
no new guard clause) and **never clear `:force_poller_crash` during the
test body** — this is what makes the fault PERSISTENT rather than
single-shot, the exact distinction ISS-0451 itself draws against REQ-219's
existing AC4 test. `on_exit/1` clears it at the very end, same as
`pollers_test.exs`'s own AC4 test's teardown, but nothing inside the test
body itself clears it early.

### 6.2 Test procedure

1. Capture `repo_pid_before = Process.whereis(Letflow.Repo)`,
   `top_level_pid_before = Process.whereis(Letflow.Supervisor)`,
   `infrastructure_pid_before = Process.whereis(Letflow.Supervisor.Infrastructure)`,
   `http_pid_before = Process.whereis(Letflow.Supervisor.Http)` (this last
   one may be `nil` under `config/test.exs`'s `start_http: false` — assert
   it stays exactly what it was before, `nil` or not, rather than assuming
   non-nil).
2. `Process.monitor(top_level_pid_before)` — the single most direct
   observable this test needs: if the top-level supervisor itself ever
   exits, THIS monitor fires a `:DOWN` for it, which is the exact failure
   ISS-0451 describes and which this regression test must prove does NOT
   happen. `Process.whereis(Letflow.Supervisor)` staying equal to
   `top_level_pid_before` throughout is a complementary, simpler check
   (used at the end, §6.2 step 6), but the monitor is the one that would
   catch a transient exit-and-immediate-respawn-under-a-different-pid
   scenario a single before/after `whereis` comparison at the very end
   could miss if timed unluckily — **both are specified, the monitor is
   the primary observable, the pid-equality check is the confirming one.**
3. Set both env overrides from §6.1. Restart `Letflow.Supervisor.Pollers`
   once via the SAME `terminate_child`/`restart_child` pair
   `pollers_test.exs`'s own AC4 test already uses (`restart_pollers!/0`'s
   shape, or an equivalent inline pair) — this is what makes `init/1`
   re-read the fresh env overrides and start the crash-looping poller.
4. Wait for the breaker to reach `:open` — poll (or better,
   `assert_receive`/monitor-based, matching this design's own §3.5
   accessor) `Letflow.Supervisor.PollersBreaker.breaker_state() == :open`,
   with a generous timeout (e.g. 5 seconds — comfortably longer than the
   two `:DOWN`-cycle mechanism needs, per §3.6's arithmetic, which predicts
   this happens in well under 1 second in practice, mirroring ISSUE-FIXER's
   own 96ms-for-4-cycles probe measurement).
5. **The core assertion, run WHILE the fault is STILL persistent (env
   overrides still set, breaker still `:open`, nothing cleared yet):**
   `assert Process.whereis(Letflow.Repo) == repo_pid_before`, `assert
   Process.whereis(Letflow.Supervisor.Infrastructure) ==
   infrastructure_pid_before`, `assert Process.whereis(Letflow.Supervisor.Http)
   == http_pid_before`, and — the ISS-0451-specific, REQ-219-AC4-test does
   NOT already have this one — `assert Process.whereis(Letflow.Supervisor)
   == top_level_pid_before` PLUS `refute_received {:DOWN, _ref, :process,
   ^top_level_pid_before, _reason}` (confirming the monitor from step 2
   never fired). This is the moment REQ-219's own AC4 test structurally
   cannot reach, because that test clears the fault before a 2nd exhaustion
   cycle could ever occur — this test's whole point is to prove the
   property holds even though (in fact BECAUSE) the fault is still active.
6. **Confirm the breaker is genuinely holding Pollers stopped, not merely
   "the test got lucky with timing":** `assert Supervisor.which_children(
   Letflow.Supervisor.Pollers) == []` OR `assert Process.whereis(Letflow.
   Supervisor.Pollers) == nil` (whichever the implementation actually
   produces once `terminate_child` has run and the top level's own
   `:one_for_one` restart of the TERMINATED — as opposed to crashed — child
   does not automatically re-fire, matching `Supervisor.terminate_child/2`'s
   own documented contract that a child stopped this way is not
   automatically restarted until `restart_child/2` is called; ELIXIR-DEV
   should confirm which of the two observables is accurate against the
   real implementation and TEST-DESIGNER should assert the one that
   matches, not both defensively).
7. **Optionally, and only if wall-clock budget allows (this is a SHOULD,
   not a MUST — flagged as an open question, §7 Q1):** advance past the
   1st backoff interval (§3.3, 1 second) and confirm the breaker attempts
   exactly one `:half_open` probe, observes the persistent fault has NOT
   cleared, and returns to `:open` with `consecutive_trips: 2` — exercising
   one full backoff cycle, not just the initial trip. `on_exit/1` clears
   `:force_poller_crash` and `:start_scheduler` (restored to original) and
   performs a final `restart_pollers!/0`-equivalent PLUS resets the breaker
   back to a clean `:closed` state for whichever test runs next — mirroring
   `pollers_test.exs`'s own AC4 teardown discipline exactly (leaving a
   stopped/misconfigured singleton for later tests is not acceptable, same
   rule, same file's own precedent).

### 6.3 Why this test needs no new production test-hook beyond `breaker_state/0`

`breaker_state/0` (§3.5) is the ONE new test-observability surface this
design introduces beyond what `pollers.ex`/`poller.ex` already have; it is
a plain public `GenServer.call`-backed query, not a double-gated seam like
`pollers_init_probe`/`force_poller_crash` — there is no production-safety
concern in exposing "what state is the breaker in" as an ordinary public
function (it reveals no secret, alters no behavior, and is generically
useful for future ops visibility per §3.5's own note), so it does NOT need
the compile-time `@..._test_hooks_enabled?` gate those two hooks require.
Flagged explicitly for REVIEWER: this is a deliberate, narrower-scoped
exception to the double-gate precedent, justified because (unlike
`pollers_init_probe`, which lets a test INJECT arbitrary behavior into a
production code path, or `force_poller_crash`, which lets a test FORCE a
crash) `breaker_state/0` only ever READS already-existing state and cannot
be used to alter production behavior from a runtime `Application.put_env/3`
call the way the other two structurally could if their compile-time gate
were ever accidentally left on.

## 7. Open questions

* **Q1 — whether §6.2 step 7 (exercising one full backoff cycle, not just
  the initial trip) is required or merely encouraged** is left to
  TEST-DESIGNER/TEST-DESIGN-VALIDATOR's judgment against ISS-0451's actual
  acceptance criteria (this handoff's own AC list requires the regression
  test to prove the top-level supervisor and Repo/Bandit survive a
  persistent fault — step 7 is a deeper mechanism-level exercise beyond
  that minimum bar, valuable but not stated as a hard AC). If wall-clock
  cost (waiting out even a 1-second interval inside `mix test`) is judged
  too high for routine CI runs, TEST-DESIGNER may scope it down to a
  smaller, test-only backoff schedule reachable via the SAME kind of
  double-gated test seam this codebase already uses elsewhere (a
  `pollers_breaker_backoff_intervals` test override, gated behind
  `@supervisor_test_hooks_enabled?`, mirroring `pollers_init_probe`'s own
  shape) — not specified further here since it carries no behavioral
  consequence for ISS-0451's own acceptance criteria, only for CI runtime,
  and is exactly the kind of test-mechanism judgment call
  `req219-supervision-layering.md`'s own Q2 precedent leaves open the same
  way.
* **Q2 — exact wording of `PollersBreaker`'s log messages (§3.5)** is left
  to ELIXIR-DEV's discretion, matching `req219-supervision-layering.md`'s
  own Q1 precedent (the forced-`raise` message string) — no acceptance
  criterion constrains the exact text, only that a transition is logged at
  `Logger.warning/1` with the trip count and next interval.
* **Q3 — whether `Letflow.Supervisor.PollersBreaker` itself needs its own
  restart-intensity consideration as a top-level child** (i.e., what
  happens if the BREAKER process itself crashes) is explicitly flagged as
  NOT resolved by this design and left for REVIEWER/ELIXIR-DEV: the
  breaker is an ordinary `GenServer` under the top-level `Letflow.Supervisor`'s
  own default `:one_for_one`/OTP-default intensity, so a breaker crash
  consumes ONE of the top level's own restart-budget slots (now 5, per
  §4) and restarts fresh in `:closed` state, re-establishing its monitor
  on whatever `Letflow.Supervisor.Pollers` pid is currently live. This is
  believed to be safe and self-healing (a fresh breaker in `:closed` simply
  resumes normal observation) but is not empirically verified in this
  design pass the way ISSUE-FIXER's probe verified §1's core cascade — a
  future review or a TEST-DESIGNER-authored test of "breaker itself
  crashes mid-observation" would close this gap if judged worth the
  additional test cost; ISS-0451's own acceptance criteria do not require
  it.
