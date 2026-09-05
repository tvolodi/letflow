defmodule Letflow.TenantProvisioning.BackfillTest do
  @moduledoc """
  Regression tests for ISS-0332: `Letflow.TenantProvisioning.Backfill.run/1`
  backfills DEFINITION_PROMOTED to schema_version 2 for tenants provisioned before
  REQ-077 bumped the type from v1 (review_id type "string", non-null) to v2
  (review_id type ["string","null"]).

  WF-03 Step 4 fail-first requirement: since `Letflow.TenantProvisioning.Backfill`
  is a new module, running these tests against pre-fix code produces
  `UndefinedFunctionError`. In lieu of a pre-fix run, two mutants are applied to
  the shipped `Backfill.run/1` in sequence (see mutation results in
  handoffs/WF03-ISS0332-20260826/step-04-test-designer.json).

  `async: false` — required because `TenantFixture.provisioned_tenant!/1` switches
  `Letflow.Repo` to Sandbox `:auto` mode for real schema creation. See
  `test/letflow/event_store/registry_test.exs` moduledoc for the full empirical
  reasoning this file reuses rather than re-deriving.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Backfill
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # V1 attrs: review_id type "string" (non-null), as registered by pre-REQ-077
  # provisioning. Matches the schema that causes R10 to fail with a null review_id.
  defp v1_attrs do
    %{
      "name" => "DEFINITION_PROMOTED",
      "schema_version" => 1,
      "description" => "ISS-0332 v1 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "review_id" => %{"type" => "string"},
          "source_tenant_id" => %{"type" => "string"},
          "target_tenant_id" => %{"type" => "string"},
          "source_definition_id" => %{"type" => "string"},
          "target_definition_id" => %{"type" => "string"},
          "process_key" => %{"type" => "string"}
        },
        "required" => [
          "review_id",
          "source_tenant_id",
          "target_tenant_id",
          "source_definition_id",
          "target_definition_id",
          "process_key"
        ]
      }
    }
  end

  # V2 attrs: review_id type ["string","null"] — exact copy of the entry in
  # @platform_event_type_seed_attrs (lib/letflow/tenant_provisioning.ex ~L770).
  # This is the argument Backfill.run/1 receives in production.
  defp v2_attrs do
    %{
      "name" => "DEFINITION_PROMOTED",
      "schema_version" => 2,
      "description" => "ISS-0332 v2 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "review_id" => %{"type" => ["string", "null"]},
          "source_tenant_id" => %{"type" => "string"},
          "target_tenant_id" => %{"type" => "string"},
          "source_definition_id" => %{"type" => "string"},
          "target_definition_id" => %{"type" => "string"},
          "process_key" => %{"type" => "string"}
        },
        "required" => [
          "review_id",
          "source_tenant_id",
          "target_tenant_id",
          "source_definition_id",
          "target_definition_id",
          "process_key"
        ]
      }
    }
  end

  # A valid DEFINITION_PROMOTED payload with null review_id. Against v1 schema, this
  # fails (review_id must be a string). Against v2, it passes. This is the exact payload
  # shape that caused ISS-0332's Severity-1 event-append failure.
  defp null_review_id_payload do
    Jason.encode!(%{
      "review_id" => nil,
      "source_tenant_id" => Ecto.UUID.generate(),
      "target_tenant_id" => Ecto.UUID.generate(),
      "source_definition_id" => Ecto.UUID.generate(),
      "target_definition_id" => Ecto.UUID.generate(),
      "process_key" => "test-process-key"
    })
  end

  # Removes all DEFINITION_PROMOTED entries from the tenant's event_type_registry and
  # inserts a fresh v1 row, simulating a pre-REQ-077 provisioned tenant.
  # provisioned_tenant! seeds v2 during replay_migrations, so this downgrade is
  # necessary to reproduce the ISS-0332 pre-condition.
  defp downgrade_to_v1!(schema_name) do
    from(e in EventType, where: e.name == "DEFINITION_PROMOTED")
    |> Repo.delete_all(prefix: schema_name)

    EventType.changeset(%EventType{}, v1_attrs())
    |> Repo.insert!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------
  # AC1: backfill updates pre-existing tenants' DEFINITION_PROMOTED to schema_version 2
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- backfill updates pre-existing tenant to schema_version 2" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-ac1")

    # Downgrade DEFINITION_PROMOTED to v1 to simulate a pre-REQ-077 tenant.
    downgrade_to_v1!(schema_name)

    assert {:ok, %EventType{schema_version: 1}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)

    assert {:ok, %{updated: updated, skipped: _skipped}} = Backfill.run(v2_attrs())
    assert updated >= 1

    # Post-backfill: highest registered version for this tenant is now 2.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end

  # ---------------------------------------------------------------------------
  # AC2: R10 against a pre-existing tenant succeeds end-to-end
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- R10 event-append succeeds after backfill (validate_payload accepts null review_id)" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-ac2")

    downgrade_to_v1!(schema_name)

    payload = null_review_id_payload()

    # BEFORE backfill: v1 schema rejects null review_id — this is ISS-0332's bug.
    assert {:error, {:payload_validation_failed, _}} =
             Registry.validate_payload("DEFINITION_PROMOTED", payload, tenant_id)

    assert {:ok, _} = Backfill.run(v2_attrs())

    # AFTER backfill: v2 schema accepts null review_id — the fix is effective.
    assert :ok = Registry.validate_payload("DEFINITION_PROMOTED", payload, tenant_id)
  end

  # ---------------------------------------------------------------------------
  # AC3: idempotent on already-v2 tenants (skipped, not errored)
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- idempotent: already-v2 tenant is skipped, not errored" do
    %{tenant_id: tenant_id} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-ac3")

    # provisioned_tenant! seeds DEFINITION_PROMOTED at v2 via replay_migrations.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)

    assert {:ok, %{updated: _updated, skipped: skipped}} = Backfill.run(v2_attrs())
    assert skipped >= 1

    # Schema version unchanged after backfill.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end

  # ---------------------------------------------------------------------------
  # Additional: higher existing schema_version is also skipped (schema_version_not_monotonic)
  # ---------------------------------------------------------------------------

  test "regression: ISS-0332 -- higher existing schema_version is skipped (schema_version_not_monotonic)" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0332-monotonic")

    # Replace v2 (seeded at provisioning) with v3 to simulate a hypothetical
    # future-versioned tenant. register_type/2 enforces monotonicity, so we bypass
    # it via direct Repo.insert! here — consistent with downgrade_to_v1!/1's
    # approach for the opposite direction.
    from(e in EventType, where: e.name == "DEFINITION_PROMOTED")
    |> Repo.delete_all(prefix: schema_name)

    EventType.changeset(%EventType{}, %{
      "name" => "DEFINITION_PROMOTED",
      "schema_version" => 3,
      "description" => "ISS-0332 v3 fixture (hypothetical future version)",
      "json_schema" => %{"type" => "object"}
    })
    |> Repo.insert!(prefix: schema_name)

    assert {:ok, %EventType{schema_version: 3}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)

    # Backfill with v2 attrs must skip the v3 tenant without error.
    assert {:ok, %{updated: _updated, skipped: skipped}} = Backfill.run(v2_attrs())
    assert skipped >= 1

    # v3 is untouched.
    assert {:ok, %EventType{schema_version: 3}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end

  # ---------------------------------------------------------------------------
  # ISS-0343 regression: a tenant whose Registration row survives its own
  # schema being dropped mid-sweep is skipped, not a crash of the whole run.
  # ---------------------------------------------------------------------------

  # Provisions a real tenant, then drops its physical schema WITHOUT deleting the
  # Registration row -- the exact "Registration exists, schema does not" window
  # ISS-0343's concurrent teardown/offboarding race produces. Mirrors
  # test/letflow/event_store/registry_tenant_schema_missing_test.exs's own
  # tenant_with_vanished_schema/1 helper (this file needs its own copy since it lives
  # in a different test module).
  defp tenant_with_vanished_schema!(prefix) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(prefix),
          display_name: "ISS-0343 Backfill Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

    tenant.id
  end

  test "regression: ISS-0343 -- a tenant whose schema vanished mid-sweep is skipped, not a crash of the whole run" do
    # A normal, healthy tenant that the sweep must still update.
    %{tenant_id: healthy_tenant_id, schema_name: healthy_schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0343-backfill-healthy")

    downgrade_to_v1!(healthy_schema_name)

    # A tenant whose Registration row exists but whose physical schema has already
    # been dropped -- the exact race Backfill.run/1's Registration -> Registry.register_type/2
    # window can hit (design doc section 1). Pre-fix, Registry.register_type/2 let the
    # resulting Postgrex.Error (undefined_table) propagate uncaught, which unwound
    # straight out of Enum.reduce_while/3 and crashed the ENTIRE run -- including the
    # still-healthy tenant above, which would never get updated.
    vanished_tenant_id = tenant_with_vanished_schema!("iss0343-backfill-vanished")

    assert {:ok, %{updated: updated, skipped: skipped}} = Backfill.run(v2_attrs())
    assert updated >= 1
    assert skipped >= 1

    # The healthy tenant was updated despite the other tenant's schema having vanished --
    # proof the vanished tenant did not halt/crash the sweep for everyone else.
    assert {:ok, %EventType{schema_version: 2}} =
             Registry.get_type("DEFINITION_PROMOTED", healthy_tenant_id)

    # Direct, tenant_id-scoped confirmation that the vanished tenant was specifically
    # routed to :skipped (not merely unvisited): calling the same function Backfill.run/1
    # calls internally for this tenant reproduces the same error, since the physical
    # schema is still gone.
    assert {:error, :tenant_schema_missing} =
             Registry.register_type(v2_attrs(), vanished_tenant_id)

    # The vanished tenant's Registration row is still queryable (it was never deleted --
    # only its physical schema is gone), confirming this test exercised the intended
    # "Registration present, schema absent" window rather than :tenant_not_provisioned.
    assert %Registration{} = Repo.get_by(Registration, tenant_id: vanished_tenant_id)
  end

  # ---------------------------------------------------------------------------
  # ISS-0480 design §11.10.4 item 2: post-teardown state verification.
  #
  # Every other test above provisions via `provisioned_tenant!/1` on its default
  # `template: :clone` + this file's `async: false` -- exactly the
  # `provision_via_shared_connection/1` dispatch path §11.10 fixes teardown for. A
  # green run of those tests only proves ExUnit did not observe a raised `exit`; it
  # does not by itself prove `teardown/2`'s on_exit/1 callback actually ran its DROP
  # SCHEMA/delete_all statements to completion (a swallowed exit could, in principle,
  # produce the same green result while leaking state). These two tests close that gap
  # empirically: the first provisions and records the tenant_id/schema_name in
  # `:persistent_term` (surviving past its own test process's exit, unlike a module
  # attribute or `on_exit`'s own closure); the second, which ExUnit runs strictly
  # afterward in this `async: false` module's own sync queue, asserts the schema and
  # tracking rows are actually gone.
  #
  # Safe to assert without a race: ExUnit's own documented ordering runs a given test's
  # on_exit/1 callbacks to completion before the NEXT test in the same `async: false`
  # module starts -- so by the time the second test's body runs, the first test's
  # `TenantFixture`-registered on_exit/1 teardown has already either completed or raised
  # (in which case ExUnit would already report the FIRST test as failed, independent of
  # this second test's own assertions).
  @iss0480_teardown_verify_key {__MODULE__, :iss0480_teardown_verify}

  test "regression: ISS-0480 §11.10 -- provisions a tenant whose teardown state the next test verifies" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0480-teardown-verify")

    # Sanity check before teardown: the schema and tracking rows really do exist while
    # this test is still running.
    assert %{rows: [_ | _]} =
             Repo.query!(
               "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
               [schema_name]
             )

    assert %Registration{} = Repo.get_by(Registration, tenant_id: tenant_id)
    assert %Tenant{} = Repo.get(Tenant, tenant_id)

    :persistent_term.put(@iss0480_teardown_verify_key, %{
      tenant_id: tenant_id,
      schema_name: schema_name
    })
  end

  test "regression: ISS-0480 §11.10 -- the previous test's on_exit/1 teardown actually dropped the schema and rows, not merely 'no exit observed'" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      :persistent_term.get(@iss0480_teardown_verify_key)

    assert %{rows: []} =
             Repo.query!(
               "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
               [schema_name]
             )

    refute Repo.get_by(Registration, tenant_id: tenant_id)
    refute Repo.get(Tenant, tenant_id)
  after
    :persistent_term.erase(@iss0480_teardown_verify_key)
  end
end
