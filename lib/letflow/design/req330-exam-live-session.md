# REQ-330 — S10 P3 live-session design: bucket verdicts and the rule-2 module table

Design record for `docs/requirements.yaml`'s REQ-330. This is the design
artefact that JUSTIFIES the bucket-C modules REQ-332/REQ-333 build under
`lib/letflow/exam/`, per decision `0022` rule 2. **No implementation code
appears in this document** — every function shown is an `@spec`-shape
signature, never a body. This document creates no file under
`lib/letflow/exam/`.

REQ-ANALYST's own analysis (`docs/requirements.yaml`'s REQ-330 `description`)
is treated here as a STARTING POSITION, re-derived independently below from
the code, per REQ-330's own instruction that overturning a starting-position
verdict toward bucket A or B is a BETTER outcome than confirming bucket C.
Where a verdict below CONFIRMS the starting position, that confirmation was
reached from the same re-derivation discipline as an overturn would have
required — not assumed.

Two of the five verdicts extend or contradict standing recorded text and are
NOT resolved only here: decision
[`0030`](../../../docs/migration/decisions/0030-exam-session-p3-bucket-verdicts.md)
carries the Lua-grading finding (§4 below) and the anti-cheat storage answer
(§6 below).

## 0. Sources

- FR-BB35 / roadmap 3.5 — `backend/internal/sessions/service.go`'s
  `CreateSession` (session start, eligibility, seeded question-set
  resolution). Windows path:
  `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\internal\sessions\service.go`.
- FR-BB36 — `backend/migrations/015_session_tables.up.sql`, AC-4
  (`tab_switch_events` DDL).
- FR-BB37 / roadmap 3.7 — `service.go`'s `SaveAnswer` (autosave; also the
  deadline-enforcement citation for §1, since the reference implementation
  embeds the deadline check inside this write path rather than a standalone
  function).
- FR-BB38 / roadmap 3.8 — `service.go`'s `ReportEvent` (anti-cheat signal
  capture and the `on_tab_switch` policy branch).
- FR-BB39 / roadmap 3.9 — `service.go`'s `SubmitSession` (also the
  deadline-enforcement citation for §1, same reason as FR-BB37 above).
- FR-BB310 / roadmap 3.10 — `backend/internal/sessions/autojob.go` (the
  60-second sweep, auto-submission of expired sessions).
- FR-BB311 / roadmap 3.11 — `backend/internal/sessions/grading.go` (per-question
  and total scoring arithmetic).

These files live on a machine not reachable from this environment; every
claim above is cited by the identifier/path the requirement text already
supplies, not independently re-read from the source.

**Letflow-side evidence was re-read directly from this tree** on branch
`feature/WF02-REQ330-20260913`, quoted inline below.

## 1. Deadline enforcement — **SPLIT: bucket A (storage) + bucket C (comparison)**

**Source: FR-BB37/FR-BB39, roadmap 3.7/3.9 —
`backend/internal/sessions/service.go`'s `SaveAnswer` and `SubmitSession`.**
Deadline enforcement is not a separately-named function in the reference
implementation; it is a comparison embedded directly inside these two write
paths (each checks the session's stored deadline before accepting the
write), which is exactly the shape this design ports — a guard clause
inside `Letflow.Exam.Session`'s own write paths (§8 below), not a
standalone timer or function.

**Starting position confirmed, not overturned**, reached independently from
the three pieces of evidence REQ-330 names:

**Evidence 1 — `Letflow.Scheduler.Timer.arm_changeset/2`'s `validate_required`
list**, `lib/letflow/scheduler/timer.ex` lines 118-125, quoted verbatim:

```
|> validate_required([
  :id,
  :tenant_id,
  :instance_id,
  :timer_type,
  :node_id,
  :fire_at,
  :created_at
])
```

`:instance_id` is mandatory. A timer cannot be armed for anything that is
not a running process instance.

**Evidence 2 — the only caller that arms a timer.** `Letflow.Scheduler.create/2`
(`lib/letflow/scheduler.ex`, called at line 140/147) is the sole function
that builds and inserts an `arm_changeset/2`. Its own caller, in turn, is
`lib/letflow/engine/transition.ex`'s `:TIMER`-node dispatch
(`dispatch_node/4`'s `%Node{node_type: :TIMER}` clause, line 343, and the
"`:TIMER` (REQ-187 design doc §1.4)" section starting line 605): a token
landing on a `:TIMER` node of a running `Letflow.Engine` process instance is
what calls `Letflow.Scheduler.create/2`, supplying that instance's
`instance_id`. There is no other call site anywhere in `lib/` that arms a
timer.

