defmodule Letflow.Routers.DefinitionsTest do
  @moduledoc """
  Tests for `Letflow.Routers.Definitions`'s REQ-081 read routes (get_by_id/
  list/get_active_by_name/search/export). REQ-078's `/:id/validate` route is
  untouched and not retested here.

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture`, same
  dispatch mechanism as `test/letflow/routers/instances_test.exs` (direct
  `Letflow.Routers.Definitions.call/2`, `conn.assigns[:auth_context]` set
  directly, bypassing `AuthPipeline`). `async: false` for the whole module --
  tenant provisioning/migration replay needs `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Pagination
  alias Letflow.Definitions
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])

  defp build_conn(method, path, tenant, fields) do
    roles = Map.get(fields, :roles, [])
    user_id = Map.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  defp unique_name(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp minimal_graph do
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

  defp create_definition!(schema_name, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: unique_name("req081-def"),
          version: "1.0.0",
          graph: minimal_graph(),
          created_by: Ecto.UUID.generate()
        },
        overrides
      )

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)
    definition
  end

  defp active_definition!(schema_name, overrides \\ %{}) do
    definition = create_definition!(schema_name, overrides)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- each of the five handlers, end-to-end
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1 -- five read endpoints" do
    test "GET /:id returns the definition shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac1a")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{definition.id}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == definition.id
      assert body["name"] == definition.name
      assert body["version"] == "1.0.0"
      assert body["status"] == "DRAFT"
      assert is_map(body["graph"])
      assert is_binary(body["created_at"])
      assert is_binary(body["updated_at"])
      assert Map.has_key?(body, "archived_at")
      assert Map.has_key?(body, "stage")

      assert Enum.sort(Map.keys(body)) ==
               Enum.sort([
                 "id",
                 "name",
                 "version",
                 "description",
                 "status",
                 "graph",
                 "created_by",
                 "created_at",
                 "updated_at",
                 "archived_at",
                 "stage"
               ])
    end

    test "GET / returns a page envelope" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac1b")
      _definition = create_definition!(tenant.schema_name)

      conn = build_conn("GET", "/", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["items"])
      assert Map.has_key?(body, "next_cursor")
    end

    test "GET /active/:name returns the ACTIVE definition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac1c")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("GET", "/active/#{definition.name}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == definition.id
      assert body["status"] == "ACTIVE"
    end

    test "GET /search returns a page envelope of ranked results" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac1d")
      query = unique_name("ac1d-search-term")
      definition = create_definition!(tenant.schema_name, %{name: query})

      conn =
        build_conn("GET", "/search?q=#{URI.encode_www_form(query)}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "next_cursor")
      assert [%{"definition" => item, "rank" => rank}] = body["items"]
      assert item["id"] == definition.id
      assert rank == 3.0
    end

    test "GET /:id/export returns the export document shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac1e")
      definition = create_definition!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{definition.id}/export", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == definition.id
      assert body["name"] == definition.name
      assert body["bpm_export_schema_version"] == "bpm/definition/v1"
      assert is_map(body["graph"])
      assert is_binary(body["exported_at"])

      assert Enum.sort(Map.keys(body)) ==
               Enum.sort([
                 "bpm_export_schema_version",
                 "id",
                 "name",
                 "version",
                 "description",
                 "graph",
                 "exported_at"
               ])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- search-contract preservation (REQ-042's boundary)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2 -- search contract preserved through HTTP" do
    test "empty query returns a 400-class problem document, distinct from cursor-expired's type" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac2a")

      conn = build_conn("GET", "/search", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 400
      assert String.ends_with?(body["type"], "bad-request")
      refute String.ends_with?(body["type"], "cursor-expired")
      assert body["detail"] =~ "must not be empty"
    end

    test "query over 512 bytes returns a 400-class problem document" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac2b")
      too_long = String.duplicate("a", 513)

      conn =
        build_conn("GET", "/search?q=#{too_long}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 400
      assert String.ends_with?(body["type"], "bad-request")
      assert body["detail"] =~ "512"
    end

    test "no match returns 200 with an empty array, NOT 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac2c")
      no_match_query = unique_name("no-such-definition-term")

      conn =
        build_conn("GET", "/search?q=#{URI.encode_www_form(no_match_query)}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["items"] == []
      assert body["next_cursor"] == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- search ranking order preserved through the HTTP layer
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3 -- search ranking order preserved through HTTP" do
    test "exact name match ranks above partial name match above description-only match" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac3a")
      term = unique_name("ranktest")

      exact = create_definition!(tenant.schema_name, %{name: term})
      partial = create_definition!(tenant.schema_name, %{name: term <> "-extra-suffix"})

      description_only =
        create_definition!(tenant.schema_name, %{
          name: unique_name("unrelated-name"),
          description: "mentions #{term} only in the description"
        })

      conn =
        build_conn("GET", "/search?q=#{URI.encode_www_form(term)}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      ids = Enum.map(body["items"], & &1["definition"]["id"])
      ranks = Enum.map(body["items"], & &1["rank"])

      assert ids == [exact.id, partial.id, description_only.id]
      assert ranks == [3.0, 2.0, 1.0]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 -- list and search are cursor-paginated (REQ-067)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4 -- pagination completeness" do
    test "list: every row exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac4a")
      ids = for _ <- 1..5, do: create_definition!(tenant.schema_name).id

      {page1, cursor1} = fetch_list_page(tenant, "?page_size=2")
      {page2, cursor2} = fetch_list_page(tenant, "?page_size=2&cursor=#{cursor1}")
      {page3, cursor3} = fetch_list_page(tenant, "?page_size=2&cursor=#{cursor2}")

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1
      assert cursor3 == nil

      seen = Enum.map(page1 ++ page2 ++ page3, & &1["id"])
      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(Enum.uniq(seen)) == length(seen)
    end

    test "search: every matching row exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac4b")
      term = unique_name("pagesearch")
      ids =
        for i <- 1..5,
            do: create_definition!(tenant.schema_name, %{name: term, version: "1.0.#{i}"}).id

      {page1, cursor1} = fetch_search_page(tenant, term, "&page_size=2")
      {page2, cursor2} = fetch_search_page(tenant, term, "&page_size=2&cursor=#{cursor1}")
      {page3, cursor3} = fetch_search_page(tenant, term, "&page_size=2&cursor=#{cursor2}")

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1
      assert cursor3 == nil

      seen = Enum.map(page1 ++ page2 ++ page3, & &1["definition"]["id"])
      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(Enum.uniq(seen)) == length(seen)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 -- cross-tenant/nonexistent equivalence (INV-1, INV-5)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5 -- cross-tenant/nonexistent equivalence (INV-5)" do
    test "get: cross-tenant id and nonexistent id both 404, byte-identical" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5a1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5a2")
      definition = create_definition!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{definition.id}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "export: cross-tenant id and nonexistent id both 404, byte-identical" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5b1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5b2")
      definition = create_definition!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{definition.id}/export", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/export", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "get_active_by_name: cross-tenant name and nonexistent name both 404, byte-identical" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5c1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5c2")
      definition = active_definition!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/active/#{definition.name}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/active/#{unique_name("no-such-active-name")}", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "search: a term matching only tenant B's rows returns an empty page to tenant A" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5d1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac5d2")
      term = unique_name("xtenant-only-in-b")
      _definition_b = create_definition!(tenant_b.schema_name, %{name: term})

      conn =
        build_conn("GET", "/search?q=#{URI.encode_www_form(term)}", tenant_a, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["items"] == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6 -- 403 without DefinitionsRead, on all five endpoints
  # ══════════════════════════════════════════════════════════════════════

  describe "AC6 -- permission required on every read endpoint" do
    test "AGENT_RUNNER (no DefinitionsRead) gets 403 on all five" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-ac6a")
      definition = active_definition!(tenant.schema_name)

      for path <- [
            "/",
            "/#{definition.id}",
            "/active/#{definition.name}",
            "/search?q=#{definition.name}",
            "/#{definition.id}/export"
          ] do
        conn = build_conn("GET", path, tenant, %{roles: ["AGENT_RUNNER"]}) |> dispatch()
        assert conn.status == 403, "expected 403 for #{path}, got #{conn.status}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # export/2 scope -- exactly one tenant's one definition, nothing more
  # ══════════════════════════════════════════════════════════════════════

  describe "export scope" do
    test "export contains exactly the requested definition's own fields, no other definition's data" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-export-a")
      target = create_definition!(tenant.schema_name, %{description: "target description"})
      other = create_definition!(tenant.schema_name, %{description: "other description"})

      conn =
        build_conn("GET", "/#{target.id}/export", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == target.id
      assert body["name"] == target.name
      assert body["description"] == "target description"
      refute body["id"] == other.id
      refute body["description"] == "other description"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Malformed/expired/wrong-endpoint cursor handling -- fail closed, not crash
  # ══════════════════════════════════════════════════════════════════════

  describe "cursor edge cases -- fail closed, not crash" do
    test "list: a garbage (non-base64) cursor string fails closed, does not crash" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-cursor-a")

      conn =
        build_conn("GET", "/?cursor=not-a-valid-cursor!!!", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status in 400..599
      assert is_binary(conn.resp_body)
    end

    test "search: a garbage (non-base64) cursor string fails closed, does not crash" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-cursor-b")

      conn =
        build_conn("GET", "/search?q=x&cursor=not-a-valid-cursor!!!", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status in 400..599
      assert is_binary(conn.resp_body)
    end

    test "list: an expired cursor maps to the dedicated cursor-expired problem type (410)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-cursor-c")
      long_ago_us = System.system_time(:microsecond) - 86_400_000_000 - 60_000_000

      raw =
        Pagination.build_raw_cursor_timestamp_key(
          "DL:",
          long_ago_us,
          Ecto.UUID.generate(),
          System.system_time(:microsecond)
        )

      cursor = Pagination.encode_cursor(raw)

      conn =
        build_conn("GET", "/?cursor=#{cursor}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 410
      body = Jason.decode!(conn.resp_body)
      assert String.ends_with?(body["type"], "cursor-expired")
    end

    test "search: an expired cursor maps to the dedicated cursor-expired problem type (410)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-cursor-d")
      long_ago_us = System.system_time(:microsecond) - 86_400_000_000 - 60_000_000

      raw =
        Pagination.build_raw_cursor_timestamp_key(
          "DS:",
          long_ago_us,
          "3|#{Ecto.UUID.generate()}",
          System.system_time(:microsecond)
        )

      cursor = Pagination.encode_cursor(raw)

      conn =
        build_conn("GET", "/search?q=x&cursor=#{cursor}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 410
      body = Jason.decode!(conn.resp_body)
      assert String.ends_with?(body["type"], "cursor-expired")
    end

    test "list: a search-minted cursor ('DS:') is rejected as wrong_endpoint, not applied" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-cursor-e")

      raw =
        Pagination.build_raw_cursor_timestamp_key(
          "DS:",
          System.system_time(:microsecond),
          "3|#{Ecto.UUID.generate()}",
          System.system_time(:microsecond)
        )

      cursor = Pagination.encode_cursor(raw)

      conn =
        build_conn("GET", "/?cursor=#{cursor}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] =~ "not valid for this endpoint"
    end

    test "search: a list-minted cursor ('DL:') is rejected as wrong_endpoint, not applied" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req081-cursor-f")

      raw =
        Pagination.build_raw_cursor_timestamp_key(
          "DL:",
          System.system_time(:microsecond),
          Ecto.UUID.generate(),
          System.system_time(:microsecond)
        )

      cursor = Pagination.encode_cursor(raw)

      conn =
        build_conn("GET", "/search?q=x&cursor=#{cursor}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] =~ "not valid for this endpoint"
    end
  end

  # ── Test helpers ─────────────────────────────────────────────────────

  defp fetch_list_page(tenant, query_suffix) do
    conn =
      build_conn("GET", "/#{query_suffix}", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    {body["items"], body["next_cursor"]}
  end

  defp fetch_search_page(tenant, term, extra_query) do
    conn =
      build_conn(
        "GET",
        "/search?q=#{URI.encode_www_form(term)}#{extra_query}",
        tenant,
        %{roles: ["PROCESS_OPERATOR"]}
      )
      |> dispatch()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    {body["items"], body["next_cursor"]}
  end
end
