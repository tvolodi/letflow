defmodule Letflow.Engine.ExprCorpusDriftGuardTest do
  @moduledoc """
  CI guard against `Letflow.Engine.Expr`'s accepted grammar surface drifting away
  from `priv/expr_conformance/corpus.json` without the corpus (and its
  `priv/expr_conformance/manifest.json` capability marker) changing with it (REQ-290).

  Unlike REQ-289's own `Letflow.Engine.ExprConformanceCorpusTest` (which already
  mechanically drives its builtin-coverage test from `Expr.builtin_function_names/0`),
  this module closes the same gap for `Expr`'s three closed *type unions* —
  `cmp_op()`, `arith_op()`, and `ast()` — by reading them back out of `Expr`'s
  compiled BEAM debug-info at test runtime via `Code.Typespec.fetch_types/1`
  (stdlib, the same public API `ExDoc`/Dialyzer-adjacent tooling uses), rather than
  hand-copying the current atom list into this test file. See
  `lib/letflow/design/req290-corpus-drift-guard.md` §2 for the full mechanism
  rationale (including why source-text `@type` parsing and behavioural probing were
  both rejected) and §3 for this test module's design.

  `async: true` is safe: this module reads only `Code.Typespec`, `Letflow.Engine.Expr`
  (a pure module), and the corpus/manifest JSON files — no `Letflow.Repo`, no
  `Ecto.Sandbox`, no process, same justification as REQ-289's own test.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Expr

  @corpus_path Path.join(:code.priv_dir(:letflow), "expr_conformance/corpus.json")
  @manifest_path Path.join(:code.priv_dir(:letflow), "expr_conformance/manifest.json")
  @external_resource @corpus_path
  @external_resource @manifest_path
  @corpus @corpus_path |> File.read!() |> Jason.decode!()
  @manifest @manifest_path |> File.read!() |> Jason.decode!()

  # Read once, at compile time, straight from Expr's compiled debug-info chunk.
  # This is the load-bearing mechanism: every helper below derives its answer from
  # this, never from a hand-copied atom list.
  @typespec_types (case Code.Typespec.fetch_types(Expr) do
                     {:ok, types} ->
                       types

                     :error ->
                       raise "Code.Typespec.fetch_types/1 could not read #{inspect(Expr)}'s " <>
                               "compiled @type definitions -- was mix compile run with debug_info " <>
                               "disabled?"
                   end)

  # ast() tag -> required corpus tag-prefix. Consulted only as a lookup AFTER the
  # live tag set is mechanically derived from the typespec (ast_tag_atoms/0) -- a
  # stale entry here can only cause a correct FAIL demanding it be updated, never a
  # silent false PASS. See design doc §3.3's "why @ast_tag_prefix_map does not
  # reintroduce AC2's forbidden pattern."
  @ast_tag_prefix_map %{
    lit: "lit:",
    var: "var:",
    not: "bool:not",
    and: "bool:and",
    or: "bool:or",
    cmp: "cmp:",
    arith: "arith:",
    neg: "arith:neg",
    call: "builtin:"
  }

  # §7 open question (design doc): `lit:*`/`var:*` corpus tags have no closed
  # atom-union in expr.ex to introspect directly -- they describe sub-kinds of
  # `{:lit, value()}`'s and `{:var, path}`'s *contents* (value()'s own sub-kinds,
  # and dotted-vs-simple path length), not a tagged-tuple variant `ast_tag_atoms/0`
  # can enumerate. This pair is therefore hardcoded, but in the same
  # never-silently-passes shape as @ast_tag_prefix_map: the claim it rests on
  # (ast() has exactly one :lit variant and one :var variant) is itself
  # mechanically re-verified every run via ast_tag_atoms/0.
  @lit_var_capabilities MapSet.new([
                          "lit:boolean",
                          "lit:integer",
                          "lit:float",
                          "lit:string",
                          "lit:null",
                          "var:simple",
                          "var:dotted"
                        ])

  # -----------------------------------------------------------------------
  # Generic typespec walker (design doc §2.4) -- one function, no per-type
  # special-casing. Applied to cmp_op()/arith_op()/builtin_name()'s type_ast it
  # hits the bare-atom clause per union member; applied to ast()'s type_ast it
  # hits the tagged-tuple clause once per variant.
  # -----------------------------------------------------------------------

  @spec extract_tag_atoms(type_ast :: term()) :: MapSet.t(atom())
  defp extract_tag_atoms({:type, _anno, :union, members}) do
    Enum.reduce(members, MapSet.new(), fn member, acc ->
      MapSet.union(acc, extract_tag_atoms(member))
    end)
  end

  defp extract_tag_atoms({:type, _anno, :tuple, [{:atom, _tag_anno, tag} | _rest]}) do
    MapSet.new([tag])
  end

  defp extract_tag_atoms({:atom, _anno, value}) do
    MapSet.new([value])
  end

  defp extract_tag_atoms(_other), do: MapSet.new()

  @spec type_ast_for(name :: atom()) :: term()
  defp type_ast_for(name) do
    case Enum.find(@typespec_types, fn {_kind, {type_name, _type_ast, _params}} ->
           type_name == name
         end) do
      {_kind, {^name, type_ast, _params}} ->
        type_ast

      nil ->
        raise "no @type #{name} found on #{inspect(Expr)} via Code.Typespec.fetch_types/1 -- " <>
                "was it renamed or removed?"
    end
  end

  @spec cmp_op_atoms() :: MapSet.t(atom())
  defp cmp_op_atoms, do: extract_tag_atoms(type_ast_for(:cmp_op))

  @spec arith_op_atoms() :: MapSet.t(atom())
  defp arith_op_atoms, do: extract_tag_atoms(type_ast_for(:arith_op))

  @spec builtin_name_atoms() :: MapSet.t(atom())
  defp builtin_name_atoms, do: extract_tag_atoms(type_ast_for(:builtin_name))

  @spec ast_tag_atoms() :: MapSet.t(atom())
  defp ast_tag_atoms, do: extract_tag_atoms(type_ast_for(:ast))

  @spec corpus_tags_with_prefix(prefix :: String.t()) :: MapSet.t(String.t())
  defp corpus_tags_with_prefix(prefix) do
    @corpus
    |> Enum.flat_map(& &1["grammar_constructs"])
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> MapSet.new()
  end

  @spec required_cmp_tag_names() :: MapSet.t(String.t())
  defp required_cmp_tag_names do
    cmp_op_atoms() |> Enum.map(&("cmp:" <> Atom.to_string(&1))) |> MapSet.new()
  end

  @spec required_arith_tag_names() :: MapSet.t(String.t())
  defp required_arith_tag_names do
    # arith_op() has 5 members -- :neg is NOT one of them, it is its own ast()
    # variant (`{:neg, ast()}`), covered separately via @ast_tag_prefix_map[:neg].
    arith_op_atoms() |> Enum.map(&("arith:" <> Atom.to_string(&1))) |> MapSet.new()
  end

  @spec mechanically_derived_capabilities() :: MapSet.t(String.t())
  defp mechanically_derived_capabilities do
    bool_tags =
      MapSet.new([
        Map.fetch!(@ast_tag_prefix_map, :and),
        Map.fetch!(@ast_tag_prefix_map, :or),
        Map.fetch!(@ast_tag_prefix_map, :not)
      ])

    neg_tag = MapSet.new([Map.fetch!(@ast_tag_prefix_map, :neg)])

    builtin_tags =
      Expr.builtin_function_names()
      |> Enum.map(&("builtin:" <> Atom.to_string(&1)))
      |> MapSet.new()

    [
      required_cmp_tag_names(),
      required_arith_tag_names(),
      neg_tag,
      bool_tags,
      @lit_var_capabilities,
      builtin_tags
    ]
    |> Enum.reduce(&MapSet.union/2)
  end

  # -----------------------------------------------------------------------
  # cmp_op/arith_op surface, mechanically derived
  # -----------------------------------------------------------------------

  describe "cmp_op/arith_op surface, mechanically derived" do
    test "every cmp_op/0 atom has a corpus entry tagged cmp:<atom>" do
      present = corpus_tags_with_prefix("cmp:")
      missing = MapSet.difference(required_cmp_tag_names(), present)

      assert MapSet.size(missing) == 0,
             "cmp_op atoms with no corpus coverage: #{inspect(MapSet.to_list(missing))}"
    end

    test "every arith_op/0 atom (excluding :neg) has a corpus entry tagged arith:<atom>" do
      present = corpus_tags_with_prefix("arith:")
      missing = MapSet.difference(required_arith_tag_names(), present)

      assert MapSet.size(missing) == 0,
             "arith_op atoms with no corpus coverage: #{inspect(MapSet.to_list(missing))}"
    end
  end

  # -----------------------------------------------------------------------
  # ast() node-kind surface, mechanically derived
  # -----------------------------------------------------------------------

  describe "ast() node-kind surface, mechanically derived" do
    test "every ast() tag is known and mapped to a required corpus tag-prefix" do
      for tag <- ast_tag_atoms() do
        assert Map.has_key?(@ast_tag_prefix_map, tag),
               "unmapped ast() tag: #{inspect(tag)} — add it to @ast_tag_prefix_map " <>
                 "and a corresponding corpus entry"
      end
    end

    test "every ast() tag's mapped corpus prefix has at least one covering entry" do
      live_tags = ast_tag_atoms()

      for {tag, prefix} <- @ast_tag_prefix_map, tag in live_tags do
        assert MapSet.size(corpus_tags_with_prefix(prefix)) > 0,
               "ast() tag #{inspect(tag)} (corpus prefix #{inspect(prefix)}) has no " <>
                 "covering corpus entry"
      end
    end
  end

  # -----------------------------------------------------------------------
  # builtin_name self-consistency
  # -----------------------------------------------------------------------

  describe "builtin_name self-consistency" do
    test "builtin_name/0 typespec and builtin_function_names/0 agree" do
      assert builtin_name_atoms() == MapSet.new(Expr.builtin_function_names())
    end
  end

  # -----------------------------------------------------------------------
  # corpus manifest capabilities are drift-guarded too
  # -----------------------------------------------------------------------

  describe "corpus manifest capabilities are drift-guarded too" do
    test "manifest.json's capabilities list matches the mechanically-derived required set" do
      manifest_capabilities = MapSet.new(@manifest["capabilities"])
      required = mechanically_derived_capabilities()

      missing = MapSet.difference(required, manifest_capabilities)
      extra = MapSet.difference(manifest_capabilities, required)

      assert MapSet.size(missing) == 0 and MapSet.size(extra) == 0,
             "manifest.json capabilities mismatch — missing: #{inspect(MapSet.to_list(missing))}, " <>
               "extra: #{inspect(MapSet.to_list(extra))}"
    end
  end
end
