defmodule Letflow.Engine.TransitionTest do
  @moduledoc """
  Unit + property tests for `Letflow.Engine.Transition.transition/3` (REQ-044),
  implementing `lib/letflow/design/req044-transition-kernel.md` (the
  gate-approved design this module follows). Pure module, no `Letflow.Repo`/
  `Ecto.Sandbox` dependency anywhere in this file — `async: true` is correct
  here for the same reason it is in `test/letflow/definitions/graph_test.exs`
  (REQ-028): there is no shared Postgres sandbox connection for concurrent test
  processes to contend over.

  See `test/specs/REQ-044.md` for the full test design rationale, the AC
  traceability table, and the AC1 purity / AC5 moduledoc-text / AC6
  struct-reuse code-inspection evidence (those three criteria are structural,
  not runtime-testable — following the `test/letflow/definitions/graph_test.exs`
  AC5 precedent).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}
  alias Letflow.Engine.{InstanceState, Token, Transition}

  # ---------------------------------------------------------------------
  # Fixture builders
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
      pending_task_nodes: Keyword.get(opts, :pending_task_nodes, [])
    }
  end

  # ---------------------------------------------------------------------
  # AC2 — determinism (explicitly load-bearing per REQ-044's own text:
  # "identical inputs always produce identical outputs, demonstrated by an
  # explicit test rather than asserted"). Property test, not a single
  # hand-picked example — see the generators below.
  # ---------------------------------------------------------------------

  describe "transition/3 -- determinism (acceptance criterion 2, load-bearing)" do
    property "calling transition/3 twice with the identical (snapshot, state, event) triple always returns == -equal results" do
      check all({graph, state, event} <- world_generator(), max_runs: 150) do
        result_a = Transition.transition(graph, state, event)
        result_b = Transition.transition(graph, state, event)

        assert result_a == result_b
      end
    end
  end

  # world_generator/0 and its helpers build a randomized (graph, instance_state,
  # event) triple spanning every dispatch path this requirement's kernel can
  # take: :START/:END/:HUMAN_TASK real dispatch, :EXCLUSIVE_GATEWAY/
  # :PARALLEL_GATEWAY stubs, the catch-all (:SERVICE_TASK/:TIMER/:SUB_PROCESS/
  # unrecognized atoms), {:error, :unknown_node_id}, {:error, :unknown_token_id},
  # and {:error, :unknown_event_type} -- so the determinism property is
  # exercised across the {:ok, ...} and every {:error, ...} shape alike, not
  # just the happy path. "ghost-node"/"ghost-token" are deliberately excluded
  # from @node_id_pool/@token_id_pool so references to them are guaranteed
  # misses, giving reliable coverage of the two "unknown" error branches on
  # every run rather than leaving them to chance.

  @node_id_pool ["n1", "n2", "n3", "n4"]
  @token_id_pool ["t1", "t2", "t3"]
  @ghost_node_id "ghost-node"
  @ghost_token_id "ghost-token"

  defp node_type_gen do
    StreamData.member_of([
      :START,
      :END,
      :HUMAN_TASK,
      :SERVICE_TASK,
      :EXCLUSIVE_GATEWAY,
      :PARALLEL_GATEWAY,
      :TIMER,
      :SUB_PROCESS
    ])
  end

  defp edge_gen(node_ids) do
    possible_ids = node_ids ++ [@ghost_node_id]

    gen all(
          id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 4),
          source <- StreamData.member_of(possible_ids),
          target <- StreamData.member_of(possible_ids)
        ) do
      %Edge{id: id, source: source, target: target}
    end
  end

  defp token_gen(node_ids) do
    possible_ids = node_ids ++ [@ghost_node_id]

    gen all(
          node_id <- StreamData.member_of(possible_ids),
          token_id <- StreamData.member_of(@token_id_pool ++ [@ghost_token_id])
        ) do
      %Token{node_id: node_id, token_id: token_id}
    end
  end

  defp event_gen do
    token_id_gen = StreamData.member_of(@token_id_pool ++ [@ghost_token_id])

    StreamData.frequency([
      # The well-formed shape -- most of the generated events, so most runs
      # exercise real dispatch (or a clean :unknown_token_id/:unknown_node_id).
      {7, StreamData.map(token_id_gen, &{:advance_token, &1})},
      # A tuple with a recognizable-but-wrong tag -- unknown_event_type.
      {2, StreamData.map(token_id_gen, &{:unexpected_tag, &1})},
      # Not even a tuple at all -- unknown_event_type via the bare catch-all.
      {1, StreamData.member_of([:not_a_tuple, "also not a tuple", 42])}
    ])
  end

  defp world_generator do
    gen all(
          # Deliberately NOT uniq_list_of: transition/3 never validates
          # graph-structural well-formedness (that's REQ-028's job, upstream
          # of this pure kernel), so duplicate node ids are a legal input this
          # generator should be free to produce -- and plain list_of avoids
          # StreamData.TooManyDuplicatesError against this small 4-element
          # domain at low generation sizes.
          node_ids <-
            StreamData.list_of(StreamData.member_of(@node_id_pool), min_length: 1, max_length: 4),
          node_types <- StreamData.fixed_list(List.duplicate(node_type_gen(), length(node_ids))),
          edges <- StreamData.list_of(edge_gen(node_ids), max_length: 5),
          tokens <- StreamData.list_of(token_gen(node_ids), max_length: 3),
          status <- StreamData.member_of([:active, :completed, :cancelled, :error]),
          event <- event_gen()
        ) do
      nodes =
        Enum.zip_with(node_ids, node_types, fn id, type -> %Node{id: id, node_type: type} end)

      graph = %Graph{nodes: nodes, edges: edges}

      state = %InstanceState{
        instance_id: "prop-inst",
        status: status,
        tokens: tokens,
        variables: %{},
        pending_task_nodes: []
      }

      {graph, state, event}
    end
  end

  # ---------------------------------------------------------------------
  # AC3, first half -- unknown event type never raises
  # ---------------------------------------------------------------------

  describe "transition/3 -- unknown event type (acceptance criterion 3, first half)" do
    test "a tuple with an unrecognized tag returns {:error, {:unknown_event_type, event}}, not a crash" do
      g = graph([node("s", :START)], [])
      state = instance_state([token("s", "t1")])
      event = {:bogus_event, "t1"}

      assert Transition.transition(g, state, event) == {:error, {:unknown_event_type, event}}
    end

    test "a non-tuple event value also returns {:error, {:unknown_event_type, event}}, not a crash" do
      g = graph([node("s", :START)], [])
      state = instance_state([token("s", "t1")])

      for event <- [:just_an_atom, "a string", 42, %{}, []] do
        assert Transition.transition(g, state, event) == {:error, {:unknown_event_type, event}},
               "expected {:error, {:unknown_event_type, #{inspect(event)}}}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # AC3, second half -- a token on a node_id absent from the snapshot graph
  # returns an error naming the offending node_id
  # ---------------------------------------------------------------------

  describe "transition/3 -- token on a missing node_id (acceptance criterion 3, second half)" do
    test "a token positioned on a node_id absent from the snapshot returns {:error, {:unknown_node_id, node_id}}" do
      g = graph([node("real", :START)], [])
      state = instance_state([token("ghost-node", "t1")])

      assert Transition.transition(g, state, {:advance_token, "t1"}) ==
               {:error, {:unknown_node_id, "ghost-node"}}
    end

    test "the error names the exact offending node_id, not a generic message" do
      g = graph([], [])
      state = instance_state([token("some-specific-node-42", "t1")])

      assert {:error, {:unknown_node_id, "some-specific-node-42"}} =
               Transition.transition(g, state, {:advance_token, "t1"})
    end
  end

  # ---------------------------------------------------------------------
  # Defensive, non-AC path (design doc §7.3): unknown token_id. Not literally
  # named by REQ-044's acceptance criteria, but the design doc explicitly asks
  # TEST-DESIGNER to cover it anyway, since it's part of the same "never
  # raise" totality bar AC3 establishes for the other two lookups.
  # ---------------------------------------------------------------------

  describe "transition/3 -- unknown token_id (defensive totality, design doc §7.3)" do
    test "an event naming a token_id absent from instance_state.tokens returns {:error, {:unknown_token_id, token_id}}, not a crash" do
      g = graph([node("s", :START)], [])
      state = instance_state([token("s", "t1")])

      assert Transition.transition(g, state, {:advance_token, "does-not-exist"}) ==
               {:error, {:unknown_token_id, "does-not-exist"}}
    end
  end

  # ---------------------------------------------------------------------
  # AC4, case 1/5 -- :START advances the token; pending_task_nodes unchanged
  # ---------------------------------------------------------------------

  describe "transition/3 -- :START node dispatch (5-way case 1/5, design doc §6.1)" do
    test "advances the token onto the target of its first outgoing edge in declaration order; pending_task_nodes unchanged" do
      g =
        graph(
          [node("s", :START), node("a", :HUMAN_TASK), node("b", :HUMAN_TASK)],
          # Two outgoing edges from "s" -- e1 (to "a") is declared first, so
          # it is the one taken (design doc §6.1's tie-break), not e2.
          [edge("e1", "s", "a"), edge("e2", "s", "b")]
        )

      state = instance_state([token("s", "t1")], pending_task_nodes: [])

      assert {:ok, new_state, []} = Transition.transition(g, state, {:advance_token, "t1"})
      assert new_state.tokens == [%Token{node_id: "a", token_id: "t1"}]
      assert new_state.pending_task_nodes == []
    end

    test "other tokens in the instance are left untouched, and list order is preserved" do
      g = graph([node("s", :START), node("a", :END)], [edge("e1", "s", "a")])
      other = token("a", "other-token")
      moving = token("s", "t1")
      state = instance_state([other, moving])

      assert {:ok, new_state, []} = Transition.transition(g, state, {:advance_token, "t1"})
      assert new_state.tokens == [other, %Token{node_id: "a", token_id: "t1"}]
    end

    test "a START node with no outgoing edge at all returns a named error rather than raising (defensive totality)" do
      g = graph([node("s", :START)], [])
      state = instance_state([token("s", "t1")])

      assert Transition.transition(g, state, {:advance_token, "t1"}) ==
               {:error, {:unknown_node_id, "s"}}
    end
  end

  # ---------------------------------------------------------------------
  # AC4, case 2/5 -- :END removes the token; pending_task_nodes unchanged.
  # Also covers item 6 of the handoff: END moves the instance toward
  # :completed (design doc §6.2/§12.2's multi-token completion rule).
  # ---------------------------------------------------------------------

  describe "transition/3 -- :END node dispatch (5-way case 2/5, design doc §6.2) -- moves the instance toward :completed" do
    test "the last live token reaching END is removed and status becomes :completed" do
      g = graph([node("e", :END)], [])
      state = instance_state([token("e", "t1")], status: :active, pending_task_nodes: [])

      assert {:ok, new_state, []} = Transition.transition(g, state, {:advance_token, "t1"})
      assert new_state.tokens == []
      assert new_state.status == :completed
      assert new_state.pending_task_nodes == []
    end

    test "a token reaching END while another token is still live: removed, status stays unchanged (multi-token case, design doc §12.2)" do
      g = graph([node("e", :END)], [])
      other = token("elsewhere", "other-token")
      state = instance_state([other, token("e", "t1")], status: :active)

      assert {:ok, new_state, []} = Transition.transition(g, state, {:advance_token, "t1"})
      assert new_state.tokens == [other]
      assert new_state.status == :active
    end
  end

  # ---------------------------------------------------------------------
  # AC4, case 3/5 -- :HUMAN_TASK: token stays put, pending_task_nodes gains it
  # ---------------------------------------------------------------------

  describe "transition/3 -- :HUMAN_TASK node dispatch (5-way case 3/5, design doc §6.3) -- pending_task_nodes gains the node" do
    test "the token stays at the HUMAN_TASK node, and pending_task_nodes gains this exact token" do
      g = graph([node("h", :HUMAN_TASK)], [])
      tok = token("h", "t1")
      state = instance_state([tok], pending_task_nodes: [])

      assert {:ok, new_state, []} = Transition.transition(g, state, {:advance_token, "t1"})
      assert new_state.tokens == [tok]
      assert new_state.pending_task_nodes == [tok]
    end

    test "pending_task_nodes accumulates -- an existing entry is preserved, the new token appended after it" do
      g = graph([node("h", :HUMAN_TASK)], [])
      already_pending = token("other-human-task", "earlier-token")
      tok = token("h", "t1")
      state = instance_state([tok], pending_task_nodes: [already_pending])

      assert {:ok, new_state, []} = Transition.transition(g, state, {:advance_token, "t1"})
      assert new_state.pending_task_nodes == [already_pending, tok]
    end
  end

  # ---------------------------------------------------------------------
  # AC4, case 4/5 -- :EXCLUSIVE_GATEWAY stub: named error, never touches
  # pending_task_nodes (there is no {:ok, new_state, _} at all to touch it
  # with -- the point AC4 makes about this node type is trivially true by
  # construction here, and this test proves the error is the specific named
  # stub error, not a raised exception or a silent {:ok, ...}).
  # ---------------------------------------------------------------------

  describe "transition/3 -- :EXCLUSIVE_GATEWAY node dispatch (5-way case 4/5, stub, design doc §6.4) -- pending_task_nodes unchanged" do
    test "returns the named :gateway_not_yet_implemented error, never {:ok, ...}" do
      g = graph([node("gw", :EXCLUSIVE_GATEWAY)], [])
      state = instance_state([token("gw", "t1")], pending_task_nodes: [])

      assert Transition.transition(g, state, {:advance_token, "t1"}) ==
               {:error, {:gateway_not_yet_implemented, :EXCLUSIVE_GATEWAY, "gw"}}

      # No new InstanceState value is ever produced on this path -- the
      # caller's own `state` binding is definitionally untouched (Elixir
      # immutability), so pending_task_nodes did not gain anything.
      assert state.pending_task_nodes == []
    end
  end

  # ---------------------------------------------------------------------
  # AC4, case 5/5 -- :PARALLEL_GATEWAY stub: same shape as :EXCLUSIVE_GATEWAY
  # ---------------------------------------------------------------------

  describe "transition/3 -- :PARALLEL_GATEWAY node dispatch (5-way case 5/5, stub, design doc §6.5) -- pending_task_nodes unchanged" do
    test "returns the named :gateway_not_yet_implemented error, never {:ok, ...}" do
      g = graph([node("gw", :PARALLEL_GATEWAY)], [])
      state = instance_state([token("gw", "t1")], pending_task_nodes: [])

      assert Transition.transition(g, state, {:advance_token, "t1"}) ==
               {:error, {:gateway_not_yet_implemented, :PARALLEL_GATEWAY, "gw"}}

      assert state.pending_task_nodes == []
    end
  end

  # ---------------------------------------------------------------------
  # Beyond REQ-044's 6 bare acceptance criteria -- the catch-all for the 3
  # remaining node_type() variants outside the 5-way dispatch, plus a bogus
  # atom. Not separately named by an AC (only the 5-way dispatch is), but
  # necessary for transition/3's own "never raises" totality bar (design doc
  # §6.6) and cheap to lock in as a regression test, matching the
  # test/letflow/definitions/graph_test.exs precedent of testing beyond the
  # bare AC list where the design doc flags a real, deliberate behavior.
  # ---------------------------------------------------------------------

  describe "transition/3 -- catch-all for node types outside the 5-way dispatch (design doc §6.6, beyond the bare AC list)" do
    test "SERVICE_TASK, TIMER, SUB_PROCESS, and an unrecognized node_type atom all return a named error, never raise" do
      for {node_type, node_id} <- [
            {:SERVICE_TASK, "svc"},
            {:TIMER, "tmr"},
            {:SUB_PROCESS, "sub"},
            {:NOT_A_REAL_TYPE, "bogus"}
          ] do
        g = graph([node(node_id, node_type)], [])
        state = instance_state([token(node_id, "t1")])

        assert Transition.transition(g, state, {:advance_token, "t1"}) ==
                 {:error, {:node_type_not_yet_implemented, node_type, node_id}}
      end
    end
  end

  # ---------------------------------------------------------------------
  # Item 7 of the handoff -- reuse of REQ-028's graph structs. This is a
  # structural/code-inspection property (design doc §1: "no new
  # DefinitionGraph/GraphNode/GraphEdge/NodeType type is declared anywhere
  # under lib/letflow/engine/"), already independently confirmed by
  # CODE-DESIGN-VALIDATOR and REVIEWER reading the implementation directly.
  # It is not repeated here as a dedicated runtime test (there is no runtime
  # behavior distinguishing "reuses Graph.t()" from "defines a lookalike
  # struct with the same field names" other than the module name itself,
  # which grep/code-reading already settles more directly than an ExUnit
  # assertion could). It is, however, verified *incidentally* and
  # structurally by every single test above: every fixture in this file
  # constructs and passes a real %Letflow.Definitions.Graph{} /
  # %Letflow.Definitions.Graph.Node{} value into transition/3, and
  # transition/3's own head pattern-matches on %Graph{} (see
  # lib/letflow/engine/transition.ex:123) -- if Transition depended on some
  # other, duplicate graph struct type, every test in this file would fail to
  # compile or dispatch at all. See test/specs/REQ-044.md for the full note.
  # ---------------------------------------------------------------------
end
