defmodule Letflow.Engine.ExprConformanceCorpusTest do
  @moduledoc """
  Language-neutral conformance corpus tests for `Letflow.Engine.Expr` (REQ-289).

  Each entry in `priv/expr_conformance/corpus.json` is asserted here.  The corpus is
  loaded at compile time so that `@external_resource` triggers a recompile whenever the
  JSON file changes.

  Four describe blocks:
  1. Success entries — parse succeeds, eval matches the documented value.
  2. Parse-failure entries — parse returns `{:error, {:parse_error, _}}`; eval never called.
  3. Eval-failure entries — parse succeeds, eval returns `{:error, {:eval_error, _}}`.
  4. Grammar coverage completeness — every required tag class and all builtins returned
     by `builtin_function_names/0` are covered by at least one corpus entry.

  `async: true` is safe: `Letflow.Engine.Expr` is a pure module with no Repo/Sandbox
  dependency.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Expr

  @corpus_path Path.join(:code.priv_dir(:letflow), "expr_conformance/corpus.json")
  @external_resource @corpus_path
  @corpus @corpus_path |> File.read!() |> Jason.decode!()

  # -----------------------------------------------------------------------
  # Describe 1 — success entries
  # -----------------------------------------------------------------------

  describe "corpus success entries — parse and eval" do
    test "all success entries parse and eval to the documented value" do
      success = Enum.filter(@corpus, &(&1["outcome"]["status"] == "ok"))

      for entry <- success do
        id = entry["id"]
        expression = entry["expression"]
        vars = decoded_variables(entry["variables"])
        expected = decode_marker(entry["outcome"]["value"])

        assert {:ok, ast} = Expr.parse(expression),
               "#{id}: expected parse/1 to succeed for #{inspect(expression)}"

        assert {:ok, ^expected} = Expr.eval(ast, vars),
               "#{id}: expected eval/2 to return {:ok, #{inspect(expected)}}"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Describe 2 — parse-failure entries
  # -----------------------------------------------------------------------

  describe "corpus parse-failure entries" do
    test "all parse-failure entries fail at the parse stage, never at eval" do
      failures = Enum.filter(@corpus, &(&1["outcome"]["error_kind"] == "parse_failure"))

      for entry <- failures do
        id = entry["id"]

        assert {:error, {:parse_error, _}} = Expr.parse(entry["expression"]),
               "#{id}: expected parse/1 to return a parse_error"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Describe 3 — eval-failure entries
  # -----------------------------------------------------------------------

  describe "corpus eval-failure entries" do
    test "all eval-failure entries parse successfully and then fail at eval" do
      failures = Enum.filter(@corpus, &(&1["outcome"]["error_kind"] == "eval_failure"))

      for entry <- failures do
        id = entry["id"]
        expression = entry["expression"]
        vars = decoded_variables(entry["variables"])

        assert {:ok, ast} = Expr.parse(expression),
               "#{id}: expected parse/1 to succeed for an eval-failure entry"

        assert {:error, {:eval_error, _}} = Expr.eval(ast, vars),
               "#{id}: expected eval/2 to return an eval_error"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Describe 4 — grammar coverage completeness
  # -----------------------------------------------------------------------

  describe "grammar coverage completeness" do
    # Build the union of all grammar_constructs tags across the whole corpus once.
    @all_tags @corpus
              |> Enum.flat_map(& &1["grammar_constructs"])
              |> MapSet.new()

    test "covers all 6 comparison operators" do
      for tag <- ~w(cmp:eq cmp:neq cmp:lt cmp:lte cmp:gt cmp:gte) do
        assert MapSet.member?(@all_tags, tag), "missing grammar_constructs tag: #{tag}"
      end
    end

    test "covers and, or, not" do
      for tag <- ~w(bool:and bool:or bool:not) do
        assert MapSet.member?(@all_tags, tag), "missing grammar_constructs tag: #{tag}"
      end
    end

    test "covers all 5 literal kinds" do
      for tag <- ~w(lit:boolean lit:integer lit:float lit:string lit:null) do
        assert MapSet.member?(@all_tags, tag), "missing grammar_constructs tag: #{tag}"
      end
    end

    test "covers all 5 arithmetic operators" do
      for tag <- ~w(arith:add arith:sub arith:mul arith:div arith:mod) do
        assert MapSet.member?(@all_tags, tag), "missing grammar_constructs tag: #{tag}"
      end
    end

    test "covers unary negation" do
      assert MapSet.member?(@all_tags, "arith:neg"), "missing grammar_constructs tag: arith:neg"
    end

    test "covers dotted variable paths" do
      assert MapSet.member?(@all_tags, "var:dotted"),
             "missing grammar_constructs tag: var:dotted"
    end

    test "all builtins from builtin_function_names/0 have at least one corpus entry" do
      covered_builtin_names =
        @corpus
        |> Enum.flat_map(& &1["grammar_constructs"])
        |> Enum.filter(&String.starts_with?(&1, "builtin:"))
        |> Enum.map(&String.replace_prefix(&1, "builtin:", ""))
        |> MapSet.new()

      required = Expr.builtin_function_names() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
      missing = MapSet.difference(required, covered_builtin_names)

      assert MapSet.size(missing) == 0,
             "builtins with no corpus entry: #{inspect(MapSet.to_list(missing))} — " <>
               "add a corpus entry with tag \"builtin:<name>\" for each"
    end
  end

  # -----------------------------------------------------------------------
  # Private helpers
  # -----------------------------------------------------------------------

  # Converts a $marker sentinel object to the corresponding Elixir atom.
  # All other values pass through unchanged.
  defp decode_marker(%{"$marker" => "infinity"}), do: :infinity
  defp decode_marker(%{"$marker" => "neg_infinity"}), do: :neg_infinity
  defp decode_marker(%{"$marker" => "nan"}), do: :nan
  defp decode_marker(other), do: other

  # Recursively applies decode_marker/1 to every leaf value of the variables
  # map, handling nested maps for dotted-path entries.
  defp decoded_variables(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decoded_variable_value(v)} end)
  end

  defp decoded_variable_value(v) when is_map(v) do
    decoded = decode_marker(v)
    if is_atom(decoded), do: decoded, else: decoded_variables(v)
  end

  defp decoded_variable_value(v), do: v
end
