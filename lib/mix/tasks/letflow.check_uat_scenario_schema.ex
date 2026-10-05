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
    * **SCHEMA-7** (REQ-452 rule a) -- every login actor id a scenario references has an
      entry in `test/fixtures/uat/actors.yaml` under `actors:` or `unresolved:`.
    * **SCHEMA-8** (rule b) -- every roster `builtin_roles` value is in
      `Letflow.Api.Authorization.roles/0` as loaded at check time.
    * **SCHEMA-9** (rule c) -- a roster actor whose tenant is not `platform` must not hold
      `PLATFORM_ADMIN`, unless listed under `legacy_platform_admin`.
    * **SCHEMA-10** (rule d) -- a platform-tenant actor appears only in scenarios whose
      resolved scope is `platform`, or whose id is in `platform_actor_allowed` with a reason.
    * **SCHEMA-11** (rule e) -- every resolved scope with at least one scenario has a step
      with `expect_refusal: true`, unless the scope is in `refusal_coverage_exempt`.
    * **SCHEMA-12** -- structural integrity of the new inputs: the roster file's shape, and
      `expect_refusal` being a boolean when present on a step.

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
  `letflow.check_issue_refs`, grouped with the other fast structural scans -- see
  `mix.exs`. SCHEMA-8 needs `Letflow.Api.Authorization` loaded, so `run/1` runs the
  `compile` task first (REQ-452 design D1).

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

  @type role_name :: String.t()

  @type actor_entry :: %{
          tenant: String.t(),
          builtin_roles: [role_name()],
          routing_roles: [String.t()],
          note: String.t() | nil
        }

  @type roster :: %{
          actors: %{String.t() => actor_entry()},
          unresolved: %{String.t() => [String.t()]},
          platform_actor_allowed: %{String.t() => String.t()},
          refusal_coverage_exempt: [String.t()],
          legacy_platform_admin: %{
            String.t() => %{since: Date.t(), reason: String.t(), removed_by: String.t()}
          }
        }

  @type scenario :: {Path.t(), map()}

  @type actor_stats :: %{
          login_actors: non_neg_integer(),
          in_roster: non_neg_integer(),
          unresolved: non_neg_integer(),
          missing: non_neg_integer()
        }

  @type report :: %{
          required(:files) => [file_result()],
          required(:file_count) => non_neg_integer(),
          required(:violations) => [violation()],
          optional(:actor_stats) => actor_stats() | :not_loaded,
          optional(:roster_path) => Path.t()
        }

  @roster_path "test/fixtures/uat/actors.yaml"

  @rule String.duplicate("=", 72)
  @thin_rule String.duplicate("-", 72)

  # -- Mix.Task entry point -------------------------------------------------

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    # SCHEMA-8 reads Authorization.roles/0 at check time (REQ-452 design D1).
    Mix.Task.run("compile")

    paths = @scenario_glob |> Path.wildcard() |> Enum.sort()
    report = check_paths(paths, @roster_path, known_role_names())

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
      steps_vs_branches_violations(path, scenario_data) ++
      expect_refusal_violations(path, scenario_data)
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
    case resolve_scope(data) do
      nil ->
        [
          violation(
            path,
            "SCHEMA-3",
            "neither `scope:` nor `company_id:` is present -- a scenario with no scope " <>
              "information cannot be classified"
          )
        ]

      _scope ->
        []
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

  # -- SCHEMA-12 (file-local): `expect_refusal` step key ------------------------

  @spec expect_refusal_violations(Path.t(), map()) :: [violation()]
  defp expect_refusal_violations(path, data) do
    data
    |> step_lists()
    |> Enum.flat_map(fn steps ->
      steps
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {%{"expect_refusal" => v}, n} when not is_boolean(v) ->
          [violation(path, "SCHEMA-12", "step #{n}: expect_refusal must be a boolean")]

        _ ->
          []
      end)
    end)
  end

  # -- scenario-data helpers ----------------------------------------------------

  # Every list of steps in a scenario: the flat `steps:` list and each branch's `steps:`.
  # Tolerates any malformed shape (returns fewer lists, never raises).
  @spec step_lists(term()) :: [[term()]]
  defp step_lists(data) when is_map(data) do
    flat = if is_list(data["steps"]), do: [data["steps"]], else: []

    branch_steps =
      case data["branches"] do
        branches when is_list(branches) ->
          for %{"steps" => steps} <- branches, is_list(steps), do: steps

        _ ->
          []
      end

    flat ++ branch_steps
  end

  defp step_lists(_data), do: []

  @doc "Role names from `Letflow.Api.Authorization.roles/0`, as strings, read at call time."
  @spec known_role_names() :: [role_name()]
  def known_role_names, do: Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)

  @doc "True iff `id` is a login actor id (not `actor-system-*`, not `actor-any`)."
  @spec login_actor?(term()) :: boolean()
  def login_actor?("actor-any"), do: false
  def login_actor?("actor-system-" <> _), do: false
  def login_actor?("actor-" <> _), do: true
  def login_actor?(_other), do: false

  @doc "Sorted unique login actor ids: top-level `actors:` values plus every step `actor:`."
  @spec login_actor_ids(map()) :: [String.t()]
  def login_actor_ids(data) when is_map(data) do
    declared =
      case data["actors"] do
        m when is_map(m) -> Map.values(m)
        _ -> []
      end

    from_steps =
      data
      |> step_lists()
      |> List.flatten()
      |> Enum.flat_map(fn
        %{"actor" => actor} -> [actor]
        _ -> []
      end)

    (declared ++ from_steps) |> Enum.filter(&login_actor?/1) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Resolved scope: `scope:` if a non-empty string, else `company_id:`, else `nil` (SCHEMA-3's precedence)."
  @spec resolve_scope(map()) :: String.t() | nil
  def resolve_scope(data) when is_map(data) do
    case {data["scope"], data["company_id"]} do
      {s, _} when is_binary(s) and s != "" -> s
      {_, c} when is_binary(c) and c != "" -> c
      _ -> nil
    end
  end

  @doc "True iff any step (flat or in a branch) has `expect_refusal: true`."
  @spec has_refusal_step?(map()) :: boolean()
  def has_refusal_step?(data) do
    data
    |> step_lists()
    |> List.flatten()
    |> Enum.any?(&match?(%{"expect_refusal" => true}, &1))
  end

  # -- roster: read + shape validation (SCHEMA-12) -------------------------------

  @doc """
  Reads and shape-validates the actor roster. Never raises on content: a missing,
  unreadable, unparseable or malformed roster becomes SCHEMA-12 violations whose
  `file` is the roster path.
  """
  @spec read_roster(Path.t()) :: {:ok, roster()} | {:error, [violation()]}
  def read_roster(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- YamlElixir.read_from_string(raw) do
      if is_map(data) do
        validate_roster(path, data)
      else
        {:error, [roster_violation(path, "roster is not a YAML mapping")]}
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, [roster_violation(path, "roster unreadable: #{:file.format_error(reason)}")]}

      {:error, reason} ->
        {:error,
         [roster_violation(path, "roster YAML parse error: #{format_yaml_error(reason)}")]}
    end
  end

  @spec roster_violation(Path.t(), String.t()) :: violation()
  defp roster_violation(path, message), do: violation(path, "SCHEMA-12", message)

  @spec validate_roster(Path.t(), map()) :: {:ok, roster()} | {:error, [violation()]}
  defp validate_roster(path, data) do
    {actors, actor_errors} = validate_actors(data["actors"])
    {unresolved, unresolved_errors} = validate_unresolved(data["unresolved"], actors)
    {allowed, allowed_errors} = validate_allowed(data["platform_actor_allowed"])
    {exempt, exempt_errors} = validate_exempt(data["refusal_coverage_exempt"])
    {legacy, legacy_errors} = validate_legacy(data["legacy_platform_admin"], actors)

    errors =
      actor_errors ++ unresolved_errors ++ allowed_errors ++ exempt_errors ++ legacy_errors

    if errors == [] do
      {:ok,
       %{
         actors: actors,
         unresolved: unresolved,
         platform_actor_allowed: allowed,
         refusal_coverage_exempt: exempt,
         legacy_platform_admin: legacy
       }}
    else
      {:error, errors |> Enum.map(&roster_violation(path, &1)) |> sort_violations()}
    end
  end

  defp validate_actors(actors) when is_map(actors) and map_size(actors) > 0 do
    Enum.reduce(actors, {%{}, []}, fn {id, entry}, {ok, errs} ->
      case validate_actor_entry(id, entry) do
        {:ok, e} -> {Map.put(ok, id, e), errs}
        {:error, es} -> {ok, errs ++ es}
      end
    end)
  end

  defp validate_actors(_other), do: {%{}, ["`actors:` is missing, not a mapping, or empty"]}

  defp validate_actor_entry(id, entry) when is_map(entry) do
    tenant = entry["tenant"]
    builtin = entry["builtin_roles"]
    routing = Map.get(entry, "routing_roles", [])
    note = entry["note"]

    errs =
      [
        {non_empty_string?(tenant), "actor \"#{id}\": `tenant` must be a non-empty string"},
        {string_list?(builtin) and builtin != [],
         "actor \"#{id}\": `builtin_roles` must be a non-empty list of non-empty strings"},
        {string_list?(routing),
         "actor \"#{id}\": `routing_roles` must be a list of non-empty strings"},
        {is_nil(note) or is_binary(note), "actor \"#{id}\": `note` must be a string"}
      ]
      |> Enum.reject(fn {ok?, _} -> ok? end)
      |> Enum.map(&elem(&1, 1))

    if errs == [] do
      {:ok, %{tenant: tenant, builtin_roles: builtin, routing_roles: routing, note: note}}
    else
      {:error, errs}
    end
  end

  defp validate_actor_entry(id, _entry), do: {:error, ["actor \"#{id}\": entry is not a mapping"]}

  defp validate_unresolved(nil, _actors), do: {%{}, []}

  defp validate_unresolved(unresolved, actors) when is_map(unresolved) do
    Enum.reduce(unresolved, {%{}, []}, fn {id, entry}, {ok, errs} ->
      searched = if is_map(entry), do: entry["searched"], else: nil

      dup =
        if Map.has_key?(actors, id),
          do: ["actor \"#{id}\" is under both actors and unresolved"],
          else: []

      bad =
        if string_list?(searched) and searched != [],
          do: [],
          else: ["unresolved actor \"#{id}\": `searched` must be a non-empty list of strings"]

      case dup ++ bad do
        [] -> {Map.put(ok, id, searched), errs}
        es -> {ok, errs ++ es}
      end
    end)
  end

  defp validate_unresolved(_other, _actors), do: {%{}, ["`unresolved:` must be a mapping"]}

  defp validate_allowed(nil), do: {%{}, []}

  defp validate_allowed(allowed) when is_map(allowed) do
    errs =
      for {id, reason} <- allowed,
          not (is_binary(reason) and String.trim(reason) != ""),
          do: "platform_actor_allowed \"#{id}\": reason must be a non-empty string"

    {allowed, errs}
  end

  defp validate_allowed(_other), do: {%{}, ["`platform_actor_allowed:` must be a mapping"]}

  defp validate_exempt(nil), do: {[], []}

  defp validate_exempt(list) do
    if string_list?(list),
      do: {list, []},
      else: {[], ["`refusal_coverage_exempt:` must be a list of non-empty strings"]}
  end

  defp validate_legacy(nil, _actors), do: {%{}, []}

  defp validate_legacy(legacy, actors) when is_map(legacy) do
    Enum.reduce(legacy, {%{}, []}, fn {id, entry}, {ok, errs} ->
      entry = if is_map(entry), do: entry, else: %{}
      since = parse_date(entry["since"])
      reason = entry["reason"]
      removed_by = entry["removed_by"]
      actor = Map.get(actors, id)

      es =
        [
          {since != nil, "legacy_platform_admin \"#{id}\": `since` must be an ISO date"},
          {non_empty_string?(reason), "legacy_platform_admin \"#{id}\": `reason` is empty"},
          {non_empty_string?(removed_by),
           "legacy_platform_admin \"#{id}\": `removed_by` is missing"},
          {actor != nil, "legacy_platform_admin \"#{id}\": actor is not in `actors`"},
          {actor == nil or "PLATFORM_ADMIN" in actor.builtin_roles,
           "legacy_platform_admin \"#{id}\": actor does not hold PLATFORM_ADMIN (stale exemption)"},
          {actor == nil or actor.tenant != "platform",
           "legacy_platform_admin \"#{id}\": actor has tenant platform (pointless exemption)"}
        ]
        |> Enum.reject(fn {ok?, _} -> ok? end)
        |> Enum.map(&elem(&1, 1))

      case es do
        [] -> {Map.put(ok, id, %{since: since, reason: reason, removed_by: removed_by}), errs}
        _ -> {ok, errs ++ es}
      end
    end)
  end

  defp validate_legacy(_other, _actors), do: {%{}, ["`legacy_platform_admin:` must be a mapping"]}

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_other), do: nil

  defp non_empty_string?(v), do: is_binary(v) and String.trim(v) != ""
  defp string_list?(v), do: is_list(v) and Enum.all?(v, &non_empty_string?/1)

  # -- roster-only rules: SCHEMA-8, SCHEMA-9 ------------------------------------

  @doc "Roster-only rules SCHEMA-8 (unknown built-in role) and SCHEMA-9 (tenant actor holds PLATFORM_ADMIN)."
  @spec check_roster(Path.t(), roster(), [role_name()]) :: [violation()]
  def check_roster(roster_path, roster, known_roles) do
    known = Enum.join(known_roles, ", ")

    unknown_role =
      for {id, entry} <- roster.actors,
          role <- Enum.uniq(entry.builtin_roles),
          role not in known_roles do
        violation(
          roster_path,
          "SCHEMA-8",
          "actor \"#{id}\" lists builtin_roles value \"#{role}\" which is not in " <>
            "Authorization.roles/0 (#{known})"
        )
      end

    tenant_admin =
      for {id, entry} <- roster.actors,
          entry.tenant != "platform",
          "PLATFORM_ADMIN" in entry.builtin_roles,
          not Map.has_key?(roster.legacy_platform_admin, id) do
        violation(
          roster_path,
          "SCHEMA-9",
          "actor \"#{id}\" has tenant \"#{entry.tenant}\" (not platform) but holds " <>
            "PLATFORM_ADMIN and is not listed under legacy_platform_admin"
        )
      end

    sort_violations(unknown_role ++ tenant_admin)
  end

  # -- corpus rules: SCHEMA-7, SCHEMA-10, SCHEMA-11 -----------------------------

  @doc "Cross-file rules SCHEMA-7, SCHEMA-10, SCHEMA-11, plus the actor counts for the printout."
  @spec check_corpus([scenario()], Path.t(), roster(), [role_name()]) ::
          {[violation()], actor_stats()}
  def check_corpus(scenarios, roster_path, roster, _known_roles) do
    per_scenario =
      for {path, data} <- scenarios, is_map(data), do: {path, data, login_actor_ids(data)}

    covered = fn id -> Map.has_key?(roster.actors, id) or Map.has_key?(roster.unresolved, id) end

    missing_v =
      for {path, _data, ids} <- per_scenario, id <- ids, not covered.(id) do
        violation(
          path,
          "SCHEMA-7",
          "login actor \"#{id}\" has no entry in #{roster_path} under actors: or unresolved:"
        )
      end

    platform_v =
      for {path, data, ids} <- per_scenario,
          scope = resolve_scope(data),
          scope != nil and scope != "platform",
          not allowed_platform_scenario?(roster, data),
          id <- ids,
          match?(%{tenant: "platform"}, Map.get(roster.actors, id)) do
        violation(
          path,
          "SCHEMA-10",
          "platform actor \"#{id}\" appears in scenario \"#{data["id"]}\" whose resolved " <>
            "scope is \"#{scope}\"; allowed only in scope platform or when the scenario id " <>
            "is listed in platform_actor_allowed with a non-empty reason"
        )
      end

    refusal_v =
      per_scenario
      |> Enum.filter(fn {_p, data, _ids} -> resolve_scope(data) != nil end)
      |> Enum.group_by(fn {_p, data, _ids} -> resolve_scope(data) end)
      |> Enum.flat_map(fn {scope, group} ->
        covered? =
          Enum.any?(group, fn {_p, data, _ids} -> has_refusal_step?(data) end) or
            scope in roster.refusal_coverage_exempt

        if covered? do
          []
        else
          first = group |> Enum.map(&elem(&1, 0)) |> Enum.min()

          [
            violation(
              first,
              "SCHEMA-11",
              "resolved scope \"#{scope}\" has #{length(group)} scenario(s) and none has a " <>
                "step with expect_refusal: true; add one or list \"#{scope}\" under " <>
                "refusal_coverage_exempt"
            )
          ]
        end
      end)

    all_ids = per_scenario |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()
    in_roster = Enum.count(all_ids, &Map.has_key?(roster.actors, &1))
    unresolved = Enum.count(all_ids, &Map.has_key?(roster.unresolved, &1))

    stats = %{
      login_actors: length(all_ids),
      in_roster: in_roster,
      unresolved: unresolved,
      missing: length(all_ids) - in_roster - unresolved
    }

    {sort_violations(missing_v ++ platform_v ++ refusal_v), stats}
  end

  defp allowed_platform_scenario?(roster, data) do
    case Map.get(roster.platform_actor_allowed, data["id"]) do
      reason when is_binary(reason) -> String.trim(reason) != ""
      _ -> false
    end
  end

  @spec sort_violations([violation()]) :: [violation()]
  defp sort_violations(violations) do
    violations |> Enum.uniq() |> Enum.sort_by(&{&1.rule, &1.file, &1.message})
  end

  # -- orchestration -------------------------------------------------------------

  @doc """
  Pure of `Mix`: runs the per-file checks, loads the roster, and (only when the roster
  loaded) the roster and cross-file rules. `run/1` and the live-corpus test both call it.
  """
  @spec check_paths([Path.t()], Path.t(), [role_name()]) :: report()
  def check_paths(paths, roster_path, known_roles) do
    files = Enum.map(paths, &check_file/1)
    file_violations = Enum.flat_map(files, & &1.violations)

    empty_v =
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

    {roster_v, actor_stats} =
      case read_roster(roster_path) do
        {:ok, roster} ->
          scenarios =
            Enum.flat_map(paths, fn path ->
              case YamlElixir.read_from_file(path) do
                {:ok, data} when is_map(data) -> [{path, data}]
                _ -> []
              end
            end)

          {corpus_v, stats} = check_corpus(scenarios, roster_path, roster, known_roles)
          {check_roster(roster_path, roster, known_roles) ++ corpus_v, stats}

        {:error, violations} ->
          {violations, :not_loaded}
      end

    %{
      files: files,
      file_count: length(files),
      violations: empty_v ++ file_violations ++ roster_v,
      actor_stats: actor_stats,
      roster_path: roster_path
    }
  end

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
      render_actor_stats(report),
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

  @spec render_actor_stats(report()) :: iodata()
  defp render_actor_stats(report) do
    path = Map.get(report, :roster_path, @roster_path)

    case Map.get(report, :actor_stats) do
      nil ->
        []

      :not_loaded ->
        ["Actor roster: ", path, " -- not loaded (see SCHEMA-12)\n"]

      %{login_actors: l, in_roster: r, unresolved: u, missing: m} ->
        [
          "Actor roster: #{path} -- #{l} login actor(s) in corpus: #{r} in roster, " <>
            "#{u} unresolved, #{m} missing\n"
        ]
    end
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
