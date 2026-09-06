defmodule Letflow.Entities.RecordsTest do
  @moduledoc """
  Integration tests for `Letflow.Entities.EventTypes`, `Letflow.Entities.Records`,
  `Letflow.Entities.Record.Latest`, and `Letflow.Entities.EntityTypeInstance`
  (REQ-228) -- event-type registration, create/update/delete commands,
  idempotent-replay parity, and the per-entity-TYPE synthetic-instance
  mapping. See
  `lib/letflow/design/req228-entity-event-registration-commands.md` for the
  design this file verifies, and REQ-228's own `docs/requirements.yaml`
  entry for the authoritative 8 acceptance criteria this file's `describe`
  blocks are grouped by.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), mirroring
  `test/letflow/entities/definitions_test.exs`'s own hand-rolled
  tenant-fixture pattern (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- same shape as test/letflow/entities/definitions_test.exs's
  # provisioned_tenant/0.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req228-entities"),
        display_name: "REQ-228 Entity Records Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
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
    assert {:ok, _seed_result} = EventTypes.seed!(schema_name)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp valid_definition(overrides \\ %{}) do
    Map.merge(
      %{
        name: "customer",
        display_name: "Customer",
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "age", type: :integer}
        ]
      },
      overrides
    )
  end

  defp create_active_definition!(schema, overrides \\ %{}) do
    definition = valid_definition(overrides)

    assert {:ok, entity_definition} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  defp create_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: "customer",
        field_values: %{"customer_name" => "Acme", "age" => 42},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- ENTITY_RECORD_CREATED/UPDATED/DELETED each registered exactly once.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- EventTypes.seed!/1 registers the three event types exactly once" do
    test "each of the three event types is registered exactly once, verified against event_type_registry" do
      %{schema_name: schema} = provisioned_tenant()

      for name <- ~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED) do
        rows = Repo.all(from(e in EventType, where: e.name == ^name), prefix: schema)
        assert length(rows) == 1
        assert hd(rows).schema_version == 1
      end
    end

    test "calling seed!/1 a second time is idempotent -- no duplicate rows, no error" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %{registered: [], skipped: skipped}} = EventTypes.seed!(schema)

      assert Enum.sort(skipped) ==
               Enum.sort(~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED))

      entity_event_type_count =
        EventType
        |> where(
          [e],
          e.name in ~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED)
        )
        |> Repo.aggregate(:count, prefix: schema)

      assert entity_event_type_count == 3
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- create_record/2 appends exactly one event + updates
  # entity_record_latest in the same transaction; a forced mid-transaction
  # failure leaves neither committed.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- create_record/2 atomicity" do
    test "appends exactly one ENTITY_RECORD_CREATED event and inserts one entity_record_latest row" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: record, is_duplicate: false}} =
               Records.create_record(create_attrs(), schema)

      assert record.entity_type == "customer"
      assert record.field_values == %{"customer_name" => "Acme", "age" => 42}
      refute record.deleted

      assert Repo.aggregate(Event, :count, prefix: schema) == 1
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1

      [event] = Repo.all(Event, prefix: schema)
      assert event.event_type == "ENTITY_RECORD_CREATED"
      assert event.payload["record_id"] == record.record_id
    end

    test "a forced failure after the event append but before the projection update leaves NEITHER committed" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      # Reach directly into the same composable pipeline create_record/2 uses,
      # but inject a failing final step in place of :upsert_record_latest --
      # proves the whole thing is one transaction, not two independent writes.
      entity_type = "customer"
      {:ok, instance_id} = EntityTypeInstance.get_or_create(entity_type, schema)

      event_attrs = %{
        instance_id: instance_id,
        event_type: "ENTITY_RECORD_CREATED",
        payload:
          Jason.encode!(%{
            "entity_type" => entity_type,
            "entity_def_version" => "aa",
            "record_id" => Ecto.UUID.generate(),
            "field_values" => %{"customer_name" => "Acme", "age" => 42}
          }),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, multi} = EventStore.append_multi(Ecto.Multi.new(), event_attrs, prefix: schema)

      result =
        multi
        |> Ecto.Multi.run(:upsert_record_latest, fn _repo, _changes ->
          {:error, :forced_failure_for_test}
        end)
        |> Repo.transaction()

      assert {:error, :upsert_record_latest, :forced_failure_for_test, _changes} = result

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
      assert Repo.aggregate(Latest, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- duplicate idempotency-key submission returns the ORIGINAL record
  # both times (ISS-0159/GH#480 parity).
  # ---------------------------------------------------------------------------------

  describe "AC3 -- idempotent replay returns the ORIGINAL record" do
    test "submitting create_record/2 twice with the same idempotency_key returns the same record_id/field_values both times" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      attrs = create_attrs()

      assert {:ok, %{record: first_record, is_duplicate: false}} =
               Records.create_record(attrs, schema)

      assert {:ok, %{record: second_record, is_duplicate: true}} =
               Records.create_record(attrs, schema)

      assert first_record.record_id == second_record.record_id
      assert first_record.field_values == second_record.field_values
      assert first_record.entity_type == second_record.entity_type

      # Only one event and one entity_record_latest row exist -- no second
      # record was minted on replay.
      assert Repo.aggregate(Event, :count, prefix: schema) == 1
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "a THIRD submission with the same idempotency_key still returns the same original record" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      attrs = create_attrs()

      assert {:ok, %{record: r1}} = Records.create_record(attrs, schema)
      assert {:ok, %{record: r2}} = Records.create_record(attrs, schema)
      assert {:ok, %{record: r3}} = Records.create_record(attrs, schema)

      assert r1.record_id == r2.record_id
      assert r2.record_id == r3.record_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a create command whose field_values fail REQ-227's validation is
  # rejected with zero events appended.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- REQ-227 inner field_values validation rejects zero-event on failure" do
    test "a payload missing a required field is rejected with zero events appended" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:error, {:record_payload_invalid, violations}} =
               Records.create_record(create_attrs(%{field_values: %{"age" => 42}}), schema)

      assert [%Registry.ValidationFailure{field_path: "/customer_name", constraint: "required"}] =
               violations

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
      assert Repo.aggregate(Latest, :count, prefix: schema) == 0
    end

    test "a payload with a wrong-typed field is rejected with zero events appended" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:error, {:record_payload_invalid, violations}} =
               Records.create_record(
                 create_attrs(%{
                   field_values: %{"customer_name" => "Acme", "age" => "not-a-number"}
                 }),
                 schema
               )

      assert [%Registry.ValidationFailure{field_path: "/age", constraint: "type"}] = violations

      assert Repo.aggregate(Event, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- entity_type_instances creates exactly one row per TYPE, not per
  # record.
  # ---------------------------------------------------------------------------------

  describe "AC5/AC6 -- synthetic-instance-per-entity-TYPE mapping" do
    test "creating three records of the same entity type produces exactly one synthetic instance row for that type" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      for n <- 1..3 do
        assert {:ok, _} =
                 Records.create_record(
                   create_attrs(%{field_values: %{"customer_name" => "Acme #{n}", "age" => n}}),
                   schema
                 )
      end

      assert Repo.aggregate(Latest, :count, prefix: schema) == 3
      assert Repo.aggregate(EntityTypeInstance, :count, prefix: schema) == 1
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema) == 1

      [entity_type_instance] = Repo.all(EntityTypeInstance, prefix: schema)
      assert entity_type_instance.entity_type == "customer"

      # AC6 -- design artefact's own §2 resolves per-TYPE, not per-record; this
      # is the executable proof that the shipped code matches that resolution.
      events = Repo.all(Event, prefix: schema)
      assert length(events) == 3
      assert Enum.uniq(Enum.map(events, & &1.instance_id)) == [entity_type_instance.instance_id]
    end

    test "two different entity types get two independent synthetic instance rows" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema, %{name: "customer"})

      create_active_definition!(schema, %{
        name: "invoice",
        fields: [%{name: "amount", type: :integer}]
      })

      assert {:ok, _} = Records.create_record(create_attrs(%{entity_type: "customer"}), schema)

      assert {:ok, _} =
               Records.create_record(
                 create_attrs(%{
                   entity_type: "invoice",
                   field_values: %{"amount" => 100}
                 }),
                 schema
               )

      assert Repo.aggregate(EntityTypeInstance, :count, prefix: schema) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- outer envelope schema and REQ-227's inner validation are each
  # independently exercised.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- outer envelope vs. inner field_values validation, independently exercised" do
    test "the OUTER envelope schema rejects a malformed payload at Registry.validate_payload/3 (bypassing the command function)" do
      %{schema_name: schema} = provisioned_tenant()
      {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema)

      # Missing "record_id" -- violates ENTITY_RECORD_CREATED's own outer
      # envelope schema, entirely independent of REQ-227's field_values check.
      malformed_envelope =
        Jason.encode!(%{
          "entity_type" => "customer",
          "entity_def_version" => "aa",
          "field_values" => %{"customer_name" => "Acme", "age" => 42}
        })

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload("ENTITY_RECORD_CREATED", malformed_envelope, tenant_id)

      assert Enum.any?(failures, &(&1.constraint == "required"))
    end

    test "the INNER field_values check (REQ-227) rejects an enum violation independent of the outer envelope" do
      %{schema_name: schema} = provisioned_tenant()

      create_active_definition!(schema, %{
        name: "ticket",
        fields: [%{name: "status", type: :enum, enum_values: ["open", "closed"], required: true}]
      })

      assert {:error, {:record_payload_invalid, violations}} =
               Records.create_record(
                 create_attrs(%{
                   entity_type: "ticket",
                   field_values: %{"status" => "not-a-real-status"}
                 }),
                 schema
               )

      assert [%Registry.ValidationFailure{constraint: "enum"}] = violations
    end
  end

  # ---------------------------------------------------------------------------------
  # update_record/2 / delete_record/2 -- design §5.2's own scope, exercised
  # alongside the 8 acceptance criteria above.
  # ---------------------------------------------------------------------------------

  describe "update_record/2 and delete_record/2" do
    test "update_record/2 replaces field_values in full and appends ENTITY_RECORD_UPDATED" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: updated, is_duplicate: false}} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   field_values: %{"customer_name" => "Acme Renamed", "age" => 43},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert updated.record_id == created.record_id
      assert updated.field_values == %{"customer_name" => "Acme Renamed", "age" => 43}

      assert Repo.aggregate(Event, :count, prefix: schema) == 2
      assert Repo.aggregate(Latest, :count, prefix: schema) == 1
    end

    test "update_record/2 on a non-existent record returns {:error, {:record_not_found, _}}" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:error, {:record_not_found, _}} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: Ecto.UUID.generate(),
                   field_values: %{"customer_name" => "Acme", "age" => 1},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )
    end

    test "delete_record/2 marks deleted: true and retains the last field_values" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, %{record: deleted, is_duplicate: false}} =
               Records.delete_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert deleted.deleted
      assert deleted.field_values == created.field_values

      [event] =
        Repo.all(from(e in Event, where: e.event_type == "ENTITY_RECORD_DELETED"), prefix: schema)

      refute Map.has_key?(event.payload, "field_values")
    end

    test "delete_record/2 on an already-deleted record is a no-op success (is_duplicate: false)" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      delete_attrs = %{
        entity_type: "customer",
        record_id: created.record_id,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, %{record: first_delete}} = Records.delete_record(delete_attrs, schema)

      assert {:ok, %{record: second_delete, is_duplicate: false}} =
               Records.delete_record(
                 %{delete_attrs | idempotency_key: Ecto.UUID.generate()},
                 schema
               )

      assert first_delete.record_id == second_delete.record_id
      assert Repo.aggregate(Event, :count, prefix: schema) == 2
    end

    test "update_record/2 on an already-deleted record returns {:error, {:record_already_deleted, _}}" do
      %{schema_name: schema} = provisioned_tenant()
      create_active_definition!(schema)

      assert {:ok, %{record: created}} = Records.create_record(create_attrs(), schema)

      assert {:ok, _} =
               Records.delete_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:error, {:record_already_deleted, record_id}} =
               Records.update_record(
                 %{
                   entity_type: "customer",
                   record_id: created.record_id,
                   field_values: %{"customer_name" => "Acme", "age" => 1},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      assert record_id == created.record_id
    end
  end

  # ---------------------------------------------------------------------------------
  # create_record/2 -- {:error, {:definition_not_found, _}} for an
  # unknown/inactive entity_type.
  # ---------------------------------------------------------------------------------

  describe "create_record/2 -- definition resolution" do
    test "an unknown entity_type is rejected with {:error, {:definition_not_found, _}}" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:error, {:definition_not_found, "does-not-exist"}} =
               Records.create_record(create_attrs(%{entity_type: "does-not-exist"}), schema)
    end

    test "an inactive (never-activated) definition is rejected with {:error, {:definition_not_found, _}}" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, _} =
               Definitions.create_definition(
                 %{definition: valid_definition(), created_by: Ecto.UUID.generate()},
                 schema
               )

      assert {:error, {:definition_not_found, "customer"}} =
               Records.create_record(create_attrs(), schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # Scope: no route or controller file added for this requirement.
  # ---------------------------------------------------------------------------------

  describe "scope -- no route/controller surface exists for entity records" do
    test "lib/letflow/router.ex does not forward to an entity-records router" do
      router_source = File.read!(Path.expand("../../../lib/letflow/router.ex", __DIR__))

      refute router_source =~ ~r/entity_record/i
    end

    test "no lib/letflow/routers/entity_records.ex file exists" do
      refute File.exists?(Path.expand("../../../lib/letflow/routers/entity_records.ex", __DIR__))
    end
  end
end
