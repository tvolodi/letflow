defmodule Letflow.Api.ContextTest do
  @moduledoc """
  Tests for `Letflow.Api.Context` (REQ-072). See
  `lib/letflow/design/req072-tenant-request-context.md` §2.3/§3.3/§4 for the
  test-case rationale this file implements directly.

  The trace-id/log-correlation describe blocks (§2.3) need no database and
  run `async: true`-compatible in isolation, but this file is `async: false`
  for the whole module — ExUnit's `async` setting is module-wide — because
  the §4 cross-tenant-404 block provisions and migrates real tenant schemas
  the same way `test/letflow/tenant_provisioning_test.exs` and
  `test/letflow/plugs/auth_pipeline_test.exs` already do (`Ecto.Migrator`
  cannot run under `Letflow.DataCase`'s shared sandboxed connection).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  require Logger

  alias Letflow.Api.Context
  alias Letflow.Api.Context.Test.Probe
  alias Letflow.Api.Context.Test.ProbeMigration
  alias Letflow.Api.Response
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @probe_migration_version 20_260_822_000_001

  describe "assign_trace_id/1 propagation" do
    test "propagates an incoming X-Trace-Id header value onto conn.assigns and the response header" do
      conn =
        :get
        |> conn("/whatever")
        |> put_req_header("x-trace-id", "caller-supplied-id")
        |> Context.assign_trace_id()

      assert conn.assigns.trace_id == "caller-supplied-id"
      assert get_resp_header(conn, "x-trace-id") == ["caller-supplied-id"]
    end

    test "generates a UUID v4 when no incoming header is present" do
      conn =
        :get
        |> conn("/whatever")
        |> Context.assign_trace_id()

      assert conn.assigns.trace_id =~ ~r/^[0-9a-f-]{36}$/
      assert get_resp_header(conn, "x-trace-id") == [conn.assigns.trace_id]
    end

    test "truncates an incoming header longer than 256 bytes" do
      overlong = String.duplicate("a", 300)

      conn =
        :get
        |> conn("/whatever")
        |> put_req_header("x-trace-id", overlong)
        |> Context.assign_trace_id()

      assert byte_size(conn.assigns.trace_id) == 256
      assert conn.assigns.trace_id == String.duplicate("a", 256)
      assert get_resp_header(conn, "x-trace-id") == [conn.assigns.trace_id]
    end
  end

  describe "log correlation (AC2)" do
    test "the same trace id appears on the response header and in a log line emitted during the request" do
      conn = :get |> conn("/whatever")

      {conn, log} =
        capture_log_and_result(fn ->
          conn = Context.assign_trace_id(conn)
          Logger.info("handling request")
          conn
        end)

      trace_id = conn.assigns.trace_id

      assert log =~ trace_id
      assert get_resp_header(conn, "x-trace-id") == [trace_id]
    end

    # ExUnit.CaptureLog.capture_log/1 discards the wrapped function's own
    # return value, so this local helper captures both.
    defp capture_log_and_result(fun) do
      ref = make_ref()
      # `:metadata` must be listed explicitly -- the default `:logger` format
      # does not print any metadata keys, so `Logger.metadata(trace_id: ...)`
      # would otherwise never show up in the captured text at all.
      log = capture_log([metadata: [:trace_id]], fn -> Process.put(ref, fun.()) end)
      {Process.delete(ref), log}
    end
  end

  describe "scoped_repo_opts/1 ignores request-supplied tenant hints (INV-1, AC3)" do
    setup do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req072-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req072-b")
      %{tenant_a: tenant_a, tenant_b: tenant_b}
    end

    test "derives :prefix solely from conn.assigns.auth_context, never from path/query/header hints",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      conn =
        :get
        |> conn("/whatever?tenant_id=#{tenant_b.tenant_id}")
        |> fetch_query_params()
        |> Map.put(:path_params, %{"tenant_id" => tenant_b.tenant_id})
        |> put_req_header("x-tenant-id", tenant_b.tenant_id)
        |> assign(:auth_context, %{
          tenant_id: tenant_a.tenant_id,
          user_id: Ecto.UUID.generate(),
          roles: []
        })

      assert {:ok, prefix: schema_name} = Context.scoped_repo_opts(conn)
      assert schema_name == tenant_a.schema_name
      refute schema_name == tenant_b.schema_name
    end

    test "scoped_repo_opts/1 is 1-arity — no tenant/schema/prefix parameter exists to pass" do
      assert function_exported?(Context, :scoped_repo_opts, 1)
      refute function_exported?(Context, :scoped_repo_opts, 2)
      refute function_exported?(Context, :scoped_repo_opts, 3)
      refute function_exported?(Context, :scoped_repo_opts, 4)
    end

    test "returns {:error, :missing_auth_context} when conn.assigns.auth_context is absent" do
      conn = :get |> conn("/whatever")
      assert {:error, :missing_auth_context} = Context.scoped_repo_opts(conn)
    end

    test "returns {:error, :missing_auth_context} when :auth_context lacks :tenant_id" do
      conn =
        :get
        |> conn("/whatever")
        |> assign(:auth_context, %{user_id: Ecto.UUID.generate(), roles: []})

      assert {:error, :missing_auth_context} = Context.scoped_repo_opts(conn)
    end

    test "returns {:error, :invalid_tenant_id} when the assigned tenant id cannot be cast" do
      conn =
        :get
        |> conn("/whatever")
        |> assign(:auth_context, %{
          tenant_id: "not-a-uuid",
          user_id: Ecto.UUID.generate(),
          roles: []
        })

      assert {:error, :invalid_tenant_id} = Context.scoped_repo_opts(conn)
    end
  end

  describe "cross-tenant 404 is byte-identical to a never-existed 404 (AC4, AC5, INV-5)" do
    setup do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req072-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req072-cross-b")

      assert {:ok, _versions} =
               TenantProvisioning.replay_migrations(tenant_a.tenant_id, [
                 {@probe_migration_version, ProbeMigration}
               ])

      assert {:ok, _versions} =
               TenantProvisioning.replay_migrations(tenant_b.tenant_id, [
                 {@probe_migration_version, ProbeMigration}
               ])

      tenant_b_row =
        %Probe{}
        |> Ecto.Changeset.change(%{label: "tenant-b-only"})
        |> Repo.insert!(prefix: tenant_b.schema_name)

      conn_a =
        :get
        |> conn("/whatever")
        |> assign(:auth_context, %{
          tenant_id: tenant_a.tenant_id,
          user_id: Ecto.UUID.generate(),
          roles: []
        })
        # Pinned so this field cannot vary between the two probe responses,
        # isolating the byte-identity comparison to the property under test.
        |> assign(:trace_id, "fixed-test-trace-id")

      %{conn_a: conn_a, tenant_b_row_id: tenant_b_row.id}
    end

    test "byte-identical 404 responses for a cross-tenant id and a never-existed id", %{
      conn_a: conn_a,
      tenant_b_row_id: tenant_b_row_id
    } do
      assert {:ok, prefix: schema_a} = Context.scoped_repo_opts(conn_a)

      resp_1 = not_found_response(conn_a, Probe, tenant_b_row_id, prefix: schema_a)
      resp_2 = not_found_response(conn_a, Probe, Ecto.UUID.generate(), prefix: schema_a)

      assert resp_1.status == 404
      assert resp_1.status == resp_2.status
      assert resp_1.resp_body == resp_2.resp_body
    end

    test "the cross-tenant path and the never-existed path run the same number of queries", %{
      conn_a: conn_a,
      tenant_b_row_id: tenant_b_row_id
    } do
      assert {:ok, prefix: schema_a} = Context.scoped_repo_opts(conn_a)

      handler_id = {__MODULE__, :query_counter, make_ref()}
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :counters.put(counter, 1, 0)
      _ = Repo.get(Probe, tenant_b_row_id, prefix: schema_a)
      count_1 = :counters.get(counter, 1)

      :counters.put(counter, 1, 0)
      _ = Repo.get(Probe, Ecto.UUID.generate(), prefix: schema_a)
      count_2 = :counters.get(counter, 1)

      assert count_1 == count_2
    end

    defp not_found_response(conn, schema, id, opts) do
      case Repo.get(schema, id, opts) do
        nil -> Response.not_found(conn)
        _row -> raise "test setup error: expected no row for id=#{inspect(id)}"
      end
    end
  end
end
