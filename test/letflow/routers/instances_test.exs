defmodule Letflow.Routers.InstancesTest do
  @moduledoc """
  Tests for `Letflow.Routers.Instances`'s REQ-079 write routes (create/cancel/
  reconstruct). REQ-078's rebind-pins route is untouched and not retested
  here.

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture`, same
  dispatch mechanism as `test/letflow/routers/tasks_test.exs` (direct
  `Letflow.Routers.Instances.call/2`, `conn.assigns[:auth_context]` set
  directly, bypassing `AuthPipeline`). `async: false` for the whole module --
  tenant provisioning/migration replay needs `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Instances.init([])

  defp build_conn(method, path, tenant, fields) do
    roles = Map.get(fields, :roles, [])
    user_id = Map.get(fields, :user_id, Ecto.UUID.generate())
    body = Map.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @opts)

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

  defp unique_name(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req079-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_instance!(schema_name, overrides \\ %{}) do
    definition = active_definition!(schema_name)

    attrs =
      Map.merge(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique_idempotency_key("start")
        },
        overrides
      )

    assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
    {result.instance_id, definition}
  end

  defp instance_status(schema_name, instance_id) do
    Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status
  end

  defp instance_count(schema_name) do
    Repo.aggregate(InstanceProjection, :count, prefix: schema_name)
  end

  # ── AC1 -- POST /instances creates via Engine, 201 with instance id ───────

  describe "AC1 -- create" do
    test "with definition_id returns 201 with instance_id, row exists" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1a")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"definition_id" => definition.id, "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ACTIVE"
      assert {:ok, _} = Ecto.UUID.cast(body["instance_id"])
      assert Repo.get!(InstanceProjection, body["instance_id"], prefix: tenant.schema_name)
    end

    test "with definition_name returns 201" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1b")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"definition_name" => definition.name, "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 201
    end

    test "neither definition_id nor definition_name is 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1c")

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 422
    end

    test "unresolvable definition_id is 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1d")

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"definition_id" => Ecto.UUID.generate(), "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ── AC2 -- correlation-key uniqueness (INV-8) ──────────────────────────────

  describe "AC2 -- correlation_key uniqueness" do
    test "duplicate correlation_key in the same tenant is 409, not 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac2a")
      definition = active_definition!(tenant.schema_name)
      key = unique_name("corr")

      body = %{
        "definition_id" => definition.id,
        "initial_variables" => %{},
        "correlation_key" => key
      }

      conn1 =
        build_conn("POST", "/", tenant, %{roles: ["PROCESS_OPERATOR"], body: body}) |> dispatch()

      assert conn1.status == 201

      conn2 =
        build_conn("POST", "/", tenant, %{roles: ["PROCESS_OPERATOR"], body: body}) |> dispatch()

      assert conn2.status == 409
    end

    test "the same correlation_key in two different tenants both succeed" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac2b")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac2c")
      definition_a = active_definition!(tenant_a.schema_name)
      definition_b = active_definition!(tenant_b.schema_name)
      key = unique_name("corr-cross-tenant")

      conn_a =
        build_conn("POST", "/", tenant_a, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{
            "definition_id" => definition_a.id,
            "initial_variables" => %{},
            "correlation_key" => key
          }
        })
        |> dispatch()

      conn_b =
        build_conn("POST", "/", tenant_b, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{
            "definition_id" => definition_b.id,
            "initial_variables" => %{},
            "correlation_key" => key
          }
        })
        |> dispatch()

      assert conn_a.status == 201
      assert conn_b.status == 201
    end
  end

  # ── AC3 -- cross-tenant cancel/reconstruct is the SAME 404 as absent ──────

  describe "AC3 -- cross-tenant is the same 404 as nonexistent, state unchanged" do
    test "cancel against another tenant's instance id is 404, target instance unchanged" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3b")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      conn_absent =
        build_conn("POST", "/#{Ecto.UUID.generate()}/cancel", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      conn_cross =
        build_conn("POST", "/#{instance_id}/cancel", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn_absent.status == 404
      assert conn_cross.status == 404
      assert conn_absent.resp_body == conn_cross.resp_body
      assert instance_status(tenant_a.schema_name, instance_id) == :active
    end

    test "reconstruct against another tenant's instance id is 404, target instance unchanged" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3c")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3d")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      conn_absent =
        build_conn("POST", "/#{Ecto.UUID.generate()}/reconstruct", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      conn_cross =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn_absent.status == 404
      assert conn_cross.status == 404
      assert conn_absent.resp_body == conn_cross.resp_body
      assert instance_status(tenant_a.schema_name, instance_id) == :active
    end
  end

  # ── AC4 -- permission denial leaves state unchanged, not just the 403 ─────

  describe "AC4 -- permission gating" do
    test "caller without InstancesStart cannot create, no row inserted" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac4a")
      definition = active_definition!(tenant.schema_name)
      before_count = instance_count(tenant.schema_name)

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["TASK_WORKER"],
          body: %{"definition_id" => definition.id, "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 403
      assert instance_count(tenant.schema_name) == before_count
    end

    test "caller without InstancesCancel cannot cancel, instance state unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac4b")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_DESIGNER"]})
        |> dispatch()

      assert conn.status == 403
      assert instance_status(tenant.schema_name, instance_id) == :active
    end
  end

  # ── AC5 -- no Repo/transition call in this module ──────────────────────────

  describe "AC5 -- structural" do
    test "the router module contains no Repo or Transition call" do
      source = File.read!("lib/letflow/routers/instances.ex")
      refute source =~ ~r/\bRepo\./
      refute source =~ ~r/\bTransition\./
    end
  end

  # ── AC6 -- cancelling a terminal instance ──────────────────────────────────

  describe "AC6 -- cancelling a terminal or error-status instance" do
    test "cancelling an already-CANCELLED instance is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac6a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn1 =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn1.status == 200

      conn2 =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn2.status == 409
    end

    test "cancelling an already-COMPLETED instance is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac6b")
      definition = active_definition!(tenant.schema_name)

      # A graph with no HUMAN_TASK node completes immediately on create.
      immediate_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
      }

      assert {:ok, immediate_def} =
               Definitions.create(
                 %{
                   name: unique_name("req079-immediate"),
                   version: "1.0.0",
                   graph: immediate_graph,
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      assert {:ok, %{definition: activated}} =
               Definitions.activate(immediate_def.id, prefix: tenant.schema_name)

      assert {:ok, result} =
               Engine.create(
                 %{
                   definition_id: activated.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("immediate")
                 },
                 prefix: tenant.schema_name
               )

      assert result.status == :completed
      _ = definition

      conn =
        build_conn("POST", "/#{result.instance_id}/cancel", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 409
    end

    test "cancelling an :error-status instance succeeds (not terminal)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac6c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      projection = Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name)

      projection
      |> InstanceProjection.update_changeset(%{
        status: :error,
        last_event_seq: projection.last_event_seq
      })
      |> Repo.update!(prefix: tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
    end
  end

  # ── Reconstruct (route-level correctness, not separately ACed) ────────────

  describe "reconstruct" do
    test "reconstructing a real instance returns 200 with matching tokens/variables/status" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert body["status"] == "ACTIVE"
      assert [%{"node_id" => "task", "branch_id" => _}] = body["tokens"]
      assert body["variables"] == %{}
    end

    test "reconstructing a nonexistent instance is 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-b")

      conn =
        build_conn("POST", "/#{Ecto.UUID.generate()}/reconstruct", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 404
    end

    test "reconstruct requires no permission (authenticated only)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{roles: []})
        |> dispatch()

      assert conn.status == 200
    end
  end
end
