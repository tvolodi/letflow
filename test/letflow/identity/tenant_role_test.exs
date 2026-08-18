defmodule Letflow.Identity.TenantRoleTest do
  @moduledoc """
  Direct-insert / schema-constraint tests for `Letflow.Identity.TenantRole`. See
  `test/specs/REQ-063.md` for why this file's fixtures changed — REQ-063
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `tenant_role` (and its `groups` FK target) out of `public` into each tenant's own
  provisioned Postgres schema. See `test/letflow/identity/user_test.exs`'s own
  moduledoc for the full reasoning behind the `SET search_path` fixture mechanism
  this file mirrors, INCLUDING the "Sandbox mode: what ACTUALLY protects against
  cross-test leakage" section there — this file's `setup` below restores a real
  sandboxed transaction (`Sandbox.mode(Repo, :manual)` + fresh
  `Sandbox.checkout/1`, checked back in via an explicit `Sandbox.checkin/1` in
  `on_exit/1` — NOT `{:shared, self()}` mode, which was empirically observed to
  leave orphaned tenant/schema rows behind across suite runs; see
  user_test.exs's moduledoc for why) immediately after the `:auto`-mode
  migration-replay work finishes and before issuing `SET search_path`, for
  exactly the reason explained there: switching to `:auto` mode checks in
  (discards) whatever transaction `Letflow.DataCase` had already checked out, so
  without this restore, `SET search_path` would commit against a bare pooled
  connection instead of running inside a transaction that gets rolled back on
  teardown.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.{Group, Tenant, TenantRole}
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp unique_slug, do: "req063-trole-#{System.unique_integer([:positive, :monotonic])}"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 TenantRole Test"},
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

    # REQ-063 rework: restore a REAL sandboxed transaction before issuing
    # SET search_path -- :auto mode above checked in (discarded) whatever
    # transaction Letflow.DataCase's setup had checked out, so without this
    # restore, SET search_path (a session-level GUC, not SET LOCAL) would commit
    # against a bare pooled connection and leak into whichever later test reuses
    # that connection. Mirrors identity_test.exs's "provision_oidc_user/4 --
    # concurrent-insert race" test (same underlying constraint, same fix). See
    # user_test.exs's moduledoc.
    #
    # Uses plain :manual mode + a bare checkout (NOT {:shared, self()}) -- this
    # file's tests are single-process (no Task.async spawns needing to share the
    # connection), so there is no need for shared ownership, and explicit
    # single-owner :manual mode lets on_exit/1 below checkin the SAME connection
    # deterministically rather than force-switching the whole pool's global mode
    # from a different process (the OnExitHandler process, not this test's own),
    # which was empirically observed to leave orphaned tenant/schema rows behind
    # across test runs (leftover `req063-trole-*` rows in `public.tenants`,
    # confirmed via direct Postgres inspection while debugging this rework).
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkin(Letflow.Repo)
    end)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    %{tenant: tenant, schema_name: schema_name}
  end

  # No changeset function exists yet on `TenantRole` (design §3.4 — REQ-020
  # owns list_roles/upsert_role) — insert the struct directly.
  defp insert_group!(%{tenant: tenant}) do
    {:ok, group} =
      Repo.insert(%Group{tenant_id: tenant.id, name: "Group #{Ecto.UUID.generate()}"})

    group
  end

  defp unique_role_name, do: "role-#{Ecto.UUID.generate()}"

  test "a tenant_role with a group_id that matches no groups row raises a constraint error",
       _ctx do
    # tenant_role.group_id is the one FK that DOES exist in this batch
    # (identity-schema.md §2.4), unlike users/groups.tenant_id's deliberate
    # omission. A freshly-generated UUID here matches no real groups row by
    # construction, so this must be rejected at the DB level -- inside this
    # tenant's own schema, the FK now resolves against that schema's own groups
    # table (REQ-063 §2.2), not public.groups.
    orphan_group_id = Ecto.UUID.generate()

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%TenantRole{name: unique_role_name(), group_id: orphan_group_id})
    end
  end

  test "a tenant_role with a group_id that matches a real groups row succeeds", ctx do
    group = insert_group!(ctx)

    assert {:ok, %TenantRole{group_id: group_id}} =
             Repo.insert(%TenantRole{name: unique_role_name(), group_id: group.id})

    assert group_id == group.id
  end

  test "two tenant_roles with the same name IN THE SAME tenant schema: the second raises a constraint error",
       ctx do
    group = insert_group!(ctx)
    name = unique_role_name()

    assert {:ok, _} = Repo.insert(%TenantRole{name: name, group_id: group.id})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%TenantRole{name: name, group_id: group.id})
    end
  end
end
