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
  invocation where "currently active" is guaranteed to be the empty set, so no
  in-memory liveness tracking (unlike `Letflow.SandboxPool`'s owner-monitor) is
  needed. See the design doc §2 for the full argument.
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
  or any concurrently-running `mix test` invocation.

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

      cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-min_age_seconds, :second)

      %{rows: rows} =
        repo.query!(
          "SELECT id, tenant_id, schema_name FROM tenant_schemas WHERE provisioned_at < $1",
          [cutoff]
        )

      {reclaimed, skipped_invalid_format} =
        Enum.reduce(rows, {0, 0}, fn [id, tenant_id, schema_name], {reclaimed_acc, skipped_acc} ->
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
