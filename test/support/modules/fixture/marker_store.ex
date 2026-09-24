defmodule Letflow.Modules.Fixture.MarkerStore do
  @moduledoc """
  Test-only observable marker store backing
  `Letflow.Modules.Fixture.on_install/2` (REQ-400 §4.2).

  REQ-400's own text asks `on_install/2` to write "an observable marker
  (e.g. returns `:ok` after a tenant-scoped insert the test can read
  back)" without naming a storage target (design §9 open question 3, left
  to ELIXIR-DEV). REQ-400 does not itself persist anything (that is
  REQ-402's `tenant_modules` table) and REQ-400's `on_install/2` is never
  called from a real install transaction in this requirement — the only
  call site in scope is the fixture's own standalone demonstration/test
  use. A real tenant-schema Ecto migration for a test-only marker table
  would both overreach REQ-400's explicit non-persistence scope (§7) and
  require registering a production tenant-scoped migration
  (`Letflow.TenantProvisioning.tenant_scoped_migrations/0`) for a table no
  real code ever reads. A public, named ETS table is the minimal
  compliant shape instead: a real `:ets.insert/2` ("insert"), keyed by the
  tenant `prefix` INV-1 requires every tenant-scoped call to thread
  through, readable back by any test process without coordinating setup
  order with this module.

  Not a `GenServer`/`Agent`/`Supervisor` — a bare ETS table lazily
  created on first write, consistent with `Letflow.Modules.Catalog`'s own
  plain-module idiom (this file lives under `test/support/`, so AC4's
  `lib/letflow/modules/` grep does not even reach it, but the same
  reasoning applies: no runtime mutation hazard justifies a process here
  either).
  """

  @table __MODULE__

  @doc "Records that `on_install/2` ran for `prefix` with `settings`."
  @spec put(prefix :: String.t(), settings :: map()) :: :ok
  def put(prefix, settings) do
    ensure_table()
    :ets.insert(@table, {prefix, settings})
    :ok
  end

  @doc "Reads back the marker `put/2` recorded for `prefix`, if any."
  @spec get(prefix :: String.t()) :: {:ok, map()} | :error
  def get(prefix) do
    ensure_table()

    case :ets.lookup(@table, prefix) do
      [{^prefix, settings}] -> {:ok, settings}
      [] -> :error
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set])
      rescue
        # Another process created the table between the whereis/0 check
        # above and this call -- benign race, the table already exists.
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
