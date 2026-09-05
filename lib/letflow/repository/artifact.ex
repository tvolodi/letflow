defmodule Letflow.Repository.Artifact do
  @moduledoc """
  Ecto schema for `repository_artifacts` (REQ-202, REPO-01/02). The
  content-addressed blob store half of the artifact repository: one row per
  distinct canonical content value, keyed by its own SHA-256 hash. See
  `lib/letflow/design/req202-artifact-repository.md` §2.1 for the full
  column rationale; `Letflow.Repository.Canonicaliser` for how
  `content_hash` is computed; `Letflow.Repository` for the `create/2`
  write path.

  Tenant-scoped -- lives in each tenant's own Postgres schema, per Decision
  0003-B, alongside `audit_entries`/`users`/`groups`. See the design doc §1
  for why this table is per-tenant (not global, unlike R-Co's own schema):
  cross-tenant content dedup is only possible if this table were global, but
  no REQ-202 acceptance criterion requires it, and a global content-addressed
  store built specifically so two tenants' bytes can share one physical row
  is exactly the isolation model Decision B's blast-radius-containment
  rationale exists to avoid. Dedup here is therefore per-tenant only -- a
  deliberate, recorded forfeiture of cross-tenant storage efficiency, not an
  oversight. No REVIEWER sign-off flag is raised (that flag is conditioned on
  going global, which this design does not do).

  ## R-Co migration 058 shape conflict (AC11)

  R-Co's migration `058_repo_artifacts_tenant_activation.sql` re-creates
  `repository_artifacts` with a COMPLETELY DIFFERENT shape from migration
  `045_repository_artifacts.sql` (`version_id` as primary key rather than
  `content_hash`, `content_hash` typed `TEXT` rather than `BYTEA`, an inline
  `content_json` column, no `byte_size`/`content_type` columns). Both R-Co
  migrations use `CREATE TABLE IF NOT EXISTS`, so which shape a given R-Co
  database ends up with depends on migration-application order and prior
  database state -- a real defect in R-Co's migration history, not a
  design choice to reproduce. **Letflow ships exactly one shape: migration
  045's**, the one `src/repository/artifacts.zig` actually codes against --
  the shape this schema module defines. See
  `priv/repo/migrations/20260830030001_create_repository_artifacts.exs`'s
  top-of-file comment for the migration-file-level (AC10) placement
  statement; this is the separate, moduledoc-level (AC11) statement of the
  058-vs-045 conflict.

  Immutable at the database level (both `BEFORE UPDATE` and `BEFORE DELETE`
  triggers reject any mutation, installed by this table's own migration) --
  `changeset/2` is only ever used to build the attributes for a single
  `Repo.insert/2` call (with `on_conflict: :nothing` for the dedup-by-hash
  upsert), never for an update.

  ## `content` column (REQ-211 addendum)

  `content :binary` (Postgres `bytea`) was added by REQ-211's migration
  addendum (`priv/repo/migrations/20260901000001_add_content_to_repository_artifacts.exs`,
  design `lib/letflow/design/req211-instance-attachments-core.md` §2A) --
  the actual raw content bytes this store's `content_hash` is computed over.
  REQ-202's own shipped `create/2` computed the hash/byte_size from these
  bytes but never persisted them anywhere; REQ-211 is this column's first
  real writer (`Letflow.Repository.upsert_content/6`). This does not change
  REQ-202's own acceptance criteria or `done` status -- see the migration's
  own header comment for the full addendum rationale (why `bytea`, why
  `null: false` needs no backfill).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:content_hash, :binary, autogenerate: false}
  schema "repository_artifacts" do
    field(:tenant_id, :binary_id)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:content, :binary)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [:content_hash, :tenant_id, :content_type, :byte_size, :content]

  @doc """
  Structural insert changeset -- `Letflow.Repository.create/2` supplies
  every field itself (the pre-computed `content_hash`, the derived
  `tenant_id`, and the submitted `content_type`/`byte_size`). This changeset
  only casts/validates presence; it does not compute the hash or derive the
  tenant id.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = artifact, attrs) do
    artifact
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end
end
