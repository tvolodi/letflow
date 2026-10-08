defmodule Letflow.TemplateBuildReaperTest do
  @moduledoc """
  Regression test for ISS-0941 ("orphaned 'Tenant Template Build (throwaway)' rows
  that `sweep_orphans/2` detects but never deletes"). See
  `lib/letflow/design/iss0941-orphan-tenant-row-reaper.md` §4 for the full
  test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file. Exercises
  `Letflow.TenantSchemaReaper.sweep_template_build_orphans/2` directly against
  real, hand-inserted `tenants`/`tenant_schemas` rows and (where a case needs one)
  a real Postgres schema created via `CREATE SCHEMA`, mirroring
  `test/support/tenant_schema_reaper_test.exs`'s own
  `async: false` + `Sandbox.mode(Letflow.Repo, :auto)` + manual `on_exit/1`
  pattern -- the function under test itself switches `Letflow.Repo` to `:auto`
  mode internally (its own first step), so this file's fixtures must commit for
  real (not inside a rolled-back sandbox transaction) for the sweep to be able to
  see them at all.

  This is its own file, independent of `tenant_schema_reaper_test.exs` and
  `service_catalog_reaper_test.exs` (design doc §2.2/§4), so this coverage is
  attributable to ISS-0941 independently of ISS-0064/ISS-0414's own regression
  files, even though all three exercise the same `Letflow.TenantSchemaReaper`
  module.

  `async: false` for the whole module -- same reason as the other two reaper test
  files: this file forces `Letflow.Repo` into `:auto` mode for real-commit work.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantSchemaReaper
  alias Letflow.Test.FakeInvocationConnection

  @throwaway_display_name "Tenant Template Build (throwaway)"

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant!(display_name) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("iss0941"),
        display_name: display_name
      },
      :disabled
    )
    |> Repo.insert!()
  end

  # Matches test/support/tenant_template.ex's own generate_staging_schema_name/0
  # shape ("tenant_template_build_" <> 32 hex chars) -- the belt-and-suspenders
  # schema_name LIKE scoping sweep_template_build_orphans/2's own query applies.
  defp staging_schema_name do
    "tenant_template_build_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  defp schema_exists?(schema_name) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
        schema_name
      ])

    rows != []
  end

  defp tenant_schemas_row_exists?(id) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM tenant_schemas WHERE id = $1", [Ecto.UUID.dump!(id)])

    rows != []
  end

  defp tenants_row_exists?(id) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM tenants WHERE id = $1", [Ecto.UUID.dump!(id)])
    rows != []
  end

  defp insert_tenant_schemas_row!(tenant_id, schema_name, provisioned_at) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO tenant_schemas (id, tenant_id, schema_name, provisioned_at) " <>
          "VALUES (gen_random_uuid(), $1, $2, $3) RETURNING id",
        [Ecto.UUID.dump!(tenant_id), schema_name, provisioned_at]
      )

    Ecto.UUID.cast!(id)
  end

  defp create_schema!(schema_name) do
    Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{schema_name}"))
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp cleanup_rows!(row_id, tenant_id) do
    Repo.query!("DELETE FROM tenant_schemas WHERE id = $1", [Ecto.UUID.dump!(row_id)])
    Repo.query!("DELETE FROM tenants WHERE id = $1", [Ecto.UUID.dump!(tenant_id)])
  end

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------------
  # (a) Confirmed-orphaned row IS deleted.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 reclaims a confirmed-orphaned row" do
    test "deletes both the tenant_schemas row and the parent tenants row" do
      tenant = insert_tenant!(@throwaway_display_name)
      schema_name = staging_schema_name()
      # Never created -- simulates the schema already having been dropped on a
      # failure path (ISS-0941 design doc §0).

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn -> cleanup_rows!(row_id, tenant.id) end)

      refute schema_exists?(schema_name)
      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)

      assert {:ok, %{deleted: deleted, skipped_schema_present: skipped}} =
               TenantSchemaReaper.sweep_template_build_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert deleted >= 1
      assert is_integer(skipped) and skipped >= 0

      refute tenant_schemas_row_exists?(row_id)
      refute tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # (b) Young row is NOT deleted even though its schema is absent.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 age-threshold guard" do
    test "does not touch a row younger than min_age_seconds" do
      tenant = insert_tenant!(@throwaway_display_name)
      schema_name = staging_schema_name()

      recent_provisioned_at = naive_now()
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, recent_provisioned_at)

      on_exit(fn -> cleanup_rows!(row_id, tenant.id) end)

      assert {:ok, %{deleted: 0, skipped_schema_present: 0}} =
               TenantSchemaReaper.sweep_template_build_orphans(Repo, 300)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # (b2) Old row whose schema is still PRESENT is NOT deleted -- and the schema
  # itself is never dropped by this function.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 schema-present guard" do
    test "leaves a row and its real schema untouched when the schema still exists" do
      tenant = insert_tenant!(@throwaway_display_name)
      schema_name = staging_schema_name()
      create_schema!(schema_name)

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn ->
        drop_schema!(schema_name)
        cleanup_rows!(row_id, tenant.id)
      end)

      assert {:ok, %{deleted: 0, skipped_schema_present: skipped}} =
               TenantSchemaReaper.sweep_template_build_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert skipped >= 1
      assert schema_exists?(schema_name)
      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # (c) A real (non-throwaway) tenant row is never touched, regardless of schema
  # state.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 display_name scoping" do
    test "never touches a row whose parent tenant is not the throwaway template-build tenant" do
      tenant = insert_tenant!("Acme Corp")
      # A schema name that does not even match the belt-and-suspenders LIKE
      # scoping, deliberately -- this row must be excluded by display_name alone.
      schema_name = "tenant_" <> (Ecto.UUID.generate() |> String.replace("-", ""))

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn -> cleanup_rows!(row_id, tenant.id) end)

      refute schema_exists?(schema_name)

      assert {:ok, %{deleted: 0, skipped_schema_present: 0}} =
               TenantSchemaReaper.sweep_template_build_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # (d) Concurrent invocation present -> deferred, no-op.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 concurrent-invocation guard (ISS-0110)" do
    test "defers entirely while another invocation's connection is open, leaving the row untouched" do
      tenant = insert_tenant!(@throwaway_display_name)
      schema_name = staging_schema_name()

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn -> cleanup_rows!(row_id, tenant.id) end)

      fake_tag = "letflow_mixtest_fake#{System.unique_integer([:positive])}"
      # Starts the fake-tagged connection with explicit queue options and blocks until
      # it is really visible in pg_stat_activity under its tag (the sanity check) --
      # otherwise this test could pass for the wrong reason (Q-1037 / GH #2364).
      other_conn = FakeInvocationConnection.start!(fake_tag)

      assert {:deferred, :concurrent_invocation} =
               TenantSchemaReaper.sweep_template_build_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)

      FakeInvocationConnection.stop_and_wait_gone!(other_conn, fake_tag)

      assert {:ok, %{deleted: deleted, skipped_schema_present: _}} =
               TenantSchemaReaper.sweep_template_build_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert deleted >= 1
      refute tenant_schemas_row_exists?(row_id)
      refute tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # (e) Same-TEST_PARALLEL_GROUP sibling connection present -> sweep proceeds.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 sibling test_parallel.sh guard (ISS-0217)" do
    test "proceeds (not deferred) when the other connection shares this invocation's group tag" do
      tenant = insert_tenant!(@throwaway_display_name)
      schema_name = staging_schema_name()

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn -> cleanup_rows!(row_id, tenant.id) end)

      %{rows: [[own_tag]]} = Repo.query!("SHOW application_name")

      sibling_tag =
        case Regex.run(~r/_grp(.+)$/, own_tag) do
          [_, group] -> "letflow_mixtest_sib#{System.unique_integer([:positive])}_grp#{group}"
          nil -> "letflow_mixtest_sib#{System.unique_integer([:positive])}"
        end

      expect_proceed? = own_tag =~ ~r/_grp/

      # Starts the fake-tagged connection with explicit queue options and blocks until
      # it is really visible in pg_stat_activity under its tag (the sanity check) --
      # otherwise this test could pass for the wrong reason (Q-1037 / GH #2364).
      other_conn = FakeInvocationConnection.start!(sibling_tag)

      result = TenantSchemaReaper.sweep_template_build_orphans(Repo, 1)
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      if expect_proceed? do
        assert {:ok, %{deleted: deleted, skipped_schema_present: _}} = result
        assert deleted >= 1
        refute tenant_schemas_row_exists?(row_id)
        refute tenants_row_exists?(tenant.id)
      else
        assert {:deferred, :concurrent_invocation} = result
        assert tenant_schemas_row_exists?(row_id)
        assert tenants_row_exists?(tenant.id)
      end

      FakeInvocationConnection.stop_and_wait_gone!(other_conn, sibling_tag)
    end
  end

  # ---------------------------------------------------------------------------------
  # (f) Outer failure is injected -> {:ok, %{deleted: 0, skipped_schema_present: 0}},
  # never raises.
  # ---------------------------------------------------------------------------------

  describe "sweep_template_build_orphans/2 failure-mode contract" do
    test "never raises -- a repo whose query!/1 always raises returns the zero shape" do
      assert {:ok, %{deleted: 0, skipped_schema_present: 0}} =
               TenantSchemaReaper.sweep_template_build_orphans(
                 Letflow.TemplateBuildReaperTest.BrokenRepo
               )
    end
  end

  defmodule BrokenRepo do
    @moduledoc """
    A deliberately broken "repo" for the failure-mode contract test above.
    Delegates `get_dynamic_repo/0` to the real `Letflow.Repo` so
    `Sandbox.mode/2` (this module's own step 1 and its `after`-block restore)
    still resolves and succeeds against the real, already-started repo --
    isolating the forced failure to exactly the candidate-row query path, which is
    the realistic failure this contract test is meant to prove survives.
    """
    def get_dynamic_repo, do: Letflow.Repo.get_dynamic_repo()
    def query!(_sql), do: raise("boom (BrokenRepo.query!/1, forced for ISS-0941 test)")
    def query!(_sql, _params), do: raise("boom (BrokenRepo.query!/2, forced for ISS-0941 test)")
  end
end
