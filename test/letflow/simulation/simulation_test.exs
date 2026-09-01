defmodule Letflow.SimulationTest do
  @moduledoc """
  Tests for REQ-205: S7 scenario-harness foundation.

  Verifies that:
  - All 12 fixture files are present with unchanged R-Co actor_id values (AC-1)
  - Letflow.Simulation.Seed provisions tenant, users, groups, and process
    definitions by calling Letflow's own context modules directly (AC-2)
  - Seeding the same company twice is idempotent (AC-3)
  - Letflow.Simulation.Runner executes a minimal one-step api-via scenario
    end to end (real HTTP, real DB state) (AC-4)
  - A gui-via step is recorded as DEFERRED_TO_S8, not silently skipped (AC-5)

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture`'s
  provisioning pattern. `async: false` because tenant provisioning requires
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Identity
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.Seed

  # Fixture files live at test/fixtures/simulation/
  @fixtures_dir Path.expand("../../fixtures/simulation", __DIR__)

  # ── AC-1: fixture files exist with correct actor_ids ─────────────────────

  describe "fixture files (AC-1)" do
    test "all 12 company/org/process YAML files exist under test/fixtures/simulation/" do
      expected = [
        {"swiftroute", "company.yaml"},
        {"swiftroute", "org_structure.yaml"},
        {"swiftroute", "process_shipment_approval.yaml"},
        {"swiftroute", "process_incident_report.yaml"},
        {"vortex", "company.yaml"},
        {"vortex", "org_structure.yaml"},
        {"vortex", "process_production_order_release.yaml"},
        {"vortex", "process_supplier_quality_deviation.yaml"},
        {"meridian", "company.yaml"},
        {"meridian", "org_structure.yaml"},
        {"meridian", "process_loan_origination.yaml"},
        {"meridian", "process_regulatory_compliance_review.yaml"}
      ]

      for {company, file} <- expected do
        path = Path.join([@fixtures_dir, company, file])

        assert File.exists?(path),
               "Expected fixture file to exist: #{path}"
      end
    end

    test "swiftroute org_structure.yaml contains R-Co actor_ids unchanged" do
      path = Path.join([@fixtures_dir, "swiftroute", "org_structure.yaml"])
      {:ok, org} = YamlElixir.read_from_file(path)
      actor_ids = Enum.map(org["people"], & &1["actor_id"])

      assert "actor-swiftroute-alice" in actor_ids
      assert "actor-swiftroute-marco" in actor_ids
      assert "actor-swiftroute-lena" in actor_ids
      assert "actor-swiftroute-tobias" in actor_ids
      assert "actor-swiftroute-jan" in actor_ids
      assert "actor-swiftroute-petra" in actor_ids
      assert "actor-swiftroute-hans" in actor_ids
    end

    test "vortex org_structure.yaml contains R-Co actor_ids unchanged" do
      path = Path.join([@fixtures_dir, "vortex", "org_structure.yaml"])
      {:ok, org} = YamlElixir.read_from_file(path)
      actor_ids = Enum.map(org["people"], & &1["actor_id"])

      assert "actor-vortex-dirk" in actor_ids
      assert "actor-vortex-sabine" in actor_ids
      assert "actor-vortex-karl" in actor_ids
      assert "actor-vortex-anna" in actor_ids
    end

    test "meridian org_structure.yaml contains R-Co actor_ids unchanged" do
      path = Path.join([@fixtures_dir, "meridian", "org_structure.yaml"])
      {:ok, org} = YamlElixir.read_from_file(path)
      actor_ids = Enum.map(org["people"], & &1["actor_id"])

      assert "actor-meridian-eva" in actor_ids
      assert "actor-meridian-thomas" in actor_ids
      assert "actor-meridian-julia" in actor_ids
      assert "actor-meridian-claudia" in actor_ids
    end
  end

  # ── AC-2: Seed provisions all three companies via Letflow context modules ─

  describe "Seed.seed_company/1 (AC-2)" do
    test "provisions the swiftroute tenant and returns schema_name" do
      assert {:ok, %{tenant_id: tenant_id, schema_name: schema_name}} =
               Seed.seed_company("swiftroute")

      assert is_binary(tenant_id)
      assert String.starts_with?(schema_name, "tenant_")

      # Verify Letflow.Identity can find the tenant by slug
      assert {:ok, tenant} = Identity.get_tenant_by_slug("swiftroute")
      assert tenant.id == tenant_id
      assert tenant.display_name == "SwiftRoute Ltd"
    end
  end

  describe "Seed.seed_users/2 (AC-2)" do
    setup do
      {:ok, company} = Seed.seed_company("swiftroute")
      {:ok, company: company}
    end

    test "creates users and returns actor_id → user_id map", %{company: company} do
      assert {:ok, actors} = Seed.seed_users("swiftroute", company.schema_name)

      # Seven people in swiftroute
      assert map_size(actors) == 7
      assert Map.has_key?(actors, "actor-swiftroute-alice")
      assert Map.has_key?(actors, "actor-swiftroute-lena")

      # Verify users actually exist in Letflow.Identity
      alice_id = actors["actor-swiftroute-alice"]
      assert {:ok, _alice} = Identity.get_user(alice_id, prefix: company.schema_name)
    end
  end

  describe "Seed.seed_groups/2 (AC-2)" do
    setup do
      {:ok, company} = Seed.seed_company("swiftroute")
      {:ok, actors} = Seed.seed_users("swiftroute", company.schema_name)
      {:ok, company: company, actors: actors}
    end

    test "creates groups for departments and adds members", %{company: company, actors: actors} do
      assert {:ok, groups} = Seed.seed_groups("swiftroute", company.schema_name, actors)

      # Four departments in swiftroute
      assert map_size(groups) >= 4
      assert Map.has_key?(groups, "dept-mgmt")
      assert Map.has_key?(groups, "dept-ops")

      # Verify groups exist via Identity.list_groups/1
      assert {:ok, %{groups: group_list}} = Identity.list_groups(prefix: company.schema_name)
      group_names = Enum.map(group_list, & &1.name)
      assert "dept-mgmt" in group_names
    end
  end

  describe "Seed.seed_processes/2 (AC-2)" do
    setup do
      {:ok, company} = Seed.seed_company("swiftroute")
      {:ok, company: company}
    end

    test "creates and activates all swiftroute process definitions", %{company: company} do
      assert {:ok, definitions} = Seed.seed_processes("swiftroute", company.schema_name)

      # Two process definitions for swiftroute
      assert length(definitions) == 2

      # Verify via Letflow.Definitions
      assert {:ok, stored} = Definitions.list(%{}, [prefix: company.schema_name])
      assert length(stored) >= 2

      names = Enum.map(stored, & &1.name)
      assert "Shipment Approval" in names
      assert "Driver Incident Report" in names

      # All returned definitions should be active
      for d <- definitions do
        assert d.status == :active
      end
    end
  end

  # ── AC-3: seeding twice is idempotent ─────────────────────────────────────

  describe "Seed idempotency (AC-3)" do
    setup do
      {:ok, company} = Seed.seed_company("swiftroute")
      {:ok, actors} = Seed.seed_users("swiftroute", company.schema_name)
      {:ok, company: company, actors: actors}
    end

    test "seed_company/1 twice returns ok (no error, no duplicate tenant)" do
      assert {:ok, _} = Seed.seed_company("swiftroute")
      assert {:ok, _} = Seed.seed_company("swiftroute")

      # Still exactly one tenant with slug swiftroute
      assert {:ok, %{tenants: tenants}} =
               Identity.list_tenants(%{search: "swiftroute", page_size: 10})

      assert length(Enum.filter(tenants, &(&1.slug == "swiftroute"))) == 1
    end

    test "seed_users/2 twice — no duplicate users, no error", %{company: company} do
      assert {:ok, actors1} = Seed.seed_users("swiftroute", company.schema_name)
      assert {:ok, actors2} = Seed.seed_users("swiftroute", company.schema_name)

      # Same user IDs returned both times
      assert actors1 == actors2

      # Still exactly 7 users
      assert {:ok, %{users: users}} =
               Identity.list_users(%{page_size: 50}, prefix: company.schema_name)

      assert length(users) == 7
    end

    test "seed_groups/2 twice — no duplicate groups, no error", %{
      company: company,
      actors: actors
    } do
      assert {:ok, _groups1} = Seed.seed_groups("swiftroute", company.schema_name, actors)
      assert {:ok, _groups2} = Seed.seed_groups("swiftroute", company.schema_name, actors)

      # Still exactly 4 groups (one per department)
      assert {:ok, %{groups: groups}} = Identity.list_groups(prefix: company.schema_name)
      assert length(groups) == 4
    end

    test "seed_processes/2 twice — no duplicate definitions, no error", %{company: company} do
      assert {:ok, defs1} = Seed.seed_processes("swiftroute", company.schema_name)
      assert {:ok, defs2} = Seed.seed_processes("swiftroute", company.schema_name)

      # Both calls return the same 2 definitions (second call looks up existing)
      assert length(defs1) == 2
      assert length(defs2) == 2
      assert Enum.map(defs1, & &1.id) == Enum.map(defs2, & &1.id)

      # Still exactly 2 definitions
      assert {:ok, stored} = Definitions.list(%{}, [prefix: company.schema_name])
      assert length(stored) == 2
    end
  end

  # ── AC-4: Runner executes a minimal one-step api-via scenario ─────────────

  describe "Runner.run/2 with api-via step (AC-4)" do
    setup do
      # Provision a tenant and seed swiftroute
      {:ok, company} = Seed.seed_company("swiftroute")
      {:ok, actors} = Seed.seed_users("swiftroute", company.schema_name)
      {:ok, _groups} = Seed.seed_groups("swiftroute", company.schema_name, actors)
      {:ok, defs} = Seed.seed_processes("swiftroute", company.schema_name)

      # Find the Shipment Approval definition id
      definition = Enum.find(defs, &(&1.name == "Shipment Approval"))

      # Resolve alice's user_id (the CEO / process owner)
      alice_user_id = actors["actor-swiftroute-alice"]

      tenant_context = %{
        tenant_id: company.tenant_id,
        schema_name: company.schema_name,
        user_id: alice_user_id,
        roles: ["PROCESS_OPERATOR"]
      }

      {:ok,
       company: company,
       actors: actors,
       definition: definition,
       tenant_context: tenant_context}
    end

    test "creates an instance and verifies instance_state via real DB query", %{
      definition: definition,
      tenant_context: tenant_context
    } do
      scenario = %{
        id: "test-scenario-shipment-minimal",
        company_id: "swiftroute",
        process_id: "Shipment Approval",
        actors: %{},
        preconditions: [
          %{check: "process_definition_active", process_id: "Shipment Approval"}
        ],
        steps: [
          %{
            id: "s1",
            via: "api",
            action: "create_instance",
            params: %{
              "definition_id" => definition.id,
              "initial_variables" => %{
                "shipment_id" => "ship-001",
                "destination" => "Munich",
                "declared_value" => 250,
                "cargo_type" => "standard",
                "requesting_actor_id" => tenant_context.user_id
              }
            }
          }
        ],
        expected_outcomes: [
          %{method: "instance_state", expected: "active"}
        ]
      }

      assert {:ok, result} = Runner.run(scenario, tenant_context)

      assert result.scenario_id == "test-scenario-shipment-minimal"
      assert length(result.step_results) == 1

      [step] = result.step_results
      assert step.via == "api"
      assert step.outcome == :pass, "create_instance step failed: #{inspect(step.evidence)}"

      # At least one expected_outcome should pass (instance_state == "active")
      assert [outcome] = result.expected_outcome_results
      assert outcome.method == "instance_state"
      assert outcome.outcome == :pass,
             "instance_state outcome: #{inspect(outcome.evidence)}"
    end
  end

  # ── AC-5: gui step is recorded as DEFERRED_TO_S8 ─────────────────────────

  describe "Runner gui step handling (AC-5)" do
    setup do
      {:ok, company} = Seed.seed_company("swiftroute")
      {:ok, actors} = Seed.seed_users("swiftroute", company.schema_name)
      {:ok, defs} = Seed.seed_processes("swiftroute", company.schema_name)

      definition = Enum.find(defs, &(&1.name == "Shipment Approval"))
      alice_user_id = actors["actor-swiftroute-alice"]

      tenant_context = %{
        tenant_id: company.tenant_id,
        schema_name: company.schema_name,
        user_id: alice_user_id,
        roles: ["PROCESS_OPERATOR"]
      }

      {:ok, tenant_context: tenant_context, definition: definition}
    end

    test "a gui step is recorded as DEFERRED_TO_S8, never silently skipped", %{
      tenant_context: tenant_context,
      definition: definition
    } do
      scenario = %{
        id: "test-gui-deferred",
        company_id: "swiftroute",
        preconditions: [],
        steps: [
          %{
            id: "s1",
            via: "api",
            action: "create_instance",
            params: %{
              "definition_id" => definition.id,
              "initial_variables" => %{
                "shipment_id" => "ship-gui-test",
                "destination" => "Hamburg",
                "declared_value" => 100,
                "cargo_type" => "standard",
                "requesting_actor_id" => tenant_context.user_id
              }
            }
          },
          %{
            id: "s2",
            via: "gui",
            action: "fill_form",
            params: %{"field" => "ops_decision", "value" => "approve"}
          }
        ],
        expected_outcomes: []
      }

      assert {:ok, result} = Runner.run(scenario, tenant_context)

      assert length(result.step_results) == 2

      [api_step, gui_step] = result.step_results

      assert api_step.via == "api"
      assert api_step.outcome != :deferred_to_s8

      # The gui step must be DEFERRED_TO_S8 — not :skip, not :pass, not absent
      assert gui_step.via == "gui"
      assert gui_step.outcome == :deferred_to_s8,
             "Expected gui step to be :deferred_to_s8, got #{inspect(gui_step.outcome)}"

      # The evidence must carry a note (not silently empty)
      assert is_binary(gui_step.evidence.note)
      assert String.contains?(gui_step.evidence.note, "DEFERRED_TO_S8")
    end
  end
end
