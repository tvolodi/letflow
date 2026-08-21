defmodule Letflow.Routers.Promotion do
  @moduledoc "Stub sub-router for promotion routes. Routes added by REQ-077. All unmatched requests return the RFC 9457 404 problem document via `Letflow.Api.Response.not_found/1`. Mounted at /promotion by `Letflow.Plugs.ApiPipeline`."

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
