defmodule Letflow.Oidc.Iss0778PlatformAdminTokenVerifierDouble do
  @moduledoc """
  Test-only `Letflow.Oidc.TokenVerifier` implementation, sibling to
  `Letflow.Oidc.TokenVerifierDouble` and `Letflow.Oidc.Iss0736RoleClaimTokenVerifierDouble`
  (neither of which this module replaces or mutates — `config/test.exs` keeps wiring
  `Letflow.Oidc.TokenVerifierDouble` in as the suite-wide default; this double is only
  ever activated locally, per-test, via a scoped `Application.put_env/3` swap with a
  restore, same mechanism `test/letflow/plugs/iss0736_oidc_live_revocation_test.exs`'s
  `use_role_claim_token_verifier!/0` already establishes for the identical reason).

  Built for `test/letflow/plugs/iss0778_platform_role_seeding_e2e_test.exs`'s ISS-0778
  T4 end-to-end proof (`lib/letflow/design/iss-0778-platform-role-seeding.md` §5/§6):
  neither existing double can claim `PLATFORM_ADMIN` — `TokenVerifierDouble` hardcodes
  `["VIEWER"]`, and `Iss0736RoleClaimTokenVerifierDouble` hardcodes `["PROCESS_OPERATOR"]`
  — so T4 needs its own sentinel claiming `PLATFORM_ADMIN` to prove a freshly-onboarded
  tenant's admin user can authenticate and reach a PLATFORM_ADMIN-gated route via the
  real, unmodified OIDC JIT-sync path (T2's mechanism), with zero manual
  `Letflow.Identity`/`Letflow.Identity.RoleRegistry` bootstrap in the test itself.

  Realm `bpm-default` — same fixed realm both sibling doubles use — matching this
  design's own resolution of the open question (design §6, "Fixture mechanics for T4's
  non-bpm-default tenant realm"): `POST /api/v1/onboarding`'s own `@create_schema`
  accepts no `idp_realm_id` field at all (confirmed by direct read,
  `lib/letflow/routers/onboarding.ex`), and `Letflow.Identity.Tenant.update_changeset/2`
  structurally excludes `:idp_realm_id` from its cast list (immutable after creation,
  by design — see that schema's own moduledoc) — so no *supported* path exists to bind
  a fresh, non-default realm to an onboarding-created tenant at all. T4 therefore
  reuses `Letflow.Support.BpmDefaultRealmDisplacement` to take exclusive, test-owned
  control of the one realm (`"bpm-default"`) the test double roster already recognizes,
  then binds the freshly-onboarded tenant to it directly via `Repo.update_all/2` (a
  raw, changeset-bypassing write — the only way to set `idp_realm_id` post-creation at
  all, given the immutability above) as this test's own stand-in for the out-of-band
  IdP-realm-configuration step a real deployment's operator would perform once a new
  tenant is provisioned (explicitly out of this codebase's scope per the design's §1/§4
  — "The IdP-side configuration that decides which real human ends up with a token...
  remains entirely out of this codebase's scope").

  Recognizes one fixed sentinel raw token, deliberately distinct from every other
  double's sentinel so a stray `Bearer` header from a copied helper can never
  accidentally cross-activate this claims shape under the wrong double:

    * `"iss0778-platform-admin-token"` → `{:ok, claims}`, realm `bpm-default`, fixed
      subject `"iss0778-platform-admin-subject"` (one subject only, matching both
      sibling doubles' own "not parameterized by token suffix" precedent), claiming
      exactly one role: `"PLATFORM_ADMIN"`.
    * any other value → `{:error, :invalid_test_token}`, matching every sibling
      double's behavior for the same case.
  """

  @behaviour Letflow.Oidc.TokenVerifier

  @valid_token "iss0778-platform-admin-token"

  @valid_claims %{
    "iss" => "https://placeholder-keycloak.invalid/realms/bpm-default",
    "sub" => "iss0778-platform-admin-subject",
    "email" => "iss0778-platform-admin-subject@example.com",
    "preferred_username" => "iss0778-platform-admin-subject",
    "name" => "ISS-0778 Platform Admin E2E Test User",
    "realm_access" => %{"roles" => ["PLATFORM_ADMIN"]}
  }

  @impl Letflow.Oidc.TokenVerifier
  def verify_bearer_token(@valid_token), do: {:ok, @valid_claims}
  def verify_bearer_token(_other_token), do: {:error, :invalid_test_token}
end
