defmodule Letflow.Plugs.TenantStatusTest do
  @moduledoc """
  Tests for `Letflow.Plugs.TenantStatus` (REQ-021 acceptance criterion 3). See
  `test/specs/REQ-021.md` for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres, sandboxed connection, rolled back per test) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database. Per the
  design doc §6.1 ("runs after AuthPipeline, reading
  conn.assigns[:auth_context][:tenant_id]"), every test builds `conn.assigns[:auth_context]`
  directly (simulating `AuthPipeline` having already run) rather than running the full
  `AuthPipeline` first — this plug's own contract only depends on that one assign key
  being present, which `AuthPipeline`'s own tests (`auth_pipeline_test.exs`) already
  prove gets populated correctly.

  All tests run `async: true` — every test seeds its own tenant row with a unique slug
  inside its own sandboxed transaction (rolled back after the test).
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity.Tenant
  alias Letflow.Plugs.TenantStatus

  import Plug.Test
  import Plug.Conn

  defp unique_slug(prefix \\ "tenant") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_tenant!(status) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{slug: unique_slug(), display_name: "Tenant Status Test Tenant", status: status},
      :disabled
    )
    |> Repo.insert!()
  end

  defp call_plug(method, tenant_id) do
    conn(method, "/whatever")
    |> assign(:auth_context, %{user_id: Ecto.UUID.generate(), tenant_id: tenant_id, roles: []})
    |> TenantStatus.call(TenantStatus.init([]))
  end

  # Named (not anonymous) telemetry handler function — :telemetry.attach/4 logs a
  # performance-penalty info message for anonymous-function/local-capture handlers,
  # per its own docs (see the "method short-circuit" tests below).
  def handle_query_telemetry(_event, _measurements, _metadata, test_pid) do
    send(test_pid, :query_fired)
  end

  describe "acceptance criterion 3 — write methods against a :migrating tenant" do
    test "a POST request against a :migrating tenant is rejected 503 with a Retry-After header" do
      tenant = insert_tenant!(:migrating)

      conn = call_plug(:post, tenant.id)

      assert conn.status == 503
      assert conn.halted
      assert get_resp_header(conn, "retry-after") == ["30"]
      assert %{"error" => "tenant_migrating"} = Jason.decode!(conn.resp_body)
    end

    test "the tenant-status write-pause rejects every write method (PUT, PATCH, DELETE)" do
      tenant = insert_tenant!(:migrating)

      for method <- [:put, :patch, :delete] do
        conn = call_plug(method, tenant.id)

        assert conn.status == 503,
               "expected #{method} to be rejected 503, got #{inspect(conn.status)}"

        assert conn.halted, "expected #{method} to halt the conn"
        assert get_resp_header(conn, "retry-after") == ["30"]
      end
    end

    test "a GET request against a :migrating tenant passes through unchanged" do
      tenant = insert_tenant!(:migrating)

      conn = call_plug(:get, tenant.id)

      refute conn.halted
      assert conn.status == nil
    end

    test "a HEAD request against a :migrating tenant also passes through unchanged" do
      tenant = insert_tenant!(:migrating)

      conn = call_plug(:head, tenant.id)

      refute conn.halted
      assert conn.status == nil
    end
  end

  describe "acceptance criterion 3 — write methods against an :active tenant" do
    test "a POST request against an :active tenant passes through unchanged" do
      tenant = insert_tenant!(:active)

      conn = call_plug(:post, tenant.id)

      refute conn.halted
      assert conn.status == nil
    end

    test "PUT/PATCH/DELETE against an :active tenant all pass through unchanged" do
      tenant = insert_tenant!(:active)

      for method <- [:put, :patch, :delete] do
        conn = call_plug(method, tenant.id)

        refute conn.halted, "expected #{method} against an :active tenant to pass through"
        assert conn.status == nil
      end
    end
  end

  describe "method short-circuit — no DB query at all for a non-write method" do
    test "a GET request issues no Ecto query at all (method short-circuit, no DB round-trip)" do
      tenant = insert_tenant!(:migrating)

      test_pid = self()
      handler_id = {:tenant_status_test, :query_telemetry, make_ref()}

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        &__MODULE__.handle_query_telemetry/4,
        test_pid
      )

      try do
        call_plug(:get, tenant.id)
        refute_received :query_fired, "expected no Ecto query for a GET request"
      after
        :telemetry.detach(handler_id)
      end
    end

    test "a POST request against a :migrating tenant DOES issue an Ecto query (the write-method path queries the DB)" do
      tenant = insert_tenant!(:migrating)

      test_pid = self()
      handler_id = {:tenant_status_test, :query_telemetry_post, make_ref()}

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        &__MODULE__.handle_query_telemetry/4,
        test_pid
      )

      try do
        call_plug(:post, tenant.id)
        assert_received :query_fired, "expected a POST request to issue an Ecto query"
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "no auth_context present (design §6.3 OQ-12, undefined-but-documented case)" do
    test "a write request with no :auth_context assign at all passes through rather than crashing" do
      conn = conn(:post, "/whatever") |> TenantStatus.call(TenantStatus.init([]))

      refute conn.halted
      assert conn.status == nil
    end
  end
end
