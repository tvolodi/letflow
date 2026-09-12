defmodule Letflow.Routers.EntitiesExportTest do
  @moduledoc """
  Tests for REQ-319's `POST /entities/records/:entity_type/export` route
  (`Letflow.Routers.Entities`), written by ELIXIR-DEV at WF-02 Step 2a. See
  `lib/letflow/design/req314-entity-record-bulk-export-import.md` -- in
  particular the FINAL "SECURITY-REVIEWER Final Verdict" section at the
  bottom of that document (not the original FAILed pass above it), which
  governs §6's two-tier default-redacted/escalated-unredacted mechanism this
  file exercises.

  ## Every request goes through the full pipeline, not the router in isolation

  Same discipline as `entities_test.exs`/`entities_aggregate_test.exs`:
  dispatched via `Letflow.Router.call/2` with a real API-token bearer
  credential, so `Letflow.Plugs.AuthPipeline` -> `Letflow.Plugs.TenantStatus`
  -> `Letflow.Plugs.Authorize` -> the router all genuinely run.

  ## A real, load-bearing gap in today's role matrix (design §5, stated there
  explicitly, re-confirmed against `lib/letflow/api/authorization.ex` here)

  `role_allows?/2`'s only clause naming ANY of `:EntitiesRecordsExport` /
  `:EntitiesRecordsExportUnredacted` is `:PLATFORM_ADMIN`'s unconditional
  catch-all (`role_allows?(:PLATFORM_ADMIN, _permission), do: true`) -- every
  other role's clause is a closed, static list that names neither atom.
  Mechanically, this means: for ANY combination of the five real roles, the
  resulting permission set either contains NEITHER atom (PLATFORM_ADMIN
  excluded) or BOTH atoms plus everything else (PLATFORM_ADMIN included,
  since its clause ORs in literally every permission). There is today no
  real, token-backed caller who holds `:EntitiesRecordsExport` without also
  holding `:EntitiesRecordsExportUnredacted` -- this is the exact,
  deliberate, narrow-by-default role-matrix state design §5 documents
  ("only PLATFORM_ADMIN's existing catch-all grants them today... a future
  REVIEWER-led role-matrix pass decides wider role assignment").

  Because of that, "a caller holding only base :EntitiesRecordsExport"
  cannot be constructed via a real HTTP request today, and this file does
  not fabricate one. Instead:

    * the FULL-DISCLOSURE side of the two-tier mechanism (both atoms held,
      `unredacted: true` bypasses `FieldGrants` entirely) is proven at the
      real HTTP layer with a PLATFORM_ADMIN caller (describe
      "escalated mode -- full disclosure" below);
    * the FAIL-CLOSED side of the SAME check
      (`check_unredacted_permission/2` in `lib/letflow/routers/entities.ex`,
      which calls `Letflow.Api.Authorization.evaluate_access/2` exactly the
      way `Letflow.Plugs.Authorize` itself does) is proven directly against
      that real function, with a real role that genuinely lacks the atom
      (describe "escalated mode -- fail-closed mechanism" below) -- this is
      the SAME code path the handler runs, not a stand-in;
    * atom independence (`:EntitiesQuery` alone, or no permission at all,
      never reaches export data) is proven at the HTTP layer, and requires
      no role-matrix workaround since every non-admin role already lacks
      `:EntitiesRecordsExport` entirely.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode. Self-sufficient: does not depend on any
  fixture defined in `entities_test.exs`/`entities_aggregate_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body, opts) do
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

  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  defp export(ctx, entity_type, body, opts \\ []),
    do: request(:post, "/api/v1/entities/records/#{entity_type}/export", ctx, body, opts)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp wire_sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req319-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-319 Export Route Test User",
      email: "req319-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp tenant_ctx(slug_prefix, roles \\ ["PLATFORM_ADMIN"]) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-319 Export Route Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  # A SECOND credential for a tenant that already exists, belonging to a
  # DIFFERENT user in the same schema -- mirrors entities_test.exs's own
  # second_user_ctx/2, needed by the two-caller redaction-comparison test.
  defp second_user_ctx(ctx, roles \\ ["PLATFORM_ADMIN"]) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req319-user2-#{Ecto.UUID.generate()}",
        display_name: "REQ-319 Second User",
        email: "req319-2-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    %{ctx | plaintext: plaintext, user_id: user.id}
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
        "req319 go-live",
        ctx.schema_name
      )

    activated
  end

  defp seed_widget!(ctx) do
    create_active_definition!(ctx, %{
      name: "widget",
      display_name: "Widget",
      fields: [
        %{name: "title", type: :string, queried: true},
        %{name: "secret_cost", type: :string, queried: true}
      ]
    })
  end

  defp seed_record!(ctx, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "widget",
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp delete_record!(ctx, record_id) do
    {:ok, %{record: record}} =
      Records.delete_record(
        %{
          entity_type: "widget",
          record_id: record_id,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
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

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- default mode's disclosure strength matches :EntitiesQuery exactly,
  # via the SAME two-caller comparison technique
  # entities_test.exs's own REQ-311 AC8 test used.
  # ═══════════════════════════════════════════════════════════════════════

  describe "default mode -- disclosure strength matches :EntitiesQuery" do
    test "a caller with a user_entity_grants row sees the real value; a caller without sees the sentinel" do
      ctx = tenant_ctx("req319-default-redact")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")
      insert_user_grant!(ctx, ctx.user_id, "widget", "secret_cost")

      other = second_user_ctx(ctx)

      seed_record!(ctx, %{"title" => "widget-a", "secret_cost" => "CLEARTEXT COST"})

      granted = export(ctx, "widget", %{})
      ungranted = export(other, "widget", %{})

      assert granted.status == 200
      assert ungranted.status == 200

      assert [granted_record] = body_of(granted)["records"]
      assert [ungranted_record] = body_of(ungranted)["records"]

      assert granted_record["field_values"]["secret_cost"] == "CLEARTEXT COST"
      assert ungranted_record["field_values"]["secret_cost"] == wire_sentinel()

      # unrestricted field is untouched on both sides.
      assert granted_record["field_values"]["title"] == "widget-a"
      assert ungranted_record["field_values"]["title"] == "widget-a"

      refute granted.resp_body == ungranted.resp_body
    end

    test "an absent body means no filter, natural order, redacted -- unredacted defaults to false" do
      ctx = tenant_ctx("req319-default-absent")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")
      seed_record!(ctx, %{"title" => "widget-a", "secret_cost" => "SECRET"})

      conn = export(ctx, "widget", nil)

      assert conn.status == 200
      assert [record] = body_of(conn)["records"]
      assert record["field_values"]["secret_cost"] == wire_sentinel()
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # ⛔ AC -- escalated mode's FAIL-CLOSED half of the two-tier mechanism.
  #
  # See this file's moduledoc for why this is tested directly against
  # Letflow.Api.Authorization.evaluate_access/2 -- the EXACT function and
  # atom `check_unredacted_permission/2` (lib/letflow/routers/entities.ex)
  # calls -- rather than via a real HTTP round trip: today's role matrix
  # (design §5) grants :EntitiesRecordsExport to no role but PLATFORM_ADMIN,
  # which also always holds :EntitiesRecordsExportUnredacted, so no real
  # token-backed caller can currently clear the route-level gate while
  # failing this second one.
  # ═══════════════════════════════════════════════════════════════════════

  describe "escalated mode -- fail-closed mechanism" do
    test "a context lacking :EntitiesRecordsExportUnredacted is denied by the exact check the handler runs" do
      ctx = %Authorization.AccessContext{
        user_id: Ecto.UUID.generate(),
        roles: Authorization.roles_from_strings(["TASK_WORKER"])
      }

      decision = Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted)

      assert decision.kind == :Deny403
    end

    test "a context holding NO role at all is denied identically -- fail-closed, not fail-open" do
      ctx = %Authorization.AccessContext{user_id: Ecto.UUID.generate(), roles: []}

      decision = Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted)

      assert decision.kind == :Deny403
    end

    # HTTP-level companion: a caller who fails even the ROUTE-level
    # :EntitiesRecordsExport check (TASK_WORKER holds only :EntitiesQuery)
    # gets 403 with NO record data at all, `unredacted: true` or not --
    # proving that shape of request can never reach the selection query
    # either, at the outer gate.
    test "a caller without base :EntitiesRecordsExport requesting unredacted: true still gets 403, no record data" do
      ctx = tenant_ctx("req319-fail-closed-http", ["TASK_WORKER"])
      seed_widget!(ctx)
      seed_record!(ctx, %{"title" => "widget-a", "secret_cost" => "SECRET"})

      conn = export(ctx, "widget", %{"unredacted" => true})

      assert conn.status == 403
      refute Map.has_key?(body_of(conn), "records")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- escalated mode's FULL-DISCLOSURE half: both atoms held (real HTTP,
  # PLATFORM_ADMIN, which holds both today).
  # ═══════════════════════════════════════════════════════════════════════

  describe "escalated mode -- full disclosure" do
    test "unredacted: true returns every field unredacted, even one restricted for this caller under :EntitiesQuery" do
      ctx = tenant_ctx("req319-unredacted-full")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")
      # Deliberately NO user_entity_grants row for ctx.user_id -- this
      # caller IS restricted from "secret_cost" under plain :EntitiesQuery.
      seed_record!(ctx, %{"title" => "widget-a", "secret_cost" => "CLEARTEXT COST"})

      redacted = export(ctx, "widget", %{})
      unredacted = export(ctx, "widget", %{"unredacted" => true})

      assert redacted.status == 200
      assert unredacted.status == 200

      assert [redacted_record] = body_of(redacted)["records"]
      assert [unredacted_record] = body_of(unredacted)["records"]

      assert redacted_record["field_values"]["secret_cost"] == wire_sentinel()
      assert unredacted_record["field_values"]["secret_cost"] == "CLEARTEXT COST"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- atom independence: :EntitiesQuery alone never implies export
  # access, whether or not the request asks for the escalated mode.
  # ═══════════════════════════════════════════════════════════════════════

  describe "atom independence" do
    test "a caller holding only :EntitiesQuery (TASK_WORKER) gets 403 on the export route entirely" do
      ctx = tenant_ctx("req319-atom-independence", ["TASK_WORKER"])
      seed_widget!(ctx)

      conn = export(ctx, "widget", %{})

      assert conn.status == 403
    end

    test "a caller holding NONE of the Entities* permissions (AGENT_RUNNER) also gets 403" do
      ctx = tenant_ctx("req319-atom-independence-none", ["AGENT_RUNNER"])
      seed_widget!(ctx)

      conn = export(ctx, "widget", %{})

      assert conn.status == 403
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- pagination: >200 records -> exactly 200 + next_cursor; the
  # remainder on a second call with that cursor.
  # ═══════════════════════════════════════════════════════════════════════

  describe "pagination -- §7's 200-record cap" do
    test "201 records -> first page has exactly 200 + a working next_cursor; second page has the remainder" do
      ctx = tenant_ctx("req319-pagination")
      seed_widget!(ctx)

      for n <- 1..201, do: seed_record!(ctx, %{"title" => "row-#{n}"})

      page1 = export(ctx, "widget", %{"page_size" => 200})

      assert page1.status == 200
      body1 = body_of(page1)
      assert length(body1["records"]) == 200
      assert is_binary(body1["next_cursor"])

      page2 =
        export(ctx, "widget", %{"page_size" => 200, "cursor" => body1["next_cursor"]})

      assert page2.status == 200
      body2 = body_of(page2)
      assert length(body2["records"]) == 1
      assert body2["next_cursor"] == nil

      ids = Enum.map(body1["records"] ++ body2["records"], & &1["record_id"])
      assert length(Enum.uniq(ids)) == 201
    end

    test "an ABSENT page_size defaults to the full 200-record cap, not query's smaller 50-record default" do
      ctx = tenant_ctx("req319-pagination-default")
      seed_widget!(ctx)

      for n <- 1..201, do: seed_record!(ctx, %{"title" => "row-#{n}"})

      conn = export(ctx, "widget", %{})

      assert conn.status == 200
      assert length(body_of(conn)["records"]) == 200
      assert is_binary(body_of(conn)["next_cursor"])
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- export_document shape (design §1): schema version, entity_type,
  # exported_at, records[].{record_id, field_values, deleted}, `deleted`
  # matching entity_record_latest.deleted for a soft-deleted record.
  # ═══════════════════════════════════════════════════════════════════════

  describe "export_document shape" do
    test "the response carries record_export_schema_version/entity_type/exported_at/records, deleted matches a soft-deleted record" do
      ctx = tenant_ctx("req319-shape")
      seed_widget!(ctx)

      live = seed_record!(ctx, %{"title" => "still here"})
      to_delete = seed_record!(ctx, %{"title" => "going away"})
      delete_record!(ctx, to_delete.record_id)

      conn = export(ctx, "widget", %{})

      assert conn.status == 200
      body = body_of(conn)

      assert body["record_export_schema_version"] == "entities/record-export/v1"
      assert body["entity_type"] == "widget"
      assert {:ok, _, _} = DateTime.from_iso8601(body["exported_at"])

      records_by_id = Map.new(body["records"], &{&1["record_id"], &1})

      live_entry = Map.fetch!(records_by_id, live.record_id)
      deleted_entry = Map.fetch!(records_by_id, to_delete.record_id)

      assert MapSet.new(Map.keys(live_entry)) ==
               MapSet.new(["record_id", "field_values", "deleted"])

      assert live_entry["deleted"] == false
      assert deleted_entry["deleted"] == true
      # field_values retained unchanged, per Records.delete_record/2's own
      # moduledoc -- the deleted entry's title is still readable.
      assert deleted_entry["field_values"]["title"] == "going away"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- INV-5: cross-tenant and nonexistent entity_type are the same bytes.
  # ═══════════════════════════════════════════════════════════════════════

  describe "INV-5" do
    test "a nonexistent entity_type and a cross-tenant entity_type produce byte-identical 404 responses" do
      ctx1 = tenant_ctx("req319-inv5-a")
      ctx2 = tenant_ctx("req319-inv5-b")
      seed_widget!(ctx2)

      trace_id = Ecto.UUID.generate()

      nonexistent = export(ctx1, "widget", %{}, trace_id: trace_id)
      cross_tenant = export(ctx1, "widget_only_in_tenant_b", %{}, trace_id: trace_id)

      assert nonexistent.status == 404
      assert cross_tenant.status == 404
      assert nonexistent.resp_body == cross_tenant.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- path-vs-body entity_type mismatch -> 422 before any selection runs.
  # ═══════════════════════════════════════════════════════════════════════

  describe "path-vs-body entity_type mismatch" do
    test "a body entity_type that disagrees with the path segment is rejected 422, no record data" do
      ctx = tenant_ctx("req319-mismatch")
      seed_widget!(ctx)
      seed_record!(ctx, %{"title" => "widget-a"})

      conn = export(ctx, "widget", %{"entity_type" => "not-widget"})

      assert conn.status == 422
      refute Map.has_key?(body_of(conn), "records")
    end

    test "a body entity_type that AGREES with the path segment succeeds -- the check is a mismatch check, not a ban on the field" do
      ctx = tenant_ctx("req319-match-ok")
      seed_widget!(ctx)
      seed_record!(ctx, %{"title" => "widget-a"})

      conn = export(ctx, "widget", %{"entity_type" => "widget"})

      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- moduledoc route table carries the new row.
  # ═══════════════════════════════════════════════════════════════════════

  describe "moduledoc" do
    test "the route table names POST /entities/records/:entity_type/export and both permission atoms" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _fn_docs} =
        Code.fetch_docs(Letflow.Routers.Entities)

      assert moduledoc =~ "POST /entities/records/:entity_type/export"
      assert moduledoc =~ "EntitiesRecordsExport"
      assert moduledoc =~ "EntitiesRecordsExportUnredacted"
    end
  end
end
