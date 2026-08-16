defmodule Letflow.Identity.RoleRegistryTest do
  @moduledoc """
  Tests for `Letflow.Identity.RoleRegistry` (REQ-020): `list_roles/0`,
  `upsert_role/2`, `resolve_role_in_tx/1`. See `test/specs/REQ-020.md` for the full
  test-case rationale, including why AC5 (the `@moduledoc` content requirement) has no
  runtime test here and why AC4's "never raises" clause is covered the way it is.

  Separate file from `test/letflow/identity_test.exs` deliberately, mirroring
  `lib/letflow/design/req020-role-registry.md` §1's own module-boundary decision:
  `Letflow.Identity.RoleRegistry` is a standalone module, not a function added to
  `Letflow.Identity`, specifically so the "no OIDC-pipeline coupling" invariant is
  structural rather than a convention inside a file that already imports OIDC-adjacent
  aliases for sibling functions. The test file mirrors that same boundary — this file
  never aliases `Letflow.Identity` or any `Letflow.Oidc.*` module, matching the
  production module it tests.

  Uses `Letflow.DataCase` (real Postgres, sandboxed connection, rolled back per test)
  per `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database anywhere
  in this file. All tests run `async: true`: each test builds its own unique `Group`/
  `TenantRole` fixtures inside its own sandboxed transaction, so no test's data is ever
  visible to another test (matching `identity_test.exs`'s established `async: true`
  convention for REQ-019, since `tenant_role.name` is a table-wide unique index and
  collisions across concurrently-running tests would otherwise be possible with a
  shared/hardcoded name).
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole

  # Every test builds its own unique name/tenant — no shared hardcoded values, per
  # test_developer_guide.md's "no test pollution" principle and this project's
  # established System.unique_integer/1 convention (identity_test.exs's unique_realm/1,
  # unique_slug/1).
  defp unique_name(prefix \\ "role") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_group! do
    %Group{}
    |> Ecto.Changeset.change(%{
      tenant_id: Ecto.UUID.generate(),
      name: "group-#{System.unique_integer([:positive, :monotonic])}"
    })
    |> Repo.insert!()
  end

  describe "list_roles/0 (acceptance criterion 1)" do
    test "returns [] (not an error) against an empty tenant_role table" do
      assert RoleRegistry.list_roles() == []
    end

    test "returns all rows sorted by name ascending, proving the ORDER BY is real" do
      group = insert_group!()

      # Names deliberately chosen so alphabetical order differs from insertion order —
      # if list_roles/0 silently relied on insertion/primary-key order instead of a
      # real ORDER BY name, this would fail: inserting "zeta" then "alpha" then "mid"
      # would come back in that same insertion order, not alphabetically.
      name_zeta = "zeta-#{System.unique_integer([:positive, :monotonic])}"
      name_alpha = "alpha-#{System.unique_integer([:positive, :monotonic])}"
      name_mid = "mid-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _} = RoleRegistry.upsert_role(name_zeta, group.id)
      assert {:ok, _} = RoleRegistry.upsert_role(name_alpha, group.id)
      assert {:ok, _} = RoleRegistry.upsert_role(name_mid, group.id)

      names =
        RoleRegistry.list_roles()
        |> Enum.map(& &1.name)
        |> Enum.filter(&(&1 in [name_zeta, name_alpha, name_mid]))

      assert names == [name_alpha, name_mid, name_zeta]
    end
  end

  describe "upsert_role/2 — group_id not found (acceptance criterion 2)" do
    test "a syntactically-valid but nonexistent group_id returns {:error, :group_not_found} and inserts no row" do
      name = unique_name()
      nonexistent_group_id = Ecto.UUID.generate()

      assert {:error, :group_not_found} = RoleRegistry.upsert_role(name, nonexistent_group_id)

      import Ecto.Query

      rows = TenantRole |> where(name: ^name) |> Repo.all()
      assert rows == []
    end
  end

  describe "upsert_role/2 — update existing binding (acceptance criterion 3)" do
    test "called twice with the same name and a different group_id updates the binding, no duplicate row" do
      name = unique_name()
      group_a = insert_group!()
      group_b = insert_group!()

      assert {:ok, %TenantRole{group_id: first_group_id}} =
               RoleRegistry.upsert_role(name, group_a.id)

      assert first_group_id == group_a.id

      assert {:ok, %TenantRole{group_id: second_group_id}} =
               RoleRegistry.upsert_role(name, group_b.id)

      assert second_group_id == group_b.id

      # Re-select from Postgres directly rather than trusting the in-memory reply,
      # matching this project's established persistence-test convention
      # (process_instance_test.exs / identity_test.exs's Repo.get/2 re-select pattern).
      import Ecto.Query

      rows = TenantRole |> where(name: ^name) |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).group_id == group_b.id
    end
  end

  describe "resolve_role_in_tx/1 (acceptance criterion 4)" do
    test "returns the bound group_id for a name that exists" do
      name = unique_name()
      group = insert_group!()

      assert {:ok, _} = RoleRegistry.upsert_role(name, group.id)

      assert RoleRegistry.resolve_role_in_tx(name) == group.id
    end

    test "returns nil for an unbound/unknown name" do
      assert RoleRegistry.resolve_role_in_tx(unique_name("nonexistent")) == nil
    end

    test "called from inside an existing Repo.transaction/1 callback (its documented usage), still resolves correctly" do
      name = unique_name()
      group = insert_group!()

      assert {:ok, _} = RoleRegistry.upsert_role(name, group.id)

      result =
        Repo.transaction(fn ->
          RoleRegistry.resolve_role_in_tx(name)
        end)

      assert {:ok, resolved_group_id} = result
      assert resolved_group_id == group.id
    end

    # "Never raises" coverage — see test/specs/REQ-020.md's discussion of why this is
    # the practical limit of this claim's testability at this level. The unbound-name
    # case above already exercises the ordinary nil-producing path (Repo.get_by/2's own
    # no-match behavior, which never raises to begin with — no rescue needed there).
    # This test targets the OTHER branch: a query that reaches Ecto/Postgrex but fails
    # in a way that would normally raise (here, an invalid parameter type causing
    # Ecto.Query.CastError), proving the function's explicit `rescue` genuinely
    # intercepts a real raised exception rather than merely never encountering one in
    # the two obvious cases.
    test "a query-level error that would otherwise raise resolves to nil, not an unhandled exception" do
      # Repo.get_by(TenantRole, name: name) expects `name` to be a string (the schema's
      # field type). Passing a value Ecto cannot cast for that field forces
      # Ecto.Query.CastError inside the query built by resolve_role_in_tx/1's own
      # implementation, exercising the function's `rescue` clause for real rather than
      # by construction/inspection alone.
      invalid_name = {:not, :a, :string}

      assert RoleRegistry.resolve_role_in_tx(invalid_name) == nil
    end
  end

  describe "upsert_role/2 — name validation rejection modes (beyond the bare acceptance criteria)" do
    test "rejects an empty name" do
      group = insert_group!()

      assert {:error, :invalid_role_name} = RoleRegistry.upsert_role("", group.id)
    end

    test "rejects a name longer than 128 codepoints" do
      group = insert_group!()
      too_long = String.duplicate("a", 129)

      assert {:error, :invalid_role_name} = RoleRegistry.upsert_role(too_long, group.id)
    end

    test "accepts a name of exactly 128 codepoints (the boundary itself is valid)" do
      group = insert_group!()
      exactly_128 = String.duplicate("a", 128)

      assert {:ok, %TenantRole{name: ^exactly_128}} =
               RoleRegistry.upsert_role(exactly_128, group.id)
    end

    test "rejects a name containing a control character" do
      group = insert_group!()
      with_control_char = "role-#{<<0x01>>}-name"

      assert {:error, :invalid_role_name} = RoleRegistry.upsert_role(with_control_char, group.id)
    end
  end

  describe "upsert_role/2 — group_id invalid-UUID-format rejection (beyond the bare acceptance criteria)" do
    test "rejects a group_id that is not a syntactically valid UUID, distinct from the not-found case" do
      name = unique_name()

      assert {:error, :invalid_group_id} = RoleRegistry.upsert_role(name, "not-a-uuid")

      import Ecto.Query

      rows = TenantRole |> where(name: ^name) |> Repo.all()
      assert rows == []
    end
  end
end
