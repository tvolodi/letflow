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

  # ISS-0260 -- AC1's "no global lock" wall-clock proxy multiplier, split by load
  # regime (design doc lib/letflow/design/iss0260-ac1-timing-flake.md §3.1-§3.3).
  # `@ac1_timing_multiplier_default` (30x, unchanged) applies to a plain `mix test`
  # run; `@ac1_timing_multiplier_parallel` (60x) applies only when
  # `TEST_PARALLEL_GROUP` is set (a real `scripts/test_parallel.sh` N-way
  # partition), where real cross-partition Postgres/scheduler contention pushes the
  # ratio higher than in an uncontended run. `TEST_AC1_TIMING_MULTIPLIER`, when set,
  # overrides both unconditionally, mirroring decision 0009's env-knob pattern and
  # `test_parallel.sh`'s own `TEST_MAX_CONNECTIONS` validation style (lines 124-127
  # there): it must be a positive integer or the test fails loudly, naming the bad
  # value, rather than silently falling back to a default.
  @ac1_timing_multiplier_default 30
  @ac1_timing_multiplier_parallel 60

  defp ac1_timing_multiplier do
    case System.get_env("TEST_AC1_TIMING_MULTIPLIER") do
      nil ->
        case System.get_env("TEST_PARALLEL_GROUP") do
          nil -> @ac1_timing_multiplier_default
          _group -> @ac1_timing_multiplier_parallel
        end

      value ->
        if Regex.match?(~r/^[1-9][0-9]*$/, value) do
          String.to_integer(value)
        else
          flunk("TEST_AC1_TIMING_MULTIPLIER='#{value}' is not a positive integer")
        end
    end
  end

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

  defp complete_attrs(overrides \\ %{}) do
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
  # concurrent Task.async calls, all launched before any is awaited. Split out
  # from `provision_and_complete_all!/2` (below) specifically so AC1's timing
  # measurement can wrap ONLY this concurrent span -- not the sequential
  # `start_n_instances!/3` setup that precedes it -- keeping the "no global lock"
  # wall-clock proxy an apples-to-apples comparison against `baseline_micros`
  # (which also times a single bare `complete_task/3` call with zero
  # instance-creation cost).
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

      # Independent baseline: one instance completed alone, measured immediately
      # before the concurrent batch, used as the "no global lock" wall-clock proxy
      # (design §3.4 Case AC1 -- deliberately loose, catches only gross regressions
      # like an accidentally-reintroduced global mutex/singleton serializer).
      [baseline] = start_n_instances!(schema_name, definition, 1)

      {baseline_micros, baseline_result} =
        :timer.tc(fn ->
          Engine.complete_task(baseline.task_id, complete_attrs(), prefix: schema_name)
        end)

      assert {:ok, %{instance_status: :completed}} = baseline_result

      # Setup (sequential -- start_n_instances!/3's own docstring) happens OUTSIDE
      # the timed span: only the concurrent Task.async/Task.await_many completion
      # phase is measured, so concurrent_micros stays comparable to baseline_micros
      # (which also excludes any instance-creation cost).
      instances = start_n_instances!(schema_name, definition, @instance_count)

      {concurrent_micros, results} =
        :timer.tc(fn -> complete_all_concurrently!(schema_name, instances) end)

      for {_instance_id, result} <- results do
        assert {:ok, %{instance_status: :completed}} = result
      end

      for %{instance_id: instance_id} <- instances do
        projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
        assert projection.status == :completed
        assert projection.variables["instance_seed"] == instance_id
      end

      # Loose proxy, not a tight bound (design §3.4/§6 OQ2): genuine per-row locking
      # lets @instance_count completions overlap, so total time stays within a small
      # multiple of one call's own time; a global mutex/table-lock design would push
      # this toward ~@instance_count x instead. The multiplier is load-regime-aware
      # (ISS-0260, lib/letflow/design/iss0260-ac1-timing-flake.md §3) -- 30x under
      # plain `mix test`, 60x under a real `scripts/test_parallel.sh` N-way
      # partition (`TEST_PARALLEL_GROUP` set), or an explicit
      # `TEST_AC1_TIMING_MULTIPLIER` override.
      multiplier = ac1_timing_multiplier()
      ratio = concurrent_micros / baseline_micros

      assert concurrent_micros < baseline_micros * multiplier,
             "AC1 timing ratio #{Float.round(ratio, 2)}x exceeded multiplier #{multiplier}x " <>
               "(TEST_PARALLEL_GROUP #{if System.get_env("TEST_PARALLEL_GROUP"), do: "set", else: "unset"}) " <>
               "-- baseline_micros=#{baseline_micros}, concurrent_micros=#{concurrent_micros}"
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
