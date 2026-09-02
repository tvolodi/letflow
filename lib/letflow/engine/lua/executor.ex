defmodule Letflow.Engine.Lua.Executor do
  @moduledoc """
  REQ-153 (LUA-02 restated) + REQ-154 (LUA-08 layer 1 restated) + REQ-155 (LUA-10
  layer 2 restated) + REQ-158 (LUA-07, coordinated hash change) — concrete
  `Executor` implementation for the tv-labs/lua BEAM runtime. Implements
  `@behaviour Letflow.Engine.LuaScriptAudit.Executor`.

  `script_ref` concrete shape (widened by REQ-158, design
  `lib/letflow/design/req158-lua-manifest-validation.md` §5.3.1): either a bare
  `binary()` containing the Lua source text to execute (legacy shape, treated as
  paired with an empty manifest — `script_id: ""`, `capabilities: []` — so a
  bare-binary caller's hash is still `Letflow.Engine.Lua.Manifest.compute_hash/2`'s
  output, just over an empty manifest), or a two-key map
  `%{manifest: Letflow.Engine.Lua.Manifest.t(), script_source: binary()}` that
  carries a real manifest alongside the source text. A value that is neither
  shape returns `{:error, :invalid_script_ref}` without ever invoking the Lua
  runtime.

  Every call to `execute_with_manifest/2` creates a fresh `Lua.t()` via
  `Letflow.Engine.Lua.Sandbox.new/1` — no state is reused between invocations
  (LUA-02 isolation invariant). **REQ-158 change:** the manifest hash is no
  longer the bare SHA-256 of the script source alone — it is
  `Letflow.Engine.Lua.Manifest.compute_hash/2`'s output over the paired manifest
  and script source (manifest+script bytes, per that module's documented byte
  layout), computed after execution succeeds. This module calls
  `Manifest.compute_hash/2` directly rather than duplicating its byte-layout
  logic (design §5.3, "reuse that function directly").

  ## REQ-154: LUA-08 layer 1 restatement

  This module **restates LUA-08 as layer 1 of a two-layer pair**. It does NOT satisfy
  LUA-08's literal text on its own.

  LUA-08 literal: *"Exceeding the limit MUST terminate the script with a structured
  timeout error."*

  `:max_instructions` is an in-band, pcall-catchable budget. When the budget is hit,
  the `tv-labs/lua` library raises a Lua runtime error with the message
  `"instruction budget exceeded"`. A Lua script may wrap its own loop in `pcall` and
  intercept that error — the inner loop stops, execution returns to Lua, and
  `Lua.eval!/2` returns normally. This is expected layer-1 behavior (confirmed by
  REQ-148 spike OQ-2(a)). LUA-08's literal ("MUST terminate") is therefore not met by
  this layer alone.

  ## REQ-155: LUA-10 layer 2 restatement

  This requirement **restates LUA-10 as layer 2 of the mandatory LUA-08/LUA-10
  pair**. Neither LUA-08 nor LUA-10 is met until both layers have landed together —
  this module must not, on its own, claim either one satisfied independently of the
  other.

  LUA-10 literal: *"Each script execution MUST have a configurable wall clock timeout
  enforced BY THE HOST (not relying on Lua to cooperate)."*

  LUA-10's parenthetical — "enforced by the host", "not relying on Lua to
  cooperate" — is exactly what `:max_instructions` cannot satisfy, by construction,
  not as a limitation that more tuning would fix. `:max_instructions` is an in-band VM
  counter: when it is exhausted, control returns to the Lua script itself (via a
  raised, `pcall`-catchable error), and the script decides what happens next — that is
  the definition of "relying on Lua to cooperate." No configuration of
  `:max_instructions` changes this; the mechanism is intrinsically in-band and
  catchable.

  **Mechanism (decision 0014(a)):** a preemptively-scheduled BEAM process is
  interruptible by construction — this is the direct replacement for R-Co's single
  `LUA_MASKCOUNT` debug hook (INV-4), which existed only because it was "the only
  mechanism in the codebase that can interrupt a tight `while true do end` loop." On
  the BEAM, no hook is needed: `execute_with_manifest/2,3` runs the script body inside
  a task supervised by `Letflow.Engine.Lua.TaskSupervisor`, started via
  `Task.Supervisor.async_nolink/2`. The caller bounds the wait with `Task.yield/2` on
  the configured `:timeout_ms`; if the task has not finished within that window, the
  caller calls `Task.shutdown(task, :brutal_kill)` — an unconditional kill delivered
  from outside the task's process — and returns `{:error, {:wallclock_timeout,
  timeout_ms}}`. This kill fires purely on elapsed wall-clock time observed from
  outside the task. It has no dependency on whether the script trapped, ignored, or
  never triggered its own `:max_instructions` error: a script that `pcall`s its own
  budget exhaustion and loops again is still killed, because the outer timeout has no
  counter of its own for the script to reset or dodge — it only measures how long the
  task's OS-level process has been running.

  **Named supervisor: `Letflow.Engine.Lua.TaskSupervisor`, not a reuse of
  `Letflow.Engine.PluginTaskSupervisor`.** `lib/letflow/application.ex` already
  establishes the convention of one dedicated `Task.Supervisor` per subsystem rather
  than one shared supervisor for every supervised task in the application —
  `Letflow.SandboxPool.TaskSupervisor` and `Letflow.Engine.PluginTaskSupervisor`
  already coexist as two separate supervisors for two separate concerns. Lua script
  execution is a third, independent concern: it executes tenant-supplied script
  source directly (not an in-process Elixir plugin handler module), it sits on the
  hot path of workflow execution rather than of ad hoc plugin dispatch, and a
  dedicated supervisor keeps its crash/telemetry namespace (child counts,
  restart/shutdown observability) separate from plugin-handler task activity. A
  `Task.Supervisor` provides no resource quota that would make sharing one a capacity
  optimization — only a naming convenience — and this repo's own precedent already
  rejects that convenience.

  **Limitation carried forward from `lib/letflow/engine/plugin_interface.ex`'s
  moduledoc (same supervised-task mechanism, same disclosure):** this covers a script
  that hangs (an unbounded loop, or a blocking host-function call — LUA-10's own
  acceptance example), a script whose evaluation raises, and a task process that
  exits for any other reason — all fold into one of this module's `{:error, _}` arms
  within `timeout_ms`. This does **NOT** cover a hard kill of the BEAM node itself, or
  a call to `System.halt/0` — no task, monitor, or supervisor observes either from
  inside the same node, because both terminate the node the supervising process
  itself is running on. This is an accepted, stated limitation, not a gap this module
  papers over.

  ## REQ-156: LUA-09 restatement — configurable memory limit

  LUA-09 literal: *"Each script execution MUST have a configurable memory limit.
  Allocations exceeding the limit MUST fail gracefully and terminate the script."*

  LUA-09 has two clauses. **"terminate the script" is MET**: `:max_heap_size` with
  `kill: true` (REQ-149 §3, empirically verified: exit reason `:killed`) gives a hard,
  unconditional allocation boundary enforced by the BEAM scheduler itself, with no
  cooperation from the running script. **"fail gracefully" is NOT MET**: there is no
  allocator hook in a pure-BEAM Lua VM (`tv-labs/lua`), and no allocation-failure
  exception exists for `pcall` to intercept — the BEAM kills the process before any
  Lua-level trap can fire. The script observes nothing; it simply stops running. This
  is not a gap this module can close without replacing the Lua runtime with one that
  has a custom allocator hook (REQ-149 §3; decision 0014 named this "the weakest point
  of the Lua decision").

  **`:max_instructions` is rejected as a memory-limit proxy**, per decision 0014's
  OQ-1: allocation is not proportional to instruction count — a single opcode can
  allocate an arbitrarily large string (`string.rep("x", 1_000_000_000)`), while a
  tight arithmetic loop allocates nothing while exhausting an instruction budget. No
  code path in this module tightens `:max_instructions` in response to a memory
  concern, or vice versa — the two options are independently threaded through `opts`
  and independently enforced.

  **`Task.Supervisor.async_nolink/2,3` cannot carry `:max_heap_size`.** Read directly
  from the installed Elixir source (`task/supervisor.ex`, `task/supervised.ex`):
  `async_nolink/2,3`'s `async_opts` type accepts only `:shutdown`, and
  `Task.Supervised.start_link/2,3` spawn via bare `spawn_link/3` / `spawn/4` with no
  options list at all — there is no way to inject `max_heap_size` through
  `Task.Supervisor`. Therefore, when a memory limit is configured, this module
  bypasses `Task.Supervisor` entirely for that call and spawns the script's process
  directly via `:erlang.spawn_opt/2` with `[:monitor, max_heap_size: %{size:
  max_heap_words, kill: true, error_logger: false}]`.

  **Branching on `:max_heap_words`.** `nil` (unconstrained) keeps the REQ-155 path
  completely unchanged — `Task.Supervisor.async_nolink/2` + `Task.yield/2` +
  `Task.shutdown(task, :brutal_kill)`. A configured `pos_integer()` uses the new
  `spawn_opt`/monitor path instead: the caller's own bounded `receive`/`after` stands
  in for `Task.yield/2`, and `Process.exit(pid, :kill)` stands in for
  `Task.shutdown(task, :brutal_kill)` if the caller's own timeout fires first.

  **Resolving the `:killed` ambiguity structurally, not by reason atom.** Both a
  BEAM-issued `max_heap_size` kill and a caller-issued timeout kill produce the
  identical exit reason `:killed` on the `:DOWN` message — the atom alone does not say
  who killed the process. This module resolves the ambiguity by message-arrival
  order: the caller only issues its own kill *after* its bounded wait has already
  expired with nothing observed. A `:killed` `:DOWN` message received *during* that
  bounded wait — before the caller has taken any killing action of its own — cannot
  be attributed to the caller, because nothing else monitors or otherwise has standing
  to kill that unlinked process. It can only be the BEAM's own `max_heap_size`
  enforcement, and is reported as `{:error, :memory_limit_exceeded}`.

  **Observability divergence from the `nil` path.** When a memory limit is
  configured, the executing process is not a child of `Letflow.Engine.Lua.TaskSupervisor`
  and does not appear in `Task.Supervisor.children/1` on that supervisor, because it
  is spawned directly rather than through any supervisor.

  ## REQ-162 (LUA-16 restated) — uncaught Lua runtime errors captured as structured SCRIPT_ERROR

  LUA-16 literal: *"Uncaught Lua errors MUST be captured by the host and converted to
  structured SCRIPT_ERROR events with stack trace, instruction count consumed, and
  capability state at failure."* Its acceptance example ("division by zero in script
  yields rich error report") is a Lua 5.1 assumption that does not fire as written in
  this runtime: `1/0` (float division) evaluates to `inf` and never raises (Lua 5.3
  §3.4.1, confirmed by direct reading of `deps/lua/lib/lua/vm/executor.ex`). Only the
  integer floor-division/modulo operators raise on a zero divisor; this module's own
  tests substitute `1//0` (raises `"attempt to divide by zero"`, the closer literal
  match) rather than `1%0` (raises `"attempt to perform 'n%0'"`, which reads as a
  modulo failure, not a division one) or `1/0` (does not raise at all).

  **Branch (a) of LUA-16's restatement holds: the consumed instruction count IS
  retrievable on the uncaught-error path**, via
  `exception.original.state.instruction_count` — `exception` being the
  `%Lua.RuntimeException{}` caught by `run_script/3`'s `rescue`, `.original` the
  wrapped `%Lua.VM.RuntimeError{}`/`%Lua.VM.TypeError{}`/`%Lua.VM.AssertionError{}`
  struct, and `.state` the `Lua.VM.State.t()` snapshot at the raising instruction. This
  diverges from REQ-148 §5/OQ-2(c)'s own success-path finding
  (`lua_after.state.instruction_count`, read off the returned `Lua.t()`): on the
  raise path there is no returned `Lua.t()` at all, so the value lives one level
  deeper, inside the wrapped exception instead. The narrower per-instance fallback
  (branch (b)) is retained for exception shapes with no populated `:state` field
  (`Lua.VM.InternalError` declares no `:state` field at all; an arbitrary Elixir
  exception reaching `Lua.eval!/2`'s catch-all clause has none either) — those report
  `{:configured_budget, budget}` instead, never a zero-filled `instruction_count: 0`.

  **Five-arm distinction.** `{:error, {:script_error, script_error()}}` (this
  section) is pattern-match-distinguishable from all four other real arms:
  `{:script_failed, _}` (req161-lua-platform-fail.md §3.3 — a process `exit/1`, not an
  `{:error, _}` return, and a tag this module never reuses for SCRIPT_ERROR),
  `{:error, {:budget_exceeded, _}}` (the string-matched branch that runs strictly
  first in the same `rescue` clause), `{:error, {:wallclock_timeout, _}}` (produced
  only by `handle_yield_result/3`'s `nil` clause or `run_with_heap_limit/5`'s `after`
  clause, never inside `run_script/3`), and `:memory_limit_exceeded` (a bare atom, not
  a 2-tuple).

  **Inherited capability-wiring gap (not closed by this requirement).**
  `run_script/3` constructs its sandbox via `Sandbox.new(max_instructions: budget)`,
  which unconditionally installs the empty `Letflow.Engine.Lua.Capabilities.new()`
  grant set (`sandbox.ex`, `platform.ex`'s own "OQ-1"). The `capabilities` field below
  is correctly wired to `Letflow.Engine.Lua.Capabilities`'s real type — the same
  empty-grant-set value `Sandbox.new/1` already installs, not a separately-constructed
  empty set that merely looks the same — but will report `[]` for every SCRIPT_ERROR
  produced via the real `execute_with_manifest/2,3` path today, until a future
  requirement threads `manifest.capabilities` into `Sandbox.new/1`. This mirrors
  `req161-lua-platform-fail.md` §4's own disclosure convention for an analogous gap.

  **Stack-trace sanitization is structural, not a best-effort filter.** `stack_trace`
  never surfaces an Elixir-level stacktrace (`__STACKTRACE__`,
  `Process.info(pid, :current_stacktrace)`). For the typed case (`Lua.VM.RuntimeError`/
  `TypeError`/`AssertionError`), it is `Lua.RuntimeException.to_map(exception).call_stack`
  — the library's own Lua-level call-frame render, which cannot embed an Elixir module
  atom or a host filesystem path because `build_call_stack/1` never reads either. For
  the untyped/fallback case (`Lua.VM.InternalError`, or an arbitrary Elixir exception),
  `message` is a fixed, non-leaking placeholder and `stack_trace` is `[]`, rather than
  attempting to scrub an open-ended message format. A dedicated regression test (per
  REQ-148 §5's own warning, since this mechanism reaches one level deeper than the
  success-path read) asserts a real, uncaught VM-opcode error's `.original.state` is a
  populated `%Lua.VM.State{}` carrying a non-negative `:instruction_count`, so a future
  `tv-labs/lua` upgrade that removes or renames either field fails loudly instead of
  silently reporting branch (b) forever.

  ## What R-Co had, and why it does not port

  **INV-2 (registry-stored limiter):** R-Co stored the limiter pointer in
  `LUA_REGISTRYINDEX` to prevent a script from writing `_G.__limiter__ = nil` and
  defeating the counter. This threat does not exist in the `tv-labs/lua` runtime:
  `:max_instructions` is wired into the VM at construction time via `Lua.new/1` and is
  not reachable from Lua script globals. **INV-2 does not port because the threat it
  guarded against does not exist in this runtime.**

  **INV-4 (one combined `LUA_MASKCOUNT` hook):** R-Co used a single `LUA_MASKCOUNT`
  debug hook to carry both the instruction-count check and the elapsed-time check,
  because that hook was the only Lua C API mechanism that could interrupt a tight
  `while true do end` loop. **INV-4 does not port because this runtime has no hook API
  and needs none.** The `tv-labs/lua` library enforces `:max_instructions` via its own
  internal VM counter. The tight-loop interruption that INV-4 existed to solve is
  REQ-155's problem, solved by preemptive BEAM scheduling (see above). **No hook was
  intentionally never written.**
  """

  @behaviour Letflow.Engine.LuaScriptAudit.Executor

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Manifest
  alias Letflow.Engine.Lua.Sandbox

  @typedoc "See moduledoc's REQ-158 section for the two accepted shapes. New " <>
             "callers should prefer the manifest-carrying map shape " <>
             "(`%{manifest: Manifest.t(), script_source: binary()}`) -- the bare " <>
             "`binary()` shape is legacy, retained only because ~40 pre-existing " <>
             "test call sites still pass a bare script string."
  @type script_ref :: binary() | %{manifest: Manifest.t(), script_source: binary()}

  @typedoc "REQ-162 design §3 — one Lua-level call frame, exactly the shape " <>
             "`Lua.VM.ErrorFormatter.to_map/3` already documents and builds. `source`/" <>
             "`name` are Lua-level (a chunk source name, a Lua function name), never an " <>
             "Elixir module or a host filesystem path -- see moduledoc's REQ-162 section."
  @type lua_frame :: %{
          source: String.t() | nil,
          line: pos_integer() | nil,
          name: String.t() | nil
        }

  @typedoc "REQ-162 design §3/§2.3 -- a two-tag union so the branch that fired is part " <>
             "of the value's own shape, never a bare integer that could be mistaken for " <>
             "a zero-filled or silently-defaulted count. `{:consumed, n}` when " <>
             "`exception.original.state` is a populated `%Lua.VM.State{}`; " <>
             "`{:configured_budget, budget}` otherwise."
  @type instruction_count_report ::
          {:consumed, non_neg_integer()} | {:configured_budget, pos_integer()}

  @typedoc "REQ-162 design §3 -- the structured SCRIPT_ERROR payload built from an " <>
             "uncaught `Lua.RuntimeException` (any Lua.RuntimeException other than the " <>
             "budget-exceeded one, which stays `{:budget_exceeded, _}`)."
  @type script_error :: %{
          message: String.t(),
          stack_trace: [lua_frame()],
          instruction_count: instruction_count_report(),
          capabilities: [Capabilities.capability()]
        }

  @doc """
  Implements `Letflow.Engine.LuaScriptAudit.Executor.execute_with_manifest/2`.
  Runs the paired script source (see moduledoc's `script_ref` shapes) in a fresh
  sandbox, under a supervised task bounded by a host-enforced wall-clock timeout,
  and returns `Letflow.Engine.Lua.Manifest.compute_hash/2`'s output (manifest+
  script bytes, REQ-158) as the manifest hash. Reads the instruction budget from
  Application config (`:letflow, :lua_max_instructions`), the wall-clock timeout
  from Application config (`:letflow, :lua_wallclock_timeout_ms`), and the heap word
  limit from Application config (`:letflow, :lua_max_heap_words`, REQ-156).
  """
  @impl Letflow.Engine.LuaScriptAudit.Executor
  @spec execute_with_manifest(script_ref :: script_ref(), registered_hash :: String.t()) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, {:wallclock_timeout, pos_integer()}}
          | {:error, :memory_limit_exceeded}
          | {:error, {:script_error, script_error()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  def execute_with_manifest(script_ref, registered_hash) do
    execute_with_manifest(script_ref, registered_hash,
      max_instructions: default_budget(),
      timeout_ms: default_timeout_ms(),
      max_heap_words: default_max_heap_words()
    )
  end

  @doc """
  Runs `script_source` in a fresh sandbox with an explicit instruction budget, an
  explicit wall-clock timeout, and an explicit heap word limit. `opts` must include
  `:max_instructions` (a `pos_integer()`), `:timeout_ms` (a `pos_integer()`,
  milliseconds), and `:max_heap_words` (a `pos_integer()` or `nil`, REQ-156) — all
  three are required, with no default at this arity, so a caller (in particular a
  test) can drive different configured values in the same run without round-tripping
  through `Application.put_env/3`. Not part of the behaviour — use this overload in
  tests that need a specific budget, timeout, and/or heap limit per call site.

  When `:max_heap_words` is `nil` (unconstrained), the script body runs inside a task
  supervised by `Letflow.Engine.Lua.TaskSupervisor` (`Task.Supervisor.async_nolink/2`),
  exactly as REQ-155 established: the call blocks on `Task.yield/2` for at most
  `:timeout_ms`, and on a `nil` yield the task's process is killed via
  `Task.shutdown(task, :brutal_kill)`, returning `{:error, {:wallclock_timeout,
  timeout_ms}}`.

  When `:max_heap_words` is a `pos_integer()`, `Task.Supervisor` is bypassed entirely
  (it cannot carry a `max_heap_size` spawn option — see the moduledoc's REQ-156
  section) and the script body runs in a process spawned directly via
  `:erlang.spawn_opt/2` with `[:monitor, max_heap_size: %{size: max_heap_words, kill:
  true, error_logger: false}]`. A BEAM heap-kill observed before the caller's own
  wall-clock timeout fires returns `{:error, :memory_limit_exceeded}`; the caller's
  own timeout, if it fires first, kills the process directly and returns
  `{:error, {:wallclock_timeout, timeout_ms}}` — see the moduledoc for how the two
  `:killed` sources are told apart.
  """
  @spec execute_with_manifest(
          script_ref :: script_ref(),
          registered_hash :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, {:wallclock_timeout, pos_integer()}}
          | {:error, :memory_limit_exceeded}
          | {:error, {:script_error, script_error()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  def execute_with_manifest(script_ref, _registered_hash, opts) do
    budget = Keyword.fetch!(opts, :max_instructions)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_heap_words = Keyword.fetch!(opts, :max_heap_words)

    case normalize_script_ref(script_ref) do
      :error ->
        {:error, :invalid_script_ref}

      {:ok, {manifest, script_source}} ->
        case max_heap_words do
          nil ->
            task =
              Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn ->
                run_script(manifest, script_source, budget)
              end)

            task
            |> Task.yield(timeout_ms)
            |> handle_yield_result(task, timeout_ms)

          heap_words when is_integer(heap_words) and heap_words > 0 ->
            run_with_heap_limit(manifest, script_source, budget, timeout_ms, heap_words)
        end
    end
  end

  # REQ-158, design §5.3.1: script_ref widened from a bare binary to optionally
  # carry a Manifest.t() alongside the source text. A bare binary is treated as
  # paired with an empty manifest (script_id: "", capabilities: []) so its hash is
  # still Manifest.compute_hash/2's output, just over an empty manifest -- this is
  # what keeps every pre-REQ-158 bare-binary caller (REQ-153/154/155/156's own
  # tests) compiling and running unchanged, while every hash this module now
  # returns is uniformly produced by Manifest.compute_hash/2, never duplicated.
  @spec normalize_script_ref(script_ref()) :: {:ok, {Manifest.t(), binary()}} | :error
  defp normalize_script_ref(script_source) when is_binary(script_source) do
    {:ok, {%Manifest{script_id: "", capabilities: []}, script_source}}
  end

  defp normalize_script_ref(%{manifest: %Manifest{} = manifest, script_source: script_source})
       when is_binary(script_source) do
    {:ok, {manifest, script_source}}
  end

  defp normalize_script_ref(_other), do: :error

  # The entirety of what REQ-154's execute_with_manifest/3 previously did
  # synchronously in the caller's process, now the body of the supervised task
  # (design §4.2). Returns exactly one of the four in-band outcomes; the fifth arm,
  # {:error, {:wallclock_timeout, _}}, is produced only by handle_yield_result/3
  # below and never by this function.
  defp run_script(manifest, script_source, budget) do
    lua = Sandbox.new(max_instructions: budget)

    try do
      Lua.eval!(lua, script_source)
      manifest_hash = Manifest.compute_hash(manifest, script_source)
      {:ok, %{manifest_hash: manifest_hash}}
    rescue
      e in Lua.RuntimeException ->
        if String.contains?(Exception.message(e), "instruction budget exceeded") do
          {:error, {:budget_exceeded, budget}}
        else
          {:error, {:script_error, build_script_error(e, budget, Capabilities.new())}}
        end

      e in Lua.CompilerException ->
        {:error, Exception.message(e)}

      # Guard: script_ref is term() per the behaviour; reject non-binary gracefully
      _e in FunctionClauseError ->
        {:error, :invalid_script_ref}
    end
  end

  # REQ-162 design §3/§13. Placeholder message for the untyped/fallback stack-trace
  # case (§6.2 -- exact wording is not load-bearing for any acceptance criterion, only
  # that it never leaks Elixir/host detail).
  @script_error_placeholder_message "internal script execution error"

  # Builds the script_error() shape (design §3) from the rescued Lua.RuntimeException,
  # the configured instruction budget (used only for the {:configured_budget, _}
  # fallback branch), and the grant set the executing sandbox held for the run.
  #
  # Public (with @doc false), not private: this is REQ-162 design §4.2/AC3's
  # "shaping-function level" test seam. Triggering a Lua.VM.InternalError-wrapping
  # Lua.RuntimeException naturally from parsed Lua source is not practical (its only
  # raise sites -- "goto target not found", "unimplemented instruction", "break
  # outside loop" -- are all unreachable past the compiler's own static checks for
  # any script that actually parses), so the executor_test.exs suite exercises this
  # function directly with a constructed exception double rather than only through
  # `execute_with_manifest/2,3`. Not part of the `Executor` behaviour; no external
  # caller other than this module's own `run_script/3` and its test suite.
  @spec build_script_error(Lua.RuntimeException.t(), pos_integer(), Capabilities.grant_set()) ::
          script_error()
  @doc false
  def build_script_error(%Lua.RuntimeException{} = exception, budget, capabilities) do
    %{
      message: script_error_message(exception),
      stack_trace: script_error_stack_trace(exception),
      instruction_count: instruction_count_report(exception.original, budget),
      capabilities: MapSet.to_list(capabilities)
    }
  end

  # Typed case (design §6.1): the wrapped exception is one of the three VM error
  # shapes this design confirmed reliably carries :state and has a dedicated
  # Lua.RuntimeException.to_map/2 clause. message/1 here is Lua.RuntimeException's
  # own message/1 -- never the raw Elixir inspect/1 of an arbitrary term.
  defp script_error_message(%Lua.RuntimeException{original: original} = exception)
       when is_struct(original, Lua.VM.RuntimeError) or is_struct(original, Lua.VM.TypeError) or
              is_struct(original, Lua.VM.AssertionError) do
    Exception.message(exception)
  end

  # Untyped/fallback case (design §6.2): a fixed, non-leaking placeholder --
  # never the wrapped exception's own message, which for an arbitrary Elixir
  # exception can legitimately embed argument dumps or module names.
  defp script_error_message(%Lua.RuntimeException{}), do: @script_error_placeholder_message

  defp script_error_stack_trace(%Lua.RuntimeException{original: original} = exception)
       when is_struct(original, Lua.VM.RuntimeError) or is_struct(original, Lua.VM.TypeError) or
              is_struct(original, Lua.VM.AssertionError) do
    Lua.RuntimeException.to_map(exception).call_stack
  end

  defp script_error_stack_trace(%Lua.RuntimeException{}), do: []

  # REQ-162 design §2.3's per-instance rule -- inspects exception.original for a
  # populated %Lua.VM.State{} in its :state field. `%{state: %Lua.VM.State{}}` only
  # matches when that key is present AND holds a populated struct (not nil, and not
  # absent -- Lua.VM.InternalError declares no :state field at all, so this clause
  # structurally cannot match it). Never a zero-filled instruction_count: 0.
  @spec instruction_count_report(term(), pos_integer()) :: instruction_count_report()
  defp instruction_count_report(%{state: %Lua.VM.State{instruction_count: count}}, _budget) do
    {:consumed, count}
  end

  defp instruction_count_report(_original, budget) do
    {:configured_budget, budget}
  end

  # ISS-0426 design §2.1.1/§2.1.1a candidate (i): a test-only synchronous entry point
  # that calls run_script/3 directly, with no Task.Supervisor.async_nolink and no
  # Task.yield in its call chain. Precedented by this module's own build_script_error/3
  # above (public, @doc false, test-only) -- same shape, same justification: a test
  # needs an inner function without the wrapper that isn't the thing under test.
  #
  # Production impact: none. execute_with_manifest/2,3 and every other production
  # function in this module are untouched byte-for-byte -- this is a new, additive
  # function alongside them, called only from tests (ISS-0426 HARD CONSTRAINT 1/AC4).
  #
  # Categorical bound (design §2.1.1b): run_script/3 always runs under
  # Sandbox.new(max_instructions: budget) -- a real VM-level instruction counter the
  # tv-labs/lua interpreter enforces on every opcode it executes, not interceptable
  # from Lua source (see moduledoc's REQ-154/155 sections). A script can only escape
  # the *outcome* of that counter (by pcall-catching the raised "instruction budget
  # exceeded" error and continuing); it cannot escape the counter *incrementing*. So
  # for any script that does not use Lua's own `goto` to construct a non-standard,
  # VM-level-uninstrumented control-flow escape, this function terminates within a
  # bounded number of VM instructions by construction -- a categorical guarantee, not
  # a fact about which scripts today's callers happen to pass it. This is a STRONGER,
  # different-in-kind guarantee than run_with_heap_limit_sync/5 below carries -- see
  # that function's own @doc false for the contrast.
  @spec run_script_sync(Manifest.t(), binary(), pos_integer()) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, {:script_error, script_error()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  @doc false
  def run_script_sync(manifest, script_source, budget) do
    run_script(manifest, script_source, budget)
  end

  # REQ-156, design §5: the max_heap_words-configured path. Task.Supervisor cannot
  # carry a max_heap_size spawn_opt (moduledoc REQ-156 section), so this bypasses it
  # entirely and spawns directly via :erlang.spawn_opt/2 with :monitor (atomically
  # returning {pid, monitor_ref}, race-free) plus max_heap_size: kill: true.
  #
  # Two distinct references are in play, deliberately: `reply_ref` is this module's
  # own tag for the spawned process's normal-completion message (mirroring the
  # {ref, reply} shape Task.Supervised's own protocol uses internally, but owned by
  # this module's code, not borrowed from Task's private contract) -- it must be
  # generated by the caller before spawning, since the child cannot know the BIF's
  # atomically-returned monitor_ref in advance. `monitor_ref` is the spawn_opt :monitor
  # reference, used only to identify :DOWN messages for this specific pid.
  defp run_with_heap_limit(manifest, script_source, budget, timeout_ms, max_heap_words) do
    parent = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          send(parent, {reply_ref, run_script(manifest, script_source, budget)})
        end,
        [:monitor, max_heap_size: %{size: max_heap_words, kill: true, error_logger: false}]
      )

    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      # Design §5.3: this :killed DOWN is observed strictly before the `after` clause
      # below has had any chance to issue the caller's own kill -- so it cannot be
      # attributed to the caller. Nothing else monitors or links to this process, so
      # it can only be the BEAM's own max_heap_size enforcement.
      {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
        {:error, :memory_limit_exceeded}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, "#{inspect(__MODULE__)} task crashed: " <> format_exit_reason(reason)}
    after
      # This module's own bounded wait standing in for Task.yield/2, and the
      # unconditional kill below standing in for Task.shutdown(task, :brutal_kill) --
      # design §5.2. Reaching this branch means nothing was observed within
      # timeout_ms, so any :killed DOWN this process is about to trigger below is
      # attributable to this caller's own action, not the BEAM's heap enforcement.
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end

        {:error, {:wallclock_timeout, timeout_ms}}
    end
  end

  # ISS-0426 design §2.1.2/§2.1.2a: a test-only unbounded-wait variant of
  # run_with_heap_limit/5 above, for the heap-limited Group 1 call sites. Mirrors that
  # function's spawn_opt/monitor/receive shape exactly -- same spawn_opt call, same
  # reply_ref/monitor_ref pair, same three receive clauses ({^reply_ref, result}, the
  # :killed :DOWN, and the other-reason :DOWN) -- with the `after timeout_ms -> ...`
  # clause REMOVED ENTIRELY. The max_heap_size: %{kill: true} spawn_opt is retained
  # unchanged: that BEAM-enforced limit, not this function's own patience, is what
  # still bounds these workloads. run_with_heap_limit/5 itself is untouched by this
  # addition (ISS-0426 HARD CONSTRAINT 1/AC4) -- this is a second, narrower entry
  # point alongside it, never invoked from any non-test code path.
  #
  # BINDING USAGE CONTRACT (ISS-0426 design §2.1.2a -- this is the binding text
  # itself, not merely a pointer to the design doc; per rework 2's explicit
  # requirement, callers must be able to read the rule here at the call site):
  #
  #   Callers of this function MUST pass a workload that is guaranteed to terminate
  #   on its own, independently of any wall-clock enforcement -- either because it is
  #   bounded by :max_instructions alone (a fixed-iteration or otherwise self-limiting
  #   script with no construct that traps and re-triggers its own budget exhaustion),
  #   or because it is expected to terminate via the configured max_heap_words
  #   heap-kill. This function deliberately does not enforce a wall-clock bound --
  #   that is its entire purpose, to let Group-1 tests assert an outcome without
  #   racing the production wall-clock kill (run_with_heap_limit/5's own `after`
  #   clause, untouched above). A script that can catch its own instruction-budget
  #   exhaustion (e.g. via pcall) and continue executing is NOT a valid input to this
  #   function: nothing will terminate it, and the calling test process will hang
  #   until ExUnit's own default 60s test timeout, not this function's -- a
  #   materially worse failure mode than the flake this function exists to remove. If
  #   a workload cannot be shown to terminate independently of wall-clock enforcement,
  #   it belongs in the tagged/isolated :lua_wallclock_race partition instead (racing
  #   the real `after` clause via run_with_heap_limit/5 or Task.yield as normal) --
  #   never passed to this function.
  #
  # Guarantee kind (design §2.1.1b's contrast table): this is CONTRACTUAL, not
  # categorical like run_script_sync/3 above -- it holds only if the caller obeys the
  # contract stated above; this function's own mechanism enforces nothing if the
  # contract is violated. The memory-limit path itself stays exactly as strong as
  # run_with_heap_limit/5's: max_heap_size: kill: true is enforced by the BEAM
  # runtime on the spawned process regardless of whether anything is receive-ing for
  # it, so removing the wait's own timeout does not relax the heap limit, only this
  # function's patience for observing the outcome.
  @spec run_with_heap_limit_sync(Manifest.t(), binary(), pos_integer(), pos_integer()) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, {:script_error, script_error()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
          | {:error, :memory_limit_exceeded}
  @doc false
  def run_with_heap_limit_sync(manifest, script_source, budget, max_heap_words) do
    parent = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          send(parent, {reply_ref, run_script(manifest, script_source, budget)})
        end,
        [:monitor, max_heap_size: %{size: max_heap_words, kill: true, error_logger: false}]
      )

    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      # No caller-issued kill exists on this path at all (the `after` clause is
      # removed entirely), so every :killed DOWN this function can possibly observe
      # is unconditionally the BEAM's own max_heap_size enforcement -- the ordering
      # argument run_with_heap_limit/5 relies on degenerates to a simpler, strictly
      # stronger statement here: there is no caller-issued kill branch to
      # disambiguate against in the first place (design §2.1.2).
      {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
        {:error, :memory_limit_exceeded}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, "#{inspect(__MODULE__)} task crashed: " <> format_exit_reason(reason)}
    end
  end

  # Task.yield/2 result handling, mirroring plugin_interface.ex's
  # handle_yield_result/4 private clauses (design §4.3), applied to this module's
  # five-arm return union instead of PluginInterface's outcome().
  defp handle_yield_result({:ok, {:ok, %{manifest_hash: hash}} = result}, _task, _timeout_ms)
       when is_binary(hash) do
    result
  end

  defp handle_yield_result(
         {:ok, {:error, {:budget_exceeded, limit}} = result},
         _task,
         _timeout_ms
       )
       when is_integer(limit) do
    result
  end

  defp handle_yield_result({:ok, {:error, {:script_error, _}} = result}, _task, _timeout_ms) do
    result
  end

  defp handle_yield_result({:ok, {:error, :invalid_script_ref} = result}, _task, _timeout_ms) do
    result
  end

  defp handle_yield_result({:ok, {:error, reason} = result}, _task, _timeout_ms)
       when is_binary(reason) do
    result
  end

  defp handle_yield_result({:ok, other}, _task, _timeout_ms) do
    {:error,
     "#{inspect(__MODULE__)} task returned a value outside its contract: " <> inspect(other)}
  end

  defp handle_yield_result({:exit, reason}, _task, _timeout_ms) do
    {:error, "#{inspect(__MODULE__)} task crashed: " <> format_exit_reason(reason)}
  end

  defp handle_yield_result(nil, task, timeout_ms) do
    Task.shutdown(task, :brutal_kill)
    {:error, {:wallclock_timeout, timeout_ms}}
  end

  defp format_exit_reason({exception, stacktrace}) when is_list(stacktrace) do
    Exception.format(:error, exception, stacktrace)
  rescue
    _ -> inspect({exception, stacktrace})
  end

  defp format_exit_reason(reason), do: inspect(reason)

  @spec default_budget() :: pos_integer()
  defp default_budget do
    Application.fetch_env!(:letflow, :lua_max_instructions)
  end

  @spec default_timeout_ms() :: pos_integer()
  defp default_timeout_ms do
    Application.fetch_env!(:letflow, :lua_wallclock_timeout_ms)
  end

  @spec default_max_heap_words() :: pos_integer() | nil
  defp default_max_heap_words do
    Application.fetch_env!(:letflow, :lua_max_heap_words)
  end
end
