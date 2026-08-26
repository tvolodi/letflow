defmodule Letflow.Routers.Promotion do
  @moduledoc """
  Stub sub-router for promotion routes. Routes added by REQ-077. All
  unmatched requests return the RFC 9457 404 problem document via
  `Letflow.Api.Response.not_found/1`. Mounted at /promotion by
  `Letflow.Plugs.ApiPipeline`.

  `use Letflow.Api.AuthorizedRouter` (REQ-131), not `use Plug.Router` — even
  though this module declares zero real routes yet, `Letflow.Plugs.Authorize`
  is already wired into its pipeline. REQ-077's future routes must be
  declared with this module's `authz_get`/`authz_post`/`authz_put`/
  `authz_patch`/`authz_delete` macros, each carrying its own policy key, and
  must NOT reintroduce a route-local `with_authorized_scope`/
  `with_authorization`-shaped helper (REQ-130's design §2.4) — the mandatory
  plug is already here, waiting.
  """

  use Letflow.Api.AuthorizedRouter

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
