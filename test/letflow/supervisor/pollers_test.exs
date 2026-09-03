defmodule Letflow.Supervisor.PollersTest do
  @moduledoc """
  REQ-219 (design `req219-supervision-layering.md` §4/§5/§6/§8): AC2 (a
  genuine cold-boot ordering test), AC4 (crash-loop isolation), and AC7
  (empty-children-list under `config/test.exs`'s current gates).

  `async: false` -- mutates global `Application` config and, uniquely
  among this module's tests, the AC2 test stops/restarts the ENTIRE
  `:letflow` OTP application. Leans on the same ExUnit scheduling
  guarantee `test/support/admission_test_helpers.ex`'s moduledoc already
  documents and relies on for a lighter-weight single-singleton restart:
  all `async: true` modules finish before any `async: false` module
  starts, and `async: false` modules run strictly one at a time relative
  to each other -- so no other test's Sandbox checkout against
  `Letflow.Repo` can be in flight while this module's AC2 test tears it
  down and restarts it.

  Test order in this file is deliberate (not enforced by ExUnit, but
  written in this order per the design doc's own suggestion): AC7, then
  AC4, then AC2 last, since AC2 is the one test in this design that
  stops/restarts the whole application -- running it last avoids
  perturbing the others with an extra full-app restart.

  ## Design doc §9 Q4 -- empirically resolved

  The design's own open question (whether `:logger.add_primary_filter/2`
  raises, vs. silently ignores, a duplicate filter id) was left unverified
  because that design environment had no reachable Elixir/OTP runtime.
  This environment does: running the AC2 test below WITHOUT its
  `:logger.remove_primary_filter/1` defensive step (a temporary local
  edit, reverted before this commit) completed with **no raise and no
  logged error** on this project's pinned toolchain (Elixir 1.20.3 / OTP
  29) -- `:logger.add_primary_filter/2` is a silent no-op (or an ignored
  error return) on a duplicate id here, not a raise, contrary to the
  original inline comment's own stated assumption in
  `lib/letflow/application.ex`. The defensive removal step is kept anyway,
  per the design's own reasoning: it is a no-op-safe call either way, and
  keeping it is more faithful to that comment's "exactly once per node"
  assumption than silently relying on this one runtime's observed
  behavior, which is not itself an OTP-documented contract.
  """

  use ExUnit.Case, async: false

  test "AC7: Letflow.Supervisor.Pollers has zero children under config/test.exs's current gates" do
    refute Application.get_env(:letflow, :start_scheduler, true)
    refute Application.get_env(:letflow, :start_service_task_dispatcher, true)

    assert Process.whereis(Letflow.Supervisor.Pollers) != nil
    assert Supervisor.which_children(Letflow.Supervisor.Pollers) == []
  end

  test "AC4: init/1 includes exactly the two gated poller children, in order, when both gates are true (pure -- no process started)" do
    # Coverage gap this test closes: the crash-loop test below flips
    # :start_scheduler to true and restarts the LIVE Letflow.Supervisor.Pollers
    # singleton, but that restart is immediately followed by an induced crash
    # -- nothing in this file previously asserted the actual which_children/1
    # id list Letflow.Supervisor.Pollers.init/1 produces when BOTH gates are
    # true (the "owns exactly Letflow.Scheduler.Poller and
    # Letflow.Engine.ServiceTaskDispatcher.Poller" half of AC4's own text, as
    # opposed to the "zero children when both false" half AC7 above already
    # covers). Calling init/1 directly is a plain, side-effect-free function
    # call (Supervisor.init/2's own documented contract: it returns
    # {:ok, {flags, child_specs}}, it starts nothing) -- this does not touch
    # the live supervision tree or spawn either Poller GenServer, so it
    # carries none of the zero-delay-first-tick/DBConnection.OwnershipError
    # hazard the crash-loop test below exists to reproduce deliberately.
    original_scheduler = Application.get_env(:letflow, :start_scheduler, true)
    original_dispatcher = Application.get_env(:letflow, :start_service_task_dispatcher, true)

    on_exit(fn ->
      Application.put_env(:letflow, :start_scheduler, original_scheduler)
      Application.put_env(:letflow, :start_service_task_dispatcher, original_dispatcher)
    end)

    Application.put_env(:letflow, :start_scheduler, true)
    Application.put_env(:letflow, :start_service_task_dispatcher, true)

    {:ok, {_flags, children}} = Letflow.Supervisor.Pollers.init(nil)

    ids = Enum.map(children, & &1.id)
    assert ids == [Letflow.Scheduler.Poller, Letflow.Engine.ServiceTaskDispatcher.Poller]
  end

  describe "AC4: crash-loop isolation" do
    test "a Poller crash-looping past Pollers' own restart intensity restarts only Letflow.Supervisor.Pollers" do
      repo_pid_before = Process.whereis(Letflow.Repo)
      pollers_pid_before = Process.whereis(Letflow.Supervisor.Pollers)
      infrastructure_pid_before = Process.whereis(Letflow.Supervisor.Infrastructure)

      assert repo_pid_before != nil
      assert pollers_pid_before != nil

      original_start_scheduler = Application.get_env(:letflow, :start_scheduler, true)

      on_exit(fn ->
        Application.delete_env(:letflow, :force_poller_crash)
        Application.put_env(:letflow, :start_scheduler, original_start_scheduler)
        restart_pollers!()
      end)

      Application.put_env(:letflow, :start_scheduler, true)
      Application.put_env(:letflow, :force_poller_crash, true)

      # This terminate_child/restart_child pair is a MANUAL restart, only
      # to make Letflow.Supervisor.Pollers' own init/1 re-read the two env
      # overrides above (it does not, by itself, exercise the crash-loop
      # property under test -- terminate_child/2 always produces a `:DOWN`
      # for pollers_pid_before regardless of whether a crash-loop would
      # ever happen, so asserting on THAT `:DOWN` would prove nothing).
      # The pid captured AFTER this restart (below) is the one whose
      # SUBSEQUENT, AUTOMATIC exit -- once the crash-looping
      # Letflow.Scheduler.Poller exhausts Letflow.Supervisor.Pollers' own
      # max_restarts: 5, max_seconds: 60 budget -- is the actual AC4
      # property this test asserts.
      :ok = Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)
      {:ok, pollers_pid_after_manual_restart} =
        Supervisor.restart_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)

      refute pollers_pid_after_manual_restart == pollers_pid_before

      ref = Process.monitor(pollers_pid_after_manual_restart)

      assert_receive {:DOWN, ^ref, :process, ^pollers_pid_after_manual_restart, _reason}, 5_000

      # GENUINE TIMING HAZARD, found empirically while mutation-testing this
      # test (not anticipated by the design doc): the top-level
      # Letflow.Supervisor restarts the just-exited Letflow.Supervisor.Pollers
      # automatically, and if :force_poller_crash / :start_scheduler were
      # left as-is, that freshly restarted Pollers immediately crash-loops
      # AGAIN (same env still in effect) -- fast enough, in practice, to also
      # exhaust the TOP-LEVEL supervisor's own default restart intensity (3
      # restarts/5 seconds) and take the WHOLE :letflow application down,
      # which is not what AC4 asserts and would otherwise make this test
      # flaky/self-destructive. Clearing both here, immediately after
      # observing the first :DOWN and before checking anything else, races
      # against (and in practice reliably wins against) the top-level
      # supervisor's own restart of Pollers, which must still go through
      # Pollers.init/1 -> the Poller GenServer's own start_link/init (which
      # only THEN schedules its zero-delay first tick) -- several BEAM
      # message-passing hops this synchronously-resumed test process does
      # not have to wait through.
      Application.delete_env(:letflow, :force_poller_crash)
      Application.put_env(:letflow, :start_scheduler, false)

      # Letflow.Repo and Letflow.Supervisor.Infrastructure are untouched --
      # the AC4-mandated proof that the crash-loop is isolated to
      # Letflow.Supervisor.Pollers alone.
      assert Process.whereis(Letflow.Repo) == repo_pid_before
      assert Process.whereis(Letflow.Supervisor.Infrastructure) == infrastructure_pid_before

      # The top-level Letflow.Supervisor did restart the exited layer, not
      # merely leave it down -- a THIRD, distinct pid. The top-level
      # supervisor's own restart, triggered by the EXIT signal it receives
      # once Letflow.Supervisor.Pollers exits, happens asynchronously
      # relative to this test process, so a short poll (design doc §5 step
      # 4's own guidance) rather than a single immediate check.
      new_pollers_pid = wait_for_new_pollers_pid(pollers_pid_after_manual_restart)
      assert new_pollers_pid != nil
      assert new_pollers_pid != pollers_pid_after_manual_restart
    end
  end

  describe "AC2: cold-boot ordering (Infrastructure fully started before Pollers starts)" do
    test "Obs.Alerts.TaskSupervisor is already registered at the moment Pollers.init/1 runs, on a genuine cold boot" do
      test_pid = self()

      Application.put_env(:letflow, :pollers_init_probe, fn whereis_result ->
        send(test_pid, {:pollers_init_whereis, whereis_result})
      end)

      on_exit(fn -> Application.delete_env(:letflow, :pollers_init_probe) end)

      :ok = Application.stop(:letflow)

      assert Process.whereis(Letflow.Obs.Alerts.TaskSupervisor) == nil

      # Letflow.Application.start/2's first line re-registers this same
      # filter id via :logger.add_primary_filter/2 on the very next line
      # below (Application.ensure_all_started/1). Removed defensively here
      # so that call is a genuine first-time registration again, rather
      # than depending on whatever :logger.add_primary_filter/2 does with a
      # duplicate id -- EMPIRICALLY CONFIRMED (this test module's own
      # moduledoc records the finding) that omitting this line does NOT
      # raise on this OTP release either, but the design's own §4.3 step 3
      # rationale for keeping it regardless (a no-op removal-then-readd is
      # never a hazard, and it stays faithful to the original comment's
      # "exactly once per node" assumption) still holds, so it is kept.
      :logger.remove_primary_filter(:letflow_secrets_redaction)

      {:ok, _apps} = Application.ensure_all_started(:letflow)

      assert_receive {:pollers_init_whereis, whereis_result}, 5_000
      assert whereis_result != nil
    end
  end

  # Polls (up to ~2 seconds wall clock, well under any real hang scenario)
  # for Process.whereis(Letflow.Supervisor.Pollers) to become a pid other
  # than `stale_pid` -- the top-level Letflow.Supervisor's own restart of
  # its exited child is asynchronous relative to this test process.
  defp wait_for_new_pollers_pid(stale_pid, attempts_left \\ 40) do
    case Process.whereis(Letflow.Supervisor.Pollers) do
      pid when not is_nil(pid) and pid != stale_pid ->
        pid

      _ when attempts_left > 0 ->
        Process.sleep(50)
        wait_for_new_pollers_pid(stale_pid, attempts_left - 1)

      other ->
        other
    end
  end

  defp restart_pollers! do
    :ok = Supervisor.terminate_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)
    {:ok, _pid} = Supervisor.restart_child(Letflow.Supervisor, Letflow.Supervisor.Pollers)
    :ok
  end
end
