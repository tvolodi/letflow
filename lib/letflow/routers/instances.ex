defmodule Letflow.Routers.Instances do
  @moduledoc "Stub sub-router for instances routes. Routes added by REQ-079/080. All unmatched requests return the RFC 9457 404 problem document via `Letflow.Api.Response.not_found/1`. Mounted at /instances by `Letflow.Plugs.ApiPipeline`."

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
