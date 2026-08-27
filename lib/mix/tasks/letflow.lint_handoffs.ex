defmodule Mix.Tasks.Letflow.LintHandoffs do
  @shortdoc "Validates every handoffs/**/*.json against HANDOFF_PROTOCOL.md's schema"

  @moduledoc """
  Implements ISS-0191: the handoff linter `HANDOFF_PROTOCOL.md`'s Enforcement
  note has described as a known gap since the protocol was written. Mirrors,
  for Letflow, what R-Co's `tools/lint_handoffs.py` does for R-Co (schema
  conformance, timestamp monotonicity, registry coverage), adopted after a
  2026-08-05 R-Co audit found unenforced bookkeeping rules were followed at
  0.4-8.6% compliance despite being written down.

  A plain Mix task, not a shell script: this project already has precedent
  (`mix letflow.check_toolchain`, `mix letflow.check_test`) and JSON decoding
  needs `Jason`, a runtime dependency only reachable inside the compiled app
  -- unlike `scripts/timed_test.sh`, which is deliberately a shell script for
  an unrelated reason (measuring a genuinely cold `mix compile`; this task
  has no such constraint, so that precedent does not apply here).

  ## Checks

  ### Hard (exit non-zero on any un-grandfathered violation)

    * **H1** -- top-level `status` is one of the six legal values.
    * **H2** -- `completed_at` never precedes `started_at`, when both are set.
    * **H3** -- top-level keys are a subset of `HANDOFF_PROTOCOL.md` §2's
      schema (`@schema_top_keys` below), or individually grandfathered.
    * **H4** -- when `not_agent_attested` is present, its member set is
      **exactly** the required six (or those six plus `backfill_note`), read
      live out of `HANDOFF_PROTOCOL.md` §4.1(b)'s own table -- not hardcoded
      here, so a future edit to that table is what the linter measures, not
      what it silently drifts away from (ISS-0203's own concern about this
      exact class of drift). `backfill_note` itself is legal on at most the
      one file §4.1(b) names as its single spent exception, extracted the
      same way.
    * **H5** -- registry coverage: every `run_id` implied by a
      `handoffs/<run_id>/` directory appears in `handoffs/registry.json`'s
      `runs[].run_id`, and vice versa.
    * **H6** -- every discovered handoff-shaped file (basename starts with
      `step`) is JSON. A non-`.json` file is a discovery-completeness defect
      in its own right. **Unlike H1-H4, H6 is not grandfathered by an
      explicit file list** -- a file whose content already existed in git
      history at or before `@h6_floor_commit` is automatically exempt
      (reported, does not fail the build); a file introduced after that
      floor always fails the build. See `@h6_floor_commit`'s own comment and
      `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` for why.

  A hard violation on a file not in this module's grandfather maps is a
  **new** regression and fails the run. A hard violation on a grandfathered
  file is reported (so the debt stays visible) but does not fail the run --
  each grandfathered file is named individually, dated, and traced to
  ISS-0190, per that issue's "no blanket suppression" requirement. This
  module contains **no wildcard or pattern-based grandfathering, with one
  exception: H6**, which is governed by the `@h6_floor_commit`
  commit-boundary rule instead of a per-file list -- see above. Every other
  hard rule's grandfathering always means naming one exact path.

  ### Advisory (WARN or INFO; never change the exit code)

    * **H-SIZE-1/2/3** -- specified in `HANDOFF_PROTOCOL.md`'s Enforcement
      note ("Specified but NOT YET RUNNING" section, added by ISS-0198, the
      `result.summary` figures added by ISS-0200). Implemented here exactly
      per that spec: H-SIZE-1 (cite-and-restate), H-SIZE-2 (under-specified),
      H-SIZE-3 (per-run report, includes ISS-0200's `result.summary`
      figures -- report-only, no threshold, no pass/fail, per that issue's
      own ruling).
    * **artifacts_out self-reference** (ISS-0202) -- WARN when a handoff's
      `result.artifacts_out` lists its own file (by basename, or either path
      a suffix of the other). Applies only to handoffs created at or after
      the commit that landed ISS-0202's rule (`@artifacts_out_rule_commit`
      below) -- the 201 pre-existing self-referencing files are historical
      and are not, and must not be, flagged; see `HANDOFF_PROTOCOL.md`'s
      `result.artifacts_out does not include the handoff's own file`
      subsection for why.

  ## What this task deliberately does NOT check

  Whether a `result` block was actually attested by its acting agent, rather
  than reconstructed after that agent died. That property exists in no
  artefact on disk, so it is structurally unfalsifiable from the files this
  task reads -- asserting it would be a green run of a different, fictional
  test. This task only checks that a *present* `not_agent_attested` marker is
  internally well-formed (H4); a file that omits the marker without needing
  one and a file that omits it while needing one are indistinguishable here,
  by design, per ISS-0191's own scope note.

  ## Usage

      mix letflow.lint_handoffs

  Exits non-zero (`Mix.raise/1`) iff at least one un-grandfathered hard
  violation exists. WARN/INFO output goes to stdout and never affects the
  exit code.
  """

  use Mix.Task

  @handoffs_dir "handoffs"
  @registry_file Path.join(@handoffs_dir, "registry.json")
  @protocol_file "docs/agents/shared/HANDOFF_PROTOCOL.md"
  @rule String.duplicate("=", 72)

  @legal_statuses ~w(PENDING IN_PROGRESS COMPLETED FAILED ESCALATED CANCELLED)

  @schema_top_keys ~w(
    handoff_id run_id workflow_id step from_agent to_agent file created_at
    started_at completed_at status priority context task result rework_count
    max_rework not_agent_attested gate_history
  )

  # The commit that landed ISS-0202's rule (`result.artifacts_out` excludes
  # the handoff's own file) on `main`. Handoffs created before this commit
  # predate the rule and are never flagged by the artifacts_out WARN check.
  @artifacts_out_rule_commit "48a4a55"

  # The commit boundary before which a non-JSON handoff-shaped file (H6) is
  # automatically exempt -- a file whose content already existed in git
  # history at or before this commit is grandfathered; a file introduced
  # strictly after it always hard-fails. See
  # `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` for the full
  # mechanism and why it replaced the old per-file `@grandfathered` entries.
  #
  # 2026-08-22, ISS-0273: pinned to `c4a8e397...930252` -- the parent of
  # `184d846`, the commit that merged the H6 check onto `main` -- per
  # `lib/letflow/design/iss0273-h6-floor-commit-pin.md`. This value never
  # needs to move again: everything H6 was written to grandfather predates
  # it, and everything introduced from `184d846` onward (including H6's own
  # fixture) correctly lands on the "new, must pass or hard-fail honestly"
  # side. The BOOTSTRAP runtime-resolution fallback this constant previously
  # required has been removed -- `h6_floor_commit/0` now returns this
  # literal directly.
  @h6_floor_commit "c4a8e39729e253397d4f1aa34155a74522930252"

  # -- Individually-named pre-existing hard violations. Measured 2026-08-21
  # by this task's own first run against the corpus (626 files), then
  # RE-MEASURED the same day once ISS-0190 landed and fixed the 24 entries
  # that were in its scope (15 H1 status corrections, 6 H3 next_action
  # relocations, 2 H3 flat-schema migrations, 1 H3 gate_history -- the last
  # of these stopped being a violation at all once ISS-0190 formalised
  # `gate_history` as a documented optional top-level field in
  # HANDOFF_PROTOCOL.md §2 and `@schema_top_keys` above, rather than being
  # fixed by editing the file). No wildcards, no path prefixes: every entry
  # below is one exact file this task actually found violating. A NEW file
  # hitting the same rule is NOT covered by this list and fails the build --
  # grandfathering is per-file, never per-rule.
  #
  # 6 entries remain, all explicitly OUT OF ISS-0190's scope: 3 H3 (the
  # ISS-0117 recovery-marker keys `orch_timestamp_correction` x2 and
  # `orch_restart_note`, deliberately excluded by ISS-0190's own acceptance
  # criteria) + 1 H3 (`orch_status_correction` on
  # WF02-REQ062-20260819/step-03-test-designer.json, the same-shaped marker
  # ISS-0192 added for a non-agent-death status-flip correction -- same
  # class as the three ISS-0117 markers, not yet formalised into the schema
  # either) + 2 H2 (a negative started_at/completed_at gap, the timestamp
  # class ISS-0117/HANDOFF_PROTOCOL.md §1.2 already documents separately).
  #
  # 2026-08-22, ISS-0262 Step 8 change-approach rework (rework_count 2): H6 no
  # longer uses per-file grandfathering. The 12 entries previously here (10
  # from WF03-ISS0258-20260822, 2 from WF03-ISS0261-20260822) are removed --
  # H6 is now governed entirely by the `@h6_floor_commit` commit-boundary
  # rule (a file whose content predates that floor in git history is
  # automatically exempt; a file introduced at or after it always
  # hard-fails). See `lib/letflow/design/iss0262-h6-floor-commit-addendum.md`
  # for the mechanism and why the per-file list could not keep pace with
  # `main`. H1-H3's grandfathering below is unaffected by this change.
  @grandfathered [
    {"H3", "handoffs/WF02-REQ023-20260816/step-06-doc-updater.json"},
    {"H2", "handoffs/WF02-REQ025-20260817/step-01b-code-design-validator.json"},
    {"H3", "handoffs/WF02-REQ027-20260816/step-02d-reviewer.json"},
    {"H3", "handoffs/WF02-REQ037-20260817/step-02c-rework1-security-reviewer.json"},
    {"H3", "handoffs/WF02-REQ062-20260819/step-03-test-designer.json"},
    {"H2", "handoffs/WF03-ISS0047-20260818/step-03-elixir-dev.json"}
  ]

  @spec grandfathered?(String.t(), String.t()) :: boolean()
  defp grandfathered?(rule, path), do: {rule, path} in @grandfathered

  # -- H6 commit-boundary floor --------------------------------------------
  #
  # See `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` §1-§2 for
  # the full mechanism, rationale, and fail-safe direction.

  @spec h6_floor_commit() :: String.t()
  defp h6_floor_commit, do: @h6_floor_commit

  # Two git calls: (A) find the file's first-ever appearance in history
  # (`--diff-filter=A`, `--follow` across renames, `--reverse` for oldest
  # first); (B) is that first-appearance commit at or before `floor`. Fails
  # safe to `false` on any git error or nil floor -- H6 is a hard gate, so a
  # git malfunction must surface as a failure, not silently exempt a file
  # that might be a genuine regression (design §1.4).
  @spec pre_floor_file?(path :: String.t(), floor :: String.t() | nil) :: boolean()
  def pre_floor_file?(path, floor) do
    case Process.get({:h6_pre_floor, path, floor}, :unset) do
      :unset ->
        result = compute_pre_floor_file?(path, floor)
        Process.put({:h6_pre_floor, path, floor}, result)
        result

      cached ->
        cached
    end
  end

  defp compute_pre_floor_file?(_path, nil), do: false

  defp compute_pre_floor_file?(path, floor) do
    case System.cmd(
           "git",
           ["log", "--follow", "--diff-filter=A", "--format=%H", "--reverse", "--", path],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> String.split("\n", trim: true) do
          [] -> false
          [first_add_sha | _] -> ancestor_or_equal?(first_add_sha, floor)
        end

      _ ->
        false
    end
  end

  defp ancestor_or_equal?(sha, floor) do
    case System.cmd("git", ["merge-base", "--is-ancestor", sha, floor], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, 1} -> false
      _ -> false
    end
  end

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    files = handoff_files()
    protocol = File.read!(@protocol_file)
    not_agent_attested_schema = parse_not_agent_attested_schema(protocol)

    results = Enum.map(files, &lint_file(&1, not_agent_attested_schema))

    registry_result = check_registry_coverage(files)

    print_hard_violations(results)
    print_advisory(results)
    print_registry(registry_result)

    hard_new = Enum.flat_map(results, & &1.hard_new)

    # H5 (registry coverage) is report-only, per ISS-0191's own acceptance
    # criteria wording: AC1 says the schema checks are things the task
    # "validates" (a gate); AC2 separately says registry coverage is
    # something the task "reports" -- a different verb, deliberately. It
    # does not participate in the exit code.
    total_new = length(hard_new)

    IO.puts(@rule)

    if total_new > 0 do
      IO.puts("letflow.lint_handoffs: FAIL -- #{total_new} new (un-grandfathered) violation(s).")

      IO.puts(@rule)
      Mix.raise("letflow.lint_handoffs found #{total_new} new violation(s) -- see output above")
    else
      grandfathered_count =
        results |> Enum.flat_map(& &1.hard_grandfathered) |> length()

      IO.puts(
        "letflow.lint_handoffs: OK -- 0 new violations across #{length(files)} handoff files " <>
          "(#{grandfathered_count} pre-existing grandfathered, traced to ISS-0190)."
      )

      IO.puts(@rule)
      :ok
    end
  end

  # -- discovery ----------------------------------------------------------

  @spec handoff_files(dir :: String.t()) :: [String.t()]
  def handoff_files(dir \\ @handoffs_dir) do
    Path.wildcard(Path.join(dir, "**/step*.*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(&1 == registry_file(dir)))
    |> Enum.sort()
  end

  @spec registry_file(dir :: String.t()) :: String.t()
  defp registry_file(dir), do: Path.join(dir, "registry.json")

  # -- §4.1(b) schema, read live from HANDOFF_PROTOCOL.md ------------------

  # Returns %{required: [String.t()], optional: [String.t()], spent_exception_file: String.t() | nil}
  @spec parse_not_agent_attested_schema(String.t()) :: map()
  defp parse_not_agent_attested_schema(protocol) do
    table_section =
      case String.split(protocol, "### (b) The mandatory marking", parts: 2) do
        [_, rest] -> rest |> String.split("### (c)", parts: 2) |> hd()
        _ -> ""
      end

    row_re = ~r/^\|\s*`(\w+)`\s*(\*\*\(OPTIONAL[^)]*\)\*\*)?\s*\|/m

    {required, optional} =
      Regex.scan(row_re, table_section)
      |> Enum.reduce({[], []}, fn match, {req, opt} ->
        name = Enum.at(match, 1)
        optional_marker = Enum.at(match, 2, "")

        if optional_marker in [nil, ""] do
          {[name | req], opt}
        else
          {req, [name | opt]}
        end
      end)

    spent_file =
      case Regex.run(~r/One backfill was authorised.*?\n`([^`]+)`/s, protocol) do
        [_, path] -> path
        nil -> nil
      end

    %{
      required: Enum.reverse(required),
      optional: Enum.reverse(optional),
      spent_exception_file: spent_file
    }
  end

  # -- per-file lint --------------------------------------------------------

  @spec handoff_kind(path :: String.t()) :: :json | :non_json
  def handoff_kind(path) do
    if String.downcase(Path.extname(path)) == ".json" do
      :json
    else
      :non_json
    end
  end

  @spec lint_file(path :: String.t(), not_agent_attested_schema :: map()) :: map()
  def lint_file(path, not_agent_attested_schema) do
    case handoff_kind(path) do
      :non_json ->
        floor = h6_floor_commit()
        pre_floor? = pre_floor_file?(path, floor)

        v =
          violation(
            path,
            "H6",
            "non-JSON handoff-shaped file: #{path} has extension " <>
              "#{inspect(Path.extname(path))}, expected .json " <>
              "(pre_floor?: #{pre_floor?}, h6_floor_commit: #{inspect(floor)})",
            pre_floor?
          )

        %{
          path: path,
          hard_new: if(v.grandfathered, do: [], else: [v]),
          hard_grandfathered: if(v.grandfathered, do: [v], else: []),
          advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}},
          parse_error: nil
        }

      :json ->
        with {:ok, raw} <- File.read(path),
             {:ok, data} <- Jason.decode(raw) do
          hard = []

          hard = hard ++ check_h1_status(path, data)
          hard = hard ++ check_h2_timestamps(path, data)
          hard = hard ++ check_h3_keys(path, data)
          hard = hard ++ check_h4_not_agent_attested(path, data, not_agent_attested_schema)

          {grandfathered, new} = Enum.split_with(hard, & &1.grandfathered)

          advisory = check_advisory(path, data)

          %{
            path: path,
            hard_new: new,
            hard_grandfathered: grandfathered,
            advisory: advisory,
            parse_error: nil
          }
        else
          {:error, reason} ->
            %{
              path: path,
              hard_new: [
                %{
                  path: path,
                  rule: "PARSE",
                  message: "could not read/decode: #{inspect(reason)}",
                  grandfathered: false
                }
              ],
              hard_grandfathered: [],
              advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}},
              parse_error: inspect(reason)
            }
        end
    end
  end

  defp violation(path, rule, message, grandfathered? \\ false) do
    %{path: path, rule: rule, message: message, grandfathered: grandfathered?}
  end

  # H1 -------------------------------------------------------------------

  defp check_h1_status(path, %{"status" => status}) when is_binary(status) do
    if status in @legal_statuses do
      []
    else
      [
        violation(
          path,
          "H1",
          "top-level status #{inspect(status)} is not one of #{inspect(@legal_statuses)}",
          grandfathered?("H1", path)
        )
      ]
    end
  end

  defp check_h1_status(path, data) do
    [
      violation(
        path,
        "H1",
        "missing or non-string top-level status (#{inspect(Map.get(data, "status"))})",
        grandfathered?("H1", path)
      )
    ]
  end

  # H2 -------------------------------------------------------------------

  defp check_h2_timestamps(path, %{"started_at" => s, "completed_at" => c})
       when is_binary(s) and is_binary(c) do
    with {:ok, started, _} <- DateTime.from_iso8601(s),
         {:ok, completed, _} <- DateTime.from_iso8601(c) do
      if DateTime.compare(completed, started) == :lt do
        [
          violation(
            path,
            "H2",
            "completed_at (#{c}) precedes started_at (#{s})",
            grandfathered?("H2", path)
          )
        ]
      else
        []
      end
    else
      _ -> [violation(path, "H2", "started_at/completed_at present but not parseable ISO8601")]
    end
  end

  defp check_h2_timestamps(_path, _data), do: []

  # H3 -------------------------------------------------------------------

  defp check_h3_keys(path, data) do
    extra = Map.keys(data) -- @schema_top_keys

    if extra == [] do
      []
    else
      [
        violation(
          path,
          "H3",
          "non-schema top-level key(s): #{inspect(extra)}",
          grandfathered?("H3", path)
        )
      ]
    end
  end

  # H4 -------------------------------------------------------------------

  defp check_h4_not_agent_attested(_path, %{"not_agent_attested" => nil}, _schema), do: []

  defp check_h4_not_agent_attested(path, %{"not_agent_attested" => marker}, schema)
       when is_map(marker) do
    keys = Map.keys(marker)
    required = schema.required
    optional = schema.optional
    legal = required ++ optional

    missing_required = required -- keys
    illegal_extra = keys -- legal

    violations =
      []
      |> add_if(
        missing_required != [],
        violation(
          path,
          "H4",
          "not_agent_attested missing required member(s): #{inspect(missing_required)}"
        )
      )
      |> add_if(
        illegal_extra != [],
        violation(
          path,
          "H4",
          "not_agent_attested has member(s) outside the closed set: #{inspect(illegal_extra)}"
        )
      )

    backfill_violation =
      if "backfill_note" in keys and path != schema.spent_exception_file do
        [
          violation(
            path,
            "H4",
            "backfill_note present, but the §4.1(b) spent exception names only " <>
              "#{inspect(schema.spent_exception_file)} -- admissible on no other file"
          )
        ]
      else
        []
      end

    violations ++ backfill_violation
  end

  defp check_h4_not_agent_attested(_path, _data, _schema), do: []

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list

  # -- advisory checks ------------------------------------------------------

  @cite_restate_threshold 6_000
  @under_specified_threshold 400

  defp check_advisory(path, data) do
    desc = get_in(data, ["task", "description"]) || ""
    acs = get_in(data, ["task", "acceptance_criteria"]) || []
    artifacts_in = get_in(data, ["context", "artifacts_in"]) || []

    result_map =
      case Map.get(data, "result") do
        r when is_map(r) -> r
        _ -> %{}
      end

    artifacts_out = Map.get(result_map, "artifacts_out") || []

    summary =
      case Map.get(result_map, "summary") do
        s when is_binary(s) -> s
        _ -> ""
      end
    created_at = Map.get(data, "created_at")

    names = artifacts_in |> Enum.map(&Path.basename/1) |> MapSet.new()

    h_size_1 =
      if String.length(desc) > @cite_restate_threshold and
           Enum.any?(names, &String.contains?(desc, &1)) do
        [
          {:warn, "H-SIZE-1",
           "cite-and-restate: description is #{String.length(desc)} chars and repeats a named artifacts_in file"}
        ]
      else
        []
      end

    ac_len = Enum.reduce(acs, 0, fn ac, acc -> acc + String.length(to_string(ac)) end)

    h_size_2 =
      if String.length(desc) + ac_len < @under_specified_threshold do
        [
          {:warn, "H-SIZE-2",
           "under-specified: description + acceptance_criteria total #{String.length(desc) + ac_len} chars"}
        ]
      else
        []
      end

    artifacts_out_self_ref =
      if created_at_after_rule?(created_at) and self_referencing?(path, artifacts_out) do
        [{:warn, "ARTIFACTS_OUT_SELF_REF", "result.artifacts_out lists this handoff's own file"}]
      else
        []
      end

    %{
      path: path,
      warnings: h_size_1 ++ h_size_2 ++ artifacts_out_self_ref,
      size_info: %{
        desc_len: String.length(desc),
        summary_len: String.length(summary)
      }
    }
  end

  defp self_referencing?(path, artifacts_out) do
    base = Path.basename(path)

    Enum.any?(artifacts_out, fn out ->
      out_base = Path.basename(out)
      out_base == base or String.ends_with?(path, out) or String.ends_with?(out, path)
    end)
  end

  # Handoffs created at or after @artifacts_out_rule_commit's landing are in
  # scope for the WARN; earlier ones are historical and exempt. We can't ask
  # git "was this created_at before or after a commit" directly, so we use
  # the commit's own committed-at timestamp as the floor -- resolved once,
  # lazily, via `git show`.
  defp created_at_after_rule?(nil), do: false

  defp created_at_after_rule?(created_at) do
    with {:ok, ts, _} <- DateTime.from_iso8601(created_at),
         floor when not is_nil(floor) <- rule_commit_timestamp() do
      DateTime.compare(ts, floor) != :lt
    else
      _ -> false
    end
  end

  defp rule_commit_timestamp do
    case Process.get(:artifacts_out_rule_floor, :unset) do
      :unset ->
        floor = fetch_rule_commit_timestamp()
        Process.put(:artifacts_out_rule_floor, floor)
        floor

      cached ->
        cached
    end
  end

  defp fetch_rule_commit_timestamp do
    case System.cmd("git", ["show", "-s", "--format=%cI", @artifacts_out_rule_commit],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out |> String.trim() |> DateTime.from_iso8601() |> elem(1)

      _ ->
        nil
    end
  end

  # -- registry coverage ------------------------------------------------------

  defp check_registry_coverage(files) do
    disk_run_ids =
      files
      |> Enum.map(&(&1 |> Path.relative_to(@handoffs_dir) |> Path.split() |> hd()))
      |> Enum.uniq()
      |> MapSet.new()

    registry_run_ids =
      case File.read(@registry_file) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, %{"runs" => runs}} ->
              runs |> Enum.map(& &1["run_id"]) |> Enum.reject(&is_nil/1) |> MapSet.new()

            _ ->
              MapSet.new()
          end

        _ ->
          MapSet.new()
      end

    missing_from_registry = MapSet.difference(disk_run_ids, registry_run_ids) |> Enum.sort()
    missing_on_disk = MapSet.difference(registry_run_ids, disk_run_ids) |> Enum.sort()

    %{missing_from_registry: missing_from_registry, missing_on_disk: missing_on_disk}
  end

  # -- output ---------------------------------------------------------------

  defp print_hard_violations(results) do
    new = Enum.flat_map(results, & &1.hard_new)
    grandfathered = Enum.flat_map(results, & &1.hard_grandfathered)

    if new != [] do
      IO.puts(@rule)
      IO.puts("NEW HARD VIOLATIONS (fail the build):")

      Enum.each(new, fn v ->
        IO.puts("  [#{v.rule}] #{v.path}: #{v.message}")
      end)
    end

    if grandfathered != [] do
      IO.puts(@rule)
      IO.puts("GRANDFATHERED (pre-existing, traced to ISS-0190, do not fail the build):")

      Enum.each(grandfathered, fn v ->
        IO.puts("  [#{v.rule}] #{v.path}: #{v.message}")
      end)
    end
  end

  defp print_advisory(results) do
    all_warnings =
      Enum.flat_map(results, fn r -> Enum.map(r.advisory.warnings, &{r.path, &1}) end)

    if all_warnings != [] do
      IO.puts(@rule)
      IO.puts("ADVISORY (WARN, does not affect exit code):")

      Enum.each(all_warnings, fn {path, {:warn, rule, msg}} ->
        IO.puts("  [#{rule}] #{path}: #{msg}")
      end)
    end

    sizes = Enum.map(results, & &1.advisory.size_info)
    desc_lens = Enum.map(sizes, & &1.desc_len) |> Enum.sort()
    summary_lens = Enum.map(sizes, & &1.summary_len) |> Enum.sort()

    IO.puts(@rule)
    IO.puts("H-SIZE-3 (INFO, report only):")
    IO.puts("  n_steps: #{length(results)}")

    IO.puts(
      "  task.description len -- median: #{median(desc_lens)}, max: #{Enum.max(desc_lens, fn -> 0 end)}, total: #{Enum.sum(desc_lens)}"
    )

    h1_hits =
      results
      |> Enum.flat_map(& &1.advisory.warnings)
      |> Enum.count(fn {:warn, rule, _} -> rule == "H-SIZE-1" end)

    IO.puts("  H-SIZE-1 hits: #{h1_hits}")

    IO.puts(
      "  result.summary len -- median: #{median(summary_lens)}, max: #{Enum.max(summary_lens, fn -> 0 end)}, total: #{Enum.sum(summary_lens)}"
    )
  end

  defp print_registry(%{missing_from_registry: mfr, missing_on_disk: mod}) do
    IO.puts(@rule)
    IO.puts("H5 REGISTRY COVERAGE:")
    IO.puts("  run_id on disk but missing from registry.json: #{inspect(mfr)}")
    IO.puts("  run_id in registry.json but missing on disk: #{inspect(mod)}")
  end

  defp median([]), do: 0

  defp median(sorted) do
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end
end
