defmodule Letflow.TenantSchemaReaper do
  @moduledoc """
  Suite-boundary reaper for orphaned `tenant_schemas` rows (ISS-0064).

  See `lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md` for the full design
  and rationale — this module implements that design exactly; do not add behavior
  beyond it without a design update.

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per `mix.exs`) —
  **not** part of the shipped application and never added to
  `lib/letflow/application.ex`'s supervision tree. Not a GenServer, not a supervised
  process of any kind — a plain module with one public function.

  ## Why this exists

  30+ test files provision a real (non-sandboxed) tenant schema via
  `Letflow.TenantProvisioning.provision_tenant_schema/1` and rely solely on a
  manually-registered `on_exit/1` callback to clean it up. `on_exit/1` callbacks only
  run if ExUnit gets the chance to schedule them — a killed or hard-timed-out test
  process silently orphans the `tenant_schemas` row (and its real Postgres schema),
  and orphans accumulate across `mix test` invocations, eventually tripping
  `test/letflow/identity_migration_test.exs`'s `DropLegacyPublicIdentityTables` guard
  tests (ISS-0048/ISS-0050/ISS-0064).

  `sweep_orphans/2` is called once before `ExUnit.start()` and once via
  `ExUnit.after_suite/1` (`test/test_helper.exs`) — the two points in every `mix test`
  invocation where "currently active" is guaranteed to be the empty set FOR THIS
  INVOCATION. See the design doc §2 for the full argument.

  ## ISS-0110 — liveness guard against a concurrent invocation

  The argument above only ever covered THIS invocation's own activity. It says
  nothing about a second, concurrently-running `mix test` invocation sharing the same
  database (ISS-0107 showed a nested invocation really can — it inherits
  `LETFLOW_DB_PORT`/`MIX_TEST_PARTITION` via `Port.open`'s environment inheritance)
  whose own tenant schemas are still genuinely in use despite being older than
  `min_age_seconds` (the suite now regularly runs 564-609s, well past the original
  300s default).

  This module has no per-row ownership tracking (adding one would mean a migration on
  the production `tenant_schemas` table for a test-only concern, or hooking every one
  of the ~40 test-file call sites that provision a tenant schema — both rejected as
  disproportionate to the actual hazard). Instead it asks a coarser, sufficient
  question: **is any OTHER `mix test` invocation currently connected to this database
  at all, right now?** `config/test.exs` tags every connection this invocation opens
  with `application_name: "letflow_mixtest_\#{System.pid()}"` — stable for this
  invocation's whole lifetime, and distinct per invocation (a nested invocation is a
  distinct OS process, hence a distinct `System.pid()`). `sweep_orphans/2` checks
  `pg_stat_activity` for any *other* `letflow_mixtest_*` tag before touching anything.

  If another invocation is present, the sweep defers ENTIRELY for this call — not just
  for that invocation's own rows, since without per-row ownership there is no way to
  tell which old rows belong to the live invocation and which are genuinely orphaned
  from some third, already-dead one. This trades promptness (orphan cleanup can be
  delayed while a second invocation is running) for correctness (never guesses), which
  is the direction ISS-0110 asks for explicitly. The next sweep — this invocation's
  own `after_suite`, or a later invocation's own pre-`ExUnit.start()` sweep — retries
  and proceeds normally once the database is single-occupant again.

  This does NOT weaken the original ISS-0064 guarantee: a schema whose owning
  invocation's OS process has genuinely died closes every connection it held (TCP-level,
  unconditionally), so its `application_name` tag stops appearing in `pg_stat_activity`
  and the very next sweep (by any invocation) reclaims it exactly as before.
  """

  require Logger

  alias Ecto.Adapters.SQL.Sandbox

  # Mirrors Letflow.TenantProvisioning.Registration's own @schema_name_format
  # (lib/letflow/tenant_provisioning/registration.ex) — literal duplicate, not a
  # shared reference, since that module attribute is private and this is a
  # test-only module living outside lib/letflow/ (design doc §4 INV-R-1, §8 OQ-3).
  # Keep both in sync if either ever changes.
  @schema_name_format ~r/^tenant_[0-9a-f]{32}$/

  @default_min_age_seconds 300

  @doc """
  Reclaims `tenant_schemas` rows old enough (`provisioned_at` older than
  `min_age_seconds`) to no longer plausibly belong to an in-progress test, in this
  invocation — but only once it has confirmed (ISS-0110) that no OTHER `mix test`
  invocation is currently connected to this database at all. If one is, the sweep
  defers entirely (see the moduledoc's "ISS-0110" section for why entirely, not just
  for that invocation's own rows) and reports the same shape as a genuinely empty
  sweep, distinguishable only via the log line.

  Never raises to its caller — an outer failure (e.g. the bulk `SELECT` itself
  raising, or either `Sandbox.mode/2` call raising) is caught, logged, and reported
  back identically to a genuinely empty sweep (`{:ok, %{reclaimed: 0,
  skipped_invalid_format: 0}}`); only the log output distinguishes the two cases.
  See the design doc §3.1/§3.2 for the full failure-mode contract.
  """
  @spec sweep_orphans(repo :: module(), min_age_seconds :: non_neg_integer()) ::
          {:ok, %{reclaimed: non_neg_integer(), skipped_invalid_format: non_neg_integer()}}
  def sweep_orphans(repo \\ Letflow.Repo, min_age_seconds \\ @default_min_age_seconds) do
    try do
      Sandbox.mode(repo, :auto)

      own_tag = current_application_name(repo)

      if concurrent_invocation_present?(repo, own_tag) do
        Logger.info(
          "TenantSchemaReaper.sweep_orphans/2: deferring this sweep entirely -- " <>
            "another mix test invocation (application_name != #{inspect(own_tag)}) is " <>
            "currently connected to this database, and this module tracks no per-row " <>
            "ownership, so an age-based reap right now could reclaim that invocation's " <>
            "still-live tenant schema (ISS-0110). Retrying on the next boundary sweep."
        )

        {:ok, %{reclaimed: 0, skipped_invalid_format: 0}}
      else
        cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-min_age_seconds, :second)

        %{rows: rows} =
          repo.query!(
            "SELECT id, tenant_id, schema_name FROM tenant_schemas WHERE provisioned_at < $1",
            [cutoff]
          )

        {reclaimed, skipped_invalid_format} =
          Enum.reduce(rows, {0, 0}, fn [id, tenant_id, schema_name],
                                       {reclaimed_acc, skipped_acc} ->
            if Regex.match?(@schema_name_format, schema_name) do
              if reclaim_row(repo, %{id: id, tenant_id: tenant_id, schema_name: schema_name}) do
                {reclaimed_acc + 1, skipped_acc}
              else
                {reclaimed_acc, skipped_acc}
              end
            else
              Logger.warning(
                "TenantSchemaReaper.sweep_orphans/2: skipping tenant_schemas row id=#{Ecto.UUID.cast!(id)} " <>
                  "tenant_id=#{Ecto.UUID.cast!(tenant_id)} with malformed schema_name=#{inspect(schema_name)}"
              )

              {reclaimed_acc, skipped_acc + 1}
            end
          end)

        {:ok, %{reclaimed: reclaimed, skipped_invalid_format: skipped_invalid_format}}
      end
    rescue
      exception ->
        Logger.error(
          "TenantSchemaReaper.sweep_orphans/2 aborted: #{Exception.format(:error, exception, __STACKTRACE__)}"
        )

        {:ok, %{reclaimed: 0, skipped_invalid_format: 0}}
    after
      Sandbox.mode(repo, :manual)
    end
  end

  # The application_name this connection was opened with -- config/test.exs sets it
  # to "letflow_mixtest_#{System.pid()}" for every connection this invocation opens
  # (ISS-0110), so any connection this repo hands back reports the same value.
  defp current_application_name(repo) do
    %{rows: [[name]]} = repo.query!("SHOW application_name")
    name
  end

  # True if pg_stat_activity shows a connection tagged for a DIFFERENT mix test
  # invocation than this one. Matches only the "letflow_mixtest_" tag prefix this
  # project's own config/test.exs writes -- a bare Postgres session with no such tag
  # (e.g. a human's psql shell) is not a mix test invocation and is correctly ignored.
  defp concurrent_invocation_present?(repo, own_tag) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM pg_stat_activity " <>
          "WHERE application_name LIKE 'letflow_mixtest_%' AND application_name <> $1 LIMIT 1",
        [own_tag]
      )

    rows != []
  end

  # Drops the row's real Postgres schema and deletes its tenant_schemas/tenants
  # rows. schema_name has already been validated by the caller. Returns true on
  # success, false if this row's own cleanup raised (left for the next sweep to
  # retry) — a per-row failure never aborts the sweep for the remaining rows.
  defp reclaim_row(repo, %{id: id, tenant_id: tenant_id, schema_name: schema_name}) do
    repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
    repo.query!("DELETE FROM tenant_schemas WHERE id = $1", [id])
    repo.query!("DELETE FROM tenants WHERE id = $1", [tenant_id])
    true
  rescue
    exception ->
      Logger.warning(
        "TenantSchemaReaper.sweep_orphans/2: failed to reclaim tenant_schemas row id=#{Ecto.UUID.cast!(id)} " <>
          "tenant_id=#{Ecto.UUID.cast!(tenant_id)} schema_name=#{schema_name}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      false
  end
end
