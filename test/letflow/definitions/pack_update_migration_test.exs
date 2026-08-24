defmodule Letflow.Definitions.PackUpdateMigrationTest do
  @moduledoc """
  Integration tests for REQ-041's three GLOBAL migrations
  (`priv/repo/migrations/20260817083801..083803_*.exs`) and
  `Letflow.Definitions.compute_pack_update_plan/5`, run against real Postgres via
  `Letflow.DataCase`. See `test/specs/REQ-041.md` for the full test-case rationale and
  the WF-02 Step 3 scope-test verdict.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  ## Why this file does NOT use REQ-022's provision-then-replay tenant fixture machinery

  Every other S2 migration test in this project
  (`promotion_review_migration_test.exs`, `migrations_test.exs`) provisions a real
  tenant schema and replays tenant-scoped migrations into it, because the tables under
  test only exist inside that per-tenant schema (`:prefix`). REQ-041's three tables are
  the deliberate exception: they are GLOBAL (public/default schema, no `:prefix`, not
  registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0` -- REQ-041
  acceptance criterion 1), so they are created by the ordinary `mix ecto.migrate
  --quiet` step `mix test`'s own alias already runs before any test starts (confirmed
  directly: `MIX_ENV=test mix ecto.migrate --quiet` applies all three cleanly with no
  errors). There is therefore no `Ecto.Migrator`-needs-a-second-connection problem to
  work around here: this file uses the perfectly ordinary `Letflow.DataCase` sandboxed
  transaction, `async: true`, exactly like `identity/tenant_test.exs` and
  `identity/tenant_role_test.exs` (this project's own precedent for a GLOBAL-table
  test).

  `solution_pack_installs`/`solution_pack_artefact_bases`/`pack_update_resolutions.tenant_id`
  all carry a real DB-level foreign key to `tenants.id` (design section 3.1), so every
  fixture in this file that needs a row to actually persist inserts a real
  `Letflow.Identity.Tenant` row first, matching `identity/tenant_role_test.exs`'s own
  pattern for its one real FK.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Definitions
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning

  # Fixed literal, never DateTime.utc_now/0 -- no test in this project may depend on
  # wall-clock time (docs/guides/test_developer_guide.md principle 3).
  @fixed_timestamp ~U[2026-01-02 03:04:05.000000Z]

  @req041_tables %{
    "solution_pack_installs" => SolutionPackInstall,
    "solution_pack_artefact_bases" => SolutionPackArtefactBase,
    "pack_update_resolutions" => PackUpdateResolution
  }

  @req041_migration_modules [
    Letflow.Repo.Migrations.CreateSolutionPackInstalls,
    Letflow.Repo.Migrations.CreateSolutionPackArtefactBases,
    Letflow.Repo.Migrations.CreatePackUpdateResolutions
  ]

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # oidc_mode: :disabled avoids Tenant.create_changeset/3's idp_realm_id requirement --
  # irrelevant to anything this file tests, matching every other provisioning test in
  # this project's own use of :disabled.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req041-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-041 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp unique_pack_id, do: "req041-pack-#{System.unique_integer([:positive, :monotonic])}"
  defp unique_artefact_id, do: "req041-art-#{System.unique_integer([:positive, :monotonic])}"

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp columns_in(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
        [schema_name, table_name]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp insert_install(tenant_id, pack_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          tenant_id: tenant_id,
          pack_id: pack_id,
          installed_version: "1.0.0",
          installed_at: @fixed_timestamp
        },
        overrides
      )

    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(attrs)
    |> Repo.insert()
  end

  defp insert_base!(tenant_id, pack_id, artefact_type, artefact_id, content) do
    {:ok, base} =
      %SolutionPackArtefactBase{}
      |> SolutionPackArtefactBase.upsert_changeset(%{
        tenant_id: tenant_id,
        pack_id: pack_id,
        artefact_type: artefact_type,
        artefact_id: artefact_id,
        base_version: "1.0.0",
        base_content: content,
        captured_at: @fixed_timestamp
      })
      |> Repo.insert()

    base
  end

  defp insert_base(tenant_id, pack_id, artefact_type, artefact_id, content) do
    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: artefact_type,
      artefact_id: artefact_id,
      base_version: "1.0.0",
      base_content: content,
      captured_at: @fixed_timestamp
    })
    |> Repo.insert()
  end

  defp insert_resolution!(tenant_id, pack_id, target_version, artefact_type, artefact_id) do
    {:ok, resolution} =
      %PackUpdateResolution{}
      |> PackUpdateResolution.insert_changeset(%{
        tenant_id: tenant_id,
        pack_id: pack_id,
        target_version: target_version,
        artefact_type: artefact_type,
        artefact_id: artefact_id,
        resolution: "keep_local",
        resolved_by: Ecto.UUID.generate(),
        resolved_at: @fixed_timestamp
      })
      |> Repo.insert()

    resolution
  end

  defp insert_resolution(tenant_id, pack_id, target_version, artefact_type, artefact_id) do
    %PackUpdateResolution{}
    |> PackUpdateResolution.insert_changeset(%{
      tenant_id: tenant_id,
      pack_id: pack_id,
      target_version: target_version,
      artefact_type: artefact_type,
      artefact_id: artefact_id,
      resolution: "keep_local",
      resolved_by: Ecto.UUID.generate(),
      resolved_at: @fixed_timestamp
    })
    |> Repo.insert()
  end

  defp artefact_input(type, id, content),
    do: %{artefact_type: type, artefact_id: id, content: content}

  defp entry_for(plan, artefact_type, artefact_id) do
    Enum.find(
      plan.entries,
      &(&1.artefact_type == artefact_type and &1.artefact_id == artefact_id)
    )
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "priv/repo/migrations gains solution_pack_installs,
  # solution_pack_artefact_bases, and pack_update_resolutions migrations in the
  # public/default schema (not :prefix-scoped), applying cleanly"
  # ---------------------------------------------------------------------------------

  describe "AC1 -- all three migrations land in the public/default schema, applying cleanly" do
    test "all three tables exist under table_schema = 'public'" do
      for table <- Map.keys(@req041_tables) do
        assert table_exists_in_schema?("public", table),
               "#{table} is missing from the public schema -- REQ-041 acceptance criterion 1 requires it there, unguarded by any :prefix"
      end
    end

    test "none of the three REQ-041 migration modules is registered in tenant_scoped_migrations/0" do
      # This is the test that actually distinguishes "deliberately GLOBAL" from
      # "someone forgot the :prefix guard AND forgot to register it" -- a naive
      # existence check above would pass either way. Registration is what would make
      # TenantProvisioning.replay_migrations/2 create these tables inside a tenant's
      # own schema too, which REQ-041's GLOBAL classification explicitly forbids
      # (design section 4.1: "no manifest entry, deliberately").
      registered_modules =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 1))

      for module <- @req041_migration_modules do
        refute module in registered_modules,
               "#{inspect(module)} is registered in tenant_scoped_migrations/0 -- REQ-041's three tables must be GLOBAL, never tenant-scoped"
      end
    end

    test "each table's real column set in the public schema matches its Ecto.Schema module's field list exactly" do
      # "Applies cleanly" is necessary but not sufficient -- a migration can apply
      # without error and still disagree with the schema module that reads it, which
      # would otherwise surface much later as a runtime Postgrex error. Matches
      # REQ-027's/REQ-035's own migration-test convention.
      for {table, module} <- @req041_tables do
        expected = module.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

        assert columns_in("public", table) == expected,
               "#{table}'s real columns disagree with #{inspect(module)}.__schema__(:fields)"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "compute_pack_update_plan/5 against an artefact with no
  # matching solution_pack_artefact_bases row classifies it as conflict, not unchanged
  # or an error, per PRM-09 AC5" -- full 5-argument orchestration, real DB lookup.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- compute_pack_update_plan/5 against no matching base row (and no install row at all) classifies :conflict" do
    test "returns {:ok, plan} with classification :conflict and base: nil, not an error and not :unchanged",
         %{} do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      # Deliberately no solution_pack_installs row and no solution_pack_artefact_bases
      # row for this (tenant, pack, artefact) -- the literal "cannot prove no
      # modification" scenario PRM-09 AC5 names.
      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "theirs-content")],
                 [artefact_input(artefact_type, artefact_id, "incoming-content")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :conflict
      assert entry.base == nil
      refute entry.classification == :unchanged
    end

    test "still classifies :conflict even when theirs and incoming happen to be identical, since a nil base can never confirm no modification" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "same-content")],
                 [artefact_input(artefact_type, artefact_id, "same-content")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :conflict,
             "an artefact with no base row must classify :conflict even when theirs == incoming"
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "compute_pack_update_plan/5 against base==theirs!=incoming
  # classifies clean_update; base==incoming!=theirs classifies local_only;
  # base==theirs==incoming classifies unchanged -- each with an explicit test", exercised
  # end to end through a real solution_pack_artefact_bases row.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- the three named outcomes plus the both-differ conflict case, through the full orchestration with a real base row" do
    test "base == theirs != incoming classifies :clean_update" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "base-v1")],
                 [artefact_input(artefact_type, artefact_id, "incoming-v2")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :clean_update
      assert entry.base == "base-v1"
      assert entry.theirs == "base-v1"
      assert entry.incoming == "incoming-v2"
    end

    test "base == incoming != theirs classifies :local_only" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "theirs-v2")],
                 [artefact_input(artefact_type, artefact_id, "base-v1")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :local_only
      assert entry.base == "base-v1"
      assert entry.theirs == "theirs-v2"
      assert entry.incoming == "base-v1"
    end

    test "base == theirs == incoming classifies :unchanged" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "base-v1")],
                 [artefact_input(artefact_type, artefact_id, "base-v1")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :unchanged
    end

    test "base, theirs and incoming are three distinct values classifies :conflict (both sides changed)" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "theirs-v2")],
                 [artefact_input(artefact_type, artefact_id, "incoming-v3")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :conflict
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "has_unresolved_conflicts is true when at least one
  # conflict-classified artefact has no matching pack_update_resolutions row, and false
  # once every conflict artefact has one"
  # ---------------------------------------------------------------------------------

  describe "AC4 -- has_unresolved_conflicts is true iff at least one conflict entry lacks a matching resolution row" do
    test "true when a conflict artefact has no resolution row" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "theirs-v2")],
                 [artefact_input(artefact_type, artefact_id, "incoming-v3")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :conflict
      refute entry.resolved
      assert plan.has_unresolved_conflicts
    end

    test "false once the conflict artefact has a matching pack_update_resolutions row for the same target_version" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()
      incoming_version = "2.0.0"

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")
      insert_resolution!(tenant.id, pack_id, incoming_version, artefact_type, artefact_id)

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 incoming_version,
                 [artefact_input(artefact_type, artefact_id, "theirs-v2")],
                 [artefact_input(artefact_type, artefact_id, "incoming-v3")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :conflict
      assert entry.resolved
      refute plan.has_unresolved_conflicts
    end

    test "stays true when only one of two conflict artefacts is resolved -- Enum.any?, not Enum.all?" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      incoming_version = "2.0.0"
      artefact_type = "process_node"
      resolved_artefact_id = unique_artefact_id()
      unresolved_artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, resolved_artefact_id, "base-v1")
      insert_base!(tenant.id, pack_id, artefact_type, unresolved_artefact_id, "base-v1")

      insert_resolution!(
        tenant.id,
        pack_id,
        incoming_version,
        artefact_type,
        resolved_artefact_id
      )

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 incoming_version,
                 [
                   artefact_input(artefact_type, resolved_artefact_id, "theirs-v2"),
                   artefact_input(artefact_type, unresolved_artefact_id, "theirs-v2")
                 ],
                 [
                   artefact_input(artefact_type, resolved_artefact_id, "incoming-v3"),
                   artefact_input(artefact_type, unresolved_artefact_id, "incoming-v3")
                 ]
               )

      assert entry_for(plan, artefact_type, resolved_artefact_id).resolved
      refute entry_for(plan, artefact_type, unresolved_artefact_id).resolved

      assert plan.has_unresolved_conflicts,
             "one unresolved conflict among several must still set has_unresolved_conflicts, not just when ALL are unresolved"
    end

    test "a resolution recorded against a different target_version does not resolve the conflict" do
      # Proves pack_update_resolutions' per-attempt target_version scoping (design
      # section 3.3, OQ-5) is actually enforced in the lookup query, not just
      # documented as intent.
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")
      insert_resolution!(tenant.id, pack_id, "1.5.0", artefact_type, artefact_id)

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "theirs-v2")],
                 [artefact_input(artefact_type, artefact_id, "incoming-v3")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      refute entry.resolved,
             "a resolution scoped to target_version 1.5.0 must not resolve a conflict against incoming_version 2.0.0"

      assert plan.has_unresolved_conflicts
    end

    test "false vacuously when there are zero conflict-classified artefacts" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      insert_base!(tenant.id, pack_id, artefact_type, artefact_id, "base-v1")

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.id,
                 pack_id,
                 "2.0.0",
                 [artefact_input(artefact_type, artefact_id, "base-v1")],
                 [artefact_input(artefact_type, artefact_id, "base-v1")]
               )

      entry = entry_for(plan, artefact_type, artefact_id)

      assert entry.classification == :unchanged
      refute plan.has_unresolved_conflicts
    end
  end

  # ---------------------------------------------------------------------------------
  # Beyond the bare acceptance criteria -- cheap, real, not busywork.
  # ---------------------------------------------------------------------------------

  describe "real DB-level foreign key: tenant_id references tenants.id on all three GLOBAL tables" do
    test "solution_pack_installs rejects a tenant_id matching no tenants row" do
      orphan_tenant_id = Ecto.UUID.generate()

      assert_raise Ecto.ConstraintError, fn ->
        insert_install(orphan_tenant_id, unique_pack_id())
      end
    end

    test "solution_pack_artefact_bases rejects a tenant_id matching no tenants row" do
      orphan_tenant_id = Ecto.UUID.generate()

      assert_raise Ecto.ConstraintError, fn ->
        insert_base(
          orphan_tenant_id,
          unique_pack_id(),
          "process_node",
          unique_artefact_id(),
          "content"
        )
      end
    end

    test "pack_update_resolutions rejects a tenant_id matching no tenants row" do
      orphan_tenant_id = Ecto.UUID.generate()

      assert_raise Ecto.ConstraintError, fn ->
        insert_resolution(
          orphan_tenant_id,
          unique_pack_id(),
          "2.0.0",
          "process_node",
          unique_artefact_id()
        )
      end
    end
  end

  describe "each table's own unique index rejects a real duplicate insert" do
    test "uq_solution_pack_install_active rejects a second active install for the same (tenant_id, pack_id)" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()

      assert {:ok, _} = insert_install(tenant.id, pack_id)

      assert {:error, changeset} = insert_install(tenant.id, pack_id)
      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn
               {:tenant_id, {_, opts}} ->
                 opts[:constraint_name] == "uq_solution_pack_install_active"

               _ ->
                 false
             end),
             "expected a uq_solution_pack_install_active constraint error, got #{inspect(changeset.errors)}"
    end

    test "uq_solution_pack_artefact_base rejects a second base row for the same (tenant_id, pack_id, artefact_type, artefact_id)" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      assert {:ok, _} = insert_base(tenant.id, pack_id, artefact_type, artefact_id, "content-a")

      assert {:error, changeset} =
               insert_base(tenant.id, pack_id, artefact_type, artefact_id, "content-b")

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn
               {:tenant_id, {_, opts}} ->
                 opts[:constraint_name] == "uq_solution_pack_artefact_base"

               _ ->
                 false
             end),
             "expected a uq_solution_pack_artefact_base constraint error, got #{inspect(changeset.errors)}"
    end

    test "uq_pack_update_resolution rejects a second resolution for the same (tenant_id, pack_id, target_version, artefact_type, artefact_id)" do
      tenant = insert_tenant!()
      pack_id = unique_pack_id()
      artefact_type = "process_node"
      artefact_id = unique_artefact_id()

      assert {:ok, _} =
               insert_resolution(tenant.id, pack_id, "2.0.0", artefact_type, artefact_id)

      assert {:error, changeset} =
               insert_resolution(tenant.id, pack_id, "2.0.0", artefact_type, artefact_id)

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn
               {:tenant_id, {_, opts}} ->
                 opts[:constraint_name] == "uq_pack_update_resolution"

               _ ->
                 false
             end),
             "expected a uq_pack_update_resolution constraint error, got #{inspect(changeset.errors)}"
    end
  end
end
