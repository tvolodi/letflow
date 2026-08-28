defmodule Letflow.Engine.Wasm.ModuleVersionRegistryTest do
  @moduledoc """
  REQ-173 (WASM-14) -- coverage for `Letflow.Engine.Wasm.ModuleVersionRegistry`.
  See `lib/letflow/design/req173-wasm-module-hot-reload.md` (gate-approved,
  commit c7d10ea) and `test/specs/REQ-173.md` for the full design/spec this
  suite exercises -- in particular `test/specs/REQ-173.md`'s "Blocking
  finding" section, which this file's first `describe` block both reproduces
  and documents: `ModuleRegistry.register/1`'s stage-2 real-instantiation
  attempt (`module_registry.ex`, unmodified by this requirement, reused
  verbatim by `register_version/3`) always calls `Wasmex.start_link/1` with
  NO import table at all (`imports: %{}`, `wasmex.ex:229`) -- so it
  unconditionally rejects ANY module declaring even one host-function import,
  regardless of what capability manifest is supplied to `register_version/3`.
  This blocks the exact `req173_v1_gated.wat`/`req173_v2_gated.wat` scenario
  design SS8.2/SS8.4 specifies (a real, controllable host-call gate is the
  only way to hold an invocation open per SS8.1 -- and any such call requires
  a declared import). The `describe "SS8.4: the one overlapping scenario ..."`
  block below is written EXACTLY per the design's own prescribed mechanism and
  is expected -- and, at time of writing, confirmed -- to fail at its very
  first step (`register_version/3` for `req173_v1_gated.wat`) for this reason,
  not because of a flaw in this test. It is kept, not deleted, because it
  correctly encodes WASM-14/AC5 and will start passing (no test edit needed)
  the moment a future ELIXIR-DEV fix makes `register_version/3` build a real,
  manifest-derived import table for its own proving instantiation instead of
  delegating that stage verbatim to `ModuleRegistry.register/1`.

  The remaining `describe` blocks below use `req173_v1_capless.wat`/
  `req173_v2_capless.wat` (zero imports, so they DO pass registration) to give
  genuine, passing coverage of every part of WASM-14/AC1-AC4 that does not
  require an actually-held-open invocation, plus AC5's design SS8.4 step 14
  "defense in depth" manifest-disjointness check, which needs no WASM
  execution at all.

  `async: false`: builds real Wasmtime instances via `wasmex`'s NIF (mirrors
  every other WASM-NIF test file in this suite), AND drives the single,
  supervised `ModuleVersionRegistry` GenServer singleton shared by the whole
  test run -- every test uses a fresh, unique `module_name` (via
  `unique_module_name/1`) so no test can observe another test's state.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Wasm.CapabilityGate
  alias Letflow.Engine.Wasm.HostApi
  alias Letflow.Engine.Wasm.ModuleVersionRegistry
  alias Letflow.Test.Req173BlockingServiceCaller

  @v1_manifest %{capabilities: ["service:call"]}
  @v2_manifest %{capabilities: ["var:write"]}
  @capless_manifest %{capabilities: []}

  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  # Fresh module_name per test -- this GenServer is a single, long-lived
  # singleton shared by the whole test run (never reset between tests), per
  # design SS2's "registry_state()" being a straightforward, permanent map --
  # so cross-test isolation depends entirely on using a unique key per test,
  # exactly as TEST-DESIGN-VALIDATOR's own checklist requires.
  defp unique_module_name(tag) do
    "req173-#{tag}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # ---------------------------------------------------------------------
  # Blocking finding: register_version/3 rejects ANY module with a real
  # host import, regardless of manifest -- reproduced and documented here.
  # See test/specs/REQ-173.md for the full write-up.
  # ---------------------------------------------------------------------

  describe "blocking finding: register_version/3 cannot register a module that declares a host import" do
    test "req173_v1_gated.wat (imports platform_call_service) is rejected at registration, not merely denied capability at invoke time" do
      module_name = unique_module_name("blocking-v1")

      assert {:error, {:instantiation_failed, {:unresolved_import, "env", "platform_call_service"}}} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_gated.wat"),
                 @v1_manifest
               )
    end

    test "req173_v2_gated.wat (imports write_variable) is rejected at registration too -- the defect is blanket, not specific to one import" do
      module_name = unique_module_name("blocking-v2")

      assert {:error, {:instantiation_failed, {:unresolved_import, "env", "write_variable"}}} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v2_gated.wat"),
                 @v2_manifest
               )
    end

    test "the same v1 bytes register successfully once the module declares zero imports (req173_v1_capless.wat), confirming the import declaration -- not anything else about the fixture -- is what stage 2 rejects" do
      module_name = unique_module_name("blocking-control")

      assert {:ok, _version_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_capless.wat"),
                 @capless_manifest
               )
    end
  end

  # ---------------------------------------------------------------------
  # design SS8.4 -- the ONE overlapping scenario, written exactly per the
  # design's own prescribed mechanism. Expected (and, at time of writing,
  # confirmed) to fail at step 1 for the reason documented above and in
  # test/specs/REQ-173.md -- kept because it correctly encodes WASM-14/AC5
  # and needs no edit once the blocking finding above is fixed.
  # ---------------------------------------------------------------------

  describe "design SS8.4: the one overlapping scenario (held invocation completes against OLD version, concurrent invocation observes NEW version, capability isolation both directions)" do
    setup do
      {:ok, _gate} = Req173BlockingServiceCaller.start_gate()
      previous = Req173BlockingServiceCaller.arm()
      on_exit(fn -> Req173BlockingServiceCaller.restore(previous) end)
      :ok
    end

    test "AC1+AC2+AC3+AC4+AC5 in one overlapping scenario" do
      module_name = unique_module_name("overlap")

      # Step 1
      assert {:ok, v1_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_gated.wat"),
                 @v1_manifest
               )

      assert :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      # Step 3 -- invocation A, asynchronous: this call will not return until
      # the gate is released.
      task_a =
        Task.async(fn ->
          ModuleVersionRegistry.invoke(module_name, "run", [], HostApi.empty_execution_context(), 5_000)
        end)

      # Step 4 -- synchronous wait on the gate, never a sleep.
      assert :ok = Req173BlockingServiceCaller.await_parked(5_000)

      # Step 5
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :active

      # Step 6
      assert {:ok, v2_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v2_gated.wat"),
                 @v2_manifest
               )

      assert :ok = ModuleVersionRegistry.activate(module_name, v2_id)

      # Step 7
      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v2_id}

      # Step 8 -- AC4 (release timing): superseded, NOT released, while A is
      # still parked.
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :superseded

      # Step 9 -- AC2: a new invocation started AFTER activation observes the
      # NEW version, and (per the disjoint manifests) only succeeds because it
      # was instantiated against v2_manifest's grant of "var:write".
      result_b =
        ModuleVersionRegistry.invoke(module_name, "run", [], HostApi.empty_execution_context(), 5_000)

      assert {:ok, ^v2_id, [222]} = result_b

      # Step 10
      :ok = Req173BlockingServiceCaller.release()

      # Step 11 -- AC1: the held invocation completes against the OLD
      # version's behaviour, only reachable via v1_manifest's grant of
      # "service:call".
      result_a = Task.await(task_a, 5_000)
      assert {:ok, ^v1_id, [111]} = result_a

      # Step 12 -- AC4: release actually fires now, immediately after A's own
      # release call, with no further external action.
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :released

      # Step 13 -- AC3, explicit.
      assert result_a != result_b

      # Step 14 -- AC5 defense-in-depth: the manifests themselves are as
      # disjoint as claimed, independent of invoke/4's own code.
      table_v1 = CapabilityGate.build_import_table(@v1_manifest, HostApi.empty_execution_context())
      table_v2 = CapabilityGate.build_import_table(@v2_manifest, HostApi.empty_execution_context())

      assert Map.has_key?(table_v1["env"], "platform_call_service")
      refute Map.has_key?(table_v1["env"], "write_variable")
      assert Map.has_key?(table_v2["env"], "write_variable")
      refute Map.has_key?(table_v2["env"], "platform_call_service")
    end
  end

  # ---------------------------------------------------------------------
  # What IS testable without a held-open invocation: sequential version
  # switching, error-path contracts, idempotent activation, and the
  # "nothing to wait for" release trigger (design SS6 trigger point 2).
  # ---------------------------------------------------------------------

  describe "register_version/3 + activate/2 + current_version/1 + version_status/2 -- sequential (non-overlapping) mechanics" do
    test "a brand-new module has no current version until activate/2 is called" do
      module_name = unique_module_name("no-auto-activate")

      assert {:ok, v1_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_capless.wat"),
                 @capless_manifest
               )

      assert ModuleVersionRegistry.current_version(module_name) ==
               {:error, {:no_active_version, module_name}}

      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :superseded
    end

    test "activate/2 makes a version current, and a later invocation resolves to it, returning its own distinct literal" do
      module_name = unique_module_name("activate-then-invoke")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v1_id}

      assert {:ok, ^v1_id, [111]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "run",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )
    end

    test "activating a second version supersedes the first; a new invocation observes the new version and its own distinct literal (AC2/AC3, non-overlapping case)" do
      module_name = unique_module_name("second-version")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      assert {:ok, ^v1_id, [111]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "run",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )

      {:ok, v2_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v2_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v2_id)

      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v2_id}

      assert {:ok, ^v2_id, [222]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "run",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )
    end

    test "design SS6 trigger point 2: activating away from a version whose ref_count is already 0 releases it IMMEDIATELY, inside the same activate/2 call -- the \"nothing to wait for\" case" do
      module_name = unique_module_name("immediate-release")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      # No invocation was ever made against v1 -- ref_count is still 0.
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :active

      {:ok, v2_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v2_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v2_id)

      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :released
    end

    test "a no-op activation (activating the already-current version) is idempotent and does not release it" do
      module_name = unique_module_name("noop-activate")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)
      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v1_id}
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :active
    end

    test "current_version/1 for an unknown module_name" do
      module_name = unique_module_name("unknown")

      assert ModuleVersionRegistry.current_version(module_name) ==
               {:error, {:unknown_module, module_name}}
    end

    test "activate/2 for an unknown module_name" do
      module_name = unique_module_name("unknown-activate")

      assert ModuleVersionRegistry.activate(module_name, 1) ==
               {:error, {:unknown_module, module_name}}
    end

    test "activate/2 for a known module but an unregistered version_id" do
      module_name = unique_module_name("unknown-version")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      bogus_version_id = v1_id + 100

      assert ModuleVersionRegistry.activate(module_name, bogus_version_id) ==
               {:error, {:unknown_version, module_name, bogus_version_id}}
    end

    test "version_status/2 for an unknown module_name and unknown version_id" do
      module_name = unique_module_name("status-unknown")

      assert ModuleVersionRegistry.version_status(module_name, 1) ==
               {:unknown_module, module_name}

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      assert ModuleVersionRegistry.version_status(module_name, v1_id + 100) ==
               {:unknown_version, module_name}
    end

    test "invoke/4 against a module with no active version" do
      module_name = unique_module_name("no-active")

      {:ok, _v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      assert ModuleVersionRegistry.invoke(
               module_name,
               "run",
               [],
               HostApi.empty_execution_context(),
               5_000
             ) == {:error, {:no_active_version, module_name}}
    end

    test "invoke/4 against a wholly unknown module_name" do
      module_name = unique_module_name("wholly-unknown")

      assert ModuleVersionRegistry.invoke(
               module_name,
               "run",
               [],
               HostApi.empty_execution_context(),
               5_000
             ) == {:error, {:unknown_module, module_name}}
    end
  end

  # ---------------------------------------------------------------------
  # AC5 (design SS8.4 step 14) -- the manifest-disjointness "defense in
  # depth" check needs no WASM execution at all, so it is unaffected by the
  # blocking finding above.
  # ---------------------------------------------------------------------

  describe "AC5 defense in depth: v1_manifest/v2_manifest are disjoint, independent of invoke/4's own code" do
    test "v1_manifest grants platform_call_service only" do
      table = CapabilityGate.build_import_table(@v1_manifest, HostApi.empty_execution_context())

      assert Map.has_key?(table["env"], "platform_call_service")
      refute Map.has_key?(table["env"], "write_variable")
    end

    test "v2_manifest grants write_variable only" do
      table = CapabilityGate.build_import_table(@v2_manifest, HostApi.empty_execution_context())

      assert Map.has_key?(table["env"], "write_variable")
      refute Map.has_key?(table["env"], "platform_call_service")
    end
  end
end
