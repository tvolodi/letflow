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

  No changeset function is defined here — REQ-018 (JIT provisioning
  upsert) and REQ-019 (tenant-scoped user operations) own the actual
  changeset functions and their validation logic.
  """

  use Ecto.Schema

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
end
