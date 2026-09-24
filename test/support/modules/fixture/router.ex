defmodule Letflow.Modules.Fixture.Router do
  @moduledoc """
  The fixture module's one-route `router/0` (REQ-400 §4.2), matching its own
  `manifest/0`'s single `route_policies` entry (`{"GET", "/items/:id",
  :FixtureRead}`) exactly. Relative to the module's own mount
  `/api/v1/modules/fixture` (REQ-400 does not mount this router — REQ-403/404
  do; this module is not reachable over HTTP under REQ-400's own scope).
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/items/:id" do
    send_resp(conn, 200, Jason.encode!(%{fixture: true, id: id}))
  end
end
