defmodule Letflow.Routers.TenantConfig do
  @moduledoc "Stub sub-router for tenant-config routes. Routes added by REQ-078. All unmatched requests return the RFC 9457 404 problem document via `Letflow.Api.Response.not_found/1`. Mounted at /tenant-config by `Letflow.Plugs.ApiPipeline`."

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
