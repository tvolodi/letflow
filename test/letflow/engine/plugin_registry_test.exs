defmodule Letflow.Engine.PluginRegistryTest do
  @moduledoc """
  Tests for REQ-057's `Letflow.Engine.PluginRegistry` -- registration errors
  (AC4), SVC-02 scoping errors + cross-tenant resolution isolation (AC5),
  built-in-shadowing precedence (AC6), and the moduledoc scope-boundary
  assertions (AC7). See `lib/letflow/design/req057-plugin-interface-registry.md`
  §3-§6 (the gate-approved design this module implements) and
  `test/specs/REQ-057.md` for the full rationale.

  ## Why this file is `async: false` and restarts a real supervised child

  `Letflow.Engine.PluginRegistry` is a single, named-singleton `GenServer`
  (`lib/letflow/application.ex`) owning a single, fixed-named ETS table
  (`Letflow.Engine.PluginRegistry.Table`) -- there is no way to run a second,
  independently-seeded instance alongside it (the `:named_table` name is a
  module attribute, not parameterized by process name, unlike
  `Letflow.SandboxPool`'s own `:name` option precedent). `init/1` also
  freezes the registry automatically the instant a boot's seed list finishes
  processing successfully (design doc §6.4) -- so the live, app-booted
  instance (seeded from `Application.get_env(:letflow, :plugin_handlers, [])`,
  empty by default under `config/test.exs`) is *always* already frozen by the
  time any test runs. That is sufficient, on its own, to test AC4's
  `registry_frozen` error directly against the live singleton (no restart
  needed -- see the first `describe` block below). Every OTHER registration
  error (`nil_handler`, `invalid_node_type`, the two SVC-02 scoping errors,
  `incompatible_api_version`, `duplicate_node_type`) can only ever be
  observed at SEED time (`do_register/2` runs with `frozen?: false` only
  inside `seed_registrations/1`, design doc §6.1/§6.4) -- so this file
  restarts the real, application-supervised child with a deliberately
  malformed seed list via `Supervisor.start_child(Letflow.Supervisor,
  {PluginRegistry, seed_list})`, asserts on the resulting boot failure, then
  restores the default (empty) registry in `on_exit` before the next test
  runs. AC5's cross-tenant/AC6's shadowing tests restart it with a
  deliberately VALID seed list instead, for the same reason -- there is no
  other way to get a live, resolvable registration into this singleton from
  a test.

  This is why `async: true` would be unsafe here (this file mutates a
  node-wide singleton child of `Letflow.Supervisor`) -- every test either
  reads the always-frozen default registry (safe) or brackets its own
  mutation with `seed_registry!/1` + `on_exit` restoration (serialized,
  `async: false`, matching `engine_execution_error_test.exs`'s own
  `async: false` precedent for a different reason -- shared real Postgres
  state there, a shared OTP singleton here).
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.PluginRegistry

  defmodule OkHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context), do: {:complete, %{}}
  end

  defmodule OkHandler2 do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context), do: {:complete, %{}}
  end

  # ---------------------------------------------------------------------
  # Restart helpers -- see moduledoc above for why this is necessary.
  # ---------------------------------------------------------------------

  defp stop_registry_child do
    case Supervisor.terminate_child(Letflow.Supervisor, PluginRegistry) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(Letflow.Supervisor, PluginRegistry) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restore_default_registry do
    stop_registry_child()
    {:ok, _pid} = Supervisor.start_child(Letflow.Supervisor, {PluginRegistry, []})
    :ok
  end

  # Restarts the real, application-supervised PluginRegistry child with
  # `seed_list`, schedules restoration of the default (empty) registry after
  # this test, and returns whatever Supervisor.start_child/2 returned --
  # {:ok, pid} on a valid seed list, {:error, {:invalid_plugin_registration,
  # registration_error()}} on a malformed one (init/1 stopping itself,
  # design doc §6.4).
  defp seed_registry!(seed_list) do
    stop_registry_child()
    on_exit(fn -> restore_default_registry() end)
    Supervisor.start_child(Letflow.Supervisor, {PluginRegistry, seed_list})
  end

  defp unique_key(prefix \\ "PLUGIN") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Supervisor.start_child/2 wraps a failed start_link/1 as
  # {:error, {start_link_error, child_spec}} -- start_link_error here is
  # init/1's own {:stop, {:invalid_plugin_registration, reason}} reason
  # (design doc §6.4). This extracts just the registration_error() atom a
  # test cares about, so each test asserts on the one thing that's actually
  # distinct per error, not the (identical every time) child_spec noise.
  defp registration_start_error_reason(
         {:error, {{:invalid_plugin_registration, reason}, _child_spec}}
       ),
       do: reason

  # ---------------------------------------------------------------------
  # AC4 -- registry_frozen, tested directly against the live default
  # singleton (always frozen post-boot -- no restart needed).
  # ---------------------------------------------------------------------

  describe "register_plugin_handler/1 -- registry_frozen (AC4)" do
    test "any post-boot registration attempt against the live singleton is rejected -- it is always frozen" do
      assert {:error, :registry_frozen} =
               PluginRegistry.register_plugin_handler(%{
                 handler_key: unique_key(),
                 handler: OkHandler,
                 scope: :global
               })
    end
  end

  # ---------------------------------------------------------------------
  # AC4 -- the other five, distinct, pattern-matchable registration errors,
  # each triggered at seed time (see moduledoc).
  # ---------------------------------------------------------------------

  describe "register_plugin_handler/1 -- nil_handler (AC4)" do
    test "a nil handler is rejected with its own distinct error" do
      seed = [%{handler_key: unique_key(), handler: nil, scope: :global}]

      assert registration_start_error_reason(seed_registry!(seed)) == :nil_handler
    end
  end

  describe "register_plugin_handler/1 -- invalid_node_type (AC4)" do
    test "a blank handler_key is rejected with its own distinct error" do
      seed = [%{handler_key: "", handler: OkHandler, scope: :global}]

      assert registration_start_error_reason(seed_registry!(seed)) == :invalid_node_type
    end
  end

  describe "register_plugin_handler/1 -- incompatible_api_version (AC4)" do
    test "an api_version that does not match supported_api_version/0 is rejected with its own distinct error" do
      assert PluginRegistry.supported_api_version() == 1

      seed = [
        %{handler_key: unique_key(), handler: OkHandler, scope: :global, api_version: 2}
      ]

      assert registration_start_error_reason(seed_registry!(seed)) == :incompatible_api_version
    end
  end

  describe "register_plugin_handler/1 -- duplicate_node_type (AC4)" do
    test "registering the identical {handler_key, scope, owner_tenant_id} triple twice is rejected with its own distinct error" do
      entry = %{handler_key: unique_key(), handler: OkHandler, scope: :global}

      assert registration_start_error_reason(seed_registry!([entry, entry])) ==
               :duplicate_node_type
    end

    test "registering the same handler_key under two DIFFERENT scopes is NOT a duplicate" do
      key = unique_key()
      tenant_id = Ecto.UUID.generate()

      seed = [
        %{handler_key: key, handler: OkHandler, scope: :global},
        %{handler_key: key, handler: OkHandler2, scope: :tenant, owner_tenant_id: tenant_id}
      ]

      assert {:ok, _pid} = seed_registry!(seed)
    end
  end

  # ---------------------------------------------------------------------
  # AC5 -- the two SVC-02 scoping errors, each distinct.
  # ---------------------------------------------------------------------

  describe "register_plugin_handler/1 -- tenant_scoped_plugin_requires_owner_id (AC5)" do
    test "a :tenant-scoped registration without owner_tenant_id is rejected with its own distinct error" do
      seed = [%{handler_key: unique_key(), handler: OkHandler, scope: :tenant}]

      assert registration_start_error_reason(seed_registry!(seed)) ==
               :tenant_scoped_plugin_requires_owner_id
    end
  end

  describe "register_plugin_handler/1 -- global_plugin_must_not_have_owner_id (AC5)" do
    test "a :global-scoped registration WITH an owner_tenant_id is rejected with its own distinct error" do
      seed = [
        %{
          handler_key: unique_key(),
          handler: OkHandler,
          scope: :global,
          owner_tenant_id: Ecto.UUID.generate()
        }
      ]

      assert registration_start_error_reason(seed_registry!(seed)) ==
               :global_plugin_must_not_have_owner_id
    end
  end

  # ---------------------------------------------------------------------
  # AC5 -- resolution for tenant B never returns tenant A's tenant-scoped
  # handler; a tenant-scoped registration for the caller's own tenant wins
  # over a coexisting global one (design doc §5.2's own two-step order).
  # ---------------------------------------------------------------------

  describe "resolve_plugin_handler_for_tenant/2 -- cross-tenant isolation (AC5)" do
    test "tenant B's lookup never returns tenant A's tenant-scoped registration" do
      key = unique_key()
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()

      seed = [%{handler_key: key, handler: OkHandler, scope: :tenant, owner_tenant_id: tenant_a}]

      assert {:ok, _pid} = seed_registry!(seed)

      assert {:error, :not_registered} =
               PluginRegistry.resolve_plugin_handler_for_tenant(key, tenant_b)

      assert {:ok, registration} = PluginRegistry.resolve_plugin_handler_for_tenant(key, tenant_a)
      assert registration.owner_tenant_id == tenant_a
      assert registration.handler == OkHandler
    end

    test "tenant-scoped wins for its own tenant, but a DIFFERENT tenant still gets the global fallback" do
      key = unique_key()
      tenant_a = Ecto.UUID.generate()
      other_tenant = Ecto.UUID.generate()

      seed = [
        %{handler_key: key, handler: OkHandler, scope: :global},
        %{handler_key: key, handler: OkHandler2, scope: :tenant, owner_tenant_id: tenant_a}
      ]

      assert {:ok, _pid} = seed_registry!(seed)

      assert {:ok, tenant_a_registration} =
               PluginRegistry.resolve_plugin_handler_for_tenant(key, tenant_a)

      assert tenant_a_registration.handler == OkHandler2
      assert tenant_a_registration.scope == :tenant

      assert {:ok, global_registration} =
               PluginRegistry.resolve_plugin_handler_for_tenant(key, other_tenant)

      assert global_registration.handler == OkHandler
      assert global_registration.scope == :global
    end

    test "no registration under handler_key at all resolves to {:error, :not_registered}" do
      assert {:error, :not_registered} =
               PluginRegistry.resolve_plugin_handler_for_tenant(
                 unique_key(),
                 Ecto.UUID.generate()
               )
    end
  end

  # ---------------------------------------------------------------------
  # AC6 -- a plugin registered for a node_type that also has a REAL built-in
  # handler (HUMAN_TASK -- one of Transition's 5 genuinely-implemented
  # dispatch clauses, design doc §0) shadows it, demonstrated by an explicit
  # before/after test.
  # ---------------------------------------------------------------------

  describe "resolve_node_handler_kind/1 -- plugin precedence over a real built-in (AC6)" do
    test "HUMAN_TASK resolves :builtin before registration, :plugin after -- the built-in is shadowed" do
      assert PluginRegistry.resolve_node_handler_kind("HUMAN_TASK") == :builtin

      seed = [%{handler_key: "HUMAN_TASK", handler: OkHandler, scope: :global}]
      assert {:ok, _pid} = seed_registry!(seed)

      assert PluginRegistry.resolve_node_handler_kind("HUMAN_TASK") == :plugin
    end

    test "an unregistered handler_key resolves to :builtin" do
      assert PluginRegistry.resolve_node_handler_kind(unique_key("NEVER_REGISTERED")) == :builtin
    end
  end

  # ---------------------------------------------------------------------
  # AC7 -- moduledoc scope-boundary content: WASM/S5, in-process-only, and
  # the registry-storage mechanism named. Following
  # engine_execution_error_test.exs's own AC6 moduledoc-inspection precedent
  # (REQ-061) exactly -- Code.fetch_docs/1 + a normalized substring match.
  # ---------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "moduledoc -- WASM/S5 scope boundary and in-process-only support statement (AC7)" do
    test "Letflow.Engine.PluginInterface names S5 as the WASM host's stage and states in-process-only support" do
      doc = normalized_moduledoc(Letflow.Engine.PluginInterface)

      assert doc =~ "S5"
      assert doc =~ "no WASM sandboxing"
      assert doc =~ "PluginInterface` supports **only in-process Elixir modules**"
    end

    test "Letflow.Engine.PluginRegistry names S5 as the WASM host's stage and states in-process-only support" do
      doc = normalized_moduledoc(PluginRegistry)

      assert doc =~ "S5"
      assert doc =~ "no WASM host"
      assert doc =~ "This module supports **only in-process Elixir modules**"
    end
  end

  describe "moduledoc -- names the registry-storage mechanism (AC7)" do
    test "Letflow.Engine.PluginRegistry's moduledoc names and explains the chosen storage mechanism" do
      doc = normalized_moduledoc(PluginRegistry)

      assert doc =~ "Storage mechanism"
      assert doc =~ "GenServer"
      assert doc =~ "ETS table"
    end
  end
end
