# GUI review: `swiftroute/shipment-ops-timeout-escalation` (PW-17)

**Date:** 2026-09-20
**Reviewer:** ORCH (this GUI-review sweep, 17th of 18 scenarios)
**Scenario:** `test/fixtures/uat/scenarios/swiftroute/shipment-ops-timeout-escalation.yaml`
**Result:** UNBUILT_FEATURE / BLOCKED — the core mechanism this scenario
tests (a HUMAN_TASK timing out and escalating to a different role) does not
exist in Letflow's graph engine today, and the same two provisioning gaps
already filed against the sibling `shipment-high-value-happy` review
(REQ-395, ISS-0739) independently block any live driving even for the parts
that would otherwise work. No live browser session was opened. One new
requirement (REQ-396) was filed; no new small defect was found to fix in
this pass (the one found during the sibling review, `TaskDetailPanel`'s
discarded form input, was already fixed there and is not re-touched here).

## Path taken

Per the task's own instruction, checked the scenario's step 2 pre-condition
first: does `POST /api/v1/instances/:id/advance-timer` exist?

### Step 0 check — the advance-timer endpoint

**It exists.** `grep -n 'advance-timer' lib/letflow/routers/instances.ex`:

```
17:  | advance-timer | `POST /instances/:id/advance-timer` | ...
351:  authz_post "/:id/advance-timer", :InstancesAdvanceTimer do
352:    handle_advance_timer(conn, conn.params["id"])
690:  # ── POST /instances/:id/advance-timer (ISS-0389 design §1-4) ──────────────
696:  defp handle_advance_timer(conn, raw_id) do
704:      render_advance_timer(
728:  defp render_advance_timer(conn, instance_id, timer, {:ok, fire_result})
740:  defp render_advance_timer(conn, _instance_id, _timer, {:error, _reason}),
```

Backed by a full design (`lib/letflow/design/iss0389-advance-timer-endpoint.md`,
ISS-0389), a real permission (`:InstancesAdvanceTimer`, not the
rebind-pins/reconstruct ad-hoc allowlist pattern), and
`Letflow.Scheduler.resolve_advance_target/3` + `fire_timer/2`. This
supersedes the older finding recorded in REQ-206's own text (docs/requirements.yaml
~L11916-11927, dated 2026-09-01) that the endpoint did not exist and that
this scenario should be SKIP/MINOR — that disposition no longer applies;
the scenario's own fallback ("If not available, mark SKIP/MINOR") does not
trigger. Continued to the full review per the task's instructions.

### Step 1 — is the escalation logic itself real?

**No.** Checked two things:

**(a) Does any HUMAN_TASK node support a timeout-to-escalation attribute?**
`Letflow.Definitions.Graph` (`lib/letflow/definitions/graph.ex`) supports a
real `:TIMER` node type with a validated `duration_iso8601` attribute
(CHK-12, `check_timer_duration/1` ~L815-828) — but nothing on `:HUMAN_TASK`
itself for a race-and-escalate timeout. This is not a fresh discovery:
`docs/requirements.yaml`'s own REQ-185/186/187/188 preamble (~L9736-9742)
already names it explicitly as a known, deliberately deferred blocker:

> SCH-04's escalation half (HUMAN_TASK escalation_timer_duration ->
> reassignment) is scoped to REQ-188 only as far as firing an ESCALATION
> event. Blocker: Letflow's Graph validates duration_iso8601 on :TIMER
> nodes (CHK-12) but has no escalation_timer_duration attribute on
> :HUMAN_TASK at all... Named in REQ-188's own text.

And restated again in REQ-185's acceptance criteria (~L10113-10120) as
"ALSO OUT OF SCOPE, BLOCKER NAMED... escalation timers need a
definitions-side requirement first." No requirement in the file has since
picked that up — grepped `escalation_timer_duration` across
`docs/requirements.yaml` and `docs/issues/`: the only hits are these two
already-recorded deferral notes, no implementation requirement.

