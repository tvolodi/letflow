defmodule Letflow.Scripts.SeedSwiftrouteDefinitionTest do
  @moduledoc """
  REQ-395 AC4: payload drift guard between `scripts/seed_swiftroute_definition.sh`
  and `test/fixtures/simulation/swiftroute/process_route_approval.yaml`.

  The seed script sources `test/fixtures/qa/swiftroute_process_definition.json` as its
  deployment payload. This test loads both the JSON fixture and the YAML fixture and
  asserts they agree on all structurally load-bearing elements:

    * node IDs (TC-395-01)
    * edge IDs (TC-395-02)
    * escalation attributes on ops-review (TC-395-03)
    * CEL condition on the ceo-approval-gate → ceo-approval edge (TC-395-04)
    * fallback-ops-review edge target (TC-395-05)

  No database, no HTTP, no process state — `async: true` is safe. Uses only
  `File.read!/1`, `Jason.decode!/1`, and `YamlElixir.read_from_file/1`.

  AC1–AC3 are not auto-executable in CI (require live QA credentials, blocked by
  ISS-0739). The manual QA procedure is documented in `test/specs/REQ-395.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @json_fixture Path.expand(
                  "../../fixtures/qa/swiftroute_process_definition.json",
                  __DIR__
                )

  @yaml_fixture Path.expand(
                  "../../fixtures/simulation/swiftroute/process_route_approval.yaml",
                  __DIR__
                )

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup_all do
    json_payload =
      @json_fixture
      |> File.read!()
      |> Jason.decode!()

    {:ok, yaml_doc} = YamlElixir.read_from_file(@yaml_fixture)

    json_node_ids =
      json_payload
      |> get_in(["graph", "nodes"])
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    json_edge_ids =
      json_payload
      |> get_in(["graph", "edges"])
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    yaml_node_ids =
      yaml_doc
      |> get_in(["graph", "nodes"])
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    yaml_edge_ids =
      yaml_doc
      |> get_in(["graph", "edges"])
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    json_nodes_by_id =
      json_payload
      |> get_in(["graph", "nodes"])
      |> Map.new(&{&1["id"], &1})

    json_edges_by_id =
      json_payload
      |> get_in(["graph", "edges"])
      |> Map.new(&{&1["id"], &1})

    %{
      json_node_ids: json_node_ids,
      json_edge_ids: json_edge_ids,
      yaml_node_ids: yaml_node_ids,
      yaml_edge_ids: yaml_edge_ids,
      json_nodes_by_id: json_nodes_by_id,
      json_edges_by_id: json_edges_by_id
    }
  end

  # ---------------------------------------------------------------------------
  # TC-395-01: all YAML node IDs present in JSON
  # ---------------------------------------------------------------------------

  test "TC-395-01: all YAML node IDs appear in JSON payload",
       %{yaml_node_ids: yaml_ids, json_node_ids: json_ids} do
    missing = MapSet.difference(yaml_ids, json_ids)

    assert MapSet.size(missing) == 0,
           "Node IDs in YAML but missing from JSON fixture: #{inspect(MapSet.to_list(missing))}"
  end

  # ---------------------------------------------------------------------------
  # TC-395-02: all YAML edge IDs present in JSON
  # ---------------------------------------------------------------------------

  test "TC-395-02: all YAML edge IDs appear in JSON payload",
       %{yaml_edge_ids: yaml_ids, json_edge_ids: json_ids} do
    missing = MapSet.difference(yaml_ids, json_ids)

    assert MapSet.size(missing) == 0,
           "Edge IDs in YAML but missing from JSON fixture: #{inspect(MapSet.to_list(missing))}"
  end

  # ---------------------------------------------------------------------------
  # TC-395-03: ops-review escalation attributes in JSON
  # ---------------------------------------------------------------------------

  test "TC-395-03: ops-review HUMAN_TASK has escalation_timer_duration and escalation_role in JSON",
       %{json_nodes_by_id: nodes} do
    ops_review = Map.fetch!(nodes, "ops-review")
    attrs = ops_review["attributes"] || %{}

    assert attrs["escalation_timer_duration"] == "PT2H",
           "Expected escalation_timer_duration: PT2H, got: #{inspect(attrs["escalation_timer_duration"])}"

    assert attrs["escalation_role"] == "role-ceo",
           "Expected escalation_role: role-ceo, got: #{inspect(attrs["escalation_role"])}"
  end

  # ---------------------------------------------------------------------------
  # TC-395-04: CEL condition declared_value > 500 on e3
  # ---------------------------------------------------------------------------

  test "TC-395-04: edge e3 (ceo-approval-gate → ceo-approval) has condition containing 'declared_value > 500'",
       %{json_edges_by_id: edges} do
    e3 = Map.fetch!(edges, "e3")
    condition = e3["condition"] || ""

    assert String.contains?(condition, "declared_value > 500"),
           "Expected e3 condition to contain 'declared_value > 500', got: #{inspect(condition)}"
  end

  # ---------------------------------------------------------------------------
  # TC-395-05: fallback-ops-review targets ceo-approval
  # ---------------------------------------------------------------------------

  test "TC-395-05: fallback-ops-review edge targets ceo-approval in JSON",
       %{json_edges_by_id: edges} do
    fallback = Map.fetch!(edges, "fallback-ops-review")

    assert fallback["target"] == "ceo-approval",
           "Expected fallback-ops-review target: ceo-approval, got: #{inspect(fallback["target"])}"
  end
end
