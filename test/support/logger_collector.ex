defmodule Letflow.Test.LoggerCollector do
  @moduledoc """
  A `:logger` handler (test-only) that forwards EVERY log event, at every level and with
  its full event term, to an owner process (REQ-441 AC5, design M2a).

  `ExUnit.CaptureLog` sees only what the Elixir Logger translates; crash reports raised
  through `:proc_lib` / `:logger` directly (which print process arguments) can bypass
  that, so the no-leak suite attaches this handler as well and renders both the
  formatted message and the inspected event term.

  This VM's Elixir Logger drops SASL-domain events (which is what a `:proc_lib` crash
  report is) at the primary level (`handle_sasl_reports` is false), so no handler would
  ever see one. For the duration of the attachment the translator filter is therefore
  replaced by an identical one with `sasl: true`; `detach/1` restores the original filter
  exactly. This makes "no crash report leaks the password" a statement about what the
  adapter does, not about a filter that hides the report.

  `attach!/0` returns a handle; `collected/1` returns everything received so far as
  `[%{level: level, text: text}]`. The handler and the filter are restored by `detach/1`.
  """

  @type handle :: {atom(), reference(), {function(), map()} | nil}

  @doc "Attaches the handler for the calling process; returns the handle."
  @spec attach!() :: handle()
  def attach! do
    ref = make_ref()
    id = :"req441_collector_#{System.unique_integer([:positive])}"
    original = enable_sasl_reports()

    :ok =
      :logger.add_handler(id, __MODULE__, %{
        level: :all,
        filter_default: :log,
        filters: [],
        config: %{owner: self(), ref: ref}
      })

    {id, ref, original}
  end

  @doc "Removes the handler and restores the primary translator filter."
  @spec detach(handle()) :: :ok
  def detach({id, _ref, original}) do
    _ = :logger.remove_handler(id)
    restore_translator(original)
    :ok
  end

  @doc "Everything the handler has forwarded to the calling process so far."
  @spec collected(handle() | {nil, reference(), nil}) :: [%{level: atom(), text: String.t()}]
  def collected({_id, ref, _original}) do
    receive do
      {:req441_log, ^ref, entry} -> [entry | collected({nil, ref, nil})]
    after
      0 -> []
    end
  end

  defp enable_sasl_reports do
    case :logger.get_primary_config().filters |> List.keyfind(:logger_translator, 0) do
      {:logger_translator, {fun, %{sasl: false} = config}} = original ->
        :ok = :logger.remove_primary_filter(:logger_translator)
        :ok = :logger.add_primary_filter(:logger_translator, {fun, %{config | sasl: true}})
        original

      _already_enabled_or_absent ->
        nil
    end
  end

  defp restore_translator({:logger_translator, filter}) do
    _ = :logger.remove_primary_filter(:logger_translator)
    :ok = :logger.add_primary_filter(:logger_translator, filter)
  end

  defp restore_translator(nil), do: :ok

  # :logger handler callback
  @doc false
  def log(%{level: level} = event, %{config: %{owner: owner, ref: ref}}) do
    formatted =
      try do
        event
        |> :logger_formatter.format(%{template: [:msg], single_line: false})
        |> IO.chardata_to_string()
      catch
        _kind, _reason -> ""
      end

    raw = inspect(event, limit: :infinity, printable_limit: :infinity)
    send(owner, {:req441_log, ref, %{level: level, text: formatted <> "\n" <> raw}})
    :ok
  end
end
