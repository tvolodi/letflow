defmodule Letflow.Support.TenantAdminMigrationFixture do
  @moduledoc """
  Test-only fixtures shared by the REQ-447 migration tests
  (`test/letflow/identity/tenant_admin_migration_test.exs` and
  `test/mix/tasks/letflow.migrate_tenant_admins_test.exs`): provisioned tenants in the legacy
  `PLATFORM_ADMIN` state, the operator (platform) tenant pinned for the test, registration
  isolation, and a row snapshot used to prove that a refused or dry run wrote nothing.

  Every function is called from the test process. The tenant fixture switches the sandbox to
  `:auto` mode, so these writes are committed and cleaned up by the fixture teardown (and by
  `isolate_registrations!/1`'s `on_exit`).
  """

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.TenantSlugFixture

  # A provisioned tenant with a unique realm; `.slug` and `.realm` are convenience keys.
  def tenant!(prefix) do
    realm = TenantSlugFixture.unique_realm("req447-realm")
    fx = TenantFixture.provisioned_tenant!(slug_prefix: prefix, idp_realm_id: realm)
    Map.merge(fx, %{slug: fx.tenant.slug, realm: realm})
  end

  def new_user!(schema) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "pii-username-#{n}",
      display_name: "Pii Person #{n}",
      email: "pii-email-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  def group!(schema, name) do
    {:ok, %Group{} = group} = RoleRegistry.get_or_create_group_by_name(name, prefix: schema)
    group
  end

  def bind!(schema, name, kind, group) do
    {:ok, %TenantRole{} = role} = RoleRegistry.upsert_role(name, kind, group.id, prefix: schema)
    role
  end

  def member!(schema, group, user) do
    Repo.insert!(%GroupMember{group_id: group.id, user_id: user.id}, prefix: schema)
    user
  end

  def token!(schema, user, roles) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      %ApiToken{
        user_id: user.id,
        name: "token-#{n}",
        token_hash: "hash-#{n}-" <> Ecto.UUID.generate(),
        roles: roles,
        expires_at:
          DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:second)
      },
      prefix: schema
    )
  end

  # The legacy state of a tenant: a PLATFORM_ADMIN group, its binding, and `count` members.
  def legacy!(fx, count) do
    group = group!(fx.schema_name, "PLATFORM_ADMIN")
    bind!(fx.schema_name, "PLATFORM_ADMIN", :platform_role, group)
    users = for _ <- 1..count//1, do: member!(fx.schema_name, group, new_user!(fx.schema_name))
    %{group: group, users: users}
  end

  # The operator tenant (P): pinned, with one legacy operator.
  # The sweep reads EVERY registered tenant. The test database can hold a committed leftover (a
  # throwaway template-build registration) that always fails the sweep. The fixture switches the
  # sandbox to :auto mode (writes are committed, cleaned by its own teardown), so this removes the
  # other registrations for the duration of the test and puts them back in `on_exit`: every report,
  # the task's exit status and a subprocess all see only this test's tenants.
  def isolate_registrations!(keep) do
    others =
      Repo.all(
        from(r in Registration,
          where: r.tenant_id != ^keep.tenant_id,
          select: %{
            id: r.id,
            tenant_id: r.tenant_id,
            schema_name: r.schema_name,
            migrations_applied_at: r.migrations_applied_at,
            provisioned_at: r.provisioned_at
          }
        )
      )

    ids = Enum.map(others, & &1.id)
    Repo.delete_all(from(r in Registration, where: r.id in ^ids))

    ExUnit.Callbacks.on_exit(fn ->
      Repo.insert_all(Registration, others, on_conflict: :nothing)
    end)

    :ok
  end

  def operator_tenant! do
    p = tenant!("req447-op")
    isolate_registrations!(p)
    legacy!(p, 1)
    Fixture.pin!(p.tenant_id)
    p
  end

  def good_opts(p), do: [platform_tenant_slug: p.slug, expected_realm_id: p.realm]

  def snapshot(fixtures) do
    Map.new(fixtures, fn %{schema_name: s} ->
      {s,
       %{
         groups: Repo.all(from(g in Group, order_by: g.id, select: {g.id, g.name}), prefix: s),
         members:
           Repo.all(
             from(m in GroupMember,
               order_by: [m.group_id, m.user_id],
               select: {m.group_id, m.user_id}
             ),
             prefix: s
           ),
         roles:
           Repo.all(
             from(r in TenantRole, order_by: r.id, select: {r.id, r.name, r.kind, r.group_id}),
             prefix: s
           ),
         tokens:
           Repo.all(
             from(t in ApiToken,
               order_by: t.id,
               select:
                 {t.id, t.token_hash, t.roles, t.name, t.user_id, t.expires_at, t.revoked_at,
                  t.last_used_at}
             ),
             prefix: s
           ),
         audit: Repo.all(from(e in Entry, order_by: e.id, select: {e.id, e.action}), prefix: s)
       }}
    end)
  end
end
