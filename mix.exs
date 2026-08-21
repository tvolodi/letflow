defmodule Letflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :letflow,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: ["letflow.check": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Letflow.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.17"},
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 0.6", only: :test},
      {:ueberauth_oidcc, "~> 0.4"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # `mix.exs` alias, not a `lib/mix/tasks/` custom task: REQ-003's
      # task-discovery-forces-compile problem (`docs/status/requirement_status.yaml`)
      # applied only to a module Mix must load from `lib/mix/tasks/` before running it,
      # and only broke a *timing measurement* that needed a genuinely-first compile to
      # measure — this alias needs neither (it wants `mix compile` to run as one of its
      # own steps regardless, and reads from `mix.exs` data, never from a compiled
      # `lib/` module), so the concern doesn't apply.
      #
      # ISS-0106 update: the alias's *first step* now IS such a `lib/mix/tasks/` task
      # (`letflow.check_toolchain`), so Mix must load that module before running it and
      # the alias therefore forces a project compile before the format check. The
      # hazard that raises is whether the later `compile --warnings-as-errors` step is
      # weakened by finding nothing left to recompile. It is not: measured (design
      # doc M5, re-verified as V4/V5) that an already-compiled project still exits 1
      # from that step, with the warnings re-emitted from the compile manifest.
      "letflow.check": [
        "letflow.check_toolchain",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "letflow.check.test"
      ]
    ]
  end
end
