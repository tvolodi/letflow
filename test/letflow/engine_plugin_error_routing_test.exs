defmodule Letflow.EnginePluginErrorRoutingTest do
  @moduledoc """
  The design-doc-§7.1-mandated demonstration for REQ-057's AC1 (full COMPLETE
  -> `VariableMerge.merge/3` path) and AC2/AC8 (full ERROR ->
  `Letflow.Engine.set_instance_error/2` path). See
  `lib/letflow/design/req057-plugin-interface-registry.md` §7.1 for the exact
  7-step sequence this file follows, and `test/specs/REQ-057.md` for the
  full rationale.

  Mirrors `test/letflow/engine_execution_error_test.exs`'s own
  `provisioned_tenant/0` pattern and file-boundary precedent exactly: a real
  Postgres-backed instance via `Letflow.Engine.create/2` (REQ-045), then a
  fixture `PluginInterface` handler invoked through the real, crash-safe
  `invoke/2` (never a mock), then either `VariableMerge.merge/3` (AC1) or
  `build_error_args/3` -> the real `Letflow.Engine.set_instance_error/2`
  (AC2/AC8) -- exactly the sequence design doc §7.1 commits to, closing
  REQ-061's own AC8 obligation that was deferred forward because REQ-057 did
  not exist when REQ-061 was built.

  Deliberately does NOT touch `Letflow.Engine.PluginRegistry` at all --
  §7.1 states explicitly this demonstration needs no registry lookup, no
  live graph-node dispatch wiring (that remains out of scope, §1/§7). Uses
  `Letflow.DataCase`, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------
  # Fixture handlers -- reused from the same design-doc §7.1 step 2 shapes
  # AC3 already covers in plugin_interface_test.exs; this file only needs
  # the COMPLETE and deliberate-ERROR outcomes.
  # ---------------------------------------------------------------------

  defmodule CompleteHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(context), do: {:complete, Map.merge(context.variables, %{"approved" => true})}
  end

  defmodule ErrorHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context),
      do: {:error, "a deliberately deterministic reason string, REQ-057 AC8"}
  end

  # ---------------------------------------------------------------------
  # Fixtures / helpers -- mirrors engine_execution_error_test.exs
  # ---------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req057-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-057 Test Tenant"
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

    # EXECUTION_ERROR is now auto-seeded by replay_migrations/2's default manifest
    # (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- this fixture used to
    # self-register it again against a permissive `%{"type" => "object"}` schema
    # (ISS-0073/GH#267: that duplicate registration now collides with provisioning's
    # own seed and hard-fails). Removed rather than reconciled: every EXECUTION_ERROR
    # payload this file writes goes through the real
    # ExecutionError.append_execution_error_event/2 writer provisioning's stricter
    # schema was written to validate.
    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req057-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

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

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name(),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_instance!(schema_name, graph, initial_variables \\ %{}) do
    definition = active_definition!(schema_name, graph)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: initial_variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_idempotency_key("start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp execution_error_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR")
    |> Repo.all(prefix: schema_name)
  end

  defp execution_context(instance_id, overrides \\ %{}) do
    %ExecutionContext{
      instance_id: instance_id,
      definition_id: Map.get(overrides, :definition_id, Ecto.UUID.generate()),
      node_id: Map.get(overrides, :node_id, "task"),
      node_type: Map.get(overrides, :node_type, "SERVICE_TASK"),
      variables: Map.get(overrides, :variables, %{}),
      node_config: Map.get(overrides, :node_config, %{}),
      trace_id: Map.get(overrides, :trace_id, "trace-req057")
    }
  end

  # ---------------------------------------------------------------------
  # AC1 -- COMPLETE -> VariableMerge.merge/3, design doc §8's exact call
  # shape: output_variables IS merge/3's incoming_variables, no adapter.
  # ---------------------------------------------------------------------

  describe "AC1 -- a handler's COMPLETE outcome merges via REQ-049's VariableMerge.merge/3" do
    test "output variables are merged into the instance's current variable snapshot with no adapter" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end(), %{"seed" => 1})

      ctx = execution_context(instance_id, %{variables: %{"seed" => 1}})

      assert {:complete, output_variables} = PluginInterface.invoke(CompleteHandler, ctx)
      assert output_variables == %{"seed" => 1, "approved" => true}

      # design doc §8's literal call shape -- output_variables IS
      # merge/3's incoming_variables parameter, unchanged.
      assert {:ok, new_variables, _events} =
               VariableMerge.merge(ctx.variables, output_variables, nil)

      assert new_variables == %{"seed" => 1, "approved" => true}
    end
  end

  # ---------------------------------------------------------------------
  # AC2/AC8 -- design doc §7.1's exact 7-step sequence: real create/2
  # instance, fixture handler, invoke/2, build_error_args/3,
  # set_instance_error/2, real read-back.
  # ---------------------------------------------------------------------

  describe "AC2/AC8 -- a handler ERROR outcome routes into REQ-061's set_instance_error/2" do
    test "invoke -> build_error_args -> set_instance_error commits status:error, reason preserved verbatim" do
      %{schema_name: schema_name} = provisioned_tenant()

      # step 1 -- a real, active, persisted instance (Letflow.Engine.create/2).
      instance_id = start_instance!(schema_name, graph_human_task_end(), %{"seed" => 1})
      assert Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status == :active

      # step 2/3 -- fixture handler + a hand-built ExecutionContext pointing
      # at the real instance (node_id/node_type/trace_id are test-fixture
      # literals -- §7.1 states this needs no live graph-node execution).
      ctx =
        execution_context(instance_id, %{
          node_id: "task",
          node_type: "HUMAN_TASK",
          variables: %{"seed" => 1}
        })

      # step 4 -- invoke/2 returns {:error, reason} unchanged.
      assert {:error, reason} = PluginInterface.invoke(ErrorHandler, ctx)
      assert reason == "a deliberately deterministic reason string, REQ-057 AC8"

      # step 5 -- the pure mapper.
      actor_id = Ecto.UUID.generate()
      idempotency_key = unique_idempotency_key("plugin-error")

      error_args =
        PluginInterface.build_error_args(ctx, reason, %{
          actor_id: actor_id,
          idempotency_key: idempotency_key
        })

      assert error_args.error_type == :plugin_error_outcome
      assert error_args.reason == reason

      # step 6 -- a REAL call into the real, already-shipped REQ-061 function.
      assert {:ok, result} = Engine.set_instance_error(error_args, prefix: schema_name)
      assert result.status == :error
      assert result.error_type == :plugin_error_outcome

      # step 7 -- re-fetch and re-read independently, not inferred from the
      # return value alone.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "plugin_error_outcome"

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.event_type == "EXECUTION_ERROR"
      # AC2's own bar: the handler's reason string preserved byte-for-byte.
      assert event.payload["reason"] == reason
    end
  end

  # ---------------------------------------------------------------------
  # AC3 (routing half) -- a raise and an exit both reach set_instance_error/2
  # the same way a deliberate {:error, _} outcome does -- reusing AC3's own
  # outcomes here confirms invoke/2's uniform {:error, _} shape is what
  # actually gets routed, not just asserted in isolation.
  # ---------------------------------------------------------------------

  defmodule RaisingHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context), do: raise("plugin blew up")
  end

  describe "AC3 (routing half) -- a raising handler's crash also reaches set_instance_error/2" do
    test "a raise's ERROR outcome routes into set_instance_error/2 exactly like a deliberate ERROR" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      ctx = execution_context(instance_id)

      assert {:error, reason} = PluginInterface.invoke(RaisingHandler, ctx)
      assert reason =~ "plugin blew up"

      error_args =
        PluginInterface.build_error_args(ctx, reason, %{
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique_idempotency_key("plugin-raise")
        })

      assert {:ok, result} = Engine.set_instance_error(error_args, prefix: schema_name)
      assert result.status == :error

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["reason"] =~ "plugin blew up"
    end
  end
end
