defmodule Letflow.TenantProvisioning.Backfill do
  @moduledoc """
  Post-hoc reconciliation of event type schema versions across already-provisioned
  tenants. Used to address ISS-0332: tenants provisioned before REQ-077 bumped
  DEFINITION_PROMOTED from schema_version 1 to 2 still have v1 in their
  event_type_registry, causing R10 audit-event appends to fail against a null
  review_id.
  """

  require Logger

  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.EventStore.Registry

  @spec run(event_type_attrs :: map()) ::
          {:ok, %{updated: non_neg_integer(), skipped: non_neg_integer()}}
          | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
  def run(event_type_attrs) do
    registrations = Repo.all(Registration)

    Enum.reduce_while(registrations, {:ok, %{updated: 0, skipped: 0}}, fn registration,
                                                                           {:ok, counts} ->
      tenant_id = registration.tenant_id

      case Registry.register_type(event_type_attrs, tenant_id) do
        {:ok, _} ->
          {:cont, {:ok, %{counts | updated: counts.updated + 1}}}

        {:error, :duplicate_event_type_version} ->
          {:cont, {:ok, %{counts | skipped: counts.skipped + 1}}}

        {:error, :schema_version_not_monotonic} ->
          {:cont, {:ok, %{counts | skipped: counts.skipped + 1}}}

        {:error, :tenant_not_provisioned} ->
          Logger.warning(
            "ISS-0332 backfill: tenant #{tenant_id} has Registration row but is not provisioned, skipping"
          )

          {:cont, {:ok, %{counts | skipped: counts.skipped + 1}}}

        {:error, other} ->
          {:halt, {:error, {:backfill_failed, tenant_id, other}}}
      end
    end)
  end
end
