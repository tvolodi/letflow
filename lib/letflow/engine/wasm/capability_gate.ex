defmodule Letflow.Engine.Wasm.CapabilityGate do
  @moduledoc """
  REQ-167 (WASM-06, MUST — import whitelist; WASM-07 restated — no
  filesystem access by default).

  Given a `manifest()` (an admin-granted capability set, external to the
  guest module's own bytes) and a compiled module's raw `bytes`,
  `start_instance/2` builds the exact `imports:` map
  `Wasmex.start_link/1` is instantiated with — containing an entry for
  every host function `manifest.capabilities` grants, and, structurally,
  no entry for anything else — then attempts a real instantiation
  against exactly that table. A guest importing anything outside the
  whitelist fails **instantiation**, not merely "fails when called":
  `wasmex`'s `imports:` option is the entire host-function surface
  offered to an instance, with no implicit universal grant underneath it
  (`lib/letflow/design/req167-wasm-import-whitelist.md` §1.1/§1.2, live
  -verified against the installed `wasmex` v0.15.1 this session).

  See `lib/letflow/design/req167-wasm-import-whitelist.md` (gate
  -approved) for the full design this module implements — in particular
  §4's structural proof that no host function beyond the manifest's
  grants is ever reachable by an instance this module produces.

  ## Scope boundary — a new, third module, not a graft onto REQ-165/166

  Neither `Letflow.Engine.Wasm.ModuleRegistry` (REQ-166 — validates a
  module's *export* shape, instantiates with **no** imports at all to
  prove instantiability) nor `Letflow.Engine.Wasm.PluginHandler`
  (REQ-165 — dispatches one fixed known guest export through the
  process boundary) consumes a manifest or builds a constrained import
  table. This module is deliberately independent of both — neither
  `module_registry.ex` nor `plugin_handler.ex` is modified by this
  requirement (design §0/§10). Wiring registration, capability-gated
  instantiation, and export dispatch together into one production call
  path is a future dispatch-integration requirement's job (design §8).

  ## WASM-07 restatement (AC5)

  This module restates WASM-07: the *intent* — no filesystem capability
  granted by default — is fully implemented. `start_instance/2` never
  supplies a `wasi:` option to `Wasmex.start_link/1` (§2/§5.2 of the
  design), and `@known_imports` (below) contains zero filesystem
  -shaped entries, so no `manifest()` value, however permissive, can
  ever cause a filesystem import to resolve. WASM-07's acceptance
  criterion's *concrete interface name*, `wasi:filesystem/types`, is
  ABI-dependent and was replaced per
  `lib/letflow/design/req163-wasm-abi-choice.md`'s Decision (this
  platform targets core modules, not the WASI Preview 2 component
  model).

  ## AC4 — why the literal name `wasi:filesystem/types` is NOT the surface tested here

  `wasi:filesystem/types` is a WASI **Preview 2 component-model**
  interface identifier — it names a WIT interface path, which has no
  meaning under wasmtime's **core-module** linking used here, where
  imports are named by a flat `(namespace, function)` pair instead. A
  test asserting that this runtime rejects an import literally spelled
  `wasi:filesystem/types` would be a **false pass**: that string is not
  even syntactically a core-module `(namespace, name)` pair, so *any*
  core-module import section referencing it is rejected as
  unrecognized — identically to how a misspelled or wholly nonexistent
  import name would be rejected — regardless of whether real
  filesystem-shaped imports are actually denied. **What is tested
  instead** is the concrete core-module surface
  `req163-wasm-abi-choice.md` §4 names: the `wasi_snapshot_preview1`
  namespace's functions — `path_open`, `fd_read`, `fd_write`,
  `fd_readdir`, `path_filestat_get`, `fd_filestat_get`,
  `path_create_directory`, `path_remove_directory`, `path_unlink_file`,
  `path_rename`, `path_symlink`, and siblings. Every one of them fails
  identically to any other unresolved import, via the same
  never-supplied-`wasi:`, never-registered-capability mechanism this
  module uses throughout.

  ## AC6 — no explicit filesystem-grant path exists today

  `@known_imports` below defines exactly two entries, neither
  filesystem-shaped, and no code in this module inspects
  `manifest.capabilities` for any filesystem-related token. There is
  **no code path today** by which any `manifest()` value could cause a
  `wasi_snapshot_preview1` (or any other WASI) function to appear in
  `build_import_table/1`'s output. WASM-07's clause "any future grant
  MUST be explicit in the capability manifest" is **not implemented**
  by this module — doing so would require a real filesystem-capability
  registry entry and a real WASI-preopen-backed callback (or a `wasi:`
  option wired from a manifest-derived `Wasmex.Wasi.WasiOptions`),
  which nothing in this requirement's scope calls for and no acceptance
  criterion exercises. Stated plainly rather than implied: **the
  "future grant" clause is not satisfied merely because `manifest()`
  has a generic capability-list shape.**

  ## Placeholder registry, now fully resolved (REQ-172)

  `@known_imports` was originally a small, fixed placeholder proving the
  *mechanism* (whitelist construction and enforcement) only. REQ-171
  (`lib/letflow/design/req171-wasm-host-api-read.md`, gate-approved) extended it
  additively with real rows for `read_variable`, `log`, `now`, `uuid`. REQ-172
  (`lib/letflow/design/req172-wasm-host-api-write-path-and-parity-suite.md`,
  gate-approved) completes the registry: `platform_call_service`'s signature widens
  from its original 2-param illustrative placeholder to its real 6-param shape and
  dispatches to `HostApi.do_call_service/8`, and two new rows (`write_variable`,
  `fail`) are added — every row now dispatches to a real
  `Letflow.Engine.Wasm.HostApi` implementation, no placeholder stub remains.

  ## REQ-171 — `:none`-gated rows and `build_import_table/2` (design §4)

  `platform.ex`'s Lua-side matrix has a `:none` row (`now`/`fail`): installed
  unconditionally, gated per-call (gating happens inside the wrapper, not at
  installation). WASM's gate *is* import-table membership, so there was no
  equivalent mechanism for "install regardless of grant state" before this
  requirement. `import_descriptor()` gains a `capability_requirement()` (widened from
  `capability()`, additively — see below) and a `stub` field; `build_import_table/1`'s
  filter now includes a `capability: :none` descriptor **unconditionally**, mirroring
  `required_capability/2`'s own `:none` clause on the Lua side, restated as a filter
  rather than a per-call check. This is additive to the *same* mechanism — no second
  registry, no second whitelist.

  `build_import_table/1` is unchanged in signature and now defined as
  `build_import_table(manifest, Letflow.Engine.Wasm.HostApi.empty_execution_context())`
  — every entry's callback becomes `HostApi`'s real dispatcher, closed over the
  *empty* context, so this module's own pre-existing tests (which exercise only
  whitelist-membership / instantiation success-or-failure, never a granted function's
  actual return value) continue to pass unchanged. `build_import_table/2` is the new
  real entry point: `execution_context` is captured once per call and closed over by
  every installed callback for the lifetime of the returned `import_table()`.

  ## Cross-runtime denial-timing divergence (REQ-171 design §4.3) — inherited, not fixed

  An ungranted **Lua** call to a gated function raises at the moment of that specific
  call — code before it in the same script has already run. An ungranted **WASM**
  import causes the entire module to fail **instantiation** — no guest code runs at
  all. This divergence is inherent to this module's already-approved
  import-table-membership-is-the-gate architecture (§4.1 above); REQ-171 states it
  explicitly (its own acceptance criteria are the first to compare Lua/WASM behavior
  side by side) but does not, and is not positioned to, resolve it. Flagged for
  REVIEWER/SECURITY-REVIEWER as a known, accepted, pre-existing divergence.
  """

  alias Letflow.Engine.Wasm.HostApi

  @typedoc "Per design §2 — a bare capability grant set; opaque string tokens, exact-match only."
  @type capability :: String.t()

  @typedoc """
  The minimal manifest shape this requirement needs (design §2) — an
  admin-granted capability set. Not `Letflow.Engine.Lua.Manifest`, and
  not derived from a guest's own self-declared `get_capabilities`
  export (an untrusted guest's own claim of what it needs cannot be
  trusted to determine what it may reach).
  """
  @type manifest :: %{capabilities: [capability()]}

  @type valtype :: :i32 | :i64 | :v128 | :f32 | :f64

  @typedoc """
  REQ-171 design §4.2 — widens `capability()` (never narrows it): `:none` marks a row
  that is **always** included in the built import table regardless of
  `manifest.capabilities`'s contents, mirroring `platform.ex`'s own
  `required_capability_spec()` `:none` case (`now`/`fail`, permanently ungated).
  """
  @type capability_requirement :: capability() | :none

  @typedoc """
  REQ-171/172 design §4.7 — which `Letflow.Engine.Wasm.HostApi` function a row's
  callback dispatches to. As of REQ-172, every row names a real
  `Letflow.Engine.Wasm.HostApi.do_*/N` function — `:call_service` is no longer a
  REQ-167 placeholder (its signature and dispatch both went real this requirement).
  """
  @type host_fn_spec ::
          :read_variable | :log | :now | :uuid | :call_service | :write_variable | :fail

  @typedoc """
  One entry in the host-function registry (`@known_imports` below). `capability` is
  the exact grant-set token gating this entry (exact-string membership only, no
  wildcard/prefix matching), or `:none` for a row that is always installed
  (REQ-171 design §4.1).
  """
  @type import_descriptor :: %{
          capability: capability_requirement(),
          namespace: String.t(),
          name: String.t(),
          params: [valtype()],
          results: [valtype()],
          stub: host_fn_spec()
        }

  @typedoc """
  The exact shape `Wasmex.start_link/1`'s `imports:` option requires:
  namespace -> import name -> a 4-tuple of
  `(:fn, params, results, callback)`.
  """
  @type import_table :: %{
          String.t() => %{String.t() => {:fn, [valtype()], [valtype()], (... -> term())}}
        }

  @typedoc """
  One concrete way a gated instantiation attempt failed. Structurally
  parallel to, but never shared with,
  `Letflow.Engine.Wasm.ModuleRegistry.instantiation_defect/0` (design
  §4 — each module keeps its own private crash classifier rather than
  extracting a shared helper, to avoid touching REQ-166's already
  gate-approved implementation).
  """
  @type instantiation_defect ::
          {:unresolved_import, namespace :: String.t(), function :: String.t()}
          | {:crashed, raw_reason :: term()}
          | {:timeout, timeout_ms :: non_neg_integer()}

  @typedoc "The structured rejection reason (AC1/AC3 — never a bare string)."
  @type gate_error :: {:instantiation_denied, instantiation_defect()}

  # design §2.2's decision -- a new, dedicated Task.Supervisor,
  # registered in lib/letflow/application.ex, distinct from
  # ModuleRegistryTaskSupervisor/PluginTaskSupervisor/Lua.TaskSupervisor.
  @task_supervisor Letflow.Engine.Wasm.CapabilityGateTaskSupervisor

  # design §5.2 step 2 -- an ELIXIR-DEV implementation constant, not
  # fixed by the design, mirroring ModuleRegistry's identical constant.
  @instantiation_timeout_ms 5_000

  # Matches the exact wording wasmex v0.15.1 produces for an unresolved
  # import (design §1.2, live-reproduced for this module's own cases).
  # A future wasmex version bump that changes this wording falls
  # through to the {:crashed, _} catch-all instead (a precision gap,
  # not a soundness one -- design §7).
  @unresolved_import_pattern ~r/unknown import: `(?<namespace>[^:`]+)::(?<function>[^`]+)` has not been defined/

  # design §6's original two-entry placeholder for `var:read`/`service:call`, extended
  # by REQ-171 design §4.4 with the real `read_variable`/`log`/`now`/`uuid` rows, and
  # by REQ-172 design §6.1 with real `write_variable`/`fail` rows plus
  # `platform_call_service`'s widened, real signature/dispatch. `var:read`/
  # `service:call` and `read_variable`/`platform_call_service` are WASM-06's own
  # acceptance-criterion text, used as-is. `read_variable`'s signature was widened from
  # the original illustrative `[:i32, :i32] -> [:i32]` to the real 4-param buffer-out
  # shape (REQ-171 design §5.3); `platform_call_service`'s signature is widened here
  # from its original illustrative 2-param placeholder to its real 6-param shape
  # (REQ-172 design §6.1).
  @known_imports [
    %{
      capability: "var:read",
      namespace: "env",
      name: "read_variable",
      params: [:i32, :i32, :i32, :i32],
      results: [:i32],
      stub: :read_variable
    },
    %{
      capability: "audit:log",
      namespace: "env",
      name: "log",
      params: [:i32, :i32, :i32, :i32, :i32, :i32],
      results: [],
      stub: :log
    },
    %{
      capability: :none,
      namespace: "env",
      name: "now",
      params: [:i32, :i32],
      results: [:i32],
      stub: :now
    },
    %{
      capability: :none,
      namespace: "env",
      name: "uuid",
      params: [:i32, :i32],
      results: [:i32],
      stub: :uuid
    },
    %{
      capability: "service:call",
      namespace: "env",
      name: "platform_call_service",
      params: [:i32, :i32, :i32, :i32, :i32, :i32],
      results: [:i32],
      stub: :call_service
    },
    %{
      capability: "var:write",
      namespace: "env",
      name: "write_variable",
      params: [:i32, :i32, :i32, :i32],
      results: [:i32],
      stub: :write_variable
    },
    %{
      capability: :none,
      namespace: "env",
      name: "fail",
      params: [:i32, :i32, :i32, :i32],
      results: [],
      stub: :fail
    }
  ]

  @doc """
  REQ-172 design §8.4 -- a small, additive, test-only accessor returning the `stub`
  field of every `@known_imports` row (i.e. every host function this module currently
  dispatches to a real `Letflow.Engine.Wasm.HostApi` implementation for, plus
  `:call_service`'s still-real dispatch since REQ-172 widens it), mirroring
  `Letflow.Engine.Lua.Platform.capability_matrix/0`'s own existing
  "exposed for introspection/testing" pattern. Used by `Letflow.Test.HostApiParity`'s
  own exhaustiveness guard so a future 8th `@known_imports` row lacking a matching
  scenario there is caught by construction, never by a second hand-written literal list.
  """
  @spec known_host_functions() :: [host_fn_spec()]
  def known_host_functions do
    Enum.map(@known_imports, & &1.stub)
  end

  @doc """
  Builds the `imports:` map (design §5.1) containing an entry for every
  `import_descriptor()` in `@known_imports` whose `capability` is `:none` (always
  included, REQ-171 design §4.1) or is a member of `manifest.capabilities` (exact
  string match) — and, structurally, no entry for any other descriptor whose
  capability is absent. Every installed callback is closed over the *empty*
  `Letflow.Engine.Wasm.HostApi.execution_context()` (REQ-171 design §4.6) — this
  module's own pre-existing tests exercise only whitelist-membership/instantiation
  success-or-failure, never a granted function's actual return value, so they
  continue to pass against this empty-context dispatcher unchanged. Pure function: no
  store, no module, no instantiation, no side effect.
  """
  @spec build_import_table(manifest()) :: import_table()
  def build_import_table(manifest) do
    build_import_table(manifest, HostApi.empty_execution_context())
  end

  @doc """
  REQ-171 design §4.6 — the real entry point. Identical to `build_import_table/1`
  except every installed callback closes over the given `execution_context` (captured
  once per call, fixed for the lifetime of the returned `import_table()`) instead of
  the empty sentinel.
  """
  @spec build_import_table(manifest(), HostApi.execution_context()) ::
          import_table()
  def build_import_table(%{capabilities: capabilities}, execution_context) do
    granted = MapSet.new(capabilities)

    @known_imports
    |> Enum.filter(&(&1.capability == :none or MapSet.member?(granted, &1.capability)))
    |> Enum.reduce(%{}, fn descriptor, table ->
      entry =
        {:fn, descriptor.params, descriptor.results,
         build_callback(descriptor.stub, execution_context)}

      Map.update(
        table,
        descriptor.namespace,
        %{descriptor.name => entry},
        &Map.put(&1, descriptor.name, entry)
      )
    end)
  end

  # design §4.7's dispatch fold -- for every row, a closure of arity
  # `1 + length(params)` (context, then one argument per declared param) that calls
  # the corresponding Letflow.Engine.Wasm.HostApi.do_* function with context, the raw
  # argument list, and the closed-over execution_context. No capability check runs
  # inside any of these callback bodies -- this module's own import-table-membership
  # filter, above, is the only gating WASM ever gets, structurally prior to any guest
  # code running at all.
  @spec build_callback(host_fn_spec(), HostApi.execution_context()) :: (... -> term())
  defp build_callback(:read_variable, execution_context) do
    fn context, name_ptr, name_len, out_ptr, out_cap ->
      HostApi.do_read_variable(context, name_ptr, name_len, out_ptr, out_cap, execution_context)
    end
  end

  defp build_callback(:log, execution_context) do
    fn context, level_ptr, level_len, message_ptr, message_len, context_ptr, context_len ->
      HostApi.do_log(
        context,
        level_ptr,
        level_len,
        message_ptr,
        message_len,
        context_ptr,
        context_len,
        execution_context
      )
    end
  end

  defp build_callback(:now, _execution_context) do
    fn context, out_ptr, out_cap -> HostApi.do_now(context, out_ptr, out_cap) end
  end

  defp build_callback(:uuid, _execution_context) do
    fn context, out_ptr, out_cap -> HostApi.do_uuid(context, out_ptr, out_cap) end
  end

  defp build_callback(:call_service, execution_context) do
    fn context, service_id_ptr, service_id_len, payload_ptr, payload_len, out_ptr, out_cap ->
      HostApi.do_call_service(
        context,
        service_id_ptr,
        service_id_len,
        payload_ptr,
        payload_len,
        out_ptr,
        out_cap,
        execution_context
      )
    end
  end

  defp build_callback(:write_variable, execution_context) do
    fn context, name_ptr, name_len, value_ptr, value_len ->
      HostApi.do_write_variable(
        context,
        name_ptr,
        name_len,
        value_ptr,
        value_len,
        execution_context
      )
    end
  end

  defp build_callback(:fail, _execution_context) do
    fn context, reason_ptr, reason_len, details_ptr, details_len ->
      HostApi.do_fail(context, reason_ptr, reason_len, details_ptr, details_len)
    end
  end

  @doc """
  Builds the whitelist (`build_import_table/1`) from `manifest`, then
  attempts a real instantiation of `bytes` against exactly that import
  table and no `wasi:` option (design §2/§7 — no filesystem grant path
  exists today). Runs the attempt inside a monitored
  `Task.Supervisor.async_nolink/2` task under
  `Letflow.Engine.Wasm.CapabilityGateTaskSupervisor`, never inline —
  the identical crash-propagation reason
  `req166-wasm-module-abi-validation.md` §1.5 live-reproduced and this
  design's own §1.2 re-confirmed for the whitelist case.

  On success, returns `{:ok, pid}` — a live, running instance the
  caller owns and must `GenServer.stop/1` when done. Unlike
  `ModuleRegistry.register/1`'s stage-2 proving instance, this function
  does **not** stop it: this is the real instance a caller intends to
  invoke against, not a proof-of-instantiability throwaway (design §3).

  On any instantiation failure — including an import outside the
  whitelist, or a denied WASI import — returns
  `{:error, {:instantiation_denied, instantiation_defect()}}`.
  """
  @spec start_instance(bytes :: binary(), manifest()) :: {:ok, pid()} | {:error, gate_error()}
  def start_instance(bytes, %{capabilities: _} = manifest) when is_binary(bytes) do
    table = build_import_table(manifest)

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Wasmex.start_link(%{bytes: bytes, imports: table})
      end)

    case Task.yield(task, @instantiation_timeout_ms) do
      {:ok, {:ok, pid}} ->
        {:ok, pid}

      {:ok, {:error, reason}} ->
        {:error, {:instantiation_denied, {:crashed, reason}}}

      {:exit, reason} ->
        {:error, {:instantiation_denied, classify_crash(reason)}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:instantiation_denied, {:timeout, @instantiation_timeout_ms}}}
    end
  end

  # design §4/§7 -- identical crash-shape match to
  # ModuleRegistry.classify_crash/1, deliberately duplicated rather
  # than shared (see this module's moduledoc and design §4).
  @spec classify_crash(term()) :: instantiation_defect()
  defp classify_crash({{:badmatch, {:error, message}}, _stacktrace} = reason)
       when is_binary(message) do
    case Regex.named_captures(@unresolved_import_pattern, message) do
      %{"namespace" => namespace, "function" => function} ->
        {:unresolved_import, namespace, function}

      nil ->
        {:crashed, reason}
    end
  end

  defp classify_crash(reason), do: {:crashed, reason}
end
