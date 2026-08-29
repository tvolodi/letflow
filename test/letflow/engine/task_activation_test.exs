defmodule Letflow.Engine.TaskActivationTest do
  @moduledoc """
  Unit tests for REQ-047's `Letflow.Engine.TaskActivation` — the pure
  diff/attrs-building layer for task-activation persistence (EE-03). See
  `lib/letflow/design/req047-task-activation-persistence.md` (the
  gate-approved design this module implements) and `test/specs/REQ-047.md`
  for the full test-case rationale and AC traceability.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this
  file except for the `insert_attrs/4`/`token_id_to_record_id/2` cases, which
  build plain structs by hand rather than hitting the DB — `async: true` for
  the same reason `test/letflow/engine/parallel_gateway_test.exs` (REQ-051)
  and `test/letflow/engine/transition_test.exs` (REQ-044) use it.

  DB-level integration coverage (the same acceptance criteria proven end to
  end through `Letflow.Engine.create/2`'s real `Ecto.Multi`) lives in
  `test/letflow/engine_test.exs`'s own `"(REQ-047 ...)"`-prefixed describe
  blocks, not here.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}
  alias Letflow.Engine.{InstanceState, TaskActivation, Token, TokenRecord, Transition}

  # ---------------------------------------------------------------------
  # Fixture builders (mirrors transition_test.exs's / parallel_gateway_test.exs's
  # own helpers exactly)
  # ---------------------------------------------------------------------

  defp node(id, type, opts \\ []) do
    %Node{
      id: id,
      node_type: type,
      label: Keyword.get(opts, :label),
      attributes: Keyword.get(opts, :attributes)
    }
  end

  defp edge(id, source, target, opts \\ []) do
    %Edge{
      id: id,
      source: source,
      target: target,
      condition: Keyword.get(opts, :condition),
      is_default: Keyword.get(opts, :is_default, false)
    }
  end

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

  # ---------------------------------------------------------------------------------
  # Test spec case 1 -- newly_pending_tokens/2
  # ---------------------------------------------------------------------------------

  describe "newly_pending_tokens/2" do
    test "returns only tokens whose token_id is new relative to the previous list" do
      previous = [token("task_a", "t1")]
      new = [token("task_a", "t1"), token("task_b", "t2")]

      assert TaskActivation.newly_pending_tokens(previous, new) == [token("task_b", "t2")]
    end

    test "returns [] when every token_id in the new list was already present" do
      previous = [token("task_a", "t1")]
      new = [token("task_a", "t1")]

      assert TaskActivation.newly_pending_tokens(previous, new) == []
    end

    test "returns [] when the new list is empty regardless of the previous list" do
      assert TaskActivation.newly_pending_tokens([token("task_a", "t1")], []) == []
    end

    test "the empty-list previous (create/2's own call site, design §5.1) treats every entry as new" do
      new = [token("task_a", "t1"), token("task_b", "t2")]

      assert TaskActivation.newly_pending_tokens([], new) == new
    end
  end

  # ---------------------------------------------------------------------------------
  # Test spec case 2 -- resolve_assignee/1 (AC4)
  # ---------------------------------------------------------------------------------

  describe "resolve_assignee/1" do
    test "reads assignee_ref from attributes[\"role\"] and assignee_type from attributes[\"assignee_type\"]" do
      n =
        node("task", :HUMAN_TASK, attributes: %{"role" => "approver", "assignee_type" => "GROUP"})

      assert TaskActivation.resolve_assignee(n) == {"GROUP", "approver"}
    end

    test "assignee_type is nil when the key is absent -- no invented default (OQ-1)" do
      n = node("task", :HUMAN_TASK, attributes: %{"role" => "approver"})

      assert TaskActivation.resolve_assignee(n) == {nil, "approver"}
    end

    # AC4's own concrete proof at this layer: a group name with zero members is not a
    # concept resolve_assignee/1 can even see -- it copies attributes verbatim, so
    # "no members" (unvalidated by anything in this codebase) can never surface as an
    # error here. This is the pure-layer half of test/specs/REQ-047.md case 2/10.
    test "an assignee_ref naming a group with no members is returned unchanged, no error" do
      n =
        node("task", :HUMAN_TASK,
          attributes: %{"role" => "empty-group", "assignee_type" => "GROUP"}
        )

      assert TaskActivation.resolve_assignee(n) == {"GROUP", "empty-group"}
    end

    test "a nil attributes map is treated as empty, not a crash" do
      n = node("task", :HUMAN_TASK, attributes: nil)

      assert TaskActivation.resolve_assignee(n) == {nil, nil}
    end
  end

  # ---------------------------------------------------------------------------------
  # Test spec case 3 -- insert_attrs/4
  # ---------------------------------------------------------------------------------

  describe "insert_attrs/4" do
    test "builds the six-key attrs map, node_name from node.label, status never included" do
      t = token("task", "t1")
      n = node("task", :HUMAN_TASK, label: "Approve request", attributes: %{"role" => "approver"})

      attrs = TaskActivation.insert_attrs("inst-1", "record-1", t, n)

      assert attrs == %{
               instance_id: "inst-1",
               token_id: "record-1",
               node_id: "task",
               node_name: "Approve request",
               assignee_type: nil,
               assignee_ref: "approver"
             }

      refute Map.has_key?(attrs, :status)
    end

    test "node_name falls back to node.id when node.label is nil (design §4.2, OQ-2)" do
      t = token("task", "t1")
      n = node("task", :HUMAN_TASK, label: nil, attributes: %{"role" => "approver"})

      attrs = TaskActivation.insert_attrs("inst-1", "record-1", t, n)

      assert attrs.node_name == "task"
    end
  end

  # ---------------------------------------------------------------------------------
  # Test spec case 4 -- token_id_to_record_id/2
  # ---------------------------------------------------------------------------------

  describe "token_id_to_record_id/2" do
    test "zips two same-order lists into a token_id => record.id map" do
      tokens = [token("task_a", "t1"), token("task_b", "t2")]

      records = [
        %TokenRecord{id: "rec-1", node_id: "task_a"},
        %TokenRecord{id: "rec-2", node_id: "task_b"}
      ]

      assert TaskActivation.token_id_to_record_id(tokens, records) == %{
               "t1" => "rec-1",
               "t2" => "rec-2"
             }
    end

    test "returns %{} for two empty lists" do
      assert TaskActivation.token_id_to_record_id([], []) == %{}
    end
  end

  # ---------------------------------------------------------------------------------
  # cancel_pending_timers/5 -- REQ-187's real implementation, replacing the
  # former cancel_pending_timers/2 no-op this describe block used to cover.
  # This module's own DB-touching functions (append_multi/6,
  # append_multi_from_existing_records/6) already have their real behavior
  # proven end to end through Letflow.Engine.create/2 / complete_task/3's
  # own Ecto.Multi in test/letflow/engine_test.exs, not in this pure/async
  # file (see moduledoc above) -- cancel_pending_timers/5's own real
  # status-guarded UPDATE, SCH-03 concurrency edge cases, and both call
  # sites (finalize_instance_projection/5, run_cancel_instance/5) get the
  # same DB-level integration coverage there.
  # ---------------------------------------------------------------------------------

  describe "cancel_pending_timers/5" do
    test "its own @doc names the SCH-03 status-guarded UPDATE and both known call sites" do
      {:docs_v1, _anno, _lang, _format, _module_doc, _meta, docs} =
        Code.fetch_docs(TaskActivation)

      {_key, _anno, _sig, %{"en" => doc}, _meta} =
        Enum.find(docs, fn
          {{:function, :cancel_pending_timers, 5}, _anno, _sig, _doc, _meta} -> true
          _other -> false
        end)

      normalized = String.replace(doc, ~r/\s+/, " ")

      assert normalized =~ "SCH-03"
      assert normalized =~ "instance_completed"
      assert normalized =~ "instance_cancelled"
    end
  end

  # ---------------------------------------------------------------------------------
  # Test spec case 5 -- one explicit unit test per node type (AC3): calling
  # Transition.transition/3 directly (REQ-044's real, shipped dispatch clauses) and
  # then diffing pending_task_nodes with newly_pending_tokens/2, asserting []. This
  # *verifies* the transition function's own guarantee against its real code, rather
  # than merely assuming it because the design doc says so.
  # ---------------------------------------------------------------------------------

  defp assert_no_newly_pending(graph, state, token_id) do
    previous_pending = state.pending_task_nodes

    assert {:ok, new_state, _pending_events} =
             Transition.transition(graph, state, {:advance_token, token_id})

    assert TaskActivation.newly_pending_tokens(previous_pending, new_state.pending_task_nodes) ==
             []
  end

  describe "pending_task_nodes diff per node type (AC3)" do
    test "a token dispatched off :START never appears in the pending_task_nodes diff" do
      g = graph([node("start", :START), node("mid", :HUMAN_TASK)], [edge("e1", "start", "mid")])
      state = instance_state([token("start", "t1")])

      assert_no_newly_pending(g, state, "t1")
    end

    test "a token dispatched into :END never appears in the pending_task_nodes diff" do
      g = graph([node("end", :END)], [])
      state = instance_state([token("end", "t1")])

      assert_no_newly_pending(g, state, "t1")
    end

    test "a token dispatched through :EXCLUSIVE_GATEWAY never appears in the pending_task_nodes diff" do
      g =
        graph(
          [node("gw", :EXCLUSIVE_GATEWAY), node("end", :END)],
          [edge("e1", "gw", "end", is_default: true)]
        )

      state = instance_state([token("gw", "t1")])

      assert_no_newly_pending(g, state, "t1")
    end

    test "a token dispatched through :PARALLEL_GATEWAY (pass-through) never appears in the pending_task_nodes diff" do
      g =
        graph(
          [node("gw", :PARALLEL_GATEWAY), node("end", :END)],
          [edge("e1", "gw", "end")]
        )

      state = instance_state([token("gw", "t1")])

      assert_no_newly_pending(g, state, "t1")
    end

    # Contrast case (not itself an AC3 target -- proves assert_no_newly_pending/3
    # would actually fail if a dispatch clause did append, i.e. that this helper
    # is a real test and not a tautology): :HUMAN_TASK is the one node type this
    # design's whole diff mechanism exists to detect.
    test "contrast: a token dispatched into :HUMAN_TASK DOES appear in the diff" do
      g = graph([node("task", :HUMAN_TASK)], [])
      state = instance_state([token("task", "t1")])

      assert {:ok, new_state, _pending_events} =
               Transition.transition(g, state, {:advance_token, "t1"})

      assert TaskActivation.newly_pending_tokens(
               state.pending_task_nodes,
               new_state.pending_task_nodes
             ) ==
               [token("task", "t1")]
    end
  end
end
