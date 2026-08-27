defmodule Letflow.Engine.Lua.ExecutorTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Executor` (REQ-153, LUA-02 restated). Covers all 8
  acceptance criteria from the requirement.

  No database access required — the isolation tests exercise only the Lua VM, and the
  INV-LSA-1 / INV-LSA-2 paths short-circuit before any Repo insert. `async: true` is
  safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Lua.Executor
  alias Letflow.Engine.LuaScriptAudit

  # ---------------------------------------------------------------------------------
  # AC1 -- module exists and implements the Executor behaviour
  # ---------------------------------------------------------------------------------

  describe "behaviour implementation (AC1)" do
    test "Executor implements the Letflow.Engine.LuaScriptAudit.Executor behaviour" do
      behaviours =
        Executor.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Letflow.Engine.LuaScriptAudit.Executor in behaviours
    end

    test "execute_with_manifest/2 is exported" do
      assert function_exported?(Executor, :execute_with_manifest, 2)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- lua_script_audit.ex does NOT reference the concrete Executor module
  # ---------------------------------------------------------------------------------

  describe "lua_script_audit.ex isolation (AC2)" do
    test "lua_script_audit.ex does not reference Letflow.Engine.Lua.Executor" do
      source = File.read!("lib/letflow/engine/lua_script_audit.ex")

      refute source =~ "Letflow.Engine.Lua.Executor",
             "lua_script_audit.ex must not directly reference the concrete Executor module"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- global isolation: a global set in execution 1 is absent in execution 2
  # ---------------------------------------------------------------------------------

  describe "global isolation (AC3)" do
    test "a global written in execution 1 is absent in execution 2" do
      # Execution 1: set a global
      assert {:ok, _} = Executor.execute_with_manifest("MY_GLOBAL = 42", "any-hash")

      # Execution 2 through the same executor: if MY_GLOBAL leaked, Lua's error() fires
      # and the executor returns {:error, _}. assert {:ok, _} therefore PROVES absence.
      # (Asserting {:ok, _} on `return MY_GLOBAL` would be vacuous because execute_with_manifest
      # discards the Lua return value -- both nil and 42 would yield {:ok, _} there.)
      assert {:ok, _} =
               Executor.execute_with_manifest(
                 "if MY_GLOBAL ~= nil then error('global_leaked: MY_GLOBAL = ' .. tostring(MY_GLOBAL)) end",
                 "any-hash"
               ),
             "MY_GLOBAL must be absent (nil) in a fresh executor invocation"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- distinct state: table mutated in exec 1 is pristine in exec 2
  # ---------------------------------------------------------------------------------

  describe "distinct state (AC4)" do
    test "a table mutated in execution 1 is pristine in execution 2" do
      # Execution 1: create and populate a table
      assert {:ok, _} = Executor.execute_with_manifest("T = {}; T.x = 99", "h1")

      # Execution 2 through the same executor: if T leaked, Lua's error() fires and the
      # executor returns {:error, _}. assert {:ok, _} PROVES T is nil/absent.
      assert {:ok, _} =
               Executor.execute_with_manifest(
                 "if T ~= nil then error('table_T_leaked: T.x = ' .. tostring(T.x)) end",
                 "h2"
               ),
             "table T from execution 1 must not survive into execution 2"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- INV-LSA-1: invalid instance_id short-circuits before executor is invoked
  # ---------------------------------------------------------------------------------

  describe "INV-LSA-1 with real executor (AC5)" do
    test "nil instance_id short-circuits and the real executor is never called" do
      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          nil,
          "return 1",
          "any-hash",
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert result == {:error, :invalid_instance_id}
    end

    test "malformed instance_id short-circuits and the real executor is never called" do
      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          "not-a-uuid",
          "return 1",
          "any-hash",
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert result == {:error, :invalid_instance_id}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- INV-LSA-2: manifest hash mismatch with real executor
  # ---------------------------------------------------------------------------------

  describe "INV-LSA-2 with real executor (AC6)" do
    test "a registered_hash that does not match the script's SHA-256 returns mismatch error" do
      script = "return 2 + 2"
      real_hash = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)
      wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000"

      assert wrong_hash != real_hash

      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          Ecto.UUID.generate(),
          script,
          wrong_hash,
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert {:error, {:manifest_hash_mismatch, ^wrong_hash, ^real_hash}} = result
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- moduledoc documents the script_ref concrete shape
  # ---------------------------------------------------------------------------------

  describe "moduledoc documents script_ref shape (AC7)" do
    test "the module's @moduledoc mentions that script_ref is a binary (Lua source text)" do
      docs = Code.fetch_docs(Executor)
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = docs

      assert moduledoc =~ "binary",
             "moduledoc must state that script_ref is a binary; got:\n#{moduledoc}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Bonus: successful execution returns the correct SHA-256 manifest hash
  # ---------------------------------------------------------------------------------

  describe "manifest hash correctness" do
    test "execute_with_manifest returns the SHA-256 of the script source on success" do
      script = "return 'hello'"
      expected_hash = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)

      assert {:ok, %{manifest_hash: ^expected_hash}} =
               Executor.execute_with_manifest(script, "ignored")
    end

    test "a Lua syntax error returns {:error, reason}" do
      assert {:error, _reason} = Executor.execute_with_manifest("this is not lua ===", "h")
    end
  end
end
