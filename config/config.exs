import Config

config :letflow, ecto_repos: [Letflow.Repo]

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

# REQ-152: production/dev default time source for Letflow.Engine.Lua.Platform.now/0 —
# set explicitly here (rather than relying solely on Application.get_env/3's inline
# default) so the configured implementation is legible by reading config, not only by
# reading platform.ex's source. Tests override this per-test via Application.put_env/3
# to inject an exact, pre-set timestamp.
config :letflow, :lua_platform_time_source, Letflow.Engine.Lua.Platform.SystemClock

import_config "#{config_env()}.exs"
