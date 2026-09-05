defmodule Letflow.Definitions.SnapshotStore do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for `Store.create`/`Store.get` (PD-08, `snapshot.zig`) — the
  definition-snapshot store. See `lib/letflow/design/req033-snapshot-store.md`
  for the full design this module implements; this moduledoc restates the
  points that design's §8 requires to be stated here verbatim in substance.

  ## S3 scope boundary (design §1, §8 item 1)

  Calling `create/3` at instance-start time — before any event is appended
  (EE-01) — is **S3 scope, not built here**. The engine that would make that
  call doesn't exist in Letflow yet. This module builds only the store's
  create/retrieve operations in isolation, fully testable without any engine
  code.

  ## `create/3` is idempotent on `instance_id` (design §5, §8 item 2)

  A retry `create/3` call for an `instance_id` that already has a snapshot
  returns the pre-existing row — not an error, not a second row. This is a
  deliberate reading of REQ-033's acceptance criterion 2 (which explicitly
  permits either an idempotent no-op or a distinct
  `SnapshotAlreadyExists`-equivalent error); the idempotent reading is chosen
  because it is what a naive S3 EE-01 retry (after a crash/timeout with no way
  to know whether an earlier attempt committed) needs in order to converge
  without its own error-classification logic. There is no way to tell, from
  the return value alone, whether a given call just created the row or found
  one an earlier call created — this is deliberate, not an oversight (design
  §5).

  ## Write-once, no update/delete path (design §1, §8 item 3)

  This module exposes no update or delete path onto `instance_definition_snapshots`,
  ever — matching `Letflow.Definitions.InstanceDefinitionSnapshot`'s own
  moduledoc and PD-08's "Snapshots read-only after creation; no API endpoint
  permits modification."

  ## No `tenant_id` derivation anywhere in this module (design §3, §8 item 4)

  Neither table this module touches carries a `tenant_id` column that this
  module's own code populates: `instance_definition_snapshots` has no
  `tenant_id` column at all, and this module never writes to
  `process_definitions` (the one table that does have the column) — it only
  reads it, under a lock. Tenant isolation for both tables is enforced
  entirely by the Postgres schema (`:prefix`) boundary, not by a column value.

  ## `opts[:prefix]` is required on every call (design §2.1, §8 item 5)

  There is no default tenant schema — both tables are per-tenant
  (`if prefix() do ... end`-gated) with no `public`-schema counterpart. A
  missing or non-binary `:prefix` is `{:error, :missing_prefix}`, checked
  before any I/O.

  ## Deliberate divergence from the design's literal text: `instance_id`/
  ## `definition_id` are validated as UUIDs before any query runs (INV-8)

  The design's error taxonomy (§4.3) assumed a malformed `instance_id`/
  `definition_id` would surface as an `Ecto.Changeset.t()` error via
  `InstanceDefinitionSnapshot.create_changeset/2`'s own cast (design §4.3's
  `Ecto.Changeset.t()` clause commentary). That assumption does not hold:
  `create/3`'s locked read (§6.1 L1) queries `process_definitions` by
  `definition_id` *before* any changeset is ever built, and `get_by_instance_id/2`
  queries `instance_definition_snapshots` by `instance_id` directly — both are
  plain `Ecto.Query`/`Repo.get/3` lookups, not changeset-mediated writes.
  Confirmed empirically against this host's real Postgres (`mix run` against
  each path with a malformed id): both raise `Ecto.Query.CastError`, not a
  typed error — the same INV-8 class of bug
  `lib/letflow/event_store.ex`'s `fetch_event_type/1` comment documents for
  `event_type`. Guarded here the same way `Letflow.EventStore.append/2` guards
  `instance_id`/`actor_id` (`Ecto.UUID.cast/1`, which safely returns `:error`
  — never raises — for `nil`, non-binary values, maps, and structs alike):
  `create/3` returns `{:error, :invalid_instance_id}` /
  `{:error, :invalid_definition_id}`, and `get_by_instance_id/2` returns
  `{:error, :invalid_instance_id}`, before any query is composed. Flagged for
  REVIEWER at Step 2d as a deliberate, reasoned divergence from the design
  doc's literal §4.3 text, not a silent re-decision — the design's own
  catch-all `Ecto.Changeset.t()`/`term()` clauses remain in the type as
  defense-in-depth for any other unexpected cast failure this guard doesn't
  anticipate.

  ## Open questions carried from the design, not resolved here

  OQ-1/OQ-2/OQ-3 (design §9) are implemented exactly as the design states —
  see that document for the full reasoning. They are flagged again in this
  run's ELIXIR-DEV handoff for REVIEWER's explicit sign-off at Step 2d, not
  silently decided as obviously correct by this module's implementation.
  """

  import Ecto.Query

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo

  @type create_error ::
          :missing_prefix
          | :invalid_instance_id
          | :invalid_definition_id
          | :definition_not_found
          | Ecto.Changeset.t()
          | term()

  @doc """
  Creates (or, on a retry for an already-snapshotted `instance_id`, returns
  the pre-existing) definition snapshot for `instance_id`, capturing
  `definition_id`'s `process_definitions` row under a `FOR SHARE` lock.
  `opts[:prefix]` (the tenant's physical Postgres schema name) is required.
  See this module's moduledoc for the idempotency contract.
  """
  @spec create(
          instance_id :: Ecto.UUID.t(),
          definition_id :: Ecto.UUID.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, InstanceDefinitionSnapshot.t()} | {:error, create_error()}
  def create(instance_id, definition_id, opts) when is_list(opts) do
    with {:ok, prefix} <- fetch_prefix(opts),
         {:ok, instance_id} <- cast_uuid(instance_id, :invalid_instance_id),
         {:ok, definition_id} <- cast_uuid(definition_id, :invalid_definition_id) do
      Repo.transaction(fn ->
        case locked_source_definition(definition_id, prefix) do
          nil ->
            Repo.rollback(:definition_not_found)

          %ProcessDefinition{} = source_definition ->
            insert_snapshot_and_reselect(instance_id, definition_id, source_definition, prefix)
        end
      end)
    end
  end

  @doc """
  Looks up `instance_id`'s definition snapshot. `opts[:prefix]` (the tenant's
  physical Postgres schema name) is required. Never returns `nil` on a miss —
  returns `{:error, :snapshot_not_found}` instead.
  """
  @spec get_by_instance_id(instance_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
          {:ok, InstanceDefinitionSnapshot.t()}
          | {:error, :snapshot_not_found | :missing_prefix | :invalid_instance_id}
  def get_by_instance_id(instance_id, opts) when is_list(opts) do
    with {:ok, prefix} <- fetch_prefix(opts),
         {:ok, instance_id} <- cast_uuid(instance_id, :invalid_instance_id) do
      case Repo.get(InstanceDefinitionSnapshot, instance_id, prefix: prefix) do
        nil -> {:error, :snapshot_not_found}
        %InstanceDefinitionSnapshot{} = snapshot -> {:ok, snapshot}
      end
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §6.1 P0, plus the INV-8 UUID guards
  # this module's moduledoc documents as a deliberate divergence) -- pure or
  # read-only, zero writes attempted before Repo.transaction/2 opens.
  # ---------------------------------------------------------------------

  defp fetch_prefix(opts) do
    case Keyword.get(opts, :prefix) do
      prefix when is_binary(prefix) and byte_size(prefix) > 0 -> {:ok, prefix}
      _ -> {:error, :missing_prefix}
    end
  end

  defp cast_uuid(value, error_reason) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_reason}
    end
  end

  # ---------------------------------------------------------------------
  # Transactional phase (design doc §6.2) -- a plain Repo.transaction/2
  # closure (not Ecto.Multi, per the design's own stated rationale),
  # prefix: prefix on every operation.
  # ---------------------------------------------------------------------

  # L1 -- locked read of the source process_definitions row. Ecto.Query.lock/2
  # composition (INV-7: never a hand-written SQL string).
  defp locked_source_definition(definition_id, prefix) do
    ProcessDefinition
    |> where([d], d.id == ^definition_id)
    |> lock("FOR SHARE")
    |> Repo.one(prefix: prefix)
  end

  # L2 -- insert-or-ignore the snapshot row, keyed on instance_id
  # (on_conflict: :nothing suppresses a concurrent/repeat call's conflict at
  # the DB level, before InstanceDefinitionSnapshot's own unique_constraint/3
  # ever gets a chance to convert it to a changeset error -- design §6.3).
  # L3 -- re-select the authoritative row by instance_id, in the same
  # transaction, since an on_conflict: :nothing insert returns an ambiguous
  # struct when suppressed (design §6.2 L3).
  defp insert_snapshot_and_reselect(instance_id, definition_id, source_definition, prefix) do
    attrs = %{
      instance_id: instance_id,
      definition_id: definition_id,
      definition_name: source_definition.name,
      definition_ver: source_definition.version,
      graph: source_definition.graph
    }

    changeset = InstanceDefinitionSnapshot.create_changeset(%InstanceDefinitionSnapshot{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :instance_id,
           prefix: prefix
         ) do
      {:ok, _} ->
        case Repo.get(InstanceDefinitionSnapshot, instance_id, prefix: prefix) do
          %InstanceDefinitionSnapshot{} = snapshot -> snapshot
          nil -> Repo.rollback({:snapshot_missing_after_insert, instance_id})
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(changeset)
    end
  end
end
