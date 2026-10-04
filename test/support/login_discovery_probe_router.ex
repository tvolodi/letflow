defmodule Letflow.LoginDiscoveryProbeRouter do
  @moduledoc """
  REQ-436 test-only stub router. Chain, in order: `Letflow.Plugs.ClientIp`,
  `Letflow.Plugs.LoginDiscoveryRateLimit`, `:match`, `:dispatch` -- the shape
  REQ-437 will mount, with NO body parsing before the limiter (first-plug rule).

  * `POST /probe` -- returns 200 when the limiter admits the request.
  * `POST /probe-email` -- takes an opaque email key from the `x-test-email-key`
    header and the bucket kind from `x-test-kind` (`"send"`, otherwise
    `"request"`), calls `consume_email/2`, and on refusal produces the 429
    through the real `send_rate_limited/1` constructor.

  Lives in `test/support` (compiled only in `:test`, see `mix.exs`
  `elixirc_paths/1`); it is never reachable from `Letflow.Router`.
  """

  use Plug.Router

  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter

  plug(Letflow.Plugs.ClientIp)
  plug(Letflow.Plugs.LoginDiscoveryRateLimit)
  plug(:match)
  plug(:dispatch)

  post "/probe" do
    send_resp(conn, 200, "ok")
  end

  post "/probe-email" do
    [key | _] = get_req_header(conn, "x-test-email-key")

    kind =
      case get_req_header(conn, "x-test-kind") do
        ["send" | _] -> :send
        _ -> :request
      end

    case Limiter.consume_email(key, kind) do
      :ok -> send_resp(conn, 200, "ok")
      :rate_limited -> Limiter.send_rate_limited(conn)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
