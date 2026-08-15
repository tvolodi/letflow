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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
