defmodule Letflow.Support.KeycloakTestClient do
  @moduledoc """
  Test-only Keycloak HTTP client for REQ-134's real-token integration path. Not part of
  the shipped application.

  Implements `lib/letflow/design/req134-real-keycloak-token-integration.md` §4.1
  exactly — do not add behavior beyond it without a design update.

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per `mix.exs`) —
  **not** part of the shipped application, never referenced from `lib/`, and never added
  to `lib/letflow/application.ex`'s supervision tree. Not a GenServer, not a supervised
  process of any kind — a plain module of pure/IO functions, matching
  `Letflow.TenantSchemaReaper`/`Letflow.TenantFixture`'s established `test/support/`
  shape (module doc explicitly disclaiming supervision).

  Uses Erlang/OTP's built-in `:httpc` (the `:inets` application) rather than adding a new
  `mix.exs` HTTP-client dependency purely for one excluded-by-default test file (design
  §3.2's decision).
  """

  @type token_error ::
          {:http_error, status :: pos_integer(), body :: String.t()}
          | {:transport_error, reason :: term()}
          | {:unexpected_response, term()}

  # Design §3.2: short, explicit timeouts turn "Keycloak is down" into a fast, clear
  # skip/error instead of ExUnit's own (much longer) default test timeout expiring
  # mid-setup_all.
  @http_options [timeout: 2_000, connect_timeout: 1_000]

  @doc """
  `Application.ensure_all_started(:inets)` — idempotent, safe to call every time.
  Called at the top of `discovery_reachable?/1` and `direct_access_token/4` so callers
  never need to sequence this themselves.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    :ok
  end

  @doc """
  GETs `discovery_url` via `:httpc` with the short timeout from §3.2. `true` only on
  HTTP 200; `false` on any transport error, non-200 status, or timeout. Never raises —
  a reachability probe that could raise would turn "Keycloak down" into a test *crash*
  in `setup_all` rather than the intended `{:skip, _}`.
  """
  @spec discovery_reachable?(discovery_url :: String.t()) :: boolean()
  def discovery_reachable?(discovery_url) do
    ensure_started()

    case :httpc.request(:get, {String.to_charlist(discovery_url), []}, @http_options, []) do
      {:ok, {{_http_version, 200, _reason_phrase}, _headers, _body}} -> true
      _other -> false
    end
  rescue
    _exception -> false
  end

  @doc """
  POSTs a direct-access-grant (resource-owner-password) request to Keycloak's token
  endpoint: form-encoded body
  `grant_type=password&client_id=<opts[:client_id]>&username=<username>&password=<password>`,
  `Content-Type: application/x-www-form-urlencoded`, via `:httpc` with the short timeout
  from §3.2.

  `opts[:client_id]` has no default (always passed explicitly by the caller as
  `"letflow-web"`, matching `priv/keycloak/realms/bpm-default.json`'s public client) so
  this module carries no realm-specific literal itself.

  On HTTP 200, decodes the JSON body via `Jason.decode!/1` and returns
  `{:ok, body["access_token"]}`. Any non-200 status returns
  `{:error, {:http_error, status, body}}`; a transport failure returns
  `{:error, {:transport_error, reason}}`; a 200 response whose body doesn't decode to a
  map with an `"access_token"` string key returns
  `{:error, {:unexpected_response, decoded_or_raw}}`.
  """
  @spec direct_access_token(
          token_url :: String.t(),
          username :: String.t(),
          password :: String.t(),
          opts :: [client_id: String.t()]
        ) :: {:ok, raw_token :: String.t()} | {:error, token_error()}
  def direct_access_token(token_url, username, password, opts) do
    ensure_started()

    client_id = Keyword.fetch!(opts, :client_id)

    body =
      URI.encode_query(%{
        "grant_type" => "password",
        "client_id" => client_id,
        "username" => username,
        "password" => password
      })

    request =
      {String.to_charlist(token_url), [], ~c"application/x-www-form-urlencoded",
       String.to_charlist(body)}

    case :httpc.request(:post, request, @http_options, []) do
      {:ok, {{_http_version, 200, _reason_phrase}, _headers, response_body}} ->
        decode_access_token(response_body)

      {:ok, {{_http_version, status, _reason_phrase}, _headers, response_body}} ->
        {:error, {:http_error, status, to_string(response_body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp decode_access_token(response_body) do
    case Jason.decode(to_string(response_body)) do
      {:ok, %{"access_token" => access_token}} when is_binary(access_token) ->
        {:ok, access_token}

      {:ok, decoded} ->
        {:error, {:unexpected_response, decoded}}

      {:error, _reason} ->
        {:error, {:unexpected_response, to_string(response_body)}}
    end
  end

  @doc """
  Splits `raw_token` on `"."` (JWT compact serialization: header.payload.signature), and
  returns the same header and payload segments with the signature segment replaced by a
  same-length string of a different base64url alphabet character repeated (mapping every
  non-`"A"` char to `"A"` and `"A"` to `"B"`, so the result is guaranteed to differ from
  the original signature bit-for-bit while staying syntactically a three-segment JWT).

  Raises `ArgumentError` if `raw_token` does not have exactly 3 `"."`-separated segments
  (a defensive guard — this helper must never silently hand back an unmodified or
  malformed token). This is the ONLY place this design introduces per-byte mutation
  logic — `AuthPipeline`/`Oidcc` verification is never touched.
  """
  @spec tamper_signature(raw_token :: String.t()) :: String.t()
  def tamper_signature(raw_token) do
    case String.split(raw_token, ".") do
      [header, payload, signature] ->
        Enum.join([header, payload, tamper(signature)], ".")

      _other ->
        raise ArgumentError,
              "expected a 3-segment JWT (header.payload.signature), got: #{inspect(raw_token)}"
    end
  end

  defp tamper(signature) do
    signature
    |> String.graphemes()
    |> Enum.map(fn
      "A" -> "B"
      _other -> "A"
    end)
    |> Enum.join()
  end
end
