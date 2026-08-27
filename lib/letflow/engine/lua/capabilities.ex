defmodule Letflow.Engine.Lua.Capabilities do
  @moduledoc """
  REQ-157 (LUA-05, LUA-06 restated) — the capability-set representation and the gate
  functions every gated `platform.*` host function calls before doing any work. Implements
  `lib/letflow/design/req157-lua-capability-model.md` §2 exactly.

  A capability is an opaque string token (`"variable:read"`, `"service:call:billing"`,
  etc.) — no atom-keyed enum, no struct. A grant set is a bare `MapSet.t()` kept behind
  this module's own `grant_set()` type: callers depend on `has?/2`/`add/2`/`new/0,1` rather
  than reaching into the underlying `MapSet.t()` directly.

  This module has no dependency on `Letflow.Engine.Lua.Platform`, `Lua`, or any Lua-VM
  concept — it is pure grant-set/denial-shape logic (design §3). `Platform` depends on
  this module, never the reverse.

  ## The structured denial shape

  `check/3` returns `{:error, denial()}` on a missing capability, where `denial()` carries
  exactly the three fields LUA-06 names: the `function` atom being called, the single
  `required` capability string that was missing, and the full `granted` list the calling
  script's grant set actually held at check time (never omitted or elided, `[]` for an
  empty grant set).

  ## `check/3` vs `check!/3`

  `check/3` is the non-raising form — for any Elixir-side caller that is not going through
  a Lua call at all (a future manifest-validation step, or an admin/introspection
  surface). `check!/3` is what every gated `platform.*` Lua wrapper
  (`Letflow.Engine.Lua.Platform.install/2`) actually calls: on denial it raises
  `Lua.RuntimeException` via that library's keyword-list `exception/1` clause, carrying the
  three official keys the library validates (`:scope`, `:function`, `:message`) plus two
  extra keys the library does not validate but retains unmodified on `:original`
  (`:capability_required`, `:capabilities_granted`) — so a caller that rescues the
  exception can read the structured denial fields directly off `exception.original`,
  without needing a custom exception module (design §6.3: a bespoke `defexception` would
  not be caught by `Executor.execute_with_manifest/2`'s existing
  `rescue e in [Lua.RuntimeException, Lua.CompilerException]` clause).

  `required = :none` short-circuits `check/3`/`check!/3` to `:ok` unconditionally, without
  consulting the grant set at all — this is the mechanism that makes `platform.now` and
  `platform.fail` ungated **by construction**: no capability string is ever associated with
  either function in `Platform`'s capability matrix, so this module never even looks at the
  grant set for them.
  """

  @type capability :: String.t()
  @opaque grant_set :: MapSet.t(capability())

  @type denial :: %{
          function: atom(),
          required: capability(),
          granted: [capability()]
        }

  @doc """
  The empty grant set. This is what `Letflow.Engine.Lua.Platform.install/1` passes to
  `install/2` for every production `Sandbox.new/0,1` VM until a future requirement threads
  a real manifest's grants through.
  """
  @spec new() :: grant_set()
  def new, do: MapSet.new()

  @doc """
  Builds a grant set from a list of capability strings (e.g. a manifest's declared
  capabilities).
  """
  @spec new(capabilities :: [capability()]) :: grant_set()
  def new(capabilities) when is_list(capabilities), do: MapSet.new(capabilities)

  @doc """
  Returns a new grant set with `capability` added. Pure, non-mutating — the `grant_set`
  passed in is unchanged.
  """
  @spec add(grant_set(), capability()) :: grant_set()
  def add(grant_set, capability) do
    MapSet.put(grant_set, capability)
  end

  @doc """
  `true` iff `capability` is an exact member of `grant_set` — no prefix/wildcard matching
  of any kind. `has?(grants, "service:call:billing")` is `true` only for that exact
  string, never for `"service:call:*"` or a bare `"service:call"`.
  """
  @spec has?(grant_set(), capability()) :: boolean()
  def has?(grant_set, capability) do
    MapSet.member?(grant_set, capability)
  end

  @doc """
  Checks whether `grant_set` authorises a call to `function_name` requiring `required`.

  `required = :none` returns `:ok` unconditionally, without consulting `grant_set` at all
  (the ungating mechanism for `platform.now`/`platform.fail` — see moduledoc). Otherwise
  returns `:ok` if `has?(grant_set, required)`, else `{:error, denial()}` with all three
  fields populated.
  """
  @spec check(grant_set(), function_name :: atom(), required :: capability() | :none) ::
          :ok | {:error, denial()}
  def check(_grant_set, _function_name, :none), do: :ok

  def check(grant_set, function_name, required) when is_binary(required) do
    if has?(grant_set, required) do
      :ok
    else
      {:error,
       %{
         function: function_name,
         required: required,
         granted: MapSet.to_list(grant_set)
       }}
    end
  end

  @doc """
  Calls `check/3`; returns `:ok` on grant (or when `required = :none`); on denial raises
  `Lua.RuntimeException` carrying the denial's three fields (`:capability_required`,
  `:capabilities_granted`, plus the library-validated `:function`) alongside the
  library-required `:scope`/`:message` keys, and never returns.
  """
  @spec check!(grant_set(), function_name :: atom(), required :: capability() | :none) :: :ok
  def check!(grant_set, function_name, required) do
    case check(grant_set, function_name, required) do
      :ok ->
        :ok

      {:error, denial} ->
        raise Lua.RuntimeException,
          scope: [:platform],
          function: denial.function,
          message:
            "platform.#{denial.function} denied: requires capability #{inspect(denial.required)}, " <>
              "script granted #{inspect(denial.granted)}",
          capability_required: denial.required,
          capabilities_granted: denial.granted
    end
  end

  @doc """
  Returns the capability string required to call `platform.call_service(svc_id, ...)` for
  a given service id: `"service:call:" <> svc_id`, exactly. This is the one and only place
  that string template is constructed — both `Platform`'s capability matrix row for
  `call_service` and any future test/manifest code minting a `service:call:*` grant string
  call this function rather than string-interpolating the format a second time.
  """
  @spec service_capability(svc_id :: String.t()) :: capability()
  def service_capability(svc_id) when is_binary(svc_id) do
    "service:call:" <> svc_id
  end
end
