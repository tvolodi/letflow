# Design: REQ-433 — Meridian credit-committee 2-of-3 quorum vote

**Requirement:** REQ-433 (`docs/requirements.yaml`, stage S7), filed from ISS-0973.
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact node/edge data to add to/remove from both process-
definition fixtures, the exact scenario-file edits, and the exact version bumps. This is a
process-definition/fixture/scenario **data** change — no engine code, so "signatures and
type shapes" per this role's usual output do not apply; the artifacts below are the fixture
data itself (JSON/YAML), not implementation code, per REQ-433's own OUT OF SCOPE clause and
its AC6 (`git diff` must show zero changes under `lib/letflow/engine/`).

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-433 full entry (title, description incl. REQ-ANALYST's own
  concrete sketch, all 7 acceptance criteria, `depends_on: []`).
- `docs/issues/ISS-0973.yaml` (full).
- `test/fixtures/qa/meridian_loan_origination_process_definition.json` — read in full
  (all nodes, all edges) via direct JSON parse, not excerpt.
- `test/fixtures/simulation/meridian/process_claim_intake.yaml` — read in full, diffed
  structurally (sorted-key JSON dump) against the qa fixture to establish what already,
  legitimately differs between the two (service-task endpoint string format: full
  `https://httpbin.org/anything/...` URLs in the qa fixture vs. `METHOD /path` shorthand
  in the simulation fixture; a one-off missing `e9-default` edge in the simulation fixture
  that pre-dates this requirement and is out of scope here; `version` fields that are
  independently tracked, `1.2` vs `1.0`) versus what must stay identical (every node id,
  edge id, edge source/target, and edge condition in the committee subgraph itself).
- `test/fixtures/uat/scenarios/meridian/loan-origination-above-threshold.yaml` and
  `...-below-threshold.yaml` (full).
