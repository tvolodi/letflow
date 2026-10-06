defmodule Letflow.Definitions.RoleBinding do
  @moduledoc """
  Advisory listing of human-task roles that have no `tenant_role` binding in a
  tenant (REQ-455 check 4). A pure core (`task_roles/1`, `unbound/2`,
  `format_warning/2`) and one impure read (`bound_role_names/1`).

  Never writes: no binding is ever created here, and the result is a warning
  list, not a violation (Decision 0029 section 2 keeps required roles advisory
  and role seeding out of packs).
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Identity.RoleRegistry

  @type task_role :: %{role_name: String.t(), node_ids: [String.t()]}

  @doc """
  Every role a HUMAN_TASK routes to (`attributes["role"]` and
  `attributes["escalation_role"]`, each when a non-blank binary, used raw),
  grouped by role name. `role_name` and `node_ids` are sorted ascending and
  deduplicated. Total on malformed attributes.
  """
  @spec task_roles(Graph.t()) :: [task_role()]
  def task_roles(%Graph{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK and is_map(&1.attributes)))
    |> Enum.flat_map(fn node ->
      for key <- ["role", "escalation_role"],
          name = Map.get(node.attributes, key),
          is_binary(name) and String.trim(name) != "",
          do: {name, node.id}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, ids} ->
      %{role_name: name, node_ids: ids |> Enum.uniq() |> Enum.sort()}
    end)
    |> Enum.sort_by(& &1.role_name)
  end

  @doc "Keeps the task roles whose name is not in `bound_names`, order preserved."
  @spec unbound([task_role()], MapSet.t(String.t())) :: [task_role()]
  def unbound(task_roles, %MapSet{} = bound_names) do
    Enum.reject(task_roles, &MapSet.member?(bound_names, &1.role_name))
  end

  @doc """
  Names of the roles bound in this tenant's `tenant_role` table (any `kind`),
  read through the prefix-scoped `RoleRegistry.list_roles/1`.
  """
  @spec bound_role_names(opts :: [prefix: String.t()]) :: MapSet.t(String.t())
  def bound_role_names(opts) do
    opts |> RoleRegistry.list_roles() |> MapSet.new(& &1.name)
  end

  @doc "The single place the wire text of an unbound-role warning is built."
  @spec format_warning(definition_name :: String.t(), task_role()) :: String.t()
  def format_warning(definition_name, %{role_name: role_name, node_ids: node_ids}) do
    "unbound_task_role: #{role_name} (definition '#{definition_name}', nodes: " <>
      Enum.join(node_ids, ", ") <> ")"
  end

  @doc """
  One warning per (definition, unbound role), definitions in input order. One
  `bound_role_names/1` read in total. `[]` when nothing is unbound.
  """
  @spec warnings_for_definitions([{String.t(), Graph.t()}], opts :: [prefix: String.t()]) ::
          [String.t()]
  def warnings_for_definitions(definitions, opts) do
    bound = bound_role_names(opts)

    Enum.flat_map(definitions, fn {name, %Graph{} = graph} ->
      graph |> task_roles() |> unbound(bound) |> Enum.map(&format_warning(name, &1))
    end)
  end
end
