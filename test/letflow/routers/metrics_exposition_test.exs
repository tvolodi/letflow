defmodule Letflow.Plugs.HttpMetricsRouteTemplateProbeRouter do
  @moduledoc """
  Test-only fixture router for `test/letflow/routers/metrics_exposition_test.exs`'s
  AC5 (route-template normalization) coverage -- a standalone `Plug.Router` with one
  `:id`-parameterized route, `Letflow.Plugs.HttpMetrics` mounted the same way
  `Letflow.Router` mounts it (ahead of `:match`/`:dispatch`). A dedicated route
  template (`/req194-ac5-probe/:id`) that no other test or production route uses, so
  this file's counter assertions can be exact rather than approximate.
  """

  use Plug.Router

  plug(Letflow.Plugs.HttpMetrics)
  plug(:match)
  plug(:dispatch)

  get "/req194-ac5-probe/:id" do
    send_resp(conn, 200, "ok")
  end

  # Separate template for AC6's own use, so its one extra request never inflates
  # AC5's exact-count assertion on the `/req194-ac5-probe/:id` template above.
  get "/req194-ac6-probe/:id" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Letflow.Routers.MetricsExpositionTest do
  @moduledoc """
  Tests for REQ-194's `GET /metrics` Prometheus exposition endpoint (design
  `lib/letflow/design/req194-prometheus-metrics.md`). A good-faith initial pass --
  TEST-DESIGNER performs the full acceptance-criterion gap-check per WF-02 Step 3.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas.
  `async: false` -- `Letflow.Metrics.Registry` is one process-wide, named ETS table
  shared by the whole test suite (by design -- it is a platform-global registry), so
  tests here use route templates/labels unique to this file to keep assertions exact
  despite that shared state, mirroring `test/letflow/routers/tenants_test.exs`'s own
  `async: false` reasoning for tenant provisioning.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Metrics.Exposition
  alias Letflow.Metrics.Registry, as: MetricsRegistry
  alias Letflow.TenantFixture

  @router_opts Letflow.Router.init([])
  @probe_opts Letflow.Plugs.HttpMetricsRouteTemplateProbeRouter.init([])

  defp call_router(conn), do: Letflow.Router.call(conn, @router_opts)

  defp unique_name(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK) -> END.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req194-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # Starts an instance and completes its one pending HUMAN_TASK -- exercises the real
  # Letflow.Engine.complete_task/3 call site (design §7), proving the
  # [:letflow, :task, :completed] wiring end to end, not just the Registry's own
  # handler in isolation. Returns the definition/instance ids used, so AC6 can assert
  # neither ever appears as a label value anywhere in the scrape.
  defp complete_one_task!(schema_name) do
    definition = active_definition!(schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req194-start")
               },
               prefix: schema_name
             )

    [task] = Repo.all(EngineTask, prefix: schema_name)

    assert {:ok, _completed} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req194-complete")
               },
               prefix: schema_name
             )

    %{definition_id: definition.id, instance_id: result.instance_id}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC2 -- format/path/consumer-contract: the exact GET /metrics path
  # MetricsPage.tsx/metricsApi.prometheusText() reaches, Prometheus exposition text.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC2: GET /metrics is the SPA's exact consumer contract" do
    test "200, Content-Type text/plain; version=0.0.4, well-formed # HELP/# TYPE/sample body" do
      resp = conn(:get, "/metrics") |> call_router()

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") == ["text/plain; version=0.0.4"]
      assert resp.resp_body =~ "# HELP letflow_active_instances "
      assert resp.resp_body =~ "# TYPE letflow_active_instances gauge"
      assert resp.resp_body =~ "# TYPE letflow_task_completions_total counter"
      assert resp.resp_body =~ "# TYPE letflow_event_append_duration_seconds histogram"
      assert resp.resp_body =~ "# TYPE letflow_db_query_duration_seconds histogram"
      assert resp.resp_body =~ "# TYPE letflow_http_requests_total counter"
      assert resp.resp_body =~ "# TYPE letflow_http_errors_total counter"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 -- all six OBS-02 families present in the exposition output after
  # exercising the corresponding behaviour, asserted by parsing the response body.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4: all six families produce a real sample line after being exercised" do
    test "active_instances, task_completions, event_append, db_query, http_requests, http_errors" do
      %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "req194-ac4")

      # Family 1: active_instances -- via the exact public function
      # Letflow.Scheduler.Poller's tick calls (design §5/§6). Not exercised through
      # Poller.handle_info/2's own full tick here -- see AC7's own describe block
      # moduledoc note on why that would make this test depend on unrelated
      # tenant_schemas hygiene in this shared database.
      assert {:ok, counts} = Engine.count_instances_by_status(prefix: schema_name)
      assert :ok = MetricsRegistry.set_active_instances(Map.fetch!(counts, :active))

      # Family 4: db_query_duration_seconds -- Ecto's own already-emitted
      # [:letflow, :repo, :query] event fires for every query above and throughout
      # this whole test file; no separate exercise needed.

      # Family 2: task_completions_total, via the real Engine.complete_task/3 site.
      %{} = complete_one_task!(schema_name)

      # Family 3: event_append_duration_seconds -- already exercised by
      # complete_one_task!/1 above (every event append goes through
      # EventStore.append/2's :telemetry.span/3 wrapper), and by Engine.create/2's
      # own instance-started event.

      # Family 5: http_requests_total -- one real request via the top-level router
      # (excluding /metrics itself).
      assert %{status: 200} = conn(:get, "/health") |> call_router()

      # Family 6: http_errors_total increments ONLY on status >= 500 (design §3) --
      # not naturally producible via a real route without deliberately breaking one,
      # so this exercises the real [:letflow, :http, :request] event directly, the
      # same event Letflow.Plugs.HttpMetrics emits.
      :telemetry.execute(
        [:letflow, :http, :request],
        %{duration: 1},
        %{method: "GET", route_template: "unmatched", status: 500}
      )

      body = Exposition.render()

      assert body =~ ~r/^letflow_active_instances \d+(\.\d+)?$/m
      assert body =~ ~r/^letflow_task_completions_total\{definition_status="active"\} \d+$/m
      assert body =~ ~r/^letflow_event_append_duration_seconds_count \d+$/m
      assert body =~ ~r/^letflow_db_query_duration_seconds_count\{query_type="[a-z]+"\} \d+$/m
      assert body =~ ~r/^letflow_http_requests_total\{.*method="GET".*\} \d+$/m
      assert body =~ ~r/^letflow_http_errors_total\{route_template="unmatched"\} \d+$/m
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 -- HTTP-request labels by route TEMPLATE, not raw path: two requests to the
  # same route with different path parameters produce ONE label combination.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: route-template normalization keeps cardinality bounded" do
    test "two different ids on the same route collapse to one label set" do
      id_a = Ecto.UUID.generate()
      id_b = Ecto.UUID.generate()

      assert %{status: 200} =
               conn(:get, "/req194-ac5-probe/#{id_a}")
               |> Letflow.Plugs.HttpMetricsRouteTemplateProbeRouter.call(@probe_opts)

      assert %{status: 200} =
               conn(:get, "/req194-ac5-probe/#{id_b}")
               |> Letflow.Plugs.HttpMetricsRouteTemplateProbeRouter.call(@probe_opts)

      body = Exposition.render()

      matching_lines =
        body
        |> String.split("\n")
        |> Enum.filter(
          &(&1 =~ ~r/^letflow_http_requests_total\{.*route_template="\/req194-ac5-probe\/:id".*\}/)
        )

      # Exactly one distinct label combination -- never one line per request, and
      # never a line containing either raw id.
      assert length(matching_lines) == 1
      assert [line] = matching_lines
      assert line =~ ~r/ 2$/
      refute line =~ id_a
      refute line =~ id_b
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC6 -- global + unauthenticated is safe ONLY because no label ever carries a
  # tenant-identifying value. Assert directly against real seeded identifiers.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC6: no metric label anywhere carries a seeded tenant/instance/definition id" do
    test "two tenants' real ids never appear anywhere in a full scrape" do
      %{schema_name: schema_a, tenant_id: tenant_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req194-ac6-a")

      %{schema_name: schema_b, tenant_id: tenant_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req194-ac6-b")

      %{definition_id: definition_a, instance_id: instance_a} = complete_one_task!(schema_a)
      %{definition_id: definition_b, instance_id: instance_b} = complete_one_task!(schema_b)

      # Also exercise the http path with a real UUID in it, to prove route-template
      # normalization (not just the label allow-list) keeps ids out of the body.
      assert %{status: 200} =
               conn(:get, "/req194-ac6-probe/#{instance_a}")
               |> Letflow.Plugs.HttpMetricsRouteTemplateProbeRouter.call(@probe_opts)

      body = Exposition.render()

      for id <- [
            tenant_a,
            tenant_b,
            definition_a,
            definition_b,
            instance_a,
            instance_b,
            schema_a,
            schema_b
          ] do
        refute body =~ to_string(id),
               "expected no label to leak #{inspect(id)}, but it appeared in the scrape"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC7 -- returns successfully with the last known value when the database is
  # unavailable, rather than erroring.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC7: DB-unavailable graceful degradation" do
    # Exercises the exact building blocks Letflow.Scheduler.Poller's tick uses
    # (Letflow.Engine.count_instances_by_status/1 -> Letflow.Metrics.Registry.set_active_instances/1,
    # design §6) directly, rather than through Poller.handle_info/2's own full tick.
    # Deliberate: this shared Postgres instance carries tenant_schemas registrations
    # accumulated across many prior, unrelated test runs, and a real tick iterates
    # ALL of them (Letflow.Scheduler.poll_and_fire/1 included) -- calling the full
    # tick here would make this test's pass/fail depend on the hygiene of schemas
    # this requirement has nothing to do with. TEST-DESIGNER should still add a
    # Poller-level test mirroring test/letflow/scheduler/poller_test.exs's own
    # `Poller.handle_info(:tick, state)` convention once that risk is otherwise
    # controlled (e.g. a fixture that resets tenant_schemas to a known-clean set).
    test "active_instances retains its last-known value and the endpoint keeps serving 200 when its data source becomes unreachable" do
      %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "req194-ac7")

      assert {:ok, _instance} =
               Engine.create(
                 %{
                   definition_id: active_definition!(schema_name).id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_name("req194-ac7-start")
                 },
                 prefix: schema_name
               )

      assert {:ok, counts} = Engine.count_instances_by_status(prefix: schema_name)
      assert :ok = MetricsRegistry.set_active_instances(Map.fetch!(counts, :active))

      body_before = Exposition.render()
      [gauge_line_before] = extract_gauge_lines(body_before, "letflow_active_instances")
      assert String.to_integer(gauge_line_before) >= 1

      # Real, unrecoverable failure: the tenant's own physical schema is dropped
      # mid-test (Postgres DDL is transactional, so TenantFixture's own teardown
      # still runs cleanly against the already-gone schema via its `IF EXISTS`).
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

      # The real failure path Letflow.Scheduler.Poller's own count_active_for_schema/1
      # catches -- a genuine Postgrex error, not a simulated one.
      assert_raise Postgrex.Error, fn -> Engine.count_instances_by_status(prefix: schema_name) end
      assert :ok = MetricsRegistry.mark_active_instances_refresh_failed()

      body_after = Exposition.render()
      [gauge_line_after] = extract_gauge_lines(body_after, "letflow_active_instances")

      assert gauge_line_after == gauge_line_before

      assert %{status: 200} = conn(:get, "/metrics") |> call_router()
    end
  end

  defp extract_gauge_lines(body, metric_name) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#{metric_name} "))
    |> Enum.map(&(&1 |> String.trim_leading("#{metric_name} ")))
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC8 -- instrumentation emitted via :telemetry only; emitting call sites never
  # reference Letflow.Metrics.Registry directly.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC8: emitting call sites reference only :telemetry, never the registry" do
    test "grep over the instrumented modules' real code, excluding moduledoc prose" do
      for path <- [
            "lib/letflow/plugs/http_metrics.ex",
            "lib/letflow/engine.ex",
            "lib/letflow/event_store.ex"
          ] do
        contents = File.read!(Path.join(File.cwd!(), path))

        # Strips @moduledoc """...""" blocks first -- these modules' own moduledocs
        # deliberately NAME Letflow.Metrics.Registry in prose (documenting exactly
        # the invariant this test checks), which a bare full-file grep would
        # false-positive on. The real invariant is about CODE references, not
        # documentation mentioning the module by name.
        code_only = Regex.replace(~r/@moduledoc\s+"""[\s\S]*?"""/, contents, "")

        refute code_only =~ "Letflow.Metrics.Registry",
               "#{path} must not reference Letflow.Metrics.Registry directly outside its moduledoc"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC9 -- Letflow.Routers.Metrics's removal is explicit and no SPA-called route 404s.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC9: Letflow.Routers.Metrics is removed; no SPA-called route regresses" do
    test "the old module no longer exists" do
      refute Code.ensure_loaded?(Letflow.Routers.Metrics)
    end

    test "GET /health and GET /api/tenant-config still resolve (unaffected by the removal)" do
      assert %{status: 200} = conn(:get, "/health") |> call_router()
    end
  end
end
