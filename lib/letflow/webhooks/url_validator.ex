defmodule Letflow.Webhooks.UrlValidator do
  @moduledoc """
  Validates a webhook `target_url` before any outbound HTTP request is made —
  scheme allowlist check followed by a private-range IP blocklist check (including
  post-DNS-resolution, catching DNS rebinding).

  All rejected IP ranges are **Letflow's own choice**, not ported from R-Co
  (R-Co's `src/webhook/` SSRF handling is not inspectable from this codebase's
  history):

  - 127.0.0.0/8 — loopback
  - 10.0.0.0/8 — RFC-1918 private
  - 172.16.0.0/12 — RFC-1918 private
  - 192.168.0.0/16 — RFC-1918 private
  - 169.254.0.0/16 — link-local, including 169.254.169.254 (cloud metadata)
  - ::1/128 — IPv6 loopback
  - fc00::/7 — IPv6 ULA (unique local)
  - fe80::/10 — IPv6 link-local (REVIEWER-approved, OQ-1 — same attack class as 169.254.0.0/16)
  - IPv4-mapped-IPv6 forms (::ffff:A.B.C.D and ::A.B.C.D) of any IPv4 ranges above

  Only `"https"` is permitted as URL scheme; `"http"` and all other schemes
  are rejected.
  """

  import Bitwise

  @type dns_resolver ::
          (charlist() ->
             {:ok,
              [
                {:inet, {byte(), byte(), byte(), byte()}, []}
                | {:inet6,
                   {0..65535, 0..65535, 0..65535, 0..65535,
                    0..65535, 0..65535, 0..65535, 0..65535}, []}
              ]}
             | {:error, term()})

  @spec validate(url :: String.t()) :: :ok | {:error, :target_url_not_allowed}
  def validate(url), do: validate(url, &default_resolver/1)

  @spec validate(url :: String.t(), dns_resolver()) ::
          :ok | {:error, :target_url_not_allowed}
  def validate(url, dns_resolver) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         :ok <- check_host(uri, dns_resolver) do
      :ok
    end
  end

  # Public so webhooks.ex can pass &UrlValidator.default_resolver/1 to
  # dispatch_http/4 without a captured closure.
  @doc false
  @spec default_resolver(charlist()) ::
          {:ok,
           [
             {:inet, {byte(), byte(), byte(), byte()}, []}
             | {:inet6,
                {0..65535, 0..65535, 0..65535, 0..65535,
                 0..65535, 0..65535, 0..65535, 0..65535}, []}
           ]}
          | {:error, term()}
  def default_resolver(host_charlist), do: resolve_all(host_charlist)

  # Wraps :inet.getaddrs/2 for both :inet and :inet6, returning the tagged
  # list shape the dns_resolver type specifies. DNS failure = blocked.
  @spec resolve_all(charlist()) ::
          {:ok,
           [
             {:inet, {byte(), byte(), byte(), byte()}, []}
             | {:inet6,
                {0..65535, 0..65535, 0..65535, 0..65535,
                 0..65535, 0..65535, 0..65535, 0..65535}, []}
           ]}
          | {:error, term()}
  defp resolve_all(host_charlist) do
    v4 =
      case :inet.getaddrs(host_charlist, :inet) do
        {:ok, addrs} -> Enum.map(addrs, fn addr -> {:inet, addr, []} end)
        {:error, _} -> []
      end

    v6 =
      case :inet.getaddrs(host_charlist, :inet6) do
        {:ok, addrs} -> Enum.map(addrs, fn addr -> {:inet6, addr, []} end)
        {:error, _} -> []
      end

    case v4 ++ v6 do
      [] -> {:error, :nxdomain}
      addrs -> {:ok, addrs}
    end
  end

  @spec check_scheme(URI.t()) :: :ok | {:error, :target_url_not_allowed}
  defp check_scheme(%URI{scheme: "https"}), do: :ok
  defp check_scheme(_), do: {:error, :target_url_not_allowed}

  @spec check_host(URI.t(), dns_resolver()) :: :ok | {:error, :target_url_not_allowed}
  defp check_host(%URI{host: nil}, _dns_resolver), do: {:error, :target_url_not_allowed}
  defp check_host(%URI{host: ""}, _dns_resolver), do: {:error, :target_url_not_allowed}

  defp check_host(%URI{host: host}, dns_resolver) do
    case check_ip_literal(host) do
      :not_an_ip -> resolve_and_check(String.to_charlist(host), dns_resolver)
      result -> result
    end
  end

  @spec check_ip_literal(host :: String.t()) ::
          :ok | {:error, :target_url_not_allowed} | :not_an_ip
  defp check_ip_literal(host) do
    # Defensive bracket strip; URI.parse/1 strips them in Elixir 1.14+ but
    # :inet.parse_address/1 does not accept the bracket form.
    stripped = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(stripped)) do
      {:ok, {a, b, c, d}} ->
        if blocked_ipv4?({a, b, c, d}), do: {:error, :target_url_not_allowed}, else: :ok

      {:ok, {a, b, c, d, e, f, g, h}} ->
        if blocked_ipv6?({a, b, c, d, e, f, g, h}),
          do: {:error, :target_url_not_allowed},
          else: :ok

      {:error, _} ->
        :not_an_ip
    end
  end

  @spec resolve_and_check(host_charlist :: charlist(), dns_resolver()) ::
          :ok | {:error, :target_url_not_allowed}
  defp resolve_and_check(host_charlist, dns_resolver) do
    case dns_resolver.(host_charlist) do
      {:ok, addrs} ->
        blocked =
          Enum.any?(addrs, fn
            {:inet, tuple, _} -> blocked_ipv4?(tuple)
            {:inet6, tuple, _} -> blocked_ipv6?(tuple)
          end)

        if blocked, do: {:error, :target_url_not_allowed}, else: :ok

      {:error, _} ->
        {:error, :target_url_not_allowed}
    end
  end

  @spec blocked_ipv4?({byte(), byte(), byte(), byte()}) :: boolean()
  defp blocked_ipv4?({127, _, _, _}), do: true
  defp blocked_ipv4?({10, _, _, _}), do: true
  defp blocked_ipv4?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp blocked_ipv4?({192, 168, _, _}), do: true
  defp blocked_ipv4?({169, 254, _, _}), do: true
  defp blocked_ipv4?(_), do: false

  @spec blocked_ipv6?(
          {0..65535, 0..65535, 0..65535, 0..65535,
           0..65535, 0..65535, 0..65535, 0..65535}
        ) :: boolean()
  defp blocked_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # fc00::/7: first 16-bit group in 0xFC00..0xFDFF
  defp blocked_ipv6?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  # fe80::/10 — IPv6 link-local (same attack class as 169.254.0.0/16, REVIEWER-approved OQ-1)
  defp blocked_ipv6?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  # IPv4-mapped ::ffff:A.B.C.D
  defp blocked_ipv6?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: blocked_ipv4?(ipv4_from_mapped_ipv6({0, 0, 0, 0, 0, 0xFFFF, hi, lo}))

  # IPv4-compatible ::A.B.C.D (excluding ::0.0.0.0 and ::0.0.0.1)
  defp blocked_ipv6?({0, 0, 0, 0, 0, 0, hi, lo}) when hi != 0 or lo > 1,
    do: blocked_ipv4?(ipv4_from_mapped_ipv6({0, 0, 0, 0, 0, 0, hi, lo}))

  defp blocked_ipv6?(_), do: false

  @spec ipv4_from_mapped_ipv6(
          {0..65535, 0..65535, 0..65535, 0..65535,
           0..65535, 0..65535, 0..65535, 0..65535}
        ) :: {byte(), byte(), byte(), byte()} | nil
  defp ipv4_from_mapped_ipv6({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
  end

  defp ipv4_from_mapped_ipv6({0, 0, 0, 0, 0, 0, hi, lo}) when hi != 0 or lo > 1 do
    {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
  end

  defp ipv4_from_mapped_ipv6(_), do: nil
end
