defmodule Letflow.PublicRead.Handle do
  @moduledoc """
  Ecto schema for the `public_read_handles` table (REQ-352, design
  `lib/letflow/design/req352-unauthenticated-read-platform.md` §4). Backs
  `Letflow.PublicRead.issue_handle/4` (the writer) and
  `Letflow.PublicRead.resolve/2` (the reader).

  **This table stores `handle_hash` only, never the plaintext handle**
  (INV-4) -- the same discipline `Letflow.Identity.ApiToken` already
  establishes for `token_hash`. The plaintext is generated and returned
  exactly once, by `Letflow.PublicRead.issue_handle/4`'s own return value; no
  field on this schema, and no changeset function below, ever accepts a
  plaintext handle.

  Global schema (no tenant `:prefix`) -- see the migration's own header
  comment for why.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "public_read_handles" do
    field(:handle_hash, :string)
    field(:tenant_id, Ecto.UUID)
    field(:kind, :string)
    field(:resource_id, Ecto.UUID)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          handle_hash: String.t(),
          tenant_id: Ecto.UUID.t(),
          kind: String.t(),
          resource_id: Ecto.UUID.t(),
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Insert changeset for `Letflow.PublicRead.issue_handle/4`. `attrs` carries
  `handle_hash`/`tenant_id`/`kind`/`resource_id`/`expires_at` -- never a
  `"handle"`/`"plaintext"` key (see moduledoc).
  """
  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(%__MODULE__{} = handle, attrs) do
    handle
    |> cast(attrs, [:handle_hash, :tenant_id, :kind, :resource_id, :expires_at])
    |> validate_required([:handle_hash, :tenant_id, :kind, :resource_id])
    |> unique_constraint(:handle_hash)
    |> foreign_key_constraint(:tenant_id)
  end
end
