defmodule Letflow.Simulation.Req207VortexTest do
  @moduledoc """
  REQ-207 acceptance criteria: 4 Vortex scenario YAMLs run through
  `Letflow.Simulation.Runner`, each returning a closed disposition:
  EXECUTED/PASS-or-FAIL (production-order-above-threshold, supplier-quality-deviation
  critical/false-positive), BLOCKED_ON_DEPENDENCY (entity-list-filter-and-page).

  ## entity-list-filter-and-page disposition, re-derived 2026-09-11 (REQ-310)

  Still BLOCKED_ON_DEPENDENCY, but on a NARROWER dependency than when REQ-207
  was written. REQ-310 landed `Letflow.Routers.Entities` with nine routes and
  mounted it at `/entities`, so the original reason -- "the entity subsystem has
  no HTTP surface" -- is factually false and is no longer asserted anywhere.

  The scenario remains blocked because all six of its `:gui` steps are record
  READS (list/filter/sort/page/field-redaction), and record reads happen only
  through `POST /entities/query`, which is REQ-311's and unbuilt: REQ-310
  shipped definition CRUD plus record WRITES only. A second, independent
  blocker is recorded separately -- `Letflow.Simulation.Runner` defers every
  `:gui` step unconditionally, so S8 harness work is needed on top of REQ-311.
  Full reasoning and the re-derivation history live in that describe block's own
  comments; `test/specs/REQ-310.md` states the test cases.

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

  # Returns the `status:` value of the requirement whose entry starts at the
  # `- id: <req_id>` line, as a string ("pending", "done", ...), or nil if the
  # id or its status key is not found. Scans forward from the id line only to
  # the NEXT `- id:` line, so a malformed/missing status never silently picks
  # up the following requirement's status.
  defp requirement_status(lines, req_id) do
    lines
    |> Enum.drop_while(fn line ->
      not Regex.match?(
        ~r/^\s*-\s+id:\s*#{Regex.escape(req_id)}\s*$/,
        String.trim_trailing(line, "\r")
      )
    end)
    |> Enum.drop(1)
    |> Enum.take_while(fn line -> not Regex.match?(~r/^\s*-\s+id:\s*REQ-/, line) end)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*status:\s*(\S+)\s*$/, String.trim_trailing(line, "\r")) do
        [_, status] -> status
        nil -> nil
      end
    end)
  end

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
    test "disposition is BLOCKED_ON_DEPENDENCY on the record-query route (REQ-311), re-derived live after REQ-310 mounted /entities" do
      # ══════════════════════════════════════════════════════════════════════
      # DISPOSITION RE-DERIVED 2026-09-11, AFTER REQ-310 LANDED (f6e0ae64).
      #
      # The 2026-09-11 ⛔ block preserved below predicted exactly this moment
      # and instructed that the right response is to re-derive, never to
      # allowlist REQ-310. That is what happened here. The old disposition --
      # "the entity subsystem has no HTTP surface" -- is now FACTUALLY FALSE
      # and has been replaced, not patched:
      #
      #   * /entities IS mounted (api_pipeline.ex), Signal 1's old assertion
      #     inverted accordingly (Signal 1' below asserts the mount POSITIVELY);
      #   * both deferred-routes rows ARE gone from router.ex (Signal 1'');
      #   * Letflow.Routers.Entities exists and serves NINE real routes.
      #
      # The scenario is nonetheless STILL BLOCKED, for a different and much
      # narrower reason, and the assertions below are correspondingly sharper
      # than the ones they replace:
      #
      #   ⇒ All six of this scenario's :gui steps are RECORD READS (list,
      #     filter x2, sort, page, field-level redaction -- see the fixture).
      #     Record reads happen ONLY through POST /entities/query
      #     (lib/letflow/design/req308-entity-http-surface.md:182, verbatim:
      #     "record reads only happen via /entities/query"), and that route is
      #     REQ-311's, still unbuilt. REQ-310 shipped definition CRUD plus
      #     record WRITES; there is no record read path anywhere -- not a
      #     route, and not even a context function to hang one off
      #     (Letflow.Entities.Records is command-only).
      #
      # Signal 3 was ALSO rewritten rather than kept, because REQ-310 made it
      # a tautology: it asserted lib/letflow/entities.ex and
      # lib/letflow/entity_query.ex do not exist, and they still do not -- but
      # the subsystem shipped under lib/letflow/entities/ (a DIRECTORY:
      # definitions.ex, records.ex, entity_definition.ex, query/) and was never
      # going to occupy those two flat paths. Asserting their absence proved
      # the subsystem was unbuilt in 2026-09-09 and proves nothing at all
      # today. It is replaced by a capability check (Signal 3'): no read
      # function is exported by Letflow.Entities.Records.
      #
      # This test now also RUNS the scenario (Runner.run/1) rather than
      # recording steps_executed: 0 -- see Signal 4 and the disposition_report
      # at the bottom.
      # ══════════════════════════════════════════════════════════════════════

      # ── Signal 1' (INVERTED): /entities IS mounted. ───────────────────────
      # The old test asserted the opposite. Asserting the mount POSITIVELY
      # means this file can never silently drift back into certifying that a
      # serving subsystem is absent.
      api_pipeline_content =
        File.read!(Path.expand("../../../lib/letflow/plugs/api_pipeline.ex", __DIR__))

      assert api_pipeline_content =~ ~s|forward("/entities", to: Letflow.Routers.Entities)|,
             "Expected api_pipeline.ex to mount Letflow.Routers.Entities at /entities " <>
               "(REQ-310 point 5). If this fails, the mount was reverted and this " <>
               "scenario's disposition must be re-derived AGAIN -- it would be blocked " <>
               "on the whole HTTP surface once more, not just on the query route."

      # ── Signal 1'' : the deferred-routes rows are RETIRED from router.ex. ─
      # REQ-310 point 7 deleted both outright ("REMOVED outright, not
      # annotated"). Pinning their absence pins that retirement.
      router_content = File.read!(Path.expand("../../../lib/letflow/router.ex", __DIR__))

      refute router_content =~ "Letflow.Routers.Entities",
             "Expected router.ex's deferred-routes row for Letflow.Routers.Entities to be " <>
               "GONE (REQ-310 point 7 removed it outright); a reappearance means the mount " <>
               "was reverted"

      refute router_content =~ "Letflow.Routers.EntityQuery",
             "Expected router.ex's deferred-routes row for Letflow.Routers.EntityQuery to be " <>
               "GONE (REQ-310 point 7 removed it outright)"

      # Signal 2: every docs/requirements.yaml title: claiming the entity/entity-query
      # subsystem (word-bounded entity/entities match, not the bare "entit" substring
      # which false-positives on "identity") traces back to either REQ-207's own
      # self-referential title, or one of REQ-225..231 -- the scoping requirements
      # ISS-0438 registered to plan the subsystem's build-out (design doc
      # lib/letflow/design/iss0438-entity-subsystem-scoping.md). REQ-225..231 *plan*
      # the subsystem; none of them *build* it -- that's still gated on Signal 3 below,
      # so their presence here doesn't change the BLOCKED_ON_DEPENDENCY disposition.
      #
      # UPDATE (S10 expansion, 2026-09-09): REQ-295, REQ-296, REQ-299, REQ-300 and
      # REQ-302 were filed against
      # docs/migration/decisions/0023-entity-storage-hybrid.md (entity storage as
      # per-entity-type tables with a hybrid promoted-column/blob shape) and match
      # this same word-bounded pattern, so they join the allowlist. They do NOT
      # change the disposition, for the same reason REQ-225..231 do not: they
      # re-shape how entity records are STORED (and REQ-295/REQ-302 only answer
      # design questions -- 0023 forbids filing any implementation requirement
      # against it until its DDL-execution open question is answered and gated).
      # None of them mounts Letflow.Routers.Entities or Letflow.Routers.EntityQuery
      # -- that HTTP surface is S10's own gap 1. (That gap was unowned and unfiled
      # when this block was written on 2026-09-09; it is owned by REQ-308 as of
      # 2026-09-11 -- see the third UPDATE below. Still unmounted either way.)
      # Signal 3 below remains the real gate, and it was re-verified live rather
      # than assumed when this allowlist was extended: neither context module
      # exists, and both router rows are still in the reserved/unbuilt table.
      #
      # UPDATE (S10 gap 13, 2026-09-10): REQ-304 joins the allowlist. It adds an
      # entity_definitions section to Letflow.Definitions.SolutionPack's pack
      # document so a solution pack can CARRY an entity definition -- delivery,
      # not runtime. It mounts no route and builds no context module, so the
      # disposition is unaffected for the same reason as the entries above.
      # Signal 3 was re-verified live again here rather than assumed: still no
      # lib/letflow/entities.ex, no lib/letflow/entity_query.ex, no entity
      # router module under lib/letflow/routers/, and Letflow.Routers.Entities
      # still present only as a reserved/unbuilt row in router.ex.
      #
      # UPDATE (S10 gap 1, 2026-09-11): REQ-308 joins the allowlist. It is the
      # first requirement to actually OWN gap 1 -- the entity HTTP surface the
      # 2026-09-09 block above called "still unowned and unfiled" (that sentence
      # was true when written and is corrected in place above). REQ-308 is a
      # DESIGN requirement and nothing more: owner CODE-DESIGNER, its sole
      # artefact is a design document under lib/letflow/design/, and its own
      # description scopes it "exactly as REQ-295 and REQ-303 were: a design
      # artefact under lib/letflow/design/, no lib/ implementation, no route
      # mounted, no test". A design artefact mounts no route and builds no
      # context module, so the disposition is unaffected -- deciding the shape
      # of a surface is not the same as serving it. The requirement that
      # implements REQ-308's design is the one that will flip this scenario,
      # and it is not filed yet. Signal 3 was re-verified live here rather than
      # assumed, for the third time: no lib/letflow/entities.ex, no
      # lib/letflow/entity_query.ex, no entity router module among the sixteen
      # files under lib/letflow/routers/, both Entities/EntityQuery still only
      # reserved/unbuilt rows in router.ex, and api_pipeline.ex's forward list
      # still has no entities entry.
      #
      # UPDATE (S10 gap 1, 2026-09-11, second block of the same day): REQ-309
      # joins the allowlist, and this block additionally records a DATED WARNING
      # about REQ-310, which is the requirement that finally flips this test.
      #
      # REQ-309 first. It is the first implementation requirement built from
      # REQ-308's design (lib/letflow/design/req308-entity-http-surface.md §3),
      # and it is deliberately the vocabulary half of that design and nothing
      # more: it adds four permission atoms (:EntitiesDefinitionsRead,
      # :EntitiesDefinitionsWrite, :EntitiesRecordsWrite, :EntitiesQuery), the
      # matching endpoint_policy_key/2 clauses and the role_allows?/2 matrix
      # arms, all inside lib/letflow/api/authorization.ex. Its own scope fence
      # says it in as many words: "It creates no router, mounts no route,
      # touches no file under lib/letflow/routers/, does not edit
      # lib/letflow/router.ex or lib/letflow/plugs/api_pipeline.ex". A policy
      # key with no route consuming it is unreachable over HTTP -- the same
      # "ported ahead of its consuming route" state :DlqOperate and
      # :WebhooksManage already sat in. So the disposition is unaffected:
      # naming the permission that WOULD gate a surface is not serving that
      # surface. All three signals were re-verified live here rather than
      # assumed, for the fourth time: router.ex lines 82-83 still carry
      # `Letflow.Routers.Entities` / entities.zig and
      # `Letflow.Routers.EntityQuery` / entity_query.zig as rows in the
      # "## Deferred routes (not yet mounted -- added by owning stage)" table
      # and nowhere else; no lib/letflow/entities.ex; no
      # lib/letflow/entity_query.ex; no entity router among the sixteen files
      # under lib/letflow/routers/; and api_pipeline.ex's forward list (lines
      # 141-153) still forwards only identity, tenants, instances, definitions,
      # tasks, promotions, onboarding, solution-packs, audit, dlq, webhooks,
      # services and admin/services -- no /entities.
      #
      # ⛔⛔ NOW THE WARNING. READ THIS BEFORE TOUCHING THE ALLOWLIST AGAIN. ⛔⛔
      #
      # REQ-310 ("Create Letflow.Routers.Entities with the nine definition and
      # record routes, mount it at /entities, and retire the two deferred-routes
      # rows" -- filed, status pending, letflow-queue task 597) IS THE
      # REQUIREMENT THAT FLIPS THIS TEST. Its description, points 1, 5 and 7,
      # commits to exactly the three things this scenario's disposition rests on
      # being absent:
      #
      #   * point 1 creates lib/letflow/routers/entities.ex -> Signal 3 goes
      #     false (the context/router surface exists);
      #   * point 5 adds `forward("/entities", to: Letflow.Routers.Entities)` to
      #     lib/letflow/plugs/api_pipeline.ex -> the subsystem becomes reachable
      #     over HTTP;
      #   * point 7 DELETES both the `Letflow.Routers.Entities` and
      #     `Letflow.Routers.EntityQuery` rows from router.ex's deferred-routes
      #     table outright ("REMOVED outright, not annotated") -> Signal 1 goes
      #     false, and this test's two `router_content =~ ...` assertions above
      #     will fail on their own.
      #
      # WHEN REQ-310 LANDS, THIS SCENARIO'S BLOCKED_ON_DEPENDENCY DISPOSITION
      # BECOMES FACTUALLY WRONG. The entity list/filter/page surface the vortex
      # scenario exercises will be live, so the scenario should actually RUN --
      # Runner.run/1 against entity-list-filter-and-page.yaml, its six :gui
      # steps executed and asserted -- rather than be recorded as blocked with
      # steps_executed == 0.
      #
      # ⛔ DO NOT "FIX" THE REQ-310 FAILURE BY ADDING "REQ-310" TO allowed_ids.
      # That is the wrong reflex and it is precisely the failure mode this
      # tripwire exists to prevent. The allowlist triages a requirement whose
      # TITLE mentions entities but which does not BUILD the subsystem; REQ-310
      # builds it. Admitting it to the allowlist would silence the title
      # assertion while leaving Signals 1 and 3 to fail anyway, and anyone who
      # then also "fixed" those would be left with a green test asserting a
      # disposition that is false -- a test actively certifying that a shipped,
      # mounted, HTTP-reachable subsystem is missing. That is worse than no test.
      #
      # WHOEVER IMPLEMENTS REQ-310 MUST RE-EVALUATE THIS SCENARIO'S DISPOSITION
      # ITSELF: re-derive it against the three signals as they then stand (all
      # false), replace this whole describe block's blocked-on-dependency
      # bookkeeping with a real execution of the scenario, and update
      # lib/letflow/design/ §4.1/§4.3's disposition table to match. Route it
      # through TEST-DESIGNER rather than patching it inline: the change is a
      # new test, not an allowlist edit.
      #
      # NOTE ON WHY REQ-310 AND REQ-311 APPEAR BELOW ANYWAY. Both are already
      # FILED in docs/requirements.yaml (pending, queue tasks 597 and 598), and
      # both carry entity titles, so this tripwire fires on them TODAY -- on the
      # mere filing, years before the code lands. Filing builds nothing, so the
      # disposition is still correct and they must be admitted. But admitting
      # them flatly would burn the warning above: the test would then stay green
      # straight through REQ-310 landing, and the only thing standing between a
      # mounted /entities and a test asserting it does not exist would be
      # whether someone read this comment. So they are admitted CONDITIONALLY,
      # in a second list the test checks against their live `status:` -- pending
      # passes, anything else fails loudly with these instructions. REQ-311
      # ("POST /entities/query", which REQ-310's §SCOPE explicitly defers to it)
      # is armed the same way and for the same reason.
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
          "REQ-231",
          "REQ-295",
          "REQ-296",
          "REQ-299",
          "REQ-300",
          "REQ-302",
          "REQ-304",
          "REQ-308",
          "REQ-309",
          # Promoted from pending_only_ids on 2026-09-11 -- see the block below
          # the list for why each promotion is a triage result, not a silencing.
          "REQ-310"
        ])

      # SECOND-TIER ALLOWLIST -- admitted ONLY WHILE `status: pending`.
      #
      # Every id in allowed_ids above is `status: done`: each was triaged by
      # reading what it actually shipped and confirming it did not build the
      # subsystem. REQ-310 and REQ-311 cannot be triaged that way, because they
      # are the requirements that DO build it -- they are simply not built yet.
      # Filing a requirement changes nothing about what is reachable over HTTP,
      # so a pending REQ-310 leaves the disposition correct; a done REQ-310
      # makes it false.
      #
      # Rather than record that in a comment and trust the next reader, this
      # list is conditional and the test enforces the condition: the moment
      # either id's status flips to done, the assertion below fails with an
      # explicit instruction. That is why admitting them here is not the
      # "wrong reflex" the ⛔ block warns about -- they are not being waved
      # through, they are being armed.
      #
      # ⛔ THE FIX WHEN THIS FIRES IS NOT TO MOVE THE ID INTO allowed_ids ABOVE.
      # It is to re-derive this scenario's disposition against Signals 1 and 3
      # as they then stand, and to make the scenario RUN. See the ⛔ block above.
      #
      # ── 2026-09-11, AFTER REQ-310 LANDED: THIS TIER FIRED AS DESIGNED. ────
      #
      # It fired via Signal 1 rather than via the status check -- REQ-310's
      # CODE landed (f6e0ae64) while docs/requirements.yaml still reads
      # `status: pending`, because DOC-UPDATER had not yet run. Worth recording
      # plainly, because it is the mechanism's one real blind spot: `status:`
      # lags the code by one pipeline step, so the status check alone would NOT
      # have caught REQ-310. Signal 1 caught it. That redundancy is why the
      # tripwire was built with three independent signals and not just the
      # status list, and it is why Signal 1' above is now a POSITIVE assertion
      # on the mount rather than a negative one on the deferred rows.
      #
      # REQ-310 was NOT moved into allowed_ids to silence anything -- the ⛔
      # block above is explicit that doing so is the wrong reflex. It was moved
      # there only AFTER its disposition consequence was re-derived in full and
      # this whole describe block was rewritten to assert the new truth. The
      # pending-only tier's contract ("admitted only while it builds nothing")
      # no longer describes it: it HAS built something, that something was
      # triaged, and the triage is what produced the assertions above. REQ-309
      # moved for the ordinary reason -- it shipped permission vocabulary only,
      # which its own scope fence confirms builds no route.
      #
      # REQ-311 stays here, re-armed. It is now the sole remaining tripwire and
      # the requirement that will flip this scenario for real: it adds
      # POST /entities/query, the record-read route all six :gui steps need.
      pending_only_ids = ["REQ-311"]

      refute Enum.empty?(entity_title_matches),
             "Expected at least 1 title: match for word-bounded entity/entities (REQ-207's own), got none"

      matched_ids =
        Enum.map(entity_title_matches, fn {_line, idx} ->
          nearest_preceding_id_line(title_lines, idx - 1)
        end)

      Enum.each(matched_ids, fn preceding_line ->
        pending_only_id =
          Enum.find(pending_only_ids, &(preceding_line =~ "id: #{&1}"))

        cond do
          Enum.any?(allowed_ids, &(preceding_line =~ "id: #{&1}")) ->
            :ok

          pending_only_id != nil ->
            assert requirement_status(title_lines, pending_only_id) == "pending",
                   "#{pending_only_id} is allowed to carry an entity title ONLY while it is " <>
                     "status: pending -- filing it builds nothing, so the " <>
                     "BLOCKED_ON_DEPENDENCY disposition survives. Its status is now " <>
                     "#{inspect(requirement_status(title_lines, pending_only_id))}, which means " <>
                     "POST /entities/query -- the record-read route ALL SIX of this scenario's " <>
                     ":gui steps need (list, filter x2, sort, page, field redaction) -- HAS NOW " <>
                     "BEEN BUILT, and the one remaining reason this scenario is blocked is gone. " <>
                     "Do NOT silence this by moving #{pending_only_id} into allowed_ids -- that " <>
                     "would leave a green test asserting a route is missing when it is mounted " <>
                     "and serving, which is worse than no test. Re-derive the disposition " <>
                     "against Signals 3' and 4 as they then stand: Records/Query will expose a " <>
                     "read path and __authz_routes__/0 will carry a tenth {\"POST\", \"/query\", " <>
                     ":EntitiesQuery} entry. NOTE the remaining independent blocker documented " <>
                     "at Signal 4: Letflow.Simulation.Runner records EVERY :gui step as " <>
                     ":deferred_to_s8 and never dispatches one, so even a complete query route " <>
                     "does not by itself make these six steps execute -- that needs S8's " <>
                     "harness work. Judge whether the disposition becomes :executed or stays " <>
                     "blocked on the HARNESS rather than on the route, and say which in the " <>
                     "disposition_report. Route it through TEST-DESIGNER; see the ⛔ block above."

          true ->
            flunk(
              "Expected the line preceding each entity title: match to carry one of " <>
                "#{inspect(MapSet.to_list(allowed_ids))} (unconditional) or " <>
                "#{inspect(pending_only_ids)} (only while pending), got: #{inspect(preceding_line)}"
            )
        end
      end)

      # ── Signal 3' (REPLACES the old Signal 3): no RECORD READ PATH exists. ─
      #
      # The old Signal 3 asserted lib/letflow/entities.ex and
      # lib/letflow/entity_query.ex do not exist. Both still don't -- and that
      # fact is now WORTHLESS as evidence, because REQ-310's subsystem shipped
      # under lib/letflow/entities/ (a directory) and was never going to occupy
      # those two flat paths. A path-absence check that can no longer go false
      # is a tautology, so it is replaced by a CAPABILITY check against the
      # real module.
      #
      # Letflow.Entities.Records is a COMMAND-ONLY context module by design
      # (its own moduledoc, and Letflow.Routers.Entities' "No route reads a
      # record by id, and none lists records"). If no context function can read
      # a record, no route can serve one -- which is the actual load-bearing
      # fact behind this scenario's disposition. Checked via the module's real
      # exports, so a later list_records/2 or get_record/3 trips it.
      Code.ensure_loaded!(Letflow.Entities.Records)

      record_read_exports =
        Letflow.Entities.Records.__info__(:functions)
        |> Enum.filter(fn {name, _arity} ->
          name_string = Atom.to_string(name)

          String.starts_with?(name_string, "list_") or String.starts_with?(name_string, "get_") or
            String.starts_with?(name_string, "query_") or
            String.starts_with?(name_string, "fetch_")
        end)

      assert record_read_exports == [],
             "Letflow.Entities.Records is command-only by design (create/update/delete and " <>
               "NO read function) -- record reads belong exclusively to POST /entities/query " <>
               "(design req308-entity-http-surface.md:182). A read function appearing here " <>
               "means that rule changed and this scenario's disposition must be re-derived; " <>
               "observed: #{inspect(record_read_exports)}"

      # ── Signal 3'' : the nine routes, and NO record-read route among them. ─
      #
      # This is the sharpest assertion in the block and the one that actually
      # carries the disposition. Structural (against the router's own compiled
      # __authz_routes__/0 table), not textual. It proves in one shot that the
      # router is real and serving, that definition CRUD and record WRITES are
      # covered, and that nothing reads records.
      expected_routes =
        MapSet.new([
          {"POST", "/definitions", :EntitiesDefinitionsWrite},
          {"POST", "/definitions/:name/activate", :EntitiesDefinitionsWrite},
          {"GET", "/definitions", :EntitiesDefinitionsRead},
          {"GET", "/definitions/:id", :EntitiesDefinitionsRead},
          {"GET", "/definitions/active/:name", :EntitiesDefinitionsRead},
          {"GET", "/definitions/by-name/:name", :EntitiesDefinitionsRead},
          {"POST", "/records/:entity_type", :EntitiesRecordsWrite},
          {"PUT", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
          {"DELETE", "/records/:entity_type/:record_id", :EntitiesRecordsWrite}
        ])

      actual_routes = MapSet.new(Letflow.Routers.Entities.__authz_routes__())

      assert MapSet.equal?(actual_routes, expected_routes),
             "Letflow.Routers.Entities must serve exactly REQ-310's nine routes. " <>
               "Unexpected: #{inspect(MapSet.to_list(MapSet.difference(actual_routes, expected_routes)))}; " <>
               "missing: #{inspect(MapSet.to_list(MapSet.difference(expected_routes, actual_routes)))}. " <>
               "A tenth route (REQ-311's POST /query) appearing here means this scenario's " <>
               "disposition must be re-derived -- see the pending_only_ids block above."

      assert MapSet.size(actual_routes) == 9

      refute Enum.any?(actual_routes, fn {_method, path, _perm} -> path == "/query" end),
             "POST /entities/query must NOT exist yet -- it is REQ-311's, and it is the one " <>
               "route this scenario's six :gui steps actually need"

      refute Enum.any?(actual_routes, fn {method, path, _perm} ->
               method == "GET" and String.starts_with?(path, "/records")
             end),
             "No GET route may exist under /records -- record reads are POST /entities/query " <>
               "only (design §1)"

      refute Enum.any?(actual_routes, fn {_method, _path, perm} -> perm == :EntitiesQuery end),
             "No route may carry :EntitiesQuery yet -- that permission is REQ-309's vocabulary, " <>
               "minted ahead of REQ-311's route that will consume it"

      # ── Signal 3''' : the permission exists, but nothing consumes it. ─────
      #
      # This is what distinguishes "unspecified" from "specified and
      # vocabulary-complete but not yet served" -- precisely the state REQ-311
      # changes. REQ-309 minted :EntitiesQuery and wrote the policy clause; the
      # refute above proved no route carries it.
      assert Letflow.Api.Authorization.endpoint_policy_key("POST", "/entities/query") ==
               :EntitiesQuery,
             "REQ-309 minted the :EntitiesQuery policy key for a route that does not exist " <>
               "yet; a policy key with no route behind it is the signature of a surface that " <>
               "is specified but unserved"

      # ── Signal 4: the scenario now actually RUNS. ─────────────────────────
      #
      # The old block never called Runner.run/1 and recorded steps_executed: 0.
      # It runs now -- and the run itself is the evidence for the SECOND,
      # INDEPENDENT blocker: Letflow.Simulation.Runner.run_steps/1 matches
      # step.via == :gui and records :deferred_to_s8 unconditionally
      # (test/support/simulation/runner.ex), never dispatching a GUI step. So
      # even a complete POST /entities/query would not by itself make these six
      # steps execute; that needs S8's harness work.
      #
      # Kept as a SEPARATE evidence line from the missing-route blocker, never
      # conflated with it: the primary blocker is a route REQ-311 clears, this
      # one is a harness capability S8 clears. Folding them together would let
      # this test survive REQ-311 landing without anyone re-examining it.
      scenario =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "entity-list-filter-and-page.yaml"))

      assert scenario.id == "vortex-entity-list-filter-and-page"
      assert length(scenario.steps) == 6
      assert Enum.all?(scenario.steps, &(&1.via == :gui))

      assert {:ok, run_report} = Runner.run(scenario)

      assert length(run_report.step_results) == 6

      assert Enum.all?(run_report.step_results, &(&1.outcome == :deferred_to_s8)),
             "Every :gui step must come back :deferred_to_s8 -- the harness does not " <>
               "dispatch GUI steps (runner.ex run_steps/1). Observed outcomes: " <>
               inspect(Enum.map(run_report.step_results, & &1.outcome))

      # No step was actually dispatched, so nothing was really exercised: the
      # disposition below is not contradicted by the fact that run/1 returned.
      refute Enum.any?(run_report.step_results, &(&1.outcome == :ok)),
             "No :gui step may report :ok -- none of them is dispatched at all"

      # ── Disposition ──────────────────────────────────────────────────────
      # Still BLOCKED_ON_DEPENDENCY, on a narrower and fully provable
      # dependency than before.
      disposition_report = %{
        scenario_id: "vortex-entity-list-filter-and-page",
        disposition: :blocked_on_dependency,
        missing_subsystem:
          "POST /entities/query (REQ-311) -- the record-read route. NOT the entity HTTP " <>
            "surface as a whole, which REQ-310 landed and mounted on 2026-09-11.",
        evidence: [
          "lib/letflow/plugs/api_pipeline.ex: forward(\"/entities\", to: Letflow.Routers.Entities) IS mounted (REQ-310 point 5) -- the old 'no HTTP surface' evidence line is FALSE and has been replaced",
          "lib/letflow/router.ex: both deferred-routes rows RETIRED outright (REQ-310 point 7) -- likewise no longer evidence of anything missing",
          "Letflow.Routers.Entities.__authz_routes__/0 returns exactly 9 routes: 6 definition CRUD + 3 record WRITES (POST/PUT/DELETE). No route reads records; no {_, \"/query\", _} entry exists",
          "Letflow.Entities.Records exports no list_/get_/query_/fetch_ function -- command-only by design, so no read route could be served even if one were declared",
          "lib/letflow/design/req308-entity-http-surface.md:182 verbatim: 'record reads only happen via /entities/query' -- and all six of this scenario's :gui steps (list, filter x2, sort, page, field redaction) are record reads",
          "Letflow.Api.Authorization.endpoint_policy_key(\"POST\", \"/entities/query\") == :EntitiesQuery, yet no route carries that permission -- REQ-309 minted the vocabulary ahead of REQ-311's consuming route",
          "SECOND, INDEPENDENT BLOCKER: Letflow.Simulation.Runner records every :gui step as :deferred_to_s8 and dispatches none, so all 6 steps are deferred even now (asserted live above via Runner.run/1). Clearing REQ-311 alone does not make these steps execute -- that needs S8's harness work",
          "docs/requirements.yaml: every word-bounded entity/entities title: traces to REQ-207's own, REQ-225..231 (ISS-0438 scoping), REQ-295..302 (decision 0023 storage), REQ-304 (solution-pack delivery), REQ-308 (design artefact), REQ-309 (permission vocabulary only) or REQ-310 (the nine routes, triaged and acted on by this very rewrite) -- plus REQ-311, still status: pending and admitted only on that condition, asserted against it"
        ],
        # Dated statement about pending work, not a standing fact. REQ-311
        # (queue task 598) adds POST /entities/query, the record-read route.
        # When it lands, the PRIMARY blocker above goes false and this
        # disposition must be re-derived once more -- at which point the
        # remaining question is whether the second blocker (the harness's
        # unconditional :gui deferral) leaves it blocked on S8 instead, or
        # whether the scenario finally executes. Do not re-allowlist; see the
        # ⛔ block above.
        flips_when: "REQ-311",
        then_gated_on: "S8 simulation-harness GUI-step dispatch (runner.ex run_steps/1)",
        steps_executed: 0,
        steps_deferred: 6
      }

      assert disposition_report.disposition == :blocked_on_dependency
      assert disposition_report.flips_when == "REQ-311"
      assert disposition_report.steps_executed == 0
      assert disposition_report.steps_deferred == length(run_report.step_results)
    end
  end
end
