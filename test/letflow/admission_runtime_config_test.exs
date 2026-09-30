defmodule Letflow.AdmissionRuntimeConfigTest do
  @moduledoc """
  Tests for ISS-0908 (GH-2032) -- `config/runtime.exs`'s prod-only `Letflow.Repo`
  `pool_size` default and the new `:letflow, :admission, :reserved_headroom`
  wiring, per `lib/letflow/design/iss0908-admission-pool-headroom.md` §5/AC5.

  ## Why these tests shell out to a real `mix run --no-start` subprocess

  `config/runtime.exs`'s `if config_env() == :prod do` block only ever evaluates
  under `MIX_ENV=prod` -- this already-booted test suite runs under `MIX_ENV=test`
  and cannot re-enter that branch by calling a function, same reasoning as
  `test/letflow/secrets_runtime_config_test.exs`'s own moduledoc for that file's
  `LETFLOW_SECRETS_MASTER_KEY` checks (which live in the SAME file, just outside
  the `if config_env() == :prod do` block).

  `--no-start` is load-bearing: `mix run` always evaluates `config/runtime.exs`
  (via Mix's own `app.config` step) before deciding whether to start the OTP
  application, so the prod branch's config still resolves and can be inspected --
  but `--no-start` means `Letflow.Application.start/2` (and therefore
  `Letflow.Repo`'s real connection attempt) never runs. This lets the test assert
  against the resolved `pool_size`/`reserved_headroom` values with a throwaway,
  unreachable `DATABASE_URL` and without a live Postgres, matching this design's
  §5 instruction to assert only against the resolved config value, not a full node
  boot.

  `LETFLOW_SECRETS_MASTER_KEY` must still be a validly-shaped (64 lowercase-hex,
  non-zero, non-all-0xFF) value even though this suite has nothing to do with
  secrets -- `config/runtime.exs` validates it unconditionally (REQ-190, outside
  the `if config_env() == :prod do` block), in every environment, before reaching
  the prod branch this suite actually targets.

  `MIX_TEST_PARTITION`/`MIX_BUILD_PATH` are explicitly nil'd in `env:` for the same
  reason `secrets_runtime_config_test.exs` documents: under
  `scripts/test_parallel.sh` this test process itself has them set, and
  `System.cmd/3`'s `env:` option merges onto (rather than replaces) the inherited
  environment, so an un-nil'd `MIX_TEST_PARTITION` would leak into the child
  `MIX_ENV=prod` subprocess. `config/runtime.exs`'s `MIX_TEST_PARTITION` guard is
  itself only wired for `MIX_ENV=dev` (`config/dev.exs`), so it wouldn't fire
  under `MIX_ENV=prod` regardless -- nil'd anyway per the same defensive
  reasoning as that file.

  `@tag :slow` -- each test spawns a fresh `mix run --no-start`, materially slower
  than the rest of the suite. Not `@tag :skip`: this project runs all tags by
  default (no `ExUnit.configure(exclude: ...)` in `mix.exs`).

  ## Why `setup_all` precompiles `_build/prod` (ISS-0908 follow-up, flaky CI timeout)

  All 5 tests below run `async: true` and each independently shells out to `mix run
  --no-start` under `MIX_ENV=prod`, with `MIX_BUILD_PATH` nil'd (see above) so the
  child process falls back to the default `_build/prod` directory. On a warm
  checkout (already-compiled `_build/prod` from an earlier local run) this is fast.
  On a genuinely cold CI runner, `_build/prod` doesn't exist yet, so whichever
  subprocess reaches `mix run` first triggers a full project compile under
  `MIX_ENV=prod` -- and because `async: true` starts all 5 tests concurrently, every
  one of their subprocesses race into that same cold compile simultaneously. A
  compile of this size can exceed ExUnit's default 60s per-test timeout, failing
  whichever test's subprocess is still waiting when the clock runs out (observed in
  CI run 36736055229: "RESERVED_HEADROOM absent ..." timed out at exactly 60000ms;
  1418/1419 other tests passed -- a flaky timeout, not a real assertion failure).

  The fix: pay the cold-compile cost exactly once, synchronously, in `setup_all`,
  before any of the 5 tests start. `setup_all` runs in its own process with no
  ExUnit-imposed timeout of its own (`ExUnit.Runner.run_setup_all/4` blocks on a
  plain `receive` with no `after` clause -- confirmed by reading
  `lib/ex_unit/runner.ex` in this project's installed Elixir/OTP 29 toolchain), so
  an expensive first-time compile here has no 60s budget to race against. By the
  time the 5 `async: true` tests start, `_build/prod` is already warm and each
  test's own `mix run --no-start` subprocess only has to load already-compiled
  `.beam` files, comfortably inside the 60s per-test timeout even under load.
  """

  use ExUnit.Case, async: true

  @moduletag :slow

  setup_all do
    env = [
      {"MIX_ENV", "prod"},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil}
    ]

    {output, exit_status} =
      System.cmd("mix", ["compile"], env: env, stderr_to_stdout: true, cd: File.cwd!())

    if exit_status != 0 do
      raise "precompiling _build/prod under MIX_ENV=prod failed (exit #{exit_status}):\n#{output}"
    end

    :ok
  end

  # Not a real secret -- 64 lowercase-hex chars, deliberately not all-zero or
  # all-0xFF (config/runtime.exs's REQ-190 validation rejects both), used only to
  # satisfy that unconditional check so this suite can reach the `if
  # config_env() == :prod do` branch it actually targets.
  @dummy_secrets_master_key String.duplicate("1234567890abcdef", 4)
  @dummy_database_url "ecto://letflow:unused@localhost/letflow_unreachable"

  defp run_runtime_config(extra_env) do
    base_env = [
      {"MIX_ENV", "prod"},
      {"DATABASE_URL", @dummy_database_url},
      {"LETFLOW_SECRETS_MASTER_KEY", @dummy_secrets_master_key},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil}
    ]

    env =
      Enum.reduce(extra_env, base_env, fn {k, v}, acc ->
        [{k, v} | Enum.reject(acc, fn {ek, _} -> ek == k end)]
      end)

    System.cmd(
      "mix",
      [
        "run",
        "--no-start",
        "-e",
        "IO.inspect({Application.fetch_env!(:letflow, Letflow.Repo)[:pool_size], Application.get_env(:letflow, :admission)[:reserved_headroom]})"
      ],
      env: env,
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  test "POOL_SIZE absent resolves pool_size to 30 (not the old default of 10)" do
    {output, exit_status} = run_runtime_config([{"POOL_SIZE", nil}, {"RESERVED_HEADROOM", nil}])

    assert exit_status == 0, "expected exit 0, got #{exit_status} with output:\n#{output}"
    assert output =~ "{30, 2}"
  end

  test "POOL_SIZE explicitly set still overrides the new default" do
    {output, exit_status} =
      run_runtime_config([{"POOL_SIZE", "15"}, {"RESERVED_HEADROOM", nil}])

    assert exit_status == 0, "expected exit 0, got #{exit_status} with output:\n#{output}"
    assert output =~ "{15, 2}"
  end

  test "RESERVED_HEADROOM absent resolves reserved_headroom to 2, matching Letflow.Admission's @default_reserved_headroom" do
    {output, exit_status} = run_runtime_config([{"POOL_SIZE", nil}, {"RESERVED_HEADROOM", nil}])

    assert exit_status == 0, "expected exit 0, got #{exit_status} with output:\n#{output}"
    assert output =~ "{30, 2}"
  end

  test "RESERVED_HEADROOM explicitly set resolves end to end to the overridden value" do
    {output, exit_status} =
      run_runtime_config([{"POOL_SIZE", nil}, {"RESERVED_HEADROOM", "5"}])

    assert exit_status == 0, "expected exit 0, got #{exit_status} with output:\n#{output}"
    assert output =~ "{30, 5}"
  end

  test "RESERVED_HEADROOM set to a non-numeric value fails fast the same way POOL_SIZE's own String.to_integer/1 line always has" do
    {output, exit_status} =
      run_runtime_config([{"POOL_SIZE", nil}, {"RESERVED_HEADROOM", "abc"}])

    refute exit_status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    assert output =~ "ArgumentError"
  end
end
