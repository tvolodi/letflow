defmodule Letflow.Plugs.LoginDiscoveryRateLimitSmokeTest do
  # Node-global ETS table: async: false. TEST-DESIGNER owns the full suite.
  use ExUnit.Case, async: false

  import Plug.Test

  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter
  alias Letflow.Plugs.LoginDiscoveryRateLimit.Bucket

  test "per-IP bucket refuses after ip_capacity and leaves global untouched" do
    ip = {192, 0, 2, 77}
    cap = Limiter.config().ip_capacity

    results =
      for _ <- 1..(cap + 1) do
        conn(:post, "/x") |> Map.put(:remote_ip, ip) |> Limiter.call([])
      end

    assert Enum.map(results, & &1.halted) == List.duplicate(false, cap) ++ [true]
    assert List.last(results).status == 429

    assert Limiter.ip_bucket_id({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}) ==
             {:v4, {203, 0, 113, 7}}
  end

  test "rows live in own table, namespaced, and sweep is lossless" do
    key = :crypto.strong_rand_bytes(8)
    assert Limiter.consume_email(key, :request, 0) == :ok
    assert Limiter.consume_email(key, :send, 0) == :ok
    assert Limiter.consume_email(key, :send, 1000) == :rate_limited

    assert Enum.all?(:ets.tab2list(Bucket.table()), fn row ->
             elem(elem(row, 0), 0) == :login_discovery
           end)

    assert {:ok, t} = Bucket.token_count({:login_discovery, :email_hmac, key}, 0)
    assert t < 5
    Bucket.sweep(10_000_000, :email)
    assert Bucket.token_count({:login_discovery, :email_hmac, key}, 10_000_000) == :absent
  end
end
