defmodule Letflow.SecretsRuntimeConfigTest do
  @moduledoc """
  Tests for REQ-190 AC6 -- `LETFLOW_SECRETS_MASTER_KEY` missing or malformed fails
  application boot, per `docs/migration/decisions/0016-secrets-storage-backend.md` §B
  and `lib/letflow/design/req190-secrets-core.md` §2. Implementation:
  `config/runtime.exs`.

  ## Why these tests shell out to a real `mix run` subprocess

  `config/runtime.exs`'s validation runs exactly once, at BEAM node boot, before
  `Letflow.Application.start/2` -- it is not a function this already-booted test suite
  can re-invoke with a different environment-variable value. There is no way to
  re-exercise a `raise` inside `config/runtime.exs` from inside the process that has
  already passed it. `System.cmd/3` spawning a fresh `mix run` in a child OS process,
  with a deliberately absent/malformed env var, is the only way to actually observe
  this behavior -- anything else (e.g. extracting the validation into a plain function
  and unit-testing that in isolation) would test a refactor of the design, not the
  design as actually written in `config/runtime.exs`.

  Spiked interactively before writing these tests (commands and their real observed
  output):

    env -u LETFLOW_SECRETS_MASTER_KEY MIX_ENV=dev mix run -e "IO.puts(1)"
      -> exit 1, "... is missing. Required in every environment ..."

    LETFLOW_SECRETS_MASTER_KEY="not-64-hex-characters-at-all" MIX_ENV=test mix run -e "IO.puts(1)"
      -> exit 1, "... is malformed: it must be exactly 64 lowercase hexadecimal ..."

  `MIX_ENV=test` cannot exercise the truly-*absent* case: `config/test.exs` itself
  injects a fallback test-only value when the variable is absent from the real
  environment (so the rest of this suite can boot at all), so an absent-var subprocess
  run under `MIX_ENV=test` would silently succeed via that fallback and prove nothing.
  `MIX_ENV=dev` has no such fallback. Boot never reaches `Letflow.Repo` (the raise
  fires during config evaluation, before any DB connection attempt), so no live
  Postgres is required for the `MIX_ENV=dev` subprocess to fail exactly as asserted.

  Also spiked and rejected: an **empty string** value (`""`) for the malformed case.
  Passed via `System.cmd/3`'s `env:` option, it arrives at the child process
  indistinguishable from an absent variable on this host (`System.get_env/1` inside
  the child returned `config/test.exs`'s own fallback value, not `""`) -- so it would
  silently exercise the "absent" path instead of "present but malformed," proving
  nothing distinct from the first test. The malformed-value test below therefore uses
  a non-empty, wrong-shaped string instead.

  `@tag :slow` -- each test spawns a fresh `mix run`, materially slower than the rest
  of the suite (measured several seconds, dominated by Elixir/Erlang VM boot). Not
  `@tag :skip`: this project runs all tags by default (`mix.exs` defines no
  `ExUnit.configure(exclude: ...)`), so `:slow` here is informational, not a means of
  excluding the test from a normal `mix test` run. `System.cmd/3` has no timeout
  option of its own -- ExUnit's own per-test timeout (default 60s, ample headroom
  above the few-second `mix run` boot this measures) is the backstop if a subprocess
  ever genuinely hangs.
  """

  use ExUnit.Case, async: true

  @moduletag :slow

  test "LETFLOW_SECRETS_MASTER_KEY unset fails application boot with a clear 'is missing' error" do
    # MIX_TEST_PARTITION/MIX_BUILD_PATH must be explicitly nil'd out, not just
    # left unset here: `System.cmd/3`'s `env:` option merges onto this test
    # process's own inherited environment rather than replacing it, and under
    # scripts/test_parallel.sh this process itself has MIX_TEST_PARTITION (and
    # MIX_BUILD_PATH) set on it -- inherited by the child `mix run` below, which
    # would then trip config/dev.exs's own ISS-0015 guard ("MIX_TEST_PARTITION is
    # set, but MIX_ENV is dev") instead of ever reaching the assertion this test
    # is actually checking. Reproduced: this test passed under a plain serial
    # `mix test` but failed under `scripts/test_parallel.sh` before this fix.
    env = [
      {"LETFLOW_SECRETS_MASTER_KEY", nil},
      {"MIX_ENV", "dev"},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil}
    ]

    {output, exit_status} =
      System.cmd("mix", ["run", "-e", "IO.puts(:should_not_reach_here)"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    refute exit_status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    assert output =~ "LETFLOW_SECRETS_MASTER_KEY"
    assert output =~ "is missing"
    refute output =~ "should_not_reach_here"
  end

  test "LETFLOW_SECRETS_MASTER_KEY set to a malformed value fails application boot with a clear 'is malformed' error" do
    # Deliberately a non-empty, wrong-shaped value -- NOT an empty string. An empty
    # string passed via System.cmd/3's env: option is indistinguishable from an
    # absent variable once it reaches the child process on this host (confirmed by
    # spiking: System.get_env/1 in the child returned config/test.exs's own
    # fallback value, not ""), so it would silently exercise the "absent" path
    # instead of "present but malformed" and prove nothing distinct from the first
    # test above.
    env = [{"LETFLOW_SECRETS_MASTER_KEY", "not-64-hex-characters-at-all"}, {"MIX_ENV", "test"}]

    {output, exit_status} =
      System.cmd("mix", ["run", "-e", "IO.puts(:should_not_reach_here)"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    refute exit_status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    assert output =~ "LETFLOW_SECRETS_MASTER_KEY"
    assert output =~ "is malformed"
    refute output =~ "should_not_reach_here"
  end
end
