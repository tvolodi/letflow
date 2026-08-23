defmodule Letflow.EventStore.PlatformEventsTest do
  @moduledoc """
  Tests for `Letflow.EventStore.append_platform_event/2` and
  `Letflow.EventStore.PlatformEvents` (REQ-140). See `test/specs/REQ-140.md`
  for the full test-case rationale and
  `lib/letflow/design/req140-platform-event-append-path.md` for the
  gate-approved design this file exercises.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file, and no mocked `SandboxPool` for the
  `PROMOTION_ASSERTION_TEARDOWN_FAILED` fixture (a real release failure is
  driven, not stubbed -- mirrors
  `test/letflow/definitions/promotion_assertion_rerun_test.exs`'s own
  established technique).

  ## Fixture strategy

  Every test provisions its own tenant(s) via `Letflow.TenantFixture`
  (`provisioned_tenant/1` below) -- real `CREATE SCHEMA` + a real
  `TenantProvisioning.replay_migrations/1` -- so the three REQ-140 platform
  event types are already seeded on every schema this file touches (they are
  unconditionally part of `@platform_event_type_seed_attrs`, REQ-140 §5.1),
  exactly like a real, non-test-fixture tenant. `async: false` for the whole
  module, same reasoning as every other file in this project that switches
  `Letflow.Repo`'s sandbox mode to `:auto` (see e.g.
  `test/letflow/event_store_test.exs`'s moduledoc for the full
  ExUnit-source-level proof this file relies on rather than re-deriving).

  ## AC5's "captured, never hand-written" technique

  For each of the three promotion event types, this file calls the REAL
  producer (`Promotion.promote_definition/3`, `Definitions.rollback_definition_version/4`,
  `Definitions.apply_promotion_assertion_rerun/6`) with an injected
  `event_appender` that only records what it was called with (mirrors
  `promotion_test.exs`'s/`rollback_test.exs`'s/
  `promotion_assertion_rerun_test.exs`'s own `recording_event_appender/1`),
  never hand-writes the attrs map. The captured map is then fed into the
  real `Letflow.EventStore.PlatformEvents` adapter, invoked for real against
  a genuinely provisioned tenant schema, so a schema mismatch between the
  seeded `json_schema` and what the producer actually builds surfaces as a
  real `{:error, {:payload_validation_failed, _}}` from
  `Registry.validate_payload/3`, not a hand-authored fixture that could
  silently drift from the producer's real shape.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionArtifact
  alias Letflow.Definitions.PromotionArtifact.Assertion
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.EventStore.PlatformEvents
  alias Letflow.EventStore.Registry
  alias Letflow.SandboxPool
  alias Letflow.SandboxPool.FixtureLoader.FixtureRow
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- tenant provisioning
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req140-platform-events") do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-140 Platform Events Test Tenant"
      )

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp table_count(schema, schema_name) do
    Repo.aggregate(schema, :count, prefix: schema_name)
  end

  defp unique_idempotency_key(prefix \\ "REQ140") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_type_name(prefix \\ "REQ140_EVT") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # A minimal, permissive event type (accepts any JSON object), for the
  # generic append_platform_event/2 tests (AC1-AC4) that are not about
  # schema validation.
  defp register_event_type!(tenant_id) do
    name = unique_type_name()

    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "REQ-140 test fixture"
               },
               tenant_id
             )

    name
  end

  defp platform_attrs(event_type, overrides \\ %{}) do
    Map.merge(
      %{
        instance_id: EventStore.platform_instance_id(),
        event_type: event_type,
        payload: Jason.encode!(%{}),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key()
      },
      overrides
    )
  end

  defp seed_projection!(schema_name, instance_id, status \\ :active) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: status,
      last_event_seq: 0,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp event_by_id(schema_name, event_id) do
    Repo.one(from(e in Event, where: e.event_id == ^event_id), prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- process_definitions / rollback (mirrors rollback_test.exs)
  # ---------------------------------------------------------------------------------

  defp unique_process_key(prefix \\ "req140-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_attrs(overrides) do
    Map.merge(
      %{
        name: unique_process_key(),
        version: "1.0.0",
        graph: valid_graph(),
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp create!(schema_name, overrides) do
    assert {:ok, definition} = Definitions.create(create_attrs(overrides), prefix: schema_name)
    definition
  end

  defp activate!(schema_name, id) do
    assert {:ok, %{definition: definition}} = Definitions.activate(id, prefix: schema_name)
    definition
  end

  defp reread!(schema_name, id) do
    Repo.get!(ProcessDefinition, id, prefix: schema_name)
  end

  defp two_version_history!(schema_name, process_key) do
    v1 = create!(schema_name, %{name: process_key, version: "1.0.0"})
    _v1_active = activate!(schema_name, v1.id)
    v2 = create!(schema_name, %{name: process_key, version: "2.0.0"})
    v2_active = activate!(schema_name, v2.id)

    %{v1: reread!(schema_name, v1.id), v2: v2_active}
  end

  defp allow, do: fn _actor_id, _tenant_id -> true end

  defp recording_event_appender(test_pid) do
    fn event_attrs, prefix ->
      send(test_pid, {:event_appended, event_attrs, prefix})
      {:ok, %{event_id: Ecto.UUID.generate()}}
    end
  end

  defp sample_plan(tenant_id, process_key) do
    %{
      source_tenant_id: Ecto.UUID.generate(),
      target_tenant_id: tenant_id,
      process_key: process_key,
      source_definition_id: Ecto.UUID.generate(),
      target_definition_id: nil,
      base_version: nil,
      entries: [
        %{
          type: :graph_node,
          id: "n-#{System.unique_integer([:positive, :monotonic])}",
          change_kind: :added,
          before: nil,
          after: %{"id" => "n1", "node_type" => "START"}
        }
      ]
    }
  end

  defp digest_for(plan), do: PromotionDigest.compute_plan_digest(plan)

  defp review_pending!(schema_name, tenant_id, process_key) do
    plan = sample_plan(tenant_id, process_key)
    digest = digest_for(plan)

    assert {:ok, review} =
             PromotionReviewStore.insert_review(
               %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
               prefix: schema_name
             )

    review
  end

  defp review_approved!(schema_name, tenant_id, process_key) do
    review = review_pending!(schema_name, tenant_id, process_key)

    assert {:ok, approved} =
             PromotionReviewStore.approve_review(
               review.id,
               Ecto.UUID.generate(),
               review.plan_digest,
               prefix: schema_name
             )

    approved
  end

  defp review_applied!(schema_name, tenant_id, process_key) do
    approved = review_approved!(schema_name, tenant_id, process_key)

    assert {:ok, applied} =
             PromotionReviewStore.mark_review_applied(approved.id, prefix: schema_name)

    applied
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- Promotion.promote_definition/3 (mirrors promotion_test.exs)
  # ---------------------------------------------------------------------------------

  defp insert_definition!(schema_name, attrs) do
    base = %{
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  defp promo_activate!(schema_name, id) do
    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(id)]
             )
  end

  defp insert_active_definition!(schema_name, attrs) do
    definition = insert_definition!(schema_name, attrs)
    promo_activate!(schema_name, definition.id)
    %{definition | status: :active}
  end

  defp review_for(plan, overrides \\ %{}) do
    base = %{
      id: Ecto.UUID.generate(),
      plan_digest: PromotionDigest.compute_plan_digest(plan),
      def_id: plan.process_key,
      serialised_plan: Jason.encode!(plan),
      requested_by: Ecto.UUID.generate(),
      status: :approved,
      row_version: 2
    }

    struct(PromotionReview, Map.merge(base, overrides))
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- apply_promotion_assertion_rerun/6 real teardown-failure
  # path (mirrors promotion_assertion_rerun_test.exs's own fixtures, the minimum
  # subset this file needs)
  # ---------------------------------------------------------------------------------

  defp start_pool!(opts) do
    name = :"req140_platform_events_test_pool_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SandboxPool.start_link(Keyword.put_new(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp fixed_rng_seed, do: 1_700_000_000 * 4_294_967_296 + 424_242

  defp assertion(overrides \\ %{}) do
    base = %{
      id: "req140-assertion-#{System.unique_integer([:positive, :monotonic])}",
      payload: Jason.encode!(%{"result" => "expected"})
    }

    attrs = Map.merge(base, overrides)
    %Assertion{id: attrs.id, payload: attrs.payload}
  end

  defp valid_process_definition_fixture_row(overrides \\ %{}) do
    now =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:microsecond)
      |> NaiveDateTime.to_iso8601()

    row_json =
      %{
        "id" => Ecto.UUID.generate(),
        "tenant_id" => Ecto.UUID.generate(),
        "name" => "req140-fixture-#{System.unique_integer([:positive, :monotonic])}",
        "version" => "1.0.0",
        "status" => "draft",
        "graph" => %{"nodes" => [], "edges" => []},
        "created_by" => Ecto.UUID.generate(),
        "created_at" => now,
        "updated_at" => now
      }
      |> Map.merge(overrides)
      |> Jason.encode!()

    %FixtureRow{table_name: "process_definitions", row_json: row_json}
  end

  defp artifact(overrides \\ %{}) do
    base = %{
      id: "req140-artifact-#{System.unique_integer([:positive, :monotonic])}",
      assertions: [assertion()],
      fixtures: [valid_process_definition_fixture_row()],
      rng_seed: fixed_rng_seed(),
      non_deterministic_fields: [],
      candidate_definitions: []
    }

    attrs = Map.merge(base, overrides)

    %PromotionArtifact{
      id: attrs.id,
      assertions: attrs.assertions,
      fixtures: attrs.fixtures,
      rng_seed: attrs.rng_seed,
      non_deterministic_fields: attrs.non_deterministic_fields,
      candidate_definitions: attrs.candidate_definitions
    }
  end

  defp default_style_result(%Assertion{payload: payload}) do
    if byte_size(payload) > 0, do: {:ok, payload}, else: {:ok, "{}"}
  end

  # Same technique promotion_assertion_rerun_test.exs's own
  # evaluator_releasing_sandbox_once/1 uses: on its first invocation, reads the
  # sandbox_id currently claimed by `pool` and calls the REAL SandboxPool.release/2
  # for it, so finish_replay/8's own SUBSEQUENT Step 5 release call gets a real
  # {:error, :not_found} -- a genuine release failure, not a stubbed one.
  defp evaluator_releasing_sandbox_once(pool) do
    fn assertion, _injection ->
      unless Process.get(:req140_already_released) do
        Process.put(:req140_already_released, true)
        %{active: active} = :sys.get_state(pool)

        case Map.keys(active) do
          [sandbox_id] -> SandboxPool.release(sandbox_id, pool)
          other -> flunk("expected exactly one active sandbox claim, got: #{inspect(other)}")
        end
      end

      default_style_result(assertion)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1: "EventStore.append_platform_event/2 appends successfully for a tenant
  # with NO instance_projections row for platform_instance_id/0, verified by a
  # test asserting that table is empty for that id both before and after the
  # call, and that the returned event_id names a real row in `events`"
  # ---------------------------------------------------------------------------------

  describe "AC1 -- appends with no instance_projections row for platform_instance_id/0" do
    test "succeeds; instance_projections stays empty for the sentinel before and after" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)

      assert table_count(InstanceProjection, schema_name) == 0

      assert {:ok, %{event: event, is_duplicate: false}} =
               EventStore.append_platform_event(platform_attrs(event_type), prefix: schema_name)

      assert table_count(InstanceProjection, schema_name) == 0

      assert event.instance_id == EventStore.platform_instance_id()

      # The returned event_id names a REAL row in `events` -- re-read directly
      # from Postgres, not just the in-memory reply.
      persisted = event_by_id(schema_name, event.event_id)
      assert persisted != nil
      assert persisted.event_id == event.event_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: "append_platform_event/2 called with any instance_id other than
  # platform_instance_id/0 returns an error tuple and writes nothing ... a
  # randomly generated UUID and a real started instance's id are both covered"
  # ---------------------------------------------------------------------------------

  describe "AC2 -- any instance_id other than platform_instance_id/0 is rejected" do
    test "a random UUID is rejected, zero rows written" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)

      before_count = table_count(Event, schema_name)

      assert {:error, :not_platform_instance_id} =
               EventStore.append_platform_event(
                 platform_attrs(event_type, %{instance_id: Ecto.UUID.generate()}),
                 prefix: schema_name
               )

      assert table_count(Event, schema_name) == before_count
    end

    test "a real started instance's id is also rejected, zero rows written" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      real_instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, real_instance_id, :active)

      before_count = table_count(Event, schema_name)

      assert {:error, :not_platform_instance_id} =
               EventStore.append_platform_event(
                 platform_attrs(event_type, %{instance_id: real_instance_id}),
                 prefix: schema_name
               )

      assert table_count(Event, schema_name) == before_count
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: "three successive append_platform_event/2 calls under the shared
  # sentinel receive sequence_number 1, 2, 3, asserted by reading the rows back
  # ordered by sequence_number, demonstrating M2 assign_sequence works with no
  # projection row present"
  # ---------------------------------------------------------------------------------

  describe "AC3 -- three successive calls get sequence_number 1, 2, 3" do
    test "sequence numbers are 1, 2, 3 in call order, confirmed by reading rows back ordered" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)

      assert {:ok, %{event: e1}} =
               EventStore.append_platform_event(platform_attrs(event_type), prefix: schema_name)

      assert {:ok, %{event: e2}} =
               EventStore.append_platform_event(platform_attrs(event_type), prefix: schema_name)

      assert {:ok, %{event: e3}} =
               EventStore.append_platform_event(platform_attrs(event_type), prefix: schema_name)

      assert e1.sequence_number == 1
      assert e2.sequence_number == 2
      assert e3.sequence_number == 3

      rows =
        Repo.all(
          from(e in Event,
            where: e.instance_id == ^EventStore.platform_instance_id(),
            order_by: e.sequence_number
          ),
          prefix: schema_name
        )

      assert Enum.map(rows, & &1.sequence_number) == [1, 2, 3]
      assert Enum.map(rows, & &1.event_id) == [e1.event_id, e2.event_id, e3.event_id]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4: "re-appending with the same deterministic idempotency key yields
  # exactly one `events` row, asserted by a count query, and both calls return
  # the SAME event_id rather than a second one"
  # ---------------------------------------------------------------------------------

  describe "AC4 -- re-appending with the same idempotency key is a no-op" do
    test "second call with the same idempotency_key returns the same event_id, one row total" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      attrs = platform_attrs(event_type)

      assert {:ok, %{event: first, is_duplicate: false}} =
               EventStore.append_platform_event(attrs, prefix: schema_name)

      assert {:ok, %{event: second, is_duplicate: true}} =
               EventStore.append_platform_event(attrs, prefix: schema_name)

      assert first.event_id == second.event_id

      count =
        Repo.aggregate(
          from(e in Event, where: e.idempotency_key == ^attrs.idempotency_key),
          :count,
          prefix: schema_name
        )

      assert count == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 (1/3): DEFINITION_PROMOTED -- attrs captured from the real producer
  # (Promotion.promote_definition/3), then validated against its seeded
  # json_schema by a real append_definition_promoted/2 call.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- DEFINITION_PROMOTED validates against its seeded schema using the real producer's attrs" do
    test "captured event_attrs from promote_definition/3 validates via a real append_definition_promoted/2 call" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} =
        provisioned_tenant("req140-promoted-src")

      %{tenant_id: target_tenant_id, schema_name: target_schema} =
        provisioned_tenant("req140-promoted-tgt")

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "2.0.0",
          graph: %{"nodes" => [%{"id" => "n1", "node_type" => "START"}], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)
      actor_id = Ecto.UUID.generate()
      test_pid = self()

      assert {:ok, _result} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      assert_received {:event_appended, event_attrs, _received_prefix}
      assert event_attrs.event_type == "DEFINITION_PROMOTED"

      # Never hand-written: this is the real attrs map append_promotion_event/9
      # itself built, now run through the real adapter for real schema
      # validation against a freshly provisioned tenant.
      assert {:ok, %{event_id: event_id}} =
               PlatformEvents.append_definition_promoted(event_attrs, target_schema)

      assert is_binary(event_id)
      assert event_by_id(target_schema, event_id) != nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 (2/3): DEFINITION_VERSION_ROLLED_BACK -- attrs captured from the real
  # producer (finish_rollback/7, via rollback_definition_version/4), then
  # validated against its seeded json_schema by a real
  # append_definition_version_rolled_back/2 call.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- DEFINITION_VERSION_ROLLED_BACK validates against its seeded schema using the real producer's attrs" do
    test "captured event_attrs from finish_rollback/7 validates via a real append_definition_version_rolled_back/2 call" do
      %{schema_name: schema_name} = provisioned_tenant("req140-rollback-schema")
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)
      test_pid = self()

      assert {:ok, _result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      assert_received {:event_appended, event_attrs, _received_prefix}
      assert event_attrs.event_type == "DEFINITION_VERSION_ROLLED_BACK"

      assert {:ok, %{event_id: event_id}} =
               PlatformEvents.append_definition_version_rolled_back(event_attrs, schema_name)

      assert is_binary(event_id)
      assert event_by_id(schema_name, event_id) != nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 (3/3) + AC6: PROMOTION_ASSERTION_TEARDOWN_FAILED -- attrs captured from
  # the real producer (apply_teardown_precedence/append_teardown_failure_event,
  # via apply_promotion_assertion_rerun/6's real teardown-failure path), then
  # validated against its seeded json_schema by a real
  # append_promotion_assertion_teardown_failed/2 call. Also proves AC6: the
  # producer's attrs carry `tenant_id` and no `actor_id`, yet the real adapter
  # call neither rejects tenant_id nor errors on the missing actor_id, and the
  # persisted row's actor_id is platform_actor_id/0.
  # ---------------------------------------------------------------------------------

  describe "AC5 + AC6 -- PROMOTION_ASSERTION_TEARDOWN_FAILED validates and substitutes platform_actor_id/0" do
    test "captured event_attrs (tenant_id present, no actor_id) validates via a real append call; persisted actor_id == platform_actor_id/0" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant("req140-teardown")
      review = review_pending!(schema_name, tenant_id, unique_process_key())
      passing = assertion(%{payload: Jason.encode!(%{"result" => "req140-passing"})})
      art = artifact(%{assertions: [passing]})
      test_pid = self()
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(test_pid),
                 assertion_evaluator: evaluator_releasing_sandbox_once(pool)
               )

      assert result.status == :teardown_failed
      assert result.teardown_event_appended == true

      assert_received {:event_appended, event_attrs, _received_prefix}
      assert event_attrs.event_type == "PROMOTION_ASSERTION_TEARDOWN_FAILED"
      # The producer's own attrs map carries tenant_id and no actor_id --
      # confirmed here directly, never assumed.
      assert Map.has_key?(event_attrs, :tenant_id)
      assert event_attrs.tenant_id == tenant_id
      refute Map.has_key?(event_attrs, :actor_id)

      # Never hand-written: the real captured attrs map, run through the real
      # adapter for real schema validation. Neither :tenant_id_not_accepted nor
      # :missing_actor_id occurs.
      assert {:ok, %{event_id: event_id}} =
               PlatformEvents.append_promotion_assertion_teardown_failed(
                 event_attrs,
                 schema_name
               )

      persisted = event_by_id(schema_name, event_id)
      assert persisted != nil
      assert persisted.actor_id == EventStore.platform_actor_id()
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 + AC8: "the appender satisfies definitions.ex:595-597's event_appender_fun
  # type -- a test asserts that the :event_id key of the map finish_rollback/7
  # returns and the persisted superseded_by column both carry the same event_id
  # that append_platform_event/2 returned ... the fixture seeds EXACTLY ONE
  # promotion_reviews row in :applied or :approved status for the process_key"
  # ---------------------------------------------------------------------------------

  describe "AC7 + AC8 -- the real adapter's event_id flows into both finish_rollback/7's map and the persisted superseded_by column" do
    test "PlatformEvents.append_definition_version_rolled_back/2 used as the real event_appender: result.event_id == persisted superseded_by, with exactly one applied review matching" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant("req140-ac7-ac8")
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)

      # Exactly ONE promotion_reviews row in :applied status for this
      # process_key -- AC8's non-vacuity requirement. supersede_matching_review/3's
      # [] branch (zero matches) and [_, _ | _] branch (ambiguous) both return
      # nil and mutate nothing, so without this exactly-one fixture the
      # superseded_by assertion below would pass vacuously (nil == nil).
      applied = review_applied!(schema_name, tenant_id, process_key)
      assert applied.status == :applied

      assert {:ok, result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: &PlatformEvents.append_definition_version_rolled_back/2
               )

      assert is_binary(result.event_id)
      assert result.superseded_review_id == applied.id

      # The event_id really was written by append_platform_event/2 -- not a
      # stub or fabricated id.
      persisted_event = event_by_id(schema_name, result.event_id)
      assert persisted_event != nil
      assert persisted_event.event_type == "DEFINITION_VERSION_ROLLED_BACK"

      reread_review = Repo.get!(PromotionReview, applied.id, prefix: schema_name)
      assert reread_review.status == :superseded
      # Both the returned map's :event_id key AND the persisted superseded_by
      # column carry the SAME event_id append_platform_event/2 returned.
      assert reread_review.superseded_by == result.event_id
    end
  end
end
