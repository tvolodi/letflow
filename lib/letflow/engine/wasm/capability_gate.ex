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

  ## Placeholder registry, not a resolved host-API vocabulary

  `@known_imports` is a small, fixed placeholder proving the
  *mechanism* (whitelist construction and enforcement) only — the real
  host-function vocabulary, signatures, and callback bodies belong to a
  future requirement (design §6/§8). No test of this module ever
  invokes a granted function through a successfully-instantiated
  instance; whitelist presence/absence and instantiation success/
  failure are both observable without calling the granted function, so
  each registry entry's callback is a trivial stub.
  """

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
  One entry in the placeholder host-function registry (`@known_imports`
  below). `capability` is the exact grant-set token gating this entry
  (exact-string membership only, no wildcard/prefix matching).
  """
  @type import_descriptor :: %{
          capability: capability(),
          namespace: String.t(),
          name: String.t(),
          params: [valtype()],
          results: [valtype()]
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

  # design §6's placeholder registry, verbatim -- exactly two entries.
  # `var:read`/`service:call` and `read_variable`/`platform_call_service`
  # are WASM-06's own acceptance-criterion text, used as-is (design §6
  # explains why no restatement is needed here, unlike WASM-07's
  # component-model-shaped literal). Signatures are illustrative
  # core-module type shapes only -- REQ-171/172 own the real ones.
  @known_imports [
    %{
      capability: "var:read",
      namespace: "env",
      name: "read_variable",
      params: [:i32, :i32],
      results: [:i32]
    },
    %{
      capability: "service:call",
      namespace: "env",
      name: "platform_call_service",
      params: [:i32, :i32],
      results: [:i32]
    }
  ]

  @doc """
  Builds the `imports:` map (design §5.1) containing an entry for every
  `import_descriptor()` in `@known_imports` whose `capability` is a
  member of `manifest.capabilities` (exact string match) — and,
  structurally, no entry for any descriptor whose capability is absent.
  Pure function: no store, no module, no instantiation, no side effect.
  """
  @spec build_import_table(manifest()) :: import_table()
  def build_import_table(%{capabilities: capabilities}) do
    granted = MapSet.new(capabilities)

    @known_imports
    |> Enum.filter(&MapSet.member?(granted, &1.capability))
    |> Enum.reduce(%{}, fn descriptor, table ->
      entry = {:fn, descriptor.params, descriptor.results, stub_callback()}

      Map.update(
        table,
        descriptor.namespace,
        %{descriptor.name => entry},
        &Map.put(&1, descriptor.name, entry)
      )
    end)
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

  # design §6 -- no test invokes a granted function through a running
  # instance; whitelist presence/absence and instantiation success/
  # failure are both observable without ever calling it. A trivial,
  # constant-returning stub suffices wherever a test needs a working,
  # callable placeholder. Every current registry entry has one i32
  # result, so a single arity/shape (context + 2 params) covers both.
  @spec stub_callback() :: (term(), term(), term() -> integer())
  defp stub_callback do
    fn _context, _arg1, _arg2 -> 0 end
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