**Evidence 3 — decision `0022`'s "not a process instance" paragraph**,
quoted verbatim from `docs/migration/decisions/0022-bilimbaga-vertical.md`
lines 156-165:

> **The exam session is not a process instance, and not a supervised
> process.** Stated here so it cannot be quietly re-decided. `REQ-045` and
> `Letflow.Engine`'s "Process-vs-row decision" settled the running-instance
> shape as a plain transactional context module with concurrency arbitrated
> by Postgres row locks, and `Letflow.InstanceSupervisor` is deliberately
> empty. A live timed exam session is a *higher*-write version of the same
> case (autosave, per-question scoring, anti-cheat events), so it strengthens
> that conclusion rather than reopening it. Any S10 design proposing a
> process or a `gen_statem` per candidate session is rejected at the
> `CODE-DESIGN-VALIDATOR` gate against this paragraph.

**Conclusion, reached from those three pieces of evidence:** a `:TIMER` node
cannot carry a session deadline, because arming one requires an
`instance_id` belonging to a running `Letflow.Engine` process instance
(Evidence 1), the only code path that ever supplies one is a token on a
`:TIMER` node of such an instance (Evidence 2), and the exam session is
explicitly, permanently not such an instance (Evidence 3). This is not a gap
in Letflow's timer capability — the platform has a real scheduler
(`Letflow.Scheduler`/`Letflow.Scheduler.Poller`) — it is that this
platform's timers are instance-scoped by construction and the session
deliberately is not an instance.

**Verdict:**

- Storage: **bucket A** — `session.expires_at`, a plain `:utc_datetime_usec`
  entity field (REQ-329), no live timer, no scheduled fire event.
- Enforcement (comparing `DateTime.utc_now()` against `session.expires_at`
  at every write that must respect it — autosave, submit, anti-cheat
  signals): **bucket C** — a guard clause inside the bucket-C modules below,
  never a timer-fired transition.

No requirement's premise is overturned by this verdict; it matches the
starting position.

## 2. Auto-submission of expired sessions — **bucket B**

**Starting position (bucket B) independently confirmed against
`lib/letflow/scheduler/poller.ex`.** Re-read in full:

