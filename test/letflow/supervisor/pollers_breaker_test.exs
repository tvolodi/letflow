defmodule Letflow.Supervisor.PollersBreakerTest do
  @moduledoc """
  ISS-0451 (design `iss0451-poller-crash-budget-isolation.md` §6): regression
  test for a PERSISTENT (never-cleared) `Letflow.Supervisor.Pollers` fault.

  This is the deliberate persistent-fault counterpart to
  `pollers_test.exs`'s own `AC4: crash-loop isolation` test: that test sets
  `:force_poller_crash` and clears it again immediately after observing the
  breaker's single-shot restart, proving REQ-219's original AC4 property
  (one exhaustion cycle restarts only Pollers). This test does the opposite
  on purpose -- it sets the SAME fault flag and never clears it during the
  test body -- to prove ISS-0451's own property: that a fault which keeps
  re-exhausting Pollers' own `5/60` budget, cycle after cycle, still cannot
  reach the top-level `Letflow.Supervisor`, `Letflow.Repo`, or
  `Letflow.Supervisor.Http` (Bandit) -- and that `Letflow.Supervisor.PollersBreaker`
  itself eventually trips to `:open` and stops trying, rather than retrying
  forever at the fault's own ~24-30ms cadence.

  `async: false` -- mutates global `Application` config and the live
  supervision tree (terminates/restarts the same named
  `Letflow.Supervisor.Pollers` singleton `pollers_test.exs`'s own AC4 test
  does) -- must not run concurrently with that module. ExUnit's own
  "async: false modules run one at a time" guarantee (already leaned on by
  `pollers_test.exs` and `test/support/admission_test_helpers.ex`) is what
  makes this safe with no new cross-file coordination.
  """

  use ExUnit.Case, async: false

  describe "ISS-0451: persistent Poller fault is bounded by PollersBreaker" do
    test "top-level Supervisor, Repo, and Http survive a persistent crash-loop, and the breaker trips to :open" do
      repo_pid_before = Process.whereis(Letflow.Repo)
      top_level_pid_before = Process.whereis(Letflow.Supervisor)
      infrastructure_pid_before = Process.whereis(Letflow.Supervisor.Infrastructure)
      http_pid_before = Process.whereis(Letflow.Supervisor.Http)

      assert repo_pid_before != nil
      assert top_level_pid_before != nil
      assert infrastructure_pid_before != nil

      # §6.2 step 2: the primary observable. If the top-level supervisor
      # ever exits during this test, this monitor's :DOWN is the exact
      # failure ISS-0451 describes.
      Process.monitor(top_level_pid_before)

      original_start_scheduler = Application.get_env(:letflow, :start_scheduler, true)

      on_exit(fn ->
        # §6.2 step 7 teardown: clear the fault, restore the gate, and
        # leave a clean, running, :closed-state singleton for later tests
        # -- same discipline as pollers_test.exs's own AC4 teardown.
        Application.delete_env(:letflow, :force_poller_crash)
        Application.put_env(:letflow, :start_scheduler, original_start_scheduler)
        restart_pollers_and_reset_breaker!()
      end)

      # §6.1: the exact opposite of pollers_test.exs's own AC4 test -- set
      # both env overrides and NEVER clear :force_poller_crash during the
      # test body. This is what makes the fault PERSISTENT.
      Application.put_env(:letflow, :start_scheduler, true)
      Application.put_env(:letflow, :force_poller_crash, true)

      # §6.2 step 3: trigger the first exit the same way pollers_test.exs's
      # revised AC4 test and this design's own §6.2 step 3 both do --
      # terminate then explicitly restart via the :temporary-carrying spec,
      # so init/1 re-reads the fresh env overrides and starts the
      # crash-looping poller. From here on, PollersBreaker is the sole
      # restart authority -- this test issues no further restart calls.
      :ok = Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)

      case Supervisor.start_child(
             Letflow.Supervisor,
             Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary)
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # §6.2 step 4: wait for the breaker to observe the persistent fault
      # and trip to :open. Generous 5s timeout -- §3.6's arithmetic predicts
      # well under 1 second in practice (mirroring ISSUE-FIXER's own
      # 96ms-for-4-cycles probe), but this must not be flaky under CI load.
      assert wait_for_breaker_open(), "PollersBreaker did not reach :open within the timeout"

      # §6.2 step 5: the core assertion, run WHILE the fault is STILL
      # persistent (env overrides still set, breaker still :open, nothing
      # cleared yet) -- the one moment REQ-219's own AC4 test structurally
      # cannot reach, because that test clears the fault before a 2nd
      # exhaustion cycle could occur.
      assert Process.whereis(Letflow.Repo) == repo_pid_before
      assert Process.whereis(Letflow.Supervisor.Infrastructure) == infrastructure_pid_before
      assert Process.whereis(Letflow.Supervisor.Http) == http_pid_before
      assert Process.whereis(Letflow.Supervisor) == top_level_pid_before

      refute_received {:DOWN, _ref, :process, ^top_level_pid_before, _reason}

      # §6.2 step 6: confirm the breaker is genuinely holding Pollers
      # stopped, not merely "the test got lucky with timing" -- a
      # supervisor started with the corrected
      # Supervisor.child_spec(child, restart: :temporary) children-list
      # entry genuinely leaves Process.whereis/1 for the killed child as
      # nil after it exits and is not restarted.
      assert Process.whereis(Letflow.Supervisor.Pollers) == nil

      assert Letflow.Supervisor.PollersBreaker.breaker_state() == :open
    end
  end

  # §6.2 step 4: poll (not assert_receive, since the breaker's own state
  # transition is internal GenServer state, not a message this test process
  # receives) breaker_state/0 until it reports :open, or give up after the
  # timeout.
  defp wait_for_breaker_open(attempts_left \\ 500) do
    cond do
      Letflow.Supervisor.PollersBreaker.breaker_state() == :open ->
        true

      attempts_left > 0 ->
        Process.sleep(10)
        wait_for_breaker_open(attempts_left - 1)

      true ->
        false
    end
  end

  # Teardown helper: the fault is already cleared by the time this runs, so
  # Pollers' own max_restarts: 5/max_seconds: 60 budget is not being
  # re-exhausted -- but PollersBreaker may currently be :open (holding
  # Pollers stopped) or mid-backoff. Bringing Pollers back up here requires
  # restarting the breaker itself (a plain :permanent top-level child) so
  # its own init/1 re-monitors a freshly-started Pollers from a clean
  # :closed, consecutive_trips: 0 state -- simply calling start_child/2 for
  # Pollers alone would leave the breaker's own internal state (:open or
  # :half_open, a stale monitor ref) inconsistent with the fresh Pollers pid,
  # which would corrupt state for whichever test runs next.
  defp restart_pollers_and_reset_breaker!() do
    _ =
      case Process.whereis(Letflow.Supervisor.Pollers) do
        nil -> :ok
        _pid -> Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)
      end

    case Supervisor.start_child(
           Letflow.Supervisor,
           Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary)
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.PollersBreaker)

    case Supervisor.restart_child(Letflow.Supervisor, Letflow.Supervisor.PollersBreaker) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Wait for the freshly-restarted breaker to settle back to :closed
    # (its own init/1 always starts :closed) before handing control to the
    # next test.
    wait_for_breaker_closed()
  end

  defp wait_for_breaker_closed(attempts_left \\ 500) do
    cond do
      Letflow.Supervisor.PollersBreaker.breaker_state() == :closed ->
        :ok

      attempts_left > 0 ->
        Process.sleep(10)
        wait_for_breaker_closed(attempts_left - 1)

      true ->
        :ok
    end
  end
end
