defmodule Letflow.Definitions.InstanceDefinitionSnapshot do
  @moduledoc """
  Ecto schema for the `instance_definition_snapshots` table. See
  `lib/letflow/design/req027-definition-core-schema.md` §3.2 and §5.1.

  ## Ported source (REQ-027 acceptance criterion 5)

  Ported from R-Co's `src/design/definition.md` PD-08 section (the definition
  snapshot: `SnapshotStore`, the `Snapshot` struct's DB column mapping, and the
  "Atomicity guarantee" section), with the table DDL from R-Co's
  `migrations/004_definitions.sql`. The PD-01 and PD-07 sections of the same
  document are the ported source for `process_definitions`, the table this one
  references — see `Letflow.Definitions.ProcessDefinition`.

  ## No `ON DELETE CASCADE` on `definition_id` (REQ-027 acceptance criterion 4)

  `definition_id` references `process_definitions.id` with NO ON DELETE
  CASCADE. This is deliberate, per PD-08's "FK without `ON DELETE CASCADE`"
  paragraph: "Deletion of the source definition does NOT automatically remove
  snapshot rows. Snapshot rows persist with their captured `graph`,
  `definition_name`, and `definition_ver` regardless of what happens to the
  source definition." It is what satisfies PD-08's edge case: "Definition
  hard-deleted (DRAFT) after instances were started from it: instances retain
  their snapshot and continue normally." Adding `on_delete: :delete_all` here
  would destroy exactly the data this table exists to preserve, and would break
  REQ-033's fourth acceptance criterion.

  R-Co itself later replaced this FK with an ON DELETE CASCADE variant in
  `migrations/1106_iss0125_instance_definition_snapshots_cascade.sql`, whose
  own header gives the reason as a test-harness cleanup-ordering problem
  ("bespoke per-test cleanup helpers that swallowed SQL errors"), not a design
  change — and that migration directly contradicts the PD-08 design text quoted
  above. Letflow follows PD-08's design and does NOT port that migration.

  Mechanically, the migration passes `on_delete: :nothing`, which falls through
  `reference_on_delete/1`'s catch-all
  (`deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1918`) and so emits
  no `ON DELETE` clause at all — Postgres's default `NO ACTION`. A consequence
  worth stating because REQ-033's fourth acceptance criterion is worded around
  it: under `NO ACTION` no delete of a *referenced* definition ever succeeds,
  DRAFT or otherwise; Postgres raises `foreign_key_violation` (23503). The
  snapshot survives a fortiori, but a test must assert the delete is
  **rejected** and the snapshot still readable, not that the delete succeeds
  (design OQ-2).

  ## No foreign key on `instance_id`, deliberately

  `definition.md:362` describes `instance_id` as an "FK to
  `process_instances.id`". Letflow follows R-Co's SQL, not that prose:
  `004_definitions.sql:60` declares a bare `UUID PRIMARY KEY` with no
  `REFERENCES` clause, and no `process_instances` table exists in R-Co at all
  (verified by search across all 146 `migrations/*.sql`; R-Co's instance table
  is `instance_projections`). Beyond the missing table, an FK here would be
  wrong on its own terms: PD-08's EE-01 contract requires the snapshot to be
  created **before** the `InstanceStarted` event is appended
  (`definition.md:2069-2081`), so a snapshot row can legitimately exist before
  any instance row does.

  ## Write-once (design INV-DEF-6)

  This table is write-once. This module deliberately exposes no
  `update_changeset/2`, no generic `changeset/2`, and no delete path — per
  PD-08, "Snapshots read-only after creation; no API endpoint permits
  modification." The absence of those functions is the whole of what REQ-027
  provides; runtime enforcement of the write-once rule is REQ-033's job, not
  this migration's.

  There is also deliberately no `belongs_to :definition` association, even
  though a real DB foreign key exists: an association would invite
  `Repo.preload/2` across the snapshot→definition edge, which is precisely the
  coupling PD-08 exists to break — a snapshot is meaningful *without* its
  source definition.

  ## Scope — this requirement builds schema only

  This requirement (REQ-027) builds schema only. The snapshot create/retrieve
  functions (`Letflow.Definitions.SnapshotStore`) are REQ-033, and the EE-01
  instance-start integration point that calls them is S3 scope, not built here.

  ## No `@schema_prefix` (design INV-DEF-7)

  This table lives in many Postgres schemas — one per tenant — so every read
  and write must pass `prefix: schema_name` explicitly at call time rather than
  relying on a compile-time prefix. `schema_name` comes from a
  `Letflow.TenantProvisioning.Registration` row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # autogenerate: false is deliberate — the instance id is minted by S3's engine and
  # supplied by the caller, never by this row.
  @primary_key {:instance_id, :binary_id, autogenerate: false}
  schema "instance_definition_snapshots" do
    field(:definition_id, Ecto.UUID)
    field(:definition_name, :string)
    field(:definition_ver, :string)
    field(:graph, :map)

    # Assigned by the column's DB default, never by the changeset — mirroring R-Co,
    # whose INSERT omits the column and reads it back via RETURNING
    # (definition.md:1995-2006).
    field(:snapshotted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @type t :: %__MODULE__{}

  @doc """
  Structural changeset for creating an instance's definition snapshot. Does no I/O.

  This is the only changeset this module exposes — the table is write-once
  (see this module's moduledoc).
  """
  @spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def create_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:instance_id, :definition_id, :definition_name, :definition_ver, :graph])
    |> validate_required([
      :instance_id,
      :definition_id,
      :definition_name,
      :definition_ver,
      :graph
    ])
    |> validate_length(:definition_name, min: 1, max: 255)
    |> validate_length(:definition_ver, min: 1, max: 255)
    # Turns a duplicate-instance_id insert into {:error, changeset} rather than a
    # raised Ecto.ConstraintError, which is what lets REQ-033 return its
    # SnapshotAlreadyExists-equivalent.
    |> unique_constraint(:instance_id, name: :instance_definition_snapshots_pkey)
    # Turns a dangling definition_id into {:error, changeset} rather than a raised
    # error, which is what lets REQ-033 return DefinitionNotFound. The constraint name
    # is Ecto's own default for this table/column pair
    # (deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1895-1896).
    |> foreign_key_constraint(:definition_id,
      name: :instance_definition_snapshots_definition_id_fkey
    )
  end
end