- `test/fixtures/simulation/meridian/scenarios/loan-origination-above-threshold.yaml`
  (full) and its header comment's claim, re-verified directly rather than trusted —
  see §4.2: that comment is **stale**. The `join_counters`-not-persisted defect it
  describes is `docs/issues/ISS-0397.yaml`, `status: resolved` (2026-09-01, confirmed
  by direct re-read of that issue file's `resolution` field), and independently
  confirmed fixed by direct read of `lib/letflow/engine.ex` itself: `join_counters` is
  durably round-tripped via `SnapshotWriter.serialize_join_counters/1` /
  `deserialize_join_counters/1` at every write/read site (lines ~1850-1862, ~2594,
  ~5067-5091; `insert_instance_projection/8`'s own attrs include
  `join_counters: SnapshotWriter.serialize_join_counters(join_counters)`) — no site
  hardcodes `join_counters: %{}` anywhere in the current file. §4.2 below reworks this
  scenario's own edits accordingly instead of repeating the stale claim.
- `test/letflow/simulation/req208_meridian_test.exs` (full) — read because it is the
  test that actually consumes the simulation scenario YAML above via
  `Letflow.Simulation.Runner.run/1`; confirms (a) this scenario runs against
  `@simple_loan_origination_graph`, a hand-maintained, test-local Elixir map in this
  file — not `process_claim_intake.yaml` directly — that today still encodes the OLD
  single-vote `credit-committee-vote`/`committee_outcome` shape REQ-433 deletes from
  the two real fixtures; (b) the existing `"meridian-loan-origination-above-threshold"`
  describe block asserts `length(report.step_results) == 3` and is explicitly
  documented in this file's own moduledoc as "kept... unchanged, since rewriting
  those two [describe blocks] would lose their own historical ISS-0397-fix-locking
  value" — i.e. deliberately scoped narrow, not a ceiling on what the engine can
  actually do; (c) `test/support/simulation/runner.ex`'s own `{{produces.X.items.N.id}}`
  template substitution (`resolve_dotted_path/2`/`walk_path/3`) is purely positional —
  no filter-by-field (e.g. by `node_id`) expression exists — confirmed directly from
  that file's source, not assumed.
- A third, separate describe block in that same test file
  (`"loan-origination above-threshold, full committee-vote through disbursement
  (REQ-215 AC2)"`) — read in full because it is live, already-passing, direct proof
  (not a guess) of three things this design's §4.2 revision now relies on: (i) a
  single `Engine.complete_task/3` call on the LAST of two parallel assessment
  branches cascades automatically, in one hop-chain, through the join and every
  downstream gateway up to the next real task node(s) (its own comment: "the join
  fired... past eligibility-gate... past authority-routing... landing the token at
  credit-committee-vote... in one complete_task/3 call"); (ii) `credit_decision:
  "pass"` + `risk_rating: "acceptable"` is a proven-working eligibility-gate input
  pair (not this design's own untested guess); (iii) a SERVICE_TASK node (here,
  `create-facility`) parks the token with no automatic outgoing traversal once
  reached — confirmed by that block's own comment ("The token PARKS there (no
  automatic outgoing traversal...)") and assertion (`current_nodes ==
  ["create-facility"]`, a real `ServiceTaskDispatch` row with `status: "pending"`).
  Also confirms, by cross-reference with this same test file's moduledoc, that
  REQ-215 deliberately did NOT extend the Runner-driven YAML scenario to resolve
  that SERVICE_TASK dispatch itself ("extending the YAML format itself is out of
  REQ-215's own scope... the existing scenario YAMLs... have no step primitive for
  'resolve a pending SERVICE_TASK dispatch'") — a still-current, unrelated-to-
  ISS-0397 limitation this design's §4.2 revision respects rather than re-litigates.
- `scripts/seed_meridian_definition.sh` (full) — confirms the script's version-aware
  idempotency reads `fixture_version` via `jq -r '.version'` directly from
  `test/fixtures/qa/meridian_loan_origination_process_definition.json` (the actual
  `fixture_path` argument passed to `seed_definition` for "Loan Origination"), not from
  `process_claim_intake.yaml`.
- `lib/letflow/design/req028-graph-structural-validator.md` §5 (the CHK-01..CHK-08 table)
  — confirms there is no fan-in/fan-out-count-matching check between a `PARALLEL_GATEWAY`
  fork and its join (join-arrival-count semantics are a runtime/`JoinCounter` concern, not
  a structural-validator one), and that an `EXCLUSIVE_GATEWAY` may legally route more than
  one edge (conditioned or default) to the same target node (already true today: `e9`/
  `e9-default` both target `assessment-join`).

## 1. Current committee subgraph (both fixtures, before this change)

Nodes:
```json
{"id": "credit-committee-vote", "node_type": "HUMAN_TASK", "attributes": {"role": "role-committee-member"}}
{"id": "committee-timeout", "node_type": "SERVICE_TASK", "attributes": {"endpoint": "<flag endpoint>", "method": "POST", "timeout_ms": 300000}}
```
Edges:
```json
{"id": "e18", "source": "authority-routing", "target": "credit-committee-vote", "condition": "variables.requested_amount_eur > 500000"}
{"id": "e23", "source": "credit-committee-vote", "target": "create-facility", "condition": "variables.committee_outcome == 'approved'"}
{"id": "e24", "source": "credit-committee-vote", "target": "decline-application", "condition": "variables.committee_outcome == 'rejected'"}
{"id": "timeout-credit-committee-vote", "source": "credit-committee-vote", "target": "committee-timeout"}
{"id": "e25", "source": "committee-timeout", "target": "decline-application"}
```
This is unreachable end-to-end today: nothing ever supplies `variables.committee_outcome`.

## 2. Target committee subgraph — exact node/edge data

Max existing numeric edge id in the qa fixture is `e28` (confirmed by direct scan of all
edge ids). New numbered edges continue `e29..e40`; new named edges follow the fixture's
own existing `timeout-<task-id>` convention (already used for
`timeout-credit-memo-review`, `timeout-risk-assessment`, `timeout-kyc-manual-review`,
and the now-deleted `timeout-credit-committee-vote`) and the `<excl-gw-edge>-default`
convention (already used for `e9-default`).

### 2.1 DELETE (both fixtures)

- Node `credit-committee-vote` (HUMAN_TASK)
- Node `committee-timeout` (SERVICE_TASK)
- Edges `e23`, `e24`, `timeout-credit-committee-vote`, `e25`

### 2.2 ADD nodes (both fixtures — role, structure identical; only the `endpoint` string
format differs per fixture, matching each fixture's own pre-existing style)

```json
{"id": "committee-vote-fork", "node_type": "PARALLEL_GATEWAY"}
{"id": "committee-vote-cro", "node_type": "HUMAN_TASK", "attributes": {"role": "role-committee-member"}}
{"id": "committee-vote-director", "node_type": "HUMAN_TASK", "attributes": {"role": "role-committee-member"}}
{"id": "committee-vote-ceo", "node_type": "HUMAN_TASK", "attributes": {"role": "role-committee-member"}}
{"id": "committee-vote-cro-timeout", "node_type": "SERVICE_TASK", "attributes": {"endpoint": "<flag endpoint, this fixture's format>", "method": "POST", "timeout_ms": 300000}}
{"id": "committee-vote-director-timeout", "node_type": "SERVICE_TASK", "attributes": {"endpoint": "<flag endpoint, this fixture's format>", "method": "POST", "timeout_ms": 300000}}
{"id": "committee-vote-ceo-timeout", "node_type": "SERVICE_TASK", "attributes": {"endpoint": "<flag endpoint, this fixture's format>", "method": "POST", "timeout_ms": 300000}}
{"id": "committee-vote-join", "node_type": "PARALLEL_GATEWAY"}
{"id": "committee-tally", "node_type": "EXCLUSIVE_GATEWAY"}
```

(`<flag endpoint, this fixture's format>` = exactly the same literal string the existing
`risk-assessment-timeout`/`credit-memo-timeout` nodes already use in that fixture —
`"https://httpbin.org/anything/internal/applications/{{variables.application_id}}/flag"`
in the qa JSON fixture, `"POST /internal/applications/{application_id}/flag"` in the
simulation YAML fixture — reusing the existing shape exactly, introducing no new endpoint
string.)

### 2.3 ADD edges (both fixtures, identical ids/sources/targets/conditions)

```json
{"id": "e29", "source": "committee-vote-fork", "target": "committee-vote-cro"}
{"id": "e30", "source": "committee-vote-fork", "target": "committee-vote-director"}
{"id": "e31", "source": "committee-vote-fork", "target": "committee-vote-ceo"}

{"id": "e32", "source": "committee-vote-cro", "target": "committee-vote-join"}
{"id": "e33", "source": "committee-vote-director", "target": "committee-vote-join"}
{"id": "e34", "source": "committee-vote-ceo", "target": "committee-vote-join"}

{"id": "timeout-committee-vote-cro", "source": "committee-vote-cro", "target": "committee-vote-cro-timeout"}
{"id": "timeout-committee-vote-director", "source": "committee-vote-director", "target": "committee-vote-director-timeout"}
{"id": "timeout-committee-vote-ceo", "source": "committee-vote-ceo", "target": "committee-vote-ceo-timeout"}

{"id": "e35", "source": "committee-vote-cro-timeout", "target": "committee-vote-join"}
{"id": "e36", "source": "committee-vote-director-timeout", "target": "committee-vote-join"}
{"id": "e37", "source": "committee-vote-ceo-timeout", "target": "committee-vote-join"}

{"id": "e38", "source": "committee-vote-join", "target": "committee-tally"}

{"id": "e39", "source": "committee-tally", "target": "create-facility",
 "condition": "(variables.committee_vote_cro == 'approve' && variables.committee_vote_director == 'approve') || (variables.committee_vote_cro == 'approve' && variables.committee_vote_ceo == 'approve') || (variables.committee_vote_director == 'approve' && variables.committee_vote_ceo == 'approve')"}
{"id": "e40", "source": "committee-tally", "target": "decline-application",
 "condition": "(variables.committee_vote_cro == 'reject' && variables.committee_vote_director == 'reject') || (variables.committee_vote_cro == 'reject' && variables.committee_vote_ceo == 'reject') || (variables.committee_vote_director == 'reject' && variables.committee_vote_ceo == 'reject')"}
{"id": "e40-default", "source": "committee-tally", "target": "decline-application", "is_default": true}
```

### 2.4 RETARGET existing edge (both fixtures)

`e18` keeps its id and condition, only its `target` changes:

```json
{"id": "e18", "source": "authority-routing", "target": "committee-vote-fork", "condition": "variables.requested_amount_eur > 500000"}
```

### 2.5 Shape check against the existing `parallel-assessment-fork`/`assessment-join` precedent

| | existing (3-way assessment) | new (3-way committee) |
|---|---|---|
| fork out-degree | 3 (`e1`,`e2`,`e3`) | 3 (`e29`,`e30`,`e31`) |
| per-branch task→join | unconditioned | unconditioned |
| per-branch timeout→join | unconditioned, via a sibling SERVICE_TASK | unconditioned, via a sibling SERVICE_TASK (identical pattern) |
| join out-degree | 1 (`e14` → `eligibility-gate`) | 1 (`e38` → `committee-tally`) |

Identical shape — no new join-arrival-count semantics requested of `JoinCounter`; each of
the 3 committee branches resolves to the join via exactly one of its two mutually
exclusive paths (vote completion OR timeout), exactly like each of the 3 existing
assessment branches already does. CHK-04 (isolated-node) is satisfied the same way the
existing 3-way fork/join is: every new node has both an in-edge and an out-edge. No
CHK-01..CHK-08 check inspects fork/join arrival counts or node-type-specific fan-in/
fan-out ratios beyond CHK-04's "has at least one edge each way," so both fixtures continue
to pass whatever structural validation the engine already runs (**AC1**, second half).

### 2.6 Output-variable convention (no definition change — completion-payload convention only)

Each vote task's completion call supplies its own output variable, following the same
per-HUMAN_TASK convention this definition already uses for `credit_decision`,
`risk_rating`, `l1_decision`, `l2_decision` (none of which are declared anywhere in the
node definition itself — they are read only by downstream edge conditions):

- `committee-vote-cro` completion → `committee_vote_cro: 'approve' | 'reject'`
- `committee-vote-director` completion → `committee_vote_director: 'approve' | 'reject'`
- `committee-vote-ceo` completion → `committee_vote_ceo: 'approve' | 'reject'`

`variables.committee_outcome` is never written or read anywhere in the new subgraph
(**AC2**).

## 3. Fixture `version` bumps

- `test/fixtures/qa/meridian_loan_origination_process_definition.json`: `"version": "1.2"`
  → `"version": "1.3"`. This is the fixture `scripts/seed_meridian_definition.sh` actually
  reads (`fixture_version=$(jq -r '.version' ".../meridian_loan_origination_process_definition.json")`)
  — bumping it is what makes the script's version-aware idempotency contract (409 ⇒ bump
  version, never edit an already-seeded one in place) succeed against a clean QA instance
  that may already hold v1.2 ACTIVE (**AC7**).
