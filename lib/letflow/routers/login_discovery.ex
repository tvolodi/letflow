defmodule Letflow.Routers.LoginDiscovery do
  @moduledoc """
  REQ-437 -- the public, credential-free email-first login-discovery mount
  (design `lib/letflow/design/req434-email-first-login-directory.md` s5, s7,
  s10, s12, s13, s15.3; decisions 0042/0043).

  Mounted by `Letflow.Router` via `forward("/api/login-discovery", ...)`, after
  `/api/public` and before `/api/v1`, so it never enters
  `Letflow.Plugs.AuthPipeline` (not modified). Public by mount position.

  | Handler   | Method/path                 | Auth     | DB                                   | Response |
  |-----------|-----------------------------|----------|--------------------------------------|----------|
  | lookup    | `POST /api/login-discovery` | **none** | global `tenant_login_directory` + `tenants` | `202` neutral, `200` single disclosed match, `429` |
  | catch-all | `match _`                   | **none** | none                                 | standard `404` |

  ## Chain (D25), in order

  `enabled_gate/2` (mount switch, request-time config, emits `:disabled` and the
  standard 404 for every method/path when off, before anything else runs) ->
  `Letflow.Plugs.ClientIp` -> `Letflow.Plugs.LoginDiscoveryRateLimit` ->
  `:match` -> `:dispatch`. No `Plug.Parsers`, no trace-id plug.

  ## Handler sequence (design s5.3, identical for every input class)

  Bounded body read (whatever the content type) -> non-raising JSON decode ->
  `LoginDirectory.email_keys/1` (or `sentinel_keys/0` for malformed input; the
  all-zero constant key when the pepper is unavailable, D27) -> per-email bucket
  on the CURRENT key -> EXACTLY ONE `LoginDirectory.lookup_by_keys/1` ->
  `LoginDiscovery.decide/2` -> exactly one `Dispatch.submit/3` -> one outcome
  event -> hand-built response. The endpoint never calls `lookup_by_email/1`.
  The only returns ahead of the query on an enabled `POST /` are the three 429
  refusals. Malformed input is the neutral 202, never 400/415/422/500 (D26).

  ## Telemetry / logging (INV-4)

  Exactly one `[:letflow, :login_discovery, :outcome]` event per request that
  reaches this router, metadata `%{outcome: ...}` only: `:disabled` (gate),
  `:tenant` (200), `:accepted` (every 202), `:not_found` (404 on an enabled
  mount); the limiter emits the `:rate_limited_*` outcomes. The only log line is
  a fixed `Logger.error` when the pepper is unavailable. No email, key, IP, slug
  or tenant id is logged or put in telemetry.
  """

  use Plug.Router

  require Logger

  alias Letflow.Api.Response
  alias Letflow.LoginDirectory
  alias Letflow.LoginDiscovery
  alias Letflow.LoginDiscovery.Dispatch
  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter
  alias Letflow.Identity.TenantMembership

  @cache_control "private, no-store"
  @referrer_policy "no-referrer"
  @robots_tag "noindex, nofollow"
  @zero_key <<0::256>>

  plug(:enabled_gate)
  plug(Letflow.Plugs.ClientIp)
  plug(Letflow.Plugs.LoginDiscoveryRateLimit)
  plug(:match)
  plug(:dispatch)

  @doc """
  Mount switch (design s5.1, D12): when `enabled` (read at request time from
  `config :letflow, Letflow.Routers.LoginDiscovery`) is not exactly `true`,
  emits `:disabled`, answers the standard 404 and halts, before `ClientIp`, the
  limiter, body reading or any query.
  """
  @spec enabled_gate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def enabled_gate(conn, _opts) do
    if :letflow |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled) == true do
      conn
    else
      emit(:disabled)

      conn
      |> Response.not_found()
      |> halt()
    end
  end

  post "/" do
    {conn, email} = read_email(conn)
    {keys, recipient} = candidate_keys(email)

    case Limiter.consume_email(hd(keys), :request) do
      :rate_limited ->
        Limiter.send_rate_limited(conn)

      :ok ->
        result = LoginDirectory.lookup_by_keys(keys)
        mode = LoginDiscovery.mode()
        decision = LoginDiscovery.decide(mode, result)
        :ok = Dispatch.submit(recipient, mode, result)
        respond(conn, decision)
    end
  end

  match _ do
    emit(:not_found)
    Response.not_found(conn)
  end

  # ── request reading ─────────────────────────────────────────────────────

  # Bounded read whatever the content type; every failure is the malformed
  # class (`nil` email), never an early return.
  defp read_email(conn) do
    max = LoginDiscovery.max_body_bytes()

    case read_body(conn,
           length: max,
           read_length: max,
           read_timeout: LoginDiscovery.read_timeout()
         ) do
      {:ok, body, conn} ->
        {conn, decode_email(conn, body)}

      {:more, _partial, conn} ->
        {conn, nil}

      {:error, _reason} ->
        {conn, nil}
    end
  end

  defp decode_email(conn, body) do
    with true <- json_content_type?(conn),
         {:ok, %{"email" => email}} <- Jason.decode(body) do
      email
    else
      _malformed -> nil
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
          "application/json"

      [] ->
        false
    end
  end

  # ── keys (design s5.3 step 3, D27) ──────────────────────────────────────

  # Always returns a non-empty key list and the notifier recipient (nil unless
  # the input was a valid address with keys available).
  defp candidate_keys(email) do
    case LoginDirectory.email_keys(email) do
      {:ok, keys} ->
        {keys, TenantMembership.normalize_subject_key(email)}

      :invalid ->
        sentinel_or_degraded()

      {:error, :pepper_unavailable} ->
        degraded()
    end
  end

  defp sentinel_or_degraded do
    case LoginDirectory.sentinel_keys() do
      [_ | _] = keys -> {keys, nil}
      _unavailable -> degraded()
    end
  end

  # Pepper unavailable: the single query still runs with the all-zero constant
  # key (no writer can write it), and the one limiter key is shared (throttled).
  defp degraded do
    Logger.error("login discovery: key material unavailable")
    {[@zero_key], nil}
  end

  # ── responses (hand-built, literal keys) ────────────────────────────────

  defp respond(conn, {:match, %{slug: slug, display_name: display_name}}) do
    emit(:tenant)

    conn
    |> common_headers()
    |> Response.send_json(200, %{
      result: "tenant",
      tenant: %{slug: slug, display_name: display_name}
    })
  end

  defp respond(conn, :neutral) do
    emit(:accepted)

    conn
    |> common_headers()
    |> Response.send_json(202, %{result: "accepted"})
  end

  defp common_headers(conn) do
    conn
    |> put_resp_header("cache-control", @cache_control)
    |> put_resp_header("referrer-policy", @referrer_policy)
    |> put_resp_header("x-robots-tag", @robots_tag)
  end

  defp emit(outcome) do
    :telemetry.execute([:letflow, :login_discovery, :outcome], %{count: 1}, %{outcome: outcome})
  end
end
