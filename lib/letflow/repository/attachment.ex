defmodule Letflow.Repository.Attachment do
  @moduledoc """
  Ecto schema for `instance_attachments` (REQ-211). See
  `lib/letflow/design/req211-instance-attachments-core.md` §1/§3 for the full
  column rationale; `Letflow.Repository.Attachments` for the
  `upload/list/get/delete` context module.

  Tenant-scoped -- lives in each tenant's own Postgres schema (Decision B),
  alongside `dlq_entries`/`webhook_subscriptions`/`repository_artifacts`. An
  attachment is ordinary tenant business data (a document a tenant's user
  attached to that tenant's own workflow instance) -- unlike
  `repository_artifacts`, whose per-tenant-vs-global placement was genuinely
  debated (REQ-202), `instance_attachments` rows are never shared or looked
  up across tenants under any circumstance (design §1.1).

  `content_hash` is a FK to `repository_artifacts.content_hash`
  (`on_delete: :restrict`, same shape as `artifact_versions`'s own FK) --
  this table reuses REQ-202's content-addressed byte store rather than
  duplicating content storage; it does not itself hold any byte content.

  Not immutable at the database level (unlike `repository_artifacts` itself)
  -- ordinary tenant business data with a normal delete path (`delete/2`),
  not a content-addressed store (design §1.4). No `update_changeset/2` exists
  -- a "changed" attachment is a new `upload/2` call (a new row), matching the
  immutable-content spirit of the store it references, though not itself
  DB-trigger-enforced.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "instance_attachments" do
    field(:tenant_id, :binary_id)
    field(:instance_id, :binary_id)
    field(:content_hash, :binary)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:uploaded_by, :binary_id)
    field(:description, :string)

    timestamps(updated_at: false, inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :tenant_id,
    :instance_id,
    :content_hash,
    :file_name,
    :content_type,
    :byte_size,
    :uploaded_by
  ]

  @optional_fields [:description]

  @doc """
  Structural insert changeset -- `Letflow.Repository.Attachments.upload/2`
  supplies every field itself (the derived `tenant_id`, the computed
  `content_hash`/`byte_size`, the caller's declared `file_name`/`content_type`/
  `uploaded_by`/`description`). This changeset only casts/validates presence
  plus a `max_length` check on `file_name` (255, matching the column's
  `size: 255`); it does not compute or derive anything. No `update_changeset/2`
  -- this table has no legitimate update path (design §1.4).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attachment, attrs) do
    attachment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:file_name, max: 255)
  end
end
