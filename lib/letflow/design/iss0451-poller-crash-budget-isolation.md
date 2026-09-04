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

**REWORK ITERATION 1 (2026-09-04):** CODE-DESIGN-VALIDATOR FAILed the prior
version of this document
(`handoffs/WF03-ISS0451-20260904/step-02b-code-design-validator.json`,
`result.issues[0]`) because §4's margin arithmetic assumed, without proof,
that `PollersBreaker`'s `terminate_child` call always beat the top-level
`Letflow.Supervisor`'s own automatic restart-on-exit for the same child
crash. This revision closes that gap using the validator's named
approach (a): `Letflow.Supervisor.Pollers`' own child spec is now
`restart: :temporary` in `Letflow.Application`'s children list, so the top
level is structurally unable to auto-restart Pollers at all —
`PollersBreaker` becomes solely responsible for every restart of Pollers,
via explicit restart calls, removing the race by construction rather than
attempting to win it. See §3.4a (new), and the revised §3.6, §3.7, §4, §5,
and §6.2 step 6.

**REWORK ITERATION 2 (2026-09-04):** CODE-DESIGN-VALIDATOR FAILed
iteration 1 (`step-02b-code-design-validator.json`'s 4 BLOCKERs) because
§3.4a's children-list syntax, `{Letflow.Supervisor.Pollers, restart:
:temporary}`, does not actually apply `:temporary` — Elixir's `Supervisor`
treats a children-list 2-tuple `{module, arg}` as "call
`module.child_spec(arg)`," threading `arg` into the `start_link` call, not
into `Supervisor.child_spec/2`'s override keys. This revision (1) corrects
the syntax to `Supervisor.child_spec(Letflow.Supervisor.Pollers, restart:
:temporary)` used directly as the children-list entry, live-verified in
this rework to genuinely apply `:temporary`; and (2) discovers and fixes a
second, previously-unflagged defect surfaced only by that correction:
`PollersBreaker`'s planned `Supervisor.restart_child/2` call cannot
restart a `:temporary` child that has already exited once, because OTP
deletes a `:temporary` child's spec the instant it terminates —
`restart_child/2` returns `{:error, :not_found}` in that case. Every
restart call in this design (the breaker's `:closed`-branch and
`:half_open_probe` handlers, and the EXISTING `pollers_test.exs` test's own
`restart_pollers!/0` helper, which uses the same now-broken
`terminate_child`-then-`restart_child` pattern) is corrected to
`Supervisor.start_child/2` with the full child spec instead. See §3.4a
(both corrections), and the re-derived §3.6, §3.7, §4, §5, and §6.2 step 6
below.

**REWORK ITERATION 3 (2026-09-04, FINAL):** the design passed
CODE-DESIGN-VALIDATOR's gate clean at iteration 2, but ELIXIR-DEV's
implementation of iteration 2's §5 guidance for adapting the EXISTING
`pollers_test.exs` AC4 test surfaced a genuine, previously-unflagged race
(`handoffs/WF03-ISS0451-20260904/step-03-elixir-dev.json`
`result.issues[0]`, full empirical detail there): once `PollersBreaker` is
live, it and the test process both react to the SAME
`terminate_child`-induced `:DOWN` and race to restart Pollers, producing
either a `MatchError` (both call `start_child/2` for the same spec; the
loser gets `{:error, {:already_started, pid}}`) or a lost synchronous
window (Letflow.Scheduler.Poller's zero-delay first tick lets the
breaker-restarted Pollers crash-loop and trip the breaker to `:open`
before the test's own next line runs). **Root cause: the original AC4
test's structure — the test process itself performs ONE manual
synchronous restart, then a SEPARATE automatic top-level restart is what
gets exercised by the crash-loop — described the PRE-breaker world, where
the top level's automatic restart-on-exit was a distinct actor from
anything the test did. That structure no longer maps onto the real
system: `PollersBreaker` is the SOLE restart authority for Pollers from
the very first exit onward (§3.4a), so there is no longer a "test does one
restart, then a separate mechanism does the next" story to preserve —
attempting to keep that shape means fighting the one actor that now
legitimately owns every restart.** This revision replaces §5's guidance:
rather than adapting the test's old manual-restart-then-observe structure,
the existing AC4 test is redefined to drive the ENTIRE scenario as a
single breaker-mediated flow (ELIXIR-DEV's own named option 2, chosen over
their option 1 — see §5's new text for why), matching this design's own
§6.2 regression-test shape. No changes to `lib/letflow/supervisor/pollers_breaker.ex`
or `lib/letflow/application.ex` are required — both are confirmed correct
and complete as implemented; the fix is scoped entirely to the EXISTING
test's procedure. See the revised §5 below.

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

**Why NOT circuit-breaker-alone, i.e. why §4's top-level raise is kept even
though (REVISED, rework iteration 1 — see §3.4a/§4) Pollers' own exits now
consume ZERO top-level restart-budget slots, always:** the breaker (§3)
still has a startup transient — its own state machine needs to observe
Pollers' OWN budget being exhausted at least once (the `:closed → :open`
transition, §3.2) before it opens, and during that observation window (and
during every subsequent `:closed` window after a `:half_open` recovery) the
`PollersBreaker` process ITSELF is an ordinary `:permanent` top-level child
whose own restarts (Q3, §7) plus Infrastructure's and Http's do still draw
from the shared top-level budget, exactly as they would with no breaker at
all. Leaving the top level at the bare OTP default of 3 would provide zero
margin if, e.g., an unrelated transient Infrastructure or Http restart
happens to coincide with a `PollersBreaker` restart (Q3) in the same
5-second window — a coincidence unrelated to Pollers' own fault behavior
entirely, and not addressed by the breaker no matter how well it bounds
Pollers specifically. §4's 2-restart increase is sized exactly to cover
that unrelated-coincidence case, not to do any of the persistent-fault-
bounding work itself (that work is now done entirely, and provably, by
§3.4a's `restart: :temporary`).

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
`Supervisor.terminate_child/2`/`start_child/2` against the ALREADY-named
`Letflow.Supervisor.Pollers` and `Letflow.Supervisor` process names, which
resolve by name regardless of relative boot order once both exist -- see
§3.4a's "SECOND CORRECTION" for why `start_child/2`, not `restart_child/2`,
is the restart call this design actually specifies).

`Letflow.Application.start/2`'s children list becomes: `[Letflow.
Supervisor.Infrastructure, Letflow.Supervisor.Pollers, Letflow.
Supervisor.PollersBreaker, Letflow.Supervisor.Http]` — Http stays last,
unaffected; the breaker sits between Pollers and Http.

### 3.4a `restart: :temporary` on Pollers' own child spec — REVISED (rework iteration 2, syntax corrected + restart-call defect fixed), the mechanism that makes this design's central race structurally impossible rather than merely won

**This subsection replaces the prior iteration's implicit reliance on
"the breaker's `terminate_child` call happens before the top level's own
automatic restart-on-exit reacts to the same child exit."**
CODE-DESIGN-VALIDATOR correctly identified
(`handoffs/WF03-ISS0451-20260904/step-02b-code-design-validator.json`,
`result.issues[0]`) that the prior version never proved that ordering: the
top-level `Letflow.Supervisor`'s own automatic restart reacts to a child's
EXIT signal directly, in-process, with no extra message hop, while
`PollersBreaker`'s intervention required its own `Process.monitor` `:DOWN`
message to be delivered to its mailbox, `handle_info` to be scheduled and
run, and then a synchronous `Supervisor.terminate_child/2` round trip to
complete -- a strictly LONGER chain reacting to the exact same exit event,
with nothing in OTP's documented `Supervisor`/`GenServer` contracts
guaranteeing the longer chain wins. That gap is real, and no OTP contract
proving the opposite was found on review, so this design does not attempt
to re-litigate the ordering (the validator named this as one of exactly
two acceptable fixes, and named it the safer, verifiable one).

**REWORK ITERATION 2 (2026-09-04):** CODE-DESIGN-VALIDATOR FAILed the
iteration-1 revision of this subsection
(`handoffs/WF03-ISS0451-20260904/step-02b-code-design-validator.json`,
`result.issues`, all 4 BLOCKERs) because the children-list snippet below
used the WRONG syntax to apply `restart: :temporary`. The concept (make
Pollers' child spec `:temporary` so the top level structurally cannot
auto-restart it) was independently confirmed correct by the validator;
only the syntax was wrong. This revision fixes the syntax and re-derives
every downstream section that depended on it (§3.6, §3.7, §4, §5, §6.2
step 6) against the corrected form.

**The fix: `Letflow.Application.start/2`'s children list gives Pollers'
OWN child spec `restart: :temporary` explicitly** (Elixir's `Supervisor`
child-spec `:restart` option -- one of `:permanent` (the implicit default
every child in this list currently uses, including Pollers itself today),
`:transient`, or `:temporary`; see the "Restart values" section of the
`Supervisor` module docs). `:temporary` means: **a `:temporary` child is
never restarted by its supervisor, regardless of exit reason** -- not on a
normal exit, not on an abnormal exit, not once, not ever. This is
`Supervisor`'s own documented, unconditional contract for that restart
type, decided statically from the child spec at the moment it is
registered, not evaluated at exit time against any runtime condition or
race. There is therefore no race left to win: **the top-level `Letflow.
Supervisor` structurally never attempts to restart `Letflow.
Supervisor.Pollers` automatically, under any circumstance, ever again.**

**CORRECTED SYNTAX (rework iteration 2):** the children-list ENTRY ITSELF
must be the RESULT of calling `Supervisor.child_spec/2` with the override
keyword list -- not a bare `{module, arg}` 2-tuple. Elixir's `Supervisor`
gives those two syntactic forms genuinely different meanings, confirmed
here both by reading `lib/elixir/lib/supervisor.ex`'s own `init_child/1`
(child-spec normalization for children-list entries) and `child_spec/2`
(the actual override-applying function), and by a live probe run against
this project's pinned Elixir 1.20.3 during this rework:

```
defmodule ProbeCD.Worker do
  use GenServer
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
  def init(arg), do: {:ok, arg}
