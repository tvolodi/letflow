defmodule Letflow.Identity.Tenant do
  @moduledoc """
  Ecto schema for the `tenants` table. Ported from R-Co
  `src/design/adp-04b-tenant-realm-binding.md` ("Data model and
  migration/backfill semantics", "Core types" `Tenant` struct, "Key
  invariants" 1-2).

  `status` distinguishes `:active` from `:migrating` — the latter is the
  concrete write-pause state R-Co's `src/api/middleware/tenant_status.zig`
  checks before allowing a mutating request through (see REQ-021).

  `idp_realm_id` is nullable at the column level. adp-04b's own forward
  constraint ("non-default tenant insert requires non-empty idp_realm_id")
  is conditional on runtime OIDC-mode config, which a migration-time CHECK
  constraint cannot see — it is enforced as an application-level (changeset)
  invariant in REQ-019, not here. Its uniqueness (when present) is a
  partial unique index (`tenants_idp_realm_id_partial_index`, see the
  `CreateTenants` migration), resolving adp-04b's own Open Question OQ-2
  explicitly in favor of partial.

  This schema targets Ecto's single default schema — schema-per-tenant
  provisioning (Decision B,
  `docs/migration/decisions/0003-ecto-schema-strategy.md`) is deferred, see
  `lib/letflow/design/identity-schema.md` section 1.

  No changeset function is defined here — tenant create/update changesets
  (including the idp_realm_id-required-for-non-default-tenant rule) belong
  to REQ-019.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenants" do
    field(:slug, :string)
    field(:display_name, :string)
    field(:status, Ecto.Enum, values: [:active, :migrating], default: :active)
    field(:idp_realm_id, :string)

    timestamps()
  end
end
