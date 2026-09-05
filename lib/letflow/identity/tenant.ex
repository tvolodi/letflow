defmodule Letflow.Identity.Tenant do
  @moduledoc """
  Ecto schema for the `tenants` table. Ported from R-Co
  `src/design/adp-04b-tenant-realm-binding.md` ("Data model and
  migration/backfill semantics", "Core types" `Tenant` struct, "Key
  invariants" 1-2).

  PROVENANCE (historical, not current decision authority):
  `status` distinguishes `:active` from `:migrating` from `:inactive` —
  `:migrating` is the concrete write-pause state R-Co's
  `src/api/middleware/tenant_status.zig` checks before allowing a mutating
  request through (see REQ-021); `:inactive` (REQ-075) is the broader
  deactivation state `Letflow.Plugs.TenantStatus` rejects on **every** HTTP
  method (not just writes) for any non-`PLATFORM_ADMIN` caller — see that
  module's moduledoc, and `docs/migration/stage-4-api-surface.md`'s
  2026-08-22 (REQ-075) REVIEWER sign-off entry for the exact authorized
  shape. Only `Letflow.Identity.deactivate_tenant/1` and
  `Letflow.Identity.reactivate_tenant/1` (via `status_changeset/2` below)
  ever write `:inactive`/`:active` through this path — `PATCH
  /tenants/:slug` cannot, structurally (see `admin_patch_changeset/2`'s
  @doc).

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

  ## Changesets (REQ-019)

  `create_changeset/3` and `update_changeset/2` implement
  `lib/letflow/design/req019-tenant-realm-binding.md` §3.

  **`idp_realm_id` is immutable after creation.** This is enforced
  structurally, not by a runtime rejection check: `update_changeset/2`'s
  `cast/3` field list simply does not include `:idp_realm_id`, so there is no
  field in that changeset's allowed inputs that could ever carry a value into
  it — an attempted change to it via `update_changeset/2` produces no change
  at all (not a validation error), because the field was never cast in the
  first place.

  **No dedicated admin-only rotation function exists in this module.** R-Co's
  own `adp-04b-tenant-realm-binding.md` leaves realm-rotation policy as its
  own unresolved open question (OQ-1: strict immutability vs. a
  dedicated admin operation); REQ-019's acceptance criteria do not ask for
  one, and no other requirement in this codebase currently needs one. So
  `idp_realm_id`, once set at creation, has no code path anywhere in this
  module that can change it again — see the design doc §3.1 for the full
  reasoning.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenants" do
    field(:slug, :string)
    field(:display_name, :string)
    field(:status, Ecto.Enum, values: [:active, :migrating, :inactive], default: :active)
    field(:idp_realm_id, :string)

    timestamps()
  end

  @default_tenant_slug "bpm-default"

  @doc """
  Changeset for creating a new tenant. `oidc_mode` (`:enabled` or
  `:disabled`) is caller-resolved and passed in explicitly — this changeset
  does not read OIDC-enabled state from `Application` config itself, since no
  config key for a global OIDC-enabled/disabled toggle currently exists (see
  `lib/letflow/design/req019-tenant-realm-binding.md` §8 OQ-1). When
  `oidc_mode == :enabled` and the tenant being created is not the default
  tenant (`slug != "bpm-default"`), `idp_realm_id` is required. Otherwise it
  remains optional (nullable at the column level regardless).

  The default tenant (`slug == "bpm-default"`) is additionally pinned:
  its `idp_realm_id` must equal exactly `"bpm-default"`.
  """
  @spec create_changeset(t :: %__MODULE__{}, attrs :: map(), oidc_mode :: :enabled | :disabled) ::
          Ecto.Changeset.t()
  def create_changeset(tenant, attrs, oidc_mode) when oidc_mode in [:enabled, :disabled] do
    tenant
    |> cast(attrs, [:slug, :display_name, :status, :idp_realm_id])
    |> validate_required([:slug, :display_name])
    |> validate_default_tenant_pinning()
    |> validate_idp_realm_id_required(oidc_mode)
    |> unique_constraint(:slug)
    |> unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)
  end

  @doc """
  Changeset for updating an existing tenant. Only `:display_name` and
  `:status` are castable — `:slug` and `:idp_realm_id` are both structurally
  absent from this changeset's allowed fields, so neither can ever be
  changed via this path. `:idp_realm_id`'s absence is the immutability
  invariant (see moduledoc); `:slug`'s absence is this module's own
  conservative default (not a cited REQ-019 requirement — see the design
  doc §8 OQ-2).
  """
  @spec update_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:display_name, :status])
    |> validate_required([:display_name])
    |> unique_constraint(:slug)
  end

  @doc """
  Changeset for `PATCH /tenants/:slug` (REQ-075) — casts **only**
  `:display_name`. `:status` is deliberately absent from this changeset's
  cast list (a real, flagged divergence from `update_changeset/2`'s cast
  list, which includes `:status` — see
  `lib/letflow/design/req075-tenant-administration-routes.md` §6.4): this is
  what makes it structurally impossible for `PATCH /tenants/:slug` to ever
  flip a tenant's `:status`, so `deactivate_tenant/1`/`reactivate_tenant/1`
  (via `status_changeset/2`) remain the only two writers of that field. `:slug`
  and `:idp_realm_id` are absent for the same reason `update_changeset/2`
  excludes them (immutability).
  """
  @spec admin_patch_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def admin_patch_changeset(tenant, attrs) do
    cast(tenant, attrs, [:display_name])
  end

  @doc """
  Changeset for `POST /tenants/:slug/deactivate` and `POST
  /tenants/:slug/reactivate` (REQ-075) — casts **only** `:status`. Mirrors
  `admin_patch_changeset/2`'s structural-impossibility discipline in the
  other direction: this changeset cannot ever touch `:display_name`.
  """
  @spec status_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def status_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:status])
    |> validate_required([:status])
  end

  defp validate_default_tenant_pinning(changeset) do
    if get_field(changeset, :slug) == @default_tenant_slug do
      validate_change(changeset, :idp_realm_id, fn :idp_realm_id, idp_realm_id ->
        if idp_realm_id == @default_tenant_slug do
          []
        else
          [idp_realm_id: "must equal \"#{@default_tenant_slug}\" for the default tenant"]
        end
      end)
      |> validate_required([:idp_realm_id])
    else
      changeset
    end
  end

  defp validate_idp_realm_id_required(changeset, :enabled) do
    if get_field(changeset, :slug) == @default_tenant_slug do
      changeset
    else
      validate_required(changeset, [:idp_realm_id])
    end
  end

  defp validate_idp_realm_id_required(changeset, :disabled), do: changeset
end
