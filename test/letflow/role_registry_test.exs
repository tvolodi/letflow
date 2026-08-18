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

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database anywhere in this file.

  ## REQ-063 fixture change (read before touching a test here)

  REQ-063 (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `groups`/`tenant_role` out of `public` into each tenant's own provisioned Postgres
  schema. `Letflow.Identity.RoleRegistry` itself was deliberately NOT modified by
  REQ-063 (out of that design's scope — see
  `lib/letflow/design/req020-role-registry.md`'s "Why zero arguments" section,
  which explicitly documents that `list_roles/0`/`upsert_role/2`/
  `resolve_role_in_tx/1` all take no tenant/prefix parameter today, relying on a
  future per-request `SET search_path` mechanism Letflow has "not built yet" as of
  REQ-020's own writing). REQ-063 made that future mechanism's absence concrete: with
  `groups`/`tenant_role` no longer in `public` at all, `RoleRegistry`'s unprefixed
  queries now need a real `search_path` pointed at a tenant schema to find anything.

  This file therefore now provisions a real tenant schema per test (`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`
  + `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/2`) and
  issues `SET search_path TO "<schema>", public` on that connection before each
  test body runs — see `test/letflow/identity/user_test.exs`'s own moduledoc,
  "Sandbox mode: what ACTUALLY protects against cross-test leakage" section, for
  the full reasoning. In short: switching to `:auto` mode above checks in
  (discards) whatever sandboxed transaction `Letflow.DataCase`'s own setup had
  already checked out, so `SET search_path` is NOT automatically reverted by any
  rollback at that point — an earlier version of this moduledoc wrongly claimed
  it was. What actually protects against leakage is that this file's `setup`
  below explicitly restores a real sandboxed transaction
  (`Sandbox.mode(Repo, :manual)` + fresh `Sandbox.checkout/1`) immediately after
  the migration-replay work finishes and BEFORE issuing `SET search_path`, so
  the `SET search_path` call and everything the test body does afterward run
  inside a transaction that gets rolled back at teardown. Deliberately NOT
  `{:shared, self()}` mode: this file's tests are single-process (no
  `Task.async` spawns needing to share the connection).

  This deliberately does NOT register an `on_exit/1`-based `Sandbox.checkin/1`
  either. An earlier version of this fix did, believing the checkin closed the
  loop; it did not — `Ecto.Adapters.SQL.Sandbox.checkin/1` (and
  `DBConnection.Ownership`'s `ownership_checkin`/`proxy_checkin` underneath it,
  see `deps/db_connection/lib/db_connection/ownership/manager.ex`) keys the
  checkin by the CALLING process's own pid, but `ExUnit.OnExitHandler` runs
  every `on_exit/1` callback via `spawn_monitor` in a dedicated runner process,
  never the original test process that performed the checkout — so a checkin
  issued from `on_exit/1` checks in on behalf of the wrong process and silently
  no-ops (`:not_found`). What actually reclaims the checked-out connection and
  rolls back its transaction is `DBConnection.Ownership.Manager`'s own
  unconditional `:DOWN`-monitor handler (`handle_info({:DOWN, ref, _, _, _},
  state)`), which fires automatically once this test's own process exits — the
  exact mechanism `Letflow.DataCase`'s own `{:shared, self()}` checkout already
  relies on (it never calls `checkin/1` either). No explicit checkin step is
  attempted here.
  `Ecto.Migrator` cannot run under the sandbox's single shared connection
  (`lib/letflow/design/req022-tenant-schema-provisioning.md` §6's testing-
  environment caveat), so this file is now `async: false` for its entire module
  (ExUnit's `async` setting is module-wide) — unlike its pre-REQ-063 version, which
  ran `async: true` against bare `public` tables. Every test still builds its own
  unique `Group`/`TenantRole` fixture names (no shared hardcoded values), and since
  each test also gets its OWN freshly-provisioned tenant schema (not merely a
  rolled-back transaction against a shared one), `tenant_role.name`'s table-wide
  unique index cannot collide across tests even though they now run sequentially
  rather than concurrently.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # Every test builds its own unique name/tenant — no shared hardcoded values, per
  # test_developer_guide.md's "no test pollution" principle and this project's
  # established System.unique_integer/1 convention (identity_test.exs's unique_realm/1,
  # unique_slug/1).
  defp unique_name(prefix \\ "role") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_slug, do: "req063-rolereg-#{System.unique_integer([:positive, :monotonic])}"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 RoleRegistry Test"},
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      # This callback runs AFTER the test process (and thus the {:shared, self()}
      # ownership set up below) is gone -- so it must not assume that mode is still
      # in effect. Force :auto mode first so the DROP SCHEMA / DELETE cleanup below
      # always gets a real, checked-in connection regardless of what mode the test
      # body left the pool in (mirrors identity_test.exs's own on_exit/1 handling
      # of this exact hazard, confirmed empirically there).
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

    # REQ-063 rework (iteration 2): restore a REAL sandboxed transaction before
    # issuing SET search_path -- :auto mode above checked in (discarded) whatever
    # transaction Letflow.DataCase's setup had checked out, so without this
    # restore, SET search_path (a session-level GUC, not SET LOCAL) would commit
    # against a bare pooled connection and leak into whichever later test reuses
    # that connection. Mirrors identity_test.exs's "provision_oidc_user/4 --
    # concurrent-insert race" test (same underlying constraint, same fix). See
    # this file's moduledoc and user_test.exs's moduledoc.
    #
    # Uses plain :manual mode + a bare checkout (NOT {:shared, self()}) -- this
    # file's tests are single-process (no Task.async spawns needing to share the
    # connection), so there is no need for shared ownership.
    #
    # Deliberately does NOT register an on_exit/1 checkin -- see moduledoc's
    # "Sandbox mode: what ACTUALLY protects against cross-test leakage" section.
    # A checkin from on_exit/1 runs in ExUnit's separate OnExitHandler process,
    # not this test process, so DBConnection.Ownership.Manager's proxy_checkin
    # (keyed by the CALLING process's pid) finds no matching ownership entry and
    # silently no-ops. This checkout is instead reclaimed by
    # DBConnection.Ownership.Manager's unconditional :DOWN-monitor handler when
    # this test process itself exits -- the same mechanism Letflow.DataCase's
    # own {:shared, self()} checkout already relies on.
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    %{tenant: tenant, schema_name: schema_name}
  end

  defp insert_group!(_ctx) do
    %Group{}
    |> Ecto.Changeset.change(%{
      name: "group-#{System.unique_integer([:positive, :monotonic])}"
    })
    |> Repo.insert!()
  end

  describe "list_roles/0 (acceptance criterion 1)" do
    test "returns [] (not an error) against an empty tenant_role table", _ctx do
      assert RoleRegistry.list_roles() == []
    end

    test "returns all rows sorted by name ascending, proving the ORDER BY is real", ctx do
      group = insert_group!(ctx)

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
    test "a syntactically-valid but nonexistent group_id returns {:error, :group_not_found} and inserts no row",
         _ctx do
      name = unique_name()
      nonexistent_group_id = Ecto.UUID.generate()

      assert {:error, :group_not_found} = RoleRegistry.upsert_role(name, nonexistent_group_id)

      rows = TenantRole |> where(name: ^name) |> Repo.all()
      assert rows == []
    end
  end

  describe "upsert_role/2 — update existing binding (acceptance criterion 3)" do
    test "called twice with the same name and a different group_id updates the binding, no duplicate row",
         ctx do
      name = unique_name()
      group_a = insert_group!(ctx)
      group_b = insert_group!(ctx)

      assert {:ok, %TenantRole{group_id: first_group_id}} =
               RoleRegistry.upsert_role(name, group_a.id)

      assert first_group_id == group_a.id

      assert {:ok, %TenantRole{group_id: second_group_id}} =
               RoleRegistry.upsert_role(name, group_b.id)

      assert second_group_id == group_b.id

      # Re-select from Postgres directly rather than trusting the in-memory reply,
      # matching this project's established persistence-test convention
      # (process_instance_test.exs / identity_test.exs's Repo.get/2 re-select pattern).
      rows = TenantRole |> where(name: ^name) |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).group_id == group_b.id
    end
  end

  describe "resolve_role_in_tx/1 (acceptance criterion 4)" do
    test "returns the bound group_id for a name that exists", ctx do
      name = unique_name()
      group = insert_group!(ctx)

      assert {:ok, _} = RoleRegistry.upsert_role(name, group.id)

      assert RoleRegistry.resolve_role_in_tx(name) == group.id
    end

    test "returns nil for an unbound/unknown name", _ctx do
      assert RoleRegistry.resolve_role_in_tx(unique_name("nonexistent")) == nil
    end

    test "called from inside an existing Repo.transaction/1 callback (its documented usage), still resolves correctly",
         ctx do
      name = unique_name()
      group = insert_group!(ctx)

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
    test "a query-level error that would otherwise raise resolves to nil, not an unhandled exception",
         _ctx do
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
    test "rejects an empty name", ctx do
      group = insert_group!(ctx)

      assert {:error, :invalid_role_name} = RoleRegistry.upsert_role("", group.id)
    end

    test "rejects a name longer than 128 codepoints", ctx do
      group = insert_group!(ctx)
      too_long = String.duplicate("a", 129)

      assert {:error, :invalid_role_name} = RoleRegistry.upsert_role(too_long, group.id)
    end

    test "accepts a name of exactly 128 codepoints (the boundary itself is valid)", ctx do
      group = insert_group!(ctx)
      exactly_128 = String.duplicate("a", 128)

      assert {:ok, %TenantRole{name: ^exactly_128}} =
               RoleRegistry.upsert_role(exactly_128, group.id)
    end

    test "rejects a name containing a control character", ctx do
      group = insert_group!(ctx)
      with_control_char = "role-#{<<0x01>>}-name"

      assert {:error, :invalid_role_name} = RoleRegistry.upsert_role(with_control_char, group.id)
    end
  end

  describe "upsert_role/2 — group_id invalid-UUID-format rejection (beyond the bare acceptance criteria)" do
    test "rejects a group_id that is not a syntactically valid UUID, distinct from the not-found case",
         _ctx do
      name = unique_name()

      assert {:error, :invalid_group_id} = RoleRegistry.upsert_role(name, "not-a-uuid")

      rows = TenantRole |> where(name: ^name) |> Repo.all()
      assert rows == []
    end
  end
end
