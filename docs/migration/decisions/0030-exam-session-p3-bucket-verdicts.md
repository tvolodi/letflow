# 0030 — S10 P3 live-session bucket verdicts: the Lua-grading bucket-A claim is not realizable today, and the anti-cheat storage open question is answered

Status: decided (2026-09-13, `CODE-DESIGNER`, REQ-330), pending `SECURITY-REVIEWER`
and `REVIEWER` sign-off (sections below left as explicit PENDING placeholders for
the next pipeline step, not filled in by `CODE-DESIGNER`).
Owner: `ORCH` (this record extends/contradicts standing text in decision 0022 and
in `docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions" section; it
produces no implementation and none is scheduled by it).

## Why this record exists

`docs/requirements.yaml`'s REQ-330 requires a design doc
(`lib/letflow/design/req330-exam-live-session.md`) that re-derives, from the
actual code, which of S10 P3's five live-session behaviours are bucket A, B or
C. Two of the five verdicts extend or contradict text already on record, and
REQ-330's own instructions are explicit that this may not be resolved only in
the design doc:

1. Decision `0022`'s bucket table (`## The bucket rule` → `## Reasoning`, the
   `BilimBaga` / `Letflow mechanism` / `Bucket` table) lists **"auto-grading
   rules → sandboxed Lua (`lib/letflow/engine/lua/`, decision 0014) — grading
   logic ships *in the pack*" as bucket A.** The design doc
   (`req330-exam-live-session.md` §4) tested that claim against the current
   tree and it is false today — recorded in full below.
2. `docs/migration/stage-10-bilimbaga-vertical.md`'s "Open questions" section
   carries an explicit, unanswered item: *"Anti-cheat scope... Whether these
   are entity-record events, `Letflow.EventStore` events, or neither is a P3
   design question."* This record answers it.

This record does not itself edit `stage-10-bilimbaga-vertical.md` — REQ-334
(`DOC-UPDATER`, gated on REQ-330/REQ-332/REQ-333) is the requirement that
updates that file's bucket-C inventory and open-questions section. This
record, together with the design doc, is what REQ-334 copies from.

## Finding 1 — 0022's "Lua grading rules ship in the pack" bucket-A claim is not realizable in the current tree

**Re-verified directly, not taken from the requirement text:**

- `lib/letflow/engine/transition.ex`'s `dispatch_node/4` clauses match on
  exactly eight `node_type` values: `:START`, `:END`, `:HUMAN_TASK`,
  `:EXCLUSIVE_GATEWAY`, `:PARALLEL_GATEWAY`, `:SUB_PROCESS`, `:TIMER`, and
  `:SERVICE_TASK` (grep for `node_type: :` across the file, lines 299-636).
  There is no `:LUA`/`:SCRIPT` node type and no clause in this file that
  constructs a call into `Letflow.Engine.Lua.Executor`.
- `lib/letflow/engine/lua/executor.ex` defines `Letflow.Engine.Lua.Executor`.
  A repo-wide grep for `Letflow.Engine.Lua.Executor` outside
  `lib/letflow/engine/lua/` itself finds exactly two hits, both in
  moduledoc prose inside `lib/letflow/engine/lua/manifest.ex` and
  `lib/letflow/engine/lua/platform.ex` describing what a *future* caller
  would do (`manifest.ex`: "reaches `Letflow.Engine.Lua.Executor.execute_with_manifest/2,3`") —
  neither is an actual call site. `lib/letflow/supervisor/infrastructure.ex`
  references it only in a comment about a supervisor child
  (`PluginTaskSupervisor`), not a call.
- `lib/letflow/engine/lua_script_audit.ex` (`Letflow.Engine.LuaScriptAudit`)
  is a **different** module with its own **different** `Executor` behaviour
  (`Letflow.Engine.LuaScriptAudit.Executor`, a `defmodule Executor do ... end`
  nested inside `lua_script_audit.ex` itself, distinct from
  `Letflow.Engine.Lua.Executor`). Its own moduledoc states, quoted verbatim:
  *"This module is a MINIMAL, deliberately narrow engine-side call path that
  (a) invokes an injected script executor and (b) persists the resulting
  manifest hash to a queryable audit record... It is NOT the SERVICE_TASK
  script-execution handler."* and, under its own `## No caller yet` heading:
  *"As of this requirement, nothing in this codebase calls
  `execute_script_for_audit/6` — this requirement builds the audit-path
  function and its storage only."*

