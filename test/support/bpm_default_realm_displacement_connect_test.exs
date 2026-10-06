defmodule Letflow.Support.BpmDefaultRealmDisplacementConnectTest do
  @moduledoc """
  Regression test for the CI flake where `BpmDefaultRealmDisplacement`'s dedicated
  advisory-lock connection was load-shed while still connecting (main CI 206338d3
  `bpm_default_realm_displacement_test.exs:141`; PR #2313 run 37490851195
  `req077_promotion_pipeline_test.exs:1279` -- both `DBConnection.ConnectionError:
  connection not available and request was dropped from queue after 4000ms`).

  The dedicated connection is a brand-new DBConnection pool of one whose physical
  connect is asynchronous; with DBConnection's default `:queue_target`/
  `:queue_interval` a first query that waits longer than the interval for the connect
  is shed. A slow CI runner produces that delay by accident; this test produces it by
  construction with a small TCP proxy test double that accepts the client socket and
  withholds every byte for `@proxy_delay_ms` (the delay lives in the proxy process,
  never in the test body) before piping to the real database.

    * (a) the OLD option shape (`Repo.config/0` minus `:pool`/`:pool_size`, DBConnection
      defaults) pointed at the proxy raises the "dropped from queue" error;
    * (b) the REAL production options (`BpmDefaultRealmDisplacement.dedicated_connection_opts/0`)
      pointed at the same proxy complete the query.

  No data is touched (`SELECT 1` only), so this file needs neither the sandbox nor the
  shared "bpm-default" row and is safe to run alongside any other test.
  """

  use ExUnit.Case, async: false

  alias Letflow.Repo
  alias Letflow.Support.BpmDefaultRealmDisplacement

  # DBConnection.ConnectionPool polls its queue every :queue_interval (default 2000 ms
  # in the pinned deps/db_connection) and starts dropping on the SECOND poll that sees
  # the same head-of-queue request still waiting: at ~4000 ms when the request was queued
  # in the same millisecond the pool started (the "after 4000ms" seen in CI), at ~6000 ms
  # otherwise. 7500 ms therefore sheds deterministically on the old shape; a 2600 ms
  # delay was tried first and did NOT reproduce (nothing is shed before the second poll).
  @proxy_delay_ms 7_500
  @iterations 10

  defp old_opts, do: Repo.config() |> Keyword.drop([:pool, :pool_size])

  defp via_proxy(opts, port),
    do: Keyword.merge(opts, hostname: "127.0.0.1", port: port)

  # Delaying TCP proxy: accepts, waits `delay_ms` in its own process, then pipes bytes
  # to the real database in both directions. Returns {listen_port, listener_pid}.
  defp start_proxy!(delay_ms) do
    upstream = Repo.config()
    host = upstream |> Keyword.fetch!(:hostname) |> String.to_charlist()
    up_port = Keyword.get(upstream, :port, 5432)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept_loop(listen, host, up_port, delay_ms) end)

    on_exit(fn ->
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp accept_loop(listen, host, up_port, delay_ms) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        pid = spawn(fn -> serve(client, host, up_port, delay_ms) end)
        :gen_tcp.controlling_process(client, pid)
        accept_loop(listen, host, up_port, delay_ms)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(client, host, up_port, delay_ms) do
    # The client's startup packet waits unread in the socket buffer meanwhile.
    receive do
    after
      delay_ms -> :ok
    end

    {:ok, server} = :gen_tcp.connect(host, up_port, [:binary, active: false])
    :ok = :inet.setopts(client, active: true)
    :ok = :inet.setopts(server, active: true)
    pipe(client, server)
  end

  defp pipe(client, server) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(server, data)
        pipe(client, server)

      {:tcp, ^server, data} ->
        :gen_tcp.send(client, data)
        pipe(client, server)

      _closed_or_error ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)
    end
  end

  defp query_select_1(opts) do
    {:ok, conn} = Postgrex.start_link(opts)
    Process.unlink(conn)

    try do
      Postgrex.query!(conn, "SELECT 1", [], timeout: 60_000)
    after
      if Process.alive?(conn), do: GenServer.stop(conn)
    end
  end

  # The @iterations connections run concurrently (each has its own proxy handler and its
  # own pool of one), so the total wall time is one proxy delay, not N of them.
  defp run_all(opts) do
    1..@iterations
    |> Task.async_stream(
      fn _ ->
        try do
          {:ok, query_select_1(opts)}
        rescue
          e in DBConnection.ConnectionError -> {:error, e}
        end
      end,
      max_concurrency: @iterations,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "(a) the old option shape is load-shed while the lock connection is still connecting" do
    port = start_proxy!(@proxy_delay_ms)
    results = run_all(via_proxy(old_opts(), port))

    assert length(results) == @iterations

    for result <- results do
      assert {:error, %DBConnection.ConnectionError{message: message}} = result
      assert message =~ "dropped from queue"
    end
  end

  test "(b) dedicated_connection_opts/0 survives the same slow connect" do
    port = start_proxy!(@proxy_delay_ms)
    results = run_all(via_proxy(BpmDefaultRealmDisplacement.dedicated_connection_opts(), port))

    assert length(results) == @iterations

    for result <- results do
      assert {:ok, %Postgrex.Result{rows: [[1]]}} = result
    end
  end

  test "dedicated_connection_opts/0 keeps the sandbox pool options out and the queue options off the shedding path" do
    opts = BpmDefaultRealmDisplacement.dedicated_connection_opts()

    refute Keyword.has_key?(opts, :pool)
    refute Keyword.has_key?(opts, :pool_size)
    assert is_integer(opts[:queue_target]) and opts[:queue_target] >= 30_000
    assert is_integer(opts[:queue_interval]) and opts[:queue_interval] >= 30_000
    assert is_integer(opts[:connect_timeout]) and opts[:connect_timeout] >= 30_000
    assert is_integer(opts[:timeout]) and opts[:timeout] >= 120_000
  end
end
