defmodule Letflow.Engine.ServiceTaskRoutingTest do
  @moduledoc """
  Integration tests for REQ-056's AC5(b), AC6, and AC8: proving
  `Letflow.Engine.ServiceTask.build_service_task_give_up_error_attrs/1` and
  `Letflow.Engine.ServiceTask.build_empty_url_error_attrs/1` actually compose
  with REQ-061's already-shipped `Letflow.Engine.set_instance_error/2` --
  real Postgres, real tenant schema, real instance -- not just a shape
  assertion on the returned map.

  `Letflow.Engine.ServiceTask` itself never calls `set_instance_error/2` (no
  dispatch-orchestration caller exists yet, by design -- design doc §1, §6).
  So these tests build the attrs map with the module's own builder
  functions, then call `Letflow.Engine.set_instance_error/2` directly
  against a real instance fixture, and confirm the instance lands in
  `:error` status with an `EXECUTION_ERROR` event recorded -- reusing the
  exact `provisioned_tenant/0` / `active_definition!/2` / `start_instance!/2`
  fixture pattern from `test/letflow/engine_execution_error_test.exs` (REQ-061's
  own suite). See `test/specs/REQ-056.md` for the full rationale.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors test/letflow/engine_execution_error_test.exs exactly
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req056-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-056 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp register_event_type!(name, tenant_id) do
    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "REQ-056 test fixture -- permissive schema"
               },
               tenant_id
             )

    :ok
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

    :ok = register_event_type!("EXECUTION_ERROR", tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req056-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix \\ "req056-idk") do
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

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  # START -> svc(SERVICE_TASK) -> END -- svc's own endpoint attribute is
  # irrelevant here (this suite never dispatches through it, per this
  # module's own scope boundary, design doc §1); just needs to be a
  # structurally valid, activatable definition to reach a real instance.
  defp graph_service_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => "http://example.invalid/hook"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  defp start_instance!(schema_name, graph) do
    definition = active_definition!(schema_name, graph)
    assert {:ok, result} = Engine.create(start_attrs(definition), prefix: schema_name)
    result.instance_id
  end

  defp execution_error_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR")
    |> Repo.all(prefix: schema_name)
  end

  defp give_up_context(instance_id, overrides \\ %{}) do
    Map.merge(
      %{
        instance_id: instance_id,
        node_id: "svc",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("give-up"),
        variables: %{"seed" => 1},
        last_failure_kind: :invalid_2xx_body,
        attempt_index: 0,
        retry_limit: 3
      },
      overrides
    )
  end

  defp empty_url_context(instance_id, overrides \\ %{}) do
    Map.merge(
      %{
        instance_id: instance_id,
        node_id: "svc",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("empty-url"),
        variables: %{"seed" => 1}
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------------
  # AC5(b) -- 2xx JSON array/bare string does not merge, routes to REQ-061's ERROR path
  # ---------------------------------------------------------------------------------

  describe "AC5(b) -- an invalid 2xx body's give-up verdict routes to set_instance_error/2" do
    test "a JSON array body -> :invalid_2xx_body -> give_up -> instance lands in :error" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_service_task_end())

      # The classification/decision chain AC5(b) requires, exercised for real.
      assert :invalid_2xx_body = ServiceTask.classify_failure_kind({:http, 200, "[1,2,3]"})
      refute ServiceTask.is_retriable_failure(:invalid_2xx_body)
      assert :give_up = ServiceTask.decide_failure(:invalid_2xx_body, 0, 3)

      attrs =
        give_up_context(instance_id, %{last_failure_kind: :invalid_2xx_body, attempt_index: 0})
        |> ServiceTask.build_service_task_give_up_error_attrs()

      assert {:ok, result} = Engine.set_instance_error(attrs, prefix: schema_name)
      assert result.status == :error
      assert result.error_type == :service_task_retries_exhausted

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "service_task_retries_exhausted"

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["error_type"] == "service_task_retries_exhausted"
      # "not retriable" branch of build_service_task_give_up_error_attrs/1's cause_text
      # (design doc §4) -- distinguishes this from AC8's "retries exhausted" case below.
      assert event.payload["reason"] =~ "not retriable"
    end

    test "a bare JSON string body -> :invalid_2xx_body -> give_up -> instance lands in :error" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_service_task_end())

      assert :invalid_2xx_body =
               ServiceTask.classify_failure_kind({:http, 200, ~s("just a string")})

      attrs =
        give_up_context(instance_id, %{last_failure_kind: :invalid_2xx_body, attempt_index: 0})
        |> ServiceTask.build_service_task_give_up_error_attrs()

      assert {:ok, result} = Engine.set_instance_error(attrs, prefix: schema_name)
      assert result.status == :error

      assert Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status == :error
      assert [_event] = execution_error_events(schema_name, instance_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- empty rendered URL rejected at activation, routes to REQ-061's ERROR path
  # ---------------------------------------------------------------------------------

  describe "AC6 -- an empty rendered URL routes to set_instance_error/2 rather than dispatching" do
    test "validate_rendered_url rejects the empty render, and the build attrs land the instance in :error" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_service_task_end())

      assert {:error, :empty_rendered_url} = ServiceTask.validate_rendered_url("")

      attrs =
        instance_id
        |> empty_url_context()
        |> ServiceTask.build_empty_url_error_attrs()

      assert {:ok, result} = Engine.set_instance_error(attrs, prefix: schema_name)
      assert result.status == :error
      assert result.error_type == :service_task_url_rendered_empty

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "service_task_url_rendered_empty"

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["error_type"] == "service_task_url_rendered_empty"
      assert event.payload["reason"] =~ "empty"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- exhausted-retry give-up (distinct scenario from AC5(b)) routes to
  # set_instance_error/2 rather than a bespoke ERROR transition of its own.
  # ---------------------------------------------------------------------------------

  describe "AC8 -- exhausted retries (retriable kind at retry_limit) routes to set_instance_error/2" do
    test "a retriable kind at attempt_index == retry_limit gives up and lands the instance in :error" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_service_task_end())

      # Distinct cause from AC5(b): :timeout IS retriable, but attempt_index has
      # reached retry_limit -- the "exhausted retries" case AC8 names verbatim,
      # not the "immediately non-retriable" case AC5(b) covers.
      assert ServiceTask.is_retriable_failure(:timeout)
      assert :give_up = ServiceTask.decide_failure(:timeout, 3, 3)

      attrs =
        give_up_context(instance_id, %{
          last_failure_kind: :timeout,
          attempt_index: 3,
          retry_limit: 3
        })
        |> ServiceTask.build_service_task_give_up_error_attrs()

      assert {:ok, result} = Engine.set_instance_error(attrs, prefix: schema_name)
      assert result.status == :error
      assert result.error_type == :service_task_retries_exhausted

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["error_type"] == "service_task_retries_exhausted"
      # "retries exhausted after N attempts" branch of cause_text (design doc §4) --
      # distinguishes this from AC5(b)'s "not retriable" reason text above, even
      # though both share the identical error_type atom and the identical sink
      # function (set_instance_error/2) -- design doc §6's routing statement.
      assert event.payload["reason"] =~ "retries exhausted after 3 attempts"

      # Same sink function for both AC5(b) and AC8's give-up causes -- confirms
      # design doc §6: no separate ERROR-transition code path exists per cause.
      assert {:build_service_task_give_up_error_attrs, 1} in ServiceTask.__info__(:functions)
    end
  end
end
