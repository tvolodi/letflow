defmodule Letflow.Scripts.MeridianLoanOriginationFixtureTest do
  @moduledoc """
  ISS-0928 / Q-928 T8 -- the QA Meridian "Loan Origination" fixture must give the
  `kyc-routing` EXCLUSIVE_GATEWAY an unconditioned default edge, so a KYC stub
  response with no `kyc_status` key does not stall (ISS-0998: it now goes to `kyc-manual-review`, not `assessment-join`) instead of
  erroring (or, pre-fix, stalling) the instance. The version was bumped to 1.2 (ISS-0928; now 1.5, ISS-0998 changed the default edge target to kyc-manual-review) so
  `scripts/seed_meridian_definition.sh` re-seeds QA (409 means bump, never delete).

  Pure: no DB, no HTTP. See `test/specs/ISS-0928.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph

  @fixture Path.expand(
             "../../fixtures/qa/meridian_loan_origination_process_definition.json",
             __DIR__
           )

  defp doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp kyc_routing_edges(document),
    do: Enum.filter(document["graph"]["edges"], &(&1["source"] == "kyc-routing"))

  defp graph!(document) do
    assert {:ok, graph} = Graph.from_map(document["graph"])
    graph
  end

  test "fixture version is 1.5 (ISS-0998: forces QA re-seed of the kyc-routing default edge + KYC stub)" do
    assert doc()["version"] == "1.5"
  end

  test "ISS-0998: kyc-routing has exactly one default edge, to kyc-manual-review (fail toward scrutiny), carrying no condition" do
    defaults = Enum.filter(kyc_routing_edges(doc()), &(&1["is_default"] == true))

    assert [%{"id" => "e9-default", "target" => "kyc-manual-review"} = default_edge] = defaults
    refute Map.has_key?(default_edge, "condition")
  end

  test "ISS-0998: the kyc-aml-check stub endpoint answers kyc_status=clear (httpbin /response-headers echoes the query as JSON keys)" do
    node = Enum.find(doc()["graph"]["nodes"], &(&1["id"] == "kyc-aml-check"))
    uri = URI.parse(node["attributes"]["endpoint"])

    assert uri.host == "httpbin.org"
    assert uri.path == "/response-headers"
    assert URI.decode_query(uri.query) == %{"kyc_status" => "clear"}
  end

  test "the explicit kyc_status routes are unchanged (clear -> join; hit/inconclusive -> manual review)" do
    by_id = Map.new(kyc_routing_edges(doc()), &{&1["id"], &1})

    assert %{"target" => "assessment-join", "condition" => "variables.kyc_status == 'clear'"} =
             by_id["e9"]

    assert %{"target" => "kyc-manual-review", "condition" => "variables.kyc_status == 'hit'"} =
             by_id["e10"]

    assert %{
             "target" => "kyc-manual-review",
             "condition" => "variables.kyc_status == 'inconclusive'"
           } = by_id["e11"]
  end

  test "every non-default kyc-routing edge is conditioned (CHK-13 would otherwise fire)" do
    for edge <- kyc_routing_edges(doc()), edge["is_default"] != true do
      assert is_binary(edge["condition"]) and String.trim(edge["condition"]) != ""
    end
  end

  test "the graph validates clean through Graph (structure, node attributes, edge conditions)" do
    graph = graph!(doc())

    assert %{valid: true, violations: []} = Graph.validate_graph(graph)
    assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
    assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
  end
end
