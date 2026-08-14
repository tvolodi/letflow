defmodule Letflow.RowApproval do
  @moduledoc """
  Same two-approver sign-off semantics as `Letflow.ParallelApproval`,
  implemented as a plain Ecto-backed Postgres row instead of a
  supervised `:gen_statem` process.

  This is the deliberate row-based counterpart to
  `Letflow.ParallelApproval`: no gen_statem, no GenServer, no
  DynamicSupervisor, no process per instance — just reads and writes
  against a single `approvals` row per instance, addressed by its
  `id`. Where `Letflow.ParallelApproval` tracks progress as `:gen_statem`
  data on a `:pending` state, this module tracks the identical
  progress as two nullable timestamp columns
  (`finance_approved_at`/`ops_approved_at`) plus a `status` string
  column, updated in place.

  Known approvers and idempotency/rejection semantics are intentionally
  identical to `Letflow.ParallelApproval` so the two implementations are
  comparable rather than one being a strawman.
  """

  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.RowApproval.Approval

  @type approver :: :finance | :ops
  @type status :: :pending | :approved

  @approvers [:finance, :ops]

  @spec approvers() :: [approver()]
  def approvers, do: @approvers

  @doc """
  Inserts a fresh pending approval row and returns its id. The
  row-based equivalent of asking a supervisor to start a new instance
  process — there's no supervisor here, so this is the entry point
  that plays that role.
  """
  @spec create() :: {:ok, String.t()}
  def create do
    approval = Repo.insert!(%Approval{status: "pending"})
    {:ok, approval.id}
  end

  @spec approve(String.t(), approver()) :: :ok | {:error, term()}
  def approve(_id, approver) when approver not in @approvers do
    {:error, {:unknown_approver, approver}}
  end

  def approve(id, approver) do
    case Repo.get(Approval, id) do
      nil ->
        {:error, :not_found}

      approval ->
        do_approve(approval, approver)
    end
  end

  @spec get(String.t()) :: %{status: status(), approved_by: [approver()]} | {:error, :not_found}
  def get(id) do
    case Repo.get(Approval, id) do
      nil -> {:error, :not_found}
      approval -> to_view(approval)
    end
  end

  defp do_approve(approval, approver) do
    column = approved_at_column(approver)

    # Already signed by this approver: no-op, matching
    # Letflow.ParallelApproval's idempotent re-approval behavior. Also
    # covers an already-:approved row, since both columns are already
    # set by the time status flips to "approved".
    if Map.get(approval, column) do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      updated = Map.put(approval, column, now)
      new_status = if both_signed?(updated), do: "approved", else: "pending"

      {1, _} =
        from(a in Approval, where: a.id == ^approval.id)
        |> Repo.update_all(set: [{column, now}, {:status, new_status}, {:updated_at, now}])

      :ok
    end
  end

  defp both_signed?(%Approval{finance_approved_at: f, ops_approved_at: o}),
    do: not is_nil(f) and not is_nil(o)

  defp approved_at_column(:finance), do: :finance_approved_at
  defp approved_at_column(:ops), do: :ops_approved_at

  defp to_view(%Approval{} = approval) do
    approved_by =
      @approvers
      |> Enum.filter(&Map.get(approval, approved_at_column(&1)))

    %{status: status_atom(approval.status), approved_by: approved_by}
  end

  # Explicit mapping rather than String.to_existing_atom/1: the two
  # status strings are only ever written by this module (see
  # do_approve/2), so an explicit clause per known value is both safer
  # (no dependency on some other atom happening to already be interned
  # at runtime) and, unlike to_existing_atom, fails loudly with a
  # FunctionClauseError on any value this module didn't itself write.
  defp status_atom("pending"), do: :pending
  defp status_atom("approved"), do: :approved
end
