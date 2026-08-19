defmodule Letflow.Plugs.AuthPipelineConfigurableVerifierTest do
  @moduledoc """
  Tests for `Letflow.Plugs.AuthPipeline` (REQ-021) that need
  `Letflow.Oidc.ConfigurableTokenVerifierDouble` (`test/support/`) wired in as the
  request's verifier — the branches `Letflow.Oidc.TokenVerifierDouble`'s one fixed
  sentinel token can't reach: an arbitrary, test-chosen realm (for the
  `:jit_disabled` -> 403 branch, which needs a realm whose
  `config :letflow, :oidc_jit_provisioning` entry is `enabled: false`, distinct from
  `bpm-default`'s `enabled: true`) and a token with no `sub` claim (the
  `:sub_claim_missing` -> 401 branch). See `test/specs/REQ-021.md`'s "Why a second
  double" section for the full reasoning.

  **Deliberately `async: false`, in its own module, separate from
  `Letflow.Plugs.AuthPipelineTest`.** `Letflow.Plugs.AuthPipeline.verify_token/1`
  resolves its verifier module from `Application.fetch_env!(:letflow, :oidc)`, read
  fresh on every call — there is no per-call override, so reaching
  `ConfigurableTokenVerifierDouble` end-to-end through the real plug requires
  temporarily swapping `config :letflow, :oidc`'s `:token_verifier` via
  `Application.put_env/3`. `Application` config is global, process-shared VM state
  (an ETS table, not per-process), so mutating it is only safe when no other test can
  observe the swapped value concurrently — `async: false` guarantees that for this
  module (ExUnit runs `async: false` modules one at a time, never overlapping with any
  `async: true` module's tests, per ExUnit's own scheduling contract). The original
  value is restored via `on_exit/1` even if a test fails, so no other test file (all of
  which run `async: true` and expect `config/test.exs`'s literal
  `Letflow.Oidc.TokenVerifierDouble`) is ever affected.

  **REQ-063 fixture change:** `insert_tenant_for_realm!/1` now also provisions and
  migrates a real tenant schema (`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`
  + `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/2`), not just
  a bare `tenants` row — `users`/`groups`/`tenant_role` moved out of `public` per
  `lib/letflow/design/req063-identity-tables-schema-per-tenant.md`, so
  `AuthPipeline.provision_user/3`'s internal JIT-provisioning step needs somewhere
  real to write. See `test/letflow/plugs/auth_pipeline_test.exs`'s own moduledoc/
  `insert_tenant!/1` comment for the fuller reasoning this file's helper mirrors.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  setup do
    original_oidc_config = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original_oidc_config, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)

    :ok
  end

  defp unique_realm(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_slug(prefix \\ "tenant") do
    Letflow.TenantSlugFixture.unique_slug(prefix)
  end

  # REQ-063: this file was already `async: false` (needed for the global
  # Application-config swap in `setup` above), so it does not itself change
  # async-mode. But it now ALSO needs `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo,
  # :auto)` before inserting the tenant row, per the same reasoning
  # `test/letflow/plugs/auth_pipeline_test.exs`'s own `insert_tenant!/1` comment
  # documents in full: `TenantProvisioning.provision_tenant_schema/1`'s `:auto`-mode
  # connection cannot see a tenant row that only exists inside a not-yet-committed
  # sandboxed transaction, and `Ecto.Migrator` (called by `replay_migrations/2`)
  # cannot run at all under the sandbox's shared single connection. Every tenant
  # this file seeds now needs a real, provisioned + migrated schema, not just a bare
  # `tenants` row, for `AuthPipeline.provision_user/3`'s internal JIT-provisioning
  # step to succeed against.
  defp insert_tenant_for_realm!(realm) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: unique_slug(),
          display_name: "Configurable Verifier Test Tenant",
          idp_realm_id: realm
        },
        :enabled
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

    assert {:ok, %Registration{schema_name: _schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    tenant
  end

  defp user_count_for_tenant(tenant_id) do
    # REQ-064 (Decision 0006 D2) dropped `users.tenant_id` -- the tenant boundary is
    # now the provisioned schema itself (`prefix: schema_name`), so counting all rows
    # in that schema is already tenant-scoped without an extra `where`. Mirrors
    # auth_pipeline_test.exs's identically-adjusted helper.
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    User |> Repo.aggregate(:count, :id, prefix: schema_name)
  end

  defp call_pipeline(method, headers) do
    conn = conn(method, "/whatever")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        put_req_header(acc, key, value)
      end)

    AuthPipeline.call(conn, AuthPipeline.init([]))
  end

  describe "JIT-disabled realm (403, distinct from every 401 case)" do
    test "a token for a realm with JIT provisioning disabled is rejected 403 end-to-end, no user row created" do
      realm = "jit-disabled-test-realm"
      tenant = insert_tenant_for_realm!(realm)

      conn = call_pipeline(:post, [{"authorization", "Bearer realm-token:#{realm}"}])

      assert conn.status == 403
      assert conn.halted
      assert %{"error" => "forbidden"} = Jason.decode!(conn.resp_body)
      assert user_count_for_tenant(tenant.id) == 0
    end
  end

  describe "sub_claim_missing branch (beyond the bare acceptance criteria)" do
    test "a token with no sub claim is rejected 401 end-to-end, no user row created" do
      realm = unique_realm("no-sub-e2e")
      tenant = insert_tenant_for_realm!(realm)

      conn = call_pipeline(:post, [{"authorization", "Bearer no-sub-token:#{realm}"}])

      assert conn.status == 401
      assert conn.halted
      assert user_count_for_tenant(tenant.id) == 0
    end
  end

  describe "arbitrary test-chosen realm (proves the pipeline isn't hardcoded to bpm-default)" do
    test "a realm-token for an arbitrary test-chosen realm still flows through the full pipeline successfully" do
      realm = unique_realm("configurable-happy-path")
      tenant = insert_tenant_for_realm!(realm)

      conn = call_pipeline(:post, [{"authorization", "Bearer realm-token:#{realm}"}])

      refute conn.halted
      assert %{tenant_id: tenant_id} = conn.assigns[:auth_context]
      assert tenant_id == tenant.id
    end
  end
end
