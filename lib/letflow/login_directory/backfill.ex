defmodule Letflow.LoginDirectory.Backfill do
  @moduledoc """
  Idempotent backfill of `tenant_login_directory` for users that existed before
  the directory's writers shipped (REQ-435; design
  `lib/letflow/design/req434-email-first-login-directory.md` §4). Driven by
  `mix letflow.backfill_login_directory`.

  Iterates **every registered tenant** via
  `Letflow.TenantProvisioning.list_registrations/0`, regardless of tenant
  status: tenant status is filtered at query time by
  `Letflow.LoginDirectory.lookup_by_keys/1`, so skipping an `:inactive` tenant
  would leave its users undiscoverable after reactivation (design §0.3 D3).

  For each tenant it reads the active users' emails from that tenant's own
  schema (the registration's `schema_name` passed as `:prefix`, never
  interpolated into SQL -- INV-1/INV-7), derives each key with
  `Letflow.LoginDirectory.email_key/1` (invalid or over-length addresses are
  skipped), and inserts the `(email_key, tenant_id)` pairs in chunks with
  `ON CONFLICT DO NOTHING`; the driver's returned count is the number actually
  inserted, so a second run reports 0 and leaves the row set identical.

  Each tenant runs in its own transaction under a rescue: a failure is recorded
  in `failed` with a reason atom only (never exception text or an email) and the
  next tenant still runs (INV-8).

  **It is the re-keying step of a pepper rotation (0043 D-C):** keys are computed
  with `email_key/1` and rows are written under the CURRENT key and
  `current_key_id/0` only, never under the previous key, so after a rotation every
  active user gains a current-key row (old-key rows are left alone; removing them
  is `retire_key`, REQ-443). Steady state: a re-run inserts 0.

  Insert-only: it never removes. A backfill racing a concurrent deactivation can
  leave a ghost entry for the race window (0042 RQ-4); it does not take the
  per-key advisory lock (cost), so run it in a maintenance window.

  Output and logs carry counts and tenant ids only, never an email or a key
  (INV-4); every `Repo` call passes `log: false`.
  """

  import Ecto.Query

  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @insert_chunk_size 1000

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t(),
          users_read: non_neg_integer(),
          keys: non_neg_integer(),
          inserted: non_neg_integer()
        }

  @type backfill_report :: %{
          tenants: [tenant_report()],
          failed: [%{tenant_id: Ecto.UUID.t(), reason: atom()}],
          dry_run: boolean(),
          key_id: String.t()
        }

  @doc """
  Runs the backfill. `dry_run: true` reads and computes but writes nothing
  (`inserted` is 0; `keys` is how many distinct keys a real run would attempt).
  Returns `{:error, :pepper_unavailable}` before touching any tenant when the
  keys are not configured (`current_key_id/0`); the report carries the `key_id`; otherwise `{:ok, report}` even when `failed != []`.
  """
  @spec run(opts :: [dry_run: boolean()]) ::
          {:ok, backfill_report()} | {:error, :pepper_unavailable}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    case LoginDirectory.current_key_id() do
      {:error, :pepper_unavailable} ->
        {:error, :pepper_unavailable}

      {:ok, key_id} ->
        report =
          Enum.reduce(
            TenantProvisioning.list_registrations(),
            %{tenants: [], failed: [], dry_run: dry_run?, key_id: key_id},
            fn registration, acc -> backfill_tenant(registration, dry_run?, key_id, acc) end
          )

        {:ok,
         %{report | tenants: Enum.reverse(report.tenants), failed: Enum.reverse(report.failed)}}
    end
  end

  defp backfill_tenant(registration, dry_run?, key_id, acc) do
    case Repo.transaction(fn -> do_backfill_tenant(registration, dry_run?, key_id) end) do
      {:ok, tenant_report} -> %{acc | tenants: [tenant_report | acc.tenants]}
      {:error, reason} -> record_failure(acc, registration, reason)
    end
  rescue
    # Reason atom only: exception text could carry row data.
    _exception -> record_failure(acc, registration, :tenant_backfill_failed)
  end

  defp record_failure(acc, registration, reason) do
    %{acc | failed: [%{tenant_id: registration.tenant_id, reason: reason} | acc.failed]}
  end

  defp do_backfill_tenant(registration, dry_run?, key_id) do
    emails =
      Repo.all(
        from(u in User, where: u.status == :active and not is_nil(u.email), select: u.email),
        prefix: registration.schema_name,
        log: false
      )

    keys =
      emails
      |> Enum.flat_map(fn email ->
        case LoginDirectory.email_key(email) do
          {:ok, key} -> [key]
          _skipped -> []
        end
      end)
      |> Enum.uniq()

    inserted = if dry_run?, do: 0, else: insert_keys(keys, registration.tenant_id, key_id)

    %{
      tenant_id: registration.tenant_id,
      users_read: length(emails),
      keys: length(keys),
      inserted: inserted
    }
  end

  defp insert_keys(keys, tenant_id, key_id) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    keys
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, total ->
      rows =
        Enum.map(chunk, &%{email_key: &1, key_id: key_id, tenant_id: tenant_id, inserted_at: now})

      {count, _} =
        Repo.insert_all(TenantLoginDirectoryEntry, rows,
          on_conflict: :nothing,
          conflict_target: [:email_key, :tenant_id],
          log: false
        )

      total + count
    end)
  end
end
