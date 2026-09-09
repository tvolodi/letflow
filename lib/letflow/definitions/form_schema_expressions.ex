defmodule Letflow.Definitions.FormSchemaExpressions do
  @moduledoc """
  Definition-time validation of the three `x-ui` form-field logic keys
  (`visible_when`, `computed`, `cross_field_validation`) REQ-291 adds to the
  `x-ui` vocabulary REQ-284 established — see
  `lib/letflow/design/req291-x-ui-logic-keys.md` (the gate-approved design
  this module implements) and `docs/frontend/x-ui-widget-vocabulary.md` §6
  for the vocabulary-facing statement of these same semantics.

  Called from `Letflow.Definitions.Graph`'s CHK-20
  (`check_form_schema_expressions/1`), hooked into `validate_node_attributes/1`
  (PD-05), mirroring CHK-18's (`Letflow.Definitions.SubProcessInterface`)
  established shape: a pure, no-I/O leaf module with one list-returning
  entry point per node, delegated to from `Graph`.

  ## Purity

  Depends on Elixir/Erlang stdlib and `Letflow.Engine.Expr` only — no
  `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no
  HTTP/file/process-mailbox call anywhere, matching `Graph`'s and
  `SubProcessInterface`'s own zero-I/O contract.

  ## No evaluator

  This module never calls `Letflow.Engine.Expr.eval/2`. It calls
  `translate_cel_to_expr/1` and `parse_strict/1` only — the same
  definition-time-only pair REQ-288 already established for edge
  conditions. Nothing here computes what a `computed` field's value *would
  be*; it only checks that each expression is well-formed and in-scope, and
  that no `computed`-field reference cycle exists.

  ## Hook point and non-goals (design doc §2)

  Extracted from a `:HUMAN_TASK` node's `attributes["form_schema"]` only —
  the only node type `Letflow.Engine.TaskActivation` ever resolves a
  `form_schema` for. If `form_schema` is absent, not a map, or fails
  `Letflow.Definitions.JsonSchemaShape.check/1`'s own structural predicate,
  `validate_node_form_schema/2` returns `[]` — general `form_schema` shape
  validation stays exactly where REQ-273 put it (activation time,
  `Letflow.Engine.TaskActivation.resolve_form_schema/1`); this module does
  not move or duplicate that check.

  ## Scope rule (design doc §4.2)

  A field expression may reference only the flat, top-level keys of the
  same `form_schema`'s `"properties"` map, as bare single-segment
  identifiers — no `"variables."` prefix, no dotted/multi-segment path.
  """

  alias Letflow.Definitions.Graph.Violation
  alias Letflow.Definitions.JsonSchemaShape
  alias Letflow.Engine.Expr

  @doc """
  Check-list entry point (CHK-20) — extracts `attributes["form_schema"]`
  (if `attributes` is a map, and `form_schema` is a well-formed JSON Schema
  document per `JsonSchemaShape.check/1`), validates every field's
  `x-ui.visible_when`/`x-ui.computed`/`x-ui.cross_field_validation` key, and
  returns just the violations. Total and defensive: never raises, always
  returns a list (possibly `[]`).
  """
  @spec validate_node_form_schema(node_id :: String.t(), attributes :: map() | nil) ::
          [Violation.t()]
  def validate_node_form_schema(_node_id, attributes) do
    case extract_form_schema(attributes) do
      nil ->
        []

      form_schema ->
        properties = extract_properties(form_schema)
        top_level_keys = MapSet.new(Map.keys(properties))

        field_violations =
          Enum.flat_map(properties, fn {field_name, field_schema} ->
            check_field(field_name, field_schema, top_level_keys)
          end)

        field_violations ++ check_cycles(properties)
    end
  end

  @spec extract_form_schema(map() | nil) :: map() | nil
  defp extract_form_schema(attributes) when is_map(attributes) do
    case Map.get(attributes, "form_schema") do
      nil ->
        nil

      form_schema ->
        if JsonSchemaShape.check(form_schema) == :ok, do: form_schema, else: nil
    end
  end

  defp extract_form_schema(_attributes), do: nil

  @spec extract_properties(map()) :: map()
  defp extract_properties(form_schema) do
    case Map.get(form_schema, "properties", %{}) do
      properties when is_map(properties) -> properties
      _not_a_map -> %{}
    end
  end

  # One field's x-ui.visible_when / x-ui.computed / x-ui.cross_field_validation,
  # each checked independently -- a malformed/invalid/out-of-scope key never
  # short-circuits checking the other two keys on the same field.
  @spec check_field(String.t(), term(), MapSet.t(String.t())) :: [Violation.t()]
  defp check_field(field_name, field_schema, top_level_keys) do
    x_ui =
      case field_schema do
        %{"x-ui" => x} when is_map(x) -> x
        _other -> %{}
      end

    {visible_when_violations, _ast} =
      validate_string_expr_key(
        field_name,
        "visible_when",
        Map.get(x_ui, "visible_when"),
        top_level_keys
      )

    {computed_violations, _ast} =
      validate_string_expr_key(field_name, "computed", Map.get(x_ui, "computed"), top_level_keys)

    cross_field_violations =
      validate_cross_field_validation(
        field_name,
        Map.get(x_ui, "cross_field_validation"),
        top_level_keys
      )

    visible_when_violations ++ computed_violations ++ cross_field_violations
  end

  # visible_when / computed: absent -> no violation; present and not a
  # string -> :form_schema_x_ui_logic_malformed; present and a string ->
  # full expression validation (§4.1/§4.2).
  @spec validate_string_expr_key(String.t(), String.t(), term(), MapSet.t(String.t())) ::
          {[Violation.t()], Expr.ast() | nil}
  defp validate_string_expr_key(_field_name, _key, nil, _top_level_keys), do: {[], nil}

  defp validate_string_expr_key(field_name, key, value, top_level_keys) when is_binary(value) do
    validate_expr_string(field_name, key, value, top_level_keys)
  end

  defp validate_string_expr_key(field_name, key, _value, _top_level_keys) do
    {[malformed_violation(field_name, key, "expected a string")], nil}
  end

  # cross_field_validation: absent -> no violation; present and not a
  # well-formed %{"expression" => string, "message" => string} shape ->
  # :form_schema_x_ui_logic_malformed; well-formed -> validate the
  # "expression" string exactly like visible_when/computed.
  @spec validate_cross_field_validation(String.t(), term(), MapSet.t(String.t())) ::
          [Violation.t()]
  defp validate_cross_field_validation(_field_name, nil, _top_level_keys), do: []

  defp validate_cross_field_validation(field_name, value, top_level_keys) when is_map(value) do
    expression = Map.get(value, "expression")
    message = Map.get(value, "message")

    cond do
      not is_binary(expression) ->
        [
          malformed_violation(
            field_name,
            "cross_field_validation",
            "'expression' is missing or not a string"
          )
        ]

      not is_binary(message) ->
        [
          malformed_violation(
            field_name,
            "cross_field_validation",
            "'message' is missing or not a string"
          )
        ]

      true ->
        {violations, _ast} =
          validate_expr_string(field_name, "cross_field_validation", expression, top_level_keys)

        violations
    end
  end

  defp validate_cross_field_validation(field_name, _not_a_map, _top_level_keys) do
    [
      malformed_violation(
        field_name,
        "cross_field_validation",
        "expected an object with 'expression' and 'message' string keys"
      )
    ]
  end

  # Runs one field expression string through the real grammar (mirrors
  # Graph's own cel_grammar_error/1 for edge conditions, REQ-288) and, on a
  # successful parse, checks the resulting ast()'s variable scope (§4.2).
  @spec validate_expr_string(String.t(), String.t(), String.t(), MapSet.t(String.t())) ::
          {[Violation.t()], Expr.ast() | nil}
  defp validate_expr_string(field_name, key, expr_string, top_level_keys) do
    case Expr.translate_cel_to_expr(expr_string) do
      {:error, :unsupported_cel_feature} ->
        {[
           invalid_violation(
             field_name,
             key,
             "uses a CEL construct this grammar does not support (unsupported call, `in`, or `?`)"
           )
         ], nil}

      {:error, :translate_error} ->
        {[
           invalid_violation(
             field_name,
             key,
             "could not be translated to a well-formed expression"
           )
         ], nil}

      {:ok, expr_source} ->
        case Expr.parse_strict(expr_source) do
          {:ok, ast} ->
            {check_scope(field_name, key, ast, top_level_keys), ast}

          {:error, %{line: line, column: column, token_text: token_text, message: message}} ->
            {[
               invalid_violation(
                 field_name,
                 key,
                 "failed validation at line #{line}, column #{column} " <>
                   "(near '#{token_text}'): #{message}"
               )
             ], nil}
        end
    end
  end

  # §4.2: a parsed ast() may only reference single-segment bare identifiers
  # that are members of top_level_keys -- a multi-segment path is always
  # out of scope, unconditionally.
  @spec check_scope(String.t(), String.t(), Expr.ast(), MapSet.t(String.t())) :: [Violation.t()]
  defp check_scope(field_name, key, ast, top_level_keys) do
    ast
    |> collect_var_paths()
    |> Enum.filter(fn path ->
      length(path) != 1 or not MapSet.member?(top_level_keys, hd(path))
    end)
    |> Enum.map(fn path ->
      var_name = Enum.join(path, ".")

      %Violation{
        code: :form_schema_expression_out_of_scope,
        message:
          "Field '#{field_name}' x-ui.#{key} expression references undeclared variable " <>
            "'#{var_name}' — not a property of this form_schema"
      }
    end)
  end

  @doc """
  Walks a parsed `Letflow.Engine.Expr.ast()` and collects every `{:var,
  path}` node's `path`, in traversal order (duplicates included). The one
  shared AST walker feeding both the scope check (`check_scope/4`) and the
  computed-field dependency graph (`build_computed_dependency_graph/1`).
  """
  @spec collect_var_paths(Expr.ast()) :: [[String.t()]]
  def collect_var_paths({:lit, _value}), do: []
  def collect_var_paths({:var, path}), do: [path]
  def collect_var_paths({:not, ast}), do: collect_var_paths(ast)
  def collect_var_paths({:neg, ast}), do: collect_var_paths(ast)

  def collect_var_paths({:and, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  def collect_var_paths({:or, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  def collect_var_paths({:cmp, _op, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  def collect_var_paths({:arith, _op, left, right}),
    do: collect_var_paths(left) ++ collect_var_paths(right)

  def collect_var_paths({:call, _name, args}), do: Enum.flat_map(args, &collect_var_paths/1)

  # --- §4.4: computed-field dependency graph + cycle detection --------------

  @spec check_cycles(properties :: map()) :: [Violation.t()]
  defp check_cycles(properties) do
    properties
    |> build_computed_dependency_graph()
    |> find_cycle()
    |> case do
      nil ->
        []

      cycle ->
        [
          %Violation{
            code: :form_schema_computed_field_cycle,
            message:
              "Computed-field dependency cycle: #{Enum.join(cycle, " -> ")} -> #{List.first(cycle)}"
          }
        ]
    end
  end

  @doc """
  Builds the computed-field dependency graph (§4.4): nodes are the field
  names carrying an `x-ui.computed` key; a directed edge `A -> B` exists
  when field `A`'s `computed` expression's `ast()` contains a `{:var, [B]}`
  reference and `B` also carries an `x-ui.computed` key. A `computed`
  expression that itself fails to translate/parse contributes no edges
  here — that failure is already reported as
  `:form_schema_expression_invalid` by `check_field/3`, independently of
  cycle detection.
  """
  @spec build_computed_dependency_graph(properties :: map()) ::
          %{optional(String.t()) => [String.t()]}
  def build_computed_dependency_graph(properties) do
    computed_field_names =
      properties
      |> Enum.filter(fn {_name, schema} -> computed_expression(schema) != nil end)
      |> Enum.map(fn {name, _schema} -> name end)
      |> MapSet.new()

    computed_field_names
    |> Enum.map(fn name ->
      schema = Map.fetch!(properties, name)
      {name, computed_dependencies(computed_expression(schema), computed_field_names)}
    end)
    |> Map.new()
  end

  @spec computed_expression(term()) :: String.t() | nil
  defp computed_expression(schema) when is_map(schema) do
    case Map.get(schema, "x-ui") do
      x_ui when is_map(x_ui) ->
        case Map.get(x_ui, "computed") do
          value when is_binary(value) -> value
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp computed_expression(_schema), do: nil

  @spec computed_dependencies(String.t(), MapSet.t(String.t())) :: [String.t()]
  defp computed_dependencies(expr_string, computed_field_names) do
    with {:ok, expr_source} <- Expr.translate_cel_to_expr(expr_string),
         {:ok, ast} <- Expr.parse_strict(expr_source) do
      ast
      |> collect_var_paths()
      |> Enum.filter(&(length(&1) == 1))
      |> Enum.map(&hd/1)
      |> Enum.filter(&MapSet.member?(computed_field_names, &1))
      |> Enum.uniq()
    else
      _error -> []
    end
  end

  @doc """
  Standard depth-first-search cycle detection over the dependency graph
  `build_computed_dependency_graph/1` returns — a "currently on the DFS
  stack" check that uniformly catches a self-reference, a 2-node cycle and
  an N-node cycle alike (§4.4). Returns the ordered list of field names
  forming the first cycle found, or `nil` if the graph is acyclic.
  """
  @spec find_cycle(graph :: %{optional(String.t()) => [String.t()]}) :: [String.t()] | nil
  def find_cycle(graph) do
    graph
    |> Map.keys()
    |> Enum.find_value(fn root -> dfs_cycle(root, graph, [], MapSet.new()) end)
  end

  @spec dfs_cycle(String.t(), map(), [String.t()], MapSet.t(String.t())) :: [String.t()] | nil
  defp dfs_cycle(node, graph, path, on_stack) do
    if MapSet.member?(on_stack, node) do
      cycle_start = Enum.find_index(path, &(&1 == node))
      Enum.slice(path, cycle_start, length(path) - cycle_start)
    else
      new_path = path ++ [node]
      new_stack = MapSet.put(on_stack, node)

      graph
      |> Map.get(node, [])
      |> Enum.find_value(fn neighbor -> dfs_cycle(neighbor, graph, new_path, new_stack) end)
    end
  end

  @spec malformed_violation(String.t(), String.t(), String.t()) :: Violation.t()
  defp malformed_violation(field_name, key, reason) do
    %Violation{
      code: :form_schema_x_ui_logic_malformed,
      message: "Field '#{field_name}' x-ui.#{key} is malformed: #{reason}"
    }
  end

  @spec invalid_violation(String.t(), String.t(), String.t()) :: Violation.t()
  defp invalid_violation(field_name, key, reason) do
    %Violation{
      code: :form_schema_expression_invalid,
      message: "Field '#{field_name}' x-ui.#{key} expression #{reason}"
    }
  end

  # --- §4.3/§4.5: pinned semantics not executed by this (definition-time
  # only) validator, stated here as accessors so REQ-292 (Elixir),
  # REQ-293 (TypeScript) and REQ-294 (Dart) agree without conferring. ------

  @doc """
  §4.3's pinned single behaviour: a `computed` field whose expression
  evaluation fails for *any* reason (an absent referenced field, a
  referenced field holding an explicit JSON `null` that causes a downstream
  type-mismatch, or any other `Expr.eval/2` eval-error) evaluates the field
  to `nil` — one behaviour, not a per-cause table. Not executed by this
  module (no evaluator is in scope for REQ-291); pinned here so
  REQ-292/293/294 do not each independently guess.
  """
  @spec computed_field_absent_or_null_input_result() :: :nil_value
  def computed_field_absent_or_null_input_result, do: :nil_value

  @doc """
  §4.5's pinned decision: a `visible_when`-hidden field's value is
  submitted, not dropped or retained-only, client-side. The server (REQ-292)
  is what turns "submitted" into "trusted or not."
  """
  @spec hidden_field_submit_disposition() :: :submitted_as_untrusted_input
  def hidden_field_submit_disposition, do: :submitted_as_untrusted_input

  @doc """
  §4.5's pinned decision: a `computed` field's value is submitted, not
  dropped, client-side, even though the server (REQ-292) recomputes and
  authoritatively checks it.
  """
  @spec computed_field_submit_disposition() :: :submitted_as_untrusted_input
  def computed_field_submit_disposition, do: :submitted_as_untrusted_input
end
