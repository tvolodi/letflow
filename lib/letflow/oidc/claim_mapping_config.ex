defmodule Letflow.Oidc.ClaimMappingConfig do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Per-realm configuration for `Letflow.Oidc.ClaimMapping` — which claim path
  (dot-delimited) supplies each `Letflow.Oidc.IdentityContext` field. Ported
  from `src/oidc/claim_mapping.zig`'s `ClaimMappingConfig` struct (lines
  55-62) and its `DEFAULT_CLAIM_MAPPING_CONFIG` constant (lines 87-95).

  Sourced from application config (`config :letflow, :oidc_claim_mapping`,
  a map keyed by realm string — see `config/dev.exs`/`config/test.exs`) for
  now, per REQ-017's own scope note: no DB-backed per-realm config table
  (Zig's `loadClaimMappingConfig`/`ClaimMappingError`) is built here. This is
  a distinct config key from `config :letflow, :oidc` (REQ-016's
  provider-worker-startup config, consumed by `Letflow.Application`) — kept
  separate deliberately, not nested under `:oidc`, so the two concerns
  (provider startup vs. claim-path mapping) don't get conflated.

  `for_realm/1` performs a config read (`Application.fetch_env!/2`), which is
  not I/O in the DB/network sense (compiled-in application config), but it is
  *not* part of `Letflow.Oidc.ClaimMapping.map_verified_claims/3`'s own call
  graph — callers resolve a `ClaimMappingConfig` via `for_realm/1` (or build
  one directly, e.g. in tests) and pass the already-resolved struct in. See
  `lib/letflow/design/req017-claim-mapping.md` §4 and §9.
  """

  @enforce_keys [
    :realm,
    :tenant_id_claim,
    :roles_claim_paths,
    :email_claim,
    :preferred_username_claim,
    :display_name_claim
  ]
  defstruct [
    :realm,
    :tenant_id_claim,
    :roles_claim_paths,
    :email_claim,
    :preferred_username_claim,
    :display_name_claim
  ]

  @type t :: %__MODULE__{
          realm: String.t(),
          tenant_id_claim: String.t(),
          roles_claim_paths: [String.t()],
          email_claim: String.t(),
          preferred_username_claim: String.t(),
          display_name_claim: String.t()
        }

  @doc """
  Looks up `realm` in `config :letflow, :oidc_claim_mapping`. Returns a
  `ClaimMappingConfig` built from that realm's configured claim paths if
  present, otherwise falls back to `default/1`.
  """
  @spec for_realm(realm :: String.t()) :: t()
  def for_realm(realm) when is_binary(realm) do
    config_by_realm = Application.fetch_env!(:letflow, :oidc_claim_mapping)

    case Map.fetch(config_by_realm, realm) do
      {:ok, entry} ->
        %__MODULE__{
          realm: realm,
          tenant_id_claim: entry.tenant_id_claim,
          roles_claim_paths: entry.roles_claim_paths,
          email_claim: entry.email_claim,
          preferred_username_claim: entry.preferred_username_claim,
          display_name_claim: entry.display_name_claim
        }

      :error ->
        default(realm)
    end
  end

  @doc """
  The hardcoded default claim-path config, mirroring Zig's
  `DEFAULT_CLAIM_MAPPING_CONFIG` (lines 87-95) — with one deliberate
  deviation: `realm` is taken as an argument and threaded into the returned
  struct rather than hardcoded to Zig's literal `""`, since Elixir's caller
  (`for_realm/1`) always knows the realm being looked up. See
  `lib/letflow/design/req017-claim-mapping.md` §4.1 (OQ-1).

  Pure — no config read, no I/O. Usable directly by tests and by
  `for_realm/1`'s fallback branch alike.
  """
  @spec default(realm :: String.t()) :: t()
  def default(realm) when is_binary(realm) do
    %__MODULE__{
      realm: realm,
      tenant_id_claim: "tenant_id",
      roles_claim_paths: ["realm_access.roles", "roles"],
      email_claim: "email",
      preferred_username_claim: "preferred_username",
      display_name_claim: "name"
    }
  end
end
