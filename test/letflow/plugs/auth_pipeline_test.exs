defmodule Letflow.Plugs.AuthPipelineTest do
  @moduledoc """
  Tests for `Letflow.Plugs.AuthPipeline` (REQ-021). See `test/specs/REQ-021.md` for the
  full test-case rationale, including the "AC4 test strategy" section explaining why
  acceptance criterion 4 (realm-ownership mismatch) is proven via
  `Letflow.Identity.verify_realm_ownership/2` called with the plug's exact argument
  shape, rather than via a full end-to-end plug-level data race — a structural property
  of `AuthPipeline.call/2`'s own `with` chain (both `resolve_tenant_by_realm/1` and
  `verify_realm_ownership/2` key off the identical `idp_realm_id` column for the
  identical `realm` string within one request, so they cannot disagree absent a genuine
  concurrent write racing between the two calls — independently confirmed by
  ELIXIR-DEV's own `scratch/req021_demo.exs` self-verification script, step 3). See
  `test/specs/REQ-063.md` for why this file's fixtures changed.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database. Uses `config/test.exs`'s config-wired
  `Letflow.Oidc.TokenVerifierDouble` throughout this module (the one fixed sentinel
  token, `"valid-test-token"`, claiming realm `bpm-default`) — `AuthPipeline.call/2` is
  exercised directly via `Plug.Test.conn/3`, not through a real running HTTP server
  (the design doc §8 confirms no route mounts this plug yet, so there is no
  server-level surface to test against), per DIRECTIVE T-2's "unit tests of a single
  function are the exception" framing.

  ## REQ-063 fixture change (read before touching a test here)

  REQ-063 (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `users`/`groups`/`tenant_role` out of the `public` schema into each tenant's own
  provisioned Postgres schema. `AuthPipeline.provision_user/3` now derives the
  target schema itself internally, via `TenantProvisioning.schema_name_for_tenant/1`
  on its own already-resolved `tenant_id`, and passes it to
  `Identity.provision_oidc_user/4`'s new `prefix:` opt — so this file's tests do not
  need to pass a prefix themselves (the plug is exercised end to end, black-box, per
  its existing convention), but every tenant this file seeds now needs a REAL,
  provisioned + migrated schema for the plug's internal JIT-provisioning step to
  succeed against, not just a bare `tenants` row. Without that, `provision_user/3`
  would fail (`relation "users" does not exist` under a schema with no tables) —
  exactly the class of failure REQ-063's design §7 item 4 predicted for this file.

  This file follows `test/letflow/identity_test.exs`'s and
  `test/letflow/tenant_provisioning_test.exs`'s established
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` + manual `on_exit/1` cleanup
  pattern (`Ecto.Migrator` cannot run under the sandbox's shared single connection —
  see `lib/letflow/design/req022-tenant-schema-provisioning.md` §6's testing-
  environment caveat, and `identity_test.exs`'s own moduledoc for the fuller
  citation). **This file is now `async: false` for its entire module** (ExUnit's
  `async` setting is module-wide) — unlike its pre-REQ-063 version, which ran
  `async: true` because every tenant it seeded only ever needed a bare `tenants` row
  in `public`. Every `insert_tenant_for_realm!/1`/`insert_bpm_default_tenant!/0` call
  in this file now also provisions and migrates a real tenant schema, cleaned up via
  `on_exit/1`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  defp unique_realm(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_slug(prefix \\ "tenant") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # REQ-063: switches to Sandbox :auto mode FIRST (before inserting the tenant row
  # at all) and provisions a real tenant schema (CREATE SCHEMA + full migration
  # replay, including the three now-tenant-scoped identity tables). Both the
  # `tenants` row and its schema must be created under the SAME connection
  # discipline — inserting the tenant under DataCase's normal rolled-back sandbox
  # transaction first, then switching to :auto for the schema, would leave
  # provision_tenant_schema/1's :auto-mode connection unable to see a tenant row
  # that only exists inside the not-yet-committed (and never-to-be-committed)
  # sandboxed transaction, surfacing as {:error, :tenant_not_found} (confirmed
  # empirically while drafting this file). Mirrors identity_test.exs's/
  # tenant_provisioning_test.exs's/event_store_test.exs's established
  # provisioned_tenant!/1-style helper, cleaned up explicitly in on_exit/1 since
  # :auto-mode state is real, committed Postgres state, not rolled back
  # automatically.
  defp insert_tenant!(attrs) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(attrs, :enabled)
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

  defp insert_tenant_for_realm!(realm) do
    insert_tenant!(%{
      slug: unique_slug(),
      display_name: "Auth Pipeline Test Tenant",
      idp_realm_id: realm
    })
  end

  defp insert_bpm_default_tenant! do
    # "bpm-default" is the one realm Letflow.Oidc.TokenVerifierDouble's fixed sentinel
    # token always claims — reused here safely: every test seeds its own tenant row
    # (and now its own tenant schema) with a unique slug, so concurrently-run tests
    # would not collide even under async — this file no longer runs async purely
    # because of the :auto-mode requirement above, not because of this realm reuse.
    insert_tenant!(%{
      slug: unique_slug("bpm-default-tenant"),
      display_name: "BPM Default Realm Tenant",
      idp_realm_id: "bpm-default"
    })
  end

  defp user_count_for_tenant(tenant_id, schema_name) do
    User |> where(tenant_id: ^tenant_id) |> Repo.aggregate(:count, :id, prefix: schema_name)
  end

  defp call_pipeline(method, headers) do
    conn = conn(method, "/whatever")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        put_req_header(acc, key, value)
      end)

    AuthPipeline.call(conn, AuthPipeline.init([]))
  end

  describe "acceptance criterion 1 — valid token flows through the full pipeline" do
    test "a valid bearer token flows through the full pipeline and attaches user_id/tenant_id/roles to conn.assigns[:auth_context]" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      conn = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])

      refute conn.halted
      assert %{user_id: user_id, tenant_id: tenant_id, roles: roles} = conn.assigns[:auth_context]
      assert tenant_id == tenant.id
      assert roles == ["VIEWER"]

      # Re-select from Postgres directly, rather than trusting the in-memory assign —
      # matches identity_test.exs's own persistence-check convention. Must pass
      # prefix: here per REQ-063 — this row lives in the tenant's own schema now, not
      # public.
      persisted = Repo.get(User, user_id, prefix: schema_name)
      assert persisted != nil
      assert persisted.tenant_id == tenant.id
      assert persisted.auth_source == :oidc
    end

    test "a second request with the same valid token resolves to the same user_id, not a duplicate row" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      conn1 = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])
      conn2 = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])

      user_id1 = conn1.assigns[:auth_context][:user_id]
      user_id2 = conn2.assigns[:auth_context][:user_id]

      assert user_id1 == user_id2
      assert user_count_for_tenant(tenant.id, schema_name) == 1
    end
  end

  describe "acceptance criterion 2 — missing/malformed token rejected before any DB/JIT work" do
    test "no Authorization header at all is rejected 401 before any tenant resolution or provisioning runs" do
      # Deliberately no tenant seeded matching any realm this request could resolve to.
      conn = call_pipeline(:post, [])

      assert conn.status == 401
      assert conn.halted
      assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
    end

    test "a malformed Authorization header (wrong scheme prefix) is rejected 401" do
      conn = call_pipeline(:post, [{"authorization", "Token abcdef"}])

      assert conn.status == 401
      assert conn.halted
    end

    test "an empty token after the Bearer prefix is rejected 401" do
      conn = call_pipeline(:post, [{"authorization", "Bearer "}])

      assert conn.status == 401
      assert conn.halted
    end

    test "a lowercase bearer prefix is rejected 401 (case-sensitive per RFC 6750)" do
      conn = call_pipeline(:post, [{"authorization", "bearer valid-test-token"}])

      assert conn.status == 401
      assert conn.halted
    end

    test "a well-formed but invalid/unverifiable bearer token is rejected 401" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      conn = call_pipeline(:post, [{"authorization", "Bearer this-is-not-the-valid-sentinel"}])

      assert conn.status == 401
      assert conn.halted
      # No row written under the tenant that would have matched, had verification
      # somehow been skipped.
      assert user_count_for_tenant(tenant.id, schema_name) == 0
    end

    test "none of the above rejected requests write any user row anywhere" do
      tenant = insert_bpm_default_tenant!()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

      call_pipeline(:post, [])
      call_pipeline(:post, [{"authorization", "Token abcdef"}])
      call_pipeline(:post, [{"authorization", "Bearer "}])
      call_pipeline(:post, [{"authorization", "bearer valid-test-token"}])
      call_pipeline(:post, [{"authorization", "Bearer garbage-token"}])

      assert user_count_for_tenant(tenant.id, schema_name) == 0
    end
  end

  describe "acceptance criterion 4 — realm-ownership guard rejects mismatch, no JIT under wrong tenant" do
    test "the realm-ownership guard rejects a tenant that does not own the token's claimed realm, called with the exact arguments AuthPipeline itself passes" do
      realm = unique_realm("owned-by-a")
      _tenant_a = insert_tenant_for_realm!(realm)
      tenant_b = insert_tenant_for_realm!(unique_realm("owned-by-b"))
      {:ok, schema_b} = TenantProvisioning.schema_name_for_tenant(tenant_b.id)

      # This is the exact call AuthPipeline.guard_realm_ownership/2 makes internally
      # (Identity.verify_realm_ownership(tenant_id, realm)) — reproduced directly here
      # against a tenant_id that provably does not own `realm`, per test/specs/REQ-021.md's
      # "AC4 test strategy" section.
      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant_b.id, realm)

      # Not silently JIT-provisioned under the wrong tenant: no user row exists under
      # tenant_b as a consequence of this rejected pairing. This test never calls
      # Identity.provision_oidc_user/4 at all — the row count staying at zero is the
      # proof nothing this test didn't explicitly call could have written a row.
      assert user_count_for_tenant(tenant_b.id, schema_b) == 0
    end

    test "AuthPipeline's call/2 never reaches JIT provisioning when tenant resolution fails, no row written under any tenant" do
      # A bpm-default-claiming token, but deliberately no tenant bound to bpm-default at
      # all -- resolve_tenant_by_realm/1 returns {:error, :not_found}, so the pipeline
      # never reaches the realm-ownership guard or JIT provisioning in the first place.
      other_tenant = insert_tenant_for_realm!(unique_realm("unrelated"))
      {:ok, other_schema} = TenantProvisioning.schema_name_for_tenant(other_tenant.id)

      conn = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])

      assert conn.status == 401
      assert conn.halted
      refute Map.has_key?(conn.assigns, :auth_context)
      assert user_count_for_tenant(other_tenant.id, other_schema) == 0
    end
  end
end
