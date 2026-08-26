defmodule Letflow.EngineConcurrencyTest do
  @moduledoc """
  Tests for REQ-055 (EE-12) — concurrent instance isolation guarantees. See
  `test/specs/REQ-055.md` for the full test-case rationale and
  `lib/letflow/design/req-055-concurrent-instance-isolation.md` for the design this
  file implements.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file, and no mocked
  concurrency: every "concurrent" scenario below launches real `Task.async` bodies
  against real, separately-checked-out Postgres connections before awaiting any of
  them.

  `provisioned_tenant/0` below calls `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo,
  :auto)`, exactly matching `test/letflow/engine_complete_task_test.exs`'s own
  fixture -- NOT `Letflow.DataCase`'s own default `{:shared, self()}` sandbox mode.
  Shared mode would route every DB call from every `Task.async` body back through one
  checked-out connection, serializing them at the connection layer regardless of
  Postgres-level row locking, which would defeat AC1/AC4's "genuine cross-instance
  parallelism" requirement and make AC2's "run concurrently, not sequentially"
  requirement untestable (the two `complete_task/3` calls would never actually race
  for the same row lock). `:auto` mode takes real, non-rolled-back commits, so this
  file's `on_exit` does real cleanup (`DROP SCHEMA ... CASCADE`, `Repo.delete_all`),
  matching `engine_complete_task_test.exs`'s own `on_exit` shape verbatim. Self-
  contained: does not share fixtures with `engine_complete_task_test.exs` or
  `engine_test.exs` even though several helpers below are structurally identical to
  theirs, per `docs/guides/test_developer_guide.md` DIRECTIVE T-4 ("no test
  pollution" / each test file provisions its own tenant schema) and this design
  doc's own §5 note.

  ## AC5 -- not applicable, stated explicitly (design doc §1, §2.6, §3.4 Case AC5)

  REQ-045 resolved the S3 running-instance shape to a plain transactional context
  module (`Letflow.Engine.create/2`), not a supervised `:gen_statem`/
  `DynamicSupervisor`-per-instance process -- confirmed directly from
  `lib/letflow/engine.ex`'s own moduledoc ("Process-vs-row decision (AC5, AC6)"
  section) and `lib/letflow/instance_supervisor.ex`'s own moduledoc ("Currently
  supervises no children... nothing for this supervisor to own yet"). There is
  therefore no per-instance process for AC5's "kill one instance's process, assert a
  sibling instance's state is untouched" scenario to exercise, and no test case for
  AC5 exists in this file. Isolation for row-based state rests instead on row-level
  locking discipline (documented in `lib/letflow/engine.ex`'s own `## EE-12
  (REQ-055)` moduledoc section, AC3's deliverable) and schema-level scoping
  (`instance_id`/`token_id`/`task_id` foreign keys, tenant-schema-per-tenant
  `prefix`) -- exactly what the AC1/AC2/AC4 test cases below exercise under real
  concurrent load. See design doc §1/§2.6 for the full finding this statement is
  based on.
  """

  use Letflow.DataCase, async: false

  # ISS-0297: pool_size >= @instance_count (100) is required; impossible at N >= 2 on standard 100-max_connections Postgres.
  @moduletag :high_pool_demand

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @instance_count 100

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- copied (same signatures/bodies) from
  # engine_complete_task_test.exs per design §3.2, this file provisions its own
  # tenant schema independently.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req055"),
        display_name: "REQ-055 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    # TASK_COMPLETED is now auto-seeded by replay_migrations/2's default manifest
    # (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- this fixture used to
    # self-register it again against a permissive `%{"type" => "object"}` schema
    # (ISS-0073/GH#267: that duplicate registration now collides with provisioning's
    # own seed and hard-fails). Removed rather than reconciled: every payload this
    # file writes goes through the real Engine.complete_task/3 writer provisioning's
    # stricter schema was written to validate.
    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req055-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK) -> END. The plainest graph shape; sufficient for
  # every test case in this file, none of which needs gateway/parallel-split
  # structure.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name(),
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
        initial_variables: %{"seed" => "value"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  defp start_instance_with_pending_task!(schema_name, graph) do
    definition = active_definition!(schema_name, graph)

    assert {:ok, result} = Engine.create(start_attrs(definition), prefix: schema_name)

    [task] = Repo.all(EngineTask, prefix: schema_name)
    assert task.status == :pending

    {result.instance_id, task}
  end

  defp complete_attrs(overrides) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("complete")
      },
      overrides
    )
  end

  defp task_completed_events(schema_name, instance_id) do
    Letflow.EventStore.Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "TASK_COMPLETED")
    |> Repo.all(prefix: schema_name)
  end

  # New concurrency-specific fixture (design §3.3) -- starts `n` instances against
  # the same already-activated `definition`, sequentially (the concurrency under
  # test is the subsequent task-completion step, not this setup), and returns each
  # instance's own {instance_id, task_id} pair.
  defp start_n_instances!(schema_name, definition, n) when is_integer(n) and n > 0 do
    for _ <- 1..n do
      assert {:ok, result} =
               Engine.create(start_attrs(definition), prefix: schema_name)

      [task] =
        EngineTask
        |> Repo.all(prefix: schema_name)
        |> Enum.filter(&(&1.instance_id == result.instance_id))

      %{instance_id: result.instance_id, task_id: task.id}
    end
  end

  # Completes every {instance_id, task_id} pair in `instances` via genuinely
  # concurrent Task.async calls, all launched before any is awaited.
  defp complete_all_concurrently!(schema_name, instances) do
    tasks =
      Enum.map(instances, fn %{instance_id: instance_id, task_id: task_id} ->
        Task.async(fn ->
          {instance_id,
           Engine.complete_task(
             task_id,
             complete_attrs(%{output_variables: %{"instance_seed" => instance_id}}),
             prefix: schema_name
           )}
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  # ISS-0291 -- same as complete_all_concurrently!/2 but each task also records its
  # own [start, end] wall-clock window (monotonic_time, native units), returned
  # alongside the completion result. Used only by AC1, which needs per-task
  # overlap evidence rather than a batch-total timing ratio -- see
  # max_overlap_depth/1 below for why this replaced the old baseline-ratio
  # assertion (it flaked 3 times: ISS-0260, then twice more on GitHub Actions CI
  # even after two threshold widenings, per ISS-0291's diagnosis).
  defp complete_all_concurrently_with_windows!(schema_name, instances) do
    tasks =
      Enum.map(instances, fn %{instance_id: instance_id, task_id: task_id} ->
        Task.async(fn ->
          start_at = System.monotonic_time()

          result =
            Engine.complete_task(
              task_id,
              complete_attrs(%{output_variables: %{"instance_seed" => instance_id}}),
              prefix: schema_name
            )

          end_at = System.monotonic_time()
          {instance_id, result, start_at, end_at}
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  # ISS-0291 -- classic interval-sweep max-overlap-depth: given a list of
  # {start, end} windows (any monotonic unit), returns the maximum number of
  # windows simultaneously "in flight" at any point in time. A start event
  # increments depth, an end event decrements it; events at the same instant
  # sort starts before ends so two back-to-back-but-non-overlapping windows
  # never register a false depth-2 moment. depth > 1 is direct, timing-value-
  # independent evidence that at least two completions genuinely overlapped in
  # wall-clock time -- true regardless of how fast or slow (or how noisy) the
  # host executing the test is, unlike a ratio against a single baseline
  # measurement.
  defp max_overlap_depth(windows) do
    windows
    |> Enum.flat_map(fn {start_at, end_at} -> [{start_at, :start}, {end_at, :end}] end)
    |> Enum.sort_by(fn {at, kind} -> {at, if(kind == :end, do: 0, else: 1)} end)
    |> Enum.reduce({0, 0}, fn
      {_at, :start}, {depth, max_depth} -> {depth + 1, max(depth + 1, max_depth)}
      {_at, :end}, {depth, max_depth} -> {depth - 1, max_depth}
    end)
    |> elem(1)
  end

  # Shared by Case AC1 and Case AC4 -- provisions a tenant, starts @instance_count
  # instances, and completes all of their pending tasks concurrently. Returns the
  # instance list and results so AC4 can reconstruct each instance afterward. AC1
  # does not call this directly (it needs to time only the completion phase); it
  # calls `start_n_instances!/3` and `complete_all_concurrently!/2` separately
  # instead, see below.
  defp provision_and_complete_all!(schema_name, definition) do
    instances = start_n_instances!(schema_name, definition, @instance_count)
    results = complete_all_concurrently!(schema_name, instances)

    {instances, results}
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- 100 concurrent task completions across 100 distinct instances: no
  # deadlock/corruption, real Postgres, real cross-instance overlap.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- 100 concurrent task completions across 100 distinct instances" do
    test "every completion succeeds, no cross-instance corruption, no global serialization" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_end())

      # Setup (sequential -- start_n_instances!/3's own docstring) happens before
      # the timed span.
      instances = start_n_instances!(schema_name, definition, @instance_count)

      windowed_results = complete_all_concurrently_with_windows!(schema_name, instances)

      for {_instance_id, result, _start_at, _end_at} <- windowed_results do
        assert {:ok, %{instance_status: :completed}} = result
      end

      for %{instance_id: instance_id} <- instances do
        projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
        assert projection.status == :completed
        assert projection.variables["instance_seed"] == instance_id
      end

      # ISS-0291 -- direct overlap evidence, not a wall-clock ratio against a
      # single baseline measurement (design §3.4/§6 OQ2's original approach,
      # which flaked three times: ISS-0260, then twice more on GitHub Actions CI
      # even after two threshold widenings -- shared-runner CPU contention has
      # an effectively unbounded noise tail, so no fixed multiplier is safe).
      # `max_overlap_depth/1` sweeps every completion's own [start, end] window
      # and finds how many were simultaneously in flight at any instant. Depth 1
      # would mean every completion ran strictly after the previous one finished
      # -- exactly what a global mutex/table-lock serializer would produce,
      # regardless of host speed. Depth > 1 is the same property the old ratio
      # was a noisy proxy for, verified directly and with zero sensitivity to
      # how fast or how contended the machine running this test is.
      windows =
        Enum.map(windowed_results, fn {_id, _result, start_at, end_at} -> {start_at, end_at} end)

      depth = max_overlap_depth(windows)

      assert depth > 1,
             "AC1 expected genuine concurrent overlap (max_overlap_depth > 1) across " <>
               "#{@instance_count} completions, got max depth #{depth} -- every completion " <>
               "ran strictly sequentially, consistent with an accidentally-reintroduced " <>
               "global lock/serializer"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- two concurrent task completions on the SAME instance: exactly one
  # success, one conflict, launched concurrently not sequentially.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- two concurrent task completions on the SAME instance" do
    test "exactly one commits :completed, the other observes {:task_not_pending, :completed}" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task} =
        start_instance_with_pending_task!(schema_name, graph_human_task_end())

      task_1 =
        Task.async(fn ->
          Engine.complete_task(
            task.id,
            complete_attrs(%{idempotency_key: unique_idempotency_key("ac2-1")}),
            prefix: schema_name
          )
        end)

      task_2 =
        Task.async(fn ->
          Engine.complete_task(
            task.id,
            complete_attrs(%{idempotency_key: unique_idempotency_key("ac2-2")}),
            prefix: schema_name
          )
        end)

      results = Task.await_many([task_1, task_2], 5_000)

      successes = Enum.filter(results, &match?({:ok, %{instance_status: :completed}}, &1))

      conflicts =
        Enum.filter(results, &match?({:error, {:task_not_pending, :completed}}, &1))

      assert length(successes) == 1
      assert length(conflicts) == 1
      assert length(results) == 2

      final_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert final_task.status == :completed

      assert [_one_event] = task_completed_events(schema_name, instance_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- after the concurrent AC1 run, every one of the @instance_count instances
  # reconstructs (from its own event log, REQ-053) to a state matching its own live
  # projection.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- reconstruction matches projection for all instances after the concurrent run" do
    test "each instance's reconstructed status/variables/token positions match its own projection" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_end())

      {instances, results} = provision_and_complete_all!(schema_name, definition)

      for {_instance_id, result} <- results do
        assert {:ok, %{instance_status: :completed}} = result
      end

      for %{instance_id: instance_id} <- instances do
        projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

        assert {:ok, %{instance_state: instance_state}} =
                 Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

        assert instance_state.status == projection.status
        assert instance_state.variables == projection.variables

        reconstructed_nodes = instance_state.tokens |> Enum.map(& &1.node_id) |> Enum.sort()
        assert reconstructed_nodes == Enum.sort(projection.current_nodes)
      end
    end
  end
end
