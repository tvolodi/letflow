# REQ-208 — Run Meridian's 3 simulation scenarios through REQ-205's harness

**Requirement:** REQ-208. Fourth requirement of S7 (`docs/migration/stage-7-simulation-uat-parity.md`).
**Stage:** S7
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Depends on:** REQ-205 (`lib/letflow/design/req205-simulation-harness-foundation.md`,
`test/support/simulation/runner.ex`, `test/support/simulation/seed.ex`) and REQ-199
(`Letflow`'s correlated-effect-ordering subsystem, ORD-01..04) — both confirmed
`status: done` on `main` as of this design session (`docs/requirements.yaml`, read
directly: REQ-205 line ~entry `status: done`, REQ-199 line 10843 `status: done`).
This is the load-bearing dependency statement AC4 (below) requires be made
explicitly, not assumed.

**Scope discipline** (mirrors REQ-206/207's own): this requirement runs Meridian
scenario content through the existing harness. It does **not** build
`POST /api/v1/instances/:id/advance-timer` (already filed as ISS-0389 by REQ-206;
referenced here, not re-filed), does not port the real R-Co scenario-definition YAML
corpus (already filed as ISS-0393; referenced here, not re-filed a third time), does
not touch SwiftRoute/Vortex (REQ-206/207), and does not build a native multi-voter
quorum-counting node type in `Letflow.Engine` (§2.2 states explicitly why this
requirement cannot and does not need to — the real, ISS-0388-ported process fixture
itself already reduces "multi-voter" to a single `HUMAN_TASK` node, so there is no
Engine gap to build around, only a modeling fact to disclose).

---

## §0 — Verified source-of-truth facts (not assumed)

### §0.1 R-Co unreachable — same finding as REQ-205/206/207's own sessions

```
ls "c:\Users\tvolo\dev\ai-dala\R-Co" -> No such file or directory (this session)
find / -maxdepth 3 -iname "*R-Co*" -o -iname "*ai-dala*" -> no checkout found
```

### §0.2 Company/org/process fixtures — real, ISS-0388-ported content (confirmed by direct read this session)

`test/fixtures/simulation/meridian/{company,org_structure}.yaml` and both existing
process fixtures were read in full this session, not inherited from a prior record:

- `company.yaml` — `slug: meridian`, `display_name: "Meridian Capital AG"`,
  `hostname: meridian.simulation.test`.
- `org_structure.yaml` — 10 real actor ids (`actor-meridian-{eva,thomas,julia,ben,
  sophie,lars,miriam,oliver,claudia,marcus}`) across 5 groups: `dept-exec` (eva),
  `dept-credit-de` (julia, ben, sophie, lars), `dept-risk` (thomas, miriam, oliver),
  `dept-compliance` (claudia), `dept-ops` (marcus). Matches ISS-0388's "10 meridian"
  count.
- `test/fixtures/simulation/meridian/process_claim_intake.yaml` — filename kept for
  backward compat; header comment states it was ported from R-Co's
  `process_loan_origination.yaml`. `name: "Loan Origination"`. **This is exactly**
  both `meridian-loan-origination-above-threshold`'s and
  `meridian-loan-origination-below-threshold`'s shared process — full graph read
  this session (28 edges, 21 nodes), reproduced in relevant part at §2.1.
- `test/fixtures/simulation/meridian/process_policy_binding.yaml` — filename kept for
  backward compat; header comment states it was ported from R-Co's
  `process_regulatory_compliance_review.yaml`. `name: "Regulatory Compliance
  Review"`. **This is exactly** `meridian-regulatory-compliance-review-bafin`'s
  process — full graph read this session (18 edges, 16 nodes), reproduced in
  relevant part at §2.2.

**No new process fixture is authored by this requirement** — both real fixtures
already model exactly the processes REQ-208's three scenarios need, unlike
REQ-206/207 which each had to author at least one test-local simplified graph from
scratch. §2 still designs test-local **simplified** graphs (SERVICE_TASK elision,
same REQ-206/207 workaround), but derived from these two already-real fixtures, not
invented.

### §0.3 R-Co's real scenario-definition YAMLs — unreachable, same disposition as REQ-206/207 (ISS-0393, not a new issue)

R-Co's real `tests/simulation/scenarios/meridian-*.yaml` corpus (the actual
scenario — preconditions/steps/expected_outcomes — files, a different file set from
§0.2's company/org/process fixtures) remains unreachable from this sandbox, per the
same finding REQ-206/207 each made for their own tenants. **ISS-0393
(`docs/issues/ISS-0393.yaml`, status `open`) already names Meridian explicitly**
in its `description` ("REQ-208 (Meridian) will likely need the same disclosure
unless this is fixed first") and lists `REQ-208` in its `related` field — this
design references ISS-0393 as-is and files no third duplicate. The 3 Meridian
scenario YAMLs this requirement authors are self-authored synthetic fixtures,
structurally faithful to REQ-208's own requirement-text field-by-field account,
carrying the same header-comment disclosure convention REQ-206/207 established:

```
# Synthetic — R-Co's tests/simulation/scenarios/<name>.yaml is unreachable from
# this sandbox (see lib/letflow/design/req208-meridian-scenario-execution.md §0.3;
# tracked by ISS-0393, not a new issue); structurally faithful to REQ-208's own
# requirement-text field-by-field account, not a byte-for-byte port.
```

### §0.4 `advance-timer` endpoint — confirmed absent, same finding as REQ-206/ISS-0389 (not re-filed)

```
grep -rn "advance-timer|advance_timer" lib/letflow/router.ex lib/letflow/routers/*.ex
-> zero matches (re-confirmed this session)
```

`docs/issues/ISS-0389.yaml` (status `open`) already names this exact gap, already
lists `REQ-208` in its `related` field, and already states in its own `description`:
"Already referenced as a blocking gap by REQ-208/209 per the run-history note for
REQ-206's done event." This design references ISS-0389, files no duplicate, and
**records this scenario's step 3 as `:blocked`, not `:skip`** — §1 below states
precisely why the two are different dispositions, and §2.3.4 states the concrete
finding text for the handoff's `result.issues`.

### §0.5 REQ-199 (correlated effect ordering) — confirmed `status: done`

`docs/requirements.yaml`, REQ-199 entry (~line 10840): `status: done`, stage S6.
Ports R-Co's ORD-01 (claim guard, `FOR UPDATE SKIP LOCKED`), ORD-02 (per-correlation
execute guard, transaction advisory lock), ORD-03 (per-correlation order/cursor
guard), ORD-04 (different correlations proceed independently in parallel). **This
requirement's own report must state this fact plainly (AC4)** — it is stated here,
verified from source, not inherited from the run-history note quoted in §0.4's
citation without independent re-confirmation (`docs/anti-patterns.md`'s
"inheriting a claim from a record instead of re-deriving it from the source").

**Material caveat this design surfaces regardless of REQ-199's `done` status (§2.1's
own finding, not deferred):** REQ-199's ORD-01..04 guards protect **out-of-band
effect completions re-entering the engine** (§0.5's own description: "a long-running
external effect completes out-of-band, its completion must be re-entered... in the
order the effects were emitted"). `Letflow.Simulation.Runner.run_steps/1` (read this
session, `test/support/simulation/runner.ex`) dispatches every `:api` step
**sequentially**, in an `Enum.reduce` over `scenario.steps` in declared order — there
is no concurrent/parallel step-dispatch mechanism in the harness as shipped. This
means: **REQ-208's own scenario execution, as designed here within Runner's existing
sequential-dispatch contract, does not itself generate genuinely concurrent
out-of-band completions and therefore does not independently re-exercise ORD-01/02/03
under real concurrent load** — it exercises only that the *shape* of a
parallel-fork/parallel-join graph (3 independent branches, one join) transitions
correctly when each branch's `HUMAN_TASK` is completed one at a time, which is a
real, valuable engine-instance-shape test but is not the same claim as "no lost
update under concurrent completions." This is stated explicitly per the
requirement's own instruction ("if either was not fully exercised... note that
explicitly... rather than assuming S3's unit tests already cover it") — see §2.1's
finding and §4's follow-up-issue recommendation, rather than silently letting a
sequential run stand in for a concurrent-correctness claim.

### §0.6 No native multi-voter / quorum-counting primitive in `Letflow.Engine` — confirmed, and not a gap this requirement needs to fill

```
grep -rn "quorum\|multi.voter\|MULTI_VOTER" lib/letflow/ --include=*.ex
-> zero matches (this session, excluding this design doc and test fixtures)
```

`process_claim_intake.yaml`'s own header comment (§0.2, ISS-0388-ported, R-Co's own
authored content) states the process's `credit-committee-vote` node is
"multi-voter, mapped to `HUMAN_TASK`" — i.e., **R-Co's own scenario design already
reduces "committee of N voters" to a single `HUMAN_TASK` node**, not a Letflow
migration gap invented here. `Letflow.Tasks`' task lifecycle (confirmed by reading
`lib/letflow/routers/tasks.ex`'s `handle_complete_result/2` this session, matching
REQ-206's §0 finding) allows **exactly one** `complete` call per task — a second
`complete` on an already-`COMPLETED` task returns `{:error, {:task_not_pending, ...}}`.
There is therefore no way, with today's Engine, to model "3 independent voters each
submit their own vote and the engine tallies quorum" as 3 separate task completions
on the same node — only one actor can ever complete `credit-committee-vote`.

