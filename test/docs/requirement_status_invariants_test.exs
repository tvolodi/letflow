defmodule Letflow.Docs.RequirementStatusInvariantsTest do
  @moduledoc """
  ISS-0119 regression test — the requirement run history stays readable,
  append-only, and schema-conformant.

  Specified by `lib/letflow/design/iss-0119-status-file-readability.md` §7
  (assertions A0–A8) and §7.1 (the fail-first demonstration). No database, no
  new dependencies; all helpers live in `Letflow.Test.StatusHistory`
  (`test/support/status_history.ex`) and take explicit paths.

  ## One `test` block per assertion — deliberate, not stylistic

  ExUnit aborts a block at its *first* failed assertion. A0 is **expected to
  fail** when this file is run against a pre-fix tree (there is no index there),
  and A3 is the fail-first proof. If A0 and A3 shared a block with A0 first, A3
  would never execute and the pre-fix run would short-circuit on the missing
  index — resurrecting the precise failure design §7.1 opens by rejecting.
  A0..A8 (and A3b) therefore each get their own block, and A3 is never preceded
  by A0 within a block. (REVIEWER ruling C3 at Step 3d; raised as MINOR M1 by
  CODE-DESIGN-VALIDATOR.)

  The fail-first evidence itself is recorded in `test/specs/ISS-0119.md`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Test.StatusHistory, as: SH

  @index_path "docs/status/requirement_status.index.yaml"
  @status_dir "docs/status"
  @volume_glob "docs/status/requirement_status*.yaml"

  @legal_reqs [~r/^REQ-\d{3}$/, "SCOPE-CHANGE"]
  @legal_events ~w(started done blocked cancelled revised verified)

  # ── A0 ──────────────────────────────────────────────────────────────────────

  test "A0: the index exists and current-volume resolution is not degraded" do
    resolution = SH.current_volume(@index_path, @status_dir)

    assert match?({:index, path} when is_binary(path), resolution), """
    A0 — current-volume resolution is DEGRADED.

    #{@index_path} is missing, unreadable, or names no `status: current` volume,
    so StatusHistory.current_volume/2 fell back to the pre-index layout:

        #{inspect(resolution)}

    A0 exists so that fallback can never be *silently* active on a tree that is
    supposed to have ISS-0119's fix. On a PRE-FIX tree this failure is expected
    and correct — see design §7.1 and test/specs/ISS-0119.md.
    """
  end

  # ── A1 ──────────────────────────────────────────────────────────────────────

  test "A1: every indexed volume exists on disk, and every volume on disk is indexed" do
    index = SH.parse_index(@index_path)
    indexed = index.volumes |> Enum.map(& &1.path) |> Enum.sort()

    missing = Enum.reject(indexed, &File.exists?/1)

    # The glob also matches the index itself, which is not a volume; exclude it
    # by its own path rather than by a naming heuristic.
    on_disk =
      @volume_glob
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @index_path))
      |> Enum.sort()

    orphans = on_disk -- indexed

    assert {missing, orphans} == {[], []}, """
    A1 — index/disk disagreement.

      indexed but absent from disk: #{inspect(missing)}
      on disk but absent from index: #{inspect(orphans)}

      indexed: #{inspect(indexed)}
      on disk: #{inspect(on_disk)}
    """
  end

  # ── A2 ──────────────────────────────────────────────────────────────────────

  test "A2: exactly one volume is current and all others are closed" do
    index = SH.parse_index(@index_path)
    statuses = Enum.map(index.volumes, &{&1.volume, &1.status})

    current = Enum.filter(statuses, &(elem(&1, 1) == "current"))
    other = Enum.reject(statuses, &(elem(&1, 1) in ["current", "closed"]))

    assert {length(current), other} == {1, []}, """
    A2 — volume statuses are not well formed.

      current volumes: #{inspect(current)} (must be exactly one)
      neither current nor closed: #{inspect(other)}

      all: #{inspect(statuses)}
    """
  end

  # ── A3 — THE ISS-0119 REGRESSION ASSERTION (design §7.1) ────────────────────

  test "A3: the current volume is within the roll-rule ceilings" do
    resolution = SH.current_volume(@index_path, @status_dir)

    {tag, current_path} = resolution

    {max_lines, max_bytes} =
      case tag do
        :index ->
          roll_rule = SH.parse_index(@index_path).roll_rule
          {roll_rule.max_lines, roll_rule.max_bytes}

        :no_index_fallback ->
          SH.default_ceilings()
      end

    result = SH.within_bounds?(current_path, max_lines, max_bytes)

    assert result == :ok, """
    A3 — THE CURRENT RUN-HISTORY VOLUME IS TOO LARGE TO READ IN FULL.

    This is ISS-0119 itself: the append-only safeguard requires reading the
    volume you are about to append to, and a volume over the ceilings cannot be
    read in one un-scoped call.

      resolution: #{inspect(resolution)}
      ceilings:   #{max_lines} lines / #{max_bytes} bytes (#{ceiling_source(tag)})
      measured:   #{inspect(result)}

    A `resolution` of `{:no_index_fallback, _}` means this ran against a tree
    with no index — i.e. a pre-fix tree — and the failure above is a SIZE
    failure on the pre-index status file, not a missing-file error. That pairing
    is the fail-first demonstration design §7.1 requires; see
    test/specs/ISS-0119.md.
    """
  end

  # ── A3b — detector calibration, explicitly NOT the fail-first proof ─────────

  test "A3b: within_bounds?/3 actually fires at the index ceilings against frozen volume 1" do
    roll_rule = SH.parse_index(@index_path).roll_rule
    volume_1 = "docs/status/requirement_status.yaml"

    result = SH.within_bounds?(volume_1, roll_rule.max_lines, roll_rule.max_bytes)

    assert {:error, %{over: [:lines, :bytes]}} = result

    # Calibration guard only (design §7.1): volume 1 is oversized before AND
    # after the fix, so this is green in both worlds and is never shown to fail.
    # What it buys is that the detector fires at the index's REAL ceilings
    # against a real ~361 KB artefact — it goes red if the helper's line or byte
    # measurement regresses, or if a future agent raises the ceilings toward the
    # tool limits (which design §12 #2 forbids). It is NOT the ISS-0119
    # regression proof; A3 is.
  end

  # ── A4 ──────────────────────────────────────────────────────────────────────

  test "A4: every entry in every volume conforms to the documented vocabulary and shape" do
    index = SH.parse_index(@index_path)

    declared =
      index.known_anomalies
      |> Enum.map(&Map.take(&1, [:path, :line, :field, :value]))
      |> MapSet.new()

    vocabulary_drift =
      index.volumes
      |> Enum.flat_map(&SH.anomalies(&1.path, @legal_reqs, @legal_events))
      |> Enum.reject(&MapSet.member?(declared, &1))

    shape_violations =
      for volume <- index.volumes,
          entry <- SH.entries(volume.path),
          reason = shape_problem(entry),
          do: %{path: volume.path, line: entry.line, req: entry.req, problem: reason}

    assert {vocabulary_drift, shape_violations} == {[], []}, """
    A4 — run-history entries do not conform.

      undeclared vocabulary violations (#{length(vocabulary_drift)}):
    #{indent(vocabulary_drift)}

      shape violations (#{length(shape_violations)}):
    #{indent(shape_violations)}

    Legal `req:` values: REQ-NNN | SCOPE-CHANGE.
    Legal `event:` values: #{Enum.join(@legal_events, " | ")}.
    Required field order: #{inspect(SH.entry_field_order())}, with a parseable
    ISO-8601 `at:`.

    Vocabulary violations already declared in the index's `known_anomalies:` are
    excluded above (A5 checks that declared set separately, in both directions).
    The index has NO declaration mechanism for shape violations — see the note in
    test/specs/ISS-0119.md.
    """
  end

  # ── A5 ──────────────────────────────────────────────────────────────────────

  test "A5: the on-disk vocabulary-anomaly set equals the index's declared set exactly" do
    index = SH.parse_index(@index_path)

    on_disk =
      index.volumes
      |> Enum.flat_map(&SH.anomalies(&1.path, @legal_reqs, @legal_events))
      |> MapSet.new()

    declared =
      index.known_anomalies
      |> Enum.map(&Map.take(&1, [:path, :line, :field, :value]))
      |> MapSet.new()

    assert on_disk == declared, """
    A5 — the declared anomaly set does not match disk.

      on disk but NOT declared (new drift):
    #{indent(MapSet.difference(on_disk, declared))}

      declared but NOT on disk (a past entry was silently normalised or deleted
      — the exact act the append-only rule forbids):
    #{indent(MapSet.difference(declared, on_disk))}
    """
  end

  # ── A6 ──────────────────────────────────────────────────────────────────────

  test "A6: every closed volume's frozen prefix still hashes to its recorded digest" do
    index = SH.parse_index(@index_path)
    closed = Enum.filter(index.volumes, &(&1.status == "closed"))

    assert closed != [], "A6 — the index declares no closed volume; expected at least volume 1."

    for volume <- closed do
      actual = SH.frozen_prefix_digest(volume.path, volume.frozen_prefix_lines)

      assert actual == volume.frozen_prefix_sha256, """
      A6 — CLOSED VOLUME #{volume.volume} HAS BEEN MODIFIED.

        path:     #{volume.path}
        prefix:   first #{volume.frozen_prefix_lines} lines
        recorded: #{volume.frozen_prefix_sha256}
        actual:   #{actual}

      A closed volume is frozen: no entry in it may be edited, reordered,
      renumbered or deleted, ever. If a line above the closure footer changed,
      revert it. The hashed byte stream is design §8's convention — every line
      terminated by a single \\n including the last; terminators are trimmed
      "\\n" first then "\\r", never the two-byte "\\r\\n" (§8 erratum, Step 3d),
      so the digest is identical on a CRLF and an LF checkout.
      """
    end
  end

  # ── A7 ──────────────────────────────────────────────────────────────────────

  test "A7: every closed volume's footer names the next volume in the index" do
    index = SH.parse_index(@index_path)
    ordered = Enum.sort_by(index.volumes, & &1.volume)

    breaks =
      ordered
      |> Enum.chunk_every(2, 1)
      |> Enum.flat_map(fn
        [%{status: "closed"} = closed, successor] ->
          footer = SH.closure_footer(closed.path)

          cond do
            is_nil(footer) ->
              [%{volume: closed.volume, problem: :no_closure_footer}]

            not String.contains?(footer, successor.path) ->
              [
                %{
                  volume: closed.volume,
                  problem: :footer_does_not_name_successor,
                  expected: successor.path
                }
              ]

            true ->
              []
          end

        [%{status: "closed"} = closed] ->
          [%{volume: closed.volume, problem: :closed_volume_has_no_successor}]

        _ ->
          []
      end)

    assert breaks == [], """
    A7 — the volume chain is broken.

    #{indent(breaks)}

    Every closed volume must carry a closure footer naming the path of the next
    volume, and that path must be the next volume in the index. A closed volume
    with no successor, or a footer pointing somewhere else, strands an agent that
    arrives at a closed volume instead of the index.
    """
  end

  # ── A8 ──────────────────────────────────────────────────────────────────────

  test "A8: the current volume's header documents the full vocabulary and the real ceilings" do
    index = SH.parse_index(@index_path)
    {:index, current_path} = SH.current_volume(@index_path, @status_dir)
    header = SH.header(current_path)

    %{max_lines: max_lines, max_bytes: max_bytes} = index.roll_rule

    missing_vocabulary =
      Enum.reject(@legal_events ++ ["REQ-NNN", "SCOPE-CHANGE"], &String.contains?(header, &1))

    # The two ceiling restatements design §7/A8 names, rebuilt from the index —
    # so the index stays the single source of truth and a header that drifts
    # from it fails here rather than misleading an appending agent.
    prose_ceilings = "under #{thousands(max_lines)} lines / #{thousands(max_bytes)} bytes"
    rule_ceilings = "lines > #{max_lines} OR bytes > #{max_bytes}"

    missing_ceilings =
      Enum.reject([prose_ceilings, rule_ceilings], &String.contains?(header, &1))

    actual = {missing_vocabulary, missing_ceilings, SH.default_ceilings()}
    expected = {[], [], {max_lines, max_bytes}}

    assert actual == expected, """
    A8 — the current volume's header is incomplete or has drifted from the index.

      volume: #{current_path}

      vocabulary tokens the header never names: #{inspect(missing_vocabulary)}
      ceiling restatements the header never names: #{inspect(missing_ceilings)}

      index roll_rule:              #{max_lines} lines / #{max_bytes} bytes
      StatusHistory.default_ceilings/0: #{inspect(SH.default_ceilings())}

    The header is the copy an appending agent actually reads. A volume opened by
    copy-paste error, a vocabulary extension that skips the header, or a ceiling
    changed in the index but not in the header, all land here.
    """
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp ceiling_source(:index), do: "from the index's roll_rule"
  defp ceiling_source(:no_index_fallback), do: "from StatusHistory.default_ceilings/0"

  defp shape_problem(entry) do
    cond do
      entry.fields != SH.entry_field_order() ->
        {:field_set_or_order, entry.fields}

      not parseable_iso8601?(entry.at) ->
        {:unparseable_at, entry.at}

      true ->
        nil
    end
  end

  defp parseable_iso8601?(value) when is_binary(value) do
    match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp parseable_iso8601?(_), do: false

  defp thousands(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp indent(items) do
    case Enum.to_list(items) do
      [] -> "    (none)"
      list -> Enum.map_join(list, "\n", &("    " <> inspect(&1)))
    end
  end
end
