defmodule Letflow.ServiceCatalogReaperTest do
  @moduledoc """
  Regression test for ISS-0414 ("suite-wide safety net against leftover
  `service_catalog` rows"). See
  `lib/letflow/design/iss0414-service-catalog-safety-net.md` §4 for the full
  test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file. Exercises
  `Letflow.TenantSchemaReaper.sweep_service_catalog_orphans/1` directly
  against real, hand-inserted `service_catalog` rows, mirroring
  `test/support/tenant_schema_reaper_test.exs`'s own
  `async: false` + `Sandbox.mode(Letflow.Repo, :auto)` + manual `on_exit/1`
  pattern -- the function under test itself switches `Letflow.Repo` to
  `:auto` mode internally (its own first step), so this file's fixtures must
  commit for real (not inside a rolled-back sandbox transaction) for the
  sweep to be able to see them at all.

  This is its own file, independent of `tenant_schema_reaper_test.exs`
  (design doc §2.2/§4), so this coverage is attributable to ISS-0414
  independently of ISS-0064's own regression file, even though both exercise
  the same `Letflow.TenantSchemaReaper` module.

  `async: false` for the whole module -- same reason as
  `tenant_schema_reaper_test.exs`: this file forces `Letflow.Repo` into
  `:auto` mode for real-commit work.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.TenantSchemaReaper

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp unique_service_id(prefix \\ "iss0414-svc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Lightweight tenant: no schema provisioning, just a real `tenants` row so a
  # `scope: :tenant` row's `owner_tenant_id` FK is satisfiable.
  defp insert_tenant! do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("iss0414-tenant"),
          display_name: "ISS-0414 Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id)) end)

    tenant
  end

  # Follows service_catalog_test.exs's own Entry.insert_changeset/2 fixture
  # pattern (design doc §4) rather than going through Letflow.ServiceCatalog.register/1
  # directly, so a test can insert rows this module's own reaper is later expected
  # to find without depending on register/1's own tenant-existence side effects.
  defp insert_entry!(overrides) do
    attrs =
      %{
        service_id: unique_service_id(),
        endpoint_url: "https://example.test/svc",
        required_auth: :NONE,
        timeout_ms: 5_000,
        scope: :global
      }
      |> Map.merge(overrides)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entry =
      %Entry{}
      |> Entry.insert_changeset(attrs)
      |> Ecto.Changeset.put_change(:created_at, now)
      |> Ecto.Changeset.put_change(:updated_at, now)
      |> Repo.insert!()

    on_exit(fn -> cleanup_entry!(entry.service_id) end)

    entry
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp service_catalog_row_exists?(service_id) do
    Repo.exists?(from(e in Entry, where: e.service_id == ^service_id))
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------------
  # Criterion 1 -- empty table, no concurrent invocation -> {:ok, %{deleted: 0}}.
  # ---------------------------------------------------------------------------------

  describe "sweep_service_catalog_orphans/1 with an empty table" do
    test "returns {:ok, %{deleted: 0}} and leaves the table empty" do
      # Sweep any pre-existing rows first so this test's own assertion of a
      # genuinely empty table isn't polluted by an unrelated leftover from a
      # different test file run earlier in this same invocation.
      TenantSchemaReaper.sweep_service_catalog_orphans(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert {:ok, %{deleted: 0}} = TenantSchemaReaper.sweep_service_catalog_orphans(Repo)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert Repo.aggregate(Entry, :count) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 2 -- both scope: :global and scope: :tenant rows are deleted
  # unconditionally, no scope-based filtering.
  # ---------------------------------------------------------------------------------

  describe "sweep_service_catalog_orphans/1 with leftover rows present" do
    test "deletes both global and tenant-scoped rows unconditionally" do
      tenant = insert_tenant!()

      global_entry = insert_entry!(%{scope: :global})
      tenant_entry = insert_entry!(%{scope: :tenant, owner_tenant_id: tenant.id})

      assert service_catalog_row_exists?(global_entry.service_id)
      assert service_catalog_row_exists?(tenant_entry.service_id)

      assert {:ok, %{deleted: deleted}} = TenantSchemaReaper.sweep_service_catalog_orphans(Repo)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert deleted >= 2
      refute service_catalog_row_exists?(global_entry.service_id)
      refute service_catalog_row_exists?(tenant_entry.service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 3 (ISS-0110, reused) -- a genuinely concurrent, non-sibling invocation
  # defers the sweep entirely: rows survive untouched.
  # ---------------------------------------------------------------------------------

  describe "sweep_service_catalog_orphans/1 concurrent-invocation guard" do
    test "defers entirely while another invocation's connection is open, leaving rows untouched" do
      entry = insert_entry!(%{scope: :global})

      fake_tag = "letflow_mixtest_fake#{System.unique_integer([:positive])}"
      repo_config = Repo.config()

      {:ok, other_conn} =
        Postgrex.start_link(
          hostname: Keyword.fetch!(repo_config, :hostname),
          port: Keyword.fetch!(repo_config, :port),
          username: Keyword.fetch!(repo_config, :username),
          password: Keyword.fetch!(repo_config, :password),
          database: Keyword.fetch!(repo_config, :database),
          parameters: [application_name: fake_tag]
        )

      # ISS-0452: tolerate the connection process already being gone -- it is
      # linked to the test process, and on_exit runs after that process
      # exits, so check-then-act races its own shutdown.
      on_exit(fn ->
        try do
          GenServer.stop(other_conn)
        catch
          :exit, _ -> :ok
        end
      end)

      %{rows: [[1]]} =
        Postgrex.query!(
          other_conn,
          "SELECT 1 FROM pg_stat_activity WHERE application_name = $1",
          [fake_tag]
        )

      assert {:deferred, :concurrent_invocation} =
               TenantSchemaReaper.sweep_service_catalog_orphans(Repo)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert service_catalog_row_exists?(entry.service_id)

      GenServer.stop(other_conn)

      assert {:ok, %{deleted: deleted}} = TenantSchemaReaper.sweep_service_catalog_orphans(Repo)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert deleted >= 1
      refute service_catalog_row_exists?(entry.service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 4 (ISS-0217, reused) -- a same-TEST_PARALLEL_GROUP-tagged sibling
  # connection is not treated as a hazard: the sweep proceeds.
  # ---------------------------------------------------------------------------------

  describe "sweep_service_catalog_orphans/1 sibling test_parallel.sh guard" do
    test "proceeds (not deferred) when the other connection shares this invocation's group tag" do
      entry = insert_entry!(%{scope: :global})

      %{rows: [[own_tag]]} = Repo.query!("SHOW application_name")

      # This invocation's own group suffix, if any (config/test.exs only sets one
      # when TEST_PARALLEL_GROUP is present, i.e. under scripts/test_parallel.sh).
      # Fabricate a sibling tag carrying the SAME group when we have one; otherwise
      # (a plain `mix test` invocation, no group of its own) fabricate a tag with no
      # group at all -- concurrent_invocation_present?/2's own contract (own_group:
      # nil) still means every other tag counts as external, so this exercises the
      # unchanged ISS-0110 behavior instead of a false "sibling" premise.
      sibling_tag =
        case Regex.run(~r/_grp(.+)$/, own_tag) do
          [_, group] -> "letflow_mixtest_sib#{System.unique_integer([:positive])}_grp#{group}"
          nil -> "letflow_mixtest_sib#{System.unique_integer([:positive])}"
        end

      expect_proceed? = own_tag =~ ~r/_grp/

      repo_config = Repo.config()

      {:ok, other_conn} =
        Postgrex.start_link(
          hostname: Keyword.fetch!(repo_config, :hostname),
          port: Keyword.fetch!(repo_config, :port),
          username: Keyword.fetch!(repo_config, :username),
          password: Keyword.fetch!(repo_config, :password),
          database: Keyword.fetch!(repo_config, :database),
          parameters: [application_name: sibling_tag]
        )

      # ISS-0452: tolerate the process already being gone (see that issue).
      on_exit(fn ->
        try do
          GenServer.stop(other_conn)
        catch
          :exit, _ -> :ok
        end
      end)

      # Sanity: the sibling connection is really visible to Postgres under its tag
      # before running the sweep -- otherwise this test could pass/fail for the
      # wrong reason (a not-yet-registered connection, not the guard itself).
      %{rows: [[1]]} =
        Postgrex.query!(
          other_conn,
          "SELECT 1 FROM pg_stat_activity WHERE application_name = $1",
          [sibling_tag]
        )

      result = TenantSchemaReaper.sweep_service_catalog_orphans(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      if expect_proceed? do
        assert {:ok, %{deleted: deleted}} = result
        assert deleted >= 1
        refute service_catalog_row_exists?(entry.service_id)
      else
        assert {:deferred, :concurrent_invocation} = result
        assert service_catalog_row_exists?(entry.service_id)
      end

      GenServer.stop(other_conn)
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 5 -- an outer failure never raises out of the call; returns
  # {:ok, %{deleted: 0}} instead.
  # ---------------------------------------------------------------------------------

  describe "sweep_service_catalog_orphans/1 failure-mode contract" do
    test "never raises -- a repo whose query!/1 always raises returns {:ok, %{deleted: 0}}" do
      assert {:ok, %{deleted: 0}} =
               TenantSchemaReaper.sweep_service_catalog_orphans(
                 Letflow.ServiceCatalogReaperTest.BrokenRepo
               )
    end
  end

  defmodule BrokenRepo do
    @moduledoc """
    A deliberately broken "repo" for the failure-mode contract test above.
    Delegates `get_dynamic_repo/0` to the real `Letflow.Repo` so
    `Sandbox.mode/2` (this module's own step 1 and its `after`-block restore)
    still resolves and succeeds against the real, already-started repo --
    isolating the forced failure to exactly the `SELECT`/`DELETE` query path
    (step 4 in the design's §2.4 algorithm), which is the realistic failure
    this contract test is meant to prove survives.
    """
    def get_dynamic_repo, do: Letflow.Repo.get_dynamic_repo()
    def query!(_sql), do: raise("boom (BrokenRepo.query!/1, forced for ISS-0414 test)")
    def query!(_sql, _params), do: raise("boom (BrokenRepo.query!/2, forced for ISS-0414 test)")
  end
end
