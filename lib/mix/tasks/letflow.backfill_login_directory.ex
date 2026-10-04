defmodule Mix.Tasks.Letflow.BackfillLoginDirectory do
  @shortdoc "Backfills the platform tenant-login directory from every registered tenant's active users (REQ-435)"

  @moduledoc """
  Backfills `tenant_login_directory` (REQ-435; design
  `lib/letflow/design/req434-email-first-login-directory.md` §4) for users that
  existed before the directory's writers shipped. Thin wrapper over
  `Letflow.LoginDirectory.Backfill.run/1`, following
  `mix letflow.backfill_platform_roles`.

  ## Usage

      mix letflow.backfill_login_directory [--dry-run]

  `--dry-run` reads and computes but inserts nothing. Targets whatever
  `MIX_ENV`/`Letflow.Repo` config is active -- no `LETFLOW_DEV_DB_CONFIRMED`
  guard (same precedent as `mix letflow.backfill_platform_roles`).

  Idempotent: a second run inserts zero rows. Prints per-tenant counts and tenant
  ids only -- never an email address or a key. A tenant that fails is reported and
  skipped while the others still run; the task then exits non-zero.
  """

  use Mix.Task

  alias Letflow.LoginDirectory.Backfill

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [dry_run: :boolean])

    Mix.Task.run("app.start")

    case Backfill.run(dry_run: Keyword.get(opts, :dry_run, false)) do
      {:ok, %{tenants: tenants, failed: failed, dry_run: dry_run?}} ->
        Enum.each(tenants, fn t ->
          Mix.shell().info(
            "tenant #{t.tenant_id}: users_read=#{t.users_read} keys=#{t.keys} inserted=#{t.inserted}"
          )
        end)

        Enum.each(failed, fn f ->
          Mix.shell().error("tenant #{f.tenant_id}: FAILED reason=#{f.reason} (skipped)")
        end)

        Mix.shell().info(
          "login directory backfill#{if dry_run?, do: " (dry run)", else: ""} complete: " <>
            "#{length(tenants)} tenant(s) processed, #{length(failed)} failed, " <>
            "#{Enum.sum(Enum.map(tenants, & &1.inserted))} row(s) inserted"
        )

        if failed != [], do: System.halt(1), else: :ok

      {:error, :pepper_unavailable} ->
        Mix.shell().error(
          "login directory backfill: LETFLOW_LOGIN_DIRECTORY_PEPPER is not configured"
        )

        System.halt(1)
    end
  end
end
