defmodule Letflow.Plugs.TenantStatusTest do
  @moduledoc """
  Tests for `Letflow.Plugs.TenantStatus` — REQ-021 acceptance criterion 3
  (the `:migrating` write-pause check) and REQ-075 acceptance criterion 5
  (the `:inactive` all-methods check, authorized by REVIEWER —
  `docs/migration/stage-4-api-surface.md`'s 2026-08-22 (REQ-075) sign-off
  entry). See `test/specs/REQ-021.md` for the write-pause rationale and
  `lib/letflow/design/req075-tenant-administration-routes.md` §4.3 for the
  `:inactive` test design.

  Uses `Letflow.DataCase` (real Postgres, sandboxed connection, rolled back per test) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database. Per the
  design doc §6.1 ("runs after AuthPipeline, reading
  conn.assigns[:auth_context][:tenant_id]"), every test builds `conn.assigns[:auth_context]`
  directly (simulating `AuthPipeline` having already run) rather than running the full
  `AuthPipeline` first — this plug's own contract only depends on that one assign key
  being present, which `AuthPipeline`'s own tests (`auth_pipeline_test.exs`) already
  prove gets populated correctly. This also exercises the REQ-075 check for real: the
  plug reads `conn.assigns.auth_context.roles` directly, so injecting `auth_context`
  this way (rather than routing a real bearer token through `AuthPipeline`) still
  dispatches through the exact same `TenantStatus.call/2` the full
  `Letflow.Plugs.ApiPipeline` chain invokes — nothing about this plug's own contract
  depends on how `auth_context` got populated.

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

  defp call_plug(method, tenant_id, roles \\ []) do
    conn(method, "/whatever")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: roles
    })
    |> TenantStatus.call(TenantStatus.init([]))
  end

  # Named (not anonymous) telemetry handler function — :telemetry.attach/4 logs a
  # performance-penalty info message for anonymous-function/local-capture handlers,
  # per its own docs (see the "method short-circuit" tests below).
  #
  # ISS-0031 (GH#90): [:letflow, :repo, :query] is a single node-global event name --
  # :telemetry.attach/4 has no per-process scoping, so once attached, this handler
  # fires for EVERY query any process in the VM issues against Letflow.Repo, not just
  # this test's own call_plug/2. Under this module's `async: true`, many other test
  # processes are genuinely issuing real queries concurrently, so an unfiltered
  # send/2 could deliver a stray :query_fired from an unrelated test and flake the
  # `refute_received` assertion below. Fixed by exploiting that :telemetry.execute/3
  # invokes every attached handler synchronously IN THE CALLING PROCESS (no message
  # passing, no process hop -- this is exactly why :telemetry is hot-path-safe) --
  # self/0 here is therefore the PID of whatever process actually issued the query
  # that fired this event. Only forward the message when that's this test's own
  # process, so a concurrent test's query is silently ignored instead of polluting
  # this test's mailbox.
  def handle_query_telemetry(_event, _measurements, _metadata, test_pid) do
    if self() == test_pid do
      send(test_pid, :query_fired)
    end
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

  describe "REQ-075 restructure — every method now queries the DB once (shared lookup)" do
    # This describe block's title/tests changed shape under REQ-075 (REVIEWER-approved,
    # docs/migration/stage-4-api-surface.md 2026-08-22 entry, point 7): the new
    # :inactive check must run for EVERY method, so call/2 no longer has a GET-method
    # short-circuit that skips Repo.get/2 entirely — both GET and POST now issue
    # exactly one shared Repo.get(Tenant, tenant_id) query, whatever the method.
    test "a GET request now DOES issue exactly one Ecto query (the shared :inactive/:migrating lookup)" do
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
        assert_received :query_fired, "expected the shared lookup query for a GET request"
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

    # ISS-0031 (GH#90) regression: deterministically proves the self()-filter itself,
    # rather than relying on statistical confidence from repeated full-suite runs.
    # [:letflow, :repo, :query] is node-global, so a query genuinely fired by a
    # DIFFERENT process (simulating a concurrently running async test under this
    # module's `async: true`) must not reach this test's mailbox.
    test "handle_query_telemetry/4 ignores an event fired from a different process than the one it was attached for" do
      test_pid = self()

      {:ok, other_pid} =
        Task.start(fn ->
          receive do
            :fire -> handle_query_telemetry([:letflow, :repo, :query], %{}, %{}, test_pid)
          end
        end)

      send(other_pid, :fire)

      # Prove the other process really did run the handler (so a "the Task never ran"
      # false negative can't masquerade as this test's fix working) before asserting
      # the mailbox stayed empty -- Task.start/1's own process exits right after
      # handling :fire, so awaiting that exit is a reliable synchronization point.
      ref = Process.monitor(other_pid)
      assert_receive {:DOWN, ^ref, :process, ^other_pid, :normal}, 1000

      refute_received :query_fired,
                      "expected a query event fired from a different process to be filtered out"
    end
  end

  describe "no auth_context present (design §6.3 OQ-12, undefined-but-documented case)" do
    test "a write request with no :auth_context assign at all passes through rather than crashing" do
      conn = conn(:post, "/whatever") |> TenantStatus.call(TenantStatus.init([]))

      refute conn.halted
      assert conn.status == nil
    end
  end

  # ── REQ-075 AC5 — the new :inactive, all-methods, PLATFORM_ADMIN-exempt check ──

  describe "REQ-075 AC5 — a caller whose home tenant is :inactive" do
    test "GET against an :inactive tenant is rejected 403 tenant_inactive (not just writes)" do
      tenant = insert_tenant!(:inactive)

      conn = call_plug(:get, tenant.id, ["PROCESS_DESIGNER"])

      assert conn.status == 403
      assert conn.halted
      assert get_resp_header(conn, "retry-after") == []

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "tenant_inactive",
               "detail" => "tenant is deactivated"
             }
    end

    test "POST against an :inactive tenant is also rejected 403 tenant_inactive (not the 503 write-pause body)" do
      tenant = insert_tenant!(:inactive)

      conn = call_plug(:post, tenant.id, ["PROCESS_DESIGNER"])

      assert conn.status == 403
      assert conn.halted
      assert get_resp_header(conn, "retry-after") == []
      assert Jason.decode!(conn.resp_body)["error"] == "tenant_inactive"
    end

    test "a caller with no roles at all is rejected the same as any other non-PLATFORM_ADMIN caller" do
      tenant = insert_tenant!(:inactive)

      conn = call_plug(:get, tenant.id, [])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "tenant_inactive"
    end
  end

  describe "REQ-075 AC5 — a PLATFORM_ADMIN caller whose home tenant is :inactive is exempt" do
    test "GET against an :inactive tenant passes through unchanged for PLATFORM_ADMIN" do
      tenant = insert_tenant!(:inactive)

      conn = call_plug(:get, tenant.id, ["PLATFORM_ADMIN"])

      refute conn.halted
      assert conn.status == nil
    end

    test "POST against an :inactive tenant passes through unchanged for PLATFORM_ADMIN" do
      tenant = insert_tenant!(:inactive)

      conn = call_plug(:post, tenant.id, ["PLATFORM_ADMIN"])

      refute conn.halted
      assert conn.status == nil
    end
  end

  describe "REQ-075 AC5 — :active and :migrating tenants are unaffected by the new check" do
    test "GET/POST against an :active tenant pass through unchanged for a non-admin caller" do
      tenant = insert_tenant!(:active)

      for method <- [:get, :post] do
        conn = call_plug(method, tenant.id, ["PROCESS_DESIGNER"])
        refute conn.halted, "expected #{method} against an :active tenant to pass through"
        assert conn.status == nil
      end
    end

    test "a :migrating (not :inactive) tenant still gets the existing 503 write-pause for a non-admin caller's POST, not a 403" do
      tenant = insert_tenant!(:migrating)

      conn = call_plug(:post, tenant.id, ["PROCESS_DESIGNER"])

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"] == "tenant_migrating"
    end
  end
end
