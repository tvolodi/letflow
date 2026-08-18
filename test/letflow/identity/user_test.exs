defmodule Letflow.Identity.UserTest do
  @moduledoc """
  Direct-insert / schema-constraint tests for `Letflow.Identity.User`. See
  `test/specs/REQ-063.md` for why this file's fixtures changed — REQ-063
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved `users`
  out of the `public` schema into each tenant's own provisioned Postgres schema, so
  a bare `Repo.insert(struct(User, ...))` with no schema targeting now fails with
  `Postgrex.Error` (`relation "users" does not exist`) — `public.users` no longer
  exists post-cutover.

  ## Fixture mechanism: `SET search_path`, not `prefix:`

  Every insert in this file goes through `Repo.insert/1` on a bare `%User{}` struct
  (no `Ecto.Changeset`, since REQ-015/018/019's changeset functions on `User` only
  cover the JIT-provisioning path — see `Letflow.Identity.User.jit_changeset/2`'s own
  moduledoc), so there is no single call site to thread a `prefix:` option through
  the way `identity_test.exs`'s `provision_oidc_user/4` tests can. Passing `prefix:`
  per-call would also not be enough on its own for `assert_raise Ecto.ConstraintError`
  tests below, since the raised error's constraint-name matching doesn't depend on
  prefix — the simplest correct fix is to point the whole connection's Postgres
  `search_path` at the provisioned tenant schema for the test's duration via
  `SET search_path TO "<schema>", public`, so every unprefixed `Repo` call in this
  file resolves against that schema automatically, exactly matching how a real
  per-request `SET search_path` would work once Letflow eventually adopts that
  mechanism project-wide (`lib/letflow/design/req020-role-registry.md` §"Why zero
  arguments" already names this as the target architecture, not yet built). This
  technique was verified directly against real Postgres while drafting this file
  (a `SET search_path` issued on a sandboxed connection is transaction-scoped exactly
  like any other write on that connection — reverted automatically by
  `Letflow.DataCase`'s normal rollback, no manual cleanup needed for the
  `search_path` GUC itself).

  Provisioning the schema itself (`TenantProvisioning.provision_tenant_schema/1` +
  `replay_migrations/2`) still needs `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo,
  :auto)` first (`Ecto.Migrator` cannot run under the sandbox's single shared
  connection — see `lib/letflow/design/req022-tenant-schema-provisioning.md` §6's
  testing-environment caveat), so this file is `async: false` for its entire module
  (ExUnit's `async` setting is module-wide) and cleans up the real schema/rows it
  creates via `on_exit/1`, mirroring `test/letflow/tenant_provisioning_test.exs`'s
  and `test/letflow/identity_test.exs`'s established pattern.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # No changeset function exists yet on `User` for this direct-insert path (deferred
  # to REQ-018/REQ-019, see lib/letflow/design/identity-schema.md §3.2) — inserts
  # here build the struct directly and call Repo.insert/1, same pattern as
  # tenant_test.exs.
  defp unique_username, do: "user-#{Ecto.UUID.generate()}"

  defp unique_slug, do: "req063-user-#{System.unique_integer([:positive, :monotonic])}"

  # REQ-063: provisions a real tenant schema and points this connection's
  # search_path at it (see moduledoc) — every test in this file calls this once via
  # `setup`.
  defp provisioned_tenant_with_search_path! do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 User Test"},
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    %{tenant: tenant, schema_name: schema_name}
  end

  setup do
    provisioned_tenant_with_search_path!()
  end

  defp base_attrs(%{tenant: tenant}) do
    %{
      tenant_id: tenant.id,
      username: unique_username(),
      display_name: "A User",
      email: "user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "hash"
    }
  end

  test "two users with external_id: nil can both be inserted (partial index does not collide NULLs)",
       ctx do
    assert {:ok, _} = Repo.insert(struct(User, base_attrs(ctx)))
    assert {:ok, _} = Repo.insert(struct(User, base_attrs(ctx)))
  end

  test "two users with the same (external_realm, external_id): the second raises a constraint error",
       ctx do
    external_realm = "realm-#{Ecto.UUID.generate()}"
    external_id = "sub-#{Ecto.UUID.generate()}"

    assert {:ok, _} =
             Repo.insert(
               struct(
                 User,
                 Map.merge(base_attrs(ctx), %{
                   external_realm: external_realm,
                   external_id: external_id
                 })
               )
             )

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(
        struct(
          User,
          Map.merge(base_attrs(ctx), %{external_realm: external_realm, external_id: external_id})
        )
      )
    end
  end

  test "two users with the same username: the second raises a constraint error", ctx do
    username = unique_username()

    assert {:ok, _} =
             Repo.insert(struct(User, Map.put(base_attrs(ctx), :username, username)))

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(struct(User, Map.put(base_attrs(ctx), :username, username)))
    end
  end

  test "two users with the SAME username in TWO DIFFERENT tenant schemas both succeed (per-tenant-unique, not global-unique — Decision 0006 §3.1, REQ-063 acceptance criteria)",
       %{tenant: tenant_a, schema_name: schema_a} do
    username = unique_username()

    attrs_a = %{
      tenant_id: tenant_a.id,
      username: username,
      display_name: "User A",
      email: "user-a-#{Ecto.UUID.generate()}@example.com",
      password_hash: "hash"
    }

    assert {:ok, %User{id: id_a}} = Repo.insert(struct(User, attrs_a))

    # Provision a genuinely separate second tenant schema and point the connection's
    # search_path at IT instead — proves the SAME username succeeds in a different
    # schema, not merely that this file's helper can be called twice.
    %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant_with_search_path!()

    attrs_b = %{
      tenant_id: tenant_b.id,
      username: username,
      display_name: "User B",
      email: "user-b-#{Ecto.UUID.generate()}@example.com",
      password_hash: "hash"
    }

    assert {:ok, %User{id: id_b}} = Repo.insert(struct(User, attrs_b))

    assert id_a != id_b
    assert schema_a != schema_b

    # Confirm both rows genuinely persisted, one per tenant schema, by querying each
    # schema directly via prefix: (search_path currently points at schema_b, so
    # querying schema_a explicitly by prefix confirms it independently of the
    # ambient search_path).
    assert %User{username: ^username} = Repo.get(User, id_a, prefix: schema_a)
    assert %User{username: ^username} = Repo.get(User, id_b, prefix: schema_b)
  end

  test "a user can reference a tenant_id with no matching tenants row (no DB-level FK enforced)",
       ctx do
    # Deliberate design decision (identity-schema.md §2.2): users.tenant_id
    # carries no DB-level FK to tenants.id. A freshly-generated UUID here
    # matches no real tenants row by construction (UUIDv4 collision is not a
    # real-world concern) — if a future migration accidentally added
    # references(:tenants) back onto this column, this insert would start
    # raising Ecto.ConstraintError and this test would fail, catching the
    # regression.
    orphan_tenant_id = Ecto.UUID.generate()

    assert {:ok, %User{tenant_id: ^orphan_tenant_id}} =
             Repo.insert(struct(User, Map.put(base_attrs(ctx), :tenant_id, orphan_tenant_id)))
  end

  test "casting an invalid auth_source value is rejected by the Ecto.Enum declaration", ctx do
    changeset =
      Ecto.Changeset.cast(
        %User{},
        Map.put(base_attrs(ctx), :auth_source, "bogus"),
        [:tenant_id, :username, :display_name, :email, :password_hash, :auth_source]
      )

    refute changeset.valid?
    assert %{auth_source: _} = errors_on(changeset)
  end

  test "auth_source/external-fields inconsistency is NOT rejected at the DB level (no CHECK constraint)",
       ctx do
    # adp-04a's rule 2 (auth_source: :oidc requires both external fields
    # non-null; auth_source: :internal requires both null) is an
    # application-level (changeset) invariant per REQ-015's acceptance
    # criteria, deferred to REQ-018/REQ-019 — not a DB CHECK constraint. A row
    # that violates that rule must still succeed at the DB layer today.
    attrs =
      base_attrs(ctx)
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
