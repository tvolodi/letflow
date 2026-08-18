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
  arguments" already names this as the target architecture, not yet built).

  ## Sandbox mode: what ACTUALLY protects against cross-test leakage

  Provisioning the schema itself (`TenantProvisioning.provision_tenant_schema/1` +
  `replay_migrations/2`) needs `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`
  first (`Ecto.Migrator` cannot run under the sandbox's single shared connection —
  see `lib/letflow/design/req022-tenant-schema-provisioning.md` §6's testing-
  environment caveat). Switching to `:auto` mode checks in (discards) whatever
  sandboxed transaction `Letflow.DataCase`'s own setup had already checked out
  (`deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex`'s own moduledoc: "Whenever you
  change the mode to `:manual` or `:auto`, all existing connections are checked
  in.") — an earlier version of this file wrongly assumed the subsequent
  `SET search_path` call would still be transaction-scoped and rolled back
  automatically after that mode switch. It is not: with the pool in `:auto` mode,
  `SET search_path` (a session-level GUC, not `SET LOCAL`) is a real, committed
  change against a bare pooled connection, and that connection is returned to the
  pool still carrying it — a genuine cross-test-pollution vector.

  This file's `point_search_path_at!/1` helper therefore explicitly switches BACK
  to a real sandboxed transaction immediately after the migration-replay work
  finishes and before issuing `SET search_path`: `Sandbox.mode(Repo, :manual)` +
  a fresh `Sandbox.checkout(Repo)`. This restores a genuine, properly-checked-out
  sandboxed transaction, so `SET search_path` and every insert/assertion that
  follows it run inside a transaction that gets rolled back at teardown — via an
  explicit `Sandbox.checkin(Repo)` registered in `on_exit/1` right after the
  checkout (NOT `{:shared, self()}` mode: this file's tests are single-process, no
  `Task.async` spawns needing to share the connection, and an earlier version of
  this fix that used `{:shared, self()}` + force-switching the pool back to
  `:auto` from `on_exit`'s own process was empirically observed to leave orphaned
  `req063-user-*` tenant rows behind across suite runs — confirmed via direct
  Postgres inspection while debugging this rework — because forcing global mode
  from a process other than the connection's owner raced against that owner
  process's own teardown). Explicit `checkin` avoids that race entirely: the same
  process that checked the connection out also checks it back in.

  The provisioned tenant schema/rows themselves are real, committed Postgres state
  (a `CREATE SCHEMA` inside a transaction that later rolls back would not persist,
  so provisioning itself must happen, and does happen, outside sandbox
  protection), which is why `on_exit/1` still does the `DROP SCHEMA` / row cleanup
  in `provision_tenant_schema!/0` below — that part was never covered by rollback
  and still isn't; only the `SET search_path` GUC and the test body's own inserts
  are protected by the checkout/checkin pair.

  `provision_tenant_schema!/0` and `point_search_path_at!/1` are deliberately two
  separate helpers (not one combined step) because the "same username in two
  different tenant schemas" test below needs to provision BOTH schemas while still
  in `:auto` mode, before entering any sandboxed transaction — provisioning a
  second schema mid-test, after already being in a sandboxed transaction from the
  first, would switch back to `:auto` and discard that first transaction (rolling
  back whatever it held). That test instead drops out of the sandboxed-transaction
  approach entirely for its own body — see its own comment for why.
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

  # REQ-063: provisions a real tenant schema (still needs Sandbox :auto mode for
  # Ecto.Migrator's migration replay -- see moduledoc), WITHOUT touching
  # search_path or sandbox transaction state. Returns the tenant/schema_name pair;
  # callers that need `search_path` pointed at it call
  # `point_search_path_at!/1` separately (kept apart specifically so the "same
  # username, two different schemas" test below can provision BOTH schemas first,
  # while still in :auto mode, before entering a shared sandboxed transaction --
  # see that test for why interleaving provisioning with an active shared
  # transaction is unsafe).
  defp provision_tenant_schema! do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 User Test"},
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      # This callback runs AFTER the test process (and thus any {:shared, self()}
      # ownership established during the test) is gone -- so it must not assume
      # that mode is still in effect. Force :auto mode first so the DROP SCHEMA /
      # DELETE cleanup below always gets a real, checked-in connection regardless
      # of what mode the test body left the pool in (mirrors identity_test.exs's
      # own on_exit/1 handling of this exact hazard, confirmed empirically there).
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

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

    %{tenant: tenant, schema_name: schema_name}
  end

  # REQ-063 rework: restores a REAL sandboxed transaction, THEN issues
  # SET search_path -- must run after all :auto-mode provisioning is done for
  # the test, never interleaved with it. Switching to :auto mode (as
  # `provision_tenant_schema!/0` does for migration replay) checks in and
  # discards whatever sandboxed transaction was previously checked out
  # (`deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex`'s own moduledoc), so calling
  # this, then provisioning ANOTHER schema, then calling this again would silently
  # roll back everything inserted under the first call's transaction. Mirrors
  # identity_test.exs's "provision_oidc_user/4 -- concurrent-insert race" test
  # (same underlying constraint, same fix). See moduledoc.
  # Uses plain :manual mode + a bare checkout (NOT {:shared, self()}) -- this
  # file's tests are single-process (no Task.async spawns needing to share the
  # connection), so there is no need for shared ownership, and explicit
  # single-owner :manual mode lets an on_exit/1 checkin the SAME connection
  # deterministically rather than force-switching the whole pool's global mode
  # from a different process (the OnExitHandler process, not this test's own),
  # which was empirically observed to leave orphaned tenant/schema rows behind
  # across test runs (leftover `req063-user-*` rows in `public.tenants`,
  # confirmed via direct Postgres inspection while debugging this rework).
  defp point_search_path_at!(schema_name) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkin(Letflow.Repo)
    end)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    :ok
  end

  # Single-schema convenience wrapper for the common case (every test except the
  # "same username, two different schemas" test below, which needs the two steps
  # split apart).
  defp provisioned_tenant_with_search_path! do
    %{tenant: tenant, schema_name: schema_name} = provision_tenant_schema!()
    :ok = point_search_path_at!(schema_name)
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
    # This test genuinely needs TWO real, independently-queryable tenant schemas
    # alive at the same time, which a single {:shared, self()} sandboxed
    # transaction cannot provide (each checkout/mode-restore discards whatever
    # transaction came before it — see point_search_path_at!/1's moduledoc
    # reference). So this test deliberately drops out of the shared-transaction
    # fixture `setup` established and switches the WHOLE Repo pool to :auto mode
    # for its own body instead — every insert below is a real, committed Postgres
    # row (not something rolled back at teardown), cleaned up explicitly via
    # `on_exit/1` DELETEs, exactly mirroring identity_test.exs's own "two
    # different tenant schemas" test (`provisioned_tenant!/0` there never uses
    # {:shared, self()} at all, for this same reason).
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    username = unique_username()

    attrs_a = %{
      tenant_id: tenant_a.id,
      username: username,
      display_name: "User A",
      email: "user-a-#{Ecto.UUID.generate()}@example.com",
      password_hash: "hash"
    }

    Repo.query!(~s(SET search_path TO "#{schema_a}", public))
    assert {:ok, %User{id: id_a}} = Repo.insert(struct(User, attrs_a))

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
      Repo.delete_all(from(u in User, where: u.id == ^id_a), prefix: schema_a)
    end)

    # Provision a genuinely separate second tenant schema and point search_path
    # at IT instead — proves the SAME username succeeds in a different schema,
    # not merely that this file's helper can be called twice. Still real,
    # committed Postgres state (a CREATE SCHEMA can't happen inside a transaction
    # that later rolls back and still persist), same as schema_a's own
    # provisioning under `setup`.
    %{tenant: tenant_b, schema_name: schema_b} = provision_tenant_schema!()
    Repo.query!(~s(SET search_path TO "#{schema_b}", public))

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
