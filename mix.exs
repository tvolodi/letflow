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
      # :inets and :ssl: REQ-183's deliver/3 uses :httpc.request/4 for
      # outbound webhook delivery -- both are required started for :httpc to
      # work, neither was needed before this requirement (the project's
      # first outbound-HTTP-call requirement, design
      # req183-webhook-delivery-dispatch.md §5).
      extra_applications: [:logger, :inets, :ssl],
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
      # REQ-194 (design req194-prometheus-metrics.md §10): promotes an ALREADY-PRESENT
      # transitive dependency (mix.lock already resolves telemetry v1.4.2 via bandit,
      # db_connection, ecto, ecto_sql, plug) to a direct one -- zero new bytes, zero new
      # transitive tree, zero new license surface. Needed because lib/letflow/metrics/,
      # lib/letflow/plugs/http_metrics.ex, engine.ex and event_store.ex now call
      # :telemetry.execute/3 / :telemetry.attach_many/4 / :telemetry.span/3 directly for
      # the first time -- standard Elixir hygiene pins a directly-called library rather
      # than borrowing it off another dependency's transitive graph. Flagged for
      # REVIEWER sign-off per this requirement's own AC3 (see the design's §10 and the
      # CODE-DESIGN-VALIDATOR's dependency_promotion_flag_for_reviewer note on the
      # step-02a handoff) -- REVIEWER sign-off must be recorded before this merges.
      {:telemetry, "~> 1.4"},
      {:stream_data, "~> 0.6", only: :test},
      # REQ-205 (design lib/letflow/design/req205-simulation-harness-foundation.md
      # §4): pure-Elixir YAML 1.1 parser (wraps :yamerl) for the S7 simulation
      # harness's business-fixture YAML (test/fixtures/simulation/). Test-only --
      # nothing under lib/letflow/ (production code) ever parses YAML -- mirrors
      # stream_data's own `only: :test` entry, not wasmex/lua's unconditional
      # runtime-engine entries. Flagged for REVIEWER sign-off per REQ-205's AC7,
      # same procedural precedent as REQ-148/REQ-165's own new top-level deps.
      {:yaml_elixir, "~> 2.11", only: :test},
      {:ueberauth_oidcc, "~> 0.4"},
      {:lua, "~> 1.0"},
      {:wasmex, "~> 0.15.1"}
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
        "letflow.check_requirements_registration",
        # ISS-0258: positioned immediately after the registration check per design
        # D5 -- it shares a parse of docs/requirements.yaml with that check, so a
        # stale deferral is reported in a second rather than after a full
        # compile+test cycle. T-ALIAS-SLOT asserts this ordering.
        "letflow.check_deferral_staleness",
        # ISS-0257: wired in as a hard gate, matching check_requirements_registration's
        # own precedent ("a check nobody runs is not a check") -- verified green on
        # main and against both open PRs' own new content before landing (neither adds
        # a handoffs/ file at all), so this addition does not retroactively fail any
        # currently in-flight branch. See HANDOFF_PROTOCOL.md's Enforcement note for
        # what "hard" and "advisory" mean for this task's own findings.
        "letflow.lint_handoffs",
        # ISS-0481: a pure static/textual scan over test/**/*_test.exs, like
        # lint_handoffs above and check_requirements_registration -- no
        # compile step, no shared parse target with any neighbor, so it has
        # no ordering dependency either direction. Placed with the other
        # fast, non-compiling checks so a violation surfaces in seconds, not
        # after a full compile+test cycle.
        "letflow.check_async_sandbox_reachability",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "letflow.check.test"
      ]
    ]
  end
end
