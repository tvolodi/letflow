defmodule Letflow.Simulation.Req208MeridianTest do
  @moduledoc """
  REQ-208 acceptance criteria: 3 Meridian scenario YAMLs run through
  `Letflow.Simulation.Runner`.

  ## FIXED by ISS-0397 (2026-09-01) -- formerly a CRITICAL FINDING blocking full
  AC1/AC2 verification; superseding note added rather than deleting the
  original finding, per this project's discipline of not silently erasing a
  documented defect's own history

  `Letflow.Engine.complete_task/3`'s real, per-call state-rebuild
  (`lib/letflow/engine.ex`'s `build_instance_state/3`) used to hardcode
  `join_counters: %{}` on EVERY call, confirmed reproduced against a real
  running instance in the session that wrote this test (`Letflow.Engine.create/2`
  for the initial split, then a SEPARATE `Letflow.Engine.complete_task/3` call
  for the first branch's own completion -- real HTTP 500,
  `{:error, {:activation_failed, {:unknown_branch_id, _}}}` internally). A
  `PARALLEL_GATEWAY` join could therefore only ever fire within the SAME
  hop-chain call as its own split. **ISS-0397**
  (`lib/letflow/design/iss0397-join-counters-fix.md`) fixed this by adding a
  durable `instance_projections.join_counters` column, read/written under the
  same `FOR UPDATE` lock `complete_task/3`/`advance_after_timer_fired/3` already
  hold on that row -- a join cohort opened by one call is now durably readable
  (and closeable) by a later, separate call. The two tests below were updated
  accordingly (see each `describe` block's own comments) to assert the now-real,
  now-successful second-call behavior instead of the pre-fix HTTP 500 -- they no
  longer reproduce a defect, they lock in its fix.

  **Still NOT fully verified by this file's ORIGINAL two describe blocks below
  (unchanged since REQ-208, kept for their own historical/ISS-0397-fix-locking
  value, not rewritten):** AC1/AC2's own fuller claims (full quorum across all
  3 branches through to disbursement, EO-002's negative assertion) remain out
  of reach of a real end-to-end run there -- `disburse-loan`/
  `credit-committee-vote`/`l1-approval` sit behind `SERVICE_TASK` nodes this
  engine did not yet dispatch at the time those two describe blocks were
  written (§0.8/§3 below, a platform-wide gap REQ-206/207 already found,
  unrelated to ISS-0397).

  ## CLOSED by REQ-215 (2026-09-03) -- the SERVICE_TASK dispatch gap itself

  `Letflow.Engine.Transition.dispatch_node/4` now has a real `:SERVICE_TASK`
  clause (`lib/letflow/design/req215-service-task-engine-wiring.md`); REQ-214
  built the dispatch-core poller this requirement's re-entry function
  (`Letflow.Engine.advance_after_service_task_outcome/4`) hands a resolved
  outcome to. **REQ-215's own AC2 is exactly this file's own long-standing
  gap:** "`req208_meridian_test.exs`'s committee-vote/quorum-2-of-3/
  disbursement paths (previously unreached) are reached and pass end to
  end." The new `"meridian-loan-origination-above-threshold, full committee-
  vote quorum through disbursement (REQ-215 AC2)"` describe block below
  closes it -- a THIRD describe block, added rather than rewriting the first
  two (which independently lock in ISS-0397's own fix and stay valid,
  unchanged, on their own narrower claim). It exercises the real
  `credit-committee-vote` (HUMAN_TASK) -> `create-facility` (a REAL
  `SERVICE_TASK` node now, not elided) -> `disburse-loan` (HUMAN_TASK) path,
  driven via direct `Letflow.Engine`/`Letflow.Tasks` API calls (not
  `Runner.run/1` against the existing scenario YAMLs, which have no step
  primitive for "resolve a pending SERVICE_TASK dispatch" and were never
  updated past the point they originally truncated at -- extending the YAML
  format itself is out of REQ-215's own scope). `attempt_dispatch/2` +
  `advance_after_service_task_outcome/4` are called directly rather than via
  `ServiceTaskDispatcher.poll_and_dispatch/1`, since `poll_and_dispatch/1`
  currently crashes on a genuine `:advance` outcome -- see
  `test/letflow/engine/service_task_wiring_test.exs`'s own "DEFECT" describe
  block for the full report; not re-derived here, just avoided the same way
  that file's own working tests avoid it.

  ## SERVICE_TASK limitation (design §0.8/§3, same platform-wide gap REQ-206/207
  already found) -- applies ONLY to the original two describe blocks below,
  NOT to the new third one (which restores a real SERVICE_TASK node, above)
  `Letflow.Engine` did not yet dispatch SERVICE_TASK nodes as of REQ-208. The
  real `process_claim_intake.yaml`/`process_policy_binding.yaml` fixtures have
  SERVICE_TASKs on their critical paths. Test-local simplified process graphs
  (`@simple_loan_origination_graph`, `@simple_regulatory_review_graph`) replace
  them with direct edges/END nodes, mirroring REQ-206/207's own precedent
  exactly -- unchanged, since rewriting those two would lose their own
  historical ISS-0397-fix-locking value.

  ## Token roles are a separate namespace from process `attributes.role` strings
  (design §0.7, re-confirmed this session)
  `HUMAN_TASK` node `attributes.role` values (e.g. `"role-credit-manager"`,
  `"role-committee-member"`) are engine-internal `assignee_ref` strings, never
  a token permission -- `Identity.create_token/3` (`lib/letflow/identity.ex`)
  accepts ONLY `Authorization.roles/0`'s 5 literal values
  (PLATFORM_ADMIN/PROCESS_DESIGNER/PROCESS_OPERATOR/TASK_WORKER/AGENT_RUNNER),
  confirmed empirically this session (`{:error, :invalid_role_set}` on a
  `role-*` string). Every actor below is granted `PROCESS_OPERATOR`
  (matching REQ-206/207's own precedent) -- per §0.7, claim is not required
  before complete and `:TasksComplete` unconditionally allows any
  `PROCESS_OPERATOR`-permissioned actor to complete any task regardless of its
  `assignee_ref`.

  ## REQ-199 status at execution time (AC4)
  `docs/requirements.yaml` REQ-199 entry: `status: done`, stage S6 (re-confirmed
  this session, design §0.5). Material caveat stated regardless: `Runner.run_steps/1`
  dispatches every `:api` step sequentially -- this run does not itself generate
  genuinely concurrent out-of-band completions and therefore does not
  independently re-exercise REQ-199's ORD-01/02/03 guards under real concurrent
  load. It exercises only that the parallel-fork/join graph SHAPE transitions
  correctly under one-at-a-time completions (a real, valuable engine-instance-shape
  test, not the same claim as "no lost update under concurrent completions"). See
  design §0.5/§7 -- a follow-up issue recommendation is reported via
  `result.issues` at handoff time (checked against ISS-0388..0393 first, per
  the requirement's own instruction; not a duplicate).

  Real Postgres, `async: false` -- tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Instances
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.ScenarioFixture
  alias Letflow.Simulation.Seed
  alias Letflow.Tasks
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/meridian", __DIR__)
  @scenarios_dir Path.join(@fixtures_dir, "scenarios")

  # ── §3.1: @simple_loan_origination_graph ──────────────────────────────────
  # Derived from process_claim_intake.yaml (design §0.2), SERVICE_TASK nodes
  # elided/replaced: credit-memo-timeout/risk-assessment-timeout/kyc-timeout/
  # committee-timeout (on_timeout fallbacks) elided entirely; create-facility
  # replaced by a direct edge from l2-approval's approve branch /
  # credit-committee-vote's approved branch straight to disburse-loan;
  # decline-application replaced by a direct edge to end-declined. Every
  # HUMAN_TASK/EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY node and every condition
  # string on the real, exercised path kept verbatim -- EXCEPT the KYC/AML
  # branch, per the ELIXIR-DEV finding below.
  #
  # ELIXIR-DEV finding, over the design's own §3.1 plan (design proposed
  # replacing kyc-aml-check with a direct edge from parallel-assessment-fork
  # to kyc-routing, an EXCLUSIVE_GATEWAY, keeping kyc-routing/kyc-manual-review
  # real): empirically, this does not activate. `Letflow.Engine.create/2`
  # returns `{:error, {:activation_failed, {:no_matching_join_found,
  # "parallel-assessment-fork"}}}` -- confirmed this session by direct
  # reproduction against a real running instance. Reading
  # `lib/letflow/engine/transition.ex`'s `find_matching_join/2` and
  # `walk_to_gateway/3` (REQ-051's own fork/join implementation) shows every
  # fork branch must be a chain of SINGLE-outgoing-edge nodes until it reaches
  # the PARALLEL_GATEWAY join -- a node with more than one outgoing edge
  # (kyc-routing, an EXCLUSIVE_GATEWAY with 3 outgoing edges) makes
  # `walk_to_gateway/3` return `:error` before ever reaching assessment-join,
  # which fails the WHOLE split (not just that branch) at instance-creation
  # time. This is a genuine, previously-undocumented Engine limitation --
  # distinct from the SERVICE_TASK-not-dispatched gap REQ-206/207/208's design
  # docs already record -- reported via `result.issues` at handoff time (new
  # finding, checked against ISS-0388..0393 first; not a duplicate).
  #
  # Resolution here: the KYC/AML branch is a single, unconditioned, immediate
  # edge from parallel-assessment-fork straight to assessment-join (no
  # kyc-routing/kyc-manual-review nodes in this simplified graph at all) --
  # both scenarios' own `kyc_status: "clear"` value would have taken
  # kyc-routing's own `== 'clear'` edge straight to assessment-join anyway
  # (design §3.1's own edge table), so no scenario-observable behavior is
  # lost; only the (never-exercised-by-either-scenario, per design §3.1's own
  # table) kyc-manual-review branch is now structurally absent rather than
  # present-but-unreached. `kyc_status` is dropped from both scenarios'
  # `initial_variables` accordingly (it would be inert dead data otherwise).
  @simple_loan_origination_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{"id" => "parallel-assessment-fork", "node_type" => "PARALLEL_GATEWAY"},
      %{
        "id" => "credit-memo-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "risk-assessment",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-risk-manager"}
      },
      %{"id" => "assessment-join", "node_type" => "PARALLEL_GATEWAY"},
      %{"id" => "eligibility-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{"id" => "authority-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "l1-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "l2-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-director"}
      },
      %{
        "id" => "credit-committee-vote",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-committee-member"}
      },
      %{
        "id" => "disburse-loan",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-loan-ops"}
      },
      %{"id" => "end-disbursed", "node_type" => "END"},
      %{"id" => "end-declined", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "parallel-assessment-fork"},
      %{"id" => "e1", "source" => "parallel-assessment-fork", "target" => "credit-memo-review"},
      %{"id" => "e2", "source" => "parallel-assessment-fork", "target" => "risk-assessment"},
      # e3: the KYC/AML track's own branch, direct to assessment-join (see the
      # ELIXIR-DEV finding above -- no gateway node survives mid-branch here).
      %{"id" => "e3", "source" => "parallel-assessment-fork", "target" => "assessment-join"},
      %{"id" => "e4", "source" => "credit-memo-review", "target" => "assessment-join"},
      %{"id" => "e6", "source" => "risk-assessment", "target" => "assessment-join"},
      %{"id" => "e14", "source" => "assessment-join", "target" => "eligibility-gate"},
      %{
        "id" => "e15",
        "source" => "eligibility-gate",
        "target" => "authority-routing",
        "condition" =>
          "variables.credit_decision == 'pass' && variables.risk_rating != 'unacceptable'"
      },
      %{
        "id" => "e16",
        "source" => "eligibility-gate",
        "target" => "end-declined",
        "condition" =>
          "variables.credit_decision == 'fail' || variables.risk_rating == 'unacceptable'"
      },
      %{
        "id" => "e17",
        "source" => "authority-routing",
        "target" => "l1-approval",
        "condition" => "variables.requested_amount_eur <= 500000"
      },
      %{
        "id" => "e18",
        "source" => "authority-routing",
        "target" => "credit-committee-vote",
        "condition" => "variables.requested_amount_eur > 500000"
      },
      %{
        "id" => "e19",
        "source" => "l1-approval",
        "target" => "l2-approval",
        "condition" => "variables.l1_decision == 'approve' || variables.l1_decision == 'escalate'"
      },
      %{
        "id" => "e20",
        "source" => "l1-approval",
        "target" => "end-declined",
        "condition" => "variables.l1_decision == 'reject'"
      },
      %{
        "id" => "e21",
        "source" => "l2-approval",
        "target" => "disburse-loan",
        "condition" => "variables.l2_decision == 'approve'"
      },
      %{
        "id" => "e22",
        "source" => "l2-approval",
        "target" => "end-declined",
        "condition" => "variables.l2_decision == 'reject'"
      },
      %{
        "id" => "e23",
        "source" => "credit-committee-vote",
        "target" => "disburse-loan",
        "condition" => "variables.committee_outcome == 'approved'"
      },
      %{
        "id" => "e24",
        "source" => "credit-committee-vote",
        "target" => "end-declined",
        "condition" => "variables.committee_outcome == 'rejected'"
      },
      # Fallback edges (REQ-208's own graph-validation-driven addition, over the
      # design's literal §3.1 edge set): Letflow.Definitions.Graph's validator
      # requires every HUMAN_TASK with at least one really-conditioned outgoing
      # edge to also have an unconditioned fallback edge. The real fixture's own
      # fallback-l1-approval/fallback-l2-approval/timeout-credit-committee-vote
      # edges served this role (targeting l2-approval/create-facility/
      # committee-timeout respectively) -- kept here, verbatim in shape, with
      # targets adjusted for this graph's own create-facility/committee-timeout
      # elisions (design §3.1): l1-approval's fallback still targets l2-approval
      # (unchanged from the real fixture); l2-approval's and
      # credit-committee-vote's fallbacks now target disburse-loan directly,
      # since create-facility/committee-timeout no longer exist as intermediate
      # nodes in this simplified graph. Never exercised by either scenario (both
      # always set a condition-satisfying decision variable).
      %{"id" => "fallback-l1-approval", "source" => "l1-approval", "target" => "l2-approval"},
      %{"id" => "fallback-l2-approval", "source" => "l2-approval", "target" => "disburse-loan"},
      %{
        "id" => "fallback-credit-committee-vote",
        "source" => "credit-committee-vote",
        "target" => "disburse-loan"
      },
      %{"id" => "e27", "source" => "disburse-loan", "target" => "end-disbursed"}
    ]
  }

  # ── REQ-215 AC2: @loan_origination_graph_with_service_task ────────────────
  # A second variant of the above graph, for the new describe block this
  # requirement adds below: `create-facility` is restored as a REAL
  # SERVICE_TASK node (process_claim_intake.yaml's own real node,
  # process_claim_intake.yaml:74-78, `endpoint: POST /core-banking/facilities`)
  # instead of being elided the way @simple_loan_origination_graph elides
  # every SERVICE_TASK. Every other node/edge (the parallel-assessment-fork,
  # KYC/AML track's own edge, eligibility-gate, authority-routing, l1/l2
  # approval chain, credit-committee-vote) is kept identical to
  # @simple_loan_origination_graph above -- this graph exists ONLY to prove
  # REQ-215's own AC2 (committee-vote/quorum-2-of-3/disbursement paths
  # reached and passing end to end), not to re-prove anything the original
  # two describe blocks below already lock in.
  @loan_origination_graph_with_service_task %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{"id" => "parallel-assessment-fork", "node_type" => "PARALLEL_GATEWAY"},
      %{
        "id" => "credit-memo-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "risk-assessment",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-risk-manager"}
      },
      %{"id" => "assessment-join", "node_type" => "PARALLEL_GATEWAY"},
      %{"id" => "eligibility-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{"id" => "authority-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "l1-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "l2-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-director"}
      },
      %{
        "id" => "credit-committee-vote",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-committee-member"}
      },
      # REAL SERVICE_TASK node, unlike @simple_loan_origination_graph's own
      # direct-edge elision -- endpoint is a test-time placeholder, patched to
      # a real local WebhookTestServer URL at test setup time (this graph
      # constant itself cannot know the server's OS-assigned port).
      %{
        "id" => "create-facility",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{
          "endpoint" => "SERVICE_TASK_ENDPOINT_PLACEHOLDER",
          "timeout_ms" => 5_000
        }
      },
      %{
        "id" => "disburse-loan",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-loan-ops"}
      },
      %{"id" => "end-disbursed", "node_type" => "END"},
      %{"id" => "end-declined", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "parallel-assessment-fork"},
      %{"id" => "e1", "source" => "parallel-assessment-fork", "target" => "credit-memo-review"},
      %{"id" => "e2", "source" => "parallel-assessment-fork", "target" => "risk-assessment"},
      %{"id" => "e3", "source" => "parallel-assessment-fork", "target" => "assessment-join"},
      %{"id" => "e4", "source" => "credit-memo-review", "target" => "assessment-join"},
      %{"id" => "e6", "source" => "risk-assessment", "target" => "assessment-join"},
      %{"id" => "e14", "source" => "assessment-join", "target" => "eligibility-gate"},
      %{
        "id" => "e15",
        "source" => "eligibility-gate",
        "target" => "authority-routing",
        "condition" =>
          "variables.credit_decision == 'pass' && variables.risk_rating != 'unacceptable'"
      },
      %{
        "id" => "e16",
        "source" => "eligibility-gate",
        "target" => "end-declined",
        "condition" =>
          "variables.credit_decision == 'fail' || variables.risk_rating == 'unacceptable'"
      },
      %{
        "id" => "e17",
        "source" => "authority-routing",
        "target" => "l1-approval",
        "condition" => "variables.requested_amount_eur <= 500000"
      },
      %{
        "id" => "e18",
        "source" => "authority-routing",
        "target" => "credit-committee-vote",
        "condition" => "variables.requested_amount_eur > 500000"
      },
      %{
        "id" => "e19",
        "source" => "l1-approval",
        "target" => "l2-approval",
        "condition" => "variables.l1_decision == 'approve' || variables.l1_decision == 'escalate'"
      },
      %{
        "id" => "e20",
        "source" => "l1-approval",
        "target" => "end-declined",
        "condition" => "variables.l1_decision == 'reject'"
      },
      %{
        "id" => "e21",
        "source" => "l2-approval",
        "target" => "create-facility",
        "condition" => "variables.l2_decision == 'approve'"
      },
      %{
        "id" => "e22",
        "source" => "l2-approval",
        "target" => "end-declined",
        "condition" => "variables.l2_decision == 'reject'"
      },
      %{
        "id" => "e23",
        "source" => "credit-committee-vote",
        "target" => "create-facility",
        "condition" => "variables.committee_outcome == 'approved'"
      },
      %{
        "id" => "e24",
        "source" => "credit-committee-vote",
        "target" => "end-declined",
        "condition" => "variables.committee_outcome == 'rejected'"
      },
      %{"id" => "fallback-l1-approval", "source" => "l1-approval", "target" => "l2-approval"},
      %{"id" => "fallback-l2-approval", "source" => "l2-approval", "target" => "create-facility"},
      %{
        "id" => "fallback-credit-committee-vote",
        "source" => "credit-committee-vote",
        "target" => "create-facility"
      },
      %{"id" => "e26", "source" => "create-facility", "target" => "disburse-loan"},
      %{"id" => "e27", "source" => "disburse-loan", "target" => "end-disbursed"}
    ]
  }

  # ── §3.2: @simple_regulatory_review_graph ─────────────────────────────────
  # Derived from process_policy_binding.yaml (design §0.2). No SERVICE_TASK on this
  # scenario's own actually-exercised path (start -> evidence-collection ->
  # risk-evaluation, then blocked) needs elision -- the on_timeout-fallback
  # SERVICE_TASKs are elided anyway for structural cleanliness (never exercised),
  # every other node kept for structural completeness only.
  @simple_regulatory_review_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "evidence-collection",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-compliance-officer"}
      },
      %{
        "id" => "risk-evaluation",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-risk-manager"}
      },
      %{"id" => "severity-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "findings-sign-off",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-cro"}
      },
      %{"id" => "end-closed", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "evidence-collection"},
      %{"id" => "e1", "source" => "evidence-collection", "target" => "risk-evaluation"},
      %{"id" => "e3", "source" => "risk-evaluation", "target" => "severity-routing"},
      %{
        "id" => "e7",
        "source" => "severity-routing",
        "target" => "findings-sign-off",
        "condition" =>
          "variables.highest_severity == 'none' || variables.highest_severity == 'low' || variables.highest_severity == 'medium' || variables.highest_severity == 'high'"
      },
      # findings-sign-off's own outgoing edge is left unconditioned here (the real
      # fixture's e11/e12 pair -- sign_off/reject_and_reopen -- collapsed to one
      # edge): findings-sign-off is present only for structural completeness
      # (design §3.2, never exercised by this scenario's 3 steps), and
      # Letflow.Definitions.Graph's validator requires every HUMAN_TASK with a
      # really-conditioned outgoing edge to also carry an unconditioned fallback;
      # since this node is never reached, a single unconditioned edge is
      # simpler and equally inert.
      %{"id" => "e11", "source" => "findings-sign-off", "target" => "end-closed"}
    ]
  }

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req208")

    company = %{
      "slug" => unique,
      "display_name" => "Meridian Capital AG",
      "hostname" => unique <> ".simulation.test"
    }

    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    {:ok, org_structure} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "org_structure.yaml"))

    org_structure =
      update_in(org_structure["people"], fn people ->
        Enum.map(people, fn person ->
          Map.update!(person, "username", &(&1 <> "-" <> unique))
        end)
      end)

    {:ok, users} = Seed.seed_users(org_structure, tenant)

    users_by_actor_id =
      org_structure["people"]
      |> Enum.zip(users)
      |> Map.new(fn {person, user} -> {Map.fetch!(person, "actor_id"), user} end)

    lars = Map.fetch!(users_by_actor_id, "actor-meridian-lars")
    julia = Map.fetch!(users_by_actor_id, "actor-meridian-julia")
    thomas = Map.fetch!(users_by_actor_id, "actor-meridian-thomas")
    ben = Map.fetch!(users_by_actor_id, "actor-meridian-ben")
    eva = Map.fetch!(users_by_actor_id, "actor-meridian-eva")
    marcus = Map.fetch!(users_by_actor_id, "actor-meridian-marcus")
    claudia = Map.fetch!(users_by_actor_id, "actor-meridian-claudia")

    # Seed simplified loan-origination process (no SERVICE_TASKs; shared by both
    # above-threshold and below-threshold scenarios, per the requirement text).
    simple_loan_name = "SimpleLoanOrigination-" <> unique

    {:ok, definition_loan} =
      case Letflow.Definitions.get_active_by_name(simple_loan_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_loan_name,
                     version: "1.0",
                     description:
                       "REQ-208 test-local process: exercises parallel-fork/join and authority-routing EXCLUSIVE_GATEWAY branches (l1/l2 chain vs. committee vote) without SERVICE_TASKs.",
                     graph: @simple_loan_origination_graph,
                     created_by: lars.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Seed simplified regulatory-review process (no SERVICE_TASKs on the exercised
    # path; for the BaFin scenario).
    simple_review_name = "SimpleRegulatoryComplianceReview-" <> unique

    {:ok, definition_review} =
      case Letflow.Definitions.get_active_by_name(simple_review_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_review_name,
                     version: "1.0",
                     description:
                       "REQ-208 test-local process: exercises evidence-collection -> risk-evaluation, the node whose on_timeout boundary the (missing, ISS-0389) advance-timer endpoint would advance.",
                     graph: @simple_regulatory_review_graph,
                     created_by: claudia.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Deviation from the design's literal §4.1 token-role wording (recorded, not
    # silent): `Identity.create_token/3` (lib/letflow/identity.ex, re-confirmed
    # this session) accepts ONLY `Letflow.Api.Authorization.roles/0`'s five
    # literal role-name strings (PLATFORM_ADMIN/PROCESS_DESIGNER/
    # PROCESS_OPERATOR/TASK_WORKER/AGENT_RUNNER) as `attrs.roles` -- an
    # unrecognized entry (e.g. the process-attribute strings "role-credit-manager"
    # etc., which the design's own §4.1 text used) is rejected loudly,
    # `{:error, :invalid_role_set}`, confirmed empirically this session. Those
    # `role-*` strings are `HUMAN_TASK` node `attributes.role` values -- a
    # completely separate namespace the engine uses only for `assignee_ref`
    # resolution (design §0.7), never a token permission. Per §0.7, claim is not
    # required before complete and `:TasksComplete` always yields unconditional
    # `:Allow` -- every actor below is granted `PROCESS_OPERATOR` (matching
    # REQ-206/207's own precedent, `req206_swiftroute_test.exs`/
    # `req207_vortex_test.exs`), sufficient to complete any task regardless of
    # its `assignee_ref` string. `task_assigned` checks against a role-attributed
    # task still assert `outcome in [:pass, :fail]` with the real
    # `observed.assignee_ref` string as evidence, same limitation REQ-206/207
    # already recorded (design §0.7).
    {:ok, %{plaintext: lars_token}} =
      Identity.create_token(lars.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: julia_token}} =
      Identity.create_token(julia.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: thomas_token}} =
      Identity.create_token(thomas.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: ben_token}} =
      Identity.create_token(ben.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: eva_token}} =
      Identity.create_token(eva.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: marcus_token}} =
      Identity.create_token(marcus.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: claudia_token}} =
      Identity.create_token(claudia.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    actors = %{
      "actor-meridian-lars" => %{"token" => lars_token, "tenant_slug" => unique},
      "actor-meridian-julia" => %{"token" => julia_token, "tenant_slug" => unique},
      "actor-meridian-thomas" => %{"token" => thomas_token, "tenant_slug" => unique},
      "actor-meridian-ben" => %{"token" => ben_token, "tenant_slug" => unique},
      "actor-meridian-eva" => %{"token" => eva_token, "tenant_slug" => unique},
      "actor-meridian-marcus" => %{"token" => marcus_token, "tenant_slug" => unique},
      "actor-meridian-claudia" => %{"token" => claudia_token, "tenant_slug" => unique}
    }

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      unique: unique,
      actors: actors,
      definitions: %{loan: definition_loan, review: definition_review},
      # REQ-215 AC2's own new describe block drives its steps via direct
      # Letflow.Engine/Letflow.Tasks calls (not Runner.run/1 -- see this
      # module's own moduledoc, "CLOSED by REQ-215" section, for why) and
      # needs real actor_id UUIDs, not just API tokens.
      actor_ids: %{
        lars: lars.id,
        julia: julia.id,
        thomas: thomas.id,
        ben: ben.id,
        eva: eva.id,
        marcus: marcus.id,
        claudia: claudia.id
      }
    }
  end

  defp teardown(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, _reason} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))

      {:error, :not_found} ->
        :ok
    end
  end

  # Replaces "TENANT_PREFIX" in precondition/outcome args, "DEFINITION_NAME" in
  # process_id/step params, with real test-time values. Mirrors
  # req207_vortex_test.exs's patch_scenario/2 exactly (no :audit_event_ordering
  # method here, so no "first"/"second" nested-prefix branch is needed).
  defp patch_scenario(scenario, schema_name: schema_name, definition_name: defn, actors: actors) do
    %{
      scenario
      | process_id: defn,
        actors: actors,
        preconditions: patch_preconditions(scenario.preconditions, schema_name, defn),
        steps: patch_step_params(scenario.steps, defn),
        expected_outcomes: patch_outcome_prefix(scenario.expected_outcomes, schema_name)
    }
  end

  defp patch_preconditions(preconditions, schema_name, defn) do
    Enum.map(preconditions, fn p ->
      args = Map.get(p, :args, %{})

      args =
        args
        |> Map.put("prefix", schema_name)
        |> then(fn a ->
          if Map.get(a, "name") == "DEFINITION_NAME", do: Map.put(a, "name", defn), else: a
        end)

      Map.put(p, :args, args)
    end)
  end

  defp patch_step_params(steps, defn) do
    Enum.map(steps, fn step ->
      case Map.get(step, :params) do
        %{"definition_name" => "DEFINITION_NAME"} = params ->
          Map.put(step, :params, Map.put(params, "definition_name", defn))

        _ ->
          step
      end
    end)
  end

  defp patch_outcome_prefix(outcomes, schema_name) do
    Enum.map(outcomes, fn outcome ->
      args = outcome.verification.args
      put_in(outcome, [:verification, :args], Map.put(args, "prefix", schema_name))
    end)
  end

  # ─── AC1: meridian-loan-origination-above-threshold ──────────────────────

  describe "meridian-loan-origination-above-threshold" do
    test "3 parallel tracks fork for real; a separate branch-completion call now advances the join cohort (ISS-0397)",
         %{schema_name: schema_name, actors: actors, definitions: %{loan: definition}} do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "loan-origination-above-threshold.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 3
      [step1, step2a, step2b] = report.step_results

      instance_id = step1.captured["instance_id"]

      assert step1.outcome == :ok, "step 1 (POST /instances) failed — #{inspect(step1.detail)}"
      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok, "step 2a (GET credit-memo lookup) — #{inspect(step2a.detail)}"

      # AC1's own "3 parallel assessment tracks confirmed created from real
      # queried task state" -- real: the split itself happens within
      # instance-creation's own single hop-chain, so both real HUMAN_TASKs
      # (credit-memo-review, risk-assessment) exist as task rows from that
      # point on regardless of what happens next; the KYC/AML track is the
      # immediate, unconditioned edge straight to assessment-join (test
      # module's own @simple_loan_origination_graph comment). Queried here
      # (by task existence, any status) rather than right after step1's own
      # `captured` map, because `Runner.run/1` executes this scenario's
      # entire step list -- including step 2b below -- before returning; a
      # query issued only after `Runner.run/1` returns necessarily observes
      # state as of the LAST step, not step 1's own (pre-ISS-0397 this
      # distinction never mattered here since step 2b always rolled back).
      {:ok, %{items: all_tasks}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, page_size: 10},
          prefix: schema_name
        )

      all_task_node_ids = Enum.map(all_tasks, fn {task, _form_version} -> task.node_id end)
      assert "credit-memo-review" in all_task_node_ids
      assert "risk-assessment" in all_task_node_ids

      # NOTE on `items.0` (found while updating this test for ISS-0397, not new
      # behavior it introduced): `GET /api/v1/tasks?...status=PENDING` orders by
      # `inserted_at DESC, id DESC` (Letflow.Tasks.list_tasks/2) -- since
      # credit-memo-review is inserted before risk-assessment within create/2's
      # own hop-chain, `items.0` is actually the risk-assessment task, not
      # credit-memo-review as this scenario's own YAML/step names assume. This
      # was never observable pre-fix (step 2b 500'd regardless of which task was
      # targeted) -- now that the call succeeds, the real task identity matters
      # and is asserted explicitly below rather than left to the (incorrect)
      # naming.
      #
      # Step 2b -- pre-ISS-0397, this reproduced the join_counters defect: a
      # real, separate HTTP call completing one parallel branch could not route
      # through assessment-join, since Engine.complete_task/3's freshly-rebuilt
      # InstanceState always had join_counters: %{}. Post-fix, this call reads
      # the durably-persisted cohort create/2's own split left behind
      # (instance_projections.join_counters) and succeeds: one of the 3 expected
      # branches (this one) is now received, two remain outstanding (the join
      # does not fire yet).
      assert step2b.outcome == :ok,
             "step 2b (POST task complete) was expected to succeed now that " <>
               "ISS-0397 durably persists join_counters across calls; " <>
               "instead got outcome #{inspect(step2b.outcome)}, detail: #{inspect(step2b.detail)}"

      assert %{"instance_status" => "ACTIVE"} = step2b.detail

      # No expected_outcomes in this scenario's YAML (full quorum/disbursement
      # verification is out of reach of a real run, moduledoc) -- AC5's "closed
      # disposition, no step left unaddressed" is satisfied by every one of
      # these 3 steps having a real, asserted outcome.
      assert report.outcome_results == []

      # Real-state evidence the join cohort advanced correctly, one branch at a
      # time: risk-assessment is now COMPLETED (no longer pending), and the
      # assessment-join cohort still durably tracks credit-memo-review and the
      # KYC/AML branch as outstanding -- current_nodes narrows to
      # credit-memo-review alone (the join has not fired: 2 of 3 branches
      # received).
      {:ok, %{items: pending_after_step2b}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      pending_node_ids_after_step2b =
        Enum.map(pending_after_step2b, fn {task, _form_version} -> task.node_id end)

      assert pending_node_ids_after_step2b == ["credit-memo-review"],
             "Expected only credit-memo-review still PENDING after risk-assessment's " <>
               "own branch completed and joined into the still-outstanding cohort"

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
      assert final_projection.current_nodes == ["credit-memo-review"]

      assert %{"assessment-join" => cohort} = final_projection.join_counters
      assert length(cohort["received_from_branches"]) == 2
      assert length(cohort["expected_from_branches"]) == 3
    end
  end

  # ─── AC2: meridian-loan-origination-below-threshold ──────────────────────

  describe "meridian-loan-origination-below-threshold" do
    test "3 parallel tracks fork for real; second, separate task-completion call now succeeds (ISS-0397)",
         %{schema_name: schema_name, actors: actors, definitions: %{loan: definition}} do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "loan-origination-below-threshold.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 3
      [step1, step2a, step2b] = report.step_results

      instance_id = step1.captured["instance_id"]

      assert step1.outcome == :ok, "step 1 (POST /instances) failed — #{inspect(step1.detail)}"
      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok, "step 2a (GET credit-memo lookup) — #{inspect(step2a.detail)}"

      # Same "3 real HUMAN_TASKs created" evidence as the above-threshold test
      # above -- queried by existence (any status), not "still pending", since
      # `Runner.run/1` already executed step 2b (below) by the time this
      # returns (see that test's own comment on why).
      {:ok, %{items: all_tasks}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, page_size: 10},
          prefix: schema_name
        )

      all_task_node_ids = Enum.map(all_tasks, fn {task, _form_version} -> task.node_id end)
      assert "credit-memo-review" in all_task_node_ids
      assert "risk-assessment" in all_task_node_ids

      # Same fix as the above-threshold scenario (moduledoc, top) -- this
      # scenario's own graph is identical up to this point, so it behaves
      # identically post-fix. EO-002's own literal design point (no
      # committee-vote task exists) still cannot be verified via a full
      # end-to-end run (SERVICE_TASK dispatch gap, unrelated to ISS-0397) --
      # stated explicitly here, not silently assumed to hold.
      assert step2b.outcome == :ok,
             "step 2b (POST task complete) was expected to succeed now that " <>
               "ISS-0397 durably persists join_counters across calls; " <>
               "instead got outcome #{inspect(step2b.outcome)}, detail: #{inspect(step2b.detail)}"

      assert %{"instance_status" => "ACTIVE"} = step2b.detail

      assert report.outcome_results == []

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
      assert final_projection.current_nodes == ["credit-memo-review"]

      assert %{"assessment-join" => cohort} = final_projection.join_counters
      assert length(cohort["received_from_branches"]) == 2
      assert length(cohort["expected_from_branches"]) == 3
    end
  end

  # ─── AC3: meridian-regulatory-compliance-review-bafin ────────────────────

  describe "meridian-regulatory-compliance-review-bafin" do
    test "steps 1/2 real against real queried state; step 3 :blocked, blocked_by ISS-0389",
         %{schema_name: schema_name, actors: actors, definitions: %{review: definition}} do
      scenario_raw =
        ScenarioFixture.load!(
          Path.join(@scenarios_dir, "regulatory-compliance-review-bafin.yaml")
        )

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 4
      [step1, step2a, step2b, step3] = report.step_results

      instance_id = step1.captured["instance_id"]

      assert step1.outcome == :ok, "step 1 (POST /instances) failed — #{inspect(step1.detail)}"
      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok,
             "step 2a (GET evidence-collection lookup) — #{inspect(step2a.detail)}"

      # Step 1's own real-queried-state verification (design §4.3): since
      # Runner.run/1 dispatches every step through to completion before this test
      # body ever inspects anything (there is no intermediate-state hook), the
      # ONLY real evidence of state "right after step 1" is step 2a's own
      # already-captured real HTTP response (a GET /tasks call dispatched before
      # step 2b ever runs) -- not a fresh query issued now, after step 2b has
      # already moved the instance on to risk-evaluation. That real response
      # confirms an evidence-collection HUMAN_TASK existed at that point.
      assert %{"items" => [%{"node_id" => "evidence-collection"} | _]} = step2a.captured

      assert step2b.outcome == :ok,
             "step 2b (POST evidence-collection complete) — #{inspect(step2b.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST evidence-collection complete) — #{inspect(step2b.detail)}"

      # Step 2's own real-queried-state verification (design §4.3, primary
      # mechanism, superseding the task-list-inference workaround the design
      # originally proposed, per OQ-1): current_nodes contains "risk-evaluation"
      # after evidence-collection completes -- direct, real-queried-state evidence
      # the instance is genuinely paused exactly at the node whose timer boundary
      # step 3 would need to advance.
      {:ok, projection_after_step2} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert projection_after_step2.status == :active
      assert "risk-evaluation" in projection_after_step2.current_nodes

      # Kept alongside (not replacing) current_nodes: the risk-evaluation
      # HUMAN_TASK (role-risk-manager) exists and is PENDING -- distinct evidence
      # (task existence, role assignment) current_nodes alone cannot express.
      {:ok, %{items: pending_items}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      risk_evaluation_task =
        Enum.find(pending_items, fn {task, _form_version} -> task.node_id == "risk-evaluation" end)

      assert risk_evaluation_task != nil,
             "Expected a real, pending risk-evaluation HUMAN_TASK to exist for this instance"

      {risk_task, _form_version} = risk_evaluation_task
      assert risk_task.assignee_ref == "role-risk-manager"

      # Step 3: :blocked, not :skip (design §2.1's rationale) -- a regression
      # detector: if a later merge ships advance-timer, this assertion should be
      # the first thing to force someone to revisit this scenario's disposition
      # (same "disposition doubles as a regression detector" precedent REQ-207 §5
      # established for its own BLOCKED_ON_DEPENDENCY entity-scenario test).
      assert step3.outcome == :blocked,
             "step 3 expected :blocked, got #{inspect(step3.outcome)}"

      assert step3.blocked_by == "ISS-0389"
      assert step3.severity == :blocker
      assert step3.captured == nil

      # TEST-DESIGNER coverage-verification addition (this session): the
      # :no_task_of_type verification method (design §2.2, EO-002's own
      # negative-assertion primitive) was implemented by ELIXIR-DEV but never
      # actually exercised anywhere -- both loan-origination scenarios were
      # truncated before EO-002 could run (join_counters BLOCKER, see moduledoc).
      # Exercised here instead, on real queried state unaffected by that defect
      # (this scenario has no PARALLEL_GATEWAY), so the new verification method's
      # own logic gets real coverage rather than shipping untested.
      assert length(report.outcome_results) == 2
      [eo_no_task_absent, eo_no_task_present] = report.outcome_results

      # EO-NO-TASK-001: findings-sign-off is never reached on this scenario's
      # exercised path -- genuine :pass (real absence, not an unresolved
      # template or a not-found error mistaken for absence).
      assert eo_no_task_absent.outcome == :pass,
             "expected :no_task_of_type(findings-sign-off) to PASS (real absence) — " <>
               "observed: #{inspect(eo_no_task_absent.observed)}"

      refute Enum.any?(eo_no_task_absent.observed, fn {node_id, _status} ->
               node_id == "findings-sign-off"
             end)

      # EO-NO-TASK-002: negative control proving EO-NO-TASK-001 is not vacuously
      # true. evidence-collection DOES exist (COMPLETED by step 2b) -- queried
      # across every status, per design §2.2's "absence must hold regardless of
      # status" rule, so a status-blind implementation bug (e.g. only checking
      # :pending) cannot silently pass here. Real :fail expected.
      assert eo_no_task_present.outcome == :fail,
             "expected :no_task_of_type(evidence-collection) to FAIL (task genuinely " <>
               "exists, COMPLETED) — observed: #{inspect(eo_no_task_present.observed)}"

      assert Enum.any?(eo_no_task_present.observed, fn {node_id, _status} ->
               node_id == "evidence-collection"
             end)

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-215 AC2 -- committee-vote/quorum-2-of-3/disbursement paths reached
  # and passing end to end, now that SERVICE_TASK dispatch is wired. See this
  # module's own moduledoc, "CLOSED by REQ-215" section.
  # ═══════════════════════════════════════════════════════════════════════

  describe "loan-origination above-threshold, full committee-vote through disbursement (REQ-215 AC2)" do
    setup %{schema_name: schema_name, actor_ids: actor_ids} do
      Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
      on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)

      %{url: server_url} =
        Letflow.WebhookTestServer.start(200, ~s({"facility_id":"FAC-9001"}))

      graph =
        put_in(
          @loan_origination_graph_with_service_task["nodes"],
          Enum.map(@loan_origination_graph_with_service_task["nodes"], fn
            %{"id" => "create-facility"} = node ->
              put_in(node, ["attributes", "endpoint"], server_url)

            node ->
              node
          end)
        )

      name =
        "LoanOriginationWithServiceTask-" <>
          to_string(System.unique_integer([:positive, :monotonic]))

      {:ok, d} =
        Definitions.create(
          %{
            name: name,
            version: "1.0",
            description:
              "REQ-215 AC2 test-local process: same shape as SimpleLoanOrigination but " <>
                "keeps create-facility as a real SERVICE_TASK node instead of eliding it.",
            graph: graph,
            created_by: actor_ids.lars
          },
          prefix: schema_name
        )

      {:ok, %{definition: activated}} = Definitions.activate(d.id, prefix: schema_name)

      %{definition: activated, server_url: server_url}
    end

    test "quorum-2-of-3 join fires, committee approves, create-facility SERVICE_TASK dispatches and resolves, disbursement completes the instance",
         %{schema_name: schema_name, actor_ids: actor_ids, definition: definition} do
      # Step 1 -- above-threshold amount (750000 > 500000), same as
      # loan-origination-above-threshold.yaml's own initial_variables.
      assert {:ok, create_result} =
               Engine.create(
                 %{
                   definition_id: definition.id,
                   initial_variables: %{"requested_amount_eur" => 750_000},
                   actor_id: actor_ids.lars,
                   idempotency_key: "req215-ac2-create-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      instance_id = create_result.instance_id

      # 2 real HUMAN_TASKs from the fork (the KYC/AML track is the immediate,
      # unconditioned edge straight to assessment-join, same as
      # @simple_loan_origination_graph -- see that graph's own comment).
      {:ok, %{items: fork_tasks}} =
        Tasks.list_tasks(%{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      fork_task_node_ids = Enum.map(fork_tasks, fn {task, _fv} -> task.node_id end) |> Enum.sort()
      assert fork_task_node_ids == ["credit-memo-review", "risk-assessment"]

      credit_memo_task =
        Enum.find(fork_tasks, fn {t, _fv} -> t.node_id == "credit-memo-review" end) |> elem(0)

      risk_task =
        Enum.find(fork_tasks, fn {t, _fv} -> t.node_id == "risk-assessment" end) |> elem(0)

      # Complete both real, separate branches -- ISS-0397's own durable
      # join_counters fix (moduledoc) lets each SEPARATE complete_task/3
      # call route through assessment-join correctly. The join fires on the
      # SECOND completion (2-of-3 already received from credit-memo-review +
      # risk-assessment + the KYC/AML track's own immediate edge = quorum
      # reached at assessment-join, a real PARALLEL_GATEWAY join, in-degree 3).
      assert {:ok, _} =
               Engine.complete_task(
                 credit_memo_task.id,
                 %{
                   output_variables: %{"credit_decision" => "pass"},
                   actor_id: actor_ids.julia,
                   idempotency_key: "req215-ac2-credit-memo-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert {:ok, risk_complete_result} =
               Engine.complete_task(
                 risk_task.id,
                 %{
                   output_variables: %{"risk_rating" => "acceptable"},
                   actor_id: actor_ids.thomas,
                   idempotency_key: "req215-ac2-risk-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      # The join fired -- current_nodes narrows past assessment-join, past
      # eligibility-gate (pass/acceptable -> authority-routing), past
      # authority-routing (750000 > 500000 -> credit-committee-vote), landing
      # the token at credit-committee-vote -- real, quorum-driven multi-hop
      # advance in one complete_task/3 call, proving quorum-2-of-3 genuinely
      # fired (not just "the join counter incremented").
      assert risk_complete_result.instance_status == :active
      assert risk_complete_result.current_nodes == ["credit-committee-vote"]

      {:ok, %{items: committee_tasks}} =
        Tasks.list_tasks(%{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      assert [{committee_task, _fv}] = committee_tasks
      assert committee_task.node_id == "credit-committee-vote"
      assert committee_task.assignee_ref == "role-committee-member"

      # Committee votes "approved" -- routes to create-facility, a REAL
      # SERVICE_TASK node. The token PARKS there (no automatic outgoing
      # traversal, design doc §1.4) -- a real service_task_dispatches row is
      # created in the SAME transaction (REQ-215 AC3's own guarantee, proven
      # generically in service_task_wiring_test.exs; here proven in the
      # context AC2 actually names: the real Meridian committee-vote path).
      assert {:ok, committee_complete_result} =
               Engine.complete_task(
                 committee_task.id,
                 %{
                   output_variables: %{"committee_outcome" => "approved"},
                   actor_id: actor_ids.eva,
                   idempotency_key: "req215-ac2-committee-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert committee_complete_result.instance_status == :active
      assert committee_complete_result.current_nodes == ["create-facility"]

      assert [dispatch] =
               ServiceTaskDispatch
               |> Ecto.Query.where([d], d.instance_id == ^instance_id)
               |> Repo.all(prefix: schema_name)

      assert dispatch.status == "pending"
      assert dispatch.node_id == "create-facility"

      # REQ-214's already-shipped transport call resolves it -- a real 2xx
      # JSON response from the real local server (facility_id, the exact
      # kind of downstream-system response create-facility's own real
      # endpoint, POST /core-banking/facilities, would return).
      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert decoded_body == %{"facility_id" => "FAC-9001"}

      # This requirement's own re-entry function -- advances the token off
      # create-facility onto disburse-loan, merging the decoded body into
      # instance variables (REQ-049's VariableMerge.merge/3, exercised here
      # in the real Meridian committee-vote/disbursement context AC2 names,
      # not just a synthetic graph).
      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:advance, decoded_body},
                 Repo,
                 schema_name
               )

      {:ok, projection_after_advance} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert projection_after_advance.status == :active
      assert projection_after_advance.current_nodes == ["disburse-loan"]
      assert projection_after_advance.variables["facility_id"] == "FAC-9001"

      {:ok, %{items: disburse_tasks}} =
        Tasks.list_tasks(%{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      assert [{disburse_task, _fv}] = disburse_tasks
      assert disburse_task.node_id == "disburse-loan"
      assert disburse_task.assignee_ref == "role-loan-ops"

      # Disbursement itself -- the loan-ops actor completes disburse-loan,
      # reaching end-disbursed. This is AC2's own literal "disbursement path
      # ... reached and pass end to end" claim, closed for real: the
      # instance actually COMPLETES.
      assert {:ok, disburse_complete_result} =
               Engine.complete_task(
                 disburse_task.id,
                 %{
                   output_variables: %{},
                   actor_id: actor_ids.marcus,
                   idempotency_key: "req215-ac2-disburse-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert disburse_complete_result.instance_status == :completed

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :completed
      assert final_projection.current_nodes == []
    end
  end
end
