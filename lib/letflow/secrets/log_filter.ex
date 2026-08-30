defmodule Letflow.Secrets.LogFilter do
  @moduledoc """
  `:logger` primary filter (Erlang `:logger` filter behaviour, `filter/2`)
  that redacts every log event's metadata map via
  `Letflow.Secrets.Redaction.redact_map/1` before it reaches any handler.
  Registered in `Letflow.Application.start/2` via
  `:logger.add_primary_filter/2` (design §6.2 — one of the two valid
  `:logger`-API-level integration points; this design picks the primary
  filter over an `Elixir.Logger.Formatter` hook because it runs once, before
  any handler/backend, so every configured handler benefits without each
  needing its own formatter change).

  A "value under a sensitive key never reaches a log line" is proven by
  `test/letflow/secrets/log_filter_test.exs` (or equivalent, per TEST-DESIGNER)
  capturing real log output, not by this module's own existence.
  """

  alias Letflow.Secrets.Redaction

  @doc """
  The `:logger` filter callback: `filter(log_event, filter_config) ::
  log_event | :stop | :ignore`. Redacts `log_event.meta` via
  `Redaction.redact_map/1` and always returns the (possibly modified) event
  — this filter never drops or ignores an event, it only redacts metadata.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{meta: meta} = log_event, _filter_config) when is_map(meta) do
    %{log_event | meta: Redaction.redact_map(meta)}
  end

  def filter(log_event, _filter_config), do: log_event
end
