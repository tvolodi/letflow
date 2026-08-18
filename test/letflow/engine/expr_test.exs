defmodule Letflow.Engine.ExprTest do
  @moduledoc """
  Unit tests for `Letflow.Engine.Expr` (REQ-050), implementing
  `lib/letflow/design/req050-exclusive-gateway-cel.md` (the gate-approved design this
  module follows). Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere
  in this file — `async: true` for the same reason `transition_test.exs` (REQ-044)
  already establishes.

  See `test/specs/REQ-050.md` for the full test design rationale and AC traceability.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Expr

  # ---------------------------------------------------------------------
  # AC7 -- the 4 translate_cel_to_expr/1 rewrites, tested individually
  # ---------------------------------------------------------------------

  describe "translate_cel_to_expr/1 -- rule 1, variables. prefix stripped (AC7)" do
    test "strips every variables. prefix occurrence" do
      assert Expr.translate_cel_to_expr("variables.amount") == {:ok, "amount"}
    end

    test "strips the prefix from both sides of a comparison" do
      assert Expr.translate_cel_to_expr("variables.a == variables.b") == {:ok, "a == b"}
    end
  end

  describe "translate_cel_to_expr/1 -- rule 2, && becomes and (AC7)" do
    test "rewrites && to and" do
      assert Expr.translate_cel_to_expr("variables.a && variables.b") == {:ok, "a and b"}
    end
  end

  describe "translate_cel_to_expr/1 -- rule 3, || becomes or (AC7)" do
    test "rewrites || to or" do
      assert Expr.translate_cel_to_expr("variables.a || variables.b") == {:ok, "a or b"}
    end
  end

  describe "translate_cel_to_expr/1 -- rule 4, ! becomes not, != passes through (AC7)" do
    test "rewrites a bare ! to not " do
      assert Expr.translate_cel_to_expr("!variables.approved") == {:ok, "not approved"}
    end

    # Load-bearing carve-out (design doc §4.3): a naive byte-for-byte "!" ->
    # "not " substitution would corrupt "!=" into "not =", an invalid token.
    test "leaves != untouched -- does not corrupt it into 'not ='" do
      assert Expr.translate_cel_to_expr("variables.status != \"x\"") ==
               {:ok, "status != \"x\""}
    end

    test "a condition mixing both ! and != rewrites only the bare !" do
      assert Expr.translate_cel_to_expr("!variables.a && variables.b != 1") ==
               {:ok, "not a and b != 1"}
    end
  end

  # ---------------------------------------------------------------------
  # AC6 -- unsupported CEL feature boundary, at least 2 distinct examples,
  # via translate_cel_to_expr/1 directly (parse/eval never reached)
  # ---------------------------------------------------------------------

  describe "translate_cel_to_expr/1 -- unsupported CEL feature boundary (AC6)" do
    test "a macro call (has(...)) is rejected as unsupported" do
      assert Expr.translate_cel_to_expr("has(variables.x)") == {:error, :unsupported_cel_feature}
    end

    test "a type-conversion function call (int(...)) is rejected as unsupported" do
      assert Expr.translate_cel_to_expr("int(variables.x) == 1") ==
               {:error, :unsupported_cel_feature}
    end

    test "a collection function call (size(...)) is rejected as unsupported" do
      assert Expr.translate_cel_to_expr("size(variables.list) > 0") ==
               {:error, :unsupported_cel_feature}
    end

    test "the in membership operator is rejected as unsupported" do
      assert Expr.translate_cel_to_expr("variables.x in variables.list") ==
               {:error, :unsupported_cel_feature}
    end

    test "the ternary operator is rejected as unsupported" do
      assert Expr.translate_cel_to_expr("variables.a ? variables.b : variables.c") ==
               {:error, :unsupported_cel_feature}
    end

    # A literal '?' inside a quoted string value is NOT a ternary use and must
    # not false-positive (design doc §4.4's explicit string-literal-aware note).
    test "a literal ? inside a quoted string value does not false-positive as ternary" do
      assert Expr.translate_cel_to_expr("variables.status == \"ready?\"") ==
               {:ok, "status == \"ready?\""}
    end
  end

  describe "translate_cel_to_expr/1 -- malformed input (design doc §4.2 step 3, own defensive addition)" do
    test "an empty string is a translate_error" do
      assert Expr.translate_cel_to_expr("") == {:error, :translate_error}
    end

    test "a bare 'variables.' with nothing left after stripping is a translate_error" do
      assert Expr.translate_cel_to_expr("variables.") == {:error, :translate_error}
    end
  end

  # ---------------------------------------------------------------------
  # parse/1 -- direct coverage, as needed for evaluate_condition/2's
  # composition to be independently verifiable
  # ---------------------------------------------------------------------

  describe "parse/1" do
    test "parses a bare comparison into a :cmp AST node" do
      assert Expr.parse("amount > 100") == {:ok, {:cmp, :gt, {:var, ["amount"]}, {:lit, 100}}}
    end

    test "parses a boolean literal" do
      assert Expr.parse("true") == {:ok, {:lit, true}}
    end

    test "parses and/or/not with the documented precedence (or lowest, not highest)" do
      assert Expr.parse("a and not b or c") ==
               {:ok, {:or, {:and, {:var, ["a"]}, {:not, {:var, ["b"]}}}, {:var, ["c"]}}}
    end

    test "an unparseable string returns a tagged :parse_error, never raises" do
      assert {:error, {:parse_error, _reason}} = Expr.parse("and and and")
    end
  end

  # ---------------------------------------------------------------------
  # eval/2 -- direct coverage of the error shapes evaluate_condition/2
  # composes over (AC3's two named examples: undefined variable, type
  # mismatch)
  # ---------------------------------------------------------------------

  describe "eval/2 -- undefined variable and type-mismatch errors (AC3)" do
    test "a variable absent from the map is an :undefined_variable eval error" do
      assert Expr.eval({:var, ["missing"]}, %{}) ==
               {:error, {:eval_error, {:undefined_variable, ["missing"]}}}
    end

    test "an ordering comparison between a string and a number is a :type_mismatch eval error" do
      ast = {:cmp, :gt, {:var, ["name"]}, {:lit, 5}}
      assert {:error, {:eval_error, {:type_mismatch, :gt, "bob", 5}}} = Expr.eval(ast, %{"name" => "bob"})
    end

    test "eq/neq never error across differently-typed operands (design doc §9.4)" do
      ast = {:cmp, :eq, {:lit, "5"}, {:lit, 5}}
      assert Expr.eval(ast, %{}) == {:ok, false}
    end

    test "a resolved value that is itself non-boolean is still an {:ok, _} result, not an error" do
      assert Expr.eval({:var, ["amount"]}, %{"amount" => 42}) == {:ok, 42}
    end
  end

  # ---------------------------------------------------------------------
  # evaluate_condition/2 -- the composed, always-boolean entry point.
  # Catch-false composition tested across every failing stage.
  # ---------------------------------------------------------------------

  describe "evaluate_condition/2 -- catch-false composition (AC3, AC6)" do
    test "a well-formed, true-evaluating condition returns true" do
      assert Expr.evaluate_condition("variables.amount > 100", %{"amount" => 200}) == true
    end

    test "a well-formed, false-evaluating condition returns false" do
      assert Expr.evaluate_condition("variables.amount > 100", %{"amount" => 50}) == false
    end

    test "an undefined-variable condition returns false, not a raised error" do
      assert Expr.evaluate_condition("variables.missing > 1", %{}) == false
    end

    test "a type-mismatch condition returns false, not a raised error" do
      assert Expr.evaluate_condition("variables.name > 5", %{"name" => "bob"}) == false
    end

    test "an unsupported-CEL-feature condition returns false, not a raised error" do
      assert Expr.evaluate_condition("has(variables.x)", %{}) == false
    end

    test "a condition whose eval/2 result is a non-boolean value returns false" do
      assert Expr.evaluate_condition("variables.amount", %{"amount" => 42}) == false
    end

    test "a malformed/unparseable condition returns false, not a raised error" do
      assert Expr.evaluate_condition("", %{}) == false
    end
  end

  # ---------------------------------------------------------------------
  # AC8 -- zero I/O, deterministic. Grep-based structural check (matching
  # the design doc §7 verification method) plus an explicit repeated-call
  # equality check (Expr's functions are simple pure functions of their
  # typed arguments -- a direct check, not a property test, is sufficient
  # here; transition_test.exs's existing world_generator/0 property already
  # covers determinism for the composed transition/3 call graph).
  # ---------------------------------------------------------------------

  describe "purity and determinism (AC8)" do
    test "expr.ex's actual code (docs/comments stripped) contains no I/O/clock/randomness call (grep, design doc §7)" do
      path = Path.join([File.cwd!(), "lib", "letflow", "engine", "expr.ex"])
      source = File.read!(path)

      # The moduledoc/@doc text itself legitimately *names* these forbidden
      # calls in prose (stating the purity contract, and quoting the design
      # doc's own grep command) -- stripping triple-quoted doc blocks and #
      # comment lines first keeps this check about the actual code, not
      # about documentation that mentions the words.
      code_only =
        source
        |> String.replace(~r/""".*?"""/s, "")
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) |> String.starts_with?("#")))
        |> Enum.join("\n")

      refute code_only =~ ~r/Repo\.|Logger\.|DateTime\.|System\.os_time|System\.system_time|HTTPoison|Req\.|File\.|:rand\.|:crypto\./
    end

    test "translate_cel_to_expr/1 is deterministic -- == -equal input, == -equal output, twice" do
      input = "variables.a && !variables.b"
      assert Expr.translate_cel_to_expr(input) == Expr.translate_cel_to_expr(input)
    end

    test "evaluate_condition/2 is deterministic -- == -equal input, == -equal output, twice" do
      condition = "variables.amount > 100"
      variables = %{"amount" => 200}

      assert Expr.evaluate_condition(condition, variables) ==
               Expr.evaluate_condition(condition, variables)
    end

    test "eval/2 is deterministic across an error path too" do
      ast = {:var, ["missing"]}
      assert Expr.eval(ast, %{}) == Expr.eval(ast, %{})
    end
  end
end
