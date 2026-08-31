defmodule Letflow.Webhooks.UrlValidatorTest do
  @moduledoc """
  Unit tests for `Letflow.Webhooks.UrlValidator`. See `test/specs/REQ-204.md`
  for the full acceptance-criterion -> test-case mapping and rationale.

  No database access. All hostname-based tests use injected DNS resolvers
  (`validate/2`) rather than real DNS lookups. IP-literal tests use `validate/1`
  safely because `check_ip_literal/1` short-circuits before any DNS call.
  """
  use ExUnit.Case, async: true

  alias Letflow.Webhooks.UrlValidator

  # ---------------------------------------------------------------------------
  # AC1 — non-https scheme is rejected before IP/DNS check
  # ---------------------------------------------------------------------------

  test "http:// scheme is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("http://example.com/hook")
  end

  test "ftp:// scheme is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("ftp://example.com/hook")
  end

  test "schemeless URL is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("example.com/hook")
  end

  test "empty string is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("")
  end

  # ---------------------------------------------------------------------------
  # AC2 — IPv4 private / loopback / link-local literals (no DNS needed)
  # ---------------------------------------------------------------------------

  test "IPv4 loopback 127.0.0.1 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://127.0.0.1/hook")
  end

  # 169.254.169.254 is the cloud instance-metadata service address; rejected
  # by the 169.254.0.0/16 link-local range.
  test "IPv4 link-local / cloud metadata 169.254.169.254 is rejected by name" do
    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://169.254.169.254/hook")
  end

  test "RFC-1918 10.0.0.5 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://10.0.0.5/hook")
  end

  test "RFC-1918 172.16.0.5 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://172.16.0.5/hook")
  end

  test "RFC-1918 192.168.0.5 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://192.168.0.5/hook")
  end

  # ---------------------------------------------------------------------------
  # IPv6 literals — all blocked
  # ---------------------------------------------------------------------------

  test "IPv6 loopback ::1 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://[::1]/hook")
  end

  test "IPv6 ULA fc00::1 is rejected (fc00::/7)" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://[fc00::1]/hook")
  end

  # fe80::/10 is IPv6 link-local (same attack class as 169.254.0.0/16);
  # added to the blocklist per REVIEWER OQ-1 approval.
  test "IPv6 link-local fe80::1 is rejected (fe80::/10, REVIEWER OQ-1)" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://[fe80::1]/hook")
  end

  test "IPv4-mapped IPv6 ::ffff:10.0.0.1 is rejected" do
    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://[::ffff:10.0.0.1]/hook")
  end

  test "IPv4-mapped IPv6 ::ffff:169.254.169.254 is rejected" do
    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://[::ffff:169.254.169.254]/hook")
  end

  # ---------------------------------------------------------------------------
  # AC3 — legitimate https public IP via injected resolver
  # ---------------------------------------------------------------------------

  test "hostname resolving to public IP via injected resolver is allowed" do
    resolver = fn _host -> {:ok, [{:inet, {93, 184, 216, 34}, []}]} end
    assert :ok = UrlValidator.validate("https://example.com/hook", resolver)
  end

  test "public IP literal (no DNS needed) is allowed" do
    assert :ok = UrlValidator.validate("https://93.184.216.34/hook")
  end

  # ---------------------------------------------------------------------------
  # AC4 — DNS rebinding via injected resolver
  # ---------------------------------------------------------------------------

  # The injected resolver simulates a hostname that resolved to a public IP
  # at subscription-creation time but now resolves to the cloud metadata
  # address at delivery time (DNS rebinding).
  test "hostname resolving to 169.254.169.254 at validation time is rejected (DNS rebinding)" do
    resolver = fn _host -> {:ok, [{:inet, {169, 254, 169, 254}, []}]} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://example.com/hook", resolver)
  end

  test "hostname resolving to loopback 127.0.0.1 via injected resolver is rejected" do
    resolver = fn _host -> {:ok, [{:inet, {127, 0, 0, 1}, []}]} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://example.com/hook", resolver)
  end

  test "hostname resolving to private RFC-1918 via injected resolver is rejected" do
    resolver = fn _host -> {:ok, [{:inet, {10, 0, 0, 1}, []}]} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://example.com/hook", resolver)
  end

  # ---------------------------------------------------------------------------
  # OQ-3 — DNS failure treated as blocked
  # ---------------------------------------------------------------------------

  test "DNS NXDOMAIN is treated as blocked" do
    resolver = fn _host -> {:error, :nxdomain} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://nxdomain.example.com/hook", resolver)
  end

  test "DNS timeout is treated as blocked" do
    resolver = fn _host -> {:error, :timeout} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://timeout.example.com/hook", resolver)
  end
end
