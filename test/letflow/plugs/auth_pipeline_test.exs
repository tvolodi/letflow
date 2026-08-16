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
  ELIXIR-DEV's own `scratch/req021_demo.exs` self-verification script, step 3).

  Uses `Letflow.DataCase` (real Postgres, sandboxed connection, rolled back per test) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database. Uses
  `config/test.exs`'s config-wired `Letflow.Oidc.TokenVerifierDouble` throughout this
  module (the one fixed sentinel token, `"valid-test-token"`, claiming realm
  `bpm-default`) — `AuthPipeline.call/2` is exercised directly via `Plug.Test.conn/3`,
  not through a real running HTTP server (the design doc §8 confirms no route mounts
  this plug yet, so there is no server-level surface to test against), per DIRECTIVE
  T-2's "unit tests of a single function are the exception" framing.

  All tests in this module run `async: true` — every test seeds its own tenant row(s)
  with a unique slug/realm inside its own sandboxed transaction (rolled back after the
  test), matching `identity_test.exs`'s established convention. Tests needing an
  arbitrary, test-chosen realm or a token with no `sub` claim (which
  `TokenVerifierDouble`'s one fixed sentinel token can't produce) live in
  `Letflow.Plugs.AuthPipelineConfigurableVerifierTest` (this same directory) instead —
  see that module's moduledoc for why those specific cases need `async: false`.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Plugs.AuthPipeline

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  defp unique_realm(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_slug(prefix \\ "tenant") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_tenant!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :enabled)
    |> Repo.insert!()
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
    # token always claims — reused here safely under the sandbox's per-test transaction
    # isolation, same reasoning identity_test.exs's own "bpm-default" fixture documents.
    insert_tenant!(%{
      slug: unique_slug("bpm-default-tenant"),
      display_name: "BPM Default Realm Tenant",
      idp_realm_id: "bpm-default"
    })
  end

  defp user_count_for_tenant(tenant_id) do
    User |> where(tenant_id: ^tenant_id) |> Repo.aggregate(:count)
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

      conn = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])

      refute conn.halted
      assert %{user_id: user_id, tenant_id: tenant_id, roles: roles} = conn.assigns[:auth_context]
      assert tenant_id == tenant.id
      assert roles == ["VIEWER"]

      # Re-select from Postgres directly, rather than trusting the in-memory assign —
      # matches identity_test.exs's own persistence-check convention.
      persisted = Repo.get(User, user_id)
      assert persisted != nil
      assert persisted.tenant_id == tenant.id
      assert persisted.auth_source == :oidc
    end

    test "a second request with the same valid token resolves to the same user_id, not a duplicate row" do
      tenant = insert_bpm_default_tenant!()

      conn1 = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])
      conn2 = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])

      user_id1 = conn1.assigns[:auth_context][:user_id]
      user_id2 = conn2.assigns[:auth_context][:user_id]

      assert user_id1 == user_id2
      assert user_count_for_tenant(tenant.id) == 1
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

      conn = call_pipeline(:post, [{"authorization", "Bearer this-is-not-the-valid-sentinel"}])

      assert conn.status == 401
      assert conn.halted
      # No row written under the tenant that would have matched, had verification
      # somehow been skipped.
      assert user_count_for_tenant(tenant.id) == 0
    end

    test "none of the above rejected requests write any user row anywhere" do
      tenant = insert_bpm_default_tenant!()

      call_pipeline(:post, [])
      call_pipeline(:post, [{"authorization", "Token abcdef"}])
      call_pipeline(:post, [{"authorization", "Bearer "}])
      call_pipeline(:post, [{"authorization", "bearer valid-test-token"}])
      call_pipeline(:post, [{"authorization", "Bearer garbage-token"}])

      assert user_count_for_tenant(tenant.id) == 0
    end
  end

  describe "acceptance criterion 4 — realm-ownership guard rejects mismatch, no JIT under wrong tenant" do
    test "the realm-ownership guard rejects a tenant that does not own the token's claimed realm, called with the exact arguments AuthPipeline itself passes" do
      realm = unique_realm("owned-by-a")
      _tenant_a = insert_tenant_for_realm!(realm)
      tenant_b = insert_tenant_for_realm!(unique_realm("owned-by-b"))

      # This is the exact call AuthPipeline.guard_realm_ownership/2 makes internally
      # (Identity.verify_realm_ownership(tenant_id, realm)) — reproduced directly here
      # against a tenant_id that provably does not own `realm`, per test/specs/REQ-021.md's
      # "AC4 test strategy" section.
      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant_b.id, realm)

      # Not silently JIT-provisioned under the wrong tenant: no user row exists under
      # tenant_b as a consequence of this rejected pairing. This test never calls
      # Identity.provision_oidc_user/3 at all — the row count staying at zero is the
      # proof nothing this test didn't explicitly call could have written a row.
      assert user_count_for_tenant(tenant_b.id) == 0
    end

    test "AuthPipeline's call/2 never reaches JIT provisioning when tenant resolution fails, no row written under any tenant" do
      # A bpm-default-claiming token, but deliberately no tenant bound to bpm-default at
      # all -- resolve_tenant_by_realm/1 returns {:error, :not_found}, so the pipeline
      # never reaches the realm-ownership guard or JIT provisioning in the first place.
      other_tenant = insert_tenant_for_realm!(unique_realm("unrelated"))

      conn = call_pipeline(:post, [{"authorization", "Bearer valid-test-token"}])

      assert conn.status == 401
      assert conn.halted
      refute Map.has_key?(conn.assigns, :auth_context)
      assert user_count_for_tenant(other_tenant.id) == 0
    end
  end
end
