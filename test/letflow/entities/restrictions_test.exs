defmodule Letflow.Entities.RestrictionsTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Restrictions.import_restrictions/2`
  (ISS-0935) -- see
  `lib/letflow/design/iss0935-vortex-entity-seed.md` §1.3 for the full
  design this module implements. Written by ELIXIR-DEV at WF-02 Step 2a to
  exercise the new write path directly against a real Postgres tenant
  schema, per `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no
  mocked database. Router-level coverage (the HTTP route, permission
  gating, 403/422 response shapes) lives in
  `test/letflow/routers/entities_test.exs`'s own ISS-0935 describe block.

  `async: false`: `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode, same reason every other
  tenant-provisioning test in this codebase is `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Restrictions
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp tenant!(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0935 Restrictions Test Tenant"
    )
  end

  defp insert_user!(schema_name, suffix) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "iss0935-user-#{suffix}-#{Ecto.UUID.generate()}",
      display_name: "ISS-0935 Restrictions Test User",
      email: "iss0935-#{suffix}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  describe "empty/absent arrays -- insert nothing, never an error" do
    test "an empty map inserts zero rows into every table" do
      tenant = tenant!("iss0935-empty")

      assert Restrictions.import_restrictions(%{}, tenant.schema_name) ==
               {:ok,
                %{
                  field_restrictions: 0,
                  field_grants: 0,
                  type_restrictions: 0,
                  type_grants: 0
                }}
    end
  end

  describe "field_restrictions / field_grants (REQ-231 tables)" do
    test "inserts a field_restrictions row and a field_grants row for a real user" do
      tenant = tenant!("iss0935-field")
      user = insert_user!(tenant.schema_name, "anna")

      attrs = %{
        "field_restrictions" => [
          %{"entity_type" => "production_batch", "field_name" => "cost_figure"}
        ],
        "field_grants" => [
          %{
            "user_id" => user.id,
            "entity_type" => "production_batch",
            "field_name" => "cost_figure"
          }
        ]
      }

      assert {:ok,
              %{
                field_restrictions: 1,
                field_grants: 1,
                type_restrictions: 0,
                type_grants: 0
              }} = Restrictions.import_restrictions(attrs, tenant.schema_name)

      assert Repo.aggregate("entity_field_restrictions", :count, prefix: tenant.schema_name) == 1
      assert Repo.aggregate("user_entity_grants", :count, prefix: tenant.schema_name) == 1
    end

    test "a second, byte-identical call reports all-zero counts (idempotent on_conflict: :nothing)" do
      tenant = tenant!("iss0935-field-idem")
      user = insert_user!(tenant.schema_name, "anna")

      attrs = %{
        "field_restrictions" => [
          %{"entity_type" => "production_batch", "field_name" => "cost_figure"}
        ],
        "field_grants" => [
          %{
            "user_id" => user.id,
            "entity_type" => "production_batch",
            "field_name" => "cost_figure"
          }
        ]
      }

      assert {:ok, %{field_restrictions: 1, field_grants: 1}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)

      assert {:ok,
              %{
                field_restrictions: 0,
                field_grants: 0,
                type_restrictions: 0,
                type_grants: 0
              }} = Restrictions.import_restrictions(attrs, tenant.schema_name)

      assert Repo.aggregate("entity_field_restrictions", :count, prefix: tenant.schema_name) == 1
      assert Repo.aggregate("user_entity_grants", :count, prefix: tenant.schema_name) == 1
    end
  end

  describe "type_restrictions / type_grants (REQ-394 tables)" do
    test "inserts a type_restrictions row with no grant row (Karl's denial-by-absence shape, design §2.2)" do
      tenant = tenant!("iss0935-type")

      attrs = %{
        "type_restrictions" => [%{"entity_type" => "shipment_manifest"}],
        "type_grants" => []
      }

      assert {:ok,
              %{
                field_restrictions: 0,
                field_grants: 0,
                type_restrictions: 1,
                type_grants: 0
              }} = Restrictions.import_restrictions(attrs, tenant.schema_name)

      assert Repo.aggregate("entity_type_restrictions", :count, prefix: tenant.schema_name) == 1
      assert Repo.aggregate("user_entity_type_grants", :count, prefix: tenant.schema_name) == 0
    end

    test "inserts a type_grants row for a real user" do
      tenant = tenant!("iss0935-type-grant")
      user = insert_user!(tenant.schema_name, "someone")

      attrs = %{
        "type_restrictions" => [%{"entity_type" => "shipment_manifest"}],
        "type_grants" => [%{"user_id" => user.id, "entity_type" => "shipment_manifest"}]
      }

      assert {:ok, %{type_restrictions: 1, type_grants: 1}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)
    end
  end

  describe "422 validation -- entity_type/field_name must be non-empty strings" do
    test "an empty entity_type in field_restrictions is rejected, with zero rows inserted anywhere" do
      tenant = tenant!("iss0935-422-entity-type")

      attrs = %{
        "field_restrictions" => [%{"entity_type" => "", "field_name" => "cost_figure"}],
        "type_restrictions" => [%{"entity_type" => "shipment_manifest"}]
      }

      assert {:error, {:invalid_rows, [%{table: "field_restrictions", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)

      # The whole request fails together -- the valid type_restrictions row
      # is NOT inserted either (design §1.3's own "no partial success" --
      # distinct from REQ-320's per-record import semantics).
      assert Repo.aggregate("entity_type_restrictions", :count, prefix: tenant.schema_name) == 0
    end

    test "a missing field_name in field_restrictions is rejected" do
      tenant = tenant!("iss0935-422-missing-field")

      attrs = %{"field_restrictions" => [%{"entity_type" => "production_batch"}]}

      assert {:error, {:invalid_rows, [%{table: "field_restrictions", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)
    end

    test "a non-object row is rejected" do
      tenant = tenant!("iss0935-422-non-object")

      attrs = %{"field_restrictions" => ["not-an-object"]}

      assert {:error, {:invalid_rows, [%{table: "field_restrictions", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)
    end

    test "a non-array value for a restriction key is rejected" do
      tenant = tenant!("iss0935-422-non-array")

      attrs = %{"field_restrictions" => %{"entity_type" => "production_batch"}}

      assert {:error, {:invalid_rows, [%{table: "field_restrictions", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)
    end
  end

  describe "422 validation -- user_id must resolve to a user in the CALLING tenant (SECURITY-REVIEWER §7)" do
    test "a well-formed but nonexistent user_id is rejected" do
      tenant = tenant!("iss0935-422-user-missing")

      attrs = %{
        "field_grants" => [
          %{
            "user_id" => Ecto.UUID.generate(),
            "entity_type" => "production_batch",
            "field_name" => "cost_figure"
          }
        ]
      }

      assert {:error, {:invalid_rows, [%{table: "field_grants", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)
    end

    test "a malformed (non-UUID) user_id is rejected, not raised" do
      tenant = tenant!("iss0935-422-user-malformed")

      attrs = %{
        "type_grants" => [%{"user_id" => "not-a-uuid", "entity_type" => "shipment_manifest"}]
      }

      assert {:error, {:invalid_rows, [%{table: "type_grants", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant.schema_name)
    end

    # Cross-tenant user_id injection -- SECURITY-REVIEWER's checklist (design
    # §7): a user_id that is a well-formed UUID and genuinely belongs to a
    # REAL user, just in a DIFFERENT tenant's schema, must be rejected the
    # same way a nonexistent one is. Without this guard, a caller holding
    # :EntitiesRestrictionsManage in tenant A could plant a
    # user_entity_grants/user_entity_type_grants row keyed to a user_id that
    # happens to collide with a real user in tenant B -- this test proves
    # that row is never written, because Repo.get(User, user_id, prefix:
    # tenant_a.schema_name) looks ONLY inside tenant A's own schema.
    test "a user_id belonging to a DIFFERENT tenant is rejected, not treated as valid" do
      tenant_a = tenant!("iss0935-422-xtenant-a")
      tenant_b = tenant!("iss0935-422-xtenant-b")
      other_tenant_user = insert_user!(tenant_b.schema_name, "other-tenant")

      attrs = %{
        "field_grants" => [
          %{
            "user_id" => other_tenant_user.id,
            "entity_type" => "production_batch",
            "field_name" => "cost_figure"
          }
        ]
      }

      assert {:error, {:invalid_rows, [%{table: "field_grants", index: 0}]}} =
               Restrictions.import_restrictions(attrs, tenant_a.schema_name)

      # Confirm it is genuinely valid in its OWN tenant, so this is a real
      # cross-tenant rejection, not a row that would fail validation
      # anywhere.
      assert {:ok, %{field_grants: 1}} =
               Restrictions.import_restrictions(attrs, tenant_b.schema_name)

      assert Repo.aggregate("user_entity_grants", :count, prefix: tenant_a.schema_name) == 0
      assert Repo.aggregate("user_entity_grants", :count, prefix: tenant_b.schema_name) == 1
    end
  end
end
