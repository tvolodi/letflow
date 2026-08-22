defmodule Letflow.Routers.Req078SupportingRoutesTest do
  @moduledoc """
  Tests for REQ-078 (`lib/letflow/design/req078-supporting-routes.md`) — the six
  supporting route modules: audit, definition validation, tenant config, solution
  packs (export/install), pin rebind, metrics. See `test/specs/REQ-078.md` for the
  full acceptance-criterion-to-test-case rationale.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas.
  `async: false` — mirrors `test/letflow/routers/tenants_test.exs`'s own established
  reasoning (tenant provisioning/migration replay needs `Sandbox.mode(Letflow.Repo,
  :auto)`).

  ## Dispatch strategy (AC1)

  `GET /api/tenant-config` is dispatched through `Letflow.Router` itself, because the
  property under test is specifically that it is reachable with no `Authorization`
  header — only the top-level router can prove that (design §2.4). The other five
  modules are dispatched directly against their own `Plug.Router` sub-module with
  `conn.assigns[:auth_context]` set by hand, exactly the convention
  `test/letflow/routers/tenants_test.exs`/`identity_test.exs` already establish and
  document: each handler under test reads `conn.assigns.auth_context` directly, so
  nothing here depends on how that assign got populated, and every request still goes
  through real `Plug.Router` match/dispatch and a real backing context function
  against real Postgres. `AuthPipeline`'s own bearer-token handling is REQ-021's
  coverage, not this file's.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Engine
  alias Letflow.Engine.VariableSchema
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry
  alias Letflow.TenantFixture

  @tenant_opts Letflow.Router.init([])
  @audit_opts Letflow.Routers.Audit.init([])
  @definitions_opts Letflow.Routers.Definitions.init([])
  @instances_opts Letflow.Routers.Instances.init([])
  @solution_packs_opts Letflow.Routers.SolutionPacks.init([])
  @metrics_opts Letflow.Routers.Metrics.init([])

  @pack_schema_version "bpm/definition/v1"

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp build_conn(method, path, tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["PLATFORM_ADMIN"])
    body = Keyword.get(fields, :body, nil)
    headers = Keyword.get(fields, :headers, [])

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant_fixture.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req078-test-trace-id")
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> HUMAN_TASK -> END: the instance stays :active with one open task
  # (unlike graph_start_end/0, which completes synchronously inside
  # Engine.create/2) -- required by any fixture that needs to rebind pins
  # against a still-live instance. Mirrors
  # test/letflow/engine/pin_rebind_test.exs's own graph_start_human_task_end/0.
  defp graph_start_human_task_end do
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

  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # Structurally invalid: a START node with no END node anywhere -- triggers
  # Graph.validate_graph/1's :missing_end_node violation. Definitions.create/2
  # would reject this before writing (INV-DS-3), so it is seeded directly via
  # the changeset, bypassing create/2 entirely -- the same direct-seeding idiom
  # test/letflow/event_store_test.exs already establishes for this reason.
  defp graph_missing_end do
    %{
      "nodes" => [%{"id" => "start", "node_type" => "START"}],
      "edges" => []
    }
  end

  defp create_definition_attrs(graph, overrides \\ %{}) do
    Map.merge(
      %{
        name: unique("req078-def"),
        version: "1.0.0",
        graph: graph,
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp active_definition!(schema_name, graph \\ nil) do
    graph = graph || graph_start_end()

    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # Direct-seed idiom (bypasses Definitions.create/2's mandatory graph-validity
  # pre-check, deliberately, to get a stored INVALID graph for AC4/T-12b).
  defp seed_definition_with_graph!(schema_name, graph) do
    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(create_definition_attrs(graph))
    |> Repo.insert!(prefix: schema_name)
  end

  defp unique_type_name(prefix \\ "REQ078EVT"), do: unique(prefix)
  defp unique_idempotency_key(prefix \\ "REQ078IDK"), do: unique(prefix)

  defp register_event_type!(tenant_id, json_schema \\ %{"type" => "object"}) do
    name = unique_type_name()

    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => json_schema,
                 "description" => "REQ-078 test fixture"
               },
               tenant_id
             )

    name
  end

  defp seed_projection!(schema_name, instance_id, status \\ :active) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: status,
      last_event_seq: 0,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # rebind_pins/3 requires a REAL started instance (an instance_sequence row,
  # not just an instance_projections row) -- ensure_instance_started's own
  # existence check, the same one Letflow.EventStore.read/2 uses. Mirrors
  # test/letflow/engine/pin_rebind_test.exs's own start_instance!/3 exactly, so
  # the instance carries a real :variable_schema pin that rebind_pins/3 can
  # actually change.
  defp start_instance!(schema_name, definition) do
    pin_lookup = %Engine.PinResolver.Lookup{
      catalog_lookup: fn _ref -> {:error, :not_found} end,
      module_lookup: fn _ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        {:ok, %{version: "v1", json_schema: nil}}
      end
    }

    attrs = %{
      definition_id: definition.id,
      initial_variables: %{},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key("req078-start"),
      pin_lookup: pin_lookup,
      pin_overrides: [%{kind: :variable_schema, ref: definition.name, version: "v1"}]
    }

    assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
    result
  end

  # Registered AFTER the tenant fixture's own on_exit (in creation order
  # inside a test body), so ExUnit's LIFO on_exit ordering runs this FIRST --
  # deleting the global solution_pack_installs row before TenantFixture's own
  # teardown tries to delete the tenants row it references
  # (solution_pack_installs_tenant_id_fkey). Needed because
  # solution_pack_installs is a REQ-041 global table TenantFixture has no
  # knowledge of.
  defp cleanup_solution_pack_installs!(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
    end)
  end

  defp append_event!(schema_name, event_type, instance_id, actor_id \\ nil) do
    attrs = %{
      instance_id: instance_id,
      event_type: event_type,
      payload: Jason.encode!(%{}),
      actor_id: actor_id || Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key()
    }

    assert {:ok, %{event: event}} = EventStore.append(attrs, prefix: schema_name)
    event
  end

  defp pack_document(definitions, variable_schemas \\ []) do
    %{
      "pack_id" => Ecto.UUID.generate(),
      "version" => "1.0.0",
      "bpm_export_schema_version" => @pack_schema_version,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "definitions" => definitions,
      "service_catalog_entries" => [],
      "variable_schemas" => variable_schemas,
      "manifest" => %{"required_roles" => []}
    }
  end

  defp packed_definition_json(source_id, process_key, graph \\ nil) do
    %{
      "definition_id" => source_id,
      "process_key" => process_key,
      "name" => process_key,
      "version" => "1.0.0",
      "graph" => graph || graph_start_end()
    }
  end

  defp packed_variable_schema_json(definition_id, schema_name, schema_content) do
    %{
      "definition_id" => definition_id,
      "schema_name" => schema_name,
      "schema_content" => schema_content
    }
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1 -- one end-to-end test per module through the real router
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1: end-to-end coverage, one per module" do
    test "GET /api/tenant-config -- reachable with NO Authorization header, through Letflow.Router" do
      conn = conn(:get, "/api/tenant-config") |> Letflow.Router.call(@tenant_opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.keys(body) |> Enum.sort() == ["client_id", "oidc_authority"]
      assert is_binary(body["oidc_authority"])
      assert is_binary(body["client_id"])
    end

    test "GET /audit -- 200, {items, next_cursor, count} shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac1-audit")
      event_type = register_event_type!(tenant.tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(tenant.schema_name, instance_id)
      append_event!(tenant.schema_name, event_type, instance_id)

      resp =
        build_conn(:get, "/", tenant, roles: ["PLATFORM_ADMIN"])
        |> Letflow.Routers.Audit.call(@audit_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert Map.keys(body) |> Enum.sort() == ["count", "items", "next_cursor"]
      assert body["count"] == 1
      assert [item] = body["items"]
      assert item["resource_id"] == instance_id
    end

    test "POST /definitions/:id/validate -- 200, valid graph" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac1-validate")
      definition = active_definition!(tenant.schema_name)

      resp =
        build_conn(:post, "/#{definition.id}/validate", tenant, [])
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []
      assert body["definition_id"] == definition.id
    end

    test "POST /instances/:id/rebind-pins -- 200, changes/rebound_at shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac1-rebind")
      # graph_start_human_task_end/0 -- the instance must still be :active to
      # be rebindable; graph_start_end/0 completes synchronously and would
      # 409 (INSTANCE_NOT_REBINDABLE).
      definition = active_definition!(tenant.schema_name, graph_start_human_task_end())
      instance = start_instance!(tenant.schema_name, definition)

      body = %{
        "reason" => "REQ-078 AC1 fixture",
        "entries" => [
          %{"kind" => "variable_schema", "ref" => definition.name, "version" => "v2"}
        ]
      }

      resp =
        build_conn(:post, "/#{instance.instance_id}/rebind-pins", tenant, body: body)
        |> Letflow.Routers.Instances.call(@instances_opts)

      assert resp.status == 200
      resp_body = Jason.decode!(resp.resp_body)
      assert resp_body["instance_id"] == instance.instance_id
      assert is_list(resp_body["changes"])
      assert is_binary(resp_body["rebound_at"])
    end

    test "POST /solution-packs/export -- 200, pack document shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac1-export")
      definition = active_definition!(tenant.schema_name)

      resp =
        build_conn(:post, "/export", tenant, body: %{"definition_ids" => [definition.id]})
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort([
                 "pack_id",
                 "version",
                 "bpm_export_schema_version",
                 "exported_at",
                 "definitions",
                 "service_catalog_entries",
                 "variable_schemas",
                 "manifest"
               ])

      expected_id = definition.id
      assert [%{"definition_id" => ^expected_id}] = body["definitions"]
    end

    test "POST /solution-packs/install -- 200, install result shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac1-install")
      cleanup_solution_pack_installs!(tenant.tenant_id)
      source_id = Ecto.UUID.generate()
      doc = pack_document([packed_definition_json(source_id, unique("req078-pk"))])

      resp =
        build_conn(:post, "/install", tenant, body: doc)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort([
                 "pack_id",
                 "version",
                 "install_id",
                 "installed_definitions",
                 "variable_schemas_written",
                 "role_mapping_checklist",
                 "warnings"
               ])

      assert [%{"status" => "installed"}] = body["installed_definitions"]
    end

    test "GET /metrics -- 200, scope/generated_at/instances/tasks/definitions shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac1-metrics")

      resp =
        build_conn(:get, "/", tenant, [])
        |> Letflow.Routers.Metrics.call(@metrics_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["scope"] == "tenant"
      assert is_binary(body["generated_at"])
      assert Map.has_key?(body["instances"], "active")
      assert Map.has_key?(body["tasks"], "pending")
      assert Map.has_key?(body["definitions"], "draft")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC2 -- audit tenant isolation + permission gate
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC2: audit list is tenant-isolated; caller without :AuditRead gets 403" do
    test "requesting as tenant A returns only A's events, never a B event_id, same time window" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac2-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac2-b")

      type_a = register_event_type!(tenant_a.tenant_id)
      type_b = register_event_type!(tenant_b.tenant_id)
      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()
      seed_projection!(tenant_a.schema_name, instance_a)
      seed_projection!(tenant_b.schema_name, instance_b)

      # Same time window: appended back-to-back, no artificial timestamp skew.
      _event_a = append_event!(tenant_a.schema_name, type_a, instance_a)
      event_b = append_event!(tenant_b.schema_name, type_b, instance_b)

      resp =
        build_conn(:get, "/", tenant_a, roles: ["PLATFORM_ADMIN"])
        |> Letflow.Routers.Audit.call(@audit_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      resource_ids = Enum.map(body["items"], & &1["resource_id"])
      audit_ids = Enum.map(body["items"], & &1["audit_id"])

      assert instance_a in resource_ids
      refute instance_b in resource_ids
      refute event_b.event_id in audit_ids
      assert Enum.all?(resource_ids, &(&1 == instance_a))
    end

    test "a caller with only TASK_WORKER (no :AuditRead) gets 403 and no events" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac2-403")
      event_type = register_event_type!(tenant.tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(tenant.schema_name, instance_id)
      append_event!(tenant.schema_name, event_type, instance_id)

      resp =
        build_conn(:get, "/", tenant, roles: ["TASK_WORKER"])
        |> Letflow.Routers.Audit.call(@audit_opts)

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 403
      refute Map.has_key?(body, "items")
      refute resp.resp_body =~ instance_id
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC3 -- solution pack export/install never cross a tenant boundary
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC3: solution-pack export/install are tenant-isolated" do
    test "export as A naming an A id and a B id contains no B artefact -- 422, not a leaked document" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac3-export-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac3-export-b")

      definition_a = active_definition!(tenant_a.schema_name)
      definition_b = active_definition!(tenant_b.schema_name)

      resp =
        build_conn(:post, "/export", tenant_a,
          body: %{"definition_ids" => [definition_a.id, definition_b.id]}
        )
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 422
      refute resp.resp_body =~ definition_b.id
      refute resp.resp_body =~ definition_b.name
    end

    test "install as A writes only into A's schema -- verified by reading B's schema back, zero rows" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac3-install-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac3-install-b")
      cleanup_solution_pack_installs!(tenant_a.tenant_id)

      source_id = Ecto.UUID.generate()
      process_key = unique("req078-ac3-pk")
      doc = pack_document([packed_definition_json(source_id, process_key)])

      resp =
        build_conn(:post, "/install", tenant_a, body: doc)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 200

      assert Repo.aggregate(
               from(d in ProcessDefinition, where: d.name == ^process_key),
               :count,
               :id,
               prefix: tenant_a.schema_name
             ) == 1

      assert Repo.aggregate(
               from(d in ProcessDefinition, where: d.name == ^process_key),
               :count,
               :id,
               prefix: tenant_b.schema_name
             ) == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 -- the validate endpoint adds no rule of its own (design §18.2, T-12a/T-12b)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4: definition validation route agrees exactly with calling the validators directly" do
    test "T-12a: a valid graph -- 200, findings == [], and all three direct validators report zero violations" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac4-valid")
      graph = graph_start_end()
      definition = active_definition!(tenant.schema_name, graph)

      resp =
        build_conn(:post, "/#{definition.id}/validate", tenant, [])
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []

      assert {:ok, direct_graph} = Graph.from_map(graph)
      assert Graph.validate_graph(direct_graph).violations == []
      assert Graph.validate_node_attributes(direct_graph).violations == []
      assert Graph.validate_edge_conditions(direct_graph).violations == []
    end

    test "T-12b: an invalid graph -- 422, errors == the concatenation of the three direct validators' violations, in order" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac4-invalid")
      graph = graph_missing_end()
      definition = seed_definition_with_graph!(tenant.schema_name, graph)

      resp =
        build_conn(:post, "/#{definition.id}/validate", tenant, [])
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert is_list(body["errors"])
      refute body["errors"] == []

      assert {:ok, direct_graph} = Graph.from_map(graph)

      expected_violations =
        (Graph.validate_graph(direct_graph).violations ++
           Graph.validate_node_attributes(direct_graph).violations ++
           Graph.validate_edge_conditions(direct_graph).violations)
        |> Enum.map(fn v -> %{"code" => Atom.to_string(v.code), "message" => v.message} end)

      assert body["errors"] == expected_violations
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 -- metrics tenant-exposure rule
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: metrics is per-tenant-scoped" do
    test "tenant A (1 active instance) sees no tenant B figure (7 active instances)" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac5-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac5-b")

      seed_projection!(tenant_a.schema_name, Ecto.UUID.generate(), :active)

      for _ <- 1..7 do
        seed_projection!(tenant_b.schema_name, Ecto.UUID.generate(), :active)
      end

      resp =
        build_conn(:get, "/", tenant_a, [])
        |> Letflow.Routers.Metrics.call(@metrics_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["instances"]["active"] == 1

      # No value anywhere in the body equals B's own figure (7) or a
      # platform-wide total across both tenants (8).
      all_values =
        for group <- ["instances", "tasks", "definitions"],
            {_status, value} <- body[group],
            do: value

      refute 7 in all_values
      refute 8 in all_values
    end

    test "moduledoc states the tenant-exposure rule verbatim (PER-TENANT-SCOPED)" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.Metrics)

      assert moduledoc =~ "PER-TENANT-SCOPED"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC6 -- the validation.zig distinction is documented
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC6: moduledoc distinguishes routes/validation.zig from src/api/validation.zig" do
    test "Letflow.Routers.Definitions names both and attributes the second to REQ-068" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.Definitions)

      assert moduledoc =~ "routes/validation.zig"
      assert moduledoc =~ "src/api/validation.zig"
      assert moduledoc =~ "REQ-068"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC7 -- metrics moduledoc states no subsystem is built
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC7: metrics moduledoc states no metrics subsystem is built and names S6 as owner" do
    test "Letflow.Routers.Metrics moduledoc contains both required phrases" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.Metrics)

      assert moduledoc =~ "No metrics subsystem is built here"
      assert moduledoc =~ "S6 observability"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC8 -- variable_schemas write path (T-17, T-18, T-19)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC8: pack install writes variable_schemas only into the caller's own schema" do
    test "T-17: install with one variable_schemas entry writes it into A's schema and none into B's" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac8-t17-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac8-t17-b")
      cleanup_solution_pack_installs!(tenant_a.tenant_id)

      source_id = Ecto.UUID.generate()
      process_key = unique("req078-ac8-pk")
      schema_key = "order_id"
      schema_content = Jason.encode!(%{"type" => "string"})

      doc =
        pack_document(
          [packed_definition_json(source_id, process_key)],
          [packed_variable_schema_json(source_id, schema_key, schema_content)]
        )

      resp =
        build_conn(:post, "/install", tenant_a, body: doc)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["variable_schemas_written"] == 1

      rows_a = Repo.all(VariableSchema, prefix: tenant_a.schema_name)

      assert [%VariableSchema{variable_key: ^schema_key, json_schema: %{"type" => "string"}}] =
               rows_a

      rows_b = Repo.all(VariableSchema, prefix: tenant_b.schema_name)
      assert rows_b == []
    end

    test "T-18: a malformed (non-object) variable schema aborts the WHOLE transaction -- 422, zero rows either table" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req078-ac8-t18")

      source_id = Ecto.UUID.generate()
      process_key = unique("req078-ac8-t18-pk")
      # Top-level non-object -- fails JsonSchemaShape.check/1.
      malformed_content = Jason.encode!([1, 2])

      doc =
        pack_document(
          [packed_definition_json(source_id, process_key)],
          [packed_variable_schema_json(source_id, "bad_key", malformed_content)]
        )

      resp =
        build_conn(:post, "/install", tenant, body: doc)
        |> Letflow.Routers.SolutionPacks.call(@solution_packs_opts)

      assert resp.status == 422

      assert Repo.aggregate(VariableSchema, :count, :id, prefix: tenant.schema_name) == 0

      assert Repo.aggregate(
               from(d in ProcessDefinition, where: d.name == ^process_key),
               :count,
               :id,
               prefix: tenant.schema_name
             ) == 0
    end

    test "T-19: no Repo. call anywhere under lib/letflow/routers/ (INV-RT-1)" do
      files = Path.wildcard("lib/letflow/routers/*.ex")
      assert files != []

      offenders =
        Enum.filter(files, fn f ->
          File.read!(f)
          |> strip_comments_and_docs()
          |> String.contains?("Repo.")
        end)

      assert offenders == [], "Repo. call found in route layer: #{inspect(offenders)}"
    end

    test "T-19: no VariableSchema.changeset / insert call anywhere under lib/letflow/routers/" do
      files = Path.wildcard("lib/letflow/routers/*.ex")

      forbidden = [
        "VariableSchema.changeset",
        "Repo.insert",
        "Repo.insert_all",
        "Ecto.Multi.insert"
      ]

      offenders =
        Enum.filter(files, fn f ->
          stripped = File.read!(f) |> strip_comments_and_docs()
          Enum.any?(forbidden, &String.contains?(stripped, &1))
        end)

      assert offenders == [],
             "forbidden insert-shaped call found in route layer: #{inspect(offenders)}"
    end

    test "T-19: exactly one insert path against Letflow.Engine.VariableSchema exists in lib/, inside register_variable_schemas/3" do
      files = Path.wildcard("lib/**/*.ex")

      sites =
        Enum.flat_map(files, fn f ->
          stripped = File.read!(f) |> strip_comments_and_docs()

          if String.contains?(stripped, "VariableSchema.changeset") and
               (String.contains?(stripped, "Repo.insert") or
                  String.contains?(stripped, "Ecto.Multi.insert")) do
            [f]
          else
            []
          end
        end)

      assert sites == ["lib/letflow/definitions.ex"],
             "expected the single insert-path site to be lib/letflow/definitions.ex, got: #{inspect(sites)}"

      source = File.read!("lib/letflow/definitions.ex")
      assert source =~ "def register_variable_schemas("
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # INV-5 -- cross-tenant existing-resource access is 404, byte-identical to a
  # genuine miss (rebind-pins and definition-validate both act on an existing id)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "INV-5: cross-tenant resource access yields 404, same as a genuine miss" do
    test "POST /definitions/:id/validate on tenant B's definition_id, called as tenant A, is 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-inv5-validate-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-inv5-validate-b")
      definition_b = active_definition!(tenant_b.schema_name)

      resp_cross_tenant =
        build_conn(:post, "/#{definition_b.id}/validate", tenant_a, [])
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      resp_genuine_miss =
        build_conn(:post, "/#{Ecto.UUID.generate()}/validate", tenant_a, [])
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp_cross_tenant.status == 404
      assert resp_genuine_miss.status == 404
      assert resp_cross_tenant.resp_body == resp_genuine_miss.resp_body
    end

    test "POST /instances/:id/rebind-pins on tenant B's instance_id, called as tenant A, is 404, same body as a genuine miss" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req078-inv5-rebind-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req078-inv5-rebind-b")

      definition_b = active_definition!(tenant_b.schema_name)
      instance_b = start_instance!(tenant_b.schema_name, definition_b)

      body = %{
        "reason" => "INV-5 cross-tenant probe",
        "entries" => [%{"kind" => "variable_schema", "ref" => "whatever", "version" => "v2"}]
      }

      resp_cross_tenant =
        build_conn(:post, "/#{instance_b.instance_id}/rebind-pins", tenant_a, body: body)
        |> Letflow.Routers.Instances.call(@instances_opts)

      resp_genuine_miss =
        build_conn(:post, "/#{Ecto.UUID.generate()}/rebind-pins", tenant_a, body: body)
        |> Letflow.Routers.Instances.call(@instances_opts)

      assert resp_cross_tenant.status == 404
      assert resp_genuine_miss.status == 404
      assert resp_cross_tenant.resp_body == resp_genuine_miss.resp_body
    end
  end

  # ── Source-scan helper (T-19) ────────────────────────────────────────────

  # Strips `#` line comments and @moduledoc/@doc heredocs so a mention of
  # `Repo.` or `VariableSchema.changeset` inside PROSE (which several of
  # these route moduledocs are required to carry, e.g. §8.6 item 4) does not
  # false-positive against the mechanical "no such call exists" check. Only
  # code-shaped occurrences should trip these assertions.
  defp strip_comments_and_docs(source) do
    source
    |> String.replace(~r/@(module)?doc\s+"""(.|\n)*?"""/, "")
    |> String.split("\n")
    |> Enum.map(fn line -> line |> String.split("#") |> hd() end)
    |> Enum.join("\n")
  end
end
