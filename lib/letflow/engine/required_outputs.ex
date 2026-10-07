defmodule Letflow.Engine.RequiredOutputs do
  @moduledoc """
  Pure helpers for rule C of REQ-459 / REQ-460: the HUMAN_TASK node attribute
  `required_outputs` and the refusal of a task completion whose SUBMITTED output
  lacks a required key or carries a value a `variable_schema` rejects.

  Design: `lib/letflow/design/req459-required-outputs-and-distinct-person.md`
  sections 1.1, 2.2 (steps 4c and 6b) and 8.2. Every function here is pure and
  total (INV-8): no I/O, never raises, a malformed attribute is read as "off".

  ## What counts as "missing"

  A required key is missing when it is absent from the map OR present with a
  `nil` value (BA ruling 2026-10-07). An empty string is NOT missing: it is
  judged by the key's own `variable_schema` type and enum rules. Only the map
  handed to `missing_keys/2` counts -- callers pass the SUBMITTED (or the
  corrected) output, never the variables the instance already holds, so a value
  left over from an earlier rework pass does not satisfy the requirement.

  ## Names only (INV-2)

  `rejected_keys/3` restricts the keys it reports to the allowed set
  (`allowed_keys/2`): the task's own pinned `form_schema.properties` plus
  `required_outputs`. A rejection on any other key is still a refusal (see
  `any_rejected?/1`) but its NAME is not reported, so a task worker cannot probe
  which variable keys have a `variable_schema`.
  """

  require Logger

  alias Letflow.Definitions.Graph.Node
  alias Letflow.Engine.VariableMerge

  @doc """
  The node's `required_outputs` as a list of non-empty strings.

  Returns `[]` when the attribute is absent, `nil`, empty, not a list, or holds
  an entry that is not a non-empty string (the last two also log one warning
  naming only the node id). Unreachable for a definition that passed the
  validators; exists so a snapshot written by a path that bypassed validation
  cannot crash a completion.
  """
  @spec required_outputs(Node.t() | term()) :: [String.t()]
  def required_outputs(%Node{id: node_id, attributes: %{"required_outputs" => value}}) do
    case value do
      nil ->
        []

      [] ->
        []

      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          list
        else
          warn_malformed(node_id)
          []
        end

      _other ->
        warn_malformed(node_id)
        []
    end
  end

  def required_outputs(_node), do: []

  @doc """
  The required keys that are absent from `output_variables` or hold `nil`,
  sorted ascending and deduplicated.
  """
  @spec missing_keys(required :: [String.t()], output_variables :: map()) :: [String.t()]
  def missing_keys(required, output_variables)
      when is_list(required) and is_map(output_variables) do
    required
    |> Enum.filter(fn key -> is_nil(Map.get(output_variables, key)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def missing_keys(_required, _output_variables), do: []

  @doc """
  The keys whose validation outcome is `{:rejected, _}`, minus `exclude` (the
  keys already reported as missing), intersected with `allowed`; sorted
  ascending and deduplicated.
  """
  @spec rejected_keys(
          validations :: VariableMerge.variable_validations(),
          exclude :: [String.t()],
          allowed :: [String.t()]
        ) :: [String.t()]
  def rejected_keys(validations, exclude, allowed)
      when is_map(validations) and is_list(exclude) and is_list(allowed) do
    validations
    |> Enum.flat_map(fn
      {key, {:rejected, _failures}} -> [key]
      _other -> []
    end)
    |> Enum.reject(&(&1 in exclude))
    |> Enum.filter(&(&1 in allowed))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def rejected_keys(_validations, _exclude, _allowed), do: []

  @doc """
  Whether at least one key has a `{:rejected, _}` outcome, before any
  restriction to the allowed set.
  """
  @spec any_rejected?(VariableMerge.variable_validations()) :: boolean()
  def any_rejected?(validations) when is_map(validations) do
    Enum.any?(validations, fn
      {_key, {:rejected, _failures}} -> true
      _other -> false
    end)
  end

  def any_rejected?(_validations), do: false

  @doc """
  The keys a refusal may name: the keys of the task's own pinned
  `form_schema["properties"]` unioned with `required`; sorted and deduplicated.
  """
  @spec allowed_keys(form_schema :: map() | nil, required :: [String.t()]) :: [String.t()]
  def allowed_keys(form_schema, required) when is_list(required) do
    form_keys =
      case form_schema do
        %{"properties" => properties} when is_map(properties) -> Map.keys(properties)
        _other -> []
      end

    (form_keys ++ required)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def allowed_keys(_form_schema, _required), do: []

  defp warn_malformed(node_id) do
    Logger.warning(
      "HUMAN_TASK node #{inspect(node_id)} has a malformed required_outputs attribute; " <>
        "rule C is treated as off for it"
    )
  end
end
