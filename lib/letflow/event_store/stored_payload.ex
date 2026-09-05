defmodule Letflow.EventStore.StoredPayload do
  @moduledoc """
  Ecto schema for the `event_payload_store` table — the side table holding
  payloads that exceed `src/design/event_store.md`'s 4096-byte inline boundary.
  See `lib/letflow/design/req023-event-store-schema.md` §3.4 and §5.1.

  Named `StoredPayload` rather than `EventPayloadStore` because the latter reads
  as a *store* (a context module) rather than a row struct — the same ambiguity
  `Letflow.TenantProvisioning.Registration` avoids. The authoritative
  table-to-module mapping is in the design doc's §5.1 table.

  ## `byte_size` semantics (design INV-EV-7)

  `byte_size` is the byte length of the **original** payload as measured by
  REQ-025 at append time — the value the 4096-byte boundary was applied to. It
  is *not* `octet_length(payload::text)` after storage: `jsonb` normalizes
  whitespace and key order, so a stored payload can round-trip to a different
  length than the bytes the boundary decision was made on.

  This is one symptom of a broader fact worth stating on its own (design
  §3.4, ISS-0020): `jsonb` is not byte-transparent. It cannot round-trip an
  opaque binary blob byte-for-byte the way `bytea` could. Nothing today needs
  that — see the design doc for where a future opaque-blob or hash-stable
  payload requirement would need to revisit this table's `:map`/`jsonb`
  choice.

  ## Large-payload split is invisible below the append/read layer (INV-EV-6)

  `events.payload` holds a `{"$ref": "<uuid>"}` pointer when the real bytes live
  here. Nothing in the migration layer enforces the 4096 boundary — REQ-023's
  own text assigns that to REQ-025's append logic — and nothing here reassembles
  the split; REQ-026's read path splices it back transparently.

  ## `on_delete: :restrict` and the question it keeps open (design OQ-2)

  PROVENANCE (historical, not current decision authority):
  The composite foreign key `(event_id, event_created_at)` →
  `events(event_id, created_at)` is declared `ON DELETE RESTRICT`, diverging
  from R-Co's `ON DELETE CASCADE`. Under CASCADE, REQ-026's archive operation
  (which deletes from `events` after copying to `events_archive`) would silently
  destroy the side-table payload of every archived large event, leaving archived
  events unreadable — directly contradicting
  `migrations/003_event_archive.sql:6-7` ("Archived rows are moved here, not
  deleted"). R-Co's CASCADE is not evidence to the contrary, because
  `Store.archive()` has since been retired there
  (`src/event_store/store.zig:1287-1310`), so nothing in current R-Co ever
  deletes an `events` row at all.

  `:restrict` deliberately does not *answer* how large payloads survive
  archival (design OQ-2 lists the three candidate resolutions); it makes the
  unanswered question fail loudly at REQ-026's first integration test instead of
  silently losing tenant data (design INV-EV-12).

  ## `event_created_at`, not `created_at`

  `event_created_at` is the **event's** `created_at` — the second half of the
  composite foreign key — while `inserted_at` is this row's own creation time.
  R-Co conflates both under the name `created_at` in two revisions with two
  different meanings (design §10, contradiction C-3); splitting them costs one
  column and removes the ambiguity.

  ## No `@schema_prefix` (design INV-EV-8)

  Like every event-store schema module, this table lives in many Postgres
  schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.

  ## No `tenant_id` (design §2.5)

  Unlike `Letflow.EventStore.Event`/`ArchivedEvent`/`InstanceProjection`, this
  table carries no `tenant_id` column: this table's own Postgres schema is
  already tenant-scoped, and every row is reached only via the composite FK
  to a specific `events` row, so a redundant `tenant_id` column would add no
  real guarantee. See the design doc §2.5 for the full asymmetry rationale.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_payload_store" do
    field(:event_id, Ecto.UUID)
    field(:event_created_at, :utc_datetime_usec)
    field(:payload, :map)
    field(:byte_size, :integer)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  The only changeset this module exposes — structural validation for storing one
  oversized payload. Does no I/O. There is deliberately no update counterpart: a
  payload belongs to an immutable event.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(stored_payload, attrs) do
    stored_payload
    |> cast(attrs, [:event_id, :event_created_at, :payload, :byte_size])
    |> validate_required([:event_id, :event_created_at, :payload, :byte_size])
    |> validate_number(:byte_size, greater_than: 0)
    |> unique_constraint(:event_id, name: :uq_event_payload_event)
    |> foreign_key_constraint(:event_id)
  end
end
