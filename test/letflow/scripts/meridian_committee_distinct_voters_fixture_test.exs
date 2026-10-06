defmodule Letflow.Scripts.MeridianCommitteeDistinctVotersFixtureTest do
  @moduledoc """
  ISS-1024 / Q-1006 (GH #2299) -- the QA Meridian "Loan Origination" fixture (v1.8, now v1.9) must
  route its three committee vote tasks to three DIFFERENT roles.

  v1.7 defect: `committee-vote-cro`, `committee-vote-director` and `committee-vote-ceo` all
  carried `attributes.role = "role-committee-member"`, so one committee member could cast two
  or all three votes and single-handedly make the 2-of-3 quorum.

  v1.8: cro -> `role-cro`, director -> `role-credit-director`, ceo -> `role-ceo`. Each role
  must be declared in `test/fixtures/uat/actors.yaml`, and no single actor may hold the routing
  roles of two vote tasks. This is role-level separation only; an engine-level "one person may
  not complete two tasks of one fan-out" rule is a separate follow-up.

  Pure: no DB, no HTTP.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @fixtures Path.expand("../../fixtures", __DIR__)
  @votes ~w(committee-vote-cro committee-vote-director committee-vote-ceo)

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

  defp vote_roles(nodes) do
    for id <- @votes do
      node = Enum.find(nodes, &(&1["id"] == id))
      assert node, "vote task #{id} missing"
      assert node["node_type"] == "HUMAN_TASK"
      {id, get_in(node, ["attributes", "role"])}
    end
  end

  defp fixture_vote_roles, do: vote_roles(definition()["graph"]["nodes"])

  test "the three committee vote tasks route to pairwise distinct roles" do
    roles = fixture_vote_roles()
    values = Enum.map(roles, &elem(&1, 1))

    assert Enum.all?(values, &(is_binary(&1) and &1 != ""))
    assert length(Enum.uniq(values)) == 3, "vote roles not pairwise distinct: #{inspect(roles)}"
  end

  test "each vote task routes to its dedicated role" do
    assert fixture_vote_roles() == [
             {"committee-vote-cro", "role-cro"},
             {"committee-vote-director", "role-credit-director"},
             {"committee-vote-ceo", "role-ceo"}
           ]
  end

  test "every vote role is declared in the UAT actor roster" do
    declared =
      actors()
      |> Map.values()
      |> Enum.flat_map(&(&1["routing_roles"] || []))
      |> MapSet.new()

    for {id, role} <- fixture_vote_roles() do
      assert role in declared, "#{id} routes to #{role}, which no actor in actors.yaml holds"
    end
  end

  test "no actor holds the routing roles of two different vote tasks" do
    vote_role_set = fixture_vote_roles() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    for {actor, entry} <- actors() do
      held = (entry["routing_roles"] || []) |> Enum.filter(&(&1 in vote_role_set))
      assert length(held) <= 1, "#{actor} holds #{inspect(held)}: could cast two committee votes"
    end
  end

  test "the simulation copy routes the votes identically" do
    assert vote_roles(simulation()["graph"]["nodes"]) == fixture_vote_roles()
  end
end
