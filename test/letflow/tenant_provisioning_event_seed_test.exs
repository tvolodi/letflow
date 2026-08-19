defmodule Letflow.TenantProvisioningEventSeedTest do
  @moduledoc """
  WF-03 regression test for ISS-0072 (GH#257): `Letflow.EventStore.append/2`
  rejected `TASK_COMPLETED`, `INSTANCE_CANCELLED`, `INSTANCE_PINS_REBOUND`,
  `SUB_PROCESS_COMPLETED`, and `EXECUTION_ERROR` against any real,
  non-test-fixture tenant schema, because
  `Letflow.TenantProvisioning.maybe_seed_platform_event_types/2` only ever
  seeded `INSTANCE_STARTED`. See `test/specs/ISS-0072.md` for the full
  fail-then-pass methodology and the OQ-1 collision finding this file's
  moduledoc also documents.

  ## Why this file provisions tenants the *normal* way, not via a test fixture

  ISS-0072's bug was specifically that a tenant schema provisioned through
  the real, default-manifest `TenantProvisioning.replay_migrations/2` path
  (i.e. every real, non-test tenant) had no registry row for these 5 types --
  every *test* in the suite that exercised these write paths worked anyway,
  because each test file's own fixture called
  `Letflow.EventStore.Registry.register_type/2` directly for itself before
  exercising the code under test (ISS-0072's own description names
  `engine_cancel_instance_test.exs`, `engine_complete_task_test.exs`,
  `event_store_test.exs` as exactly this pattern). A test that also
  self-registers these types would defeat the entire point of this
  regression test -- it would pass identically against both the buggy and
  the fixed code, proving nothing. This file therefore calls
  `TenantProvisioning.provision_tenant_schema/1` +
  `TenantProvisioning.replay_migrations/2` (its **default**
  `migration_source`, i.e. the real `tenant_scoped_migrations/0` manifest --
  never a caller-supplied fixture list) and never calls
  `Registry.register_type/2` itself anywhere in this file. Matches
  `test/letflow/event_store_test.exs`'s own `provisioned_tenant/1` fixture
  pattern (real `CREATE SCHEMA`, real migration replay, Sandbox `:auto` mode
  + manual `on_exit/1` cleanup because `Ecto.Migrator` needs a second real DB
  connection the DataCase sandbox can't hand out) -- see that file's
  moduledoc for the full ExUnit-source-level proof behind the `async: false`
  + `:auto`-mode combination this file reuses verbatim.

  ## Verified fail-then-pass (not merely asserted -- see test/specs/ISS-0072.md)

  Confirmed directly from `lib/letflow/tenant_provisioning.ex` at the
  pre-fix commit (`09ac8ee`, `git show
  09ac8ee:lib/letflow/tenant_provisioning.ex`): the pre-fix
  `@instance_started_event_type_attrs` module attribute held exactly one
  entry, `"INSTANCE_STARTED"`, and `maybe_seed_platform_event_types/2`'s body
  called `Registry.register_type/2` exactly once, against that one entry.
  None of `"TASK_COMPLETED"`, `"INSTANCE_CANCELLED"`,
  `"INSTANCE_PINS_REBOUND"`, `"SUB_PROCESS_COMPLETED"`, or
  `"EXECUTION_ERROR"` appeared anywhere in that pre-fix file. Every payload
  this test file appends for those 5 types would therefore have hit
  `Registry.get_type/2`'s "no matching row" branch and
  `EventStore.append/2` would have returned `{:error, :unknown_event_type}}`
  for every one of them, against the pre-fix code, in a schema provisioned
  the way this file provisions it (no test-fixture self-registration) --
  exactly the failure this regression test is designed to catch. This was
  independently re-confirmed empirically per this file's own git history
  note in `test/specs/ISS-0072.md` (checked out the pre-fix commit and ran
  a probe equivalent to this file's own assertions).
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors event_store_test.exs's provisioned_tenant/1 /
  # append_attrs/2 / seed_projection!/4 pattern exactly (see moduledoc).
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("iss0072"),
        display_name: "ISS-0072 Regression Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # THE key fixture: provisions a tenant exactly the way a real, production
  # tenant is provisioned -- real CREATE SCHEMA, real default-manifest
  # replay_migrations/2 (no caller-supplied migration_source, so
  # maybe_seed_platform_event_types/2's `using_default_manifest?` guard is
  # true and the real seed path runs) -- and registers NOTHING itself. Any
  # event type this test can successfully append was seeded by production
  # code alone.
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

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_idempotency_key(prefix \\ "ISS0072") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
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

  defp append_attrs(event_type, payload_map) do
    %{
      instance_id: Ecto.UUID.generate(),
      event_type: event_type,
      payload: Jason.encode!(payload_map),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key()
    }
  end

  # Minimal valid payload per §4 of lib/letflow/design/iss072-event-type-registration.md
  # -- exactly the required-field shape each json_schema literal demands, nothing more.
  defp minimal_payload_for("INSTANCE_STARTED") do
    %{"definition_id" => Ecto.UUID.generate(), "initial_variables" => %{}}
  end

  defp minimal_payload_for("TASK_COMPLETED") do
    %{
      "task_id" => Ecto.UUID.generate(),
      "node_id" => "task",
      "output_variables" => %{},
      "activated_nodes" => []
    }
  end

  defp minimal_payload_for("INSTANCE_CANCELLED") do
    %{"cancelled_task_ids" => [], "cancelled_token_ids" => []}
  end

  defp minimal_payload_for("INSTANCE_PINS_REBOUND") do
    %{"entries" => [], "actor" => "iss0072-test-actor"}
  end

  defp minimal_payload_for("SUB_PROCESS_COMPLETED") do
    %{
      "child_instance_id" => Ecto.UUID.generate(),
      "output_variables" => %{},
      "activated_nodes" => []
    }
  end

  defp minimal_payload_for("EXECUTION_ERROR") do
    %{
      "error_type" => "iss0072_probe",
      "affected" => %{"kind" => "node"},
      "reason" => "iss0072 regression probe",
      "variables" => %{}
    }
  end

  # The 5 types ISS-0072 found unregistered against a real, non-fixture
  # tenant schema. INSTANCE_STARTED (the pre-existing, already-working seed)
  # is asserted separately below, since it isn't part of ISS-0072's bug --
  # asserting it here too would blur "already worked" with "ISS-0072 fixed
  # this".
  @newly_seeded_event_types [
    "TASK_COMPLETED",
    "INSTANCE_CANCELLED",
    "INSTANCE_PINS_REBOUND",
    "SUB_PROCESS_COMPLETED",
    "EXECUTION_ERROR"
  ]

  # ---------------------------------------------------------------------------------
  # Core regression: each of the 5 types ISS-0072 found unregistered now
  # appends successfully against a REAL, non-test-fixture tenant schema.
  # ---------------------------------------------------------------------------------

  describe "ISS-0072: the 5 newly-seeded event types now append against a real tenant schema" do
    for event_type <- @newly_seeded_event_types do
      test "#{event_type} -- EventStore.append/2 succeeds where it used to reject with :unknown_event_type" do
        event_type = unquote(event_type)

        %{schema_name: schema_name} = provisioned_tenant()

        attrs = append_attrs(event_type, minimal_payload_for(event_type))
        seed_projection!(schema_name, attrs.instance_id)

        assert {:ok, %{event: event, is_duplicate: false}} =
                 EventStore.append(attrs, prefix: schema_name)

        assert event.event_type == event_type
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Regression against the pre-existing seed: INSTANCE_STARTED must still work
  # (proves the fix's Enum.reduce_while/3 rewrite didn't regress the one entry
  # that already worked before ISS-0072).
  # ---------------------------------------------------------------------------------

  describe "INSTANCE_STARTED still works (pre-existing seed, not touched by ISS-0072's 5 additions)" do
    test "EventStore.append/2 succeeds for INSTANCE_STARTED against a freshly-provisioned tenant" do
      %{schema_name: schema_name} = provisioned_tenant()

      attrs = append_attrs("INSTANCE_STARTED", minimal_payload_for("INSTANCE_STARTED"))
      seed_projection!(schema_name, attrs.instance_id)

      assert {:ok, %{event: event, is_duplicate: false}} =
               EventStore.append(attrs, prefix: schema_name)

      assert event.event_type == "INSTANCE_STARTED"
    end
  end

  # ---------------------------------------------------------------------------------
  # Negative control: a genuinely still-unregistered type is still rejected --
  # proves the fix seeds exactly the 6 named types, not indiscriminately
  # everything. DEFINITION_PROMOTED is one of the 3 types the design doc §1
  # "Out of scope" explicitly names as deliberately NOT seeded (no production
  # writer exists for it).
  # ---------------------------------------------------------------------------------

  describe "still-unregistered types remain rejected (proves the seed list isn't indiscriminate)" do
    test "EventStore.append/2 still returns {:error, :unknown_event_type} for DEFINITION_PROMOTED" do
      %{schema_name: schema_name} = provisioned_tenant()

      # No instance_projections row is seeded here -- Registry.validate_payload/3
      # runs (and fails) before append/2 ever touches instance_projections, so
      # this assertion is unaffected by projection state (confirmed directly
      # from lib/letflow/event_store.ex's `with` chain: fetch_event_type/1 and
      # Registry.validate_payload/3 both precede the transactional phase).
      attrs = append_attrs("DEFINITION_PROMOTED", %{"anything" => "goes"})

      assert {:error, :unknown_event_type} = EventStore.append(attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # OQ-1 (design doc §9): confirms register_type/2's own idempotency backstop
  # ({:error, :duplicate_event_type_version} folding to :ok) still holds for a
  # SECOND replay_migrations/2 call against an already-seeded tenant -- the
  # production-code half of OQ-1. The test-fixture-collision half of OQ-1 (an
  # existing test file's OWN register_type/2 call colliding with this seed) is
  # NOT reproduced here -- see test/specs/ISS-0072.md's "OQ-1 finding" section
  # for that investigation; it is a defect in unrelated pre-existing test
  # fixture files, not in the production seeding logic this test file covers,
  # and has been filed as its own issue rather than fixed in this file.
  # ---------------------------------------------------------------------------------

  describe "OQ-1: replay_migrations/2 re-run against an already-seeded tenant stays idempotent" do
    test "a second replay_migrations/2 call for the same tenant still returns :ok overall, and the 6 rows are not duplicated" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)

      %{rows: [[count]]} =
        Repo.query!(
          "SELECT COUNT(*) FROM \"#{schema_name}\".\"event_type_registry\"",
          []
        )

      assert count == 6

      # And the seeded types are still all usable after the re-seed no-op.
      attrs = append_attrs("TASK_COMPLETED", minimal_payload_for("TASK_COMPLETED"))
      seed_projection!(schema_name, attrs.instance_id)

      assert {:ok, %{event: event}} = EventStore.append(attrs, prefix: schema_name)
      assert event.event_type == "TASK_COMPLETED"
    end
  end
end
