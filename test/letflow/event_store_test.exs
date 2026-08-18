defmodule Letflow.EventStoreTest do
  @moduledoc """
  Tests for `Letflow.EventStore.append/2` (REQ-025) and `read/2`/`read_global/1`/
  `point_in_time/3`/`archive/1`/the three platform sentinel accessors (REQ-026).
  See `test/specs/REQ-025.md` and `test/specs/REQ-026.md` for the full
  test-case rationale. The pure-schema/migration half of REQ-026's
  `event_retention_policies` coverage (acceptance criterion 5) lives in
  `test/letflow/event_store/retention_policy_test.exs` instead, mirroring the
  existing schemas_test.exs/migrations_test.exs split.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## REQ-026 fixture strategy -- direct `Event`/`InstanceSequence` seeding

  Several REQ-026 tests (`archive/1`'s idempotency/policy-precedence/
  lock-scope cases, and the not-found-vs-empty-list distinction) need events
  with a `created_at` in the deliberate past -- `append/2` always stamps
  `DateTime.utc_now()`, and no test in this project may depend on wall-clock
  time (`docs/guides/test_developer_guide.md` principle 3), so waiting for a
  real event to "age" is not an option. Those tests instead seed `Event`
  (and, where needed, `InstanceSequence`) rows directly via
  `Event.insert_changeset/2`/`InstanceSequence.insert_changeset/2` +
  `Repo.insert!/2`, bypassing `append/2` entirely -- the same direct-seeding
  idiom `test/letflow/event_store/migrations_test.exs`'s own `ON DELETE
  RESTRICT` test already uses for this exact reason. `seed_event!/7` and
  `seed_instance_sequence!/3` below are that idiom, factored out for reuse.
  `event_retention_policies` rows seeded by these tests are cleaned up via
  `on_exit/1` in `seed_retention_policy!/1` since this file's tests run under
  Sandbox `:auto` mode (next paragraph), not the ordinary rolled-back
  transaction `retention_policy_test.exs` relies on.

  ## Fixture strategy -- read before adding a test here

  Per `lib/letflow/design/req025-event-append.md` §9 OQ-5 (RESOLVED, per
  REVIEWER's Step 2d ruling) and §6.2.1 (M1): `append/2` is **update-only**
  for `instance_projections` -- it never creates that row. Every test whose
  `append/2` call is meant to reach the transactional phase (i.e. every test
  except the deliberate `:instance_not_started` case and the pre-transaction
  failure cases) pre-seeds the target instance's `instance_projections` row
  directly via `Repo.insert!/2` (`seed_projection!/4` below), never via
  `append/2` itself -- exactly the strategy the design doc names as
  REVIEWER-confirmed.

  Every test provisions its own tenant (`provisioned_tenant/1`, mirroring
  `test/letflow/event_store/registry_test.exs`'s and
  `test/letflow/tenant_provisioning_test.exs`'s established pattern: real
  `CREATE SCHEMA`, real `tenant_scoped_migrations/0` replay -- which now
  includes all six of REQ-023's event-store tables plus REQ-024's
  `event_type_registry`, so one `provisioned_tenant/1` call is enough to
  exercise `append/2` end to end). `Ecto.Migrator` needs a second real DB
  connection the DataCase sandbox can't hand out, hence Sandbox `:auto` mode
  and manual `on_exit/1` cleanup instead of the normal rolled-back
  transaction. `async: false` for the whole module (ExUnit's `async` setting
  is module-wide, not per-test) -- required for the same reason those two
  files are `async: false`: the `:auto`-mode switch is only safe because
  ExUnit fully drains every `async: true` module before running any
  `async: false` module, and runs `async: false` modules one at a time (see
  those files' own moduledocs for the full ExUnit-source-level proof this
  file relies on rather than re-deriving).

  Because every test starts from a genuinely fresh, empty tenant schema (a
  brand new `CREATE SCHEMA` + migration replay per test), "zero rows written"
  assertions below check whole-table counts under that tenant's `:prefix`,
  not a per-instance filter -- nothing else could have written to that schema
  during the test.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.RetentionPolicy
  alias Letflow.EventStore.StoredPayload
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req025-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-025 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Mirrors registry_test.exs's/tenant_provisioning_test.exs's provisioned_tenant/1
  # exactly -- see this file's moduledoc for the full reasoning. Callable both as a
  # `setup` function and directly from inside a test body (registry_test.exs's own
  # "tenant-isolated" test does the latter for a second tenant) -- on_exit/1 may be
  # called from either context.
  defp provisioned_tenant(_context \\ %{}) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_idempotency_key(prefix \\ "IDK") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_type_name(prefix \\ "EVT") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Registers a minimal, permissive event type (schema %{"type" => "object"} by
  # default -- accepts any JSON object) so validate_payload/3 (design doc §6.1 P4)
  # passes for tests whose point is NOT payload-schema validation.
  defp register_event_type!(tenant_id, json_schema \\ %{"type" => "object"}) do
    name = unique_type_name()

    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => json_schema,
                 "description" => "REQ-025 test fixture"
               },
               tenant_id
             )

    name
  end

  defp append_attrs(event_type, overrides \\ %{}) do
    Map.merge(
      %{
        instance_id: Ecto.UUID.generate(),
        event_type: event_type,
        payload: Jason.encode!(%{}),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key()
      },
      overrides
    )
  end

  # The "some other mechanism" the design doc's §6.2.1/§9 OQ-5 point to for this
  # requirement's own test coverage -- a direct Repo.insert against
  # instance_projections, NEVER via append/2 itself (append/2 is update-only for
  # this table, design doc §6.2.6 M6).
  # REQ-043 note: definition_id became a required column/field on
  # InstanceProjection (priv/repo/migrations/20260818110001_...), so every
  # caller of insert_changeset/2 -- including this REQ-025/026 fixture --
  # must now supply one. A fresh random UUID is fine here: no test in this
  # file asserts anything about which definition an instance belongs to, and
  # instance_projections.definition_id carries no FK (see
  # Letflow.EventStore.InstanceProjection's own moduledoc).
  defp seed_projection!(schema_name, tenant_id, instance_id, status) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      tenant_id: tenant_id,
      status: status,
      last_event_seq: 0,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp table_count(schema, schema_name) do
    Repo.aggregate(schema, :count, prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # REQ-026 fixtures -- see this module's moduledoc for why these bypass append/2.
  # ---------------------------------------------------------------------------------

  # Direct instance_sequence seeding, for tests that need read/2's STEP 1
  # existence check to succeed (INSTANCE started) without going through a real
  # append/2 call.
  defp seed_instance_sequence!(schema_name, instance_id, next_seq \\ 1) do
    %InstanceSequence{}
    |> InstanceSequence.insert_changeset(%{instance_id: instance_id, next_seq: next_seq})
    |> Repo.insert!(prefix: schema_name)
  end

  # Direct events row seeding, with a caller-chosen created_at (deliberately in
  # the past for archive/1 eligibility tests) and an optional caller-chosen
  # event_id/payload (so a $ref-pointing payload can reference its own
  # event_id, for the ON DELETE RESTRICT ordering test).
  defp seed_event!(schema_name, tenant_id, instance_id, event_type, seq, created_at, opts \\ []) do
    event_id = Keyword.get(opts, :event_id, Ecto.UUID.generate())
    payload = Keyword.get(opts, :payload, %{"seeded" => true})

    %Event{}
    |> Event.insert_changeset(%{
      event_id: event_id,
      created_at: created_at,
      instance_id: instance_id,
      event_type: event_type,
      payload: payload,
      actor_id: Ecto.UUID.generate(),
      sequence_number: seq,
      idempotency_key: unique_idempotency_key(),
      tenant_id: tenant_id
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp seed_stored_payload!(schema_name, event_id, event_created_at, payload) do
    %StoredPayload{}
    |> StoredPayload.insert_changeset(%{
      event_id: event_id,
      event_created_at: event_created_at,
      payload: payload,
      byte_size: byte_size(Jason.encode!(payload))
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # event_retention_policies is GLOBAL (no :prefix, lives in public) -- this
  # file's tests run under Sandbox :auto mode (via provisioned_tenant/1), so a
  # row inserted here is a real commit that needs explicit on_exit/1 cleanup,
  # unlike retention_policy_test.exs's ordinary rolled-back transaction.
  defp seed_retention_policy!(attrs) do
    policy =
      %RetentionPolicy{}
      |> RetentionPolicy.insert_changeset(attrs)
      |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(r in RetentionPolicy, where: r.id == ^policy.id))
    end)

    policy
  end

  # Reads one function's published @doc text through the compiled Docs chunk
  # (never the .ex source as a string), for the platform-sentinel citation
  # test -- mirrors schemas_test.exs's normalized_moduledoc/1 but for a
  # function doc rather than a moduledoc.
  defp function_doc(module, name, arity) do
    {:docs_v1, _anno, _lang, _format, _module_doc, _meta, docs} = Code.fetch_docs(module)

    Enum.find_value(docs, fn
      {{:function, ^name, ^arity}, _anno, _sig, %{"en" => doc}, _meta} -> doc
      _ -> nil
    end)
  end

  # Every table append/2 could conceivably write to EXCEPT instance_projections
  # (which is asserted separately per test, since it may legitimately start with
  # a pre-seeded row already present).
  defp assert_no_writes_to_append_only_tables(schema_name) do
    assert table_count(Event, schema_name) == 0
    assert table_count(InstanceSequence, schema_name) == 0
    assert table_count(IdempotencyRecord, schema_name) == 0
    assert table_count(StoredPayload, schema_name) == 0
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "appending to a terminated instance (status CANCELLED
  # or COMPLETED in instance_projections) returns an error and writes zero rows
  # across all five involved tables"
  # ---------------------------------------------------------------------------------

  describe "terminated instance (AC1)" do
    test "appending against a :completed instance returns {:error, {:instance_terminated, :completed}} and writes zero rows" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()

      projection_before = seed_projection!(schema_name, tenant_id, instance_id, :completed)

      attrs = append_attrs(event_type, %{instance_id: instance_id})

      assert {:error, {:instance_terminated, :completed}} =
               EventStore.append(attrs, prefix: schema_name)

      assert_no_writes_to_append_only_tables(schema_name)
      assert table_count(InstanceProjection, schema_name) == 1

      # The pre-seeded row itself must be provably untouched, not merely "still
      # exists" -- M1 aborts the whole Multi before M6 ever runs.
      assert Repo.get(InstanceProjection, instance_id, prefix: schema_name) == projection_before
    end

    test "appending against a :cancelled instance returns {:error, {:instance_terminated, :cancelled}} and writes zero rows" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()

      projection_before = seed_projection!(schema_name, tenant_id, instance_id, :cancelled)

      attrs = append_attrs(event_type, %{instance_id: instance_id})

      assert {:error, {:instance_terminated, :cancelled}} =
               EventStore.append(attrs, prefix: schema_name)

      assert_no_writes_to_append_only_tables(schema_name)
      assert table_count(InstanceProjection, schema_name) == 1
      assert Repo.get(InstanceProjection, instance_id, prefix: schema_name) == projection_before
    end
  end

  # ---------------------------------------------------------------------------------
  # Load-bearing, beyond REQ-025's 6 numbered acceptance criteria: REVIEWER's
  # Step 2d ruling on the design doc's OQ-5 -- a missing instance_projections row
  # is a DISTINCT failure from :instance_terminated, not an implicit new/active
  # instance. See lib/letflow/event_store.ex's active_instance_guard/3.
  # ---------------------------------------------------------------------------------

  describe "instance_not_started (new failure mode, REVIEWER Step 2d OQ-5 ruling)" do
    test "append against an instance_id with no pre-existing instance_projections row returns {:error, :instance_not_started} and writes zero rows" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)

      attrs = append_attrs(event_type)

      assert {:error, :instance_not_started} = EventStore.append(attrs, prefix: schema_name)

      assert_no_writes_to_append_only_tables(schema_name)
      assert table_count(InstanceProjection, schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "two concurrent appends to the same instance_id never
  # receive the same sequence_number"
  # ---------------------------------------------------------------------------------

  describe "concurrent appends (AC2)" do
    test "two concurrent appends to the same instance_id never receive the same sequence_number" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      # Distinct idempotency_keys -- otherwise the second call could legitimately
      # resolve via the M3 duplicate path instead of racing M2's lock, which would
      # make the "sequence numbers differ" assertion vacuous.
      attrs1 = append_attrs(event_type, %{instance_id: instance_id})
      attrs2 = append_attrs(event_type, %{instance_id: instance_id})

      parent = self()

      run = fn attrs ->
        fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          after
            5000 -> flunk("barrier release never arrived")
          end

          EventStore.append(attrs, prefix: schema_name)
        end
      end

      # Sandbox mode is :auto here (via provisioned_tenant/1) -- every process,
      # including these spawned Tasks, gets its own real, independent Postgres
      # connection automatically, matching registry_test.exs's identical
      # concurrent-race precedent.
      task1 = Task.async(run.(attrs1))
      task2 = Task.async(run.(attrs2))

      assert_receive {:ready, pid1}, 5000
      assert_receive {:ready, pid2}, 5000
      assert pid1 != pid2

      send(pid1, :go)
      send(pid2, :go)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      assert {:ok, %{sequence_number: seq1}} = result1
      assert {:ok, %{sequence_number: seq2}} = result2
      assert seq1 != seq2

      # Confirmed against real Postgres, not just the in-memory replies.
      assert table_count(Event, schema_name) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "appending twice with the same idempotency_key returns
  # is_duplicate: true on the second call and does not insert a second events row"
  # ---------------------------------------------------------------------------------

  describe "idempotency (AC3)" do
    test "appending twice with the same idempotency_key returns is_duplicate: true on the second call and inserts only one events row" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      attrs = append_attrs(event_type, %{instance_id: instance_id})

      assert {:ok,
              %{event: %Event{event_id: event_id1}, is_duplicate: false, sequence_number: seq1}} =
               EventStore.append(attrs, prefix: schema_name)

      assert {:ok,
              %{event: %Event{event_id: event_id2}, is_duplicate: true, sequence_number: seq2}} =
               EventStore.append(attrs, prefix: schema_name)

      # The original event, not a fresh one -- design doc §6.2.3/§6.3.
      assert event_id1 == event_id2
      assert seq1 == seq2

      # INV-AP-6's strictly-stronger property: zero net rows change anywhere on a
      # duplicate, not just "no second events row" (AC3's literal wording).
      assert table_count(Event, schema_name) == 1
      assert table_count(IdempotencyRecord, schema_name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "a payload that fails REQ-024's validate_payload/2
  # results in zero rows written to events, instance_sequence, or
  # instance_projections -- no partial state"
  # ---------------------------------------------------------------------------------

  describe "invalid payload (AC4)" do
    test "a payload failing Registry.validate_payload/3 results in zero rows written anywhere, without ever reaching the instance_projections guard" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      event_type =
        register_event_type!(tenant_id, %{"type" => "object", "required" => ["order_id"]})

      # Deliberately no seed_projection!/4 call: Registry validation (design doc
      # §6.1 P4) runs entirely in the pre-transaction phase, before Repo.transaction
      # is ever opened -- this test proves the payload failure is reported on its
      # own terms (:payload_validation_failed), never masked by/conflated with
      # :instance_not_started even though no instance_projections row exists here.
      attrs = append_attrs(event_type, %{payload: Jason.encode!(%{})})

      assert {:error, {:payload_validation_failed, failures}} =
               EventStore.append(attrs, prefix: schema_name)

      assert [_ | _] = failures

      assert_no_writes_to_append_only_tables(schema_name)
      assert table_count(InstanceProjection, schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "a payload over 4096 bytes is split into
  # events.payload's $ref pointer form plus an event_payload_store row, verified
  # by reading both rows back after append"
  # ---------------------------------------------------------------------------------

  describe "oversized payload (AC5)" do
    test "a payload over 4096 bytes is split into events.payload's $ref pointer form plus a matching event_payload_store row" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      big_payload_map = %{"big" => String.duplicate("a", 5000)}
      raw_payload = Jason.encode!(big_payload_map)
      assert byte_size(raw_payload) > 4096

      attrs = append_attrs(event_type, %{instance_id: instance_id, payload: raw_payload})

      assert {:ok, %{event: %Event{event_id: event_id, payload: events_payload}}} =
               EventStore.append(attrs, prefix: schema_name)

      assert events_payload == %{"$ref" => event_id}

      stored = Repo.get_by(StoredPayload, [event_id: event_id], prefix: schema_name)
      assert %StoredPayload{payload: ^big_payload_map} = stored
      assert stored.byte_size == byte_size(raw_payload)

      # Re-select the events row directly from Postgres too, not just trusting
      # the in-memory reply.
      reselected = Repo.get_by(Event, [event_id: event_id], prefix: schema_name)
      assert reselected.payload == %{"$ref" => event_id}
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 6: tenant_id derivation and isolation. §9 OQ-1 of the
  # design doc: events/instance_projections carry a real tenant_id column
  # (asserted directly, sub-case a); instance_sequence/event_idempotency carry NO
  # such column at all (asserted via schema-prefix reachability instead, sub-case
  # b); a caller-supplied :tenant_id must fail loudly, not silently strip/honor
  # (sub-case c).
  # ---------------------------------------------------------------------------------

  describe "tenant_id (AC6)" do
    test "events and instance_projections rows carry tenant_id equal to the tenant :prefix resolves to" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      # Computed independently of the fixture's own tenant_id, so a derivation bug
      # in append/2 (e.g. reading the wrong opts key, or a broken reverse mapping)
      # would surface as a genuine assertion failure rather than tautologically
      # matching.
      assert {:ok, expected_tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema_name)
      assert expected_tenant_id == tenant_id

      attrs = append_attrs(event_type, %{instance_id: instance_id})

      assert {:ok, %{event: %Event{tenant_id: event_tenant_id}}} =
               EventStore.append(attrs, prefix: schema_name)

      assert event_tenant_id == expected_tenant_id

      projection = Repo.get(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.tenant_id == expected_tenant_id
    end

    test "instance_sequence and event_idempotency rows are reachable only under the correct tenant's schema prefix" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      # A second, genuinely provisioned tenant -- the "wrong" prefix this test
      # queries against must itself be a real schema, or the isolation assertion
      # would be trivially true for the wrong reason (a nonexistent schema).
      %{schema_name: other_schema_name} = provisioned_tenant()

      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      idempotency_key = unique_idempotency_key()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      attrs =
        append_attrs(event_type, %{instance_id: instance_id, idempotency_key: idempotency_key})

      assert {:ok, _result} = EventStore.append(attrs, prefix: schema_name)

      assert %InstanceSequence{} = Repo.get(InstanceSequence, instance_id, prefix: schema_name)
      refute Repo.get(InstanceSequence, instance_id, prefix: other_schema_name)

      assert %IdempotencyRecord{} =
               Repo.get_by(IdempotencyRecord, [idempotency_key: idempotency_key],
                 prefix: schema_name
               )

      refute Repo.get_by(IdempotencyRecord, [idempotency_key: idempotency_key],
               prefix: other_schema_name
             )
    end

    test "attrs carrying a caller-supplied :tenant_id key is rejected outright with {:error, :tenant_id_not_accepted}, not silently stripped or honored" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      disagreeing_tenant_id = Ecto.UUID.generate()
      refute disagreeing_tenant_id == tenant_id

      attrs =
        event_type
        |> append_attrs()
        |> Map.put(:tenant_id, disagreeing_tenant_id)

      # P0 (design doc §6.1) runs before P1-P4 and before the Multi ever opens --
      # no instance_projections row needs seeding for this test to reach a
      # meaningful assertion.
      assert {:error, :tenant_id_not_accepted} = EventStore.append(attrs, prefix: schema_name)

      assert_no_writes_to_append_only_tables(schema_name)
      assert table_count(InstanceProjection, schema_name) == 0
    end
  end

  # ===================================================================================
  # REQ-026 -- read/2, point_in_time/3, read_global/1, archive/1, platform sentinels.
  # See test/specs/REQ-026.md for the full rationale.
  # ===================================================================================

  # -----------------------------------------------------------------------------------
  # Acceptance criterion 1: "read/2 against an instance with N appended events (via
  # REQ-025) returns exactly those N events in ascending sequence_number order, with
  # any large payload transparently resolved from event_payload_store"
  # -----------------------------------------------------------------------------------

  describe "read/2 returns exactly N appended events, ascending sequence_number, $ref resolved (AC1)" do
    test "3 events appended via append/2 (one with an oversized payload) are all returned, in order, with the oversized payload resolved" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      assert {:ok, %{sequence_number: seq1}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      big_payload_map = %{"big" => String.duplicate("a", 5000)}
      raw_payload = Jason.encode!(big_payload_map)
      assert byte_size(raw_payload) > 4096

      assert {:ok, %{event: %Event{event_id: big_event_id}, sequence_number: seq2}} =
               EventStore.append(
                 append_attrs(event_type, %{instance_id: instance_id, payload: raw_payload}),
                 prefix: schema_name
               )

      assert {:ok, %{sequence_number: seq3}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      assert {:ok, events} = EventStore.read(instance_id, prefix: schema_name)

      assert length(events) == 3
      assert Enum.map(events, & &1.sequence_number) == [seq1, seq2, seq3]
      assert Enum.map(events, & &1.sequence_number) == Enum.sort([seq1, seq2, seq3])

      big_event = Enum.find(events, &(&1.event_id == big_event_id))
      # Transparently resolved -- never the raw $ref pointer.
      assert big_event.payload == big_payload_map
      refute match?(%{"$ref" => _}, big_event.payload)
    end

    test "rows inserted out of sequence_number order are still returned ascending -- proves a real ORDER BY" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      event_type = unique_type_name()
      seed_instance_sequence!(schema_name, instance_id)

      created_at = ~U[2026-01-02 03:04:05.000000Z]

      for seq <- [3, 1, 2] do
        seed_event!(schema_name, tenant_id, instance_id, event_type, seq, created_at)
      end

      assert {:ok, events} = EventStore.read(instance_id, prefix: schema_name)
      assert Enum.map(events, & &1.sequence_number) == [1, 2, 3]
    end
  end

  # -----------------------------------------------------------------------------------
  # Acceptance criterion 2: "read/2 against an instance_id with no events returns an
  # explicit not-found error, not an empty list" -- plus the flip side the design doc
  # (§4.2) specifically proves: an instance that DID have events but had them all
  # archived returns a legitimate empty list, not a not-found error.
  # -----------------------------------------------------------------------------------

  describe "read/2: not-found vs. legitimately-empty (AC2)" do
    test "an instance_id with no instance_sequence row (never appended to) returns {:error, :instance_not_found}, never {:ok, []}" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :instance_not_found} =
               EventStore.read(Ecto.UUID.generate(), prefix: schema_name)
    end

    test "an instance that had events, now fully archived, returns {:ok, []} -- NOT :instance_not_found" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      event_type = unique_type_name()
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      seed_event!(schema_name, tenant_id, instance_id, event_type, 1, old_created_at)

      assert table_count(Event, schema_name) == 1

      assert {:ok, %{moved_count: 1}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert table_count(Event, schema_name) == 0

      # instance_sequence's row is untouched (INV-AR-2) -- this instance still
      # "exists" from read/2's STEP 1 point of view.
      assert %InstanceSequence{} = Repo.get(InstanceSequence, instance_id, prefix: schema_name)

      assert {:ok, []} = EventStore.read(instance_id, prefix: schema_name)
    end
  end

  # -----------------------------------------------------------------------------------
  # Acceptance criterion 3: "read_global/1 with after_global_seq set returns only
  # events with a strictly greater global_seq, demonstrated across at least two
  # instances' interleaved events"
  # -----------------------------------------------------------------------------------

  describe "read_global/1: after_global_seq strict lower bound, interleaved instances (AC3)" do
    test "events from two instances, appended interleaved (A1 B1 A2 B2), filter to exactly the strictly-greater-global_seq subset" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_a, :active)
      seed_projection!(schema_name, tenant_id, instance_b, :active)

      assert {:ok, %{event: %Event{event_id: a1_id, global_seq: a1_seq}}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_a}),
                 prefix: schema_name
               )

      assert {:ok, %{event: %Event{event_id: b1_id}}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_b}),
                 prefix: schema_name
               )

      assert {:ok, %{event: %Event{event_id: a2_id}}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_a}),
                 prefix: schema_name
               )

      assert {:ok, %{event: %Event{event_id: b2_id}}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_b}),
                 prefix: schema_name
               )

      assert {:ok, %{events: all_events}} = EventStore.read_global(prefix: schema_name)
      assert Enum.map(all_events, & &1.event_id) == [a1_id, b1_id, a2_id, b2_id]

      assert {:ok, %{events: after_a1, has_more: false}} =
               EventStore.read_global(prefix: schema_name, after_global_seq: a1_seq)

      assert Enum.map(after_a1, & &1.event_id) == [b1_id, a2_id, b2_id]

      # Strictly greater, not >=: a1's own global_seq used as the cursor must not
      # re-include a1 itself.
      refute a1_id in Enum.map(after_a1, & &1.event_id)
    end
  end

  # -----------------------------------------------------------------------------------
  # Acceptance criterion 4: "calling archive/1 twice in a row moves the same rows the
  # first time and zero additional rows the second time (idempotent), verified by row
  # counts before/after each call"
  # -----------------------------------------------------------------------------------

  describe "archive/1 idempotency (AC4)" do
    test "3 eligible events: first call moves all 3, second call (immediately after) moves 0" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      event_type = unique_type_name()
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]

      for seq <- 1..3 do
        seed_event!(schema_name, tenant_id, instance_id, event_type, seq, old_created_at)
      end

      assert table_count(Event, schema_name) == 3
      assert table_count(ArchivedEvent, schema_name) == 0

      assert {:ok, %{moved_count: 3}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert table_count(Event, schema_name) == 0
      assert table_count(ArchivedEvent, schema_name) == 3

      assert {:ok, %{moved_count: 0}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert table_count(Event, schema_name) == 0
      assert table_count(ArchivedEvent, schema_name) == 3
    end
  end

  # -----------------------------------------------------------------------------------
  # Acceptance criterion 6: "archive/1 against an event_type with an explicit
  # event_retention_policies row uses that policy's keep_days/keep_count instead of
  # the global retention_days fallback, demonstrated with a policy row that would
  # move a different set of rows than the global default would"
  #
  # (Acceptance criterion 5 -- the table/CHECK-constraint shape itself -- is covered
  # in test/letflow/event_store/retention_policy_test.exs, not here.)
  # -----------------------------------------------------------------------------------

  describe "archive/1 honors an explicit event_retention_policies row over the global fallback (AC6)" do
    test "a keep_forever policy on one event_type excludes it from an archive/1 call that would otherwise (via the global fallback) have archived it too" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      kept_type = unique_type_name("KEEP")
      archived_type = unique_type_name("ARCH")
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      seed_event!(schema_name, tenant_id, instance_id, kept_type, 1, old_created_at)
      seed_event!(schema_name, tenant_id, instance_id, archived_type, 2, old_created_at)

      seed_retention_policy!(%{event_type: kept_type, policy: :keep_forever})

      # Without the policy row above, retention_days: 30 (both events are from
      # 2020) would archive BOTH event types -- see the contrast test below.
      assert {:ok, %{moved_count: 1}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      kept_remaining =
        Event |> where([e], e.event_type == ^kept_type) |> Repo.all(prefix: schema_name)

      assert length(kept_remaining) == 1

      archived_remaining =
        Event |> where([e], e.event_type == ^archived_type) |> Repo.all(prefix: schema_name)

      assert archived_remaining == []

      archived_rows =
        ArchivedEvent
        |> where([a], a.event_type == ^archived_type)
        |> Repo.all(prefix: schema_name)

      assert length(archived_rows) == 1
    end

    test "contrast: the same two-event-type setup with NO policy row moves both -- proving the policy row above genuinely changed the eligible set" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      type_a = unique_type_name("A")
      type_b = unique_type_name("B")
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      seed_event!(schema_name, tenant_id, instance_id, type_a, 1, old_created_at)
      seed_event!(schema_name, tenant_id, instance_id, type_b, 2, old_created_at)

      assert {:ok, %{moved_count: 2}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert table_count(Event, schema_name) == 0
      assert table_count(ArchivedEvent, schema_name) == 2
    end

    test "a keep_days policy narrower than the global fallback archives its event_type sooner than the global default would" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      narrow_type = unique_type_name("NARROW")
      seed_instance_sequence!(schema_name, instance_id)

      # 10 days old: the global fallback (retention_days: 30) alone would NOT
      # archive this -- only the event_type's own keep_days: 5 policy does.
      ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      seed_event!(schema_name, tenant_id, instance_id, narrow_type, 1, ten_days_ago)

      seed_retention_policy!(%{event_type: narrow_type, policy: :keep_days, keep_days: 5})

      assert {:ok, %{moved_count: 1}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert table_count(Event, schema_name) == 0
      assert table_count(ArchivedEvent, schema_name) == 1
    end
  end

  # -----------------------------------------------------------------------------------
  # Acceptance criterion 7: "the three platform sentinel constants exist and are
  # accessible from the context module, each documented as citing
  # src/event_store/platform.zig"
  # -----------------------------------------------------------------------------------

  describe "platform sentinel constants (AC7)" do
    test "platform_instance_id/0, platform_actor_id/0, platform_tenant_id/0 are accessible, valid UUIDs, and pairwise distinct" do
      ids = [
        EventStore.platform_instance_id(),
        EventStore.platform_actor_id(),
        EventStore.platform_tenant_id()
      ]

      for id <- ids do
        assert {:ok, _} = Ecto.UUID.cast(id)
      end

      assert Enum.uniq(ids) == ids
    end

    test "each accessor's own @doc cites src/event_store/platform.zig" do
      for {name, arity} <- [
            {:platform_instance_id, 0},
            {:platform_actor_id, 0},
            {:platform_tenant_id, 0}
          ] do
        doc = function_doc(EventStore, name, arity)
        assert doc, "#{name}/#{arity} has no published @doc"

        assert doc =~ "src/event_store/platform.zig",
               "#{name}/#{arity}'s doc does not cite src/event_store/platform.zig: #{inspect(doc)}"
      end
    end
  end

  # -----------------------------------------------------------------------------------
  # Beyond the 7 numbered acceptance criteria: the design doc's own algorithm
  # details this run's briefing calls out explicitly.
  # -----------------------------------------------------------------------------------

  describe "read/2: up_to_sequence takes precedence over up_to_timestamp when both given (ES-06)" do
    test "an up_to_timestamp far in the past that would (if applied) exclude every event is silently ignored once up_to_sequence is also given" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      assert {:ok, %{sequence_number: seq1}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      assert {:ok, %{sequence_number: seq2}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      assert {:ok, %{sequence_number: _seq3}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      far_past = ~U[2000-01-01 00:00:00.000000Z]

      # If up_to_timestamp were ANDed in (or won instead), this would return [] --
      # far_past is before every event's real created_at.
      assert {:ok, events} =
               EventStore.read(instance_id,
                 prefix: schema_name,
                 up_to_sequence: seq2,
                 up_to_timestamp: far_past
               )

      assert Enum.map(events, & &1.sequence_number) == [seq1, seq2]
    end

    test "point_in_time/3 does not strip a caller-supplied up_to_sequence -- the ordinary precedence rule still applies" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      assert {:ok, %{sequence_number: seq1}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      assert {:ok, %{sequence_number: _seq2}} =
               EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                 prefix: schema_name
               )

      far_future = ~U[2100-01-01 00:00:00.000000Z]

      assert {:ok, events} =
               EventStore.point_in_time(instance_id, far_future,
                 prefix: schema_name,
                 up_to_sequence: seq1
               )

      assert Enum.map(events, & &1.sequence_number) == [seq1]
    end
  end

  describe "read_global/1 limit clamping (design §5.2)" do
    test "limit: 0 defaults to 100, NOT a literal LIMIT 0 (which would return zero rows)" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      for _ <- 1..3 do
        assert {:ok, _} =
                 EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                   prefix: schema_name
                 )
      end

      assert {:ok, %{events: events, has_more: false}} =
               EventStore.read_global(prefix: schema_name, limit: 0)

      assert length(events) == 3
    end

    test "a negative limit is clamped to the floor of 1, not passed through as a literal negative LIMIT" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      for _ <- 1..3 do
        assert {:ok, _} =
                 EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                   prefix: schema_name
                 )
      end

      assert {:ok, %{events: events, has_more: true}} =
               EventStore.read_global(prefix: schema_name, limit: -5)

      assert length(events) == 1
    end

    test "a limit far above 1000 does not error and returns only the events that exist" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, tenant_id, instance_id, :active)

      for _ <- 1..3 do
        assert {:ok, _} =
                 EventStore.append(append_attrs(event_type, %{instance_id: instance_id}),
                   prefix: schema_name
                 )
      end

      assert {:ok, %{events: events, has_more: false}} =
               EventStore.read_global(prefix: schema_name, limit: 5000)

      assert length(events) == 3
    end
  end

  describe "archive/1 never touches instance_projections or instance_sequence (INV-AR-2)" do
    test "an archive/1 call that moves a row leaves instance_projections and instance_sequence provably untouched" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      event_type = unique_type_name()

      projection_before = seed_projection!(schema_name, tenant_id, instance_id, :active)
      sequence_before = seed_instance_sequence!(schema_name, instance_id, 5)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      seed_event!(schema_name, tenant_id, instance_id, event_type, 1, old_created_at)

      assert {:ok, %{moved_count: 1}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert Repo.get(InstanceProjection, instance_id, prefix: schema_name) == projection_before
      assert Repo.get(InstanceSequence, instance_id, prefix: schema_name) == sequence_before
      assert table_count(InstanceProjection, schema_name) == 1
      assert table_count(InstanceSequence, schema_name) == 1
    end
  end

  describe "archive/1 deletes event_payload_store before events (ON DELETE RESTRICT ordering, design §7.3 phase 2)" do
    test "an event with an externalized ($ref) payload archives cleanly (no FK violation), archived payload is fully resolved" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      event_type = unique_type_name()
      seed_instance_sequence!(schema_name, instance_id)

      event_id = Ecto.UUID.generate()
      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      big_payload_map = %{"big" => String.duplicate("a", 5000)}

      seed_event!(schema_name, tenant_id, instance_id, event_type, 1, old_created_at,
        event_id: event_id,
        payload: %{"$ref" => event_id}
      )

      seed_stored_payload!(schema_name, event_id, old_created_at, big_payload_map)

      assert table_count(StoredPayload, schema_name) == 1
      assert table_count(Event, schema_name) == 1

      # If archive/1's phase 2 deleted `events` before `event_payload_store`, this
      # call would raise Ecto.ConstraintError (event_payload_store's FK is ON
      # DELETE RESTRICT) instead of succeeding.
      assert {:ok, %{moved_count: 1}} =
               EventStore.archive(prefix: schema_name, retention_days: 30)

      assert table_count(StoredPayload, schema_name) == 0
      assert table_count(Event, schema_name) == 0

      archived = Repo.get_by(ArchivedEvent, [event_id: event_id], prefix: schema_name)
      assert archived.payload == big_payload_map
      refute match?(%{"$ref" => _}, archived.payload)
    end
  end
end
