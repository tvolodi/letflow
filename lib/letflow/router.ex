defmodule Letflow.Router do
  @moduledoc """
  Deliberately minimal — Plug + Bandit, no Phoenix. `/health` only as of REQ-046; the
  `POST/GET /instances...` pilot-slice routes this module carried through S1-S3 were
  removed alongside `Letflow.ProcessInstance`'s own retirement (see
  `lib/letflow/design/req046-process-instance-retirement.md` §6a) — S4 (api-surface)
  is expected to add the real `/api/v1/instances` routes against
  `Letflow.Engine.create/2`, not a revival of this pilot contract.
  """

  use Plug.Router

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  # GET /health -> {"status": "ok"} — used by deploy/redeploy-test.sh's
  # post-deploy health check, no auth/DB dependency by design so it stays
  # reliable as a liveness signal.
  get "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  # Every 404 this application emits — catch-all included — goes through the one
  # `Letflow.Api.Error.not_found/0` constructor (REQ-066), so no route renders an
  # error body by hand and all 404 bodies are byte-identical by construction.
  match _ do
    Letflow.Api.Response.not_found(conn)
  end

  # Delegates to the shared response contract (REQ-066) rather than keeping a
  # second copy of the same encode-and-send logic. Behaviour is identical:
  # `Letflow.Api.Response.send_json/3` is the same
  # put_resp_content_type("application/json") + Jason.encode! + send_resp.
  defp send_json(conn, status, body), do: Letflow.Api.Response.send_json(conn, status, body)
end
