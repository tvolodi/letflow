defmodule Letflow.Definitions.ServiceScopeValidator do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  SVC-03 — service/plugin scope activation validator. Ports
  `src/definition/service_scope_validator.zig`'s
  `ServiceScopeValidator.validateServiceTaskReferences` (R-Co,
  `C:\\Users\\tvolo\\dev\\ai-dala\\R-Co\\src\\definition\\service_scope_validator.zig`,
  lines 54-223) per `lib/letflow/design/req031-service-scope-validator.md` (the
  gate-approved design this module implements) — the design doc's §5 branch tables are
  this module's exact spec, ported here verbatim rather than reinterpreted.

  Walks every `:SERVICE_TASK` node in an already-built `Letflow.Definitions.Graph.t()`
  and, for each present `"service_id"`/`"plugin_handler"` node attribute, asks an
  injected `Lookup` whether the activating tenant is permitted to reference it:
  global-scope references always pass; tenant-scope references pass only when the
  looked-up owner matches the activating `tenant_id`; unregistered `service_id`s fail,
  but (deliberately, see below) unregistered `plugin_handler`s do not. Returns on the
  first violation found (design doc §5, `Enum.reduce_while/3`) — never collects or
  merges multiple violations (INV-SSV-2).

  `build/1` produces the exact 2-arity function value
  `Letflow.Definitions.activate/2`'s `opts[:service_scope_validator]` hook expects
  (`Letflow.Definitions.service_scope_validator_fun/0`, already shipped by REQ-030) —
  see that module's moduledoc, "`activate/2`'s `service_scope_validator` option." This
  module adds no code to `lib/letflow/definitions.ex` or `lib/letflow/definitions/graph.ex`
  (design doc §1).

  ## Purity (INV-SSV-4)

  This module and everything in its own call graph depend on Elixir/Erlang stdlib
  only (`Enum`, `Map`) — no `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock
  read, no HTTP/file/process-mailbox call anywhere in this module. All I/O is delegated
  entirely to the two functions carried on the caller-supplied `Lookup.t()`, treated as
  opaque — mirrors `Letflow.Definitions.Graph`'s own "Purity" moduledoc section.

  ## Two deliberate, faithfully-ported R-Co asymmetries — not bugs

  PROVENANCE (historical, not current decision authority):
  1. **`plugin_handler` "not registered" is a pass, `service_id` "not registered" is a
     violation** (INV-SSV-5). Ports `checkPluginHandler`'s "no tenant-scoped entry at
     all: PD-05 already validates handler existence; skip" branch (`.zig` line 220-222)
     verbatim — this validator does not duplicate handler-existence checking.
  PROVENANCE (historical, not current decision authority):
  2. **A resolved `:tenant`-scope lookup with a `nil` `owner_tenant_id` is a violation
     on the service side (INV-SSV-7) but a silent pass on the plugin side (INV-SSV-9)**
     — the exact inverse of each other for the identically-shaped malformed-lookup
     case. Ports `checkServiceId`'s `owner orelse { ...; return
     ServiceScopeError.ServiceNotAvailableToTenant; }` (`.zig` line 142-151) against
     `checkPluginHandler`'s `const owner = reg.owner_tenant_id orelse return;` (`.zig`
     line 187, a bare `return` inside a `ServiceScopeError!void` fn — a successful
     return, not an error) exactly as each real source function behaves. Neither R-Co
     source document states a deliberate policy reason for this particular asymmetry
     (unlike asymmetry 1 above) — flagged as design doc §9 OQ-4 for
     REVIEWER/SECURITY-REVIEWER, not silently resolved either direction here.

  ## Scope gap — no real catalog/registry integration yet

  This module implements ONLY the graph-walk-and-scope-comparison algorithm (SVC-03) against
  an injectable `Lookup` (two functions the caller supplies). It does NOT implement, and does
  not itself depend on, either of R-Co's two real dependencies:

    PROVENANCE (historical, not current decision authority):
    * a `ServiceCatalog` -- a tenant-scoped, DB-backed service registry
      (R-Co: `src/repository/service_catalog.zig`) -- belongs to **stage S6**
      (operational cross-cutting / repository layer), not yet ported as of this module.
    PROVENANCE (historical, not current decision authority):
    * a `PluginRegistry` -- an in-process plugin dispatch table
      (R-Co: `src/engine/plugin_registry.zig`) -- belongs to **stage S3**
      (instance-engine), not yet ported as of this module.

  Whoever wires a real hook (via `build/1`) into `Letflow.Definitions.activate/2` before S3/S6
  ship MUST supply a `Lookup` backed by something else (a hardcoded map, a stub) -- there is
  no default, production-ready `Lookup` in this codebase yet. The optionality is
  intentional, not an oversight: forcing a production-ready `Lookup` to exist before
  ServiceCatalog/PluginRegistry are ported would mean inventing a throwaway one now
  only to replace it later, for no benefit (R-Co's `Store` makes the equivalent field
  optional the same way: `service_scope_validator: ?*ServiceScopeValidator = null`).
  """

  alias Letflow.Definitions.Graph

  @typedoc "Whether a registered service/plugin reference is usable by any tenant or one."
  @type scope :: :global | :tenant

  @typedoc """
  One `Lookup` function's successful resolution. `owner_tenant_id` is `nil` iff
  `scope == :global`; expected non-`nil` iff `scope == :tenant` (per
  `ServiceCatalogRecord.owner_tenant_id: ?[16]u8` — "null when scope = global",
  `src/design/svc-01-04-service-scope.md` §2.1). A `:tenant` record whose
  `owner_tenant_id` is `nil` is a malformed-lookup-result case, handled DIFFERENTLY per
  side — see this module's moduledoc "Two deliberate, faithfully-ported R-Co
  asymmetries" section. Do not assume both sides resolve the same way.
  """
  @type lookup_record :: %{scope: scope(), owner_tenant_id: Ecto.UUID.t() | nil}

  @type service_lookup_result :: {:ok, lookup_record()} | {:error, :not_registered}
  @type plugin_lookup_result :: {:ok, lookup_record()} | {:error, :not_registered}

  @type service_lookup_fun :: (service_id :: String.t() -> service_lookup_result())

  @typedoc """
  `tenant_id` is passed because a real future `PluginRegistry` adapter's own
  resolution is inherently tenant-aware (R-Co's `resolvePluginHandlerForTenant/3`
  takes `tenant_id` — `src/design/svc-01-04-service-scope.md` §2.4). All of R-Co's
  two-tier "resolve for this tenant, else scan for any other tenant's claim"
  mechanics live behind this one call — not duplicated in this module.
  """
  @type plugin_lookup_fun ::
          (plugin_handler :: String.t(), tenant_id :: Ecto.UUID.t() -> plugin_lookup_result())

  defmodule Lookup do
    @moduledoc """
    The injectable dependency `Letflow.Definitions.ServiceScopeValidator.validate/3`
    calls instead of a concrete `ServiceCatalog`/`PluginRegistry` module — a struct of
    two functions rather than a config-resolved `@behaviour`, so a caller/test can pass
    a different lookup result per call without `Application.put_env/3` cross-test
    coupling. See the design doc §3.1 for the full rationale. Plain struct, not
    `Ecto.Schema` — mirrors `Letflow.Definitions.Graph.Node`/`.Edge`'s nested-plain-struct
    convention.
    """

    @enforce_keys [:service_lookup, :plugin_lookup]
    defstruct [:service_lookup, :plugin_lookup]

    @type t :: %__MODULE__{
            service_lookup: Letflow.Definitions.ServiceScopeValidator.service_lookup_fun(),
            plugin_lookup: Letflow.Definitions.ServiceScopeValidator.plugin_lookup_fun()
          }
  end

  defmodule Violation do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    One scope-check failure returned by `validate/3` (ports `.zig`'s `ScopeViolation`).
    `reason` is a closed-set atom (machine-matchable) and `message` a human-readable
    string filled in with the specific `ref_id` — mirrors
    `Letflow.Definitions.Graph.Violation`'s `code`/`message` split, naming the atom
    field `reason` to match `docs/requirements.yaml`'s own REQ-031 vocabulary. See the
    design doc §3.2 for why both fields exist (AC3 requires the not-registered case be
    "distinguishable... not just a different string").
    """

    @enforce_keys [:node_id, :kind, :ref_id, :reason, :message]
    defstruct [:node_id, :kind, :ref_id, :reason, :message]

    @type kind :: :service | :plugin

    @type reason ::
            :service_not_registered
            | :service_not_available_to_tenant
            | :plugin_not_available_to_tenant

    @type t :: %__MODULE__{
            node_id: String.t(),
            kind: kind(),
            ref_id: String.t(),
            reason: reason(),
            message: String.t()
          }
  end

  @doc """
  Returns the 2-arity function value that IS `Letflow.Definitions.activate/2`'s
  `opts[:service_scope_validator]` hook — captures `lookup` in a closure and forwards
  its own two received arguments unchanged to `validate/3`, supplying `lookup` as the
  third argument. No other logic lives here (design doc §4, INV-SSV-8).
  """
  @spec build(lookup :: Lookup.t()) :: Letflow.Definitions.service_scope_validator_fun()
  def build(%Lookup{} = lookup) do
    fn graph, tenant_id -> validate(graph, tenant_id, lookup) end
  end

  @doc """
  Walks every `:SERVICE_TASK` node in `graph.nodes` (in original order, INV-SSV-6) and
  checks each present `"service_id"`/`"plugin_handler"` node attribute against `lookup`,
  per the design doc §5 branch tables. Returns on the first violation found — never
  collects or merges multiple violations (INV-SSV-2). Public (not `defp`) so a caller
  can unit-test the algorithm directly against a hand-built `Lookup`, without going
  through `build/1`'s closure indirection or `activate/2`'s transaction machinery.

  `tenant_id` is assumed always a well-formed, non-`nil` `Ecto.UUID.t()` string —
  `Letflow.Definitions.activate/2` derives it before this hook is ever reachable; there
  is no platform-admin-bypass concept in Letflow's schema-per-tenant model today (design
  doc §9 OQ-2).
  """
  @spec validate(
          graph :: Graph.t(),
          tenant_id :: Ecto.UUID.t(),
          lookup :: Lookup.t()
        ) :: :ok | {:error, Violation.t()}
  def validate(%Graph{nodes: nodes}, tenant_id, %Lookup{} = lookup) do
    nodes
    |> Enum.filter(&(&1.node_type == :SERVICE_TASK))
    |> Enum.reduce_while(:ok, fn node, :ok -> check_node(node, tenant_id, lookup) end)
  end

  # PROVENANCE (historical, not current decision authority):
  # A node with no attributes contributes nothing (ports `.zig`'s
  # `const attrs_json = node.attributes orelse continue;`, line 65).
  defp check_node(%Graph.Node{attributes: nil}, _tenant_id, _lookup), do: {:cont, :ok}

  defp check_node(%Graph.Node{id: node_id, attributes: attributes}, tenant_id, lookup) do
    with :ok <- check_service_id(node_id, attributes, tenant_id, lookup),
         :ok <- check_plugin_handler(node_id, attributes, tenant_id, lookup) do
      {:cont, :ok}
    else
      {:error, violation} -> {:halt, {:error, violation}}
    end
  end

  # INV-SSV-3: "service_id" is read only when present as a non-empty string; a missing
  # key, nil, non-string, or empty-string value performs no lookup call and produces no
  # violation for this key.
  defp check_service_id(node_id, attributes, tenant_id, lookup) do
    case ref_id(attributes, "service_id") do
      nil ->
        :ok

      service_id ->
        service_id
        |> lookup.service_lookup.()
        |> evaluate_service_lookup(node_id, service_id, tenant_id)
    end
  end

  # INV-SSV-3, same non-empty-string gate, for "plugin_handler".
  defp check_plugin_handler(node_id, attributes, tenant_id, lookup) do
    case ref_id(attributes, "plugin_handler") do
      nil ->
        :ok

      plugin_handler ->
        plugin_handler
        |> lookup.plugin_lookup.(tenant_id)
        |> evaluate_plugin_lookup(node_id, plugin_handler, tenant_id)
    end
  end

  # String-keyed read (matches `definitions.ex`'s `graph_struct_from_map/1` convention
  # for `Node.attributes`, always string-keyed jsonb) with an `is_map/1` defensive guard
  # (belt-and-suspenders, mirrors `Graph`'s own `blank_or_missing_string?/2`).
  @spec ref_id(map() | nil, String.t()) :: String.t() | nil
  defp ref_id(attributes, key) when is_map(attributes) do
    case Map.get(attributes, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _other -> nil
    end
  end

  defp ref_id(_attributes, _key), do: nil

  # --- Service branch table (design doc §5, "Service branch table") --------------

  defp evaluate_service_lookup({:error, :not_registered}, node_id, service_id, _tenant_id) do
    {:error,
     %Violation{
       node_id: node_id,
       kind: :service,
       ref_id: service_id,
       reason: :service_not_registered,
       message: "service #{service_id} is not registered"
     }}
  end

  defp evaluate_service_lookup({:ok, %{scope: :global}}, _node_id, _service_id, _tenant_id) do
    :ok
  end

  defp evaluate_service_lookup(
         {:ok, %{scope: :tenant, owner_tenant_id: owner}},
         _node_id,
         _service_id,
         tenant_id
       )
       when owner == tenant_id do
    :ok
  end

  defp evaluate_service_lookup(
         {:ok, %{scope: :tenant, owner_tenant_id: nil}},
         node_id,
         service_id,
         _tenant_id
       ) do
    {:error,
     %Violation{
       node_id: node_id,
       kind: :service,
       ref_id: service_id,
       reason: :service_not_available_to_tenant,
       message: "service #{service_id} scope data is inconsistent"
     }}
  end

  defp evaluate_service_lookup(
         {:ok, %{scope: :tenant, owner_tenant_id: _owner}},
         node_id,
         service_id,
         _tenant_id
       ) do
    {:error,
     %Violation{
       node_id: node_id,
       kind: :service,
       ref_id: service_id,
       reason: :service_not_available_to_tenant,
       message: "service #{service_id} is not available to this tenant"
     }}
  end

  # --- Plugin branch table (design doc §5, "Plugin branch table") ----------------

  # PROVENANCE (historical, not current decision authority):
  # INV-SSV-5 — first asymmetry: no tenant-scoped entry at all is a pass, not a
  # violation (ports `.zig`'s `checkPluginHandler`, line 220-222).
  defp evaluate_plugin_lookup({:error, :not_registered}, _node_id, _plugin_handler, _tenant_id) do
    :ok
  end

  defp evaluate_plugin_lookup({:ok, %{scope: :global}}, _node_id, _plugin_handler, _tenant_id) do
    :ok
  end

  defp evaluate_plugin_lookup(
         {:ok, %{scope: :tenant, owner_tenant_id: owner}},
         _node_id,
         _plugin_handler,
         tenant_id
       )
       when owner == tenant_id do
    :ok
  end

  # PROVENANCE (historical, not current decision authority):
  # INV-SSV-9 — second asymmetry: a nil owner on a resolved tenant-scoped entry is a
  # pass here, the exact inverse of the service side's INV-SSV-7 (ports `.zig`'s
  # `const owner = reg.owner_tenant_id orelse return;`, line 187 — a bare `return`
  # inside a `ServiceScopeError!void` fn is a successful return, not an error).
  defp evaluate_plugin_lookup(
         {:ok, %{scope: :tenant, owner_tenant_id: nil}},
         _node_id,
         _plugin_handler,
         _tenant_id
       ) do
    :ok
  end

  defp evaluate_plugin_lookup(
         {:ok, %{scope: :tenant, owner_tenant_id: _owner}},
         node_id,
         plugin_handler,
         _tenant_id
       ) do
    {:error,
     %Violation{
       node_id: node_id,
       kind: :plugin,
       ref_id: plugin_handler,
       reason: :plugin_not_available_to_tenant,
       message: "plugin #{plugin_handler} is not available to this tenant"
     }}
  end
end
