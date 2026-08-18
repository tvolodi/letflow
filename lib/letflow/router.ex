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

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
