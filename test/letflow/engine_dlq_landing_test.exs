defmodule Letflow.EngineDlqLandingTest do
  @moduledoc """
  Tests for REQ-177's Hook A (`Letflow.Engine.land_service_task_exhaustion/2`) and the
  AC4 "retry/2 is a landing-only no-op" cross-module interaction with REQ-176's
  `Letflow.Dlq.retry/2`. See `test/specs/REQ-177.md` for the full
  acceptance-criterion -> test-case mapping and rationale.

  Design authority: `lib/letflow/design/req177-dlq-hooks.md` (commit 4070492).
  Implementation authority: `lib/letflow/engine.ex`'s `land_service_task_exhaustion/2`
  and `lib/letflow/engine/execution_error.ex`'s `:execution_error_dlq_landing` Multi
  step (commits fdb096a/8206de9), which already passed SECURITY-REVIEWER and REVIEWER.

  `test/letflow/engine_execution_error_test.exs` already covers Hook B's own AC2/AC3
  (the ERROR-path DLQ landing and its same-transaction atomicity) plus the combining-mark
  truncation regression -- not duplicated here. This file covers what that one does not:
  Hook A's own exhaustion/non-exhaustion split, and AC4's non-effects assertion.

  No `SERVICE_TASK` dispatch orchestrator exists in this codebase yet (design doc §0,
  §2.1) -- `Engine.create/2` cannot even activate a `SERVICE_TASK`-typed node
  (`test/letflow/engine_test.exs`'s own "node type with no dispatch clause yet" case).
  `land_service_task_exhaustion/2`'s own contract does not require the underlying
  instance's graph to contain a real `SERVICE_TASK` node -- it only needs a real,
  `:active` `instance_projections` row to hand to `set_instance_error/2` -- so, exactly
  like `engine_execution_error_test.exs`'s own fixtures, a plain `HUMAN_TASK` graph is
  used to reach that `:active` state; `context.node_id` is a synthetic id naming the
  (not-yet-activatable) SERVICE_TASK node the future orchestrator would have dispatched.

  Uses `Letflow.DataCase` (real Postgres), Sandbox `:auto`, `async: false` -- mirrors
  `engine_execution_error_test.exs`'s own pattern exactly. Self-contained.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req177-dlq-landing",
      display_name: "REQ-177 DLQ Landing Test Tenant"
    )
  end

  defp unique_name(prefix \\ "req177-dlq-landing-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp create_definition_attrs(graph) do
    %{name: unique_name(), version: "1.0.0", graph: graph, created_by: Ecto.UUID.generate()}
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # START -> task(HUMAN_TASK) -> END. Only needed to reach a real, :active
  # instance_projections row -- land_service_task_exhaustion/2 does not itself touch
  # the graph or the "svc" node this test's context.node_id names.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp start_instance!(schema_name) do
    definition = active_definition!(schema_name, graph_human_task_end())

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_idempotency_key("start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  # service_task_dlq_landing_context() (design doc §2.2). last_failure_kind/attempt_index
  # /retry_limit default to a genuine-exhaustion shape (retriable kind, attempt_index ==
  # retry_limit) -- individual tests override to reach the non-exhaustion branch.
  defp exhaustion_context(instance_id, overrides \\ %{}) do
    Map.merge(
      %{
        instance_id: instance_id,
        node_id: "svc",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("dlq-land"),
        variables: %{"seed" => 1},
        last_failure_kind: :timeout,
        attempt_index: 3,
        retry_limit: 3,
        attempted_request: %{
          method: "POST",
          url: "https://example.test/svc",
          body: "{\"foo\":\"bar\"}",
          headers: %{"content-type" => "application/json"}
        }
      },
      overrides
    )
  end

  defp dlq_entries_for(schema_name, instance_id) do
    Dlq.Entry
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- genuine exhaustion (attempt_index == retry_limit, retriable kind) lands
  # exactly one dlq_entries row, read back from the database (not the caller's own
  # return value).
  # ---------------------------------------------------------------------------------

  describe "Hook A -- genuine SERVICE_TASK retry exhaustion lands a DLQ entry" do
    test "attempt_index == retry_limit with a retriable failure kind produces exactly one dlq_entries row" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      context =
        exhaustion_context(instance_id, %{
          last_failure_kind: :timeout,
          attempt_index: 3,
          retry_limit: 3
        })

      assert {:ok, result} = Engine.land_service_task_exhaustion(context, prefix: schema_name)
      assert result.status == :error

      # Read back from the database independently -- not asserted from the caller's
      # own {:ok, result} return value (this handoff's own AC wording).
      assert [entry] = dlq_entries_for(schema_name, instance_id)
      assert entry.entry_type == "event"
      assert entry.instance_id == instance_id
      assert entry.full_reason =~ "timeout"
      assert entry.full_reason =~ "retries exhausted"
      assert entry.retry_limit == 3
      assert entry.status == :pending
      assert entry.first_failed_at != nil
      assert entry.last_failed_at != nil

      # dlq_landed_externally: true was threaded through to set_instance_error/2, so
      # Hook B's own :execution_error_dlq_landing step must NOT have landed a second
      # row for this same transition -- exactly one row total.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
    end

    test "attempt_index above retry_limit (>=, not strictly ==) still counts as exhaustion" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      context =
        exhaustion_context(instance_id, %{
          last_failure_kind: :network,
          attempt_index: 5,
          retry_limit: 3
        })

      assert {:ok, _result} = Engine.land_service_task_exhaustion(context, prefix: schema_name)

      assert [entry] = dlq_entries_for(schema_name, instance_id)
      assert entry.full_reason =~ "network"
    end
  end

  # ---------------------------------------------------------------------------------
  # Non-exhaustion companion -- an immediately-non-retriable failure kind (design doc
  # §3: "not simply decide_failure/3 returned :give_up") must NOT land a DLQ entry via
  # this hook, and must not touch the instance at all -- it is left for Hook B.
  # ---------------------------------------------------------------------------------

  describe "Hook A -- non-exhaustion companion does not land a DLQ entry" do
    test "a non-retriable failure kind returns {:error, :not_exhaustion} and lands nothing" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      context =
        exhaustion_context(instance_id, %{
          last_failure_kind: :http_non_2xx,
          # Even at attempt_index 0 -- an immediately-non-retriable kind gives up on
          # the first attempt regardless of retry_limit (design doc §3).
          attempt_index: 0,
          retry_limit: 3
        })

      assert {:error, :not_exhaustion} =
               Engine.land_service_task_exhaustion(context, prefix: schema_name)

      # Neither Dlq.enqueue/2 nor set_instance_error/2 was called -- read back
      # independently: no DLQ row, instance still :active.
      assert dlq_entries_for(schema_name, instance_id) == []

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end

    test "a retriable kind below retry_limit (not yet exhausted) also lands nothing" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      context =
        exhaustion_context(instance_id, %{
          last_failure_kind: :rate_limited_429,
          attempt_index: 1,
          retry_limit: 3
        })

      assert {:error, :not_exhaustion} =
               Engine.land_service_task_exhaustion(context, prefix: schema_name)

      assert dlq_entries_for(schema_name, instance_id) == []

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- retry/2 is a landing-only no-op beyond the DLQ row itself: it transitions
  # the entry to "retrying" but does NOT re-invoke the original SERVICE_TASK dispatch
  # and does NOT change the instance's own status away from :error. Both non-effects
  # are asserted explicitly, not just the one effect that does happen.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- Dlq.retry/2 against a Hook-A-landed entry is a no-op beyond the entry itself" do
    test "the entry transitions to retrying, but the instance stays :error and no new event is appended" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      context = exhaustion_context(instance_id)

      assert {:ok, _result} = Engine.land_service_task_exhaustion(context, prefix: schema_name)

      assert [entry] = dlq_entries_for(schema_name, instance_id)
      assert entry.status == :pending

      events_before = Letflow.EventStore.Event |> Repo.all(prefix: schema_name) |> length()
      projection_before = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_before.status == :error

      # The one effect that DOES happen: the entry's own status transitions.
      assert {:ok, retried_entry} = Dlq.retry(entry.id, prefix: schema_name)
      assert retried_entry.status == :retrying
      assert retried_entry.retry_count == 1

      # Non-effect 1: the instance's own status does NOT change away from :error --
      # retry/2 has no knowledge of, and never calls, whatever would actually
      # re-dispatch the SERVICE_TASK or resume the instance (design doc §6,
      # Letflow.Dlq's own moduledoc scope boundary).
      projection_after = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_after.status == :error
      assert projection_after.error_detail == projection_before.error_detail

      # Non-effect 2: the original SERVICE_TASK dispatch was NOT re-invoked -- no
      # observable side effect exists for it to have produced (no transport is wired
      # yet, design doc §2.5/§9 OQ-1), so this is checked the only way currently
      # possible: the durable event log gained exactly zero new events, and no second
      # dlq_entries row was landed for this instance -- retry/2 touched only the one
      # row's own columns.
      events_after = Letflow.EventStore.Event |> Repo.all(prefix: schema_name) |> length()
      assert events_after == events_before

      assert [entry_after_retry] = dlq_entries_for(schema_name, instance_id)
      assert entry_after_retry.id == entry.id
    end
  end
end