**(b) Does this scenario's actual process definition wire an escalation
path at all, independent of the general attribute question?**
`test/fixtures/simulation/swiftroute/process_route_approval.yaml` ("Shipment
Approval") is the only ProcessDefinition graph anywhere in the repo matching
`proc-swiftroute-shipment-approval`. Its `ops-review` HUMAN_TASK
(`role: role-ops-manager`) has exactly one non-decision outgoing edge:

```yaml
    # fallback for ops-review (timeout path; escalate-to-ceo not in graph)
    - id: fallback-ops-review
      source: ops-review
      target: notify-requester
```

`notify-requester` leads to `end-rejected`, not to `ceo-approval`. The
comment is the fixture's own author stating the gap directly. So even
setting aside the general schema question, *this specific graph* cannot
route a timed-out `ops-review` to the CEO under any circumstance today —
confirmed by reading the full node/edge list, not inferred from the
comment alone.

### CEO approval screen (web/src)

Not separately investigated in depth: the generic task-completion screen
(`web/src/pages/tasks/TaskInboxPage.tsx`) is the mechanism any HUMAN_TASK
completion — including a hypothetical `ceo-approval` task — would use, and
it was already reviewed and fixed for exactly this class of defect (the
`output_variables: {}` discard bug) during the sibling
`shipment-high-value-happy` review earlier in this same sweep. No
CEO-specific screen exists or is needed beyond that generic one; the gap is
entirely on the process/engine side, not the frontend.

## Why no live driving was attempted

Two independent, already-filed gaps (from the sibling `shipment-high-value-happy`
review, same process definition family) apply here unchanged:

- **REQ-395** (pending) — no live, browsable `ProcessDefinition` for any
  real `swiftroute` tenant on `qa.bizdala.com`; `process_route_approval.yaml`
  is consumed only as an in-memory `Letflow.Simulation.Runner` fixture.
- **ISS-0739** (open, MAJOR) — no seeded QA login for tenant-business
  personas; this scenario's dispatcher (`actor-swiftroute-tobias`) and CEO
  (`actor-swiftroute-alice`) are not among `qa-login.sh`'s six generic
  platform-role users.

On top of those, this scenario has a third, more fundamental blocker this
review newly confirmed: **even a live-deployed, correctly-logged-in run of
this exact graph cannot produce the escalation this scenario describes**,
because the graph has no path from a timed-out `ops-review` to
`ceo-approval`. Driving step 1 (dispatcher submits via API) alone, with
steps 2-3 known in advance to be structurally impossible, would only
demonstrate an already-established fact — matching this sweep's standing
"don't drive a flow that can only demonstrate an already-conclusively-known
gap" precedent (`renderer-permission-denied-surface`,
`shipment-attach-delivery-note`, `shipment-high-value-happy`). No browser
session was opened; no screenshots were taken.

## Requirements/issues filed

- **`REQ-396`** (owner CODE-DESIGNER, stage S7) — add
  `HUMAN_TASK.escalation_timer_duration` (or an equivalent schema shape) to
  `Letflow.Definitions.Graph`, wire the engine-side timeout->non-actionable
  ->new-task-to-escalation-role mechanics, and update
  `process_route_approval.yaml`'s `ops-review` node to actually use it.
  Explicitly the "pickup" of the deferral REQ-185/REQ-188 already named but
  never scheduled. `depends_on: []` (it is a definitions/engine change,
  independent of REQ-395's deployment gap and ISS-0739's credential gap,
  though all three must land before this scenario can be driven and
  re-reviewed end to end).
- No new issue filed for the login/deployment gaps — `REQ-395` and
  `ISS-0739` already cover them exactly, including for this scenario's
  actor set (`ISS-0739`'s text already generalizes past its own
  Lena/Marco/Alice example to "any narrative UAT scenario whose `via: gui`
  steps require signing in AS a specific named tenant-business persona").

## Not done in this pass

- No live sign-in, no instance submission, no timer advance, no
  screenshots — three independent, real blockers (REQ-395, ISS-0739,
  REQ-396) make any such attempt purely demonstrative rather than new
  evidence.
- No Playwright spec authored, no `pipeline_test:` key added to the
  scenario YAML — authoring a regression spec for a flow the engine cannot
  currently produce would be exactly the blind/aspirational spec this
  review process exists to prevent. It should be authored once REQ-395,
  ISS-0739, and REQ-396 all land.
- The scenario file itself was left completely untouched — its header
  forbids editing the ported content below it except to keep it
  byte-identical to a re-pull of the upstream R-Co commit, and it never had
  a `pipeline_test:` key.
- No small defect was found and fixed in this pass distinct from the one
  already fixed during the sibling `shipment-high-value-happy` review
  (`TaskDetailPanel`'s discarded form input, `web/src/pages/tasks/TaskInboxPage.tsx`)
  — this review's scope did not reach a live screen to find a new one.

## Cleanup

No instance was created against `https://qa.bizdala.com` during this review
(no live, reachable definition to submit one against), so the scenario's
own cleanup step (`cancel_open_instances`) has nothing to act on.
