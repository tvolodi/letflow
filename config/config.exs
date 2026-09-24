import Config

config :letflow, ecto_repos: [Letflow.Repo]

# REQ-352 (design lib/letflow/design/req352-unauthenticated-read-platform.md §8):
# the unauthenticated-read kind registry -- a map of
# %{kind_string => projection_module}, read at request time via
# Application.fetch_env!/2 by Letflow.PublicRead.fetch_kind/1. config/test.exs
# adds the one test-only fixture kind on top of this.
#
# REQ-357 (design lib/letflow/design/req357-certificate-public-projection.md
# §4) registers this stage's first real kind, "certificate" --
# Letflow.Exam.CertificatePublicProjection. Do not add a further vertical
# kind here without its own design/registration entry.
config :letflow, :public_read_kinds, %{
  "certificate" => Letflow.Exam.CertificatePublicProjection
}

# REQ-154: default instruction budget for tenant-supplied Lua scripts.
# The 2-arity execute_with_manifest/2 reads this value; the 3-arity overload
# accepts :max_instructions per call and does not use this config.
config :letflow, lua_max_instructions: 100_000

# REQ-155: default host-enforced wall-clock timeout (milliseconds) for tenant-supplied
# Lua scripts (LUA-10 layer 2). No existing timeout constant in lib/letflow/ to cite as
# precedent for this specific value (design doc §11 OQ-1); chosen consistent with
# expected Letflow flow-step script latencies -- comfortably above normal script
# execution time, short enough that a hung/looping script cannot stall a workflow
# instance indefinitely. The 2-arity execute_with_manifest/2 reads this value; the
# 3-arity overload requires :timeout_ms per call and does not use this config.
config :letflow, lua_wallclock_timeout_ms: 5_000

# REQ-156: default per-process heap word limit (LUA-09 restated) for tenant-supplied
# Lua scripts. `nil` = unconstrained -- production default, since no operational data
# yet justifies a specific tuned value (design doc req156-lua-memory-limit-impl.md §10
# OQ-1, mirroring REQ-154 §11 OQ-2 / REQ-155 §11 OQ-1's identical open questions about
# their own defaults). The 2-arity execute_with_manifest/2 reads this value; the
# 3-arity overload requires :max_heap_words per call (tests always drive an explicit
# small value there, per AC-1/AC-2) and does not use this config.
config :letflow, lua_max_heap_words: nil

# REQ-152: production/dev default time source for Letflow.Engine.Lua.Platform.now/0 —
# set explicitly here (rather than relying solely on Application.get_env/3's inline
# default) so the configured implementation is legible by reading config, not only by
# reading platform.ex's source. Tests override this per-test via Application.put_env/3
# to inject an exact, pre-set timestamp.
config :letflow, :lua_platform_time_source, Letflow.Engine.Lua.Platform.SystemClock

# REQ-193: Letflow.Obs.Logger is configured as the OTP default-handler formatter
# in config/dev.exs and config/prod.exs. Neither that nor backends: [] is set here
# so ExUnit.CaptureLog keeps working in the test environment (capture_log relies on
# the standard Elixir console formatter to produce [level]-prefixed output).

# REQ-400 (docs/migration/decisions/0039-platform-module-solution-layering.md
# D4; design lib/letflow/design/req400-module-behaviour-catalog.md §5):
# the compiled list of registered platform modules, read once via
# Application.compile_env/3 by Letflow.Modules.Catalog. No real module ships
# in P1 -- REQ-408 (P2) is what first appends one (Letflow.Modules.Exam).
# config/test.exs overrides this with the test-only fixture module.
config :letflow, :modules, []

import_config "#{config_env()}.exs"
