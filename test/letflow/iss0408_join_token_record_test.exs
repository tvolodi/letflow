defmodule Letflow.ISS0408JoinTokenRecordTest do
  @moduledoc """
  Regression coverage for ISS-0408 -- `Letflow.Engine.Transition.fire_join/5`
  mints a synthetic, non-UUID `token_id` (`origin_token_id <> "/" <> node.id
  <> "/joined"`) for the token produced when a `PARALLEL_GATEWAY` join fires.
  Before this fix, any hop chain where that join's own outgoing edge led to
  a further dispatch-needing node (e.g. another `:HUMAN_TASK`, not straight
  to `:END`) reached `Letflow.Engine.TaskActivation.append_multi_from_existing_records/6`'s
  `cast_token_record_id/1`, which rejects any non-UUID `token_id` via
  `Ecto.UUID.cast/1` -- `{:error, {:invalid_token_record_id, token_id}}` --
  because no `TokenRecord` row existed yet for the freshly-joined token. See
  `docs/issues/ISS-0408.yaml` and the gate-approved design,
  `lib/letflow/design/iss0408-join-token-record-insert-fix.md`.

  The fix (commits 542f2974..74aba472 on this branch) inserts a real
  `TokenRecord` row for any token that is new *within the current hop chain*
  (present in `final_instance_state.tokens` but absent from
  `original_active_tokens`) before task-activation and reconciliation run,
  at BOTH call sites that build a task-activation/reconciliation `Multi`
  from a pre-existing set of `TokenRecord`s:

    - `Letflow.Engine.build_task_activation_and_reconciliation_multi/4`,
      reached via `complete_task/3`'s own hop-chain tail
      (`build_complete_task_tail_multi/6`) -- §1 below.
    - `Letflow.Engine.persist_timer_fired_advance/6`, reached via
      `advance_after_timer_fired/3` (`Letflow.Scheduler.fire_timer/2` /
      `Letflow.Scheduler.poll_and_fire/1`) -- §2 below.

  Fail-then-pass proof (WF-03 Step 4 / `docs/agents/workflows/WF-03_issue_resolving.md`):
  both describe blocks below were run against the pre-fix commit (751d5806,
  the merge-base immediately before 542f2974) in a throwaway git worktree
  with ONLY this test file added on top, and confirmed to fail with the
  real `{:invalid_token_record_id, _}` error; then run again on this branch
  (post-fix) and confirmed to pass. See this run's own handoff
  (`WF03-ISS0408-20260902`) for the verbatim command output.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false`, matching every other tenant-fixture-using file in this
  codebase. Self-contained: fixtures are duplicated here rather than shared
  with `test/letflow/iss0397_join_counters_test.exs` or
  `test/letflow/engine/timer_wiring_test.exs`, per this codebase's own
  established "each test file provisions its own fixtures" discipline (both
  of those files' own graph helpers are private `defp`, not exported).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0408 Join Token Record Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b) ->
  # PARALLEL_GATEWAY(join) -> HUMAN_TASK(after_join) -> END.
  # Distinguishing feature vs. the already-passing
  # engine_test.exs:graph_start_parallel_split_join_end fixture: the join's
  # own outgoing edge leads to another HUMAN_TASK, not directly to END.
  defp graph_join_then_human_task do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "after_join",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "closer"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "after_join"},
        %{"id" => "e7", "source" => "after_join", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / TIMER(b) ->
  # PARALLEL_GATEWAY(join) -> HUMAN_TASK(after_join) -> END.
  # Same "join leads to a further HUMAN_TASK" shape as
  # graph_join_then_human_task/0 above, but branch b is a :TIMER node (per
  # timer_wiring_test.exs's own graph_parallel_split_task_and_timer/1
  # precedent) so the join-closing branch completion arrives via
  # advance_after_timer_fired/3 (persist_timer_fired_advance/6), not
  # complete_task/3 -- exercises the design's §3.5 call site.
  defp graph_join_then_human_task_via_timer(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "tmr_b",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "after_join",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "closer"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "tmr_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "tmr_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "after_join"},
        %{"id" => "e7", "source" => "after_join", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("iss0408-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0408-start")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0408-complete")
      },
      overrides
    )
  end

  defp task_by_node_id(schema_name, node_id) do
    schema_name
    |> tasks_for()
    |> Enum.find(&(&1.node_id == node_id))
  end

  defp tasks_for(schema_name) do
    Repo.all(EngineTask, prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # §1 -- complete_task/3 call site (build_task_activation_and_reconciliation_multi/4,
  # via build_complete_task_tail_multi/6).
  # ---------------------------------------------------------------------------------

  describe "join -> HUMAN_TASK via complete_task/3 (the main scenario)" do
    test "the second complete_task/3 call fires the join and successfully activates the next HUMAN_TASK" do
      %{schema_name: schema_name} = provisioned_tenant("iss0408-ct")
      definition = active_definition!(schema_name, graph_join_then_human_task())

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")
      assert task_a.status == :pending
      assert task_b.status == :pending

      # First branch: the join does not fire yet (join_outcome/1 :wait) --
      # this call always succeeded, pre-fix and post-fix alike.
      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      # Second branch: this is the hop chain that fires the join and
      # immediately continues to the newly-pending HUMAN_TASK(after_join).
      # Pre-fix: {:error, {:invalid_token_record_id, _}} (or an equivalent
      # wrapped shape) -- the join-merged token's synthetic string id has no
      # backing TokenRecord row yet when TaskActivation.cast_token_record_id/1
      # runs. Post-fix: succeeds.
      result = Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert {:ok, after_b} = result
      assert after_b.instance_status == :active
      assert after_b.current_nodes == ["after_join"]

      # Exactly one new tokens row exists for the join-merged token: real
      # UUID id, parked at after_join, no branch_id (join-merged), :active.
      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "after_join"))
      assert {:ok, _} = Ecto.UUID.cast(joined_record.id)
      assert joined_record.branch_id == nil
      assert joined_record.status == :active

      # Exactly one new tasks row exists for HUMAN_TASK(after_join), whose
      # token_id FK resolves to that same newly-inserted tokens row.
      after_join_task = task_by_node_id(schema_name, "after_join")
      assert after_join_task != nil
      assert after_join_task.status == :pending
      assert after_join_task.token_id == joined_record.id

      # The two original branch tokens are both reconciled to :completed by
      # do_reconcile_token_records/5 (consumed by the join, not carried
      # forward) -- unchanged, pre-existing reconciliation behavior.
      reloaded_task_a_record =
        Enum.find(token_records, &(&1.id == task_a.token_id))

      reloaded_task_b_record =
        Enum.find(token_records, &(&1.id == task_b.token_id))

      assert reloaded_task_a_record.status == :completed
      assert reloaded_task_b_record.status == :completed

      projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # §2 -- persist_timer_fired_advance/6 call site, via
  # advance_after_timer_fired/3 (Scheduler.poll_and_fire/1). Sibling branch
  # b is a :TIMER node whose fire is the event that closes the join.
  # ---------------------------------------------------------------------------------

  describe "join -> HUMAN_TASK via a TIMER-fired closing branch (persist_timer_fired_advance/6)" do
    test "the timer fire closes the join and successfully activates the next HUMAN_TASK" do
      %{schema_name: schema_name} = provisioned_tenant("iss0408-tmr")
      definition = active_definition!(schema_name, graph_join_then_human_task_via_timer("P0D"))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id

      task_a = task_by_node_id(schema_name, "task_a")
      assert task_a.status == :pending

      # First branch: completes the HUMAN_TASK branch. The join has not
      # fired yet (the TIMER branch is still outstanding) -- succeeds both
      # pre-fix and post-fix (matches ISS-0397's own precedent scenario).
      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      # Second branch: the TIMER fires via Scheduler's real poll-and-fire
      # path, re-entering advance_after_timer_fired/3 ->
      # persist_timer_fired_advance/6 -- the hop chain that fires the join
      # and continues to the newly-pending HUMAN_TASK(after_join). Pre-fix:
      # the same {:invalid_token_record_id, _} class of failure as the
      # complete_task/3 call site, at this call site's own TaskActivation
      # call. Post-fix: succeeds, exactly one timer fired.
      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      after_join_task = task_by_node_id(schema_name, "after_join")
      assert after_join_task != nil
      assert after_join_task.status == :pending

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "after_join"))
      assert {:ok, _} = Ecto.UUID.cast(joined_record.id)
      assert joined_record.branch_id == nil
      assert joined_record.status == :active
      assert after_join_task.token_id == joined_record.id

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end
end