**Design resolution, stated explicitly (this design's own modeling decision, not a
silently-made assumption):** the single `credit-committee-vote` `HUMAN_TASK`
completion is modeled as the **committee's already-tallied decision being recorded**
by whichever actor chairs the committee — its `output_variables` payload carries
both the individual vote fields (`vote_credit_de`, `vote_risk`, `vote_compliance` —
one committee member per department represented, per the requirement's own "quorum
2-of-3" framing) **and** the derived `committee_outcome` field, submitted together in
one `POST .../complete` call. This is not the engine computing or enforcing quorum —
it is the test scenario supplying pre-tallied vote data as ordinary task output
variables, exactly the same mechanism REQ-206/207 already used for every other
business decision in their own scenarios (`ops_decision`, `capacity_decision`, etc.).
**Quorum 2-of-3 "confirmed reached" (AC1) is therefore verified as an
internal-consistency check on real queried state** — the persisted vote fields
genuinely show 2-of-3 `"approve"` and `committee_outcome == "approved"` is
consistent with that tally — not as evidence that Engine itself enforced a
quorum rule (it has no such rule to enforce). §2.1/§3.1 make this concrete.

### §0.7 Real routes, claim-before-complete, role-attributed assignee resolution — all reused verbatim from REQ-206/207's own §0 findings

No new discovery needed; re-confirmed unchanged this session:

- `GET /api/v1/tasks?instance_id=<uuid>&status=PENDING` (`lib/letflow/routers/tasks.ex`'s
  `handle_list/3`) is the real task-lookup-by-instance mechanism.
- Claim is **not** required before complete (`lib/letflow/api/authorization.ex`'s
  `evaluate_access/2`: `:TasksComplete` always yields unconditional `:Allow`;
  `Engine.complete_task/3` applies no assignee precondition).
- A role-attributed `HUMAN_TASK`'s `assignee_type` is `nil`, `assignee_ref` is the
  literal `role` attribute string (`lib/letflow/engine/task_activation.ex`'s
  `resolve_assignee/1`) — every `task_assigned` check below against a role-attributed
  task asserts `outcome in [:pass, :fail]` with the real `observed.assignee_ref`
  string as evidence, same limitation REQ-206/207 already recorded, not new here.

### §0.8 `PARALLEL_GATEWAY` split/join — real and shipped (REQ-051, `status: done`)

`docs/requirements.yaml` REQ-051 entry: `status: done`, stage S3, "Parallel gateway
split and join." Confirmed by reading `lib/letflow/engine/transition.ex` this
session: a token reaching a `PARALLEL_GATEWAY` with N outgoing edges produces N
independent tokens (`parallel_split`, ~line 790); the join (`fire_join/5`, ~line
918) fires once every expected branch has arrived (`join_outcome/1`'s `:wait` /
`:fire` / `:cancel_join` states), merging `instance_state.variables` via
`VariableMerge.merge/3` before continuing past the join. This is real, shipped,
already-tested-at-the-unit-level (S3) machinery — REQ-208's own contribution is
exercising it through the harness's real HTTP dispatch path for the first time in
S7, not building or unit-testing it fresh. `SERVICE_TASK` dispatch is **not**
implemented (`dispatch_node/4`'s catch-all clause, same platform-wide gap
REQ-206/207 already found and worked around) — §2 below applies the identical
elision workaround to both real Meridian process fixtures.

---

## §1 — Scenario YAML corpus: authoring and parsing

### 1.1 File layout

```
test/fixtures/simulation/meridian/scenarios/loan-origination-above-threshold.yaml
test/fixtures/simulation/meridian/scenarios/loan-origination-below-threshold.yaml
test/fixtures/simulation/meridian/scenarios/regulatory-compliance-review-bafin.yaml
```

New `scenarios/` subdirectory, parallel to REQ-206/207's own layout, under the
existing `test/fixtures/simulation/meridian/` tree (`company.yaml`,
`org_structure.yaml`, both process fixtures — all untouched by this requirement).
Each file carries §0.3's header-comment convention.

### 1.2 YAML shape — reuses `Letflow.Simulation.Scenario`'s fields, plus this requirement's own additive extension (§2)

Top-level keys map 1:1 onto `Scenario`'s struct fields as shipped by REQ-205 +
REQ-206 + REQ-207 (`id`, `company_id`, `process_id`, `actors`, `preconditions`,
`steps`, `expected_outcomes`, `unbuilt_feature`), plus the one new legal `via` value
and its accompanying field this requirement adds (§2.1).

### 1.3 Parsing — `Letflow.Simulation.ScenarioFixture.load!/1`, reused as-is, one closed-vocabulary extension

**This requirement does not write a new parser.** `test/support/simulation/scenario_fixture.ex`
(shipped by REQ-206, unchanged by REQ-207) is imported and called exactly as
REQ-206/207's own test modules do:

```
@spec load!(path :: String.t()) :: Letflow.Simulation.Scenario.t()
```

The one new `via: :blocked` value (§2.1) and the one new `verification.method:
:no_task_of_type` value (§2.2) both parse through the parser's existing
`String.to_existing_atom/1`-against-a-declared-atom-set discipline — this requires
`Scenario.step()`'s `@type via` and `Scenario.expected_outcome()`'s
`@type method` to each declare the new atom (§2's type tables), which
`String.to_existing_atom/1` then resolves without any parser code change, exactly
the same "closed-vocabulary parsing, additive only" mechanism REQ-206/207 already
established. No `ArgumentError`-raising discipline needs to change — the parser
already raises `ArgumentError` on any value outside the currently-declared atom set,
which is precisely what makes this addition non-silent from the parser's point of
view.

---

## §2 — Runner extension: `:blocked` (step-level) and `:no_task_of_type` (verification method)

Both additions are **strictly additive** to `test/support/simulation/runner.ex` as
shipped by REQ-205/206/207 — no existing field is renamed, retyped, or removed, and
every existing test (`runner_test.exs`, `req206_swiftroute_test.exs`,
`req207_vortex_test.exs`) keeps passing unmodified, since every new field/branch
defaults to a value that reproduces today's exact behavior when absent, and every
existing atom in each extended enum is preserved verbatim.

### 2.1 `:blocked` — step-level, alongside `:ok`/`:error`/`:deferred_to_s8`/`:skip`

**Why a fourth `via`/`outcome` value, not a reuse of `:skip`:** the requirement text
is explicit that BLOCKED and SKIP are *not* the same disposition. `:skip` (REQ-206
§2.1) is reserved for the case **the scenario's own documentation already names an
acceptable fallback** for a missing capability — SwiftRoute's timeout-escalation
scenario's own note field literally states "if not available, this scenario is
marked SKIP with severity MINOR." `meridian-regulatory-compliance-review-bafin` has
**no such documented fallback** — its own point (BaFin regulatory-notice filing on
SLA breach) is entirely unreachable without `advance-timer`, and nothing in the
scenario's own text treats that as acceptable. Reusing `:skip` here would misrepresent
a genuinely blocking, undocumented gap as an anticipated, shrugged-off one — exactly
the false-equivalence the requirement's own text warns against ("Unlike REQ-206's
shipment-timeout scenario, THIS scenario's own YAML carries no documented
SKIP/MINOR fallback"). A distinct `:blocked` value keeps the two facts
distinguishable in every report/query over `step_result.outcome` from this point on.

**Where it lives:**

| Struct | New field | Type | Default when absent |
|---|---|---|---|
| `Scenario.step()` | `via` | `:api \| :gui \| :skip \| :blocked` (was three-valued) | n/a (required, existing field, one new legal value) |
| `Scenario.step()` | `blocked_by` | `String.t() \| nil` | `nil` (required when `via == :blocked`; the referenced issue id, e.g. `"ISS-0389"` — never a freshly-invented issue id, never left blank, since a `:blocked` step's whole point is naming the specific tracked gap) |
| `Scenario.step()` | `note` | `String.t() \| nil` | `nil` (existing field, REQ-206 §2.1 — reused verbatim for `:blocked` steps to carry the human-readable finding text) |
| `RunReport.step_result()` | `outcome` | `:ok \| :error \| :deferred_to_s8 \| :skip \| :blocked` (was four-valued) | n/a |
| `RunReport.step_result()` | `severity` | `:minor \| :major \| :blocker \| nil` | `nil` for every non-`:skip`/non-`:blocked` outcome. **A `:blocked` step's `severity` is always `:blocker`, fixed, not author-supplied** — unlike `:skip` (whose `severity` is a fixture-authoring choice among all three values), a step whose whole scenario-point is unreachable has no lesser-severity reading; the executor sets it, the fixture does not declare it, and a `:blocked` step declared with a `severity` key at all is a fixture-authoring error (same fail-loud discipline as a `:skip` step missing its required `severity`) |
| `RunReport.step_result()` | `blocked_by` | `String.t() \| nil` | `nil` (echoes the step's `blocked_by`; `nil` for every other outcome) |

**Execution algorithm change (`run_steps/1`'s existing `case step.via do` dispatch,
REQ-206 §2.1's own extension point):** a fourth branch, parallel in shape to the
existing `:skip` branch:

- `blocked_by` is read via `Map.get(step, :blocked_by)`; if `nil`, raise
  `ArgumentError` at run time ("step with via: :blocked is missing a blocked_by
  field: `#{inspect(step)}`") — same fail-loud discipline `:skip`'s missing-`severity`
  check already established, never silently defaulting to an unnamed gap.
- The constructed `step_result` carries `outcome: :blocked`, `captured: nil`,
  `severity: :blocker` (fixed, per the table above — not read from the step),
  `blocked_by: blocked_by`, `detail: Map.get(step, :note) || "blocked; see " <>
  blocked_by`.
- No HTTP dispatch occurs — same non-negotiable rule `:gui`/`:skip`/`:deferred_to_s8`
  already enforce.
- Template substitution's existing fail-closed rule (a later `:api` step's
  `{{produces.X}}` referencing a `:blocked` step's nonexistent `captured`) extends
  verbatim, same as it already does for `:skip`/`:gui`.

**`meridian-regulatory-compliance-review-bafin` fixture authoring, concretely:** step
3 (the timer-advance step) is authored:

```
via: blocked
blocked_by: "ISS-0389"
note: >
  POST /api/v1/instances/:id/advance-timer does not exist -- grep of
  lib/letflow/router.ex and lib/letflow/routers/*.ex, zero matches, per
  lib/letflow/design/req208-meridian-scenario-execution.md §0.4. Unlike
  REQ-206's shipment-timeout-escalation scenario, this scenario's own YAML
  documents no SKIP/MINOR fallback for the missing endpoint -- BaFin
  regulatory-notice filing on SLA breach is this scenario's entire point and
  is unreachable without it. Recorded BLOCKED, not SKIP.
```

Steps 1 and 2 stay `via: api` (§3.3).

### 2.2 `:no_task_of_type` — new expected-outcome verification method, for EO-002's negative assertion

**Checked, per the task's own instruction: does `Runner`'s existing `task_assigned`
method support asserting absence? No.** Reading `verify_outcome/2`'s `:task_assigned`
clause (`test/support/simulation/runner.ex`, read this session) shows its `with`
chain resolves an `args."task_ref"` value via the existing `resolve_ref/3` template
helper and then calls `Tasks.get_task/2` on that resolved id directly — any
`{:error, _}` at any step of that chain (an unresolved template, an invalid id, a
genuinely-not-found id) falls through to the same `else` clause, which always
returns `outcome: :fail`.

This method **requires a resolved `task_ref`** — an already-known task id (typically
a `{{produces.X.id}}` template pointing at a prior step's captured response). There
is no `task_ref` to resolve for "a task of this type was never created" — the whole
point of EO-002 is that no such task, and therefore no such id, exists anywhere.
Feeding it a nonexistent id would `{:error, :not_found}` through `Tasks.get_task/2`
and land on `outcome: :fail` regardless of whether the absence is the *scenario's
own point* (correct routing) or a genuine bug (e.g. a typo'd `task_ref`) —
indistinguishable failure modes at that call site, exactly the ambiguity the
requirement's own instruction is asking to resolve. **This is new design surface,
confirmed, not an existing capability this design merely restates.**

**New verification method, additive to the closed enum (same pattern as REQ-207
§3.2's `:audit_event_ordering` addition):**

| Struct | New field | Type | Default when absent |
|---|---|---|---|
| `Scenario.expected_outcome().verification.method` | — | `:task_assigned \| :instance_state \| :audit_event \| :audit_event_ordering \| :no_task_of_type` (new 5th value) | n/a |

```
args :: %{
  required("instance_ref") => produces_template :: String.t(),
  required("node_id")      => String.t(),   # the process node id whose task must not exist for this instance, e.g. "credit-committee-vote"
  optional("prefix")       => String.t()    # same fetch_prefix/1 convention every other method already uses
}
```

**`verify_outcome/2`'s new clause, described (no code):** resolves `instance_ref`
via the existing `resolve_ref/3` template-substitution helper (same mechanism every
other method already uses), resolves `prefix` via the existing `fetch_prefix/1`
helper, then calls `Tasks.list_tasks/2` — the real, already-shipped context
function (`lib/letflow/tasks.ex`, confirmed this session) — with
`%{page_size: 100, instance_id: instance_ref}` and **no `status` filter** (deliberate:
absence must hold across every task status, not merely `PENDING` — a `COMPLETED`
committee-vote task is exactly as strong a counter-example to "no committee-vote task
exists for this instance" as a `PENDING` one, and EO-002's own framing, "no
committee-vote task exists for any actor," makes no status distinction). Returns
`:pass` iff **no** item in the real queried `items` list has `node_id == expected
node_id`; `:fail` otherwise, with `observed` carrying **the full list of
`{node_id, status}` pairs the query actually returned for that instance** (never a
bare `true`/`false` or an opaque count) — the same "always carry real queried state
in `observed`, never infer PASS from absence of error" discipline every other method
already follows, and the concrete mechanism that satisfies AC2's "verified by
querying real task state and confirming absence, not merely by the L1/L2 tasks being
present" (the `observed` list, read directly, shows both that L1/L2 tasks exist
*and* that no `credit-committee-vote` entry is among them — one query, both facts,
not two separately-reasoned claims).

### 2.3 Full extended type summary (for ELIXIR-DEV's direct reference)

```
Scenario.step().via                          :: :api | :gui | :skip | :blocked                                  (was 3-valued)
Scenario.step().blocked_by                   :: String.t() | nil                                                (new; required iff via == :blocked)

RunReport.step_result().outcome              :: :ok | :error | :deferred_to_s8 | :skip | :blocked                (was 4-valued)
RunReport.step_result().blocked_by           :: String.t() | nil                                                 (new; echoes step.blocked_by)
RunReport.step_result().severity             :: :minor | :major | :blocker | nil                                 (unchanged type; :blocked steps always fixed to :blocker at run time)

Scenario.expected_outcome().verification.method ::
  :task_assigned | :instance_state | :audit_event | :audit_event_ordering | :no_task_of_type    (new 5th value)
```

No change to `Scenario.precondition()`, `RunReport.precondition_result()`, the
`:task_assigned`/`:instance_state`/`:audit_event`/`:audit_event_ordering` clauses'
own internals, or `RunReport.disposition`/`RunReport.notes` (`:unbuilt_feature`
machinery, REQ-206 §2.2) — none of this requirement's three scenarios carries an
`unbuilt_feature` field; every scenario here is `disposition: :executed` (§4).

---

## §3 — Test-local simplified process graphs (SERVICE_TASK workaround, derived from the real fixtures)

Per §0.8, `SERVICE_TASK` dispatch is not yet implemented — both real Meridian
process fixtures have `SERVICE_TASK` nodes on their critical path (§0.2's full
graphs). Same workaround REQ-206/207 both used: a test-local simplified graph,
defined inline in the test module (not committed as a new `process_*.yaml`), that
replaces every `SERVICE_TASK` node with either a direct edge to the next real node
or an `END` node, preserving every `HUMAN_TASK`/`EXCLUSIVE_GATEWAY`/
`PARALLEL_GATEWAY` node and every condition string verbatim from the real fixture.

### 3.1 `@simple_loan_origination_graph` (for both loan-origination scenarios)

Derived from `process_claim_intake.yaml` (§0.2), `SERVICE_TASK` nodes elided:

| Real fixture node | Simplified graph treatment |
|---|---|
| `start` (START) | Unchanged |
| `parallel-assessment-fork` (PARALLEL_GATEWAY) | Unchanged — this is the scenario's whole point, 3 real outgoing edges preserved verbatim (`e1`→credit-memo-review, `e2`→risk-assessment, `e3`→kyc-aml-check) |
| `credit-memo-review` (HUMAN_TASK, `role-credit-manager`) | Unchanged |
| `credit-memo-timeout` (SERVICE_TASK, on-timeout fallback) | **Elided** — not exercised (no scenario here relies on this branch's node timing out); its edge `e5`→assessment-join is dropped along with it, since `credit-memo-review`'s real, non-timeout path (`e4`) is what both scenarios use |
| `risk-assessment` (HUMAN_TASK, `role-risk-manager`) | Unchanged |
| `risk-assessment-timeout` (SERVICE_TASK, on-timeout fallback) | **Elided**, same rationale |
| `kyc-aml-check` (SERVICE_TASK) | **Replaced** by a direct edge from `parallel-assessment-fork` straight to `kyc-routing` **with `variables.kyc_status` supplied as an `initial_variables` value at instance-start time** (step 1's `POST /api/v1/instances` params), rather than as a real KYC-screening service dispatch — this substitution is stated explicitly since it changes "automated KYC screening" from a service call to a pre-seeded input variable in the test topology, exactly the same class of disclosed substitution REQ-207 §2.2 made for `quarantine-batch` |
| `kyc-manual-review` (HUMAN_TASK, `role-compliance-officer`) | Unchanged — reachable only if `kyc_status` is `'hit'`/`'inconclusive'` (edges `e10`/`e11`); **neither of this requirement's 2 loan-origination scenarios sets `kyc_status` to either value** (both set `kyc_status: 'clear'`, taking edge `e9` straight to `assessment-join`), so this node is present in the simplified graph (structural validity) but not exercised by either scenario — stated explicitly, not silently assumed exercised |
| `kyc-timeout` (SERVICE_TASK) | **Elided**, same rationale (unreachable in both scenarios' actual path per the row above) |
| `kyc-routing` (EXCLUSIVE_GATEWAY) | Unchanged — `kyc_status` conditions kept verbatim |
| `assessment-join` (PARALLEL_GATEWAY) | Unchanged — the join counterpart to `parallel-assessment-fork`; fires once all 3 branches (credit-memo, risk, kyc) arrive, per §0.8's `join_outcome/1` mechanism |
| `eligibility-gate` (EXCLUSIVE_GATEWAY) | Unchanged — `credit_decision == 'pass' && risk_rating != 'unacceptable'` / the negation, kept verbatim (this edge is both scenarios' shared entry point into the amount-based routing below) |
| `authority-routing` (EXCLUSIVE_GATEWAY) | Unchanged — `requested_amount_eur <= 500000` / `> 500000` kept verbatim, this is **the** load-bearing condition distinguishing the two scenarios |
| `l1-approval` (HUMAN_TASK, `role-credit-manager`) | Unchanged |
| `l2-approval` (HUMAN_TASK, `role-credit-director`) | Unchanged |
| `credit-committee-vote` (HUMAN_TASK, `role-committee-member`) | Unchanged — per §0.6, this single node **is** R-Co's own "multi-voter" modeling; no further substitution needed |
| `committee-timeout` (SERVICE_TASK, on-timeout fallback) | **Elided** — not exercised (both scenarios complete the committee-vote task for real, no timeout path) |
| `create-facility` (SERVICE_TASK) | **Replaced** by a direct edge from `l2-approval`'s `approve` branch and `credit-committee-vote`'s `approved` branch straight to `disburse-loan` — the "core-banking facility creation" service call cannot be dispatched, so the simplified graph represents "facility created" as *reaching* `disburse-loan`, stated explicitly (same disclosed-substitution pattern as REQ-207 §2.1's `assign-line`) |
| `disburse-loan` (HUMAN_TASK, `role-loan-ops`) | Unchanged |
| `decline-application` (SERVICE_TASK) | **Replaced** by a direct edge to `end-declined`, same substitution rationale — not exercised by either of this requirement's 2 scenarios (both are approval paths), kept only for structural completeness (every node reachable from `start` needs a path to an END node, REQ-028's structural validator) |
| `end-disbursed`, `end-declined` (END) | Unchanged |

**Concretely, the simplified edge set (both scenarios share this one graph; only
`requested_amount_eur` differs):**

```
start -> parallel-assessment-fork
parallel-assessment-fork -> credit-memo-review
parallel-assessment-fork -> risk-assessment
parallel-assessment-fork -> kyc-routing                      [kyc_status supplied as initial_variables, no real KYC-screening dispatch]
credit-memo-review -> assessment-join
risk-assessment -> assessment-join
kyc-routing -> assessment-join                                [kyc_status == 'clear']
kyc-routing -> kyc-manual-review                               [kyc_status == 'hit']
kyc-routing -> kyc-manual-review                               [kyc_status == 'inconclusive']
kyc-manual-review -> assessment-join
assessment-join -> eligibility-gate
eligibility-gate -> authority-routing                          [credit_decision == 'pass' && risk_rating != 'unacceptable']
eligibility-gate -> end-declined                               [credit_decision == 'fail' || risk_rating == 'unacceptable']
authority-routing -> l1-approval                               [requested_amount_eur <= 500000]
authority-routing -> credit-committee-vote                     [requested_amount_eur > 500000]
l1-approval -> l2-approval                                     [l1_decision == 'approve' || l1_decision == 'escalate']
l1-approval -> end-declined                                    [l1_decision == 'reject']
l2-approval -> disburse-loan                                   [l2_decision == 'approve']
l2-approval -> end-declined                                    [l2_decision == 'reject']
credit-committee-vote -> disburse-loan                         [committee_outcome == 'approved']
credit-committee-vote -> end-declined                          [committee_outcome == 'rejected']
disburse-loan -> end-disbursed
```

`requested_amount_eur: 750000` (above-threshold scenario) forces
`authority-routing -> credit-committee-vote`, never `-> l1-approval`.
`requested_amount_eur: 50000` (below-threshold scenario) forces the reverse — this is
the load-bearing assertion both AC1 and AC2 depend on (§3.1/§3.2's outcome tables).

### 3.2 `@simple_regulatory_review_graph` (for the BaFin scenario)

Derived from `process_policy_binding.yaml` (§0.2), `SERVICE_TASK` nodes elided:

| Real fixture node | Simplified graph treatment |
|---|---|
| `start` (START) | Unchanged |
| `evidence-collection` (HUMAN_TASK, `role-compliance-officer`) | Unchanged |
| `evidence-collection-timeout` (SERVICE_TASK, on-timeout fallback) | **Elided** — not exercised (step 1/2 complete this task for real, well within any timeout) |
| `risk-evaluation` (HUMAN_TASK, `role-risk-manager`) | Unchanged — **this is the node whose `on_timeout` boundary step 3 needs to advance**, per the requirement's own quoted note ("UAT-RUNNER advances the timer boundary on the risk-evaluation node"); this task is created (real, verified — §3.4) but **never completed** by any scenario step, since the scenario's whole point is the SLA-breach path, not the normal-completion path |
| `risk-evaluation-timeout` (SERVICE_TASK, on-timeout fallback) | **Kept as the target of the on_timeout edge** (not elided) so the graph's on-timeout boundary structure stays intact for a future re-run once `advance-timer` exists — but never reached by this run, since reaching it requires the blocked capability |
| `regulatory-auto-escalation` (SERVICE_TASK) | **Kept, unreached** — same rationale as the row above; this node is literally the scenario's entire unreachable point (the BaFin regulatory-notice filing), so eliding it would erase the very thing step 3's `:blocked` disposition needs to name |
| `severity-routing`, `remediation-subprocess`, `post-remediation-check`, `findings-sign-off`, `cro-sign-off-timeout`, `ceo-override`, `archive-review`, `reopen-review`, `end-closed`, `end-reopened` | **Present in the simplified graph for structural completeness (every node reachable from `start` needs a path to an END node) but not exercised by this scenario's 3 steps at all** — none of this scenario's `expected_outcomes` (§3.4) reference any of these nodes; they exist only so the graph as a whole remains a valid process definition Letflow can activate |

No edge in this graph is altered from the real fixture — unlike §3.1, **no
`SERVICE_TASK` on this scenario's own actually-exercised path needs elision at all**,
since the actually-exercised path (`start -> evidence-collection -> risk-evaluation`,
then blocked) contains none. The elisions above exist only to keep the *rest* of the
graph structurally valid, not because this scenario's own 3 steps ever reach a
`SERVICE_TASK`.

---

## §4 — Per-scenario execution plan

### 4.1 `meridian-loan-origination-above-threshold` (AC1)

6 steps, all `via: api`, using `@simple_loan_origination_graph` (§3.1) seeded under a
process definition name distinct from the real fixture's (matching REQ-206/207's
`Simple<Name>-<unique>` naming convention, e.g. `SimpleLoanOrigination-<unique>`).

| Step | Actor | `action` | `params` (post-template-substitution) | `produces` |
|---|---|---|---|---|
| 1 (relationship manager submits application) | `actor-meridian-lars` (dept-credit-de) | `POST /api/v1/instances` | `{"definition_name": "<seeded name>", "initial_variables": {"requested_amount_eur": 750000, "kyc_status": "clear"}}` | `"instance"` |
| 2a (credit-memo task lookup) | `actor-meridian-julia` (dept-credit-de, token `roles: ["role-credit-manager"]`) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"credit_memo_task"` |
| 2b (credit-memo complete) | `actor-meridian-julia` | `POST /api/v1/tasks/{{produces.credit_memo_task.id}}/complete` | `{"output_variables": {"credit_decision": "pass"}}` | `"credit_memo_result"` |
| 3a (risk-assessment task lookup) | `actor-meridian-thomas` (dept-risk, token `roles: ["role-risk-manager"]`) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"risk_task"` |
| 3b (risk-assessment complete) | `actor-meridian-thomas` | `POST /api/v1/tasks/{{produces.risk_task.id}}/complete` | `{"output_variables": {"risk_rating": "acceptable"}}` | `"risk_result"` |
| 4 (verify all 3 assessment tracks were created, before completing the committee vote — see AC1's own "confirmed created from real queried task state" wording) | n/a (a `task_assigned`/list-based expected outcome, not a step dispatch — see the "3 tracks" outcome below) | — | — | — |
| 5a (committee-vote task lookup) | `actor-meridian-julia` (chairing, token additionally `roles: ["role-committee-member"]` — see settled-choice note below) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` | n/a | `"committee_task"` |
| 5b (committee-vote complete, pre-tallied 2-of-3 per §0.6) | `actor-meridian-julia` | `POST /api/v1/tasks/{{produces.committee_task.id}}/complete` | `{"output_variables": {"vote_credit_de": "approve", "vote_risk": "approve", "vote_compliance": "reject", "committee_outcome": "approved"}}` | `"committee_result"` |
| 6 (verify disbursement) | n/a (expected outcome, not a dispatch) | — | — | — |

The scenario's own literal "6 steps" (per the requirement text: "6 api steps") maps
onto this table's 6 *business*-level dispatches (1, 2b, 3b, 5b, plus the two
verification-only rows 4/6 folded into `expected_outcomes` rather than counted as
separate HTTP dispatches, exactly as REQ-206/207's own step-vs-lookup convention
already established: lookup dispatches 2a/3a/5a are `Runner`-level plumbing, not
additional business steps).

**Committee-member role-grant choice, settled here (not deferred):** `org_structure.yaml`
has no `role-committee-member` group (§0.2's 5 groups are all department groups, not
role groups) — same shape of gap REQ-206's §3.2 already hit for `role-ceo`. This
design resolves it the same way REQ-206 did: `actor-meridian-julia` (dept-credit-de)
is granted `roles: ["role-credit-manager", "role-committee-member"]` at
token-creation time (a per-token grant, not an `org_structure.yaml` change,
consistent with REQ-206's own precedent) — she is both the credit-memo reviewer
*and* (in this scenario's telling) the committee chair who records the tallied vote.

**All 6 `expected_outcomes` (AC1's own itemized list, each verified against real
queried state):**

1. **3 parallel assessment tracks confirmed created** — a new expected outcome using
   `:instance_state`'s existing `args."variables"` matching is not sufficient here
   (it would only prove the *final* merged variables, not that 3 distinct tasks were
   independently created); instead this is 3 separate `task_assigned`-style checks —
   or, more directly, one real `GET /api/v1/tasks?instance_id=...` list query
   (asserted in the test body, not necessarily a formal `expected_outcome` entry)
   confirming `credit-memo-review`, `risk-assessment`, and (had `kyc_status` been
   `'hit'`/`'inconclusive`) `kyc-manual-review` node ids each produced a real task
   row at the point right after step 1 — this is the concrete mechanism for "all
   three parallel assessment tracks are confirmed created from real queried task
   state" (AC1's literal wording), run against the real `PARALLEL_GATEWAY` split
   §0.8 confirmed is shipped, not inferred from the scenario eventually completing.
2. `task_assigned` — the `credit-committee-vote` `HUMAN_TASK` (not `l1-approval`) was
   actually created, `assignee_ref == "role-committee-member"` — direct evidence
   `authority-routing`'s `> 500000` edge was taken. This is the scenario's "the
   committee-vote route is confirmed taken (not the L1/L2 chain)" assertion (AC1).
3. `:no_task_of_type` — **no `l1-approval` task exists for this instance** (the
   converse check to outcome 2 — confirms the committee route was taken exclusively,
   not that both routes were somehow reached), `args: {"instance_ref":
   "{{produces.instance.instance_id}}", "node_id": "l1-approval"}`.
4. `instance_state` — persisted `variables` show `vote_credit_de: "approve"`,
   `vote_risk: "approve"`, `vote_compliance: "reject"` **and**
   `committee_outcome: "approved"` — the internal-consistency check §0.6 designed
   (2 of 3 vote fields `"approve"`, consistent with the recorded outcome). This is
   the concrete mechanism for AC1's "quorum 2-of-3 is confirmed reached from the
   actual committee_outcome variable."
5. `instance_state` (second entry) — final instance `status == "COMPLETED"`, at
   `end-disbursed` (not `end-declined`) — AC1's "disbursement completes on
   end-disbursed."
6. `audit_event` — at least one audit entry exists for the committee-vote task's
   `complete` action, scoped to that task/instance id (REQ-195/196's audit store,
   same mechanism REQ-206/207 already use).

### 4.2 `meridian-loan-origination-below-threshold` (AC2)

6 steps, same `@simple_loan_origination_graph` (§3.1), same seeded definition,
`requested_amount_eur: 50000`.

| Step | Actor | `action` | `params` | `produces` |
|---|---|---|---|---|
| 1 (submit application) | `actor-meridian-lars` | `POST /api/v1/instances` | `{"definition_name": "<seeded name>", "initial_variables": {"requested_amount_eur": 50000, "kyc_status": "clear"}}` | `"instance"` |
| 2a/2b (credit-memo lookup+complete) | `actor-meridian-julia` (`roles: ["role-credit-manager"]`) | `GET .../tasks?...` then `POST .../complete` | n/a / `{"output_variables": {"credit_decision": "pass"}}` | `"credit_memo_task"` / `"credit_memo_result"` |
| 3a/3b (risk-assessment lookup+complete) | `actor-meridian-thomas` (`roles: ["role-risk-manager"]`) | `GET .../tasks?...` then `POST .../complete` | n/a / `{"output_variables": {"risk_rating": "acceptable"}}` | `"risk_task"` / `"risk_result"` |
| 4a/4b (L1-approval lookup+complete) | `actor-meridian-ben` (dept-credit-de, `roles: ["role-credit-manager"]`) | `GET .../tasks?...` then `POST .../complete` | n/a / `{"output_variables": {"l1_decision": "approve"}}` | `"l1_task"` / `"l1_result"` |
| 5a/5b (L2-approval lookup+complete) | `actor-meridian-eva` (dept-exec, `roles: ["role-credit-director"]`) | `GET .../tasks?...` then `POST .../complete` | n/a / `{"output_variables": {"l2_decision": "approve"}}` | `"l2_task"` / `"l2_result"` |
| 6 (verify disbursement + EO-002's negative assertion) | n/a (expected outcomes) | — | — | — |

Same "6 api steps" framing as §4.1 — 5 business-level dispatches (1, 2b, 3b, 4b, 5b)
plus outcome verification, lookup dispatches folded in as plumbing.

**Expected outcomes:**

1. `task_assigned` — `l1-approval` task was created, `assignee_ref ==
   "role-credit-manager"` — confirms `authority-routing`'s `<= 500000` edge was
   taken.
2. **`:no_task_of_type` — EO-002's negative assertion, the literal design point of
   this scenario's own AC**: `args: {"instance_ref":
   "{{produces.instance.instance_id}}", "node_id": "credit-committee-vote"}`. Per
   §2.2, this queries the instance's real task list (all statuses, not just
   `PENDING`) and asserts no `credit-committee-vote`-node task appears anywhere in
   it — not inferred from "the L1/L2 tasks are present" (AC2's own wording,
   satisfied because this same query's `observed` payload shows both facts from
   one real list, per §2.2's design).
3. `instance_state` — final instance `status == "COMPLETED"`, at `end-disbursed`.
4. `audit_event` — an audit entry exists for the L2-approval task's `complete`
   action.

### 4.3 `meridian-regulatory-compliance-review-bafin` (AC3)

3 steps, using `@simple_regulatory_review_graph` (§3.2).

| Step | Disposition | Mechanism |
|---|---|---|
| 1 | Real (`via: api`) | `POST /api/v1/instances` — starts the review instance. `actor-meridian-claudia` (dept-compliance, `roles: ["role-compliance-officer"]`), no `initial_variables` needed (the graph's own conditions aren't evaluated until `severity-routing`, never reached by this scenario). `produces: "instance"`. |
| 2 | Real (`via: api`, 2 dispatches: lookup + complete) | `GET /api/v1/tasks?instance_id={{produces.instance.instance_id}}&status=PENDING` (`produces: "evidence_task"`), then `POST /api/v1/tasks/{{produces.evidence_task.id}}/complete` with `{"output_variables": {}}` (`actor-meridian-claudia`, `produces: "evidence_result"`) — completes `evidence-collection`, real transition to `risk-evaluation` per edge `e1`. |
| 3 | `via: blocked`, `blocked_by: "ISS-0389"` | Per §2.1 — no HTTP dispatch. `note` cites the grep evidence and the "no documented fallback" distinction verbatim (§2.1's concrete text). |

**Steps 1 and 2's real, queried-state verification (AC3's "steps 1 and 2 run for real
against real queried state"):**

1. `instance_state` — instance is `ACTIVE` (not errored, not terminal) immediately
   after step 1.
2. `task_assigned`-style check — the `risk-evaluation` `HUMAN_TASK` (role
   `role-risk-manager`) exists and is `PENDING` after step 2 completes
   `evidence-collection` — real evidence that `e1` fired and the instance is
   genuinely paused exactly at the node whose timer boundary step 3 would need to
   advance, not merely "step 2 didn't error." This is the concrete state step 3's
   `:blocked` disposition is blocked *from progressing past* — stated as evidence,
   not assumed.

**Finding reported to ORCH (AC3's second half — referencing ISS-0389, not
duplicating it), per `docs/agents/protocols/ISSUE_QUEUE.md`:** ELIXIR-DEV's WF-02
handoff (`step-02a-elixir-dev.json`) carries, in `result.issues`, a reference-only
entry (no new issue fields — `docs/issues/ISS-0389.yaml` already exists, already
lists `REQ-208` in `related`):

```
title: "meridian-regulatory-compliance-review-bafin step 3 blocked by ISS-0389 (advance-timer missing) -- same gap as REQ-206, now confirmed blocking a second, independent tenant scenario"
description: >
  Reference only, not a new finding: ISS-0389
  (docs/issues/ISS-0389.yaml, GH#768) already names this exact
  missing-endpoint gap and already lists REQ-208 in its own related
  field. This run's own contribution is confirming the same gap now
  blocks TWO independent scenarios in two different simulated tenants
  (SwiftRoute's shipment-ops-timeout-escalation, REQ-206; Meridian's
  regulatory-compliance-review-bafin, REQ-208 here) -- itself evidence
  this is a real, cross-cutting platform gap rather than one scenario's
  edge case, per this requirement's own report (see AC3/AC4 discussion,
  lib/letflow/design/req208-meridian-scenario-execution.md §4.3).
  Disposition applied: step 3 recorded :blocked (blocked_by: "ISS-0389"),
  distinct from :skip, since this scenario's own YAML documents no
  SKIP/MINOR fallback the way REQ-206's shipment-timeout scenario did.
severity: MINOR
affected_files:
  - lib/letflow/router.ex
  - lib/letflow/routers/instances.ex
  - test/fixtures/simulation/meridian/scenarios/regulatory-compliance-review-bafin.yaml
```

ORCH does not open a new tracked issue for this entry (ISS-0389 already exists and
already names REQ-208) — it is carried in the handoff purely so the two-tenants
cross-cutting-gap observation (AC3's own report requirement) is attached to this
run's own record, not silently left only in this design doc.

---

## §5 — Test module structure

`test/letflow/simulation/req208_meridian_test.exs` — one ExUnit module, `describe`
block per scenario, mirroring `req206_swiftroute_test.exs`/`req207_vortex_test.exs`'s
shape exactly (`use Letflow.DataCase, async: false`; `Sandbox.mode(Letflow.Repo,
:auto)`; a `setup` block seeding the Meridian company/org/2 simplified process
definitions once per test, unique-slug-scoped via
`Letflow.TenantSlugFixture.unique_slug("req208")`; actor tokens created with the
literal `role-*` strings §4's tables specify; a teardown dropping the tenant's
schema and identity/onboarding/registration rows, same shape as REQ-206/207's own).

```
describe "meridian-loan-origination-above-threshold" do
  test "..." — §4.1's 6 steps + 6 expected_outcomes, including the 3-parallel-tracks
    existence check and the quorum-consistency check
end

describe "meridian-loan-origination-below-threshold" do
  test "..." — §4.2's 6 steps + 4 expected_outcomes, including EO-002's
    :no_task_of_type negative assertion
end

describe "meridian-regulatory-compliance-review-bafin" do
  test "..." — §4.3's 3 steps: 1/2 real + verified, step 3 :blocked/ISS-0389,
    asserting step_result.outcome == :blocked and step_result.blocked_by ==
    "ISS-0389" directly (a regression detector: if a later merge ships
    advance-timer, this assertion should be the first thing to force someone to
    revisit this scenario's disposition, same "disposition doubles as a
    regression detector" precedent REQ-207 §5 already established for its own
    BLOCKED_ON_DEPENDENCY entity-scenario test)
end
```

---

## §6 — Report format (AC5)

A single YAML report, `test/reports/req208-meridian-scenario-findings.yaml`
(matching this project's YAML-for-everything-except-handoffs convention), stating a
closed disposition for all 3 scenarios and every one of their steps — no step or
scenario left unaddressed (AC5's literal requirement):

```yaml
requirement: REQ-208
req_199_status_at_execution: done   # AC4's own explicit statement, verified §0.5 -- if a
                                     # future re-run finds REQ-199 no longer done, this
                                     # field and the caveat below must both change
req_199_caveat: >
  REQ-199 (status: done) protects out-of-band effect completions re-entering the
  engine in order (ORD-01..04). Runner.run_steps/1 dispatches every :api step
  sequentially -- this run does not generate genuinely concurrent completions and
  therefore does not itself independently re-exercise ORD-01/02/03 under real
  concurrent load; it exercises only that the parallel-fork/join graph SHAPE
  transitions correctly under one-at-a-time completions. See design §0.5.
scenarios:
  - id: meridian-loan-origination-above-threshold
    disposition: EXECUTED
    steps_total: 6
    steps_executed: 6
    expected_outcomes_total: 6
    expected_outcomes_pass: <filled at run time>
    expected_outcomes_fail: <filled at run time>
    quorum_consistency:
      vote_credit_de: <filled at run time>
      vote_risk: <filled at run time>
      vote_compliance: <filled at run time>
      committee_outcome: <filled at run time>
      internally_consistent: <true|false, filled at run time>
  - id: meridian-loan-origination-below-threshold
    disposition: EXECUTED
    steps_total: 6
    steps_executed: 6
    expected_outcomes_total: 4
    expected_outcomes_pass: <filled at run time>
    expected_outcomes_fail: <filled at run time>
    eo_002_negative_assertion:
      committee_vote_task_found: <must be false, filled at run time>
  - id: meridian-regulatory-compliance-review-bafin
    disposition: EXECUTED   # scenario-level disposition unchanged; only step 3's
                             # step_result.outcome is :blocked -- same convention
                             # REQ-206's own :skip-embedded scenario used
    steps_total: 3
    steps_executed: 2
    steps_blocked: 1
    blocked_step:
      index: 3
      blocked_by: "ISS-0389"
    cross_tenant_finding: >
      Same missing advance-timer capability now confirmed blocking scenarios in
      two independent tenants (SwiftRoute/REQ-206, Meridian/REQ-208) -- see
      design §4.3.
```

This report is written by ELIXIR-DEV/TEST-RUNNER at implementation/test-run time;
the design specifies its shape, populating `<filled at run time>` placeholders is
an implementation-phase obligation, same split as every other design-doc-vs-
implementation boundary in this project.

---

## §7 — Follow-up issue recommendation (AC4's own caveat, made actionable)

Per §0.5's finding — Runner's sequential step dispatch means REQ-208's own scenarios
do not independently re-exercise REQ-199's ORD-01/02/03 guards under genuine
concurrent load, despite this being "the one scenario batch that most directly
needs" that subsystem (the requirement's own framing) — this design recommends ORCH
file a new follow-up issue at Step Final (checked this session: no existing issue
among ISS-0388/0389/0390/0391/0392/0393 covers this; it is a distinct finding from
all of them, not a duplicate):

```
title: "S7's simulation harness (Letflow.Simulation.Runner) never dispatches steps
concurrently -- REQ-199's ORD-01/02/03 guards remain unit-tested (S6) but never
exercised end-to-end under real concurrent HTTP load by any S7 scenario"
description: >
  REQ-208's committee-quorum/parallel-fork-join scenario is the one S7 batch
  whose own requirement text most directly invokes REQ-199's correlated-effect-
  ordering subsystem, but Runner.run_steps/1 (test/support/simulation/runner.ex)
  dispatches every via: api step in a strict Enum.reduce, one HTTP call at a
  time -- there is no mechanism today for two steps to race against the same
  correlation/instance. This means no S7 scenario, including REQ-208's, provides
  end-to-end evidence that ORD-01 (claim guard)/ORD-02 (execute guard)/ORD-03
  (order guard) hold under genuine concurrent completions -- only that S6's own
  unit tests do. A future requirement could extend Runner with an opt-in
  concurrent step-group (e.g. steps sharing a declared "parallel_group" key
  dispatched via Task.async_stream/3, results still collected and reported in
  declared order) specifically to close this gap for the scenarios that need it
  (REQ-208's committee/parallel-track scenario chief among them).
severity: MINOR
tags: [simulation-harness, concurrency, s7]
affected_files:
  - test/support/simulation/runner.ex
  - test/letflow/simulation/req208_meridian_test.exs
related:
  - REQ-199
  - REQ-208
```

---

## §8 — Acceptance-criteria-to-design-element map

| AC | Design element |
|---|---|
| AC1 (above-threshold: end-to-end, 3 parallel tracks confirmed created, committee route confirmed taken, quorum 2-of-3 confirmed from committee_outcome, disbursement on end-disbursed) | §3.1 (`@simple_loan_origination_graph`), §4.1 (step table + 6 expected outcomes, §0.6's quorum-modeling resolution) |
| AC2 (below-threshold: end-to-end, EO-002's negative assertion verified by querying real task state and confirming absence) | §2.2 (`:no_task_of_type` new verification method — confirmed `task_assigned` cannot express this), §4.2 (step table + 4 expected outcomes) |
| AC3 (BaFin: steps 1/2 real against real queried state; step 3 BLOCKED citing ISS-0389, not duplicated; report states the same gap now blocks two tenants) | §2.1 (`:blocked` new step disposition — distinct from `:skip`, rationale stated), §3.2 (`@simple_regulatory_review_graph`), §4.3 (step table, real state verification for steps 1/2, ISS-0389 reference text) |
| AC4 (report states explicitly whether REQ-199 was done at execution time, and states any in-flight/blocked caveat) | §0.5 (REQ-199 confirmed `status: done`, verified from source — plus the material sequential-dispatch caveat stated regardless of that status), §6 (report format's `req_199_status_at_execution`/`req_199_caveat` fields), §7 (follow-up issue making the caveat actionable rather than just noted) |
| AC5 (report states a closed disposition for every one of the 3 scenarios — no step or scenario left unaddressed) | §2.3 (closed enum, no other step-level value possible), §4.1-4.3 each accounting for every step of its scenario explicitly (6+6+3 = 15 steps total, every one assigned a disposition), §6 (report format, all 3 scenarios present) |
| AC6 (`mix test`/`mix compile --warnings-as-errors` pass, real output quoted) | Implementation-phase obligation (ELIXIR-DEV/TEST-RUNNER) — no design-time element; noted so it is not missed at handoff |

No acceptance criterion is left with a "TBD" design element.

---

## §9 — Open questions (explicit, not silently resolved)

- **OQ-1**: whether `Letflow.Instances.get_by_id/2`'s projection exposes the
  currently-`ACTIVE` instance's *current node* directly (useful for §4.3 step 1's
  "instance is genuinely paused at evidence-collection" style checks) or whether
  this must be inferred from the task list alone (which node has a `PENDING` task).
  This design uses the task-list-based inference throughout (§4.1-4.3's
  `task_assigned`-style checks) specifically because it does not assume a
  current-node projection field exists without having read
  `lib/letflow/instances.ex`'s actual struct this session — ELIXIR-DEV confirms
  at implementation time whether a more direct field is available and may use it
  in preference to the task-list inference if so, without needing a design rework
  (the inference-based checks stay correct either way, just possibly less direct
  than necessary).
- **OQ-2**: the exact `Ecto.Enum` string R-Co's real fixture would use for
  `risk_rating`'s `!= 'unacceptable'` condition's *positive* values (this design
  uses `"acceptable"` at §4.1/§4.2's step 3b, a plausible value satisfying the
  condition, but not verified against any real R-Co corpus per §0.3's
  unreachability finding) — any string other than `"unacceptable"` satisfies the
  condition as written, so this does not block implementation, but ELIXIR-DEV
  should not treat `"acceptable"` as itself a load-bearing literal beyond
  satisfying `!= 'unacceptable'`.
- **OQ-3**: whether `Letflow.Tasks.list_tasks/2`'s `page_size: 100` default used
  throughout §2.2/§4 is sufficient headroom for every instance in this
  requirement's scenarios (none of the 3 scenarios here ever produces more than 4
  tasks per instance, so 100 is generously sufficient — flagged only so a future
  scenario with a genuinely large task count does not silently truncate a
  `:no_task_of_type` check's `items` list without anyone having decided that was
  acceptable).

Every open question above is a genuinely deferred implementation-time fact-check
(reading a real struct, confirming a page-size margin), not a silently-skipped
design decision — every acceptance criterion has a concrete design element per §8.
