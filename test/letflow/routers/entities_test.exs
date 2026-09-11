defmodule Letflow.Routers.EntitiesTest do
  @moduledoc """
  Tests for REQ-310's nine `Letflow.Routers.Entities` routes, written by
  ELIXIR-DEV at WF-02 Step 2a to exercise the implementation against a real
  Postgres tenant schema and the REAL `Letflow.Plugs.ApiPipeline` stack. Not
  full 16-AC coverage -- TEST-DESIGNER writes that later in this pipeline
  (Step 2d+). See `lib/letflow/design/req308-entity-http-surface.md` for the
  design these tests spot-check.

  ## Every request goes through the full pipeline, not the router in isolation

  Dispatched via `Letflow.Router.call/2` with a real API-token bearer
  credential (`Authorization: Bearer lf_tok_...` + `X-Tenant-Slug`), so
  `Letflow.Plugs.AuthPipeline` -> `Letflow.Plugs.TenantStatus` ->
  `Letflow.Plugs.Authorize` -> the router all genuinely run and
  `conn.assigns.scoped_opts` is resolved by the production code path from the
  caller's own credential -- never preset by the test. This is
  `test/letflow/api_token_auth_pipeline_test.exs`'s established convention,
  and it is what makes the INV-1 and 403 assertions below mean anything:
  a test that hand-assigned `:scoped_opts` and called
  `Letflow.Routers.Entities.call/2` directly would prove neither.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil, opts \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> maybe_pin_trace_id(Keyword.get(opts, :trace_id))
    |> dispatch()
  end

  # `Letflow.Api.Context.assign_trace_id/1` echoes a caller-supplied
  # `x-trace-id` header verbatim, and `Letflow.Api.Error`'s `trace_id` member
  # is the one field in a problem document that is per-REQUEST correlation
  # data rather than per-RESOURCE information. The INV-5 byte-identity tests
  # below pin it to one fixed value across the pair of requests they compare,
  # so `resp_body == resp_body` is a genuine byte-for-byte comparison of the
  # whole document -- rather than dropping or normalising a field, which
  # would be exactly the loophole through which a real INV-5 leak could hide.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req310-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-310 Entities Router Test User",
      email: "req310-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # A provisioned tenant plus a real API token carrying `roles`. Every role
  # string below is one of Letflow.Api.Authorization's own five closed roles,
  # so the 403/non-403 assertions are driven by that module's real matrix.
  defp tenant_ctx(slug_prefix, roles \\ ["PLATFORM_ADMIN"]) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-310 Entities Router Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp definition_body(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "widget",
        "display_name" => "Widget",
        "fields" => [
          %{"name" => "title", "type" => "string", "required" => true},
          %{"name" => "quantity", "type" => "integer"}
        ]
      },
      overrides
    )
  end

  # Creates + activates a definition through the CONTEXT MODULE (not the
  # routes), so a route test asserting on a pre-existing definition is not
  # implicitly asserting on the create/activate routes as well.
  defp seed_active_definition!(ctx, name \\ "widget") do
    document = %{
      name: name,
      display_name: String.capitalize(name),
      fields: [
        %{name: "title", type: :string, required: true},
        %{name: "quantity", type: :integer}
      ]
    }

    {:ok, definition} =
      Definitions.create_definition(
        %{definition: document, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(name, ctx.user_id, "test go-live", ctx.schema_name)

    %{created: definition, activated: activated}
  end

  # Creates an INACTIVE definition through the context module, without
  # activating it -- the precondition for the activate-route tests, which
  # must reach the delegate's activation path rather than short-circuit on
  # :not_found.
  defp seed_definition_only!(ctx, name \\ "widget") do
    {:ok, definition} =
      Definitions.create_definition(
        %{
          definition: %{
            name: name,
            display_name: String.capitalize(name),
            fields: [
              %{name: "title", type: :string, required: true},
              %{name: "quantity", type: :integer}
            ]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    definition
  end

  defp seed_record!(ctx, entity_type \\ "widget", field_values \\ %{"title" => "seeded"}) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # Guards the premise of the blocker-2 parity test below: the "typo" string
  # it sends really must NOT already be an atom in this VM, or the test
  # would silently stop testing the thing it exists to test. Asserted at
  # runtime rather than assumed, because whether an atom exists is exactly
  # the unrelated global state the fix removes from the error contract.
  defp refute_existing_atom!(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :ok
  else
    atom ->
      flunk("""
      test premise broken: #{inspect(string)} IS already an atom (#{inspect(atom)}) in this VM, \
      so it no longer exercises the to_existing_atom-raises path. Pick another string.\
      """)
  end

  # A problem document minus the one member that is legitimately per-REQUEST
  # rather than per-error (`trace_id`, see maybe_pin_trace_id/2 above). Two
  # requests differing only in a field's spelling must otherwise produce
  # byte-identical documents.
  defp normalise_problem(conn), do: conn |> body_of() |> Map.delete("trace_id")

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 -- __authz_routes__/0 returns exactly the nine designed routes.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- the declared route table matches design §1" do
    test "__authz_routes__/0 returns exactly the nine non-query routes, with their designed policy keys" do
      expected = [
        {"POST", "/definitions/:name/activate", :EntitiesDefinitionsWrite},
        {"POST", "/definitions", :EntitiesDefinitionsWrite},
        {"GET", "/definitions/active/:name", :EntitiesDefinitionsRead},
        {"GET", "/definitions/by-name/:name", :EntitiesDefinitionsRead},
        {"GET", "/definitions/:id", :EntitiesDefinitionsRead},
        {"GET", "/definitions", :EntitiesDefinitionsRead},
        {"POST", "/records/:entity_type", :EntitiesRecordsWrite},
        {"PUT", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
        {"DELETE", "/records/:entity_type/:record_id", :EntitiesRecordsWrite}
      ]

      actual = Letflow.Routers.Entities.__authz_routes__()

      assert length(actual) == 9
      assert Enum.sort(actual) == Enum.sort(expected)
    end

    test "⛔ no GET route exists under /records -- record reads are POST /entities/query only" do
      record_gets =
        Letflow.Routers.Entities.__authz_routes__()
        |> Enum.filter(fn {method, path, _key} ->
          method == "GET" and String.starts_with?(path, "/records")
        end)

      assert record_gets == []
    end

    test "route ORDER in the source places /active/:name and /by-name/:name above /definitions/:id" do
      # @authz_routes accumulates in reverse declaration order, so the
      # declared list read back gives declaration order when reversed. This
      # is a readability check only -- the LOAD-BEARING proof that ordering
      # actually works is by request, in the AC2 describe block below.
      declaration_order =
        Letflow.Routers.Entities.__authz_routes__()
        |> Enum.reverse()
        |> Enum.map(fn {method, path, _key} -> {method, path} end)

      active_index =
        Enum.find_index(declaration_order, &(&1 == {"GET", "/definitions/active/:name"}))

      by_name_index =
        Enum.find_index(declaration_order, &(&1 == {"GET", "/definitions/by-name/:name"}))

      id_index = Enum.find_index(declaration_order, &(&1 == {"GET", "/definitions/:id"}))

      assert active_index < id_index
      assert by_name_index < id_index
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 -- ⛔ ROUTE ORDER PROVEN BY REQUEST, not by reading source.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- /definitions/active/:name and /definitions/by-name/:name are not swallowed by /definitions/:id" do
    test "GET /definitions/active/<name> runs the active-by-name handler, not the :id handler" do
      ctx = tenant_ctx("req310-order-active")
      %{activated: activated} = seed_active_definition!(ctx)

      conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)

      # The :id clause could not possibly have produced this: it would have
      # cast the literal path segment "active" as a UUID (failing) and
      # returned 404, never a 200 carrying the definition activated under
      # the name "widget".
      assert conn.status == 200
      body = body_of(conn)
      assert body["id"] == activated.id
      assert body["name"] == "widget"
      assert body["status"] == "active"
    end

    test "GET /definitions/by-name/<name> runs the by-name handler, not the :id handler" do
      ctx = tenant_ctx("req310-order-byname")
      %{created: created} = seed_active_definition!(ctx)

      conn = request(:get, "/api/v1/entities/definitions/by-name/widget", ctx)

      assert conn.status == 200
      body = body_of(conn)
      assert body["id"] == created.id
      assert body["name"] == "widget"
    end

    test "THE NEGATIVE, DIRECTLY: no id lookup against the literal string 'active' occurred" do
      ctx = tenant_ctx("req310-order-negative")
      seed_active_definition!(ctx)

      # If the bare /definitions/:id clause had swallowed this path, `id`
      # would have been bound to the literal "active" -- which is not a
      # UUID, so get_definition would have 404'd. Requesting the SAME two
      # paths in one test and comparing their statuses isolates the
      # difference to the routing, not to the fixture:
      by_id_of_literal =
        request(:get, "/api/v1/entities/definitions/#{URI.encode("active")}x", ctx)

      active_by_name = request(:get, "/api/v1/entities/definitions/active/widget", ctx)

      # "activex" IS handled by the :id clause (single segment) -> 404.
      assert by_id_of_literal.status == 404
      # "/active/widget" is NOT -> 200, the observably different status the
      # :id clause could never produce for a non-UUID segment.
      assert active_by_name.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 -- every one of the nine routes returns its designed success status
  # through the full ApiPipeline stack.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- designed success status on every route, full pipeline" do
    test "all nine routes, in sequence, against one real tenant" do
      ctx = tenant_ctx("req310-success")

      # 1. POST /entities/definitions -> 201
      create_conn = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert create_conn.status == 201
      created = body_of(create_conn)
      assert created["name"] == "widget"
      assert created["status"] == "inactive"

      # 2. POST /entities/definitions/:name/activate -> 200
      activate_conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "rationale" => "go-live"
        })

      assert activate_conn.status == 200
      assert body_of(activate_conn)["status"] == "active"

      # 3. GET /entities/definitions/active/:name -> 200
      active_conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)
      assert active_conn.status == 200

      # 4. GET /entities/definitions/by-name/:name -> 200
      by_name_conn = request(:get, "/api/v1/entities/definitions/by-name/widget", ctx)
      assert by_name_conn.status == 200

      # 5. GET /entities/definitions/:id -> 200
      by_id_conn = request(:get, "/api/v1/entities/definitions/#{created["id"]}", ctx)
      assert by_id_conn.status == 200
      assert body_of(by_id_conn)["id"] == created["id"]

      # 6. GET /entities/definitions -> 200, {"items": [...], "next_cursor": ...}
      list_conn = request(:get, "/api/v1/entities/definitions", ctx)
      assert list_conn.status == 200
      list_body = body_of(list_conn)
      assert is_list(list_body["items"])
      assert Map.has_key?(list_body, "next_cursor")
      refute Map.has_key?(list_body, "count")
      assert Enum.any?(list_body["items"], &(&1["id"] == created["id"]))

      # 7. POST /entities/records/:entity_type -> 201
      create_record_conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "first", "quantity" => 3}
        })

      assert create_record_conn.status == 201
      record = body_of(create_record_conn)
      assert record["entity_type"] == "widget"
      assert record["field_values"] == %{"title" => "first", "quantity" => 3}
      refute record["deleted"]

      # 8. PUT /entities/records/:entity_type/:record_id -> 200
      update_conn =
        request(:put, "/api/v1/entities/records/widget/#{record["record_id"]}", ctx, %{
          "field_values" => %{"title" => "second", "quantity" => 9}
        })

      assert update_conn.status == 200
      assert body_of(update_conn)["field_values"] == %{"title" => "second", "quantity" => 9}

      # 9. DELETE /entities/records/:entity_type/:record_id -> 200
      delete_conn =
        request(:delete, "/api/v1/entities/records/widget/#{record["record_id"]}", ctx)

      assert delete_conn.status == 200
      assert body_of(delete_conn)["deleted"] == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 -- permission enforcement, driven by Authorization's real matrix.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- 403 without the permission, non-403 with it" do
    # AGENT_RUNNER holds NONE of the four Entities* permissions (its own
    # role_allows?/2 catch-all is `false`), so it is the 403 case for all
    # three distinct permission atoms these nine routes use.
    test ":EntitiesDefinitionsRead -- AGENT_RUNNER 403, TASK_WORKER non-403" do
      denied_ctx = tenant_ctx("req310-perm-read-deny", ["AGENT_RUNNER"])
      allowed_ctx = tenant_ctx("req310-perm-read-allow", ["TASK_WORKER"])

      assert request(:get, "/api/v1/entities/definitions", denied_ctx).status == 403
      assert request(:get, "/api/v1/entities/definitions", allowed_ctx).status != 403
    end

    test ":EntitiesDefinitionsWrite -- PROCESS_OPERATOR 403 (deliberately withheld), PROCESS_DESIGNER non-403" do
      # Per design §3's matrix, PROCESS_OPERATOR deliberately does NOT hold
      # EntitiesDefinitionsWrite -- schema authoring tracks PROCESS_DESIGNER.
      denied_ctx = tenant_ctx("req310-perm-defwrite-deny", ["PROCESS_OPERATOR"])
      allowed_ctx = tenant_ctx("req310-perm-defwrite-allow", ["PROCESS_DESIGNER"])

      denied = request(:post, "/api/v1/entities/definitions", denied_ctx, definition_body())
      assert denied.status == 403

      allowed = request(:post, "/api/v1/entities/definitions", allowed_ctx, definition_body())
      assert allowed.status != 403
      assert allowed.status == 201
    end

    test ":EntitiesRecordsWrite -- PROCESS_DESIGNER 403 (deliberately withheld), PROCESS_OPERATOR non-403" do
      # The mirror image: record authoring tracks PROCESS_OPERATOR, not
      # PROCESS_DESIGNER.
      denied_ctx = tenant_ctx("req310-perm-recwrite-deny", ["PROCESS_DESIGNER"])
      allowed_ctx = tenant_ctx("req310-perm-recwrite-allow", ["PROCESS_OPERATOR"])
      seed_active_definition!(allowed_ctx)

      denied =
        request(:post, "/api/v1/entities/records/widget", denied_ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert denied.status == 403

      allowed =
        request(:post, "/api/v1/entities/records/widget", allowed_ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert allowed.status != 403
      assert allowed.status == 201
    end

    test "every one of the nine routes 403s for a caller holding none of the permissions" do
      ctx = tenant_ctx("req310-perm-all-nine", ["AGENT_RUNNER"])
      record_id = Ecto.UUID.generate()
      definition_id = Ecto.UUID.generate()

      requests = [
        {:post, "/api/v1/entities/definitions", definition_body()},
        {:post, "/api/v1/entities/definitions/widget/activate", %{}},
        {:get, "/api/v1/entities/definitions/active/widget", nil},
        {:get, "/api/v1/entities/definitions/by-name/widget", nil},
        {:get, "/api/v1/entities/definitions/#{definition_id}", nil},
        {:get, "/api/v1/entities/definitions", nil},
        {:post, "/api/v1/entities/records/widget", %{"field_values" => %{}}},
        {:put, "/api/v1/entities/records/widget/#{record_id}", %{"field_values" => %{}}},
        {:delete, "/api/v1/entities/records/widget/#{record_id}", nil}
      ]

      for {method, path, body} <- requests do
        conn = request(method, path, ctx, body)

        assert conn.status == 403,
               "#{method |> to_string() |> String.upcase()} #{path} returned #{conn.status}, expected 403"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 -- INV-5: cross-tenant and nonexistent are BYTE-IDENTICAL.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC5 -- INV-5 byte-identity of cross-tenant and nonexistent" do
    test "GET /definitions/:id -- another tenant's real id and an id that exists nowhere are the same bytes" do
      ctx_a = tenant_ctx("req310-inv5-defs-a")
      ctx_b = tenant_ctx("req310-inv5-defs-b")

      # A real, existing definition id -- in tenant B's schema.
      %{created: b_definition} = seed_active_definition!(ctx_b)
      nowhere_id = Ecto.UUID.generate()
      pinned = [trace_id: "req310-inv5-defs-fixed-trace"]

      cross_tenant =
        request(:get, "/api/v1/entities/definitions/#{b_definition.id}", ctx_a, nil, pinned)

      nonexistent =
        request(:get, "/api/v1/entities/definitions/#{nowhere_id}", ctx_a, nil, pinned)

      # ONE assertion comparing both status AND body, not two separate
      # "assert 404" assertions: a difference in any response byte would
      # be an "exists but forbidden" oracle.
      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}

      assert cross_tenant.status == 404
    end

    test "PUT /records/:entity_type/:record_id -- another tenant's real record id and one that exists nowhere are the same bytes" do
      ctx_a = tenant_ctx("req310-inv5-put-a")
      ctx_b = tenant_ctx("req310-inv5-put-b")

      seed_active_definition!(ctx_a)
      seed_active_definition!(ctx_b)
      b_record = seed_record!(ctx_b)
      nowhere_id = Ecto.UUID.generate()

      body = %{"field_values" => %{"title" => "attempted"}}
      pinned = [trace_id: "req310-inv5-put-fixed-trace"]

      cross_tenant =
        request(
          :put,
          "/api/v1/entities/records/widget/#{b_record.record_id}",
          ctx_a,
          body,
          pinned
        )

      nonexistent =
        request(:put, "/api/v1/entities/records/widget/#{nowhere_id}", ctx_a, body, pinned)

      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}

      assert cross_tenant.status == 404
    end

    test "DELETE /records/:entity_type/:record_id -- same byte-identity" do
      ctx_a = tenant_ctx("req310-inv5-del-a")
      ctx_b = tenant_ctx("req310-inv5-del-b")

      seed_active_definition!(ctx_a)
      seed_active_definition!(ctx_b)
      b_record = seed_record!(ctx_b)
      nowhere_id = Ecto.UUID.generate()

      pinned = [trace_id: "req310-inv5-del-fixed-trace"]

      cross_tenant =
        request(
          :delete,
          "/api/v1/entities/records/widget/#{b_record.record_id}",
          ctx_a,
          nil,
          pinned
        )

      nonexistent =
        request(:delete, "/api/v1/entities/records/widget/#{nowhere_id}", ctx_a, nil, pinned)

      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}

      assert cross_tenant.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC6 -- INV-1: no caller-supplied tenant identifier is ever read.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC6 -- INV-1: tenant id / schema name / slug in body or query changes nothing" do
    test "a WRITE route ignores tenant_id, schema_name and slug in both body and query string" do
      ctx = tenant_ctx("req310-inv1-write")
      other = tenant_ctx("req310-inv1-write-other")

      clean = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert clean.status == 201
      clean_body = body_of(clean)

      # A second, structurally identical create in a SECOND tenant, this
      # time larded with every tenant-identifying field a caller could try,
      # naming the FIRST tenant. If any were read, this request would write
      # into (or read from) tenant one's schema.
      poisoned_body =
        definition_body(%{
          "tenant_id" => Ecto.UUID.generate(),
          "schema_name" => ctx.schema_name,
          "slug" => ctx.slug,
          "prefix" => ctx.schema_name
        })

      poisoned =
        request(
          :post,
          "/api/v1/entities/definitions?tenant_id=#{Ecto.UUID.generate()}" <>
            "&schema_name=#{ctx.schema_name}&slug=#{ctx.slug}&prefix=#{ctx.schema_name}",
          other,
          poisoned_body
        )

      assert poisoned.status == 201
      poisoned_body_out = body_of(poisoned)

      # Same status, same shape -- and the two rows are genuinely distinct
      # (each written into its OWN tenant's schema), which is what proves
      # the poisoned request did not follow the injected schema name.
      assert poisoned.status == clean.status
      assert poisoned_body_out["name"] == clean_body["name"]
      refute poisoned_body_out["id"] == clean_body["id"]

      # The poisoned request's row is NOT visible to the tenant it named.
      visible_to_named_tenant =
        request(:get, "/api/v1/entities/definitions/#{poisoned_body_out["id"]}", ctx)

      assert visible_to_named_tenant.status == 404
    end

    test "a READ route returns an identical response with and without tenant-identifying params" do
      ctx = tenant_ctx("req310-inv1-read")
      other = tenant_ctx("req310-inv1-read-other")
      seed_active_definition!(ctx)

      clean = request(:get, "/api/v1/entities/definitions/by-name/widget", ctx)

      poisoned =
        request(
          :get,
          "/api/v1/entities/definitions/by-name/widget?tenant_id=#{Ecto.UUID.generate()}" <>
            "&schema_name=#{other.schema_name}&slug=#{other.slug}&prefix=#{other.schema_name}",
          ctx
        )

      assert clean.status == 200
      assert {clean.status, clean.resp_body} == {poisoned.status, poisoned.resp_body}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC8 -- the mount reaches the router, not ApiPipeline's `match _` 404.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC8 -- forward(\"/entities\", to: Letflow.Routers.Entities) is live" do
    test "GET /api/v1/entities/definitions reaches the router (200), not ApiPipeline's catch-all" do
      ctx = tenant_ctx("req310-mount")

      conn = request(:get, "/api/v1/entities/definitions", ctx)

      # ApiPipeline's own `match _` would produce a 404 problem document with
      # no "items" key; a 200 with the list envelope can only come from the
      # forwarded router's own handler.
      assert conn.status == 200
      assert Map.has_key?(body_of(conn), "items")
    end

    test "an unrecognised path UNDER /entities reaches the ROUTER's own catch-all, still a 404" do
      ctx = tenant_ctx("req310-mount-catchall")

      conn = request(:get, "/api/v1/entities/no-such-thing", ctx)
      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC11 -- every error branch in design §7 is reachable at its designed
  # status.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC11 -- design §7 error mapping" do
    test "create_definition: {:validation, violations} -> 422 with a violation list" do
      ctx = tenant_ctx("req310-err-create-422")

      # A definition name violating Rule 1's ^[a-z][a-z0-9_]{0,63}$ format --
      # the validator's rule is on the DEFINITION's own name, not on a
      # field's, so this is what actually reaches {:validation, violations}.
      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "NOT A VALID NAME",
          "display_name" => "Widget",
          "fields" => [%{"name" => "title", "type" => "string"}]
        })

      assert conn.status == 422
      body = body_of(conn)
      assert is_list(body["errors"])
      assert body["errors"] != []
      assert Enum.all?(body["errors"], &Map.has_key?(&1, "code"))
    end

    test "create_definition: {:persistence, changeset} -> 409 on a duplicate name+shape" do
      ctx = tenant_ctx("req310-err-create-409")

      first = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert first.status == 201

      # Byte-identical resubmission: same name, same logical shape -> the
      # (tenant_id, name, logical_shape_version) UNIQUE constraint.
      second = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert second.status == 409
    end

    test "create_definition: a missing required body field -> RFC 9457 field errors, not a 500" do
      ctx = tenant_ctx("req310-err-create-fields")

      conn = request(:post, "/api/v1/entities/definitions", ctx, %{"display_name" => "Widget"})

      assert conn.status == 422
    end

    # ── REWORK ROUND 1, REVIEWER blocker 2 ──────────────────────────────
    #
    # `build_definition_document/1` used to wrap its whole body in a bare
    # `rescue` producing one detail-free 422 with NO `errors` key, because
    # `String.to_existing_atom/1` raises on a string that is not already an
    # atom in the VM. The measured consequence was an error contract that
    # varied with UNRELATED GLOBAL VM STATE: an unknown-atom typo got the
    # detail-free 422, while a typo that happened to collide with an atom
    # loaded by some other module survived conversion and got a proper
    # field error. These tests pin the contract to be the same either way.
    test "⛔ a bad field type produces the SAME well-formed error whether or not it is an existing atom" do
      ctx = tenant_ctx("req310-badtype-atom-parity")

      # "strng" is a typo no module in this application defines as an atom.
      # "ok" is an atom the VM has certainly loaded (it is in the stdlib's
      # own vocabulary) -- but it is NOT a member of Definition.field_type().
      # Under the old rescue these two took DIFFERENT paths. They must not.
      refute_existing_atom!("strng")
      assert :ok == String.to_existing_atom("ok")

      responses =
        for bad_type <- ["strng", "ok"] do
          conn =
            request(:post, "/api/v1/entities/definitions", ctx, %{
              "name" => "widget",
              "display_name" => "Widget",
              "fields" => [%{"name" => "title", "type" => bad_type}]
            })

          {bad_type, conn}
        end

      for {bad_type, conn} <- responses do
        assert conn.status == 422, "type #{inspect(bad_type)} returned #{conn.status}"

        body = body_of(conn)

        # The load-bearing assertion: an `errors` array in BOTH cases. The
        # old code produced this for "ok" and omitted it entirely for
        # "strng".
        assert is_list(body["errors"]) and body["errors"] != [],
               "type #{inspect(bad_type)} produced a detail-free 422: #{conn.resp_body}"

        assert Enum.any?(body["errors"], &(&1["code"] == "malformed")),
               "type #{inspect(bad_type)} errors: #{inspect(body["errors"])}"

        assert Enum.any?(body["errors"], &String.contains?(&1["message"] || "", "field type")),
               "type #{inspect(bad_type)} errors: #{inspect(body["errors"])}"
      end

      # And, stated directly: the two responses are the same document
      # modulo the per-request trace id, which is what "independent of VM
      # atom state" actually means.
      [{_, strng_conn}, {_, ok_conn}] = responses

      assert normalise_problem(strng_conn) == normalise_problem(ok_conn)
    end

    test "a bad search_strategy string is rejected by name, not by a detail-free 422" do
      ctx = tenant_ctx("req310-bad-search-strategy")
      refute_existing_atom!("fulltxt")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => [
            %{
              "name" => "title",
              "type" => "localized_text",
              "locales" => ["en"],
              "search_strategy" => "fulltxt"
            }
          ]
        })

      assert conn.status == 422
      body = body_of(conn)

      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(body["errors"], &(&1["code"] == "invalid_search_strategy")),
             inspect(body["errors"])
    end

    test "a bad constraint type string is rejected by name, not by a detail-free 422" do
      ctx = tenant_ctx("req310-bad-constraint-type")
      refute_existing_atom!("uniqe")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => [%{"name" => "title", "type" => "string"}],
          "constraints" => [%{"name" => "c1", "type" => "uniqe", "fields" => ["title"]}]
        })

      assert conn.status == 422
      body = body_of(conn)

      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(body["errors"], &String.contains?(&1["message"] || "", "constraint type")),
             inspect(body["errors"])
    end

    test "a structural malformation -- \"fields\": [\"not-a-map\"] -- reaches the caller WITH a field error" do
      ctx = tenant_ctx("req310-fields-not-a-map")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => ["not-a-map"]
        })

      assert conn.status == 422
      body = body_of(conn)

      # Under the old rescue this raised inside Enum.map/2 and collapsed to
      # a 422 with no `errors` key. The Validator's own
      # check_required_list_of_maps/3 has always had a precise violation
      # for it -- the rescue was simply intercepting it first.
      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(
               body["errors"],
               &String.contains?(&1["message"] || "", "must all be maps")
             ),
             inspect(body["errors"])
    end

    test "a field object missing \"name\" entirely reaches the caller WITH a field error" do
      ctx = tenant_ctx("req310-field-missing-name")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => [%{"type" => "string"}]
        })

      assert conn.status == 422
      body = body_of(conn)

      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(body["errors"], &String.contains?(&1["message"] || "", "field name")),
             inspect(body["errors"])
    end

    test "a non-map entry inside \"indexes\"/\"foreign_keys\"/\"constraints\" also carries a field error" do
      ctx = tenant_ctx("req310-nonmap-optional-lists")

      for key <- ["indexes", "foreign_keys", "constraints"] do
        conn =
          request(:post, "/api/v1/entities/definitions", ctx, %{
            "name" => "widget",
            "display_name" => "Widget",
            "fields" => [%{"name" => "title", "type" => "string"}],
            key => ["not-a-map"]
          })

        assert conn.status == 422, "#{key} returned #{conn.status}"

        assert is_list(body_of(conn)["errors"]) and body_of(conn)["errors"] != [],
               "#{key} produced a detail-free 422: #{conn.resp_body}"
      end
    end

    test "the three getters: {:error, :not_found} -> 404" do
      ctx = tenant_ctx("req310-err-getters-404")

      assert request(:get, "/api/v1/entities/definitions/#{Ecto.UUID.generate()}", ctx).status ==
               404

      assert request(:get, "/api/v1/entities/definitions/active/nope", ctx).status == 404
      assert request(:get, "/api/v1/entities/definitions/by-name/nope", ctx).status == 404
    end

    test "list_definitions: an out-of-range page_size -> 400" do
      ctx = tenant_ctx("req310-err-list-400")

      # Non-numeric -> the router's own parse rejection.
      assert request(:get, "/api/v1/entities/definitions?page_size=abc", ctx).status == 400
      # Numeric but out of range -> list_definitions/2's own
      # :page_size_too_large, mapped to 400 per design §7.
      assert request(:get, "/api/v1/entities/definitions?page_size=100000", ctx).status == 400
    end

    test "list_definitions: an unparseable cursor -> 400" do
      ctx = tenant_ctx("req310-err-list-cursor")

      conn = request(:get, "/api/v1/entities/definitions?cursor=not-a-real-cursor", ctx)
      assert conn.status == 400
    end

    # ── REWORK ROUND 1, REVIEWER blocker 1 ──────────────────────────────
    #
    # The bug these three tests pin: `rationale` was declared
    # `required: false` while every layer below rejects a blank one, so a
    # request the API contract called LEGAL (rationale omitted) failed --
    # and failed OPAQUELY, through the {_tag, %Ecto.Changeset{}} arm's
    # generic "entity definition could not be activated" 422 with no
    # `errors` key, logged as an activation failure rather than a
    # validation one. Every pre-existing activate test above sends
    # "rationale", which is exactly why the gap shipped green.
    test "activate_definition: rationale OMITTED -> 422 RFC 9457 field errors NAMING rationale" do
      ctx = tenant_ctx("req310-activate-no-rationale")
      seed_definition_only!(ctx)

      conn = request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{})

      assert conn.status == 422
      body = body_of(conn)

      # ⛔ The load-bearing half: an `errors` array naming the field. The
      # old default-to-"" path produced a 422 with NO `errors` key at all,
      # so asserting only on the status would still pass against the bug.
      assert is_list(body["errors"])

      assert Enum.any?(body["errors"], &(&1["field"] == "rationale")),
             "expected a field error naming `rationale`, got: #{inspect(body["errors"])}"

      assert Enum.any?(body["errors"], &(&1["constraint"] == "required"))

      # And the definition genuinely did NOT activate.
      assert request(:get, "/api/v1/entities/definitions/active/widget", ctx).status == 404
    end

    test "activate_definition: a body with NO rationale key takes the same path as an empty object" do
      ctx = tenant_ctx("req310-activate-rationale-other-keys")
      seed_definition_only!(ctx)

      # A non-empty body that simply omits `rationale` -- proving the
      # rejection is about the missing field, not about an empty body.
      conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "note" => "not a rationale"
        })

      assert conn.status == 422
      assert Enum.any?(body_of(conn)["errors"], &(&1["field"] == "rationale"))
    end

    test "activate_definition: a blank/whitespace-only rationale is rejected HERE, not three layers down" do
      ctx = tenant_ctx("req310-activate-blank-rationale")
      seed_definition_only!(ctx)

      for blank <- ["", "   "] do
        conn =
          request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
            "rationale" => blank
          })

        assert conn.status == 422,
               "rationale #{inspect(blank)} returned #{conn.status}"

        body = body_of(conn)

        # The distinguishing assertion: a FIELD error naming rationale,
        # not the delegate's opaque "could not be activated" collapse.
        assert is_list(body["errors"]),
               "rationale #{inspect(blank)} produced a detail-free 422: #{conn.resp_body}"

        assert Enum.any?(body["errors"], &(&1["field"] == "rationale"))
      end
    end

    test "activate_definition: a non-blank rationale still activates -- the fix did not break the legal path" do
      ctx = tenant_ctx("req310-activate-with-rationale")
      seed_definition_only!(ctx)

      conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "rationale" => "r"
        })

      assert conn.status == 200
      assert body_of(conn)["status"] == "active"
    end

    test "activate_definition: :not_found -> 404" do
      ctx = tenant_ctx("req310-err-activate-404")

      conn =
        request(:post, "/api/v1/entities/definitions/never-created/activate", ctx, %{
          "rationale" => "x"
        })

      assert conn.status == 404
    end

    test "Records.command_error(): {:definition_not_found, _} -> 404" do
      ctx = tenant_ctx("req310-err-rec-defnotfound")

      conn =
        request(:post, "/api/v1/entities/records/no-such-type", ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert conn.status == 404
    end

    test "Records.command_error(): {:record_payload_invalid, violations} -> 422" do
      ctx = tenant_ctx("req310-err-rec-422")
      seed_active_definition!(ctx)

      # "title" is required: true in the seeded definition.
      conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"quantity" => 1}
        })

      assert conn.status == 422
      body = body_of(conn)
      assert is_list(body["errors"])
      assert body["errors"] != []
    end

    test "Records.command_error(): {:record_not_found, _} -> 404 on update and delete" do
      ctx = tenant_ctx("req310-err-rec-404")
      seed_active_definition!(ctx)
      missing = Ecto.UUID.generate()

      assert request(:put, "/api/v1/entities/records/widget/#{missing}", ctx, %{
               "field_values" => %{"title" => "x"}
             }).status == 404

      assert request(:delete, "/api/v1/entities/records/widget/#{missing}", ctx).status == 404
    end

    test "update_record: {:record_already_deleted, _} -> 409" do
      ctx = tenant_ctx("req310-err-rec-409")
      seed_active_definition!(ctx)
      record = seed_record!(ctx)

      assert request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx).status ==
               200

      conn =
        request(:put, "/api/v1/entities/records/widget/#{record.record_id}", ctx, %{
          "field_values" => %{"title" => "resurrect"}
        })

      assert conn.status == 409
    end

    test "delete_record: deleting an already-deleted record is a no-op 200, not a 409" do
      ctx = tenant_ctx("req310-err-rec-delete-idempotent")
      seed_active_definition!(ctx)
      record = seed_record!(ctx)

      assert request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx).status ==
               200

      second = request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx)
      assert second.status == 200
      assert body_of(second)["deleted"] == true
    end
  end
end
