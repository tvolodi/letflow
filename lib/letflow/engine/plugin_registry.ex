defmodule Letflow.Engine.PluginRegistry do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  REQ-057 (EXT-03) — the plugin registration/freeze/resolution table. Ports
  `plugin_registry.zig`'s registration/resolution contract — see
  `lib/letflow/design/req057-plugin-interface-registry.md` §3-§6 for the full
  design this module implements verbatim.

  ## Scope boundary

  This module supports **only in-process Elixir modules** implementing
  `Letflow.Engine.PluginInterface` — no dynamic code-loading, no WASM host
  (R-Co's `src/wasm/`, S5, needs its own build-vs-bind decision record
  first). It does **not** wire `resolve_node_handler_kind/1` /
  `resolve_plugin_handler_for_tenant/2` into the engine's actual node-dispatch
  path — that belongs to whichever future requirement builds runtime
  plugin/service-task dispatch (most plausibly REQ-056, `pending`).

  ## Storage mechanism — a supervised `GenServer` owning a private ETS table, reads bypassing the process

  A single, named-singleton `GenServer` (started once as a child of
  `Letflow.Supervisor`, matching `Letflow.SandboxPool`'s own precedent — not
  a per-instance `DynamicSupervisor` child of `Letflow.InstanceSupervisor`,
  see design doc §4.5) that, in `init/1`, creates a **private** ETS table it
  alone owns: `:bag`, `:protected`, `:named_table`, `read_concurrency: true`.
  `:bag`, not `:set`, is required so multiple co-existing registrations under
  one `handler_key` (a `:global` registration plus one or more
  `:tenant`-scoped registrations for different owners) are each independently
  retrievable by one `:ets.lookup/2` call — a `:set` table would silently let
  a later insert under the same `handler_key` overwrite an earlier one,
  breaking AC5.

  `register_plugin_handler/1` and `freeze_plugin_registry/1` are ordinary
  `GenServer.call/2` requests (serialized writes — registration only happens
  at startup, low volume, correctness over throughput). `resolve_node_handler_kind/1`
  and `resolve_plugin_handler_for_tenant/2` — the hot, read-mostly path any
  future runtime dispatch call site would call on every plugin-eligible node
  execution — perform a **direct `:ets.lookup/2` call from the caller's own
  process** (INV-PR-7), never a `GenServer.call/2`.

  `:persistent_term` and a compile-time module were both considered and
  rejected — see design doc §4.2 for the full reasoning (a `:persistent_term.put/2`
  per registered handler would pay a VM-wide sweep cost once per handler
  rather than once per boot; a compile-time module would contradict AC4's
  "startup-only, no dynamic loading **at runtime**" framing, since
  `handler: module()` values are resolved from runtime configuration).

  ## Immutability (AC4, INV-PR-3)

  `freeze_plugin_registry/1` is **irreversible for the lifetime of the
  running node** — no `unfreeze` function exists anywhere in this module's
  public contract. `Letflow.Engine.PluginRegistry.start_link/1` seeds the
  registry from its init argument and calls `freeze_plugin_registry/1` on
  itself automatically before `init/1` returns, so a freshly-booted node's
  registry is frozen the instant the supervision tree finishes starting.

  See `lib/letflow/design/req057-plugin-interface-registry.md` (gate-approved,
  1 rework iteration) for the full design this module ports.
  """

  use GenServer

  alias Letflow.Definitions.ServiceScopeValidator

  @table __MODULE__.Table
  @supported_api_version 1

  @typedoc "SVC-02 registration visibility."
  @type scope :: :global | :tenant

  @typedoc "One committed registration."
  @type registration :: %{
          handler_key: String.t(),
          handler: module(),
          scope: scope(),
          owner_tenant_id: Ecto.UUID.t() | nil,
          api_version: pos_integer(),
          registered_at: DateTime.t()
        }

  @typedoc "Attrs a caller supplies to `register_plugin_handler/1`."
  @type registration_attrs :: %{
          required(:handler_key) => String.t(),
          required(:handler) => module() | nil,
          required(:scope) => scope() | term(),
          optional(:owner_tenant_id) => Ecto.UUID.t() | nil,
          optional(:api_version) => pos_integer()
        }

  @typedoc "The seven distinct, pattern-matchable registration errors."
  @type registration_error ::
          {:error, :registry_frozen}
          | {:error, :nil_handler}
          | {:error, :invalid_node_type}
          | {:error, :incompatible_api_version}
          | {:error, :tenant_scoped_plugin_requires_owner_id}
          | {:error, :global_plugin_must_not_have_owner_id}
          | {:error, :duplicate_node_type}

  @typedoc "Reserved for a future flag (e.g. a `force: true` re-freeze-for-testing escape hatch) — currently always `[]`."
  @type freeze_opts :: []

  # Client API

  @doc """
  Starts the registry. `registrations` is the full seed list of
  `registration_attrs()` to register at boot (sourced by
  `lib/letflow/application.ex`'s `plugin_registrations_from_config/0`).
  Every seed entry is registered, then the registry is frozen automatically
  before this function returns `{:ok, pid}` — a malformed seed entry stops
  the whole node's boot loudly (`{:stop, {:invalid_plugin_registration, reason}}`)
  rather than silently starting with a partially-seeded, already-frozen
  registry.
  """
  @spec start_link(registrations :: [registration_attrs()]) :: GenServer.on_start()
  def start_link(registrations \\ []) when is_list(registrations) do
    GenServer.start_link(__MODULE__, registrations, name: __MODULE__)
  end

  @doc "See design doc §6.1 for the exact, ordered check sequence."
  @spec register_plugin_handler(registration_attrs()) ::
          {:ok, registration()} | registration_error()
  def register_plugin_handler(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:register_plugin_handler, attrs})
  end

  @doc "Irreversible for the lifetime of the running node (INV-PR-3)."
  @spec freeze_plugin_registry(opts :: freeze_opts()) :: :ok | {:error, :already_frozen}
  def freeze_plugin_registry(opts \\ []) when is_list(opts) do
    GenServer.call(__MODULE__, :freeze_plugin_registry)
  end

  @doc """
  Whether any registration exists under `handler_key`, in any scope
  (INV-PR-6). Built-in-agnostic — does not know or care whether
  `Letflow.Engine.Transition` actually has a dispatch clause for this type.
  A direct ETS read from the calling process — never a `GenServer.call/2`
  (INV-PR-7).
  """
  @spec resolve_node_handler_kind(handler_key :: String.t()) :: :builtin | :plugin
  def resolve_node_handler_kind(handler_key) when is_binary(handler_key) do
    case :ets.lookup(@table, handler_key) do
      [] -> :builtin
      _entries -> :plugin
    end
  end

  @doc """
  SVC-02 tenant-scoped resolution (AC5): a `:tenant`-scoped registration
  owned by `tenant_id` wins over a `:global` registration under the same
  `handler_key`; a `:tenant`-scoped registration owned by a *different*
  tenant is never returned. A direct ETS read from the calling process —
  never a `GenServer.call/2` (INV-PR-7).
  """
  @spec resolve_plugin_handler_for_tenant(handler_key :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, registration()} | {:error, :not_registered}
  def resolve_plugin_handler_for_tenant(handler_key, tenant_id)
      when is_binary(handler_key) and is_binary(tenant_id) do
    registrations = Enum.map(:ets.lookup(@table, handler_key), fn {^handler_key, reg} -> reg end)

    tenant_match =
      Enum.find(registrations, fn reg ->
        reg.scope == :tenant and reg.owner_tenant_id == tenant_id
      end)

    global_match = Enum.find(registrations, fn reg -> reg.scope == :global end)

    case tenant_match || global_match do
      nil -> {:error, :not_registered}
      %{} = registration -> {:ok, registration}
    end
  end

  @doc """
  The literal REQ-031 wiring — returns the 2-arity function value
  `Letflow.Definitions.ServiceScopeValidator.Lookup.plugin_lookup` requires,
  built by calling `resolve_plugin_handler_for_tenant/2` and projecting the
  result down to exactly the two fields that type needs.
  """
  @spec as_plugin_lookup_fun() :: ServiceScopeValidator.plugin_lookup_fun()
  def as_plugin_lookup_fun do
    fn plugin_handler, tenant_id ->
      case resolve_plugin_handler_for_tenant(plugin_handler, tenant_id) do
        {:ok, registration} ->
          {:ok, %{scope: registration.scope, owner_tenant_id: registration.owner_tenant_id}}

        {:error, :not_registered} = error ->
          error
      end
    end
  end

  @doc false
  @spec supported_api_version() :: pos_integer()
  def supported_api_version, do: @supported_api_version

  # GenServer callbacks

  @impl true
  def init(registrations) do
    :ets.new(@table, [:bag, :protected, :named_table, read_concurrency: true])

    case seed_registrations(registrations) do
      :ok -> {:ok, %{frozen?: true}}
      {:error, reason} -> {:stop, {:invalid_plugin_registration, reason}}
    end
  end

  defp seed_registrations(registrations) do
    Enum.reduce_while(registrations, :ok, fn attrs, :ok ->
      case do_register(attrs, %{frozen?: false}) do
        {:ok, _registration} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def handle_call({:register_plugin_handler, attrs}, _from, state) do
    case do_register(attrs, state) do
      {:ok, _registration} = ok -> {:reply, ok, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:freeze_plugin_registry, _from, state) do
    {result, new_state} = do_freeze(state)
    {:reply, result, new_state}
  end

  defp do_freeze(%{frozen?: true} = state), do: {{:error, :already_frozen}, state}
  defp do_freeze(%{frozen?: false} = state), do: {:ok, %{state | frozen?: true}}

  # §6.1 — explicit, ordered check sequence: registry_frozen, nil_handler,
  # invalid_node_type, scope validity, incompatible_api_version,
  # duplicate_node_type, then insert.
  defp do_register(_attrs, %{frozen?: true}), do: {:error, :registry_frozen}

  defp do_register(attrs, %{frozen?: false}) do
    with :ok <- check_handler(attrs),
         :ok <- check_handler_key(attrs),
         :ok <- check_scope(attrs),
         :ok <- check_api_version(attrs),
         :ok <- check_duplicate(attrs) do
      registration = %{
        handler_key: Map.fetch!(attrs, :handler_key),
        handler: Map.fetch!(attrs, :handler),
        scope: Map.fetch!(attrs, :scope),
        owner_tenant_id: Map.get(attrs, :owner_tenant_id),
        api_version: Map.get(attrs, :api_version, 1),
        registered_at: DateTime.utc_now()
      }

      :ets.insert(@table, {registration.handler_key, registration})
      {:ok, registration}
    end
  end

  defp check_handler(%{handler: handler}) when is_atom(handler) and not is_nil(handler), do: :ok
  defp check_handler(_attrs), do: {:error, :nil_handler}

  defp check_handler_key(%{handler_key: key}) when is_binary(key) and byte_size(key) > 0, do: :ok
  defp check_handler_key(_attrs), do: {:error, :invalid_node_type}

  defp check_scope(%{scope: :tenant, owner_tenant_id: owner}) when not is_nil(owner), do: :ok

  defp check_scope(%{scope: :tenant} = attrs) do
    if Map.has_key?(attrs, :owner_tenant_id) and not is_nil(attrs.owner_tenant_id) do
      :ok
    else
      {:error, :tenant_scoped_plugin_requires_owner_id}
    end
  end

  defp check_scope(%{scope: :global} = attrs) do
    if Map.has_key?(attrs, :owner_tenant_id) and not is_nil(attrs.owner_tenant_id) do
      {:error, :global_plugin_must_not_have_owner_id}
    else
      :ok
    end
  end

  defp check_scope(_attrs), do: {:error, :invalid_node_type}

  defp check_api_version(attrs) do
    if Map.get(attrs, :api_version, 1) == @supported_api_version do
      :ok
    else
      {:error, :incompatible_api_version}
    end
  end

  defp check_duplicate(attrs) do
    handler_key = Map.fetch!(attrs, :handler_key)
    scope = Map.fetch!(attrs, :scope)
    owner_tenant_id = Map.get(attrs, :owner_tenant_id)

    duplicate? =
      Enum.any?(:ets.lookup(@table, handler_key), fn {^handler_key, reg} ->
        reg.scope == scope and reg.owner_tenant_id == owner_tenant_id
      end)

    if duplicate?, do: {:error, :duplicate_node_type}, else: :ok
  end
end
