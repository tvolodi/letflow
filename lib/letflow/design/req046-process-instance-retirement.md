# Design: REQ-046 — Retirement of `process_instance.ex`; retention of `instance_supervisor.ex`

**Requirement:** REQ-046 (`docs/requirements.yaml`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ046-20260818`, WF-02 Step 1
**This document produces:** the concrete delete/retain call for both modules (REQ-045
left it resolved-in-principle, not yet executed), the concrete disposition of
`Letflow.Events.TransitionEvent` and its migration, the exact resulting
`lib/letflow/application.ex` shape, the test-migration plan for
`test/letflow/process_instance_test.exs`, and AC4's not-applicable justification. No
implementation code — deletion/edit plan and shapes only, matching req043/044/045's
convention.

---

## 0. Sources read for this design

Read in full: `docs/guides/backend_developer_guide.md`;
`lib/letflow/design/req045-instance-start-engine-shell.md` (§1, §2 — the
process-vs-row decision and its explicit statement of which module this requirement,
REQ-046, owns); `lib/letflow/process_instance.ex`; `lib/letflow/instance_supervisor.ex`;
`lib/letflow/application.ex`; `lib/letflow/parallel_approval.ex`'s moduledoc (the
`ApprovalSupervisor`-vs-`InstanceSupervisor` separation precedent); `lib/letflow/events/
transition_event.ex`; `priv/repo/migrations/20260814000001_create_transition_events.exs`;
`test/letflow/process_instance_test.exs` (the only test file referencing
`Letflow.ProcessInstance`/`Letflow.InstanceSupervisor`/`Letflow.Events.TransitionEvent`,
confirmed by grep across `test/` — the two other hits, `test/specs/REQ-015.md` and
`test/specs/REQ-016.md`, are unrelated prose mentions, not code references);
`test/letflow/engine_test.exs` (confirmed to exist — REQ-045's own coverage of
`Letflow.Engine.create/2`, the replacement path); `test/letflow/parallel_approval_test.exs`
(confirmed to already carry the crash-isolation test, independent of
`InstanceSupervisor` — see §6).

---

## 1. Decision: `lib/letflow/process_instance.ex` — DELETE

REQ-045 §1 already classified this module **SUPERSEDED, not extended**: its hardcoded
four-atom state graph is replaced by REQ-027 definition data + REQ-044's `Transition`
kernel, and its `transition/5` persistence job is replaced by `Letflow.Engine.create/2`'s
`Ecto.Multi`. REQ-045 §1 states explicitly: "`Letflow.ProcessInstance` itself is not
deleted by this requirement (REQ-046 ... owns physically removing it)." This requirement
carries that out.

**Retain-with-documentation is rejected** as the alternative, for two concrete reasons:

1. REQ-045's own moduledoc-content requirements (§2) already state the
   supersession/disposition story in `Letflow.Engine`'s moduledoc — the "why does the old
   module still exist" narrative already lives in the *current* engine's own
   documentation, matching this codebase's practice for a completed supersession (compare:
   `req043`'s Token/TokenRecord rename left no explanatory stub at the old name once
   resolved). A second explanation bolted onto the old module would duplicate, not
   supplement, that narrative.
2. `Letflow.ProcessInstance` has no remaining role. It is not read by, written by, or
   referenced from any other shipped module (confirmed: only
   `Letflow.InstanceSupervisor` and `test/letflow/process_instance_test.exs` reference
   it — the former edited, not deleted, by this same requirement (§2), the latter
   deleted (§4)). A "retained module" with zero live callers and zero remaining purpose
   is exactly the "undocumented and unreferenced" failure mode AC1's own text warns
   against, just with a moduledoc paragraph papering over it rather than preventing it.
   This reasoning is specific to `process_instance.ex` itself — §2 below reaches a
   different conclusion for `instance_supervisor.ex`, which is *not* zero-purpose in the
   same sense: it carries a forward-looking, already-recorded reservation for
   REQ-056/REQ-057, not a stale reference to a dead module.

**Action:** delete `lib/letflow/process_instance.ex` in full.

---

## 2. Decision: `lib/letflow/instance_supervisor.ex` — RETAIN, edited (not deleted)

**This section supersedes this design's prior conclusion ("retire, not generalize"),
which CODE-DESIGN-VALIDATOR correctly FAILed.** The prior version cited only
`lib/letflow/design/req045-instance-start-engine-shell.md` (a planning artefact) as
grounds for deletion and never reconciled `lib/letflow/engine.ex`'s actual shipped
moduledoc, which makes a forward-looking, already-recorded promise this design must not
silently break. Quoting the real text (`lib/letflow/engine.ex` lines 31-36, confirmed by
direct read):

> `lib/letflow/instance_supervisor.ex` is **generalized, not superseded** — but not by
> this requirement, since this requirement introduces no process for it to supervise.
> Its `DynamicSupervisor` shape is confirmed still correct in principle for whichever
> later S3 requirement (REQ-056/REQ-057) does need a supervised process.
> `Letflow.Engine` does not modify `instance_supervisor.ex` at all.

`test/letflow/engine_test.exs`'s AC5 describe block (lines 702-707) asserts this exact
text via `Code.fetch_docs`, so it is load-bearing on the currently-passing suite, not
just prose.

**Decision: retain the module (Path A), not reverse the recorded decision (Path B).**
Reasoning:

1. **Cost of retention is genuinely near-zero.** The file is 21 lines, a bare
   `DynamicSupervisor` scaffold. Keeping it does not entail maintaining a parallel state
   machine, a duplicated schema, or any ongoing complexity tax — the concern
   CLAUDE.md's "don't design for hypothetical future requirements" rule is actually
   protecting against (speculative *behavior*, not an idle supervisor shell). There is no
   real "premature abstraction" cost here to weigh against the recorded decision.
2. **Reversal cost is real and requirement-scope-widening.** Path B would require
   editing `lib/letflow/engine.ex` (a REQ-045-owned, already-shipped/merged file — out of
   this requirement's stated scope, "the retirement of `process_instance.ex` /
   `instance_supervisor.ex`", not "revise REQ-045's engine module"), correcting/removing
   `engine_test.exs`'s AC5 assertion (REQ-045's own already-validated test coverage), and
   mandatorily routing through REVIEWER as a decision-reversal gate before ELIXIR-DEV
   could even start. All of that to save keeping one 21-line file inert for a handful of
   requirements' duration. That is a worse trade than doing nothing.
3. **`DynamicSupervisor.start_link/2` with zero children at boot is normal, not a
   defect.** `DynamicSupervisor.init(strategy: :one_for_one)` does not require any
   children to be specified — a `DynamicSupervisor` is designed to start empty and
   accept children later via `start_child/2`; this is its whole reason for existing
   (contrast `Supervisor`, which lists static children at init). An empty
   `DynamicSupervisor` in the tree is exactly as legitimate a supervision-tree shape as
   one with children — confirmed against `DynamicSupervisor`'s own documented semantics,
   not assumed.
4. **AC2's dichotomy ("starts REQ-045's engine, or is retired with a recorded reason,
   not left supervising a superseded module") is satisfiable by a third, unnamed
   reading that better matches what's actually true today:** the module does not
   "supervise a superseded module" under this design, because after the edit below it
   supervises *nothing* — superseded or otherwise. AC2's actual concern (a supervisor
   silently left pointed at dead code, undocumented) is fully addressed: nothing dead is
   referenced, and the "why idle" reason is stated explicitly in the module's own
   moduledoc, not left implicit.

**Does the `ApprovalSupervisor`-vs-`InstanceSupervisor` separation precedent still make
sense with `InstanceSupervisor` idle?** Yes. `lib/letflow/parallel_approval.ex`'s
moduledoc states the reason for the split: `Letflow.ApprovalSupervisor` is "a separate
`DynamicSupervisor` from `Letflow.InstanceSupervisor`, since [`ParallelApproval`] is a
structurally different workflow, not a variant of `Letflow.ProcessInstance`." That
reasoning is about topology-by-workflow-type — two structurally different workflows get
two separate supervision trees — and was never contingent on `InstanceSupervisor`
actually holding live children at any given moment. It stays coherent whether
`InstanceSupervisor` is idle or populated; the split exists so that when REQ-056/REQ-057
eventually populate it, `ParallelApproval` processes are not caught up in that
supervisor's restart semantics, and vice versa.

**Action:** keep `lib/letflow/instance_supervisor.ex`, with two edits:

1. Remove `start_instance/1` (lines 17-20). It calls
   `Letflow.ProcessInstance.child_spec(id)` directly, which stops compiling once §1
   deletes `process_instance.ex`; there is nothing today for it to start instead (no
   process exists per REQ-045 §1), so the function is deleted outright rather than
   rewritten against a nonexistent target. REQ-056/REQ-057 add a real `start_instance/1`
   back against their own child spec when a supervised process actually exists — this is
   their decision to make, not a stub for this requirement to guess at.
2. Replace the moduledoc with (shape, not implementation — this is prose content, not
   code the module executes):

   > `DynamicSupervisor` reserved for per-process-instance processes.
   >
   > Currently supervises no children. REQ-045 resolved the S3 running-instance shape to
   > a plain transactional context module (`Letflow.Engine.create/2`), not a supervised
   > process, so there is nothing for this supervisor to own yet. It is deliberately
   > retained rather than deleted, per `Letflow.Engine`'s own moduledoc (REQ-045 AC5):
   > "`instance_supervisor.ex` is generalized, not superseded ... its `DynamicSupervisor`
   > shape is confirmed still correct in principle for whichever later S3 requirement
   > (REQ-056/REQ-057) does need a supervised process." REQ-046 does not reverse that
   > recorded decision — see `lib/letflow/design/req046-process-instance-retirement.md`
   > §2 for the full reasoning.
   >
   > `start_instance/1` was removed by REQ-046 alongside `Letflow.ProcessInstance`'s own
   > deletion (its only caller). A real `start_instance/1` is added back by whichever of
   > REQ-056/REQ-057 introduces the first supervised instance process, against that
   > requirement's own child spec — not reconstructed speculatively here.

   The resulting module therefore keeps only `start_link/1` and `init/1` (unchanged) plus
   this moduledoc — a deliberately-idle scaffold, not a stub with dead code inside it.

**`lib/letflow/application.ex`:** unchanged — `Letflow.InstanceSupervisor` stays in the
`children` list (§5 below). No REVIEWER gate is required for this path: it does not
reverse, edit, or touch REQ-045's `engine.ex` moduledoc or `engine_test.exs` at all, so
nothing recorded is being overridden — the opposite of Path B's situation.

---

## 3. Decision: `Letflow.Events.TransitionEvent` and its migration — RETIRE

REQ-045 §1 deferred this explicitly: *"Retiring it is REQ-046's job, bundled with
`process_instance.ex`'s own removal (deleting the table out from under a still-shipping
module would break it first) — not this requirement's."* `process_instance.ex` is no
longer shipping after §1, so the precondition REQ-045 set for deferring this is now
satisfied and this requirement executes it.

`TransitionEvent` has exactly one reader/writer in the entire codebase:
`process_instance.ex`'s own `transition/5` (write) and
`test/letflow/process_instance_test.exs`'s "every successful transition is persisted"
test (read) — confirmed by grep, no other hit. Both are removed by this requirement
(§1, §4), so nothing is left to use the `transition_events` table.

**Action:**
- Delete `lib/letflow/events/transition_event.ex` in full.
- Add one new migration, `priv/repo/migrations/<timestamp>_drop_transition_events.exs`,
  whose `change/0` is `drop table(:transition_events)` — a single reversible operation
  (Ecto auto-generates the down-migration's `create table` from the same call), matching
  §3.7 of the backend guide ("additive and reversible"; a `drop table/1` inside `change/0`
  is Ecto's own reversible idiom, not a hand-written `up/0`+`down/0` pair). Do **not**
  edit or delete `20260814000001_create_transition_events.exs` itself — migrations are
  an append-only historical record in this codebase (implied by every existing migration
  file being additive-only, and matching the event-store's own insert-only philosophy
  from Decision 0003/0006); retiring a table is itself a new migration, not a rewrite of
  history.
- If any `Letflow.Events` namespace module besides `TransitionEvent` exists under
  `lib/letflow/events/`, it is out of scope — this requirement touches only
  `transition_event.ex` (confirmed by glob: `lib/letflow/events/transition_event.ex` is
  the only file matching `**/transition_event*`; no sibling files were found under
  `lib/letflow/events/` during this design's read).

---

## 4. Test migration plan: `test/letflow/process_instance_test.exs`

**Action: delete the file in full.** Not "migrate onto `Letflow.Engine.create/2`" —
the two are not equivalent shapes to migrate test-by-test:

- `Letflow.ProcessInstance` is a hardcoded 4-state approval workflow
  (`draft/submitted/approved/rejected`) with a fixed action set
  (`submit/approve/reject/resubmit`). `Letflow.Engine.create/2` starts a
  *definition-driven* instance against an arbitrary graph (REQ-027/028 data) — there is
  no "one true definition" whose start behavior corresponds 1:1 to
  `process_instance_test.exs`'s five cases. Rewriting them as `Engine.create/2` calls
  would mean inventing a specific test-fixture graph shaped like the old 4-state machine,
  which would test that invented fixture, not any real replaced behavior.
- The behavior these tests actually protected — "a definition-driven instance starts
  correctly, persists correctly, rejects illegal input correctly, and cannot reach an
  invalid state" — is already covered by `test/letflow/engine_test.exs` (REQ-045's own
  test suite, confirmed to exist, §0) for the real replacement path. Re-deriving
  equivalent coverage a second time under this requirement would duplicate REQ-045's own
  already-validated test design, not extend it.
- Per-test disposition (all five test cases in the file, all deleted for the same reason
  — the module under test no longer exists):
  1. `"the happy path: draft -> submitted -> approved"` — deleted; superseded by
     `engine_test.exs`'s instance-creation/advancement coverage.
  2. `"reject then resubmit loops back to draft"` — deleted; no analogous transition
     exists in the graph-driven engine's vocabulary (gateways/tasks, not named
     approve/reject actions) — nothing to migrate onto.
  3. `"an action illegal in the current state is rejected, not silently accepted"` —
     deleted; the graph-driven engine's equivalent illegal-input protection is
     `engine_test.exs`'s `create/2` error-path coverage (REQ-045 AC1-AC4).
  4. `"every successful transition is persisted to Postgres"` — deleted; the table it
     queries (`transition_events`) no longer exists after §3. The equivalent guarantee
     for the real engine — every write happens inside the `Ecto.Multi`/atomic phase — is
     `engine_test.exs`'s own atomicity coverage (REQ-045 AC1).
  5. `property "no sequence of actions produces an invalid state"` — deleted; this
     property was specific to the old fixed 4-atom state set. `Letflow.Engine`/
     `Transition`'s own "never raise" totality discipline (req044's design) is the
     analogous guarantee for the new engine, already the subject of req044's own test
     design, not something this requirement re-derives.

**Stated reason for the commit/PR** (required by AC3's "no test is deleted merely to
make the suite green without stating why"): *"`process_instance_test.exs` deleted in
full — every test in it exercised `Letflow.ProcessInstance`, a module removed by this
requirement (REQ-045's already-recorded supersession); the replacement engine's
equivalent behavior is covered by `test/letflow/engine_test.exs`, not re-derived here."*

No new test file is added by this requirement's own design — `Engine.create/2`'s
coverage is REQ-045/TEST-DESIGNER's prior responsibility, already discharged.

---

## 5. `lib/letflow/application.ex` — resulting supervision tree

Current `children` list (line 12-27):

```
Letflow.Repo,
{Ecto.Migrator, ...},
{Oidcc.ProviderConfiguration.Worker, ...},
{Registry, keys: :unique, name: Letflow.Registry},
Letflow.InstanceSupervisor,
Letflow.ApprovalSupervisor,
{Letflow.SandboxPool, []}
++ http_child()
```

**Change: none.** Per §2's revised decision, `Letflow.InstanceSupervisor` is retained,
not deleted, so it stays in the `children` list unmodified. It boots as an empty
`DynamicSupervisor` (zero children at start, per §2 point 3 — a normal, documented
`DynamicSupervisor` shape, not an error condition) and stays empty until REQ-056/REQ-057
give it something to supervise.

- `{Registry, keys: :unique, name: Letflow.Registry}` **stays** — `Letflow.ApprovalSupervisor`
  /`Letflow.ParallelApproval` still register under it via `{:via, Registry,
  {Letflow.Registry, {:approval, id}}}` (`parallel_approval.ex` line 53). No key
  changes: the only keys ever registered under `Letflow.Registry` by
  `Letflow.ProcessInstance` were bare `id` strings (`process_instance.ex` line 60); those
  simply stop being produced once the module is deleted. `Letflow.InstanceSupervisor`
  itself never registered under `Letflow.Registry` (it only ever held `ProcessInstance`
  children via `DynamicSupervisor.start_child/2`, not `:via` registration), so retaining
  it introduces no registry-key behavior at all. `Letflow.ApprovalSupervisor`'s
  `{:approval, id}`-tuple keys are untouched and remain the only keys registered after
  this change.
- `Letflow.ApprovalSupervisor` **stays**, unmodified — out of this requirement's scope
  entirely (it supervises `ParallelApproval`, a structurally different, still-current
  workflow per its own moduledoc, §0, §2).

---

## 6. AC4 (supervised isolation) — NOT APPLICABLE, with existing coverage cited

REQ-045 resolved EE-01's running-instance shape to a plain transactional context module
(§1 of that design) — there is no per-instance process for this requirement's own scope
to isolate. AC4's "demonstrated by a test, or explicitly stated as not-applicable if
REQ-045 resolved to a row-based engine" condition is met by the second branch: **not
applicable**, for the shape this requirement produces.

The general *system* guarantee AC4 is protecting — "killing one instance's process does
not affect another" — is not lost from the codebase by this requirement: it remains
demonstrated today by `test/letflow/parallel_approval_test.exs`'s existing test, `"killing
one instance's process does not affect a sibling instance's state"` (confirmed present at
`parallel_approval_test.exs:72`, §0), which exercises `Letflow.ApprovalSupervisor` +
`Letflow.ParallelApproval` — a supervision pairing this requirement does not touch. This
requirement does not add a new instance of that guarantee (there is no process to add one
for) and does not remove the existing one.

