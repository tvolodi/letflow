defmodule Mix.Tasks.Letflow.BackfillEventTypeVersions do
  @shortdoc "Backfills event type schema versions for pre-existing tenants (ISS-0332)"

  @moduledoc """
  Backfills the DEFINITION_PROMOTED event type to schema_version 2 for all
  tenants provisioned before REQ-077 bumped the seed (ISS-0332).

  Usage:

      mix letflow.backfill_event_type_versions

  Exits non-zero if any tenant fails to backfill.
  """

  use Mix.Task

  @definition_promoted_v2_attrs %{
    name: "DEFINITION_PROMOTED",
    schema_version: 2,
    description:
      "Emitted by Letflow.Definitions.Promotion.promote_definition/3 (PRM-01, the " <>
        "review-gated path) AND Letflow.Definitions.Promotion.promote_active_definition/5 " <>
        "(REQ-077 R10/ENV-03, the reviewless test->production path) after a promotion " <>
        "commits, via Letflow.EventStore.PlatformEvents.append_definition_promoted/2. " <>
        "Bumped from schema_version 1 (REQ-140) to 2 (REQ-077 design §9.5): an ENV-03 " <>
        "promotion genuinely has no review, so `review_id` must admit `null` rather than " <>
        "forcing a synthetic id into the audit log.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "review_id" => %{"type" => ["string", "null"]},
        "source_tenant_id" => %{"type" => "string"},
        "target_tenant_id" => %{"type" => "string"},
        "source_definition_id" => %{"type" => "string"},
        "target_definition_id" => %{"type" => "string"},
        "process_key" => %{"type" => "string"}
      },
      "required" => [
        "review_id",
        "source_tenant_id",
        "target_tenant_id",
        "source_definition_id",
        "target_definition_id",
        "process_key"
      ]
    }
  }

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    case Letflow.TenantProvisioning.Backfill.run(@definition_promoted_v2_attrs) do
      {:ok, %{updated: u, skipped: s}} ->
        Mix.shell().info("Backfill complete: #{u} updated, #{s} skipped")

      {:error, {:backfill_failed, tenant_id, reason}} ->
        Mix.shell().error("Backfill failed for tenant #{tenant_id}: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
