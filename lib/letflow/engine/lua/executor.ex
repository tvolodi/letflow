defmodule Letflow.Engine.Lua.Executor do
  @moduledoc """
  REQ-153 (LUA-02 restated) + REQ-154 (LUA-08 layer 1 restated) + REQ-155 (LUA-10
  layer 2 restated) — concrete `Executor` implementation for the tv-labs/lua BEAM
  runtime. Implements `@behaviour Letflow.Engine.LuaScriptAudit.Executor`.

  `script_ref` concrete shape: a binary containing the Lua source text to execute.

  Every call to `execute_with_manifest/2` creates a fresh `Lua.t()` via
  `Letflow.Engine.Lua.Sandbox.new/1` — no state is reused between invocations
  (LUA-02 isolation invariant). The manifest hash is the lowercase hex-encoded
  SHA-256 of the raw script source bytes, computed after execution succeeds.

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

  alias Letflow.Engine.Lua.Sandbox

  @doc """
  Implements `Letflow.Engine.LuaScriptAudit.Executor.execute_with_manifest/2`.
  Runs `script_source` (a binary containing Lua source text) in a fresh sandbox,
  under a supervised task bounded by a host-enforced wall-clock timeout, and returns
  the SHA-256 hex of the source as the manifest hash. Reads the instruction budget
  from Application config (`:letflow, :lua_max_instructions`) and the wall-clock
  timeout from Application config (`:letflow, :lua_wallclock_timeout_ms`).
  """
  @impl Letflow.Engine.LuaScriptAudit.Executor
  @spec execute_with_manifest(script_source :: binary(), registered_hash :: String.t()) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, {:wallclock_timeout, pos_integer()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  def execute_with_manifest(script_source, registered_hash)
      when is_binary(script_source) do
    execute_with_manifest(script_source, registered_hash,
      max_instructions: default_budget(),
      timeout_ms: default_timeout_ms()
    )
  end

  @doc """
  Runs `script_source` in a fresh sandbox with an explicit instruction budget and an
  explicit wall-clock timeout. `opts` must include `:max_instructions` (a
  `pos_integer()`) and `:timeout_ms` (a `pos_integer()`, milliseconds) — both are
  required, with no default at this arity, so a caller (in particular a test) can
  drive two different configured values in the same run without round-tripping
  through `Application.put_env/3`. Not part of the behaviour — use this overload in
  tests that need a specific budget and/or timeout per call site.

  The script body runs inside a task supervised by `Letflow.Engine.Lua.TaskSupervisor`
  (`Task.Supervisor.async_nolink/2`). The call blocks on `Task.yield/2` for at most
  `:timeout_ms`; if the task has not produced a result by then, the task's process is
  killed via `Task.shutdown(task, :brutal_kill)` and `{:error, {:wallclock_timeout,
  timeout_ms}}` is returned instead. This is unconditional and has no dependency on
  what the script itself did with any in-band `:max_instructions` error — see the
  moduledoc's REQ-155 section.
  """
  @spec execute_with_manifest(
          script_source :: binary(),
          registered_hash :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, {:wallclock_timeout, pos_integer()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  def execute_with_manifest(script_source, _registered_hash, opts)
      when is_binary(script_source) do
    budget = Keyword.fetch!(opts, :max_instructions)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    task =
      Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn ->
        run_script(script_source, budget)
      end)

    task
    |> Task.yield(timeout_ms)
    |> handle_yield_result(task, timeout_ms)
  end

  # The entirety of what REQ-154's execute_with_manifest/3 previously did
  # synchronously in the caller's process, now the body of the supervised task
  # (design §4.2). Returns exactly one of the four in-band outcomes; the fifth arm,
  # {:error, {:wallclock_timeout, _}}, is produced only by handle_yield_result/3
  # below and never by this function.
  defp run_script(script_source, budget) do
    lua = Sandbox.new(max_instructions: budget)

    try do
      Lua.eval!(lua, script_source)
      manifest_hash = :crypto.hash(:sha256, script_source) |> Base.encode16(case: :lower)
      {:ok, %{manifest_hash: manifest_hash}}
    rescue
      e in Lua.RuntimeException ->
        if String.contains?(Exception.message(e), "instruction budget exceeded") do
          {:error, {:budget_exceeded, budget}}
        else
          {:error, Exception.message(e)}
        end

      e in Lua.CompilerException ->
        {:error, Exception.message(e)}

      # Guard: script_ref is term() per the behaviour; reject non-binary gracefully
      _e in FunctionClauseError ->
        {:error, :invalid_script_ref}
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
end
