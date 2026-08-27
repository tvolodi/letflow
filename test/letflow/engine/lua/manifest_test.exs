defmodule Letflow.Engine.Lua.ManifestTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Manifest` (REQ-158, LUA-07 load-time half). See
  `test/specs/REQ-158.md` for the full test-case rationale and the
  acceptance-criteria mapping, and
  `lib/letflow/design/req158-lua-manifest-validation.md` for the design.

  No database, no `Repo`, no Ecto sandbox is needed anywhere in this file — every
  function this requirement adds to `Letflow.Engine.Lua.Manifest` is pure
  (design §3.1, INV-MAN-1/INV-MAN-2). `async: true` is safe.

  The end-to-end test proving the manifest hash flows into
  `Letflow.Engine.LuaScriptAudit`'s persisted audit row (AC3, design §5.3.1) and
  the test proving a mismatch still yields `LuaScriptAudit`'s own
  `{:manifest_hash_mismatch, ...}` error (AC4) both require a real Postgres tenant
  schema and live in
  `test/letflow/engine/lua/manifest_executor_audit_test.exs` instead.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Lua.Executor
  alias Letflow.Engine.Lua.Manifest

  # ---------------------------------------------------------------------------------
  # 1. Manifest struct and shape validation (AC1, AC5)
  # ---------------------------------------------------------------------------------

  describe "validate_shape/1" do
    test "returns :ok for a non-empty string script_id and a list of string capabilities" do
      manifest = %Manifest{script_id: "script-1", capabilities: ["variable:read", "platform.now"]}
      assert :ok = Manifest.validate_shape(manifest)
    end

    test "returns :ok for an empty capabilities list" do
      assert :ok = Manifest.validate_shape(%Manifest{script_id: "script-1", capabilities: []})
    end

    test "rejects a nil script_id with a distinct, pattern-matchable error" do
      manifest = %Manifest{script_id: nil, capabilities: []}
      assert {:error, {:invalid_script_id, nil}} = Manifest.validate_shape(manifest)
    end

    test "rejects an empty-string script_id" do
      manifest = %Manifest{script_id: "", capabilities: []}
      assert {:error, {:invalid_script_id, ""}} = Manifest.validate_shape(manifest)
    end

    test "rejects a non-string script_id" do
      manifest = %Manifest{script_id: 123, capabilities: []}
      assert {:error, {:invalid_script_id, 123}} = Manifest.validate_shape(manifest)
    end

    test "rejects capabilities that is not a list" do
      manifest = %Manifest{script_id: "script-1", capabilities: "not-a-list"}
      assert {:error, {:invalid_capabilities, "not-a-list"}} = Manifest.validate_shape(manifest)
    end

    test "rejects a capabilities list containing a non-string element" do
      manifest = %Manifest{script_id: "script-1", capabilities: ["variable:read", :not_a_string]}
      assert {:error, {:invalid_capabilities, _}} = Manifest.validate_shape(manifest)
    end
  end

  # ---------------------------------------------------------------------------------
  # 2. Hash determinism and canonicalization (AC5)
  # ---------------------------------------------------------------------------------

  describe "compute_hash/2 determinism and canonicalization" do
    test "identical manifest and script source produce the identical hash both times" do
      manifest = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}
      script = "return 1"

      assert Manifest.compute_hash(manifest, script) == Manifest.compute_hash(manifest, script)
    end

    test "capability list order does not affect the hash" do
      script = "return 1"
      manifest_a = %Manifest{script_id: "script-1", capabilities: ["a", "b", "c"]}
      manifest_b = %Manifest{script_id: "script-1", capabilities: ["c", "a", "b"]}

      assert Manifest.compute_hash(manifest_a, script) ==
               Manifest.compute_hash(manifest_b, script)
    end

    test "duplicate capability entries do not affect the hash" do
      script = "return 1"
      manifest_with_dupe = %Manifest{script_id: "script-1", capabilities: ["a", "a", "b"]}
      manifest_without_dupe = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}

      assert Manifest.compute_hash(manifest_with_dupe, script) ==
               Manifest.compute_hash(manifest_without_dupe, script)
    end

    test "produces a lowercase 64-character hex string" do
      manifest = %Manifest{script_id: "script-1", capabilities: ["a"]}
      hash = Manifest.compute_hash(manifest, "return 1")

      assert String.length(hash) == 64
      assert hash == String.downcase(hash)
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end

  # ---------------------------------------------------------------------------------
  # 3. Hash sensitivity (AC1, AC5)
  # ---------------------------------------------------------------------------------

  describe "compute_hash/2 sensitivity" do
    test "adding a capability changes the hash" do
      script = "return 1"
      before = %Manifest{script_id: "script-1", capabilities: ["a"]}
      after_add = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}

      refute Manifest.compute_hash(before, script) == Manifest.compute_hash(after_add, script)
    end

    test "removing a capability changes the hash" do
      script = "return 1"
      before = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}
      after_remove = %Manifest{script_id: "script-1", capabilities: ["a"]}

      refute Manifest.compute_hash(before, script) == Manifest.compute_hash(after_remove, script)
    end

    test "changing script_id changes the hash (no cross-script collision)" do
      script = "return 1"
      manifest_a = %Manifest{script_id: "script-1", capabilities: ["a"]}
      manifest_b = %Manifest{script_id: "script-2", capabilities: ["a"]}

      refute Manifest.compute_hash(manifest_a, script) ==
               Manifest.compute_hash(manifest_b, script)
    end

    test "changing a single byte of script_source changes the hash" do
      manifest = %Manifest{script_id: "script-1", capabilities: ["a"]}

      refute Manifest.compute_hash(manifest, "return 1") ==
               Manifest.compute_hash(manifest, "return 2")
    end
  end

  # ---------------------------------------------------------------------------------
  # 4. Load-time rejection of a manifest modified after registration (AC1)
  # ---------------------------------------------------------------------------------

  describe "validate_at_load/3" do
    test "a manifest modified (capability added) after registration is rejected with {:manifest_mismatch, ...}" do
      script = "return 1"
      original_manifest = %Manifest{script_id: "script-1", capabilities: ["a"]}
      registered_hash = Manifest.compute_hash(original_manifest, script)

      modified_manifest = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}

      assert {:error, {:manifest_mismatch, ^registered_hash, computed_hash}} =
               Manifest.validate_at_load(modified_manifest, script, registered_hash)

      refute computed_hash == registered_hash
    end

    test "an unmodified manifest+source pair validates successfully with a matching hash" do
      script = "return 1"
      manifest = %Manifest{script_id: "script-1", capabilities: ["a"]}
      registered_hash = Manifest.compute_hash(manifest, script)

      assert {:ok, manifest_hash} = Manifest.validate_at_load(manifest, script, registered_hash)
      assert manifest_hash == registered_hash
    end

    test "a shape-invalid manifest short-circuits to {:invalid_manifest, _} before any hash is compared" do
      manifest = %Manifest{script_id: nil, capabilities: []}

      assert {:error, {:invalid_manifest, {:invalid_script_id, nil}}} =
               Manifest.validate_at_load(manifest, "return 1", "any-hash-at-all")
    end
  end

  # ---------------------------------------------------------------------------------
  # 5. Rejection happens before any script text executes (AC2)
  # ---------------------------------------------------------------------------------

  describe "load-time rejection happens before any execution (AC2)" do
    test "a bare recording double is never invoked when validate_at_load/3 rejects a modified manifest" do
      test_pid = self()
      recorder = fn -> send(test_pid, :executed) end

      script = "return 1"
      original_manifest = %Manifest{script_id: "script-1", capabilities: ["a"]}
      registered_hash = Manifest.compute_hash(original_manifest, script)
      modified_manifest = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}

      case Manifest.validate_at_load(modified_manifest, script, registered_hash) do
        {:ok, _hash} -> recorder.()
        {:error, _reason} -> :ok
      end

      refute_received :executed,
                      "the recording double must never run when the manifest is rejected"
    end

    test "Executor.execute_with_manifest/2 is never called when the caller respects validate_at_load/3's rejection" do
      script = "error('this must never run')"
      original_manifest = %Manifest{script_id: "script-1", capabilities: ["a"]}
      registered_hash = Manifest.compute_hash(original_manifest, script)
      modified_manifest = %Manifest{script_id: "script-1", capabilities: ["a", "b"]}

      # Caller-discipline simulation: only call the real Executor if the gate
      # passed. Since it will not pass here (modified manifest), Executor is
      # never invoked -- proven by never reaching the call, not by mocking.
      result =
        case Manifest.validate_at_load(modified_manifest, script, registered_hash) do
          {:ok, manifest_hash} ->
            Executor.execute_with_manifest(
              %{manifest: modified_manifest, script_source: script},
              manifest_hash
            )

          {:error, _reason} = error ->
            error
        end

      assert {:error, {:manifest_mismatch, _, _}} = result
    end
  end

  # ---------------------------------------------------------------------------------
  # 8. Moduledoc content (AC5, AC6)
  # ---------------------------------------------------------------------------------

  describe "moduledoc content (AC5, AC6)" do
    test "moduledoc states the hash algorithm, encoding, and exact byte layout" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Manifest)

      assert moduledoc =~ "SHA-256"
      assert moduledoc =~ "lowercase"
      assert moduledoc =~ "script_id"
      assert moduledoc =~ "0x00"
      assert moduledoc =~ "0x0A"
      assert moduledoc =~ "script_source"
    end

    test "moduledoc states R-Co's manifest.zig is absent from this checkout and no field is claimed deliberately dropped" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Manifest)

      assert moduledoc =~ "manifest.zig"
      assert moduledoc =~ "not present in this checkout"
      assert moduledoc =~ "No field of the original is named here as"
    end
  end

  # ---------------------------------------------------------------------------------
  # to_grant_set/1 -- REQ-157 reuse, one conversion point
  # ---------------------------------------------------------------------------------

  describe "to_grant_set/1" do
    test "delegates to Letflow.Engine.Lua.Capabilities.new/1" do
      manifest = %Manifest{
        script_id: "script-1",
        capabilities: ["variable:read", "variable:read"]
      }

      grant_set = Manifest.to_grant_set(manifest)

      assert Letflow.Engine.Lua.Capabilities.has?(grant_set, "variable:read")
      refute Letflow.Engine.Lua.Capabilities.has?(grant_set, "variable:write")
    end
  end
end
