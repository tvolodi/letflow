defmodule Letflow.LoginDirectory.KeyRotation do
  @moduledoc """
  Operator-side half of the login-directory pepper rotation (REQ-443; decision
  `docs/migration/decisions/0043-email-first-login-ba-decisions.md` D-C; design
  `lib/letflow/design/req434-email-first-login-directory.md` §2.4, §3.9). Driven by
  `mix letflow.login_directory.key_status` and
  `mix letflow.login_directory.retire_key`, which only wrap the public functions here; a deployed
  release has no Mix, so the same functions are called through `bin/letflow rpc` (runbook
  section 0). The runbook is `docs/runbooks/login-directory-pepper-rotation.md`.

  Only key **ids** (labels) and row counts cross this module's boundary: never an
  email, an `email_key` or a pepper (INV-4). Every `Repo` call passes `log: false`
  (Ecto's default query log prints bound parameters), queries are Ecto queries
  with bound parameters (INV-7), and every failure is a fixed atom, never
  exception text.
  """

  import Ecto.Query

  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.LoginDirectory
  alias Letflow.Repo

  # Same rule as config/runtime.exs and the key_id_format CHECK.
  @key_id_format ~r/\A[a-z0-9_-]{1,32}\z/

  @type retire_report :: %{key_id: String.t(), rows: non_neg_integer(), dry_run: boolean()}

  @doc """
  Row counts per key id, ordered by key id. Counts only; only ids present in the
  table appear (a current id with no rows yet is absent). Failure is
  `{:error, :status_failed}`.
  """
  @spec key_status() :: {:ok, [{String.t(), non_neg_integer()}]} | {:error, :status_failed}
  def key_status do
    rows =
      Repo.all(
        from(d in TenantLoginDirectoryEntry,
          group_by: d.key_id,
          order_by: [asc: d.key_id],
          select: {d.key_id, count()}
        ),
        log: false
      )

    {:ok, rows}
  rescue
    _exception -> {:error, :status_failed}
  end

  @doc """
  Deletes every directory row carrying `key_id`. Refuses the CURRENT key id
  (`{:error, :current_key_id}`) and an id with no rows (`{:error, :not_found}`);
  an id that does not match `[a-z0-9_-]{1,32}` is `{:error, :invalid_key_id}`
  before any query; unconfigured keys are `{:error, :pepper_unavailable}`.

  `dry_run: true` counts what would be deleted and deletes nothing. Returns
  `{:ok, %{key_id:, rows:, dry_run:}}` where `rows` is the number deleted (or that
  would be). Any other failure is `{:error, :retire_failed}`.
  """
  @spec retire_key(key_id :: term(), opts :: [dry_run: boolean()]) ::
          {:ok, retire_report()}
          | {:error,
             :invalid_key_id
             | :pepper_unavailable
             | :current_key_id
             | :not_found
             | :retire_failed}
  def retire_key(key_id, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with :ok <- validate_key_id(key_id),
         {:ok, current} <- LoginDirectory.current_key_id(),
         :ok <- refuse_current(key_id, current) do
      do_retire(key_id, dry_run?)
    end
  rescue
    _exception -> {:error, :retire_failed}
  end

  defp validate_key_id(key_id) when is_binary(key_id) do
    if Regex.match?(@key_id_format, key_id), do: :ok, else: {:error, :invalid_key_id}
  end

  defp validate_key_id(_other), do: {:error, :invalid_key_id}

  defp refuse_current(key_id, key_id), do: {:error, :current_key_id}
  defp refuse_current(_key_id, _current), do: :ok

  defp do_retire(key_id, true) do
    rows = Repo.aggregate(rows_for(key_id), :count, log: false)
    report(key_id, rows, true)
  end

  defp do_retire(key_id, false) do
    {rows, _} = Repo.delete_all(rows_for(key_id), log: false)
    report(key_id, rows, false)
  end

  defp report(_key_id, 0, _dry_run?), do: {:error, :not_found}
  defp report(key_id, rows, dry_run?), do: {:ok, %{key_id: key_id, rows: rows, dry_run: dry_run?}}

  defp rows_for(key_id), do: from(d in TenantLoginDirectoryEntry, where: d.key_id == ^key_id)
end
