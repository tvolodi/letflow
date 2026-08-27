defmodule Letflow.Engine.Lua.ManifestExecutorAuditTest do
  @moduledoc """
  REQ-158 (LUA-07, load-time half) end-to-end integration tests, proving the
  manifest hash actually flows through the real
  `Letflow.Engine.Lua.Executor` -> `Letflow.Engine.LuaScriptAudit` path into a
  persisted audit row (AC3), and that a hash mismatch still yields
  `LuaScriptAudit`'s own `{:manifest_hash_mismatch, ...}` error and writes no row
  (AC4) -- confirming `Letflow.Engine.LuaScriptAudit.verify_manifest_hash/2`
  (INV-LSA-2) is fed, not bypassed, per design §5.4.

  Not part of `Letflow.Engine.Lua.ManifestTest` (`test/letflow/engine/lua/manifest_test.exs`)
  because these tests need a real Postgres tenant schema for
  `LuaScriptAudit.execute_script_for_audit/6`'s insert, unlike every pure test in
  that file (design §1's own scope statement: no persistence layer is decided by
  `Letflow.Engine.Lua.Manifest` itself). Mirrors
  `test/letflow/engine/lua_script_audit_test.exs`'s own `provisioned_tenant/0`
  helper shape exactly (`async: false`, `Letflow.DataCase`, real
  `CREATE SCHEMA`/`TenantProvisioning.replay_migrations/2` replay, per-test schema
  drop in `on_exit/1`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.Lua.Executor
  alias Letflow.Engine.Lua.Manifest
  alias Letflow.Engine.LuaScriptAudit
  alias Letflow.Engine.LuaScriptAudit.AuditRecord
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp provisioned_tenant do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("req158"),
          display_name: "REQ-158 Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

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

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp audit_rows(schema_name) do
    Repo.all(from(a in AuditRecord), prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- the manifest hash flows into LuaScriptAudit's persisted audit row on a
  # successful execution, end to end (not merely equal in isolation).
  # ---------------------------------------------------------------------------------

  describe "successful execution: manifest hash flows into the persisted audit row (AC3)" do
    test "the AuditRecord's manifest_hash equals Manifest.compute_hash/2's output for the executed manifest+script pair" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      manifest = %Manifest{script_id: "req158-script", capabilities: ["variable:read"]}
      script = "return 1 + 1"

      # 1. Load-time gate first (design §3.2 calling convention) -- this manifest
      # and script have not been modified since "registration", so this succeeds
      # and hands back the manifest_hash to pass on as registered_hash.
      registered_hash = Manifest.compute_hash(manifest, script)

      assert {:ok, ^registered_hash} =
               Manifest.validate_at_load(manifest, script, registered_hash)

      # 2. Real Executor + real LuaScriptAudit, end to end.
      assert {:ok, %AuditRecord{} = record} =
               LuaScriptAudit.execute_script_for_audit(
                 Executor,
                 instance_id,
                 %{manifest: manifest, script_source: script},
                 registered_hash,
                 actor_id,
                 prefix: schema_name
               )

      # 3. The value that ended up in the persisted row is EXACTLY
      # Manifest.compute_hash/2's own output for this manifest+script pair --
      # proven end to end, not merely equal in isolation.
      expected_hash = Manifest.compute_hash(manifest, script)
      assert record.manifest_hash == expected_hash
      assert record.manifest_hash == registered_hash

      # Independent read-back.
      reselected = Repo.get(AuditRecord, record.id, prefix: schema_name)
      assert reselected.manifest_hash == expected_hash

      assert audit_rows(schema_name) |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a hash mismatch still yields LuaScriptAudit's own error and writes no
  # row, confirming INV-LSA-2 is fed, not bypassed.
  # ---------------------------------------------------------------------------------

  describe "hash mismatch: LuaScriptAudit's own error, zero rows written (AC4)" do
    test "an arbitrary wrong registered_hash yields {:manifest_hash_mismatch, ...} and writes no row" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      manifest = %Manifest{script_id: "req158-script", capabilities: ["variable:read"]}
      script = "return 1 + 1"
      real_hash = Manifest.compute_hash(manifest, script)
      wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000"

      assert wrong_hash != real_hash

      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          instance_id,
          %{manifest: manifest, script_source: script},
          wrong_hash,
          actor_id,
          prefix: schema_name
        )

      assert {:error, {:manifest_hash_mismatch, ^wrong_hash, ^real_hash}} = result
      assert audit_rows(schema_name) == []
    end

    test "a stale registered_hash from a prior manifest version still fails INV-LSA-2, even though validate_at_load/3 itself already succeeded once" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      script = "return 1 + 1"
      original_manifest = %Manifest{script_id: "req158-script", capabilities: ["variable:read"]}
      stale_hash = Manifest.compute_hash(original_manifest, script)

      # validate_at_load/3 succeeds against the ORIGINAL manifest -- Manifest's own
      # gate has no way to know a race is about to change what gets executed.
      assert {:ok, ^stale_hash} =
               Manifest.validate_at_load(original_manifest, script, stale_hash)

      # But the manifest actually executed has since changed (simulating a race
      # between load-time validation and execution) -- Manifest's own successful
      # gate result must not suppress or substitute for LuaScriptAudit's
      # independent post-execution check.
      changed_manifest = %Manifest{
        script_id: "req158-script",
        capabilities: ["variable:read", "variable:write"]
      }

      actual_hash = Manifest.compute_hash(changed_manifest, script)
      assert actual_hash != stale_hash

      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          instance_id,
          %{manifest: changed_manifest, script_source: script},
          stale_hash,
          actor_id,
          prefix: schema_name
        )

      assert {:error, {:manifest_hash_mismatch, ^stale_hash, ^actual_hash}} = result
      assert audit_rows(schema_name) == []
    end
  end
end
