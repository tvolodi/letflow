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
end