**Conclusion: there is no path today, in any direction, by which a
pack-supplied Lua script executes as part of node dispatch.** Neither the
real interpreter (`Letflow.Engine.Lua.Executor`, uncalled outside its own
directory) nor the audit wrapper around it
(`Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6`, uncalled by
anything at all) is reachable from `Letflow.Engine.Transition.dispatch_node/4`
or from any other node-dispatch path in the engine. `0022`'s bucket table row
— "auto-grading rules ... grading logic ships *in the pack*" classified
**A** — describes a mechanism that does not exist in the shipped platform.

**A second, independent reason the same row is not realizable even at the
reference-implementation level:** BilimBaga's own `backend/internal/sessions/grading.go`
(FR-BB311, roadmap 3.11) hard-codes its five grading rules — single/true-false,
multiple-choice, Likert, short-text — as native Go arithmetic. Nothing in the
port source calls out to Lua, or to any embedded scripting engine, for
grading. So `0022`'s "ships in the pack" framing was not a port of an existing
BilimBaga mechanism either; it was a forward-looking Letflow-native design
this vertical's grading behaviour never actually needed from the reference
implementation.

**This is filed as a genuine, previously-unrecorded gap between `0022`'s
bucket table and the platform**, not silently routed around. It does not
retract `0014` (Lua/WASM scripting is still the adopted runtime strategy for
scripting generally) or `Letflow.Engine.Lua.Executor`'s own correctness —
only the specific claim that grading logic for *this* vertical rides that
path *today*.

### Decision — P3 writes the grading arithmetic as bucket-C Elixir now; the Lua-dispatch gap is filed, not built

**Chosen: P3 (REQ-332) implements per-question and total scoring as ordinary
bucket-C Elixir functions in `lib/letflow/exam/scoring.ex`, ported directly
from `grading.go`'s five rules, and does not wait for a Lua node-dispatch
capability.**

Reasoning:

1. **There is no scheduled requirement to wait for.** Wiring
   `Letflow.Engine.Lua.Executor` into `Transition.dispatch_node/4` (a real
   `:SCRIPT`/`:LUA` node type, or a scripted-rule hook on an existing node
   type) is unscheduled S5-adjacent platform work with no filed requirement
   number. Blocking P3 on it would stall delivery of a vertical the pipeline
   is actively building for a capability nothing currently commits to
   building.
