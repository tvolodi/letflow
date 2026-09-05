defmodule Letflow.EventStore.IdempotencyRecord do
  @moduledoc """
  Ecto schema for the `event_idempotency` table. See
  `lib/letflow/design/req023-event-store-schema.md` §3.5 and §5.1.

  ## What this table is, and what it supersedes (REQ-023 acceptance criterion 4)

  This is the dedicated idempotency sidecar table
  (`event_idempotency`), built from day one per
  `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision C point
  2(b) — the partitioning point's second lettered sub-point, distinct from
  2(a)'s primary-key-shape concern: "Letflow adopts the sidecar-table
  approach for idempotency from the start (not deferred to partitioning
  time)."

  This table supersedes R-Co's `src/design/event_store.md` "Open Question
  #1" recommendation of a two-phase deduplication check (INSERT into
  `events` with ON CONFLICT (idempotency_key) DO NOTHING, then a fallback
  SELECT against `events_archive`). 0003 already resolved that open
  question in favour of the sidecar table, so REQ-025's append and
  REQ-026's archive check and write THIS table for idempotency — not a raw
  unique index scattered across `events` and `events_archive` separately.
  Neither `events` nor `events_archive` carries a unique index on
  `idempotency_key`; the unique index `uq_event_idempotency_key` on this
  table is the single enforcement point. R-Co reached the same end state:
  `migrations/1147_par01_events_partitioning.sql` removes both of those
  indexes and states that its `plat_event_idempotency` sidecar "supersedes
  their purpose."

  ## Table naming

  `event_idempotency`, not `plat_event_idempotency`: the `plat_` prefix
  denotes a platform/cross-tenant table, and
  `src/design/par-01-monthly-range-partitioning.md:203-209` flags this specific
  table as an exception to that convention ("one new `plat_`-prefixed table that
  is *itself* per-tenant"). Letflow's sidecar is unambiguously per-tenant — 0003
  closes with "a cross-tenant-shared sidecar table would reintroduce exactly the
  shared-table blast-radius risk Decision B rejected" — so carrying the prefix
  over would import a known misnomer.

  ## Per-tenant, and no foreign key to `events`

  The claimed event may legitimately live in `events` *or* `events_archive`
  (R-Co additionally searches `events_ephemeral`), so a foreign key to `events`
  alone would break the moment REQ-026's archive operation moves the row. R-Co's
  own sidecar likewise carries none. `(event_id, event_created_at)` together
  form the full `events` primary key, which is what lets REQ-025 resolve the
  original record on a duplicate hit; `inserted_at` is this row's own creation
  time, kept separate from the event's.

  ## No `update_changeset/2`, deliberately

  A claimed idempotency key is never re-pointed at a different event; doing so
  would break ES-03's durability guarantee.

  ## No `@schema_prefix` (design INV-EV-8)

  Like every event-store schema module, this table lives in many Postgres
  schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_idempotency" do
    field(:idempotency_key, :string)
    field(:event_id, Ecto.UUID)
    field(:event_created_at, :utc_datetime_usec)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  The only changeset this module exposes — structural validation for claiming
  one idempotency key. Does no I/O; the duplicate-key collision surfaces as a
  constraint error from `Repo.insert/2` inside REQ-025's append transaction.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(idempotency_record, attrs) do
    idempotency_record
    |> cast(attrs, [:idempotency_key, :event_id, :event_created_at])
    |> validate_required([:idempotency_key, :event_id, :event_created_at])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> unique_constraint(:idempotency_key, name: :uq_event_idempotency_key)
  end
end
