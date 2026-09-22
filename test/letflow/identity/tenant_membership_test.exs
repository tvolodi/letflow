defmodule Letflow.Identity.TenantMembershipTest do
  @moduledoc """
  Light coverage for `Letflow.Identity.list_memberships_for_subject/1` and
  `Letflow.Identity.TenantMembership.create_changeset/2`/
  `normalize_subject_key/1` (REQ-384 Part A, design
  `lib/letflow/design/req384-tenant-switcher-cache-isolation.md` §1.2/§2.1).
  ELIXIR-DEV inline coverage only -- full TEST-DESIGNER coverage is a later
  pipeline step.

  `tenant_memberships` is public-schema (design §1.1, same tier as
  `tenants`) -- no tenant schema provisioning needed, plain
  `Letflow.DataCase, async: true`.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Repo

  defp insert_tenant!(slug) do
    %Tenant{}
    |> Tenant.create_changeset(%{slug: slug, display_name: String.capitalize(slug)}, :disabled)
    |> Repo.insert!()
  end

  defp insert_membership!(subject_key, tenant, attrs \\ %{}) do
    %TenantMembership{}
    |> TenantMembership.create_changeset(
      Map.merge(%{subject_key: subject_key, tenant_id: tenant.id}, attrs)
    )
    |> Repo.insert!()
  end

  describe "TenantMembership.normalize_subject_key/1" do
    test "lower-cases and trims" do
      assert TenantMembership.normalize_subject_key("  Alice@Example.COM  ") ==
               "alice@example.com"
    end
  end

  describe "TenantMembership.create_changeset/2" do
    test "normalizes subject_key before validating shape" do
      tenant = insert_tenant!("req384-cs-#{System.unique_integer([:positive])}")

      changeset =
        TenantMembership.create_changeset(%TenantMembership{}, %{
          subject_key: "  Bob@Example.com ",
          tenant_id: tenant.id
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :subject_key) == "bob@example.com"
    end

    test "rejects a non-email-shaped subject_key" do
      tenant = insert_tenant!("req384-cs2-#{System.unique_integer([:positive])}")

      changeset =
        TenantMembership.create_changeset(%TenantMembership{}, %{
          subject_key: "not-an-email",
          tenant_id: tenant.id
        })

      refute changeset.valid?
      assert {"must look like an email address", _} = changeset.errors[:subject_key]
    end

    test "enforces the [:subject_key, :tenant_id] unique constraint" do
      tenant = insert_tenant!("req384-cs3-#{System.unique_integer([:positive])}")
      email = "dup-#{System.unique_integer([:positive])}@example.com"

      insert_membership!(email, tenant)

      {:error, changeset} =
        %TenantMembership{}
        |> TenantMembership.create_changeset(%{subject_key: email, tenant_id: tenant.id})
        |> Repo.insert()

      refute changeset.valid?
    end
  end

  describe "Identity.list_memberships_for_subject/1" do
    test "returns {:ok, []} when the subject has no memberships" do
      assert Identity.list_memberships_for_subject(
               "nobody-#{System.unique_integer()}@example.com"
             ) ==
               {:ok, []}
    end

    test "joins tenant_memberships to tenants, ordered by tenant display_name ascending" do
      suffix = System.unique_integer([:positive])
      email = "switcher-#{suffix}@example.com"

      zeta = insert_tenant!("req384-zeta-#{suffix}")
      alpha = insert_tenant!("req384-alpha-#{suffix}")

      insert_membership!(email, zeta, %{display_label: "Zeta label"})
      insert_membership!(email, alpha)

      assert {:ok, [first, second]} = Identity.list_memberships_for_subject(email)

      assert first.tenant.id == alpha.id
      assert first.display_label == nil
      assert second.tenant.id == zeta.id
      assert second.display_label == "Zeta label"
    end

    test "only returns rows for the exact (already-normalized) subject_key" do
      suffix = System.unique_integer([:positive])
      email = "exact-#{suffix}@example.com"
      other_email = "other-#{suffix}@example.com"
      tenant = insert_tenant!("req384-exact-#{suffix}")

      insert_membership!(other_email, tenant)

      assert Identity.list_memberships_for_subject(email) == {:ok, []}
    end
  end
end