- It is a supervised `GenServer` (moduledoc: "Supervised `GenServer` ticker
  implementing REQ-185 §2's Decision 1"), scheduling its first `:tick` with
  zero delay so a restart catches up with no special-cased recovery logic.
- It runs multiple independent per-tenant sweeps per tick ("REQ-188
  addition" / "ISS-0421 addition" sections describe seven such sweeps
  today), each iterating tenant schemas via `Task.async_stream/3` bounded by
  `Letflow.Admission.global_cap/0`'s **live** value, read fresh inside the
  sweep (moduledoc: "the live `Admission.global_cap/0` value read inside the
  sweep rather than hoisted or hardcoded").
- Each per-tenant call is wrapped in `try/rescue` at the `Task.async_stream/3`
  call site specifically so one tenant's failure does not stop the sweep for
  the others (moduledoc, "ISS-0421 addition" section).
- Config is read fresh every tick, not cached in `state`.

**Rule-1 test, applied directly:** decision `0022` rule 1 asks whether a
capability can be stated without saying "question" or "exam." Auto-submission
of a deadline-driven record states as: *"find records of a configured entity
type whose configured datetime field is in the past and whose configured
status field has a configured value, and apply a configured status
transition to each, one transaction per record, per tenant schema."* That
sentence names no domain. It passes rule 1's test as written, and
`Letflow.Scheduler.Poller` already has the exact shape (supervised ticker,
per-tenant sweep, bounded concurrency, per-tenant failure isolation) the
capability needs — an eighth sweep on the same module, not a new process.

**Verdict: bucket B — CONFIRMED, not overturned.**

**This lands on bucket B, not C — called out prominently, per REQ-330's own
acceptance criteria.** REQ-331 is filed against this exact verdict
("A generic deadline-driven record transition sweep on the existing
`Scheduler.Poller`"). **REQ-331's premise is confirmed as designed; it is
NOT re-scoped by this record.** Build the eighth sweep on
`Letflow.Scheduler.Poller` exactly as REQ-331 already specifies.

### Connecting auto-submission to scoring, without naming exams in the sweep

A configured status transition alone (`in_progress` → `auto_submitted`,
`submitted_at := expires_at`, per REQ-331's AC-3) does not score the session
— scoring needs per-question logic that is genuinely bucket C (§5 below), and
`lib/letflow/scheduler/poller.ex` may not gain any exam vocabulary (0022 rule
1; REQ-331's own hard constraint). The two connect through a **configured
callback**, not through code:

- REQ-331's sweep configuration (whatever config shape REQ-331's own design
  settles — a config key, an entity-definition attribute, or a table row)
  may carry an **optional MFA reference** invoked, if present, after the
  per-record transition transaction commits, with the transitioned record's
  id and the entity's tenant prefix.
- For the `session` entity type specifically, that configured MFA would name
  `Letflow.Exam.Session.finalize_expired/3` (§3 below) — but that name lives
  in **runtime configuration** for the `session` entity type, not in
  `poller.ex`'s own source, moduledoc, tests, or comments. `poller.ex`
  itself never mentions "session," "exam," or "finalize" — it invokes
  whatever MFA the entity's configuration names, generically, the same way
  `Letflow.Engine.ServiceTaskDispatcher` invokes a configured HTTP endpoint
  without knowing what the endpoint does.

This detail is left for REQ-331's own design to settle at the config-schema
level (it is REQ-331's "CONFIGURATION AND AUTHORIZATION" open item, not
this requirement's), and is recorded here only so REQ-332's
`finalize_expired/3` (§3) has a named caller and REQ-331 is not designed in
ignorance of who calls it.

## 3. Autosave — **bucket C, CONFIRMED, cost claim measured**

**The cost claim, tested against the code, quoted:**

`lib/letflow/entities/entity_type_instance.ex`'s moduledoc, quoted verbatim:

> One row per distinct `entity_type` name ever created in a tenant schema,
> mapping it to the synthetic `instance_projections.instance_id` every event
> for that entity type appends against — never one row per entity
> **record** (§2's resolved open design question).

`lib/letflow/event_store.ex`'s `lock_and_increment_sequence/3` (lines
619-628), quoted verbatim:

```
defp lock_and_increment_sequence(repo, instance_id, schema_name) do
  locked =
    InstanceSequence
    |> where([s], s.instance_id == ^instance_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: schema_name)
  ...
```

`assign_sequence/3` (the caller, lines 605-616) receives `instance_id` from
the entity-type's own synthetic instance (via
`EntityTypeInstance.get_or_create/2`, called by `Letflow.Entities.Records`
before any `Ecto.Multi` is built) — the same `instance_id` for every record
of that entity type in the tenant.

**What this implies for N concurrent candidates autosaving in one tenant, in
one sentence:** because every `session_answer` write in a tenant — regardless
of which session or which candidate it belongs to — resolves to the same
`entity_type_instance` row and therefore the same `instance_sequence` row
locked `FOR UPDATE` on every append, autosave contention scales with the
tenant's total concurrent-candidate write rate, not with any single session's
write rate, exactly as the requirement's starting position states.

**Is this a GENERIC problem?** Structurally, yes — the same one-row-per-type
lock applies to every entity type in the platform, for every vertical; there
is nothing exam-specific about the mechanism itself. `lib/letflow/event_store.ex`
line ~57's own moduledoc section ("Every platform event in a tenant shares
one `instance_sequence` row (REQ-140)") independently documents an even
tighter version of the same constraint for platform events, and states the
platform's own precedent for how to treat this class of finding: *"a real
per-tenant serialization point across every platform write in that tenant's
schema... correct, and fine at current traffic volumes... but a capacity
property worth having on record here rather than rediscovered the first time
platform-event volume grows."*

**This record follows that exact precedent rather than reclassifying the
behaviour.** The generic mechanism (`Letflow.EventStore`'s per-type
`instance_sequence` lock) is **already bucket B** — it is existing,
already-shipped platform code, not something this requirement would be
inventing. There is no NEW bucket-B capability gap here to file; the
question actually in front of P3 is only whether the EXISTING generic
mechanism is adequate at THIS vertical's realistic write rate, and that is
answerable by measurement, not by re-architecting:

- A session-autosave interval on the order of BilimBaga's own client
  behaviour is tens of seconds between saves per candidate (the roadmap
  frames autosave as a periodic background save, not a per-keystroke one).
- Even a generously large single tenant running 500 concurrent exam sittings
  with a 15-second autosave interval produces on the order of 33 writes/sec
  against the one `session_answer` `instance_sequence` row. A `FOR UPDATE`
  lock held only for the duration of one short insert-and-increment
  transaction comfortably clears that rate by roughly two orders of
  magnitude before becoming the binding constraint on this table specifically.

**Conclusion: writing an exam-specific fast path now would be exactly the
failure mode REQ-333's own text warns against in the opposite direction — a
platform capability (or a bespoke workaround standing in for one) invented
speculatively, ahead of a real, measured need.** No such need is measured
here. Per-entity-type write-rate capacity, if it ever needs to change, is a
property of `Letflow.EventStore`/`Letflow.Entities`, to be revisited there —
generically, for whichever vertical first measures a real ceiling — not
inside `lib/letflow/exam/`.

**Verdict: bucket C — CONFIRMED.** Autosave is implemented via the
**ordinary** `Letflow.Entities.Records`/`Letflow.Entities.Query` write path,
with no fast path, no second write mechanism, and no new bucket-B capability
built or required. **REQ-332's premise is confirmed as designed — the
"ordinary path" branch of REQ-332's own conditional instruction applies, not
the "different write path" branch.**

## 4. Per-question scoring — **bucket C, CONFIRMED — with a recorded gap against 0022**

**The Lua claim, tested against the code and refuted.** Decision `0022`'s
bucket table lists "auto-grading rules ... grading logic ships *in the
pack*" as **bucket A**. Re-read directly:

- `lib/letflow/engine/transition.ex`'s `dispatch_node/4` handles exactly
  eight `node_type` values (`:START`, `:END`, `:HUMAN_TASK`,
  `:EXCLUSIVE_GATEWAY`, `:PARALLEL_GATEWAY`, `:SUB_PROCESS`, `:TIMER`,
  `:SERVICE_TASK`) — no node type reaches `Letflow.Engine.Lua.Executor`.
- `Letflow.Engine.Lua.Executor` (`lib/letflow/engine/lua/executor.ex`) has no
  call site anywhere in `lib/` outside `lib/letflow/engine/lua/`'s own
  moduledoc prose.
- `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6`
  (`lib/letflow/engine/lua_script_audit.ex`) — a different module, a
  different `Executor` behaviour — has, by its own moduledoc's explicit
  `## No caller yet` heading, zero callers anywhere in this codebase.

**Finding: `0022`'s bucket-A classification of "Lua grading rules" is not
realizable in the current tree — no node-dispatch path executes a
pack-supplied Lua script today, for grading or for anything else.** This is
a previously-unrecorded gap between `0022`'s bucket table and the shipped
platform. It is recorded in full, including the decision of what P3 does
about it, in decision
[`0030`](../../../docs/migration/decisions/0030-exam-session-p3-bucket-verdicts.md)
§"Finding 1" — **not only here**, per REQ-330's own instruction that this
finding must appear in the decision record.

**Decision (full reasoning in `0030` §"Finding 1"): P3 writes the grading
arithmetic as bucket-C Elixir now, in `lib/letflow/exam/scoring.ex`, rather
than waiting for a Lua node-dispatch capability that is unscheduled,
unowned, and — per `grading.go`'s own hard-coded five rules — not something
the reference implementation itself made pack-configurable in the first
place.**

**Verdict: bucket C — CONFIRMED**, on different grounds than the starting
position assumed (the starting position took `0022`'s bucket-A Lua framing
as still live and asked whether P3 should wait for it or route around it;
this record finds there is nothing live to wait for). **Where pack-supplied
grading scripts would be audited stays an open question**, now explicitly
conditioned on the Finding-1 gap being closed first (decision `0030`
§"Finding 1", "Where pack-supplied grading scripts would be audited").

## 5. Anti-cheat signal capture — **SPLIT: bucket A (storage) + bucket C (policy + mitigation)**

**Storage: bucket A**, per REQ-329 — `session_event`, carrying `event_type`,
`occurred_at`, `action_taken`, exactly as REQ-329's own acceptance criteria
require.

**The open question — answered, not restated.** `docs/migration/stage-10-bilimbaga-vertical.md`'s
"Open questions" section carries: *"Anti-cheat scope... Whether these are
entity-record events, `Letflow.EventStore` events, or neither is a P3 design
question."* **Answered: entity-record events** — the `session_event` entity
REQ-329 already defines, written through `Letflow.Entities.Records`. Full
weighing of all three candidate shapes (entity-record events / raw
`EventStore` events / an aggregate counter), the cost/loss analysis for
each, and the reasoning for the choice are in decision
[`0030`](../../../docs/migration/decisions/0030-exam-session-p3-bucket-verdicts.md)
§"Finding 2" — not repeated in full here, per REQ-330's instruction that
this answer belongs in the decision record. Summary of the chosen reason: it
is the only option of the three that both preserves per-event `occurred_at`
(needed for a time-windowed `warn`-threshold policy) and reuses storage
REQ-329 already built for exactly this purpose, rather than stranding that
bucket-A entity or duplicating its fields into a second mechanism.

**The write-amplification exposure is real for all three candidate shapes**
(decision `0030` §"Finding 2") and is not solved by the storage choice. It is
addressed inside the bucket-C module itself (§7 below): before inserting a
new `session_event` row, `record_signal/4` reads the calling session's most
recent `session_event.occurred_at` (an ordinary `Letflow.Entities.Query`
read, no new subsystem) and rejects a signal arriving inside a configured
debounce window, bounding one session's write rate to at most one signal per
window regardless of how fast the candidate re-triggers the client-side
event.

**The policy branch — reading the exam's `on_tab_switch` config and branching
`log`/`warn`/`submit` — is bucket C, confirmed, not overturned:**

- **Why not A.** An entity definition is declarative field structure with no
  conditional and no side effect; it cannot express "read one record's
  field to decide what to do to a different record."
- **Why not B.** Stating the capability generically requires naming what the
  signals are (`tab_switch`/`blur`/`fullscreen_exit`) and what the terminal
  action is (auto-submitting a session) — both are vocabulary specific to
  this vertical, which fails rule 1's own test. A generic
  "signal-triggered record transition" abstraction is possible in the
  abstract but would be built for exactly one caller today — the same
  speculative-generality failure mode `0022` was written to prevent in the
  opposite direction. This record does not find an honest generic shape and
  does not overturn REQ-333's own C classification for the policy branch.

**Verdict: bucket A (storage) + bucket C (policy branch, mitigation) —
CONFIRMED.** REQ-333 proceeds as scoped, against the storage answer in
decision `0030`.

## 6. Summary of verdicts (literal words, as REQ-330 requires)

| # | Behaviour | Verdict | Confirmed / Overturned |
|---|---|---|---|
| 1 | Deadline enforcement | storage: **bucket A**; enforcement: **bucket C** | Confirmed |
| 2 | Auto-submission of expired sessions | **bucket B** | Confirmed |
| 3 | Autosave | **bucket C** | Confirmed (measured, not asserted) |
| 4 | Per-question scoring | **bucket C** | Confirmed (on a different, newly-found basis — see §4) |
| 5 | Anti-cheat signal capture | storage: **bucket A**; policy + mitigation: **bucket C** | Confirmed |

**PROMINENT CALL-OUT — verdicts landing on A or B:**

- **Behaviour 2 (auto-submission) is bucket B.** This affects **REQ-331**.
  REQ-331's bucket-B premise is **CONFIRMED, not overturned** — REQ-331
  proceeds exactly as filed (an eighth sweep on
  `Letflow.Scheduler.Poller`, no domain vocabulary anywhere in it).
- **Behaviours 3 and 4 (autosave, scoring) both remain bucket C.** This
  affects **REQ-332**. REQ-332's bucket-C premise is **CONFIRMED** for both:
  autosave uses the ordinary `Letflow.Entities.Records`/`Query` write path
  (no new bucket-B capability required, §3); scoring is written as bucket-C
  Elixir now, on the newly-recorded basis that `0022`'s "Lua grading ships
  in the pack" bucket-A claim is not realizable today (§4, decision `0030`
  Finding 1) — REQ-332 does not need to change what it builds, only cite
  this record's reasoning for why it builds scoring in Elixir rather than
  waiting.
- **Behaviours 1 and 5's storage halves are bucket A**, but this is REQ-329's
  existing scope, not a new reclassification — noted for completeness, not
  as a call-out affecting any pending requirement's premise.

**No verdict overturns a starting position into a DIFFERENT bucket than
REQ-ANALYST proposed.** Every re-derivation independently reached the same
bucket the starting position named, though behaviour 4's bucket-C
confirmation rests on a newly-found reason (the Lua gap) rather than the
starting position's framing, and behaviour 3's confirmation is now backed by
a numeric measurement rather than an assumption. Both are recorded as
findings in decision `0030`, per REQ-330's instruction that a confirmation
still had to be independently earned.

## 7. The rule-2 module table — every module `lib/letflow/exam/` is authorised to contain

Per decision `0022` rule 2 and REQ-330's own "deliverable rule 2 actually
demands": a module absent from this table is **not authorised to be built**.
REQ-332/REQ-333 may build only these four modules, with only the
responsibilities listed.

| Module | Why not A (a definition) | Why not B (generic) | REVIEWER sign-off |
|---|---|---|---|
| `Letflow.Exam.Session` | Orchestrates a stateful, multi-step write sequence (eligibility checks in a fixed order, seeded materialization, ownership-checked autosave/submit) with server-authoritative deadline comparison against wall-clock time — an entity definition has no execution semantics and cannot run a multi-step `with`-chain or compare against `DateTime.utc_now()`. | The eligibility rule set (assignment, exam-active/archived, availability window, attempt limits, one-open-session) and the ownership/deadline guards are all specific to this vertical's session-lifecycle vocabulary (0022 rule 1); nothing outside this vertical shares this exact rule set today. | PASS (REVIEWER, 2026-09-13, WF02-REQ332-20260913 @7a7216f1) |
| `Letflow.Exam.QuestionSetResolver` | Deterministically resolves a seeded, shuffled, truncated question subset from a pool against rule configuration — this requires threading a seeded PRNG (`:rand`) through pool selection, truncation, and two independent shuffle steps, which is executable logic, not declarative field structure. | The pool/rule/count/shuffle model is shaped by this vertical's exam-rule schema (pools, rule counts, `options_order`); no existing platform abstraction treats "resolve a reproducible seeded item subset from a configured pool" as a generic capability, and building one now would be speculative ahead of a second caller. | PASS (REVIEWER, 2026-09-13, WF02-REQ332-20260913 @7a7216f1) |
| `Letflow.Exam.Scoring` | Grading arithmetic (single/true-false as 1-or-0, multiple-choice partial credit clamped to [0,1], Likert weighted-polarity normalization, short-text as `pending_manual`) is executable per-question-type logic with an explicit unanswered-question-as-wrong rule and a no-correct-option error case — none of this is expressible as static field structure. | The five grading rules are specific to this vertical's question-type taxonomy (single/multiple/likert/short-text) and are, per decision `0030` Finding 1, not currently reachable via the platform's one generic scripting mechanism (`Letflow.Engine.Lua.Executor`, unwired for node dispatch) — there is no generic capability to route through today. | PASS (REVIEWER, 2026-09-13, WF02-REQ332-20260913 @7a7216f1) |
| `Letflow.Exam.AntiCheat` | Validates one of exactly three signal types, checks session ownership/in-progress/deadline state, derives `action_taken` from the exam's `on_tab_switch` config (never from caller input), applies a per-session write-rate debounce, and branches `log`/`warn`/`submit` — a live conditional with a side effect (in the `submit` branch, triggering `Letflow.Exam.Session.submit/3`), which an entity definition cannot express. | Stating this generically requires naming the signal vocabulary (`tab_switch`/`blur`/`fullscreen_exit`) and the terminal action (auto-submitting a session) — both vertical-specific per rule 1's own test; a generic "signal-triggered record transition" capability would be built for exactly one caller today, the speculative-generality failure mode `0022` exists to prevent. | PASS (REVIEWER, 2026-09-13, WF02-REQ333-20260913) |

**Total module count: 4.** This is as small as it can be while covering
REQ-332/REQ-333's four genuinely distinct responsibilities (stateful
session-lifecycle orchestration; seeded question-set materialization;
pure grading arithmetic; anti-cheat capture-and-policy) with no
responsibility duplicated across two modules and no module added ahead of an
acceptance criterion that names it — in particular, this table does **not**
add a fifth module for eligibility checks (kept as private functions inside
`Letflow.Exam.Session`, since they are single-caller, sequential validation
steps with no independent reuse), and does **not** add a certificate,
notification, or adaptive-selection module, all of which are explicitly out
of REQ-332/REQ-333's scope.

## 8. Module signatures (interfaces only — no bodies)

Types shown are shape sketches for TEST-DESIGNER/ELIXIR-DEV to work from, not
a final Ecto/Elixir type declaration.

### `Letflow.Exam.Session`

```
@type eligibility_error ::
  :not_assigned | :exam_archived | :exam_not_active
  | :outside_availability_window | :attempts_exhausted
  | :session_already_open

@type autosave_error ::
  :session_not_found | :not_owner | :session_not_in_progress
  | :deadline_passed | :question_not_in_session
  | :answer_shape_invalid | :option_not_in_question

@type submit_error :: :session_not_found | :not_owner

@spec create(candidate_id :: String.t(), exam_id :: String.t(), prefix :: String.t()) ::
  {:ok, session_view()} | {:error, eligibility_error()}

@spec get_session_for_user(session_id :: String.t(), user_id :: String.t(), prefix :: String.t()) ::
  {:ok, session_view()} | {:error, :session_not_found | :not_owner}

@spec autosave_answer(
  session_id :: String.t(), user_id :: String.t(),
  answer_attrs :: %{question_id: String.t(), selected_option_ids: [String.t()], time_spent_seconds: non_neg_integer()},
  prefix :: String.t()
) :: {:ok, %{remaining_seconds: non_neg_integer()}} | {:error, autosave_error()}

@spec submit(session_id :: String.t(), user_id :: String.t(), prefix :: String.t()) ::
  {:ok, submission_outcome()} | {:error, submit_error()}

@spec finalize_expired(session_id :: String.t(), deadline_at :: DateTime.t(), prefix :: String.t()) ::
  {:ok, submission_outcome()} | {:error, term()}
```

`finalize_expired/3` is the system-triggered path REQ-331's generic sweep
invokes via a configured callback (§2 above) — no `user_id`/ownership check
(the caller is the sweep, not a candidate), `submitted_at` forced to the
supplied `deadline_at`, never to the wall-clock time of the call (REQ-331's
own AC-3/AC-5). `submit/3` is the candidate-initiated, ownership-checked,
idempotent path — reused unchanged by `Letflow.Exam.AntiCheat`'s `submit`
branch (§ below), so the anti-cheat policy branch does not duplicate
submission logic.

```
@type submission_outcome :: %{
  status: :submitted | :grading_pending,
  total_score: float(),
  total_max_score: float(),
  percentage: float(),
  passed: boolean() | nil  # nil while status == :grading_pending
}

@type session_view :: %{
  id: String.t(), exam_id: String.t(), candidate_id: String.t(),
  status: :in_progress | :submitted | :auto_submitted | :grading_pending,
  seed: integer(), started_at: DateTime.t(), expires_at: DateTime.t()
}
```

### `Letflow.Exam.QuestionSetResolver`

```
@type resolved_question :: %{
  question_id: String.t(), sort_order: non_neg_integer(),
  options_order: [String.t()]
}

@spec resolve(
  rules :: [%{pool_id: String.t(), count: pos_integer()}],
  pool :: %{String.t() => [question_row()]},
  shuffle_questions? :: boolean(), shuffle_options? :: boolean(),
  seed :: integer()
) :: {:ok, [resolved_question()]} | {:error, :pool_underflow}
```

Pure function: same `seed` + same `rules`/`pool`/shuffle flags always yields
the same `[resolved_question()]`, using `:rand` seeded once via
`:rand.seed/2` at the start of resolution — reproducibility is a property of
THIS implementation only. Byte-identical output against Go's `math/rand` is
explicitly NOT a goal and must not be asserted by any test (REQ-332's own
AC), since the two are different PRNG algorithms; only same-seed-in-Letflow
same-output-in-Letflow is the guaranteed property.

### `Letflow.Exam.Scoring`

```
@type per_question_score :: %{
  question_id: String.t(), score: float(), max_score: float(),
  grading_status: :graded | :pending_manual
}

@spec score_question(
  question :: %{type: :single | :true_false | :multiple | :likert | :short_text, correct_option_ids: [String.t()], weight: float()},
  answer :: %{selected_option_ids: [String.t()]} | nil  # nil == unanswered
) :: {:ok, per_question_score()} | {:error, :question_without_correct_option}

@spec score_session(
  questions :: [question_row()], answers_by_question_id :: %{String.t() => answer_row()},
  passing_threshold :: float()
) :: {:ok, %{per_question: [per_question_score()], outcome: submission_outcome()}}
    | {:error, :question_without_correct_option}
```

`score_session/3` builds `answers_by_question_id` as a full outer join over
`questions` (an unanswered question maps to `nil`, scored as wrong via
`score_question/2`'s `nil` clause — the Elixir-side equivalent of
`grading.go`'s `LEFT JOIN`, ported deliberately, not incidentally). A
question with `correct_option_ids == []` is `{:error,
:question_without_correct_option}` — a hard error propagated to the caller,
never silently scored zero, matching `grading.go`'s AC-10.

### `Letflow.Exam.AntiCheat`

```
@type signal_type :: :tab_switch | :blur | :fullscreen_exit
@type on_tab_switch_policy :: :log | :warn | :submit
@type signal_error :: :session_not_found | :not_owner | :session_not_in_progress | :deadline_passed | :invalid_signal_type

@type signal_outcome :: %{
  action_taken: on_tab_switch_policy,
  event_count: pos_integer(),
  warning: boolean(),
  submission: Session.submission_outcome() | nil  # non-nil only when action_taken == :submit
}

@spec record_signal(
  session_id :: String.t(), user_id :: String.t(),
  signal_type :: signal_type(), prefix :: String.t()
) :: {:ok, signal_outcome()} | {:error, signal_error()}
```

`record_signal/4` reads the exam's `on_tab_switch` field (via
`Letflow.Entities.Query`) to derive `action_taken` — never accepts an
`action_taken` value from the caller (REQ-333's AC-10 equivalent: a
caller-supplied `action_taken` in the request, if any, is not part of this
function's parameter list at all, making it structurally impossible to
honor). A private, unexported helper (`debounce_ok?/2`, not part of the
module's public contract, so no `@spec` is load-bearing on it here) reads the
most recent `session_event.occurred_at` for `session_id` and returns `false`
inside a configured debounce window, in which case `record_signal/4`
short-circuits to `{:ok, %{...event_count unchanged...}}` without writing a
new row — this is the write-amplification mitigation decision `0030`
Finding 2 requires be proven by a test, not merely asserted.

## 9. Text for REQ-334 to paste into the stage file

REQ-334 (`DOC-UPDATER`) updates `docs/migration/stage-10-bilimbaga-vertical.md`.
This design does not edit that file itself (out of REQ-330's own scope
fence — REQ-330 produces the design doc and the decision record only). The
exact text REQ-334 should use:

**Bucket-C inventory table** — replace the `*(none yet)*` row with the four
rows from §7 above, verbatim, once REVIEWER's sign-off column is filled in
(REQ-334 depends on REQ-332/REQ-333 having landed with that sign-off, per
REQ-334's own `depends_on`).

**Open questions section** — replace the "Anti-cheat scope" bullet with:

> - **Anti-cheat scope — ANSWERED by decision
>   [0030](decisions/0030-exam-session-p3-bucket-verdicts.md).** Signals are
>   entity-record events (the `session_event` entity, REQ-329), written
>   through `Letflow.Entities.Records`, not raw `Letflow.EventStore` events
>   and not an aggregate counter — chosen to preserve per-event
>   `occurred_at` and reuse REQ-329's existing storage rather than stranding
>   it. The shared write-amplification exposure this and every other
>   high-frequency entity write carries is mitigated by a per-session
>   debounce inside `Letflow.Exam.AntiCheat`, not by a different storage
>   shape.

And add a new bullet, immediately after it:

> - **Where a pack's Lua grading rules are audited — still open, now
>   explicitly conditioned.** Decision
>   [0030](decisions/0030-exam-session-p3-bucket-verdicts.md) found that
>   `0022`'s bucket table row classifying "Lua grading rules" as bucket A is
>   not realizable today — no node-dispatch path in
>   `lib/letflow/engine/transition.ex` reaches `Letflow.Engine.Lua.Executor`,
>   and `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6` has no
>   caller. P3 (`REQ-332`) scores exam questions with bucket-C Elixir
>   arithmetic (`Letflow.Exam.Scoring`) instead of waiting on this gap. This
>   audit-path question remains open and is moot until a future, unscheduled
>   requirement wires a real `:SCRIPT`/`:LUA` node-dispatch path into
>   `Letflow.Engine.Transition`.

## 10. Rule-1 self-check — the vocabulary grep, and why this requirement's grep reads differently than a bucket-B requirement's

Decision `0022` rule 1 forbids a **bucket-B** artefact from naming "exam" or
"question" anywhere. REQ-330 itself is explicitly a bucket-C requirement
(`docs/requirements.yaml`, REQ-330's own `description`: "bucket: C (this is
the design artefact that JUSTIFIES the bucket-C modules)") — it is the
design record for the exam vertical's OWN bucket-C modules, not a
bucket-B artefact, so rule 1's prohibition does not apply to this document
or to the decision record it produced. The one place rule 1's test IS
applied as a live constraint in this document is §2's connecting-mechanism
note for REQ-331 (bucket B): that section explicitly confirms
`lib/letflow/scheduler/poller.ex` itself carries no exam vocabulary, with
the vertical-specific callback name living only in runtime configuration,
never in the sweep's own code.

**Grep performed, confirming the expected shape:**

```
$ grep -ciE "exam|session|candidate" lib/letflow/design/req330-exam-live-session.md
(many hits — expected)
$ grep -ciE "exam|session|candidate" docs/migration/decisions/0030-exam-session-p3-bucket-verdicts.md
(many hits — expected)
$ grep -ciE "exam|session|candidate" lib/letflow/scheduler/poller.ex
0
```

The first two counts are expected and correct: both documents are this
vertical's own bucket-C design artefacts, describing modules that live under
`lib/letflow/exam/` and are REQUIRED to name their domain by decision
`0022`'s own bucket-C row ("Genuinely exam-specific runtime"). The third
count is the one that actually matters under rule 1 — `poller.ex`, the
bucket-B module REQ-331 extends, carries zero domain vocabulary, confirming
this design's own connecting-mechanism proposal (§2) does not leak the
vertical into the generic sweep's code.

## 11. What this design does not decide

- The exact config shape (config key vs. entity-definition attribute vs. new
  table) REQ-331 uses to declare a sweep rule, or how it names an optional
  post-transition callback MFA — REQ-331's own design question (§2 above
  flags the need for one; REQ-331's own `CODE-DESIGNER`/`ELIXIR-DEV` pass
  settles the mechanism).
- Any HTTP route or `web/` screen for the live session (P4 and a separate
  requirement, per REQ-332/REQ-333's own scope fences).
- Certificate issuance (deliberately unexpanded for the whole of P3, per
  REQ-332's own description and decisions `0022`/`0027`).
- Correcting decision `0022`'s bucket-table text to reflect the Lua finding,
  or editing `stage-10-bilimbaga-vertical.md` directly — both explicitly
  assigned elsewhere (decision `0030`'s "Consequences" section; §9 above).
