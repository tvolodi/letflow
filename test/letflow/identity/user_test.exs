defmodule Letflow.Identity.UserTest do
  use Letflow.DataCase, async: true

  alias Letflow.Identity.User

  # No changeset function exists yet on `User` (deferred to REQ-018/REQ-019, see
  # lib/letflow/design/identity-schema.md §3.2) — inserts here build the struct
  # directly and call Repo.insert/1, same pattern as tenant_test.exs.
  defp unique_username, do: "user-#{Ecto.UUID.generate()}"

  defp base_attrs do
    %{
      tenant_id: Ecto.UUID.generate(),
      username: unique_username(),
      display_name: "A User",
      email: "user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "hash"
    }
  end

  test "two users with external_id: nil can both be inserted (partial index does not collide NULLs)" do
    assert {:ok, _} = Repo.insert(struct(User, base_attrs()))
    assert {:ok, _} = Repo.insert(struct(User, base_attrs()))
  end

  test "two users with the same (external_realm, external_id): the second raises a constraint error" do
    external_realm = "realm-#{Ecto.UUID.generate()}"
    external_id = "sub-#{Ecto.UUID.generate()}"

    assert {:ok, _} =
             Repo.insert(
               struct(
                 User,
                 Map.merge(base_attrs(), %{
                   external_realm: external_realm,
                   external_id: external_id
                 })
               )
             )

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(
        struct(
          User,
          Map.merge(base_attrs(), %{external_realm: external_realm, external_id: external_id})
        )
      )
    end
  end

  test "two users with the same username: the second raises a constraint error" do
    username = unique_username()

    assert {:ok, _} =
             Repo.insert(struct(User, Map.put(base_attrs(), :username, username)))

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(struct(User, Map.put(base_attrs(), :username, username)))
    end
  end

  test "a user can reference a tenant_id with no matching tenants row (no DB-level FK enforced)" do
    # Deliberate design decision (identity-schema.md §2.2): users.tenant_id
    # carries no DB-level FK to tenants.id. A freshly-generated UUID here
    # matches no real tenants row by construction (UUIDv4 collision is not a
    # real-world concern) — if a future migration accidentally added
    # references(:tenants) back onto this column, this insert would start
    # raising Ecto.ConstraintError and this test would fail, catching the
    # regression.
    orphan_tenant_id = Ecto.UUID.generate()

    assert {:ok, %User{tenant_id: ^orphan_tenant_id}} =
             Repo.insert(struct(User, Map.put(base_attrs(), :tenant_id, orphan_tenant_id)))
  end

  test "casting an invalid auth_source value is rejected by the Ecto.Enum declaration" do
    changeset =
      Ecto.Changeset.cast(
        %User{},
        Map.put(base_attrs(), :auth_source, "bogus"),
        [:tenant_id, :username, :display_name, :email, :password_hash, :auth_source]
      )

    refute changeset.valid?
    assert %{auth_source: _} = errors_on(changeset)
  end

  test "auth_source/external-fields inconsistency is NOT rejected at the DB level (no CHECK constraint)" do
    # adp-04a's rule 2 (auth_source: :oidc requires both external fields
    # non-null; auth_source: :internal requires both null) is an
    # application-level (changeset) invariant per REQ-015's acceptance
    # criteria, deferred to REQ-018/REQ-019 — not a DB CHECK constraint. A row
    # that violates that rule must still succeed at the DB layer today.
    attrs =
      base_attrs()
      |> Map.put(:auth_source, :internal)
      |> Map.put(:external_realm, "realm-#{Ecto.UUID.generate()}")
      |> Map.put(:external_id, "sub-#{Ecto.UUID.generate()}")

    assert {:ok, %User{auth_source: :internal}} = Repo.insert(struct(User, attrs))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
