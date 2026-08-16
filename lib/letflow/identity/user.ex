defmodule Letflow.Identity.User do
  @moduledoc """
  Ecto schema for the `users` table. Ported from R-Co
  `src/design/adp-04-user-tenant-binding.md` ("Data model and
  migration/backfill semantics", "Index and constraint guidance") and
  `src/design/adp-04a-external-identity-linkage-user.md` ("Data model and
  migration/backfill semantics", "Unique index semantics", "Key
  invariants").

  `tenant_id` is an intra-schema column per Decision B
  (`docs/migration/decisions/0003-ecto-schema-strategy.md`) — it carries no
  database-level foreign key to `tenants.id` (see the `CreateUsers`
  migration's header comment for the full rationale).

  `auth_source`-vs-external-fields consistency (adp-04a's rule 2:
  `auth_source: :oidc` requires both `external_id`/`external_realm`
  non-null; `auth_source: :internal` requires both null) is an
  application-level (changeset) invariant, implemented in REQ-018/REQ-019 —
  it is NOT enforced by this schema module or by a DB-level CHECK
  constraint in the migration.

  `jit_changeset/2` (below) is REQ-018's JIT-provisioning insert changeset —
  the first changeset function defined on this schema. REQ-019 (tenant-scoped
  user operations, not yet implemented) owns any further changeset function
  this module eventually needs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "users" do
    field(:tenant_id, Ecto.UUID)
    field(:username, :string)
    field(:display_name, :string)
    field(:email, :string)
    field(:password_hash, :string)
    field(:status, Ecto.Enum, values: [:active, :inactive], default: :active)
    field(:auth_source, Ecto.Enum, values: [:internal, :oidc], default: :internal)
    field(:external_id, :string)
    field(:external_realm, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds the insert changeset for a JIT-provisioned (OIDC) user, per
  `lib/letflow/design/req018-jit-provisioning.md` §4/§5. `tenant_id`,
  `external_realm`, `external_id`, `username`, `display_name`, and `email` are
  populated from the caller-supplied `attrs` map (built by
  `Letflow.Identity.provision_oidc_user/3` from its `IdentityContext` and
  `tenant_id` arguments — never taken directly from raw external input by this
  function). `password_hash` and `auth_source` are fixed, changeset-internal
  values — set unconditionally below, never accepted from `attrs`, so no
  caller can override them.
  """
  @spec jit_changeset(t(), map()) :: Ecto.Changeset.t()
  def jit_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [
      :tenant_id,
      :external_realm,
      :external_id,
      :username,
      :display_name,
      :email,
      :status
    ])
    |> validate_required([
      :tenant_id,
      :external_realm,
      :external_id,
      :username,
      :display_name,
      :email,
      :status
    ])
    |> put_change(:password_hash, "__OIDC_ONLY__")
    |> put_change(:auth_source, :oidc)
    |> unique_constraint(:username)
    |> unique_constraint([:external_realm, :external_id],
      name: :users_external_identity_partial_index
    )
  end
end
