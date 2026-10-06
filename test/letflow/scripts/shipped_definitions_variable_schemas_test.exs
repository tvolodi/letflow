defmodule Letflow.Scripts.ShippedDefinitionsVariableSchemasTest do
  @moduledoc """
  ISS-1027 / Q-1009 (GH #2307) -- every shipped QA process definition carries `variable_schemas`
  with enums for the decision/outcome variables its edge conditions read.

  Why: `form_schema` is rendering only (REQ-273); the only server-side check on a task's output
  variables is `Letflow.Engine.VariableSchema.variable_validations/5`, fed by rows that
  `Letflow.Definitions.register_variable_schemas/3` writes from a `variable_schemas` array on
  POST/PUT /definitions. The QA seed scripts POST the fixture file verbatim (after
  `rewrite_service_task_base`, which only rewrites SERVICE_TASK endpoints), so the fixture IS the
  payload and the schemas live in a top-level `variable_schemas` key of each fixture. Before
  ISS-1027 none carried the key: a typo'd or unexpected decision value completed the task and the
  process silently took a default edge.

  Pure (no DB, no HTTP): `async: true`. Table-driven over ALL shipped process-definition fixtures,
  so a new decision variable added to any gateway edge without a schema fails here.

  What is asserted, per fixture:

    * (D1) every variable an edge condition compares to a string literal has a `variable_schemas`
      entry that is a string enum containing EVERY literal any condition compares it to;
    * (D2) `SemanticValidation.validate/2` against the declared fields is clean -- declaring any
      schema switches REQ-372's field-existence/type checks on at activation, so EVERY variable a
      gateway condition reads (numbers and booleans too) must be declared with a compatible type;
    * (D3) every schema is well-formed (`JsonSchemaShape.check/1`), keys are unique and non-blank;
    * (V1) every enum is a SUPERSET of the values the fixture itself can legitimately set outside
      a human's free choice: `?key=value` stub echoes in SERVICE_TASK endpoints (e.g. the KYC
      timeout stub's `kyc_outcome=unresolved`) and any HUMAN_TASK `form_schema` enum for a declared
      variable (so a form can never offer a value the schema would reject);
    * (V2) every value the shipped UAT scenarios submit for a declared variable is valid.

  Engine note (read, not assumed): SERVICE_TASK result merges pass `nil` validations
  (`Letflow.Engine.advance_service_task_dispatch/4`), so stub/timeout echoes are never rejected at
  runtime; (V1) keeps the enums honest anyway so a later move to validated service merges, or a
  sub-process merge, cannot break a legitimate path.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.{Graph, JsonSchemaShape, SemanticValidation}
  alias Letflow.Engine.VariableSchema

  @qa Path.expand("../../fixtures/qa", __DIR__)
  @scenarios Path.expand("../../fixtures/uat/scenarios", __DIR__)

  # {fixture file, vertical (scenario dir)}
  @decision_fixtures [
    {"meridian_loan_origination_process_definition.json", "meridian"},
    {"meridian_regulatory_compliance_review_process_definition.json", "meridian"},
    {"swiftroute_process_definition.json", "swiftroute"},
    {"vortex_production_order_release_process_definition.json", "vortex"},
    {"vortex_supplier_quality_deviation_process_definition.json", "vortex"}
  ]

  # Fixtures whose shipped UAT scenario submits no declared variable (the BaFin scenario rides the
  # 21-day timer path), so V2 would be vacuous for them -- named, not silently skipped.
  @no_scenario_inputs ["meridian_regulatory_compliance_review_process_definition.json"]

  # Process definitions with NO conditioned edge, hence no decision variable to constrain.
  @no_decision_fixtures ["vortex_8d_corrective_action_definition.json"]

  # Every process-definition fixture in the QA dir (entity/record fixtures are not definitions).
  defp all_process_fixtures do
    @qa
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, "_definition.json"))
    |> Enum.reject(&String.contains?(&1, "_entity_"))
    |> Enum.sort()
  end

  defp doc(file), do: @qa |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp schemas(document), do: document["variable_schemas"] || []

  defp declared(document),
    do: Map.new(schemas(document), &{&1["variable_key"], &1["json_schema"]})

  defp conditions(document) do
    document["graph"]["edges"]
    |> Enum.map(& &1["condition"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # %{variable => MapSet of string literals any condition compares it to with == / !=}.
  # `variables.x != null` / `!= ''` are not literals worth enumerating: '' is the empty-string
  # fail-closed guard (ISS-1020) and is excluded on purpose, null is not matched by the regex.
  defp compared_literals(document) do
    ~r/variables\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:==|!=)\s*'([^']*)'/
    |> then(fn re -> Enum.flat_map(conditions(document), &Regex.scan(re, &1)) end)
    |> Enum.reject(fn [_, _var, literal] -> literal == "" end)
    |> Enum.reduce(%{}, fn [_, var, literal], acc ->
      Map.update(acc, var, MapSet.new([literal]), &MapSet.put(&1, literal))
    end)
  end

  # The engine's own per-key verdict (the function task completion uses), not a re-implementation.
  defp valid?(schema, value),
    do: VariableSchema.validations_for(%{"v" => schema}, ["v"], %{"v" => value}) == %{"v" => :ok}

  describe "risk_rating (open rating scale)" do
    test "keeps 'acceptable' (submitted by the req208 simulation) alongside the form values and 'unacceptable'" do
      enum =
        declared(doc("meridian_loan_origination_process_definition.json"))["risk_rating"]["enum"]

      assert Enum.sort(enum) == Enum.sort(~w(low medium high acceptable unacceptable))
    end
  end

  describe "the fixture set under test" do
    test "every process-definition fixture is either a decision fixture or an explicit no-decision one" do
      known = Enum.map(@decision_fixtures, &elem(&1, 0)) ++ @no_decision_fixtures

      assert all_process_fixtures() -- known == [],
             "a new QA process fixture needs a variable_schemas decision"

      assert known -- all_process_fixtures() == []
    end

    test "no-decision fixtures really carry no conditioned edge (so omitting variable_schemas is correct)" do
      for file <- @no_decision_fixtures do
        assert conditions(doc(file)) == [],
               "#{file} grew an edge condition: give it variable_schemas"
      end
    end
  end

  for {file, vertical} <- @decision_fixtures do
    describe "#{file}" do
      test "D1 every variable compared to a string literal has an enum covering every literal" do
        document = doc(unquote(file))
        declared = declared(document)
        literals = compared_literals(document)

        assert literals != %{}, "fixture compares no variable to a string literal?"

        for {var, lits} <- literals do
          schema = Map.get(declared, var)

          assert is_map(schema),
                 "#{var} is compared to #{inspect(MapSet.to_list(lits))} but has no variable_schemas entry"

          assert schema["type"] == "string", "#{var} schema must be type string"
          assert is_list(schema["enum"]), "#{var} schema must carry an enum"

          missing = MapSet.difference(lits, MapSet.new(schema["enum"]))

          assert MapSet.size(missing) == 0,
                 "#{var} enum #{inspect(schema["enum"])} lacks #{inspect(MapSet.to_list(missing))}"
        end
      end

      test "D2 SemanticValidation is clean: every variable a gateway condition reads is declared, types compatible" do
        document = doc(unquote(file))
        assert {:ok, graph} = Graph.from_map(document["graph"])

        assert %{valid: true, violations: []} =
                 SemanticValidation.validate(graph, declared(document))
      end

      test "D3 schemas are present, well-formed, with unique non-blank keys" do
        document = doc(unquote(file))
        entries = schemas(document)
        assert entries != []

        keys = Enum.map(entries, & &1["variable_key"])
        assert Enum.all?(keys, &(is_binary(&1) and String.trim(&1) != ""))
        assert keys == Enum.uniq(keys)

        for %{"variable_key" => key, "json_schema" => schema} <- entries do
          assert :ok = JsonSchemaShape.check(schema), "#{key}: json_schema is not well-formed"
        end

        # No stray keys on an entry beyond what register_variable_schemas/3 reads.
        for entry <- entries,
            do: assert(Map.keys(entry) -- ["variable_key", "json_schema", "description"] == [])
      end

      test "V1 enums are supersets of stub echoes and form_schema enums in the same fixture" do
        document = doc(unquote(file))
        declared = declared(document)

        # SERVICE_TASK `?key=value` echoes (httpbin response-headers stubs)
        for node <- document["graph"]["nodes"],
            node["node_type"] == "SERVICE_TASK",
            endpoint = get_in(node, ["attributes", "endpoint"]),
            is_binary(endpoint),
            %URI{query: query} = URI.parse(endpoint),
            is_binary(query),
            {key, value} <- URI.decode_query(query),
            schema = Map.get(declared, key) do
          assert valid?(schema, value),
                 "node #{node["id"]} echoes #{key}=#{inspect(value)}, which the #{key} schema would reject"
        end

        # form_schema enums offered by a HUMAN_TASK for a declared variable
        for node <- document["graph"]["nodes"],
            props = get_in(node, ["attributes", "form_schema", "properties"]),
            is_map(props),
            {key, %{"enum" => values}} <- props,
            schema = Map.get(declared, key),
            value <- values do
          assert valid?(schema, value),
                 "node #{node["id"]} form offers #{key}=#{inspect(value)}, which the #{key} schema would reject"
        end
      end

      test "V2 every value the shipped #{vertical} UAT scenarios submit for a declared variable is valid" do
        declared = declared(doc(unquote(file)))

        submitted =
          for path <-
                Path.wildcard(Path.join([@scenarios, unquote(vertical), "*.yaml"]),
                  match_dot: false
                ),
              {:ok, scenario} = YamlElixir.read_from_file(path),
              step <- List.wrap(scenario["steps"]),
              is_map(step["input"]),
              {key, value} <- step["input"],
              schema = Map.get(declared, key) do
            {Path.basename(path), key, value, schema}
          end

        if unquote(file) not in @no_scenario_inputs do
          assert submitted != [],
                 "no scenario input exercises a declared variable: V2 would be vacuous"
        end

        for {scenario, key, value, schema} <- submitted do
          assert valid?(schema, value),
                 "#{scenario}: input #{key}=#{inspect(value)} would be rejected by the #{key} schema"
        end
      end
    end
  end
end
