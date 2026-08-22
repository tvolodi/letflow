defmodule Letflow.Engine.SubProcessTest do
  @moduledoc """
  Unit tests for REQ-062's pure surfaces: `Letflow.Engine.SubProcess`'s
  `build_child_initial_variables/2` (input filter, AC1/AC2), `build_parent_merge_variables/2`
  (output filter, AC4), and `to_error_args/6` (AC8's 4-failure-mode -> `details.code`
  mapping) -- plus `Letflow.Engine.Transition`'s two new `:SUB_PROCESS` dispatch clauses
  (`dispatch_sub_process_entry/4`, `dispatch_sub_process_completion/4`, design doc §2.3/§2.4)
  and the AC5 GH-428 struct-update regression. See
  `lib/letflow/design/req062-sub-process-runtime.md` and `test/specs/REQ-062.md`.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this file --
  `async: true` for the same reason `test/letflow/engine/transition_test.exs` (REQ-044) and
  `test/letflow/engine/parallel_gateway_test.exs` (REQ-051) use it. DB-level integration
  coverage (real child-instance creation/completion through `Letflow.Engine.create/2` and
  `Letflow.Engine.complete_task/3`) lives in `test/letflow/engine_sub_process_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}
  alias Letflow.Engine.{InstanceState, SubProcess, Token, Transition}

  # ---------------------------------------------------------------------
  # Fixture builders (mirrors transition_test.exs's / parallel_gateway_test.exs's
  # own helpers exactly)
  # ---------------------------------------------------------------------

  defp node(id, type), do: %Node{id: id, node_type: type}
  defp edge(id, source, target), do: %Edge{id: id, source: source, target: target}
  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}

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

  defp entry(name, opts) do
    %{
      name: name,
      json_schema: Keyword.get(opts, :json_schema, %{"type" => "string"}),
      required: Keyword.get(opts, :required, false)
    }
  end

  # ---------------------------------------------------------------------------------
  # AC1 / AC2 -- build_child_initial_variables/2 (activation-time input filter)
  # ---------------------------------------------------------------------------------

  describe "build_child_initial_variables/2 -- AC2: no declared interface copies the full map" do
    test "interface == nil returns parent_variables unchanged, EXT-05" do
      parent_variables = %{"a" => 1, "b" => "two", "c" => [3]}

      assert SubProcess.build_child_initial_variables(nil, parent_variables) ==
               {:ok, parent_variables}
    end
  end

  describe "build_child_initial_variables/2 -- AC1: a declared interface filters to ONLY the named inputs" do
    test "a parent variable not named in inputs is absent from the child's initial variables" do
      interface = %{inputs: [entry("amount", json_schema: %{"type" => "number"})]}
      parent_variables = %{"amount" => 5, "secret" => "do-not-leak"}

      assert {:ok, child_vars} =
               SubProcess.build_child_initial_variables(interface, parent_variables)

      assert child_vars == %{"amount" => 5}
      refute Map.has_key?(child_vars, "secret")
    end

    test "inputs: [] (explicit, zero declared inputs) produces %{} -- never a fallback to EXT-05" do
      interface = %{inputs: []}
      parent_variables = %{"amount" => 5}

      assert SubProcess.build_child_initial_variables(interface, parent_variables) == {:ok, %{}}
    end

    test "an absent optional input is silently omitted, no error" do
      interface = %{inputs: [entry("amount", required: false)]}

      assert SubProcess.build_child_initial_variables(interface, %{}) == {:ok, %{}}
    end

    test "an absent required input -> {:missing_required_input, name}, the FIRST such entry in declared order" do
      interface = %{
        inputs: [
          entry("first", required: true),
          entry("second", required: true)
        ]
      }

      assert SubProcess.build_child_initial_variables(interface, %{}) ==
               {:error, {:missing_required_input, "first"}}
    end

    test "a present input failing its own json_schema -> {:input_schema_violation, name, failures}, non-empty failures" do
      interface = %{inputs: [entry("amount", json_schema: %{"type" => "number"})]}
      parent_variables = %{"amount" => "not-a-number"}

      assert {:error, {:input_schema_violation, "amount", failures}} =
               SubProcess.build_child_initial_variables(interface, parent_variables)

      assert failures != []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- build_parent_merge_variables/2 (completion-time output filter). Same shared
  # filter_entries/2 algorithm as build_child_initial_variables/2 -- one representative
  # test per branch rather than re-covering every branch a second time (already fully
  # exercised above), matching req032's own "shared algorithm, not re-covered" precedent.
  # ---------------------------------------------------------------------------------

  describe "build_parent_merge_variables/2 -- AC4: only the named outputs merge into the parent" do
    test "interface == nil returns child_variables unchanged, EXT-05" do
      child_variables = %{"result" => true, "scratch" => "internal"}

      assert SubProcess.build_parent_merge_variables(nil, child_variables) ==
               {:ok, child_variables}
    end

    test "a child variable not named in outputs is absent from the returned merge map" do
      interface = %{outputs: [entry("result", json_schema: %{"type" => "boolean"})]}
      child_variables = %{"result" => true, "scratch" => "internal, never merged"}

      assert {:ok, merge_vars} =
               SubProcess.build_parent_merge_variables(interface, child_variables)

      assert merge_vars == %{"result" => true}
      refute Map.has_key?(merge_vars, "scratch")
    end

    test "an absent required output -> {:missing_required_output, name}" do
      interface = %{outputs: [entry("result", required: true)]}

      assert SubProcess.build_parent_merge_variables(interface, %{}) ==
               {:error, {:missing_required_output, "result"}}
    end

    test "a present output failing its own json_schema -> {:output_schema_violation, name, failures}" do
      interface = %{outputs: [entry("result", json_schema: %{"type" => "boolean"})]}
      child_variables = %{"result" => "not-a-boolean"}

      assert {:error, {:output_schema_violation, "result", failures}} =
               SubProcess.build_parent_merge_variables(interface, child_variables)

      assert failures != []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 (pure half) -- to_error_args/6: each of the 4 failure shapes maps to its own
  # `details.code`, all sharing the single `error_type: :subprocess_interface_violation`
  # reserved atom (design doc §3.2.3) -- never 4 distinct top-level error_type atoms, and
  # never a bespoke event/transition type of its own.
  # ---------------------------------------------------------------------------------

  describe "to_error_args/6 -- AC8: 4 distinct details.code values, one shared error_type" do
    test "each of the 4 SPC-01 failures maps to its own R-Co-named details.code" do
      cases = [
        {{:missing_required_input, "amount"}, "SUB_PROCESS_MISSING_REQUIRED_INPUT"},
        {{:input_schema_violation, "amount", []}, "SUB_PROCESS_INPUT_SCHEMA_VIOLATION"},
        {{:missing_required_output, "result"}, "SUB_PROCESS_MISSING_REQUIRED_OUTPUT"},
        {{:output_schema_violation, "result", []}, "SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION"}
      ]

      results =
        for {failure, expected_code} <- cases do
          error_args =
            SubProcess.to_error_args(failure, "inst-1", "sp1", %{}, "actor-1", "idk-1")

          assert error_args.error_type == :subprocess_interface_violation
          assert error_args.details.code == expected_code
          expected_code
        end

      # 4 distinct codes, never collapsed onto one another.
      assert Enum.uniq(results) |> length() == 4
    end

    test "carries the caller-supplied instance_id/variables/actor_id/idempotency_key through unchanged" do
      error_args =
        SubProcess.to_error_args(
          {:missing_required_input, "amount"},
          "inst-42",
          "sp1",
          %{"seed" => 1},
          "actor-99",
          "idk-77"
        )

      assert error_args.instance_id == "inst-42"
      assert error_args.variables == %{"seed" => 1}
      assert error_args.actor_id == "actor-99"
      assert error_args.idempotency_key == "idk-77"
      assert error_args.affected == {:field, "amount"}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- moduledoc states child creation is internal-only, unreachable from create/2.
  # Mirrors sub_process_interface_test.exs's own normalized_moduledoc/1 precedent.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC6: internal-only child creation, no second public entry point" do
    test "Letflow.Engine.SubProcess's moduledoc states create/2 cannot reach this module" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.SubProcess)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~
               "Nothing in this module is reachable from `Letflow.Engine.create/2`'s public"

      assert normalized =~ "There is no second `create/N`-shaped public entry point here."
    end
  end

  # ---------------------------------------------------------------------------------
  # Transition dispatch -- :SUB_PROCESS entry (design doc §2.3)
  # ---------------------------------------------------------------------------------

  describe "transition/3 -- :SUB_PROCESS entry, first arrival (design doc §2.3)" do
    test "a token with no child yet running stays parked at the node and emits {:sub_process_start, ...}" do
      g = graph([node("sp1", :SUB_PROCESS)], [])
      token = %Token{node_id: "sp1", token_id: "t1"}
      state = instance_state([token])

      assert {:ok, new_state, [{:sub_process_start, "t1", "sp1"}]} =
               Transition.transition(g, state, {:advance_token, "t1"})

      # Position/instance_state genuinely unchanged -- zero I/O, zero token movement
      # (design doc: "child creation is a DB write, which Transition may never perform").
      assert new_state == state
    end
  end

  describe "transition/3 -- :SUB_PROCESS entry, re-dispatch guard (design doc §2.3)" do
    test "a token already waiting on a child returns unchanged state and NO pending event" do
      g = graph([node("sp1", :SUB_PROCESS)], [])
      token = %Token{node_id: "sp1", token_id: "t1", waiting_child_instance_id: "child-1"}
      state = instance_state([token])

      assert Transition.transition(g, state, {:advance_token, "t1"}) == {:ok, state, []}
    end
  end

  # ---------------------------------------------------------------------------------
  # Transition dispatch -- {:sub_process_completed, token_id} (design doc §2.4)
  # ---------------------------------------------------------------------------------

  describe "transition/3 -- {:sub_process_completed, token_id} clears the wait and advances (design doc §2.4)" do
    test "clears waiting_child_instance_id (struct-update) and moves the token off its single outgoing edge" do
      g =
        graph(
          [node("sp1", :SUB_PROCESS), node("after", :END)],
          [edge("e1", "sp1", "after")]
        )

      token = %Token{node_id: "sp1", token_id: "t1", waiting_child_instance_id: "child-1"}
      state = instance_state([token])

      # `Transition.transition/3` performs exactly ONE dispatch per call --
      # `advance_off_completed_node/4` -> `advance_token/3` only repositions the token
      # onto the edge's target node_id, it does not recurse into that target node's own
      # type-specific dispatch. So this first call proves the wait was cleared
      # (struct-update, not a fresh literal that drops other fields) AND the token moved
      # off "sp1" onto "after", in one hop -- but "after" being a :END node is not yet
      # dispatched.
      assert {:ok, new_state, []} =
               Transition.transition(g, state, {:sub_process_completed, "t1"})

      assert new_state.tokens == [
               %Token{
                 token_id: "t1",
                 node_id: "after",
                 waiting_child_instance_id: nil,
                 branch_id: nil
               }
             ]

      # Second hop, mirroring transition_test.exs's own ":END node dispatch" test
      # ("the last live token reaching END is removed and status becomes :completed"),
      # which likewise drives :END's removal-and-complete behavior via a second,
      # separate `{:advance_token, token_id}` call rather than getting it "for free"
      # from the prior edge-traversal call. dispatch_end/3's "removes the affected
      # token, :END has no live token left -> :completed" fires here.
      assert {:ok, final_state, []} =
               Transition.transition(g, new_state, {:advance_token, "t1"})

      assert final_state.tokens == []
      assert final_state.status == :completed
    end

    test "defensive guard: a token with no waiting child at a :SUB_PROCESS node -> {:token_not_waiting_on_child, ...}" do
      g = graph([node("sp1", :SUB_PROCESS)], [])
      token = %Token{node_id: "sp1", token_id: "t1", waiting_child_instance_id: nil}
      state = instance_state([token])

      assert Transition.transition(g, state, {:sub_process_completed, "t1"}) ==
               {:error, {:token_not_waiting_on_child, :SUB_PROCESS, "sp1"}}
    end

    test "defensive guard: a waiting token whose node is NOT :SUB_PROCESS -> {:token_not_waiting_on_child, ...}" do
      g = graph([node("ht1", :HUMAN_TASK)], [])
      token = %Token{node_id: "ht1", token_id: "t1", waiting_child_instance_id: "child-1"}
      state = instance_state([token])

      assert Transition.transition(g, state, {:sub_process_completed, "t1"}) ==
               {:error, {:token_not_waiting_on_child, :HUMAN_TASK, "ht1"}}
    end

    test "an unknown token_id -> {:unknown_token_id, _}, matching {:complete_task, _}'s own outer dispatch" do
      g = graph([node("sp1", :SUB_PROCESS)], [])
      state = instance_state([%Token{node_id: "sp1", token_id: "t1"}])

      assert Transition.transition(g, state, {:sub_process_completed, "ghost"}) ==
               {:error, {:unknown_token_id, "ghost"}}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- GH-428 regression: waiting_child_instance_id survives an UNRELATED
  # transition that copies tokens for a different reason entirely (a PARALLEL_GATEWAY
  # split on a second, independent token). Design doc §1.1/§5: every dispatch clause
  # that repositions an *existing* token must use struct-update syntax, never a fresh
  # %Token{...} literal that silently drops the field -- this is R-Co's own GH #428 bug
  # class, reintroduced as a Zig-style manual-struct-copy mistake would reintroduce it
  # here too.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- GH-428 regression: an unrelated PARALLEL_GATEWAY split does not drop a sibling token's waiting_child_instance_id" do
    test "token A (parked on SUB_PROCESS, waiting on a child) is byte-for-byte unchanged after token B's split" do
      g =
        graph(
          [
            node("sp1", :SUB_PROCESS),
            node("split", :PARALLEL_GATEWAY),
            node("join", :PARALLEL_GATEWAY)
          ],
          [
            edge("e-split-0", "split", "join"),
            edge("e-split-1", "split", "join")
          ]
        )

      waiting_token = %Token{
        node_id: "sp1",
        token_id: "tA",
        waiting_child_instance_id: "child-99"
      }

      splitting_token = %Token{node_id: "split", token_id: "tB"}

      state = instance_state([waiting_token, splitting_token])

      assert {:ok, new_state, [{:parallel_split, "tB", "split", branch_ids}]} =
               Transition.transition(g, state, {:advance_token, "tB"})

      assert length(branch_ids) == 2

      # tB was consumed by the split (2 fresh branch tokens took its place); tA must
      # still be present, completely unmodified -- same token_id, same node_id, and
      # critically the same waiting_child_instance_id, never silently reset to nil.
      assert waiting_token in new_state.tokens

      refute Enum.any?(new_state.tokens, &(&1.token_id == "tA" and &1 != waiting_token))
    end
  end
end
