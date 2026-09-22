defmodule Letflow.Routers.EventRetentionTest do
  @moduledoc """
  HTTP/permission-level tests for `Letflow.Routers.EventRetention` (REQ-377).
  See `test/specs/REQ-377.md` for the full AC-to-test mapping, and
  `lib/letflow/design/req377-history-retirement-screen.md` §2.3 for the
  design rationale each test below implements directly.

  Dispatch is direct `Letflow.Routers.EventRetention.call/2` with
  `conn.assigns[:auth_context]` set directly, the same pattern
  `test/letflow/routers/platform_migrations_test.exs` already establishes
  for a router mounted with no tenant-scoped `:prefix` preamble -- only
  `roles` matters for authorization here (design §2.3/§0's pure-role gate,
  reusing `:TenantsManage`), so negative (403) tests use a bare
  `Ecto.UUID.generate()` and never provision a tenant for the caller. A
  positive-path test still needs one real, provisioned tenant schema (the
  actual fanout target), via `Letflow.TenantFixture.provisioned_tenant!/1`.

  Uses `Letflow.DataCase` (real Postgres) and `async: false` -- this
  router's `start` handler dispatches a genuinely concurrent
  `Task.Supervisor.async_nolink/3` call (same reason
  `retention_operations_test.exs` runs `async: false` / Sandbox `:auto`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Letflow.EventStore.EventHistoryRetirement
  alias Letflow.EventStore.EventHistoryRetirementOutcome
  alias Letflow.EventStore.RetentionOperations
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.EventRetention.init([])

  defp build_conn(method, path, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: Ecto.UUID.generate(),
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.EventRetention.call(conn, @opts)

  defp with_event_retention_override(overrides, fun) do
    previous = Application.get_env(:letflow, :event_retention, [])
    Application.put_env(:letflow, :event_retention, Keyword.merge(previous, overrides))

    try do
      fun.()
    after
      Application.put_env(:letflow, :event_retention, previous)
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp shift_months({year, month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp eligible_past_month do
    today = Date.utc_today()
    shift_months({today.year, today.month}, -1)
  end

  defp month_bounds_str(year, month) do
    from = "#{year}-#{pad2(month)}-01"
    {next_year, next_month} = shift_months({year, month}, 1)
    to = "#{next_year}-#{pad2(next_month)}-01"
    {from, to}
  end

  defp create_events_month_partition!(schema_name, year, month) do
    partition = "events_y#{year}m#{pad2(month)}"
    {from_bound, to_bound} = month_bounds_str(year, month)

    Repo.query!(
      ~s{CREATE TABLE "#{schema_name}"."#{partition}" PARTITION OF "#{schema_name}".events FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )

    partition
  end

  defp wait_until_status(retirement_id, target_statuses, attempts \\ 100) when attempts > 0 do
    {:ok, result} = RetentionOperations.retirement_status(retirement_id)

    if result.retirement.status in target_statuses do
      result
    else
      Process.sleep(50)
      wait_until_status(retirement_id, target_statuses, attempts - 1)
    end
  end

  defp cleanup_retirement_rows_on_exit!(retirement_id) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      Repo.delete_all(
        from(o in EventHistoryRetirementOutcome, where: o.retirement_id == ^retirement_id)
      )

      Repo.delete_all(from(r in EventHistoryRetirement, where: r.id == ^retirement_id))
    end)
  end

  # ---------------------------------------------------------------------
  # Permission gate -- 403 for a non-PLATFORM_ADMIN caller, all 3 routes.
  # ---------------------------------------------------------------------

  describe "permission gate -- non-PLATFORM_ADMIN caller" do
    test "GET /summary returns 403" do
      resp = build_conn(:get, "/summary", roles: ["PROCESS_DESIGNER"]) |> dispatch()
      assert resp.status == 403

      assert Jason.decode!(resp.resp_body) == %{
               "type" => "https://bpm.example.com/problems/forbidden",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "insufficient permissions",
               "trace_id" => "fixed-test-trace-id"
             }
    end

    test "POST /retirements returns 403 and creates no retirement row" do
      before_count = Repo.aggregate(EventHistoryRetirement, :count)

      resp = build_conn(:post, "/retirements", roles: ["PROCESS_DESIGNER"]) |> dispatch()
      assert resp.status == 403

      assert Repo.aggregate(EventHistoryRetirement, :count) == before_count
    end

    test "GET /retirements/:id returns 403 for a non-existent id too (rejected before the domain lookup)" do
      resp =
        build_conn(:get, "/retirements/#{Ecto.UUID.generate()}", roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert resp.status == 403
    end

    test "a caller with no roles at all is rejected the same way" do
      resp = build_conn(:get, "/summary", roles: []) |> dispatch()
      assert resp.status == 403
    end
  end

  # ---------------------------------------------------------------------
  # Permission gate -- PLATFORM_ADMIN succeeds; response shapes + status codes.
  # ---------------------------------------------------------------------

  describe "permission gate -- PLATFORM_ADMIN caller" do
    test "GET /summary returns 200 with the summary shape" do
      resp = build_conn(:get, "/summary", roles: ["PLATFORM_ADMIN"]) |> dispatch()
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert Map.has_key?(body, "oldest_eligible_month")
      assert is_integer(body["protected_record_count"])
      assert is_integer(body["tenant_schema_count"])
      assert is_binary(body["computed_at"])
    end

    test "GET /retirements/:id returns 404 for an unknown id (not 403 -- the permission check already passed)" do
      resp =
        build_conn(:get, "/retirements/#{Ecto.UUID.generate()}", roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 404
    end

    test "POST /retirements returns 409 when no month is currently eligible, and creates no row" do
      # Real 400-day default in force -- no tenant provisioned by this test
      # has any eligible month, so this is a genuine, not artificially
      # forced, :no_eligible_month outcome.
      before_count = Repo.aggregate(EventHistoryRetirement, :count)

      resp = build_conn(:post, "/retirements", roles: ["PLATFORM_ADMIN"]) |> dispatch()
      assert resp.status == 409

      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 409

      assert Repo.aggregate(EventHistoryRetirement, :count) == before_count
    end

    test "POST /retirements (AC1) returns 202 with the retirement record; GET status (AC1) reaches completed with the outcome table" do
      with_event_retention_override([min_partition_age_days: 1], fn ->
        # template: :replay -- the default :clone template may be sourced
        # from a "tenant_template" schema snapshot predating REQ-376's
        # `events` -> `events_p` partitioned-table swap; this test needs
        # `events` to genuinely be a partitioned parent (PARTITION OF
        # against it fails 42P17 otherwise), so it forces a real,
        # freshly-migrated-from-scratch schema instead.
        company =
          TenantFixture.provisioned_tenant!(slug_prefix: "req377-happy-path", template: :replay)

        {year, month} = eligible_past_month()
        create_events_month_partition!(company.schema_name, year, month)

        requested_by = Ecto.UUID.generate()

        start_resp =
          build_conn(:post, "/retirements", roles: ["PLATFORM_ADMIN"], user_id: requested_by)
          |> dispatch()

        assert start_resp.status == 202
        start_body = Jason.decode!(start_resp.resp_body)
        retirement_id = start_body["id"]
        assert is_binary(retirement_id)
        assert start_body["year"] == year
        assert start_body["month"] == month
        assert start_body["requested_by"] == requested_by
        assert start_body["status"] in ["running", "completed"]

        cleanup_retirement_rows_on_exit!(retirement_id)

        # AC1: poll GET /retirements/:id until the async fanout finishes,
        # and confirm the resulting outcome table ("resulting retirement
        # record") is genuinely there.
        result = wait_until_status(retirement_id, ["completed", "failed"])
        assert result.retirement.status == "completed"

        status_resp =
          build_conn(:get, "/retirements/#{retirement_id}", roles: ["PLATFORM_ADMIN"])
          |> dispatch()

        assert status_resp.status == 200
        status_body = Jason.decode!(status_resp.resp_body)
        assert status_body["retirement"]["id"] == retirement_id
        assert status_body["retirement"]["status"] == "completed"

        outcome =
          Enum.find(status_body["outcomes"], &(&1["tenant_id"] == company.tenant_id))

        assert outcome["status"] == "succeeded"
        assert is_binary(outcome["retired_partition"])
        assert is_integer(outcome["protected_rows_relocated"])
      end)
    end
  end

  # ---------------------------------------------------------------------
  # The permission decision is stated in the moduledoc, by name.
  # ---------------------------------------------------------------------

  describe "moduledoc states the permission decision by name" do
    test "Letflow.Routers.EventRetention's moduledoc names :TenantsManage and PLATFORM_ADMIN" do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Routers.EventRetention)

      assert moduledoc =~ ":TenantsManage"
      assert moduledoc =~ "PLATFORM_ADMIN"
    end
  end
end
