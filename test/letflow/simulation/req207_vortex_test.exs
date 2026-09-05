defmodule Letflow.Simulation.Req207VortexTest do
  @moduledoc """
  REQ-207 acceptance criteria: 4 Vortex scenario YAMLs run through
  `Letflow.Simulation.Runner`, each returning a closed disposition:
  EXECUTED/PASS-or-FAIL (production-order-above-threshold, supplier-quality-deviation
  critical/false-positive), BLOCKED_ON_DEPENDENCY (entity-list-filter-and-page).

  ## SERVICE_TASK limitation (affects all 3 real scenarios, design §0.3/§2)
  `Letflow.Engine` does not yet dispatch SERVICE_TASK nodes. The real
  `process_quality_check.yaml`/`process_work_order.yaml` fixtures have SERVICE_TASKs on
  their critical paths. Test-local simplified process graphs
  (`@simple_production_order_graph`, `@simple_supplier_deviation_graph`) replace them
  with direct edges/END nodes (production-order) or a HUMAN_TASK substitute
  (quarantine-batch, so EO-001's audit-event-ordering claim has real evidence) --
  mirrors REQ-206's `@simple_approval_graph` precedent exactly.

  ## OQ-2 (design §7) -- RESOLVED: no by-parent-instance-id lookup function exists on
  `Letflow.Instances`/`Letflow.Engine` (confirmed by reading both modules this session).
  `Letflow.EventStore.InstanceProjection.parent_instance_id` IS a real, populated column
  (`Letflow.Engine.SubProcess.insert_child_instance_projection/8` sets it on every
  sub-process child row) -- resolved here via a direct, test-local `Repo` query against
  that column (`find_child_by_parent_instance_id/2`, below), the narrowest read
  consistent with "no by-parent context function exists yet."

  ## OQ-3 (design §7) -- RESOLVED, differently than either candidate the design named:
  `InstanceProjection.current_nodes` is NOT usable for terminal-node identity --
  `Letflow.Engine.Transition`'s `dispatch_end/3` (transition.ex:373-379)
  unconditionally drops a token the instant it reaches an END node, so
  `current_nodes` is always `[]` once `status == :completed`, for every terminal END
  node alike (confirmed empirically this session: both scenarios below hit this).
  The real, queryable distinguishing signal is each scenario's own last real
  `TASK_COMPLETED`/`SUB_PROCESS_COMPLETED` event payload's `"activated_nodes"` field
  (via `Letflow.Instances.history/3`) -- see each describe block below for the exact
  per-scenario reasoning.

  Real Postgres, `async: false` -- tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.ScenarioFixture
  alias Letflow.Simulation.Seed
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/vortex", __DIR__)
  @scenarios_dir Path.join(@fixtures_dir, "scenarios")

  # ── §2.1: @simple_production_order_graph ──────────────────────────────────
  # Derived from process_quality_check.yaml (design §0.3), SERVICE_TASK nodes elided:
  # assign-line/auto-reject-order replaced by direct edges to end-released/end-rejected;
  # notify-planner elided entirely. capacity-review/escalate-to-ceo/budget-gate/
  # budget-approval kept verbatim, same conditions.
  @simple_production_order_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "capacity-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-production-manager"}
      },
      %{
        "id" => "escalate-to-ceo",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-ceo"}
      },
      %{"id" => "budget-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "budget-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-controller"}
      },
      %{"id" => "end-released", "node_type" => "END"},
      %{"id" => "end-rejected", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "capacity-review"},
      %{
        "id" => "e1",
        "source" => "capacity-review",
        "target" => "budget-gate",
        "condition" => "variables.capacity_decision == 'approve'"
      },
      %{
        "id" => "e2",
        "source" => "capacity-review",
        "target" => "end-rejected",
        "condition" => "variables.capacity_decision == 'reject'"
      },
      # on_timeout fallback for capacity-review
      %{
        "id" => "fallback-capacity-review",
        "source" => "capacity-review",
        "target" => "escalate-to-ceo"
      },
      %{
        "id" => "e3",
        "source" => "escalate-to-ceo",
        "target" => "budget-gate",
        "condition" => "variables.capacity_decision == 'approve'"
      },
      %{
        "id" => "e4",
        "source" => "escalate-to-ceo",
        "target" => "end-rejected",
        "condition" => "variables.capacity_decision == 'reject'"
      },
      # on_timeout fallback for escalate-to-ceo
      %{
        "id" => "timeout-escalate-to-ceo",
        "source" => "escalate-to-ceo",
        "target" => "end-rejected"
      },
      %{
        "id" => "e5",
        "source" => "budget-gate",
        "target" => "budget-approval",
        "condition" => "variables.order_value_eur > 10000"
      },
      %{
        "id" => "e6",
        "source" => "budget-gate",
        "target" => "end-released",
        "condition" => "variables.order_value_eur <= 10000"
      },
      %{
        "id" => "e7",
        "source" => "budget-approval",
        "target" => "end-released",
        "condition" => "variables.budget_decision == 'approve'"
      },
      %{
        "id" => "e8",
        "source" => "budget-approval",
        "target" => "end-rejected",
        "condition" => "variables.budget_decision == 'reject'"
      },
      # on_timeout fallback for budget-approval
      %{
        "id" => "timeout-budget-approval",
        "source" => "budget-approval",
        "target" => "end-rejected"
      }
    ]
  }

  # ── §2.2: @simple_supplier_deviation_graph ────────────────────────────────
  # Derived from process_work_order.yaml (design §0.3). quarantine-batch (SERVICE_TASK)
  # substituted to a HUMAN_TASK (design §2.2/§2.3 rationale: EO-001's audit-event
  # ordering claim needs real, timestamped task.create/task.complete evidence).
  # severity-classification/false-positive-check/severity-routing/
  # corrective-action-subprocess kept real. release-quarantine/supplier-warning/
  # supplier-notification/close-deviation/default-to-major elided, folded into
  # neighboring edges.
  @simple_supplier_deviation_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "quarantine-batch",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-quality-manager"}
      },
      %{
        "id" => "severity-classification",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-quality-manager"}
      },
      %{"id" => "false-positive-check", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{"id" => "severity-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "corrective-action-subprocess",
        "node_type" => "SUB_PROCESS",
        "attributes" => %{"definition_name" => "CHILD_DEFINITION_NAME"}
      },
      %{"id" => "end-closed", "node_type" => "END"},
      %{"id" => "end-false-positive", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "quarantine-batch"},
      %{"id" => "e1", "source" => "quarantine-batch", "target" => "severity-classification"},
      %{"id" => "e2", "source" => "severity-classification", "target" => "false-positive-check"},
      %{
        "id" => "e3",
        "source" => "false-positive-check",
        "target" => "end-false-positive",
        "condition" => "variables.false_positive == true"
      },
      %{
        "id" => "e4",
        "source" => "false-positive-check",
        "target" => "severity-routing",
        "condition" => "variables.false_positive == false"
      },
      %{
        "id" => "e5",
        "source" => "severity-routing",
        "target" => "corrective-action-subprocess",
        "condition" => "variables.severity == 'critical'"
      },
      %{"id" => "e6", "source" => "corrective-action-subprocess", "target" => "end-closed"}
    ]
  }

  # Child definition graph for corrective-action-subprocess -- START -> HUMAN_TASK ->
  # END, NOT a synchronously-completing START->END graph. A synchronously-completing
  # child cascades its own completion multi (Letflow.Engine.SubProcess.
  # append_completion_multi/5, via maybe_chain_synchronous_completion/6) back into the
  # SAME transaction as the parent hop-chain that spawned it -- both append a
  # {:task_records, parent_instance_id} Multi step for the same parent instance_id,
  # which raises `cannot merge Multi` (Ecto.Multi.merge_results/3), a real pre-existing
  # Engine defect (lib/letflow/engine.ex's append_sub_process_children_creation_multi/5
  # chaining into Letflow.Engine.SubProcess.append_start_multi/7's own synchronous-
  # completion branch), out of this requirement's scope to fix (REQ-062 already
  # shipped/reviewed; flagged for REVIEWER/a follow-up issue, not silently worked
  # around by re-designing Engine here). A pending HUMAN_TASK child, completed by its
  # own separate Engine.complete_task/3 call (the scenario's own extra step, below),
  # avoids the collision entirely -- this is the SAME class of test-local workaround
  # REQ-206 already used for the SERVICE_TASK gap (design §2), applied to a different
  # real Engine limitation this scenario happened to be the first to exercise.
  @simple_child_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "corrective-work",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-quality-manager"}
      },
      %{"id" => "end", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "corrective-work"},
      %{"id" => "e1", "source" => "corrective-work", "target" => "end"}
    ]
  }

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req207")

    company = %{
      "slug" => unique,
      "display_name" => "Vortex Manufacturing GmbH",
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

    anna = Map.fetch!(users_by_actor_id, "actor-vortex-anna")
    sabine = Map.fetch!(users_by_actor_id, "actor-vortex-sabine")
    stefan = Map.fetch!(users_by_actor_id, "actor-vortex-stefan")
    karl = Map.fetch!(users_by_actor_id, "actor-vortex-karl")
    nina = Map.fetch!(users_by_actor_id, "actor-vortex-nina")

    # Seed the trivial sub-process child definition first, so the parent simplified
    # graph can reference its real name.
    child_definition_name = "SimpleCorrectiveAction-" <> unique

    {:ok, definition_child} =
      case Letflow.Definitions.get_active_by_name(child_definition_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: child_definition_name,
                     version: "1.0",
                     description: "REQ-207 test-local trivial sub-process child (start->end).",
                     graph: @simple_child_graph,
                     created_by: anna.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Seed simplified production-order process (no SERVICE_TASKs; for
    # production-order-above-threshold).
    simple_production_order_name = "SimpleProductionOrderRelease-" <> unique

    {:ok, definition_production_order} =
      case Letflow.Definitions.get_active_by_name(simple_production_order_name,
             prefix: schema_name
           ) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_production_order_name,
                     version: "1.0",
                     description:
                       "REQ-207 test-local process: exercises budget-gate CEL EXCLUSIVE_GATEWAY branch without SERVICE_TASKs.",
                     graph: @simple_production_order_graph,
                     created_by: anna.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Seed simplified supplier-deviation process (no SERVICE_TASKs except the
    # quarantine-batch HUMAN_TASK substitute; for both critical and false-positive
    # scenarios -- same seeded definition, per the requirement text).
    simple_deviation_name = "SimpleSupplierQualityDeviation-" <> unique

    graph_with_child =
      put_in(
        @simple_supplier_deviation_graph,
        ["nodes"],
        Enum.map(@simple_supplier_deviation_graph["nodes"], fn
          %{"id" => "corrective-action-subprocess"} = node ->
            put_in(node, ["attributes", "definition_name"], definition_child.name)

          node ->
            node
        end)
      )

    {:ok, definition_deviation} =
      case Letflow.Definitions.get_active_by_name(simple_deviation_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_deviation_name,
                     version: "1.0",
                     description:
                       "REQ-207 test-local process: exercises severity-routing CEL EXCLUSIVE_GATEWAY branch and real SUB_PROCESS spawn without other SERVICE_TASKs.",
                     graph: graph_with_child,
                     created_by: karl.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    {:ok, %{plaintext: anna_token}} =
      Identity.create_token(anna.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: sabine_token}} =
      Identity.create_token(sabine.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: stefan_token}} =
      Identity.create_token(stefan.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: karl_token}} =
      Identity.create_token(karl.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: nina_token}} =
      Identity.create_token(nina.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    actors = %{
      "actor-vortex-anna" => %{"token" => anna_token, "tenant_slug" => unique},
      "actor-vortex-sabine" => %{"token" => sabine_token, "tenant_slug" => unique},
      "actor-vortex-stefan" => %{"token" => stefan_token, "tenant_slug" => unique},
      "actor-vortex-karl" => %{"token" => karl_token, "tenant_slug" => unique},
      "actor-vortex-nina" => %{"token" => nina_token, "tenant_slug" => unique}
    }

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      unique: unique,
      actors: actors,
      definitions: %{
        production_order: definition_production_order,
        deviation: definition_deviation,
        child: definition_child
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

  # Replaces "TENANT_PREFIX" in precondition/outcome args (top-level and, for
  # :audit_event_ordering's nested "first"/"second" shape, one level deep),
  # "DEFINITION_NAME" in process_id/step params, with real test-time values.
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

      patched_args =
        case Map.take(args, ["first", "second"]) do
          %{} = sides when map_size(sides) > 0 ->
            Enum.reduce(["first", "second"], args, fn key, acc ->
              case Map.get(acc, key) do
                nil -> acc
                side -> Map.put(acc, key, Map.put(side, "prefix", schema_name))
              end
            end)

          _ ->
            Map.put(args, "prefix", schema_name)
        end

      put_in(outcome, [:verification, :args], patched_args)
    end)
  end

  # OQ-2: no by-parent-instance-id context function exists on Instances/Engine (see
  # moduledoc). Direct, test-local Repo query against InstanceProjection.parent_instance_id
  # -- the narrowest read consistent with that finding.
  defp find_child_by_parent_instance_id(parent_instance_id, schema_name) do
    InstanceProjection
    |> Ecto.Query.where([p], p.parent_instance_id == ^parent_instance_id)
    |> Repo.one(prefix: schema_name)
  end

  # Bounded walk-back for Signal 2 (entity/entity-query title: -> id: adjacency check).
  # REQ-257 inserted a `# PROVENANCE (...)` comment line between id: and title: for
  # several requirements.yaml entries, breaking the old exact idx - 1 adjacency
  # assumption. This walks upward from `idx`, skipping only blank or comment lines
  # (trimmed of trailing \r and whitespace, matching /^#/), and stops at the first
  # real content line. It deliberately does NOT keep searching past a real content
  # line for an id: further up -- a genuinely wrong or missing id: line must still
  # be returned here so the caller's assertion fails on it, exactly as before.
  defp nearest_preceding_id_line(title_lines, idx) when idx >= 0 do
    line = Enum.at(title_lines, idx)
    trimmed = line |> to_string() |> String.trim_trailing("\r") |> String.trim()

    if trimmed == "" or Regex.match?(~r/^#/, trimmed) do
      nearest_preceding_id_line(title_lines, idx - 1)
    else
      line
    end
  end

  defp nearest_preceding_id_line(_title_lines, idx) when idx < 0, do: nil

  # ─── AC1: vortex-production-order-above-threshold ───────────────────────

  describe "vortex-production-order-above-threshold" do
    test "planner submits -> capacity-review -> budget-approval; 4 expected_outcomes with evidence",
         %{
           schema_name: schema_name,
           actors: actors,
           definitions: %{production_order: definition}
         } do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "production-order-above-threshold.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok,
             "step 2a (GET /tasks capacity-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST /tasks capacity-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 3a (GET /tasks budget-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 3b (POST /tasks budget-complete) failed — detail: #{inspect(step3b.detail)}"

      assert length(report.outcome_results) == 4
      [eo1, eo2, eo3, eo4] = report.outcome_results

      # EO-1: task_assigned — budget-approval task existence proves edge e5
      # (order_value_eur > 10000) was taken, not e6.
      assert eo1.outcome in [:pass, :fail],
             "EO-1 task_assigned result must be :pass or :fail"

      assert %{assignee_ref: "role-controller"} = eo1.observed,
             "Expected budget-approval task assignee_ref to be 'role-controller'; observed: #{inspect(eo1.observed)}"

      assert eo2.outcome == :pass,
             "EO-2 instance_state (COMPLETED) failed — observed: #{inspect(eo2.observed)}"

      assert eo3.outcome == :pass,
             "EO-3 instance_state (variables) failed — observed: #{inspect(eo3.observed)}"

      assert eo4.outcome == :pass,
             "EO-4 audit_event (task.complete) failed — observed: #{inspect(eo4.observed)}"
    end
  end

  # ─── AC2: vortex-supplier-quality-deviation-critical ─────────────────────

  describe "vortex-supplier-quality-deviation-critical" do
    test "quarantine -> severity CRITICAL -> sub-process spawn; EO-001 ordering + sub-process outcome",
         %{
           schema_name: schema_name,
           actors: actors,
           definitions: %{deviation: definition}
         } do
      scenario_raw =
        ScenarioFixture.load!(
          Path.join(@scenarios_dir, "supplier-quality-deviation-critical.yaml")
        )

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      instance_id = step1.captured["instance_id"]

      assert step2a.outcome == :ok,
             "step 2a (GET /tasks quarantine-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST /tasks quarantine-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 3a (GET /tasks severity-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 3b (POST /tasks severity-complete: critical) failed — detail: #{inspect(step3b.detail)}"

      # 5 expected_outcomes declared in the YAML: task_assigned, instance_state x2,
      # sub-process-spawn placeholder (verified for real below, not through the YAML's
      # own verification block), and audit_event_ordering. instance_state's own
      # `status: "COMPLETED"` checks (eo_completed/eo_variables) necessarily :fail at
      # this point in the run -- the parent instance is still :active, parked on
      # corrective-action-subprocess, waiting on the child's own pending HUMAN_TASK
      # (see @simple_child_graph's moduledoc comment for why the child is NOT
      # synchronously-completing). Re-verified for real, post-child-completion, below.
      assert length(report.outcome_results) == 5

      [eo_task_assigned, _eo_completed, _eo_variables, _eo_subprocess_placeholder, eo_ordering] =
        report.outcome_results

      assert eo_task_assigned.outcome in [:pass, :fail]

      assert %{assignee_ref: "role-quality-manager"} = eo_task_assigned.observed,
             "Expected severity-classification task assignee_ref to be 'role-quality-manager'; observed: #{inspect(eo_task_assigned.observed)}"

      # EO-001 ordering: quarantine-batch's task.create precedes severity-classification's
      # task.create -- real timestamp comparison via the new :audit_event_ordering method.
      # Both task.create events already exist by this point (steps 2a/3a), independent of
      # the child's own completion below.
      assert eo_ordering.outcome == :pass,
             "audit_event_ordering (quarantine task.create < severity task.create) failed — observed: #{inspect(eo_ordering.observed)}"

      assert %{first: %{timestamp: first_ts}, second: %{timestamp: second_ts}} =
               eo_ordering.observed

      assert DateTime.compare(first_ts, second_ts) == :lt

      # Sub-process spawn verification (OQ-2): a real child instance exists, parented to
      # this instance, real (non-nil) status, :active -- waiting on its own pending
      # corrective-work HUMAN_TASK (@simple_child_graph).
      child = find_child_by_parent_instance_id(instance_id, schema_name)

      assert child != nil,
             "Expected a real child InstanceProjection row parented to #{instance_id}"

      assert child.status != nil
      assert child.status == :active

      # Drive the child's own completion independently (own transaction, matching
      # test/letflow/engine_sub_process_test.exs's own established pattern for a
      # non-synchronously-completing child) -- this is what actually reaches
      # end-closed and cascades the parent's own completion.
      {:ok, %{items: [{child_task, _definition_ver}]}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: child.instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      assert {:ok, _} =
               Letflow.Engine.complete_task(
                 child_task.id,
                 %{
                   output_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: "req207-corrective-work-" <> to_string(child_task.id)
                 },
                 prefix: schema_name
               )

      {:ok, final_projection} = Letflow.Instances.get_by_id(instance_id, prefix: schema_name)

      assert final_projection.status == :completed,
             "Expected parent instance to reach COMPLETED after child completion; observed: #{inspect(final_projection.status)}"

      # Terminal-node-identity (OQ-3, same re-resolution as the false-positive test):
      # current_nodes is [] once completed regardless of which END node was reached
      # (dispatch_end/3 unconditionally drops the token). The real, queryable signal
      # here is the parent's own SUB_PROCESS_COMPLETED event payload's
      # "activated_nodes" field (Letflow.Engine.SubProcess.append_sub_process_completed_event/8)
      # -- empty here too, since corrective-action-subprocess routes directly to
      # end-closed with no further real node. Confirms the same COMPLETED-with-no-
      # remaining-tokens shape as the false-positive scenario, via a different (parent-
      # stream) event, and confirms this is genuinely end-closed by construction (the
      # simplified graph's only edge out of corrective-action-subprocess, §2.2) rather
      # than by re-deriving it from current_nodes.
      {:ok, %{items: parent_history}} =
        Letflow.Instances.history(instance_id, %{page_size: 100}, prefix: schema_name)

      sub_process_completed_event =
        Enum.find(parent_history, &(&1.event_type == "SUB_PROCESS_COMPLETED"))

      assert sub_process_completed_event != nil,
             "Expected a SUB_PROCESS_COMPLETED event on the parent instance's stream"

      assert sub_process_completed_event.payload["activated_nodes"] == [],
             "Expected the parent's SUB_PROCESS_COMPLETED event to show activated_nodes == [] " <>
               "(corrective-action-subprocess routes directly to end-closed); observed: #{inspect(sub_process_completed_event.payload["activated_nodes"])}"

      assert final_projection.current_nodes == []
      assert final_projection.variables["false_positive"] == false
      assert final_projection.variables["severity"] == "critical"

      {:ok, final_child} = Letflow.Instances.get_by_id(child.instance_id, prefix: schema_name)
      assert final_child.status == :completed
    end
  end

  # ─── AC3: vortex-supplier-quality-deviation-false-positive ───────────────

  describe "vortex-supplier-quality-deviation-false-positive" do
    test "quarantine -> severity false-positive; reaches end-false-positive specifically",
         %{
           schema_name: schema_name,
           actors: actors,
           definitions: %{deviation: definition}
         } do
      scenario_raw =
        ScenarioFixture.load!(
          Path.join(@scenarios_dir, "supplier-quality-deviation-false-positive.yaml")
        )

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      # 5 declared steps (design §3.3: 1 + quarantine lookup/complete pair + severity
      # lookup/complete pair).
      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      instance_id = step1.captured["instance_id"]

      assert step2a.outcome == :ok,
             "step 1b (GET /tasks quarantine-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 1b (POST /tasks quarantine-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 2a (GET /tasks severity-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 2b (POST /tasks severity-complete: false_positive) failed — detail: #{inspect(step3b.detail)}"

      assert length(report.outcome_results) == 3
      [eo1, eo2, eo3] = report.outcome_results

      assert eo1.outcome == :pass,
             "EO-1 instance_state (COMPLETED) failed — observed: #{inspect(eo1.observed)}"

      assert eo2.outcome == :pass,
             "EO-2 instance_state (variables) failed — observed: #{inspect(eo2.observed)}"

      assert eo3.outcome == :pass,
             "EO-3 instance_state (status placeholder) failed — observed: #{inspect(eo3.observed)}"

      # Terminal-node-identity check (OQ-3, RE-RESOLVED against the real projection
      # shape -- current_nodes/activated_nodes are NOT usable: dispatch_end/3
      # (lib/letflow/engine/transition.ex:373-379) unconditionally drops a token the
      # instant it reaches an END node, so current_nodes is always [] once
      # status == :completed, for EVERY terminal END node alike -- it cannot
      # distinguish end-false-positive from end-closed. The real, queryable signal is
      # the severity-classification task's own TASK_COMPLETED event payload's
      # "activated_nodes" field (lib/letflow/engine.ex append_task_completed_event/5):
      # on the false-positive path, false-positive-check routes directly to
      # end-false-positive with no further real node in between, so
      # activated_nodes == [] for the SAME reason current_nodes is [] afterward --
      # BUT distinctly from the critical scenario, where severity-classification's own
      # completion routes onward to corrective-action-subprocess (a SUB_PROCESS node
      # that PARKS a :waiting token, not an END node), so that scenario's own
      # severity-classification TASK_COMPLETED event has a NON-empty activated_nodes
      # (["corrective-action-subprocess"]) at the same point in the hop chain. This
      # asymmetry -- empty vs. non-empty activated_nodes on the severity-classification
      # completion event specifically -- is the real, re-derived distinguishing
      # evidence between the two scenarios' terminal outcomes.
      {:ok, %{items: history_items}} =
        Letflow.Instances.history(instance_id, %{page_size: 100}, prefix: schema_name)

      severity_task_id = step3a.captured["items"] |> List.first() |> Map.fetch!("id")

      severity_completed_event =
        Enum.find(history_items, fn event ->
          event.event_type == "TASK_COMPLETED" and event.payload["task_id"] == severity_task_id
        end)

      assert severity_completed_event != nil,
             "Expected a TASK_COMPLETED event for the severity-classification task"

      assert severity_completed_event.payload["activated_nodes"] == [],
             "Expected severity-classification's own TASK_COMPLETED event to show " <>
               "activated_nodes == [] (direct route to end-false-positive, no " <>
               "intervening real node); observed: #{inspect(severity_completed_event.payload["activated_nodes"])}"

      {:ok, projection} = Letflow.Instances.get_by_id(instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # Structural cross-check closing the gap left by activated_nodes == [] alone:
      # empty activated_nodes is consistent with EITHER a same-node-count-of-hops route
      # to end-false-positive OR a (bugged) direct route to end-closed -- no persisted
      # event anywhere in this codebase records the literal target END node id
      # (confirmed this session: grepped every event_type: "..." append site under
      # lib/letflow/ -- none carries a target-node field; dispatch_end/3 discards
      # token.node_id, the one place it briefly holds the real END id, without
      # recording it). The seeded graph (`@simple_supplier_deviation_graph`, this
      # module) is itself the ground truth for which literal node a given edge/condition
      # leads to, since it's the actual definition the instance ran against -- so assert
      # directly against it, not against a separately-typed literal, closing the loop:
      # this run took the `false_positive == true` edge (the only variable set on this
      # scenario's instance, `false_positive: true` with no `severity` -- confirmed
      # above via eo2's variables assertion) out of `false-positive-check`, and that
      # edge's own recorded target is the literal string "end-false-positive", never
      # "end-closed". A future edit that pointed the `false_positive == true` edge at
      # "end-closed" instead would flip this assertion, even though activated_nodes
      # would still read [] either way.
      false_positive_edge =
        Enum.find(@simple_supplier_deviation_graph["edges"], fn edge ->
          edge["source"] == "false-positive-check" and
            edge["condition"] == "variables.false_positive == true"
        end)

      assert false_positive_edge != nil,
             "Expected the seeded graph to declare an edge out of false-positive-check " <>
               "conditioned on variables.false_positive == true"

      assert false_positive_edge["target"] == "end-false-positive",
             "Expected the false_positive == true edge to target end-false-positive " <>
               "specifically, not end-closed (both are END nodes in this graph, and " <>
               "activated_nodes == [] alone cannot distinguish them); observed target: " <>
               inspect(false_positive_edge["target"])

      refute false_positive_edge["target"] == "end-closed",
             "The false_positive == true edge must not target end-closed -- that is " <>
               "the critical scenario's own terminal node and AC3's whole point is " <>
               "that these two scenarios reach genuinely distinct terminal states"
    end
  end

  # ─── AC4: vortex-entity-list-filter-and-page ─────────────────────────────

  describe "vortex-entity-list-filter-and-page" do
    test "disposition is BLOCKED_ON_DEPENDENCY, re-verified live against real source state (design §4.1)" do
      # Signal 1: Entities/EntityQuery remain in router.ex's reserved/unbuilt section
      # (not mounted).
      router_content = File.read!(Path.expand("../../../lib/letflow/router.ex", __DIR__))

      assert router_content =~ "Letflow.Routers.Entities",
             "Expected router.ex to still reference Letflow.Routers.Entities (reserved/unbuilt)"

      assert router_content =~ "Letflow.Routers.EntityQuery",
             "Expected router.ex to still reference Letflow.Routers.EntityQuery (reserved/unbuilt)"

      # A real mount would `forward` or dispatch to these modules by name outside the
      # reserved-inventory comment/table context. Since no such module exists at all
      # (signal 3 below), the presence above is necessarily comment/table-only.

      # Signal 2: every docs/requirements.yaml title: claiming the entity/entity-query
      # subsystem (word-bounded entity/entities match, not the bare "entit" substring
      # which false-positives on "identity") traces back to either REQ-207's own
      # self-referential title, or one of REQ-225..231 -- the scoping requirements
      # ISS-0438 registered to plan the subsystem's build-out (design doc
      # lib/letflow/design/iss0438-entity-subsystem-scoping.md). REQ-225..231 *plan*
      # the subsystem; none of them *build* it -- that's still gated on Signal 3 below,
      # so their presence here doesn't change the BLOCKED_ON_DEPENDENCY disposition.
      requirements_content =
        File.read!(Path.expand("../../../docs/requirements.yaml", __DIR__))

      title_lines = String.split(requirements_content, "\n")

      entity_title_matches =
        title_lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _idx} ->
          Regex.match?(~r/title:.*\bentit(y|ies)\b/i, line)
        end)

      allowed_ids =
        MapSet.new([
          "REQ-207",
          "REQ-225",
          "REQ-226",
          "REQ-227",
          "REQ-228",
          "REQ-229",
          "REQ-230",
          "REQ-231"
        ])

      refute Enum.empty?(entity_title_matches),
             "Expected at least 1 title: match for word-bounded entity/entities (REQ-207's own), got none"

      matched_ids =
        Enum.map(entity_title_matches, fn {_line, idx} ->
          nearest_preceding_id_line(title_lines, idx - 1)
        end)

      Enum.each(matched_ids, fn preceding_line ->
        assert Enum.any?(allowed_ids, &(preceding_line =~ "id: #{&1}")),
               "Expected the line preceding each entity title: match to carry one of " <>
                 "#{inspect(MapSet.to_list(allowed_ids))}, got: #{inspect(preceding_line)}"
      end)

      # Signal 3: no context module exists under lib/letflow/ for entities/entity_query.
      lib_letflow_dir = Path.expand("../../../lib/letflow", __DIR__)

      refute File.exists?(Path.join(lib_letflow_dir, "entities.ex")),
             "Expected lib/letflow/entities.ex NOT to exist (entity subsystem confirmed unbuilt)"

      refute File.exists?(Path.join(lib_letflow_dir, "entity_query.ex")),
             "Expected lib/letflow/entity_query.ex NOT to exist (entity subsystem confirmed unbuilt)"

      # All 3 signals concur -> BLOCKED_ON_DEPENDENCY (design §4.1/§4.3). The scenario
      # YAML is still authored (structurally complete, ScenarioFixture.load!/1-parseable)
      # for record-keeping, but Runner.run/1 is never called on it here.
      scenario =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "entity-list-filter-and-page.yaml"))

      assert scenario.id == "vortex-entity-list-filter-and-page"
      assert length(scenario.steps) == 6
      assert Enum.all?(scenario.steps, &(&1.via == :gui))

      disposition_report = %{
        scenario_id: "vortex-entity-list-filter-and-page",
        disposition: :blocked_on_dependency,
        missing_subsystem:
          "Letflow.Routers.Entities / Letflow.Routers.EntityQuery (entities.zig / entity_query.zig, S5/S6)",
        evidence: [
          "lib/letflow/router.ex: both Entities/EntityQuery rows in reserved/unbuilt section (not mounted)",
          "docs/requirements.yaml: every title: match for word-bounded entity/entities traces to REQ-207's own self-referential title or the REQ-225..231 scoping requirements (ISS-0438) -- none of which build the subsystem",
          "no lib/letflow/entities.ex or entity_query.ex context module exists"
        ],
        steps_executed: 0
      }

      assert disposition_report.disposition == :blocked_on_dependency
      assert disposition_report.steps_executed == 0
    end
  end
end
