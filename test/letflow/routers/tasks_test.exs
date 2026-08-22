defmodule Letflow.Routers.TasksTest do
  @moduledoc """
  Tests for `Letflow.Routers.Tasks`/`Letflow.Tasks` (REQ-083) — the three
  read-path handlers (`GET /tasks`, `GET /tasks/inbox`, `GET /tasks/:id`).
  See `test/specs/REQ-083.md` for the acceptance-criterion -> test-case
  mapping and the rationale for each case (why the case exists, not merely a
  restatement of the criterion it covers).

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) and
  `Letflow.TenantFixture` for real provisioned tenant schemas, matching
  `test/letflow/routers/identity_test.exs`'s own established pattern for
  this class of test — same dispatch mechanism (direct
  `Letflow.Routers.Tasks.call/2`, `conn.assigns[:auth_context]` set directly,
  bypassing `AuthPipeline`), same `insert_*!` fixture-helper shape, same
  cross-tenant-identical-404 idiom, same full-key-set (not
  presence/exclusion-only) assertion discipline for AC5. `async: false` for
  the whole module — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Tasks.init([])

  # ── Shared test dispatch helper (matches identity_test.exs's shape) ────

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Tasks.call(conn, @opts)

  # ── Fixture helpers ──────────────────────────────────────────────────

  # Inserts a full instance_projections -> tokens -> tasks FK chain (the
  # `tasks` table carries mandatory FKs onto both, per
  # priv/repo/migrations/20260818110003_create_tasks.exs) and returns the
  # inserted `Letflow.Engine.Task` row.
  defp insert_task!(tenant, attrs) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: tenant.schema_name)

    token =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: Map.get(attrs, :node_id, "review"),
        branch_id: "b1"
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    default = %{
      instance_id: instance_id,
      token_id: token.id,
      node_id: Map.get(attrs, :node_id, "review"),
      node_name: Map.get(attrs, :node_name, "Review"),
      assignee_type: nil,
      assignee_ref: nil
    }

    %EngineTask{}
    |> EngineTask.insert_changeset(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_user!(tenant, attrs \\ %{}) do
    default = %{
      username: "user-#{Ecto.UUID.generate()}",
      display_name: "A User",
      email: "user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_group!(tenant, attrs) do
    default = %{name: "group-#{Ecto.UUID.generate()}", display_name: "A Group"}

    %Group{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_group_member!(tenant, group_id, user_id) do
    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group_id, user_id: user_id})
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # Direct insert against the tenant-schema-scoped TenantRole table (not
  # RoleRegistry.upsert_role/2, which issues an unprefixed query per the
  # design's rework-1 note) -- binds `role_name` to `group_id`.
  defp insert_role!(tenant, role_name, group_id) do
    %TenantRole{}
    |> Ecto.Changeset.change(%{name: role_name, group_id: group_id})
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp item_ids(body), do: Enum.map(body["items"], & &1["id"])

  @task_list_item_keys [
    "assignee_ref",
    "assignee_type",
    "created_at",
    "id",
    "instance_id",
    "node_id",
    "node_name",
    "status",
    "token_id"
  ]

  @task_detail_keys Enum.sort(@task_list_item_keys ++ ["correlation_key", "updated_at"])

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- end-to-end coverage for all three handlers, list/inbox paginated
  # across >= 2 pages
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: GET /tasks/:id basic end-to-end" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-getbyid")}

    test "returns 200 with the task detail shape", %{tenant: tenant} do
      task = insert_task!(tenant, %{node_id: "n1", node_name: "Node One"})

      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == task.id
      assert body["node_id"] == "n1"
      assert body["status"] == "PENDING"
    end
  end

  describe "AC1: GET /tasks paginates across at least two pages (design §3.1)" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-list-page")}

    test "page_size=1 pages through two tasks with no overlap and no gap", %{tenant: tenant} do
      task_1 = insert_task!(tenant, %{node_id: "n1"})
      task_2 = insert_task!(tenant, %{node_id: "n2"})

      conn_1 =
        build_conn(:get, "/?page_size=1", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn_1.status == 200
      body_1 = Jason.decode!(conn_1.resp_body)
      assert length(body_1["items"]) == 1
      refute is_nil(body_1["next_cursor"])

      conn_2 =
        build_conn(
          :get,
          "/?page_size=1&cursor=#{URI.encode_www_form(body_1["next_cursor"])}",
          tenant,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert conn_2.status == 200
      body_2 = Jason.decode!(conn_2.resp_body)
      assert length(body_2["items"]) == 1
      assert is_nil(body_2["next_cursor"])

      assert Enum.sort(item_ids(body_1) ++ item_ids(body_2)) ==
               Enum.sort([task_1.id, task_2.id])

      assert item_ids(body_1) != item_ids(body_2)
    end
  end

  describe "AC1: GET /tasks/inbox paginates across at least two pages" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-inbox-page")}

    test "an operator's inbox (whole-queue scope) pages through two tasks with no overlap and no gap",
         %{tenant: tenant} do
      task_1 = insert_task!(tenant, %{node_id: "n1"})
      task_2 = insert_task!(tenant, %{node_id: "n2"})

      # PROCESS_OPERATOR is not task-worker-only (Authorization.is_task_worker_only?/1),
      # so the inbox forces :unfiltered scope -- the whole tenant queue, per design §5.3
      # point 2 -- exercising the same cursor mechanism as GET /tasks.
      conn_1 =
        build_conn(:get, "/inbox?page_size=1", tenant, roles: ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn_1.status == 200
      body_1 = Jason.decode!(conn_1.resp_body)
      assert length(body_1["items"]) == 1
      refute is_nil(body_1["next_cursor"])

      conn_2 =
        build_conn(
          :get,
          "/inbox?page_size=1&cursor=#{URI.encode_www_form(body_1["next_cursor"])}",
          tenant,
          roles: ["PROCESS_OPERATOR"]
        )
        |> dispatch()

      assert conn_2.status == 200
      body_2 = Jason.decode!(conn_2.resp_body)
      assert length(body_2["items"]) == 1
      assert is_nil(body_2["next_cursor"])

      assert Enum.sort(item_ids(body_1) ++ item_ids(body_2)) ==
               Enum.sort([task_1.id, task_2.id])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- inbox is per-principal: direct/group/role inclusion, different-
  # user exclusion. Four explicit assertions, not folded into one.
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: GET /tasks/inbox scoping for a task-worker-only caller" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-inbox-scope")}

    test "returns a task assigned directly to X, via a group X belongs to, via a role X holds -- and never a task assigned only to a different user Y",
         %{tenant: tenant} do
      user_x = insert_user!(tenant, %{username: "user-x"}).id
      user_y = insert_user!(tenant, %{username: "user-y"}).id

      group = insert_group!(tenant, name: "reviewers")
      insert_group_member!(tenant, group.id, user_x)
      insert_role!(tenant, "approver", group.id)

      task_direct = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      task_via_group = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id})

      task_via_role =
        insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "approver"})

      task_other_user = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/inbox?page_size=50", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      # Four explicit assertions (AC2's own wording) -- not folded into one.
      assert task_direct.id in returned_ids
      assert task_via_group.id in returned_ids
      assert task_via_role.id in returned_ids
      refute task_other_user.id in returned_ids
    end
  end

  describe "AC2 extra assurance: a role held only in a DIFFERENT tenant does not leak into this tenant's inbox (INV-1 on the reworked resolve_principal_scope/2 path)" do
    test "a role name identical to one X holds in tenant A, but bound to a group in tenant B that X does NOT belong to in A, does not leak a tenant-B-assigned task into X's tenant-A inbox" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req083-role-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req083-role-iso-b")

      user_x = Ecto.UUID.generate()

      # Tenant B: a role named "approver" bound to a group X does NOT belong
      # to in A (this is checking the reworked resolve_principal_scope/2's
      # :prefix-scoped TenantRole query never crosses schemas) -- a task
      # assigned to that role must never surface in X's tenant-A inbox.
      group_b = insert_group!(tenant_b, name: "b-reviewers")
      insert_role!(tenant_b, "approver", group_b.id)
      task_in_b = insert_task!(tenant_b, %{assignee_type: "ROLE", assignee_ref: "approver"})

      # Tenant A: X holds no role at all (no TenantRole row, no group
      # membership) -- only a same-tenant, directly-assigned task exists.
      task_in_a = insert_task!(tenant_a, %{assignee_type: "USER", assignee_ref: user_x})

      conn =
        build_conn(:get, "/inbox?page_size=50", tenant_a,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      assert task_in_a.id in returned_ids
      refute task_in_b.id in returned_ids
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3/INV-5 -- cross-tenant task id == nonexistent id, byte-identical
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3/INV-5: GET /tasks/:id cross-tenant id is indistinguishable from a nonexistent id" do
    test "same status code and same response body" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req083-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req083-cross-b")

      tenant_b_task = insert_task!(tenant_b, %{})

      resp_cross_tenant =
        build_conn(:get, "/#{tenant_b_task.id}", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      resp_never_existed =
        build_conn(:get, "/#{Ecto.UUID.generate()}", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp_cross_tenant.status == 404
      assert resp_cross_tenant.status == resp_never_existed.status
      assert resp_cross_tenant.resp_body == resp_never_existed.resp_body
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4/INV-1 -- tenant isolation on GET /tasks, identically-named nodes
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4/INV-1: GET /tasks tenant isolation with identically-named nodes" do
    test "tenant A caller sees no tenant B task, even though both tenants have a node named the same" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req083-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req083-iso-b")

      task_a =
        insert_task!(tenant_a, %{node_id: "shared_node", node_name: "Shared Node"})

      _task_b =
        insert_task!(tenant_b, %{node_id: "shared_node", node_name: "Shared Node"})

      conn =
        build_conn(:get, "/", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert item_ids(body) == [task_a.id]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5/INV-2 -- explicit field allowlist, full key-set assertion
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5/INV-2: response allowlists" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-allowlist")}

    test "GET /tasks item shape is exactly the nine allowlisted keys", %{tenant: tenant} do
      insert_task!(tenant, %{})

      conn = build_conn(:get, "/", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["items"] != []

      for item <- body["items"] do
        assert Map.keys(item) |> Enum.sort() == @task_list_item_keys
      end
    end

    test "GET /tasks/:id shape is exactly the ten allowlisted keys (no claimed_by, no form_schema, etc.)",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn = build_conn(:get, "/#{task.id}", tenant, roles: ["PLATFORM_ADMIN"]) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.keys(body) |> Enum.sort() == @task_detail_keys
      refute Map.has_key?(body, "claimed_by")
      refute Map.has_key?(body, "form_schema")
      refute Map.has_key?(body, "output_variables")
      refute Map.has_key?(body, "completed_by")
      refute Map.has_key?(body, "completed_at")
      refute Map.has_key?(body, "cancelled_at")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7 -- 403 without TasksRead on all three endpoints
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7: a caller without TasksRead gets 403 on all three endpoints" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-403")}

    test "GET /tasks -> 403 for a caller with no roles at all", %{tenant: tenant} do
      conn = build_conn(:get, "/", tenant, roles: []) |> dispatch()
      assert conn.status == 403
    end

    test "GET /tasks/inbox -> 403 for a caller with no roles at all", %{tenant: tenant} do
      conn = build_conn(:get, "/inbox", tenant, roles: []) |> dispatch()
      assert conn.status == 403
    end

    test "GET /tasks/:id -> 403 for a caller with no roles at all", %{tenant: tenant} do
      task = insert_task!(tenant, %{})
      conn = build_conn(:get, "/#{task.id}", tenant, roles: []) |> dispatch()
      assert conn.status == 403
    end

    # AGENT_RUNNER is a real, recognized role (Authorization.roles_from_strings/1
    # accepts it) that role_allows?/2 grants zero permissions to -- a role that
    # exists but genuinely lacks TasksRead, distinct from "no roles at all".
    test "GET /tasks -> 403 for a caller whose only role lacks TasksRead", %{tenant: tenant} do
      conn = build_conn(:get, "/", tenant, roles: ["AGENT_RUNNER"]) |> dispatch()
      assert conn.status == 403
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Route-match ordering, validation, not-found -- additional coverage
  # ══════════════════════════════════════════════════════════════════════

  describe "route-match ordering: /inbox is not swallowed by /:id" do
    test "GET /tasks/inbox is served as the inbox, not as an invalid-UUID :id lookup" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req083-route-order")

      conn =
        build_conn(:get, "/inbox", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "items")
    end
  end

  describe "validation failures" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-validation")}

    test "GET /tasks?status=bogus is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/?status=bogus", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end

    test "GET /tasks?instance_id=not-a-uuid is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/?instance_id=not-a-uuid", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end

    test "GET /tasks/:id with a malformed id is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/not-a-uuid", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end

    test "GET /tasks?cursor=not-a-valid-cursor!!! is rejected with 422 (this router's own convention, distinct from Identity's 400)",
         %{tenant: tenant} do
      conn =
        build_conn(:get, "/?cursor=not-a-valid-cursor!!!", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 422
    end
  end

  describe "status filter narrows GET /tasks results" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-status-filter")}

    test "status=COMPLETED excludes a PENDING task", %{tenant: tenant} do
      pending_task = insert_task!(tenant, %{})

      conn =
        build_conn(:get, "/?status=COMPLETED", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute pending_task.id in item_ids(body)
    end
  end

  describe "GET /tasks with assignee_id filters an :all-scope caller's results (design §5.2 point 3)" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-assignee-id")}

    test "an operator supplying assignee_id sees only that user's task", %{tenant: tenant} do
      user_x = Ecto.UUID.generate()
      user_y = Ecto.UUID.generate()

      task_x = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      _task_y = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/?assignee_id=#{user_x}", tenant, roles: ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert item_ids(body) == [task_x.id]
    end
  end

  # INV-2 -- a task-worker's row scope can never be widened by a caller-
  # supplied assignee_id, even one naming a different user.
  describe "INV-2: a task-worker-only caller's GET /tasks scope ignores a caller-supplied assignee_id" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-inv2")}

    test "assignee_id naming a different user does not widen a task-worker's own scope",
         %{tenant: tenant} do
      user_x = Ecto.UUID.generate()
      user_y = Ecto.UUID.generate()

      _task_x = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      task_y = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/?assignee_id=#{user_y}", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute task_y.id in item_ids(body)
    end
  end

  describe "GET /tasks/:id 404s for a genuinely nonexistent id (not just cross-tenant)" do
    test "returns 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req083-notfound")

      conn =
        build_conn(:get, "/#{Ecto.UUID.generate()}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 404
    end
  end

  describe "unmatched route returns the RFC 9457 404 problem document" do
    test "an unknown sub-path 404s" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req083-unmatched")

      conn =
        build_conn(:get, "/bogus/nested/path", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 404
    end
  end
end
