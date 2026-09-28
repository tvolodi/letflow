defmodule Letflow.EventStore.RegistryTenantSchemaMissingTest do
  @moduledoc """
  Regression tests for ISS-0343: `Letflow.EventStore.Registry.register_type/2`
  and `get_type/2` must return `{:error, :tenant_schema_missing}` instead of
  letting a raw `Postgrex.Error` (`undefined_table`, SQLSTATE `42P01`) escape
  as an uncaught exception when a tenant's `Registration` row still exists but
  its physical Postgres schema has already been dropped.

  See `lib/letflow/design/iss0343-backfill-missing-schema-tolerance.md` for
  the full root-cause analysis: `TenantFixture.provisioned_tenant!/1` flips
  `Ecto.Adapters.SQL.Sandbox` to `:auto` mode for the whole partition and
  never restores `:manual` (documented, intentional), so under
  `scripts/test_parallel.sh` a concurrently-running test's `on_exit` teardown
  can `DROP SCHEMA ... CASCADE` a *different* tenant's schema while
  `Letflow.TenantProvisioning.Backfill.run/1` is mid-sweep against it. This
  file does not attempt to reproduce that timing race (low-frequency,
  intermittent, already diagnosed in `handoffs/WF03-ISS0343-20260826/step-01-issue-fixer.json`).
  Instead it reproduces the exact end-state the race produces —
  "`Registration` row present, physical schema absent" — deterministically,
  by provisioning a real tenant and then dropping its schema directly via
  `drop_schema!/1` (same helper `test/letflow/event_store/registry_test.exs`
  already uses) WITHOUT deleting the `Registration` row, which is precisely
  the window `rescue_missing_schema/1` exists to tolerate. This is a stronger
  test than reproducing the race: it exercises the exact query-vs-missing-schema
  condition on every run, not only when a timing window happens to line up.

  test/letflow/tenant_provisioning/backfill_test.exs covers the same
  condition one layer up, through `Backfill.run/1`'s `Enum.reduce_while/3`
  clause.

  `async: false` for the same reason `registry_test.exs` and
  `backfill_test.exs` are: `provisioned_tenant/1` below switches
  `Letflow.Repo` to Sandbox `:auto` mode (a real, non-sandboxed schema must
  exist for `DROP SCHEMA` to have anything real to drop).
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # `drop_schema!/1` stays -- called directly to deliberately drop a tenant's schema
  # mid-test while leaving its Registration row in place (the exact race this file
  # reproduces).
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp unique_name(prefix \\ "ISS_0343_EVENT_TYPE") do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => unique_name(),
        "schema_version" => 1,
        "json_schema" => %{"type" => "object"},
        "description" => "ISS-0343 test fixture"
      },
      overrides
    )
  end

  # Provisions a real tenant + schema, then DROPS the schema WITHOUT deleting the
  # Registration row -- the exact "Registration exists, physical schema does not"
  # window ISS-0343 tolerates. Registration/Tenant row cleanup still happens via
  # TenantFixture's own on_exit teardown (its "DROP SCHEMA IF EXISTS" is a no-op by
  # the time it runs, since the schema is already gone).
  defp tenant_with_vanished_schema(prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        display_name: "ISS-0343 Test Tenant"
      )

    # The race this reproduces: the schema is dropped, but the Registration row
    # (checked first, by resolve_schema_name/1) is deliberately left in place.
    drop_schema!(schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  # ---------------------------------------------------------------------------------
  # get_type/2
  # ---------------------------------------------------------------------------------

  describe "get_type/2 tolerates a Registration row whose physical schema has vanished" do
    test "returns {:error, :tenant_schema_missing}, not an uncaught Postgrex.Error" do
      %{tenant_id: tenant_id} = tenant_with_vanished_schema("iss0343-get-type")

      assert {:error, :tenant_schema_missing} =
               Registry.get_type("ANY_EVENT_TYPE", tenant_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # register_type/2 -- both DB call sites inside insert_with_monotonicity_check/2
  # (the current_max lookup via fetch_current_max/2, and the Repo.insert/2 itself)
  # are exercised here since a fresh (never-before-registered) name necessarily
  # runs the monotonicity query first.
  # ---------------------------------------------------------------------------------

  describe "register_type/2 tolerates a Registration row whose physical schema has vanished" do
    test "returns {:error, :tenant_schema_missing}, not an uncaught Postgrex.Error" do
      %{tenant_id: tenant_id} = tenant_with_vanished_schema("iss0343-register-type")

      assert {:error, :tenant_schema_missing} =
               Registry.register_type(valid_attrs(), tenant_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Control: an ordinary, still-provisioned tenant is entirely unaffected -- the fix
  # narrows to the exact undefined_table shape and must not change behavior for the
  # common case.
  # ---------------------------------------------------------------------------------

  describe "control: a tenant whose schema was NOT dropped is unaffected by the fix" do
    test "get_type/2 and register_type/2 behave exactly as before for a healthy tenant" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0343-control",
          display_name: "ISS-0343 Test Tenant"
        )

      assert {:error, :unknown_event_type} = Registry.get_type("NEVER_REGISTERED", tenant_id)

      assert {:ok, %EventType{}} = Registry.register_type(valid_attrs(), tenant_id)
    end
  end
end
