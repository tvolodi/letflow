defmodule Letflow.TenantOnboardingTest do
  @moduledoc """
  Tests for `Letflow.TenantOnboarding` (REQ-076 AC9 — SCOPE EXTENSION, run
  `WF02-REQ076-20260822`, ISS-0230). See `test/specs/REQ-076.md`'s AC9 section for the
  full rationale, and `lib/letflow/design/req076-identity-tokens-roles-onboarding.md`
  §11 for the design.

  Uses `Letflow.DataCase` (real Postgres) but, like
  `test/letflow/tenant_provisioning_test.exs` (which this file follows directly as its
  style precedent), switches `Letflow.Repo` to Sandbox `:auto` mode for the one describe
  block that calls `Ecto.Migrator.run/4` (via `TenantProvisioning.replay_migrations/2`
  and `TenantOnboarding.recover_provisioning/1`) — `Ecto.Migrator` genuinely needs a
  second, independent database connection that DataCase's single-connection sandboxed
  transaction cannot supply (empirically confirmed in `tenant_provisioning_test.exs`'s
  own moduledoc). Real Postgres state is created and is cleaned up explicitly in
  `on_exit/1` rather than relying on transaction rollback.

  `async: false` for the whole module, same reasoning as `tenant_provisioning_test.exs`:
  ExUnit fully drains all `async: true` modules before running any `async: false` module,
  and runs `async: false` modules strictly one at a time — there is no other test's
  sandboxed connection to disturb at the moment this file's `:auto`-mode switch runs.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.TenantOnboarding
  alias Letflow.TenantOnboarding.BrokenMigrationFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # oidc_mode: :disabled -- irrelevant to this file, matches
  # tenant_provisioning_test.exs's own insert_tenant!/0 convention.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req076-ac9"),
        display_name: "REQ-076 AC9 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp registration_count(tenant_id) do
    Registration |> where([r], r.tenant_id == ^tenant_id) |> Repo.aggregate(:count)
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  # NOTE(ISS-0030): describe/test names kept short -- ExUnit's combined
  # "test " <> describe <> " " <> test_name atom is capped at 255 chars (BEAM
  # SystemLimitError). Full rationale lives in test/specs/REQ-076.md's AC9 section.
  describe "AC9: recover_provisioning/1 (ISS-0230)" do
    setup do
      # Ecto.Migrator.run/4 (invoked both by the deliberately-broken replay below and
      # by recover_provisioning/1's own real-manifest replay) needs a second, genuinely
      # independent connection beyond this process's single sandboxed one -- see this
      # file's moduledoc and tenant_provisioning_test.exs's own identical setup for the
      # full empirical justification. Switching to :auto mode here means every Repo call
      # in this describe block is a real, committing call, cleaned up manually below.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      tenant = insert_tenant!()

      on_exit(fn ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} ->
            Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

          {:error, :invalid_tenant_id} ->
            :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)

      %{tenant: tenant}
    end

    test "recovers a half-provisioned tenant and is idempotent on a second call",
         %{tenant: tenant} do
      # 1. Provision the schema for real, then force replay_migrations/2 to fail via
      #    the broken fixture (same forced-failure mechanism
      #    tenant_provisioning_test.exs's own AC3 describe block established: a
      #    migration_source override, never the default manifest).
      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert {:error, {:migration_failed, _exception}} =
               TenantProvisioning.replay_migrations(tenant.id, [{1, BrokenMigrationFixture}])

      # 2. Survival: no rollback -- the tenants row is intact, exactly one
      #    tenant_schemas row exists, and migrations_applied_at is still nil. This is
      #    the exact state WF03-ISS0230-20260822 measured against real Postgres.
      assert %Tenant{} = Repo.get(Tenant, tenant.id)

      assert %Registration{migrations_applied_at: nil} =
               Repo.get_by(Registration, tenant_id: tenant.id)

      assert registration_count(tenant.id) == 1

      # 3. Invoke the AC9 recovery entry point -- real (default) migration manifest,
      #    never the broken fixture (recover_provisioning/1 always converges onto the
      #    real shipped manifest, design §11.2.1 step 2).
      assert {:ok, %Registration{migrations_applied_at: %NaiveDateTime{}}} =
               TenantOnboarding.recover_provisioning(tenant.id)

      # 4. Full convergence: the schema is genuinely migrated (spot-checked via a real
      #    tenant-scoped production table, "users", under the tenant's own schema --
      #    not merely a returned :ok), still exactly one tenant_schemas row, and the
      #    tenant's status flipped to :active (AC10's status-flip step, exercised here
      #    via AC9's own recovery path).
      assert table_exists_in_schema?(schema_name, "users")
      assert registration_count(tenant.id) == 1
      assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)

      # 5. Invoke the SAME entry point a SECOND time, against the now-healthy tenant --
      #    mandatory per AC9's own wording, not optional. Success with unchanged
      #    cardinality (no duplicate schema, no duplicate tenant_schemas row) is what
      #    demonstrates idempotence.
      assert {:ok, %Registration{migrations_applied_at: %NaiveDateTime{}}} =
               TenantOnboarding.recover_provisioning(tenant.id)

      assert registration_count(tenant.id) == 1
      assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)
      assert table_exists_in_schema?(schema_name, "users")
    end
  end
end
