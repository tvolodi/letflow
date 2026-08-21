defmodule Letflow.Test.StatusHistory do
  @moduledoc """
  Path-parameterised helpers for the requirement run-history invariant test
  (`test/docs/requirement_status_invariants_test.exs`).

  Specified by `lib/letflow/design/iss-0119-status-file-readability.md` §7.

  Every function here takes an **explicit path or explicit bounds**. Nothing in
  this module knows that `docs/status/requirement_status.index.yaml` exists —
  that is what makes §7.1's fail-first demonstration possible, and it is a hard
  requirement of the design ("no function hardcoding the index location").

  This module is test-only: it lives under `test/support/`, which `mix.exs:20`
  compiles only for `MIX_ENV=test`. It is unreachable from `lib/`, from any mix
  task, and from any agent procedure — barrier 1 of the four listed in design
  §7.1 ("THE TRAP THIS FALLBACK MUST NOT BECOME").

  The index is parsed line-wise with the standard library: the project has no
  YAML dependency, and design §7 specifies line-oriented parsing plus `:crypto`
  for the digest. The files are machine-regular by construction.
  """

  @default_max_lines 1200
  @default_max_bytes 120_000

  @entry_field_order [:req, :event, :agent, :at, :note]

  # Bounded, file-controlled key names only; anything else is dropped rather
  # than interned, so a malformed index cannot grow the atom table.
  @key_re ~r/^[a-z][a-z0-9_]{0,40}$/

  @doc """
  The ceilings used **only** when there is no index to read `roll_rule` from
  (design §7). Pinned to the index by assertion A8, so this is a machine-checked
  copy rather than a prose copy.
  """
  @spec default_ceilings() :: {pos_integer(), pos_integer()}
  def default_ceilings, do: {@default_max_lines, @default_max_bytes}

  @doc "The five entry fields, in the order design §4 requires."
  @spec entry_field_order() :: [atom()]
  def entry_field_order, do: @entry_field_order

  @doc """
  Resolve which volume is current.

  Returns `{:index, path}` when `index_path` exists — the volume whose `status:`
  is `current`. **If and only if `index_path` does not exist**, returns
  `{:no_index_fallback, Path.join(status_dir, "requirement_status.yaml")}`:
  before ISS-0119's fix that single file *was* the entire status history, so it
  is the correct answer to "which volume is current?" in the pre-index world.

  The two-element tag is deliberate — a caller cannot consume the degraded
  answer without seeing that it is degraded (design §7.1, barrier 4).
  """
  @spec current_volume(Path.t(), Path.t()) ::
          {:index, Path.t()} | {:no_index_fallback, Path.t()}
  def current_volume(index_path, status_dir) do
    if File.exists?(index_path) do
      current =
        index_path
        |> parse_index()
        |> Map.fetch!(:volumes)
        |> Enum.find(&(Map.get(&1, :status) == "current"))

      {:index, current && Map.get(current, :path)}
    else
      {:no_index_fallback, Path.join(status_dir, "requirement_status.yaml")}
    end
  end

  @doc """
  Parse the run-history index into `%{roll_rule:, volumes:, known_anomalies:}`.
  """
  @spec parse_index(Path.t()) :: %{
          roll_rule: map(),
          volumes: [map()],
          known_anomalies: [map()]
        }
  def parse_index(index_path) do
    sections =
      index_path
      |> read_lines()
      |> Enum.reject(&comment_or_blank?/1)
      |> split_sections()

    %{
      roll_rule: parse_mapping(Map.get(sections, "roll_rule", [])),
      volumes: parse_list(Map.get(sections, "volumes", [])),
      known_anomalies: parse_list(Map.get(sections, "known_anomalies", []))
    }
  end

  @doc """
  Measure the **working-tree** file: line count (as `wc -l` and
  `(Get-Content f).Count` report it) and byte count from `File.stat!/1`.
  """
  @spec measure(Path.t()) :: %{lines: non_neg_integer(), bytes: non_neg_integer()}
  def measure(volume_path) do
    %{lines: length(read_lines(volume_path)), bytes: File.stat!(volume_path).size}
  end

  @doc """
  `:ok` when the volume is inside both ceilings, otherwise
  `{:error, %{path:, lines:, bytes:, max_lines:, max_bytes:, over:}}`.

  `over:` is always in the fixed order `[:lines, :bytes]`.
  """
  @spec within_bounds?(Path.t(), pos_integer(), pos_integer()) :: :ok | {:error, map()}
  def within_bounds?(volume_path, max_lines, max_bytes) do
    %{lines: lines, bytes: bytes} = measure(volume_path)

    over =
      Enum.filter([:lines, :bytes], fn
        :lines -> lines > max_lines
        :bytes -> bytes > max_bytes
      end)

    if over == [] do
      :ok
    else
      {:error,
       %{
         path: volume_path,
         lines: lines,
         bytes: bytes,
         max_lines: max_lines,
         max_bytes: max_bytes,
         over: over
       }}
    end
  end

  @doc """
  Every history entry in a volume.

  Each entry carries `req/event/agent/at` (`nil` when the field is absent), the
  1-based `line` of its `- req:` line, `field_lines` mapping each field name to
  its own 1-based line, and `fields` — the field names **in the order they
  appear**, which is what assertion A4's shape limb checks.
  """
  @spec entries(Path.t()) :: [map()]
  def entries(volume_path) do
    volume_path
    |> read_lines()
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, no}, acc ->
      item_match = Regex.run(~r/^  - ([a-z][a-z0-9_]*): ?(.*)$/, line)
      field_match = Regex.run(~r/^    ([a-z][a-z0-9_]*): ?(.*)$/, line)

      cond do
        item_match ->
          [_, key, value] = item_match

          [
            %{fields: [key], values: %{key => value}, field_lines: %{key => no}, line: no}
            | acc
          ]

        field_match != nil and acc != [] ->
          [_, key, value] = field_match
          [current | rest] = acc

          [
            %{
              current
              | fields: current.fields ++ [key],
                values: Map.put(current.values, key, value),
                field_lines: Map.put(current.field_lines, key, no)
            }
            | rest
          ]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.filter(&(List.first(&1.fields) == "req"))
    |> Enum.map(fn raw ->
      %{
        req: scalar(raw.values["req"]),
        event: scalar(raw.values["event"]),
        agent: scalar(raw.values["agent"]),
        at: scalar(raw.values["at"]),
        line: raw.line,
        fields: raw.fields |> Enum.map(&safe_atom/1) |> Enum.reject(&is_nil/1),
        field_lines: raw.field_lines
      }
    end)
  end

  @doc """
  Vocabulary violations in a volume, keyed exactly as the index's
  `known_anomalies:` entries are: `%{path:, line:, field:, value:}`.

  `legal_reqs` and `legal_events` are lists of `String.t()` and/or `Regex.t()`;
  a value is legal when it matches any member. `path:` is echoed back exactly as
  passed in, and `line:` is the line of the *offending field*, not of the entry.
  """
  @spec anomalies(Path.t(), [String.t() | Regex.t()], [String.t() | Regex.t()]) :: [map()]
  def anomalies(volume_path, legal_reqs, legal_events) do
    volume_path
    |> entries()
    |> Enum.flat_map(fn entry ->
      [{"req", entry.req, legal_reqs}, {"event", entry.event, legal_events}]
      |> Enum.reject(fn {_field, value, legal} -> is_nil(value) or legal?(value, legal) end)
      |> Enum.map(fn {field, value, _legal} ->
        %{
          path: volume_path,
          line: Map.get(entry.field_lines, field, entry.line),
          field: field,
          value: value
        }
      end)
    end)
  end

  @doc """
  SHA-256 of a volume's frozen prefix, lowercase hex.

  The hashed byte stream is design §8's convention: the first `line_count`
  lines, every line terminated by a single `\\n` **including the last**, so the
  stream ends in `\\n`.

  Terminator handling trims `"\\n"` first and `"\\r"` second, never the literal
  two-byte `"\\r\\n"`. That order is load-bearing: `File.stream!/1` opens in text
  mode, so on a CRLF checkout it has *already* stripped the CR and a `"\\r\\n"`
  trim would match nothing — leaving the `\\n` in place and appending a second,
  one extra byte per line. Trimming the two separately is correct for a CRLF
  text-mode read and for an LF/binary read alike, i.e. portable to CI, where the
  checkout is LF. (§8 erratum, ruled at Step 3d — see the design's §8.)
  """
  @spec frozen_prefix_digest(Path.t(), pos_integer()) :: String.t()
  def frozen_prefix_digest(volume_path, line_count) do
    volume_path
    |> File.stream!()
    |> Enum.take(line_count)
    |> Enum.map_join(
      "",
      &((&1 |> String.trim_trailing("\n") |> String.trim_trailing("\r")) <> "\n")
    )
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  A closed volume's closure footer: everything from the last
  `VOLUME <n> — CLOSED` marker line to EOF. `nil` when the file has no footer.
  """
  @spec closure_footer(Path.t()) :: String.t() | nil
  def closure_footer(volume_path) do
    lines = read_lines(volume_path)

    marker =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} -> Regex.match?(~r/VOLUME \d+ .* CLOSED/u, line) end)
      |> List.last()

    case marker do
      nil -> nil
      {_line, index} -> lines |> Enum.drop(index) |> Enum.join("\n")
    end
  end

  @doc """
  A volume's header: everything before the `history:` key.
  """
  @spec header(Path.t()) :: String.t()
  def header(volume_path) do
    volume_path
    |> read_lines()
    |> Enum.take_while(&(not Regex.match?(~r/^history:\s*$/, &1)))
    |> Enum.join("\n")
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp read_lines(path) do
    lines = path |> File.read!() |> String.split(~r/\r?\n/)

    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp comment_or_blank?(line) do
    trimmed = String.trim_leading(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp split_sections(lines) do
    lines
    |> Enum.reduce({nil, %{}}, fn line, {section, acc} ->
      case Regex.run(~r/^([a-z][a-z0-9_]*):\s*$/, line) do
        [_, name] ->
          {name, Map.put_new(acc, name, [])}

        nil ->
          if section, do: {section, Map.update!(acc, section, &(&1 ++ [line]))}, else: {nil, acc}
      end
    end)
    |> elem(1)
  end

  defp parse_mapping(lines) do
    lines
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^  ([a-z][a-z0-9_]*): ?(.*)$/, line) do
        [_, key, value] -> put_field(acc, key, value)
        nil -> acc
      end
    end)
  end

  defp parse_list(lines) do
    lines
    |> Enum.reduce([], fn line, items ->
      item_match = Regex.run(~r/^  - ([a-z][a-z0-9_]*): ?(.*)$/, line)
      field_match = Regex.run(~r/^    ([a-z][a-z0-9_]*): ?(.*)$/, line)

      cond do
        item_match ->
          [_, key, value] = item_match
          [put_field(%{}, key, value) | items]

        field_match != nil and items != [] ->
          [_, key, value] = field_match
          [current | rest] = items
          [put_field(current, key, value) | rest]

        true ->
          items
      end
    end)
    |> Enum.reverse()
  end

  defp put_field(map, key, value) do
    case safe_atom(key) do
      nil -> map
      atom -> Map.put(map, atom, scalar(value))
    end
  end

  defp safe_atom(key) do
    if Regex.match?(@key_re, key), do: String.to_atom(key), else: nil
  end

  # Unquote, drop a trailing `# ...` comment on an unquoted value, and coerce a
  # pure-integer value to an integer. Block-scalar introducers (`>`, `|`) become
  # nil — no assertion reads a block scalar's body.
  defp scalar(nil), do: nil

  defp scalar(raw) do
    value = String.trim(raw)

    cond do
      value in [">", "|", ">-", "|-", ""] ->
        nil

      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
          byte_size(value) >= 2 ->
        String.slice(value, 1..-2//1)

      true ->
        stripped = value |> String.replace(~r/\s+#.*$/, "") |> String.trim()
        if Regex.match?(~r/^\d+$/, stripped), do: String.to_integer(stripped), else: stripped
    end
  end

  defp legal?(value, legal) do
    Enum.any?(legal, fn
      %Regex{} = re -> Regex.match?(re, value)
      literal when is_binary(literal) -> literal == value
    end)
  end
end
