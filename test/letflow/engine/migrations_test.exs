defmodule Letflow.Engine.MigrationsTest do
  @moduledoc """
  Integration tests for REQ-043's three `priv/repo/migrations/20260818110001..110003_*.exs`
  migrations (the `instance_projections` engine-columns `ALTER TABLE`, `tokens`, `tasks`),
  run against real Postgres through REQ-022's provision-then-replay mechanism. See
  `test/specs/REQ-043.md` for the full test-case rationale and the WF-02 Step 3
  scope-test verdict. Mirrors `test/letflow/event_store/migrations_test.exs`'s
  established structure and helpers (each file keeps its own copies rather than
  cross-file `import`, matching that file's own precedent of small, self-contained
  per-file fixtures).

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  `Ecto.Migrator` needs a second, genuinely independent database connection beyond
  the one this process has checked out (it takes a lock on `schema_migrations`),
  which a sandboxed pool will not hand out. Every describe block below therefore
  switches `Letflow.Repo` to `Ecto.Adapters.SQL.Sandbox` `:auto` mode and cleans up
  the real schemas/rows it creates in `on_exit/1`, instead of relying on rollback --
  identical reasoning to `event_store/migrations_test.exs` and `event_store_test.exs`.
  `async: false` for the whole module for the same reason those files are: ExUnit
  fully drains every `async: true` module before starting any `async: false` module
  and runs `async: false` modules strictly one at a time, so the `:auto`-mode switch
  never disturbs another module's connection.

  Each test provisions its own tenant (`provisioned_tenant/0`, mirroring
  `event_store_test.exs`'s identical helper) rather than sharing one across a
  `describe` block's tests, for full self-sufficiency (`test_developer_guide.md`
  principle 4 -- no cross-test pollution, no test depends on another having run
  first).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.Task
  alias Letflow.Engine.Token
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @req043_migration_modules [
    Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns,
    Letflow.Repo.Migrations.CreateTokens,
    Letflow.Repo.Migrations.CreateTasks
  ]

  # Synthetic migration versions for the §4 guard test -- far below any real
  # timestamp-shaped version and far from the probe bases
  # event_store/migrations_test.exs (990_000_000) and tenant_provisioning_test.exs
  # (999_999_999) already use, so nothing collides.
  @guard_probe_version_base 980_000_000

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req043-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-043 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Mirrors event_store_test.exs's provisioned_tenant/1 exactly (see this file's
  # moduledoc). Provisions a real tenant, replays the FULL manifest (not just
  # REQ-043's three entries) because tokens/tasks' foreign keys require
  # instance_projections to already exist -- exercising the real dependency chain
  # a fresh tenant actually goes through, not a hand-picked subset.
  defp provisioned_tenant do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

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

  defp indexes_on(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema_name, table_name]
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp public_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
        []
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Raw stored column value, bypassing Ecto.Enum's atom mapping -- the only way to
  # observe whether a status was actually dumped as the literal uppercase/lowercase
  # string the design mandates, rather than trusting the in-memory struct (which
  # Ecto.Enum would decode back to the same atom regardless of dump casing, making
  # a struct-level assertion blind to a casing regression).
  defp raw_status(schema_name, table, id) do
    %{rows: [[value]]} =
      Repo.query!(
        ~s(SELECT status FROM "#{schema_name}"."#{table}" WHERE id = $1),
        [Ecto.UUID.dump!(id)]
      )

    value
  end

  defp insert_projection!(schema_name, tenant_id, instance_id, opts \\ []) do
    attrs =
      %{
        instance_id: instance_id,
        tenant_id: tenant_id,
        status: :active,
        last_event_seq: 0,
        definition_id: Keyword.get(opts, :definition_id, Ecto.UUID.generate())
      }
      |> maybe_put(:correlation_key, Keyword.get(opts, :correlation_key, :__unset__))
      |> maybe_put(:current_nodes, Keyword.get(opts, :current_nodes, :__unset__))

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(attrs)
    |> Repo.insert(prefix: schema_name)
  end

  defp maybe_put(map, _key, :__unset__), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------------
  # Acceptance criterion: "all three new/altered migrations apply cleanly and are
  # schema-per-tenant"
  # ---------------------------------------------------------------------------------

  describe "the three REQ-043 migrations replayed into a provisioned tenant schema" do
    test "tokens and tasks land in the tenant's own schema, never in public" do
      %{schema_name: schema_name} = provisioned_tenant()

      for table <- ["tokens", "tasks"] do
        assert table_exists_in_schema?(schema_name, table),
               "#{table} is missing from tenant schema #{schema_name}"

        refute table_exists_in_schema?("public", table),
               "#{table} leaked into the public schema -- the :prefix guard is not working"
      end
    end

    test "tokens' and tasks' column sets match their Ecto.Schema module's fields exactly" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert columns_in(schema_name, "tokens") ==
               Token.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert columns_in(schema_name, "tasks") ==
               Task.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "instance_projections' new engine columns exist and match InstanceProjection's fields" do
      %{schema_name: schema_name} = provisioned_tenant()

      for column <- [
            "definition_id",
            "correlation_key",
            "current_nodes",
            "variables",
            "error_detail",
            "completed_at",
            "cancelled_at"
          ] do
        assert column in columns_in(schema_name, "instance_projections"),
               "#{column} is missing from instance_projections in #{schema_name}"
      end

      assert columns_in(schema_name, "instance_projections") ==
               InstanceProjection.__schema__(:fields)
               |> Enum.map(&Atom.to_string/1)
               |> Enum.sort()
    end

    test "the three REQ-043 migrations are registered in order: ALTER, tokens, tasks" do
      registered = TenantProvisioning.tenant_scoped_migrations()
      registered_modules = Enum.map(registered, &elem(&1, 1))

      for module <- @req043_migration_modules do
        assert module in registered_modules,
               "#{inspect(module)} is not registered -- it would never reach any tenant schema"
      end

      indices =
        Map.new(@req043_migration_modules, fn module ->
          {module, Enum.find_index(registered_modules, &(&1 == module))}
        end)

      assert indices[Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns] <
               indices[Letflow.Repo.Migrations.CreateTokens]

      assert indices[Letflow.Repo.Migrations.CreateTokens] <
               indices[Letflow.Repo.Migrations.CreateTasks]
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion: "a test demonstrating uq_instance_correlation rejects a
  # second instance_projections row with the same (definition_id, correlation_key)
  # while permitting any number of NULL-correlation_key rows"
  # ---------------------------------------------------------------------------------

  describe "uq_instance_correlation (partial unique index)" do
    test "a duplicate (definition_id, correlation_key) is rejected as {:error, changeset}" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      definition_id = Ecto.UUID.generate()
      correlation_key = "corr-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _first} =
               insert_projection!(schema_name, tenant_id, Ecto.UUID.generate(),
                 definition_id: definition_id,
                 correlation_key: correlation_key
               )

      assert {:error, changeset} =
               insert_projection!(schema_name, tenant_id, Ecto.UUID.generate(),
                 definition_id: definition_id,
                 correlation_key: correlation_key
               )

      assert %{correlation_key: ["has already been taken"]} = errors_on(changeset)
    end

    test "any number of NULL-correlation_key rows for the same definition_id are permitted" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      definition_id = Ecto.UUID.generate()

      for _ <- 1..3 do
        assert {:ok, _} =
                 insert_projection!(schema_name, tenant_id, Ecto.UUID.generate(),
                   definition_id: definition_id
                 )
      end
    end

    test "the same correlation_key is fine under a different definition_id" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      correlation_key = "corr-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _} =
               insert_projection!(schema_name, tenant_id, Ecto.UUID.generate(),
                 definition_id: Ecto.UUID.generate(),
                 correlation_key: correlation_key
               )

      assert {:ok, _} =
               insert_projection!(schema_name, tenant_id, Ecto.UUID.generate(),
                 definition_id: Ecto.UUID.generate(),
                 correlation_key: correlation_key
               )
    end

    test "uq_instance_correlation and idx_proj_definition exist with the designed shape" do
      %{schema_name: schema_name} = provisioned_tenant()
      indexes = indexes_on(schema_name, "instance_projections")

      assert Map.has_key?(indexes, "uq_instance_correlation")
      uq_def = Map.fetch!(indexes, "uq_instance_correlation")
      assert String.starts_with?(uq_def, "CREATE UNIQUE INDEX")
      assert uq_def =~ "(definition_id, correlation_key)"
      assert uq_def =~ "correlation_key IS NOT NULL"

      assert Map.has_key?(indexes, "idx_proj_definition")
      idx_def = Map.fetch!(indexes, "idx_proj_definition")
      refute String.starts_with?(idx_def, "CREATE UNIQUE INDEX")
      assert idx_def =~ "(definition_id)"

      # The pre-existing REQ-023 index is untouched (design §2.1's own statement).
      assert Map.has_key?(indexes, "idx_proj_status")
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion: "a test confirming current_nodes (via the new JSONArray
  # custom Ecto.Type) round-trips a list through real Postgres without corruption"
  # ---------------------------------------------------------------------------------

  describe "current_nodes (JSONArray) round-trips through real Postgres" do
    test "a non-empty list of maps round-trips exactly, in order" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      current_nodes = [
        %{"node_id" => "n1", "branch_id" => "b1"},
        %{"node_id" => "n2", "branch_id" => "b2"}
      ]

      assert {:ok, _} =
               insert_projection!(schema_name, tenant_id, instance_id,
                 current_nodes: current_nodes
               )

      reselected = Repo.get(InstanceProjection, instance_id, prefix: schema_name)
      assert reselected.current_nodes == current_nodes
    end

    test "omitting current_nodes stores and re-reads the schema-level default []" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      assert {:ok, inserted} = insert_projection!(schema_name, tenant_id, instance_id)
      assert inserted.current_nodes == []

      reselected = Repo.get(InstanceProjection, instance_id, prefix: schema_name)
      assert reselected.current_nodes == []
    end
  end

  # ---------------------------------------------------------------------------------
  # tasks.status / tokens.status casing, confirmed at the raw DB column level
  # (design INV-EE43-4) -- corroborates schemas_test.exs's pure Ecto.Enum.mappings/2
  # assertions with the fact they predict: what Postgres actually stores.
  # ---------------------------------------------------------------------------------

  describe "status casing at the real DB column level" do
    test "a Task row's raw status column is the uppercase string \"PENDING\"" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      assert {:ok, _} = insert_projection!(schema_name, tenant_id, instance_id)

      token =
        %Token{}
        |> Token.insert_changeset(%{
          tenant_id: tenant_id,
          instance_id: instance_id,
          node_id: "n1",
          branch_id: instance_id
        })
        |> Repo.insert!(prefix: schema_name)

      task =
        %Task{}
        |> Task.insert_changeset(%{
          tenant_id: tenant_id,
          instance_id: instance_id,
          token_id: token.id,
          node_id: "n1",
          node_name: "Approve"
        })
        |> Repo.insert!(prefix: schema_name)

      assert raw_status(schema_name, "tasks", task.id) == "PENDING"
    end

    test "a Token row's raw status column is the lowercase string \"active\"" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      assert {:ok, _} = insert_projection!(schema_name, tenant_id, instance_id)

      token =
        %Token{}
        |> Token.insert_changeset(%{
          tenant_id: tenant_id,
          instance_id: instance_id,
          node_id: "n1",
          branch_id: instance_id
        })
        |> Repo.insert!(prefix: schema_name)

      assert raw_status(schema_name, "tokens", token.id) == "active"
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion: "a test demonstrating a row written into tasks (and
  # tokens) has tenant_id equal to the tenant whose schema the write targeted,
  # derived internally; a test deliberately making a caller-supplied tenant_id
  # disagree with the target schema fails loudly rather than silently attributing
  # to the wrong tenant"
  #
  # See test/specs/REQ-043.md's "Flagged limitation" section for the full
  # explanation (also filed as a MINOR issue on this run's handoff): REQ-043 ships
  # NO context-module function with a public `attrs` parameter for either table --
  # only the two Ecto.Schema modules and their structural changesets. The design
  # doc itself (§6 point 2) states this explicitly: "this requirement's schema
  # modules structurally support that contract ... but cannot themselves enforce
  # the 'never caller-supplied' half, since REQ-043 builds no public function a
  # caller could pass attrs into. Flagged explicitly for REQ-045/051/062's own
  # CODE-DESIGNER to carry forward, not silently assumed automatic." A literal
  # "rejects a disagreeing tenant_id" test would therefore assert something false
  # about REQ-043's own code -- so the three tests below instead (a) demonstrate
  # the CORRECT usage pattern a future caller must follow, (b) demonstrate real
  # tenant/schema isolation at the storage level (schema-per-tenant does its job
  # regardless of what tenant_id column value is stamped), and (c) HONESTLY pins
  # today's real, documented-as-a-gap behavior: a disagreeing tenant_id is
  # currently accepted, not rejected. Test (c) is written so that it fails the
  # moment someone adds enforcement at this layer without updating this test --
  # forcing a conscious acknowledgement rather than a silent behavior change.
  # ---------------------------------------------------------------------------------

  describe "tenant_id internal-derivation contract (design §6)" do
    test "a Token/Task row's correctly-derived tenant_id stores and reads back exactly" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      assert {:ok, _} = insert_projection!(schema_name, tenant_id, instance_id)

      # Derived independently of the fixture's own tenant_id, so a derivation bug
      # would surface as a genuine assertion failure rather than tautologically
      # matching -- same technique event_store_test.exs's AC6 test uses.
      assert {:ok, expected_tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema_name)
      assert expected_tenant_id == tenant_id

      token =
        %Token{}
        |> Token.insert_changeset(%{
          tenant_id: expected_tenant_id,
          instance_id: instance_id,
          node_id: "n1",
          branch_id: instance_id
        })
        |> Repo.insert!(prefix: schema_name)

      task =
        %Task{}
        |> Task.insert_changeset(%{
          tenant_id: expected_tenant_id,
          instance_id: instance_id,
          token_id: token.id,
          node_id: "n1",
          node_name: "Approve"
        })
        |> Repo.insert!(prefix: schema_name)

      assert Repo.get(Token, token.id, prefix: schema_name).tenant_id == expected_tenant_id
      assert Repo.get(Task, task.id, prefix: schema_name).tenant_id == expected_tenant_id
    end

    test "a Token row is reachable only under its own tenant's :prefix" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      %{schema_name: other_schema_name} = provisioned_tenant()

      instance_id = Ecto.UUID.generate()
      assert {:ok, _} = insert_projection!(schema_name, tenant_id, instance_id)

      token =
        %Token{}
        |> Token.insert_changeset(%{
          tenant_id: tenant_id,
          instance_id: instance_id,
          node_id: "n1",
          branch_id: instance_id
        })
        |> Repo.insert!(prefix: schema_name)

      assert Repo.get(Token, token.id, prefix: schema_name)
      refute Repo.get(Token, token.id, prefix: other_schema_name)
    end

    test "a disagreeing tenant_id is currently accepted, not rejected (flagged gap, design §6 pt 2)" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      assert {:ok, _} = insert_projection!(schema_name, tenant_id, instance_id)

      disagreeing_tenant_id = Ecto.UUID.generate()
      refute disagreeing_tenant_id == tenant_id

      changeset =
        Token.insert_changeset(%Token{}, %{
          tenant_id: disagreeing_tenant_id,
          instance_id: instance_id,
          node_id: "n1",
          branch_id: instance_id
        })

      # The schema module's own changeset does not know what schema it will be
      # written under (design §6 point 1 -- "the schema module itself has no
      # access to opts[:prefix]"), so it cannot itself reject this. This is the
      # exact, deliberate boundary the design flags for REQ-045/051/062 to close.
      assert changeset.valid?

      assert {:ok, token} = Repo.insert(changeset, prefix: schema_name)
      assert Repo.get(Token, token.id, prefix: schema_name).tenant_id == disagreeing_tenant_id
    end
  end

  # ---------------------------------------------------------------------------------
  # §4 guard pattern -- REQ-043's three migrations are real no-ops without a
  # :prefix (req022-tenant-schema-provisioning.md §4), scoped to just these three
  # modules so this file's own claim of coverage does not depend on
  # event_store/migrations_test.exs's identically-shaped but broader test
  # continuing to exist unchanged.
  # ---------------------------------------------------------------------------------

  describe "§4 guard pattern -- no :prefix creates nothing in public" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      probe_versions =
        Enum.map(@req043_migration_modules, fn _module ->
          @guard_probe_version_base + System.unique_integer([:positive, :monotonic])
        end)

      tables_before = public_tables()

      on_exit(fn ->
        for version <- probe_versions do
          Repo.query!(~s(DELETE FROM "schema_migrations" WHERE version = $1), [version])
        end

        strays = MapSet.difference(public_tables(), tables_before)

        for table <- strays do
          Repo.query!(~s(DROP TABLE IF EXISTS "public"."#{table}" CASCADE))
        end
      end)

      %{probe_versions: probe_versions, tables_before: tables_before}
    end

    test "each REQ-043 migration, run with no :prefix, creates nothing in public", %{
      probe_versions: probe_versions,
      tables_before: tables_before
    } do
      for {module, probe_version} <- Enum.zip(@req043_migration_modules, probe_versions) do
        assert [probe_version] ==
                 Ecto.Migrator.run(Letflow.Repo, [{probe_version, module}], :up,
                   all: true,
                   log: false
                 ),
               "#{inspect(module)} did not run under probe version #{probe_version}"
      end

      assert public_tables() == tables_before,
             "a REQ-043 migration created something in public when run with no :prefix"
    end
  end
end
