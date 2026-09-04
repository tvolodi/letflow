defmodule Mix.Tasks.Letflow.Check.Test do
  @shortdoc "Runs the test suite (parallel), gated only on ISS-0069's own warning class (unused defaults)"

  @moduledoc """
  ISS-0069 Part 2 (revised): the `test` step used by `mix letflow.check`.

  ISS-0428: shells out to `scripts/test_parallel.sh` (via `bash`) instead of plain
  `mix test` -- the parallel runner N-way partitions the suite (N derived from
  `TEST_PARALLEL_N`/`nproc`/`getconf`, never hardcoded here; see the script's own
  header and `docs/migration/decisions/0009-test-parallel-pool-sizing.md`), which
  measured 1.89x on CI's actual 2-vCPU parallelism and up to ~5x on a 16-core dev
  host (see `lib/letflow/design/iss0428-parallel-runner-in-check-test.md` section 0).
  No `mix.exs`/`ci.yml` edit is needed for CI to pick this up: CI's only backend gate
  is `mix letflow.check`, which already calls this task (REQ-136).

  The runner's own stdout only ever carries per-partition summary lines and an
  aggregated total -- never the constituent partitions' raw test output. So the
  ISS-0069 substring check below does **not** read that aggregate stream. It parses
  the runner's `test_parallel: partition logs in <dir>` line (printed unconditionally
  once the runner reaches its partition-launch step), discovers every
  `partition-*.log` file under that directory (no hardcoded partition count), and
  applies the substring check to their concatenated content -- see design doc
  section 1 for the full rationale, including why pointing this check at the
  aggregate stdout instead would make it an unreliable gate (sometimes catching a
  warning, sometimes not, depending on Mix's compile-manifest re-emission behavior)
  rather than a reliably vacuous one.

  If the log-dir line is absent/unparseable, or zero partition logs are found, this
  task hard-fails (`Mix.raise`) rather than silently passing -- a future edit to
  `scripts/test_parallel.sh` that removes or reworks that output contract must break
  this gate loudly, never silently stop gating.

  **Ordering rule** (design doc section 1.2 step 1): when the runner exits nonzero
  AND the log-dir line is absent, this task reports the runner's nonzero exit first,
  not "log line missing" -- the common real case is a `mix compile` failure inside
  `test_parallel.sh`'s own pre-compile step, which exits before the log-dir line is
  ever printed, and leading with "log line missing" would send a reader hunting a
  nonexistent parsing bug instead of the real compile error.

  **Failure-mode parity** (design doc section 4): on a failing run, this task prints
  the full content of every partition log that shows real test failures (a `Failed:`
  line) or a crash (no `Result:` line) before raising, so an agent reading the
  terminal/CI job log sees the actual failing test's detail without needing the
  runner's own `mktemp -d` directory to still exist.

  ISS-0352: after the main suite passes, this task runs a SECOND subprocess, `mix
  test --only wasm_hang`, in its own fresh BEAM node -- unchanged by ISS-0428, still
  serial. `:wasm_hang` tags a handful of tests in `test/letflow/engine/wasm/` that
  deliberately, genuinely hang a real `wasmex` NIF call to prove REQ-170's own
  live-verified finding that no BEAM-side mechanism can reclaim that thread -- it
  permanently occupies one slot of `wasmex`'s shared, node-global native worker pool
  for the rest of the OS process. Run in the same process as every other WASM NIF
  test, this starved unrelated tests once the pool was exhausted (PR #691, then worse
  on PR #692 -- 18 cascading `ExUnit.TimeoutError`s). Running under N-way parallelism
  would multiply this hazard by N, so it stays a single serial subprocess.

  ISS-0426: this task then runs a THIRD subprocess, `mix test --only
  lua_wallclock_race`, also unchanged and serial -- these tests need to run without
  racing 30+ concurrently-scheduled siblings for wall-clock-sensitive timing (see
  `lib/letflow/design/iss426-wallclock-test-contention.md` section 2.3). ISS-0423
  already recorded that parallel running is exactly what surfaces this flake, so
  putting these inside a parallel partition would reintroduce the contention they
  were isolated to remove.

  Unlike a blanket `test --warnings-as-errors`, this task does **not** fail
  on every warning. `docs/issues/ISS-0044.yaml` (`status: resolved`)
  already diagnosed two warning classes that only ever surface under
  `mix test` (never under `mix compile --warnings-as-errors`) as
  permanently deferred, not fixed:

    * `ExUnit.Case.register_test/4 is deprecated` (ISS-0044 Group 1) --
      blocked on a `stream_data` 0.6.0 -> up to 1.4.0 version bump.
    * `redefining module ... CreateEventTypeRegistry` (ISS-0044 Group 3) --
      a deliberate, documented `Code.require_file/1` test workaround.

  Blanket `--warnings-as-errors` fails on both regardless of this issue's
  fix, so this task instead gates narrowly on ISS-0069's own class: an
  unused default value on an optional `defp` argument in a test helper,
  whose compiler warning always starts with the fixed, stable substring
  `"default values for the optional arguments"` (see
  `lib/letflow/design/iss0069-unused-default-warnings-fix.md`).

  ## Exit-code contract

    * Exits `0` only if the parallel runner's own aggregated result is a real pass
      (every partition has a `Result:` line, zero parsed failures) **and** the
      target substring is absent from every partition log **and** both isolated
      subprocess runs (`:wasm_hang`, `:lua_wallclock_race`) also exit `0` clean.
    * Exits `1` if the runner (or either isolated subprocess) reports real failures,
      regardless of the substring check.
    * Exits `1` if the runner (or either isolated subprocess) exits `0` but the
      target substring is present anywhere in the relevant captured/log output,
      printing the offending line(s) -- with partition attribution for the main
      suite -- so the failure is immediately actionable.

  Every other warning class (including the two ISS-0044 classes above, and
  the separately out-of-scope unused `tenant` variable) remains visible in
  the streamed output but never affects this task's exit code.

  ## Usage

      mix letflow.check.test

  No arguments -- invoked from the `letflow.check` alias. `run/1` accepts
  and ignores the arg list Mix passes, matching the standard `Mix.Task`
  `run/1` shape.
  """

  use Mix.Task

  @target_substring "default values for the optional arguments"
  @log_dir_line_regex ~r/^test_parallel: partition logs in (.+)$/m

  @impl Mix.Task
  def run(_args) do
    run_main_suite()
    run_wasm_hang_tests()
    run_lua_wallclock_race_tests()
  end

  # ISS-0428: shells out to scripts/test_parallel.sh (an N-way parallel `mix test
  # --partitions N` runner) instead of plain `mix test`, then re-points the ISS-0069
  # substring check at the N per-partition log files the runner writes -- see
  # moduledoc and design doc section 1 for the full rationale.
  defp run_main_suite do
    bash = System.find_executable("bash")

    if is_nil(bash) do
      Mix.raise(
        "mix letflow.check.test: no bash found on PATH -- scripts/test_parallel.sh " <>
          "requires bash; see docs/guides/backend_developer_guide.md for setup."
      )
    end

    {output, exit_code} = stream_and_capture(bash, ["scripts/test_parallel.sh"])

    # ORDERING RULE (design doc section 1.2 step 1): if the runner exited nonzero,
    # report that first -- even if the log-dir line also happens to be missing. The
    # common real case is a `mix compile` failure inside test_parallel.sh's own
    # pre-compile step, which exits before the log-dir line is ever printed;
    # leading with "log line missing" would send a reader hunting a nonexistent
    # parsing bug instead of the real compile error.
    case find_partition_log_dir(output) do
      :not_found when exit_code != 0 ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- scripts/test_parallel.sh exited " <>
            "#{exit_code} before ever printing its partition-log-directory line " <>
            "(the most common cause is a `mix compile` failure in the runner's own " <>
            "pre-compile step -- check the streamed output above for the real error)."
        )

      :not_found ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- scripts/test_parallel.sh exited 0 but " <>
            "never printed a \"test_parallel: partition logs in <dir>\" line. This " <>
            "task cannot locate the per-partition logs it needs for the ISS-0069 " <>
            "warning check, so it is treating this as a hard failure of the check " <>
            "itself rather than silently passing."
        )

      {:ok, log_dir} ->
        check_main_suite_logs(resolve_native_path(log_dir), exit_code)
    end
  end

  # The directory in the log-dir line is printed by a bash/MSYS subprocess and may
  # be a POSIX-style path (e.g. "/tmp/...") that only bash/MSYS itself can resolve --
  # on this project's Windows/Git Bash host, "/tmp" is an MSYS mount onto a real
  # Windows directory (confirmed: `mount` shows "... on /tmp type ntfs"), invisible
  # to a native-Windows BEAM's own file driver (`File.exists?("/tmp/...")` is false
  # even though the directory genuinely exists). Try the path as-is first (already
  # correct on Linux/CI); if it doesn't resolve and `cygpath` is on PATH (Git Bash
  # always provides it), translate via `cygpath -w` to the native Windows form.
  # This does not change what directory is being read, only how Elixir addresses it.
  defp resolve_native_path(dir) do
    if File.exists?(dir) do
      dir
    else
      case System.find_executable("cygpath") do
        nil ->
          dir

        cygpath ->
          case System.cmd(cygpath, ["-w", dir]) do
            {native, 0} -> native |> String.trim() |> String.replace("\\", "/")
            _ -> dir
          end
      end
    end
  end

  defp check_main_suite_logs(log_dir, exit_code) do
    case partition_logs(log_dir) do
      [] ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- partition log directory #{log_dir} " <>
            "contains zero partition-*.log files. The runner never actually ran " <>
            "any partitions, so this is a hard failure rather than a silent pass."
        )

      logs ->
        indexed_logs = index_partition_logs(logs)

        if exit_code != 0 do
          report_partition_failures(indexed_logs)

          Mix.raise(
            "mix letflow.check.test: FAILED -- scripts/test_parallel.sh exited " <>
              "#{exit_code} (real test failure/error). Partition logs: #{log_dir}"
          )
        end

        case check_substring_across_logs(indexed_logs) do
          {:offending, offending} ->
            offending_lines =
              offending
              |> Enum.map(fn {i, line} -> "  [partition #{i}] #{line}" end)
              |> Enum.join("\n")

            Mix.raise(
              "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found " <>
                "(ISS-0069's own class recurring):\n#{offending_lines}\nPartition logs: #{log_dir}"
            )

          :ok ->
            Mix.shell().info(
              "mix letflow.check.test: OK -- no test failures, no ISS-0069 warnings " <>
                "(#{length(logs)} partitions, logs: #{log_dir})."
            )
        end
    end
  end

  # Parses the runner's own captured stdout for its unconditional
  # "test_parallel: partition logs in <dir>" line. Never raises -- run_main_suite/0
  # is the one that turns :not_found into a Mix.raise, per this module's existing
  # separation between pure helpers and raising call sites.
  @spec find_partition_log_dir(String.t()) :: {:ok, Path.t()} | :not_found
  defp find_partition_log_dir(output) do
    case Regex.run(@log_dir_line_regex, output) do
      [_, dir] -> {:ok, String.trim(dir)}
      nil -> :not_found
    end
  end

  # Sorted list of partition-*.log paths directly under dir. Empty list is a legal
  # return -- the caller decides whether that's an error.
  @spec partition_logs(Path.t()) :: [Path.t()]
  defp partition_logs(dir) do
    dir
    |> Path.join("partition-*.log")
    |> Path.wildcard()
    |> Enum.sort()
  end

  # Attaches each log's 1-based partition index (parsed from its own filename, not
  # list position, so a gap or non-contiguous naming can't silently mislabel a log).
  @spec index_partition_logs([Path.t()]) :: [{pos_integer(), Path.t()}]
  defp index_partition_logs(logs) do
    Enum.map(logs, fn path ->
      index =
        case Regex.run(~r/partition-(\d+)\.log$/, path) do
          [_, n] -> String.to_integer(n)
          nil -> 0
        end

      {index, path}
    end)
  end

  # Concatenates every partition log's content and applies the ISS-0069 substring
  # check, tracking {partition_index, matching_line} pairs so failures can be
  # attributed to the partition they came from.
  @spec check_substring_across_logs([{pos_integer(), Path.t()}]) ::
          :ok | {:offending, [{pos_integer(), String.t()}]}
  defp check_substring_across_logs(indexed_logs) do
    offending =
      for {index, path} <- indexed_logs,
          line <- read_lines(path),
          String.contains?(line, @target_substring) do
        {index, line}
      end

    case offending do
      [] -> :ok
      lines -> {:offending, lines}
    end
  end

  # Prints full content of every partition log showing a real `Failed:` line or a
  # missing `Result:` line (crashed before completing) -- design doc section 4.2.
  @spec report_partition_failures([{pos_integer(), Path.t()}]) :: :ok
  defp report_partition_failures(indexed_logs) do
    Enum.each(indexed_logs, fn {index, path} ->
      content = File.read!(path)

      cond do
        String.contains?(content, "Failed: ") ->
          Mix.shell().info("\n=== partition #{index} log (#{path}) -- FAILED ===\n#{content}")

        not String.contains?(content, "Result: ") ->
          Mix.shell().info(
            "\n=== partition #{index} log (#{path}) -- NO Result: LINE (crashed) ===\n#{content}"
          )

        true ->
          :ok
      end
    end)

    :ok
  end

  defp read_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
  end

  # ISS-0352: run the deliberately-hanging :wasm_hang tests in their own
  # subprocess, isolated from the main run above -- see moduledoc. Unchanged by
  # ISS-0428 (design doc section 2): stays serial, no test_parallel.sh involvement.
  defp run_wasm_hang_tests do
    {hang_output, hang_exit_code} = stream_and_capture("mix", ["test", "--only", "wasm_hang"])

    if hang_exit_code != 0 do
      Mix.raise(
        "mix letflow.check.test: FAILED -- isolated `mix test --only wasm_hang` run " <>
          "exited #{hang_exit_code} (real test failure/error)."
      )
    end

    if String.contains?(hang_output, @target_substring) do
      offending_lines =
        hang_output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, @target_substring))
        |> Enum.join("\n")

      Mix.raise(
        "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found in the " <>
          "isolated :wasm_hang run (ISS-0069's own class recurring):\n#{offending_lines}"
      )
    end

    Mix.shell().info("mix letflow.check.test: OK -- isolated :wasm_hang run also passed clean.")
  end

  # ISS-0426: run the tag-isolated :lua_wallclock_race tests (REQ-155/156/162,
  # test/letflow/engine/lua/executor_test.exs) in their own subprocess, isolated
  # from the main run above -- same shape as run_wasm_hang_tests/0, see
  # lib/letflow/design/iss426-wallclock-test-contention.md §2.3 and this module's
  # moduledoc's ISS-0352 section. Unlike :wasm_hang, these tests don't leak
  # anything -- they just need to run without racing 30+ concurrently-scheduled
  # siblings for wall-clock-sensitive timing. Unchanged by ISS-0428: stays serial.
  defp run_lua_wallclock_race_tests do
    {race_output, race_exit_code} =
      stream_and_capture("mix", ["test", "--only", "lua_wallclock_race"])

    if race_exit_code != 0 do
      Mix.raise(
        "mix letflow.check.test: FAILED -- isolated `mix test --only lua_wallclock_race` " <>
          "run exited #{race_exit_code} (real test failure/error)."
      )
    end

    if String.contains?(race_output, @target_substring) do
      offending_lines =
        race_output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, @target_substring))
        |> Enum.join("\n")

      Mix.raise(
        "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found in the " <>
          "isolated :lua_wallclock_race run (ISS-0069's own class recurring):\n#{offending_lines}"
      )
    end

    Mix.shell().info(
      "mix letflow.check.test: OK -- isolated :lua_wallclock_race run also passed clean."
    )
  end

  # Runs `cmd` as a subprocess via an OS-level Port so its combined
  # stdout+stderr is streamed live (visible immediately, same as running
  # the command directly) while also being captured in full for the
  # substring check above. `System.cmd/3`'s own `:into` option can do one
  # or the other but not both at once (an `IO.stream` target prints live
  # but discards the text; a plain list/binary target captures but only
  # after the subprocess exits), so a raw port is used instead.
  defp stream_and_capture(cmd, args) do
    executable = System.find_executable(cmd) || raise "executable not found: #{cmd}"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        collect(port, [acc, chunk])

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(acc), status}
    end
  end
end
