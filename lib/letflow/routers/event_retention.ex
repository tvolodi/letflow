defmodule Letflow.Routers.EventRetention do
  @moduledoc """
  Platform-wide event-history retirement sub-router (REQ-377), mounted at
  `/event-retention` directly by `Letflow.Plugs.ApiPipeline` (so full paths
  under `/api/v1` are `/api/v1/event-retention/summary`,
  `/api/v1/event-retention/retirements`,
  `/api/v1/event-retention/retirements/:id`). See
  `lib/letflow/design/req377-history-retirement-screen.md` §2.3 for the
  full design.

  | Handler | Method/path                         | Domain fn                                          | Auth             | Response                                                   |
  |---------|--------------------------------------|-----------------------------------------------------|------------------|-------------------------------------------------------------|
  | summary | `GET /event-retention/summary`       | `RetentionOperations.retention_summary/0`           | `:TenantsManage` | 200, summary map                                             |
  | start   | `POST /event-retention/retirements`  | `RetentionOperations.retire_oldest_eligible_month/1`| `:TenantsManage` | 202, `retirement` map; 409 on `:no_eligible_month`           |
  | status  | `GET /event-retention/retirements/:id`| `RetentionOperations.retirement_status/1`          | `:TenantsManage` | 200, `%{retirement:, outcomes:}` map; 404 on `:retirement_not_found` |

  `start` responds **202 Accepted**, not 200/201 -- the operation is not
  complete when the response is sent (`RetentionOperations`'s own moduledoc,
  "Why async"). Its request body is empty -- "oldest eligible month" is
  always system-computed, never caller-supplied, so there is no
  caller-controlled `year`/`month` input to validate at all.

  ## Permission decision -- reused, not new: `:TenantsManage`

  All three routes require `:TenantsManage` (`Letflow.Api.Authorization`,
  granted to `PLATFORM_ADMIN` only via the existing catch-all
  `role_allows?(:PLATFORM_ADMIN, _)` clause). Same risk class as the three
  existing precedents that already reuse this exact permission for a
  platform-wide, cross-tenant-touching action outside any single tenant's
  own `:prefix` scope: `POST /tenants` (REQ-075), `POST /onboarding`
  (REQ-076), and `Letflow.Routers.PlatformMigrations` (REQ-374) -- a
  platform-wide event-history retirement is the same shape again, an action
  with no single tenant context to scope by, gated purely on role. No new
  `role_allows?/2` clause is added anywhere by this router.

  No tenant-scoped `:prefix` preamble exists on this router (same
  structural reason `Letflow.Routers.PlatformMigrations` has none): these
  handlers act across every tenant schema, so there is no single tenant
  context to scope by. Every handler runs `Letflow.Plugs.Authorize` (via
  `Letflow.Api.AuthorizedRouter`'s fixed match/Authorize/dispatch plug
  chain) before any `Repo` call of any kind.

  `requested_by` (attribution on `POST /retirements`) comes from
  `conn.assigns.auth_context.user_id`, the same assign key every other
  `PLATFORM_ADMIN`-gated write already reads for actor attribution (see
  `Letflow.Routers.Tasks`/`Letflow.Routers.Entities`).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.EventStore.RetentionOperations

  authz_get "/summary", :TenantsManage do
    handle_summary(conn)
  end

  authz_post "/retirements", :TenantsManage do
    handle_start(conn)
  end

  authz_get "/retirements/:id", :TenantsManage do
    handle_status(conn, conn.params["id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /summary ──────────────────────────────────────────────────────

  defp handle_summary(conn) do
    {:ok, summary} = RetentionOperations.retention_summary()
    Response.ok(conn, summary_map(summary))
  end

  # ── POST /retirements ────────────────────────────────────────────────

  defp handle_start(conn) do
    requested_by = conn.assigns.auth_context.user_id

    case RetentionOperations.retire_oldest_eligible_month(requested_by) do
      {:ok, retirement} ->
        Response.send_json(conn, 202, retirement_map(retirement))

      {:error, :no_eligible_month} ->
        Response.conflict(conn, "No month of event history is currently eligible to retire")
    end
  end

  # ── GET /retirements/:id ─────────────────────────────────────────────

  defp handle_status(conn, id) do
    case RetentionOperations.retirement_status(id) do
      {:ok, retirement_result} -> Response.ok(conn, retirement_result_map(retirement_result))
      {:error, :retirement_not_found} -> Response.not_found(conn)
    end
  end

  # ── Response shaping ─────────────────────────────────────────────────

  defp summary_map(summary) do
    %{
      "oldest_eligible_month" => oldest_eligible_month_map(summary.oldest_eligible_month),
      "protected_record_count" => summary.protected_record_count,
      "tenant_schema_count" => summary.tenant_schema_count,
      "computed_at" => iso8601(summary.computed_at)
    }
  end

  defp oldest_eligible_month_map(nil), do: nil

  defp oldest_eligible_month_map(%{year: year, month: month}),
    do: %{"year" => year, "month" => month}

  defp retirement_result_map(%{retirement: retirement, outcomes: outcomes}) do
    %{
      "retirement" => retirement_map(retirement),
      "outcomes" => Enum.map(outcomes, &outcome_map/1)
    }
  end

  defp retirement_map(retirement) do
    %{
      "id" => retirement.id,
      "year" => retirement.year,
      "month" => retirement.month,
      "status" => retirement.status,
      "requested_by" => retirement.requested_by,
      "started_at" => iso8601(retirement.started_at),
      "completed_at" => iso8601(retirement.completed_at)
    }
  end

  defp outcome_map(outcome) do
    %{
      "tenant_id" => outcome.tenant_id,
      "schema_name" => outcome.schema_name,
      "status" => outcome.status,
      "retired_partition" => outcome.retired_partition,
      "protected_rows_relocated" => outcome.protected_rows_relocated,
      "resumed_from" => outcome.resumed_from,
      "reason" => outcome.reason,
      "completed_at" => iso8601(outcome.completed_at)
    }
  end

  defp iso8601(nil), do: nil

  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
