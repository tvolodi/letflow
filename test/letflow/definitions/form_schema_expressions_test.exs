defmodule Letflow.Definitions.FormSchemaExpressionsTest do
  @moduledoc """
  Unit tests for `Letflow.Definitions.FormSchemaExpressions` (REQ-291) — the
  definition-time validator for the `x-ui.visible_when`/`x-ui.computed`/
  `x-ui.cross_field_validation` form-field logic keys REQ-291 adds to the
  `x-ui` vocabulary REQ-284 established. Pure module, no `Letflow.Repo`/
  `Ecto.Sandbox` dependency anywhere in this file — `async: true` is correct
  here, same reasoning as `sub_process_interface_test.exs` (REQ-032). Tests
  the module's public entry point directly against bare `attributes` maps —
  no `Graph.t()`/`Node.t()` construction needed. See
  `lib/letflow/design/req291-x-ui-logic-keys.md` §7 for the test-to-AC
  mapping this file follows. `test/letflow/definitions/graph_test.exs`'s
  "CHK-20" describe block is the integration-level proof that this module is
  actually wired into `Graph.validate_node_attributes/1`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.FormSchemaExpressions

  # ---------------------------------------------------------------------------------
  # Fixture builders
  # ---------------------------------------------------------------------------------

  defp attributes(properties) do
    %{"form_schema" => %{"type" => "object", "properties" => properties}}
  end

  defp prop(type), do: %{"type" => type}
  defp prop(type, x_ui), do: %{"type" => type, "x-ui" => x_ui}

  defp codes(violations), do: Enum.map(violations, & &1.code)

  # ---------------------------------------------------------------------------------
  # Baseline: absent keys / no form_schema / non-HUMAN_TASK-relevant shapes
  # ---------------------------------------------------------------------------------

  describe "validate_node_form_schema/2 -- baseline (no logic keys present)" do
    test "attributes is nil -> []" do
      assert FormSchemaExpressions.validate_node_form_schema("n1", nil) == []
    end

    test "attributes has no form_schema key -> []" do
      assert FormSchemaExpressions.validate_node_form_schema("n1", %{"role" => "manager"}) == []
    end

    test "form_schema with properties but no x-ui logic keys on any field -> []" do
      attrs = attributes(%{"amount" => prop("number"), "note" => prop("string")})
      assert FormSchemaExpressions.validate_node_form_schema("n1", attrs) == []
    end

    test "form_schema that fails JsonSchemaShape.check/1 -> [] (that failure is REQ-273's activation-time concern)" do
      attrs = %{"form_schema" => "not-an-object"}
      assert FormSchemaExpressions.validate_node_form_schema("n1", attrs) == []
    end

    test "a well-formed visible_when/computed/cross_field_validation on in-scope fields -> []" do
      attrs =
        attributes(%{
          "amount" => prop("number", %{"computed" => "1 + 1"}),
          "note" => prop("string", %{"visible_when" => "amount > 0"}),
          "confirm" =>
            prop("boolean", %{
              "cross_field_validation" => %{
                "expression" => "amount > 0",
                "message" => "amount must be positive"
              }
            })
        })

      assert FormSchemaExpressions.validate_node_form_schema("n1", attrs) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: syntactically invalid expression per key -- 3 SEPARATE tests
  # ---------------------------------------------------------------------------------

  describe "AC2 -- a syntactically invalid expression is rejected at definition time, one test per key" do
    test "visible_when with an unbalanced paren -> :form_schema_expression_invalid naming the field" do
      attrs =
        attributes(%{
          "amount" => prop("number"),
          "note" => prop("string", %{"visible_when" => "amount > (1000"})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_expression_invalid]
      assert Enum.at(violations, 0).message =~ "'note'"
      assert Enum.at(violations, 0).message =~ "visible_when"
    end

    test "computed using an unsupported CEL construct -> :form_schema_expression_invalid naming the field" do
      attrs =
        attributes(%{
          "x" => prop("string"),
          "amount" => prop("number", %{"computed" => "has(x)"})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_expression_invalid]
      assert Enum.at(violations, 0).message =~ "'amount'"
      assert Enum.at(violations, 0).message =~ "computed"
    end

    test "cross_field_validation.expression with a bare trailing operator -> :form_schema_expression_invalid naming the field" do
      attrs =
        attributes(%{
          "amount" => prop("number"),
          "confirm" =>
            prop("boolean", %{
              "cross_field_validation" => %{"expression" => "amount >", "message" => "bad"}
            })
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_expression_invalid]
      assert Enum.at(violations, 0).message =~ "'confirm'"
      assert Enum.at(violations, 0).message =~ "cross_field_validation"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: variable scope -- no "variables." prefix, flat sibling-properties-key scope
  # (also the checkable half of AC8, D1a's "may not reference anything the client
  # wasn't given" -- same test satisfies both readings, per the design doc §7 table)
  # ---------------------------------------------------------------------------------

  describe "AC3/AC8 -- an expression referencing a name outside the flat top-level scope is rejected" do
    test "a name absent from form_schema.properties -> :form_schema_expression_out_of_scope naming the field and the undeclared variable" do
      attrs =
        attributes(%{
          "amount" =>
            prop("number", %{"visible_when" => "other_form_field_that_does_not_exist > 5"})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_expression_out_of_scope]
      [violation] = violations
      assert violation.message =~ "'amount'"
      assert violation.message =~ "other_form_field_that_does_not_exist"
    end

    test "a dotted, multi-segment path is always out of scope, even when its first segment is in-scope" do
      # `translate_cel_to_expr/1` strips a literal "variables." prefix
      # unconditionally, so "variables.amount" would collapse to the
      # in-scope bare "amount" -- not a useful fixture for this rule.
      # "amount.sub" has no such prefix and tokenizes as the 2-segment
      # {:var, ["amount", "sub"]}, which is out of scope unconditionally
      # regardless of whether "amount" itself is a declared property.
      attrs =
        attributes(%{
          "amount" => prop("number"),
          "note" => prop("string", %{"visible_when" => "amount.sub > 0"})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_expression_out_of_scope]
      [violation] = violations
      assert violation.message =~ "'note'"
      assert violation.message =~ "amount.sub"
    end

    test "a bare in-scope sibling field name is accepted (no 'variables.' prefix required)" do
      attrs =
        attributes(%{
          "amount" => prop("number"),
          "note" => prop("string", %{"visible_when" => "amount > 0"})
        })

      assert FormSchemaExpressions.validate_node_form_schema("n1", attrs) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4: absent/null input to computed -- single stated behaviour (§4.3, not executed
  # here since no evaluator is in this requirement's scope) -- accessor unit test.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- computed field absent/null input: single pinned behaviour" do
    test "computed_field_absent_or_null_input_result/0 == :nil_value" do
      assert FormSchemaExpressions.computed_field_absent_or_null_input_result() == :nil_value
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5: computed-field reference cycle rejected -- 2-node and 3-node, plus a
  # non-cyclic diamond DAG negative test proving no false positive.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- computed-field dependency cycles are rejected at definition time" do
    test "a 2-node cycle (fieldA <-> fieldB) -> exactly one :form_schema_computed_field_cycle violation naming both fields" do
      attrs =
        attributes(%{
          "fieldA" => prop("string", %{"computed" => "fieldB"}),
          "fieldB" => prop("string", %{"computed" => "fieldA"})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_computed_field_cycle]
      [violation] = violations
      assert violation.message =~ "fieldA"
      assert violation.message =~ "fieldB"
    end

    test "a 3-node cycle (fieldA -> fieldB -> fieldC -> fieldA) -> exactly one violation naming all three fields" do
      attrs =
        attributes(%{
          "fieldA" => prop("string", %{"computed" => "fieldB"}),
          "fieldB" => prop("string", %{"computed" => "fieldC"}),
          "fieldC" => prop("string", %{"computed" => "fieldA"})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_computed_field_cycle]
      [violation] = violations
      assert violation.message =~ "fieldA"
      assert violation.message =~ "fieldB"
      assert violation.message =~ "fieldC"
    end

    test "a self-reference (fieldA computed from itself) -> rejected by the same DFS check, not a special case" do
      attrs = attributes(%{"fieldA" => prop("string", %{"computed" => "fieldA"})})

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)

      assert codes(violations) == [:form_schema_computed_field_cycle]
    end

    test "a diamond DAG (fieldA/fieldB both computed from fieldC, fieldD computed from both) is NOT flagged as a cycle" do
      attrs =
        attributes(%{
          "fieldC" => prop("number"),
          "fieldA" => prop("number", %{"computed" => "fieldC"}),
          "fieldB" => prop("number", %{"computed" => "fieldC"}),
          "fieldD" => prop("number", %{"computed" => "fieldA + fieldB"})
        })

      assert FormSchemaExpressions.validate_node_form_schema("n1", attrs) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6: submit disposition for hidden/computed field values -- accessor unit tests.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- submit disposition: both hidden and computed field values are submitted, not dropped" do
    test "hidden_field_submit_disposition/0 == :submitted_as_untrusted_input" do
      assert FormSchemaExpressions.hidden_field_submit_disposition() ==
               :submitted_as_untrusted_input
    end

    test "computed_field_submit_disposition/0 == :submitted_as_untrusted_input" do
      assert FormSchemaExpressions.computed_field_submit_disposition() ==
               :submitted_as_untrusted_input
    end
  end

  # ---------------------------------------------------------------------------------
  # Malformed key shape (:form_schema_x_ui_logic_malformed) -- supporting coverage,
  # not a distinct acceptance criterion of its own but part of §4.1's shape table.
  # ---------------------------------------------------------------------------------

  describe "malformed x-ui logic key shape -- :form_schema_x_ui_logic_malformed" do
    test "x-ui.visible_when present but not a string" do
      attrs = attributes(%{"amount" => prop("number", %{"visible_when" => 123})})

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)
      assert codes(violations) == [:form_schema_x_ui_logic_malformed]
      assert Enum.at(violations, 0).message =~ "'amount'"
    end

    test "x-ui.computed present but not a string" do
      attrs = attributes(%{"amount" => prop("number", %{"computed" => true})})

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)
      assert codes(violations) == [:form_schema_x_ui_logic_malformed]
    end

    test "x-ui.cross_field_validation present but not a map" do
      attrs = attributes(%{"amount" => prop("number", %{"cross_field_validation" => "nope"})})

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)
      assert codes(violations) == [:form_schema_x_ui_logic_malformed]
    end

    test "x-ui.cross_field_validation missing 'message'" do
      attrs =
        attributes(%{
          "amount" =>
            prop("number", %{"cross_field_validation" => %{"expression" => "amount > 0"}})
        })

      violations = FormSchemaExpressions.validate_node_form_schema("n1", attrs)
      assert codes(violations) == [:form_schema_x_ui_logic_malformed]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1/AC3/AC4/AC6/AC7 (doc-content half): docs/frontend/x-ui-widget-vocabulary.md
  # gains the 3 keys, states each pinned semantic in prose, and the former
  # "deferred" heading points at REQ-291 as the resolution, not a re-deferral.
  # Pattern precedented by test/letflow/engine/service_task_wiring_test.exs's own
  # File.read!/1-based doc-content assertions.
  # ---------------------------------------------------------------------------------

  describe "docs/frontend/x-ui-widget-vocabulary.md -- REQ-291 doc-content assertions" do
    setup do
      doc =
        File.read!(Path.join(File.cwd!(), "docs/frontend/x-ui-widget-vocabulary.md"))

      {:ok, doc: doc}
    end

    test "the old 'Field logic is deferred, not rejected' heading is gone", %{doc: doc} do
      refute doc =~ "Field logic is deferred, not rejected"
    end

    test "the new §6 heading names REQ-291 as the resolution, and REQ-291 is referenced", %{
      doc: doc
    } do
      assert doc =~ "visible_when"
      assert doc =~ "computed"
      assert doc =~ "cross-field validation"
      assert doc =~ "REQ-291"
    end

    test "the scope/prefix rule is stated: no 'variables.' prefix, flat sibling-properties scope only",
         %{doc: doc} do
      assert doc =~ "variables."
      assert doc =~ "top-level keys of the same"
      assert doc =~ "multi-segment"
    end

    test "the absent/null-input decision states a single value (nil), not a range", %{doc: doc} do
      assert doc =~ "evaluates to `nil`, uniformly"
      assert doc =~ "not a per-cause table"
    end

    test "the submit-disposition decision is stated explicitly for both hidden and computed fields",
         %{doc: doc} do
      assert doc =~ "input to be checked"
      assert doc =~ "are submitted, not dropped"
    end

    test "the security boundary is stated, citing record 0020 D1a", %{doc: doc} do
      assert doc =~ "UX affordance only, never access control" or doc =~ "UX affordance only"
      assert doc =~ "0020"
      assert doc =~ "D1a"
      assert doc =~ "omitted from the schema entirely"
    end

    test "the four new Violation.code() atoms and the validator module are named", %{doc: doc} do
      assert doc =~ "Letflow.Definitions.FormSchemaExpressions"
      assert doc =~ ":form_schema_x_ui_logic_malformed"
      assert doc =~ ":form_schema_expression_invalid"
      assert doc =~ ":form_schema_expression_out_of_scope"
      assert doc =~ ":form_schema_computed_field_cycle"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9/AC10 (repo-level facts, not unit tests): expr.ex/web/ untouched -- verified
  # via git diff at implementation-report time, not asserted here.
  # ---------------------------------------------------------------------------------
end
