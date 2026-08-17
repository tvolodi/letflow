defmodule Letflow.EventStoreTest do
  @moduledoc """
  Tests for `Letflow.EventStore.append/2` (REQ-025). See `test/specs/REQ-025.md`
  for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

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
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.EventStore.Registry
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
  defp seed_projection!(schema_name, tenant_id, instance_id, status) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      tenant_id: tenant_id,
      status: status,
      last_event_seq: 0
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp table_count(schema, schema_name) do
    Repo.aggregate(schema, :count, prefix: schema_name)
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
end
