defmodule Letflow.Routers.Tasks do
  @moduledoc "Stub sub-router for tasks routes. Routes added by REQ-083/085. All unmatched requests return the RFC 9457 404 problem document via `Letflow.Api.Response.not_found/1`. Mounted at /tasks by `Letflow.Plugs.ApiPipeline`."

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
