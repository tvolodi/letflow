defmodule Mix.Tasks.Letflow.MigrateTenantAdmins do
  @shortdoc "Converts legacy PLATFORM_ADMIN holders in non-platform tenants to TENANT_ADMIN (REQ-447)"

  @moduledoc """
  Thin CLI over `Letflow.Identity.TenantAdminMigration.run/1` (REQ-447). On a
  deployed container, which has no Mix, call the same function through the release
  `rpc` instead (`lib/letflow/design/req447-infra-realm-mapping.md` section 8).

  REQ-447 PR 2 is merged: a legacy `PLATFORM_ADMIN` outside the platform tenant
  is no longer honoured, so this task is what converts its holders (members and
  API tokens) in every environment that still has them.

  ## Usage

      mix letflow.migrate_tenant_admins --dry-run
      mix letflow.migrate_tenant_admins --platform-tenant=<slug> --expected-realm-id=<id>

  The pin (`LETFLOW_PLATFORM_TENANT_ID`) is read from THIS process's environment,
  which may differ from the serving node's; `--platform-tenant` and
  `--expected-realm-id` confirm it. Both are required for a real run.

  Output is only tenant ids, slugs, realm ids, reason tags and counts: never a
  user attribute, a token or an exception message. A refused real run prints one
  line `REFUSED <tag>` and exits 1; `--dry-run` never refuses (it prints
  `would_refuse=<tags>`). Exit status 1 also when any tenant failed (a `--dry-run` included: a failed tenant is a pre-flight
  signal; only `would_refuse` leaves a dry run at 0). An unknown option or a positional
  argument prints `REFUSED invalid_option` and exits 1 before anything runs.
  """

  use Mix.Task

  alias Letflow.Identity.TenantAdminMigration

  @switches [dry_run: :boolean, platform_tenant: :string, expected_realm_id: :string]

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.shell().info("REFUSED invalid_option")
      System.halt(1)
    end

    Mix.Task.run("app.start")

    opts = [
      dry_run: Keyword.get(parsed, :dry_run, false),
      platform_tenant_slug: Keyword.get(parsed, :platform_tenant),
      expected_realm_id: Keyword.get(parsed, :expected_realm_id)
    ]

    case TenantAdminMigration.run(opts) do
      {:ok, report} ->
        print_report(report)
        if report.failed != [], do: System.halt(1), else: :ok

      {:error, {:precondition_failed, tag}} ->
        Mix.shell().info("REFUSED #{tag}")
        System.halt(1)
    end
  end

  defp print_report(%{dry_run: true} = report) do
    pre = report.preconditions
    members = Enum.sum(Enum.map(report.migrated, & &1.members_copied))
    tokens = Enum.sum(Enum.map(report.migrated, & &1.tokens_rewritten))

    Mix.shell().info(
      "pinned slug=#{pre.pinned_slug} realm=#{pre.pinned_idp_realm_id} " <>
        "operators=#{pre.operator_count} members_to_copy=#{members} tokens_to_rewrite=#{tokens} " <>
        "would_refuse=#{Enum.join(report.would_refuse, ",")}"
    )

    print_tenants(report)
  end

  defp print_report(report), do: print_tenants(report)

  defp print_tenants(report) do
    Mix.shell().info(
      "SUMMARY dry_run=#{report.dry_run} migrated=#{length(report.migrated)} " <>
        "unchanged=#{length(report.unchanged)} failed=#{length(report.failed)}"
    )

    Enum.each(report.migrated, fn t ->
      Mix.shell().info(
        "tenant #{t.tenant_id} slug=#{t.slug} realm=#{t.idp_realm_id} " <>
          "binding_created=#{t.tenant_admin_binding_created} members_copied=#{t.members_copied} " <>
          "binding_removed=#{t.platform_admin_binding_removed} tokens=#{t.tokens_rewritten} " <>
          "admins_after=#{t.tenant_admin_member_count_after}"
      )
    end)

    Enum.each(report.failed, fn f ->
      Mix.shell().info("tenant #{f.tenant_id}: FAILED reason=#{f.reason}")
    end)
  end
end
