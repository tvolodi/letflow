defmodule Letflow.EventStore do
  @moduledoc """
  Context module for `Store.append()` (ES-01/02/03/05/08/DB-03) — port of R-Co's
  `src/event_store/store.zig`'s `append`. See
  `lib/letflow/design/req025-event-append.md` for the full design this module
  implements; this moduledoc restates the four points that design's §7 requires
  to be stated here verbatim in substance.

  ## `tenant_id` is always derived, never accepted

  `tenant_id` is always derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted from
  `attrs`. `attrs` containing a `:tenant_id` (or `"tenant_id"`) key is a hard
  error, `{:error, :tenant_id_not_accepted}` — see
  `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17
  addendum, which settles this mechanism project-wide (a caller-supplied
  `tenant_id` can disagree with the schema a row is physically written into,
  which is the attribution defect that addendum exists to close).

  ## `event_id`/`created_at` are minted exactly once

  `event_id`/`created_at` are minted exactly once per `append/2` call and bound
  identically into `events`, `event_idempotency`, and (only when the payload is
  oversized) `event_payload_store` — design invariant INV-EV-5. R-Co shipped and
  then fixed the exact bug this prevents: two independent `gen_random_uuid()`
  evaluations orphaning the idempotency sidecar row from the event it points at
  (`store.zig:623-636`, quoted via `req023-event-store-schema.md`).

  ## Registry and metadata validation run before the transaction opens

  Registry validation (`Letflow.EventStore.Registry.validate_payload/3`) and
  metadata validation both complete, with zero DB writes attempted anywhere,
  **before** `Repo.transaction/2` is ever called — not merely as the first
  `Ecto.Multi` step. This is a deliberate reading of invariant 8's "zero rows
  written on failure" as literally as invariant 9's explicit "before the
  transaction opens" (see the design doc §6.1 for the full reasoning:
  avoiding `instance_sequence`'s hot row lock for a call already known to
  fail, and symmetry with metadata validation's own stated principle). Flagged
  there as this design's own interpretation, not a literal quotation of the
  unreachable `event_store.md` "append" section — re-verify against that
  primary source if it ever becomes reachable again.

  ## `instance_sequence` and `event_idempotency` carry no `tenant_id` column

  Unlike `events` and `instance_projections`, `instance_sequence` and
  `event_idempotency` carry **no** `tenant_id` column at all (confirmed
  directly against both the Ecto schema modules and the migration DDL — design
  doc §0/§9 OQ-1). Tenant isolation for those two tables' rows is enforced
  entirely by the Postgres schema (`:prefix`) boundary they are written into,
  not by a column value. This is a known requirement-text/shipped-schema
  mismatch against REQ-025's acceptance criterion 6 — reported to REVIEWER,
  not silently resolved by adding a column REQ-023's own design explicitly
  warns against completing.

  ## Scope

  Only `append/2` is built here. `read/2`, `read_global/1`, `point_in_time/3`,
  `archive/1` belong to REQ-026. Meaningful, engine-driven population of
  `instance_projections`' engine-owned columns (`definition_id`,
  `current_nodes`, ...) belongs to EE-01/S3 — `append/2` never originates an
  `instance_projections` row; it only ever advances the `last_event_seq` of a
  row that already exists (REVIEWER's Step 2d OQ-5 ruling; design doc §6.2.1,
  §6.2.6, §9 OQ-5). A missing row fails the whole call with
  `{:error, :instance_not_started}` instead.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.EventStore.{Event, IdempotencyRecord, InstanceProjection, InstanceSequence}
  alias Letflow.EventStore.Registry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @payload_inline_max_bytes 4096
  @idempotency_key_max_length 255
  @metadata_max_entries 50
  @metadata_key_max_length 128
  @metadata_value_max_length 1024

  @type append_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:event_type) => String.t(),
          required(:payload) => String.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:metadata) => %{optional(String.t()) => String.t()}
        }

  @type metadata_violation ::
          :not_a_map
          | :too_many_entries
          | {:non_string_key, key :: term()}
          | {:key_too_long, key :: String.t()}
          | {:value_too_long, key :: String.t()}
          | {:non_string_value, key :: String.t()}

  @type append_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :invalid_schema_name}
          | {:error, :missing_instance_id}
          | {:error, :missing_actor_id}
          | {:error, :missing_payload}
          | {:error, :invalid_payload}
          | {:error, :missing_event_type}
          | {:error, :missing_idempotency_key}
          | {:error, :idempotency_key_too_long}
          | {:error, {:invalid_metadata, metadata_violation()}}
          | {:error, :tenant_not_provisioned}
          | {:error, :unknown_event_type}
          | {:error, {:payload_validation_failed, [Registry.ValidationFailure.t()]}}
          | {:error, :instance_not_started}
          | {:error, {:instance_terminated, :completed | :cancelled}}
          | {:error, {:sequence_conflict, term()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @type append_result :: %{
          event: Event.t(),
          is_duplicate: boolean(),
          sequence_number: pos_integer(),
          global_seq: pos_integer()
        }

  @doc """
  Appends one event to `attrs[:instance_id]`'s stream, inside the tenant
  schema named by `opts[:prefix]`. `opts`'s only required key is `:prefix` —
  the tenant's physical Postgres schema name — matching every other
  event-store schema module's `prefix:`-at-call-time contract (INV-EV-8).

  `attrs` never accepts a `:tenant_id` key (see this module's moduledoc);
  `tenant_id` is always derived from `opts[:prefix]`.

  On a fresh append, returns the inserted `events` row with
  `is_duplicate: false`. On a call reusing an already-claimed
  `idempotency_key`, returns the **original** row from the first successful
  append with `is_duplicate: true` — zero net rows change anywhere on that
  path. See `lib/letflow/design/req025-event-append.md` for the full
  behavior, error taxonomy, and locking protocol this implements.
  """
  @spec append(attrs :: append_attrs(), opts :: [prefix: String.t()]) ::
          {:ok, append_result()} | append_error()
  def append(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_tenant_id(attrs),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, instance_id} <- fetch_uuid(attrs, :instance_id, :missing_instance_id),
         {:ok, actor_id} <- fetch_uuid(attrs, :actor_id, :missing_actor_id),
         {:ok, payload} <- fetch_payload(attrs),
         {:ok, idempotency_key} <- fetch_idempotency_key(attrs),
         {:ok, event_type} <- fetch_event_type(attrs),
         {:ok, metadata} <- validate_metadata(Map.get(attrs, :metadata) || %{}),
         :ok <- Registry.validate_payload(event_type, payload, tenant_id) do
      ctx = %{
        schema_name: prefix,
        tenant_id: tenant_id,
        instance_id: instance_id,
        event_type: event_type,
        actor_id: actor_id,
        idempotency_key: idempotency_key,
        metadata: metadata,
        payload_bytes: byte_size(payload),
        # Safe unconditionally: Registry.validate_payload/3 (above) already
        # proved `payload` decodes to a JSON object.
        decoded_payload: Jason.decode!(payload),
        event_id: Ecto.UUID.generate(),
        created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      ctx
      |> build_multi()
      |> Repo.transaction()
      |> interpret_transaction_result()
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §6.1, P0-P6) -- pure or read-only,
  # zero writes attempted before Repo.transaction/2 below is ever called.
  # ---------------------------------------------------------------------

  defp reject_tenant_id(attrs) do
    if Map.has_key?(attrs, :tenant_id) or Map.has_key?(attrs, "tenant_id") do
      {:error, :tenant_id_not_accepted}
    else
      :ok
    end
  end

  defp fetch_uuid(attrs, key, error_reason) do
    case Map.get(attrs, key) do
      nil ->
        {:error, error_reason}

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, error_reason}
        end
    end
  end

  defp fetch_payload(attrs) do
    case Map.get(attrs, :payload) do
      payload when is_binary(payload) and byte_size(payload) > 0 -> {:ok, payload}
      _ -> {:error, :missing_payload}
    end
  end

  defp fetch_idempotency_key(attrs) do
    case Map.get(attrs, :idempotency_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        if String.length(key) > @idempotency_key_max_length do
          {:error, :idempotency_key_too_long}
        else
          {:ok, key}
        end

      _ ->
        {:error, :missing_idempotency_key}
    end
  end

  # Design doc §6.1 P2/§9 OQ-4 deliberately leaves `event_type`'s structural check
  # out of the pre-transaction phase, on the stated premise that a missing/malformed
  # `event_type` would surface later via `Event.insert_changeset/2`'s ordinary
  # `%Ecto.Changeset{}` path at Multi step M4. That premise doesn't hold: P4
  # (`Registry.validate_payload/3`, right below) runs *before* the `Multi`/M4 ever
  # starts and passes `event_type` straight into an `Ecto.Query` `where` comparison
  # (`Letflow.EventStore.Registry.get_type/2`) — a non-binary value there raises
  # `Ecto.Query.CastError` (or `ArgumentError` for `nil`), not a typed error, which is
  # the exact INV-8 class of bug this rework iteration exists to close, confirmed
  # empirically (a throwaway `mix run` against real Postgres: `event_type: nil` ->
  # `ArgumentError`, `event_type: :an_atom` / `123` -> `Ecto.Query.CastError`). Guarded
  # here instead, matching every other structural field's shape (`:missing_event_type`,
  # symmetric with `:missing_instance_id`/`:missing_actor_id`/`:missing_payload`)
  # rather than leaving OQ-4's now-disproven deferral in place. Flagged for REVIEWER at
  # Step 2d as a deliberate, reasoned divergence from the design doc's literal OQ-4
  # text, not a silent re-decision.
  defp fetch_event_type(attrs) do
    case Map.get(attrs, :event_type) do
      event_type when is_binary(event_type) and byte_size(event_type) > 0 -> {:ok, event_type}
      _ -> {:error, :missing_event_type}
    end
  end

  # `is_map/1` alone is never sufficient to mean "plain map" -- a struct IS a
  # map under the hood (`is_map/1` returns `true` for e.g. `DateTime.utc_now()`,
  # `URI.parse/1`'s result, `MapSet.new/1`, or a `Range` literal like `1..5`),
  # so the guard must explicitly reject `is_struct/1` too. Structs either have
  # no `Enumerable` impl at all (raising `Protocol.UndefinedError` from the
  # `Enum.find_value/3` below) or iterate as bare elements rather than
  # `{key, value}` tuples (raising `FunctionClauseError` inside this
  # function's own anonymous function) -- both are the same INV-8 class of
  # bug as a non-map value, just a shape the first rework iteration's guard
  # didn't anticipate. Confirmed empirically for all four cases -- see this
  # handoff's regression check.
  defp validate_metadata(metadata) when not is_map(metadata) or is_struct(metadata) do
    {:error, {:invalid_metadata, :not_a_map}}
  end

  defp validate_metadata(metadata) when map_size(metadata) > @metadata_max_entries do
    {:error, {:invalid_metadata, :too_many_entries}}
  end

  defp validate_metadata(metadata) do
    Enum.find_value(metadata, {:ok, metadata}, fn {key, value} ->
      cond do
        not is_binary(key) ->
          {:error, {:invalid_metadata, {:non_string_key, key}}}

        String.length(key) > @metadata_key_max_length ->
          {:error, {:invalid_metadata, {:key_too_long, key}}}

        not is_binary(value) ->
          {:error, {:invalid_metadata, {:non_string_value, key}}}

        String.length(value) > @metadata_value_max_length ->
          {:error, {:invalid_metadata, {:value_too_long, key}}}

        true ->
          nil
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Transactional phase (design doc §6.2) -- one Ecto.Multi,
  # prefix: schema_name on every operation.
  # ---------------------------------------------------------------------

  defp build_multi(ctx) do
    Multi.new()
    |> Multi.run(:active_instance_guard, fn repo, changes ->
      active_instance_guard(repo, changes, ctx)
    end)
    |> Multi.run(:assign_sequence, fn repo, changes -> assign_sequence(repo, changes, ctx) end)
    |> Multi.run(:idempotency, fn repo, changes -> claim_idempotency(repo, changes, ctx) end)
    |> Multi.run(:insert_event, fn repo, changes -> insert_event(repo, changes, ctx) end)
    |> maybe_store_oversized_payload(ctx)
    |> Multi.run(:update_projection, fn repo, changes -> update_projection(repo, changes, ctx) end)
  end

  defp maybe_store_oversized_payload(multi, %{payload_bytes: payload_bytes} = ctx)
       when payload_bytes > @payload_inline_max_bytes do
    Multi.run(multi, :store_oversized_payload, fn repo, changes ->
      store_oversized_payload(repo, changes, ctx)
    end)
  end

  defp maybe_store_oversized_payload(multi, _ctx), do: multi

  # M1 -- active-instance guard (invariant 10, ES-01). A plain, unlocked read
  # (design doc §6.2.1 -- a stronger guarantee, e.g. locking
  # instance_projections for the append's duration, is design doc OQ-6, not
  # built here). Update-only per REVIEWER's Step 2d OQ-5 ruling: append/2
  # never originates an instance_projections row. No row found is a hard
  # failure, {:error, :instance_not_started} -- a DISTINCT case from
  # :instance_terminated below, not an implicit new/active instance. On
  # success, the actual %InstanceProjection{} struct is returned (not a bare
  # atom) so M6 (update_projection/3) can read its current `status` back via
  # `changes.active_instance_guard` and thread it, unchanged, into
  # InstanceProjection.update_changeset/2 without a second DB read.
  defp active_instance_guard(repo, _changes, %{instance_id: instance_id, schema_name: schema_name}) do
    case repo.get(InstanceProjection, instance_id, prefix: schema_name) do
      nil ->
        {:error, :instance_not_started}

      %InstanceProjection{status: status} = projection ->
        if InstanceProjection.terminal?(status) do
          {:error, {:instance_terminated, status}}
        else
          {:ok, projection}
        end
    end
  end

  # M2 -- sequence assignment: the FOR-UPDATE-equivalent locking protocol
  # (invariant 2/4, ES-02, design doc §6.2.2). Three sub-steps: (i)
  # insert-if-absent (on_conflict: :nothing keyed on instance_id -- one
  # atomic statement, not a racy existence-check-then-insert), (ii) a row-lock
  # read (Ecto's `lock: "FOR UPDATE"` query composition, per INV-7 -- never a
  # hand-written SQL string), (iii) increment under the still-held lock.
  defp assign_sequence(repo, _changes, %{instance_id: instance_id, schema_name: schema_name}) do
    insert_changeset =
      InstanceSequence.insert_changeset(%InstanceSequence{}, %{instance_id: instance_id})

    case repo.insert(insert_changeset,
           on_conflict: :nothing,
           conflict_target: :instance_id,
           prefix: schema_name
         ) do
      {:ok, _} -> lock_and_increment_sequence(repo, instance_id, schema_name)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp lock_and_increment_sequence(repo, instance_id, schema_name) do
    locked =
      InstanceSequence
      |> where([s], s.instance_id == ^instance_id)
      |> lock("FOR UPDATE")
      |> repo.one(prefix: schema_name)

    case locked do
      nil ->
        {:error, {:sequence_conflict, :row_missing_after_insert}}

      %InstanceSequence{next_seq: assigned_sequence_number} ->
        InstanceSequence
        |> where([s], s.instance_id == ^instance_id)
        |> repo.update_all([set: [next_seq: assigned_sequence_number + 1]], prefix: schema_name)
        |> case do
          {1, _} -> {:ok, assigned_sequence_number}
          _ -> {:error, {:sequence_conflict, :unexpected_update_count}}
        end
    end
  end

  # M3 -- idempotency check/insert (invariant 4, ES-03, design doc §6.2.3).
  # Reuses the "attempt an insert, then re-select to disambiguate outcome"
  # idiom already shipped in
  # Letflow.TenantProvisioning.insert_or_fetch_registration/2: `id` is
  # client-generated (well, Ecto-client-side autogenerated) via `binary_id`,
  # so a bare {:ok, struct} from an on_conflict: :nothing insert can't by
  # itself distinguish "really inserted" from "suppressed".
  defp claim_idempotency(repo, _changes, %{
         idempotency_key: idempotency_key,
         event_id: event_id,
         created_at: created_at,
         schema_name: schema_name
       }) do
    changeset =
      IdempotencyRecord.insert_changeset(%IdempotencyRecord{}, %{
        idempotency_key: idempotency_key,
        event_id: event_id,
        event_created_at: created_at
      })

    case repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :idempotency_key,
           prefix: schema_name
         ) do
      {:ok, %IdempotencyRecord{id: attempted_id}} ->
        case repo.get(IdempotencyRecord, attempted_id, prefix: schema_name) do
          %IdempotencyRecord{} = claimed -> {:ok, {:claimed, claimed}}
          nil -> resolve_duplicate(repo, idempotency_key, schema_name)
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp resolve_duplicate(repo, idempotency_key, schema_name) do
    case repo.get_by(IdempotencyRecord, [idempotency_key: idempotency_key], prefix: schema_name) do
      nil ->
        {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}

      %IdempotencyRecord{event_id: event_id, event_created_at: event_created_at} ->
        Event
        |> where([e], e.event_id == ^event_id and e.created_at == ^event_created_at)
        |> repo.one(prefix: schema_name)
        |> case do
          nil -> {:error, {:idempotency_lookup_failed, :original_event_missing}}
          %Event{} = original_event -> {:error, {:duplicate_idempotency_key, original_event}}
        end
    end
  end

  # M4 -- insert the `events` row (invariant 5/7, ES-01/02/03/05/08, design
  # doc §6.2.4). event_id/created_at come from ctx (minted once, P6);
  # sequence_number comes from M2's result; tenant_id comes from ctx's
  # derived value -- never anything attrs-supplied.
  defp insert_event(repo, %{assign_sequence: assigned_sequence_number}, %{
         event_id: event_id,
         created_at: created_at,
         instance_id: instance_id,
         event_type: event_type,
         actor_id: actor_id,
         idempotency_key: idempotency_key,
         metadata: metadata,
         tenant_id: tenant_id,
         schema_name: schema_name,
         payload_bytes: payload_bytes,
         decoded_payload: decoded_payload
       }) do
    payload_field =
      if payload_bytes <= @payload_inline_max_bytes do
        decoded_payload
      else
        %{"$ref" => event_id}
      end

    attrs = %{
      event_id: event_id,
      created_at: created_at,
      instance_id: instance_id,
      event_type: event_type,
      payload: payload_field,
      actor_id: actor_id,
      sequence_number: assigned_sequence_number,
      idempotency_key: idempotency_key,
      metadata: metadata,
      tenant_id: tenant_id
    }

    %Event{}
    |> Event.insert_changeset(attrs)
    |> repo.insert(prefix: schema_name)
  end

  # M5 -- store the oversized payload (invariant 7, design doc §6.2.5). Only
  # included in the Multi pipeline at all when payload_bytes > 4096 (see
  # maybe_store_oversized_payload/2 above). Must run after M4: the composite
  # FK requires the events row to exist first.
  defp store_oversized_payload(repo, %{insert_event: %Event{} = event}, %{
         payload_bytes: payload_bytes,
         decoded_payload: decoded_payload,
         schema_name: schema_name
       }) do
    attrs = %{
      event_id: event.event_id,
      event_created_at: event.created_at,
      payload: decoded_payload,
      byte_size: payload_bytes
    }

    %Letflow.EventStore.StoredPayload{}
    |> Letflow.EventStore.StoredPayload.insert_changeset(attrs)
    |> repo.insert(prefix: schema_name)
  end

  # M6 -- instance_projections update (invariant 6, DB-03, design doc
  # §6.2.6). Update-only per REVIEWER's Step 2d OQ-5 ruling -- this step
  # never creates a row. M1 (active_instance_guard/3) already guarantees, by
  # the time this step runs, that a row exists and is non-terminal (a
  # missing or terminal row aborts the whole Multi before M6 is ever
  # reached). Uses InstanceProjection.update_changeset/2 -- never
  # insert_changeset/2, never an on_conflict:-based upsert. Only
  # last_event_seq (and, via update_changeset/2's touch of updated_at,
  # the timestamp) actually changes; status is passed through unchanged
  # from the struct M1 already read back, purely to satisfy
  # update_changeset/2's validate_required([:status, :last_event_seq]) --
  # an ordinary append must never itself overwrite status (that belongs to
  # EE-01/S3), and tenant_id is not castable by update_changeset/2 at all.
  defp update_projection(
         repo,
         %{
           assign_sequence: assigned_sequence_number,
           active_instance_guard: %InstanceProjection{} = projection
         },
         %{schema_name: schema_name}
       ) do
    attrs = %{status: projection.status, last_event_seq: assigned_sequence_number}

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: schema_name)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §6.3).
  # ---------------------------------------------------------------------

  defp interpret_transaction_result(
         {:ok, %{insert_event: %Event{} = event, assign_sequence: sequence_number}}
       ) do
    {:ok,
     %{
       event: event,
       is_duplicate: false,
       sequence_number: sequence_number,
       global_seq: event.global_seq
     }}
  end

  defp interpret_transaction_result(
         {:error, :active_instance_guard, {:instance_terminated, status}, _changes}
       ) do
    {:error, {:instance_terminated, status}}
  end

  defp interpret_transaction_result(
         {:error, :idempotency, {:duplicate_idempotency_key, %Event{} = original_event}, _changes}
       ) do
    {:ok,
     %{
       event: original_event,
       is_duplicate: true,
       sequence_number: original_event.sequence_number,
       global_seq: original_event.global_seq
     }}
  end

  defp interpret_transaction_result(
         {:error, :insert_event, %Ecto.Changeset{} = changeset, _changes}
       ) do
    if sequence_conflict?(changeset) do
      {:error, {:sequence_conflict, changeset}}
    else
      {:error, changeset}
    end
  end

  # Catch-all -- also where {:error, :active_instance_guard, :instance_not_started,
  # _changes} (M1's no-row case) lands: no dedicated clause needed above since
  # this generic pass-through already re-surfaces the reason unchanged as
  # {:error, :instance_not_started}, matching append_error()'s explicit tag.
  defp interpret_transaction_result({:error, _failed_operation, reason, _changes}) do
    {:error, reason}
  end

  defp sequence_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "uq_event_sequence"
    end)
  end
end
