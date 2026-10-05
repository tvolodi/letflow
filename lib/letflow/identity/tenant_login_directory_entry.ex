defmodule Letflow.Identity.TenantLoginDirectoryEntry do
  @moduledoc """
  Ecto schema for the `tenant_login_directory` table (REQ-435; design
  `lib/letflow/design/req434-email-first-login-directory.md` §1.1-§1.2, decision
  `docs/migration/decisions/0042-email-first-login-tenant-directory.md`).

  Public-schema, global table -- same tier as `Letflow.Identity.Tenant` and
  `Letflow.Identity.TenantMembership`, never created per tenant schema (no
  `opts[:prefix]` anywhere in this module).

  A row is the pair `(email_key, tenant_id)`: `email_key` is the 32-byte keyed
  HMAC-SHA256 of a normalised email (`Letflow.LoginDirectory.email_key/1`, never
  the plaintext address), `tenant_id` the tenant that holds an active user with
  that email. The pair is the identity, so there is no surrogate `id` and no
  `updated_at`; rows are inserted or deleted, never edited, which is why only
  `create_changeset/2` exists (the same insert-or-delete-only shape as
  `Letflow.Identity.TenantMembership`).

  **What this table is not.** It is not an identity record: it holds no
  password, role, session, user id, `external_id`, user display name or profile
  field, and nothing references a row. It is not read by `AuthPipeline` or by
  any authenticated path (0042 standing prohibition 10) -- it answers "where
  might this email log in", never "who is this request from". It is not
  `tenant_memberships` (admin-granted, plaintext, switcher-facing) and not
  `public_read_handles` (an unrelated capability-handle table).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "tenant_login_directory" do
    field(:email_key, :binary, primary_key: true)
    field(:key_id, :string)
    belongs_to(:tenant, Letflow.Identity.Tenant, type: :binary_id, primary_key: true)

    field(:inserted_at, :naive_datetime)
  end

  @type t :: %__MODULE__{
          email_key: <<_::256>>,
          key_id: String.t(),
          tenant_id: Ecto.UUID.t(),
          inserted_at: NaiveDateTime.t()
        }

  @doc """
  Changeset for inserting an entry. Casts and requires `[:email_key, :key_id,
  :tenant_id]`; `key_id` (0043 D-C: the id of the pepper that produced
  `email_key`, not part of the primary key) must match `[a-z0-9_-]{1,32}`
  (mirrors the `key_id_format` CHECK); `unique_constraint` on the pair. No
  update changeset exists.
  """
  @spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:email_key, :key_id, :tenant_id])
    |> validate_required([:email_key, :key_id, :tenant_id])
    |> validate_format(:key_id, ~r/\A[a-z0-9_-]{1,32}\z/)
    |> check_constraint(:key_id, name: :key_id_format)
    |> unique_constraint([:email_key, :tenant_id], name: :tenant_login_directory_pkey)
  end
end
