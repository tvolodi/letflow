defmodule Letflow.Obs.Logger do
  @moduledoc """
  OTP `:logger_formatter` implementation for Letflow. Emits one newline-terminated
  JSON object per log entry with structured fields, trace-id propagation, and
  sensitive-value redaction.
  """

  @behaviour :logger_formatter

  # Keys OTP's logger always injects — strip before emitting additional fields.
  @beam_reserved_keys [:time, :mfa, :file, :line, :domain, :gl, :pid, :report_cb]

  # The five field names owned by this formatter — callers may not shadow them.
  @reserved_fields MapSet.new([
                     :timestamp,
                     :level,
                     :trace_id,
                     :component,
                     :message,
                     "timestamp",
                     "level",
                     "trace_id",
                     "component",
                     "message"
                   ])

  @exact_sensitive MapSet.new([
                     :authorization,
                     :password,
                     :password_hash,
                     :token,
                     :access_token,
                     :refresh_token,
                     :bootstrap_token,
                     :api_token,
                     :secret,
                     :client_secret,
                     :credential,
                     :credentials,
                     :cookie,
                     "authorization",
                     "password",
                     "password_hash",
                     "token",
                     "access_token",
                     "refresh_token",
                     "bootstrap_token",
                     "api_token",
                     "secret",
                     "client_secret",
                     "credential",
                     "credentials",
                     # string-only: hyphenated header name
                     "set-cookie",
                     "cookie"
                   ])

  @sensitive_suffixes ["_token", "_secret", "_password", "_credential"]

  # Work-bound (not a cycle guard — BEAM terms built through normal code cannot be
  # cyclic) for safe_value/2's recursive descent into metadata. See design doc
  # lib/letflow/design/iss0533-log-formatter-safe-value-recursion.md §1.2.
  @max_sanitize_depth 6

  @doc """
  OTP `:logger_formatter` callback — validates the formatter config at setup time.
  """
  @impl :logger_formatter
  @spec check_config(map()) :: :ok | {:error, term()}
  def check_config(_config), do: :ok

  @doc """
  OTP `:logger_formatter` callback. Returns a newline-terminated JSON line.
  """
  @impl :logger_formatter
  @spec format(
          %{level: atom(), msg: term(), meta: map()},
          map()
        ) :: iodata()
  def format(%{level: level, msg: msg, meta: meta}, _config) do
    # Re-entry guard: a violation warning that loops back through this formatter
    # would recurse infinitely. Short-circuit to plain text for those calls.
    if Map.get(meta, :formatter_violation) == true do
      ts = format_timestamp(Map.get(meta, :time, :erlang.system_time(:microsecond)))
      "#{ts} [formatter_violation] #{format_msg(msg)}\n"
    else
      encode_entry(level, msg, meta)
    end
  end

  defp encode_entry(level, msg, meta) do
    ts = format_timestamp(Map.get(meta, :time, :erlang.system_time(:microsecond)))
    level_str = level_to_string(level)

    trace_id =
      case meta[:trace_id] do
        nil -> ""
        v -> to_string(v)
      end

    component = extract_component(meta[:mfa])
    message_str = format_msg(msg)

    stripped = Map.drop(meta, @beam_reserved_keys)
    {clean, violations} = split_reserved(stripped)

    Enum.each(violations, fn key ->
      :logger.warning(~c"Log metadata contains reserved field name: ~p", [key], %{
        formatter_violation: true
      })
    end)

    additional =
      clean
      |> redact_sensitive()
      |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)

    base = %{
      "timestamp" => ts,
      "level" => level_str,
      "trace_id" => trace_id,
      "component" => component,
      "message" => message_str
    }

    try do
      Jason.encode!(Map.merge(additional, base)) <> "\n"
    rescue
      e ->
        # Defense-in-depth net for a metadata term safe_value/1 did not anticipate
        # (e.g. a non-finite float, invalid-UTF-8 binary — see design §2.1). The
        # event's REAL level/message/timestamp/trace_id/component (base, computed
        # above and never itself a source of this failure) are always preserved;
        # only the additional-metadata portion is replaced.
        fallback_additional = %{
          "metadata_encode_error" => "log metadata encoding failed: #{inspect(e)}",
          "metadata_raw" => inspect(additional)
        }

        Jason.encode!(Map.merge(fallback_additional, base)) <> "\n"
    end
  end

  defp format_timestamp(time_us) do
    seconds = div(time_us, 1_000_000)
    microseconds = rem(time_us, 1_000_000)
    dt = DateTime.from_unix!(seconds)
    date_str = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")
    us_str = String.pad_leading(Integer.to_string(microseconds), 6, "0")
    "#{date_str}.#{us_str}Z"
  end

  defp level_to_string(:warning), do: "warn"
  defp level_to_string(level), do: to_string(level)

  defp extract_component(nil), do: "letflow"

  defp extract_component({module, _fun, _arity}) do
    module
    |> inspect()
    |> String.replace_prefix("Elixir.", "")
  end

  defp format_msg({:string, iodata}), do: IO.iodata_to_binary(iodata)

  defp format_msg({format_str, args}) when is_list(format_str) do
    :io_lib.format(format_str, args) |> IO.iodata_to_binary()
  end

  defp format_msg(other), do: inspect(other)

  defp split_reserved(meta) do
    Enum.reduce(meta, {%{}, []}, fn {k, v}, {clean, violations} ->
      if MapSet.member?(@reserved_fields, k) do
        {clean, [k | violations]}
      else
        {Map.put(clean, k, v), violations}
      end
    end)
  end

  # Converts non-JSON-safe BEAM values to their inspect representation, recursively.
  # Postcondition: the returned term is always Jason-encodable, at any input nesting
  # depth up to @max_sanitize_depth, beyond which the remaining sub-term is inspected
  # wholesale rather than walked further.
  defp safe_value(v), do: safe_value(v, @max_sanitize_depth)

  defp safe_value(v, 0), do: safe_leaf(v)

  defp safe_value(v, _depth) when is_struct(v) do
    if jason_encodable?(v), do: v, else: inspect(v)
  end

  defp safe_value(v, depth) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, safe_value(val, depth - 1)} end)
  end

  defp safe_value(v, depth) when is_list(v) do
    Enum.map(v, &safe_value(&1, depth - 1))
  end

  defp safe_value(v, _depth) when is_tuple(v), do: inspect(v)

  defp safe_value(v, _depth), do: safe_leaf(v)

  # Non-container leaf: pid/reference/function/port get inspected; everything else
  # (numbers, atoms, binaries, booleans, nil, already-encodable structs) passes through.
  defp safe_leaf(v) when is_pid(v), do: inspect(v)
  defp safe_leaf(v) when is_reference(v), do: inspect(v)
  defp safe_leaf(v) when is_function(v), do: inspect(v)
  defp safe_leaf(v) when is_port(v), do: inspect(v)
  defp safe_leaf(v) when is_struct(v), do: if(jason_encodable?(v), do: v, else: inspect(v))
  defp safe_leaf(v) when is_tuple(v), do: inspect(v)
  defp safe_leaf(v), do: v

  defp jason_encodable?(v), do: Jason.Encoder.impl_for(v) not in [nil, Jason.Encoder.Any]

  @doc """
  Replaces values for sensitive keys with `"[REDACTED]"`. Only top-level keys
  are checked; nested maps are not traversed.
  """
  @spec redact_sensitive(map()) :: map()
  def redact_sensitive(meta) when is_map(meta) do
    Map.new(meta, fn {k, v} ->
      if sensitive_key?(k), do: {k, "[REDACTED]"}, else: {k, v}
    end)
  end

  defp sensitive_key?(k) when is_atom(k) do
    MapSet.member?(@exact_sensitive, k) or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(Atom.to_string(k), &1))
  end

  defp sensitive_key?(k) when is_binary(k) do
    MapSet.member?(@exact_sensitive, k) or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(k, &1))
  end

  defp sensitive_key?(_), do: false

  @doc """
  Runs `fun` under a freshly generated trace id. Restores (or clears) the prior
  trace id in an `after` block that executes regardless of exceptions or throws.
  """
  @spec with_trace((-> result)) :: result when result: var
  def with_trace(fun) do
    new_id = Letflow.Api.Context.generate_trace_id()
    prior = Logger.metadata()[:trace_id]
    Logger.metadata(trace_id: new_id)

    try do
      fun.()
    after
      if prior do
        Logger.metadata(trace_id: prior)
      else
        Logger.reset_metadata(Keyword.delete(Logger.metadata(), :trace_id))
      end
    end
  end
end
