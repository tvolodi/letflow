defmodule Letflow.Modules.FixtureFailingInstall do
  @moduledoc """
  Test-only entry module (REQ-402 design §9 open question 1, option (a),
  the design's own recommendation) — its `on_install/2` unconditionally
  returns `{:error, :boom}`, so `Letflow.Modules.Installs.install/3`'s AC6
  rollback path (a whole-transaction rollback, including the just-inserted
  `tenant_modules` row) has something real to exercise. `Fixture` itself
  cannot serve this purpose: its own `on_install/2` always returns `:ok`.

  Registered only in `config/test.exs`, alongside `Fixture` and
  `FixtureDependent` (`config :letflow, :modules, [Letflow.Modules.Fixture,
  Letflow.Modules.FixtureDependent, Letflow.Modules.FixtureFailingInstall]`),
  compiled only in the `:test` env via `mix.exs`'s existing
  `elixirc_paths(:test)`.

  `depends_on: []`, `pack: nil` — this fixture's only job is to fail at the
  `on_install/2` step (§3.3 step 6), so it must clear every earlier step
  (unknown-module, already-installed, depends_on, pack-install) trivially.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_failing_install",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: []
  )

  @impl true
  def on_install(_prefix, _settings), do: {:error, :boom}
end
