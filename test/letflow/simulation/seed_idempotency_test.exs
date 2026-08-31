defmodule Letflow.Simulation.SeedIdempotencyTest do
  @moduledoc """
  REQ-205 AC3 (`lib/letflow/design/req205-simulation-harness-foundation.md` §2.5):
  seeding the same company twice in one test run is a no-op the second time, one
  explicit test per entity kind (tenant, user, group, definition) -- a direct DB
  row-count assertion, not an inference from "no error was raised."

  Uses `Letflow.DataCase` + real Postgres (tenant provisioning needs
  `Sandbox.mode(Letflow.Repo, :auto)`, same reasoning as
  `test/letflow/routers/tenants_test.exs`) -- `async: false`.

  Loads the swiftroute fixture but overrides `slug`/`hostname`/`username`s to
  unique per-test values (`Letflow.TenantSlugFixture.unique_slug/1`) so this test
  is isolated from every other test seeding the same synthetic fixture data.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.Simulation.Seed
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/swiftroute", __DIR__)

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req205-seed")

    company = %{
      "slug" => unique,
      "display_name" => "REQ-205 Seed Test Co",
      "hostname" => unique <> ".simulation.test"
    }

    {:ok, org_structure} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "org_structure.yaml"))

    org_structure =
      update_in(org_structure["people"], fn people ->
        Enum.map(people, fn person ->
          Map.update!(person, "username", &(&1 <> "-" <> unique))
        end)
      end)

    {:ok, process_fixture} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "process_route_approval.yaml"))

    process_fixture = Map.update!(process_fixture, "name", &(&1 <> "-" <> unique))

    on_exit(fn -> teardown(unique) end)

    %{
      company: company,
      org_structure: org_structure,
      process_fixture: process_fixture,
      slug: unique
    }
  end

  defp teardown(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} ->
            Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

          {:error, _reason} ->
            :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))

      {:error, :not_found} ->
        :ok
    end
  end

  test "tenant: seeding the same company twice is a no-op", %{company: company} do
    assert {:ok, %{tenant: tenant1}} = Seed.seed_company(company)
    assert {:ok, %{tenant: tenant2}} = Seed.seed_company(company)

    assert tenant1.id == tenant2.id

    count = Repo.aggregate(from(t in Tenant, where: t.slug == ^company["slug"]), :count)
    assert count == 1
  end

  test "user: seeding the same org_structure twice is a no-op", %{
    company: company,
    org_structure: org_structure
  } do
    {:ok, %{tenant: tenant}} = Seed.seed_company(company)

    assert {:ok, users1} = Seed.seed_users(org_structure, tenant)
    assert {:ok, users2} = Seed.seed_users(org_structure, tenant)

    assert Enum.map(users1, & &1.id) == Enum.map(users2, & &1.id)

    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)
    [first_person | _rest] = org_structure["people"]
    username = first_person["username"]

    count =
      Repo.aggregate(from(u in User, where: u.username == ^username), :count, prefix: schema_name)

    assert count == 1
  end

  test "group: seeding the same org_structure twice is a no-op", %{
    company: company,
    org_structure: org_structure
  } do
    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, _users} = Seed.seed_users(org_structure, tenant)

    assert {:ok, groups1} = Seed.seed_groups(org_structure, tenant)
    assert {:ok, groups2} = Seed.seed_groups(org_structure, tenant)

    assert Enum.map(groups1, & &1.id) == Enum.map(groups2, & &1.id)

    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)
    [first_group | _rest] = org_structure["groups"]
    name = first_group["name"]

    count = Repo.aggregate(from(g in Group, where: g.name == ^name), :count, prefix: schema_name)
    assert count == 1
  end

  test "definition: seeding the same process fixture twice is a no-op", %{
    company: company,
    org_structure: org_structure,
    process_fixture: process_fixture
  } do
    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, [first_user | _rest]} = Seed.seed_users(org_structure, tenant)

    assert {:ok, definition1} = Seed.seed_process(process_fixture, tenant, first_user.id)
    assert {:ok, definition2} = Seed.seed_process(process_fixture, tenant, first_user.id)

    assert definition1.id == definition2.id

    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)
    name = process_fixture["name"]

    count =
      Repo.aggregate(
        from(d in ProcessDefinition, where: d.name == ^name),
        :count,
        prefix: schema_name
      )

    assert count == 1
  end
end
