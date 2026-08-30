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

  # Rules 2/3 emit " and "/" or " WITH surrounding spaces (ISS-0085/GH#302),
  # matching transition.zig:1177/:1183. Spaced CEL input therefore ends up
  # with a doubled space around the keyword ("a  and  b") -- harmless, since
  # do_tokenize/2 skips whitespace -- while the load-bearing case is
  # unspaced CEL input, which is valid CEL and previously fused into one
  # identifier instead of two tokens joined by "and"/"or".
  describe "translate_cel_to_expr/1 -- rule 2, && becomes ' and ' (AC7)" do
    test "rewrites && to ' and ', doubling the space around already-spaced input" do
      assert Expr.translate_cel_to_expr("variables.a && variables.b") == {:ok, "a  and  b"}
    end

    test "rewrites unspaced && without fusing the adjacent identifiers (ISS-0085/GH#302)" do
      assert Expr.translate_cel_to_expr("variables.a&&variables.b") == {:ok, "a and b"}
    end
  end

  describe "translate_cel_to_expr/1 -- rule 3, || becomes ' or ' (AC7)" do
    test "rewrites || to ' or ', doubling the space around already-spaced input" do
      assert Expr.translate_cel_to_expr("variables.a || variables.b") == {:ok, "a  or  b"}
    end

    test "rewrites unspaced || without fusing the adjacent identifiers (ISS-0085/GH#302)" do
      assert Expr.translate_cel_to_expr("variables.a||variables.b") == {:ok, "a or b"}
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
               {:ok, "not a  and  b != 1"}
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

    # ISS-0087/GH#304 -- deliberate divergence from R-Co, decided and recorded in
    # design doc §4.4/§9.1(b): R-Co's naive quote-toggle scan (no escape handling)
    # mis-parses a backslash-escaped quote and treats the `?` that follows it as
    # OUTSIDE the literal, rejecting the condition as ternary. Letflow's
    # escape-aware regex correctly treats the whole escaped literal as one span,
    # so the `?` inside it is never seen as ternary. This test locks in the
    # CHOSEN (escape-aware, arguably more correct) semantic -- if it ever fails,
    # that's a signal the tokenizer's escape handling changed, which must go
    # through the same explicit design-decision process as this issue, not a
    # silent regression.
    test "a ? immediately after a backslash-escaped quote inside a string literal is not ternary (ISS-0087)" do
      assert Expr.translate_cel_to_expr(~S|variables.q == "a\"?b"|) ==
               {:ok, ~S|q == "a\"?b"|}
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

    test "a multi-segment dotted variable path parses instead of raising (ISS-0086 root cause)" do
      assert Expr.parse("order.status == 1") ==
               {:ok, {:cmp, :eq, {:var, ["order", "status"]}, {:lit, 1}}}
    end

    test "a decimal number literal parses instead of raising (ISS-0086, same tokenizer root cause)" do
      assert Expr.parse("amount > 3.14") ==
               {:ok, {:cmp, :gt, {:var, ["amount"]}, {:lit, 3.14}}}
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

      assert {:error, {:eval_error, {:type_mismatch, :gt, "bob", 5}}} =
               Expr.eval(ast, %{"name" => "bob"})
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
  # REQ-197 AC1 -- each of + - * / % and unary negation, one test per
  # operator with a concrete expected value. Parsed from real condition
  # syntax (not hand-built ASTs) so the tokenizer/parser path is exercised
  # too, matching design doc §2.2's own worked examples where they overlap.
  # ---------------------------------------------------------------------

  describe "parse/1 + eval/2 -- each arithmetic operator, one test per (AC1)" do
    test "+ adds" do
      assert {:ok, ast} = Expr.parse("2 + 3")
      assert Expr.eval(ast, %{}) == {:ok, 5}
    end

    test "- subtracts" do
      assert {:ok, ast} = Expr.parse("5 - 3")
      assert Expr.eval(ast, %{}) == {:ok, 2}
    end

    test "* multiplies" do
      assert {:ok, ast} = Expr.parse("4 * 3")
      assert Expr.eval(ast, %{}) == {:ok, 12}
    end

    test "/ divides (integer, truncating, non-zero divisor)" do
      assert {:ok, ast} = Expr.parse("7 / 2")
      assert Expr.eval(ast, %{}) == {:ok, 3}
    end

    test "% is the remainder (non-zero divisor)" do
      assert {:ok, ast} = Expr.parse("7 % 2")
      assert Expr.eval(ast, %{}) == {:ok, 1}
    end

    test "unary - negates" do
      assert {:ok, ast} = Expr.parse("- 5")
      assert Expr.eval(ast, %{}) == {:ok, -5}
    end
  end

  # ---------------------------------------------------------------------
  # REQ-197 AC2 -- operator precedence, matching design doc §2.1/§2.2's
  # own worked examples exactly (loosest-to-tightest: or, and, not,
  # comparison, +/-, */%, unary -, primary).
  # ---------------------------------------------------------------------

  describe "parse/1 + eval/2 -- operator precedence (AC2)" do
    test "an expression mixing + and * groups the * first: 2 + 3 * 4 == 14, not 20" do
      assert {:ok, ast} = Expr.parse("2 + 3 * 4")
      assert ast == {:arith, :add, {:lit, 2}, {:arith, :mul, {:lit, 3}, {:lit, 4}}}
      assert Expr.eval(ast, %{}) == {:ok, 14}
    end

    test "a comparison mixed with arithmetic evaluates the arithmetic first: 1 + 1 == 2 is true" do
      assert {:ok, ast} = Expr.parse("1 + 1 == 2")
      assert ast == {:cmp, :eq, {:arith, :add, {:lit, 1}, {:lit, 1}}, {:lit, 2}}
      assert Expr.eval(ast, %{}) == {:ok, true}
    end

    test "- and / are left-associative: 3 - 1 - 1 == 1, not 3" do
      assert {:ok, ast} = Expr.parse("3 - 1 - 1")
      assert Expr.eval(ast, %{}) == {:ok, 1}
    end

    test "unary - is right-recursive: - - 5 == 5" do
      assert {:ok, ast} = Expr.parse("- - 5")
      assert Expr.eval(ast, %{}) == {:ok, 5}
    end
  end

  # ---------------------------------------------------------------------
  # REQ-197 AC3 -- an integer mixed with a float promotes to float, on a
  # case where integer arithmetic would give a different answer: 7 / 2 is
  # 3 (integer, truncating division, per AC1 above) but 7 / 2.0 is 3.5.
  # ---------------------------------------------------------------------

  describe "eval/2 -- int/float promotion (AC3)" do
    test "int / float promotes the int operand, giving a different answer than int / int" do
      assert {:ok, ast} = Expr.parse("7 / 2.0")
      assert Expr.eval(ast, %{}) == {:ok, 3.5}
    end
  end

  # ---------------------------------------------------------------------
  # REQ-197 AC4 -- int division/modulo by zero are errors (float division
  # by zero -> infinity is already covered by the signed-infinity describe
  # block below, whose first test is explicitly cross-referenced as AC4's
  # third case).
  # ---------------------------------------------------------------------

  describe "eval/2 -- integer division/modulo by zero (AC4)" do
    test "integer division by zero is an error, not a crash or a wrong value" do
      ast = {:arith, :div, {:lit, 5}, {:lit, 0}}
      assert Expr.eval(ast, %{}) == {:error, {:eval_error, {:division_by_zero, :int, 5, 0}}}
    end

    test "integer modulo by zero is an error, not a crash or a wrong value" do
      ast = {:arith, :mod, {:lit, 5}, {:lit, 0}}
      assert Expr.eval(ast, %{}) == {:error, {:eval_error, {:modulo_by_zero, :int, 5, 0}}}
    end
  end

  # ---------------------------------------------------------------------
  # REQ-197 AC5 -- the deliberate null asymmetry: null in a comparison
  # yields null (a real, non-error value), null in arithmetic is an error.
  # Design doc §4.5's own two worked test cases, transcribed directly.
  # ---------------------------------------------------------------------

  describe "eval/2 -- null asymmetry: comparison propagates, arithmetic errors (AC5)" do
    test "null in an ordering comparison yields null, not an error" do
      ast = {:cmp, :lt, {:var, ["amount"]}, {:lit, 100}}
      assert Expr.eval(ast, %{"amount" => nil}) == {:ok, nil}
    end

    test "null in arithmetic is an error, regardless of the other operand's type" do
      ast = {:arith, :add, {:var, ["amount"]}, {:lit, 1}}

      assert Expr.eval(ast, %{"amount" => nil}) ==
               {:error, {:eval_error, {:null_in_arithmetic, :add, nil, 1}}}
    end
  end

  # ---------------------------------------------------------------------
  # REQ-197 AC6 -- parse_strict/1's structured parse-failure surface,
  # asserted field by field on a deliberately malformed expression: a
  # trailing binary operator with no right operand.
  # ---------------------------------------------------------------------

  describe "parse_strict/1 -- structured parse failure, field by field (AC6)" do
    test "a trailing operator with no right operand reports line, column, token text and message" do
      assert Expr.parse_strict("amount + ") ==
               {:error,
                %{
                  line: 1,
                  column: 10,
                  token_text: "",
                  message: "unexpected end of input"
                }}
    end

    test "on success, returns the identical ast() parse/1 would return for the same input" do
      assert Expr.parse_strict("amount + 1") == Expr.parse("amount + 1")
    end
  end

  # ---------------------------------------------------------------------
  # REQ-197 §4.3/§4.6 -- signed-infinity/NaN 3-way split for float
  # division by a zero divisor (REVIEWER rework, OQ-1 resolved: the
  # unsigned-only :infinity fallback wrongly made an :infinity marker the
  # greatest value in ordering regardless of dividend sign).
  # ---------------------------------------------------------------------

  describe "eval/2 -- signed float division-by-zero (REQ-197 §4.3, OQ-1 sign-flip fix)" do
    test "positive dividend / 0.0 -> :infinity (AC4, still passes unmodified)" do
      ast = {:arith, :div, {:lit, 1.0}, {:lit, 0.0}}
      assert Expr.eval(ast, %{}) == {:ok, :infinity}
    end

    test "negative dividend / 0.0 -> :neg_infinity" do
      ast = {:arith, :div, {:lit, -1.0}, {:lit, 0.0}}
      assert Expr.eval(ast, %{}) == {:ok, :neg_infinity}
    end

    test "0.0 / 0.0 -> :nan" do
      ast = {:arith, :div, {:lit, 0.0}, {:lit, 0.0}}
      assert Expr.eval(ast, %{}) == {:ok, :nan}
    end

    test ":nan compares false against everything via every ordering operator, including :nan vs :nan" do
      nan_ast = {:arith, :div, {:lit, 0.0}, {:lit, 0.0}}

      for op <- [:lt, :lte, :gt, :gte] do
        assert Expr.eval({:cmp, op, nan_ast, {:lit, 5.0}}, %{}) == {:ok, false}
        assert Expr.eval({:cmp, op, nan_ast, nan_ast}, %{}) == {:ok, false}
      end
    end

    test ":nan == :nan is false and :nan != :nan is true (real IEEE 754 NaN self-inequality)" do
      nan_ast = {:arith, :div, {:lit, 0.0}, {:lit, 0.0}}

      assert Expr.eval({:cmp, :eq, nan_ast, nan_ast}, %{}) == {:ok, false}
      assert Expr.eval({:cmp, :neq, nan_ast, nan_ast}, %{}) == {:ok, true}
    end

    test "REGRESSION (REVIEWER-identified sign-flip bug): a negative amount divided by a zero-valued divisor, compared with `<` against a finite positive threshold, now evaluates true -- the old unsigned-only :infinity fallback wrongly evaluated this false" do
      # amount / divisor < threshold, with amount negative and divisor 0.0.
      # Correct IEEE-754 semantics: -1000.0 / 0.0 == :neg_infinity, and
      # :neg_infinity is the least possible value, so :neg_infinity < 100.0
      # must be true. Under the old unsigned-only fallback, this division
      # produced the single unsigned :infinity marker (treated as GREATEST
      # in every comparison), so `:infinity < 100.0` wrongly evaluated to
      # false.
      ast =
        {:cmp, :lt, {:arith, :div, {:var, ["amount"]}, {:var, ["divisor"]}}, {:lit, 100.0}}

      assert Expr.eval(ast, %{"amount" => -1000.0, "divisor" => 0.0}) == {:ok, true}
    end

    test "REGRESSION, gateway-level (`>` direction): a negative amount divided by a zero-valued divisor, compared with `>` against a finite positive threshold, now evaluates false via evaluate_condition/2 -- the old unsigned-only fallback wrongly routed this edge as true" do
      condition = "variables.amount / variables.divisor > 100.0"

      refute Expr.evaluate_condition(condition, %{"amount" => -1000.0, "divisor" => 0.0})
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

    # ISS-0085/GH#302 fail-first regression: pre-fix, unspaced && fused into
    # one identifier ("aandb"), which resolved as :undefined_variable and
    # was caught-false into `false` -- silently routing the gateway token
    # down the wrong outgoing edge with no crash and no prior test signal.
    test "unspaced && evaluates true instead of silently false (ISS-0085/GH#302)" do
      assert Expr.evaluate_condition("variables.a&&variables.b", %{"a" => true, "b" => true}) ==
               true
    end

    test "unspaced || evaluates true instead of silently false (ISS-0085/GH#302)" do
      assert Expr.evaluate_condition("variables.a||variables.b", %{"a" => false, "b" => true}) ==
               true
    end

    test "a mixed unspaced &&/|| condition evaluates correctly (ISS-0085/GH#302)" do
      assert Expr.evaluate_condition(
               "variables.a&&variables.b || variables.c",
               %{"a" => true, "b" => false, "c" => true}
             ) == true
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

    # REQ-197 AC7 / design doc §5's verification obligation: a deliberately
    # malformed ARITHMETIC condition (trailing operator, no right operand)
    # must still collapse to false via the same unconditional
    # `else _ -> false` composition, proving the catch-false rule absorbs
    # this requirement's new failure classes too, not just the pre-existing
    # ones already covered by the other tests in this describe block.
    test "a malformed arithmetic condition (trailing operator) returns false, not a raised error or an error tuple (AC7)" do
      assert Expr.evaluate_condition("variables.amount / ", %{"amount" => 5}) == false
    end

    # REQ-197 AC7: an eval-time arithmetic error (division by zero) must
    # also collapse to false, exactly like the pre-existing eval-error
    # cases (undefined variable, type mismatch) above.
    test "an integer-division-by-zero condition returns false, not a raised error or an error tuple (AC7)" do
      assert Expr.evaluate_condition("variables.amount / variables.divisor > 1", %{
               "amount" => 5,
               "divisor" => 0
             }) == false
    end

    test "a CEL method-call condition (matches()) returns false, not a raised CaseClauseError (ISS-0086/GH#303)" do
      assert Expr.evaluate_condition(~S|variables.s.matches("a")|, %{"s" => "y"}) == false
    end

    test "a nested/dotted variable path condition evaluates correctly instead of raising (ISS-0086 root cause)" do
      assert Expr.evaluate_condition(~S|variables.order.status == "approved"|, %{
               "order" => %{"status" => "approved"}
             }) == true
    end

    test "evaluate_condition/2 never raises across a corpus of out-of-grammar conditions (ISS-0086 totality)" do
      corpus = [
        {~S|variables.s.matches("a")|, %{"s" => "y"}},
        {~S|variables.a.b.c.d == 1|, %{}},
        {"variables.a..b == 1", %{}},
        {"variables. == 1", %{}},
        {"$$$", %{}},
        {"variables.x(y)", %{}}
      ]

      for {condition, variables} <- corpus do
        assert is_boolean(Expr.evaluate_condition(condition, variables)),
               "expected a boolean for #{inspect(condition)}, got a raise or non-boolean"
      end
    end

    # ISS-0087/GH#304 -- end-to-end lock-in of the chosen semantic (see the
    # translate_cel_to_expr/1 test above for the design-decision rationale). R-Co
    # would short-circuit this exact condition to false; Letflow evaluates it.
    test "a matching value against an escaped-quote-then-? literal evaluates true, not R-Co's false (ISS-0087)" do
      assert Expr.evaluate_condition(~S|variables.q == "a\"?b"|, %{"q" => ~S|a"?b|}) == true
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

      refute code_only =~
               ~r/Repo\.|Logger\.|DateTime\.|System\.os_time|System\.system_time|HTTPoison|Req\.|File\.|:rand\.|:crypto\./
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