---

## 6a. `lib/letflow/router.ex` — required disposition (gap found by ELIXIR-DEV at Step 2a)

**Not covered by §0's source list or by REQ-046's own requirement text** — `router.ex`
was never read during the original design pass. It is live production code
(`lib/letflow/application.ex`'s `http_child()` wires `{Bandit, plug: Letflow.Router,
...}` into the supervision tree, confirmed by direct read) and its two non-health routes
call every symbol §1/§4 delete: `POST /instances` calls
`Letflow.InstanceSupervisor.start_instance/1` (removed by §2), `POST
/instances/:id/actions` and `GET /instances/:id` call
`Letflow.ProcessInstance.submit/1`/`.approve/1`/`.reject/1`/`.resubmit/1`/`.get/1`
(all deleted by §1). Left unaddressed, §1+§2's deletions would leave `router.ex`
calling undefined remote functions — a `mix compile --warnings-as-errors` failure,
not merely a test failure, breaking the running application itself. **This is squarely
within REQ-046's own scope to fix**, not a separate requirement's job: it is a direct,
mechanical consequence of this requirement's own deletions (§1, §2), not a new feature
or a fresh architectural question.

**Decision: remove the two broken routes (`POST /instances`, `POST
/instances/:id/actions`, `GET /instances/:id`) from `router.ex` outright. Do not wire
them onto `Letflow.Engine.create/2`, and do not add a `501`/stub response for them.**

Reasoning:

1. **`POST /instances` has no like-for-like replacement under `Letflow.Engine.create/2`
   — wiring it through would be a mismatched contract, not a swap.** The old route took
   no request body at all: it generated a UUID and started an instance of the single
   hardcoded 4-state workflow. `Letflow.Engine.create/2`'s `create_attrs()` (confirmed by
   direct read, `lib/letflow/engine.ex` lines 101-108) *requires* `initial_variables`,
   `actor_id`, `idempotency_key`, and exactly one of `definition_id`/`definition_name` —
   none of which a bare `POST /instances` with no body has ever supplied, and none of
   which this requirement has any authority to invent values for (a fabricated
   `actor_id`/`idempotency_key`/definition reference would not be a real caller identity
   or a real workflow selection — it would be this design guessing at API shape,
   precisely the scope creep the task brief warns against). There is no honest way to
   satisfy `create/2`'s contract from the old route's contract; forcing the wire-through
   would produce an endpoint that either silently fabricates required fields or 422s on
   every real call, which is worse than not existing.
2. **The two action/read routes have no replacement at all in this requirement's
   scope** — `.submit/1`/`.approve/1`/etc. are workflow actions specific to the deleted
   hardcoded state machine; the graph-driven engine's vocabulary (gateways, tasks) has no
   1:1 analog, matching §4's identical reasoning for why the corresponding tests aren't
   migrated either.
3. **A `501`/"migrated, pending S4" stub is rejected** as inventing route surface this
   requirement was never asked to build. A stub response is still a piece of API
   contract (a status code and body shape callers could come to depend on) that no
   requirement has specified — REQ-045's own moduledoc states the real replacement,
   `POST /api/v1/instances`, is S4 scope not yet started (§0's read of `engine.ex`,
   confirmed independently here). Inventing an interim contract preempts that future
   requirement's own design decision about what "not yet implemented" should return
   (which version prefix, which error shape) rather than leaving it open for S4 to
   decide cleanly.
4. **Nothing operational depends on the two removed routes.** `deploy/redeploy-test.sh`
   (confirmed by direct read) polls only `GET /health` for its post-deploy check —
   `curl -sf http://127.0.0.1:3113/health`, nothing else. Grepping the full repo for
   `/instances` (case-insensitive) turns up no CI workflow, no other deploy/script
   reference — only `router.ex` itself, its own inline comments, and README.md's
   "Running it" walkthrough (handled next). Removing the two routes has zero effect on
   anything that actually runs today outside a developer's own manual curl session.
