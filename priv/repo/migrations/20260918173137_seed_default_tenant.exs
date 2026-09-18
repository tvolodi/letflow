# Letflow.Repo.Migrations.SeedDefaultTenant
#
# REQ-370 (design req370-multi-issuer-oidc-verification.md §10): the tenants
# table becomes the SOLE source of verification trust once this requirement's
# TokenVerifier/ProviderRegistry changes ship. req019-tenant-realm-binding.md's
# own OQ-3 already flagged that no priv/repo/seeds.exs and no real
# default-tenant row exists anywhere in this codebase today -- without a real
# tenants row bound to idp_realm_id = "bpm-default" in every deployed
# environment, the new trust gate would reject EVERY currently-working login
# (including PLATFORM_ADMIN's own) the moment this ships.
#
# Idempotent by construction (ON CONFLICT (slug) DO NOTHING): safe to run
# against an environment that may already have a bpm-default tenant row (e.g.
# QA, per ISS-0690's own live evidence that GET /tenants already lists
# tenants there) as well as one that doesn't (a fresh dev/prod DB). Safe to
# run twice in a row.
#
# This migration must run and be verified BEFORE this requirement's own
# TokenVerifier/ProviderRegistry changes are considered safe to deploy to any
# shared environment.
defmodule Letflow.Repo.Migrations.SeedDefaultTenant do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO tenants (id, slug, display_name, status, idp_realm_id, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'bpm-default', 'Default Tenant', 'active', 'bpm-default', NOW(), NOW())
    ON CONFLICT (slug) DO NOTHING
    """)
  end

  def down do
    execute("""
    DELETE FROM tenants WHERE slug = 'bpm-default' AND idp_realm_id = 'bpm-default'
    """)
  end
end
