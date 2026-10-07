defmodule Letflow.Test.LoggerCollector do
  @moduledoc """
  A `:logger` handler (test-only) that forwards log events, at every level and with
  their full event term, to an owner process (REQ-441 AC5, design M2a).

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

  `attach!/1` returns a handle; `collected/1` returns everything received so far as
  `[%{level: level, text: text}]`. The handler and the filter are restored by `detach/1`.

  ## Deterministic, attributable capture (ISS-1038 / Q-1039)

  `ExUnit.CaptureLog` is a GLOBAL capture: under concurrent tests it also receives events
  logged by unrelated processes. This handler is SYNCHRONOUS (`log/2` runs in the emitting
  process and `send/2`s before the log call returns), and `attach!/1` can restrict what it
  forwards to events attributable to the owner. Options:

    * `attribute_to: pid | nil` -- (default `nil`: collect everything) an event counts iff the
      emitting process is `pid`, or `pid` is in its `$callers` (Task, `Task.Supervisor`) or
      `$ancestors` (`:proc_lib`), or the emitting process is registered under one of
    * `also_from: [name]` -- (default `[]`) registered names whose own events also count (a
      supervisor's child-terminated report is emitted by the supervisor itself);
    * `sasl: boolean` -- (default `true`) force SASL-domain reports on (see above); `false`
      leaves the translator filter untouched;
    * `raw: boolean` -- (default `true`) `text` is the formatted message, a newline and the
      inspected event term; `false`: only the formatted message.

  A handler that crashes is removed by `:logger`, which would make an "X was not logged"
  assertion pass vacuously; `assert_alive!/1` fails loudly in that case.
  """

  @type handle :: {atom(), reference(), {function(), map()} | nil}

  @doc "Attaches the handler for the calling process; returns the handle."
  @spec attach!(keyword()) :: handle()
  def attach!(opts \\ []) do
    ref = make_ref()
    id = :"req441_collector_#{System.unique_integer([:positive])}"
    original = if Keyword.get(opts, :sasl, true), do: enable_sasl_reports(), else: nil

    config = %{
      owner: self(),
      ref: ref,
      attribute_to: Keyword.get(opts, :attribute_to),
      also_from: Keyword.get(opts, :also_from, []),
      raw: Keyword.get(opts, :raw, true)
    }

    :ok =
      :logger.add_handler(id, __MODULE__, %{
        level: :all,
        filter_default: :log,
        filters: [],
        config: config
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

  @doc """
  Raises unless the handler is still installed. `:logger` removes a handler that crashed, so
  without this check an absence assertion over `collected/1` could pass vacuously.
  """
  @spec assert_alive!(handle()) :: :ok
  def assert_alive!({id, _ref, _original}) do
    case :logger.get_handler_config(id) do
      {:ok, _config} -> :ok
      _ -> raise "LoggerCollector handler #{inspect(id)} was removed (it crashed?)"
    end
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

  # :logger handler callback; runs in the EMITTING process.
  @doc false
  def log(%{level: level} = event, %{config: %{owner: owner, ref: ref} = config}) do
    if attributed?(config) do
      formatted =
        try do
          event
          |> :logger_formatter.format(%{template: [:msg], single_line: false})
          |> IO.chardata_to_string()
        catch
          _kind, _reason -> ""
        end

      text =
        if config.raw do
          raw = inspect(event, limit: :infinity, printable_limit: :infinity)
          formatted <> "\n" <> raw
        else
          formatted
        end

      send(owner, {:req441_log, ref, %{level: level, text: text}})
    end

    :ok
  end

  defp attributed?(%{attribute_to: nil}), do: true

  defp attributed?(%{attribute_to: pid, also_from: names}) do
    self() == pid or pid in Process.get(:"$callers", []) or
      pid in Process.get(:"$ancestors", []) or
      Enum.any?(names, &(Process.whereis(&1) == self()))
  end
end
