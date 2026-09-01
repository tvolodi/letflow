defmodule Letflow.Simulation.Req208MeridianTest do
  @moduledoc """
  REQ-208 acceptance criteria: 3 Meridian scenario YAMLs run through
  `Letflow.Simulation.Runner`.

  ## CRITICAL FINDING, discovered this session, blocking full AC1/AC2 verification
  (reported via `result.issues` at handoff time -- a NEW finding, not covered by
  ISS-0388..0393; ELIXIR-DEV does not self-assign an issue id per
  `docs/agents/protocols/ISSUE_QUEUE.md`)

  `Letflow.Engine.complete_task/3`'s real, per-call state-rebuild
  (`lib/letflow/engine.ex`'s `build_instance_state/3`) hardcodes
  `join_counters: %{}` on EVERY call -- confirmed by that function's own code
  comment ("§6.5, §11 INV-EE48-7, MAJOR OQ-3): no table persists JoinCounter
  state across calls today") and independently reproduced this session against a
  real running instance (`Letflow.Engine.create/2` for the initial split, then a
  SEPARATE `Letflow.Engine.complete_task/3` call for the first branch's own
  completion -- real HTTP 500, `{:error, {:activation_failed,
  {:unknown_branch_id, _}}}` internally). A `PARALLEL_GATEWAY` join can
  therefore only ever fire within the SAME hop-chain call as its own split --
  the instant a real, separate HTTP call (any HUMAN_TASK completion on any
  branch) tries to route through the join, it fails. REQ-054 (SnapshotWriter,
  `status: done`) DOES serialize `join_counters` correctly into
  `instance_state_snapshots` -- but `Engine.complete_task/3`'s own hot path
  never reads that table; it always rebuilds state fresh from `tokens`/`tasks`
  directly (`lib/letflow/engine.ex`'s `build_snapshot_and_state/4`). This is a
  genuine, pre-existing platform BLOCKER affecting every process with a
  `PARALLEL_GATEWAY` split whose branches require separate task completions --
  not introduced by, or fixable within, REQ-208's own scope (this is Engine-core
  work, its own CODE-DESIGNER-sized task, same "does not build a native
  quorum-counting node type in `Letflow.Engine`" scope boundary the design
  itself already drew for a related but distinct reason at §2.2 of its scope
  discipline).

  **Consequence:** `meridian-loan-origination-above-threshold` and
  `meridian-loan-origination-below-threshold` cannot be exercised past their
  first parallel-branch task completion. Both scenario YAMLs were truncated
  (their own header comments explain this) to the steps that DO run for real
  (instance creation, forking 3 real parallel tracks; the first branch's task
  lookup; the first branch's task completion, which reproduces the defect) --
  fabricating a passing result for steps that cannot actually execute would
  violate `core-directives.md`'s "No speculation." AC1/AC2's own fuller claims
  (quorum, disbursement, EO-002's negative assertion) are NOT verified by this
  run; this is stated explicitly in the report (§6) rather than silently
  assumed to hold, matching the same "report an in-flight caveat rather than
  proceeding as if the dependency were closed" discipline REQ-208's own
  requirement text already establishes for AC4/REQ-199.

  ## SERVICE_TASK limitation (design §0.8/§3, same platform-wide gap REQ-206/207
  already found)
  `Letflow.Engine` does not yet dispatch SERVICE_TASK nodes. The real
  `process_claim_intake.yaml`/`process_policy_binding.yaml` fixtures have
  SERVICE_TASKs on their critical paths. Test-local simplified process graphs
  (`@simple_loan_origination_graph`, `@simple_regulatory_review_graph`) replace
  them with direct edges/END nodes, mirroring REQ-206/207's own precedent exactly.

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
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Instances
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.ScenarioFixture
  alias Letflow.Simulation.Seed
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
      definitions: %{loan: definition_loan, review: definition_review}
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
    test "3 parallel tracks fork for real; first branch completion reproduces the join_counters defect (real HTTP 500)",
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

      # AC1's own "3 parallel assessment tracks confirmed created from real queried
      # task state" -- THIS part is real and does hold: the split itself happens
      # within instance-creation's own single hop-chain, so join_counters being
      # reset on the NEXT call (see the moduledoc's critical finding) has no
      # bearing on it yet. 2 real HUMAN_TASKs are the concrete evidence here
      # (credit-memo-review, risk-assessment); the KYC/AML track is the immediate,
      # unconditioned edge straight to assessment-join (test module's own
      # @simple_loan_origination_graph comment).
      {:ok, projection_after_step1} = Instances.get_by_id(instance_id, prefix: schema_name)

      assert "credit-memo-review" in projection_after_step1.current_nodes
      assert "risk-assessment" in projection_after_step1.current_nodes

      {:ok, %{items: pending_after_step1}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      pending_node_ids_after_step1 =
        Enum.map(pending_after_step1, fn {task, _form_version} -> task.node_id end)

      assert "credit-memo-review" in pending_node_ids_after_step1
      assert "risk-assessment" in pending_node_ids_after_step1

      assert step2a.outcome == :ok, "step 2a (GET credit-memo lookup) — #{inspect(step2a.detail)}"

      # Step 2b reproduces the critical finding (moduledoc, top): a real, separate
      # HTTP call completing one parallel branch cannot route through
      # assessment-join, since Engine.complete_task/3's freshly-rebuilt
      # InstanceState always has join_counters: %{}. This is a REAL HTTP 500
      # (INV-4's no-detail internal-error problem body), not a harness
      # malfunction -- asserted explicitly here as the actual, reproducible
      # platform behavior this run discovered.
      assert step2b.outcome == :error,
             "step 2b (POST credit-memo complete) was expected to reproduce the " <>
               "join_counters-not-persisted-across-calls defect (real HTTP 500); " <>
               "instead got outcome #{inspect(step2b.outcome)}, detail: #{inspect(step2b.detail)}"

      assert %{status: 500, body: %{"status" => 500, "title" => "Internal Server Error"}} =
               step2b.detail

      # No expected_outcomes in this scenario's YAML (nothing past this point can be
      # verified for real) -- AC5's "closed disposition, no step left unaddressed"
      # is satisfied by every one of these 3 steps having a real, asserted outcome.
      assert report.outcome_results == []

      # Real-state evidence the failed call left no partial corruption (INV-EE48-7's
      # own "typed, non-crashing failure, not silent data corruption" -- the whole
      # Ecto.Multi rolled back): the credit-memo-review task is still PENDING, the
      # instance is still ACTIVE, at the same 2 nodes as right after step 1.
      {:ok, %{items: pending_after_step2b}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      pending_node_ids_after_step2b =
        Enum.map(pending_after_step2b, fn {task, _form_version} -> task.node_id end)

      assert "credit-memo-review" in pending_node_ids_after_step2b,
             "Expected the failed complete call to have rolled back entirely (no " <>
               "partial commit), leaving credit-memo-review still PENDING"

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
      assert "credit-memo-review" in final_projection.current_nodes
      assert "risk-assessment" in final_projection.current_nodes
    end
  end

  # ─── AC2: meridian-loan-origination-below-threshold ──────────────────────

  describe "meridian-loan-origination-below-threshold" do
    test "3 parallel tracks fork for real; first branch completion reproduces the SAME join_counters defect",
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

      {:ok, projection_after_step1} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert "credit-memo-review" in projection_after_step1.current_nodes
      assert "risk-assessment" in projection_after_step1.current_nodes

      assert step2a.outcome == :ok, "step 2a (GET credit-memo lookup) — #{inspect(step2a.detail)}"

      # Same defect as the above-threshold scenario (moduledoc, top) -- this
      # scenario's own graph is identical up to this point, so it reproduces
      # identically. EO-002's own literal design point (no committee-vote task
      # exists) cannot be verified via the intended full end-to-end run either,
      # since the run cannot progress past this call -- stated explicitly here,
      # not silently assumed to still hold.
      assert step2b.outcome == :error,
             "step 2b (POST credit-memo complete) was expected to reproduce the " <>
               "join_counters-not-persisted-across-calls defect (real HTTP 500); " <>
               "instead got outcome #{inspect(step2b.outcome)}, detail: #{inspect(step2b.detail)}"

      assert %{status: 500, body: %{"status" => 500, "title" => "Internal Server Error"}} =
               step2b.detail

      assert report.outcome_results == []

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
      assert "credit-memo-review" in final_projection.current_nodes
      assert "risk-assessment" in final_projection.current_nodes
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

      assert length(report.outcome_results) == 0

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
    end
  end
end
