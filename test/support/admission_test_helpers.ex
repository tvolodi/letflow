defmodule Letflow.AdmissionTestHelpers do
  @moduledoc """
  REQ-217 test-only helpers for exercising `Letflow.Admission`'s real,
  application-supervised singleton (`Letflow.Plugs.Admission` hardcodes the
  default server name -- its `mount_opt()` has no `:name` override, per the
  design doc, so any test wiring through the real plug/pipeline necessarily
  talks to the SAME named singleton every other concurrently-running test
  would use too).

  `restart_admission!/1` is the "test config override" AC1/AC2 call for --
  restarts the singleton under `Letflow.Supervisor` with a fresh
  `Application.put_env(:letflow, :admission, ...)` + `Application.put_env(:letflow,
  Letflow.Repo, pool_size: ...)` in effect, so `Letflow.Admission.init/1`
  recomputes `global_cap` from the overridden config on the very next start
  (mirrors `Letflow.Admission`'s own moduledoc "Crash / restart semantics"
  section -- a restart is the documented way this module ever changes its
  cap).

  Safe to call only from an `async: false` test (this codebase's own
  established convention for anything touching this kind of shared,
  named-singleton state -- see `test/letflow/plugs/api_pipeline_integration_test.exs`'s
  moduledoc) -- per ExUnit's own scheduling (async modules all run to
  completion before ANY `async: false` module starts, and `async: false`
  modules run one at a time relative to each other), no concurrently-running
  test can observe a shrunk cap this helper installs.
  """

  alias Letflow.Admission

  @doc """
  Restarts the real `Letflow.Admission` singleton under `pool_size: pool_size`,
  `reserved_headroom: reserved_headroom` (so `global_cap = max(pool_size -
  reserved_headroom, 1)`), and registers an `ExUnit.Callbacks.on_exit/1`
  that restores the ORIGINAL `:letflow, :admission` / `:letflow, Letflow.Repo`
  config and restarts the singleton back to its production-derived cap, so
  no later test (including ones in other, later-running `async: false`
  modules) observes this test's artificially shrunk cap.

  Must be called from inside a test (needs `ExUnit.Callbacks.on_exit/1`).
  """
  @spec restart_admission!(pool_size: pos_integer(), reserved_headroom: non_neg_integer()) :: :ok
  def restart_admission!(opts) do
    pool_size = Keyword.fetch!(opts, :pool_size)
    reserved_headroom = Keyword.fetch!(opts, :reserved_headroom)

    original_admission_env = Application.get_env(:letflow, :admission, [])
    original_repo_env = Application.get_env(:letflow, Letflow.Repo)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:letflow, :admission, original_admission_env)
      Application.put_env(:letflow, Letflow.Repo, original_repo_env)
      do_restart()
    end)

    Application.put_env(:letflow, :admission, reserved_headroom: reserved_headroom)

    Application.put_env(
      :letflow,
      Letflow.Repo,
      Keyword.put(original_repo_env, :pool_size, pool_size)
    )

    do_restart()
  end

  defp do_restart do
    # REQ-219 (design req219-supervision-layering.md §1.1) moved
    # Letflow.Admission, along with the rest of the original flat 20-child
    # list, one level down from Letflow.Supervisor's own direct children
    # into Letflow.Supervisor.Infrastructure -- this restart must target
    # that same sub-supervisor now, not the top-level Letflow.Supervisor.
    Supervisor.terminate_child(Letflow.Supervisor.Infrastructure, Admission)
    {:ok, _pid} = Supervisor.restart_child(Letflow.Supervisor.Infrastructure, Admission)
    :ok
  end
end
