defmodule Letflow.Req442TenantModeSchemaTest do
  @moduledoc """
  REQ-442 AC1 (migration / column / CHECK) and the changeset half of AC2 (only
  `Tenant.admin_patch_changeset/2` may cast `login_disclosure_mode`). See
  `test/specs/REQ-442.md` for the criterion -> test map.

  `mix ecto.rollback` / `mix ecto.migrate` themselves are NOT run from ExUnit (they
  would drop the column under every concurrent session of the shared test DB); the
  real command output is quoted in the TEST-DESIGNER handoff and these tests pin
  the static properties (up/down are explicit, the manifest is untouched).
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity.Tenant

  @migration "priv/repo/migrations/20261005000001_add_login_disclosure_mode_to_tenants.exs"

  defp unique_slug, do: "req442-schema-#{System.unique_integer([:positive, :monotonic])}"

  defp insert_tenant!(extra) do
    %Tenant{slug: unique_slug(), display_name: "REQ-442 schema"}
    |> Ecto.Changeset.change(extra)
    |> Repo.insert!()
  end

  describe "AC1: column placement and nullability" do
    test "the column exists in the public schema ONLY (no tenant_* or other schema), as nullable varchar(255)" do
      %{rows: rows} =
        Repo.query!(
          "SELECT table_schema, data_type, is_nullable, character_maximum_length, column_default " <>
            "FROM information_schema.columns " <>
            "WHERE table_name = 'tenants' AND column_name = 'login_disclosure_mode'"
        )

      assert rows == [["public", "character varying", "YES", 255, nil]]
    end

    test "a tenant row created through the normal create path reads NULL (existing rows are NULL = deployment fallback)" do
      {:ok, tenant} =
        %Tenant{}
        |> Tenant.create_changeset(%{slug: unique_slug(), display_name: "Fresh"}, :disabled)
        |> Repo.insert()

      assert Repo.get!(Tenant, tenant.id).login_disclosure_mode == nil

      %{rows: [[value]]} =
        Repo.query!("SELECT login_disclosure_mode FROM tenants WHERE id = $1", [
          Ecto.UUID.dump!(tenant.id)
        ])

      assert value == nil
    end

    test "the migration is not part of the tenant-scoped manifest" do
      versions = Letflow.TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 0))
      refute 20_261_005_000_001 in versions
    end

    test "the migration uses explicit up/0 and down/0 (not change/0) and drops the constraint before the column" do
      source = File.read!(@migration)

      assert source =~ "def up do"
      assert source =~ "def down do"
      refute source =~ "def change"

      [_, down] = String.split(source, "def down do", parts: 2)
      {drop_pos, _} = :binary.match(down, "drop constraint")
      {remove_pos, _} = :binary.match(down, "remove :login_disclosure_mode")
      assert drop_pos < remove_pos
    end
  end

  describe "AC1: the CHECK constraint" do
    test "both valid modes and NULL are accepted" do
      for value <- ["uniform_plus_email", "redirect_single", nil] do
        tenant = insert_tenant!(%{login_disclosure_mode: value})
        assert Repo.get!(Tenant, tenant.id).login_disclosure_mode == value
      end
    end

    test "'picker_unauth' is rejected by the database CHECK, naming the constraint" do
      assert {:error, changeset} =
               %Tenant{slug: unique_slug(), display_name: "Bad mode"}
               |> Ecto.Changeset.change(%{login_disclosure_mode: "picker_unauth"})
               |> Ecto.Changeset.check_constraint(:login_disclosure_mode,
                 name: :tenants_login_disclosure_mode_check
               )
               |> Repo.insert(mode: :savepoint)

      assert [login_disclosure_mode: {_msg, opts}] = changeset.errors
      assert opts[:constraint] == :check
      assert opts[:constraint_name] == "tenants_login_disclosure_mode_check"
    end

    test "other near-miss values (wrong case, empty string, 'uniform') are also rejected by the database" do
      for bad <- ["Redirect_Single", "", "uniform", "REDIRECT_SINGLE"] do
        assert_raise Postgrex.Error, ~r/tenants_login_disclosure_mode_check/, fn ->
          Repo.query!(
            "UPDATE tenants SET login_disclosure_mode = $1 WHERE id = $2",
            [bad, Ecto.UUID.dump!(insert_tenant!(%{}).id)],
            mode: :savepoint
          )
        end
      end
    end
  end

  describe "AC2 (schema half): only admin_patch_changeset/2 casts the mode" do
    test "login_disclosure_modes/0 is exactly the two modes" do
      assert Tenant.login_disclosure_modes() == ["uniform_plus_email", "redirect_single"]
    end

    test "admin_patch_changeset/2 accepts each mode, and nil as the reset-to-fallback value" do
      tenant = %Tenant{display_name: "x", login_disclosure_mode: "redirect_single"}

      for mode <- Tenant.login_disclosure_modes() do
        cs =
          Tenant.admin_patch_changeset(%Tenant{display_name: "x"}, %{login_disclosure_mode: mode})

        assert cs.valid?
        assert cs.changes == %{login_disclosure_mode: mode}
      end

      cs = Tenant.admin_patch_changeset(tenant, %{"login_disclosure_mode" => nil})
      assert cs.valid?
      assert cs.changes == %{login_disclosure_mode: nil}
    end

    test "admin_patch_changeset/2 rejects an unknown value with a field error" do
      cs =
        Tenant.admin_patch_changeset(%Tenant{display_name: "x"}, %{
          "login_disclosure_mode" => "picker_unauth"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :login_disclosure_mode)
    end

    test "admin_patch_changeset/2 still never casts status or slug" do
      cs =
        Tenant.admin_patch_changeset(%Tenant{display_name: "x"}, %{
          "status" => "inactive",
          "slug" => "hijack"
        })

      assert cs.changes == %{}
    end

    test "create/update/status/settings changesets do NOT cast login_disclosure_mode (string and atom keys)" do
      base = %Tenant{display_name: "x", slug: "x"}

      for attrs <- [
            %{"login_disclosure_mode" => "uniform_plus_email"},
            %{login_disclosure_mode: "uniform_plus_email"}
          ] do
        create_attrs = Map.merge(%{slug: "a-b", display_name: "n"}, atomize(attrs))

        refute Map.has_key?(
                 Tenant.create_changeset(%Tenant{}, create_attrs, :disabled).changes,
                 :login_disclosure_mode
               )

        refute Map.has_key?(Tenant.update_changeset(base, attrs).changes, :login_disclosure_mode)
        refute Map.has_key?(Tenant.status_changeset(base, attrs).changes, :login_disclosure_mode)

        refute Map.has_key?(
                 Tenant.settings_changeset(base, attrs).changes,
                 :login_disclosure_mode
               )
      end
    end
  end

  defp atomize(attrs), do: Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)
  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k), do: String.to_existing_atom(k)
end
