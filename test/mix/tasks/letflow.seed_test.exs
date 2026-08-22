defmodule Mix.Tasks.Letflow.SeedTest do
  @moduledoc """
  WF-03 regression test for ISS-0276 (GH#546): `mix letflow.seed`
  (`lib/mix/tasks/letflow.seed.ex`), the dev-bootstrap task that provisions the
  `bpm-default` tenant no other code path creates on a fresh dev database.

  Spec: `test/specs/ISS-0276.md` — full acceptance-criteria coverage map and the
  mutation-testing rationale (this is a brand-new module, so the ordinary
  fail-then-pass check is trivially satisfied by `UndefinedFunctionError` and
  proves nothing about whether these tests discriminate a correct
  implementation from a wrong one; see the spec and this run's TEST-DESIGNER
  handoff `result.summary` for the two mutants applied and their measured
  fail counts).

  ## Why real Postgres, `:auto` sandbox mode, not `Letflow.TenantFixture`

  `Mix.Tasks.Letflow.Seed.run/1` calls `Letflow.TenantProvisioning.provision_tenant_schema/1`
  and `replay_migrations/1`, which — like every other test file in this suite that
  exercises real schema provisioning (`test/letflow/tenant_provisioning_event_seed_test.exs`,
  `test/support/tenant_fixture.ex`) — need a second real DB connection
  `Ecto.Adapters.SQL.Sandbox`'s per-test `:manual`/`{:shared, pid}` mode can't hand out.
  This file therefore sets `Sandbox.mode(Letflow.Repo, :auto)` and does its own manual
  `on_exit/1` cleanup (drop the provisioned schema, delete the `Registration` and
  `Tenant` rows), the same pattern those files use, and runs `async: false` for the same
  reason. `Letflow.TenantFixture` is not used here because it inserts a tenant with a
  fixture-generated unique slug — this fix's whole point is a *specific*, hardcoded
  `slug`/`idp_realm_id` (`"bpm-default"`), which the fixture's API has no way to pin.

  ## Why `Seed.run/1` is called directly rather than via `Mix.Task.run("letflow.seed")`

  `Mix.Task.run/1` caches "already ran" per task name for the lifetime of the BEAM
  process, so a second `Mix.Task.run("letflow.seed")` call in the idempotency test would
  silently no-op instead of re-invoking the task's real logic (`Mix.Task.rerun/1` exists
  to bypass this, but calling the module's own `run/1` function directly is simpler, and
  it's a plain function -- not task-run-once-gated). Design §6 leaves this call-style
  choice to TEST-DESIGNER explicitly.

  ## Bootstrap-safety note

  `@attrs`' `slug`/`idp_realm_id` are both the fixed literal `"bpm-default"` (design
  §2) -- not fixture-generated unique values -- so this file's own `setup`/`on_exit`
  proactively clears any pre-existing `bpm-default` tenant before AND after each test,
  making every test self-contained even if a previous run crashed mid-test and left a
  row behind.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Mix.Tasks.Letflow.Seed

  import Ecto.Query

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    cleanup_bpm_default()
    on_exit(fn -> cleanup_bpm_default() end)
    :ok
  end

  defp cleanup_bpm_default do
    case Repo.get_by(Tenant, idp_realm_id: "bpm-default") do
      nil ->
        :ok

      %Tenant{id: tenant_id} ->
        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- fresh-DB run creates the bpm-default tenant row
  # ---------------------------------------------------------------------------------

  describe "AC1 -- run/1 creates the bpm-default tenant row" do
    test "run/1 returns :ok and inserts a tenant with slug and idp_realm_id both bpm-default" do
      assert :ok = Seed.run([])

      assert %Tenant{slug: "bpm-default", idp_realm_id: "bpm-default"} =
               Repo.get_by(Tenant, idp_realm_id: "bpm-default")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- resolve_tenant_by_realm/1 succeeds post-seed, and the tenant is actually
  # usable (schema provisioned + migrated), not just a bare row.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- resolve_tenant_by_realm/1 succeeds post-seed and the schema is usable" do
    test "resolve_tenant_by_realm(\"bpm-default\") resolves the seeded tenant" do
      assert :ok = Seed.run([])

      assert {:ok, %Tenant{} = tenant} = Identity.resolve_tenant_by_realm("bpm-default")
      assert tenant.slug == "bpm-default"
      assert tenant.idp_realm_id == "bpm-default"
    end

    test "the seeded tenant's Postgres schema exists and is migrated (not a bare row)" do
      assert :ok = Seed.run([])

      assert {:ok, tenant} = Identity.resolve_tenant_by_realm("bpm-default")
      assert {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      %{rows: schema_rows} =
        Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
          schema_name
        ])

      assert schema_rows != [], "expected schema #{schema_name} to exist post-seed"

      %{rows: table_rows} =
        Repo.query!(
          "SELECT table_name FROM information_schema.tables " <>
            "WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
          [schema_name]
        )

      table_names = Enum.map(table_rows, fn [name] -> name end)
      # A handful of the tenant-scoped tables replay_migrations/1 is supposed to
      # create -- proves migrations actually ran, not just CREATE SCHEMA.
      assert "users" in table_names
      assert "process_definitions" in table_names
      assert "tasks" in table_names
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- idempotency: a second run does not crash, and does not duplicate the row.
  # ---------------------------------------------------------------------------------

  describe "idempotency -- running the task twice" do
    test "does not crash and leaves exactly one bpm-default tenant" do
      assert :ok = Seed.run([])
      assert :ok = Seed.run([])

      count =
        Repo.aggregate(from(t in Tenant, where: t.idp_realm_id == "bpm-default"), :count)

      assert count == 1

      assert {:ok, %Tenant{slug: "bpm-default"}} =
               Identity.resolve_tenant_by_realm("bpm-default")
    end
  end
end
