defmodule Letflow.Plugs.ClientIp do
  @moduledoc """
  REQ-439 (REQ-CIP; design lib/letflow/design/req439-trusted-proxy-client-ip.md) --
  trusted-proxy client IP resolution for the login-discovery per-IP rate limiter.

  Behind Cloudflare -> nginx -> published container port, `conn.remote_ip` is the
  proxy hop, identical for every visitor. This plug sets `conn.assigns.client_ip`
  to the real visitor address, but ONLY when the TCP peer is inside a configured
  trusted CIDR AND carries exactly one well-formed `X-Real-IP` value. Every other
  case (empty trust list, untrusted peer, zero/several/comma-list/unparsable
  header) yields `conn.remote_ip` itself -- the stricter shared bucket, never a
  caller-chosen value (INV-5).

  Invariants: `conn.remote_ip` is never rewritten; `X-Forwarded-For` and
  `Forwarded` are never read; the request body is never read; nothing is logged
  and no IP, header value, CIDR entry or env value appears in any error term
  (INV-4). The pure functions are total over their stated input types: untrusted
  bytes are pre-checked and never passed to `String.to_charlist/1`.

  The trust list is read per request (`call/2`), not in `init/1`: `Plug.Builder`
  runs `init/1` at compile time, before `config/runtime.exs`, so a value read
  there would be the compile-time `[]` on a release.

  The plug is mount-agnostic; it is wired into a router by REQ-437, not here.
  """

  @behaviour Plug

  import Bitwise

  @type cidr :: {:inet.ip_address(), prefix_len :: 0..128}

  @doc "Pass-through; deliberately does not read application config (see moduledoc)."
  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc "Assigns `:client_ip` (an `:inet.ip_address()`) on every request; never halts."
  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    trusted = trusted_proxies(opts)
    values = Plug.Conn.get_req_header(conn, "x-real-ip")
    Plug.Conn.assign(conn, :client_ip, resolve(conn.remote_ip, values, trusted))
  end

  defp trusted_proxies(opts) do
    case Keyword.fetch(opts, :trusted_proxies) do
      {:ok, list} when is_list(list) ->
        list

      _ ->
        :letflow
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:trusted_proxies, [])
    end
  end

  @doc """
  Resolves the client address. Returns the original `peer` term on every
  fallback, so `client_ip == conn.remote_ip` holds exactly.
  """
  @spec resolve(:inet.ip_address(), [String.t()], [cidr()]) :: :inet.ip_address()
  def resolve(peer, x_real_ip_values, cidrs) do
    with true <- trusted?(peer, cidrs),
         [value] <- x_real_ip_values,
         {:ok, ip} <- parse_header_address(value) do
      ip
    else
      _ -> peer
    end
  end

  @doc "True iff some cidr in the list matches the address (IPv4-mapped IPv6 is treated as IPv4)."
  @spec trusted?(:inet.ip_address(), [cidr()]) :: boolean()
  def trusted?(ip, cidrs) when is_list(cidrs) do
    ip = normalise(ip)
    Enum.any?(cidrs, &matches?(ip, &1))
  end

  @doc """
  Parses a comma-separated CIDR/address list. Blank segments are dropped
  (`""` -> `{:ok, []}`); any bad segment fails the whole list with the bare
  `{:error, :invalid_cidr}` (no entry or value in the term).
  """
  @spec parse_cidrs(String.t()) :: {:ok, [cidr()]} | {:error, :invalid_cidr}
  def parse_cidrs(string) when is_binary(string) do
    segments =
      string
      |> :binary.split(",", [:global])
      |> Enum.map(&trim_ascii/1)
      |> Enum.reject(&(&1 == ""))

    segments
    |> Enum.reduce_while([], fn segment, acc ->
      case parse_cidr(segment) do
        {:ok, cidr} -> {:cont, [cidr | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_cidr}
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  @doc "nil or blank gives the default; exactly `\"true\"`/`\"false\"` parse; anything else is an error."
  @spec parse_enabled(String.t() | nil, boolean()) ::
          {:ok, boolean()} | {:error, :invalid_boolean}
  def parse_enabled(nil, default), do: {:ok, default}

  def parse_enabled(value, default) when is_binary(value) do
    case trim_ascii(value) do
      "" -> {:ok, default}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, :invalid_boolean}
    end
  end

  @doc """
  Boot decision table for `config/runtime.exs`. `cidrs` is the NORMALISED list
  from `parse_cidrs/1`.
  """
  @spec boot_check(atom(), boolean(), [cidr()]) ::
          :ok | :warn | :warn_zero_prefix | {:error, :prod_requires_trusted_proxies}
  def boot_check(_env, false, _cidrs), do: :ok
  def boot_check(:prod, true, []), do: {:error, :prod_requires_trusted_proxies}
  def boot_check(_env, true, []), do: :warn

  def boot_check(_env, true, cidrs) do
    if Enum.any?(cidrs, fn {_ip, prefix} -> prefix == 0 end), do: :warn_zero_prefix, else: :ok
  end

  # --- header address -------------------------------------------------------

  defp parse_header_address(value) when is_binary(value) do
    trimmed = trim_ascii(value)

    if trimmed != "" and printable_ascii?(trimmed) and
         not String.contains?(trimmed, [",", "%", "[", "]", "/"]) do
      case :inet.parse_strict_address(:binary.bin_to_list(trimmed)) do
        {:ok, ip} -> {:ok, ip}
        _ -> :error
      end
    else
      :error
    end
  end

  defp parse_header_address(_), do: :error

  # --- CIDR parsing ---------------------------------------------------------

  defp parse_cidr(segment) do
    if printable_ascii?(segment) and not String.contains?(segment, "%") do
      case :binary.split(segment, "/", [:global]) do
        [addr] -> build_cidr(addr, nil)
        [addr, prefix] -> build_cidr(addr, prefix)
        _ -> :error
      end
    else
      :error
    end
  end

  defp build_cidr(addr, prefix_str) do
    with {:ok, ip} <- :inet.parse_strict_address(:binary.bin_to_list(addr)),
         {:ok, prefix} <- parse_prefix(prefix_str, ip) do
      {:ok, normalise_cidr({ip, prefix})}
    else
      _ -> :error
    end
  end

  defp parse_prefix(nil, ip), do: {:ok, max_prefix(ip)}

  defp parse_prefix(str, ip) when byte_size(str) in 1..3 do
    if digits_only?(str) do
      n = String.to_integer(str)
      if n <= max_prefix(ip), do: {:ok, n}, else: :error
    else
      :error
    end
  end

  defp parse_prefix(_, _), do: :error

  defp max_prefix(ip) when tuple_size(ip) == 4, do: 32
  defp max_prefix(ip) when tuple_size(ip) == 8, do: 128

  defp normalise_cidr({{0, 0, 0, 0, 0, 0xFFFF, hi, lo}, prefix}) when prefix >= 96,
    do: {mapped_to_v4(hi, lo), prefix - 96}

  defp normalise_cidr(cidr), do: cidr

  # --- matching -------------------------------------------------------------

  defp normalise({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: mapped_to_v4(hi, lo)
  defp normalise(ip), do: ip

  defp mapped_to_v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp matches?(ip, {base, prefix})
       when tuple_size(ip) == tuple_size(base) and is_integer(prefix) do
    bits = max_prefix(ip)
    shift = bits - prefix
    to_int(ip) >>> shift == to_int(base) >>> shift
  end

  defp matches?(_ip, _cidr), do: false

  defp to_int(ip) when tuple_size(ip) == 4 do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn o, acc -> acc <<< 8 ||| o end)
  end

  defp to_int(ip) when tuple_size(ip) == 8 do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn g, acc -> acc <<< 16 ||| g end)
  end

  # --- byte helpers (ASCII only; total over arbitrary binaries) --------------

  defp trim_ascii(bin), do: bin |> trim_leading() |> trim_trailing()

  defp trim_leading(<<c, rest::binary>>) when c in [?\s, ?\t], do: trim_leading(rest)
  defp trim_leading(bin), do: bin

  defp trim_trailing(bin) do
    size = byte_size(bin)

    if size > 0 and :binary.at(bin, size - 1) in [?\s, ?\t] do
      trim_trailing(binary_part(bin, 0, size - 1))
    else
      bin
    end
  end

  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(<<c, rest::binary>>) when c in 0x21..0x7E, do: printable_ascii?(rest)
  defp printable_ascii?(_), do: false

  defp digits_only?(<<>>), do: true
  defp digits_only?(<<c, rest::binary>>) when c in ?0..?9, do: digits_only?(rest)
  defp digits_only?(_), do: false
end