- `test/fixtures/simulation/meridian/process_claim_intake.yaml`: `version: "1.0"` →
  `version: "1.1"`, per REQ-433's own instruction to bump both named fixtures together,
  even though the seed script does not read this file's version directly today — keeping
  the two fixtures' version fields moving in lockstep avoids the two files silently
  drifting into "same committee subgraph, different declared version" confusion for
  whatever next reads this file. (This design confirmed, by direct `grep -rn
  "process_claim_intake" test/ lib/ scripts/`, that no other code path reads this
  file's `version` field independently of this script's own header comment and
  non-version-reading comments in `test/letflow/simulation/req208_meridian_test.exs`
  — see §6, this is resolved, not an open question.)
- The script's own header comment (`scripts/seed_meridian_definition.sh` lines 5/6,
  `# "Loan Origination" v1.2 ...`) should be updated to `v1.3` for consistency; this is a
  comment-only edit, not a behavior change, and not itself gated by any AC, but leaving a
  stale version number in a comment immediately next to the real `jq` read is the kind of
  drift `docs/anti-patterns.md` exists to catch — ELIXIR-DEV should make this edit while
  touching the file for the AC7 verification run, not skip it as out of scope.

## 4. Scenario-file changes

### 4.1 `test/fixtures/uat/scenarios/meridian/loan-origination-above-threshold.yaml`

