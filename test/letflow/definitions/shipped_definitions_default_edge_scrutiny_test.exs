defmodule Letflow.Definitions.ShippedDefinitionsDefaultEdgeScrutinyTest do
  @moduledoc """
  ISS-0998 / Q-980 drift test: a decision's DEFAULT edge ("nothing above matched") must
  never lead to the same place as its "clear"-style branch when the gateway also has a
  manual-review branch -- an unknown or absent value would otherwise be treated as
  cleared and skip the review (the `e9-default` bug in the QA Meridian loan fixture:
  `kyc-routing` default -> `assessment-join`, same as `kyc_status == 'clear'`, skipping
  `kyc-manual-review`). The default must fail toward MORE scrutiny.

  The rule (deliberately conservative -- it only fires on this exact shape), per
  EXCLUSIVE_GATEWAY node with a default edge:

    * review targets = targets of its non-default edges whose target node is a
      HUMAN_TASK whose id contains "review";
    * clear targets  = targets of its non-default edges whose condition compares a
      variable `== 'clear' | 'cleared' | 'approved' | 'pass' | 'passed' | 'ok'`,
      excluding any review target;
    * VIOLATION iff review targets are non-empty AND the default edge's target is one
      of the clear targets.

  Known blind spots (deliberate, to avoid false positives): a review node whose id lacks "review",
  or a clear-style condition phrased outside the regex above, is not detected here; the Meridian
  fixture test pins the kyc-routing shape by exact id/target/condition instead.

  Discovery is by structure over the same set as `ShippedDefinitionsValidationTest`
  (`priv/**/*.json`, `test/fixtures/qa/*.json`, `test/fixtures/simulation/**/process_*.yaml`).
  Pure file I/O, `async: true`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)
  @clear_condition ~r/==\s*'(clear|cleared|approved|pass|passed|ok)'/i

  # Returns [{gateway_id, default_edge_id, clear_target}] for each violating gateway.
  defp default_edge_violations(%{"nodes" => nodes, "edges" => edges}) do
    nodes_by_id = Map.new(nodes, &{&1["id"], &1})

    for %{"node_type" => "EXCLUSIVE_GATEWAY", "id" => gw} <- nodes,
        outgoing = Enum.filter(edges, &(&1["source"] == gw)),
        [default | _] <- [Enum.filter(outgoing, &(&1["is_default"] == true))],
        conditional = Enum.reject(outgoing, &(&1["is_default"] == true)),
        review_targets = review_targets(conditional, nodes_by_id),
        review_targets != [],
        clear_targets = clear_targets(conditional, review_targets),
        default["target"] in clear_targets do
      {gw, default["id"], default["target"]}
    end
  end

  defp review_targets(conditional, nodes_by_id) do
    conditional
    |> Enum.map(& &1["target"])
    |> Enum.filter(fn t ->
      node = nodes_by_id[t]
      node != nil and node["node_type"] == "HUMAN_TASK" and String.contains?(t, "review")
    end)
    |> Enum.uniq()
  end

  defp clear_targets(conditional, review_targets) do
    conditional
    |> Enum.filter(&(is_binary(&1["condition"]) and &1["condition"] =~ @clear_condition))
    |> Enum.map(& &1["target"])
    |> Enum.reject(&(&1 in review_targets))
    |> Enum.uniq()
  end

  defp discover do
    json_files =
      Path.wildcard(Path.join(@root, "priv/**/*.json")) ++
        Path.wildcard(Path.join(@root, "test/fixtures/qa/*.json"))

    yaml_files = Path.wildcard(Path.join(@root, "test/fixtures/simulation/**/process_*.yaml"))

    decoded =
      Enum.map(json_files, &{&1, &1 |> File.read!() |> Jason.decode!()}) ++
        Enum.map(yaml_files, &{&1, YamlElixir.read_from_file!(&1)})

    Enum.flat_map(decoded, fn {path, doc} ->
      rel = Path.relative_to(path, @root)

      case doc do
        %{"definitions" => defs} when is_list(defs) ->
          for {entry, i} <- Enum.with_index(defs),
              graph?(entry),
              do: {"#{rel}[#{i}]", entry["graph"]}

        doc when is_map(doc) ->
          if graph?(doc), do: [{rel, doc["graph"]}], else: []

        _ ->
          []
      end
    end)
  end

  defp graph?(%{"graph" => %{"nodes" => n, "edges" => e}}) when is_list(n) and is_list(e),
    do: true

  defp graph?(_), do: false

  defp gateway_graph(default_target) do
    %{
      "nodes" => [
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "kyc-manual-review", "node_type" => "HUMAN_TASK"}
      ],
      "edges" => [
        %{
          "id" => "a",
          "source" => "gw",
          "target" => "join",
          "condition" => "variables.s == 'clear'"
        },
        %{
          "id" => "b",
          "source" => "gw",
          "target" => "kyc-manual-review",
          "condition" => "variables.s == 'hit'"
        },
        %{"id" => "d", "source" => "gw", "target" => default_target, "is_default" => true}
      ]
    }
  end

  describe "the rule itself (synthetic graphs)" do
    test "default to the same target as the clear branch is a violation (the e9-default shape)" do
      assert [{"gw", "d", "join"}] = default_edge_violations(gateway_graph("join"))
    end

    test "default to the manual-review branch is clean" do
      assert [] = default_edge_violations(gateway_graph("kyc-manual-review"))
    end

    test "a gateway with no manual-review branch is not constrained (rule is conservative)" do
      graph = gateway_graph("join")

      graph =
        update_in(graph["edges"], fn edges -> Enum.reject(edges, &(&1["id"] == "b")) end)

      assert [] = default_edge_violations(graph)
    end
  end

  describe "every shipped definition" do
    test "discovery finds the known definitions" do
      assert length(discover()) >= 12
    end

    test "no gateway's default edge leads to its 'clear' branch while a manual-review branch exists" do
      violations =
        for {label, graph} <- discover(),
            v <- default_edge_violations(graph),
            do: {label, v}

      assert violations == [],
             "default edge routes like the clear branch (skips manual review):\n" <>
               inspect(violations, pretty: true)
    end
  end
end
