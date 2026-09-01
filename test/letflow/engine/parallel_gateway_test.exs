defmodule Letflow.Engine.ParallelGatewayTest do
  @moduledoc """
  Unit tests for REQ-051's `PARALLEL_GATEWAY` split/join dispatch
  (`Letflow.Engine.Transition.dispatch_parallel_gateway/4` and its
  `dispatch_parallel_split/4`/`dispatch_parallel_join/4`/`dispatch_cancel_branch/3`
  siblings), implementing `lib/letflow/design/req051-parallel-gateway-split-join.md`
  (the gate-approved design). Pure module, no `Letflow.Repo`/`Ecto.Sandbox`
  dependency anywhere in this file — `async: true` for the same reason
  `test/letflow/engine/transition_test.exs` (REQ-044) uses it.

  See `test/specs/REQ-051.md` for the full test design rationale and the AC
  traceability list.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}
  alias Letflow.Engine.{InstanceState, JoinCounter, Token, Transition, VariableMerge}

  # ---------------------------------------------------------------------
  # Fixture builders (mirrors transition_test.exs's own helpers)
  # ---------------------------------------------------------------------

  defp node(id, type), do: %Node{id: id, node_type: type}
  defp edge(id, source, target), do: %Edge{id: id, source: source, target: target}
  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}
  defp token(node_id, token_id), do: %Token{node_id: node_id, token_id: token_id}

  defp instance_state(tokens, opts \\ []) do
    %InstanceState{
      instance_id: Keyword.get(opts, :instance_id, "inst-1"),
      status: Keyword.get(opts, :status, :active),
      tokens: tokens,
      variables: Keyword.get(opts, :variables, %{}),
      pending_task_nodes: Keyword.get(opts, :pending_task_nodes, []),
      join_counters: Keyword.get(opts, :join_counters, %{})
    }
  end

  # A standard 3-branch split ("split") -> join ("join") -> "e" :END graph.
  # Each of the split's 3 outgoing edges targets "join" directly (each branch
  # is a single edge with no intermediate node) -- find_matching_join/2's
  # walk_to_gateway/3 (design doc §3.3) recognizes a PARALLEL_GATEWAY node as
  # its own first-reached gateway with zero hops, so this is a legal,
  # minimal block-structured split/join graph, and it means each freshly
  # split child token already sits *on* the join node -- exactly the
  # positioning dispatch_parallel_join/4 (§4.2) expects for its very next
  # {:advance_token, branch_id} hop.
  defp three_branch_graph do
    graph(
      [
        node("split", :PARALLEL_GATEWAY),
        node("join", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-split-0", "split", "join"),
        edge("e-split-1", "split", "join"),
        edge("e-split-2", "split", "join"),
        edge("e-join-e", "join", "e")
      ]
    )
  end

  # ISS-0398 regression fixture (lib/letflow/design/iss0398-walk-to-gateway-fix.md
  # §4): a "split" PARALLEL_GATEWAY with 2 outgoing edges. Branch 0 is the
  # original zero-hop shape (split -> join directly, kept as a control
  # branch in the same fixture). Branch 1 passes through "gw", an
  # EXCLUSIVE_GATEWAY with 2 outgoing edges, both of which reconverge on the
  # same "join" node (the diamond shape from §2.4) -- this is the shape
  # ISS-0398.yaml's own kyc-routing scenario has, and the one
  # collect_leaf_gateways/3 must resolve where the old walk_to_gateway/3
  # failed the whole split at instance-creation time.
  defp branch_with_exclusive_gateway_graph do
    graph(
      [
        node("split", :PARALLEL_GATEWAY),
        node("gw", :EXCLUSIVE_GATEWAY),
        node("route-a", :HUMAN_TASK),
        node("route-b", :HUMAN_TASK),
        node("join", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-split-0", "split", "join"),
        edge("e-split-1", "split", "gw"),
        edge("e-gw-a", "gw", "route-a"),
        edge("e-gw-b", "gw", "route-b"),
        edge("e-route-a-join", "route-a", "join"),
        edge("e-route-b-join", "route-b", "join"),
        edge("e-join-e", "join", "e")
      ]
    )
  end

  # ISS-0398 negative fixture (design doc §4): identical to
  # branch_with_exclusive_gateway_graph/0's branch 1 except "route-b" dead-ends
  # at a separate :END node "e2" instead of reconverging on "join". One of
  # "gw"'s two paths reaches the real join, the other dead-ends -- the
  # per-branch singleton-leaf-set rule (design doc §2.5) must still reject
  # this branch as ambiguous, not accept it just because one of its paths
  # happens to reach the right gateway.
  defp ambiguous_branch_dead_ends_graph do
    graph(
      [
        node("split", :PARALLEL_GATEWAY),
        node("gw", :EXCLUSIVE_GATEWAY),
        node("route-a", :HUMAN_TASK),
        node("route-b", :HUMAN_TASK),
        node("join", :PARALLEL_GATEWAY),
        node("e", :END),
        node("e2", :END)
      ],
      [
        edge("e-split-0", "split", "join"),
        edge("e-split-1", "split", "gw"),
        edge("e-gw-a", "gw", "route-a"),
        edge("e-gw-b", "gw", "route-b"),
        edge("e-route-a-join", "route-a", "join"),
        edge("e-route-b-dead", "route-b", "e2"),
        edge("e-join-e", "join", "e")
      ]
    )
  end

  # ISS-0398 stress fixture (design doc §2.4a/§4, iteration 2's rework): a
  # PARALLEL_GATEWAY "split" with 2 outgoing edges -- branch 0 is the
  # zero-hop control branch (split -> join directly, same control shape as
  # branch_with_exclusive_gateway_graph/0's own branch 0; out-degree 2 is
  # what makes gateway_role/2 classify "split" as a real :split rather than
  # :pass_through), branch 1 is a chain of `k` EXCLUSIVE_GATEWAY diamonds --
  # gw_1..gw_k, each with two edges to b_i/c_i, both reconverging on
  # gw_{i+1} (or on the branch's real "join" PARALLEL_GATEWAY node for
  # gw_k). Branch 1 is the actual regression fixture for the
  # exponential-blowup defect SECURITY-REVIEWER found in iteration 1: under
  # the old per-path-copied-visited-set scheme this branch's call count is
  # O(2^k); under the memoized-Tarjan-SCC scheme (this revision) it is
  # O(k).
  defp diamond_chain_graph(k) when is_integer(k) and k > 0 do
    gateway_nodes = for i <- 1..k, do: node("gw#{i}", :EXCLUSIVE_GATEWAY)

    route_nodes =
      for i <- 1..k, letter <- ["b", "c"], do: node("#{letter}#{i}", :HUMAN_TASK)

    nodes =
      [node("split", :PARALLEL_GATEWAY)] ++
        gateway_nodes ++ route_nodes ++ [node("join", :PARALLEL_GATEWAY), node("e", :END)]

    split_edges = [edge("e-split-0", "split", "join"), edge("e-split-1", "split", "gw1")]

    diamond_edges =
      for i <- 1..k, letter <- ["b", "c"] do
        route_id = "#{letter}#{i}"
        target = if i == k, do: "join", else: "gw#{i + 1}"

        [
          edge("e-gw#{i}-#{route_id}", "gw#{i}", route_id),
          edge("e-#{route_id}-next", route_id, target)
        ]
      end
      |> List.flatten()

    edges = split_edges ++ diamond_edges ++ [edge("e-join-e", "join", "e")]

    graph(nodes, edges)
  end

  # ISS-0398 cyclic regression fixture (design doc §2.4b/§4, iteration 3's
  # rework): a PARALLEL_GATEWAY "split" with 2 outgoing edges -- edge 0 ->
  # "X" (reaching the cycle from outside), edge 1 -> "B" (a member of the
  # cycle itself). "X" -> "GW" (EXCLUSIVE_GATEWAY) -> "C" -> "B"
  # (EXCLUSIVE_GATEWAY, out-degree 2: "B" -> "GW" closes the cycle, legal
  # per CHK-06 since both "B" and "GW" are gateway-typed; "B" -> "D" escapes
  # it) -> "D" -> "JOIN" (PARALLEL_GATEWAY) -> "e" (:END). Both branches
  # must resolve to the same {:gateway, "JOIN"} regardless of which one
  # (the cycle-external entry or the cycle-internal entry) is evaluated
  # first -- exactly the order-independence property a plain node-keyed
  # memo cannot guarantee (§2.2.1).
  defp cyclic_escape_graph do
    graph(
      [
        node("split", :PARALLEL_GATEWAY),
        node("X", :HUMAN_TASK),
        node("GW", :EXCLUSIVE_GATEWAY),
        node("C", :HUMAN_TASK),
        node("B", :EXCLUSIVE_GATEWAY),
        node("D", :HUMAN_TASK),
        node("JOIN", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-split-0", "split", "X"),
        edge("e-split-1", "split", "B"),
        edge("e-x-gw", "X", "GW"),
        edge("e-gw-c", "GW", "C"),
        edge("e-c-b", "C", "B"),
        edge("e-b-gw", "B", "GW"),
        edge("e-b-d", "B", "D"),
        edge("e-d-join", "D", "JOIN"),
        edge("e-join-e", "JOIN", "e")
      ]
    )
  end

  # Same graph as cyclic_escape_graph/0, with the split node's edges_out
  # list order swapped (edge 0 -> "B", edge 1 -> "X") -- forces
  # find_matching_join/2's outer fold to evaluate the cycle-internal-entry
  # branch before the cycle-external-entry branch, the reverse of
  # cyclic_escape_graph/0's own order. Both fixtures must produce the exact
  # same result (design doc §2.4b's "Order 1" vs. "Order 2").
  defp cyclic_escape_graph_reversed_edges do
    graph(
      [
        node("split", :PARALLEL_GATEWAY),
        node("X", :HUMAN_TASK),
        node("GW", :EXCLUSIVE_GATEWAY),
        node("C", :HUMAN_TASK),
        node("B", :EXCLUSIVE_GATEWAY),
        node("D", :HUMAN_TASK),
        node("JOIN", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-split-0", "split", "B"),
        edge("e-split-1", "split", "X"),
        edge("e-x-gw", "X", "GW"),
        edge("e-gw-c", "GW", "C"),
        edge("e-c-b", "C", "B"),
        edge("e-b-gw", "B", "GW"),
        edge("e-b-d", "B", "D"),
        edge("e-d-join", "D", "JOIN"),
        edge("e-join-e", "JOIN", "e")
      ]
    )
  end

  # ISS-0398 empty-aggregate regression fixture (design doc §2.2.1/§4): a
  # PARALLEL_GATEWAY "split" with 2 outgoing edges, both entering the same
  # escape-less cycle (out-degree 2 is what makes gateway_role/2 classify
  # "split" as a real :split rather than :pass_through -- see
  # diamond_chain_graph/1's own comment above) -- "A" (single edge) -> "B"
  # (EXCLUSIVE_GATEWAY, single edge back to "A", closing a 2-node cycle with
  # no escape edge anywhere in it -- legal per CHK-06 since "B" is
  # gateway-typed). The SCC's aggregate leaves is the empty set (no escape
  # edges, and the cycle's own back-edge contributes nothing per §2.2.2 step
  # 2's semantic correction) -- a non-singleton, so both branches must fail
  # to resolve, and find_matching_join/2's own reduce_while halts on the
  # first one.
  defp pure_cycle_no_escape_graph do
    graph(
      [
        node("split", :PARALLEL_GATEWAY),
        node("A", :HUMAN_TASK),
        node("B", :EXCLUSIVE_GATEWAY)
      ],
      [
        edge("e-split-0", "split", "A"),
        edge("e-split-1", "split", "A"),
        edge("e-a-b", "A", "B"),
        edge("e-b-a", "B", "A")
      ]
    )
  end

  # ISS-0400 fixture 1 (lib/letflow/design/iss0400-nested-parallel-gateway-fix.md
  # §4): a PARALLEL_GATEWAY "outer_split" with 2 outgoing edges. Branch 0 is
  # the zero-hop control branch (outer_split -> outer_join directly). Branch
  # 1 passes through "pre" then reaches "inner_split", itself a
  # PARALLEL_GATEWAY split (out_degree 2, :split role per gateway_role/2) --
  # inner_a/inner_b both reconverge on "inner_join" (PARALLEL_GATEWAY, :join
  # role), which continues via "post" to the same "outer_join" branch 0
  # reaches. This is ISSUE-FIXER's own repro 1 shape -- the core regression:
  # collect_leaf_gateways/3 must recursively resolve "inner_split" via
  # resolve_nested_split/3 and continue past "inner_join" rather than
  # stopping and reporting "inner_split" itself as branch 1's leaf.
  defp nested_parallel_split_graph do
    graph(
      [
        node("outer_split", :PARALLEL_GATEWAY),
        node("pre", :HUMAN_TASK),
        node("inner_split", :PARALLEL_GATEWAY),
        node("inner_a", :HUMAN_TASK),
        node("inner_b", :HUMAN_TASK),
        node("inner_join", :PARALLEL_GATEWAY),
        node("post", :HUMAN_TASK),
        node("outer_join", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-outer-0", "outer_split", "outer_join"),
        edge("e-outer-1", "outer_split", "pre"),
        edge("e-pre-inner", "pre", "inner_split"),
        edge("e-inner-a", "inner_split", "inner_a"),
        edge("e-inner-b", "inner_split", "inner_b"),
        edge("e-a-join", "inner_a", "inner_join"),
        edge("e-b-join", "inner_b", "inner_join"),
        edge("e-join-post", "inner_join", "post"),
        edge("e-post-outer", "post", "outer_join"),
        edge("e-outer-e", "outer_join", "e")
      ]
    )
  end

  # ISS-0400 fixture 2 (design doc §4, negative case): identical to
  # nested_parallel_split_graph/0's branch 1, except "inner_b" dead-ends at a
  # separate :END node "e2" instead of reconverging on "inner_join" -- one of
  # the nested split's own two branches dead-ends, so resolve_nested_split/3
  # must propagate this as :dead_end (design §3.3) and correctly fail the
  # *outer* branch, not partially succeed or crash.
  defp nested_split_dead_end_graph do
    graph(
      [
        node("outer_split", :PARALLEL_GATEWAY),
        node("pre", :HUMAN_TASK),
        node("inner_split", :PARALLEL_GATEWAY),
        node("inner_a", :HUMAN_TASK),
        node("inner_b", :HUMAN_TASK),
        node("inner_join", :PARALLEL_GATEWAY),
        node("post", :HUMAN_TASK),
        node("outer_join", :PARALLEL_GATEWAY),
        node("e", :END),
        node("e2", :END)
      ],
      [
        edge("e-outer-0", "outer_split", "outer_join"),
        edge("e-outer-1", "outer_split", "pre"),
        edge("e-pre-inner", "pre", "inner_split"),
        edge("e-inner-a", "inner_split", "inner_a"),
        edge("e-inner-b", "inner_split", "inner_b"),
        edge("e-a-join", "inner_a", "inner_join"),
        edge("e-b-dead", "inner_b", "e2"),
        edge("e-join-post", "inner_join", "post"),
        edge("e-post-outer", "post", "outer_join"),
        edge("e-outer-e", "outer_join", "e")
      ]
    )
  end

  # ISS-0400 fixture 3 (design doc §4): CODE-DESIGN-VALIDATOR's own
  # counterexample graph, reproduced exactly -- the shape that made
  # iteration 1's reset-based resolve_nested_split/3 recurse forever, and
  # that this revision's no-reset mechanism must resolve correctly and
  # terminate. "outer_split" (PARALLEL_GATEWAY, out_degree 2): branch 0
  # direct to "outer_join". Branch 1: outer_split -> "A" -> "inner_split"
  # (PARALLEL_GATEWAY, out_degree 2, :split role) -- edge a: inner_split ->
  # "ia" -> "A" (a LIVE BACK-EDGE to "A", the still-open ancestor leading
  # into inner_split itself); edge b: inner_split -> "ib" -> "inner_join"
  # (PARALLEL_GATEWAY, :join role) -> "post" -> "outer_join". Per design
  # §3.2's worked trace: the SCC {A, inner_split, ia} closes as one unit at
  # "A" (the true SCC root), and edge b's escape path supplies the real leaf
  # value ("outer_join") that becomes every SCC member's shared memo entry.
  defp nested_split_ancestor_back_edge_graph do
    graph(
      [
        node("outer_split", :PARALLEL_GATEWAY),
        node("A", :HUMAN_TASK),
        node("inner_split", :PARALLEL_GATEWAY),
        node("ia", :HUMAN_TASK),
        node("ib", :HUMAN_TASK),
        node("inner_join", :PARALLEL_GATEWAY),
        node("post", :HUMAN_TASK),
        node("outer_join", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-outer-0", "outer_split", "outer_join"),
        edge("e-outer-1", "outer_split", "A"),
        edge("e-a-inner", "A", "inner_split"),
        edge("e-inner-ia", "inner_split", "ia"),
        edge("e-inner-ib", "inner_split", "ib"),
        edge("e-ia-back-a", "ia", "A"),
        edge("e-ib-join", "ib", "inner_join"),
        edge("e-join-post", "inner_join", "post"),
        edge("e-post-outer", "post", "outer_join"),
        edge("e-outer-e", "outer_join", "e")
      ]
    )
  end

  # ISS-0400 fixture 3b (design doc §4, negative twin of fixture 3): same
  # shape as nested_split_ancestor_back_edge_graph/0, except edge b is
  # replaced with a SECOND independent back-edge into "A" (inner_split -> ib
  # -> A) instead of escaping to inner_join/post/outer_join. This keeps
  # "inner_split" genuinely :split-classified (out_degree 2) while removing
  # every escape from the cycle -- the SCC {A, inner_split, ia, ib} must
  # close with an EMPTY aggregate leaf set (no edge in the SCC reaches a
  # PARALLEL_GATEWAY terminal), a non-singleton-agreement failure per §2.5's
  # unchanged rule, correctly failing the branch without crashing or hanging.
  defp nested_split_ancestor_back_edge_no_escape_graph do
    graph(
      [
        # outer_split's own two edges both enter the same escape-less SCC
        # (mirrors pure_cycle_no_escape_graph/0's own "both edges into the
        # cycle" convention above) -- out_degree 2 is only needed so
        # outer_split's own gateway_role/2 classification is irrelevant to
        # this fixture; find_matching_join/2's reduce_while fails on the
        # first branch that doesn't resolve, and both branches here reach
        # the same unresolvable SCC either way.
        node("outer_split", :PARALLEL_GATEWAY),
        node("A", :HUMAN_TASK),
        node("inner_split", :PARALLEL_GATEWAY),
        node("ia", :HUMAN_TASK),
        node("ib", :HUMAN_TASK)
      ],
      [
        edge("e-outer-0", "outer_split", "A"),
        edge("e-outer-1", "outer_split", "A"),
        edge("e-a-inner", "A", "inner_split"),
        edge("e-inner-ia", "inner_split", "ia"),
        edge("e-inner-ib", "inner_split", "ib"),
        edge("e-ia-back-a", "ia", "A"),
        edge("e-ib-back-a", "ib", "A")
      ]
    )
  end

  # ISS-0400 fixture 4 (design doc §4, arbitrary-depth confirmation):
  # fixture 1's branch 1, except "inner_a" itself leads to a SECOND nested
  # split/join pair ("inner2_split"/"inner2_join") before reaching
  # "inner_join" -- confirms resolve_nested_split/3's recursion terminates
  # and resolves correctly at depth 2, not only depth 1.
  defp doubly_nested_parallel_split_graph do
    graph(
      [
        node("outer_split", :PARALLEL_GATEWAY),
        node("pre", :HUMAN_TASK),
        node("inner_split", :PARALLEL_GATEWAY),
        node("inner_a", :HUMAN_TASK),
        node("inner_b", :HUMAN_TASK),
        node("inner2_split", :PARALLEL_GATEWAY),
        node("inner2_a", :HUMAN_TASK),
        node("inner2_b", :HUMAN_TASK),
        node("inner2_join", :PARALLEL_GATEWAY),
        node("inner_join", :PARALLEL_GATEWAY),
        node("post", :HUMAN_TASK),
        node("outer_join", :PARALLEL_GATEWAY),
        node("e", :END)
      ],
      [
        edge("e-outer-0", "outer_split", "outer_join"),
        edge("e-outer-1", "outer_split", "pre"),
        edge("e-pre-inner", "pre", "inner_split"),
        edge("e-inner-a", "inner_split", "inner_a"),
        edge("e-inner-b", "inner_split", "inner_b"),
        edge("e-a-inner2", "inner_a", "inner2_split"),
        edge("e-inner2-a", "inner2_split", "inner2_a"),
        edge("e-inner2-b", "inner2_split", "inner2_b"),
        edge("e-inner2a-join2", "inner2_a", "inner2_join"),
        edge("e-inner2b-join2", "inner2_b", "inner2_join"),
        edge("e-join2-innerjoin", "inner2_join", "inner_join"),
        edge("e-b-join", "inner_b", "inner_join"),
        edge("e-join-post", "inner_join", "post"),
        edge("e-post-outer", "post", "outer_join"),
        edge("e-outer-e", "outer_join", "e")
      ]
    )
  end

  # Runs the split dispatch once and returns {new_state, branch_ids} where
  # branch_ids is in edges_out declaration order (b0, b1, b2).
  defp do_split(g, initial_token_id \\ "t1") do
    state = instance_state([token("split", initial_token_id)])

    assert {:ok, new_state, [{:parallel_split, ^initial_token_id, "split", branch_ids}]} =
             Transition.transition(g, state, {:advance_token, initial_token_id})

    {new_state, branch_ids}
  end

  # ---------------------------------------------------------------------
  # AC1 -- split produces N distinct branch_ids
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY split (acceptance criterion 1)" do
    test "a 3-outgoing-edge split produces exactly 3 tokens with 3 distinct branch_ids in one transition call" do
      g = three_branch_graph()
      {new_state, branch_ids} = do_split(g)

      assert length(new_state.tokens) == 3
      assert length(branch_ids) == 3
      assert MapSet.size(MapSet.new(branch_ids)) == 3

      token_branch_ids = Enum.map(new_state.tokens, & &1.branch_id)
      assert MapSet.new(token_branch_ids) == MapSet.new(branch_ids)

      # The parent token "t1" is consumed -- no token still carries it.
      refute Enum.any?(new_state.tokens, &(&1.token_id == "t1"))

      # Each child token lands on its branch target -- "join" itself, since
      # this graph's branches are single direct edges (see three_branch_graph/0).
      assert Enum.map(new_state.tokens, & &1.node_id) == ["join", "join", "join"]

      # A JoinCounter cohort is registered for the "join" node, expecting
      # exactly these 3 branch_ids.
      assert %JoinCounter{} = counter = new_state.join_counters["join"]
      assert counter.expected_from_branches == MapSet.new(branch_ids)
      assert counter.received_from_branches == MapSet.new()
      assert counter.cancelled_branches == MapSet.new()
    end
  end

  # ---------------------------------------------------------------------
  # AC2 -- join does not fire on the 2nd of 3 arrivals, fires on the 3rd
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY join wait/fire boundary (acceptance criterion 2)" do
    test "does not fire when 2 of 3 tokens have arrived, and fires when the 3rd arrives -- asserted at both points" do
      g = three_branch_graph()
      {split_state, [b0, b1, b2]} = do_split(g)

      # First arrival (b0): still 2 outstanding (b1, b2) -- :wait, no pending event.
      assert {:ok, state_after_1, []} =
               Transition.transition(g, split_state, {:advance_token, b0})

      assert %JoinCounter{} = counter_1 = state_after_1.join_counters["join"]
      assert counter_1.received_from_branches == MapSet.new([b0])

      # Second arrival (b1): still 1 outstanding (b2) -- MUST NOT fire yet.
      assert {:ok, state_after_2, []} =
               Transition.transition(g, state_after_1, {:advance_token, b1})

      assert %JoinCounter{} = counter_2 = state_after_2.join_counters["join"]
      assert counter_2.received_from_branches == MapSet.new([b0, b1])
      # The join cohort is still outstanding -- the join has NOT fired.
      assert Map.has_key?(state_after_2.join_counters, "join")
      assert Enum.all?(state_after_2.tokens, &(&1.node_id != "e"))

      # Third arrival (b2): 0 outstanding -- fires.
      assert {:ok, state_after_3,
              [{:parallel_join_fired, "join", origin_token_id, new_token_id, _merge_events}]} =
               Transition.transition(g, state_after_2, {:advance_token, b2})

      refute Map.has_key?(state_after_3.join_counters, "join")
      assert origin_token_id == "t1"

      assert [%Token{token_id: ^new_token_id, node_id: "e", branch_id: nil}] =
               state_after_3.tokens
    end
  end

  # ---------------------------------------------------------------------
  # AC3 -- join excludes a cancelled branch, fires on the remaining active ones
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY join excludes a cancelled branch (acceptance criterion 3)" do
    test "a 3-branch join with 1 branch cancelled fires when the remaining 2 active tokens arrive, not waiting for the cancelled branch" do
      g = three_branch_graph()
      {split_state, [b0, b1, b2]} = do_split(g)

      # Cancel b2 before it ever arrives. 0 received so far, 1 cancelled, 2
      # still outstanding (b0, b1) -- :wait, no pending event, instance stays active.
      assert {:ok, state_after_cancel, []} =
               Transition.transition(g, split_state, {:cancel_branch, b2})

      assert state_after_cancel.status == :active
      assert %JoinCounter{} = counter = state_after_cancel.join_counters["join"]
      assert counter.cancelled_branches == MapSet.new([b2])

      # b0 arrives: 1 received, 1 cancelled, 1 still outstanding (b1) -- :wait.
      assert {:ok, state_after_b0, []} =
               Transition.transition(g, state_after_cancel, {:advance_token, b0})

      assert Map.has_key?(state_after_b0.join_counters, "join")

      # b1 arrives: 2 received, 1 cancelled, 0 outstanding -- fires, WITHOUT
      # ever waiting for the cancelled b2.
      assert {:ok, state_after_b1, [{:parallel_join_fired, "join", "t1", new_token_id, _}]} =
               Transition.transition(g, state_after_b0, {:advance_token, b1})

      refute Map.has_key?(state_after_b1.join_counters, "join")
      assert [%Token{token_id: ^new_token_id, node_id: "e"}] = state_after_b1.tokens
    end
  end

  # ---------------------------------------------------------------------
  # AC4 -- all branches cancelled before any arrives -> join + instance cancelled
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY all-branches-cancelled (acceptance criterion 4)" do
    test "when every branch of a split is cancelled before any reaches the join, the join is cancelled and the instance status becomes :cancelled" do
      g = three_branch_graph()
      {split_state, [b0, b1, b2]} = do_split(g)

      # Cancel b0: 2 still outstanding -- :wait.
      assert {:ok, state_1, []} = Transition.transition(g, split_state, {:cancel_branch, b0})
      assert state_1.status == :active
      assert Map.has_key?(state_1.join_counters, "join")

      # Cancel b1: 1 still outstanding -- :wait.
      assert {:ok, state_2, []} = Transition.transition(g, state_1, {:cancel_branch, b1})
      assert state_2.status == :active
      assert Map.has_key?(state_2.join_counters, "join")

      # Cancel b2 (the last one): 0 outstanding, 0 ever received -- :cancel_join.
      assert {:ok, state_3, [{:parallel_join_cancelled, "join", "t1"}]} =
               Transition.transition(g, state_2, {:cancel_branch, b2})

      assert state_3.status == :cancelled
      refute Map.has_key?(state_3.join_counters, "join")
      # No merged continuation token was ever produced -- unlike the :fire
      # case, cancellation of the last outstanding branch here never reaches
      # node "e".
      refute Enum.any?(state_3.tokens, &(&1.node_id == "e"))
    end
  end

  # ---------------------------------------------------------------------
  # AC5 -- order-independence and exactly-once firing
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY join order-independence and exactly-once firing (acceptance criterion 5)" do
    test "two different arrival orders produce identical post-join state, join fires exactly once in each" do
      g = three_branch_graph()

      run_ordering = fn order_indexes ->
        {split_state, branch_ids} = do_split(g, "t1")
        branch_ids_by_index = Enum.with_index(branch_ids) |> Map.new(fn {id, i} -> {i, id} end)

        {final_state, pending_events_per_call} =
          Enum.reduce(order_indexes, {split_state, []}, fn idx, {state, acc} ->
            branch_id = branch_ids_by_index[idx]

            assert {:ok, new_state, pending} =
                     Transition.transition(g, state, {:advance_token, branch_id})

            {new_state, acc ++ [pending]}
          end)

        {final_state, pending_events_per_call, branch_ids_by_index}
      end

      {state_order_a, pending_a, ids_a} = run_ordering.([0, 1, 2])
      {state_order_b, pending_b, ids_b} = run_ordering.([2, 0, 1])

      # Exactly one call in each ordering produced a fire event; the other
      # two produced no pending event at all.
      fire_count_a = Enum.count(pending_a, &match?([{:parallel_join_fired, _, _, _, _}], &1))
      fire_count_b = Enum.count(pending_b, &match?([{:parallel_join_fired, _, _, _, _}], &1))
      assert fire_count_a == 1
      assert fire_count_b == 1
      assert Enum.count(pending_a, &(&1 == [])) == 2
      assert Enum.count(pending_b, &(&1 == [])) == 2

      # Order-independence: same final InstanceState regardless of arrival order.
      # (branch_ids themselves are identical across both runs since do_split/2
      # is deterministic given the same initial_token_id "t1".)
      assert ids_a == ids_b
      assert state_order_a == state_order_b

      # Exactly-once: replaying the last-arriving branch's token_id again via
      # {:advance_token, _} finds no live token at all (it was already
      # consumed by the fire) -- {:error, {:unknown_token_id, _}}, not a
      # second merged token. Replaying the same branch_id via
      # {:cancel_branch, _} independently confirms the cohort itself is
      # gone too -- {:error, {:unknown_branch_id, _}} (design doc §4.3's
      # "no code path can construct a second outgoing token from the same
      # cohort, because the cohort's own record no longer exists").
      stale_branch_id = ids_a[2]

      assert Transition.transition(g, state_order_a, {:advance_token, stale_branch_id}) ==
               {:error, {:unknown_token_id, stale_branch_id}}

      assert Transition.transition(g, state_order_a, {:cancel_branch, stale_branch_id}) ==
               {:error, {:unknown_branch_id, stale_branch_id}}

      # Only one merged continuation token exists on node "e" -- not two.
      assert Enum.count(state_order_a.tokens, &(&1.node_id == "e")) == 1
    end
  end

  # ---------------------------------------------------------------------
  # AC6 -- REQ-049 merge reuse, no second collision rule in this module
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY join reuses REQ-049's merge/3, no second collision rule (acceptance criterion 6)" do
    test "the join-fire path calls VariableMerge.merge/3 exactly once -- no second collision rule is defined in transition.ex" do
      {:ok, source} = File.read("lib/letflow/engine/transition.ex")

      call_sites =
        source
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "VariableMerge.merge("))

      assert call_sites == 1,
             "expected exactly one VariableMerge.merge/3 call site in transition.ex, found #{call_sites}"

      refute source =~ ~r/defp?\s+merge\(/,
             "transition.ex must not define its own merge/N function -- it must reuse VariableMerge.merge/3"

      refute source =~ ~r/defp?\s+overwrite/,
             "transition.ex must not define its own overwrite-resolution helper -- collisions are REQ-049's job"
    end

    test "a variable conflict across two branches produces :variable_overwritten via merge/3; the join-fire itself never overwrites again" do
      g = three_branch_graph()
      {split_state, [b0, b1, b2]} = do_split(g)

      # Branch A's own task completion (simulating REQ-047's future
      # orchestration calling REQ-049 at an ordinary task completion, design
      # doc §12.5) writes a brand-new key -- no collision yet.
      assert {:ok, vars_after_a, []} =
               VariableMerge.merge(split_state.variables, %{"x" => "a"}, nil)

      # Branch B's own task completion overwrites the same key with a
      # different value -- REQ-049's merge/3 itself is the one and only
      # place this :variable_overwritten event is constructed.
      assert {:ok, vars_after_b, [{:variable_overwritten, "x", "a", "b"}]} =
               VariableMerge.merge(vars_after_a, %{"x" => "b"}, nil)

      state_with_conflict = %InstanceState{split_state | variables: vars_after_b}

      # Both remaining active branches (only 2 of the 3, deliberately -- b2
      # is left un-advanced/uncancelled here just to isolate this test to
      # the fire path itself using the standard 2-then-3rd sequencing from
      # AC2/AC3) now advance and the join fires.
      assert {:ok, state_after_b0, []} =
               Transition.transition(g, state_with_conflict, {:advance_token, b0})

      assert {:ok, state_after_b1, pending} =
               Transition.transition(g, state_after_b0, {:advance_token, b1})

      # Only b0/b1 have arrived (2 of 3) -- the join has not fired yet with
      # b2 still outstanding, so no merge_events assertion is meaningful
      # here. Cancel the still-outstanding b2 to trigger the fire via the
      # cancellation path (AC3's mechanism), then inspect the fired event.
      assert pending == []

      assert {:ok, final_state,
              [{:parallel_join_fired, "join", "t1", _new_token_id, merge_events}]} =
               Transition.transition(g, state_after_b1, {:cancel_branch, b2})

      # §4.3 step 1's join-fire call is always a no-op given the current
      # single-global-variables shape (incoming_variables always %{}) --
      # the join itself never manufactures a second overwrite event for
      # "x". The value the branches themselves already settled ("b") is
      # left untouched.
      assert merge_events == []
      assert final_state.variables["x"] == "b"
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0398 -- a fork branch containing a non-PARALLEL_GATEWAY branching
  # node (an EXCLUSIVE_GATEWAY) before reaching its join must still resolve,
  # per lib/letflow/design/iss0398-walk-to-gateway-fix.md §4.
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY split with an EXCLUSIVE_GATEWAY inside a branch (ISS-0398)" do
    test "a branch that passes through an EXCLUSIVE_GATEWAY before reconverging on the join still resolves and splits successfully" do
      g = branch_with_exclusive_gateway_graph()
      state = instance_state([token("split", "t1")])

      assert {:ok, new_state, [{:parallel_split, "t1", "split", branch_ids}]} =
               Transition.transition(g, state, {:advance_token, "t1"})

      assert length(branch_ids) == 2

      assert %JoinCounter{} = counter = new_state.join_counters["join"]
      assert counter.expected_from_branches == MapSet.new(branch_ids)

      # Branch 1's new token lands on "gw" -- the split itself only ever
      # advances each branch one hop to its own edge.target; the deeper
      # subtree search is a pure lookahead and never advances any token.
      assert Enum.map(new_state.tokens, & &1.node_id) |> Enum.sort() == ["gw", "join"]
    end

    test "a branch whose EXCLUSIVE_GATEWAY has one path reaching the join and another dead-ending still fails the whole split" do
      g = ambiguous_branch_dead_ends_graph()
      state = instance_state([token("split", "t1")])

      assert {:error, {:no_matching_join_found, "split"}} =
               Transition.transition(g, state, {:advance_token, "t1"})
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0398 -- regression coverage for the exponential-blowup defect
  # (design doc §2.4a/§4): a k-diamond EXCLUSIVE_GATEWAY chain must resolve
  # correctly AND complete fast, not just "eventually".
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY split through a long EXCLUSIVE_GATEWAY diamond chain (ISS-0398 complexity regression)" do
    test "a 40-diamond chain resolves correctly and completes well within a generous time budget" do
      k = 40
      g = diamond_chain_graph(k)
      state = instance_state([token("split", "t1")])

      {elapsed_us, result} =
        :timer.tc(fn -> Transition.transition(g, state, {:advance_token, "t1"}) end)

      assert {:ok, new_state, [{:parallel_split, "t1", "split", branch_ids}]} = result
      assert length(branch_ids) == 2

      assert %JoinCounter{} = counter = new_state.join_counters["join"]
      assert counter.expected_from_branches == MapSet.new(branch_ids)

      # Both branches ("join" directly, and "gw1" at the head of the chain)
      # advance one hop each -- chain length doesn't change which node the
      # branch resolves to, only how much work resolving it takes.
      assert Enum.map(new_state.tokens, & &1.node_id) |> Enum.sort() == ["gw1", "join"]

      # O(2^40) ~= 10^12 leaf-level calls under the old unmemoized scheme
      # would be nowhere near this budget (would not finish in any
      # practical time at all); O(k) fresh explorations under this
      # revision's memoized Tarjan-SCC scheme finishes in microseconds. 2
      # seconds is generous enough to avoid CI flakiness while still being
      # far too tight for a reversion to O(2^k) behavior at k = 40 to sneak
      # through.
      assert elapsed_us < 2_000_000,
             "expected diamond_chain_graph(#{k}) to resolve in well under 2s, took #{elapsed_us}us"
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0398 -- regression coverage for the memo-key-unsoundness defect
  # (design doc §2.2.1/§2.4b/§4): a cycle through a branching gateway node
  # whose branching member also has an escape edge out of the cycle must
  # resolve identically regardless of which cycle-adjacent branch is
  # evaluated first.
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY split through a cycle with an internal escape edge (ISS-0398 memo-soundness regression)" do
    test "cyclic_escape_graph/0 and its edge-order-reversed twin produce identical results" do
      state_a = instance_state([token("split", "t1")])
      state_b = instance_state([token("split", "t1")])

      result_a = Transition.transition(cyclic_escape_graph(), state_a, {:advance_token, "t1"})

      result_b =
        Transition.transition(
          cyclic_escape_graph_reversed_edges(),
          state_b,
          {:advance_token, "t1"}
        )

      assert {:ok, new_state_a, [{:parallel_split, "t1", "split", branch_ids_a}]} = result_a
      assert {:ok, new_state_b, [{:parallel_split, "t1", "split", branch_ids_b}]} = result_b

      assert length(branch_ids_a) == 2
      assert length(branch_ids_b) == 2

      assert %JoinCounter{} = counter_a = new_state_a.join_counters["JOIN"]
      assert %JoinCounter{} = counter_b = new_state_b.join_counters["JOIN"]
      assert counter_a.expected_from_branches == MapSet.new(branch_ids_a)
      assert counter_b.expected_from_branches == MapSet.new(branch_ids_b)

      # The branch entering directly at "B" (the cycle member) lands its
      # new token on "B" itself in both fixtures -- the split only ever
      # advances one hop per branch, regardless of what the deeper
      # lookahead discovers.
      assert "B" in Enum.map(new_state_a.tokens, & &1.node_id)
      assert "B" in Enum.map(new_state_b.tokens, & &1.node_id)

      # THE actual regression assertion for the memo-key-unsoundness defect
      # (design doc §2.2.1/§2.4b): branch_id assignment in
      # dispatch_parallel_split/4 is purely positional (token_id <> "/" <>
      # index), independent of which node each edge targets, so
      # branch_ids_a and branch_ids_b -- and therefore the two JoinCounters
      # built from them -- are expected to be identical, byte-for-byte,
      # regardless of which cycle-adjacent branch ("X"-entry or "B"-entry)
      # find_matching_join/2's outer fold happens to evaluate first. A
      # plain node-keyed memo (iteration 2's falsified scheme) could not
      # guarantee this: §2.4b's own trace shows it produced a clean
      # singleton value for "GW" under a "B"-first entry order but a
      # two-element, non-singleton value under an "X"-first entry order --
      # asserting only per-fixture success (as the two blocks above do)
      # would not by itself distinguish "both orders happen to land on the
      # same conclusion" from "both orders happen to independently fail or
      # coincidentally agree." Comparing the two JoinCounters directly is
      # the literal cross-order agreement check the design doc calls for.
      assert Enum.sort(branch_ids_a) == Enum.sort(branch_ids_b)
      assert counter_a == counter_b
    end

    test "a pure escape-less cycle (no gateway reachable) fails the whole split cleanly" do
      g = pure_cycle_no_escape_graph()
      state = instance_state([token("split", "t1")])

      assert {:error, {:no_matching_join_found, "split"}} =
               Transition.transition(g, state, {:advance_token, "t1"})
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0400 -- a PARALLEL_GATEWAY nested inside one branch of an outer
  # PARALLEL_GATEWAY split, per
  # lib/letflow/design/iss0400-nested-parallel-gateway-fix.md §4.
  # ---------------------------------------------------------------------

  describe "transition/3 -- PARALLEL_GATEWAY nested inside a fork branch (ISS-0400 fixture 1)" do
    test "a nested split/join pair inside one branch resolves recursively and the outer split succeeds against the real outer join" do
      g = nested_parallel_split_graph()
      state = instance_state([token("outer_split", "t1")])

      assert {:ok, new_state, [{:parallel_split, "t1", "outer_split", branch_ids}]} =
               Transition.transition(g, state, {:advance_token, "t1"})

      assert length(branch_ids) == 2

      # Resolves against the real OUTER join -- never "inner_split" or
      # "inner_join", which is exactly the defect ISS-0400 fixes: before the
      # fix, this same call returned
      # {:error, {:no_matching_join_found, "outer_split"}} because
      # collect_leaf_gateways/3 reported "inner_split" itself as branch 1's
      # leaf and never continued past it.
      assert %JoinCounter{} = counter = new_state.join_counters["outer_join"]
      assert counter.expected_from_branches == MapSet.new(branch_ids)
      refute Map.has_key?(new_state.join_counters, "inner_split")
      refute Map.has_key?(new_state.join_counters, "inner_join")

      # The split itself only ever advances each branch one hop -- branch 1's
      # token lands on "pre" (its own edge.target), not deeper into the
      # subtree the lookahead search resolved. The deeper resolution is a
      # pure lookahead and never advances any token.
      assert Enum.map(new_state.tokens, & &1.node_id) |> Enum.sort() == ["outer_join", "pre"]
    end

    test "the nested split still functions as its own independently-dispatchable PARALLEL_GATEWAY split once a token actually reaches it" do
      # Confirms design §4/§5's explicit boundary: this fix is scoped to the
      # lookahead search find_matching_join/2 performs at outer-split
      # activation time, and must not change dispatch_parallel_gateway/4's
      # own runtime dispatch of the inner split when a token later actually
      # arrives there.
      g = nested_parallel_split_graph()
      state = instance_state([token("outer_split", "t1")])

      assert {:ok, state_after_split, [{:parallel_split, "t1", "outer_split", branch_ids}]} =
               Transition.transition(g, state, {:advance_token, "t1"})

      [branch_1_token] = Enum.filter(state_after_split.tokens, &(&1.node_id == "pre"))
      branch_1_token_id = branch_1_token.token_id
      assert branch_1_token_id in branch_ids

      # "pre" is a :HUMAN_TASK -- {:advance_token, _} cannot move a token off
      # it (dispatch_human_task/3's own "no automatic outgoing traversal"
      # contract, this module's moduledoc). {:complete_task, _} is the
      # caller's explicit "this task just completed" signal that actually
      # advances it, via its single unconditioned outgoing edge, onto
      # "inner_split".
      assert {:ok, state_at_inner_split, []} =
               Transition.transition(
                 g,
                 state_after_split,
                 {:complete_task, branch_1_token_id}
               )

      assert Enum.any?(state_at_inner_split.tokens, &(&1.node_id == "inner_split"))

      # Now dispatch the inner split for real -- it independently splits into
      # its own 2 branches and registers its own JoinCounter under
      # "inner_join", exactly as any other PARALLEL_GATEWAY split would.
      assert {:ok, state_after_inner_split,
              [{:parallel_split, ^branch_1_token_id, "inner_split", inner_branch_ids}]} =
               Transition.transition(
                 g,
                 state_at_inner_split,
                 {:advance_token, branch_1_token_id}
               )

      assert length(inner_branch_ids) == 2

      assert %JoinCounter{} =
               inner_counter = state_after_inner_split.join_counters["inner_join"]

      assert inner_counter.expected_from_branches == MapSet.new(inner_branch_ids)
    end
  end

  describe "transition/3 -- PARALLEL_GATEWAY nested split whose own inner branch dead-ends (ISS-0400 fixture 2, negative)" do
    test "a nested split with one internal branch dead-ending fails the whole outer split cleanly" do
      g = nested_split_dead_end_graph()
      state = instance_state([token("outer_split", "t1")])

      assert {:error, {:no_matching_join_found, "outer_split"}} =
               Transition.transition(g, state, {:advance_token, "t1"})
    end
  end

  describe "transition/3 -- PARALLEL_GATEWAY nested split whose own branch loops back to a still-open outer-walk ancestor (ISS-0400 fixture 3, CODE-DESIGN-VALIDATOR's counterexample)" do
    test "the branch resolves successfully against the real outer join, and terminates, when a nested split's own branch loops back to the ancestor node that led into it" do
      g = nested_split_ancestor_back_edge_graph()
      state = instance_state([token("outer_split", "t1")])

      # This is the direct regression assertion for the BLOCKER
      # CODE-DESIGN-VALIDATOR found in iteration 1 of the design: under
      # iteration 1's reset-based resolve_nested_split/3, this exact call
      # never returned at all (unbounded recursion, per design §3.2's
      # trace). Under this revision's no-reset mechanism, the SCC
      # {A, inner_split, ia} closes as one unit at "A" and edge b's escape
      # path (ib -> inner_join -> post -> outer_join) supplies the real leaf
      # value. Completing at all, within the test's own normal execution
      # (no explicit wall-clock budget needed here -- design §4's own
      # fixture-3 note: any completion in bounded time already falsifies
      # the non-termination failure mode), is itself part of what this test
      # proves, not merely the returned value.
      assert {:ok, new_state, [{:parallel_split, "t1", "outer_split", branch_ids}]} =
               Transition.transition(g, state, {:advance_token, "t1"})

      assert length(branch_ids) == 2

      assert %JoinCounter{} = counter = new_state.join_counters["outer_join"]
      assert counter.expected_from_branches == MapSet.new(branch_ids)
      refute Map.has_key?(new_state.join_counters, "inner_split")
      refute Map.has_key?(new_state.join_counters, "A")
    end
  end

  describe "transition/3 -- PARALLEL_GATEWAY nested split whose own branch loops back with no escape (ISS-0400 fixture 3b, negative twin)" do
    test "a nested split's branch that loops back to the ancestor with no escape edge anywhere in the cycle fails the whole outer split cleanly, without hanging" do
      g = nested_split_ancestor_back_edge_no_escape_graph()
      state = instance_state([token("outer_split", "t1")])

      # The SCC {A, inner_split, ia, ib} closes with an EMPTY aggregate leaf
      # set (no edge anywhere in the SCC reaches a PARALLEL_GATEWAY
      # terminal) -- a non-singleton (empty-set) agreement failure per
      # §2.5's unchanged rule. Same non-regression requirement as fixture 3:
      # completing at all, without hanging, is part of what this test
      # proves.
      assert {:error, {:no_matching_join_found, "outer_split"}} =
               Transition.transition(g, state, {:advance_token, "t1"})
    end
  end

  describe "transition/3 -- PARALLEL_GATEWAY doubly-nested split (ISS-0400 fixture 4, arbitrary-depth confirmation)" do
    test "a nested split whose own branch contains a second, deeper nested split still resolves recursively to the real outer join" do
      g = doubly_nested_parallel_split_graph()
      state = instance_state([token("outer_split", "t1")])

      assert {:ok, new_state, [{:parallel_split, "t1", "outer_split", branch_ids}]} =
               Transition.transition(g, state, {:advance_token, "t1"})

      assert length(branch_ids) == 2

      assert %JoinCounter{} = counter = new_state.join_counters["outer_join"]
      assert counter.expected_from_branches == MapSet.new(branch_ids)

      # Confirms memoization correctly threads through two levels of
      # resolve_nested_split/3 recursion -- neither the depth-1 nor the
      # depth-2 nested split's own id ever becomes a JoinCounter key.
      refute Map.has_key?(new_state.join_counters, "inner_split")
      refute Map.has_key?(new_state.join_counters, "inner2_split")
      refute Map.has_key?(new_state.join_counters, "inner_join")
      refute Map.has_key?(new_state.join_counters, "inner2_join")
    end
  end
end