2. **The grading rules are fixed, not tenant-configurable, in the reference
   implementation itself** (Finding 1's second point, above). Since
   BilimBaga's own product never made these rules pack-authorable Lua, P3
   porting them as fixed Elixir functions is a faithful port, not a
   downgrade from a capability the source actually has.
3. **`0022` rule 3's own logic cuts this way too.** Building a
   `:SCRIPT`-node dispatch path now, only to justify this one grading
   feature, would be exactly the "platform capability invented
   speculatively" failure mode `0022`/REQ-333's own text warns against in
   the opposite direction — engineering generality nothing currently asks
   for, ahead of a real second caller.
4. **The two decisions are independent and this one is reversible.** If a
   later, real requirement wires pack-supplied Lua scripts into node
   dispatch for some other vertical or a later exam-grading revision, P3's
   `Letflow.Exam.Scoring` module can be superseded by that mechanism without
   having blocked anything in the meantime — the reverse (waiting now) is
   not reversible in the sense that it would delay P3 indefinitely against
   an unscheduled dependency.

**Where pack-supplied grading scripts would be audited — left open, but now
explicitly conditioned.** The stage file's own open question ("Where a
pack's Lua grading rules are audited... `SECURITY-REVIEWER` interest") is
**not** answered by this record, and is **not** answered by P3, because P3
builds no Lua-based grading path for this question to apply to. This record
states explicitly that the audit-path question is moot until the Finding-1
gap (a real node-dispatch path to `Letflow.Engine.Lua.Executor`) is closed by
some future requirement — at which point that requirement inherits both open
questions together, not just the audit one.

## Finding 2 — the anti-cheat storage open question, answered

**The question, quoted from `stage-10-bilimbaga-vertical.md`'s "Open
questions" section:** *"Anti-cheat scope. BilimBaga's roadmap includes
tab-focus and timing signals. Whether these are entity-record events,
`Letflow.EventStore` events, or neither is a P3 design question; deciding it
now would pre-empt gap 1's route shape."*

**Answer: entity-record events — the `session_event` entity REQ-329 already
defines, written through `Letflow.Entities.Records`, exactly like every other
P3 storage table.**

The three candidates, weighed:

1. **Entity-record events (`session_event`, an ordinary `Letflow.Entities.Records`-written
   row per signal).** Cost: one `EventStore` append per signal, which —
   re-verified in the design doc §3 — hits the same single per-entity-type
   `instance_sequence` row under `lock("FOR UPDATE")` every other entity
   write does, and a candidate can trigger the write at will (unmetered).
   Gains: per-event `occurred_at` is a real column; the row is queryable
   through the same `Letflow.Entities.Query` allowlist/redaction machinery
   every other P3 read already uses; it is the storage shape REQ-329
   (bucket A, `session_event`) **already defines** — REQ-329's own
   acceptance criteria (its entry in `docs/requirements.yaml`) require
   `event_type`, `occurred_at`, and `action_taken` fields on exactly this
   entity, so choosing anything else here would strand a bucket-A entity
   REQ-329 built for this exact purpose.
2. **Raw `Letflow.EventStore` events** (bypassing the entity/`Records` layer
   and appending a platform event directly). Cost: the requirement's own
   framing states this correctly — same lock class, same unmetered-write
   exposure, no cheaper. Gain: none over (1) for this data — the audit
   timeline `Letflow.EventStore` serves is for platform/business-object
   state transitions (`Letflow.Audit`'s own domain), and mixing
   candidate-triggered telemetry signals into it does not make that timeline
   more useful; it adds a foreign category of event to a stream every other
   platform consumer reads as "things that happened to durable records."
   Rejected: no cost advantage, and a real (if soft) cost to audit-timeline
   coherence for no offsetting benefit.
3. **"Neither" — an aggregate counter on the session record** (e.g.
   `session.tab_switch_count`, incremented in place). Cost: cheapest of the
   three — one `UPDATE` on a row the session already owns, no new
   per-signal row, no shared-sequence contention beyond what a normal
   session update already causes. Loss, stated by the requirement and
   confirmed here: it discards the per-event `occurred_at` the source table
   (`tab_switch_events`) stores and REQ-329 already carries forward, and the
   product's own `on_tab_switch: 'warn'` behaviour ("a warning flag with the
   running event count") is representable with a counter alone, but a
   `warn`-threshold policy stated in terms of *time* (e.g., "N events within
   M minutes") — which the roadmap's warn-threshold language leaves open —
   is not, once individual timestamps are gone. Rejected on that
   irreversibility: a counter can always be *derived* from per-event rows
   later; per-event timestamps can never be recovered from a counter after
   the fact.

**Chosen: (1), entity-record events, for the reasons above.** The
write-amplification exposure common to all three options is real and is
addressed by a bucket-C mitigation inside `lib/letflow/exam/anti_cheat.ex`
(design doc §7) — a per-session debounce check reading the most recent
`session_event.occurred_at` for that session before inserting a new one —
rather than by choosing a cheaper storage shape. This mitigation is
exam-specific application logic (a guard clause on an existing read/write
path), not a new platform capability, and stays inside the bucket-C module
REQ-333 builds.

## Consequences

- **REQ-332 and REQ-333 build against the design doc's module table
  unchanged in bucket** — no reclassification of the autosave, scoring, or
  anti-cheat *behaviours* results from this record. What changes is that
  REQ-332's scoring module is now built with an explicit, on-record reason
  for not waiting on Lua dispatch, and REQ-333's storage shape is no longer
  an open question its own requirement text has to re-litigate.
- **`0022`'s bucket table is not edited by this record.** Correcting its
  "auto-grading rules ... ships in the pack" row to reflect Finding 1 is
  editorial follow-on work against `docs/migration/decisions/0022-bilimbaga-vertical.md`
  itself, out of this record's scope fence (this record leaves `0022`
  byte-identical) — REQ-334 or a later requirement should make that
  correction explicitly rather than leaving the two records in silent
  tension.
- **`stage-10-bilimbaga-vertical.md`'s "Open questions" section is not
  edited by this record either.** REQ-334 (`DOC-UPDATER`) is the requirement
  that updates it; the design doc (`req330-exam-live-session.md` §9) states
  the exact replacement text for the anti-cheat bullet and adds the
  Lua-dispatch gap as a new bullet, for REQ-334 to paste in.
- **No code changes anywhere.** This record produces no implementation;
  `git diff --name-only` shows only this file and
  `lib/letflow/design/req330-exam-live-session.md` as new.

## What this record does not decide

- **Whether or when a real `:SCRIPT`/`:LUA` node-dispatch path is built.**
  That is unscheduled, unowned S5-adjacent platform work this record
  neither files nor assumes a number for.
- **Where pack-supplied grading scripts would be audited**, left explicitly
  open and explicitly conditioned on the above (see Finding 1's "Decision"
  section).
- **Any change to `0022`'s bucket table text itself** — flagged as stale
  against Finding 1, not corrected here.
- **Any HTTP route, `web/` screen, or certificate-issuance mechanism** — all
  out of scope for every S10 P3 requirement per the stage file and per
  decision `0022`/`0027`.

## SECURITY-REVIEWER sign-off

**Verdict: PASS, with two follow-ups flagged for REQ-332/REQ-333's own
implementation gates (not blockers on this design record).**

**Scope test, run explicitly.** This diff (`git status --porcelain` on
`feature/WF02-REQ330-20260913`) shows exactly two untracked files —
`lib/letflow/design/req330-exam-live-session.md` and this record — no
tracked file carries a diff, and `git diff --name-only` against `main` is
empty (nothing to diff; both files are new and untracked, confirmed by
`git status --porcelain` alone). Neither file contains a function body,
migration, or route (re-confirmed independently below, §5). Even so, this
is a tenant-data-path handoff, not a no-op: this record and the design doc
it accompanies are the artefact REQ-332/REQ-333 build `Letflow.Exam.*`
against, per decision `0022` rule 2 — a design-level tenant-isolation
shortcut or an unflagged capacity gap here would ship silently once
implementation starts, since REQ-332/REQ-333 cite this record rather than
re-deriving these questions themselves. Reviewed as a design-time/policy-time
gate, same framing as `0027`'s own SECURITY-REVIEWER section.

**INV-1 (tenant data isolation) — APPLIES, PASS.** Re-read the module table
(design doc §8) directly rather than taking its own framing on trust: every
`@spec` across all four proposed modules (`Session.create/3`,
`get_session_for_user/3`, `autosave_answer/4`, `submit/3`,
`finalize_expired/3`; `QuestionSetResolver.resolve/5`;
`Scoring.score_question/2`, `score_session/3`; `AntiCheat.record_signal/4`)
that touches tenant data carries an explicit `prefix :: String.t()`
parameter, consistent with `0003`'s Dimension B mechanism (schema-per-tenant
via Ecto `:prefix`) rather than a bare `tenant_id` predicate or an
unscoped lookup. No interface resolves a session, question, or event by ID
alone without a `prefix` alongside it — `get_session_for_user/3` requires
both `user_id` and `prefix` (ownership plus schema scoping, not one
standing in for the other), and `finalize_expired/3`'s omission of
`user_id` is explained and justified in-text (§8: "the caller is the
sweep, not a candidate") rather than a silent gap — it still carries
`prefix`. No shortcut found.

**INV-4/INV-7/INV-9 — NOT APPLICABLE.** No secret material, no raw SQL, and
no outbound-URL construction appears anywhere in either document — both are
pure `@spec`-shape interface sketches and prose. Confirmed by reading both
files in full, not by grep alone.

**INV-2/INV-3/INV-5 — NOT APPLICABLE**, per the applicability note in
`security-invariants.md` (S4/S5 not started). Flagged for completeness only:
Finding 1's Lua-dispatch gap is exactly the kind of thing INV-3 will apply
to once S5 lands, but building nothing today means there's nothing INV-3
can gate yet (see below).

**INV-8 — APPLIES at the design-interface level, PASS.** Every `@spec` in
§8 returns a tagged tuple (`{:ok, _} | {:error, _}`) with an enumerated
error-atom union, not a bare value that could raise on a realistic failure
path — `autosave_answer/4`'s seven-member `autosave_error()` union in
particular shows the tagged-result discipline is being carried into the
design rather than deferred. Nothing to flag; re-verify at ELIXIR-DEV's
implementation gate that these unions are exhaustively pattern-matched.

**Finding 1 (Lua-dispatch gap) — confirmed a genuine unbuilt capability, not
a partially-wired, partially-secured mechanism.** Read
`lib/letflow/engine/lua_script_audit.ex`'s moduledoc directly (lines 1-41):
it states its own scope in exactly the terms this record quotes — "a
MINIMAL, deliberately narrow engine-side call path," "It is NOT the
SERVICE_TASK script-execution handler," and its own `## No caller yet`
heading: "nothing in this codebase calls `execute_script_for_audit/6`."
That framing is unchanged and still accurate as of this review, and it does
not contradict this record's Finding 1 — the two describe the same fact
from two sides (the audit wrapper documents its own non-wiring; this record
documents that `Letflow.Engine.Transition.dispatch_node/4` never reaches
either it or the real `Letflow.Engine.Lua.Executor`). There is no dispatch
path here that is half-secured or reachable-but-unaudited — it is simply
absent. Nothing exploitable follows from writing exam scoring as bucket-C
Elixir instead of waiting on it. PASS.

**Write-amplification / capacity concern (behaviour 3, autosave) — flagged,
not a blocker on this record, but a real gap this record should not let
pass without naming.** The design's own arithmetic (~33 writes/sec at 500
concurrent sittings, 15-second client interval, against a lock that clears
roughly two orders of magnitude more) is reasonable **as a measurement of
the well-behaved-client case**, and I don't dispute the arithmetic itself.
But the 15-second figure is stated as "BilimBaga's own client behaviour" —
i.e. a *client-side* convention — and neither document identifies any
**server-side** rate limit, debounce, or per-caller throttle on the
ordinary `Letflow.Entities.Records`/`Letflow.Entities.Query` autosave write
path itself (distinct from the anti-cheat path, which does specify one —
see below). A malicious or simply buggy client that autosaves at, say,
10/sec instead of 1-per-15-sec multiplies one candidate's contribution to
the shared `instance_sequence` lock roughly 150x; at that ratio the
"two orders of magnitude" headroom the design leans on is consumed by a
**single** misbehaving client, before any other candidate in the tenant is
considered. This is a real write-amplification/DoS surface against a
shared-fate resource (one lock per entity type per tenant, per §3's own
finding), and it is currently unaddressed by anything in this design or in
the generic `Letflow.EventStore`/`Letflow.Entities` write path this design
correctly declines to modify. **This does not block this record**, because
(a) the design is explicit and correct that inventing a bucket-C or
bucket-B fast path here now would be speculative ahead of measurement, and
(b) the generic mechanism, not `lib/letflow/exam/`, is the right layer to
carry a rate limit if one is ever added. But it is an unaddressed gap, not
a closed question, and REQ-332's own implementation and test design should
either (i) add a per-session server-side rate limit/debounce to
`autosave_answer/4` analogous to `AntiCheat.record_signal/4`'s, or (ii)
explicitly accept the residual DoS exposure with a stated reason, rather
than silently inheriting "33 writes/sec is fine" as a load-bearing security
conclusion it never actually was.

**Anti-cheat debounce (behaviour 5) — assessed as a real, server-side
mitigation as specified, not merely asserted, but not yet built.** Design
doc §8 is explicit about mechanism, not just outcome: `record_signal/4`'s
private `debounce_ok?/2` helper "reads the most recent
`session_event.occurred_at` for `session_id`" via "an ordinary
`Letflow.Entities.Query` read" — a **server-side** check against
persisted state, evaluated on every call regardless of what the calling
client does or claims, not a client-side interval the client could ignore
or fake. That is a real mitigation shape, structurally sound: a client
that fires the same signal 1000×/sec still produces at most one accepted
write per debounce window, because the gate reads the database's own
last-write timestamp rather than trusting anything the client sends. Two
things are correctly still open, and this record already says so — the
concrete debounce window length is unspecified (left as "a configured
debounce window," a REQ-333 implementation-time value, not a design-time
security defect), and the design doc itself already requires this behavior
"be proven by a test, not merely asserted" (§8). I confirm that requirement
should stand as-is at TEST-DESIGNER's gate — this sign-off does not
consider the mitigation real until that test exists and passes; the
mechanism as specified is sound, but nothing in `lib/letflow/exam/` has
been written yet for it to be true of. No design-level gap found here
beyond what the design already flags.

**Module-table tenant-isolation shortcut check (§8, item 4 of my brief) —
none found.** See INV-1 analysis above; no interface bypasses `prefix`,
and no interface resolves a record by a caller-supplied `tenant_id` field
distinct from the resolved prefix (0003's addendum concern) — none of the
four modules' specs take a `tenant_id` parameter at all, only `prefix`.

**No implementation code found in either document — re-confirmed
independently.** Read both files in full (not sampled): every code block in
`req330-exam-live-session.md` is a `@type`/`@spec` declaration or a quoted
excerpt from *existing* Letflow/BilimBaga source cited as evidence, never a
new function body; `0030` itself contains no code blocks at all beyond
quoted excerpts of existing files. `git status --porcelain` shows only the
two new files as untracked, no tracked file modified.

**Overall: PASS.** Two follow-ups carried forward, by name, for later
requirements to close rather than for this design record to solve: (1) the
autosave path has no server-side rate limit analogous to the anti-cheat
debounce — REQ-332 should either add one or explicitly accept the residual
DoS exposure; (2) the anti-cheat debounce is a sound mechanism as specified
but is unimplemented and untested as of this review — REQ-333/TEST-DESIGNER
must not treat it as mitigated until the test the design doc itself already
demands exists and passes.

— SECURITY-REVIEWER, 2026-09-13

## REVIEWER sign-off

**Verdict: PASS (2026-09-13, `REVIEWER`, REQ-330).**

**1. Decision-record consistency — `0022`.** Read `0022` in full, including
the bucket table (`## Reasoning` § the `BilimBaga` / `Letflow mechanism` /
`Bucket` table, line 96) and the "not a process instance" paragraph (lines
156-165). This record does not silently re-decide either. The "not a process
instance" paragraph is cited by the design doc (§1, Evidence 3) and used
correctly, not worked around: §1's deadline-enforcement verdict is reached
*because* a `:TIMER` node requires a running `Letflow.Engine` instance and the
session is permanently not one, and the module table (design doc §8) confirms
`Letflow.Exam.Session` is a plain module with ordinary functions (`create/3`,
`autosave_answer/4`, `submit/3`) — no `gen_statem`, no supervised process, no
`spawn`. Nothing here reopens REQ-045's process-vs-row decision.

The Lua-grading correction (Finding 1) is the one place this record's content
genuinely conflicts with `0022`'s existing bucket-table text ("auto-grading
rules ... ships *in the pack*" — bucket A), and it is handled the right way:
filed as a **named finding in `0030`** ("a previously-unrecorded gap between
`0022`'s bucket table and the platform"), with `0022`'s own file left
byte-identical (`0030`'s "Consequences" section says so explicitly, and I
confirmed `0022` carries no uncommitted diff — `git status --porcelain` shows
only the two new files). Correcting `0022`'s table text itself is correctly
deferred to REQ-334/a later requirement rather than done here or in the design
doc. This is the proper shape: a disagreement with standing text becomes a
decision-record finding, not a quiet edit and not a footnote in a design doc
with no record trail. I independently re-verified Finding 1's central claim
rather than taking it on trust — see §4 below.

**2. Consistency with `stage-10-bilimbaga-vertical.md`'s open questions.**
Read the "Open questions" section directly (lines 186-192). It asks exactly
two things: (a) "Anti-cheat scope... Whether these are entity-record events,
`Letflow.EventStore` events, or neither is a P3 design question," and (b)
"Where a pack's Lua grading rules are audited... a `SECURITY-REVIEWER`
interest." `0030` Finding 2 answers (a) directly and narrowly — entity-record
events, via `Letflow.Entities.Records`, with the other two candidates weighed
and rejected on stated grounds (no cost advantage / audit-timeline
incoherence for raw `EventStore`; irreversible loss of per-event `occurred_at`
for the counter). It does not substitute a different question for the one
asked (e.g. it does not just restate "storage is bucket A, REQ-329 already
decided this" without weighing the alternatives — the three-way comparison is
real). `0030` Finding 1 correctly does **not** answer (b) — it explicitly
states the audit-path question stays open, now conditioned on a future,
unscheduled node-dispatch requirement — which is the honest answer given
Finding 1's own conclusion that no Lua-based grading path exists for (b) to
apply to yet. Design doc §9's proposed replacement text for REQ-334 matches
this record's own answers to both questions verbatim in substance. No
question is dodged, narrowed, or answered with something adjacent.

**3. Idiom/rigor against precedent.** Compared against
`lib/letflow/design/req308-entity-http-surface.md` (694 lines, S10, prior
accepted design covering route surface, permissions, the query DSL, tenant
scoping, pagination, error shaping, and its own SECURITY-REVIEWER section).
`req330-exam-live-session.md` (682 lines) matches that bar: numbered sections
with a defined scope per section, verbatim-quoted evidence from the actual
tree (not paraphrased), an explicit sources/citations section (§0), a
rule-1 vocabulary self-check with actual grep output (§10), and a "what this
design does not decide" closing section (§11) naming exactly what is deferred
and to which requirement. The four-module interface table (§8) is at the same
`@spec`-only rigor as req308's route/permission tables. Nothing here reads as
thinner, and the decision record's own SECURITY-REVIEWER section is written
at the same evidentiary density as `0027`'s.

**4. Re-verification of the two corrected defects.** Ran independently rather
than trusting CODE-DESIGN-VALIDATOR's re-check:

```
$ grep -n "node_type: :" lib/letflow/engine/transition.ex
```

returns clauses for exactly eight distinct `node_type` values —
`:START`, `:END`, `:HUMAN_TASK`, `:EXCLUSIVE_GATEWAY`, `:PARALLEL_GATEWAY`,
`:SUB_PROCESS`, `:TIMER`, `:SERVICE_TASK` (two of the eleven matched lines are
a second `:HUMAN_TASK`/`:TIMER` clause pair and one `:PARALLEL_GATEWAY` helper
clause elsewhere in the file, not new node types). Both documents now say
"eight" (design doc §4, decision `0030` Finding 1) and both lists name the
same eight values in the same order — matches the code exactly. The
previously-reported wrong count is fixed and consistent between both
documents.

The FR-BB37/FR-BB39 citation (design doc §1, opening line: "**Source:
FR-BB37/FR-BB39, roadmap 3.7/3.9 — `service.go`'s `SaveAnswer` and
`SubmitSession`.**") is present and reads sensibly in context: §0's sources
list already explains why deadline enforcement is cited under both
identifiers rather than one ("the reference implementation embeds the
deadline check inside this write path rather than a standalone function"),
and §1's own text reiterates the same reasoning immediately below the
citation before proceeding to the three numbered evidence pieces. This is not
a bare citation dropped in without support — it is explained twice, once at
the source-catalog level and once in the section that uses it.

**5. Module-table justifications, read fresh.** All four bucket-C
justifications hold up under independent re-reading, not rubber-stamped:

- `Letflow.Exam.Session` — genuinely stateful multi-step orchestration
  (ordered eligibility checks, ownership-checked write paths, wall-clock
  deadline comparison). Not a definition; not generalizable without naming
  this vertical's eligibility rule set. Agree.
- `Letflow.Exam.Scoring` — five fixed grading rules over a vertical-specific
  question-type taxonomy, with Finding 1 now on record establishing there is
  no generic scripting capability to route through today. Agree; the
  bucket-C classification rests on a stronger basis than the design's
  starting position did.
- `Letflow.Exam.AntiCheat` — a live conditional deriving a side effect from
  vertical-specific config and vocabulary (`tab_switch`/`blur`/
  `fullscreen_exit`, `on_tab_switch` policy). Not a definition; the "why not
  B" argument correctly identifies that a maximally generic
  "signal-triggered record transition" abstraction would have exactly one
  caller today — the speculative-generality failure mode `0022` exists to
  prevent. Agree.
- `Letflow.Exam.QuestionSetResolver` — this is the one I pushed on hardest,
  since "resolve a seeded reproducible subset from a configured pool" reads,
  at first glance, more like a shape a query/selection utility could
  generalize than the other three do. On a closer read, the "why not B"
  argument does not rest on "nobody else needs this" alone (which would be a
  weak, speculative-future argument) — it rests on the concrete mechanics
  bucket B requires being genuinely coupled to this vertical's schema today:
  two independent shuffle steps (`shuffle_questions?` and `shuffle_options?`
  as separate flags, not one generic "shuffle" toggle), a pool/rule/count
  model shaped by this vertical's specific `rules :: [%{pool_id, count}]`
  configuration, and — per design doc §8 — a hard non-goal against
  byte-identical reproducibility with the Go reference implementation's
  PRNG, meaning even the "reproducible subset" property itself is scoped to
  this vertical's own semantics rather than a portable contract. I do not
  find an existing platform abstraction this could be pulled toward today (no
  generic "seeded sample from a named pool" capability exists elsewhere in
  `lib/letflow/`), and building one now, ahead of a second caller, would be
  exactly the inverted version of the mistake `0022` rule 3 warns against.
  This verdict should be watched, not overturned: if a second vertical ever
  needs seeded-pool sampling, that is the moment to extract a bucket-B
  capability, not before. Agree with CODE-DESIGNER's verdict, on independent
  grounds.

**6. Scope check.** `git status --porcelain` shows exactly two untracked
files — `lib/letflow/design/req330-exam-live-session.md` and this record.
`git diff --name-only` (against the index and against `main`) is empty.
Nothing under `lib/letflow/exam/` exists yet; no implementation code appears
in either document (re-confirmed by reading both in full — every code block
is an `@type`/`@spec` shape or a verbatim-quoted excerpt of existing source,
never a new function body, matching SECURITY-REVIEWER's own independent
finding above).

**7. SECURITY-REVIEWER's two follow-ups — legible enough to survive to
REQ-332/REQ-333.** Both are named, not buried: the autosave capacity gap is
stated as a numbered, titled paragraph ("Write-amplification / capacity
concern (behaviour 3, autosave)") ending in a concrete two-option instruction
("REQ-332's own implementation and test design should either (i) add a
per-session server-side rate limit/debounce ... or (ii) explicitly accept the
residual DoS exposure with a stated reason"), and repeated in the "Overall"
summary paragraph by number. The anti-cheat debounce follow-up is similarly
titled, states plainly that the mechanism is "unimplemented and untested as
of this review," and gives TEST-DESIGNER/REQ-333 an explicit non-negotiable
("must not treat it as mitigated until the test the design doc itself already
demands exists and passes"). Both are also cross-referenced from the design
doc itself (§8, on `record_signal/4` and `debounce_ok?/2`) and from decision
`0030`'s own Finding 2 text, so a reader of any of the three documents lands
on the same two open items. Neither reads as vague or easy to miss when
REQ-332/REQ-333 are scoped.

**No defects found. This gate PASSes.** Ready for ORCH to commit/push/merge.

— REVIEWER, 2026-09-13
