defmodule Letflow.Migrations.BackfillExamTenantModulesTest do
  @moduledoc """
  REQ-409 acceptance tests for
  `Letflow.Repo.Migrations.BackfillExamTenantModules` (P2 exam row backfill).

  ## Test strategy

  The migration is registered in `@tenant_scoped_migration_manifest` and
  therefore runs automatically during `TenantFixture.provisioned_tenant!/1`
  (either via the template build + clone or via the replay path). At
  provisioning time no `solution_pack_installs` row exists yet for any of
  the freshly-created fixture tenants, so the migration's conditional
  INSERT fires but the `WHERE EXISTS` returns false — each provisioned
  tenant starts with zero exam rows.

  To exercise the conditional INSERT with data present, each test:

  1. Provisions the tenant(s) normally (full manifest — zero exam rows after
     provisioning, version `20260926010001` recorded in `schema_migrations`).
  2. Inserts any required `solution_pack_installs` rows.
  3. Deletes the `schema_migrations` entry for `20260926010001` so
     `Ecto.Migrator` sees the migration as pending again.
  4. Calls `TenantProvisioning.replay_migrations/2` with a custom
     `migration_source` containing only this migration — isolating the
     migration under test from side-effects of re-running the full manifest.
  5. Asserts the expected `tenant_modules` state.

  For AC3 (ON CONFLICT DO NOTHING), step 3–4 is repeated a second time
  against a tenant that already holds the exam row, verifying that the SQL
  body executes again and produces exactly one row, not two.

  ## Teardown order

  `solution_pack_installs` has a GLOBAL FK to `tenants`.
  `TenantFixture.provisioned_tenant!/1` registers its own `on_exit` teardown
  (which deletes the `tenants` row). `insert_pack_install!/2` below registers
  its own `on_exit` AFTER `provisioned_tenant!`'s, so ExUnit's LIFO callback
  ordering ensures the SPI cleanup runs first — the FK is satisfied before the
  `tenants` row is deleted (same pattern `Letflow.ExamFixtures` uses for
  `entity_column_promotions`).

  `async: false` — `TenantFixture.provisioned_tenant!/1` sets
  `Ecto.Adapters.SQL.Sandbox` to `:auto` mode (real DDL outside any
  sandboxed transaction requires it).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @migration_version 20_260_926_010_001
  @migration_module Letflow.Repo.Migrations.BackfillExamTenantModules

  # Removes the `schema_migrations` record for this migration's version from
  # `schema`'s schema_migrations table, causing `Ecto.Migrator` to treat the
  # migration as pending on the next `replay_migrations/2` call.
  defp reset_migration_version!(schema_name) do
    Repo.query!(
      ~s(DELETE FROM "#{schema_name}".schema_migrations WHERE version = $1),
      [@migration_version]
    )
  end

  # Runs only our backfill migration against the tenant identified by
  # `tenant_id`, via a custom `migration_source` that contains nothing else.
  # Returns `{:ok, applied_versions}` on success (same spec as
  # `TenantProvisioning.replay_migrations/2`).
  defp run_backfill!(tenant_id) do
    TenantProvisioning.replay_migrations(tenant_id, [
      {@migration_version, @migration_module}
    ])
  end

  # Inserts a `solution_pack_installs` row for `tenant_id` with the given
  # `pack_id` via the shipped changeset. Also registers an `on_exit` teardown
  # to delete ALL spi rows for this `tenant_id` — ExUnit's LIFO callback
  # ordering ensures this runs BEFORE `TenantFixture`'s own teardown (which
  # deletes the `tenants` row), so the FK constraint is satisfied.
  defp insert_pack_install!(tenant_id, pack_id) do
    on_exit(fn ->
      Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
    end)

    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: tenant_id,
      pack_id: pack_id,
      installed_version: "1.0.0",
      installed_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # Returns all `tenant_modules` rows from `schema_name`.
  defp list_tenant_modules(schema_name) do
    Repo.all(TenantModule, prefix: schema_name)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # AC1: tenant A with bilimbaga-question-bank → exactly one exam row
  # ──────────────────────────────────────────────────────────────────────────

  describe "AC1 -- tenant with bilimbaga-question-bank pack install gets exam module row" do
    test "inserts exactly one tenant_modules row with module_id 'exam' and the exam manifest version" do
      %{tenant_id: tid_a, schema_name: schema_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req409-ac1-a")

      # Migration ran during provisioning with no spi data → 0 rows.
      assert list_tenant_modules(schema_a) == []

      # Insert the qualifying solution_pack_installs row for this tenant.
      insert_pack_install!(tid_a, "bilimbaga-question-bank")

      # Force Ecto to see the migration as pending for this tenant.
      reset_migration_version!(schema_a)

      # Run the migration — should apply exactly this one version.
      assert {:ok, [@migration_version]} = run_backfill!(tid_a)

      # Assert exactly one exam row with the correct fields.
      rows = list_tenant_modules(schema_a)
      assert length(rows) == 1, "expected 1 tenant_modules row, got #{length(rows)}"

      [row] = rows
      assert row.module_id == "exam"
      assert row.version == "0.1.0"
      assert %DateTime{} = row.installed_at
      assert row.settings == %{}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # AC2: tenant B (no spi row) and tenant C (different pack_id) → zero rows
  # ──────────────────────────────────────────────────────────────────────────

  describe "AC2 -- tenants without a bilimbaga-question-bank install get no exam row" do
    test "tenant B (no solution_pack_installs row at all) stays at zero tenant_modules rows" do
      %{tenant_id: tid_b, schema_name: schema_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req409-ac2-b")

      reset_migration_version!(schema_b)

      assert {:ok, [@migration_version]} = run_backfill!(tid_b)

      assert list_tenant_modules(schema_b) == []
    end

    test "tenant C (solution_pack_installs row exists but for a different pack_id) stays at zero tenant_modules rows" do
      %{tenant_id: tid_c, schema_name: schema_c} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req409-ac2-c")

      # Insert a row for a different pack — must not trigger the exam backfill.
      insert_pack_install!(tid_c, "some-other-pack")

      reset_migration_version!(schema_c)

      assert {:ok, [@migration_version]} = run_backfill!(tid_c)

      assert list_tenant_modules(schema_c) == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # AC3: running the migration a second time leaves exactly one exam row
  # (proves ON CONFLICT DO NOTHING)
  # ──────────────────────────────────────────────────────────────────────────

  describe "AC3 -- migration is idempotent (ON CONFLICT DO NOTHING)" do
    test "running the migration a second time against tenant A leaves exactly one exam row" do
      %{tenant_id: tid_a, schema_name: schema_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req409-ac3-a")

      insert_pack_install!(tid_a, "bilimbaga-question-bank")

      # FIRST RUN — inserts the exam row.
      reset_migration_version!(schema_a)
      assert {:ok, [@migration_version]} = run_backfill!(tid_a)
      assert Repo.aggregate(TenantModule, :count, prefix: schema_a) == 1

      # SECOND RUN — forces the SQL body to execute again (reset
      # schema_migrations) to prove ON CONFLICT (module_id) DO NOTHING keeps
      # the count at exactly 1, not 2.
      reset_migration_version!(schema_a)
      assert {:ok, [@migration_version]} = run_backfill!(tid_a)

      rows = list_tenant_modules(schema_a)
      assert length(rows) == 1,
             "expected exactly 1 tenant_modules row after second run, got #{length(rows)}"

      assert hd(rows).module_id == "exam"
    end
  end
end
