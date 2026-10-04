defmodule Letflow.IdentityLoginDirectoryConcurrencyTest do
  @moduledoc """
  REQ-435 -- cross-connection behaviour of the login-directory writers (design
  §3.4 / §3.7 / §15.1 "concurrency"): the per-`(tenant_id, email_key)` advisory
  lock plus the `FOR UPDATE` pre-read must make concurrent decisions observe
  each other's outcome.

  The SQL sandbox cannot exercise real cross-connection locking, so this file
  follows `test/letflow/engine_concurrency_test.exs`: `:auto` mode stays in
  effect for the whole test, the tenant and its rows are really committed, every
  "concurrent" step is a `Task.async/1` body on its own pooled connection, and
  `on_exit/1` deletes everything (the directory rows cascade with the tenant).

  Each scenario runs several rounds with a fresh email, because the interleaving
  is not controllable from the test; a correct implementation passes every
  round, and the pre-lock implementation (each writer deciding from its own
  snapshot) loses or leaks an entry in a fraction of rounds.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Test.LoginDirectoryFixture, as: Fx
  alias Letflow.Test.SandboxAutoMode

  @rounds 4

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    %{tenant_id: tenant_id, schema_name: schema_name} =
      Letflow.TenantFixture.provisioned_tenant!(
        slug_prefix: "req435-conc",
        idp_realm_id: Letflow.TenantSlugFixture.unique_realm("req435-conc"),
        teardown: false
      )

    # Runs before exit_auto_mode! (LIFO): cleanup needs real committed access.
    on_exit(fn -> Fx.drop_tenant!(tenant_id) end)

    %{tenant: %{tenant_id: tenant_id, schema_name: schema_name}}
  end

  defp opts(tenant), do: [prefix: tenant.schema_name, tenant_id: tenant.tenant_id]

  defp create!(tenant, email) do
    {:ok, user} =
      Identity.create_user(
        %{
          "username" => "conc-#{System.unique_integer([:positive])}",
          "display_name" => "Conc",
          "email" => email
        },
        opts(tenant)
      )

    user
  end

  defp entry_count(tenant, email) do
    key = Fx.key!(email)
    tenant.tenant_id |> Fx.entries() |> Enum.count(&(&1.email_key == key))
  end

  test "concurrent deactivation of two same-email users ends with the entry removed", %{
    tenant: tenant
  } do
    for round <- 1..@rounds do
      email = "dual-#{round}-#{System.unique_integer([:positive])}@example.test"
      u1 = create!(tenant, email)
      u2 = create!(tenant, email)
      assert entry_count(tenant, email) == 1

      results =
        [u1, u2]
        |> Enum.map(fn u ->
          Task.async(fn -> Identity.update_user_status(u.id, :inactive, opts(tenant)) end)
        end)
        |> Task.await_many(30_000)

      assert [{:ok, _}, {:ok, _}] = results
      assert Repo.get!(User, u1.id, prefix: tenant.schema_name).status == :inactive
      assert Repo.get!(User, u2.id, prefix: tenant.schema_name).status == :inactive
      assert entry_count(tenant, email) == 0, "round #{round}: ghost entry left behind"
    end
  end

  test "concurrent create-versus-deactivate of the same email keeps the entry", %{tenant: tenant} do
    for round <- 1..@rounds do
      email = "cvd-#{round}-#{System.unique_integer([:positive])}@example.test"
      u1 = create!(tenant, email)

      [deactivate, create] =
        [
          Task.async(fn -> Identity.update_user_status(u1.id, :inactive, opts(tenant)) end),
          Task.async(fn ->
            Identity.create_user(
              %{
                "username" => "conc-new-#{System.unique_integer([:positive])}",
                "display_name" => "New",
                "email" => email
              },
              opts(tenant)
            )
          end)
        ]
        |> Task.await_many(30_000)

      assert {:ok, _} = deactivate
      assert {:ok, %User{status: :active}} = create

      assert entry_count(tenant, email) == 1,
             "round #{round}: entry lost while an active user holds the email"
    end
  end

  test "concurrent first logins of the same identity: both succeed, one created, one entry, no aborted transaction",
       %{tenant: tenant} do
    for round <- 1..@rounds do
      ctx = %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: Letflow.TenantSlugFixture.unique_realm("race"),
        roles: [],
        email: "race-#{round}-#{System.unique_integer([:positive])}@example.test",
        preferred_username: "race-#{System.unique_integer([:positive])}",
        display_name: "Racer"
      }

      config = %JitProvisioningConfig{
        realm: "unused",
        enabled: true,
        default_status: :active,
        default_roles: []
      }

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Identity.provision_oidc_user(ctx, tenant.tenant_id, config,
              prefix: tenant.schema_name
            )
          end)
        end)
        |> Task.await_many(30_000)

      assert [{:ok, %{user: u1}}, {:ok, %{user: u2}}] = results
      assert u1.id == u2.id
      assert Enum.count(results, fn {:ok, %{created: created}} -> created end) == 1
      assert entry_count(tenant, ctx.email) == 1
    end
  end
end
