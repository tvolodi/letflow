defmodule Letflow.Routers.PublicRead do
  @moduledoc """
  REQ-352 (design `lib/letflow/design/req352-unauthenticated-read-platform.md`
  §2), building the first concrete artefact of the pattern fixed by
  `lib/letflow/design/req323-unauthenticated-read-pattern.md` and decision
  `docs/migration/decisions/0028-unauthenticated-read-boundary.md`.

  Mounted by `Letflow.Router` via `forward("/api/public", to:
  __MODULE__)`, declared after `/metrics` and before the `/api/v1` forward
  -- so it never enters `Letflow.Plugs.AuthPipeline`, which has no bypass.

  | Handler   | Method/path                      | Delegate                     | Auth     | Response |
  |-----------|-----------------------------------|-------------------------------|----------|----------|
  | show      | `GET /api/public/<kind>/:handle`  | `Letflow.PublicRead.resolve/2` | **none** | `200` on a resolved handle; `404` `application/problem+json` on every other input |
  | catch-all | `match _`                          | --                             | **none** | `404` `application/problem+json`, byte-identical to the miss body |

  This module contains **no** resource-type-specific branch anywhere in its
  source -- `<kind>` dispatches only through
  `Letflow.PublicRead.fetch_kind/1`'s config-driven registry lookup and
  `Letflow.PublicRead.resolve/2`. Grep-verifiable (AC-10):

      $ grep -n '"' lib/letflow/routers/public_read.ex

  must show no kind-name literal other than the path template
  `"/:kind/:handle"` and the header/content-type string literals below.

  ## Refusal discipline (design §7, decision 0028 point 4)

  Every non-success outcome -- unregistered kind, malformed/unknown/revoked/
  expired/kind-mismatched handle, deleted/unpublishable resource, wrong
  method, wrong path, deactivated tenant -- produces the byte-identical
  `404 application/problem+json` via `Letflow.Api.Response.not_found/1`.
  Never 401, never 403.

  ## Rate limiting (design §11, decision 0028 point 6)

  `Letflow.Plugs.PublicReadRateLimit` is the FIRST plug in this router's own
  chain, ahead of `plug(:match)`, so a `429` is input-independent -- it
  fires identically whether `:handle` would have resolved or not, and no
  resolution work ever begins for a rate-limited request.

  ## Response headers (design §12)

  `Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`, and
  `X-Robots-Tag: noindex, nofollow` are set identically on the success
  clause and the catch-all -- via `set_response_headers/1`, so the two
  clauses cannot drift out of sync.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.PublicRead

  plug(Letflow.Plugs.PublicReadRateLimit)
  plug(:match)
  plug(:dispatch)

  get "/:kind/:handle" do
    conn = set_response_headers(conn)

    case PublicRead.fetch_kind(kind) do
      :error ->
        Response.not_found(conn)

      {:ok, _projection_module} ->
        case PublicRead.resolve(kind, handle) do
          {:ok, data} -> Response.send_json(conn, 200, data)
          :not_found -> Response.not_found(conn)
        end
    end
  end

  match _ do
    conn
    |> set_response_headers()
    |> Response.not_found()
  end

  defp set_response_headers(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end
end
