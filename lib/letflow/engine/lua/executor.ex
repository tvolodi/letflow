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

  alias Letflow.Engine.Lua.Manifest
  alias Letflow.Engine.Lua.Sandbox

  @typedoc "See moduledoc's REQ-158 section for the two accepted shapes."
  @type script_ref :: binary() | %{manifest: Manifest.t(), script_source: binary()}

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
          {:error, Exception.message(e)}
        end

      e in Lua.CompilerException ->
        {:error, Exception.message(e)}

      # Guard: script_ref is term() per the behaviour; reject non-binary gracefully
      _e in FunctionClauseError ->
        {:error, :invalid_script_ref}
    end
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

  @spec default_max_heap_words() :: pos_integer() | nil
  defp default_max_heap_words do
    Application.fetch_env!(:letflow, :lua_max_heap_words)
  end
end
