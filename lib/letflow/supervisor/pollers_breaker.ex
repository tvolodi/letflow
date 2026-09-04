defmodule Letflow.Supervisor.PollersBreaker do
  @moduledoc """
  ISS-0451 (design `iss0451-poller-crash-budget-isolation.md` §3): a
  circuit breaker that bounds a PERSISTENT `Letflow.Supervisor.Pollers`
  fault so it cannot exhaust the top-level `Letflow.Supervisor`'s own
  restart budget.

  ## Why this exists, and why it is a separate process

  REQ-219 (`req219-supervision-layering.md`) already isolates a SINGLE
  `Letflow.Supervisor.Pollers` budget-exhaustion event: when one of the two
  gated pollers crash-loops past Pollers' own `max_restarts: 5,
  max_seconds: 60` budget, only the `Pollers` layer exits and is restarted,
  leaving `Letflow.Repo`/`Letflow.Supervisor.Infrastructure`/
  `Letflow.Supervisor.Http` untouched (REQ-219 AC4). But a PERSISTENT fault
  (nothing ever clears it) re-exhausts that same budget again almost
  immediately after every restart -- ISSUE-FIXER's live probe measured a
  full 5-restart Pollers-level exhaustion cycle at ~24-30ms, so a handful of
  such cycles exhausts the TOP level's own default 3-restarts/5-seconds
  budget in well under one second, taking down the whole application.

  A `Supervisor` process cannot react to "I am about to exceed my own
  `max_restarts`" from inside its own callback contract -- by the time its
  intensity check fires, the process is already exiting, with no callback
  invocation to hook. So this breaker lives as a SEPARATE, PARENT-LEVEL
  `GenServer`, a sibling of `Letflow.Supervisor.Pollers` under the top-level
  `Letflow.Supervisor`, which observes Pollers' exits from the outside via
  `Process.monitor/1` and decides whether/when to bring Pollers back.

  ## `Letflow.Supervisor.Pollers`' child spec is `restart: :temporary`

  `Letflow.Application.start/2` gives Pollers' own child spec
  `restart: :temporary`, so the top-level `Letflow.Supervisor` structurally
  NEVER restarts `Letflow.Supervisor.Pollers` automatically, for any exit,
  ever. This breaker becomes the SOLE mechanism that restarts Pollers, from
  the very first exit onward -- via `Supervisor.start_child/2` with the
  full `restart: :temporary`-carrying child spec, never
  `Supervisor.restart_child/2` (which only works on a child whose SPEC
  still exists; OTP deletes a `:temporary` child's spec the instant it
  exits, so `restart_child/2` against it returns `{:error, :not_found}`).

  Because Pollers is never auto-restarted by the top level, Pollers-related
  activity consumes exactly ZERO of the top-level `Letflow.Supervisor`'s own
  restart-intensity budget, unconditionally, for any fault pattern,
  persistent or otherwise -- see `Letflow.Application`'s own moduledoc-style
  comment at its `opts` for the resulting `max_restarts: 5, max_seconds: 5`
  sizing.

  ## State machine

  Three states, held as this `GenServer`'s own process state:

    * `:closed` -- normal operation. On the FIRST `:DOWN` observed for
      Pollers, immediately calls `Supervisor.start_child/2` to bring it
      back (this is REQ-219 AC4's own already-tested single-shot case, now
      served by this breaker's explicit call instead of the top level's
      former implicit one) and starts a short observation timer
      (`@observation_window_ms`). If a SECOND `:DOWN` for the
      newly-restarted pid arrives before that timer fires, the fault is
      PERSISTENT -- trip to `:open`.
    * `:open` -- tripped. Pollers stays down, unrestarted (no
      `start_child/2` call), for one backoff interval
      (`@backoff_schedule_ms`, indexed by `consecutive_trips`). A
      `:half_open_probe` message is scheduled for when that interval
      elapses.
    * `:half_open` -- probing. Restarts Pollers exactly once via
      `Supervisor.start_child/2` and watches: if the observation window
      elapses with no further `:DOWN`, the fault cleared -- return to
      `:closed`, reset `consecutive_trips` to 0. If another `:DOWN` arrives
      first, trip back to `:open` with the NEXT backoff interval
      (`consecutive_trips` incremented, schedule never resets on a repeat
      trip).

  ## Backoff schedule

  Exponential with a cap: 1s, 5s, 30s, 2m, then 5m (does not grow further).
  The 1st interval (1s) is comfortably longer than the ~24-30ms measured
  full Pollers-exhaustion cycle, so even the first `:half_open` probe never
  lands inside the same rolling top-level-intensity window as the trip that
  opened the breaker. The schedule grows fast enough that a genuinely
  permanent fault settles into a bounded worst case of one probe attempt
  every 5 minutes, forever -- not an unbounded retry storm -- while still
  being picked back up within a human-reasonable window if the fault
  eventually clears.

  ## Scope: whole `Letflow.Supervisor.Pollers` supervisor, not per-poller

  Matches the granularity at which Pollers' own shared `5/60` budget
  already lives (see `Letflow.Supervisor.Pollers`' own moduledoc,
  "DELIBERATE, ACCEPTED CONSEQUENCE"). If only one of the two gated pollers
  develops a persistent fault, the breaker trips for BOTH -- the healthy
  poller also stops once the breaker opens, extending REQ-219's own
  already-accepted "both pollers restart together" consequence to "stop
  together."
  """

  use GenServer

  require Logger

  @backoff_schedule_ms [
    :timer.seconds(1),
    :timer.seconds(5),
    :timer.seconds(30),
    :timer.minutes(2),
    :timer.minutes(5)
  ]

  # Comfortably longer than the ~24-30ms empirically-measured full
  # Pollers-exhaustion cycle (so a genuinely persistent fault is reliably
  # caught on its 2nd cycle), comfortably shorter than Pollers' own 60s
  # window (design doc §3.6).
  @observation_window_ms :timer.seconds(2)

  @type breaker_state :: :closed | :open | :half_open

  @type t :: %{
          state: breaker_state(),
          consecutive_trips: non_neg_integer(),
          pollers_monitor_ref: reference() | nil,
          backoff_timer_ref: reference() | nil,
          observation_timer_ref: reference() | nil
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Read-only query of the breaker's current state. Not a double-gated test
  hook (design doc §6.3) -- an ordinary public function, since it only ever
  reads already-existing state and cannot alter production behavior.
  """
  @spec breaker_state() :: breaker_state()
  def breaker_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @impl true
  def init(_init_arg) do
    ref =
      Letflow.Supervisor.Pollers
      |> Process.whereis()
      |> Process.monitor()

    {:ok,
     %{
       state: :closed,
       consecutive_trips: 0,
       pollers_monitor_ref: ref,
       backoff_timer_ref: nil,
       observation_timer_ref: nil
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pollers_monitor_ref: ref} = state) do
    handle_pollers_down(state)
  end

  # A :DOWN for a stale monitor ref (already superseded by a later
  # restart's own monitor) -- ignore.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:half_open_probe, %{state: :open} = state) do
    ref = restart_pollers()

    {:noreply,
     %{
       state
       | state: :half_open,
         pollers_monitor_ref: ref,
         backoff_timer_ref: nil,
         observation_timer_ref: start_observation_timer()
     }}
  end

  def handle_info(:half_open_probe, state) do
    # A stale timer message (e.g. the breaker already recovered to :closed
    # via a different path) -- defensive no-op.
    {:noreply, state}
  end

  def handle_info(:observation_window_elapsed, %{state: :half_open} = state) do
    # The probe restart survived the whole observation window without a
    # further :DOWN -- genuine recovery. Reset the schedule only here, on
    # a GENUINE recovery, never merely on the passage of time.
    {:noreply, %{state | state: :closed, consecutive_trips: 0, observation_timer_ref: nil}}
  end

  def handle_info(:observation_window_elapsed, state) do
    # Reached :closed (or already re-tripped) before the timer fired --
    # stale message, no-op.
    {:noreply, %{state | observation_timer_ref: nil}}
  end

  # First observed exit (state is :closed, no observation window running
  # yet), or an exit that arrived after a prior observation window already
  # cleared: immediately restart Pollers and start watching for a 2nd
  # :DOWN.
  defp handle_pollers_down(%{state: :closed, observation_timer_ref: nil} = state) do
    ref = restart_pollers()

    {:noreply,
     %{state | pollers_monitor_ref: ref, observation_timer_ref: start_observation_timer()}}
  end

  # A 2nd :DOWN arrived while still watching the 1st restart -- the fault
  # is persistent. Trip to :open; do NOT restart again.
  defp handle_pollers_down(%{state: :closed} = state) do
    trip_to_open(state)
  end

  # The :half_open probe restart itself crashed and re-exhausted -- trip
  # back to :open with the NEXT backoff interval.
  defp handle_pollers_down(%{state: :half_open} = state) do
    trip_to_open(state)
  end

  # Should not observe a :DOWN while :open (no restart was issued while
  # open, so no live Pollers process exists to exit) -- defensive no-op.
  defp handle_pollers_down(%{state: :open} = state) do
    Logger.warning(
      "Letflow.Supervisor.PollersBreaker received an unexpected :DOWN while :open " <>
        "(no restart was issued) -- ignoring"
    )

    {:noreply, state}
  end

  defp trip_to_open(state) do
    consecutive_trips = state.consecutive_trips + 1
    backoff_ms = backoff_for(consecutive_trips)

    Logger.warning(
      "Letflow.Supervisor.PollersBreaker: Letflow.Supervisor.Pollers tripped the circuit " <>
        "breaker (consecutive_trips=#{consecutive_trips}) -- holding it stopped for " <>
        "#{backoff_ms}ms before the next :half_open probe"
    )

    backoff_timer_ref = Process.send_after(self(), :half_open_probe, backoff_ms)

    {:noreply,
     %{
       state
       | state: :open,
         consecutive_trips: consecutive_trips,
         pollers_monitor_ref: nil,
         backoff_timer_ref: backoff_timer_ref,
         observation_timer_ref: nil
     }}
  end

  defp backoff_for(consecutive_trips) do
    index = min(consecutive_trips, length(@backoff_schedule_ms)) - 1
    Enum.at(@backoff_schedule_ms, index)
  end

  defp start_observation_timer do
    Process.send_after(self(), :observation_window_elapsed, @observation_window_ms)
  end

  # Restarts Letflow.Supervisor.Pollers via Supervisor.start_child/2 with
  # the full restart: :temporary-carrying child spec -- NOT
  # Supervisor.restart_child/2, which only works on a child whose spec
  # still exists; OTP deletes a :temporary child's spec the instant it
  # exits, so restart_child/2 against it returns {:error, :not_found}
  # (design doc §3.4a "SECOND CORRECTION").
  defp restart_pollers do
    case Supervisor.start_child(
           Letflow.Supervisor,
           Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary)
         ) do
      {:ok, pid} -> Process.monitor(pid)
      {:ok, pid, _info} -> Process.monitor(pid)
      # Already running (e.g. a defensive/racing call) -- monitor the
      # existing pid rather than crashing.
      {:error, {:already_started, pid}} -> Process.monitor(pid)
    end
  end
end
