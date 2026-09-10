defmodule Letflow.TenantProvisioning.ColumnPromotion do
  @moduledoc """
  `Ecto.Schema` for `entity_column_promotions` -- the global (not
  tenant-scoped) bookkeeping table tracking one `(tenant_id, entity_type,
  attribute)` column-promotion attempt through its lifecycle. See
  `docs/migration/decisions/0024-entity-promotion-ddl-execution.md` and
  `lib/letflow/design/req295-entity-promotion-ddl-execution.md` §1 for the
  decision and the original field list this schema mostly implements
  verbatim, and `lib/letflow/design/req297-entity-promotion-executor.md` §2
  for this requirement's own re-confirmation of that field list.

  This schema is the persisted backbone for all four of 0024's sub-answers,
  implemented by `Letflow.TenantProvisioning`'s REQ-297 functions built
  against it: (1) the mechanism -- `Letflow.TenantProvisioning`, extended,
  issuing DDL directly, not a second module; (2) partial-failure -- one row
  per tenant, no cross-tenant atomicity, a `status` enum including
  `ddl_failed` and a `last_error` field, repair being a retry of exactly this
  one row (`Letflow.TenantProvisioning.retry_failed_column_promotion/1`), not
  a whole-batch re-run; (3) backfill -- `status` transitions through
  `backfilling`/`backfilled` as `Letflow.Entities.Record.Projector.rebuild_projection/2`
  replays, with `status in [ddl_applied, backfilling, backfilled]` driving
  dual-write via `column_promotion_dual_write?/3`; (4) rollback --
  `suspend_column_promotion/2` flips `query_eligible` to `false` while
  `status` stays `"active"`, never dropping or narrowing the column.

  Sibling to `Letflow.TenantProvisioning.Registration`, same conventions:
  plain `binary_id` primary key, no `belongs_to` association on `tenant_id`.

  ## Two fields added beyond req295 §1's literal list (flagged, not silent)

  - `pg_type :: String.t()` -- req295 §1's field list has no column
    carrying the Postgres type text for the `ALTER TABLE ... ADD COLUMN`
    statement `run_column_promotion/1` must issue. Without storing it on
    the row, `run_column_promotion/1` (which per req295 §2 takes only
    `promotion_id`, with no second, independently-supplied
    `column_spec`) would have no way to know what type to add. This is an
    additive, necessary field this requirement supplies -- the same class
    of gap CODE-DESIGN-VALIDATOR already flagged and accepted for
    `run_column_promotion/1`'s new `{:column_type_conflict, _, _}` error
    variant (design doc §0): a real, necessary, correctly-scoped addition,
    not a deviation from req295's contract.
  - `suspend_reason :: String.t() | nil` -- design doc §4's
    `suspend_column_promotion/2` section leaves open whether `reason` reuses
    `last_error` or gets a dedicated field, since req295 §1 names neither.
    Reusing `last_error` (documented above as "populated on ddl_failed,
    cleared on retry") would overload a field with a different, DDL-failure
    -specific meaning and would destroy history on a `retry` after a
    suspend. A dedicated field resolves the design's own explicitly-left-open
    question cleanly.

  ## `references_entity` (REQ-298)

  `references_entity :: String.t() | nil` -- the target entity-type
  **string** (never a resolved table name) for an FK-promoted column,
  stored verbatim as given to `register_column_promotion/4`. `nil` for the
  common, non-FK case. Resolved to a physical table name only at
  `run_column_promotion/1` time
  (`Letflow.TenantProvisioning.resolve_fk_target_table/1`), the same
  entity-type-space-until-execution-time posture `entity_type`/`attribute`
  already have on this row. See
  `lib/letflow/design/req298-constraint-fk-activation.md` §3.

  ## `generated_as` (REQ-301)

  `generated_as :: String.t() | nil` -- nullable, absent from
  `@required_fields`, exactly like every other field on an ordinary
  (non-generated) promotion's row. Non-`nil` only for a locale-derived
  generated column (`Letflow.Entities.Definition.DDL.localized_text_column_specs/1`),
  where it carries the SQL expression text `Letflow.TenantProvisioning`'s
  `execute_add_column/3` wraps in `GENERATED ALWAYS AS (...) STORED`. See
  `lib/letflow/design/req301-localized-text-field-type.md` §4.1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_column_promotions" do
    field(:tenant_id, Ecto.UUID)
    field(:entity_type, :string)
    field(:attribute, :string)
    field(:column_name, :string)
    field(:pg_type, :string)
    field(:status, :string)
    field(:query_eligible, :boolean, default: false)
    field(:last_error, :string)
    field(:suspend_reason, :string)
    field(:references_entity, :string)
    field(:generated_as, :string)
    field(:attempted_at, :naive_datetime)
    field(:ddl_applied_at, :naive_datetime)
    field(:backfilled_at, :naive_datetime)
    field(:activated_at, :naive_datetime)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @statuses ~w(pending ddl_applied backfilling backfilled active ddl_failed suspended)

  @cast_fields [
    :tenant_id,
    :entity_type,
    :attribute,
    :column_name,
    :pg_type,
    :status,
    :query_eligible,
    :last_error,
    :suspend_reason,
    :references_entity,
    :generated_as,
    :attempted_at,
    :ddl_applied_at,
    :backfilled_at,
    :activated_at
  ]

  @required_fields [:tenant_id, :entity_type, :attribute, :column_name, :status, :pg_type]

  @doc """
  Structural changeset: casts every field above except timestamps, requires
  the identity/status/pg_type fields, validates `status` against the closed
  seven-value enum, and declares the DB-level constraint fallbacks
  (`unique_constraint/2` for `(tenant_id, entity_type, attribute)`,
  `foreign_key_constraint/2` for `tenant_id`).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(column_promotion, attrs) do
    column_promotion
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:tenant_id,
      name: :entity_column_promotions_tenant_id_entity_type_attribute_idx
    )
    |> foreign_key_constraint(:tenant_id)
  end
end
