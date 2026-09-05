defmodule Letflow.Identity.RoleRegistry do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ports R-Co `src/identity/role_registry.zig`'s `TenantRoleStore` (`list_roles`,
  `upsert_role`) and `resolveRoleInTx` — see also
  `src/design/idn05-role-registry.md`, the design doc `role_registry.zig` itself points
  to. Operates on REQ-015's `tenant_role`/`groups` schema
  (`Letflow.Identity.TenantRole`, `Letflow.Identity.Group`). Full design:
  `lib/letflow/design/req020-role-registry.md`.

  This module has **no coupling to the OIDC/claim-mapping pipeline**: it does not
  `alias` or call any `Letflow.Oidc.*` module, and it does not call or get called by
  `Letflow.Identity`'s OIDC-pipeline functions (`provision_oidc_user/3`,
  `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`).
  It is a standalone, workflow-engine-facing role registry — consumed by a future S3
  transition-time lookup (role name → group UUID) — not part of token verification or
  identity resolution.
  """

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo

  @type upsert_error ::
          :invalid_role_name
          | :invalid_group_id
          | :group_not_found
          | Ecto.Changeset.t()

  @max_name_codepoints 128
  @control_char_pattern ~r/[\x00-\x1F\x7F]/u

  @doc """
  Returns every role binding sorted by `name` ascending. Returns `[]` (not an error)
  when `tenant_role` is empty.
  """
  @spec list_roles() :: [TenantRole.t()]
  def list_roles do
    Repo.all(from(t in TenantRole, order_by: [asc: t.name]))
  end

  @doc """
  Inserts or updates the `(name -> group_id)` binding: validates `name`'s format and
  `group_id`'s UUID syntax before any DB round-trip, then confirms `group_id` references
  an existing group and upserts on `name` conflict (updating only `group_id`) inside one
  transaction.
  """
  @spec upsert_role(name :: String.t(), group_id :: Ecto.UUID.t() | String.t()) ::
          {:ok, TenantRole.t()} | {:error, upsert_error()}
  def upsert_role(name, group_id) do
    with :ok <- validate_role_name(name),
         {:ok, normalized_group_id} <- Ecto.UUID.cast(group_id) do
      do_upsert_role(name, normalized_group_id)
    else
      :error -> {:error, :invalid_group_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transition-time role resolution: looks up `name`'s bound `group_id`. Meant to be
  called from inside a caller's own `Repo.transaction/1` (a future S3 `applyTransition`)
  — takes no repo/connection argument itself, since Ecto's transaction context is
  ambient to the calling process once invoked from inside that callback.

  Returns `nil` on any lookup failure — unknown `name`, or a genuine DB/connection
  error — never raises, never returns an `{:error, _}` tuple. This is a deliberate
  divergence from this module's other functions: role resolution must never fail a
  transition transaction due to a lookup problem.
  """
  @spec resolve_role_in_tx(name :: String.t()) :: Ecto.UUID.t() | nil
  def resolve_role_in_tx(name) do
    case Repo.get_by(TenantRole, name: name) do
      %TenantRole{group_id: group_id} -> group_id
      nil -> nil
    end
  rescue
    _ -> nil
  end

  defp do_upsert_role(name, group_id) do
    Repo.transaction(fn ->
      case Repo.get(Group, group_id) do
        nil ->
          Repo.rollback(:group_not_found)

        %Group{} ->
          insert_or_update_role(name, group_id)
      end
    end)
  end

  defp insert_or_update_role(name, group_id) do
    case %TenantRole{}
         |> TenantRole.changeset(%{name: name, group_id: group_id})
         |> Repo.insert(
           conflict_target: :name,
           on_conflict: [set: [group_id: group_id]],
           returning: true
         ) do
      {:ok, role} -> role
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp validate_role_name(name) do
    cond do
      name == "" ->
        {:error, :invalid_role_name}

      String.length(name) > @max_name_codepoints ->
        {:error, :invalid_role_name}

      String.match?(name, @control_char_pattern) ->
        {:error, :invalid_role_name}

      true ->
        :ok
    end
  end
end
