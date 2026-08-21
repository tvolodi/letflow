defmodule Letflow.Plugs.TenantStatus do
  @moduledoc """
  Tenant write-pause check — ports `src/api/middleware/tenant_status.zig`'s
  `checkTenantWritePause/4`. Call this **after** `Letflow.Plugs.AuthPipeline`
  has resolved `conn.assigns[:auth_context][:tenant_id]`, and before
  dispatching to a write handler — matching `tenant_status.zig`'s own doc
  comment on its calling convention.

  A write request (`POST`/`PUT`/`PATCH`/`DELETE`) against a tenant whose
  `status` is `:migrating` is rejected with 503 and a `Retry-After` header.
  `GET`/`HEAD` (and any other non-write method) pass through unchanged, with
  no DB query at all.

  **Fail-closed on a genuine DB error during the tenant-status lookup** — a
  deliberate divergence from `tenant_status.zig`'s own fail-open behavior
  (pool exhaustion / query failure both let the request through in R-Co).
  This plug instead lets a lookup failure propagate as a crash of the
  handling process (letting the existing OTP/Bandit request-handling
  isolation apply) rather than silently bypassing a data-integrity
  safeguard. See `lib/letflow/design/req021-auth-plug-pipeline.md` §6.4
  (OQ-14) — the design states this as a recommendation, not a mandate;
  REVIEWER should confirm.

  **Mounted since REQ-071**, immediately after `Letflow.Plugs.AuthPipeline` in
  `Letflow.Plugs.ApiPipeline`'s plug chain, matching this module's own calling
  convention above — every `/api/v1/*` request has `conn.assigns[:auth_context]`
  populated by `AuthPipeline` before this plug runs.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Identity.Tenant
  alias Letflow.Repo

  @write_methods ~w(POST PUT PATCH DELETE)
  @retry_after_seconds "30"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @write_methods do
    tenant_id = get_in(conn.assigns, [:auth_context, :tenant_id])
    check_write_pause(conn, tenant_id)
  end

  def call(conn, _opts), do: conn

  # No auth context resolved ahead of this plug — undefined per this design
  # (§6.3's OQ-12: TenantStatus is only ever mounted after AuthPipeline in
  # the same pipeline; this case should not occur in practice). Passing
  # through rather than crashing is the safer of two unspecified choices,
  # but this is explicitly not a defended-against case.
  defp check_write_pause(conn, nil), do: conn

  defp check_write_pause(conn, tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{status: :migrating} ->
        reject_migrating(conn)

      %Tenant{} ->
        conn

      nil ->
        # Should not occur — AuthPipeline already resolved this tenant via
        # resolve_tenant_by_realm/1. A race/deletion between steps, not a
        # normal case; pass through rather than fail the request over it.
        conn
    end
  end

  defp reject_migrating(conn) do
    body =
      Jason.encode!(%{
        error: "tenant_migrating",
        detail: "tenant is being migrated; writes are paused"
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("retry-after", @retry_after_seconds)
    |> send_resp(503, body)
    |> halt()
  end
end