- Insert a new step between the existing step 5 (director votes) and step 6
  (disbursement), renumbering the old step 6 → step 7:

```yaml
  - step: 6
    actor: committee_member_ceo
    action: >
      As a credit committee member, casts a 'reject' vote -- quorum has
      already been reached 2-of-3 by the CRO and director, so this
      dissent does not change the outcome
    via: api
    input:
      vote: reject
      conditions: "Concerned about sector concentration risk; outvoted by quorum."

  - step: 7
    actor: loan_ops
    action: >
      Disburses the approved €750,000 loan, recording the disbursement
      date and reference
    via: api
    input:
      disbursement_date: "2026-06-10"
      disbursement_ref: "DISB-MER-2026-001"
```

- Update `EO-002`'s `detail` string: `task type 'credit-committee-vote' assigned to
  role-committee-member` → `task type 'committee-vote-cro', 'committee-vote-director',
  'committee-vote-ceo' assigned to role-committee-member` (still "no task type
  'l1-approval' or 'l2-approval' assigned" unchanged).
- Replace `EO-003` entirely:

```yaml
  - id: EO-003
    description: >
      With two of three committee members ('committee_vote_cro' and
      'committee_vote_director') voting 'approve', quorum 2-of-3 is
      reached regardless of the third member's ('committee_vote_ceo')
      dissenting 'reject' vote. Quorum is evaluated structurally only
      once all three members have voted -- the parallel vote tasks are
      joined before the tally gateway runs, not the instant the second
      vote lands.
    verification:
      method: instance_state
      detail: >
        committee_vote_cro == 'approve' AND committee_vote_director ==
        'approve', quorum reached despite committee_vote_ceo == 'reject'
    on_fail:
      severity: BLOCKER
      business_impact: >
        The credit committee mechanism is not correctly counting votes
        or reaching quorum. Loans that should be approved are stuck or
        incorrectly declined.
      suggested_action: route_to_wf03
