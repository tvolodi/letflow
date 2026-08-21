defmodule Letflow.Routers.Definitions do
  @moduledoc "Stub sub-router for definitions routes. Routes added by REQ-081/082. All unmatched requests return the RFC 9457 404 problem document via `Letflow.Api.Response.not_found/1`. Mounted at /definitions by `Letflow.Plugs.ApiPipeline`."

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
