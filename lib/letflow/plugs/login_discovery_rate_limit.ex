defmodule Letflow.Plugs.LoginDiscoveryRateLimit do
  @moduledoc """
  REQ-436 (design `req436-login-discovery-rate-limiter.md`, governed by
  `req434-email-first-login-directory.md` s0.3 D5/D6/D10/D11/D13/D14) -- the
  mounting precondition for REQ-437's unauthenticated login-discovery mount.

  Designed to run immediately after `Letflow.Plugs.ClientIp` at the head of
  the router chain, ahead of `plug(:match)`, so the 429 is input-independent
  and the body is never read. The client address is `conn.assigns.client_ip`,
  falling back to `conn.remote_ip`; never a raw forwarded header.

  Order: the per-IP bucket (IPv6 aggregated to its /64, IPv4-mapped IPv6
  mapped to IPv4) is consumed FIRST; an IP refusal halts without touching the
  global bucket. Only an IP-admitted request consumes the global bucket.
  Per-email buckets are exposed as `consume_email/2,3` for the endpoint and
  notifier task to call once they hold the email key.

  Every refusal goes through ONE constructor, `send_rate_limited/1`, so
  status, headers and body are identical by construction and carry no
  cause- or email-dependent content.

  State is entirely separate from `Letflow.Plugs.PublicReadRateLimit` (own
  table, every key namespaced `:login_discovery`); that module and its
  `Bucket` are unchanged. The token-bucket algorithm is shared with it in
  idea only -- see `Letflow.Plugs.PublicReadRateLimit.Bucket`.

  Configuration: `config :letflow, Letflow.Plugs.LoginDiscoveryRateLimit, ...`
  (keys in `defaults/0`), read per call, never in `init/1`. This module
  emits no `Logger` output (INV-4); refusals emit the telemetry event
  `[:letflow, :login_discovery, :outcome]` with metadata `%{outcome: ...}`
  only.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Plugs.LoginDiscoveryRateLimit.Bucket

  @cache_control "private, no-store"
  @referrer_policy "no-referrer"
  @robots_tag "noindex, nofollow"

  @type ip_bucket_id :: Bucket.ip_bucket_id()

  @refill_keys [
    :global_refill_per_sec,
    :ip_refill_per_sec,
    :email_refill_per_sec,
    :send_refill_per_sec
  ]
  @int_keys [
    :global_capacity,
    :ip_capacity,
    :email_capacity,
    :send_capacity,
    :max_email_keys,
    :max_ip_keys,
    :sweep_interval_ms,
    :retry_after_seconds,
    :inline_sweep_min_interval_ms
  ]

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    config = config()
    id = ip_bucket_id(client_address(conn))

    case Bucket.consume({:login_discovery, :ip, id}, config.ip_capacity, config.ip_refill_per_sec) do
      :rate_limited ->
        emit(:rate_limited_ip)
        send_rate_limited(conn)

      :ok ->
        case Bucket.consume(
               {:login_discovery, :global},
               config.global_capacity,
               config.global_refill_per_sec
             ) do
          :ok ->
            conn

          :rate_limited ->
            emit(:rate_limited_global)
            send_rate_limited(conn)
        end
    end
  end

  @doc """
  Consumes the per-address bucket for `email_key` (an opaque binary): kind
  `:request` is the request bucket, `:send` the per-address minimum send
  interval. Emits `:rate_limited_email` on refusal; does not send a response.
  """
  @spec consume_email(binary(), :request | :send) :: :ok | :rate_limited
  def consume_email(email_key, kind) do
    consume_email(email_key, kind, System.monotonic_time(:millisecond))
  end

  @spec consume_email(binary(), :request | :send, integer()) :: :ok | :rate_limited
  def consume_email(email_key, kind, now_ms)
      when is_binary(email_key) and kind in [:request, :send] do
    config = config()

    {key, capacity, refill} =
      case kind do
        :request ->
          {{:login_discovery, :email_hmac, email_key}, config.email_capacity,
           config.email_refill_per_sec}

        :send ->
          {{:login_discovery, :email_send, email_key}, config.send_capacity,
           config.send_refill_per_sec}
      end

    case Bucket.consume(key, capacity, refill, now_ms) do
      :ok ->
        :ok

      :rate_limited ->
        emit(:rate_limited_email)
        :rate_limited
    end
  end

  @doc """
  The single 429 constructor: constant headers, fixed body, halts. Nothing
  about the refusal cause, the email, the IP or the key reaches it.
  """
  @spec send_rate_limited(Plug.Conn.t()) :: Plug.Conn.t()
  def send_rate_limited(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(config().retry_after_seconds))
    |> put_resp_header("cache-control", @cache_control)
    |> put_resp_header("referrer-policy", @referrer_policy)
    |> put_resp_header("x-robots-tag", @robots_tag)
    |> Response.rate_limited("rate limit exceeded")
    |> halt()
  end

  @doc "Resolved client address: the `client_ip` assign, else `conn.remote_ip`."
  @spec client_address(Plug.Conn.t()) :: :inet.ip_address()
  def client_address(conn) do
    case conn.assigns[:client_ip] do
      {a, b, c, d} = ip when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
        ip

      {_, _, _, _, _, _, _, _} = ip ->
        if valid_v6?(ip), do: ip, else: conn.remote_ip

      _ ->
        conn.remote_ip
    end
  end

  defp valid_v6?(ip), do: ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..65535))

  @doc "Maps an address to its bucket id: IPv6 -> /64, IPv4-mapped IPv6 -> IPv4."
  @spec ip_bucket_id(:inet.ip_address()) :: ip_bucket_id()
  def ip_bucket_id({_, _, _, _} = v4), do: {:v4, v4}

  def ip_bucket_id({0, 0, 0, 0, 0, 0xFFFF, g7, g8}) do
    {:v4, {div(g7, 256), rem(g7, 256), div(g8, 256), rem(g8, 256)}}
  end

  def ip_bucket_id({a, b, c, d, _, _, _, _}), do: {:v6_64, {a, b, c, d}}

  @doc "Default configuration (design s12.4 / s6.1)."
  @spec defaults() :: keyword()
  def defaults do
    [
      global_capacity: 60,
      global_refill_per_sec: 10,
      ip_capacity: 10,
      ip_refill_per_sec: 0.5,
      email_capacity: 5,
      email_refill_per_sec: 1 / 60,
      send_capacity: 1,
      send_refill_per_sec: 1 / 900,
      max_email_keys: 50_000,
      max_ip_keys: 100_000,
      sweep_interval_ms: 30_000,
      retry_after_seconds: 60,
      inline_sweep_min_interval_ms: 1_000
    ]
  end

  @doc "Defaults merged with application env, as a map (read per call)."
  @spec config() :: map()
  def config do
    defaults()
    |> Keyword.merge(Application.get_env(:letflow, __MODULE__, []))
    |> Map.new()
  end

  @doc """
  Validates `overrides` merged over `defaults/0`; raises `ArgumentError`
  naming the offending key(s). Called at boot from `Bucket.init/1`.
  """
  @spec validate_config!(keyword()) :: :ok
  def validate_config!(overrides) do
    c = defaults() |> Keyword.merge(overrides) |> Map.new()

    for k <- @int_keys, not (is_integer(c[k]) and c[k] > 0) do
      raise ArgumentError, "#{inspect(k)} must be a positive integer"
    end

    for k <- @refill_keys do
      v = c[k]

      unless is_number(v) and v > 0 do
        raise ArgumentError, "#{inspect(k)} must be a positive number"
      end

      if round(v * 1_000_000) < 1 do
        raise ArgumentError, "#{inspect(k)}: refill rounds to zero micro-tokens per second"
      end
    end

    if c.max_ip_keys < c.ip_capacity do
      raise ArgumentError, "max_ip_keys must be >= ip_capacity"
    end

    t_email_full_max =
      max(c.email_capacity / c.email_refill_per_sec, c.send_capacity / c.send_refill_per_sec)

    required =
      2 *
        (c.global_capacity +
           ceil(c.global_refill_per_sec * (t_email_full_max + c.sweep_interval_ms / 1000)))

    if c.max_email_keys < required do
      raise ArgumentError,
            "max_email_keys (#{c.max_email_keys}) must be >= " <>
              "2 * (global_capacity + ceil(global_refill_per_sec * " <>
              "(t_email_full_max + sweep_interval_s))) = #{required}"
    end

    :ok
  end

  defp emit(outcome) do
    :telemetry.execute([:letflow, :login_discovery, :outcome], %{count: 1}, %{outcome: outcome})
  end
end
