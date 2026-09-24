defmodule Letflow.Routers.HelpTest do
  @moduledoc """
  REQ-366 §1 -- direct route-behavior tests for `Letflow.Routers.Help`'s
  `GET /help/resolved` handler. `test/letflow/help_test.exs` (REQ-364) covers
  `Letflow.Help`'s own context functions; `test/letflow/api/authorization_test.exs`
  covers `:HelpRead`'s presence/role grant in the permission matrix. Neither
  exercises this router's own new logic: `select_live_row/2`'s tie-break
  (design §1.2 steps 4a-4d), `compute_stale/2`'s comparison (design §1.2 step
  6), the 400/404 branches, or `resolved_help_json/3`'s response shape
  (design §1.6). That is this file's job -- TEST-DESIGNER pass, REQ-366.

  Dispatch mechanism mirrors `test/letflow/routers/definitions_test.exs`:
  `Letflow.Routers.Help.call/2` invoked directly with `conn.assigns.auth_context`
  set by hand (bypassing `AuthPipeline`, since `Letflow.Plugs.Authorize` itself
  -- the thing under test's own pipeline -- reads only `auth_context`, not
  anything `AuthPipeline` would add on top). `async: false`: tenant
  provisioning/migration needs `Sandbox.mode(Letflow.Repo, :auto)`
  (`TenantFixture.provisioned_tenant!/1`'s own requirement).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions
  alias Letflow.Help
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Help.init([])

  defp build_conn(method, path, tenant, fields \\ %{}) do
    roles = Map.get(fields, :roles, ["PROCESS_OPERATOR"])
    user_id = Map.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req366-help-router-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Help.call(conn, @opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp unique_screen_id(prefix \\ "req366-router-screen") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_def_name(prefix \\ "req366-router-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_process_definition!(schema_name, version \\ "1.0.0") do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_def_name(),
                 version: version,
                 graph: valid_graph(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    definition
  end

  defp draft!(schema_name, overrides) do
    attrs =
      Map.merge(
        %{
          screen_id: unique_screen_id(),
          title: "Router test help",
          body: "Some help text.",
          created_by: Ecto.UUID.generate()
        },
        overrides
      )

    assert {:ok, help} = Help.create_draft(attrs, prefix: schema_name)
    help
  end

  defp live!(schema_name, overrides) do
    help = draft!(schema_name, overrides)
    assert {:ok, published} = Help.publish(help.id, prefix: schema_name)
    published
  end

  # ---------------------------------------------------------------------------------
  # 400 -- missing screen_id
  # ---------------------------------------------------------------------------------

  describe "GET /resolved -- screen_id required" do
    test "400 when screen_id is missing" do
      %{tenant_id: tenant_id, schema_name: _schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      conn =
        build_conn(:get, "/resolved", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 400
    end

    test "400 when screen_id is blank" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      conn =
        build_conn(:get, "/resolved?screen_id=", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 400
    end
  end

  # ---------------------------------------------------------------------------------
  # 404 -- no row resolved
  # ---------------------------------------------------------------------------------

  describe "GET /resolved -- 404 when nothing resolves" do
    test "404 when no help_content row exists at all for screen_id" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 404
    end

    test "404 when only a :draft row exists for screen_id -- a draft is never shown" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      draft!(schema_name, %{screen_id: screen_id})

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ---------------------------------------------------------------------------------
  # tie-break (design §1.2 steps 4a-4d)
  # ---------------------------------------------------------------------------------

  describe "GET /resolved -- select_live_row/2 tie-break" do
    test "a live, generic (no process_definition_id) row is returned for a plain screen_id lookup" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      live = live!(schema_name, %{screen_id: screen_id})

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 200
      body = json(conn)
      assert body["id"] == live.id
      assert body["process_definition_id"] == nil
    end

    test "when a matching process_definition_id is supplied, the process-specific live row outranks the generic live row" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      definition = create_process_definition!(schema_name)

      _generic = live!(schema_name, %{screen_id: screen_id})
      specific = live!(schema_name, %{screen_id: screen_id, process_definition_id: definition.id})

      conn =
        build_conn(
          :get,
          "/resolved?screen_id=#{screen_id}&process_definition_id=#{definition.id}",
          %{tenant_id: tenant_id}
        )
        |> dispatch()

      assert conn.status == 200
      body = json(conn)
      assert body["id"] == specific.id
      assert body["process_definition_id"] == definition.id
    end

    test "when process_definition_id is supplied but no live row matches it, the generic live row is returned as fallback" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      other_definition = create_process_definition!(schema_name)
      generic = live!(schema_name, %{screen_id: screen_id})

      conn =
        build_conn(
          :get,
          "/resolved?screen_id=#{screen_id}&process_definition_id=#{other_definition.id}",
          %{tenant_id: tenant_id}
        )
        |> dispatch()

      assert conn.status == 200
      body = json(conn)
      assert body["id"] == generic.id
    end

    test "two tied live generic rows -- the most recently updated_at one wins, deterministically" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      older = live!(schema_name, %{screen_id: screen_id})
      # Ensure a measurable updated_at gap between the two rows.
      Process.sleep(10)
      newer = live!(schema_name, %{screen_id: screen_id})

      assert DateTime.compare(newer.updated_at, older.updated_at) == :gt

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 200
      assert json(conn)["id"] == newer.id
    end

    test "when two live rows have the same process_definition_id, the row with the later updated_at wins regardless of microsecond position" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      definition = create_process_definition!(schema_name)

      # stale: second=5, microsecond=999000 — old struct comparison picks this (wrong)
      stale = live!(schema_name, %{screen_id: screen_id, process_definition_id: definition.id})
      stale_ts = ~U[2024-01-01 00:00:05.999000Z]
      Ecto.Changeset.change(stale, updated_at: stale_ts) |> Repo.update!(prefix: schema_name)

      # fresh: second=6, microsecond=1 — later wall-clock, correct answer
      fresh = live!(schema_name, %{screen_id: screen_id, process_definition_id: definition.id})
      fresh_ts = ~U[2024-01-01 00:00:06.000001Z]
      fresh = Ecto.Changeset.change(fresh, updated_at: fresh_ts) |> Repo.update!(prefix: schema_name)

      conn =
        build_conn(
          :get,
          "/resolved?screen_id=#{screen_id}&process_definition_id=#{definition.id}",
          %{tenant_id: tenant_id}
        )
        |> dispatch()

      assert conn.status == 200
      assert json(conn)["id"] == fresh.id
    end
  end

  # ---------------------------------------------------------------------------------
  # compute_stale/2 (design §1.2 step 6) -- exercised with two real process
  # definition versions, not a hardcoded/mocked comparison.
  # ---------------------------------------------------------------------------------

  describe "GET /resolved -- staleness computation" do
    test "stale is false right after publish, when confirmed_for_definition_version matches the process definition's current version" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      definition = create_process_definition!(schema_name, "1.0.0")
      live = live!(schema_name, %{screen_id: screen_id, process_definition_id: definition.id})
      assert live.confirmed_for_definition_version == "1.0.0"

      conn =
        build_conn(
          :get,
          "/resolved?screen_id=#{screen_id}&process_definition_id=#{definition.id}",
          %{tenant_id: tenant_id}
        )
        |> dispatch()

      assert conn.status == 200
      assert json(conn)["stale"] == false
    end

    test "stale becomes true once the process definition's version is bumped past what was confirmed" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      definition = create_process_definition!(schema_name, "1.0.0")
      live!(schema_name, %{screen_id: screen_id, process_definition_id: definition.id})

      assert {:ok, _updated} =
               Definitions.update(definition.id, %{version: "2.0.0"}, prefix: schema_name)

      conn =
        build_conn(
          :get,
          "/resolved?screen_id=#{screen_id}&process_definition_id=#{definition.id}",
          %{tenant_id: tenant_id}
        )
        |> dispatch()

      assert conn.status == 200
      body = json(conn)
      assert body["stale"] == true
      assert body["confirmed_for_definition_version"] == "1.0.0"
    end

    test "non-process-scoped help is never stale, regardless of process_definition_id query param" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      live!(schema_name, %{screen_id: screen_id})

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 200
      assert json(conn)["stale"] == false
    end
  end

  # ---------------------------------------------------------------------------------
  # response shape (design §1.6)
  # ---------------------------------------------------------------------------------

  describe "GET /resolved -- response shape" do
    test "200 body has exactly design §1.6's field set, with status always \"live\" and scope always \"tenant\" today" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router")

      screen_id = unique_screen_id()
      live = live!(schema_name, %{screen_id: screen_id})

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 200
      body = json(conn)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort([
                 "id",
                 "screen_id",
                 "process_definition_id",
                 "title",
                 "body",
                 "status",
                 "confirmed_at",
                 "confirmed_for_definition_version",
                 "media",
                 "scope",
                 "stale"
               ])

      assert body["id"] == live.id
      assert body["screen_id"] == screen_id
      assert body["title"] == live.title
      assert body["body"] == live.body
      assert body["status"] == "live"
      assert body["scope"] == "tenant"
      assert body["media"] == []
      assert is_binary(body["confirmed_at"])
    end
  end

  # ---------------------------------------------------------------------------------
  # tenant isolation -- a row in one tenant schema is never resolved from another
  # ---------------------------------------------------------------------------------

  describe "GET /resolved -- tenant scoping" do
    test "a live row in another tenant's schema is not visible" do
      %{tenant_id: other_tenant_id, schema_name: other_schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req366-router-a")

      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req366-router-b")

      screen_id = unique_screen_id()
      _other_tenant_row = live!(other_schema, %{screen_id: screen_id})

      conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: tenant_id})
        |> dispatch()

      assert conn.status == 404

      # sanity: the row genuinely exists in the OTHER tenant's schema.
      other_conn =
        build_conn(:get, "/resolved?screen_id=#{screen_id}", %{tenant_id: other_tenant_id})
        |> dispatch()

      assert other_conn.status == 200
    end
  end
end
