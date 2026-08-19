defmodule Letflow.Engine.LuaScriptAuditTest do
  @moduledoc """
  Tests for `Letflow.Engine.LuaScriptAudit.execute_script_for_audit/6` (REQ-058,
  LUA-07). See `test/specs/REQ-058.md` for the full test-case rationale and the
  acceptance-criteria mapping.

  No real Lua runtime exists (S5, unstarted) -- every test injects an inline
  test-double module implementing `Letflow.Engine.LuaScriptAudit.Executor`'s
  `@behaviour` (defined below, module scope, since `@behaviour` implementations must
  be compile-time modules, not anonymous functions). Two double styles are used,
  matching `test/letflow/definitions/service_scope_validator_test.exs`'s
  "raise-if-called" idiom plus an explicit `send/2`-based call recorder, per this
  file's own spec §"Test-double strategy" -- a raise proves "never reached on this
  control-flow path," a recorder proves "the call count is exactly zero," and using
  both is the strongest available check for AC3's ordering guarantee.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. The migration/tenant
  describe block mirrors `test/letflow/engine/migrations_test.exs`'s established
  `provisioned_tenant/0` shape exactly (real `CREATE SCHEMA`, real
  `TenantProvisioning.replay_migrations/2` replay, `:auto`-mode sandbox switch,
  per-test schema drop in `on_exit/1`) -- `async: false` for the same reason that file
  states: the `:auto`-mode switch is only safe because ExUnit fully drains every
  `async: true` module before running any `async: false` module, and runs
  `async: false` modules strictly one at a time. The pure-function describe blocks
  (success path, instance_id validation, hash mismatch, prefix fail-closed) still use
  real Postgres inserts (this module writes rows), so the whole file stays
  `async: false` rather than splitting into a second module, matching this codebase's
  precedent of keeping one requirement's Repo-touching tests in a single `async:
  false` file when a shared tenant-provisioning helper is needed throughout.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.LuaScriptAudit
  alias Letflow.Engine.LuaScriptAudit.AuditRecord
  alias Letflow.Engine.LuaScriptAudit.Executor
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Test-double Executor implementations (module scope -- @behaviour implementations
  # must be compile-time modules, not closures/anonymous functions).
  # ---------------------------------------------------------------------------------

  # Echoes registered_hash back as the "actual" hash -- always a match, for the
  # success path (AC2).
  defmodule EchoExecutor do
    @moduledoc false
    @behaviour Executor

    @impl Executor
    def execute_with_manifest(_script_ref, registered_hash),
      do: {:ok, %{manifest_hash: registered_hash}}
  end

  # Always reports a fixed hash regardless of registered_hash -- deliberately
  # mismatched, for AC4.
  defmodule MismatchExecutor do
    @moduledoc false
    @behaviour Executor

    @impl Executor
    def execute_with_manifest(_script_ref, _registered_hash),
      do: {:ok, %{manifest_hash: "actual-hash-from-executor"}}
  end

  # Raises if ever invoked -- proves "never reached on this control-flow path" for
  # AC3 and the :missing_prefix fail-closed cases, mirroring
  # service_scope_validator_test.exs's raise_if_called_lookup/0 technique.
  defmodule RaiseIfCalledExecutor do
    @moduledoc false
    @behaviour Executor

    @impl Executor
    def execute_with_manifest(script_ref, registered_hash) do
      raise "execute_with_manifest must not be called, got: #{inspect({script_ref, registered_hash})}"
    end
  end

  # Records every call by sending a message to the calling process (the test process
  # itself -- execute_script_for_audit/6 invokes this synchronously, in-process) and
  # echoes registered_hash back. Used for the positive "zero calls" assertion via
  # refute_received/1, complementing RaiseIfCalledExecutor's crash-based guarantee.
  defmodule RecordingExecutor do
    @moduledoc false
    @behaviour Executor

    @impl Executor
    def execute_with_manifest(script_ref, registered_hash) do
      send(self(), {:lua_executor_called, script_ref, registered_hash})
      {:ok, %{manifest_hash: registered_hash}}
    end
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req058-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-058 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Mirrors engine/migrations_test.exs's provisioned_tenant/0 exactly (this file's
  # moduledoc). Provisions a real tenant and replays the full manifest.
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
        "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema_name, table_name]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp audit_rows(schema_name) do
    Repo.all(from(a in AuditRecord), prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- successful write + read-back with matching hash
  # ---------------------------------------------------------------------------------

  describe "execute_script_for_audit/6 success path" do
    test "writes exactly one audit row and it reads back with the columns given" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      hash = "sha256-fixture-hash"

      assert {:ok, record} =
               LuaScriptAudit.execute_script_for_audit(
                 EchoExecutor,
                 instance_id,
                 :any_script_ref,
                 hash,
                 actor_id,
                 prefix: schema_name
               )

      assert record.instance_id == instance_id
      assert record.manifest_hash == hash
      assert record.actor_id == actor_id
      assert %DateTime{} = record.executed_at

      # Independent read-back -- don't just trust the function's own return value.
      reselected = Repo.get(AuditRecord, record.id, prefix: schema_name)
      assert reselected.instance_id == instance_id
      assert reselected.manifest_hash == hash
      assert reselected.actor_id == actor_id

      assert audit_rows(schema_name) |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- instance_id validated before the executor is ever invoked
  # ---------------------------------------------------------------------------------

  describe "instance_id validated before executor invocation" do
    test "nil instance_id is rejected and the executor is never called" do
      %{schema_name: schema_name} = provisioned_tenant()
      actor_id = Ecto.UUID.generate()

      assert {:error, :invalid_instance_id} =
               LuaScriptAudit.execute_script_for_audit(
                 RaiseIfCalledExecutor,
                 nil,
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 prefix: schema_name
               )

      assert audit_rows(schema_name) == []
    end

    test "a malformed (non-UUID) instance_id is rejected and the executor is never called" do
      %{schema_name: schema_name} = provisioned_tenant()
      actor_id = Ecto.UUID.generate()

      assert {:error, :invalid_instance_id} =
               LuaScriptAudit.execute_script_for_audit(
                 RaiseIfCalledExecutor,
                 "not-a-uuid",
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 prefix: schema_name
               )

      assert audit_rows(schema_name) == []
    end

    test "the call-recorder double confirms exactly zero invocations for a nil instance_id" do
      %{schema_name: schema_name} = provisioned_tenant()
      actor_id = Ecto.UUID.generate()

      assert {:error, :invalid_instance_id} =
               LuaScriptAudit.execute_script_for_audit(
                 RecordingExecutor,
                 nil,
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 prefix: schema_name
               )

      refute_received {:lua_executor_called, _, _}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- manifest-hash mismatch: distinct error, zero rows written
  # ---------------------------------------------------------------------------------

  describe "manifest hash mismatch" do
    test "a mismatched hash returns the distinct 3-tuple error and writes no row" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:error, {:manifest_hash_mismatch, "registered-hash", "actual-hash-from-executor"}} =
               LuaScriptAudit.execute_script_for_audit(
                 MismatchExecutor,
                 instance_id,
                 :any_script_ref,
                 "registered-hash",
                 actor_id,
                 prefix: schema_name
               )

      assert audit_rows(schema_name) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # missing/nil/empty :prefix -- fails closed, zero writes, zero executor calls
  # (added during INV-1 rework -- INV-LSA-6)
  # ---------------------------------------------------------------------------------

  describe "missing or blank :prefix fails closed" do
    test "no :prefix key at all is rejected before the executor is touched" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} =
               LuaScriptAudit.execute_script_for_audit(
                 RaiseIfCalledExecutor,
                 instance_id,
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 []
               )

      assert audit_rows(schema_name) == []
    end

    test "prefix: nil is rejected before the executor is touched" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} =
               LuaScriptAudit.execute_script_for_audit(
                 RaiseIfCalledExecutor,
                 instance_id,
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 prefix: nil
               )

      assert audit_rows(schema_name) == []
    end

    test "prefix: \"\" (empty string) is rejected before the executor is touched" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} =
               LuaScriptAudit.execute_script_for_audit(
                 RaiseIfCalledExecutor,
                 instance_id,
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 prefix: ""
               )

      assert audit_rows(schema_name) == []
    end

    test "the call-recorder double confirms zero invocations when :prefix is missing" do
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert {:error, :missing_prefix} =
               LuaScriptAudit.execute_script_for_audit(
                 RecordingExecutor,
                 instance_id,
                 :any_script_ref,
                 "some-hash",
                 actor_id,
                 []
               )

      refute_received {:lua_executor_called, _, _}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- migration applies cleanly against a provisioned tenant schema, and is
  # actually reachable (both the migration file's guard and the manifest
  # registration -- design doc §0/§6.3, "either alone is insufficient").
  # ---------------------------------------------------------------------------------

  describe "migration applies to a provisioned tenant schema" do
    test "lua_script_execution_audit exists in the tenant schema, never in public" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert table_exists_in_schema?(schema_name, "lua_script_execution_audit")

      refute table_exists_in_schema?("public", "lua_script_execution_audit"),
             "lua_script_execution_audit leaked into the public schema -- the :prefix guard is not working"
    end

    test "its column set matches AuditRecord's schema fields exactly" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert columns_in(schema_name, "lua_script_execution_audit") ==
               AuditRecord.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "idx_lua_script_execution_audit_instance exists on the tenant table" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert "idx_lua_script_execution_audit_instance" in indexes_on(
               schema_name,
               "lua_script_execution_audit"
             )
    end

    test "the migration module is registered in tenant_scoped_migrations/0" do
      registered_modules =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 1))

      assert Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit in registered_modules,
             "CreateLuaScriptExecutionAudit is not registered -- it would never reach any tenant schema"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5/AC6 -- mix.exs carries no Lua/NIF dependency; the moduledoc carries the S5
  # scope-deferral and narrowness statements in substance.
  # ---------------------------------------------------------------------------------

  describe "mix.exs and moduledoc guardrails" do
    test "mix.exs declares no Lua/NIF-shaped dependency" do
      dep_names =
        Mix.Project.config()[:deps]
        |> Enum.map(fn dep -> dep |> elem(0) |> Atom.to_string() |> String.downcase() end)

      refute Enum.any?(dep_names, &(&1 =~ "lua")),
             "found a Lua-shaped dependency in mix.exs: #{inspect(dep_names)}"
    end

    test "the moduledoc states the Lua runtime is S5 scope, pending the build-vs-bind decision record" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(LuaScriptAudit)

      assert moduledoc =~ "S5"
      assert moduledoc =~ "stage-5-scripting-plugins.md"
    end

    test "the moduledoc states this is not the SERVICE_TASK handler and will be superseded" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(LuaScriptAudit)

      assert moduledoc =~ "SERVICE_TASK"
      assert moduledoc =~ "supersedes" or moduledoc =~ "superseded"
    end
  end
end
