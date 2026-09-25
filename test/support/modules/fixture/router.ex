defmodule Letflow.Modules.Fixture.Router do
  @moduledoc """
  The fixture module's one-route `router/0` (REQ-400 §4.2), matching its own
  `manifest/0`'s single `route_policies` entry (`{"GET", "/items/:id",
  :FixtureRead}`) exactly. Relative to the module's own mount
  `/api/v1/modules/fixture` (REQ-400 does not mount this router — REQ-403/404
  do; this module was not reachable over HTTP under REQ-400/402/403's own
  scope).

  REQ-404 (design `lib/letflow/design/req404-module-router-mount.md` §0.1):
  `use Letflow.Api.AuthorizedRouter`, not a plain `use Plug.Router` — the
  same `authz_get`/`Letflow.Plugs.Authorize` shape every core router already
  uses (see `lib/letflow/routers/tenant_modules.ex`). Necessary, not merely
  convenient: without a real authorization check here, every caller who
  clears `Letflow.Routers.Modules`' D5 install-gate would get `200`
  regardless of role, making AC2's 403-branch structurally untestable.
  """

  use Letflow.Api.AuthorizedRouter

  authz_get "/items/:id", :FixtureRead do
    send_resp(conn, 200, Jason.encode!(%{fixture: true, id: id}))
  end
end
