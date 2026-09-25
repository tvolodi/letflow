defmodule Letflow.Modules.FixtureDependent do
  @moduledoc """
  Test-only entry module (REQ-402 design §4) — depends on `"fixture"`, so
  `Letflow.Modules.Installs.install/3` can be exercised against a real
  `depends_on` check. Registered only in `config/test.exs`, alongside
  `Letflow.Modules.Fixture` (`config :letflow, :modules,
  [Letflow.Modules.Fixture, Letflow.Modules.FixtureDependent]`), compiled
  only in the `:test` env via `mix.exs`'s existing `elixirc_paths(:test)`
  (already includes `test/support`, no `mix.exs` change needed).

  Minimal shape — no `router/0`, no `on_install/2` (both are
  `@optional_callbacks`, and this fixture needs neither: it exists only to
  prove REQ-402 AC4's missing-dependency-rejection test).
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_dependent",
    version: "0.1.0",
    depends_on: ["fixture"],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: []
  )
end
