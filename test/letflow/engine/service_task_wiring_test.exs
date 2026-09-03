defmodule Letflow.Engine.ServiceTaskWiringTest do
  @moduledoc """
  Tests for REQ-215's engine wiring of `:SERVICE_TASK` nodes -- transition-layer
  purity, activation-time INSERT (config parse/render/validate), re-entry via
  `Letflow.Engine.advance_after_service_task_outcome/4` once REQ-214's dispatcher
  resolves a row, and cancellation. See
  `handoffs/WF02-REQ215-20260903/step-00-git-setup.json`'s own acceptance-criteria
  list and `lib/letflow/design/req215-service-task-engine-wiring.md` (the
  gate-approved design this file's tests verify against).

  Mirrors `test/letflow/engine/timer_wiring_test.exs`'s own structure and
  conventions closely -- REQ-215's own requirement text and design doc both
  state this requirement "mirrors REQ-187's own split from REQ-186 exactly."
  Also mirrors `test/letflow/engine/service_task_dispatcher_test.exs`'s own
  `:service_task_ssrf_validation_enabled` real-HTTP test-server seam (REQ-214's
  own precedent) for AC1's real HTTPS-shaped round trip.

  Does NOT re-cover ground the mechanical REQ-214/REQ-215 handoff already
  fixed in `test/letflow/engine/transition_test.exs`'s own `"transition/3 --
  :SERVICE_TASK entry"` describe block (pure `dispatch_service_task/3`
  park-and-emit behavior, not caught by the catch-all) -- this file covers the
  impure activation-time caller, the re-entry function, and cancellation, all
  requiring a real Postgres-backed instance.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false`, matching every other tenant-fixture-using file in this
  codebase. `SERVICE_TASK_COMPLETED`/`INSTANCE_STARTED`/`INSTANCE_CANCELLED`/
  `INSTANCE_ERROR` are all auto-seeded by `TenantFixture.provisioned_tenant!/1`'s
  own `replay_migrations/1` call (confirmed by `timer_wiring_test.exs`'s own
  moduledoc for the equivalent TIMER_FIRED case; `tenant_provisioning.ex`'s own
  `@platform_event_type_seed_attrs` list, design doc §3.2, carries the new
  `SERVICE_TASK_COMPLETED` entry this requirement adds).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req215-svcwiring") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-215 SERVICE_TASK Wiring Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("req215-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp base_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req215-start")
      },
      overrides
    )
  end

  defp cancel_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req215-cancel")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req215-complete")
      },
      overrides
    )
  end

  # START -> SERVICE_TASK(inline_url) -> END. `endpoint` is the SERVICE_TASK
  # node's own url_template (Letflow.Engine.ServiceTask.parse_config_from_node_attributes/1
  # reads it under the "endpoint" attribute key, confirmed by direct reading of
  # lib/letflow/engine/service_task.ex).
  defp graph_service_task_end(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK -> SERVICE_TASK -> END -- lets a test drive the
  # SERVICE_TASK dispatch row's own token_id off a real, separate token
  # advance (complete_task/3) rather than only from create/2's own hop-chain,
  # matching this requirement's "a SERVICE_TASK's outgoing edge can lead into
  # another dispatch-needing node" framing used throughout the design doc.
  defp graph_human_task_service_task_end(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-any"}},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  defp dispatches_for(schema_name, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp service_task_completed_events_for(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "SERVICE_TASK_COMPLETED")
    |> Repo.all(prefix: schema_name)
  end

  defp enable_ssrf_bypass do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- a definition containing a SERVICE_TASK node whose route_kind is
  # inline_url, dispatched against a real (test-server) HTTPS-shaped endpoint
  # returning a 2xx JSON object, starts an instance whose token reaches that
  # node, parks (no {:error, {:node_type_not_yet_implemented, :SERVICE_TASK,
  # _}}), and is later advanced past the node once REQ-214's dispatcher
  # resolves it.
  # ---------------------------------------------------------------------------------

  describe "AC1: end-to-end SERVICE_TASK dispatch against a real test-server endpoint" do
    test "instance starts, token parks at the SERVICE_TASK node with a real pending dispatch row, then advances past it once the poller resolves the row" do
      enable_ssrf_bypass()

      %{url: server_url} = WebhookTestServer.start(200, ~s({"approved":true,"limit":5000}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      # Parked, not the old node_type_not_yet_implemented stub -- create/2
      # itself succeeded (the assertion above already proves this structurally:
      # a {:error, {:activation_failed, {:node_type_not_yet_implemented, ...}}}
      # would have failed the assert {:ok, result} pattern match).
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.current_nodes == ["svc"]

      [token_record] = Repo.all(TokenRecord, prefix: schema_name)
      assert token_record.status == :active
      assert token_record.node_id == "svc"

      # A real service_task_dispatches row, pending, config_snapshot carrying
      # the rendered_url (AC1's own "dispatched against" wording -- proven by
      # a real row existing with the real server's URL frozen into it).
      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.status == "pending"
      assert dispatch.node_id == "svc"
      assert dispatch.config_snapshot["rendered_url"] == server_url
      assert dispatch.config_snapshot["route_kind"] == "inline_url"

      # attempt_dispatch/2 (REQ-214's already-shipped transport call) resolves
      # it -- a real 2xx JSON response from the real local server.
      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert decoded_body == %{"approved" => true, "limit" => 5000}

      reloaded_dispatch = Repo.get!(ServiceTaskDispatch, dispatch.id, prefix: schema_name)
      assert reloaded_dispatch.status == "advanced"

      # This requirement's own re-entry function, called the same way
      # ServiceTaskDispatcher.poll_and_dispatch/1's reduce loop calls it
      # (design doc §3.1) -- proves the token actually advances off the
      # SERVICE_TASK node onto its outgoing edge. Asserted against the
      # single-wrapped {:ok, :advanced} its own @spec (engine.ex:2749-2752)
      # promises -- ELIXIR-DEV's fix for the double-wrap defect originally
      # found while writing this test (see the "DEFECT (FIXED):
      # advance_after_service_task_outcome/4's :advance clause used to
      # double-wrap its own success result" describe block below for the
      # full history: root cause, downstream consequence, and the fix).
      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:advance, decoded_body},
                 Repo,
                 schema_name
               )

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :completed

      # Instance :completed (already asserted above) is itself the proof the
      # token advanced past "svc" onto its outgoing edge to "end" -- a
      # START -> SERVICE_TASK -> END graph only reaches :completed once the
      # END node is actually processed (dispatch_end/3 removes the token
      # from the live list). The persisted TokenRecord's own node_id is left
      # at its last-known value ("svc") by design (matching every other
      # completed-token precedent in this codebase, e.g. timer_wiring_test.exs's
      # own TIMER -> END case, which asserts only token_record.status ==
      # :completed, never a changed node_id) -- asserted here for status
      # only, not re-derived incorrectly as a node_id change.
      [final_token] = Repo.all(TokenRecord, prefix: schema_name)
      assert final_token.status == :completed

      # SERVICE_TASK_COMPLETED domain event carries the decoded body (design
      # doc §3.2 step 5).
      assert [event] = service_task_completed_events_for(schema_name, instance_id)
      assert event.payload["dispatch_id"] == dispatch.id
      assert event.payload["node_id"] == "svc"
      assert event.payload["decoded_body"] == %{"approved" => true, "limit" => 5000}
    end
  end

  # ---------------------------------------------------------------------------------
  # IMPLEMENTATION DEFECT found while writing AC1's own coverage, reported per
  # this handoff's own instructions, and since FIXED by ELIXIR-DEV -- NOT a
  # named acceptance criterion, kept as its own describe block so this
  # history (and its regression coverage) stays legible on its own.
  #
  # Letflow.Engine.advance_after_service_task_outcome/4's own @spec
  # (engine.ex:2466-2477) promises {:ok, :advanced} for the :advance outcome.
  # The originally observed return value was {:ok, {:ok, :advanced}} --
  # double-wrapped. Root cause, traced directly (engine.ex):
  #   - do_persist_service_task_advance/10's own success clause (formerly
  #     line 2750) returned {:ok, {:ok, :advanced}} where {:ok, :advanced}
  #     alone would match the @spec (compare handle_success/3's TIMER-side
  #     analogue, which returns a single-wrapped {:ok, :advanced}-shaped
  #     value at the equivalent point).
  #   - That value flowed up through persist_service_task_advance/10 and
  #     advance_service_task_dispatch/4 UNCHANGED.
  #   - advance_after_service_task_outcome/4's own :advance clause
  #     (line 2478) wrapped it AGAIN: `repo.transaction(fn -> case ... do
  #     {:ok, result} -> result end)` unwraps ONE layer (result becomes
  #     {:ok, :advanced}), then repo.transaction/1 itself wraps the
  #     anonymous function's return value in a SECOND {:ok, _} envelope --
  #     producing the final {:ok, {:ok, :advanced}}.
  #
  # Downstream consequence, proven below: ServiceTaskDispatcher.poll_and_dispatch/1
  # (service_task_dispatcher.ex:589-601's own call_advance_after_service_task_outcome/3)
  # pattern-matches on exactly {:ok, :advanced}/{:ok, :error_set}/
  # {:ok, :already_final} -- neither matched {:ok, {:ok, :advanced}} -- so a
  # REAL :advance outcome used to CRASH poll_and_dispatch/1 with a
  # CaseClauseError. This is AC1's own literal, real end-to-end path ("later
  # advanced past the node once REQ-214's dispatcher resolves it," via
  # poll_and_dispatch/1).
  #
  # THE FIX (ELIXIR-DEV, lib/letflow/engine.ex:2749-2752):
  # do_persist_service_task_advance/10's success clause now returns
  # {:ok, :advanced}, not {:ok, {:ok, :advanced}}. Both tests below are
  # updated from their original bug-documenting form to genuine positive
  # regression coverage of the fix: the first now proves
  # poll_and_dispatch/1 completes without raising and actually advances the
  # token through the real poller entry point (AC1's own end-to-end path,
  # via the one call chain the original test could not exercise because of
  # this bug); the second proves advance_after_service_task_outcome/4's
  # return value now matches its own @spec exactly.
  # ---------------------------------------------------------------------------------

  describe "DEFECT (FIXED): advance_after_service_task_outcome/4's :advance clause used to double-wrap its own success result, crashing poll_and_dispatch/1" do
    test "poll_and_dispatch/1 resolves a genuine :advance outcome without raising, advancing the token through the real poller entry point" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id
      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.status == "pending"

      # The real poller entry point (design doc §3.1's own reduce loop) --
      # claims, dispatches, and advances the token in one call, with no
      # direct attempt_dispatch/2 + advance_after_service_task_outcome/4
      # scaffolding from this test. Used to raise CaseClauseError; now
      # completes and returns its normal dispatch_poll_result() map, with
      # the one claimed row correctly folded into :advanced (not :retried
      # or :given_up, and not silently dropped by the {:error, _reason}
      # defensive fold that a resurfaced double-wrap defect would trigger).
      assert %{claimed: 1, advanced: 1, retried: 0, given_up: 0} =
               ServiceTaskDispatcher.poll_and_dispatch(schema_name)

      reloaded_dispatch = Repo.get!(ServiceTaskDispatch, dispatch.id, prefix: schema_name)
      assert reloaded_dispatch.status == "advanced"

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :completed
    end

    test "Engine.advance_after_service_task_outcome/4's :advance clause returns {:ok, :advanced}, matching its own @spec" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id
      assert [dispatch] = dispatches_for(schema_name, instance_id)

      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      actual =
        Engine.advance_after_service_task_outcome(
          dispatch.id,
          {:advance, decoded_body},
          Repo,
          schema_name
        )

      # Single-wrapped, matching the @spec exactly -- the regression guard
      # against the double-wrap defect returning.
      assert actual == {:ok, :advanced}
      refute actual == {:ok, {:ok, :advanced}}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- the dispatch row and its state-transition event are written in ONE
  # transaction: a test that forces the event append to fail leaves no
  # service_task_dispatches row behind. Reuses the exact "missing :actor_id
  # fails EventStore.append/2's own event-append step" forced-failure
  # technique test/letflow/engine_test.exs's own REQ-047 AC2 test, and
  # timer_wiring_test.exs's own AC2 test, already established.
  # ---------------------------------------------------------------------------------

  describe "AC3: dispatch row + state-transition event are in one transaction" do
    test "missing :actor_id fails the event append and leaves zero service_task_dispatches rows" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)

      assert dispatches_for(schema_name, Ecto.UUID.generate()) == []
      assert Repo.aggregate(ServiceTaskDispatch, :count, prefix: schema_name) == 0
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema_name) == 0
      assert Repo.aggregate(TokenRecord, :count, prefix: schema_name) == 0
    end

    test "the same one-transaction guarantee holds for a SERVICE_TASK reached mid-hop-chain (HUMAN_TASK -> SERVICE_TASK)" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      [task] = Repo.all(EngineTask, prefix: schema_name)

      # Force the completion's own event-append step to fail the same way --
      # a missing idempotency_key on complete_task/3's own required attrs
      # (fetch_actor_and_idempotency_key/1-equivalent pre-transaction check
      # for complete_task/3 is only actor_id/idempotency_key presence, same
      # class of forced failure as cancel_instance/3's own AC5 precedent
      # test below, adapted to the hop chain that would otherwise create a
      # SERVICE_TASK dispatch row for "svc").
      too_long_key = String.duplicate("x", 256)

      assert {:error, {:event_append_failed, :idempotency_key_too_long}} =
               Engine.complete_task(
                 task.id,
                 complete_attrs(%{idempotency_key: too_long_key}),
                 prefix: schema_name
               )

      # No SERVICE_TASK dispatch row was ever created for "svc" -- the whole
      # hop-chain's Multi rolled back, including the INSERT this event's
      # own failed append would otherwise have accompanied.
      assert dispatches_for(schema_name, instance_id) == []

      # The HUMAN_TASK itself is unaffected (still open) -- proves this was a
      # clean rollback, not partial corruption.
      reloaded_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert reloaded_task.status == :pending
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a URL template that renders to an empty string is rejected at
  # activation via build_empty_url_error_attrs/1, routing to
  # Letflow.Engine.set_instance_error/2's ERROR path, never creating a
  # dispatch row.
  # ---------------------------------------------------------------------------------

  describe "AC4: an empty-rendered-URL template routes to the ERROR path, never creates a dispatch row" do
    test "a url_template that is entirely one placeholder referencing an unset variable renders empty and is rejected" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(schema_name, graph_service_task_end("{{variables.missing}}"))

      assert {:error, {:activation_failed, {:service_task_url_rendered_empty, "svc"}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      # create/2's own "must write nothing on failure" contract (design doc
      # §2.1 point 3) -- no instance, no token, no dispatch row at all for
      # this specific case, since activation itself aborted before any
      # persist/1 Multi ran.
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema_name) == 0
      assert Repo.aggregate(TokenRecord, :count, prefix: schema_name) == 0
      assert Repo.aggregate(ServiceTaskDispatch, :count, prefix: schema_name) == 0
    end

    test "an empty-rendered-URL reached mid-hop-chain routes the already-persisted instance to ERROR, never inserting a dispatch row" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_human_task_service_task_end("{{variables.missing}}")
        )

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      [task] = Repo.all(EngineTask, prefix: schema_name)

      # This requirement's own AC4 wording: "routes to
      # Letflow.Engine.set_instance_error/2's ERROR path" -- the design doc's
      # own §2.4 clarifies this is satisfied in substance via the SAME
      # ExecutionError.append_multi/3 sink set_instance_error/2 itself
      # delegates to, composed into the hop-chain's own already-open Multi
      # (not a second, standalone transaction). complete_task/3's own
      # interpret_complete_result/1 (engine.ex) maps this outcome to
      # {:error, {:instance_execution_error, error_type, affected}} --
      # req061's own established shape for an in-hop-chain ERROR transition
      # (the Multi still COMMITS; this is not a rollback/failure of the
      # call itself, confirmed below by the instance's own real, persisted
      # :error status).
      assert {:error,
              {:instance_execution_error, :service_task_url_rendered_empty, {:node, "svc"}}} =
               Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :error
      assert final_projection.error_detail["error_type"] == "service_task_url_rendered_empty"

      # Structurally, no dispatch row was ever created for "svc" -- step 4 of
      # §2.2 halts before step 5's arm_attrs construction (design doc §2.4).
      assert dispatches_for(schema_name, instance_id) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- cancelling an instance with a still-pending service_task_dispatches
  # row marks that row status: "given_up", last_failure_kind:
  # "instance_cancelled" (the verified schema-shape-forced decision, design
  # doc §4 -- no "cancelled" status value exists in this table's own domain)
  # in the SAME transaction as the instance's own status flip, and REQ-214's
  # dispatcher never dispatches a cancelled row.
  # ---------------------------------------------------------------------------------

  describe "AC5: cancel_instance/3 marks a still-pending dispatch row given_up/instance_cancelled in the same transaction" do
    test "an ordinary cancel_instance/3 call marks the pending dispatch row given_up with last_failure_kind instance_cancelled" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%ServiceTaskDispatch{status: "pending"} = dispatch] =
               dispatches_for(schema_name, instance_id)

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      reloaded = Repo.get!(ServiceTaskDispatch, dispatch.id, prefix: schema_name)
      assert reloaded.status == "given_up"
      assert reloaded.last_failure_kind == "instance_cancelled"
      assert reloaded.dispatched_at != nil

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :cancelled

      # REQ-214's dispatcher never dispatches a cancelled row -- already
      # guaranteed structurally by claim_due_dispatch_ids/2's own
      # status == "pending" filter (design doc §4's own AC5 argument), proven
      # here empirically: a poll immediately after cancellation claims and
      # advances/gives-up nothing.
      poll_result = ServiceTaskDispatcher.poll_and_dispatch(schema_name)
      assert poll_result.claimed == 0
    end

    test "cancel_pending_dispatches/4 only touches PENDING rows -- an already-advanced row for the SAME instance is left untouched" do
      # Regression guard for the status filter itself
      # (`d.status == "pending"` in ServiceTaskDispatcher.cancel_pending_dispatches/4)
      # -- mutation-confirmed this session: removing that filter clause (while
      # keeping the instance_id filter intact) left every other test in this
      # suite green, since none of them independently seed a SECOND,
      # already-terminal dispatch row on the SAME instance being cancelled
      # and assert it survives untouched. A same-instance-different-status
      # row is the only shape that actually exercises the status predicate
      # (a different-instance row is already excluded by the instance_id
      # filter alone, which this mutation does not touch).
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      %Letflow.EventStore.InstanceProjection{}
      |> Ecto.Changeset.change(%{
        instance_id: instance_id,
        status: :active,
        definition_id: Ecto.UUID.generate(),
        last_event_seq: 0
      })
      |> Repo.insert!(prefix: schema_name)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      config_snapshot = %{
        "route_kind" => "inline_url",
        "url_template" => "https://127.0.0.1/hook",
        "rendered_url" => "https://127.0.0.1/hook",
        "method" => "POST",
        "body_template" => nil,
        "headers" => %{},
        "timeout_ms" => 5_000,
        "retry_limit" => 3
      }

      base_attrs = %{
        tenant_id: Ecto.UUID.generate(),
        instance_id: instance_id,
        node_id: "n1",
        config_snapshot: config_snapshot,
        next_attempt_at: now,
        created_at: now
      }

      # A genuinely-pending row on this instance (arm_changeset/2, REQ-215's
      # own real INSERT path -- forces status: "pending") -- the one
      # cancellation is actually supposed to touch.
      pending_attrs =
        Map.merge(base_attrs, %{id: Ecto.UUID.generate(), token_id: Ecto.UUID.generate()})

      assert {:ok, pending_dispatch} =
               %ServiceTaskDispatch{}
               |> ServiceTaskDispatch.arm_changeset(pending_attrs)
               |> Repo.insert(prefix: schema_name)

      # An already-"advanced" row on the SAME instance -- built the same way,
      # then flipped to "advanced" via terminal_changeset/2 (REQ-214's own
      # real, established write path for this transition -- the same
      # function attempt_dispatch/2's own success path uses), so this row is
      # exactly what a real prior successful dispatch on this instance would
      # look like.
      already_advanced_attrs =
        Map.merge(base_attrs, %{id: Ecto.UUID.generate(), token_id: Ecto.UUID.generate()})

      assert {:ok, already_advanced_dispatch} =
               %ServiceTaskDispatch{}
               |> ServiceTaskDispatch.arm_changeset(already_advanced_attrs)
               |> Repo.insert(prefix: schema_name)

      assert {:ok, already_advanced_dispatch} =
               already_advanced_dispatch
               |> ServiceTaskDispatch.terminal_changeset(%{
                 status: "advanced",
                 dispatched_at: now
               })
               |> Repo.update(prefix: schema_name)

      cancelled_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, 1} =
               ServiceTaskDispatcher.cancel_pending_dispatches(
                 Repo,
                 instance_id,
                 cancelled_at,
                 schema_name
               )

      reloaded_pending = Repo.get!(ServiceTaskDispatch, pending_dispatch.id, prefix: schema_name)
      assert reloaded_pending.status == "given_up"
      assert reloaded_pending.last_failure_kind == "instance_cancelled"

      # The already-"advanced" row on the SAME instance is completely
      # untouched -- still "advanced", last_failure_kind still nil.
      reloaded_advanced =
        Repo.get!(ServiceTaskDispatch, already_advanced_dispatch.id, prefix: schema_name)

      assert reloaded_advanced.status == "advanced"
      assert reloaded_advanced.last_failure_kind == nil
      assert reloaded_advanced.dispatched_at != nil
    end

    test "forcing the :event step to fail (idempotency_key too long) rolls back the dispatch cancellation too -- same transaction as the instance's own status flip" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%ServiceTaskDispatch{status: "pending"} = dispatch] =
               dispatches_for(schema_name, instance_id)

      too_long_key = String.duplicate("x", 256)

      assert {:error, {:event_append_failed, :idempotency_key_too_long}} =
               Engine.cancel_instance(
                 instance_id,
                 cancel_attrs(%{idempotency_key: too_long_key}),
                 prefix: schema_name
               )

      # The dispatch row's own cancellation-marking was rolled back alongside
      # everything else in run_cancel_instance/5's own Multi -- still
      # pending, not given_up.
      reloaded = Repo.get!(ServiceTaskDispatch, dispatch.id, prefix: schema_name)
      assert reloaded.status == "pending"
      assert reloaded.last_failure_kind == nil

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end

    test "the race: a row claimed (locked) but not yet dispatched at cancellation time is never advanced by the concurrent claimant afterward" do
      # Forces the exact race the handoff names explicitly: "row
      # claimed-but-not-yet-dispatched at cancellation time." Simulated
      # deterministically (no real concurrency needed to prove the invariant)
      # by claiming the row's id via claim_due_dispatch_ids/2 (which does NOT
      # itself change status -- confirmed by reading
      # service_task_dispatcher.ex's own §5.4 design, the row stays "pending"
      # until attempt_dispatch/2 actually runs), THEN cancelling the instance
      # before attempt_dispatch/2 is ever called for that claimed id -- the
      # same ordering a real concurrent poller tick racing a real concurrent
      # cancel_instance/3 call could produce.
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [dispatch] = dispatches_for(schema_name, instance_id)

      # "Claimed" (a real poller would have read this id off
      # claim_due_dispatch_ids/2 already, before attempt_dispatch/2 itself
      # runs) -- status is still "pending" in the DB at this point, exactly
      # the window the race targets.
      assert [claimed_id] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
      assert claimed_id == dispatch.id

      # The instance is cancelled while that claimed id has not yet been
      # dispatched.
      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      # The concurrent claimant now (belatedly) calls attempt_dispatch/2 for
      # the id it claimed earlier -- attempt_dispatch/2 re-fetches/re-locks
      # the row itself (design precedent, service_task_dispatcher.ex's own
      # fetch_and_lock_dispatch/2), so it observes the row's CURRENT status,
      # not a stale value from the earlier claim read.
      assert {:ok, :already_final} =
               ServiceTaskDispatcher.attempt_dispatch(claimed_id, schema_name)

      reloaded = Repo.get!(ServiceTaskDispatch, dispatch.id, prefix: schema_name)
      assert reloaded.status == "given_up"
      assert reloaded.last_failure_kind == "instance_cancelled"

      # No real HTTP request was ever sent to the real server for this row --
      # structural proof the "claimed" window did not let the row slip
      # through to a real dispatch after cancellation.
      refute_receive {:webhook_test_server_request, _request}, 200
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- lib/letflow/engine/transition.ex contains no :httpc/HTTPoison/Req/
  # File call after this change, and its moduledoc names the new
  # pending_event() variant and which InstanceState field carries the parked
  # token. Mirrors the original TIMER/REQ-187 purity-grep precedent
  # (transition.ex's own moduledoc "Purity (AC1)" section documents the exact
  # grep command) -- a static/source-text check, not a runtime one, matching
  # this requirement's own handoff wording ("can be a compile-time or
  # static-check test rather than a runtime one").
  # ---------------------------------------------------------------------------------

  describe "AC6: transition.ex purity -- no HTTP/file call, moduledoc names the new variant/field" do
    # Strips @moduledoc/@doc/@typedoc string-literal bodies before checking
    # for real call syntax -- transition.ex's own moduledoc (AC1's own
    # "Purity" section) *documents* the grep command that names
    # HTTPoison/Req./File./:httpc as prose, quoted verbatim inside its own
    # """ string, which would otherwise false-positive a naive substring
    # match against the whole raw file (confirmed empirically: a naive
    # `refute source =~ "HTTPoison"` fails against this file's own,
    # unmodified moduledoc, not against any real call). This mirrors
    # service_task_dispatcher_test.exs's own established technique for the
    # same class of hazard ("Checks for actual CALL syntax ... not mere
    # prose mentions").
    defp strip_doc_strings(source) do
      Regex.replace(~r/@(?:module)?doc\s+"""[\s\S]*?"""/, source, "")
    end

    test "grep-equivalent: no :httpc/HTTPoison/Req/File CALL anywhere in transition.ex's real code" do
      code =
        File.read!(Path.join(File.cwd!(), "lib/letflow/engine/transition.ex"))
        |> strip_doc_strings()

      refute code =~ ":httpc."
      refute code =~ "HTTPoison"
      refute code =~ ~r/\bReq\./
      refute code =~ ~r/\bFile\./
    end

    test "the module's own broader purity grep (extended with HTTP-client names) still returns zero matches across the 3 pure-kernel files' real code" do
      code =
        [
          "lib/letflow/engine/instance_state.ex",
          "lib/letflow/engine/token.ex",
          "lib/letflow/engine/transition.ex"
        ]
        |> Enum.map(&File.read!(Path.join(File.cwd!(), &1)))
        |> Enum.map(&strip_doc_strings/1)
        |> Enum.join("\n")

      forbidden = [
        "Repo.",
        "Logger.",
        "DateTime.",
        "System.os_time",
        "System.system_time",
        "HTTPoison",
        ~r/\bReq\./,
        ~r/\bFile\./,
        ":rand.",
        ":crypto."
      ]

      Enum.each(forbidden, fn pattern -> refute code =~ pattern end)
    end

    test "moduledoc names the new pending_event() variant, {:service_task_dispatch_requested, ...}" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/engine/transition.ex"))

      [_before, moduledoc_and_rest] = String.split(source, "@moduledoc \"\"\"", parts: 2)
      [moduledoc, _rest] = String.split(moduledoc_and_rest, "\"\"\"", parts: 2)

      assert moduledoc =~ "{:service_task_dispatch_requested"
    end

    test "moduledoc names the InstanceState field carrying the parked token, pending_service_task_nodes" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/engine/transition.ex"))

      [_before, moduledoc_and_rest] = String.split(source, "@moduledoc \"\"\"", parts: 2)
      [moduledoc, _rest] = String.split(moduledoc_and_rest, "\"\"\"", parts: 2)

      assert moduledoc =~ "pending_service_task_nodes"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- docs/migration/stage-7-simulation-uat-parity.md's REQ-210 REVIEWER
  # sign-off entry no longer attributes the Meridian quorum/disbursement gap
  # to join_counters, and instead correctly names this requirement's own fix.
  # ---------------------------------------------------------------------------------

  describe "AC7: stage-7-simulation-uat-parity.md's REQ-210 sign-off is corrected" do
    test "the corrected text is present; the stale mis-attribution text is absent" do
      doc =
        File.read!(Path.join(File.cwd!(), "docs/migration/stage-7-simulation-uat-parity.md"))

      # Whitespace-collapsed so a line-wrap difference in the real doc can't
      # hide (or spuriously break) a match on either the corrected phrase or
      # the stale one.
      collapsed = doc |> String.replace(~r/\s+/, " ")

      # Item (1)'s own corrected sentence (design doc §5) -- join_counters/
      # ISS-0397's own real, correctly-scoped finding is kept, but now
      # explicitly states it did NOT alone unblock the Meridian
      # committee-vote/quorum/disbursement paths, and forward-points to
      # ISS-0411/REQ-215.
      assert collapsed =~
               "this defect alone did not fully unblock the Meridian loan-origination scenarios' committee-vote/quorum/disbursement"

      assert collapsed =~ "ISS-0411"
      assert collapsed =~ "REQ-215"

      # Item (d)'s own closing clause naming this requirement as the
      # follow-up work that closes the gap (design doc §5's "Also update ...
      # item (d)'s own closing clause").
      assert collapsed =~ "This follow-up work is REQ-215"

      # The stale text this design's §5 replaces: the ORIGINAL item (1)
      # sentence directly attributed the Meridian committee-vote/quorum/
      # disbursement paths to join_counters as a plain, unqualified
      # consequence ("...HTTP calls -- blocked both Meridian ... paths
      # (`ISS-0397`, resolved);"), with no corrective clause at all --
      # verified absent.
      refute collapsed =~
               "separate task-completion HTTP calls (`ISS-0397`, resolved) -- blocked both Meridian"
    end
  end

  # ---------------------------------------------------------------------------------
  # REVIEWER/SECURITY-REVIEWER-traced findings given real regression coverage
  # (handoff's own "Also test" section) -- not named acceptance criteria, but
  # real behavior both gates already inspected in the code and asked to be
  # locked in with a real test rather than only a code read.
  # ---------------------------------------------------------------------------------

  describe "the :advance outcome's variable-merge behavior actually merges the 2xx body" do
    test "VariableMerge.merge/3's output (the decoded 2xx body) is present in the instance's own variables after advancing" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"credit_score":720}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [dispatch] = dispatches_for(schema_name, instance_id)

      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:advance, decoded_body},
                 Repo,
                 schema_name
               )

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :completed
      assert final_projection.variables["credit_score"] == 720
    end
  end

  describe "the :give_up outcome folds both instance-terminal and instance-already-error races to a benign {:ok, :error_set}" do
    test "instance already :completed (a benign race) -- give_up still returns {:ok, :error_set}, does not fail" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [dispatch] = dispatches_for(schema_name, instance_id)

      # Independently complete/terminate the instance BEFORE the give_up
      # re-entry call lands -- forces set_instance_error/2's own
      # {:error, {:instance_terminal, :cancelled}} race branch.
      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      standalone_error_attrs = %{
        instance_id: instance_id,
        error_type: :service_task_retries_exhausted,
        affected: {:node, "svc"},
        reason: "service task retries exhausted",
        variables: %{},
        details: %{last_failure_kind: :network, attempt_index: 3, retry_limit: 3},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req215-give-up-race")
      }

      assert {:ok, :error_set} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:give_up, standalone_error_attrs},
                 Repo,
                 schema_name
               )

      # Instance stays cancelled (the earlier, real terminal transition) --
      # this benign race did not overwrite it or raise.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :cancelled
    end

    test "instance already :error (a second, equally benign race) -- give_up still returns {:ok, :error_set}, does not fail" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_service_task_end(server_url))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [dispatch] = dispatches_for(schema_name, instance_id)

      first_error_attrs = %{
        instance_id: instance_id,
        error_type: :service_task_retries_exhausted,
        affected: {:node, "svc"},
        reason: "first give_up sets the instance to ERROR",
        variables: %{},
        details: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req215-give-up-first")
      }

      assert {:ok, %{status: :error}} =
               Engine.set_instance_error(first_error_attrs, prefix: schema_name)

      # A SECOND, independent give_up call for the same instance now hits
      # {:error, {:instance_already_error, _}} instead of {:instance_terminal, _}
      # -- the other co-equal race branch (design doc §3.3), proven distinctly
      # from the :cancelled case above.
      second_error_attrs = %{
        instance_id: instance_id,
        error_type: :service_task_retries_exhausted,
        affected: {:node, "svc"},
        reason: "second, concurrent give_up races the first",
        variables: %{},
        details: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req215-give-up-second")
      }

      assert {:ok, :error_set} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:give_up, second_error_attrs},
                 Repo,
                 schema_name
               )

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
      # The FIRST error's own reason won -- proves the second call did not
      # overwrite the already-set error (set_instance_error/2's own
      # {:error, {:instance_already_error, _}} branch never re-runs the
      # write).
      assert projection.error_detail["reason"] == "first give_up sets the instance to ERROR"
    end
  end

  describe "the minimal {{variables.KEY}} renderer -- basic substitution, and no regression toward something unsafe" do
    test "basic substitution: a template with one placeholder resolves against a real instance variable" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))
      %{port: port} = URI.parse(server_url)

      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_service_task_end("http://127.0.0.1:#{port}/hook/{{variables.application_id}}")
        )

      assert {:ok, result} =
               Engine.create(
                 base_attrs(definition, %{initial_variables: %{"application_id" => "APP-42"}}),
                 prefix: schema_name
               )

      instance_id = result.instance_id
      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.config_snapshot["rendered_url"] == "http://127.0.0.1:#{port}/hook/APP-42"
    end

    test "a missing variable renders to the empty string, not the literal placeholder text -- regression guard" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))
      %{port: port} = URI.parse(server_url)

      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_service_task_end("http://127.0.0.1:#{port}/hook?ref={{variables.missing_key}}")
        )

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.config_snapshot["rendered_url"] == "http://127.0.0.1:#{port}/hook?ref="
      refute dispatch.config_snapshot["rendered_url"] =~ "{{"
      refute dispatch.config_snapshot["rendered_url"] =~ "}}"
    end

    test "no nested/double-substitution: a variable whose OWN value looks like a template placeholder is inserted literally, never re-expanded" do
      # Regression guard the handoff explicitly asks for: "the renderer
      # doesn't do anything WORSE than simple substitution (no eval, no
      # double-substitution/nested-template expansion)." A variable value
      # that itself contains "{{variables.other}}" text must appear verbatim
      # in the rendered URL, not be recursively re-rendered against a SECOND
      # variable.
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))
      %{port: port} = URI.parse(server_url)

      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_service_task_end("http://127.0.0.1:#{port}/hook?ref={{variables.tricky}}")
        )

      assert {:ok, result} =
               Engine.create(
                 base_attrs(definition, %{
                   initial_variables: %{
                     "tricky" => "{{variables.other}}",
                     "other" => "SHOULD_NOT_APPEAR"
                   }
                 }),
                 prefix: schema_name
               )

      instance_id = result.instance_id
      assert [dispatch] = dispatches_for(schema_name, instance_id)

      rendered = dispatch.config_snapshot["rendered_url"]
      # The literal placeholder text from `tricky`'s own value survives
      # un-expanded (URI-encoded by nothing here, since this renderer does
      # not URL-encode -- confirmed by direct substitution, matching the
      # design's own "one Regex.replace/3 call" minimal scope).
      assert rendered == "http://127.0.0.1:#{port}/hook?ref={{variables.other}}"
      refute rendered =~ "SHOULD_NOT_APPEAR"
    end
  end
end
