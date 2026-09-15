defmodule Letflow.Plugs.PublicReadRateLimitTest do
  @moduledoc """
  Tests for `Letflow.Plugs.PublicReadRateLimit` (REQ-352 design §11, AC-8,
  `test/specs/REQ-352.md`). Exercises the limiter through the real mount
  (`Letflow.Router` -> `Letflow.Routers.PublicRead`), not the plug in
  isolation, so the assertion covers the actual plug ordering (limiter
  before `:match`).

  `Letflow.Plugs.PublicReadRateLimit.Bucket` owns one node-global,
  supervised ETS table for the life of the running node -- this test uses a
  distinct, never-reused `conn.remote_ip` (a TEST-NET-3 documentation
  address, RFC 5737, never the default `Plug.Test` loopback address other
  `/api/public` tests in this suite use) so its own bucket-exhaustion is
  independent of every other test's IP-keyed bucket. The GLOBAL bucket
  (default capacity 200, shared across all IPs) is also touched by every
  other `/api/public` test in the suite, but its capacity is an order of
  magnitude larger than the per-IP bucket this test exhausts (default 20),
  so the per-IP bucket is guaranteed to run out first regardless of what
  else the suite has already consumed from the global one.

  `async: false`: this test intentionally drives the SAME shared, node-wide
  IP bucket to exhaustion across many sequential requests -- running it
  concurrently with itself (which `async: true` would never do for a single
  test anyway) is not the concern; the concern is keeping this file's own
  request count deterministic and easy to reason about without another
  async test file's `/api/public` traffic interleaving against the same
  default loopback IP mid-run. This file uses its own dedicated IP
  specifically so that is not actually a hazard, but `async: false` is kept
  as a second, cheap layer of determinism for a test whose entire point is
  counting exact request numbers against shared state.
  """

  use Letflow.DataCase, async: false

  import Plug.Test

  alias Letflow.PublicReadFixtureSupport

  @opts Letflow.Router.init([])
  # RFC 5737 TEST-NET-3 -- documentation-only, never a real client, and
  # distinct from Plug.Test's default loopback remote_ip.
  @rate_limit_test_ip {203, 0, 113, 77}

  defp call(conn), do: Letflow.Router.call(conn, @opts)

  defp get_public(path) do
    conn(:get, path)
    |> Map.put(:remote_ip, @rate_limit_test_ip)
    |> call()
  end

  # Reads the plug's own configured ip_capacity (falls back to its
  # documented default of 20) rather than hard-coding it a second time here.
  defp ip_capacity do
    Application.get_env(:letflow, Letflow.Plugs.PublicReadRateLimit, [])
    |> Keyword.get(:ip_capacity, 20)
  end

  describe "AC-8: a rate-limited caller is refused input-independently" do
    test "429 for both an invalid handle and a VALID handle once the per-IP bucket is exhausted" do
      %{tenant_id: tenant_id, schema_name: schema} = PublicReadFixtureSupport.provision_tenant!()
      resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})
      valid_handle = PublicReadFixtureSupport.issue_handle!(tenant_id, resource.id)

      kind = PublicReadFixtureSupport.kind()
      capacity = ip_capacity()

      # Exhaust the per-IP bucket with `capacity` requests using an invalid
      # handle -- none of these are expected to succeed at resolution, but
      # each one still consumes one token, since the limiter runs before
      # :match/resolution.
      responses =
        for _ <- 1..capacity do
          get_public("/api/public/#{kind}/not-a-valid-handle!!")
        end

      refute Enum.any?(responses, &(&1.status == 429)),
             "did not expect a 429 before the bucket's capacity (#{capacity}) was reached"

      # The bucket is now empty. The NEXT request -- using a real, VALID
      # fixture handle that would otherwise resolve successfully -- must
      # still be refused with 429, proving the limiter is input-independent.
      valid_conn = get_public("/api/public/#{kind}/#{valid_handle}")
      assert valid_conn.status == 429

      # And an invalid handle is refused identically once exhausted.
      invalid_conn = get_public("/api/public/#{kind}/not-a-valid-handle!!")
      assert invalid_conn.status == 429
    end
  end
end
