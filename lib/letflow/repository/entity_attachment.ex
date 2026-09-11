defmodule Letflow.Repository.EntityAttachment do
  @moduledoc """
  Ecto schema for `entity_record_attachments` (REQ-316). See
  `lib/letflow/design/req313-entity-record-attachments.md` §1/§2 for the full
  column rationale; `Letflow.Repository.EntityAttachments` for the
  `upload/list/get/get_content/delete` context module.

  Tenant-scoped -- lives in each tenant's own Postgres schema (Decision B),
  same placement as `Letflow.Repository.Attachment`. An entity-record
  attachment is ordinary tenant business data (a document a tenant's user
  attached to one of that tenant's own entity records) -- never shared or
  looked up across tenants under any circumstance (design §1).

  Column-for-column identical to `Letflow.Repository.Attachment` except
  `instance_id :binary_id` is replaced by `entity_type :string` +
  `record_id :binary_id` (design §1) -- the pair that selects which entity
  record, within the tenant, this attachment belongs to. `record_id` is
  typed `:binary_id` here (not `Ecto.UUID`) purely as a naming choice; both
  are the same underlying Postgres `uuid` column type.

  `content_hash` is a FK to `repository_artifacts.content_hash`
  (`on_delete: :restrict`) -- this table reuses the SAME shared
  content-addressed byte store `Letflow.Repository.Attachment` already uses,
  not a second one (design §2's dedup statement); it does not itself hold
  any byte content.

  `(entity_type, record_id)` additionally carries a real, DB-level composite
  FK to `entity_record_latest(entity_type, record_id)`, `DEFERRABLE INITIALLY
  DEFERRED` (design §1) -- not modeled as an Ecto association (a composite FK
  has no direct `belongs_to`/`references` support), enforced purely at the
  migration/database level and surfaced here only via
  `foreign_key_constraint/3` in `changeset/2`.

  Not immutable at the database level -- ordinary tenant business data with a
  normal delete path (`delete/2`), matching `Letflow.Repository.Attachment`'s
  own precedent. No `update_changeset/2` exists -- a "changed" attachment is
  a new `upload/2` call (a new row).

  `scan_status` is a closed 4-value `Ecto.Enum`
  (`:pending`/`:clean`/`:infected`/`:error`), DB-default `"pending"`
  (fail-closed for any pre-existing row), always explicit-set by
  `Letflow.Repository.EntityAttachments.upload/2` on every new insert --
  `:clean` is the only value `upload/2` itself ever writes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_record_attachments" do
    field(:tenant_id, :binary_id)
    field(:entity_type, :string)
    field(:record_id, :binary_id)
    field(:content_hash, :binary)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:uploaded_by, :binary_id)
    field(:description, :string)
    field(:scan_status, Ecto.Enum, values: [:pending, :clean, :infected, :error])

    timestamps(updated_at: false, inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :tenant_id,
    :entity_type,
    :record_id,
    :content_hash,
    :file_name,
    :content_type,
    :byte_size,
    :uploaded_by,
    :scan_status
  ]

  @optional_fields [:description]

  @doc """
  Structural insert changeset -- `Letflow.Repository.EntityAttachments.upload/2`
  supplies every field itself (the derived `tenant_id`, the computed
  `content_hash`/`byte_size`, the caller's declared `entity_type`/`record_id`/
  `file_name`/`content_type`/`uploaded_by`/`description`). This changeset
  casts/validates presence, a `max_length` check on `file_name` (255,
  matching the column's `size: 255`), and declares the migration's composite
  FK to `entity_record_latest(entity_type, record_id)` via
  `foreign_key_constraint/3` -- a violation surfaces as an ordinary
  `{:error, %Ecto.Changeset{}}`, not a raised, unhandled Postgres error. No
  `update_changeset/2` -- this table has no legitimate update path.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attachment, attrs) do
    attachment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:file_name, max: 255)
    |> foreign_key_constraint(:record_id, name: :entity_record_attachments_record_fkey)
  end
end
