defmodule Mix.Tasks.Letflow.CheckUatScenarioSchema do
  @shortdoc "Validates test/fixtures/uat/scenarios/**/*.yaml against the UAT scenario schema"

  @moduledoc """
  REQ-358: mechanical schema validation for the UAT scenario corpus.

  Documents the schema itself in `docs/agents/uat-scenario-schema.md` (the `scope:`
  field and the `branches:`/`when:` step-level branching construct) — this task
  enforces only the mechanical half of that schema, never the semantic
  "is this scenario classified correctly" judgment call the schema doc itself
  says is not mechanically checkable.

  Follows `Mix.Tasks.Letflow.CheckRequirementsRegistration`'s structural
  precedent: a thin `run/1` `Mix.Task` entry point over a pure,
  hermetically-testable core (`check_scenario/2`) that never raises on
  malformed *content* — a parse or schema violation becomes a `file_result()`
  with `ok?: false` and a populated `violations` list. Only an unreadable path
  (an I/O error, not a schema error) raises.

  ## Rules (each a distinct `rule` tag; any violation across the corpus fails the run)

    * **SCHEMA-0** -- the scenario glob matched zero files. An empty corpus is
      never a silent green pass (mirrors `check_requirements_registration`'s R5).
    * **SCHEMA-1** -- the file parses as valid YAML at all. A parse failure is
      reported with the underlying decoder error message, not swallowed.
    * **SCHEMA-2** -- top-level `id`, `title`, `version` are present and
      non-empty strings. Pre-existing required fields, unchanged by this
      design -- stated here because this task validates the whole current
      shape, not only the new additions.
    * **SCHEMA-3** -- resolved `scope` (an explicit `scope:` key, or the
      schema doc's default derived from `company_id:`) is present and a
      non-empty string. Fires when neither `scope:` nor `company_id:` is
      present at all.
    * **SCHEMA-4** -- a file carries either top-level `steps:`+`expected_outcomes:`
      or `branches:`, never both, never neither.
    * **SCHEMA-5** -- (when `branches:` is present) each branch entry has a
      non-empty `name` (unique within the file), a `when` that is either the
      literal string `"else"` or a map with `fact` (non-empty string), `op`
      (exactly `"eq"` or `"in"`), and `value` (a string for `eq`, a non-empty
      list of strings for `in`), and non-empty `steps:`/`expected_outcomes:`
      lists.
    * **SCHEMA-6** -- at most one `branches:` entry has `when: else`, and if
      present it is the last entry in the list.

  ## What this task never does

  It never validates the semantic correctness of a scenario's `scope`
  classification (per the schema doc's classification rule -- "is this the
  right classification" is a human/agent judgment call, not a mechanical
  check) and does not re-validate every field of the pre-existing per-step /
  per-expected-outcome shape beyond the additive `scope`/`branches` surface
  (SCHEMA-3 through SCHEMA-6) -- see the REQ-358 design doc's OQ-2.

  ## Usage

      mix letflow.check_uat_scenario_schema

  Wired into the `letflow.check` alias immediately after
  `letflow.check_issue_refs`, grouped with the other fast, non-compiling,
  structural scans -- see `mix.exs`.

  Exits `0` iff every scenario file is violation-free; `Mix.raise/1`
  otherwise, naming every violation by rule id, file, and message.
  """

  use Mix.Task

  @scenario_glob "test/fixtures/uat/scenarios/**/*.yaml"

  @type violation :: %{
          file: Path.t(),
          rule: String.t(),
          message: String.t()
        }

  @type file_result :: %{
          file: Path.t(),
          ok?: boolean(),
          violations: [violation()]
        }

  @type report :: %{
          files: [file_result()],
          file_count: non_neg_integer(),
          violations: [violation()]
        }

  @rule String.duplicate("=", 72)
  @thin_rule String.duplicate("-", 72)

  # -- Mix.Task entry point -------------------------------------------------

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    paths = @scenario_glob |> Path.wildcard() |> Enum.sort()

    files = Enum.map(paths, &check_file/1)

    file_violations = Enum.flat_map(files, & &1.violations)

    corpus_violations =
      if paths == [] do
        [
          %{
            file: @scenario_glob,
            rule: "SCHEMA-0",
            message:
              "scenario glob matched zero files -- an empty UAT scenario corpus is never " <>
                "a silent green pass"
          }
        ]
      else
        []
      end

    report = %{
      files: files,
      file_count: length(files),
      violations: corpus_violations ++ file_violations
    }

    report |> render() |> IO.write()

    if report.violations == [] do
      :ok
    else
      Mix.raise(
        "mix letflow.check_uat_scenario_schema: FAILED -- " <>
          "#{length(report.violations)} violation(s):\n" <>
          Enum.map_join(report.violations, "\n", &format_violation/1)
      )
    end
  end

  # -- pure core --------------------------------------------------------------

  @doc """
  Checks one scenario file by path.

  Never raises on a malformed file -- a parse or schema violation becomes a
  `file_result()` with `ok?: false` and a populated `violations` list, exactly
  like `check_requirements_registration`'s `scan/1` never raising on
  malformed content. Raises only if the path cannot be read at all (I/O
  error, not a schema error).
  """
  @spec check_file(Path.t()) :: file_result()
  def check_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) ->
        violations = check_scenario(path, data)
        %{file: path, ok?: violations == [], violations: violations}

      {:ok, _other} ->
        violation = violation(path, "SCHEMA-1", "top-level YAML content is not a mapping")
        %{file: path, ok?: false, violations: [violation]}

      {:error, reason} ->
        violation(path, "SCHEMA-1", "YAML parse error: #{format_yaml_error(reason)}")
        |> List.wrap()
        |> then(&%{file: path, ok?: false, violations: &1})
    end
  end

  @doc """
  Pure core: given already-parsed scenario data (a map, as produced by
  `YamlElixir.read_from_file/1`, matching the codebase's existing convention
  in e.g. `test/support/simulation/scenario_fixture.ex`) and the file's path
  (for error messages only), returns every mechanically-checkable violation.
  Empty list iff the file satisfies every mechanical rule (SCHEMA-2 through
  SCHEMA-6). This is the unit hermetic fixture tests target, mirroring
  `classify_entry/1`'s role in the precedent module.
  """
  @spec check_scenario(Path.t(), map()) :: [violation()]
  def check_scenario(path, scenario_data) when is_map(scenario_data) do
    required_string_violations(path, scenario_data) ++
      scope_violations(path, scenario_data) ++
      steps_vs_branches_violations(path, scenario_data)
  end

  # -- SCHEMA-2: pre-existing required top-level fields ------------------------

  @spec required_string_violations(Path.t(), map()) :: [violation()]
  defp required_string_violations(path, data) do
    ["id", "title", "version"]
    |> Enum.flat_map(fn key ->
      case Map.get(data, key) do
        v when is_binary(v) and v != "" ->
          []

        _ ->
          [
            violation(
              path,
              "SCHEMA-2",
              "top-level `#{key}:` is missing or not a non-empty string"
            )
          ]
      end
    end)
  end

  # -- SCHEMA-3: resolved `scope` -----------------------------------------------

  @spec scope_violations(Path.t(), map()) :: [violation()]
  defp scope_violations(path, data) do
    scope = Map.get(data, "scope")
    company_id = Map.get(data, "company_id")

    cond do
      is_binary(scope) and scope != "" ->
        []

      is_binary(company_id) and company_id != "" ->
        []

      true ->
        [
          violation(
            path,
            "SCHEMA-3",
            "neither `scope:` nor `company_id:` is present -- a scenario with no scope " <>
              "information cannot be classified"
          )
        ]
    end
  end

  # -- SCHEMA-4/5/6: steps-vs-branches and branch shape -------------------------

  @spec steps_vs_branches_violations(Path.t(), map()) :: [violation()]
  defp steps_vs_branches_violations(path, data) do
    has_steps? = Map.has_key?(data, "steps")
    has_expected_outcomes? = Map.has_key?(data, "expected_outcomes")
    has_branches? = Map.has_key?(data, "branches")
    flat_present? = has_steps? or has_expected_outcomes?

    cond do
      flat_present? and has_branches? ->
        [
          violation(
            path,
            "SCHEMA-4",
            "carries both top-level `steps:`/`expected_outcomes:` and `branches:` -- " <>
              "a scenario must use exactly one of the two step shapes"
          )
        ]

      not flat_present? and not has_branches? ->
        [
          violation(
            path,
            "SCHEMA-4",
            "carries neither top-level `steps:`/`expected_outcomes:` nor `branches:` -- " <>
              "a scenario must define at least one step shape"
          )
        ]

      has_branches? ->
        branch_violations(path, Map.get(data, "branches"))

      true ->
        []
    end
  end

  @spec branch_violations(Path.t(), term()) :: [violation()]
  defp branch_violations(path, branches) when is_list(branches) and branches != [] do
    shape_violations =
      branches |> Enum.with_index() |> Enum.flat_map(&branch_shape_violations(path, &1))

    else_violations = else_branch_violations(path, branches)
    name_violations = duplicate_branch_name_violations(path, branches)

    shape_violations ++ else_violations ++ name_violations
  end

  defp branch_violations(path, _branches) do
    [violation(path, "SCHEMA-5", "`branches:` must be a non-empty list")]
  end

  @spec branch_shape_violations(Path.t(), {term(), non_neg_integer()}) :: [violation()]
  defp branch_shape_violations(path, {branch, index}) when is_map(branch) do
    label = branch_label(branch, index)

    name_v =
      case Map.get(branch, "name") do
        v when is_binary(v) and v != "" ->
          []

        _ ->
          [violation(path, "SCHEMA-5", "branch #{label} has a missing or empty `name`")]
      end

    when_v = when_violations(path, label, Map.get(branch, "when"))

    steps_v =
      case Map.get(branch, "steps") do
        v when is_list(v) and v != [] ->
          []

        _ ->
          [violation(path, "SCHEMA-5", "branch #{label} has a missing or empty `steps:` list")]
      end

    outcomes_v =
      case Map.get(branch, "expected_outcomes") do
        v when is_list(v) and v != [] ->
          []

        _ ->
          [
            violation(
              path,
              "SCHEMA-5",
              "branch #{label} has a missing or empty `expected_outcomes:` list"
            )
          ]
      end

    name_v ++ when_v ++ steps_v ++ outcomes_v
  end

  defp branch_shape_violations(path, {_branch, index}) do
    [violation(path, "SCHEMA-5", "branch at index #{index} is not a mapping")]
  end

  @spec when_violations(Path.t(), String.t(), term()) :: [violation()]
  defp when_violations(_path, _label, "else"), do: []

  defp when_violations(path, label, %{"fact" => fact, "op" => op, "value" => value}) do
    fact_v =
      if is_binary(fact) and fact != "" do
        []
      else
        [violation(path, "SCHEMA-5", "branch #{label}'s `when.fact` is missing or empty")]
      end

    op_value_v =
      case op do
        "eq" ->
          if is_binary(value) and value != "" do
            []
          else
            [
              violation(
                path,
                "SCHEMA-5",
                "branch #{label}'s `when.value` must be a non-empty string for `op: eq`"
              )
            ]
          end

        "in" ->
          if is_list(value) and value != [] and Enum.all?(value, &(is_binary(&1) and &1 != "")) do
            []
          else
            [
              violation(
                path,
                "SCHEMA-5",
                "branch #{label}'s `when.value` must be a non-empty list of non-empty " <>
                  "strings for `op: in`"
              )
            ]
          end

        _ ->
          [
            violation(
              path,
              "SCHEMA-5",
              "branch #{label}'s `when.op` is #{inspect(op)} -- only `eq` and `in` are allowed"
            )
          ]
      end

    fact_v ++ op_value_v
  end

  defp when_violations(path, label, _other) do
    [
      violation(
        path,
        "SCHEMA-5",
        "branch #{label}'s `when` is neither the literal string `else` nor a map with " <>
          "`fact`/`op`/`value`"
      )
    ]
  end

  @spec else_branch_violations(Path.t(), [term()]) :: [violation()]
  defp else_branch_violations(path, branches) do
    else_indexes =
      branches
      |> Enum.with_index()
      |> Enum.filter(fn {branch, _i} -> is_map(branch) and Map.get(branch, "when") == "else" end)
      |> Enum.map(fn {_branch, i} -> i end)

    last_index = length(branches) - 1

    cond do
      length(else_indexes) > 1 ->
        [
          violation(
            path,
            "SCHEMA-6",
            "more than one `branches:` entry has `when: else` (at index(es) " <>
              "#{Enum.join(else_indexes, ", ")}) -- at most one is allowed"
          )
        ]

      else_indexes == [last_index] or else_indexes == [] ->
        []

      true ->
        [only_index] = else_indexes

        branch_name =
          branches
          |> Enum.at(only_index)
          |> case do
            %{"name" => name} when is_binary(name) -> name
            _ -> "index #{only_index}"
          end

        [
          violation(
            path,
            "SCHEMA-6",
            "`when: else` branch #{inspect(branch_name)} is not the last entry in " <>
              "`branches:` (appears at index #{only_index} of #{last_index})"
          )
        ]
    end
  end

  @spec duplicate_branch_name_violations(Path.t(), [term()]) :: [violation()]
  defp duplicate_branch_name_violations(path, branches) do
    names =
      branches
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      violation(path, "SCHEMA-5", "branch name #{inspect(name)} is not unique within the file")
    end)
    |> Enum.sort_by(& &1.message)
  end

  @spec branch_label(map(), non_neg_integer()) :: String.t()
  defp branch_label(%{"name" => name}, _index) when is_binary(name) and name != "" do
    inspect(name)
  end

  defp branch_label(_branch, index), do: "at index #{index}"

  # -- rendering ----------------------------------------------------------------

  @doc """
  Renders the always-printed report (per-file pass/fail line, then a
  summary and, when present, the violation list). Pure, like
  `check_requirements_registration`'s `render/1`.
  """
  @spec render(report()) :: iodata()
  def render(report) do
    [
      @rule,
      "\n",
      "mix letflow.check_uat_scenario_schema -- ",
      @scenario_glob,
      "\n",
      @rule,
      "\n",
      render_files(report),
      @thin_rule,
      "\n",
      summary_line(report),
      "\n",
      render_violations(report),
      @rule,
      "\n"
    ]
  end

  @spec render_files(report()) :: iodata()
  defp render_files(%{files: files}) do
    Enum.map(files, fn %{file: file, ok?: ok?} ->
      status = if ok?, do: "OK", else: "FAIL"
      [status, "  ", file, "\n"]
    end)
  end

  @spec summary_line(report()) :: String.t()
  defp summary_line(%{file_count: file_count, violations: violations}) do
    fail_count = violations |> Enum.map(& &1.file) |> Enum.uniq() |> length()

    "#{file_count} file(s) checked, #{length(violations)} violation(s) across " <>
      "#{fail_count} file(s)"
  end

  @spec render_violations(report()) :: iodata()
  defp render_violations(%{violations: []}), do: []

  defp render_violations(%{violations: violations}) do
    [
      @thin_rule,
      "\n",
      "VIOLATIONS (each one fails the run):\n",
      Enum.map(violations, fn v -> ["  ", format_violation(v), "\n"] end)
    ]
  end

  @spec format_violation(violation()) :: String.t()
  defp format_violation(%{rule: rule, file: file, message: message}) do
    "[#{rule}] #{file}: #{message}"
  end

  # -- helpers --------------------------------------------------------------

  @spec violation(Path.t(), String.t(), String.t()) :: violation()
  defp violation(file, rule, message), do: %{file: file, rule: rule, message: message}

  @spec format_yaml_error(term()) :: String.t()
  defp format_yaml_error(reason) do
    case reason do
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end
  end
end
