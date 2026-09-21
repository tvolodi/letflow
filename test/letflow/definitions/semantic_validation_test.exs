defmodule Letflow.Definitions.SemanticValidationTest do
  @moduledoc """
  Pure, no-I/O unit tests for REQ-372's `Letflow.Definitions.SemanticValidation`:
  `validate/2` (field-existence + type-compatibility checks over an `EXCLUSIVE_GATEWAY`
  edge's parsed condition), `levenshtein_distance/2`, and `nearest_declared_field/2`. See
  `test/specs/REQ-372.md` for the full per-test rationale and the WF-02 Step 3 scope-test
  verdict.

  `async: true` is safe here: `SemanticValidation.validate/2` is pure (no `Letflow.Repo`,
  no clock, no I/O of any kind — see the module's own moduledoc "Purity" section), same
  as `Letflow.Definitions.Graph`'s own `test/letflow/definitions/graph_test.exs`, whose
  fixture-builder style (`node/2`, `edge/3`/`cond_edge/5`, `graph/2`) this file mirrors
  directly rather than inventing a parallel convention.

  The DB-backed half of REQ-372's coverage — AC6, "re-runs in full, never a cached prior
  result, at the definition's actual release/promotion submission call path" — needs a
  real `activate/2` call against a real tenant schema and lives in
  `test/letflow/definitions/semantic_validation_activation_test.exs`, which uses
  `Letflow.DataCase` (mirrors the pure-vs-DB-backed split `definitions_test.exs` and
  `store_test.exs` already established for REQ-030/REQ-041).

  Every test builds its own `Graph.t()`/`declared_fields()` fixture inline or via this
  file's own tiny helpers — no shared hardcoded ids, no execution-order dependency, no
  wall-clock/unseeded-randomness dependence (`docs/guides/test_developer_guide.md` §1).
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}
  alias Letflow.Definitions.SemanticValidation

  # ---------------------------------------------------------------------------------
  # Fixture builders -- mirrors graph_test.exs's node/2, edge/3, graph/2 exactly, plus
  # a cond_edge/5 for a gateway edge carrying a condition (same shape as graph_test.exs's
  # own cond_edge/5, reimplemented here rather than imported since these are two
  # independent test modules).
  # ---------------------------------------------------------------------------------

  defp node(id, type), do: %Node{id: id, node_type: type}

  defp cond_edge(id, source, target, condition) do
    %Edge{id: id, source: source, target: target, condition: condition}
  end

  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}

  # A minimal graph shape used by most tests below: one EXCLUSIVE_GATEWAY node
  # ("gw") with one outgoing conditional edge ("e1") to an END node ("t"), plus a
  # second unconditional default-shaped edge is NOT needed here -- SemanticValidation
  # doesn't care about CHK-15/CHK-16's default-edge rules, it only walks whatever
  # EXCLUSIVE_GATEWAY-sourced edges carry a non-blank condition, per its own moduledoc
  # "Edge selection" note (mirrors Graph's CHK-13/CHK-17 selection exactly).
  defp gateway_graph(condition) do
    graph(
      [node("gw", :EXCLUSIVE_GATEWAY), node("t", :END)],
      [cond_edge("e1", "gw", "t", condition)]
    )
  end

  defp field(type), do: %{"type" => type}

  defp codes(%{violations: violations}), do: Enum.map(violations, & &1.code)
  defp messages(%{violations: violations}), do: Enum.map(violations, & &1.message)

  # ---------------------------------------------------------------------------------
  # AC1 -- undeclared-variable-reference violation names the exact typed variable
  # name and the step/edge it belongs to.
  # ---------------------------------------------------------------------------------

  describe "validate/2 (AC1) -- undeclared variable reference names the exact typed variable and its edge/step" do
    test "a gateway edge condition referencing a variable absent from declared_fields produces :undeclared_variable_reference naming the edge id, source node id, and the exact typed variable name" do
      declared_fields = %{"customer_name" => field("string")}
      graph = gateway_graph("cusotmer_name == \"John\"")

      result = SemanticValidation.validate(graph, declared_fields)

      assert result.valid == false
      assert codes(result) == [:undeclared_variable_reference]

      [message] = messages(result)
      # exact typed variable name, verbatim as authored (not corrected/normalized)
      assert message =~ "references undeclared variable 'cusotmer_name'"
      # the step/edge it belongs to
      assert message =~ "Edge 'e1'"
      assert message =~ "EXCLUSIVE_GATEWAY node 'gw'"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- the violation's suggested nearest declared field name, computed by a real
  # string-distance measure, proven with a clear one-typo case.
  # ---------------------------------------------------------------------------------

  describe "validate/2 (AC2) -- suggested nearest declared field name via real string-distance" do
    test "'cusotmer_name' typed against a declared 'customer_name' field suggests 'customer_name' by name in the violation message" do
      declared_fields = %{"customer_name" => field("string"), "amount" => field("number")}
      graph = gateway_graph("cusotmer_name == \"John\"")

      result = SemanticValidation.validate(graph, declared_fields)

      [message] = messages(result)
      assert message =~ "nearest declared field: 'customer_name'"
    end

    test "with zero declared fields, no suggestion clause is emitted at all (nearest_declared_field/2 has nothing to suggest)" do
      graph = gateway_graph("cusotmer_name == \"John\"")

      result = SemanticValidation.validate(graph, %{})

      [message] = messages(result)
      refute message =~ "nearest declared field"
    end
  end

  describe "levenshtein_distance/2 and nearest_declared_field/2 (AC2) -- real edit-distance measure, not a placeholder or first-alphabetical fallback" do
    test "levenshtein_distance/2 computes the real Wagner-Fischer edit distance, not a constant or a length difference" do
      assert SemanticValidation.levenshtein_distance("cusotmer_name", "customer_name") == 2
      assert SemanticValidation.levenshtein_distance("kitten", "sitting") == 3
      assert SemanticValidation.levenshtein_distance("same", "same") == 0
      assert SemanticValidation.levenshtein_distance("", "abc") == 3
    end

    test "levenshtein_distance/2 is case-sensitive by design (case-only differences are real substitutions, not zero)" do
      # "Customer_Name" vs "customer_name" differ at 'C'/'c' and 'N'/'n' -- 2
      # substitutions. Not 0, which is what a case-folding (or otherwise incorrect)
      # implementation would wrongly report.
      assert SemanticValidation.levenshtein_distance("Customer_Name", "customer_name") == 2
      refute SemanticValidation.levenshtein_distance("Customer_Name", "customer_name") == 0
    end

    test "nearest_declared_field/2 picks the true minimum-distance candidate, not the alphabetically-first one when it is farther away" do
      # "custname" is closer to "customer_name" (distance 5) than to "amount" (distance 8)
      # or "zzz_field" (much farther) -- if the implementation were a first-alphabetical
      # placeholder, "amount" (alphabetically first) would win instead.
      assert SemanticValidation.nearest_declared_field("custname", [
               "zzz_field",
               "amount",
               "customer_name"
             ]) == "customer_name"
    end

    test "nearest_declared_field/2 tie-breaks by alphabetical order among equidistant candidates" do
      # "ab" is distance 1 from both "ac" and "ad" -- deterministic tie-break, not
      # iteration-order-dependent.
      assert SemanticValidation.nearest_declared_field("ab", ["ad", "ac"]) == "ac"
    end

    test "nearest_declared_field/2 returns nil when there are zero declared field names" do
      assert SemanticValidation.nearest_declared_field("anything", []) == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- a comparison between two operands of non-comparable declared types (at
  # minimum numeric/money vs. text/string) produces a violation.
  # ---------------------------------------------------------------------------------

  describe "validate/2 (AC3) -- non-comparable type-pair produces :incompatible_comparison_operand_types" do
    test "comparing a numeric/money-typed field against a string-typed field is flagged (the explicit AC3 floor)" do
      declared_fields = %{"amount" => field("number"), "customer_name" => field("string")}
      graph = gateway_graph("amount == customer_name")

      result = SemanticValidation.validate(graph, declared_fields)

      assert result.valid == false
      assert codes(result) == [:incompatible_comparison_operand_types]

      [message] = messages(result)
      assert message =~ "compares incompatible types"
      assert message =~ "(numeric)"
      assert message =~ "(string)"
      assert message =~ "=="
    end

    test "an :integer-typed field is also :numeric for comparability purposes (money-by-convention, no distinct money type)" do
      declared_fields = %{"amount" => field("integer"), "label" => field("string")}
      graph = gateway_graph("amount > label")

      result = SemanticValidation.validate(graph, declared_fields)

      assert codes(result) == [:incompatible_comparison_operand_types]
    end

    test "two fields of the SAME declared family are comparable -- no violation (proves the table's OK cells, not only its VIOLATION cells)" do
      declared_fields = %{"amount" => field("number"), "threshold" => field("number")}
      graph = gateway_graph("amount > threshold")

      result = SemanticValidation.validate(graph, declared_fields)

      assert result == %{valid: true, violations: []}
    end

    test "a field == null / field != null guard is always exempt from the table, regardless of the field's declared type" do
      declared_fields = %{"amount" => field("number")}
      graph = gateway_graph("amount == null")

      result = SemanticValidation.validate(graph, declared_fields)

      assert result == %{valid: true, violations: []}
    end

    test "an array- or object-typed field is never comparable, including against its own family" do
      declared_fields = %{"tags" => field("array"), "other_tags" => field("array")}
      graph = gateway_graph("tags == other_tags")

      result = SemanticValidation.validate(graph, declared_fields)

      assert codes(result) == [:incompatible_comparison_operand_types]
    end

    test "an operand that is itself undeclared is exempt from the type-compatibility table (already independently reported by the field-existence check, no redundant second violation)" do
      declared_fields = %{"amount" => field("number")}
      graph = gateway_graph("amount == mystery_field")

      result = SemanticValidation.validate(graph, declared_fields)

      # only the field-existence violation for mystery_field, no
      # :incompatible_comparison_operand_types for the same comparison
      assert codes(result) == [:undeclared_variable_reference]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a definition with two independent broken rules (one field-existence
  # violation, one type-compatibility violation) produces BOTH violations from a
  # SINGLE validate/2 call -- never requiring two separate calls to discover both.
  # ---------------------------------------------------------------------------------

  describe "validate/2 (AC4) -- both violation classes from a single call when a definition has one of each" do
    test "one edge with an undeclared-variable condition and a second edge with a type-incompatible comparison both surface from the SAME validate/2 call" do
      declared_fields = %{"amount" => field("number"), "customer_name" => field("string")}

      graph =
        graph(
          [
            node("gw1", :EXCLUSIVE_GATEWAY),
            node("gw2", :EXCLUSIVE_GATEWAY),
            node("a", :END),
            node("b", :END)
          ],
          [
            cond_edge("e1", "gw1", "a", "cusotmer_name == \"John\""),
            cond_edge("e2", "gw2", "b", "amount == customer_name")
          ]
        )

      result = SemanticValidation.validate(graph, declared_fields)

      assert result.valid == false

      assert Enum.sort(codes(result)) ==
               Enum.sort([:undeclared_variable_reference, :incompatible_comparison_operand_types])
    end

    test "the same single edge can independently trigger BOTH violation classes at once (one undeclared operand, one type-incompatible comparison elsewhere in the same condition)" do
      declared_fields = %{"amount" => field("number"), "customer_name" => field("string")}

      # "cusotmer_name == \"x\"" -> field-existence violation.
      # "amount == customer_name" -> type-compatibility violation.
      # Joined with `and` so both {:var,...} and {:cmp,...} nodes exist in one parsed ast().
      graph = gateway_graph("cusotmer_name == \"x\" and amount == customer_name")

      result = SemanticValidation.validate(graph, declared_fields)

      assert Enum.sort(codes(result)) ==
               Enum.sort([:undeclared_variable_reference, :incompatible_comparison_operand_types])
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- a definition with zero semantic violations validates cleanly, including
  # after both AC4 violations are corrected in the SAME test (the fix path).
  # ---------------------------------------------------------------------------------

  describe "validate/2 (AC5) -- zero violations validates cleanly, including after both AC4 violations are corrected" do
    test "a definition with no field-existence or type-compatibility problems validates with valid: true and an empty violations list" do
      declared_fields = %{"amount" => field("number"), "customer_name" => field("string")}
      graph = gateway_graph("amount > 100 and customer_name == \"Jane\"")

      result = SemanticValidation.validate(graph, declared_fields)

      assert result == %{valid: true, violations: []}
    end

    test "starting from the AC4 broken definition (one field-existence + one type-compatibility violation), correcting BOTH in the same test re-validates clean -- proves the fix path, not just a fresh clean fixture" do
      declared_fields = %{"amount" => field("number"), "customer_name" => field("string")}

      broken_condition = "cusotmer_name == \"x\" and amount == customer_name"
      broken_graph = gateway_graph(broken_condition)

      broken_result = SemanticValidation.validate(broken_graph, declared_fields)

      assert broken_result.valid == false

      assert Enum.sort(codes(broken_result)) ==
               Enum.sort([:undeclared_variable_reference, :incompatible_comparison_operand_types])

      # Fix 1: correct the misspelled field name (customer_name, not cusotmer_name).
      # Fix 2: compare amount against a numeric literal instead of the string field.
      fixed_condition = "customer_name == \"x\" and amount == 100"
      fixed_graph = gateway_graph(fixed_condition)

      fixed_result = SemanticValidation.validate(fixed_graph, declared_fields)

      assert fixed_result == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- HUMAN_TASK routing/assignment-by-field is out of scope. This test proves
  # the SCOPE BOUNDARY (a HUMAN_TASK-sourced edge condition is never walked by this
  # pass, even one that would otherwise be flagged), which is the opposite of
  # implying HUMAN_TASK routing validation is covered -- no test in this file
  # exercises or asserts on any HUMAN_TASK role/assignment mechanism.
  # ---------------------------------------------------------------------------------

  describe "validate/2 (AC7 scope boundary) -- a HUMAN_TASK-sourced edge condition is never walked by this pass" do
    test "an edge sourced from a HUMAN_TASK node carrying an undeclared-variable-referencing condition produces no violation (out of this pass's edge selection, not a routing/assignment check)" do
      graph =
        graph(
          [node("h", :HUMAN_TASK), node("t", :END)],
          [cond_edge("e1", "h", "t", "totally_undeclared_field == \"x\"")]
        )

      result = SemanticValidation.validate(graph, %{})

      assert result == %{valid: true, violations: []}
    end
  end

  # ---------------------------------------------------------------------------------
  # Ordering-contract note (§1.2 of the design): a grammar-invalid condition is
  # defensively skipped, not crashed on and not double-reported -- CHK-17's job.
  # Not itself an acceptance criterion, but proves validate/2 stays total per its own
  # documented contract, directly relevant to AC6's "activate/2 reflects fresh state"
  # not blowing up on stale/edge-case input.
  # ---------------------------------------------------------------------------------

  describe "validate/2 -- defensive skip on a grammar-invalid condition (ordering contract, not this module's job to report)" do
    test "a condition that fails to parse (e.g. a dangling comparison operator) contributes zero violations from this pass rather than raising" do
      declared_fields = %{"amount" => field("number")}
      graph = gateway_graph("amount >")

      result = SemanticValidation.validate(graph, declared_fields)

      assert result == %{valid: true, violations: []}
    end
  end
end
