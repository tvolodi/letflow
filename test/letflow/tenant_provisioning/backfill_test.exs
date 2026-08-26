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
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.Backfill

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

    assert {:ok, %{updated: 1, skipped: 0}} = Backfill.run(v2_attrs())

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

    assert {:ok, %{updated: 0, skipped: 1}} = Backfill.run(v2_attrs())

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
    assert {:ok, %{updated: 0, skipped: 1}} = Backfill.run(v2_attrs())

    # v3 is untouched.
    assert {:ok, %EventType{schema_version: 3}} =
             Registry.get_type("DEFINITION_PROMOTED", tenant_id)
  end
end
