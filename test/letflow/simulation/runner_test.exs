defmodule Letflow.Simulation.RunnerTest do
  @moduledoc """
  REQ-205 AC4/AC5 (`lib/letflow/design/req205-simulation-harness-foundation.md`
  §3). AC4: `Letflow.Simulation.Runner.run/1` executes a minimal one-step
  api-via scenario end to end against a real running instance (real HTTP through
  `Letflow.Router.call/2`, not a mocked handler) and evaluates at least one
  `instance_state` expected outcome by querying actual instance state
  afterward. AC5: a `via: :gui` step is recorded `:deferred_to_s8`, never
  silently skipped, never executed as if it were an `api` step.

  Real Postgres (`Letflow.DataCase`), `async: false` -- tenant provisioning needs
  `Sandbox.mode(Letflow.Repo, :auto)`, same reasoning as every other
  tenant-provisioning test in this suite.

  Builds a hand-made `%Letflow.Simulation.Scenario{}` directly -- no scenario
  YAML corpus exists yet (REQ-206/207/208's own scope, design §9 OQ-2).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.Scenario
  alias Letflow.Simulation.Seed
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/swiftroute", __DIR__)

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req205-runner")

    company = %{
      "slug" => unique,
      "display_name" => "REQ-205 Runner Test Co",
      "hostname" => unique <> ".simulation.test"
    }

    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    {:ok, org_structure} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "org_structure.yaml"))

    org_structure =
      update_in(org_structure["people"], fn people ->
        Enum.map(people, fn person -> Map.update!(person, "username", &(&1 <> "-" <> unique)) end)
      end)

    {:ok, [operator | _rest]} = Seed.seed_users(org_structure, tenant)

    {:ok, process_fixture} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "process_route_approval.yaml"))

    process_fixture = Map.update!(process_fixture, "name", &(&1 <> "-" <> unique))

    {:ok, definition} = Seed.seed_process(process_fixture, tenant, operator.id)

    {:ok, %{token: _token, plaintext: plaintext}} =
      Identity.create_token(operator.id, %{roles: ["PLATFORM_ADMIN"]}, prefix: schema_name)

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      definition: definition,
      actor: %{"token" => plaintext, "tenant_slug" => unique}
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

  test "AC4: a minimal one-step api-via scenario runs real HTTP and verifies instance_state", %{
    schema_name: schema_name,
    definition: definition,
    actor: actor
  } do
    scenario = %Scenario{
      id: "req205-smoke-start-instance",
      company_id: "swiftroute",
      process_id: definition.name,
      actors: %{"operator" => actor},
      preconditions: [
        %{check: :process_definition_active, args: %{"name" => definition.name}}
      ],
      steps: [
        %{
          via: :api,
          action: "POST /api/v1/instances",
          params: %{"definition_name" => definition.name, "initial_variables" => %{}},
          produces: "instance",
          actor: "operator"
        }
      ],
      expected_outcomes: [
        %{
          verification: %{
            method: :instance_state,
            args: %{
              "prefix" => schema_name,
              "instance_ref" => "{{produces.instance.instance_id}}",
              # Real R-Co process pauses at HUMAN_TASK, instance is ACTIVE not COMPLETED
              "status" => "ACTIVE"
            }
          }
        }
      ]
    }

    assert {:ok, report} = Runner.run(scenario)

    assert [%{outcome: :ok}] = report.precondition_results
    assert [%{outcome: :ok, captured: captured}] = report.step_results
    assert %{"instance_id" => _id, "status" => "ACTIVE"} = captured

    assert [%{outcome: :pass, observed: observed}] = report.outcome_results
    assert observed.status == "ACTIVE"
  end

  test "AC5: a via: gui step is recorded DEFERRED_TO_S8, never run, never dropped", %{
    schema_name: schema_name,
    definition: definition,
    actor: actor
  } do
    scenario = %Scenario{
      id: "req205-smoke-gui-deferral",
      company_id: "swiftroute",
      process_id: definition.name,
      actors: %{"operator" => actor},
      preconditions: [],
      steps: [
        %{via: :gui, action: "click submit button", actor: "operator"},
        %{
          via: :api,
          action: "POST /api/v1/instances",
          params: %{"definition_name" => definition.name, "initial_variables" => %{}},
          produces: "instance",
          actor: "operator"
        }
      ],
      expected_outcomes: [
        %{
          verification: %{
            method: :instance_state,
            args: %{
              "prefix" => schema_name,
              "instance_ref" => "{{produces.instance.instance_id}}",
              # Real R-Co process pauses at HUMAN_TASK, instance is ACTIVE not COMPLETED
              "status" => "ACTIVE"
            }
          }
        }
      ]
    }

    assert {:ok, report} = Runner.run(scenario)

    assert length(report.step_results) == 2

    assert [gui_result, api_result] = report.step_results
    assert gui_result.outcome == :deferred_to_s8
    assert gui_result.captured == nil
    assert gui_result.detail =~ "S8"

    assert api_result.outcome == :ok
  end
end
