defmodule Letflow.Definitions.SemanticValidation do
  @moduledoc """
  Semantic validation of `EXCLUSIVE_GATEWAY` edge conditions against a
  process definition's own declared `variable_schemas` (REQ-372,
  `lib/letflow/design/req372-semantic-decision-rule-validation.md` — the
  gate-approved design this module implements). Two independent violation
  classes, collected together in a single pass, never short-circuiting on
  the first one found:

    1. **Field-existence** — an edge condition references a variable root
       segment (`{:var, path}`, checked at `hd(path)` only — see "Nested
       variable references" below) not present among the definition's
       declared `variable_schemas` keys.
    2. **Type-compatibility** — an edge condition compares (`{:cmp, op,
       left, right}`, all six `Letflow.Engine.Expr.cmp_op/0` values treated
       identically) two operands whose declared/literal type families are
       not comparable — see "The comparable/non-comparable type-pair table"
       below for the full table stated in prose, as this moduledoc is
       required to do explicitly rather than leave to test coverage.

  Sibling to `Letflow.Definitions.SubProcessInterface` and
  `Letflow.Definitions.FormSchemaExpressions`: a pure function taking a
  `Letflow.Definitions.Graph.t()` (plus this module's one extra input, the
  declared fields) and returning `Letflow.Definitions.Graph.result()`,
  consumed by `Letflow.Definitions` rather than by `Graph` itself.

  ## Purity

  Depends on Elixir/Erlang stdlib and `Letflow.Engine.Expr` only — no
  `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no
  HTTP/file/process-mailbox call anywhere, matching `Graph`'s own zero-I/O
  contract. Reading `variable_schemas` fresh (so this pass genuinely
  re-runs in full on every call, never against a cached prior result) is
  entirely the caller's job — see `Letflow.Engine.VariableSchema.fetch_schemas/3`,
  already public, already a plain uncached `Repo.all/2`, called fresh by
  `Letflow.Definitions.activate/2` and `Letflow.Definitions.validate_definition_graph/2`
  on every invocation.

  ## Ordering contract

  This module assumes, but does not verify, that `Graph.validate_graph/1`
  **and** `Graph.validate_edge_conditions/1` have already been run against
  the same `graph` value and both returned `valid: true`. It does not call
  either. `Graph.validate_edge_conditions/1`'s CHK-17
  (`check_cel_syntax/1`) is what guarantees every non-blank edge
  `condition` is syntactically valid CEL — `translate_cel_to_expr/1` +
  `parse_strict/1` are guaranteed to succeed only under that precondition.
  Calling `validate/2` against a graph with a grammar-invalid condition will
  not crash: an edge whose condition fails to translate/parse is
  defensively skipped, contributing zero violations for that edge from this
  pass — the CEL-syntax violation is CHK-17's to report, not this module's
  job to duplicate or paper over. Enforcing "run `validate_graph/1` ->
  `validate_edge_conditions/1` -> `SemanticValidation.validate/2`, in that
  order" is entirely the caller's job.

  ## The comparable/non-comparable type-pair table

  Every declared `variable_schemas` field and every literal operand
  resolves to one `type_family()`: `:numeric` (JSON Schema `"number"` or
  `"integer"` — **there is no distinct "money" type in this codebase**; a
  money-valued field is declared as `{"type": "number"}` with, by
  convention, an inert `"format"` annotation, so "money" is simply the
  `:numeric` family for this check's purposes), `:string` (`"string"`),
  `:boolean` (`"boolean"`), `:array` (`"array"`), or `:object`
  (`"object"`). A comparison is exempted from the table entirely (no
  violation, regardless of family) when either operand is a `null` literal
  (a `field == null` / `field != null` guard is always legitimate), an
  unresolved variable reference (already independently reported by the
  field-existence check against the same edge — no redundant second
  violation for the same root cause), or otherwise resolves to `:unknown`
  (an arithmetic expression, a builtin function call, a declared field with
  no recognized or a polymorphic multi-value `"type"`). For every other
  comparison, both operands are one of `:numeric | :string | :boolean |
  :array | :object`, and the full table is:

  | vs.      | numeric   | string    | boolean   | array     | object    |
  |----------|-----------|-----------|-----------|-----------|-----------|
  | numeric  | OK        | VIOLATION | VIOLATION | VIOLATION | VIOLATION |
  | string   | VIOLATION | OK        | VIOLATION | VIOLATION | VIOLATION |
  | boolean  | VIOLATION | VIOLATION | OK        | VIOLATION | VIOLATION |
  | array    | VIOLATION | VIOLATION | VIOLATION | VIOLATION | VIOLATION |
  | object   | VIOLATION | VIOLATION | VIOLATION | VIOLATION | VIOLATION |

  In words: each of the three primitive families (`:numeric`, `:string`,
  `:boolean`) is comparable only with itself; `:array` and `:object` are
  never comparable with anything, including themselves, in this grammar
  (REQ-197's `eval/2` has no defined structural-equality semantic for a CEL
  condition, and an `array`/`object` operand can only ever have reached a
  gateway condition through a declaration mistake). At minimum, this
  records numeric/money vs. text/string as non-comparable, satisfying this
  requirement's own explicit floor.

  ## HUMAN_TASK routing/assignment-by-field: OUT OF SCOPE (explicit, not a silent omission)

  This module's checks walk **only** `EXCLUSIVE_GATEWAY` edge conditions.
  No HUMAN_TASK attribute is walked, and no HUMAN_TASK-routing-by-field (or
  assignment-by-field) mechanism is designed or implemented here. This is
  a deliberate, grep-verified decision, not an oversight: no such
  mechanism exists anywhere in `lib/letflow/` today.
  `check_human_task_role/1` (`Letflow.Definitions.Graph`'s CHK-09) requires
  a HUMAN_TASK node's `attributes["role"]` to be a non-blank **plain
  string constant**, never an `Letflow.Engine.Expr` expression, and no
  HUMAN_TASK attribute is ever routed through `Letflow.Engine.Expr` at
  activation, task-creation, or anywhere else in the engine. There is
  therefore no existing "authored rule expression" on a HUMAN_TASK node for
  this pass to validate against `variable_schemas` at all — inventing one
  would require a separate, prerequisite requirement (a new node-attribute
  shape, a new consumption point in the engine, its own grammar/scope
  decisions) before any validation of it could even be designed. This gap
  is filed separately and is not solved here.

  ## Nested variable references

  `VariableSchema.variable_key` is a single flat string with no
  nested-path concept — `fetch_schemas/3` selects one row per
  `(definition_id, variable_key)` pair, not per JSON-pointer path into a
  schema's `"properties"`. A multi-segment reference
  (`variables.customer.name`, `path == ["customer", "name"]`) is therefore
  checked only at its root segment (`"customer"`); whether `"customer"`'s
  own declared `json_schema["properties"]` also declares `"name"` is never
  checked by this pass. That would be a materially different check
  (validating against a nested schema, not "is this top-level field
  declared") and is left to a distinct follow-up requirement.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Violation
  alias Letflow.Engine.Expr

  @typedoc "The comparability family a resolved operand belongs to."
  @type type_family :: :numeric | :string | :boolean | :array | :object | :unknown

  @typedoc """
  `variable_key -> its stored json_schema map`, exactly
  `Letflow.Engine.VariableSchema.fetch_schemas/3`'s `{:ok, schema_map}`
  payload.
  """
  @type declared_fields :: Letflow.Engine.VariableSchema.schema_map()

  # Sentinel families used only internally by operand_family/2 to mark an
  # operand that must be exempted from the comparability table entirely
  # (never surfaced as a real type_family() value).
  @typep operand_family :: type_family() | :null_literal | :unresolvable

  @doc """
  The single entry point. Walks every `EXCLUSIVE_GATEWAY`-sourced edge with
  a non-blank `condition`, and for each one collects every field-existence
  violation and every type-compatibility violation across the whole graph
  in one pass — never short-circuits, mirroring every existing `Graph`
  check's "never short-circuits" convention.
  """
  @spec validate(graph :: Graph.t(), declared_fields :: declared_fields()) :: Graph.result()
  def validate(%Graph{nodes: nodes, edges: edges}, declared_fields)
      when is_map(declared_fields) do
    node_index = build_node_index(nodes)

    violations =
      edges
      |> Enum.filter(&qualifying_edge?(nodes, node_index, &1))
      |> Enum.flat_map(&edge_violations(&1, declared_fields))

    %{valid: violations == [], violations: violations}
  end

  @doc """
  Classic Wagner-Fischer dynamic-programming edit distance, over
  `String.graphemes/1` (not byte-based — a multi-byte grapheme counts as
  one edit unit). Case-sensitive: `"Customer_Name"` and `"customer_name"`
  are one substitution apart, not identical — declared field names and
  authored references are both raw strings as typed, and case-folding
  would let a real typo go unreported as "close enough" while still
  failing the existence check.
  """
  @spec levenshtein_distance(a :: String.t(), b :: String.t()) :: non_neg_integer()
  def levenshtein_distance(a, b) when is_binary(a) and is_binary(b) do
    a_graphemes = String.graphemes(a)
    b_graphemes = String.graphemes(b)

    b_len = length(b_graphemes)
    first_row = Enum.to_list(0..b_len//1)

    a_graphemes
    |> Enum.with_index(1)
    |> Enum.reduce(first_row, fn {a_char, i}, prev_row ->
      {final_row, _last_diag} =
        b_graphemes
        |> Enum.with_index(1)
        |> Enum.reduce({[i], Enum.at(prev_row, 0)}, fn {b_char, j}, {row_acc, diag} ->
          above = Enum.at(prev_row, j)
          left = hd(row_acc)

          cost = if a_char == b_char, do: 0, else: 1

          value = Enum.min([above + 1, left + 1, diag + cost])

          {[value | row_acc], above}
        end)

      Enum.reverse(final_row)
    end)
    |> List.last()
  end

  @doc """
  Returns the element of `declared_field_names` with the minimum
  `levenshtein_distance/2` against `typed_name`; `nil` iff
  `declared_field_names == []`. Tie-break: the alphabetically-first
  (`String.<`) candidate among those sharing the minimum distance —
  deterministic regardless of map/list iteration order. No maximum-distance
  cutoff — a suggestion is always produced whenever at least one field is
  declared.
  """
  @spec nearest_declared_field(typed_name :: String.t(), declared_field_names :: [String.t()]) ::
          String.t() | nil
  def nearest_declared_field(_typed_name, []), do: nil

  def nearest_declared_field(typed_name, declared_field_names)
      when is_binary(typed_name) and is_list(declared_field_names) do
    declared_field_names
    |> Enum.map(fn name -> {levenshtein_distance(typed_name, name), name} end)
    |> Enum.sort(fn {dist_a, name_a}, {dist_b, name_b} ->
      {dist_a, name_a} <= {dist_b, name_b}
    end)
    |> List.first()
    |> elem(1)
  end

  # ---------------------------------------------------------------------------------
  # Edge selection (§2.1) -- the same "EXCLUSIVE_GATEWAY-sourced, non-blank
  # condition" set Graph's own CHK-13/CHK-17 already treat as "an
  # EXCLUSIVE_GATEWAY's own condition". HUMAN_TASK-sourced conditions are
  # not walked by this requirement (see moduledoc).
  # ---------------------------------------------------------------------------------

  @spec build_node_index([Graph.Node.t()]) :: %{String.t() => non_neg_integer()}
  defp build_node_index(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, index}, acc -> Map.put_new(acc, node.id, index) end)
  end

  @spec qualifying_edge?([Graph.Node.t()], %{String.t() => non_neg_integer()}, Graph.Edge.t()) ::
          boolean()
  defp qualifying_edge?(nodes, node_index, %Graph.Edge{} = edge) do
    exclusive_gateway_source?(nodes, node_index, edge) and not blank_condition?(edge.condition)
  end

  @spec exclusive_gateway_source?(
          [Graph.Node.t()],
          %{String.t() => non_neg_integer()},
          Graph.Edge.t()
        ) :: boolean()
  defp exclusive_gateway_source?(nodes, node_index, %Graph.Edge{source: source}) do
    with {:ok, index} <- Map.fetch(node_index, source),
         %Graph.Node{node_type: :EXCLUSIVE_GATEWAY} <- Enum.at(nodes, index) do
      true
    else
      _ -> false
    end
  end

  @spec blank_condition?(String.t() | nil) :: boolean()
  defp blank_condition?(nil), do: true
  defp blank_condition?(condition) when is_binary(condition), do: String.trim(condition) == ""

  # ---------------------------------------------------------------------------------
  # Per-edge violations: parse once (defensive-skip on translate/parse
  # failure -- CHK-17's job, not this module's), then run both checks
  # against the same parsed ast().
  # ---------------------------------------------------------------------------------

  @spec edge_violations(Graph.Edge.t(), declared_fields()) :: [Violation.t()]
  defp edge_violations(%Graph.Edge{} = edge, declared_fields) do
    case parse_condition(edge.condition) do
      {:ok, ast} ->
        field_existence_violations(edge, ast, declared_fields) ++
          type_compatibility_violations(edge, ast, declared_fields)

      :error ->
        []
    end
  end

  @spec parse_condition(String.t()) :: {:ok, Expr.ast()} | :error
  defp parse_condition(condition) do
    with {:ok, expr_source} <- Expr.translate_cel_to_expr(condition),
         {:ok, ast} <- Expr.parse_strict(expr_source) do
      {:ok, ast}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------------
  # Field-existence check (§2.2, AC1/AC2)
  # ---------------------------------------------------------------------------------

  @spec field_existence_violations(Graph.Edge.t(), Expr.ast(), declared_fields()) ::
          [Violation.t()]
  defp field_existence_violations(%Graph.Edge{} = edge, ast, declared_fields) do
    declared_names = Map.keys(declared_fields)

    ast
    |> collect_var_paths()
    |> Enum.filter(fn path -> not Map.has_key?(declared_fields, hd(path)) end)
    |> Enum.map(fn path -> undeclared_variable_violation(edge, hd(path), declared_names) end)
  end

  @spec undeclared_variable_violation(Graph.Edge.t(), String.t(), [String.t()]) :: Violation.t()
  defp undeclared_variable_violation(%Graph.Edge{} = edge, typed_root_segment, declared_names) do
    suggestion_clause =
      case nearest_declared_field(typed_root_segment, declared_names) do
        nil -> ""
        nearest -> "; nearest declared field: '#{nearest}'"
      end

    %Violation{
      code: :undeclared_variable_reference,
      message:
        "Edge '#{edge.id}' (from EXCLUSIVE_GATEWAY node '#{edge.source}') condition " <>
          "references undeclared variable '#{typed_root_segment}'" <>
          suggestion_clause <>
          "; rule as authored: \"#{edge.condition}\""
    }
  end

  # Walks ast() collecting every {:var, path} node's path, in traversal
  # order, not deduplicated (matching CHK-05/CHK-16's "N occurrences -> N
  # violations" convention).
  @spec collect_var_paths(Expr.ast()) :: [[String.t()]]
  defp collect_var_paths({:var, path}), do: [path]
  defp collect_var_paths({:lit, _value}), do: []
  defp collect_var_paths({:not, inner}), do: collect_var_paths(inner)
  defp collect_var_paths({:neg, inner}), do: collect_var_paths(inner)

  defp collect_var_paths({:and, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:or, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:cmp, _op, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:arith, _op, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  defp collect_var_paths({:call, _name, args}), do: Enum.flat_map(args, &collect_var_paths/1)

  # ---------------------------------------------------------------------------------
  # Type-compatibility check (§2.3, AC3)
  # ---------------------------------------------------------------------------------

  @spec type_compatibility_violations(Graph.Edge.t(), Expr.ast(), declared_fields()) ::
          [Violation.t()]
  defp type_compatibility_violations(%Graph.Edge{} = edge, ast, declared_fields) do
    ast
    |> collect_cmp_nodes()
    |> Enum.flat_map(fn {op, left, right} ->
      comparison_violation(edge, op, left, right, declared_fields)
    end)
  end

  # Walks ast() collecting every {:cmp, op, left, right} node encountered,
  # including ones nested under and/or/not -- all six cmp_op() values
  # treated identically (this check does not narrow to only the four
  # ordering operators; see moduledoc).
  @spec collect_cmp_nodes(Expr.ast()) :: [{Expr.cmp_op(), Expr.ast(), Expr.ast()}]
  defp collect_cmp_nodes({:cmp, op, left, right}) do
    [{op, left, right}] ++ collect_cmp_nodes(left) ++ collect_cmp_nodes(right)
  end

  defp collect_cmp_nodes({:lit, _value}), do: []
  defp collect_cmp_nodes({:var, _path}), do: []
  defp collect_cmp_nodes({:not, inner}), do: collect_cmp_nodes(inner)
  defp collect_cmp_nodes({:neg, inner}), do: collect_cmp_nodes(inner)

  defp collect_cmp_nodes({:and, left, right}),
    do: collect_cmp_nodes(left) ++ collect_cmp_nodes(right)

  defp collect_cmp_nodes({:or, left, right}),
    do: collect_cmp_nodes(left) ++ collect_cmp_nodes(right)

  defp collect_cmp_nodes({:arith, _op, left, right}),
    do: collect_cmp_nodes(left) ++ collect_cmp_nodes(right)

  defp collect_cmp_nodes({:call, _name, args}), do: Enum.flat_map(args, &collect_cmp_nodes/1)

  @spec comparison_violation(
          Graph.Edge.t(),
          Expr.cmp_op(),
          Expr.ast(),
          Expr.ast(),
          declared_fields()
        ) :: [Violation.t()]
  defp comparison_violation(%Graph.Edge{} = edge, op, left, right, declared_fields) do
    left_family = operand_family(left, declared_fields)
    right_family = operand_family(right, declared_fields)

    if exempt?(left_family) or exempt?(right_family) or comparable?(left_family, right_family) do
      []
    else
      [
        %Violation{
          code: :incompatible_comparison_operand_types,
          message:
            "Edge '#{edge.id}' (from EXCLUSIVE_GATEWAY node '#{edge.source}') condition " <>
              "compares incompatible types: '#{operand_repr(left)}' (#{left_family}) " <>
              "#{cmp_op_cel(op)} '#{operand_repr(right)}' (#{right_family}); " <>
              "rule as authored: \"#{edge.condition}\""
        }
      ]
    end
  end

  @spec exempt?(operand_family()) :: boolean()
  defp exempt?(:null_literal), do: true
  defp exempt?(:unresolvable), do: true
  defp exempt?(:unknown), do: true
  defp exempt?(_), do: false

  # Both operands are one of :numeric | :string | :boolean | :array | :object
  # by the time this is called (exempt?/1 already filtered the rest). :array
  # and :object are never comparable, including with themselves; the three
  # primitive families are pairwise incompatible and each is only
  # compatible with itself.
  @spec comparable?(type_family(), type_family()) :: boolean()
  defp comparable?(:array, _), do: false
  defp comparable?(_, :array), do: false
  defp comparable?(:object, _), do: false
  defp comparable?(_, :object), do: false
  defp comparable?(family, family), do: true
  defp comparable?(_left, _right), do: false

  @spec operand_family(Expr.ast(), declared_fields()) :: operand_family()
  defp operand_family({:lit, nil}, _declared_fields), do: :null_literal
  defp operand_family({:lit, v}, _declared_fields) when is_number(v), do: :numeric

  defp operand_family({:lit, marker}, _declared_fields)
       when marker in [:infinity, :neg_infinity, :nan],
       do: :numeric

  defp operand_family({:lit, v}, _declared_fields) when is_binary(v), do: :string
  defp operand_family({:lit, v}, _declared_fields) when is_boolean(v), do: :boolean

  defp operand_family({:var, path}, declared_fields) do
    case Map.fetch(declared_fields, hd(path)) do
      {:ok, json_schema} -> declared_type_family(json_schema)
      :error -> :unresolvable
    end
  end

  defp operand_family(_other, _declared_fields), do: :unknown

  @spec operand_repr(Expr.ast()) :: String.t()
  defp operand_repr({:var, path}), do: "variables." <> Enum.join(path, ".")
  defp operand_repr({:lit, value}), do: inspect(value)
  defp operand_repr(other), do: inspect(other)

  @spec cmp_op_cel(Expr.cmp_op()) :: String.t()
  defp cmp_op_cel(:eq), do: "=="
  defp cmp_op_cel(:neq), do: "!="
  defp cmp_op_cel(:lt), do: "<"
  defp cmp_op_cel(:lte), do: "<="
  defp cmp_op_cel(:gt), do: ">"
  defp cmp_op_cel(:gte), do: ">="

  # ---------------------------------------------------------------------------------
  # §2.3.1 -- resolving a stored json_schema's family
  # ---------------------------------------------------------------------------------

  @spec declared_type_family(json_schema :: map()) :: type_family()
  defp declared_type_family(json_schema) when is_map(json_schema) do
    case Map.get(json_schema, "type") do
      type when is_binary(type) ->
        family_of_type_name(type)

      types when is_list(types) ->
        families =
          types
          |> Enum.reject(&(&1 == "null"))
          |> Enum.map(&family_of_type_name/1)
          |> MapSet.new()

        case MapSet.to_list(families) do
          [single_family] -> single_family
          _ -> :unknown
        end

      _other ->
        :unknown
    end
  end

  @spec family_of_type_name(String.t()) :: type_family()
  defp family_of_type_name("string"), do: :string
  defp family_of_type_name("number"), do: :numeric
  defp family_of_type_name("integer"), do: :numeric
  defp family_of_type_name("boolean"), do: :boolean
  defp family_of_type_name("object"), do: :object
  defp family_of_type_name("array"), do: :array
  defp family_of_type_name(_other), do: :unknown
end
