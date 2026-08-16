defmodule Letflow.Router do
  @moduledoc """
  Deliberately minimal — Plug + Bandit, no Phoenix. Three endpoints,
  just enough to drive the state machine end to end over HTTP.
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

  # POST /instances -> {"id": "..."}
  post "/instances" do
    id = Ecto.UUID.generate()

    case Letflow.InstanceSupervisor.start_instance(id) do
      {:ok, _pid} -> send_json(conn, 201, %{id: id})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # POST /instances/:id/actions  body: {"action": "submit"}
  post "/instances/:id/actions" do
    result =
      case conn.body_params["action"] do
        "submit" -> Letflow.ProcessInstance.submit(id)
        "approve" -> Letflow.ProcessInstance.approve(id)
        "reject" -> Letflow.ProcessInstance.reject(id)
        "resubmit" -> Letflow.ProcessInstance.resubmit(id)
        other -> {:error, {:unknown_action, other}}
      end

    case result do
      :ok -> send_json(conn, 200, %{ok: true})
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  # GET /instances/:id -> {"state": "...", "history": [...]}
  get "/instances/:id" do
    case Letflow.ProcessInstance.get(id) do
      %{state: state, history: history} ->
        send_json(conn, 200, %{
          state: state,
          history: Enum.map(history, &encode_history_entry/1)
        })
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp encode_history_entry(%{action: action, from: from, to: to, at: at}) do
    %{action: action, from: from, to: to, at: DateTime.to_iso8601(at)}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