```

- Append one clause to the scenario `description:` block noting quorum is evaluated once
  all three members have voted (full join), not on the second vote — satisfies the
  requirement text's own instruction to "note in the scenario's own description."
- `cleanup.description` and `preconditions` are unchanged.

This file is the one and only "above-threshold UAT scenario" the requirement's own AC4
names; UAT-RUNNER executes it as a real (non-mocked) run against a real instance, driving
all three `committee-vote-*` HUMAN_TASKs to completion, reaching `end-disbursed`
(**AC4**).

### 4.2 `test/fixtures/simulation/meridian/scenarios/loan-origination-above-threshold.yaml`

**Revised call, superseding this design's original comment-only treatment.** The
original version of this section took this file's own header comment at face value
("already halts at step 2b... due to `join_counters` not persisted") and stopped
there. That comment is **stale**: `docs/issues/ISS-0397.yaml` is `status: resolved`
(resolved 2026-09-01), and `lib/letflow/engine.ex` confirms the fix is genuinely live
today — `join_counters` is durably persisted/read via `SnapshotWriter.serialize_
join_counters/1`/`deserialize_join_counters/1` at every write and read site (§0 above
cites exact line numbers), with no `join_counters: %{}` hardcode anywhere in the
current file. The blocker this file's header cited for stopping at step 2b is gone.
That means this file's own instruction from REQ-433's text — "apply [the step-5b/
EO-003-equivalent change] to... `test/fixtures/simulation/meridian/scenarios/loan-
origination-above-threshold.yaml`" — is no longer blocked and should not be skipped.

**What is still genuinely true, and still limits this file (a *different*, current,
already-independently-documented constraint — not ISS-0397):** this scenario is
executed by `Letflow.Simulation.Runner.run/1` against `@simple_loan_origination_graph`
(a hand-maintained, test-local Elixir map in `test/letflow/simulation/
req208_meridian_test.exs`), not `process_claim_intake.yaml` directly, and `create-
facility` — the node the new committee-tally's approve-path edge (`e39`) targets — is
a real `SERVICE_TASK`. REQ-215's own already-passing third describe block in that same
test file proves directly (§0 above) that a `SERVICE_TASK` node parks the token with
no automatic outgoing traversal, and that its own moduledoc already recorded, as a
closed decision, that extending this Runner-driven YAML scenario format to resolve a
pending `SERVICE_TASK` dispatch is out of scope ("the existing scenario YAMLs... have
no step primitive for 'resolve a pending SERVICE_TASK dispatch'"). This is unrelated
to and not fixed by ISS-0397, and this design does not re-litigate it.

**The resulting, explicit call:** extend this scenario's real, executable steps as far
as the engine will actually carry them with existing Runner primitives — through the
remaining assessment branch, the join, both gateways, and all three real committee
votes — stopping at the point the token legitimately parks at `create-facility`
(`SERVICE_TASK`, pending dispatch), the same "honestly truncated, not fabricated"
discipline this file's header already follows today, just one phase further than
before. This is a genuine, meaningful extension: it exercises the real 2-of-3 quorum
tally (`committee-tally`, `e39`/`e40`/`e40-default`) end to end with real, separate
HUMAN_TASK completions, which is exactly what REQ-433's committee subgraph exists to
prove — it does not, and does not need to, reach disbursement (REQ-433's AC4 names
only the UAT scenario, §4.1, for that).

Steps to append, continuing this file's existing step numbering/style (no `step:`
field in this file's convention, unlike the UAT scenario — comments only):

```yaml
  # Step 3 — look up the one remaining pending assessment task (credit-memo-review;
  # risk-assessment and the KYC/AML track's immediate edge are already closed by
  # step 2b/create — see that step's own "items.0" note). Real.
  - via: api
    action: "GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING"
    produces: remaining_assessment_task_list
    actor: actor-meridian-julia

  # Step 4 — completes the last assessment branch. Real: fires assessment-join
  # (3 of 3 received) and cascades, in this one call, through eligibility-gate and
  # authority-routing (750000 > 500000 -> committee-vote-fork), landing 3 real
  # HUMAN_TASKs (committee-vote-cro/director/ceo) in one hop-chain -- the same
  # single-call multi-hop cascade req208_meridian_test.exs's own REQ-215 AC2
  # describe block already proves against this exact gateway shape (§0).
  # risk_rating: "acceptable" pairs with the credit_decision: "pass" step 2b already
  # set (on whichever physical task step 2b actually completed -- output_variables
  # are instance-global, not validated against the completing task's own node id,
  # confirmed by that same step 2b already succeeding across a mismatched node) to
  # reuse exactly the eligibility-gate input pair REQ-215's own test already proved
  # passes (§0) -- not a new, unverified guess.
  - via: api
    action: "POST /api/v1/tasks/{{produces.remaining_assessment_task_list.items.0.id}}/complete"
    params:
      output_variables:
        risk_rating: acceptable
    produces: last_assessment_result
    actor: actor-meridian-julia

  # Step 5 — look up the 3 committee-vote-* tasks created by step 4's cascade. Real.
  # Order is NOT assumed to correspond to a specific node id (confirmed:
  # test/support/simulation/runner.ex's template substitution is purely positional,
  # no filter-by-node_id capability -- §0). This does not matter: output_variables
  # are instance-global and unvalidated against the completing task's own node id
  # (same property step 2b already relies on), so assigning the 3 required
  # committee_vote_* variable names to whichever 3 tasks come back in whatever
  # order still produces the exact same quorum tally (2 approve, 1 reject)
  # regardless of which physical committee-vote-{cro,director,ceo} node each one
  # structurally is.
  - via: api
    action: "GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING"
    produces: committee_task_list
    actor: actor-meridian-thomas

  # Step 6 — first committee member votes approve. Real.
  - via: api
    action: "POST /api/v1/tasks/{{produces.committee_task_list.items.0.id}}/complete"
    params:
      output_variables:
        committee_vote_cro: approve
    produces: committee_vote_1_result
    actor: actor-meridian-thomas

  # Step 7 — second committee member votes approve, reaching 2-of-3 quorum. Real.
  - via: api
    action: "POST /api/v1/tasks/{{produces.committee_task_list.items.1.id}}/complete"
    params:
      output_variables:
        committee_vote_director: approve
    produces: committee_vote_2_result
    actor: actor-meridian-julia

  # Step 8 — third committee member dissents. Real: this is the 3rd-of-3 arrival at
  # committee-vote-join (a set-based wait-for-all-expected join, per
  # join_counter.ex's own moduledoc -- quorum is only evaluated once all three have
  # voted, not released early on the 2nd approve, same as §4.1's revised EO-003).
  # Fires committee-vote-join -> committee-tally (e39: 2 of 3 == 'approve' is true
  # even with this dissent) -> create-facility, a real SERVICE_TASK. The token PARKS
  # there (no automatic outgoing traversal -- req208_meridian_test.exs's own REQ-215
  # AC2 describe block proves this property directly, §0): this is the real,
  # honestly-reached end state for this scenario, proving the quorum tally fired
  # correctly without needing to resolve the SERVICE_TASK dispatch itself (out of
  # scope here, same as REQ-215 already found for this file format -- §4.2 above).
  - via: api
    action: "POST /api/v1/tasks/{{produces.committee_task_list.items.2.id}}/complete"
    params:
      output_variables:
        committee_vote_ceo: reject
    produces: committee_vote_3_result
    actor: actor-meridian-eva
