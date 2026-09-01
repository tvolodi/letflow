defmodule Letflow.Simulation.Seed do
  @moduledoc """
  Test-support module that provisions the three simulation companies (SwiftRoute,
  Vortex, Meridian) into a running Letflow instance by calling Letflow's own
  context modules directly — no HTTP client, no Python subprocess.

  Each seed function is idempotent: a second call for the same entity is a no-op
  (the existing record is left unchanged), mirroring R-Co seed.py's
  "409 means already exists" contract.

  ## Mapping from R-Co seed.py to Letflow context modules

  | seed.py action               | Letflow call                                         |
  |------------------------------|------------------------------------------------------|
  | POST /api/v1/onboarding      | `Identity.create_tenant/1` + `TenantOnboarding.provision_and_migrate/1` + `Identity.create_onboarding/1` |
  | POST /api/v1/users           | `Identity.create_user/2`                            |
  | POST /api/v1/admin/groups    | `Identity.create_group/2` + `Identity.add_group_member/3` |
  | POST /api/v1/definitions     | `Definitions.create/2` + `Definitions.activate/2`   |

  ## YAML-parsing dependency (REQ-205 AC7)

  Uses `yaml_elixir` (`:test`-only dep, mix.exs) to parse fixture files. REVIEWER
  sign-off recorded in REQ-205's PR as required by the new-top-level-dep precedent
  (REQ-148/REQ-165).

  ## Distinction from Letflow.Routers.SimulationTest / simulation_test.zig

  This module is a TEST-PROVISIONING tool for the S7 correctness gate. It is
  unrelated to `Letflow.Routers.SimulationTest` and R-Co's
  `src/api/routes/simulation_test.zig` / `src/simulation/scenario_runner.zig`,
  which are a design-time dry-run tool for validating a candidate process
  DEFINITION against a schema+event-trace assertion set. Those share the word
  "simulation" and nothing else: different input shape, different caller, different
  question answered. This requirement does NOT build `Letflow.Routers.SimulationTest`;
  that router slot remains reserved in `Letflow.Router` for S7 scope. See
  `Letflow.Simulation.Runner`'s moduledoc for the same clarification from the
  runner side.
  """

  alias Letflow.Definitions
  alias Letflow.Identity
  alias Letflow.TenantOnboarding

  # Migrator needs its own connection checkout, same as TenantFixture.provisioned_tenant!/1.
  alias Ecto.Adapters.SQL.Sandbox

  @fixtures_dir Path.expand("../../fixtures/simulation", __DIR__)

  @type company_id :: String.t()
  @type schema_name :: String.t()
  @type actor_map :: %{String.t() => Ecto.UUID.t()}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Seeds all three companies. Returns a map keyed by company_id with tenant and
  actor information for use in subsequent test assertions or Runner calls.
  """
  @spec seed_all([company_id()]) ::
          {:ok, %{company_id() => %{tenant_id: Ecto.UUID.t(), schema_name: schema_name(), actors: actor_map()}}}
  def seed_all(company_ids \\ ["swiftroute", "vortex", "meridian"]) do
    result =
      Enum.reduce_while(company_ids, {:ok, %{}}, fn company_id, {:ok, acc} ->
        with {:ok, %{tenant_id: tenant_id, schema_name: schema_name}} <- seed_company(company_id),
             {:ok, actors} <- seed_users(company_id, schema_name),
             {:ok, _groups} <- seed_groups(company_id, schema_name, actors),
             {:ok, _defs} <- seed_processes(company_id, schema_name) do
          {:cont, {:ok, Map.put(acc, company_id, %{tenant_id: tenant_id, schema_name: schema_name, actors: actors})}}
        else
          {:error, reason} -> {:halt, {:error, {company_id, reason}}}
        end
      end)

    result
  end

  @doc """
  Provisions a company's tenant: creates the `Tenant` row, provisions its Postgres
  schema, replays migrations, and records the `OnboardingRecord`. Idempotent —
  a second call with the same `company_id` returns `{:ok, existing}`.

  Returns `{:ok, %{tenant_id: uuid, schema_name: string}}`.
  """
  @spec seed_company(company_id()) ::
          {:ok, %{tenant_id: Ecto.UUID.t(), schema_name: schema_name()}} | {:error, term()}
  def seed_company(company_id) do
    # Migrator checks out its own connection; Sandbox must be in :auto mode.
    # Matches TenantFixture.provisioned_tenant!/1's identical step 1.
    Sandbox.mode(Letflow.Repo, :auto)

    company = read_fixture!(company_id, "company.yaml")
    slug = company["id"]
    display_name = company["name"]
    hostname = "#{slug}.sim.example"

    case Identity.create_tenant(%{"slug" => slug, "display_name" => display_name}) do
      {:ok, tenant} ->
        with {:ok, _reg} <- TenantOnboarding.provision_and_migrate(tenant.id),
             {:ok, schema_name} <- schema_name_for(tenant.id),
             {:ok, _record} <-
               Identity.create_onboarding(%{
                 tenant_id: tenant.id,
                 slug: slug,
                 hostname: hostname
               }) do
          {:ok, %{tenant_id: tenant.id, schema_name: schema_name}}
        end

      {:error, :duplicate_slug} ->
        # Tenant already exists; re-run provision_and_migrate to ensure the
        # schema exists and is fully migrated (the TenantSchemaReaper may have
        # swept it between test runs while leaving the tenant row).
        case Identity.get_tenant_by_slug(slug) do
          {:ok, tenant} ->
            with {:ok, _reg} <- TenantOnboarding.provision_and_migrate(tenant.id),
                 {:ok, schema_name} <- schema_name_for(tenant.id) do
              # Onboarding record is idempotent (duplicate_hostname is OK)
              _ = Identity.create_onboarding(%{tenant_id: tenant.id, slug: slug, hostname: hostname})
              {:ok, %{tenant_id: tenant.id, schema_name: schema_name}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates Letflow `User` records for every person in `org_structure.yaml`.
  Returns `{:ok, actor_map}` where `actor_map` maps each R-Co `actor_id` to
  the Letflow user UUID (for use by the Runner and downstream scenario tests).

  Idempotent: a `:duplicate_username` error means the user already exists; the
  user is looked up by email and included in the returned map.
  """
  @spec seed_users(company_id(), schema_name()) :: {:ok, actor_map()} | {:error, term()}
  def seed_users(company_id, schema_name) do
    %{"people" => people} = read_fixture!(company_id, "org_structure.yaml")
    opts = [prefix: schema_name]

    result =
      Enum.reduce_while(people, {:ok, %{}}, fn person, {:ok, acc} ->
        username = username_from_email(person["email"])

        attrs = %{
          "username" => username,
          "display_name" => person["name"],
          "email" => person["email"]
        }

        case Identity.create_user(attrs, opts) do
          {:ok, user} ->
            {:cont, {:ok, Map.put(acc, person["actor_id"], user.id)}}

          {:error, :duplicate_username} ->
            # User already exists — look up by username to get the id
            case find_user_by_username(username, opts) do
              {:ok, user} -> {:cont, {:ok, Map.put(acc, person["actor_id"], user.id)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    result
  end

  @doc """
  Creates one `Group` per department and adds the relevant people as members.
  Returns `{:ok, dept_to_group_map}`.

  Idempotent: `:duplicate_group_name` means the group already exists; it is
  looked up and members are added idempotently via `add_group_member/3`'s own
  idempotency.
  """
  @spec seed_groups(company_id(), schema_name(), actor_map()) ::
          {:ok, %{String.t() => Ecto.UUID.t()}} | {:error, term()}
  def seed_groups(company_id, schema_name, actors) do
    org = read_fixture!(company_id, "org_structure.yaml")
    departments = org["departments"] || []
    people = org["people"] || []
    opts = [prefix: schema_name]

    # Build dept_id → [user_id] membership from people list
    dept_members =
      Enum.reduce(people, %{}, fn person, acc ->
        user_id = Map.get(actors, person["actor_id"])

        if user_id do
          Map.update(acc, person["department_id"], [user_id], &[user_id | &1])
        else
          acc
        end
      end)

    Enum.reduce_while(departments, {:ok, %{}}, fn dept, {:ok, acc} ->
      case ensure_group(dept["id"], dept["name"], opts) do
        {:ok, group} ->
          member_ids = Map.get(dept_members, dept["id"], [])

          member_result =
            Enum.reduce_while(member_ids, :ok, fn user_id, :ok ->
              case Identity.add_group_member(group.id, user_id, opts) do
                {:ok, _} -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)

          case member_result do
            :ok -> {:cont, {:ok, Map.put(acc, dept["id"], group.id)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Creates and activates one `ProcessDefinition` per process YAML fixture for
  the given company. Returns `{:ok, [ProcessDefinition.t()]}`.

  Idempotent: `:duplicate_name_version` means the definition already exists
  with the same (name, version) key; it is skipped and not included in the
  returned list (the caller should not care about already-existing definitions).
  """
  @spec seed_processes(company_id(), schema_name()) ::
          {:ok, [Letflow.Definitions.ProcessDefinition.t()]} | {:error, term()}
  def seed_processes(company_id, schema_name) do
    process_files = list_process_files(company_id)

    Enum.reduce_while(process_files, {:ok, []}, fn file, {:ok, acc} ->
      case seed_process(company_id, file, schema_name) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, defs} -> {:ok, Enum.reverse(defs)}
      error -> error
    end
  end

  @doc """
  Creates and activates a single process definition from a fixture file.
  Returns `{:error, :already_exists}` if the (name, version) pair is already
  present (idempotency — caller may ignore or collect separately).
  """
  @spec seed_process(company_id(), String.t(), schema_name()) ::
          {:ok, Letflow.Definitions.ProcessDefinition.t()}
          | {:error, :already_exists}
          | {:error, term()}
  def seed_process(company_id, process_file, schema_name) do
    proc = read_fixture!(company_id, process_file)
    graph = translate_graph(proc)
    name = proc["name"]
    version = proc["version"] || "1.0"

    attrs = %{
      name: name,
      version: version,
      description: proc["description"],
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    opts = [prefix: schema_name]

    case Definitions.create(attrs, opts) do
      {:ok, definition} ->
        case Definitions.activate(definition.id, opts) do
          {:ok, %{definition: activated}} -> {:ok, activated}
          {:error, reason} -> {:error, reason}
        end

      {:error, :duplicate_name_version} ->
        # Already exists — look up and return the existing active definition
        case Definitions.get_active_by_name(name, opts) do
          {:ok, existing} -> {:ok, existing}
          {:error, :not_found} -> {:error, :already_exists}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Graph translation ───────────────────────────────────────────────────────

  # Translates R-Co's YAML process format to Letflow's graph map format.
  # Handles:
  #   - node type mapping (user-task → HUMAN_TASK, etc.)
  #   - edge from/to → source/target with IDs generated by index
  #   - branch condition resolution for edges using `via: branch-xxx`
  #   - on_timeout implicit edges (where the target node exists in the graph)
  #   - fallback edge injection for HUMAN_TASK nodes with all-conditioned outgoing
  @spec translate_graph(map()) :: map()
  defp translate_graph(proc) do
    raw_nodes = proc["nodes"] || []
    raw_edges = proc["edges"] || []

    node_ids = MapSet.new(raw_nodes, & &1["id"])
    branch_index = build_branch_index(raw_nodes)

    # Translate explicit edges
    translated_edges =
      raw_edges
      |> Enum.with_index()
      |> Enum.map(fn {edge, i} ->
        condition = edge["condition"] || lookup_branch_condition(edge["via"], branch_index)

        %{"id" => "e#{i}", "source" => edge["from"], "target" => edge["to"]}
        |> maybe_put_condition(condition)
      end)

    # Add on_timeout edges where the target node exists
    timeout_edges =
      raw_nodes
      |> Enum.filter(& &1["on_timeout"])
      |> Enum.filter(fn node -> MapSet.member?(node_ids, node["on_timeout"]) end)
      |> Enum.with_index(length(translated_edges))
      |> Enum.map(fn {node, i} ->
        %{"id" => "e#{i}", "source" => node["id"], "target" => node["on_timeout"]}
      end)

    all_edges = translated_edges ++ timeout_edges

    # Translate nodes
    nodes =
      Enum.map(raw_nodes, fn node ->
        node_type = translate_node_type(node["type"])
        attrs = build_node_attributes(node, node_type)

        base = %{"id" => node["id"], "node_type" => node_type}
        if attrs, do: Map.put(base, "attributes", attrs), else: base
      end)

    # Add fallback edges for HUMAN_TASK nodes missing one
    final_edges = inject_fallback_edges(nodes, all_edges)

    %{"nodes" => nodes, "edges" => final_edges}
  end

  # Build a map from branch_id → condition string, scanning all nodes' branches.
  @spec build_branch_index([map()]) :: %{String.t() => String.t()}
  defp build_branch_index(nodes) do
    Enum.reduce(nodes, %{}, fn node, acc ->
      branches = node["branches"] || []

      Enum.reduce(branches, acc, fn branch, acc ->
        if branch["id"] && branch["condition"] do
          Map.put(acc, branch["id"], branch["condition"])
        else
          acc
        end
      end)
    end)
  end

  @spec lookup_branch_condition(String.t() | nil, map()) :: String.t() | nil
  defp lookup_branch_condition(nil, _index), do: nil
  defp lookup_branch_condition(via, index), do: Map.get(index, via)

  @node_type_map %{
    "start" => "START",
    "end" => "END",
    "user-task" => "HUMAN_TASK",
    # multi-voter-task maps to HUMAN_TASK (closest Letflow equivalent)
    "multi-voter-task" => "HUMAN_TASK",
    "service-task" => "SERVICE_TASK",
    "exclusive-gateway" => "EXCLUSIVE_GATEWAY",
    "parallel-gateway" => "PARALLEL_GATEWAY",
    "sub-process" => "SUB_PROCESS"
  }

  @spec translate_node_type(String.t() | nil) :: String.t()
  defp translate_node_type(type),
    do: Map.get(@node_type_map, type, "SERVICE_TASK")

  @spec build_node_attributes(map(), String.t()) :: map() | nil
  defp build_node_attributes(node, "HUMAN_TASK") do
    # user-task uses assignee_role; multi-voter-task uses voter_role
    role = node["assignee_role"] || node["voter_role"]
    if role, do: %{"role" => role}, else: nil
  end

  defp build_node_attributes(node, "SERVICE_TASK") do
    endpoint = node["endpoint"]
    # CHK-11: SERVICE_TASK requires timeout_ms (integer 1..300_000).
    # R-Co service tasks use timeout_hours on user-tasks only; for service
    # tasks we default to 300_000ms (5 min, the Letflow maximum) as a
    # fixture-appropriate ceiling that keeps all 8 process definitions valid.
    timeout_ms =
      case node["timeout_hours"] do
        hours when is_number(hours) -> min(round(hours * 3_600_000), 300_000)
        _ -> 300_000
      end

    base = %{"timeout_ms" => timeout_ms}
    if endpoint, do: Map.put(base, "endpoint", endpoint), else: base
  end

  defp build_node_attributes(_node, _type), do: nil

  @spec maybe_put_condition(map(), String.t() | nil) :: map()
  defp maybe_put_condition(edge, nil), do: edge
  defp maybe_put_condition(edge, ""), do: edge
  defp maybe_put_condition(edge, condition), do: Map.put(edge, "condition", condition)

  # For each HUMAN_TASK with at least one "really conditioned" outgoing edge
  # but no fallback candidate, inject a synthetic fallback edge (nil condition)
  # pointing to the same target as the first conditioned edge.
  @spec inject_fallback_edges([map()], [map()]) :: [map()]
  defp inject_fallback_edges(nodes, edges) do
    human_task_ids =
      nodes
      |> Enum.filter(&(&1["node_type"] == "HUMAN_TASK"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    extra =
      human_task_ids
      |> Enum.flat_map(fn node_id ->
        outgoing = Enum.filter(edges, &(&1["source"] == node_id))

        has_really_conditioned = Enum.any?(outgoing, &really_conditioned?/1)
        has_fallback = Enum.any?(outgoing, &fallback_candidate?/1)

        if has_really_conditioned and not has_fallback do
          first_conditioned = Enum.find(outgoing, &really_conditioned?/1)
          [%{"id" => "fallback-#{node_id}", "source" => node_id, "target" => first_conditioned["target"]}]
        else
          []
        end
      end)

    edges ++ extra
  end

  # A "really conditioned" edge has a non-empty, non-nil condition and
  # is_default is not true. Mirrors Graph.check_human_task_fallback_edge/1's
  # own `human_task_edge_really_conditioned?/1` predicate.
  @spec really_conditioned?(map()) :: boolean()
  defp really_conditioned?(edge) do
    edge["is_default"] != true and
      is_binary(edge["condition"]) and
      edge["condition"] != ""
  end

  # A fallback candidate has is_default true, or a nil/empty condition.
  @spec fallback_candidate?(map()) :: boolean()
  defp fallback_candidate?(edge) do
    edge["is_default"] == true or
      is_nil(edge["condition"]) or
      edge["condition"] == ""
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec read_fixture!(company_id(), String.t()) :: map()
  defp read_fixture!(company_id, filename) do
    path = Path.join([@fixtures_dir, company_id, filename])
    YamlElixir.read_from_file!(path)
  end

  @spec list_process_files(company_id()) :: [String.t()]
  defp list_process_files(company_id) do
    dir = Path.join(@fixtures_dir, company_id)

    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "process_"))
    |> Enum.sort()
  end

  @spec schema_name_for(Ecto.UUID.t()) :: {:ok, String.t()} | {:error, term()}
  defp schema_name_for(tenant_id) do
    Letflow.TenantProvisioning.schema_name_for_tenant(tenant_id)
  end

  @spec username_from_email(String.t()) :: String.t()
  defp username_from_email(email) do
    email
    |> String.split("@")
    |> List.first()
  end

  @spec find_user_by_username(String.t(), keyword()) ::
          {:ok, Letflow.Identity.User.t()} | {:error, :not_found}
  defp find_user_by_username(username, opts) do
    case Identity.list_users(%{search: username, page_size: 1}, opts) do
      {:ok, %{users: [user | _]}} -> {:ok, user}
      {:ok, %{users: []}} -> {:error, :not_found}
    end
  end

  @spec ensure_group(String.t(), String.t(), keyword()) ::
          {:ok, Letflow.Identity.Group.t()} | {:error, term()}
  defp ensure_group(dept_id, dept_name, opts) do
    # Use dept_id as the group name for stable idempotency across seeds
    attrs = %{"name" => dept_id, "display_name" => dept_name}

    case Identity.create_group(attrs, opts) do
      {:ok, group} ->
        {:ok, group}

      {:error, :duplicate_group_name} ->
        # Look up existing group by name
        case Identity.list_groups(opts) do
          {:ok, %{groups: groups}} ->
            case Enum.find(groups, &(&1.name == dept_id)) do
              nil -> {:error, :group_not_found}
              group -> {:ok, group}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
