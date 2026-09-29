defmodule Letflow.Identity.RoleBackfillTest do
  @moduledoc """
  Tests for `Letflow.Identity.RoleBackfill` (ISS-0886) — see
  `docs/issues/ISS-0886.yaml` for the full root-cause writeup and
  `lib/letflow/design/iss0886-role-backfill-preexisting-tenants.md` §4 for
  the acceptance-criteria-to-test-case mapping this file implements.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database
  anywhere in this file. Provisions real tenant schemas via
  `Letflow.TenantFixture.provisioned_tenant!/1` (ISS-0112/GH#366's current
  convention — every explicit `Repo` call below carries its own `prefix:`,
  matching that fixture's established usage across the codebase, e.g.
  `test/letflow/engine_dlq_landing_test.exs`, `test/letflow/audit_test.exs`).
  This is a deliberate, non-behavioral deviation from the design doc's own
  §4 sketch, which mirrors the OLDER, more verbose `SET search_path`-based
  fixture `test/letflow/role_registry_test.exs` still carries (predates
  `Letflow.TenantFixture`'s introduction) — the design's own moduledoc calls
  that older shape out as one of "39 copy-paste fixture sites" earmarked for
  eventual migration to `TenantFixture`, not the pattern a brand-new test
  file should adopt today.

  `async: false`: `Letflow.TenantFixture.provisioned_tenant!/1` runs
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (real, committed
  Postgres state, not a rolled-back sandbox transaction) — matches every
  other test file in this codebase that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # ---------------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------------

  # Provisions a fresh tenant schema and seeds ONLY PLATFORM_ADMIN into it,
  # simulating a tenant provisioned before ISS-0778 shipped (design §4's
  # `platform_admin_only_tenant_fixture!/0`).
  defp platform_admin_only_tenant_fixture!(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "ISS-0886 PLATFORM_ADMIN-only fixture"
      )

    {:ok, %Group{id: group_id}} =
      RoleRegistry.get_or_create_group_by_name("PLATFORM_ADMIN", prefix: schema_name)

    {:ok, _role} =
      RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group_id, prefix: schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "iss0886-user-#{System.unique_integer([:positive, :monotonic])}",
      display_name: "ISS-0886 Test User",
      email: "iss0886-#{System.unique_integer([:positive, :monotonic])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Binds a user to the Group backing a given platform-role name within a given
  # tenant schema (design §4's `bind_user_to_platform_role!/3`). Assumes the
  # role's Group already exists (i.e. is called post-backfill).
  defp bind_user_to_platform_role!(user, role_name, schema_name) do
    %TenantRole{group_id: group_id} =
      Repo.get_by(TenantRole, [name: role_name], prefix: schema_name)

    {:ok, _} = Identity.add_group_member(group_id, user.id, prefix: schema_name)
    :ok
  end

  defp platform_role_names(schema_name) do
    TenantRole
    |> Ecto.Query.where(kind: :platform_role)
    |> Repo.all(prefix: schema_name)
    |> Enum.map(& &1.name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 (issue fail-first)
  # ---------------------------------------------------------------------------------

  describe "pre-backfill fail-first (AC1)" do
    test "a TASK_WORKER/CANDIDATE-claimed token resolves ZERO effective roles on a PLATFORM_ADMIN-only tenant, before any backfill runs" do
      %{schema_name: schema_name} = platform_admin_only_tenant_fixture!("iss0886-ac1")
      user = insert_user!(schema_name)

      # No TASK_WORKER group/role exists on this tenant yet (only PLATFORM_ADMIN
      # was seeded) -- there is nothing for a claimed TASK_WORKER/CANDIDATE role
      # to bind this user to, so list_effective_role_names/2 reads back empty,
      # reproducing the issue's own "roles: []" symptom for a non-admin user.
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == []

      # Confirms this genuinely is the pre-ISS-0778-shaped tenant the fixture
      # claims: exactly one platform-role binding exists (PLATFORM_ADMIN), not
      # all six.
      assert platform_role_names(schema_name) == ["PLATFORM_ADMIN"]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: run/0 seeds the five missing platform roles
  # ---------------------------------------------------------------------------------

  describe "run/0 seeds the five missing platform roles for a PLATFORM_ADMIN-only tenant (AC2)" do
    test "converges the tenant to all six platform-role tenant_role rows, and the tenant_id appears under :seeded" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        platform_admin_only_tenant_fixture!("iss0886-ac2")

      assert {:ok, %{seeded: seeded, unchanged: _unchanged}} = RoleBackfill.run()

      assert tenant_id in seeded

      expected_names = Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
      assert Enum.sort(platform_role_names(schema_name)) == Enum.sort(expected_names)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: post-backfill effective-role resolution (the issue's core regression assertion)
  # ---------------------------------------------------------------------------------

  describe "post-backfill: a user bound to the newly-seeded TASK_WORKER group resolves non-empty effective roles (AC3)" do
    test "list_effective_role_names/2 returns [\"TASK_WORKER\"] for a user bound after the backfill runs" do
      %{schema_name: schema_name} = platform_admin_only_tenant_fixture!("iss0886-ac3")
      user = insert_user!(schema_name)

      assert {:ok, _} = RoleBackfill.run()

      bind_user_to_platform_role!(user, "TASK_WORKER", schema_name)

      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == ["TASK_WORKER"]
    end
  end

  # ---------------------------------------------------------------------------------
  # Idempotency
  # ---------------------------------------------------------------------------------

  describe "run/0 is idempotent" do
    test "a second call reports the same tenant under :unchanged and writes no duplicate rows" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        platform_admin_only_tenant_fixture!("iss0886-idem")

      assert {:ok, %{seeded: seeded_first}} = RoleBackfill.run()
      assert tenant_id in seeded_first

      assert {:ok, %{seeded: seeded_second, unchanged: unchanged_second}} = RoleBackfill.run()

      refute tenant_id in seeded_second
      assert tenant_id in unchanged_second

      assert Repo.aggregate(Group, :count, prefix: schema_name) == 6
      assert Repo.aggregate(TenantRole, :count, prefix: schema_name) == 6
    end
  end

  # ---------------------------------------------------------------------------------
  # Already-fully-seeded tenant is a no-op
  # ---------------------------------------------------------------------------------

  describe "run/0 against an already-fully-seeded tenant (normal onboarding path)" do
    test "reports the tenant under :unchanged, with zero writes" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0886-fullyseeded",
          display_name: "ISS-0886 fully-seeded fixture"
        )

      # Mirrors TenantOnboarding.provision_and_migrate/1's own onboarding-time
      # call (ISS-0778) -- unchanged, reused as-is.
      assert {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
      assert length(roles) == 6

      assert {:ok, %{seeded: seeded, unchanged: unchanged}} = RoleBackfill.run()

      refute tenant_id in seeded
      assert tenant_id in unchanged

      assert Repo.aggregate(Group, :count, prefix: schema_name) == 6
      assert Repo.aggregate(TenantRole, :count, prefix: schema_name) == 6
    end
  end

  # ---------------------------------------------------------------------------------
  # Multi-tenant isolation
  # ---------------------------------------------------------------------------------

  describe "run/0 processes every tenant independently" do
    test "backfilling tenant A does not affect tenant B's own tenant_role rows" do
      %{tenant_id: tenant_id_a, schema_name: schema_a} =
        platform_admin_only_tenant_fixture!("iss0886-multi-a")

      %{tenant_id: tenant_id_b, schema_name: schema_b} =
        platform_admin_only_tenant_fixture!("iss0886-multi-b")

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()

      assert tenant_id_a in seeded
      assert tenant_id_b in seeded

      expected_names = Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
      assert Enum.sort(platform_role_names(schema_a)) == Enum.sort(expected_names)
      assert Enum.sort(platform_role_names(schema_b)) == Enum.sort(expected_names)

      # Tenant A's six Group ids are distinct from tenant B's six Group ids --
      # proves the sweep created independent bindings per tenant schema, not
      # one shared set accidentally reused across both.
      group_ids_a = Repo.all(Group, prefix: schema_a) |> Enum.map(& &1.id) |> MapSet.new()
      group_ids_b = Repo.all(Group, prefix: schema_b) |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.disjoint?(group_ids_a, group_ids_b)
    end
  end

  # ---------------------------------------------------------------------------------
  # Hard-failure propagation
  # ---------------------------------------------------------------------------------

  describe "run/0 halts on a hard per-tenant failure" do
    test "a tenant whose physical schema vanished mid-sweep halts the sweep with {:error, {:backfill_failed, tenant_id, reason}}, not a crash" do
      %{tenant_id: vanished_tenant_id, schema_name: vanished_schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0886-vanished",
          display_name: "ISS-0886 vanished-schema fixture",
          teardown: false
        )

      # Registered BEFORE the schema drop below, and BEFORE either assertion,
      # so this tenant's Registration/Tenant rows are reliably cleaned up even
      # if an assertion below fails -- teardown: false above means
      # TenantFixture's own on_exit does not run this cleanup for us (its
      # normal DROP SCHEMA path would be a no-op here anyway, since the schema
      # is deliberately dropped by this test itself first). Guarding against
      # this test leaving a permanently "vanished-schema" Registration row
      # behind to poison every later RoleBackfill.run() call in this suite
      # (a real failure mode hit once already during this file's own
      # development -- see docs/anti-patterns.md-worthy lesson: a manual
      # cleanup statement placed AFTER an assertion never runs if that
      # assertion fails).
      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

        Repo.delete_all(
          from(r in TenantProvisioning.Registration, where: r.tenant_id == ^vanished_tenant_id)
        )

        Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^vanished_tenant_id))
      end)

      # Drop the physical schema WITHOUT deleting the Registration row --
      # exactly the "Registration present, schema absent" window
      # test/letflow/tenant_provisioning/backfill_test.exs's own ISS-0343
      # regression test constructs the identical way.
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{vanished_schema_name}" CASCADE))

      assert {:error, {:backfill_failed, ^vanished_tenant_id, _reason}} = RoleBackfill.run()

      # Direct, tenant_id-scoped confirmation that this test genuinely
      # exercised the vanished-schema window (not some other failure mode):
      # the Registration row is still present, only the physical schema is
      # gone.
      assert %TenantProvisioning.Registration{} =
               Repo.get_by(TenantProvisioning.Registration, tenant_id: vanished_tenant_id)
    end
  end
end