5. **This keeps `router.ex` honest** about what currently works: after this change it
   exposes exactly one route, `/health`, which is exactly what remains true and
   supervised end-to-end. This is the same "don't paper over a superseded module with
   documentation that outlives its accuracy" reasoning §1 point 1 already applies to
   `process_instance.ex` itself.

**Resulting `router.ex` shape (route list only, no implementation code):**

- `GET /health` → unchanged, `{"status": "ok"}`.
- `POST /instances` → **removed**.
- `POST /instances/:id/actions` → **removed**.
- `GET /instances/:id` → **removed**.
- `match _` (404 fallback) → unchanged.
- `encode_history_entry/1` (private helper) → **removed** — its only caller
  (`GET /instances/:id`'s handler) is removed above.
- `send_json/3` (private helper) → unchanged, still used by `/health` and the 404
  fallback.
- Moduledoc → updated to drop the "Three endpoints" framing (line 3, "Deliberately
  minimal — Plug + Bandit, no Phoenix. Three endpoints, just enough to drive the state
  machine end to end over HTTP.") to something reflecting the post-REQ-046 state, e.g.:
  "Deliberately minimal — Plug + Bandit, no Phoenix. `/health` only as of REQ-046; the
  `POST/GET /instances...` pilot-slice routes this module carried through S1-S3 were
  removed alongside `Letflow.ProcessInstance`'s own retirement (see
  `lib/letflow/design/req046-process-instance-retirement.md` §6a) — S4 (api-surface)
  is expected to add the real `/api/v1/instances` routes against
  `Letflow.Engine.create/2`, not a revival of this pilot contract."
- `lib/letflow/application.ex`'s `{Bandit, plug: Letflow.Router, ...}` wiring is
  **unchanged** — the router module still exists and still serves `/health`, so nothing
  about the supervision tree changes.

**README.md flag for DOC-UPDATER (Step 6):** this decision changes what commands a
reader of README.md's "Running it" section (lines 77-86) would actually be able to run.
The three `curl` examples against `POST /instances`, `POST /instances/:id/actions`, and
`GET /instances/:id` will 404 after this requirement ships. DOC-UPDATER must remove or
replace that block — at minimum drop it down to the `GET /health` example alone (or
note explicitly that the create/act/read flow is offline pending S4) — do not leave
stale curl examples that no longer work in the primary onboarding doc.

---

## 7. Acceptance-criteria traceability

| REQ-046 AC | Concrete design element |
|---|---|
| AC1 — `process_instance.ex` deleted, tests migrated/removed, `mix test` passes | §1 (delete decision + reasons), §4 (full test disposition per case) |
| AC1 (compile integrity) — no remaining reference to a deleted symbol, `mix compile --warnings-as-errors` passes | §6a (`router.ex`'s three broken routes removed; only remaining caller of the deleted symbols) |
| AC2 — `instance_supervisor.ex` starts REQ-045's engine or is retired with a recorded reason, not left supervising a superseded module | §2 (retain decision + reasons + `engine.ex` moduledoc reconciliation + the exact moduledoc/code edit), §5 (`application.ex` unchanged, reasoning for why) |
| AC3 — `mix test` passes, no test deleted without a stated reason | §4 (per-test reason table + the required commit/PR statement) |
| AC4 — supervised isolation preserved or explicitly not-applicable | §6 (not-applicable, with `parallel_approval_test.exs`'s existing coverage cited as the surviving general-guarantee evidence) |
| (implicit) `Letflow.Events.TransitionEvent` disposition, named by REQ-045 as REQ-046's job | §3 (delete module + table-drop migration) |
| (implicit) `application.ex`/`Letflow.Registry` key changes | §5 |

---

## 8. Open questions

None genuinely open. §1's and §3's decisions are execution of REQ-045's already-recorded
decision, not a fresh architectural question. §2's decision (`instance_supervisor.ex`
retained, not deleted) was reworked after CODE-DESIGN-VALIDATOR's FAIL specifically
because the prior version treated a reversal of `engine.ex`'s recorded forward-looking
statement as a foregone conclusion without reconciling it; §2 now quotes that statement
directly and resolves in its favor (Path A — retain), so no REVIEWER sign-off gate is
required for this run (that gate is only triggered by Path B, a genuine reversal — this
design does not take that path). ELIXIR-DEV should flag to REVIEWER only if a reference
to any of the retired modules/table (`process_instance.ex`,
`Letflow.Events.TransitionEvent`, `transition_events`) or to `instance_supervisor.ex`'s
now-removed `start_instance/1` is discovered during implementation that this design's
grep (§0) missed — not expected, but stated as the one residual risk worth a
human-legible flag rather than a silent surprise.

**Update (WF02-REQ046-20260818, Step 1 follow-up):** this residual risk materialized —
`lib/letflow/router.ex` was exactly such a missed reference (never in §0's source list,
never named by REQ-046's requirement text), caught by ELIXIR-DEV at Step 2a before any
edit was made. Resolved by §6a above (routes removed, not rewired or stubbed). No other
missed reference has been found; §6a's own grep (case-insensitive, whole-repo, for
`/instances`) is the confirming check for this specific gap.
