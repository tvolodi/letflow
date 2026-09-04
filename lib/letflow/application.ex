defmodule Letflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # REQ-190 (design req190-secrets-core.md §6.2): redacts every log
    # event's metadata map via Letflow.Secrets.Redaction.redact_map/1
    # before it reaches any handler. Registered first, ahead of every
    # other child, so nothing below this line can log an unredacted
    # secret-shaped value before the filter is active. Idempotent-safe:
    # :logger.add_primary_filter/2 raises on a duplicate filter id, which
    # would only happen on a second Letflow.Application.start/2 call in
    # the same node -- not expected in normal operation (a release/test run
    # starts the application exactly once per node).
    :logger.add_primary_filter(
      :letflow_secrets_redaction,
      {&Letflow.Secrets.LogFilter.filter/2, %{}}
    )

    # REQ-219 (design req219-supervision-layering.md §2): the flat 20-child
    # list this module used to build directly is now layered into three
    # sibling supervisors -- Letflow.Supervisor.Infrastructure,
    # Letflow.Supervisor.Pollers, Letflow.Supervisor.Http -- each owning a
    # disjoint slice of the original 20 children (see each module's own
    # moduledoc for its exact children list and ordering guarantees).
    # Infrastructure MUST be listed before Pollers: Supervisor starts
    # children strictly in list order, one child's start_link/1 completing
    # before the next begins, so listing Infrastructure first is what makes
    # ISS-0429's "Obs.Alerts.TaskSupervisor registered before either
    # Poller's first tick" guarantee structural (a supervisor-boundary
    # guarantee, not merely a list-position fact) -- see
    # Letflow.Supervisor.Infrastructure's own moduledoc. :one_for_one here
    # (not :rest_for_one) is deliberate: every named-process infra child is
    # looked up BY NAME at its call sites, never by stored pid, so a rare
    # Infrastructure exit has no pid-based dependency reason to also
    # force-restart Pollers or Http; a Pollers crash-loop exhausting its own
    # restart intensity (Letflow.Supervisor.Pollers' own moduledoc) now
    # kills and restarts ONLY that one layer.
    children = [
      Letflow.Supervisor.Infrastructure,
      Letflow.Supervisor.Pollers,
      Letflow.Supervisor.Http
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Letflow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
