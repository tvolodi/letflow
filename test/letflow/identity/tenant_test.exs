defmodule Letflow.Identity.TenantTest do
  use Letflow.DataCase, async: true

  alias Letflow.Identity.Tenant

  # No changeset function exists yet on `Tenant` (deferred to REQ-019, see
  # lib/letflow/design/identity-schema.md §3.1) — inserts here build the
  # struct directly and call Repo.insert/1, matching this project's existing
  # pattern for changeset-less schemas (Letflow.RowApproval.Approval).
  defp unique_slug, do: "tenant-#{Ecto.UUID.generate()}"

  test "two tenants with idp_realm_id: nil can both be inserted (partial index does not collide NULLs)" do
    assert {:ok, _} =
             Repo.insert(%Tenant{
               slug: unique_slug(),
               display_name: "Tenant A",
               idp_realm_id: nil
             })

    assert {:ok, _} =
             Repo.insert(%Tenant{
               slug: unique_slug(),
               display_name: "Tenant B",
               idp_realm_id: nil
             })
  end

  test "two tenants with the same non-null idp_realm_id: the second raises a constraint error" do
    realm_id = "realm-#{Ecto.UUID.generate()}"

    assert {:ok, _} =
             Repo.insert(%Tenant{
               slug: unique_slug(),
               display_name: "Tenant A",
               idp_realm_id: realm_id
             })

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%Tenant{
        slug: unique_slug(),
        display_name: "Tenant B",
        idp_realm_id: realm_id
      })
    end
  end

  test "two tenants with the same slug: the second raises a constraint error" do
    slug = unique_slug()

    assert {:ok, _} =
             Repo.insert(%Tenant{slug: slug, display_name: "Tenant A"})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%Tenant{slug: slug, display_name: "Tenant B"})
    end
  end

  test "casting an invalid status value is rejected by the Ecto.Enum declaration" do
    changeset =
      Ecto.Changeset.cast(
        %Tenant{},
        %{slug: unique_slug(), display_name: "Tenant A", status: "bogus"},
        [:slug, :display_name, :status]
      )

    refute changeset.valid?
    assert %{status: _} = errors_on(changeset)
  end

  test "casting :inactive is accepted by the extended Ecto.Enum declaration (REQ-075)" do
    changeset =
      Ecto.Changeset.cast(
        %Tenant{},
        %{slug: unique_slug(), display_name: "Tenant A", status: "inactive"},
        [:slug, :display_name, :status]
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :status) == :inactive
  end

  describe "admin_patch_changeset/2 (REQ-075)" do
    test "casts display_name but structurally cannot write status" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original", status: :active}

      changeset =
        Tenant.admin_patch_changeset(tenant, %{
          "display_name" => "Renamed",
          "status" => "inactive"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :display_name) == "Renamed"
      # :status was never cast -- no change key for it at all, not merely unchanged.
      refute Map.has_key?(changeset.changes, :status)
    end

    test "an attrs map with only display_name is a valid changeset" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original"}

      changeset = Tenant.admin_patch_changeset(tenant, %{"display_name" => "New Name"})

      assert changeset.valid?
    end
  end

  describe "status_changeset/2 (REQ-075)" do
    test "casts status but structurally cannot write display_name" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original", status: :active}

      changeset =
        Tenant.status_changeset(tenant, %{"status" => "inactive", "display_name" => "Renamed"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :inactive
      refute Map.has_key?(changeset.changes, :display_name)
    end

    test "status is required (an explicit nil in attrs is rejected)" do
      tenant = %Tenant{slug: unique_slug(), display_name: "Original", status: :active}

      changeset = Tenant.status_changeset(tenant, %{"status" => nil})

      refute changeset.valid?
      assert %{status: _} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
