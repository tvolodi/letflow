defmodule Letflow.Engine.Lua.Platform do
  @moduledoc """
  REQ-152 (LUA-14 restated) — implements the `platform.now()` half of LUA-14 ("Time
  Source, MUST"): `platform.now()` MUST return the platform's authoritative time as ISO
  8601 UTC. The other half of LUA-14 (denying `os.time` and its ambient-time siblings) is
  implemented in `Letflow.Engine.Lua.Sandbox`'s deny-set, not here — see that module's
  moduledoc for the restatement of why `os.date`/`os.clock`/`os.difftime`/`os.setlocale`
  are also denied, beyond LUA-14's literal wording.

  This module owns two concerns, deliberately kept together rather than split across
  files: what `platform.now()` returns (`now/0`), and how the entire `platform.*` table
  becomes reachable from a Lua script at all (`install/1`, `install/2`).

  ## `platform.now` is ungated by design — not an omission

  Per decision 0014 / R-Co's `src/lua/host_api/mod.zig` capability matrix: `now` is "a
  pure time read with no state reach," and that matrix entry is "a POSITIVE design
  statement, not an omission ... A test that expects a gate on `now` or `fail` is reading
  the matrix wrong."

  **Binding statement for future requirements:** `platform.now/0` has no capability
  check, no gate, no permission lookup, anywhere in its call path — by design,
  permanently, not "not yet implemented." `install/1`/`install/2` wire it unconditionally
  into every `Lua.t()` that `Letflow.Engine.Lua.Sandbox.new/0` or `new/1` produces; there
  is no `Sandbox.new/1` option that can suppress or gate it, and none should ever be
  added. REQ-157's capability-gating work (below) MUST NOT add a gate to `platform.now`
  "by symmetry" with the gating mechanism it introduces for the other six `platform.*`
  functions.

  ## Time-source injection — behaviour + application-env resolution

  `now/0` never reads `DateTime.utc_now/0` directly. It resolves the configured
  `#{inspect(__MODULE__)}.TimeSource` implementation from application env
  (`Application.get_env(:letflow, :lua_platform_time_source, ...)`), read fresh on every
  call (never cached), and calls that implementation's `now/0` callback. This lets a test
  swap in a fixed-value double via `Application.put_env/3` in `setup`/`on_exit`, without
  recompiling or restarting any supervision tree, and asserts `platform.now()` returns
  one exact, pre-set timestamp rather than merely a well-formed one. The default
  implementation, `#{inspect(__MODULE__)}.SystemClock`, is the one and only production
  call site of `DateTime.utc_now/0` this requirement's module set introduces.

  ## Composition point

  `install/1` is called from `Letflow.Engine.Lua.Sandbox.new/1`'s construction pipeline,
  immediately after the sandboxed VM is constructed — every `Lua.t()` produced by
  `Sandbox.new/0` or `Sandbox.new/1` therefore has the full `platform.*` table available
  with no second call any caller must remember to make. `install/1`/`install/2` never
  touch the deny-set: installing globals at `[:platform, _]` and denying paths under
  `[:os, ...]` are independent operations.

  ## REQ-157 (LUA-05, LUA-06 restated) — the capability matrix

  This requirement extends `platform` from the single `now` function (REQ-152) to the
  full, CLOSED set of exactly 8 functions R-Co's own capability matrix names. Every
  `platform.*` global this module ever installs comes from `@capability_matrix` below,
  via a single fold in `install/2` — there is no other place in this module, or anywhere
  else under `lib/`, that installs a `platform.*` global via `Lua.set!/3` (INV-CAP-1).
  Adding a 9th `platform.*` function means adding a 9th row to this matrix; there is no
  other way to expose one.

  | Function | Required capability | Notes |
  |---|---|---|
  | `call_service` | `"service:call:" <> svc_id` (the first call argument, via `Letflow.Engine.Lua.Capabilities.service_capability/1`) | Parameterised — a grant for one service does not authorise another. |
  | `read_variable` | `"variable:read"` | Constant, ignores arguments. |
  | `write_variable` | `"variable:write"` | Constant, ignores arguments. |
  | `log` | `"audit:log"` | Constant, ignores arguments. |
  | `emit_event` | `"event:emit"` | Constant, ignores arguments. |
  | `get_instance_state` | `"instance:read"` | Constant, ignores arguments. |
  | `now` | `:none` — no capability, ever | Ungated by design (see above). A pure time read with no state reach (LUA-14). |
  | `fail` | `:none` — no capability, ever | Ungated by design. A script may always terminate itself: gating self-termination behind a capability would mean a script could be denied the ability to stop itself, which serves no isolation purpose (it does not reach any state, service, or variable) and would only complicate the one guaranteed way a script has of signaling its own failure back to the host. |

  **A test that expects a gate on `now` or `fail` is reading the matrix wrong** — neither
  function's `required` value is ever a capability string, in any row, for any argument;
  both always evaluate to `:none`, which `Letflow.Engine.Lua.Capabilities.check/3` treats
  as an unconditional `:ok` without ever consulting the calling script's grant set
  (INV-CAP-4).

  Every one of the six gated functions is stubbed only enough to prove the gate ran
  (`Letflow.Engine.Lua.Capabilities.check!/3` raises a `Lua.RuntimeException` on denial,
  LUA-06's "MUST raise a Lua error") — none of the six has a real implementation yet
  (REQ-159/160/161/162). `install/1` remains a thin delegate to `install/2` with an empty
  `Letflow.Engine.Lua.Capabilities.new()` grant set, so every production `Sandbox.new/0,1`
  VM exposes all 8 names with the six gated ones permanently denying until a future
  requirement calls `install/2` directly with a populated grant set.
  """

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform.TimeSource

  @type iso8601_utc :: String.t()

  @default_time_source Letflow.Engine.Lua.Platform.SystemClock

  # `required` is a description of how to compute the required capability from the Lua
  # call's argument list, not a raw closure — Elixir module attributes cannot hold
  # anonymous functions (only literal/escapable terms), so this design's
  # `required_capability_fun`/`stub_fun` shapes are represented here as plain data tags
  # that `required_capability/2` and `run_stub/3` below dispatch on. This keeps
  # `@capability_matrix` itself a literal, inspectable module attribute while preserving
  # the "one fold, one place to add a 9th function" property (INV-CAP-1) the design
  # requires: the tags are resolved only inside `install/2`'s fold, nowhere else.
  @type required_capability_spec :: :none | :call_service_arg0 | Capabilities.capability()
  @type stub_spec :: :now | :fail | :not_yet_implemented

  @type matrix_row :: %{
          name: atom(),
          required: required_capability_spec(),
          stub: stub_spec()
        }
  @type capability_matrix :: [matrix_row()]

  # The entire closed set of `platform.*` functions — exactly 8 rows, no more, no fewer
  # (INV-CAP-2). `install/2` folds over this list; it is the ONLY call site under `lib/`
  # that ever installs a `platform.*` global via `Lua.set!/3` (INV-CAP-1). See moduledoc
  # for the human-readable version of this same table.
  @capability_matrix [
    %{name: :call_service, required: :call_service_arg0, stub: :not_yet_implemented},
    %{name: :read_variable, required: "variable:read", stub: :not_yet_implemented},
    %{name: :write_variable, required: "variable:write", stub: :not_yet_implemented},
    %{name: :log, required: "audit:log", stub: :not_yet_implemented},
    %{name: :emit_event, required: "event:emit", stub: :not_yet_implemented},
    %{name: :get_instance_state, required: "instance:read", stub: :not_yet_implemented},
    %{name: :now, required: :none, stub: :now},
    %{name: :fail, required: :none, stub: :fail}
  ]

  @doc """
  Returns the current authoritative time as an ISO 8601 UTC string, e.g.
  `"2026-08-26T14:32:07.123456Z"`. Reads the configured `TimeSource` implementation from
  application env on every call (never a direct `DateTime.utc_now/0` read at this call
  site) so the source is injectable for exact-value testing. Never fails: no I/O, no user
  input — reading an injected time source and formatting it cannot fail.
  """
  @spec now() :: iso8601_utc()
  def now do
    source = Application.get_env(:letflow, :lua_platform_time_source, @default_time_source)

    source.now()
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  @doc """
  The full 8-row capability matrix. Exposed for introspection/testing; `install/2` is the
  only caller that uses it to install `platform.*` globals.
  """
  @spec capability_matrix() :: capability_matrix()
  def capability_matrix, do: @capability_matrix

  @doc """
  Installs the full `platform.*` table into `lua` with an EMPTY capability grant set —
  defined as `install(lua, Letflow.Engine.Lua.Capabilities.new())`. Retained for source
  compatibility with `Letflow.Engine.Lua.Sandbox.new/1`'s existing call site, which is
  unchanged by this requirement (design §1.1). Every production `Sandbox.new/0,1` VM
  therefore exposes all 8 `platform.*` names, with the six gated ones permanently denying
  until some future requirement calls `install/2` directly with a populated grant set.

  Additive only — never touches the sandbox deny-set. Not intended to be called directly
  by any caller other than `Sandbox.new/1`.
  """
  @spec install(lua :: Lua.t()) :: Lua.t()
  def install(%Lua{} = lua) do
    install(lua, Capabilities.new())
  end

  @doc """
  The single registration point for the entire `platform.*` table (INV-CAP-1). Folds over
  `@capability_matrix`, calling `Lua.set!/3` once per row to bind `[:platform, row.name]`
  to a Lua-callable wrapper. `capabilities` is captured once per `install/2` call and
  closed over by every one of the 8 installed wrappers — the grant set is fixed for the
  lifetime of the returned `Lua.t()`.

  Each installed wrapper, when invoked with the Lua call's argument list:

    1. computes the capability this particular call requires by applying `row.required`
       to the argument list (a constant string for 6 of the 8 rows, parameterised by the
       first argument for `call_service`, or `:none` for `now`/`fail`);
    2. passes that value, `capabilities`, and `row.name` to
       `Letflow.Engine.Lua.Capabilities.check!/3` — the single gate call every wrapper
       makes; on denial it raises and the wrapper never proceeds to step 3;
    3. only if `check!/3` returns, invokes `row.stub` with the same argument list and
       returns its result as the Lua call's return value.
  """
  @spec install(lua :: Lua.t(), capabilities :: Capabilities.grant_set()) :: Lua.t()
  def install(%Lua{} = lua, capabilities) do
    Enum.reduce(@capability_matrix, lua, fn row, lua_acc ->
      Lua.set!(lua_acc, [:platform, row.name], fn args ->
        required = required_capability(row.required, args)
        Capabilities.check!(capabilities, row.name, required)
        run_stub(row.stub, row.name, args)
      end)
    end)
  end

  # Resolves a `matrix_row.required` tag to the capability string (or `:none`) this
  # particular call requires, given the Lua call's argument list. `:call_service_arg0` is
  # the only row whose required capability depends on the call's arguments (§4.2) —
  # every other row is either a constant string or the unconditional `:none` that makes
  # `now`/`fail` ungated (§5, INV-CAP-4).
  @spec required_capability(required_capability_spec(), [term()]) ::
          Capabilities.capability() | :none
  defp required_capability(:none, _args), do: :none

  defp required_capability(:call_service_arg0, [svc_id | _]) when is_binary(svc_id) do
    Capabilities.service_capability(svc_id)
  end

  defp required_capability(:call_service_arg0, _args) do
    Capabilities.service_capability("")
  end

  defp required_capability(required, _args) when is_binary(required), do: required

  # Runs the stub body for a row, only ever reached after `Capabilities.check!/3` has
  # returned (i.e. the call was permitted, or `required` was `:none`). Per design §4.3,
  # none of the six non-`now`/`fail` stubs do real work — every one of them raises a
  # distinct, clearly-labeled "not yet implemented" error so a granted call is
  # distinguishable from a capability denial.
  @spec run_stub(stub_spec(), atom(), [term()]) :: [term()]
  defp run_stub(:now, _function_name, _args), do: [__MODULE__.now()]

  defp run_stub(:fail, _function_name, args) do
    message =
      case args do
        [msg | _] when is_binary(msg) -> "script called platform.fail: #{msg}"
        _ -> "script called platform.fail"
      end

    raise Lua.RuntimeException,
      scope: [:platform],
      function: :fail,
      message: message,
      reason: :explicit_fail
  end

  defp run_stub(:not_yet_implemented, function_name, _args) do
    raise Lua.RuntimeException,
      scope: [:platform],
      function: function_name,
      message: "#{function_name} is not yet implemented (REQ-159/160)",
      stub: true
  end

  defmodule TimeSource do
    @moduledoc """
    Behaviour for `Letflow.Engine.Lua.Platform.now/0`'s injectable time source. A test
    double implements this behaviour and is installed via
    `Application.put_env(:letflow, :lua_platform_time_source, <module>)` to make
    `platform.now()` return one exact, pre-set timestamp.
    """

    @type source_now_result :: DateTime.t()

    @callback now() :: source_now_result()
  end

  defmodule SystemClock do
    @moduledoc """
    Default `TimeSource` implementation. The one and only production call site of
    `DateTime.utc_now/0` this requirement's module set (`platform.ex`) introduces — every
    other read of "now" for Lua-visible time goes through `Platform.now/0`, which
    resolves the configured `TimeSource` rather than reading the system clock directly.
    """

    @behaviour TimeSource

    @impl TimeSource
    @spec now() :: DateTime.t()
    def now, do: DateTime.utc_now()
  end
end