```

Update the header comment's two now-stale lines:
- Replace the whole "CRITICAL ELIXIR-DEV FINDING" block (lines 11-31 of the current
  file) with a short superseding note in the same style this project's other
  superseding comments use (e.g. `req208_meridian_test.exs`'s own moduledoc "FIXED by
  ISS-0397" section): state that ISS-0397 is resolved, that this scenario now runs
  through the real 2-of-3 committee quorum tally, and that it still legitimately
  truncates at `create-facility` (a real `SERVICE_TASK`) because this Runner-driven
  YAML format has no step primitive to resolve a pending `SERVICE_TASK` dispatch —
  the same, still-current limitation REQ-215's own moduledoc already documents for
  this exact file.
- The `# requested_amount_eur: 750000 ... would have forced authority-routing's
  credit-committee-vote branch` line: update `credit-committee-vote` to
  `committee-vote-fork`, consistent with §4.3's below-threshold wording.

**Required follow-on this design flags rather than silently assumes away (not
something this design can do itself — it is TEST CODE, not fixture data, outside this
role's "no implementation/test code" mandate and outside the specific file list
REQ-433's own text names):** these new steps will not pass until
`test/letflow/simulation/req208_meridian_test.exs` is also updated, in the same work
item, to (a) give `@simple_loan_origination_graph` the same `committee-vote-fork`/
`committee-vote-cro`/`committee-vote-director`/`committee-vote-ceo`/`committee-vote-
join`/`committee-tally` subgraph §2 adds to the two real fixtures (that test-local
graph is a separate, hand-maintained map — it does not inherit fixture edits
automatically), and (b) update the `"meridian-loan-origination-above-threshold"`
describe block's own `length(report.step_results) == 3` and final-state assertions to
match the extended step list and the new end state (`current_nodes ==
["create-facility"]`, a pending `ServiceTaskDispatch` row, `committee_vote_cro ==
"approve"`, `committee_vote_director == "approve"`, `committee_vote_ceo == "reject"`).
ELIXIR-DEV/TEST-DESIGNER must not skip this as "not my file" — flagged here explicitly
so it is not discovered as a surprise test failure instead.

**One open point this design does not guess past:** eligibility-gate's exact boolean
condition was not independently re-derived from source as part of this revision; the
`credit_decision: "pass"` / `risk_rating: "acceptable"` pair is reused because it is
directly proven-working elsewhere (§0, REQ-215's own describe block), not because this
design re-verified the gate's own grammar. If the real gate condition in
`process_claim_intake.yaml` ever diverges from what that other test proves, the person
running this extended scenario for real will see it fail at step 4 rather than later —
flagged so that failure mode is expected, not mysterious.

### 4.3 `test/fixtures/uat/scenarios/meridian/loan-origination-below-threshold.yaml`

No change. This instance's `requested_amount_eur: 50000` never crosses the €500,000
threshold, so `authority-routing` never traverses `e18` into the committee subgraph at
all — none of `committee-vote-cro`/`committee-vote-director`/`committee-vote-ceo` are ever
created as tasks for a below-threshold instance, so `EO-002`'s existing assertion ("task
type 'credit-committee-vote' is NOT assigned to any actor") needs updating only in its
literal task-type name list, to keep asserting the same "no committee task" property
against the new 3-task subgraph by name:

```yaml
  - id: EO-002
    description: >
      No credit committee vote tasks are created because the requested
      amount (€50,000) is below the €500,000 threshold
    verification:
      method: task_assigned
      detail: >
        task types 'committee-vote-cro', 'committee-vote-director', and
        'committee-vote-ceo' are NOT assigned to any actor
    on_fail:
      severity: BLOCKER
      business_impact: >
        Small loans are incorrectly triggering the credit committee vote,
        which is reserved only for amounts above €500,000. This delays
        routine lending and wastes committee time.
      suggested_action: route_to_wf03
