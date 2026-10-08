defmodule Letflow.Test.FakeInvocationConnectionTest do
  @moduledoc """
  Unit tests for `Letflow.Test.FakeInvocationConnection` (Q-1037 / GH #2364), the
  helper the three `TenantSchemaReaper` concurrent-invocation-guard tests use to
  stand in for "another `mix test` invocation".

  The helper is shared by three files, so a regression in it (a dropped queue
  option, a `stop_and_wait_gone!/3` that returns before the backend leaves, a poll
  that never times out) would otherwise surface only as an intermittent flake in
  those tests. These tests pin each behaviour directly. No fixed sleeps: the only
  waiting is the helper's own bounded poll. Uses `Letflow.DataCase` (async: false)
  like the sibling reaper tests, because `Letflow.Repo` runs on the sandbox pool.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.BpmDefaultRealmDisplacement
  alias Letflow.Test.FakeInvocationConnection

  # Postgres truncates application_name to NAMEDATALEN - 1 = 63 bytes, so a longer
  # tag is stored truncated and `application_name = $1` with the full tag can never
  # match: a deterministic "never visible" scenario that needs no helper seam.
  @max_application_name_bytes 63

  defp unique_tag(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The sandbox wraps the test in one transaction and Postgres caches the
  # pg_stat_activity snapshot until transaction end, which would make the helper's
  # poll_gone?/3 see a stale tag forever. Switch Repo to :auto (autocommit) exactly
  # as the sibling reaper tests do before they call stop_and_wait_gone!/3.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    :ok
  end

  # Count of backends carrying `tag`, read through Letflow.Repo (not the fake conn).
  defp backend_count(tag) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [tag])

    n
  end

  describe "opts/1" do
    test "returns the never-shedding dedicated options plus the application_name tag" do
      tag = unique_tag("fake-opts")
      opts = FakeInvocationConnection.opts(tag)
      dedicated = BpmDefaultRealmDisplacement.dedicated_connection_opts()

      # Equal to the single source of truth ...
      for key <- [:queue_target, :queue_interval, :connect_timeout, :timeout] do
        assert opts[key] == dedicated[key]
      end

      # ... and pinned to absolute numbers so a silent drop of the values is caught.
      assert opts[:queue_target] == 30_000
      assert opts[:queue_interval] == 30_000
      assert opts[:connect_timeout] == 30_000
      assert opts[:timeout] == 120_000

      refute Keyword.has_key?(opts, :pool)
      refute Keyword.has_key?(opts, :pool_size)
      assert opts[:parameters] == [application_name: tag]
    end
  end

  describe "start!/2" do
    test "returns a live connection whose tag is visible in pg_stat_activity" do
      tag = unique_tag("fake-start")
      conn = FakeInvocationConnection.start!(tag)

      assert is_pid(conn)
      assert Process.alive?(conn)
      assert backend_count(tag) == 1
      assert %Postgrex.Result{rows: [[^tag]]} = Postgrex.query!(conn, "SHOW application_name", [])
    end

    test "raises naming the tag when the tag never becomes visible" do
      tag = String.duplicate("x", @max_application_name_bytes + 10)

      error =
        assert_raise RuntimeError, fn ->
          FakeInvocationConnection.start!(tag, attempts: 2, interval_ms: 1)
        end

      assert error.message =~ tag
      assert error.message =~ "not visible in pg_stat_activity after 2 attempts"
    end
  end

  describe "stop_and_wait_gone!/3" do
    test "returns :ok only after the tag has left pg_stat_activity" do
      tag = unique_tag("fake-stop")
      conn = FakeInvocationConnection.start!(tag)
      assert backend_count(tag) == 1

      assert :ok = FakeInvocationConnection.stop_and_wait_gone!(conn, tag)

      refute Process.alive?(conn)
      assert backend_count(tag) == 0
    end

    test "raises naming the tag when another backend still carries it" do
      tag = unique_tag("fake-still")
      conn = FakeInvocationConnection.start!(tag)
      survivor = FakeInvocationConnection.start!(tag)
      assert backend_count(tag) == 2

      error =
        assert_raise RuntimeError, fn ->
          FakeInvocationConnection.stop_and_wait_gone!(conn, tag, attempts: 2, interval_ms: 1)
        end

      assert error.message =~ tag
      assert error.message =~ "still in pg_stat_activity"
      refute Process.alive?(conn)
      assert Process.alive?(survivor)
    end
  end
end
