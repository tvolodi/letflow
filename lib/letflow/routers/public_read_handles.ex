defmodule Letflow.Routers.PublicReadHandles do
  @moduledoc """
  REQ-352 (design §13.2) -- the generic, kind-agnostic authenticated issue
  route for `Letflow.PublicRead.issue_handle/4`. Mounted under
  `Letflow.Plugs.ApiPipeline` at `/public-read-handles` (tenant-scoped,
  authenticated) -- this is **not** a public route and mounts nowhere near
  `/api/public`.

  | Handler | Method/path              | Delegate                                | Auth                        | Response |
  |---------|--------------------------|------------------------------------------|-----------------------------|----------|
  | issue   | `POST /public-read-handles` | `Letflow.PublicRead.issue_handle/4` | `:PublicReadHandlesIssue` | `201`, `{"handle" => plaintext}` |

  `tenant_id` is read only from `conn.assigns.auth_context.tenant_id` --
  never from the request body (INV-1), matching every other authenticated
  tenant-scoped write in this codebase.

  `kind` in the request body is **not** validated against the kind registry
  (`Letflow.PublicRead.fetch_kind/1`) by this route -- a kind need not yet
  have a projection registered at the moment a handle is issued for it
  (issuance and public exposure are independent steps; a handle issued for
  an as-yet-unregistered kind simply 404s at read time until the kind is
  registered). Deliberate, per design §13.2 -- do not add this check.

  Role grant for `:PublicReadHandlesIssue` is deliberately left to the
  requirement that authors the first concrete issue path consuming this
  permission (per the design's §13.1) -- this module does not decide which
  role(s) hold it.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.PublicRead

  authz_post "/", :PublicReadHandlesIssue do
    handle_issue(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  defp handle_issue(conn) do
    tenant_id = conn.assigns.auth_context.tenant_id
    params = conn.body_params

    kind = Map.get(params, "kind")
    resource_id = Map.get(params, "resource_id")
    expires_at = parse_expires_at(Map.get(params, "expires_at"))

    case PublicRead.issue_handle(tenant_id, kind, resource_id, expires_at: expires_at) do
      {:ok, %{handle: plaintext}} ->
        Response.created(conn, %{"handle" => plaintext})

      {:error, %Ecto.Changeset{}} ->
        Response.bad_request(conn, "invalid public read handle request")
    end
  end

  defp parse_expires_at(nil), do: nil

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end
end
