defmodule Letflow.Identity.GroupTest do
  @moduledoc """
  Direct-insert / schema-constraint test for `Letflow.Identity.Group`. See
  `test/specs/REQ-063.md` for why this file's fixture changed — REQ-063
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved `groups`
  out of `public` into each tenant's own provisioned Postgres schema. See
  `test/letflow/identity/user_test.exs`'s own moduledoc for the full reasoning
  behind the `SET search_path` fixture mechanism this file mirrors (a bare
  `Repo.insert(%Group{...})` has no single call site to thread `prefix:` through),
  INCLUDING the "Sandbox mode: what ACTUALLY protects against cross-test leakage"
  section there — this file's `setup` below restores a real sandboxed transaction
  (`Sandbox.mode(Repo, :manual)` + fresh `Sandbox.checkout/1`, checked back in via
  an explicit `Sandbox.checkin/1` in `on_exit/1` — NOT `{:shared, self()}` mode,
  which was empirically observed to leave orphaned tenant/schema rows behind
  across suite runs; see user_test.exs's moduledoc for why) immediately after the
  `:auto`-mode migration-replay work finishes and before issuing
  `SET search_path`, for exactly the reason explained there: switching to `:auto`
  mode checks in (discards) whatever transaction `Letflow.DataCase` had already
  checked out, so without this restore, `SET search_path` would commit against a
  bare pooled connection instead of running inside a transaction that gets rolled
  back on teardown.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defp unique_slug, do: "req063-group-#{System.unique_integer([:positive, :monotonic])}"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 Group Test"},
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
    # across test runs (leftover `req063-group-*` rows in `public.tenants`,
    # confirmed via direct Postgres inspection while debugging this rework).
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkin(Letflow.Repo)
    end)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    %{tenant: tenant, schema_name: schema_name}
  end

  # No changeset function exists yet on `Group` (design §3.3 — no requirement
  # in the REQ-015..021 batch owns groups CRUD) — insert the struct directly.
  test "a group can reference a tenant_id with no matching tenants row (no DB-level FK enforced)",
       %{tenant: tenant} do
    # Same deliberate omission as users.tenant_id (identity-schema.md §2.3):
    # groups.tenant_id carries no DB-level FK to tenants.id. This UUID
    # matches no real tenants row by construction; if a future migration
    # accidentally added references(:tenants) here, this insert would start
    # raising and this test would catch it. Deliberately NOT tenant.id itself
    # (which DOES exist) — a fresh, unrelated UUID.
    orphan_tenant_id = Ecto.UUID.generate()
    refute orphan_tenant_id == tenant.id

    assert {:ok, %Group{tenant_id: ^orphan_tenant_id}} =
             Repo.insert(%Group{
               tenant_id: orphan_tenant_id,
               name: "Group #{Ecto.UUID.generate()}"
             })
  end
end