end

Supervisor.child_spec({ProbeCD.Worker, restart: :temporary}, [])
# => %{id: ProbeCD.Worker, start: {ProbeCD.Worker, :start_link, [[restart: :temporary]]}}
#    NO :restart key at all -- defaults to :permanent. `restart: :temporary`
#    was silently threaded into start_link's init arg instead.

Supervisor.child_spec(ProbeCD.Worker, restart: :temporary)
# => %{id: ProbeCD.Worker, restart: :temporary, start: {ProbeCD.Worker, :start_link, [[]]}}
#    :restart correctly set to :temporary.
```

A children-list 2-tuple `{module, arg}` entry is normalized by
`Supervisor.init/2` as "call `module.child_spec(arg)`" -- `arg` becomes
the `start_link` argument, exactly as `Letflow.Supervisor.Pollers.child_spec/1`
(generated by `use Supervisor`) would receive it, NOT as override keys
passed to `Supervisor.child_spec/2`. Only the 2-arg call form,
`Supervisor.child_spec(module_or_spec, overrides)`, applies `overrides` as
child-spec overrides. The children list becomes:

```
children = [
  Letflow.Supervisor.Infrastructure,
  Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary),
  Letflow.Supervisor.PollersBreaker,
  Letflow.Supervisor.Http
]
```

(No change to `Letflow.Supervisor.Pollers.child_spec/1` itself, which
still comes from `use Supervisor`'s own generated default -- the
override happens entirely at the call site in
`Letflow.Application.start/2`, the same place REQ-219's own boot-order
guarantee already lives, so this remains a small, structurally-scoped,
one-line-of-intent change; only the exact syntax of that one line is
corrected from the prior iteration.)

**SECOND CORRECTION discovered while re-deriving this rework's downstream
sections (not flagged by either prior gate, since neither prior iteration
had a genuinely-`:temporary` child spec to test the restart mechanism
against): `PollersBreaker` cannot use `Supervisor.restart_child/2` to bring
Pollers back up after it has already exited once.** Live-verified during
this rework (Elixir 1.20.3, same probe methodology as above): once a
`:temporary` child terminates, OTP deletes its child spec from the
supervisor entirely -- this is the same "automatically deleted when the
child terminates" contract §3.4a's original text already cites from
`Supervisor`'s own docs, but this rework is the first pass to check its
consequence for the RESTART call, not just the "does the top level
auto-restart" question. `Supervisor.restart_child(Letflow.Supervisor,
Letflow.Supervisor.Pollers)` against an already-exited `:temporary` child
returns `{:error, :not_found}` and does nothing -- confirmed live:

```
# after killing a :temporary child once (spec already deleted):
Supervisor.restart_child(Top, Crashy)
# => {:error, :not_found}   -- NOT a restart; the spec is simply gone.

