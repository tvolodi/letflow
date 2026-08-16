defmodule Letflow.Oidc.ClaimMappingTest do
  @moduledoc """
  Unit tests for `Letflow.Oidc.ClaimMapping` and `Letflow.Oidc.ClaimMappingConfig`.
  See `test/specs/REQ-017.md` for the full test-case rationale.

  Plain `ExUnit.Case, async: true` — no `Letflow.DataCase`, no
  `Ecto.Adapters.SQL.Sandbox`. `Letflow.Oidc.ClaimMapping.map_verified_claims/3` and
  everything it calls are pure, I/O-free functions (design doc
  `lib/letflow/design/req017-claim-mapping.md` §9); every test below constructs its
  own in-memory `claims`/`config` fixtures and starts no DB connection, which is
  itself evidence for acceptance criterion 1 alongside the direct call-graph
  inspection SECURITY-REVIEWER/REVIEWER already performed.
  """

  use ExUnit.Case, async: true

  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.IdentityContext

  defp base_config(overrides \\ %{}) do
    struct(
      %ClaimMappingConfig{
        realm: "bpm-default",
        tenant_id_claim: "tenant_id",
        roles_claim_paths: ["realm_access.roles", "roles"],
        email_claim: "email",
        preferred_username_claim: "preferred_username",
        display_name_claim: "name"
      },
      overrides
    )
  end

  describe "map_verified_claims/3 — defaulting behavior (acceptance criterion 2)" do
    test "all optional claims missing: every field defaults per Key Invariant 3" do
      config = base_config()

      assert {:ok, %IdentityContext{} = ctx} =
               ClaimMapping.map_verified_claims(config, "user-1", %{"sub" => "user-1"})

      assert ctx.external_user_id == "user-1"
      assert ctx.tenant_id == nil
      assert ctx.realm == "bpm-default"
      assert ctx.roles == []
      assert ctx.email == ""
      assert ctx.preferred_username == "user-1"
      assert ctx.display_name == nil
    end

    test "preferred_username defaults to the subject value, not a blank string" do
      config = base_config()

      assert {:ok, %IdentityContext{preferred_username: "subject-alpha"}} =
               ClaimMapping.map_verified_claims(config, "subject-alpha", %{})

      assert {:ok, %IdentityContext{preferred_username: "subject-beta"}} =
               ClaimMapping.map_verified_claims(config, "subject-beta", %{})
    end

    test "email missing -> \"\"" do
      config = base_config()

      claims = %{
        "tenant_id" => "tenant-1",
        "roles" => ["admin"],
        "preferred_username" => "someone",
        "name" => "Someone"
      }

      assert {:ok, %IdentityContext{email: ""}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "tenant_id missing -> nil" do
      config = base_config()

      claims = %{
        "email" => "someone@example.com",
        "roles" => ["admin"],
        "preferred_username" => "someone",
        "name" => "Someone"
      }

      assert {:ok, %IdentityContext{tenant_id: nil}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "display_name missing -> nil" do
      config = base_config()

      claims = %{
        "email" => "someone@example.com",
        "tenant_id" => "tenant-1",
        "roles" => ["admin"],
        "preferred_username" => "someone"
      }

      assert {:ok, %IdentityContext{display_name: nil}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "roles missing -> []" do
      config = base_config()

      claims = %{
        "email" => "someone@example.com",
        "tenant_id" => "tenant-1",
        "preferred_username" => "someone",
        "name" => "Someone"
      }

      assert {:ok, %IdentityContext{roles: []}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "a present-but-wrong-JSON-type claim value defaults exactly like a missing one, for each of the four string-shaped fields" do
      config = base_config()

      claims = %{
        "email" => 12_345,
        "tenant_id" => ["not", "a", "string"],
        "preferred_username" => %{"nested" => "map"},
        "name" => true
      }

      assert {:ok, ctx} = ClaimMapping.map_verified_claims(config, "user-1", claims)

      assert ctx.email == ""
      assert ctx.tenant_id == nil
      assert ctx.preferred_username == "user-1"
      assert ctx.display_name == nil
    end

    test "combination: some optional fields present, some missing" do
      config = base_config()

      claims = %{
        "email" => "present@example.com",
        "roles" => ["reviewer", "admin"]
        # tenant_id, preferred_username, name (display_name) intentionally absent
      }

      assert {:ok, ctx} = ClaimMapping.map_verified_claims(config, "user-1", claims)

      assert ctx.email == "present@example.com"
      assert ctx.roles == ["reviewer", "admin"]
      assert ctx.tenant_id == nil
      assert ctx.preferred_username == "user-1"
      assert ctx.display_name == nil
    end

    test "all optional claims present with valid values: no defaulting occurs" do
      config = base_config()

      claims = %{
        "email" => "full@example.com",
        "tenant_id" => "tenant-42",
        "roles" => ["approver"],
        "preferred_username" => "full.user",
        "name" => "Full User"
      }

      assert {:ok, ctx} = ClaimMapping.map_verified_claims(config, "user-1", claims)

      assert ctx.email == "full@example.com"
      assert ctx.tenant_id == "tenant-42"
      assert ctx.roles == ["approver"]
      assert ctx.preferred_username == "full.user"
      assert ctx.display_name == "Full User"
    end

    test "realm always comes from config, never from claims, even if claims contains a \"realm\" key" do
      config = base_config(%{realm: "bpm-default"})

      claims = %{"realm" => "attacker-supplied"}

      assert {:ok, %IdentityContext{realm: "bpm-default"}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end
  end

  describe "resolve_roles/2 short-circuit behavior" do
    test "first configured roles path that resolves to a list wins" do
      config = base_config(%{roles_claim_paths: ["realm_access.roles", "roles"]})

      claims = %{
        "realm_access" => %{"roles" => ["from-realm-access"]},
        "roles" => ["from-top-level"]
      }

      assert {:ok, %IdentityContext{roles: ["from-realm-access"]}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "a path that resolves to a non-list value is skipped, not treated as an error or a match" do
      config = base_config(%{roles_claim_paths: ["realm_access.roles", "roles"]})

      claims = %{
        # wrong type at the first configured path — not a list
        "realm_access" => %{"roles" => "not-a-list"},
        "roles" => ["from-top-level"]
      }

      assert {:ok, %IdentityContext{roles: ["from-top-level"]}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "no configured path resolves to a list at all -> []" do
      config = base_config(%{roles_claim_paths: ["realm_access.roles", "roles"]})

      claims = %{
        "realm_access" => %{"roles" => "not-a-list"}
        # "roles" absent entirely
      }

      assert {:ok, %IdentityContext{roles: []}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)
    end

    test "non-string elements inside a matched roles array become empty strings, array length preserved" do
      config = base_config(%{roles_claim_paths: ["roles"]})

      claims = %{"roles" => ["admin", 42, "user", nil, %{}]}

      assert {:ok, %IdentityContext{roles: roles}} =
               ClaimMapping.map_verified_claims(config, "user-1", claims)

      assert roles == ["admin", "", "user", "", ""]
      assert length(roles) == 5
    end
  end

  describe "map_verified_claims/3 — sub-missing error case (acceptance criterion 3)" do
    test "nil subject returns {:error, :sub_claim_missing}" do
      config = base_config()

      claims = %{
        "email" => "someone@example.com",
        "tenant_id" => "tenant-1",
        "roles" => ["admin"],
        "preferred_username" => "someone",
        "name" => "Someone"
      }

      assert {:error, :sub_claim_missing} = ClaimMapping.map_verified_claims(config, nil, claims)
    end

    test "empty-string subject returns {:error, :sub_claim_missing}" do
      config = base_config()

      claims = %{
        "email" => "someone@example.com",
        "tenant_id" => "tenant-1",
        "roles" => ["admin"],
        "preferred_username" => "someone",
        "name" => "Someone"
      }

      assert {:error, :sub_claim_missing} = ClaimMapping.map_verified_claims(config, "", claims)
    end

    test "a present, non-empty subject never triggers sub_claim_missing, even when every other claim is absent" do
      config = base_config()

      assert {:ok, %IdentityContext{}} =
               ClaimMapping.map_verified_claims(config, "real-subject", %{})
    end
  end

  describe "resolve_claim_path/2 — path resolution" do
    test "single-segment path resolves a top-level key" do
      assert ClaimMapping.resolve_claim_path(%{"email" => "a@b.com"}, "email") == "a@b.com"
    end

    test "multi-segment dotted path resolves a nested value" do
      claims = %{"realm_access" => %{"roles" => ["admin", "user"]}}

      assert ClaimMapping.resolve_claim_path(claims, "realm_access.roles") == ["admin", "user"]
    end

    test "a path that hits a non-map value partway through resolves to nil, does not raise" do
      claims = %{"a" => %{"b" => "not-a-map"}}

      assert ClaimMapping.resolve_claim_path(claims, "a.b.c") == nil
    end

    test "a completely absent top-level path resolves to nil" do
      assert ClaimMapping.resolve_claim_path(%{"other" => "value"}, "missing") == nil
    end

    test "an absent nested path (parent map exists, child key doesn't) resolves to nil" do
      claims = %{"realm_access" => %{"other_key" => "value"}}

      assert ClaimMapping.resolve_claim_path(claims, "realm_access.roles") == nil
    end
  end

  describe "ClaimMappingConfig.for_realm/1 / default/1" do
    test "for_realm/1 returns the configured entry for a realm present in application config" do
      config = ClaimMappingConfig.for_realm("bpm-default")

      assert config.realm == "bpm-default"
      assert config.tenant_id_claim == "tenant_id"
      assert config.roles_claim_paths == ["realm_access.roles", "roles"]
      assert config.email_claim == "email"
      assert config.preferred_username_claim == "preferred_username"
      assert config.display_name_claim == "name"
    end

    test "for_realm/1 falls back to default/1 for a realm with no config entry" do
      assert ClaimMappingConfig.for_realm("unconfigured-realm") ==
               ClaimMappingConfig.default("unconfigured-realm")
    end

    test "default/1 threads the given realm into the returned struct's realm field, not Zig's literal empty string" do
      assert ClaimMappingConfig.default("some-realm").realm == "some-realm"
      assert ClaimMappingConfig.default("other-realm").realm == "other-realm"
    end
  end
end
