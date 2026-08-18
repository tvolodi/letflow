# Design: REQ-046 — Retirement of `process_instance.ex` / `instance_supervisor.ex`

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
   it — both retired/migrated by this same requirement, §2/§4). A "retained module" with
   zero live callers and zero remaining purpose is exactly the "undocumented and
   unreferenced" failure mode AC1's own text warns against, just with a moduledoc paragraph
   papering over it rather than preventing it.

**Action:** delete `lib/letflow/process_instance.ex` in full.

---

## 2. Decision: `lib/letflow/instance_supervisor.ex` — RETIRE (delete), not generalize

REQ-045 §1 confirms this requirement introduces no process for `InstanceSupervisor` to
supervise: `Letflow.Engine.create/2` is a plain transactional function, not a
`:gen_statem`. There is therefore nothing today for `start_instance/1` to be generalized
*to* — REQ-045 §1 is explicit that "`start_instance/1`'s eventual generalization ... is
deferred to [REQ-056/REQ-057], not built here," and this requirement's own text names the
same fork: "if REQ-045 resolved to a row-based engine with no process per instance, this
supervisor may have nothing left to supervise — in that case retire it explicitly."

That is exactly the state today, so: **retire, not generalize.**

**Retire = delete, not "leave as an inert module."** Two forcing reasons, not just a
style preference:

1. `instance_supervisor.ex` line 19 calls `Letflow.ProcessInstance.child_spec(id)`
   directly. Once §1 deletes `process_instance.ex`, this line does not compile — a
   "retained but undocumented no-op" is not an available option; the module must be
   either rewritten to start something else (nothing exists to start, per REQ-045 §1) or
   removed.
2. An inert `DynamicSupervisor` module kept in the tree with a `start_instance/1` that
   can never be called (nothing else in the codebase calls it — confirmed by the same
   reference grep as §1) is precisely the "left in the supervision tree supervising a
   superseded module" outcome AC2 forbids.

**Action:** delete `lib/letflow/instance_supervisor.ex` in full, and remove
`Letflow.InstanceSupervisor` from `lib/letflow/application.ex`'s `children` list (§5).

**Recorded reason (since no moduledoc survives to carry it):** this design doc (§1, §2)
is the primary record; `DOC-UPDATER`'s status-history event for REQ-046
(`docs/status/requirement_status.yaml`) must restate it in one line: *"`InstanceSupervisor`
retired — REQ-045 resolved the running-instance shape to a plain transactional context
module (`Letflow.Engine.create/2`), leaving no process for a `DynamicSupervisor` to own;
re-introducing a supervised instance process is REQ-056/REQ-057's own decision to make
against their own shape, not a revival of this module."* The commit message deleting the
file must carry the same one-line reason, per this project's "don't delete without
stating why" convention (WF-02 Step 1 procedure's own instruction; `docs/anti-patterns.md`
precedent for undocumented deletions).

No stub, no `@deprecated` shim, no re-export — nothing else in the codebase or its tests
references `Letflow.InstanceSupervisor` after §4's test migration, so no compile-time
compatibility surface is needed.

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

Current `children` list (line 12-27, reproduced for the diff):

```
Letflow.Repo,
{Ecto.Migrator, ...},
{Oidcc.ProviderConfiguration.Worker, ...},
{Registry, keys: :unique, name: Letflow.Registry},
Letflow.InstanceSupervisor,        # <- removed
Letflow.ApprovalSupervisor,
{Letflow.SandboxPool, []}
++ http_child()
```

**Change:** remove the `Letflow.InstanceSupervisor,` line only. Nothing else in the
`children` list changes.

- `{Registry, keys: :unique, name: Letflow.Registry}` **stays** — `Letflow.ApprovalSupervisor`
  /`Letflow.ParallelApproval` still register under it via `{:via, Registry,
  {Letflow.Registry, {:approval, id}}}` (`parallel_approval.ex` line 53). No key
  changes: the only keys ever registered under `Letflow.Registry` by
  `Letflow.ProcessInstance` were bare `id` strings (`process_instance.ex` line 60); those
  simply stop being produced once the module is deleted. `Letflow.ApprovalSupervisor`'s
  `{:approval, id}`-tuple keys are untouched and remain the only keys registered after
  this change.
- `Letflow.ApprovalSupervisor` **stays**, unmodified — out of this requirement's scope
  entirely (it supervises `ParallelApproval`, a structurally different, still-current
  workflow per its own moduledoc, §0).

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

## 7. Acceptance-criteria traceability

| REQ-046 AC | Concrete design element |
|---|---|
| AC1 — `process_instance.ex` deleted, tests migrated/removed, `mix test` passes | §1 (delete decision + reasons), §4 (full test disposition per case) |
| AC2 — `instance_supervisor.ex` starts REQ-045's engine or is retired with a recorded reason, not left supervising a superseded module | §2 (retire = delete decision + reasons + recorded-reason text), §5 (removed from `application.ex`) |
| AC3 — `mix test` passes, no test deleted without a stated reason | §4 (per-test reason table + the required commit/PR statement) |
| AC4 — supervised isolation preserved or explicitly not-applicable | §6 (not-applicable, with `parallel_approval_test.exs`'s existing coverage cited as the surviving general-guarantee evidence) |
| (implicit) `Letflow.Events.TransitionEvent` disposition, named by REQ-045 as REQ-046's job | §3 (delete module + table-drop migration) |
| (implicit) `application.ex`/`Letflow.Registry` key changes | §5 |

---

## 8. Open questions

None genuinely open. This requirement is execution of REQ-045's already-recorded
decision (§1 of that design), not a fresh architectural question — every fork the
requirement text itself poses (delete-vs-retain, generalize-vs-retire) resolves to one
concrete branch once REQ-045's resolution (plain transactional module, no process) is
applied, as shown in §1, §2, §3 above. ELIXIR-DEV should flag to REVIEWER only if a
reference to any of the three retired modules/table is discovered during implementation
that this design's grep (§0) missed — not expected, but stated as the one residual risk
worth a human-legible flag rather than a silent surprise.
