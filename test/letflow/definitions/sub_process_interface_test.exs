defmodule Letflow.Definitions.SubProcessInterfaceTest do
  @moduledoc """
  Unit tests for `Letflow.Definitions.SubProcessInterface` (REQ-032) — the SPC-02
  (definition-time) half of a `:SUB_PROCESS` node's optional `interface` attribute.
  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this file —
  `async: true` is correct here, same reasoning as `graph_test.exs` (REQ-028/029). Tests
  the module's three public functions directly against bare terms — no `Graph.t()`/
  `Node.t()` construction needed, per the design doc §1/§5.3's stated testability
  rationale. See `test/specs/REQ-032.md` for the full test-case rationale, and
  `test/letflow/definitions/graph_test.exs`'s new "CHK-18" describe block for the
  integration-level proof that this module is actually wired into
  `Graph.validate_node_attributes/1`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.SubProcessInterface

  # ---------------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------------

  # Same "compiled Docs chunk, whitespace-normalised" pattern already established by
  # test/letflow/definitions_test.exs's `normalized_moduledoc/1` and
  # test/letflow/definitions/promotion_review_test.exs — reused verbatim rather than
  # inventing a parallel style, for AC5's moduledoc check below.
  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  # Builds a json_schema nested exactly `n` "items" levels deep, counting the
  # schema itself as level 1 (design doc §6's depth convention: "the entry's own
  # top-level json_schema value is passed at depth = 1"). `nested_schema(1)` is a
  # leaf schema with no recursion; `nested_schema(n)` for n > 1 wraps
  # `nested_schema(n - 1)` one level deeper via `"items"`.
  #
  # Hand-traced: `validate_schema_shape(nested_schema(n), 1)` makes its deepest
  # recursive call at `depth = n` (each "items" descent increments depth by 1,
  # starting from the top-level call at depth 1). So `nested_schema(32)` is the
  # exact maximum-accepted-depth fixture (deepest call at depth 32, `32 > 32` is
  # false) and `nested_schema(33)` is the exact one-level-too-deep fixture
  # (deepest call at depth 33, `33 > 32` is true -> `false` at that call,
  # propagating back up through every `Enum.all?`/`is_map` check above it).
  defp nested_schema(1), do: %{"type" => "string"}
  defp nested_schema(n) when n > 1, do: %{"items" => nested_schema(n - 1)}

  # ---------------------------------------------------------------------------------
  # AC1: "a SUB_PROCESS node with a well-formed interface (valid inputs/outputs,
  # well-formed json_schema on each entry) passes validation and is persisted
  # unchanged as part of the node's attributes"
  #
  # The "persisted unchanged" half is proven at the Graph/CHK-18 integration level
  # (graph_test.exs) since persistence is outside this module's own I/O-free scope
  # (design doc §5.4) -- this describe block proves the "passes validation" half:
  # parse_interface/2 returns zero violations and the expected parsed shape.
  # ---------------------------------------------------------------------------------

  describe "parse_interface/2 -- AC1: interface_value absent" do
    test "nil (the interface attribute absent entirely) is valid, not a violation" do
      # Design doc §5.3 step 1: this is the one CHK-01..18 case (across this whole
      # validator family) where "attribute entirely absent" is legal, not a
      # violation, since `interface` is optional for SUB_PROCESS. Contrast with the
      # SUB_PROCESS_INTERFACE_NOT_OBJECT tests below, where the attribute IS present
      # but has the wrong shape.
      assert SubProcessInterface.parse_interface("sp1", nil) == {nil, []}
    end
  end

  describe "parse_interface/2 -- AC1: a well-formed interface passes validation" do
    test "valid inputs/outputs with well-formed json_schema on each entry -> zero violations, expected parsed shape" do
      interface = %{
        "inputs" => [
          %{"name" => "amount", "json_schema" => %{"type" => "number", "minimum" => 0}},
          %{
            "name" => "note",
            "json_schema" => %{"type" => "string", "$ref" => "#/definitions/freeText"},
            "required" => true
          }
        ],
        "outputs" => [
          %{"name" => "confirmation", "json_schema" => %{"type" => "boolean"}}
        ]
      }

      assert SubProcessInterface.parse_interface("sp1", interface) ==
               {%{
                  inputs: [
                    %{
                      name: "amount",
                      json_schema: %{"type" => "number", "minimum" => 0},
                      required: false
                    },
                    %{
                      name: "note",
                      json_schema: %{"type" => "string", "$ref" => "#/definitions/freeText"},
                      required: true
                    }
                  ],
                  outputs: [
                    %{name: "confirmation", json_schema: %{"type" => "boolean"}, required: false}
                  ]
                }, []}
    end

    test "an interface with both 'inputs' and 'outputs' absent (empty object) is well-formed -- zero violations, empty lists" do
      assert SubProcessInterface.parse_interface("sp1", %{}) == {%{inputs: [], outputs: []}, []}
    end
  end

  describe "parse_interface/2 -- 'required' defaults to false when absent (design doc §5.3.1 point 2)" do
    test "an entry with no 'required' key parses with required: false" do
      {parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{
          "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
        })

      assert violations == []

      assert parsed.inputs == [
               %{name: "amount", json_schema: %{"type" => "number"}, required: false}
             ]
    end

    test "an entry with 'required': true is not overridden by the default" do
      {parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{
          "inputs" => [
            %{"name" => "amount", "json_schema" => %{"type" => "number"}, "required" => true}
          ]
        })

      assert violations == []
      assert [%{required: true}] = parsed.inputs
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2, code 1/6: SUB_PROCESS_INTERFACE_NOT_OBJECT
  # ---------------------------------------------------------------------------------

  describe "parse_interface/2 -- AC2: SUB_PROCESS_INTERFACE_NOT_OBJECT" do
    test "interface_value present but not a JSON object -> :sub_process_interface_not_object, and only that code" do
      for value <- ["not an object", 42, true, false, ["a", "list"]] do
        {parsed, violations} = SubProcessInterface.parse_interface("sp1", value)

        assert parsed == nil

        assert Enum.map(violations, & &1.code) == [:sub_process_interface_not_object],
               "expected :sub_process_interface_not_object for #{inspect(value)}, got #{inspect(Enum.map(violations, & &1.code))}"

        [violation] = violations
        assert violation.message =~ "sp1"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2, codes 2/6 and 3/6: SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY / _OUTPUTS_NOT_ARRAY
  # ---------------------------------------------------------------------------------

  describe "parse_interface/2 -- AC2: SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY / _OUTPUTS_NOT_ARRAY" do
    test "'inputs' present but not a JSON array -> :sub_process_interface_inputs_not_array, and only that code" do
      {parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{"inputs" => "not-a-list"})

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_inputs_not_array]
      # inputs is skipped entirely per §5.3 step 3b; outputs (absent) defaults to [].
      assert parsed == %{inputs: [], outputs: []}
    end

    test "'outputs' present but not a JSON array -> :sub_process_interface_outputs_not_array, and only that code" do
      {parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{"outputs" => %{"not" => "a list"}})

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_outputs_not_array]
      assert parsed == %{inputs: [], outputs: []}
    end

    test "both 'inputs' and 'outputs' non-array at once -> both codes fire, never-short-circuit (design doc §5.3 step 3b)" do
      {_parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{"inputs" => "x", "outputs" => 1})

      assert Enum.map(violations, & &1.code) == [
               :sub_process_interface_inputs_not_array,
               :sub_process_interface_outputs_not_array
             ]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2, code 4/6: SUB_PROCESS_INTERFACE_ENTRY_INVALID
  # ---------------------------------------------------------------------------------

  describe "parse_interface/2 -- AC2: SUB_PROCESS_INTERFACE_ENTRY_INVALID" do
    test "every distinct entry-shape defect -> :sub_process_interface_entry_invalid, and only that code" do
      malformed_entries = [
        "not a map",
        %{},
        %{"name" => "", "json_schema" => %{}},
        %{"name" => "   ", "json_schema" => %{}},
        %{"name" => 42, "json_schema" => %{}},
        %{"name" => "amount"},
        %{"name" => "amount", "json_schema" => "not-a-map"},
        %{"name" => "amount", "json_schema" => %{}, "required" => "yes"}
      ]

      for entry <- malformed_entries do
        {_parsed, violations} =
          SubProcessInterface.parse_interface("sp1", %{"inputs" => [entry]})

        assert Enum.map(violations, & &1.code) == [:sub_process_interface_entry_invalid],
               "expected :sub_process_interface_entry_invalid for #{inspect(entry)}, got #{inspect(Enum.map(violations, & &1.code))}"
      end
    end

    test "an entry that fails the shape check is excluded from the parsed entry list" do
      {parsed, _violations} =
        SubProcessInterface.parse_interface("sp1", %{
          "inputs" => [%{"name" => "", "json_schema" => %{}}]
        })

      assert parsed.inputs == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2, code 5/6: SUB_PROCESS_INTERFACE_SCHEMA_INVALID
  # ---------------------------------------------------------------------------------

  describe "parse_interface/2 -- AC2: SUB_PROCESS_INTERFACE_SCHEMA_INVALID" do
    test "shape-valid entry with a malformed json_schema -> :sub_process_interface_schema_invalid, entry still included in parsed output" do
      # Design doc §5.3.1 point 2: _SCHEMA_INVALID is exclusive of _ENTRY_INVALID and
      # the entry IS still returned in the parsed list (its tuple shape is valid,
      # only the nested schema failed) -- this is the assertion that would fail if a
      # future change wrongly excluded schema-invalid entries like shape-invalid ones.
      schema = %{"minimum" => "not-a-number"}

      {parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{
          "inputs" => [%{"name" => "amount", "json_schema" => schema}]
        })

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_schema_invalid]
      assert parsed.inputs == [%{name: "amount", json_schema: schema, required: false}]

      [violation] = violations
      assert violation.message =~ "amount"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2, code 6/6: SUB_PROCESS_INTERFACE_DUPLICATE_NAME
  # ---------------------------------------------------------------------------------

  describe "parse_interface/2 -- AC2: SUB_PROCESS_INTERFACE_DUPLICATE_NAME" do
    test "a name repeated within 'inputs' -> :sub_process_interface_duplicate_name, N occurrences -> N-1 violations" do
      # Same "N occurrences -> N-1 violations, reported on each repeat" convention as
      # CHK-05/CHK-16 (design doc §5.3.2) -- 3 occurrences here to strengthen beyond
      # the minimal 2-occurrence case (mirrors REQ-029's own 3-default-edges test).
      interface = %{
        "inputs" => [
          %{"name" => "amount", "json_schema" => %{"type" => "number"}},
          %{"name" => "amount", "json_schema" => %{"type" => "string"}},
          %{"name" => "amount", "json_schema" => %{"type" => "boolean"}}
        ]
      }

      {_parsed, violations} = SubProcessInterface.parse_interface("sp1", interface)

      assert Enum.map(violations, & &1.code) == [
               :sub_process_interface_duplicate_name,
               :sub_process_interface_duplicate_name
             ]
    end

    test "a name repeated within 'outputs' -> :sub_process_interface_duplicate_name" do
      interface = %{
        "outputs" => [
          %{"name" => "result", "json_schema" => %{"type" => "string"}},
          %{"name" => "result", "json_schema" => %{"type" => "string"}}
        ]
      }

      {_parsed, violations} = SubProcessInterface.parse_interface("sp1", interface)

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_duplicate_name]
    end

    test "the same name in both 'inputs' and 'outputs' is NOT a duplicate -- namespaces are independent (design doc §5.3.2)" do
      interface = %{
        "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}],
        "outputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
      }

      assert {_parsed, []} = SubProcessInterface.parse_interface("sp1", interface)
    end

    test "an entry excluded for _ENTRY_INVALID never participates in duplicate-name detection (no reliable name to dedupe against)" do
      interface = %{
        "inputs" => [
          %{"name" => "amount", "json_schema" => %{"type" => "number"}},
          %{"name" => "", "json_schema" => %{"type" => "number"}}
        ]
      }

      {_parsed, violations} = SubProcessInterface.parse_interface("sp1", interface)

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_entry_invalid]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: "an interface entry's json_schema containing an unsupported-but-recognized-
  # as-inert keyword (e.g. $ref or pattern) is accepted, not rejected"
  # ---------------------------------------------------------------------------------

  describe "validate_schema_shape/2 -- AC3: unsupported keywords are permitted and inert" do
    test "the design doc §6 worked example ($ref/pattern on a nested schema) is accepted" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "number", "minimum" => 0},
          "note" => %{
            "type" => "string",
            "$ref" => "#/definitions/freeText",
            "pattern" => "^.*$"
          }
        },
        "required" => ["amount"],
        "additionalProperties" => false
      }

      assert SubProcessInterface.validate_schema_shape(schema, 1) == true
    end

    test "a schema consisting entirely of unsupported keywords is accepted (nothing left to fail)" do
      assert SubProcessInterface.validate_schema_shape(
               %{"$ref" => "#/foo", "pattern" => "^x$", "allOf" => [%{"whatever" => true}]},
               1
             ) == true
    end

    test "end-to-end: an interface entry whose json_schema uses only inert unknown keywords produces zero violations" do
      interface = %{
        "inputs" => [
          %{"name" => "note", "json_schema" => %{"$ref" => "#/foo", "pattern" => "^x$"}}
        ]
      }

      assert {_parsed, []} = SubProcessInterface.parse_interface("sp1", interface)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4: "a json_schema nested beyond the 32-level recursion cap is rejected as
  # malformed" -- exact 32-deep (accepted) / 33-deep (rejected) boundary pair, per
  # design doc §6's precise depth-numbering convention.
  # ---------------------------------------------------------------------------------

  describe "validate_schema_shape/2 -- AC4: the 32-level recursion depth-cap boundary" do
    test "a schema nested exactly 32 levels deep is accepted -- the maximum accepted depth" do
      assert SubProcessInterface.validate_schema_shape(nested_schema(32), 1) == true
    end

    test "a schema nested 33 levels deep is rejected -- one level beyond the cap" do
      assert SubProcessInterface.validate_schema_shape(nested_schema(33), 1) == false
    end

    test "depth > 32 rejects immediately regardless of schema content, even an otherwise-trivial schema" do
      # Exercises design doc §6 step 1 (the depth guard) directly and independently
      # of the recursive-building helper above -- a call already past the cap must
      # never even inspect `schema`.
      assert SubProcessInterface.validate_schema_shape(%{}, 33) == false
      assert SubProcessInterface.validate_schema_shape(%{"type" => "string"}, 33) == false
    end

    test "end-to-end: an entry with a 33-deep json_schema -> :sub_process_interface_schema_invalid" do
      {parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{
          "inputs" => [%{"name" => "deep", "json_schema" => nested_schema(33)}]
        })

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_schema_invalid]
      # Shape-valid, schema-invalid entries are still included in the parsed output
      # (same rule as the SCHEMA_INVALID describe block above).
      assert [%{name: "deep"}] = parsed.inputs
    end

    test "end-to-end: an entry with a 32-deep json_schema produces zero violations" do
      {_parsed, violations} =
        SubProcessInterface.parse_interface("sp1", %{
          "inputs" => [%{"name" => "deep", "json_schema" => nested_schema(32)}]
        })

      assert violations == []
    end
  end

  # ---------------------------------------------------------------------------------
  # Design doc §6's full 10-entry supported-keyword table (REQ-032's own text groups
  # minimum/maximum and minLength/maxLength as single "/"-paired items, for 8 named
  # groups; the implementation validates each of the 10 underlying keys
  # independently) -- each accepted at least once, and (going one step further than
  # "accepted at least once" to actually pin each keyword's own rule) each rejected
  # at least once for a malformed value.
  # ---------------------------------------------------------------------------------

  describe "validate_schema_shape/2 -- the full supported-keyword set" do
    @valid_keyword_schemas %{
      "type" => %{"type" => "string"},
      "minimum" => %{"minimum" => 0},
      "maximum" => %{"maximum" => 100},
      "minLength" => %{"minLength" => 0},
      "maxLength" => %{"maxLength" => 255},
      "enum" => %{"enum" => ["a", "b", "c"]},
      "required (meta-keyword)" => %{"required" => ["a"]},
      "properties" => %{"properties" => %{"x" => %{"type" => "string"}}},
      "items" => %{"items" => %{"type" => "number"}},
      "additionalProperties (boolean)" => %{"additionalProperties" => false},
      "additionalProperties (schema)" => %{"additionalProperties" => %{"type" => "string"}}
    }

    test "each supported keyword is individually accepted with a well-formed value" do
      for {label, schema} <- @valid_keyword_schemas do
        assert SubProcessInterface.validate_schema_shape(schema, 1) == true,
               "expected #{label} to be accepted for #{inspect(schema)}"
      end
    end

    @invalid_keyword_schemas %{
      "type (empty string)" => %{"type" => ""},
      "type (non-string)" => %{"type" => 5},
      "minimum (non-number)" => %{"minimum" => "not-a-number"},
      "maximum (non-number)" => %{"maximum" => "not-a-number"},
      "minLength (negative)" => %{"minLength" => -1},
      "maxLength (negative)" => %{"maxLength" => -1},
      "enum (non-list)" => %{"enum" => "not-a-list"},
      "required (non-string element)" => %{"required" => [1, 2]},
      "properties (non-schema value)" => %{"properties" => %{"x" => "not-a-schema"}},
      "items (non-schema)" => %{"items" => "not-a-schema"},
      "additionalProperties (neither boolean nor map)" => %{
        "additionalProperties" => "not-boolean-or-map"
      }
    }

    test "each supported keyword individually rejects a malformed value" do
      for {label, schema} <- @invalid_keyword_schemas do
        refute SubProcessInterface.validate_schema_shape(schema, 1),
               "expected #{label} to be rejected for #{inspect(schema)}"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # validate_node_interface/2 -- the CHK-18 entry point itself, tested directly
  # (integration through Graph.validate_node_attributes/1 lives in graph_test.exs)
  # ---------------------------------------------------------------------------------

  describe "validate_node_interface/2 -- check-list entry point" do
    test "attributes: nil -> no violations (interface is optional, absent attributes is not itself an error)" do
      assert SubProcessInterface.validate_node_interface("sp1", nil) == []
    end

    test "attributes without an 'interface' key -> no violations" do
      assert SubProcessInterface.validate_node_interface("sp1", %{"other" => "stuff"}) == []
    end

    test "attributes that is not a map at all -> treated as interface absent, no violations (defensive, never raises)" do
      assert SubProcessInterface.validate_node_interface("sp1", "not-a-map") == []
    end

    test "a well-formed interface attribute -> no violations" do
      attributes = %{
        "interface" => %{
          "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
        }
      }

      assert SubProcessInterface.validate_node_interface("sp1", attributes) == []
    end

    test "a malformed interface attribute -> the violation list only (not the parsed data)" do
      violations = SubProcessInterface.validate_node_interface("sp1", %{"interface" => "bad"})

      assert Enum.map(violations, & &1.code) == [:sub_process_interface_not_object]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5: "the moduledoc explicitly states SPC-01 (runtime activation/completion
  # helpers) is out of this requirement's scope and belongs to S3, naming
  # src/engine/instance.zig as SPC-01's future integration point"
  # ---------------------------------------------------------------------------------

  describe "AC5 -- moduledoc states SPC-01 is out of scope, belonging to S3" do
    test "the moduledoc states SPC-01 is explicitly out of this module's scope" do
      doc = normalized_moduledoc(SubProcessInterface)

      assert doc =~ "SPC-01 is explicitly out of this module's scope",
             "moduledoc does not explicitly flag SPC-01 as out of scope"
    end

    test "the moduledoc names Stage 3 and src/engine/instance.zig as SPC-01's future home/integration point" do
      doc = normalized_moduledoc(SubProcessInterface)

      assert doc =~ "Stage 3", "moduledoc does not name Stage 3 as SPC-01's future stage"

      assert doc =~ "src/engine/instance.zig",
             "moduledoc does not name src/engine/instance.zig as SPC-01's integration point"
    end

    test "the moduledoc states this module ports only the SPC-02 (definition-time) half" do
      doc = normalized_moduledoc(SubProcessInterface)

      assert doc =~ "ports only the SPC-02 (definition-time) half",
             "moduledoc does not scope this module to the SPC-02 half only"
    end
  end
end
