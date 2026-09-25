defmodule Letflow.Modules.DefmanifestTest do
  @moduledoc """
  ISS-0806 AC1 — `defmanifest/1` raises a `CompileError` at macro-expansion
  time when a `role_grants` value atom is absent from `permissions`.

  Tests use `Code.compile_string/1` to exercise the compile-time check in
  isolation, so no running application or database is needed (`async: true`).
  """

  use ExUnit.Case, async: true

  @bad_module_source """
  defmodule Letflow.Test.BadManifestModule do
    @behaviour Letflow.Modules.Module
    import Letflow.Modules.Module, only: [defmanifest: 1]

    defmanifest(
      id: "bad",
      version: "0.0.1",
      depends_on: [],
      pack: nil,
      permissions: [:DeclaredPerm],
      role_grants: %{TASK_WORKER: [:UndeclaredPerm]},
      required_roles: [],
      settings_schema: nil,
      route_policies: []
    )
  end
  """

  @good_module_source """
  defmodule Letflow.Test.GoodManifestModule do
    @behaviour Letflow.Modules.Module
    import Letflow.Modules.Module, only: [defmanifest: 1]

    defmanifest(
      id: "good",
      version: "0.0.1",
      depends_on: [],
      pack: nil,
      permissions: [:DeclaredPerm],
      role_grants: %{TASK_WORKER: [:DeclaredPerm]},
      required_roles: [],
      settings_schema: nil,
      route_policies: []
    )
  end
  """

  describe "ISS-0806 AC1 — compile-time role_grants ⊆ permissions check" do
    test "raises CompileError when a role_grants atom is absent from permissions" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string(@bad_module_source)
        end

      assert error.description =~
               "role_grants atom :UndeclaredPerm is not declared in permissions"
    end

    test "CompileError message names the caller module" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string(@bad_module_source)
        end

      assert error.description =~ "Letflow.Test.BadManifestModule"
    end

    test "compiles cleanly when all role_grants atoms are in permissions" do
      # Should not raise — if it does, the test fails automatically.
      assert [{Letflow.Test.GoodManifestModule, _binary}] =
               Code.compile_string(@good_module_source)
    end

    test "Letflow.Modules.Fixture (uses defmanifest) satisfies @behaviour and returns correct manifest" do
      # AC1 positive path via the fixture that already uses defmanifest after ISS-0806.
      manifest = Letflow.Modules.Fixture.manifest()

      assert manifest.id == "fixture"
      assert manifest.permissions == [:FixtureRead]
      assert manifest.role_grants == %{TASK_WORKER: [:FixtureRead]}
      assert manifest.route_policies == [{"GET", "/items/:id", :FixtureRead}]
    end
  end
end