# the working replacement, re-supplying the full spec each time:
Supervisor.start_child(Top, Supervisor.child_spec(Crashy, restart: :temporary))
# => {:ok, #PID<...>}   -- verified to work identically across repeated
#    kill/restart cycles, and to return {:error, {:already_started, pid}}
#    (a safe, informative no-op) if called while the child is still alive
#    -- relevant to the defensive :open-state no-op branch below.
```

**Every mechanism reference below that names `Supervisor.restart_child/2`
as the call `PollersBreaker` issues to bring Pollers back up is corrected
by this rework to `Supervisor.start_child(Letflow.Supervisor,
Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary))`
instead** -- same call sites, same triggering events (1st `:DOWN` in
`:closed`, `:half_open_probe` firing), same non-consequence for the
overall design (this is still an explicit, breaker-issued call that never
touches the top level's own automatic-restart intensity counter, per the
live verification in §3.6 below) -- only the specific OTP function name
changes, because `restart_child/2` is documented for restarting a child
whose SPEC still exists but whose PROCESS has stopped (e.g. a `:permanent`
or `:transient` child mid-shutdown, or one explicitly stopped via
`terminate_child/2`), which is not this design's situation: a `:temporary`
child's spec is gone the moment it exits, so only `start_child/2` with the
full spec can re-establish it.

**Consequence, stated precisely because it changes the mechanism from the
prior iteration, not just patches it: `PollersBreaker` becomes the SOLE
mechanism by which `Letflow.Supervisor.Pollers` is ever restarted, full
stop -- sole from the very FIRST exit onward, not merely "sole after the
2nd exit" as the prior iteration modeled.** This means the single-shot
case REQ-219's existing AC4 test already exercises (one Pollers exit, then
the fault clears) now ALSO depends on `PollersBreaker` performing an
explicit restart -- the top level no longer does this automatically for
ANY Pollers exit, including the very first one. The breaker's own
`:closed`-state handling (§3.4 below) reflects this: it must call
`Supervisor.start_child/2` with the full `restart: :temporary`-carrying
spec (§3.4a's "SECOND CORRECTION" -- not `restart_child/2`) on the FIRST
`:DOWN`, not merely observe it, and §4 below re-derives the top-level
margin arithmetic under the new, now-airtight invariant that Pollers' own
exits consume ZERO top-level
restart-budget slots, ever -- not "usually 2, hopefully never 3" as
before.

**Why this does not merely relocate the race to a different pair of
processes, and is not merely "very likely" safe:** `PollersBreaker` still
learns of a Pollers exit via the same `Process.monitor`/`:DOWN` message
path as the prior iteration -- but now there is nothing racing against it.
The top-level `Letflow.Supervisor` has no restart-on-exit code path to
invoke for a `:temporary` child at all; per `Supervisor`'s own documented
contract, that decision not to restart is made from the child spec's
static `:restart` value, independent of scheduling order, message
latency, or which process reacts first. There is no second actor whose
speed matters, because there is no second actor with a restart action to
take. `PollersBreaker`'s own `handle_info({:DOWN, ...})` handler runs
whenever the BEAM schedules it -- sooner or later changes only how long
Pollers is briefly absent from supervision (itself an accepted, visible
`:open`-state or restart-in-flight property of this design, §3.2, not a
hazard), never whether the top level might still "win" a restart race,
because the top level has no restart move left to make.

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
  every time `Letflow.Supervisor.Pollers` exits, for ANY reason. **REVISED
  (rework iteration 1): because §3.4a now gives Pollers' child spec
  `restart: :temporary`, the top level NEVER restarts Pollers
  automatically -- not on the 1st exit, not ever -- so this handler is now
  responsible for issuing every restart itself, including the one REQ-219's
  existing AC4 test already exercises (previously supplied for free by the
  top level's own default `:permanent` restart).** On EACH such `:DOWN`:
  * If current state is `:closed`: this is either the FIRST observed exit,
    or a subsequent exit that arrived after a prior observation window
    already cleared (§3.6). Either way: immediately call
    `Supervisor.start_child(Letflow.Supervisor, Supervisor.child_spec(
    Letflow.Supervisor.Pollers, restart: :temporary))` -- **corrected
    (rework iteration 2, §3.4a's "SECOND CORRECTION"): NOT
    `restart_child/2`.** REQ-219's existing AC4 test's own
    `restart_pollers!/0` helper (`terminate_child/2` then `restart_child/2`)
    is NOT the same action any more either, and itself needs the identical
    fix -- see §5's revised text below, since that helper's own
    `restart_child/2` call breaks the exact same way once Pollers' spec is
    `:temporary` (confirmed live during this rework: `terminate_child/2` on
    a `:temporary` child also deletes its spec immediately, so ANY
    subsequent `restart_child/2` -- the breaker's or the test helper's --
    returns `{:error, :not_found}`, never a fresh pid). Re-monitor the
    resulting new pid, and start a short observation timer (§3.6). Do NOT
    open the breaker yet on a single event -- a single Pollers exit,
    immediately restarted, is exactly the ALREADY-ACCEPTED, ALREADY-TESTED
    (REQ-219 AC4) case, now served by an explicit `start_child/2` call
    instead of an implicit top-level one; the observable end state (Pollers
    restarted once, running again) is unchanged from today, only the
    mechanism producing it moved from "top level's own default" to
    "breaker's explicit call." If a SECOND `:DOWN` for the re-monitored pid
    arrives before that observation timer fires, THAT is what trips
    `:closed -> :open` (transition to `:open`, `consecutive_trips: 1` -- no
    further `start_child/2` call this time; §3.3's `:open` state means
    Pollers stays down, unrestarted, for the backoff interval),
    `Process.send_after(self(), :half_open_probe, 1_000)` (§3.3's 1st
    interval).
  * If current state is `:open`: should not observe a `:DOWN` here (no
    restart was issued while `:open`, so no live Pollers process exists to
    exit) -- a defensive no-op / log, not a crash.
  * If current state is `:half_open`: the probe restart (§3.2/§3.3's
    `:half_open_probe` handler below) itself crash-looped and re-exhausted
    -- trip back to `:open`, `consecutive_trips: consecutive_trips + 1`,
    schedule the NEXT backoff interval per §3.3's table indexed by the new
    `consecutive_trips` value. No `start_child/2` call here either (same
    reasoning as the `:closed -> :open` transition above) -- the NEXT
    restart attempt happens only when the next `:half_open_probe` fires.
  * **What `Supervisor.terminate_child/2` is for now, since restart
    responsibility moved to the `:DOWN` handler above:** with `:temporary`,
    a crash-looping Pollers instance exits ON ITS OWN once its own
    `max_restarts: 5, max_seconds: 60` budget is exhausted (§3.2's
    `:closed` state, unchanged) -- no explicit `terminate_child/2` call is
    needed to STOP it, because a `:temporary` child that exits is already
    gone from the top level's restart-eligible set structurally; the "no
    3rd automatic restart" property §3.7 (previous iteration) had to argue
    for is now true by construction for every exit, not just the 2nd. The
    breaker's own `terminate_child/2` calls are reserved for one case only:
    forcing a KNOWN-still-alive Pollers process down (e.g. if a future
    operational need required stopping Pollers outside its own crash-loop
    path) -- not exercised by this design's own state machine, since every
    transition here reacts to an ALREADY-exited Pollers via `:DOWN`, never
    to a still-running one.
* `handle_info(:half_open_probe, state)` (fires when a `:open`-state backoff
  timer elapses): transition to `:half_open`,
  `Supervisor.start_child(Letflow.Supervisor, Supervisor.child_spec(
  Letflow.Supervisor.Pollers, restart: :temporary))` (corrected, rework
  iteration 2 -- same `start_child/2` fix as the `:closed`-branch call
  above, not `restart_child/2`), re-monitor the resulting pid, start a
  fixed observation window (§3.6) to decide success vs. re-trip.
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

### 3.6 REVISED (rework iteration 2, re-derived against the corrected `start_child/2` mechanism): why the two-`:DOWN`-events-vs-one-observation-timer mechanism still does not double-count REQ-219's own AC4 single-shot case, now under explicit-restart semantics

**This is the one subtlety load-bearing enough to spell out arithmetically,
since a sloppy version of this mechanism could accidentally trip the
breaker on ordinary, already-tested single-shot behavior.** REQ-219's own
AC4 test (`pollers_test.exs`, `describe "AC4: crash-loop isolation"`)
already exercises exactly ONE Pollers-level exit-and-restart cycle and
explicitly, deliberately clears the fault right after — the breaker MUST
NOT open on that single event, or it would change AC4's own already-passing
behavior (Pollers restarting once, staying healthy afterward) into "Pollers
never comes back because the breaker treats one exit as enough to open" — a
regression against REQ-219, forbidden by this design's own §6 guarantee
below. This subsection's role changed under §3.4a's revision: it is no
longer about winning a race against the top level's own automatic restart
(§3.4a already made that race impossible by construction), it is purely
about the breaker's OWN internal one-exit-vs-two-exits distinction — a
question entirely internal to `PollersBreaker`'s own state machine now,
with no other actor involved.

The mechanism in §3.4 handles this correctly BECAUSE it requires TWO
`:DOWN` events with no successful settle in between, not one:

1. 1st `:DOWN` (Pollers exhausted its own 5/60 budget once) →
   `PollersBreaker` itself calls `Supervisor.start_child/2` with the full,
   `restart: :temporary`-carrying spec (§3.4a's "SECOND CORRECTION" —
   `start_child/2`, not `restart_child/2`, since a `:temporary` child's
   spec is deleted the instant it exits and `restart_child/2` would return
   `{:error, :not_found}` — verified live during this rework), then starts
   an observation timer. Does NOT open.
2. If the fault was a SINGLE-SHOT (REQ-219 AC4's own scenario, and any
   ordinary transient burst): the re-monitored, freshly-restarted Pollers
   process keeps running — no 2nd `:DOWN` arrives before the observation
   timer's own deadline. The observation timer's `handle_info` clears the
   "watching for a 2nd `:DOWN`" flag and the breaker stays `:closed`,
   `consecutive_trips: 0` — REQ-219 AC4's exact scenario, and its
   Pollers-restarted-once end state, both reproduced, just via the
   breaker's explicit `start_child/2` call instead of the top level's
   former implicit one (§5 below confirms the existing AC4 test needs a
   corresponding update, not a behavior change).
3. If the fault is PERSISTENT (ISS-0451's scenario): per §1's own measured
   ~24-30ms full-cycle cadence, the 2nd `:DOWN` arrives well inside any
   reasonable observation-timer duration — set to **2 seconds** (comfortably
   longer than the empirically-measured cadence so a genuinely persistent
   fault is reliably caught on its 2nd cycle, and comfortably shorter than
   needing to wait out Pollers' full 60-second window). This 2nd `:DOWN` is
   what actually opens the breaker — no further `start_child/2` call is
   issued for it (§3.4's `:closed`-branch text above); Pollers simply stays
   down, unrestarted, until the `:half_open_probe` fires.

**Arithmetic tying this back to the top level's own budget (§4) — REVISED
(rework iteration 2), re-verified live against the corrected mechanism, not
merely re-asserted:** because §3.4a (corrected form) makes Pollers' child
spec genuinely `restart: :temporary` — confirmed by this rework's own live
probe (§3.4a: a `:temporary` child killed once never comes back via the
top level, `which_children` on the parent goes to `[]`, and the parent
supervisor itself stays alive/untouched) — the top-level `Letflow.
Supervisor` NEVER attempts an automatic restart of Pollers for ANY of
these `:DOWN` events — not the 1st, not the 2nd, not any subsequent one
across any number of breaker trip/backoff cycles. **Every restart of
Pollers, across the mechanism described in this section, is an explicit
`Supervisor.start_child/2` call issued by `PollersBreaker` itself, never
an automatic action by the top-level Supervisor.** A further live check
run during this rework confirms this call genuinely does not touch the
top level's own intensity counter: 10 repeated kill/`start_child`-restart
cycles against a `max_restarts: 1` top-level supervisor left the top
level alive throughout (§3.4a's "SECOND CORRECTION" probe) — if
`start_child/2`-issued restarts consumed the top level's own budget the
same way automatic restarts do, that probe would have exited the top
level well before 10 cycles under a budget of 1. Consequently, the
top-level `Letflow.Supervisor`'s own restart-intensity counter is
incremented by Pollers-related activity **exactly zero times, under any
fault pattern, persistent or otherwise, structurally and unconditionally**
— not "usually 2, hopefully never 3" as the iteration-0 unproven race
required, but a fixed, provable **0**, now confirmed against the corrected
`start_child/2`-based mechanism rather than assumed to carry over from the
`restart_child/2`-based description this rework replaced. This is what
makes §4's own margin arithmetic below simple rather than delicately
balanced against a race outcome.

### 3.7 What replaces `terminate_child`-as-race-winner: nothing needs to, because there is no race to win

The prior iteration's §3.7 argued that calling `Supervisor.terminate_child/2`
immediately after the 2nd `:DOWN` was necessary to preempt the top level's
own automatic restart before it could fire a 3rd time — an argument that
CODE-DESIGN-VALIDATOR correctly identified as unproven (no ordering
guarantee that the preemption would win). **Under §3.4a's `restart:
:temporary` revision (corrected syntax), this entire question is moot: the
top level has no automatic-restart action to preempt in the first place**,
for the 1st, 2nd, or any exit — re-verified live in this rework (§3.4a),
not merely re-asserted from the prior iteration's text. "Stopped, not
crash-looping" (ISS-0451's own required end state) is produced simply by
`PollersBreaker` declining to call `start_child/2` again while in `:open`
state (§3.4's `:closed -> :open` transition text) — there is no longer a
competing top-level restart path that must be beaten to a synchronous
call; there is only the breaker's own single, uncontested decision of
whether to call `start_child/2` or not.
This is a strictly simpler, and now fully verifiable-from-the-child-spec-
alone, mechanism than the prior iteration's.

## 4. Top-level `Letflow.Supervisor` intensity: `max_restarts: 5, max_seconds: 5` — REVISED margin arithmetic (rework iteration 2, re-verified against the corrected `Supervisor.child_spec/2` form), now under a proven zero-Pollers-consumption invariant

**Exact value, unchanged from the prior iteration: raise `max_restarts`
from the OTP default of 3 to 5; `max_seconds` stays at the OTP default of
5** (i.e. `opts = [strategy: :one_for_one, max_restarts: 5, max_seconds: 5,
name: Letflow.Supervisor]` in `Letflow.Application.start/2`). The VALUE is
the same 5; the ARITHMETIC justifying it is re-derived below because the
prior iteration's justification depended on the now-removed "breaker
consumes 2 of the top level's restarts" premise, which no longer applies.

**Arithmetic for why 5, not some other number, per ISS-0451's own AC2
requirement for concrete arithmetic:**

* §3.4a/§3.6 established, by construction (not by racing), that Pollers'
  `restart: :temporary` child spec means the top-level `Letflow.Supervisor`
  NEVER restarts `Letflow.Supervisor.Pollers` automatically, for any exit,
  under any fault pattern. **Pollers-related activity consumes exactly 0
  of the top level's own `max_restarts` budget, unconditionally.** This
  holds whether the fault is single-shot, persistent, or the breaker is
  mid-way through any number of `:open`/`:half_open` backoff cycles (§3.3)
  — every one of those cycles' restarts is `PollersBreaker`'s own explicit
  `Supervisor.start_child/2` call (§3.4a's "SECOND CORRECTION" —
  `start_child/2`, not `restart_child/2`), which does not touch or
  increment the TOP level's intensity counter at all (that counter only
  counts the top level's OWN automatic restarts of its OWN children; a
  `:temporary` child that is manually re-added via `start_child/2` by a
  THIRD process is invisible to it, per `Supervisor`'s documented
  intensity-tracking scope, which is per-supervisor and reacts only to
  that supervisor's own automatic restart decisions — confirmed live
  during this rework: 10 repeated kill/`start_child`-restart cycles left a
  `max_restarts: 1` top-level supervisor alive throughout, §3.6 above).
* This means the top-level's own `max_restarts`/`max_seconds` budget is now
  available ENTIRELY for its two remaining `:permanent` children,
  Infrastructure and Http (plus `PollersBreaker` itself, also
  `:permanent` by default — see Q3 in §7, unchanged from the prior
  iteration, now scoped to a budget that is no longer shared with Pollers
  activity at all). The raise from 3 to 5 is therefore no longer sized
  against any breaker-consumption figure (there is none) — it is sized,
  exactly as the prior iteration's residual paragraph already argued, for
  tolerating more than one UNRELATED transient restart among
  Infrastructure/Http/PollersBreaker landing in the same rolling window,
  a margin that is now MORE conservative than strictly required (the prior
  iteration needed the +2 to offset the breaker's assumed 2-restart
  consumption; this iteration gets that same +2 as pure extra headroom,
  since actual Pollers-attributable consumption is now 0, not 2).
* **Restated as the exact inequality ISS-0451's AC2 asks for:** for the
  top level to survive a persistent Poller fault indefinitely, it is
  sufficient that Pollers-attributable restarts-of-Pollers-by-the-top-level
  stay at 0 for the ENTIRE duration of the fault, for any duration,
  including forever. §3.4a's `restart: :temporary` proves exactly that:
  `0 <= max_restarts` holds for every value of `max_restarts >= 0`,
  independent of how long the fault persists, how many breaker trip cycles
  occur, or how fast the fault's own internal cadence is (§1's ~24-30ms
  figure, which mattered enormously to the prior iteration's arithmetic,
  is now irrelevant to the TOP level's own survival — it only affects how
  quickly `PollersBreaker` itself reaches `:open`, an internal breaker-only
  concern). This is the "tolerates a persistent fault indefinitely" bar
  ISS-0451/AC2 sets, met exactly, not merely approximated or bounded to a
  large-but-finite number of cycles.
* The raise to 5 (rather than leaving the OTP default at 3) is kept for
  the SAME, now purely orthogonal, defense-in-depth reason §2's rejected-
  alternatives paragraph already named: covering a coincidence of multiple
  independent UNRELATED transient restarts (Infrastructure, Http, or
  `PollersBreaker` itself, per Q3) landing in the same 5-second window —
  `5 (new ceiling) - 0 (Pollers' now-proven zero consumption) = 5` full
  restarts of headroom for those three children combined, one more than
  the OTP default's original 3 (which had to cover the same three children
  in today's, pre-this-design, world), a strictly SAFER position than
  either the prior iteration (margin of 3) or today's unmodified default
  (margin of 3), not merely an equally-safe one.
* This remains a SMALL, JUSTIFIED, NON-ARBITRARY increase (2, not "raised
  until it works") for the identical reason the prior iteration gave and
  which is unaffected by this rework: a genuinely crash-looping
  Infrastructure or Http child (the scenario REQ-219 decision 3
  deliberately wanted the OTP default to catch) still exhausts this
  only-slightly-larger 5-restart budget in the same order of magnitude of
  time the OTP default would have, and still brings the application down —
  decision 3's own stated correctness property ("a fault severe enough
  that taking the app down is still correct") is preserved, not weakened.
  `max_seconds` is left at the OTP default (5s) unchanged, since nothing in
  this design's reasoning depends on a wider window.

## 5. REQ-219 AC2/AC4 preservation — stated explicitly, both criteria — REVISED (rework iteration 2, re-derived against the corrected mechanism, plus a newly-discovered `restart_pollers!/0` consequence) for the `restart: :temporary` mechanism change

**AC2 (boot order: Infrastructure before Pollers, structural via list
order) — UNCHANGED, fully preserved, and unaffected by §3.4a's revision.**
`Letflow.Application.start/2`'s children list gains exactly one new element
(`Letflow.Supervisor.PollersBreaker`) and one modified child-spec option on
the existing Pollers entry (`restart: :temporary`, §3.4a's corrected
`Supervisor.child_spec/2` form) — neither changes LIST ORDER:
`[Infrastructure, Supervisor.child_spec(Pollers, restart: :temporary),
PollersBreaker, Http]`. Infrastructure is still listed first, still starts
(and, per `Supervisor.start_link/3`'s own sequential-startup contract,
still fully completes its own 17-child `init/1`) strictly before Pollers
starts — nothing about the breaker's insertion or Pollers' `:restart`
option changes that relative ordering; `:restart` governs ONLY what
happens when a child later EXITS, never when or whether it starts, so it
has zero effect on boot-order sequencing. The breaker's own `init/1` (§3.4)
does not depend on Infrastructure's contents at all (it only calls
`Process.whereis(Letflow.Supervisor.Pollers)`, a name lookup independent of
list position beyond "Pollers must already be registered," which is
guaranteed by the breaker being listed strictly after Pollers). REQ-219's
own AC2 test (`pollers_test.exs`'s cold-boot ordering test) is untouched by
this design and needs no modification — it asserts a property entirely
about Infrastructure-before-Pollers, which nothing here touches.

**AC4 (single-crash isolation: Pollers exhausting its budget once must
still leave Infrastructure/Http alone) — the OBSERVABLE PROPERTY is
UNCHANGED and fully preserved; the MECHANISM producing it changes, and
this design states that change explicitly rather than leaving it implicit
(per CODE-DESIGN-VALIDATOR's own "unambiguous enough for ELIXIR-DEV to
implement" bar). REVISED (rework iteration 2): re-verified against the
corrected `start_child/2`-based mechanism, and one further, previously
unflagged consequence for the EXISTING test's own helper function is
added below.** A single Pollers-budget exhaustion event still: (a) leaves
`Letflow.Repo` and `Letflow.Supervisor.Infrastructure`'s pid untouched
(nothing in this design's `PollersBreaker` process ever calls
`terminate_child`/`start_child` against `Letflow.Supervisor.Infrastructure`
or `Letflow.Supervisor.Http` — its ENTIRE mechanism is scoped to
monitoring and restarting `Letflow.Supervisor.Pollers` alone); (b) IS still
restarted once, but **now via `PollersBreaker`'s own explicit
`Supervisor.start_child/2` call on the 1st `:DOWN` (§3.4's revised
`:closed`-branch text, corrected to `start_child/2` in this rework — see
§3.4a's "SECOND CORRECTION"), not via the top-level `Letflow.Supervisor`'s
former automatic restart** — that automatic path no longer exists at all
once Pollers' child spec is genuinely `restart: :temporary` (§3.4a's
corrected `Supervisor.child_spec/2` form, live-verified in this rework).
The END STATE AC4 requires (Pollers restarted once, running again,
Infrastructure/Http/Repo untouched) is unchanged; ONLY the mechanism
producing the restart moved from "top level's implicit default" to
"breaker's explicit call."

**Consequence this design states explicitly, since it is a REAL change to
existing, already-passing test code, not merely new test code alongside
it — RE-DERIVED, not re-asserted, in this rework against the corrected
`:temporary` mechanism (§3.4a):** REQ-219's own existing AC4 test
(`test/letflow/supervisor/pollers_test.exs`, lines 152-161 as read for this
design) currently asserts, in its own words, "The top-level
`Letflow.Supervisor` did restart the exited layer, not merely leave it
down" and polls `Process.whereis(Letflow.Supervisor.Pollers)` for a NEW pid
appearing WITHOUT the test itself calling `restart_child/2` for that
occurrence. **Once Pollers' child spec is genuinely `restart: :temporary`
(confirmed live in this rework — see §3.4a's probe, which shows the top
level does NOT bring the child back), that specific assertion's premise
(the top level restarts it automatically) is no longer true, and this
existing test will fail as written** unless updated.

**REWORK ITERATION 3 — the guidance below REPLACES iteration 2's own text
(which is superseded, not merely amended, because iteration 2's approach —
"adapt the test's existing manual-restart-then-observe structure to expect
the breaker instead of the top level" — was tried literally by ELIXIR-DEV
and does not produce a deterministic test; see
`handoffs/WF03-ISS0451-20260904/step-03-elixir-dev.json` `result.issues[0]`
for the full empirical detail, summarized here).**

**Why iteration 2's approach cannot be patched, only replaced.** The
original (pre-ISS-0451) AC4 test's structure has the TEST PROCESS itself
perform ONE manual, synchronous restart (`terminate_child` +
`restart_child`, "so `init/1` re-reads the env overrides"), and then
separately exercises the ACTUAL property under test: that supervisor's own
SUBSEQUENT, AUTOMATIC crash-loop-triggered exit only touches
`Letflow.Supervisor.Pollers`, not Infrastructure/Http/Repo. That shape —
"the test does one restart itself, a genuinely separate mechanism does the
next one" — was a true description of the PRE-breaker world: the test
process and the top-level `Letflow.Supervisor`'s own automatic
restart-on-exit were two distinct, non-competing actors, because the test
process's restart happened first and completed synchronously before any
crash-loop began. **Once `PollersBreaker` exists, that shape is no longer
true of the real system: `PollersBreaker` is the SOLE restart authority
for `Letflow.Supervisor.Pollers` from the very first exit onward (§3.4a),
including the exact "first restart after `terminate_child`" moment the
test's own manual step targets.** There is no longer a first restart that
belongs to the test process and a separate later one that belongs to
"the automatic mechanism" — both belong to the breaker now, and a test
that tries to perform one of them itself is competing with the one actor
that legitimately owns all of them. This is a structural mismatch, not a
timing bug to smooth over: ELIXIR-DEV's two empirically-reproduced failure
modes (the `{:already_started, pid}` race and the lost synchronous window
before the breaker's own 2-second observation timer) are two different
SYMPTOMS of this one root cause, and no amount of retry/backoff/wait
tuning in the test removes the root cause, only relocates the symptom.

**Chosen fix: redefine the AC4 test's own procedure to stop performing a
manual pre-restart at all, and instead drive the entire scenario as a
single breaker-mediated flow — matching the shape of this design's own new
regression test (§6.2).** This is ELIXIR-DEV's own named option 2. Chosen
over their option 1 (a test-only synchronization hook added to
`PollersBreaker`, double-gated like `pollers_init_probe`/
`force_poller_crash`) for two reasons: (a) option 1 would still be
building a mechanism whose entire purpose is to make the breaker
temporarily step aside so the test can perform a restart that, in the real
system, the breaker always performs itself — the resulting test would
verify a synthetic path that never occurs outside the test, not the actual
always-on breaker-mediated path; (b) option 1 requires new production
code in `pollers_breaker.ex` (a coordination hook + call sites to check
it) to preserve a test structure that stopped describing the real
mechanism the moment the breaker went in, whereas option 2 requires zero
production-code changes and directly exercises the real, always-on path.
**Explicit confirmation, since the rework task requires it: this fix
requires NO addition to `lib/letflow/supervisor/pollers_breaker.ex`'s
design or to `lib/letflow/application.ex`. Both remain exactly as
iteration 2 specified and as ELIXIR-DEV already implemented them — the
gap was entirely in how the EXISTING test's procedure was adapted, not in
the production mechanism.**

**Revised AC4 test procedure (replaces the existing test body's manual-
restart step and the assertions that followed it; the test's PURPOSE —
prove a Pollers crash-loop restarts only Pollers, leaving
Repo/Infrastructure/Http untouched, and that Pollers itself comes back —
is unchanged, only the mechanics of driving and observing it change):**

1. Capture `repo_pid_before`, `infrastructure_pid_before`, and (unchanged
   from the current test) `pollers_pid_before = Process.whereis(Letflow.Supervisor.Pollers)`.
2. Set `Application.put_env(:letflow, :start_scheduler, true)` and
   `Application.put_env(:letflow, :force_poller_crash, true)` — unchanged.
3. **Single trigger, no test-issued restart call:** `:ok =
   Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)`
   only. Do NOT follow it with a test-issued `start_child/2` call (this is
   the one line iteration 2's guidance added and this revision removes).
   This `terminate_child/2` call alone produces exactly the `:DOWN`
   `PollersBreaker` needs to perform its OWN first, `:closed`-state
   restart (§3.4/§3.6's "1st `:DOWN`" branch) — the same call this
   design's own §6.2 step 3 already uses for its new regression test, so
   this AC4 test now shares its trigger mechanism with §6.2 exactly,
   rather than diverging from it.
4. **Wait for the breaker's restart, not a bare pid-appears poll:** poll
   `Letflow.Supervisor.PollersBreaker.breaker_state()` (§3.5's public
   accessor) together with `Process.whereis(Letflow.Supervisor.Pollers)`
   until a new, non-nil pid distinct from `pollers_pid_before` appears
   AND `breaker_state() == :closed` (confirming the breaker's own
   observation timer has not yet seen a 2nd `:DOWN` — i.e. this is the
   single-shot case, not yet tripped). A short poll loop mirroring the
   existing `wait_for_new_pollers_pid/2` helper's shape is sufficient
   (e.g. up to ~2 seconds, comfortably inside the breaker's own
   `@observation_window_ms`); this replaces the old
   `assert_receive {:DOWN, ...}` step, since there is no longer a
   test-owned monitor ref to receive a `:DOWN` for (the test issued no
   restart of its own to monitor the result of).
5. **Clear the fault before the SECOND exhaustion cycle, exactly as
   before, but now racing only the breaker's single observation
   timer, not a second restarter:** `Application.delete_env(:letflow,
   :force_poller_crash)` and `Application.put_env(:letflow,
   :start_scheduler, false)`, immediately after step 4's wait succeeds.
   This preserves the existing test's own "clear the fault promptly so
   only ONE exhaustion cycle occurs" intent (REQ-219 AC4's single-shot
   scenario) — now correctly synchronized against the ONE actor
   (`PollersBreaker`) that could otherwise trip a 2nd time, rather than
   against an assumed-but-uncontested top-level auto-restart.
6. Unchanged: `assert Process.whereis(Letflow.Repo) == repo_pid_before`
   and `assert Process.whereis(Letflow.Supervisor.Infrastructure) ==
   infrastructure_pid_before` — AC4's core isolation property.
7. **New pid assertion, restated against the breaker-restarted pid from
   step 4** (no longer "a third pid distinct from a test-restarted
   second pid" — there is no test-restarted second pid any more, only
   the breaker's one restart): `new_pollers_pid = Process.whereis(Letflow.Supervisor.Pollers)`,
   `assert new_pollers_pid != nil`, `assert new_pollers_pid != pollers_pid_before`.
8. **New, ISS-0451-motivated confirming assertion, cheap to add and
   directly rules out the failure this whole rework exists to prevent:**
   `assert Letflow.Supervisor.PollersBreaker.breaker_state() == :closed`
   — confirms the single-shot fault did NOT trip the breaker, i.e. this
   really was REQ-219 AC4's single-shot scenario and not an accidental
   2nd trip.
9. `on_exit` teardown: unchanged in intent (delete `:force_poller_crash`,
   restore `:start_scheduler`), but its own `restart_pollers!/0` call
   (used to leave a clean, running `Letflow.Supervisor.Pollers` for later
   tests) keeps the `start_child/2`-based fix already applied to that
   helper (§5's "Second, previously-unflagged consequence" text below,
   unaffected by this rework) — teardown is not part of the race this
   rework fixes, since by teardown time the fault is already cleared and
   the breaker is `:closed`, so a teardown-time `{:error,
   {:already_started, pid}}` tolerance (already present in the helper) is
   sufficient there, unchanged.

**Why this is not a weakening of AC4.** The same observable property —
a Pollers crash-loop restarts (only) Pollers once, leaving
Repo/Infrastructure/Http untouched, and Pollers comes back running — is
still asserted and still holds, with one assertion ADDED (step 8) that
the codebase did not have before. What changes is only which actor
performs the restart the test observes (the breaker, always, matching the
real system) and how the test waits for it (the breaker's own
`breaker_state()` accessor plus a pid-appears poll, instead of a
test-issued `start_child/2` call plus a monitor `:DOWN`) — the same class
of change already applied, without controversy, to `restart_pollers!/0`
in the "Second, previously-unflagged consequence" text immediately below.

**Second, previously-unflagged consequence, unaffected by this rework's
§5 rewrite above and restated for completeness: the existing test's OWN
`restart_pollers!/0` helper (`pollers_test.exs`, current form) also needed
its `terminate_child`-then-`restart_child` pair corrected to
`terminate_child`-then-`start_child/2`, since a `:temporary` child's spec
is deleted immediately on either an automatic exit or a `terminate_child/2`
call.** ELIXIR-DEV already applied this fix (visible in the current
`restart_pollers!/0`, which also tolerates the breaker racing IT for the
identical spec via `{:error, {:already_started, pid}}` — correct as
implemented, and this rework does not change it). This helper is used only
in `on_exit` teardown after this rework's §5 rewrite above (no longer
inline in the AC4 test body, since step 3 above no longer calls it there),
so its own race-tolerance is sufficient for the reduced role it now plays.

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
   once via `Supervisor.terminate_child(Letflow.Supervisor,
   Letflow.Supervisor.Pollers)` followed by `Supervisor.start_child(
   Letflow.Supervisor, Supervisor.child_spec(Letflow.Supervisor.Pollers,
   restart: :temporary))` — **corrected (rework iteration 2): NOT the
   `terminate_child`/`restart_child` pair `pollers_test.exs`'s own
   `restart_pollers!/0` currently uses**, since that pair no longer works
   once Pollers' child spec is `:temporary` (§5's newly-flagged
   `restart_pollers!/0` consequence — the same helper needs the same
   `start_child/2` fix independently of this new test). This is what makes
   `init/1` re-read the fresh env overrides and start the crash-looping
   poller.
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
   "the test got lucky with timing" — RE-VERIFIED (rework iteration 2,
   against the corrected `Supervisor.child_spec/2` form, not merely
   re-asserted from the prior iteration's text):** `assert Process.whereis(
   Letflow.Supervisor.Pollers) == nil`. Live-confirmed in this rework
   (§3.4a's probe): a supervisor started with the CORRECTED
   `Supervisor.child_spec(child, restart: :temporary)` children-list entry
   genuinely leaves `Process.whereis/1` for the killed child as `nil` after
   it exits and is not restarted — this was the exact property the prior
   iteration's broken `{module, arg}` syntax did NOT actually produce (that
   syntax's child stayed `:permanent` and DID come back with a new pid, per
   the validator's own live probe). Under the corrected form: the
   top-level `Letflow.Supervisor` structurally never re-registers a live
   `Letflow.Supervisor.Pollers` process once the crash-looping instance has
   exited on its own (per its own unchanged `max_restarts: 5,
   max_seconds: 60` budget, §3.2's `:closed` state) — no
   `terminate_child/2` call is needed or made by the breaker to produce
   this (§3.7's revised text); the pid simply stays unregistered because
   nothing (top level OR breaker) issues another `start_child/2` call
   while the breaker holds `:open` (§3.4a's "SECOND CORRECTION" —
   `start_child/2`, not `restart_child/2`, is the call the breaker would
   issue if it were going to restart Pollers here, but §3.2/§3.4's `:open`
   state means it deliberately does not).
   `Supervisor.which_children(Letflow.Supervisor.Pollers)` is NOT a valid
   alternative observable here (unlike the prior iteration's phrasing) —
   once the process itself has exited and is not restarted,
   `Letflow.Supervisor.Pollers` is not a running supervisor at all and
   `which_children/1` against a dead/unregistered name will raise (also
   live-confirmed during this rework: `GenServer.call` against a
   no-longer-registered name exits with `:noproc`), not return `[]`;
   `Process.whereis/1` returning `nil` is the correct and only
   observable for "this named process does not currently exist."
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
  restart-intensity consideration as a top-level child, AND (REVISED,
  rework iteration 1, sharper now that the breaker is the SOLE restart
  authority for Pollers rather than a secondary observer) what its fresh
  `init/1` should do if it restarts while Pollers is currently `:open`
  (stopped, `Process.whereis(Letflow.Supervisor.Pollers) == nil`)** is
  explicitly flagged as NOT resolved by this design and left for
  REVIEWER/ELIXIR-DEV. The breaker is an ordinary `GenServer` under the
  top-level `Letflow.Supervisor`'s own default `:one_for_one`/OTP-default
  intensity, so a breaker crash consumes ONE of the top level's own
  restart-budget slots (now 5, per §4) and restarts fresh — but a fresh
  `init/1` restarting `consecutive_trips: 0`/`:closed` unconditionally
  would, if Pollers was legitimately `:open` at the moment of the crash,
  either leave Pollers stopped forever (if the fresh breaker does not
  itself call `start_child/2`, per §3.4a's corrected mechanism) or
  prematurely resume restarting a still-
  persistent fault with the backoff schedule reset to its shortest interval
  (if it does) — NEITHER is clearly correct without a decision this design
  does not make: whether `init/1` should call `Process.whereis(Letflow.
  Supervisor.Pollers)` and treat `nil` as "resume in `:open` with a fresh
  backoff timer" versus some other recovery. This is believed to be a rare
  case (the breaker crashing is itself an unrelated fault) but is not
  empirically verified in this design pass the way ISSUE-FIXER's probe
  verified §1's core cascade — a future review or a TEST-DESIGNER-authored
  test of "breaker itself crashes mid-observation, or while `:open`" would
  close this gap if judged worth the additional test cost; ISS-0451's own
  acceptance criteria do not require
  it.
