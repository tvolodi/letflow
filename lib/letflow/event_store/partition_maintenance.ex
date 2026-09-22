defmodule Letflow.EventStore.PartitionMaintenance do
  @moduledoc """
  REQ-376 — Postgres-native monthly partitioning maintenance for `events`/
  `events_archive`: the pre-creation sweep (AC5) and the whole-partition
  retirement function (AC2/AC3/AC4). See
  `lib/letflow/design/req376-partition-event-retirement.md` for the full
  design this module implements, and
  `docs/migration/decisions/0037-event-store-partitioning-and-whole-partition-retirement.md`
  for the decision it implements.

  ## Scope

  `ensure_future_partitions/2` (§3) pre-creates `events`' own next
  `months_ahead` monthly partitions so no `append/2` write ever waits on
  partition creation. It does NOT pre-create any `events_archive` partition
  (§3.2, revised) — `events_archive`'s only partitions come from the
  one-time migration backfill (historical months) and from
  `retire_month/3`'s own `ATTACH` step, each exactly once per month, at the
  moment that month retires.

  `retire_month/3` (§4) whole-partition-retires one calendar month:
  `DETACH PARTITION ... CONCURRENTLY` from `events`, then `ATTACH PARTITION`
  onto `events_archive` for the same month — never `DROP` (decision 0037).
  It is catalog-state-detected and idempotent/resumable (§4.3.1) — every
  call re-derives which step has already completed from Postgres's own
  catalogs (`pg_inherits`), never from state this module persists itself.

  ## Every DDL identifier here is system-derived, never user input (INV-7)

  `schema_name` is validated via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`
  before use (its own `"tenant_" <> <32 lowercase hex>` shape check).
  Partition/table names are built here only from that validated schema name
  plus a `year`/`month` pair this module itself computes or receives as
  typed integers — never from any request body, query param, or other
  caller-supplied string. `execute/1`-style raw SQL is unavoidable for
  partition DDL (Ecto's migration DSL has no `PARTITION BY` primitive, and
  this module isn't a migration at all — it runs at runtime, not migration
  time), but nothing here ever interpolates tenant- or user-supplied data
  into a SQL string; every value that plausibly could vary per call is
  passed as a bound query parameter, never string-interpolated into the
  query text itself, except identifiers (schema/table names), which SQL has
  no parameterization syntax for and which are always system-derived here.
  """

  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @default_months_ahead 2
  @default_min_partition_age_days 400
  @default_reconciliation_batch_size 5000

  @type resumed_from :: :not_started | :pending_detach | :detached_standalone | :already_retired

  # ===========================================================================
  # Config accessors (§4.2, §4.4b) -- same Application.get_env(:letflow,
  # :event_retention, ...) location/pattern as every other retention knob in
  # this codebase (Letflow.Scheduler's retention_days/2 accessor idiom).
  # ===========================================================================

  defp event_retention_config, do: Application.get_env(:letflow, :event_retention, [])

  @doc """
  Default lookahead (calendar months) `ensure_future_partitions/2` creates
  `events` partitions for, ahead of the current month. Config key
  `:months_ahead` under `:letflow, :event_retention`.
  """
  @spec months_ahead_default() :: pos_integer()
  def months_ahead_default do
    Keyword.get(event_retention_config(), :months_ahead, @default_months_ahead)
  end

  @doc """
  §4.2 eligibility rule's `min_partition_age_days` -- a month `M` is
  eligible for `retire_month/3` once `today >= last_day(M) + N` days.
  Deliberately config-driven and operator-tunable, not derived from
  `event_retention_policies`' own `keep_days`/`keep_count` values (§4.2's
  "why an early move is not a policy violation"). OQ4 (design §7): this
  default (400 days, > 1 calendar year) is a conservative starting point
  with no production data behind it yet -- revisit once real
  `event_retention_policies` usage is observable.
  """
  @spec min_partition_age_days() :: pos_integer()
  def min_partition_age_days do
    Keyword.get(
      event_retention_config(),
      :min_partition_age_days,
      @default_min_partition_age_days
    )
  end

  @doc """
  §4.4b's `reconciliation_batch_size` -- the fixed batch size
  `retire_month/3`'s `events_archive_default` reconciliation step uses.
  OQ7 (design §7): picked with no production data behind it yet, same
  category of gap as `min_partition_age_days/0`'s OQ4.
  """
  @spec reconciliation_batch_size() :: pos_integer()
  def reconciliation_batch_size do
    Keyword.get(
      event_retention_config(),
      :reconciliation_batch_size,
      @default_reconciliation_batch_size
    )
  end

  # ===========================================================================
  # ensure_future_partitions/2 (§3 -- AC5)
  # ===========================================================================

  @doc """
  Pre-creates `events`' own next `opts[:months_ahead]` (default
  `months_ahead_default/0`) monthly partitions, for the tenant schema named
  `schema_name`, if they don't already exist. `events_archive` gets no
  forward-looking partitions from this function (§3.2, revised) -- see this
  module's moduledoc.

  Each `CREATE TABLE ... PARTITION OF` is preceded by an existence check
  (`IF NOT EXISTS` is not valid syntax for `PARTITION OF` in Postgres) --
  metadata-only against an as-yet-empty relation, sub-millisecond, no lock
  that conflicts with concurrent DML on any other partition (§3.2).
  """
  @spec ensure_future_partitions(schema_name :: String.t(), opts :: [months_ahead: pos_integer()]) ::
          {:ok, %{events_created: [String.t()], archive_created: [String.t()]}}
          | {:error, :invalid_schema_name}
          | {:error, term()}
  def ensure_future_partitions(schema_name, opts \\ []) when is_binary(schema_name) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(schema_name) do
      months_ahead = Keyword.get(opts, :months_ahead, months_ahead_default())
      months = months_window(months_ahead)

      events_created =
        months
        |> Enum.map(&maybe_create_events_partition(schema_name, &1))
        |> Enum.reject(&is_nil/1)

      {:ok, %{events_created: events_created, archive_created: []}}
    end
  end

  defp months_window(months_ahead) do
    today = Date.utc_today()
    current = {today.year, today.month}

    0..months_ahead
    |> Enum.map(fn offset -> shift_months(current, offset) end)
  end

  defp shift_months({year, month}, 0), do: {year, month}

  defp shift_months({year, month}, offset) when offset > 0 do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp maybe_create_events_partition(schema_name, {year, month}) do
    partition = partition_name("events", year, month)

    if partition_exists?(schema_name, partition) do
      nil
    else
      create_partition!(schema_name, "events", partition, year, month)
      partition
    end
  end

  defp partition_exists?(schema_name, partition_name) do
    %Postgrex.Result{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2)",
        [schema_name, partition_name]
      )

    exists
  end

  # `FOR VALUES FROM (...) TO (...)` is a partition-bound clause -- Postgres
  # requires these to be constant expressions resolved at DDL-parse time, not
  # bind parameters (confirmed empirically: Postgrex/Postgres rejects a
  # parameterized FOR VALUES clause with "parameters must be of length 0",
  # since the prepared statement carries zero parameter slots for this
  # clause). `from_bound`/`to_bound` are inline-interpolated here as a
  # result -- still never user input (INV-7): both come from `month_bounds/2`,
  # itself built only from this module's own validated `year`/`month`
  # integers, in the exact `'YYYY-MM-01'` shape every migration in this
  # requirement's own set already uses the same way for the identical reason.
  defp create_partition!(schema_name, parent, partition_name, year, month) do
    {from_bound, to_bound} = month_bounds(year, month)

    Repo.query!(
      ~s{CREATE TABLE "#{schema_name}"."#{partition_name}" PARTITION OF "#{schema_name}"."#{parent}" FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )

    :ok
  end

  # ===========================================================================
  # retire_month/3 (§4 -- AC2/AC3/AC4)
  # ===========================================================================

  @type retire_month_error ::
          {:error, :invalid_schema_name}
          | {:error, :partition_not_eligible}
          | {:error, :partition_not_found}
          | {:error, {:stuck_pending_detach, term()}}
          | {:error, term()}

  @doc """
  Whole-partition-retires calendar month `year`-`month` for tenant schema
  `schema_name` (§4). Idempotent and resumable (§4.3.1) -- every call
  re-derives, from Postgres's own catalogs, which step has already
  completed and resumes from there. See this module's moduledoc.
  """
  @spec retire_month(schema_name :: String.t(), year :: pos_integer(), month :: 1..12) ::
          {:ok,
           %{
             retired_partition: String.t(),
             protected_rows_relocated: non_neg_integer(),
             default_partition_rows_reconciled: non_neg_integer(),
             resumed_from: resumed_from()
           }}
          | retire_month_error()
  def retire_month(schema_name, year, month)
      when is_binary(schema_name) and is_integer(year) and month in 1..12 do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(schema_name) do
      # IMPORTANT DEVIATION FROM THE APPROVED DESIGN, discovered only by
      # testing against real Postgres (16) -- flagged here explicitly for
      # REVIEWER's Step 2d attention, not silently patched around. Postgres
      # rejects `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` outright
      # whenever the parent has a DEFAULT partition attached (confirmed
      # empirically: 55000 object_not_in_prerequisite_state, "cannot detach
      # partitions concurrently when a default partition exists"). `events`
      # ALWAYS has one -- `events_default`, migration 2's own AC5/OQ1 safety
      # net -- so §4.3 step 2 as originally approved (DETACH ... CONCURRENTLY
      # against a table that permanently carries a DEFAULT partition) can
      # never actually succeed in this codebase; this is not a transient or
      # edge-case failure, every single `retire_month/3` call would hit it.
      # Fix applied here: self-healingly ensure `events_default` is
      # temporarily detached (idempotent -- a no-op if it's already detached,
      # e.g. resuming after a crash mid-retirement) immediately before the
      # real CONCURRENTLY detach, and reattached immediately after -- see
      # `ensure_default_partition_detached!/1`/`ensure_default_partition_reattached!/1`
      # below. Called unconditionally at the TOP of every retire_month/3 call
      # (before dispatching on catalog_state/2), not only from the
      # `:not_started` path, so a crash that left the default partition
      # detached self-heals on the very next call for ANY month, matching
      # this module's existing "catalog-detected, never self-persisted"
      # philosophy (§4.3.1) rather than adding a new bookkeeping mechanism.
      # Trade-off, stated honestly: for the brief window between the default
      # partition's own detach and reattach, a write whose created_at falls
      # outside every pre-created partition's range (the exact case
      # events_default exists to catch, §3.3 OQ3) would fail instead of
      # being caught by the safety net -- expected rare (events_default is
      # designed to stay empty in steady state) and narrow (metadata-only
      # operations on both sides), but a real, non-zero-probability window
      # that the original CONCURRENTLY-only design did not have. REVIEWER
      # should confirm this trade-off is acceptable, or direct a different
      # resolution (e.g. dropping the DEFAULT partition safety net entirely,
      # which OQ1/AC5 explicitly wanted).
      ensure_default_partition_reattached!(schema_name)

      partition = partition_name("events", year, month)

      case catalog_state(schema_name, partition) do
        :not_found ->
          {:error, :partition_not_found}

        :not_started ->
          if eligible?(year, month) do
            do_not_started(schema_name, year, month, partition)
          else
            {:error, :partition_not_eligible}
          end

        :pending_detach ->
          do_pending_detach(schema_name, year, month, partition)

        :detached_standalone ->
          do_detached_standalone(schema_name, year, month, partition, 0)

        :already_retired ->
          do_already_retired(schema_name, year, month, partition)
      end
    end
  end

  defp eligible?(year, month) do
    {_from, %NaiveDateTime{} = next_month_start} = month_bounds(year, month)
    cutoff = Date.add(NaiveDateTime.to_date(next_month_start), min_partition_age_days())
    Date.compare(Date.utc_today(), cutoff) != :lt
  end

  # -- §4.3.1 catalog-state machine -------------------------------------------

  defp catalog_state(schema_name, partition_name) do
    cond do
      child_of?(schema_name, partition_name, "events_archive") ->
        :already_retired

      pending_detach?(schema_name, partition_name) ->
        :pending_detach

      child_of?(schema_name, partition_name, "events") ->
        :not_started

      standalone_exists?(schema_name, partition_name) ->
        :detached_standalone

      true ->
        :not_found
    end
  end

  # §4.3.2 -- child-of-<parent_table> catalog check, joined entirely on
  # pg_catalog rows (never string-built regclass casts), so `schema_name`/
  # `partition_name`/`parent_table` are always bound query parameters, never
  # interpolated into the SQL text.
  defp child_of?(schema_name, partition_name, parent_table) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_namespace pn ON pn.oid = p.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND pn.nspname = $1 AND p.relname = $3
        """,
        [schema_name, partition_name, parent_table]
      )

    rows != []
  end

  defp pending_detach?(schema_name, partition_name) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND i.inhdetachpending = true
        """,
        [schema_name, partition_name]
      )

    rows != []
  end

  defp standalone_exists?(schema_name, partition_name) do
    partition_exists?(schema_name, partition_name)
  end

  # -- §4.3.3 the steps themselves ---------------------------------------------

  defp do_not_started(schema_name, year, month, partition) do
    # §4.4b only, here -- the pre-detach step is now JUST the
    # events_archive_default reconciliation (see this module's own
    # "IMPLEMENTATION-DISCOVERED CORRECTION (further, found by testing)"
    # comment on count_protected_rows/2 below for why 4.4a's original
    # physical-relocation mechanism is gone entirely, not merely reordered).
    default_reconciled = reconcile_default_partition(schema_name, year, month, partition)

    detach_partition!(schema_name, partition)

    do_detached_standalone(
      schema_name,
      year,
      month,
      partition,
      default_reconciled,
      :not_started
    )
  end

  defp do_pending_detach(schema_name, year, month, partition) do
    case finalize_detach(schema_name, partition) do
      :ok ->
        do_detached_standalone(schema_name, year, month, partition, 0, :pending_detach)

      {:error, reason} ->
        {:error, {:stuck_pending_detach, reason}}
    end
  end

  defp do_detached_standalone(schema_name, year, month, partition, default_reconciled) do
    do_detached_standalone(
      schema_name,
      year,
      month,
      partition,
      default_reconciled,
      :detached_standalone
    )
  end

  defp do_detached_standalone(
         schema_name,
         year,
         month,
         partition,
         default_reconciled,
         resumed_from
       ) do
    constraint = bounds_constraint_name(year, month)
    {from_bound, to_bound} = month_bounds(year, month)

    ensure_bounds_constraint!(schema_name, partition, constraint, from_bound, to_bound)
    attach_partition!(schema_name, partition, from_bound, to_bound)
    drop_bounds_constraint!(schema_name, partition, constraint)

    # §4.4a, corrected: count_protected_rows/2 is read-only now (see its own
    # comment for the full "why") -- runs after ATTACH purely to report how
    # many keep_forever rows this retired partition carries; it never
    # mutates anything, so its position relative to ATTACH has no
    # correctness consequence either way (kept here, after, since the count
    # is only meaningful/cheap to state once the partition's final row set
    # -- including anything §4.4b swept in from events_archive_default -- is
    # settled).
    protected_relocated = count_protected_rows(schema_name, partition)

    {:ok,
     %{
       retired_partition: partition,
       protected_rows_relocated: protected_relocated,
       default_partition_rows_reconciled: default_reconciled,
       resumed_from: resumed_from
     }}
  end

  defp do_already_retired(schema_name, year, month, partition) do
    constraint = bounds_constraint_name(year, month)
    drop_bounds_constraint!(schema_name, partition, constraint)

    # Same read-only count as do_detached_standalone/6's final step, re-run
    # here so a resumed call against an already-fully-retired month still
    # reports an accurate protected_rows_relocated instead of a hardcoded 0
    # -- see count_protected_rows/2's own comment.
    protected_relocated = count_protected_rows(schema_name, partition)

    {:ok,
     %{
       retired_partition: partition,
       protected_rows_relocated: protected_relocated,
       default_partition_rows_reconciled: 0,
       resumed_from: :already_retired
     }}
  end

  # §4.3.3 step 2 -- DETACH ... CONCURRENTLY. See retire_month/3's own
  # top-of-function comment for why the default partition must be
  # temporarily detached first.
  defp detach_partition!(schema_name, partition) do
    ensure_default_partition_detached!(schema_name)

    Repo.query!(
      ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."#{partition}" CONCURRENTLY}
    )

    ensure_default_partition_reattached!(schema_name)

    :ok
  end

  @default_partition_name "events_default"

  # Idempotent: a no-op if events_default is already detached (e.g. this is
  # a resumed call after a crash between the two detach_partition!/2 calls
  # above).
  defp ensure_default_partition_detached!(schema_name) do
    if default_partition_attached?(schema_name) do
      Repo.query!(
        ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."#{@default_partition_name}"}
      )
    end

    :ok
  end

  # Idempotent: a no-op if events_default is already attached. Called both
  # right after detach_partition!/2's own real detach, and unconditionally
  # at the top of every retire_month/3 call (self-healing a stray detached
  # default partition left by a crash between the two calls in
  # detach_partition!/2, regardless of which month's retirement caused it).
  defp ensure_default_partition_reattached!(schema_name) do
    unless default_partition_attached?(schema_name) do
      # events_default may not exist as a standalone relation at all if it
      # was never detached in the first place (the common case) -- only
      # attempt ATTACH when it exists but isn't currently attached.
      if partition_exists?(schema_name, @default_partition_name) do
        Repo.query!(
          ~s{ALTER TABLE "#{schema_name}"."events" ATTACH PARTITION "#{schema_name}"."#{@default_partition_name}" DEFAULT}
        )
      end
    end

    :ok
  end

  defp default_partition_attached?(schema_name) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class p ON p.oid = i.inhparent
        WHERE n.nspname = $1 AND c.relname = $2 AND p.relname = 'events'
        """,
        [schema_name, @default_partition_name]
      )

    rows != []
  end

  # §4.3.1 :pending_detach recovery -- Postgres's own documented FINALIZE
  # statement for an interrupted concurrent detach.
  defp finalize_detach(schema_name, partition) do
    Repo.query!(
      ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."#{partition}" FINALIZE}
    )

    :ok
  rescue
    error -> {:error, error}
  end

  # §4.3.3 step 3 -- pre-validated CHECK constraint (fast-attach idiom).
  # Existence-checked first, not attempt-and-catch, since a prior crash may
  # have completed ADD CONSTRAINT but not VALIDATE CONSTRAINT (§4.3.1
  # :detached_standalone note).
  # Same DDL-vs-bind-parameter restriction as create_partition!/5 applies to
  # this ADD CONSTRAINT's CHECK expression when issued via Postgrex's
  # extended query protocol against `ALTER TABLE`; inlined for the same
  # reason (system-derived bounds only, never user input -- INV-7).
  defp ensure_bounds_constraint!(schema_name, partition, constraint, from_bound, to_bound) do
    unless constraint_exists?(schema_name, partition, constraint) do
      Repo.query!(
        ~s{ALTER TABLE "#{schema_name}"."#{partition}" ADD CONSTRAINT "#{constraint}" CHECK (created_at >= '#{from_bound}'::timestamp AND created_at < '#{to_bound}'::timestamp) NOT VALID}
      )
    end

    Repo.query!(
      ~s{ALTER TABLE "#{schema_name}"."#{partition}" VALIDATE CONSTRAINT "#{constraint}"}
    )

    :ok
  end

  defp constraint_exists?(schema_name, partition, constraint) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_constraint co
        JOIN pg_class c ON c.oid = co.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND co.conname = $3
        """,
        [schema_name, partition, constraint]
      )

    rows != []
  end

  # §4.3.3 step 4 -- metadata-only ATTACH given step 3's pre-validated
  # constraint. Requires events_archive_default to hold no row in-range at
  # this moment -- guaranteed by §4.4b's events_archive_default
  # reconciliation having already run (on :not_started) or having already
  # been run by a prior call (on a resumed state -- the reconciliation is
  # itself idempotent, §4.4b crash-recovery note: already-relocated rows are
  # gone from events_archive_default, so a resumed call's own §4.4b -- if
  # re-entered -- naturally sees nothing left to move). §4.4a's keep_forever
  # accounting is now read-only (see count_protected_rows/2's own comment
  # for why physical relocation is impossible here), so it plays no part in
  # this precondition at all.
  # ANOTHER material deviation from the approved design, discovered only by
  # testing against real Postgres -- flagged here for REVIEWER's Step 2d
  # attention, same as the default-partition finding at the top of
  # retire_month/3. `events_archive` has one column `events` does not
  # (`archived_at`) -- decision 0037/the design doc's "same physical table,
  # just reparented, no row copy" framing for EO-003 did not account for
  # this: Postgres's ATTACH PARTITION requires the child to already carry
  # every column the parent has (confirmed empirically: 42804
  # datatype_mismatch, "child table is missing column \"archived_at\"").
  # Fixed here with `ensure_archived_at_column!/1` immediately before
  # ATTACH -- adds the column with a CONSTANT literal default (a snapshot of
  # `DateTime.utc_now()` taken once, formatted as a literal, NOT a `now()`
  # function call), which Postgres's fast-default optimization (v11+)
  # applies as a metadata-only catalog change for existing rows, not a
  # per-row table rewrite -- so this stays consistent with AC2's "whole-unit
  # DDL, no per-row work" property. A `now()`-function default here instead
  # would have been volatile (not a true constant), forcing exactly the
  # full-table rewrite this design exists to avoid.
  defp attach_partition!(schema_name, partition, from_bound, to_bound) do
    ensure_archived_at_column!(schema_name, partition)

    Repo.query!(
      ~s{ALTER TABLE "#{schema_name}"."events_archive" ATTACH PARTITION "#{schema_name}"."#{partition}" FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )

    :ok
  end

  defp ensure_archived_at_column!(schema_name, partition) do
    unless column_exists?(schema_name, partition, "archived_at") do
      literal_now = DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.to_string()

      Repo.query!(
        ~s{ALTER TABLE "#{schema_name}"."#{partition}" ADD COLUMN archived_at timestamp NOT NULL DEFAULT '#{literal_now}'}
      )
    end

    :ok
  end

  defp column_exists?(schema_name, table_name, column_name) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [schema_name, table_name, column_name]
      )

    rows != []
  end

  # §4.3.3 step 5 -- cleanup.
  defp drop_bounds_constraint!(schema_name, partition, constraint) do
    if constraint_exists?(schema_name, partition, constraint) do
      Repo.query!(~s{ALTER TABLE "#{schema_name}"."#{partition}" DROP CONSTRAINT "#{constraint}"})
    end

    :ok
  end

  # -- §4.4 step 1 (4.4b -- events_archive_default reconciliation, runs
  # BEFORE detach, called directly from do_not_started/4) and, further down
  # this module, §4.4a (keep_forever relocation, runs AFTER attach, called
  # from do_detached_standalone/6 and do_already_retired/4) -------------

  # §4.4b -- batched, bounded reconciliation. Fixed-size batches, one
  # Repo.transaction/1 per batch, SELECT...LIMIT with no OFFSET (each
  # batch's DELETE physically removes the just-processed rows, so the next
  # SELECT naturally advances over what remains). Terminates when a batch
  # returns fewer rows than reconciliation_batch_size/0.
  defp reconcile_default_partition(schema_name, year, month, partition) do
    {from_bound, to_bound} = month_bounds(year, month)
    batch_size = reconciliation_batch_size()

    do_reconcile_default_partition_loop(
      schema_name,
      partition,
      from_bound,
      to_bound,
      batch_size,
      0
    )
  end

  defp do_reconcile_default_partition_loop(
         schema_name,
         partition,
         from_bound,
         to_bound,
         batch_size,
         total
       ) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        ~s{SELECT event_id, created_at FROM "#{schema_name}"."events_archive_default" WHERE created_at >= $1::timestamp AND created_at < $2::timestamp ORDER BY created_at, event_id LIMIT $3},
        [from_bound, to_bound, batch_size]
      )

    count = length(rows)

    if count == 0 do
      total
    else
      relocate_default_batch!(schema_name, partition, rows)

      if count < batch_size do
        total + count
      else
        do_reconcile_default_partition_loop(
          schema_name,
          partition,
          from_bound,
          to_bound,
          batch_size,
          total + count
        )
      end
    end
  end

  defp relocate_default_batch!(schema_name, partition, rows) do
    event_ids = Enum.map(rows, fn [event_id, _created_at] -> event_id end)
    created_ats = Enum.map(rows, fn [_event_id, created_at] -> created_at end)

    # Explicit column list, never `SELECT *`: events_archive_default's shape
    # carries one column (`archived_at`) the destination `events`-partition
    # table does not have.
    Repo.transaction(fn ->
      Repo.query!(
        ~s{INSERT INTO "#{schema_name}"."#{partition}" (event_id, created_at, instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata, global_seq) SELECT event_id, created_at, instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata, global_seq FROM "#{schema_name}"."events_archive_default" WHERE event_id = ANY($1) AND created_at = ANY($2)},
        [event_ids, created_ats]
      )

      Repo.query!(
        ~s{DELETE FROM "#{schema_name}"."events_archive_default" WHERE event_id = ANY($1) AND created_at = ANY($2)},
        [event_ids, created_ats]
      )
    end)

    :ok
  end

  # §4.4a -- keep_forever accounting.
  #
  # IMPLEMENTATION-DISCOVERED CORRECTION (further, found by testing --
  # TEST-DESIGN-VALIDATOR's Step 3b EO-002 gate, 2026-09-22, and confirmed by
  # ELIXIR-DEV's own independent empirical re-check during this rework):
  # this function used to physically relocate keep_forever rows via
  # INSERT-then-DELETE into `events_archive_default` -- first (in the
  # originally-approved design and its first implementation) BEFORE
  # `detach_partition!/2`, relying on `events_archive` parent-table routing;
  # then (this rework's first attempt, per this rework's own task
  # instructions) AFTER `attach_partition!/4`, targeting
  # `events_archive_default` directly. BOTH ARE IMPOSSIBLE, not just the
  # first: Postgres's default-partition mechanism enforces, unconditionally,
  # that NO row in a DEFAULT partition may ever fall within the range of any
  # sibling partition attached to the same parent -- checked constructively
  # on `ATTACH` (rejects an `ATTACH` if the default already holds an
  # in-range row: `23514 check_violation`, confirmed 3/3 real Postgres 16
  # runs at Step 3b) and reactively on plain `INSERT` once that sibling IS
  # attached (rejects the `INSERT` itself: `23514 check_violation`,
  # "new row for relation \"events_archive_default\" violates partition
  # constraint" -- confirmed independently via a minimal two-statement
  # reproduction against this workspace's real Postgres 16 instance during
  # this rework, isolated from the rest of this module's own logic). There
  # is no third ordering: for the exact calendar month this call is
  # retiring, `events_archive_default` can NEVER durably hold a row in that
  # month's range, neither before, during, nor after this month's own
  # `ATTACH`, for as long as that month has its own dedicated
  # `events_archive` partition (which `retire_month/3` always gives it, by
  # design).
  #
  # Given that, decision 0037/this design's §4.4a original goal --
  # physically moving keep_forever rows into `events_archive_default` so a
  # HYPOTHETICAL future per-partition-DROP purge tier could drop a whole
  # month's partition without losing protected data -- cannot be achieved by
  # relocating rows anywhere within the CURRENT schema for a month that gets
  # its own retired partition; the only table that can hold such a row is
  # the retiring partition itself.
  #
  # Correct resolution (this rework): no physical relocation at all.
  # Decision 0037 already commits this design to NEVER `DROP` a partition --
  # only `DETACH`+`ATTACH`, permanently -- so every row in the retiring
  # partition, keep_forever or not, already survives this call intact,
  # carried across from `events` to `events_archive` by the whole-partition
  # `DETACH`/`ATTACH` itself (§4.3.3), with no row copy. A keep_forever row
  # needs no SEPARATE protection mechanism today: it is exactly as
  # permanently retained as every other row in its month, because nothing in
  # this codebase ever drops a retired partition. This function is now
  # read-only -- it counts how many keep_forever-policy rows the retiring
  # partition carries (for `protected_rows_relocated`'s informational value:
  # "how many protected rows this retirement covered", not "how many rows
  # were physically moved") and issues no `INSERT`/`DELETE`. §4.4b's own
  # reconciliation (above) already folds in any keep_forever row that had
  # separately landed in `events_archive_default` via `archive/1`'s early
  # per-row path before this month retired, so this count is accurate
  # regardless of a row's origin. If a future per-partition-DROP purge tier
  # is ever built, protecting keep_forever rows from IT will need its own
  # mechanism at that time (most likely: exempting matching partitions from
  # that future DROP entirely, or moving keep_forever rows to a table
  # outside this partition scheme's date-range constraint before that
  # specific DROP) -- out of REQ-376's scope, flagged here for whoever
  # designs that tier.
  defp count_protected_rows(schema_name, partition) do
    keep_forever_types = keep_forever_event_types()

    if keep_forever_types == [] do
      0
    else
      %Postgrex.Result{rows: [[count]]} =
        Repo.query!(
          ~s{SELECT count(*) FROM "#{schema_name}"."#{partition}" WHERE event_type = ANY($1)},
          [keep_forever_types]
        )

      count
    end
  end

  defp keep_forever_event_types do
    Letflow.EventStore.RetentionPolicy
    |> where([p], p.policy == :keep_forever)
    |> select([p], p.event_type)
    |> Repo.all()
  end

  # ===========================================================================
  # Naming helpers (§2.2)
  # ===========================================================================

  defp partition_name(prefix, year, month) do
    "#{prefix}_y#{year}m#{pad2(month)}"
  end

  defp bounds_constraint_name(year, month) do
    "chk_partition_bounds_#{year}_#{pad2(month)}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Returns NaiveDateTime structs, not strings -- this value is used two
  # ways by this module's callers: (a) inline-interpolated into DDL text
  # (CREATE TABLE ... FOR VALUES FROM/TO, ADD CONSTRAINT CHECK, ATTACH
  # PARTITION ... FOR VALUES FROM/TO) since Postgres partition-bound clauses
  # reject bind parameters outright (confirmed empirically -- see
  # create_partition!/5's comment); NaiveDateTime's String.Chars produces a
  # valid quoted timestamp literal there ("2024-01-01 00:00:00"). (b) passed
  # as a genuine Postgrex bind parameter in
  # do_reconcile_default_partition_loop/6's ordinary (non-DDL) SELECT --
  # Postgrex's timestamp encoder requires a %NaiveDateTime{}/%DateTime{}
  # struct, not a plain string (confirmed empirically: "Postgrex expected
  # %DateTime{} or %NaiveDateTime{}, got ..." when a bare string was passed).
  # One return shape serves both call sites correctly.
  defp month_bounds(year, month) do
    from = NaiveDateTime.new!(year, month, 1, 0, 0, 0)
    {next_year, next_month} = shift_months({year, month}, 1)
    to = NaiveDateTime.new!(next_year, next_month, 1, 0, 0, 0)
    {from, to}
  end
end
