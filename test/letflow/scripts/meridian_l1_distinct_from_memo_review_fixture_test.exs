defmodule Letflow.Scripts.MeridianL1DistinctFromMemoReviewFixtureTest do
  @moduledoc """
  ISS-1028 / Q-1010 (GH #2308) -- the QA Meridian "Loan Origination" fixture (v1.11) must route
  `l1-approval` to a DIFFERENT role than `credit-memo-review` (process-audit PA-MERIDIAN-002,
  checklist B2, separation of duties).

  v1.10 defect: both tasks carried `attributes.role = "role-credit-manager"`, and only
  actor-meridian-ben held that role, so one person could review the credit memo and then give
  first-level approval of their own review (and the below-threshold UAT scenario, which has a
  second person approve at step 4, could not run).

  v1.11: l1-approval -> `role-credit-approver-l1` (held by actor-meridian-lars). Role-level
  separation only; an engine-level "one person may not complete two tasks of one instance" rule
  is a separate follow-up. The l1-approval outgoing edges are unchanged (D-ESC timers are Q-995).

  Pure: no DB, no HTTP.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @fixtures Path.expand("../../fixtures", __DIR__)
  @memo "credit-memo-review"
  @l1 "l1-approval"

  defp definition,
    do:
      Path.join(@fixtures, "qa/meridian_loan_origination_process_definition.json")
      |> File.read!()
      |> Jason.decode!()

  defp simulation,
    do:
      Path.join(@fixtures, "simulation/meridian/process_claim_intake.yaml")
      |> YamlElixir.read_from_file!()

  defp actors,
    do:
      Path.join(@fixtures, "uat/actors.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.fetch!("actors")

  defp role_of(nodes, id) do
    node = Enum.find(nodes, &(&1["id"] == id))
    assert node, "task #{id} missing"
    assert node["node_type"] == "HUMAN_TASK"
    get_in(node, ["attributes", "role"])
  end

  defp human_task_roles(nodes) do
    for n <- nodes,
        n["node_type"] == "HUMAN_TASK",
        do: {n["id"], get_in(n, ["attributes", "role"])}
  end

  test "credit-memo-review and l1-approval route to different roles" do
    nodes = definition()["graph"]["nodes"]
    memo = role_of(nodes, @memo)
    l1 = role_of(nodes, @l1)

    assert is_binary(memo) and memo != ""
    assert is_binary(l1) and l1 != ""
    assert memo != l1, "memo review and L1 approval both route to #{memo}"
  end

  test "each task routes to its dedicated role" do
    nodes = definition()["graph"]["nodes"]
    assert role_of(nodes, @memo) == "role-credit-manager"
    assert role_of(nodes, @l1) == "role-credit-approver-l1"
  end

  test "every human-task role in the definition is declared in the UAT actor roster" do
    declared =
      actors()
      |> Map.values()
      |> Enum.flat_map(&(&1["routing_roles"] || []))
      |> MapSet.new()

    for {id, role} <- human_task_roles(definition()["graph"]["nodes"]) do
      assert role in declared, "#{id} routes to #{role}, which no actor in actors.yaml holds"
    end
  end

  test "no actor holds both the memo-review role and the L1 role" do
    nodes = definition()["graph"]["nodes"]
    pair = MapSet.new([role_of(nodes, @memo), role_of(nodes, @l1)])

    for {actor, entry} <- actors() do
      held = (entry["routing_roles"] || []) |> Enum.filter(&(&1 in pair))
      assert length(held) <= 1, "#{actor} holds #{inspect(held)}: could review and approve L1"
    end
  end

  test "actor-meridian-lars holds the L1 role and actor-meridian-ben only the memo role" do
    a = actors()
    assert "role-credit-approver-l1" in a["actor-meridian-lars"]["routing_roles"]
    assert a["actor-meridian-ben"]["routing_roles"] == ["role-credit-manager"]
  end

  test "l1-approval keeps its outgoing edges (D-ESC timers are a separate issue)" do
    edges = definition()["graph"]["edges"]
    targets = for e <- edges, e["source"] == @l1, do: e
    assert targets != [], "l1-approval has no outgoing edges"
  end

  test "the simulation copy routes the two tasks identically" do
    nodes = simulation()["graph"]["nodes"]
    d = definition()["graph"]["nodes"]
    assert role_of(nodes, @memo) == role_of(d, @memo)
    assert role_of(nodes, @l1) == role_of(d, @l1)
  end
end