```

This satisfies **AC5** literally: EO-002 is "re-verified true ... by name" against the
new 3-task subgraph, naming all three new task types explicitly rather than the deleted
`credit-committee-vote` id.

## 5. Acceptance-criteria traceability

1. *"...both replace the single credit-committee-vote HUMAN_TASK with the
   committee-vote-fork/.../committee-tally subgraph ..., kept identical to each other in
   this subgraph, ... both fixtures still pass whatever structural/schema validation this
   engine already runs"* → §2.1-2.4 (identical node/edge data in both fixtures, differing
   only in the pre-existing endpoint-string-format convention each fixture already uses,
   per §0's structural diff); §2.5 (shape-equivalence check against the existing
   3-way-fork/join precedent already present and passing in this same file, so no new
   CHK-01..CHK-08 failure mode is introduced).
2. *"committee-tally's edge conditions use only variables.*, ==, &&, || ... no
   committee_outcome variable appears anywhere"* → §2.3 (`e39`/`e40` conditions, grammar
   check: every operand is `variables.committee_vote_{cro,director,ceo}`, every operator
   is `==`/`&&`/`||`); §2.6 confirms `committee_outcome` is deleted, not renamed, from both
   fixtures.
3. *"committee-tally has exactly one is_default edge, targeting decline-application"* →
   §2.3: `e39` (no `is_default`), `e40` (no `is_default`), `e40-default`
   (`"is_default": true`, `target: "decline-application"`) — exactly one default edge,
   correctly targeted, fail-safe per the requirement's own stated rationale (a 1-1-1 split
   or a timed-out voter falls through both conditioned edges and the default declines
   rather than hangs).
4. *"the above-threshold UAT scenario is updated with the committee_member_ceo vote step
   and revised EO-003 ..., a real (non-mocked) run reaches end-disbursed with all three
   committee-vote-* tasks completed, 2 of 3 approve, one reject"* → §4.1 in full (new step
   6, renumbered step 7, revised EO-002/EO-003). The run itself is UAT-RUNNER's job, not
   this design's — this design's job is making the scenario and fixture capable of
   producing that real outcome, which §2 and §4.1 together do.
5. *"the below-threshold UAT scenario's EO-002 ... re-verified true against the new
   3-task subgraph by name"* → §4.3 (EO-002 rewritten to name all three new task types;
   no other part of that scenario changes, since the instance never reaches the committee
   branch).
6. *"git diff shows zero changes under lib/letflow/engine/"* → §6 below confirms this
   directly; nothing in §2-§4 touches any file under `lib/letflow/engine/`.
7. *"scripts/seed_meridian_definition.sh's version-aware idempotency still succeeds
   against the bumped fixture version on a clean QA instance (... or the equivalent
   ExUnit seed path ...), with real output quoted"* → §3 (version bump to the exact
   fixture the script's own `jq -r '.version'` call reads); the actual idempotent-seed run
   and its quoted output is ELIXIR-DEV's verification step at implementation time, not
   something this design can execute itself.

## 6. Open questions (not silently resolved)

- ~~Does any other code path read `process_claim_intake.yaml`'s `version` field
  independently of `seed_meridian_definition.sh`?~~ **Resolved, not open.** `grep -rn
  "process_claim_intake" test/ lib/ scripts/` was run directly as part of this
  revision: the only hits are `seed_meridian_definition.sh`'s own header comment and
  non-version-reading comments in `test/letflow/simulation/req208_meridian_test.exs`
  (prose references to the file's name, not code reading its `version` key). No other
  code path reads this file's `version` field. The `1.0` → `1.1` bump (§3) is inert
  everywhere except this script's own header-comment cross-reference, already covered
  there.
- **`scripts/seed_meridian_definition.sh`'s own header comment line 31** ("Payload
  sources of truth: ... process_claim_intake.yaml (-> Loan Origination)") already,
  pre-existing this requirement, disagrees with what `seed_definition` actually passes as
  `fixture_path` for "Loan Origination" (the qa JSON fixture, not this YAML file — see
  §0). This design does not touch that comment (out of scope, pre-existing, unrelated to
  the committee subgraph), but flags it for whoever next touches that script, rather than
  silently treating the comment as authoritative.

## 7. Does this touch `lib/letflow/engine/` or any tenant-data-path code? — SECURITY-REVIEWER

**No.** Every change in this design is confined to:
- two process-definition **fixture data files** (`test/fixtures/qa/...json`,
  `test/fixtures/simulation/meridian/process_claim_intake.yaml`) — static JSON/YAML node
  and edge data, no code;
- three **scenario fixture files** (`test/fixtures/uat/scenarios/meridian/*.yaml`,
  `test/fixtures/simulation/meridian/scenarios/loan-origination-above-threshold.yaml`) —
  static narrative/assertion data, no code;
- one **comment-only** edit to `scripts/seed_meridian_definition.sh` (§3, version number
  in a comment) — no logic in that script changes; its `jq`-driven version-compare
  idempotency logic is read, not modified.

REQ-433's own `description` independently confirms this (direct source reads of
`lib/letflow/engine/transition.ex`, `join_counter.ex`, `expr.ex` cited as already
supporting every primitive this subgraph needs), and AC6 makes it an explicit, checkable
gate (`git diff` must show zero changes under `lib/letflow/engine/`). This design adds no
new node type, no new edge-condition operator, and no new join semantics — it is a pure
recombination of node/edge types and an edge-condition grammar the engine already
executes today for the existing `parallel-assessment-fork`/`assessment-join` and
`eligibility-gate`/`authority-routing` subgraphs in this same definition.

Process-definition fixtures are not a runtime tenant-data path in the sense
`security-invariants.md` INV-1..INV-8 gate on (they are not an API route, not a
migration, not a secret, not response shaping of live tenant data) — they are seeded
*into* a tenant's definition store via the existing, unchanged `POST /api/v1/definitions`
path, through which every other process definition in this codebase already flows.
**SECURITY-REVIEWER is not required for this requirement** — this is a fixture-only
change with zero `lib/letflow/` code touched. If, at implementation time, ELIXIR-DEV finds
any reason this turns out to require a real code change (e.g. the structural validator
genuinely rejects the new subgraph and needs a fix), that would be new scope outside this
design and outside REQ-433's own OUT OF SCOPE clause — it must stop and get a fresh
CODE-DESIGNER pass, not patch `lib/letflow/engine/` under cover of this fixture-only
design.
