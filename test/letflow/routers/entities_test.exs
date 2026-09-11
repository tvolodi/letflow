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

  # REQ-311: only for the ColumnPromotion cleanup in promote_and_create_table!/5
  # below. No test in this file issues a query of its own -- every read and
  # write goes through a context module or through the HTTP routes themselves.
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

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
      # REQ-311 added `tenant_id` (needed by
      # TenantProvisioning.register_column_promotion/4, which the join tests
      # use to create real per-entity-type tables) and `tenant` (needed by
      # the INV-5 cross-tenant test, which mints a SECOND credential against
      # an existing tenant).
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  # A SECOND credential for a tenant that already exists, belonging to a
  # DIFFERENT user in the same schema. REQ-311's INV-1 two-user test needs
  # two callers whose `user_entity_grants` rows differ while every other
  # input -- the request body included -- is byte-identical.
  defp second_user_ctx(ctx, roles \\ ["PLATFORM_ADMIN"]) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req311-user2-#{Ecto.UUID.generate()}",
        display_name: "REQ-311 Second User",
        email: "req311-2-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    %{ctx | plaintext: plaintext, user_id: user.id}
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
    # REQ-311 raised this from nine to TEN: the tenth is POST /query, and
    # the count is asserted explicitly so appending an eleventh route
    # without updating design §1's table fails here rather than silently.
    test "__authz_routes__/0 returns exactly the ten designed routes, with their designed policy keys" do
      expected = [
        {"POST", "/definitions/:name/activate", :EntitiesDefinitionsWrite},
        {"POST", "/definitions", :EntitiesDefinitionsWrite},
        {"GET", "/definitions/active/:name", :EntitiesDefinitionsRead},
        {"GET", "/definitions/by-name/:name", :EntitiesDefinitionsRead},
        {"GET", "/definitions/:id", :EntitiesDefinitionsRead},
        {"GET", "/definitions", :EntitiesDefinitionsRead},
        {"POST", "/records/:entity_type", :EntitiesRecordsWrite},
        {"PUT", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
        {"DELETE", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
        {"POST", "/query", :EntitiesQuery}
      ]

      actual = Letflow.Routers.Entities.__authz_routes__()

      assert length(actual) == 10
      assert Enum.sort(actual) == Enum.sort(expected)
      assert {"POST", "/query", :EntitiesQuery} in actual
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

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-311 -- POST /entities/query.
  #
  # Fixture helpers below mirror test/letflow/entities/query_joins_test.exs's
  # own (that file is the REQ-300 join suite these routes now front) -- real
  # per-entity-type tables via the real REQ-297 column-promotion mechanism,
  # real entity_field_restrictions/user_entity_grants rows. Nothing is mocked.
  # ═══════════════════════════════════════════════════════════════════════

  defp query(ctx, body, opts \\ []),
    do: request(:post, "/api/v1/entities/query", ctx, body, opts)

  # The "widget" definition the query tests use. Deliberately NOT
  # `seed_active_definition!/2` above (which REQ-310's own route tests share):
  # this one marks both fields `queried: true`, which is what puts them on
  # `Allowlist.load/2`'s output at all. Using the shared fixture here would
  # make every filter in this block fail as {:field_not_allowed, _} and
  # silently stop testing whatever it was written to test, while changing the
  # shared fixture would perturb REQ-310's nine route tests.
  defp seed_queryable_widget!(ctx) do
    create_active_definition!(ctx, %{
      name: "widget",
      display_name: "Widget",
      fields: [
        %{name: "title", type: :string, queried: true},
        %{name: "quantity", type: :integer, queried: true}
      ]
    })
  end

  defp create_active_definition!(ctx, definition) do
    {:ok, entity_definition} =
      Definitions.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "req311 go-live",
        ctx.schema_name
      )

    activated
  end

  # Promotes one attribute for `entity_type`, creating that entity type's own
  # per-entity-type table on the first promotion -- the real REQ-297 path.
  #
  # ⛔ Registers its OWN on_exit to delete this tenant's `entity_column_promotions`
  # rows. `Letflow.TenantFixture`'s shared teardown deletes the schema, the
  # Registration and the Tenant, but NOT ColumnPromotion rows -- nothing had
  # created any before REQ-311, since none of REQ-310's nine routes promotes a
  # column. Without this, the tenant delete fails on
  # `entity_column_promotions_tenant_id_fkey` and every join test in this file
  # fails in teardown even when its body passed.
  #
  # ExUnit runs on_exit callbacks LIFO, and this one is registered strictly
  # after `provisioned_tenant!/1`'s (a promotion can only happen once a tenant
  # exists), so it runs BEFORE the tenant delete -- which is the order the FK
  # requires. `test/letflow/entities/query_joins_test.exs` does the same
  # cleanup inline in its own hand-rolled tenant fixture.
  defp promote_and_create_table!(ctx, entity_type, attribute, pg_type, opts \\ []) do
    references_entity = Keyword.get(opts, :references_entity)

    on_exit(fn ->
      Repo.delete_all(
        from(cp in Letflow.TenantProvisioning.ColumnPromotion,
          where: cp.tenant_id == ^ctx.tenant_id
        )
      )
    end)

    column_spec =
      if references_entity do
        %{pg_type: pg_type, nullable: true, references_entity: references_entity}
      else
        %{pg_type: pg_type, nullable: true}
      end

    {:ok, [row]} =
      TenantProvisioning.register_column_promotion(
        entity_type,
        attribute,
        column_spec,
        [ctx.tenant_id]
      )

    {:ok, %{status: "ddl_applied"}} = TenantProvisioning.run_column_promotion(row.id)
    :ok
  end

  defp insert_field_restriction!(ctx, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp insert_user_grant!(ctx, user_id, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  # The redaction sentinel as it appears ON THE WIRE. `FieldGrants`' sentinel
  # is the ATOM `:__field_redacted__` (deliberately an atom, so it cannot
  # collide with any JSON-decoded value -- that module's own moduledoc);
  # Jason encodes an atom as its string name, so a decoded response body
  # carries `"__field_redacted__"`. Derived from `redacted_sentinel/0` rather
  # than hardcoded, so renaming the sentinel cannot leave these tests
  # asserting a stale literal that no longer means "redacted".
  defp wire_sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

  # The design's own worked join example: "question" <- "answer_option", the
  # far side carrying BOTH a restricted field and an unrestricted one, so a
  # far-side redaction test can prove redaction happened AND that it was
  # selective.
  defp seed_join_fixture!(ctx) do
    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "question", "stem", "text")

    create_active_definition!(ctx, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "text", type: :string, queried: true},
        %{name: "secret_note", type: :string, queried: true},
        %{name: "question_id", type: :string}
      ],
      foreign_keys: [
        %{name: "question_fk", field: "question_id", references_entity: "question"}
      ]
    })

    promote_and_create_table!(ctx, "answer_option", "question_id", "uuid",
      references_entity: "question"
    )

    :ok
  end

  defp seed_query_record!(ctx, entity_type, field_values) do
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

  # ═══════════════════════════════════════════════════════════════════════
  # ⛔ AC1/AC2/AC3 -- THE JOIN-BEARING REDACTION BRANCH.
  #
  # This is the block SECURITY-REVIEWER's verdict on design §11 exists for:
  # "it would be easy to implement only the simpler branch and let it
  # silently under-redact joined reads." A handler that called
  # redact_page/2 (or nothing) on a joined result would return the far-side
  # entity's restricted field IN CLEAR and still pass every non-join test in
  # this file.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC1 -- a JOINED far-side entity's restricted field is redacted" do
    test "⛔ far-side restricted field -> sentinel, AND an unrestricted far-side field on the SAME row keeps its real value" do
      ctx = tenant_ctx("req311-join-redact")
      seed_join_fixture!(ctx)

      # The restriction is on the FAR side of the join ("answer_option"),
      # NOT on the primary ("question"). The querying user holds no
      # user_entity_grants row for it, so it is in their redaction set for
      # that entity type -- reachable ONLY through redact_joined_page/2's
      # "answer_option"-keyed restriction set.
      insert_field_restriction!(ctx, "answer_option", "secret_note")

      q = seed_query_record!(ctx, "question", %{"stem" => "2 + 2 = ?"})

      seed_query_record!(ctx, "answer_option", %{
        "text" => "4",
        "secret_note" => "THE ANSWER IS FOUR",
        "question_id" => q.record_id
      })

      conn =
        query(ctx, %{
          "entity_type" => "question",
          "filters" => [%{"field" => "stem", "op" => "eq", "value" => "2 + 2 = ?"}],
          "join" => [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]

      far_side = item["answer_option"]

      # HALF 1 -- the restricted far-side field IS redacted.
      assert far_side["field_values"]["secret_note"] == wire_sentinel()
      refute far_side["field_values"]["secret_note"] == "THE ANSWER IS FOUR"

      # HALF 2 -- an UNRESTRICTED far-side field on the SAME row keeps its
      # real value. Without this, the test would pass just as well against a
      # handler that redacted every field of everything.
      assert far_side["field_values"]["text"] == "4"

      # And the primary side, which has no restrictions at all, is untouched.
      assert item["primary"]["field_values"]["stem"] == "2 + 2 = ?"
    end

    test "a far-side restricted field the user DOES hold a grant for is NOT redacted -- proving the grant, not the join, decides" do
      ctx = tenant_ctx("req311-join-granted")
      seed_join_fixture!(ctx)

      insert_field_restriction!(ctx, "answer_option", "secret_note")
      insert_user_grant!(ctx, ctx.user_id, "answer_option", "secret_note")

      q = seed_query_record!(ctx, "question", %{"stem" => "granted?"})

      seed_query_record!(ctx, "answer_option", %{
        "text" => "yes",
        "secret_note" => "VISIBLE TO THE GRANT HOLDER",
        "question_id" => q.record_id
      })

      conn =
        query(ctx, %{
          "entity_type" => "question",
          "join" => [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["answer_option"]["field_values"]["secret_note"] == "VISIBLE TO THE GRANT HOLDER"
    end
  end

  describe "REQ-311 AC2 -- the two redaction branches are actually distinct" do
    test "a join-bearing and a non-join request over the same entity type both succeed, and only the join-bearing one carries the joined key" do
      ctx = tenant_ctx("req311-two-branches")
      seed_join_fixture!(ctx)

      insert_field_restriction!(ctx, "question", "stem")
      insert_field_restriction!(ctx, "answer_option", "secret_note")

      q = seed_query_record!(ctx, "question", %{"stem" => "shared question"})

      seed_query_record!(ctx, "answer_option", %{
        "text" => "an option",
        "secret_note" => "hidden",
        "question_id" => q.record_id
      })

      # Branch A -- no join: items are flat entity rows, redact_page/2's
      # shape. A "primary"/"answer_option" key here would mean the joined
      # shape leaked into the non-join path.
      plain = query(ctx, %{"entity_type" => "question"})
      assert plain.status == 200
      assert [plain_item] = body_of(plain)["items"]
      refute Map.has_key?(plain_item, "primary")
      refute Map.has_key?(plain_item, "answer_option")
      assert plain_item["field_values"]["stem"] == wire_sentinel()

      # Branch B -- join-bearing: items ARE the joined shape. The presence of
      # the "answer_option" key is what proves redact_joined_page/2 ran:
      # redact_page/2 on this page would have crashed or passed the joined
      # rows through unredacted, and a redact_page/2-shaped result carries no
      # per-entity keys at all.
      joined =
        query(ctx, %{
          "entity_type" => "question",
          "join" => [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
        })

      assert joined.status == 200
      assert [joined_item] = body_of(joined)["items"]
      assert Map.has_key?(joined_item, "primary")
      assert Map.has_key?(joined_item, "answer_option")

      # BOTH sides redacted, each by its OWN entity type's restriction set.
      assert joined_item["primary"]["field_values"]["stem"] == wire_sentinel()
      assert joined_item["answer_option"]["field_values"]["secret_note"] == wire_sentinel()
      assert joined_item["answer_option"]["field_values"]["text"] == "an option"
    end
  end

  describe "REQ-311 -- the NON-join branch redacts BOTH of its own item shapes" do
    # Regression test for a pre-existing gap this route is the first caller to
    # reach: FieldGrants.redact_page/2's private redact_item/2 matches
    # %Latest{} only, but Compiler.compile_plain/5 emits a plain
    # Compiler.entity_row() MAP whenever the entity type has a promoted
    # per-entity-type table. Before the router's own redact_plain_page/2, a
    # non-join query against a PROMOTED entity type raised
    # FunctionClauseError -> 500. Flagged for REVIEWER; the fix lives in the
    # router because REQ-311's scope fence forbids touching
    # lib/letflow/entities/.
    test "a non-join query against a PROMOTED entity type (entity_row() map items, not %Latest{}) still redacts" do
      ctx = tenant_ctx("req311-promoted-plain")
      seed_join_fixture!(ctx)

      insert_field_restriction!(ctx, "question", "stem")
      seed_query_record!(ctx, "question", %{"stem" => "CLEARTEXT STEM"})

      conn = query(ctx, %{"entity_type" => "question"})

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["stem"] == wire_sentinel()
      refute item["field_values"]["stem"] == "CLEARTEXT STEM"
    end

    test "a non-join query against an UNPROMOTED entity type (%Latest{} items) still redacts" do
      ctx = tenant_ctx("req311-unpromoted-plain")
      seed_queryable_widget!(ctx)

      insert_field_restriction!(ctx, "widget", "title")
      seed_record!(ctx, "widget", %{"title" => "CLEARTEXT TITLE"})

      conn = query(ctx, %{"entity_type" => "widget"})

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["title"] == wire_sentinel()
    end

    test "record_id is the SAME canonical UUID-string form on both shapes -- a promotion is not observable in a response body" do
      promoted = tenant_ctx("req311-rid-promoted")
      seed_join_fixture!(promoted)
      seeded = seed_query_record!(promoted, "question", %{"stem" => "x"})

      unpromoted = tenant_ctx("req311-rid-unpromoted")
      seed_queryable_widget!(unpromoted)
      seed_record!(unpromoted, "widget", %{"title" => "y"})

      assert [p_item] = body_of(query(promoted, %{"entity_type" => "question"}))["items"]
      assert [u_item] = body_of(query(unpromoted, %{"entity_type" => "widget"}))["items"]

      # The promoted binding reads record_id back as a raw 16-byte binary;
      # both must reach the wire as the canonical string form.
      assert p_item["record_id"] == seeded.record_id
      assert {:ok, _} = Ecto.UUID.cast(p_item["record_id"])
      assert {:ok, _} = Ecto.UUID.cast(u_item["record_id"])
    end
  end

  describe "REQ-311 AC3 -- the restriction_sets map excludes the `through` entity's type" do
    test "a many-to-many query through a join entity returns rows keyed :primary + the joined type only, never the through type" do
      ctx = tenant_ctx("req311-through")

      create_active_definition!(ctx, %{
        name: "topic",
        display_name: "Topic",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      promote_and_create_table!(ctx, "topic", "stem", "text")

      create_active_definition!(ctx, %{
        name: "label",
        display_name: "Label",
        fields: [%{name: "caption", type: :string, queried: true}]
      })

      promote_and_create_table!(ctx, "label", "caption", "text")

      create_active_definition!(ctx, %{
        name: "topic_labels",
        display_name: "Topic Labels",
        fields: [
          %{name: "topic_id", type: :string},
          %{name: "label_id", type: :string}
        ],
        foreign_keys: [
          %{name: "fk_topic", field: "topic_id", references_entity: "topic"},
          %{name: "fk_label", field: "label_id", references_entity: "label"}
        ]
      })

      promote_and_create_table!(ctx, "topic_labels", "topic_id", "uuid",
        references_entity: "topic"
      )

      promote_and_create_table!(ctx, "topic_labels", "label_id", "uuid",
        references_entity: "label"
      )

      # ⛔ THE TRAP THIS TEST GUARDS: a restriction row on the THROUGH entity.
      # If the handler wrongly keyed a restriction set by the through
      # entity's type, this row would be loaded for a key no joined row
      # carries -- harmless-looking. The real defect it flags is the
      # converse: a through-keyed set means the implementer mis-derived the
      # key list, and the same mis-derivation omits or misnames a key that IS
      # exposed, which Map.fetch!/2 turns into a 500.
      insert_field_restriction!(ctx, "topic_labels", "topic_id")

      t = seed_query_record!(ctx, "topic", %{"stem" => "linked topic"})
      l = seed_query_record!(ctx, "label", %{"caption" => "math"})

      seed_query_record!(ctx, "topic_labels", %{
        "topic_id" => t.record_id,
        "label_id" => l.record_id
      })

      conn =
        query(ctx, %{
          "entity_type" => "topic",
          "filters" => [%{"field" => "stem", "op" => "eq", "value" => "linked topic"}],
          "join" => [
            %{"entity_type" => "label", "through" => "topic_labels", "fk" => "fk_label"}
          ]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]

      # The row's key set is EXACTLY :primary + the joined type. The through
      # entity is absent -- its row is never exposed, so no restriction set
      # is keyed for it either.
      assert MapSet.new(Map.keys(item)) == MapSet.new(["primary", "label"])
      refute Map.has_key?(item, "topic_labels")

      assert item["primary"]["field_values"]["stem"] == "linked topic"
      assert item["label"]["field_values"]["caption"] == "math"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 -- the 400-vs-422 error-class split (design §4).
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC4 -- 400 for a malformed literal, 422 for a semantic rejection" do
    setup do
      ctx = tenant_ctx("req311-400-422")
      seed_queryable_widget!(ctx)
      %{ctx: ctx}
    end

    test "400: an unrecognised filter \"op\" string -- Types.parse_filter_op/1 rejects it BEFORE compile/2",
         %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "SQUIGGLE", "value" => "x"}]
        })

      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "SQUIGGLE"
    end

    test "400: an unrecognised sort \"dir\" string -- Types.parse_sort_dir/1 rejects it BEFORE compile/2",
         %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "sort" => [%{"field" => "title", "dir" => "sideways"}]
        })

      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "sideways"
    end

    test "422: a filter naming a field absent from the allowlist -- well-formed, semantically rejected",
         %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "no_such_field", "op" => "eq", "value" => "x"}]
        })

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "no_such_field"
    end

    test "422: an :in filter whose value is not a list", %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "in", "value" => "not-a-list"}]
        })

      assert conn.status == 422
    end

    # The pre-parsing is what makes these two DIFFERENT statuses. A handler
    # that skipped it and let compile/2 reject the operator would answer 422
    # to both -- asserted as one comparison so the distinction cannot be lost
    # by editing either test above alone.
    test "the two classes are genuinely different statuses for the same field", %{ctx: ctx} do
      bad_literal =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "SQUIGGLE", "value" => "x"}]
        })

      bad_semantics =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "nope", "op" => "eq", "value" => "x"}]
        })

      assert {bad_literal.status, bad_semantics.status} == {400, 422}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 -- every caller-reachable compile_error() member maps to its
  # design-§4 status.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC5 -- compile_error() members map to design §4's statuses" do
    test ":entity_type_not_found -> 404" do
      ctx = tenant_ctx("req311-ce-404")
      conn = query(ctx, %{"entity_type" => "no-such-entity-type"})
      assert conn.status == 404
    end

    test "{:field_not_allowed, _} -> 422" do
      ctx = tenant_ctx("req311-ce-fna")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "unknown", "op" => "eq", "value" => 1}]
        })

      assert conn.status == 422
    end

    test "{:value_arity_mismatch, _} -> 422 (an :eq clause with no value at all)" do
      ctx = tenant_ctx("req311-ce-arity")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "eq"}]
        })

      assert conn.status == 422
    end

    test "{:invalid_in_value, _} -> 422" do
      ctx = tenant_ctx("req311-ce-in")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "not_in", "value" => 7}]
        })

      assert conn.status == 422
    end

    test "{:operator_not_valid_for_type, _, _} -> 422 (a :contains on an integer field)" do
      ctx = tenant_ctx("req311-ce-optype")

      create_active_definition!(ctx, %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "quantity", type: :integer, queried: true}]
      })

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "quantity", "op" => "contains", "value" => "3"}]
        })

      assert conn.status == 422
    end

    test "{:too_many_joins, _} -> 422 (five joins exceeds Compiler's @max_joins of four)" do
      ctx = tenant_ctx("req311-ce-joins")
      seed_queryable_widget!(ctx)

      joins =
        for n <- 1..5, do: %{"entity_type" => "other_#{n}", "fk" => "fk_#{n}"}

      conn = query(ctx, %{"entity_type" => "widget", "join" => joins})

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "5"
    end

    test "{:duplicate_join_target, _} -> 422" do
      ctx = tenant_ctx("req311-ce-dup")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "join" => [
            %{"entity_type" => "answer_option", "fk" => "a"},
            %{"entity_type" => "answer_option", "fk" => "b"}
          ]
        })

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "answer_option"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC6 -- Cursor.paginate/5's own error union.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC6 -- Cursor.paginate/5's error union maps per design §4" do
    setup do
      ctx = tenant_ctx("req311-cursor")
      seed_queryable_widget!(ctx)
      seed_record!(ctx)
      %{ctx: ctx}
    end

    test ":page_size_too_large -> 400", %{ctx: ctx} do
      conn = query(ctx, %{"entity_type" => "widget", "page_size" => 100_000})
      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "page_size"
    end

    test ":invalid_cursor -> 400", %{ctx: ctx} do
      conn = query(ctx, %{"entity_type" => "widget", "cursor" => "not-a-real-cursor"})
      assert conn.status == 400
    end

    test ":wrong_endpoint -> 400 (a well-formed cursor minted for a DIFFERENT endpoint)", %{
      ctx: ctx
    } do
      # Structurally valid and unexpired -- it differs from this endpoint's
      # own cursors ONLY in its prefix literal, which is exactly what
      # Pagination.decode_cursor/4's prefix check exists to catch.
      foreign_cursor = mint_cursor("DEF:", System.system_time(:microsecond), [])

      conn = query(ctx, %{"entity_type" => "widget", "cursor" => foreign_cursor})

      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "endpoint"
    end

    test ":expired -> the dedicated cursor-expired PROBLEM DOCUMENT, not merely a status", %{
      ctx: ctx
    } do
      # This endpoint's own prefix, but minted a year ago -- so it passes the
      # prefix check and fails the expiry check, isolating :expired from
      # :wrong_endpoint and :invalid_cursor.
      year_ago_us = System.system_time(:microsecond) - 365 * 24 * 60 * 60 * 1_000_000

      expired_cursor = mint_cursor(Cursor.cursor_prefix(), year_ago_us, [0])

      conn = query(ctx, %{"entity_type" => "widget", "cursor" => expired_cursor})

      body = body_of(conn)
      expected = Letflow.Api.Error.cursor_expired()

      # Asserted on the problem document's own type/status members -- the
      # dedicated Error.cursor_expired() path -- not just on conn.status,
      # which a generic bad_request would also satisfy.
      assert body["type"] == expected.type
      assert body["status"] == expected.status
      assert conn.status == expected.status
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC7 -- the success envelope, and real cursor paging.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC7 -- response envelope is exactly {items, next_cursor}" do
    test "the decoded body's KEY SET is exactly [\"items\", \"next_cursor\"] -- no \"count\" key" do
      ctx = tenant_ctx("req311-envelope")
      seed_queryable_widget!(ctx)
      seed_record!(ctx)

      conn = query(ctx, %{"entity_type" => "widget"})

      assert conn.status == 200
      assert MapSet.new(Map.keys(body_of(conn))) == MapSet.new(["items", "next_cursor"])
      refute Map.has_key?(body_of(conn), "count")
    end

    test "paging with the returned next_cursor walks two pages and the final page's next_cursor is null" do
      ctx = tenant_ctx("req311-paging")
      seed_queryable_widget!(ctx)

      for n <- 1..3, do: seed_record!(ctx, "widget", %{"title" => "row-#{n}"})

      page1 = query(ctx, %{"entity_type" => "widget", "page_size" => 2})
      assert page1.status == 200
      body1 = body_of(page1)
      assert length(body1["items"]) == 2
      assert is_binary(body1["next_cursor"])

      page2 =
        query(ctx, %{
          "entity_type" => "widget",
          "page_size" => 2,
          "cursor" => body1["next_cursor"]
        })

      assert page2.status == 200
      body2 = body_of(page2)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      # Every seeded row was seen exactly once across the two pages.
      ids = Enum.map(body1["items"] ++ body2["items"], & &1["record_id"])
      assert length(Enum.uniq(ids)) == 3
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC8 -- INV-1: nothing tenant- or identity-bearing comes from the body.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC8 -- INV-1: prefix and user_id are server-resolved only" do
    test "tenant_id/schema/slug sent as BODY FIELDS change nothing -- the response is identical to the same request without them" do
      ctx = tenant_ctx("req311-inv1-body")
      seed_queryable_widget!(ctx)
      seed_record!(ctx, "widget", %{"title" => "only row"})

      trace = "req311-inv1-#{Ecto.UUID.generate()}"

      clean = query(ctx, %{"entity_type" => "widget"}, trace_id: trace)

      spoofed =
        query(
          ctx,
          %{
            "entity_type" => "widget",
            "tenant_id" => Ecto.UUID.generate(),
            "schema" => "some_other_tenant_schema",
            "slug" => "some-other-tenant",
            "prefix" => "public",
            "user_id" => Ecto.UUID.generate()
          },
          trace_id: trace
        )

      assert clean.status == 200
      assert spoofed.status == 200
      assert spoofed.resp_body == clean.resp_body
    end

    test "the user_id used for redaction is the AUTHENTICATED caller's -- the SAME body from two users with different grants is redacted differently" do
      ctx = tenant_ctx("req311-inv1-users")
      seed_queryable_widget!(ctx)

      insert_field_restriction!(ctx, "widget", "title")

      # User 1 holds a grant for the restricted field; user 2 does not.
      insert_user_grant!(ctx, ctx.user_id, "widget", "title")
      other = second_user_ctx(ctx)

      seed_record!(ctx, "widget", %{"title" => "CLEARTEXT TITLE"})

      body = %{"entity_type" => "widget"}

      granted = query(ctx, body)
      ungranted = query(other, body)

      assert granted.status == 200
      assert ungranted.status == 200

      assert [granted_item] = body_of(granted)["items"]
      assert [ungranted_item] = body_of(ungranted)["items"]

      assert granted_item["field_values"]["title"] == "CLEARTEXT TITLE"
      assert ungranted_item["field_values"]["title"] == wire_sentinel()

      # The one identical body producing two different bodies is the proof
      # that user_id came from the credential, not the request.
      refute granted.resp_body == ungranted.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC9 -- INV-5: cross-tenant and nonexistent are the same bytes.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC9 -- INV-5: a cross-tenant entity type is byte-identical to a nonexistent one" do
    test "an entity_type that exists only in ANOTHER tenant's schema produces the same bytes as one that exists nowhere" do
      ctx = tenant_ctx("req311-inv5-a")
      other_tenant = tenant_ctx("req311-inv5-b")

      # "hidden_type" is a real, active entity type -- in the OTHER tenant's
      # schema only. The caller below is scoped to their own schema, where it
      # does not exist.
      create_active_definition!(other_tenant, %{
        name: "hidden_type",
        display_name: "Hidden Type",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      trace = "req311-inv5-#{Ecto.UUID.generate()}"

      cross_tenant = query(ctx, %{"entity_type" => "hidden_type"}, trace_id: trace)
      nonexistent = query(ctx, %{"entity_type" => "absolutely_no_such_type"}, trace_id: trace)

      assert cross_tenant.status == 404

      # ONE assertion comparing the whole documents -- not two separate
      # "both are 404" assertions, which would pass even if the bodies
      # differed and leaked existence.
      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC10 -- authorization: the route is really gated by :EntitiesQuery.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC10 -- the route is gated by a real, enforced :EntitiesQuery clause" do
    test "endpoint_policy_key/2 resolves POST /entities/query to :EntitiesQuery" do
      assert Letflow.Api.Authorization.endpoint_policy_key("POST", "/entities/query") ==
               :EntitiesQuery
    end

    test "a caller whose role does not hold :EntitiesQuery is refused, and one that holds it is not" do
      seeded = tenant_ctx("req311-authz")
      seed_queryable_widget!(seeded)

      # :AGENT_RUNNER holds NO permission at all (Authorization's own
      # role_allows?(:AGENT_RUNNER, _) -> false); :TASK_WORKER is the
      # narrowest role that DOES hold :EntitiesQuery. Both are members of
      # Authorization's five closed roles, so this is driven by the real
      # matrix, not by a role string invented here.
      denied = %{seeded | plaintext: mint_token!(seeded, ["AGENT_RUNNER"])}
      allowed = %{seeded | plaintext: mint_token!(seeded, ["TASK_WORKER"])}

      assert query(denied, %{"entity_type" => "widget"}).status == 403
      assert query(allowed, %{"entity_type" => "widget"}).status == 200
    end
  end

  defp mint_token!(ctx, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(ctx.user_id, %{roles: roles, expires_at: nil},
        prefix: ctx.schema_name
      )

    plaintext
  end

  # Mints a cursor in exactly the wire format `Letflow.Api.Pagination`'s own
  # decoder expects -- `"<prefix><mint_time_us>:<resume_key_json>"`,
  # base64url-encoded -- so a test can isolate the prefix check and the
  # expiry check from each other and from a merely-unparseable string.
  # Built from `Pagination.encode_cursor/1` and `Cursor.cursor_prefix/0`
  # rather than a hardcoded literal.
  defp mint_cursor(prefix, mint_time_us, resume_values) do
    Letflow.Api.Pagination.encode_cursor(
      "#{prefix}#{mint_time_us}:#{Jason.encode!(resume_values)}"
    )
  end
end
