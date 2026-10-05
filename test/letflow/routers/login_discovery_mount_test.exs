defmodule Letflow.Routers.LoginDiscoveryMountTest do
  @moduledoc """
  REQ-437 (spec `test/specs/REQ-437.md`): the mount switch (C3, D12/D23), the chain
  order (C2/C6, D25), the 429 behaviour and the client-IP integration (AC "client
  IP", design s15.0), all through the real `Letflow.Router`.

  No tenant is needed: every request here is an unknown address or never reaches
  the lookup. `async: false` (global limiter table, application env).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  alias Letflow.LoginDiscoveryProbeRouter, as: Probe
  alias Letflow.Plugs.LoginDiscoveryRateLimit.Bucket
  alias Letflow.Test.LoginDiscoveryHelpers, as: H

  @methods [:get, :post, :put, :patch, :delete, :options, :head]
  @suffixes ["", "/", "/x/y"]
  @tiny 0.0001

  setup do
    H.setup_limiter!([])
    H.put_enabled!(true)
    H.await_idle()
    :ok
  end

  defp footprint(fun) do
    {{{conn, outcomes}, queries}, submissions} =
      H.capture_submissions(fn -> H.capture_queries(fn -> H.capture_outcomes(fun) end) end)

    %{conn: conn, outcomes: outcomes, queries: queries, submissions: submissions}
  end

  defp limiter_state_size, do: :ets.info(H.limiter_table(), :size)

  defp catch_all(method), do: H.fp(conn(method, "/api/zz-not-mounted") |> H.run())

  # ── mount switch (C3) ───────────────────────────────────────────────────

  describe "enabled: false" do
    setup do
      H.put_enabled!(false)
      :ets.delete_all_objects(H.limiter_table())
      :ok
    end

    test "every non-preflight method/path is the catch-all 404: zero queries, no limiter state, one :disabled event" do
      for method <- @methods, suffix <- @suffixes do
        r = footprint(fn -> H.call(method, suffix) end)

        assert H.fp(r.conn) == catch_all(method), "#{method} #{inspect(suffix)}"
        assert r.conn.status == 404
        assert r.queries == []
        assert r.submissions == 0
        assert [{measurements, metadata}] = r.outcomes
        assert measurements == %{count: 1}
        assert Map.keys(metadata) == [:outcome]
        assert metadata.outcome == :disabled

        assert limiter_state_size() == 0,
               "ClientIp/limiter must not have run (#{method} #{suffix})"
      end
    end

    test "a POST with a valid body is also just the 404" do
      r = footprint(fn -> H.post_email(H.email()) end)

      assert H.fp(r.conn) == catch_all(:post)
      assert r.queries == []
      assert r.submissions == 0
      assert r.outcomes == [{%{count: 1}, %{outcome: :disabled}}]
      assert limiter_state_size() == 0
    end

    test "an OPTIONS that is not an allowed-origin preflight is the :disabled 404" do
      variants = [
        [],
        [{"origin", "https://evil.example"}, {"access-control-request-method", "POST"}],
        [{"origin", "http://localhost:5173"}],
        [{"access-control-request-method", "POST"}]
      ]

      for headers <- variants do
        r =
          footprint(fn ->
            c = conn(:options, H.mount())
            headers |> Enum.reduce(c, fn {k, v}, acc -> put_req_header(acc, k, v) end) |> H.run()
          end)

        assert r.conn.status == 404, inspect(headers)
        assert r.outcomes == [{%{count: 1}, %{outcome: :disabled}}]
        assert r.queries == []
        assert limiter_state_size() == 0
      end
    end

    test "an allowed-origin CORS preflight is a 204 from Cors: no event, no query, no limiter state" do
      r = footprint(fn -> preflight("http://localhost:5173") end)

      assert r.conn.status == 204
      assert get_resp_header(r.conn, "access-control-allow-origin") == ["http://localhost:5173"]
      assert r.outcomes == []
      assert r.queries == []
      assert r.submissions == 0
      assert limiter_state_size() == 0
    end

    test "any enabled value other than exactly true disables the mount; so does a missing key" do
      for value <- [nil, "true", 1, :yes] do
        H.put_enabled!(value)
        conn = H.post_email(H.email())
        assert conn.status == 404, "enabled: #{inspect(value)}"
      end

      H.delete_env!(Letflow.Routers.LoginDiscovery)
      assert H.post_email(H.email()).status == 404
    end
  end

  test "the allowed-origin preflight is a plain 204 with no event on an enabled mount" do
    r = footprint(fn -> preflight("http://localhost:5173") end)
    assert r.conn.status == 204
    assert r.outcomes == []
    assert r.queries == []
    assert limiter_state_size() == 0
  end

  test "toggling enabled at runtime needs no recompile" do
    email = H.email()
    H.put_enabled!(false)
    assert H.post_email(email).status == 404
    H.put_enabled!(true)
    assert H.post_email(email).status == 202
    H.put_enabled!(false)
    assert H.post_email(email).status == 404
  end

  # ── chain order (C2, C6) ────────────────────────────────────────────────

  describe "chain order (by behaviour)" do
    test "a rate-limited request is a 429 even with an invalid body" do
      H.setup_limiter!(ip_capacity: 1, ip_refill_per_sec: @tiny)

      assert H.post_email(H.email()).status == 202

      r = footprint(fn -> H.post_raw("{definitely not json", "text/plain") end)
      assert r.conn.status == 429
      assert r.queries == []
      assert r.submissions == 0
      assert r.outcomes == [{%{count: 1}, %{outcome: :rate_limited_ip}}]
    end

    test "a wrong method is a 404 only when the limiter admits it, and it consumes tokens" do
      H.setup_limiter!(ip_capacity: 2, ip_refill_per_sec: @tiny)

      assert H.call(:get, "/x").status == 404
      assert H.call(:delete, "").status == 404
      conn = H.call(:get, "/x")
      assert conn.status == 429
      assert H.post_email(H.email()).status == 429
    end

    test "per-IP, global and per-email 429s are byte-identical and equal to REQ-436 bytes" do
      ip = refuse(:ip)
      global = refuse(:global)
      email = refuse(:email)

      for {cause, r} <- [ip: ip, global: global, email: email] do
        assert r.conn.status == 429, "#{cause}"
        assert r.queries == []
        assert r.submissions == 0
        assert [{%{count: 1}, metadata}] = r.outcomes
        assert Map.keys(metadata) == [:outcome]
        assert metadata.outcome == :"rate_limited_#{cause}"
        assert get_resp_header(r.conn, "retry-after") == ["60"]
      end

      assert H.fp(ip.conn) == H.fp(global.conn)
      assert H.fp(ip.conn) == H.fp(email.conn)

      # equal to what REQ-436's probe router (same constructor) answers
      H.setup_limiter!(ip_capacity: 1, ip_refill_per_sec: @tiny)

      probe = fn ->
        conn(:post, "/probe")
        |> Map.put(:remote_ip, {192, 0, 2, 77})
        |> Probe.call(Probe.init([]))
      end

      assert probe.().status == 200
      probe_429 = probe.()
      assert probe_429.status == 429
      assert ip.conn.status == probe_429.status
      assert ip.conn.resp_body == probe_429.resp_body
      assert get_resp_header(ip.conn, "retry-after") == get_resp_header(probe_429, "retry-after")

      assert get_resp_header(ip.conn, "content-type") ==
               get_resp_header(probe_429, "content-type")
    end
  end

  # Produces one 429 whose cause is `cause`, from a clean limiter state.
  defp refuse(:ip) do
    H.setup_limiter!(ip_capacity: 1, ip_refill_per_sec: @tiny)
    assert H.post_email(H.email()).status == 202
    footprint(fn -> H.post_email(H.email()) end)
  end

  defp refuse(:global) do
    H.setup_limiter!(global_capacity: 1, global_refill_per_sec: @tiny)
    assert H.post_from(~s({"email":"a@x.test"}), {192, 0, 2, 1}, []).status == 202
    footprint(fn -> H.post_from(~s({"email":"b@x.test"}), {192, 0, 2, 2}, []) end)
  end

  defp refuse(:email) do
    H.setup_limiter!(email_capacity: 1, email_refill_per_sec: @tiny)
    email = H.email()
    assert H.post_email(email).status == 202
    footprint(fn -> H.post_email(email) end)
  end

  # ── client IP integration (REQ-439 through the real chain) ──────────────

  describe "client IP through the real LoginDiscovery chain" do
    @peer {10, 0, 0, 1}

    defp post_as(real_ip) do
      H.post_from(~s({"email":"#{H.email()}"}), @peer, [{"x-real-ip", real_ip}])
    end

    test "two X-Real-IP values behind one trusted peer fall into two per-IP buckets" do
      H.setup_limiter!(ip_capacity: 1, ip_refill_per_sec: @tiny)
      H.put_env!(Letflow.Plugs.ClientIp, trusted_proxies: [{{10, 0, 0, 0}, 8}])

      assert post_as("203.0.113.5").status == 202
      assert post_as("203.0.113.6").status == 202
      assert Bucket.size(:ip) == 2

      # each bucket holds exactly one token: the same value again is refused
      assert post_as("203.0.113.5").status == 429
      assert post_as("203.0.113.6").status == 429
      assert Bucket.size(:ip) == 2
    end

    test "with an empty trust list a spoofed X-Real-IP changes nothing" do
      H.setup_limiter!(ip_capacity: 1, ip_refill_per_sec: @tiny)
      H.put_env!(Letflow.Plugs.ClientIp, trusted_proxies: [])

      assert post_as("203.0.113.5").status == 202
      assert post_as("203.0.113.6").status == 429
      assert post_as("198.51.100.9").status == 429
      assert Bucket.size(:ip) == 1
    end

    test "a peer outside the trusted CIDRs cannot choose its own bucket" do
      H.setup_limiter!(ip_capacity: 1, ip_refill_per_sec: @tiny)
      H.put_env!(Letflow.Plugs.ClientIp, trusted_proxies: [{{10, 0, 0, 0}, 8}])

      body = ~s({"email":"#{H.email()}"})
      assert H.post_from(body, {192, 0, 2, 9}, [{"x-real-ip", "203.0.113.5"}]).status == 202
      assert H.post_from(body, {192, 0, 2, 9}, [{"x-real-ip", "203.0.113.6"}]).status == 429
      assert Bucket.size(:ip) == 1
    end
  end

  defp preflight(origin) do
    conn(:options, H.mount())
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "POST")
    |> H.run()
  end
end
