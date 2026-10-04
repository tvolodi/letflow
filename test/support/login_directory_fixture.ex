defmodule Letflow.Test.LoginDirectoryFixture do
  @moduledoc """
  Shared fixture for the REQ-435 login-directory tests (test-only; never
  referenced from `lib/`).

  `tenant!/1` provisions a real tenant schema bound to a unique `idp_realm_id`
  (so `Letflow.LoginDirectory.lookup_by_key/1` can find it), using the same
  `SandboxAutoMode.provision!/2` + explicit cleanup shape as
  `test/letflow/audit_dispositions_test.exs`: provisioning commits real state in
  `:auto` mode, the test body then runs in a dedicated rolled-back sandbox
  checkout, and `on_exit/1` drops the schema and rows. Directory rows written
  by a test therefore roll back with it, and a `DROP TABLE` inside a test is
  reverted too.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @type tenant :: %{tenant_id: Ecto.UUID.t(), schema_name: String.t()}

  @doc """
  Provisions one tenant. Options: `:slug_prefix`, `:display_name`,
  `:idp_realm_id` (default a unique realm; `:none` for unbound).

  IMPORTANT: every call re-enters `:auto` mode and takes a fresh sandbox
  checkout, which discards any uncommitted writes the test made before it.
  Provision ALL tenants first, then write.
  """
  @spec tenant!(keyword()) :: tenant()
  def tenant!(opts \\ []) do
    realm =
      case Keyword.get(opts, :idp_realm_id, :unique) do
        :unique -> Letflow.TenantSlugFixture.unique_realm("req435")
        :none -> nil
        other -> other
      end

    %{tenant_id: tenant_id, schema_name: schema_name} =
      SandboxAutoMode.provision!(Repo, fn ->
        fixture =
          TenantFixture.provisioned_tenant!(
            slug_prefix: Keyword.get(opts, :slug_prefix, "req435"),
            display_name: Keyword.get(opts, :display_name, "REQ-435 Tenant"),
            idp_realm_id: realm,
            teardown: false
          )

        on_exit(fn ->
          Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
          drop_tenant!(fixture.tenant_id)
          SandboxAutoMode.exit_auto_mode!(Repo)
        end)

        fixture
      end)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  @doc """
  Sets a tenant's status inside the test's sandbox (rolled back with it). Call
  only after every `tenant!/1` call of the test (see its note).
  """
  @spec set_status!(tenant(), :active | :inactive | :migrating) :: :ok
  def set_status!(%{tenant_id: tenant_id}, status) do
    {1, _} =
      Repo.update_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id),
        set: [status: status]
      )

    :ok
  end

  @doc "Deletes a tenant's directory rows, schema, registration and tenant row (committed cleanup)."
  @spec drop_tenant!(Ecto.UUID.t()) :: :ok
  def drop_tenant!(tenant_id) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      {:error, :invalid_tenant_id} -> :ok
    end

    Repo.delete_all(from(d in TenantLoginDirectoryEntry, where: d.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id))
    :ok
  end

  @doc "All directory rows of `tenant_id` (bypasses the context under test)."
  @spec entries(Ecto.UUID.t()) :: [TenantLoginDirectoryEntry.t()]
  def entries(tenant_id) do
    Repo.all(from(d in TenantLoginDirectoryEntry, where: d.tenant_id == ^tenant_id))
  end

  @doc "Keyed-hash of `email` or raises (the test pepper is always configured)."
  @spec key!(String.t()) :: binary()
  def key!(email) do
    {:ok, key} = Letflow.LoginDirectory.email_key(email)
    key
  end

  @doc "Count of `users` rows in a tenant schema."
  @spec user_count(String.t()) :: non_neg_integer()
  def user_count(schema_name) do
    Repo.aggregate(Letflow.Identity.User, :count, prefix: schema_name)
  end

  @doc "A unique, valid email address."
  @spec unique_email(String.t()) :: String.t()
  def unique_email(prefix \\ "u") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}@example.test"
  end
end
