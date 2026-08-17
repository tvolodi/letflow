defmodule Letflow.Repo do
  use Ecto.Repo,
    otp_app: :letflow,
    adapter: Ecto.Adapters.Postgres

  # `init/2` runs immediately before this repo actually opens a
  # connection -- the one point in the boot sequence common to every path
  # that touches Postgres (full `Letflow.Application` supervision, and
  # standalone `mix ecto.migrate`/`ecto.create`/`ecto.drop`, which start
  # the repo directly without going through the application tree at all).
  # A guard placed in config/dev.exs instead would fire on every `mix`
  # invocation under MIX_ENV=dev, including `mix compile`/`mix format`,
  # which never connect -- this only fires when a connection is actually
  # about to be attempted.
  @impl true
  def init(_type, config) do
    if config[:require_dev_db_confirmation] && is_nil(System.get_env("LETFLOW_DEV_DB_CONFIRMED")) do
      raise """
      Refusing to connect to the shared letflow_dev database without explicit confirmation.

      Unlike the test database (letflow_test#{System.get_env("MIX_TEST_PARTITION")}, isolated
      per workspace via MIX_TEST_PARTITION), letflow_dev is a single database shared by every
      concurrent workspace/host in this project's multi-workspace setup -- writing to it from
      one workspace can corrupt or confuse verification happening concurrently in another.

      If you're doing throwaway/scratch verification (provisioning a tenant, checking a
      migration or constraint by hand), use the test database instead -- already isolated per
      workspace and already the established pattern in this project:

          MIX_ENV=test MIX_TEST_PARTITION=<N> mix ecto.create --quiet
          MIX_ENV=test MIX_TEST_PARTITION=<N> mix ecto.migrate --quiet
          MIX_ENV=test MIX_TEST_PARTITION=<N> mix run -e '...'

      (<N> should match whatever partition this workspace already uses for `mix test` -- check
      this checkout's own prior `mix test` invocations, or ask ORCH if unsure.)

      If you genuinely need the interactive dev environment (not scratch verification) and
      understand it's shared, persistent state:

          LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt
      """
    end

    {:ok, config}
  end
end
