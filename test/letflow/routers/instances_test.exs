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

    # REQ-131 closed this route's previously-wholly-open authorization gap
    # (see this file's own moduledoc/lib/letflow/routers/instances.ex's
    # "Authorization gap" comment on the route declaration) -- it now
    # requires :InstancesCancel, the same permission POST /:id/cancel
    # already requires, reusing an existing endpoint_policy_key() atom
    # directly (not via Authorization.endpoint_policy_key/2, which has no
    # clause for this path -- see test/letflow/api/authorization_enforcement_test.exs's
    # allowlist). This supersedes this test's own former, now-stale name
    # and 200 assertion for a no-roles caller.
    test "reconstruct requires :InstancesCancel -- a caller with no roles is denied 403" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{roles: []})
        |> dispatch()

      assert conn.status == 403
    end

    test "reconstruct requires :InstancesCancel -- TASK_WORKER (holds neither InstancesCancel-granting role) is denied 403" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-d")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{roles: ["TASK_WORKER"]})
        |> dispatch()

      assert conn.status == 403
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-080 -- read routes (get_by_id/list/history/timeline/pins)
  # ══════════════════════════════════════════════════════════════════════

  # ── AC1 -- each of the five handlers, end-to-end ───────────────────────

  describe "AC1 -- five read endpoints" do
    test "GET /:id returns the instance shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1a")
      {instance_id, definition} = start_instance!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{instance_id}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert body["definition_id"] == definition.id
      assert body["status"] == "ACTIVE"
      assert is_map(body["variables"])
      assert is_binary(body["started_at"])
    end

    test "GET / returns a page envelope" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1b")
      {_instance_id, _def} = start_instance!(tenant.schema_name)

      conn = build_conn("GET", "/", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["items"])
      assert body["count"] == length(body["items"])
      assert Map.has_key?(body, "next_cursor")
    end

    test "GET /:id/history returns the INSTANCE_STARTED event" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{instance_id}/history", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert [%{"event_type" => "INSTANCE_STARTED"} | _] = body["items"]
    end

    test "GET /:id/timeline returns a lighter per-event projection" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1d")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{instance_id}/timeline", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert [%{"event_type" => "INSTANCE_STARTED", "sequence_number" => _} = item | _] =
               body["items"]

      refute Map.has_key?(item, "actor_display_name")
    end

    test "GET /:id/pins returns the effective pin set" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1e")
      {instance_id, definition} = start_instance!(tenant.schema_name)
      definition_name = definition.name

      conn =
        build_conn("GET", "/#{instance_id}/pins", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id

      assert [%{"kind" => "variable_schema", "ref" => ^definition_name, "source" => "resolved"}] =
               body["pins"]
    end
  end

  # ── AC2 -- pagination completeness (list/history/timeline) ─────────────

  describe "AC2 -- pagination completeness" do
    test "list: every row exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac2a")
      ids = for _ <- 1..5, do: elem(start_instance!(tenant.schema_name), 0)

      {page1, cursor1} = fetch_list_page(tenant, "?page_size=2")
      {page2, cursor2} = fetch_list_page(tenant, "?page_size=2&cursor=#{cursor1}")
      {page3, cursor3} = fetch_list_page(tenant, "?page_size=2&cursor=#{cursor2}")

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1
      assert cursor3 == nil

      seen = Enum.map(page1 ++ page2 ++ page3, & &1["instance_id"])
      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(Enum.uniq(seen)) == length(seen)
    end

    test "history: every event exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac2b")
      {instance_id, _def} = start_instance!(tenant.schema_name)
      cancel_instance!(tenant.schema_name, instance_id)

      all_seqs = fetch_all_history_seqs(tenant, instance_id, 1)

      # At least INSTANCE_STARTED + INSTANCE_CANCELLED -- walked one page at
      # a time (page_size=1) so every page boundary is exercised.
      assert length(all_seqs) >= 2
      assert length(Enum.uniq(all_seqs)) == length(all_seqs)
      assert all_seqs == Enum.sort(all_seqs)
    end

    test "timeline: every event exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac2c")
      {instance_id, _def} = start_instance!(tenant.schema_name)
      cancel_instance!(tenant.schema_name, instance_id)

      all_seqs = fetch_all_timeline_seqs(tenant, instance_id, 1)

      assert length(all_seqs) >= 2
      assert length(Enum.uniq(all_seqs)) == length(all_seqs)
      assert all_seqs == Enum.sort(all_seqs)
    end
  end

  # ── AC3 -- cross-tenant is the same response as nonexistent (INV-5) ────

  describe "AC3 -- cross-tenant is the same as nonexistent" do
    test "get: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3a1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3a2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "history: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3b1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3b2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}/history", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/history", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "timeline: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3c1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3c2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}/timeline", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/timeline", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "pins: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3d1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3d2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}/pins", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/pins", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end
  end

  # ── AC4 -- list filter returns only the calling tenant's rows (INV-1) ──

  describe "AC4 -- tenant isolation on filters" do
    test "same correlation_key value seeded in two tenants: each list sees only its own" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac4a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac4b")
      key = unique_name("shared-corr")

      {id_a, _} = start_instance!(tenant_a.schema_name, %{correlation_key: key})
      {id_b, _} = start_instance!(tenant_b.schema_name, %{correlation_key: key})

      {items_a, _} = fetch_list_page(tenant_a, "?correlation_key=#{key}")
      {items_b, _} = fetch_list_page(tenant_b, "?correlation_key=#{key}")

      assert Enum.map(items_a, & &1["instance_id"]) == [id_a]
      assert Enum.map(items_b, & &1["instance_id"]) == [id_b]
    end
  end

  # ── AC5 -- SQL-metacharacter filter is inert (INV-7) ────────────────────

  describe "AC5 -- filter values are literal, not SQL" do
    test "a correlation_key filter containing SQL metacharacters matches zero rows, no crash" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac5a")
      {_instance_id, _def} = start_instance!(tenant.schema_name)

      malicious = URI.encode_www_form("'; DROP TABLE instance_projections; --")

      conn =
        build_conn("GET", "/?correlation_key=#{malicious}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["items"] == []
      # table still present -- a second, ordinary list still works
      assert instance_count(tenant.schema_name) == 1
    end

    test "no raw SQL fragment is used anywhere in this requirement's code" do
      refute File.read!("lib/letflow/instances.ex") =~ "fragment("
      refute File.read!("lib/letflow/routers/instances.ex") =~ "fragment("
    end
  end

  # ── AC6 -- 403 without InstancesRead, on all five endpoints ─────────────

  describe "AC6 -- permission required on every read endpoint" do
    test "AGENT_RUNNER (no InstancesRead) gets 403 on all five" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac6a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      for path <- [
            "/",
            "/#{instance_id}",
            "/#{instance_id}/history",
            "/#{instance_id}/timeline",
            "/#{instance_id}/pins"
          ] do
        conn = build_conn("GET", path, tenant, %{roles: ["AGENT_RUNNER"]}) |> dispatch()
        assert conn.status == 403, "expected 403 for #{path}, got #{conn.status}"
      end
    end
  end

  # ── REQ-080 test helpers ─────────────────────────────────────────────

  defp cancel_instance!(schema_name, instance_id) do
    assert {:ok, _} =
             Engine.cancel_instance(
               instance_id,
               %{
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_idempotency_key("cancel")
               },
               prefix: schema_name
             )
  end

  defp fetch_list_page(tenant, query_suffix) do
    conn =
      build_conn("GET", "/#{query_suffix}", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    {body["items"], body["next_cursor"]}
  end

  defp fetch_all_history_seqs(tenant, instance_id, page_size),
    do: fetch_all_seqs(tenant, "/#{instance_id}/history", page_size)

  defp fetch_all_timeline_seqs(tenant, instance_id, page_size),
    do: fetch_all_seqs(tenant, "/#{instance_id}/timeline", page_size)

  defp fetch_all_seqs(tenant, path, page_size),
    do: fetch_all_seqs(tenant, path, page_size, nil, [])

  defp fetch_all_seqs(tenant, path, page_size, cursor, acc) do
    query = "?page_size=#{page_size}" <> if cursor, do: "&cursor=#{cursor}", else: ""

    conn = build_conn("GET", path <> query, tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    seqs = Enum.map(body["items"], & &1["sequence_number"])
    acc = acc ++ seqs

    case body["next_cursor"] do
      nil -> acc
      next -> fetch_all_seqs(tenant, path, page_size, next, acc)
    end
  end
end
