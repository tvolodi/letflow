defmodule Letflow.Repository.ArtifactVersion do
  @moduledoc """
  Ecto schema for `artifact_versions` (REQ-202, REPO-02/03). The named,
  ordered-version half of the artifact repository: each row points into
  `Letflow.Repository.Artifact`'s content-addressed store via
  `content_hash`. See `lib/letflow/design/req202-artifact-repository.md`
  §2.2 for the full column rationale.

  Tenant-scoped, same schema-per-tenant placement as
  `Letflow.Repository.Artifact` -- see that module's moduledoc for the full
  placement reasoning (§1 of the design doc).

  ## OQ-4, resolved: `artifact_id` semantics

  `artifact_id` is **server-generated**, not caller-supplied: the first time
  `Letflow.Repository.create/2` sees a given `(artifact_kind, artifact_name)`
  pair in a tenant's schema, it generates a fresh UUID and stores it on that
  first version row; every subsequent version created for the same
  `(artifact_kind, artifact_name)` pair reuses the `artifact_id` already
  present on that pair's most recent version row. This makes `artifact_id` a
  stable handle for "the same logical artifact across its version history"
  without requiring the caller to coordinate or pre-allocate an id, at the
  cost of `artifact_id` carrying no independent information beyond the
  `(artifact_kind, artifact_name)` pair it was minted for -- a rename (a new
  `artifact_name` for what a caller considers "the same" artifact) is, under
  this reading, a new `artifact_id`, not a continuation of the old one. This
  is a deliberate choice, not a silent default: REQ-202's schema spec does
  not state whether `artifact_id` is caller-supplied or server-derived, and
  this design picks server-generated as the simpler contract that needs no
  new uniqueness/collision handling in `create/2` beyond what the
  `(artifact_kind, artifact_name, version_number)` unique index already
  provides.

  Immutable at the database level (a `BEFORE UPDATE` trigger, installed by
  this table's own migration, rejects any mutation) -- "changing" a version
  means calling `create/2` again with new content, which produces a new
  `content_hash` and a new `version_number` (REPO-02). `changeset/2` is only
  ever used to build the attributes for a single `Repo.insert/2` call.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:version_id, :binary_id, autogenerate: true}
  schema "artifact_versions" do
    field(:tenant_id, :binary_id)
    field(:artifact_id, :binary_id)

    field(:artifact_kind, Ecto.Enum,
      values: [
        :definition,
        :form,
        :schema,
        :service_catalog,
        :script,
        :module,
        :scenario
      ]
    )

    field(:artifact_name, :string)
    field(:version_number, :integer)
    field(:content_hash, :binary)
    field(:parent_version_id, :binary_id)
    field(:created_by, :binary_id)
    field(:description, :string)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :tenant_id,
    :artifact_id,
    :artifact_kind,
    :artifact_name,
    :version_number,
    :content_hash,
    :created_by
  ]

  @castable_fields [
    :version_id,
    :tenant_id,
    :artifact_id,
    :artifact_kind,
    :artifact_name,
    :version_number,
    :content_hash,
    :parent_version_id,
    :created_by,
    :description
  ]

  # Must match the explicit `:name` given to `unique_index/3` in
  # `priv/repo/migrations/20260830030001_create_repository_artifacts.exs`
  # exactly -- Ecto's own default-generated name for this column list is 66
  # bytes, over Postgres's 63-byte NAMEDATALEN limit, so Postgres silently
  # truncates the real constraint name; an untruncated name here would never
  # match what a real unique-violation is actually raised against, and
  # `unique_constraint/3`'s error-catching (design §4.4's concurrency-retry
  # contract) would never fire.
  @unique_version_number_constraint_name :artifact_versions_kind_name_number_idx

  @doc """
  Structural insert changeset -- `Letflow.Repository.create/2` supplies
  every field itself (the resolved `tenant_id`, the resolved/minted
  `artifact_id`, the computed `content_hash`, and the computed
  `version_number`). This changeset casts/validates presence and attaches
  the unique-index-backed constraint that makes concurrent `create/2` calls
  for the same `(artifact_kind, artifact_name)` pair safe (design §4.4): a
  second writer that raced to the same `version_number` fails this
  constraint instead of silently double-assigning it, and
  `Letflow.Repository`'s own retry loop recomputes and retries on exactly
  this constraint's violation.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = version, attrs) do
    version
    |> cast(attrs, @castable_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(
      [:artifact_kind, :artifact_name, :version_number],
      name: @unique_version_number_constraint_name
    )
  end
end
