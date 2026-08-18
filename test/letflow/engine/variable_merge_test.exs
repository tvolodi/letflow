defmodule Letflow.Engine.VariableMergeTest do
  @moduledoc """
  Unit tests for `Letflow.Engine.VariableMerge.merge/3` (REQ-049), implementing
  `lib/letflow/design/req049-variable-merge.md` (the gate-approved design this
  module follows). Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency
  anywhere in this file — `async: true` is correct here for the same reason it
  is in `test/letflow/engine/transition_test.exs` (REQ-044): there is no
  shared Postgres sandbox connection for concurrent test processes to contend
  over.

  See `test/specs/REQ-049.md` for the full test design rationale, the AC
  traceability table, and the AC4 (`validate_payload/3` reuse) code-inspection
  evidence — that criterion is structural, not runtime-testable, following the
  `test/letflow/engine/transition_test.exs` AC1/AC5/AC6 precedent.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Engine.{InstanceState, Token, Transition, VariableMerge}
  alias Letflow.EventStore.Registry.ValidationFailure

  # ---------------------------------------------------------------------
  # Fixture builders
  # ---------------------------------------------------------------------

  defp node(id, type), do: %Node{id: id, node_type: type}
  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}
  defp token(node_id, token_id), do: %Token{node_id: node_id, token_id: token_id}

  defp instance_state(tokens, opts) do
    %InstanceState{
      instance_id: Keyword.get(opts, :instance_id, "inst-1"),
      status: Keyword.get(opts, :status, :active),
      tokens: tokens,
      variables: Keyword.get(opts, :variables, %{}),
      pending_task_nodes: Keyword.get(opts, :pending_task_nodes, [])
    }
  end

  # ---------------------------------------------------------------------
  # AC1, first half -- insert of a key absent from the instance map
  # ---------------------------------------------------------------------

  describe "merge/3 -- inserting a key absent from current_variables (acceptance criterion 1, first half)" do
    test "a brand-new key is inserted into new_variables and produces zero events" do
      current = %{"existing" => "unchanged"}
      incoming = %{"brand_new" => "value"}

      assert {:ok, new_variables, events} = VariableMerge.merge(current, incoming, nil)

      assert new_variables == %{"existing" => "unchanged", "brand_new" => "value"}
      assert events == []
    end

    test "inserting several new keys at once still produces zero events" do
      current = %{}
      incoming = %{"a" => 1, "b" => 2, "c" => 3}

      assert {:ok, new_variables, []} = VariableMerge.merge(current, incoming, nil)
      assert new_variables == %{"a" => 1, "b" => 2, "c" => 3}
    end
  end

  # ---------------------------------------------------------------------
  # AC1, second half -- overwrite of a key already present produces exactly
  # one VARIABLE_OVERWRITTEN event carrying key/old/new
  # ---------------------------------------------------------------------

  describe "merge/3 -- overwriting a key already present (acceptance criterion 1, second half)" do
    test "overwrites the value and produces exactly one variable_overwritten event with key, old value, and new value" do
      current = %{"count" => 1}
      incoming = %{"count" => 2}

      assert {:ok, new_variables, events} = VariableMerge.merge(current, incoming, nil)

      assert new_variables == %{"count" => 2}
      assert events == [{:variable_overwritten, "count", 1, 2}]
    end

    test "overwriting two keys at once produces exactly one event per overwritten key, none for inserts" do
      current = %{"x" => "old_x", "y" => "old_y"}
      incoming = %{"x" => "new_x", "y" => "new_y", "z" => "brand_new"}

      assert {:ok, new_variables, events} = VariableMerge.merge(current, incoming, nil)

      assert new_variables == %{"x" => "new_x", "y" => "new_y", "z" => "brand_new"}
      # Sorted-key order (design doc §3.1 step 1/step 4): "x" before "y".
      assert events == [
               {:variable_overwritten, "x", "old_x", "new_x"},
               {:variable_overwritten, "y", "old_y", "new_y"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # AC2 -- empty incoming map is a no-op: zero events, map unchanged (identity)
  # ---------------------------------------------------------------------

  describe "merge/3 -- empty incoming_variables map (acceptance criterion 2)" do
    test "returns the exact same current_variables value unchanged, with zero events" do
      current = %{"already_here" => "value", "another" => 42}

      assert {:ok, new_variables, events} = VariableMerge.merge(current, %{}, nil)

      # Identity, not merely value-equality -- proves no copy divergence and
      # no accidental key was touched (design doc §9).
      assert new_variables == current
      assert events == []
    end

    test "an empty current_variables map merged with an empty incoming map stays empty" do
      assert {:ok, %{}, []} = VariableMerge.merge(%{}, %{}, nil)
    end
  end

  # ---------------------------------------------------------------------
  # AC3 -- a rejected key leaves the variable map unchanged, returns
  # {:rejected, unchanged_variables, [execution_error_event]}
  # ---------------------------------------------------------------------

  describe "merge/3 -- a value a registered variable schema rejects (acceptance criterion 3)" do
    test "rejects the batch, leaves current_variables byte-for-byte unchanged, and produces exactly one execution_error event" do
      current = %{"amount" => 10}
      incoming = %{"amount" => -5}

      failures = [%ValidationFailure{field_path: "/value", constraint: "minimum", actual: -5}]
      validations = %{"amount" => {:rejected, failures}}

      assert {:rejected, unchanged_variables, events} =
               VariableMerge.merge(current, incoming, validations)

      # Verified by reading the variable map back, not merely by return shape
      # (per the requirement text's own verification method).
      assert unchanged_variables == current
      refute Map.get(unchanged_variables, "amount") == -5
      assert Map.get(unchanged_variables, "amount") == 10

      assert events == [
               {:execution_error, "amount", -5, :variable_schema_rejected, failures}
             ]
    end

    test "a variable_validations entry for a new (non-overwrite) key is silently ignored -- new_keys are never looked up" do
      current = %{}
      incoming = %{"new_and_rejected" => "bad_value"}

      failures = [%ValidationFailure{field_path: "/value", constraint: "type", actual: "bad_value"}]
      # "new_and_rejected" is absent from current_variables, so it is a
      # new_keys member -- design doc §3.1 step 3 says new_keys are NEVER
      # looked up in variable_validations, even if an entry happens to exist.
      # A {:rejected, _} entry for this key must therefore have no effect.
      validations = %{"new_and_rejected" => {:rejected, failures}}

      assert {:ok, new_variables, []} = VariableMerge.merge(current, incoming, validations)

      # AC1's insert path is unconditional -- a variable_validations entry for
      # a new_keys member is silently ignored (design doc §3.1 step 3).
      assert new_variables == %{"new_and_rejected" => "bad_value"}
    end
  end

  # ---------------------------------------------------------------------
  # Whole-batch all-or-nothing rejection semantics (REVIEWER-confirmed,
  # design doc §3.2) -- its own explicit test, per the handoff's own demand.
  # ---------------------------------------------------------------------

  describe "merge/3 -- whole-batch all-or-nothing rejection (design doc §3.2, REVIEWER-confirmed)" do
    test "a batch with both a valid new key and a rejected overwrite key: neither lands" do
      current = %{"amount" => 10}
      incoming = %{"amount" => -5, "brand_new_key" => "should_never_land"}

      failures = [%ValidationFailure{field_path: "/value", constraint: "minimum", actual: -5}]
      validations = %{"amount" => {:rejected, failures}}

      assert {:rejected, unchanged_variables, _events} =
               VariableMerge.merge(current, incoming, validations)

      # The whole batch is rejected, not just the offending key -- the
      # otherwise-unproblematic new key insert must NOT have landed either.
      assert unchanged_variables == current
      refute Map.has_key?(unchanged_variables, "brand_new_key")
    end

    test "a batch with both a valid overwrite and a rejected overwrite: the valid one is NOT partially applied" do
      current = %{"amount" => 10, "status" => "pending"}
      incoming = %{"amount" => -5, "status" => "approved"}

      failures = [%ValidationFailure{field_path: "/value", constraint: "minimum", actual: -5}]
      validations = %{"amount" => {:rejected, failures}, "status" => :ok}

      assert {:rejected, unchanged_variables, events} =
               VariableMerge.merge(current, incoming, validations)

      assert unchanged_variables == current
      assert Map.get(unchanged_variables, "status") == "pending"
      # Exactly one execution_error event -- no variable_overwritten event for
      # "status" leaked out of the aborted batch.
      assert [{:execution_error, "amount", -5, :variable_schema_rejected, ^failures}] = events
    end

    test "first-failure-wins ordering (design doc §3.3): the lexicographically smallest rejected key is reported" do
      current = %{"zeta" => 1, "alpha" => 1}
      incoming = %{"zeta" => 2, "alpha" => 2}

      zeta_failures = [%ValidationFailure{field_path: "/value", constraint: "type", actual: 2}]
      alpha_failures = [%ValidationFailure{field_path: "/value", constraint: "minimum", actual: 2}]

      validations = %{
        "zeta" => {:rejected, zeta_failures},
        "alpha" => {:rejected, alpha_failures}
      }

      assert {:rejected, unchanged_variables, events} =
               VariableMerge.merge(current, incoming, validations)

      assert unchanged_variables == current
      # "alpha" sorts before "zeta" -- the scan stops at the first rejection
      # in sorted order (design doc §3.1 step 3), so only alpha's failures
      # are reported, never zeta's.
      assert events == [{:execution_error, "alpha", 2, :variable_schema_rejected, alpha_failures}]
    end
  end

  # ---------------------------------------------------------------------
  # AC2's "(or where no variable schema is registered)" branch -- an absent
  # variable_validations entry, and a nil variable_validations argument, both
  # default to :ok (design doc §3.1 step 3, §2).
  # ---------------------------------------------------------------------

  describe "merge/3 -- absent or nil variable_validations defaults to :ok (design doc §2, §3.1 step 3)" do
    test "an overwrite key with no entry in variable_validations at all is treated as :ok" do
      current = %{"count" => 1}
      incoming = %{"count" => 2}

      assert {:ok, %{"count" => 2}, [{:variable_overwritten, "count", 1, 2}]} =
               VariableMerge.merge(current, incoming, %{"unrelated_key" => {:rejected, []}})
    end

    test "variable_validations: nil is equivalent to variable_validations: %{}" do
      current = %{"count" => 1}
      incoming = %{"count" => 2}

      assert VariableMerge.merge(current, incoming, nil) ==
               VariableMerge.merge(current, incoming, %{})
    end

    test "an explicit :ok outcome for an overwrite key behaves identically to an absent entry" do
      current = %{"count" => 1}
      incoming = %{"count" => 2}

      assert VariableMerge.merge(current, incoming, %{"count" => :ok}) ==
               VariableMerge.merge(current, incoming, nil)
    end
  end

  # ---------------------------------------------------------------------
  # AC5 -- variables merged by a task completion are visible to a gateway
  # condition evaluated later in the same completion (design doc §11). The
  # "merge-then-observe" half is completable now; the full CEL-condition-
  # reads-it assertion awaits REQ-050 (gateway evaluation, currently a stub
  # per REQ-044 §6.4) -- see test/specs/REQ-049.md for the explicit note.
  # ---------------------------------------------------------------------

  describe "merge/3 -- immediate visibility to a later evaluation step in the same completion (acceptance criterion 5)" do
    test "the returned new_variables map, threaded into a fresh InstanceState, is immediately readable with no deferred/async step" do
      current = %{"status" => "pending"}
      incoming = %{"status" => "approved", "amount" => 100}

      assert {:ok, new_variables, _events} = VariableMerge.merge(current, incoming, nil)

      # Compose merge/3's output directly into a second read/evaluation step
      # within the same test (== "the same completion"), no process boundary,
      # no message pass, no persistence round-trip in between.
      composed_state =
        instance_state([token("gw", "t1")], variables: new_variables)

      assert composed_state.variables["status"] == "approved"
      assert composed_state.variables["amount"] == 100
    end

    test "the composed InstanceState carrying the merged variables is itself accepted by Transition.transition/3 in the same call sequence" do
      current = %{"status" => "pending"}
      incoming = %{"status" => "approved"}

      assert {:ok, new_variables, _events} = VariableMerge.merge(current, incoming, nil)

      g = graph([node("gw", :EXCLUSIVE_GATEWAY)], [])
      composed_state = instance_state([token("gw", "t1")], variables: new_variables)

      # Transition.transition/3 (REQ-044) accepts the composed InstanceState
      # and dispatches on it -- proving new_variables threads through the
      # ordinary caller-composition path with no separate fetch or refresh
      # step. EXCLUSIVE_GATEWAY's CEL-condition evaluation is now REQ-050's
      # real dispatch (no longer a stub); this fixture gateway has zero
      # outgoing edges, so dispatch returns {:error, {:no_matching_edge, ...}}
      # with an empty evaluated_conditions list rather than the old stub
      # error -- but the merged value is already present and readable on
      # composed_state, confirmed below, at the exact point the real
      # REQ-050 gateway evaluator reads it from.
      assert Transition.transition(g, composed_state, {:advance_token, "t1"}) ==
               {:error, {:no_matching_edge, "gw", []}}

      assert composed_state.variables["status"] == "approved"
    end
  end
end
