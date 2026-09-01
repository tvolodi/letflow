defmodule Letflow.ISS0397JoinCountersTest do
  @moduledoc """
  Regression coverage for ISS-0397 -- durable, always-current `join_counters`
  persistence on `instance_projections`. See
  `lib/letflow/design/iss0397-join-counters-fix.md` (the gate-approved design
  these tests verify against) and `docs/issues/ISS-0397.yaml`.

  Before this fix, `Letflow.Engine.build_instance_state/3` (engine.ex ~1813)
  always hardcoded `join_counters: %{}` regardless of any join cohort a
  previous, already-committed `complete_task/3` call had opened via
  `Transition.dispatch_parallel_split/4` -- so a cross-call
  `:PARALLEL_GATEWAY` join (split committed by one call, join reached by a
  later, separate call) always failed with
  `{:error, {:transition_failed, {:unknown_branch_id, _}}}`. Only a
  same-hop-chain (single-call) join could ever fire. This file locks in the
  fix: §5.1 is the serial two-call happy path (the exact case the hardcoded
  `%{}` broke), §5.2 is a genuine concurrent regression test modeled on
  `engine_cancel_instance_test.exs`'s own AC4 precedent (real `Task.async`/
  `Task.await_many` execution over two separate Postgres connections, not two
  sequential calls dressed up as concurrent).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file. Self-contained: does not share fixtures with
  `engine_test.exs`/`engine_complete_task_test.exs` even though the fixture
  graph below is structurally identical to `engine_test.exs`'s own
  `graph_start_parallel_split_human_tasks/0` (that function is a private
  `defp`, not exported, so it is duplicated here rather than shared, per
  this codebase's established "each test file provisions its own fixtures"
  discipline). `async: false`, matching every tenant-fixture-using file in
  this codebase.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "iss0397-joincounters") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0397 Join Counters Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b) ->
  # PARALLEL_GATEWAY(join) -> END. Identical shape to engine_test.exs's own
  # graph_start_parallel_split_human_tasks/0 (that function is a private defp,
  # duplicated here per this file's own moduledoc).
  defp graph_start_parallel_split_human_tasks do
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
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("iss0397-def"),
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
        idempotency_key: unique_name("iss0397-start")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0397-complete")
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

  defp sole_join_cohort(%InstanceProjection{join_counters: join_counters}) do
    assert map_size(join_counters) == 1
    [{join_node_id, cohort}] = Map.to_list(join_counters)
    {join_node_id, cohort}
  end

  # ---------------------------------------------------------------------------------
  # §5.1 -- serial cross-call happy path (baseline).
  # ---------------------------------------------------------------------------------

  describe "serial cross-call join: complete_task/3 called twice, as two separate top-level invocations" do
    test "the second, separate complete_task/3 call observes the first call's durably-persisted cohort and fires the join" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_parallel_split_human_tasks())

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      # Right after create/2: the split already ran (both branches reached
      # their own HUMAN_TASK within create/2's own single hop-chain), so a
      # join cohort exists and must already be durably persisted --
      # expected_from_branches has both branches, received_from_branches is
      # empty.
      projection_after_create = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_after_create.status == :active
      {join_node_id, cohort_after_create} = sole_join_cohort(projection_after_create)
      assert join_node_id == "join"
      assert length(cohort_after_create["expected_from_branches"]) == 2
      assert cohort_after_create["received_from_branches"] == []

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")
      assert task_a.status == :pending
      assert task_b.status == :pending

      # First, separate call: completes task_a only. The join must NOT fire
      # yet (task_b's branch is still outstanding) -- instance stays :active,
      # and the durably-persisted cohort now shows exactly one branch
      # received, the join node still present (not deleted).
      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      projection_after_a = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_after_a.status == :active
      {^join_node_id, cohort_after_a} = sole_join_cohort(projection_after_a)
      assert length(cohort_after_a["received_from_branches"]) == 1
      assert length(cohort_after_a["expected_from_branches"]) == 2

      # Second, separate call: completes task_b. This is the exact case
      # build_instance_state/3's pre-fix hardcoded `join_counters: %{}`
      # broke -- pre-fix, this call's own seed InstanceState would have an
      # empty join_counters map, dispatch_parallel_join/4's own
      # `with %JoinCounter{} <- Map.get(...)` guard would fail to match, and
      # this call would return
      # `{:error, {:transition_failed, {:unknown_branch_id, _}}}` instead of
      # completing the join. Post-fix, this call reads the exact
      # durably-persisted cohort the first call left behind and the join
      # fires.
      assert {:ok, after_b} =
               Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert after_b.instance_status == :completed
      assert after_b.current_nodes == []

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :completed
      assert final_projection.join_counters == %{}

      final_task_a = Repo.get!(EngineTask, task_a.id, prefix: schema_name)
      final_task_b = Repo.get!(EngineTask, task_b.id, prefix: schema_name)
      assert final_task_a.status == :completed
      assert final_task_b.status == :completed
    end
  end

  # ---------------------------------------------------------------------------------
  # §5.2 -- concurrent sibling-branch completion (the test that actually
  # stresses the locking argument, design doc §3.3).
  # ---------------------------------------------------------------------------------

  describe "concurrent sibling-branch completion: two Task.async complete_task/3 calls racing on the same instance" do
    test "the join fires exactly once regardless of which branch's call observes the M2 lock second" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_parallel_split_human_tasks())

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")

      # Real separate Postgres connections -- provisioned_tenant/0 (via
      # TenantFixture.provisioned_tenant!/1) sets sandbox mode to :auto, not
      # the shared-connection :manual sandbox mode, so these two BEAM
      # processes genuinely race for the same instance_projections FOR
      # UPDATE row rather than being serialized by the test's own sandbox
      # ownership -- mirrors engine_cancel_instance_test.exs's own AC4 and
      # engine_complete_task_test.exs's own AC4.
      task_1 =
        Elixir.Task.async(fn ->
          {:branch_a,
           Engine.complete_task(
             task_a.id,
             complete_attrs(%{idempotency_key: unique_name("iss0397-concurrent-a")}),
             prefix: schema_name
           )}
        end)

      task_2 =
        Elixir.Task.async(fn ->
          {:branch_b,
           Engine.complete_task(
             task_b.id,
             complete_attrs(%{idempotency_key: unique_name("iss0397-concurrent-b")}),
             prefix: schema_name
           )}
        end)

      results = Elixir.Task.await_many([task_1, task_2], 10_000)

      # Non-goal (design doc §5.2 point 4): this test does not assert which
      # of the two calls "wins" the M2 lock race -- only that BOTH calls
      # succeed at the Engine.complete_task/3 level (join-counter races are
      # not task-row conflicts -- each branch owns a distinct task_id, so
      # there is no {:task_not_pending, _} contention here, unlike
      # engine_complete_task_test.exs's own AC4 same-task_id race) and that
      # the OUTCOME is correct regardless of ordering.
      assert [{:branch_a, {:ok, _}}, {:branch_b, {:ok, _}}] =
               Enum.sort_by(results, fn {branch, _} -> branch end)

      statuses = Enum.map(results, fn {_branch, {:ok, r}} -> r.instance_status end)

      # Exactly one of the two calls is the one whose own hop-chain fired the
      # join (instance_status: :completed) -- not both (double-fire, which
      # would be structurally impossible here anyway since only one call can
      # ever observe :completed on a single instance) and not neither (join
      # never fires, e.g. a lost update where the second call overwrites the
      # first's received_from_branches entry instead of merging with it).
      assert Enum.count(statuses, &(&1 == :completed)) == 1
      assert Enum.count(statuses, &(&1 == :active)) == 1

      # Reading instance_projections back once both calls have committed:
      # join_counters contains no entry for the join node (fired and
      # deleted) -- not a corrupted/partial entry from a lost update.
      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :completed
      assert final_projection.join_counters == %{}

      # Reading both tasks rows back: both are :completed -- no lost update
      # dropped one branch's own completion despite the join-counter race.
      final_task_a = Repo.get!(EngineTask, task_a.id, prefix: schema_name)
      final_task_b = Repo.get!(EngineTask, task_b.id, prefix: schema_name)
      assert final_task_a.status == :completed
      assert final_task_b.status == :completed
    end
  end
end
