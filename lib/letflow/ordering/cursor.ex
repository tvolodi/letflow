defmodule Letflow.Ordering.Cursor do
  @moduledoc """
  Ecto schema for the `correlation_cursors` table (REQ-199, ORD-01).

  One row per correlation, tracking the highest `sequence_no` successfully
  applied. `applied_seq = 0` means no completions have been applied yet for
  this correlation. A cursor row is upsert-initialised at `applied_seq = 0`
  during the first `try_apply` transaction for each correlation (M3).

  The primary key is `correlation_id` (string), not a UUID — matching R-Co's
  own primary key shape for this table.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:correlation_id, :string, autogenerate: false}
  schema "correlation_cursors" do
    field :tenant_id, :binary_id
    field :applied_seq, :integer, default: 0

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc """
  Upsert-initialises a cursor row at `applied_seq = 0` if it does not exist
  (AC6). Called inside the apply transaction — not a standalone public entry
  point for callers.
  """
  @spec upsert_init(correlation_id :: String.t(), opts :: keyword()) ::
          {:ok, Letflow.Ordering.Cursor.t()} | {:error, term()}
  def upsert_init(correlation_id, opts) do
    alias Letflow.Repo
    alias Letflow.TenantProvisioning

    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      result =
        Repo.insert(
          %__MODULE__{
            correlation_id: correlation_id,
            tenant_id: tenant_id,
            applied_seq: 0,
            created_at: now,
            updated_at: now
          },
          prefix: prefix,
          on_conflict: :nothing,
          conflict_target: :correlation_id
        )

      case result do
        {:ok, _} -> {:ok, Repo.get!(__MODULE__, correlation_id, prefix: prefix)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Executes `UPDATE correlation_cursors SET applied_seq = $new WHERE
  correlation_id = $id AND applied_seq = $expected_current`. Returns `:ok` on
  1 row updated, `:race` on 0 rows (AC5).
  """
  @spec advance_conditional(
          correlation_id :: String.t(),
          expected_current :: non_neg_integer(),
          opts :: keyword()
        ) :: :ok | :race
  def advance_conditional(correlation_id, expected_current, opts) do
    import Ecto.Query
    alias Letflow.Repo

    prefix = Keyword.fetch!(opts, :prefix)
    new_seq = expected_current + 1
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {count, _} =
      Repo.update_all(
        from(c in __MODULE__,
          where: c.correlation_id == ^correlation_id and c.applied_seq == ^expected_current,
          update: [set: [applied_seq: ^new_seq, updated_at: ^now]]
        ),
        [],
        prefix: prefix
      )

    if count == 1, do: :ok, else: :race
  end
end
