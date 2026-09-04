defmodule Mix.Tasks.Letflow.Check.TestTest do
  @moduledoc """
  Regression coverage for `mix letflow.check.test` (`lib/mix/tasks/letflow.check.test.ex`)
  after ISS-0428 rewrote it to shell out to `bash scripts/test_parallel.sh` (an N-way
  parallel `mix test --partitions N` runner) instead of plain `mix test`, and re-pointed
  the ISS-0069 warning gate at the N per-partition log files the runner writes instead
  of the wrapper's own aggregated stdout.

  ## Why this file exists at all (read before touching it)

  This suite is the ONLY automated coverage of the ISS-0069 warning gate --
  `check_substring_across_logs/1` catching a recurrence of "default values for the
  optional arguments" (`docs/anti-patterns.md`, 7 prior real occurrences:
  REQ-178/187/191/195/203 among others). ISS-0428's own design doc
  (`lib/letflow/design/iss0428-parallel-runner-in-check-test.md` §1.1) is explicit that
  pointing this check at the wrong stream makes the gate go green while checking
  nothing, permanently, with nobody able to tell from a passing CI run. A suite that
  merely re-green-lights the new architecture without proving the gate still catches a
  real occurrence would be exactly that hazard, just relocated into the test file
  instead of the implementation.

  ## Technique: fake `bash` (and `mix`) on PATH, not the log-parsing internals directly

  The old (pre-ISS-0428) version of this file faked `mix` on PATH so that
  `System.find_executable("mix")` -- called internally by `run/1`'s single subprocess
  call -- resolved to a controlled fake instead of a real, recursing `mix test`. That
  interception point is gone: `run_main_suite/0` now calls `System.find_executable("bash")`
  and invokes `bash scripts/test_parallel.sh`, so a faked `mix` no longer intercepts the
  main suite's subprocess at all.

  This file fakes `bash` the same way the old file faked `mix` -- same technique, same
  spirit, moved to the seam the rewritten code actually shells out through. Three real
  alternatives were weighed:

    1. **Fake `bash` on PATH (chosen).** `run_main_suite/0`'s only interaction with the
       outside world is `System.find_executable("bash")` followed by a Port-spawned
       `bash scripts/test_parallel.sh` invocation whose captured stdout is parsed. A
       fake `bash` that prints a controlled `test_parallel: partition logs in <dir>`
       line (pointing at a synthetic fixture directory containing real files named
       `partition-N.log`) and exits with a controlled code drives `run_main_suite/0`
       and every private helper it calls (`find_partition_log_dir/1`, `partition_logs/1`,
       `check_substring_across_logs/1`, `report_partition_failures/1`) for REAL, exactly
       as committed -- nothing in the module under test is mocked, stubbed, or
       temporarily un-privatized. This is the closest available analogue to the old
       file's own technique and needs zero changes to `letflow.check.test.ex`.
    2. **Test the log-reading logic directly against fixtures, bypassing the
       subprocess.** Rejected as the *sole* technique: `find_partition_log_dir/1`,
       `partition_logs/1`, and `check_substring_across_logs/1` are `defp` today, so
       this would require either un-privatizing them (which the design doc's own
       Verification 3/4 did only temporarily, as a one-off probe, explicitly reverted
       afterward -- see the ELIXIR-DEV handoff) or duplicating their logic in the test,
       which would test the duplicate, not the shipped code. The design doc's public
       interface section (§6) does not ask for these to become public, and inventing a
       permanent testability seam not asked for by the design is a bigger footprint
       than option 1 needs. **Flagging this as a considered-and-rejected testability
       question, not a silent decision**: if a future maintainer wants direct unit
       tests of the parsing/globbing logic in isolation from the `bash` fake, the
       minimal change would be promoting exactly those three functions from `defp` to
       `def` (or `@doc false def`) -- nothing more. Not done here because option 1
       already reaches every one of them through the real public entry point,
       including their composition (ordering rule, error precedence), which isolated
       unit tests of the pieces alone would not.
    3. **Combination (fixtures for parsing + one real integration run).** Rejected for
       the "one real integration run" half: `scripts/test_parallel.sh` derives N from
       `nproc` and launches N real `mix test --partitions N` subprocesses against a
       real Postgres -- multiple minutes per run, non-deterministic partition-to-N
       assignment across hosts, and exactly the kind of slow/flaky addition to a suite
       that runs on every commit `docs/agents/instructions/core-directives.md` warns
       against manufacturing. A real end-to-end run of `test_parallel.sh` already
       exists as evidence in the ELIXIR-DEV and CODE-DESIGN-VALIDATOR handoffs (both
       quote real measured output against the real script); this file does not need to
       re-pay that cost on every CI run to preserve that evidence -- TEST-RUNNER/
       RELEASE-VALIDATOR's own full-suite run of `mix letflow.check.test` (which
       necessarily invokes the real script) is what continues exercising the real
       integration path going forward.

  All fixture data (`partition-N.log` files) lives under a fresh `System.tmp_dir!/0`
  subdirectory per test, deleted in `on_exit/1` -- no fixture is checked into the repo,
  since the content needed (a controlled ISS-0069-shaped warning line, a controlled
  `Failed:`/`Result:` shape) is small enough to construct inline and keeping it inline
  keeps the "what exactly is being proven" visible in the test itself rather than in a
  separate file a reader has to cross-reference.

  ## Windows PATH resolution (ISS-0171, same hazard as before, same fix as before)

  Exactly the same two problems the old file's own `install_fake_mix/2` documented
  apply unchanged to faking `bash`: (1) `System.find_executable/1` on Windows resolves
  a bare name against PATHEXT-style extensions, so an extensionless POSIX-shaped fake
  is invisible and the REAL `bash.exe` gets picked off PATH instead; (2) `PATH` uses
  `;` as its entry separator on Windows, not `:`. `install_fake_executable/3` below
  follows the old file's exact `.bat`-with-companion-`type`-file pattern for the same
  reason (arbitrary content -- quotes, parens, colons, exactly what a real compiler
  warning line and a `Mix.raise` message contain -- must never have to survive batch's
  own escaping rules), generalized to install any named executable rather than just
  `mix`.

  ## Fail-then-pass, proven not asserted (per WF-03's own requirement for this file)

  Every test below was run against this file's own committed logic AND independently
  re-derived by TEST-DESIGNER directly against the real, unmodified, shipped
  `Mix.Tasks.Letflow.Check.Test.run/1` via ad-hoc `mix run --no-start` probes using this
  exact fake-`bash`-on-PATH technique before this file was written (see the
  TEST-DESIGNER handoff for the literal transcripts of all six probes: the two "detects
  a real occurrence" cases, both hard-failure paths, the ordering rule, and the
  wrapper-nonzero-with-logs-present failure-reporting path) -- so these tests are known,
  by direct prior measurement against the real code, to pass against the fix. The
  mutation-testing requirement below (this issue's underlying code already existed
  pre-ISS-0428, so the "pre-fix code did not exist" carve-out does not strictly apply --
  but see the handoff for why one mutant is reported anyway, as belt-and-suspenders
  evidence) additionally proves each test can fail for the right reason.
  """

  use ExUnit.Case, async: false

  @target_substring "default values for the optional arguments"

  setup do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end
    end)

    fixture_root =
      Path.join(System.tmp_dir!(), "letflow_check_test_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_root)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    fake_bin_dir =
      Path.join(System.tmp_dir!(), "letflow_check_test_fakebin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_bin_dir)
    on_exit(fn -> File.rm_rf!(fake_bin_dir) end)

    %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir}
  end

  # Installs a fake executable named `name` (no extension) onto a shared fake-bin
  # directory, then prepends that directory onto PATH so
  # System.find_executable(name) resolves to it instead of the real one. `output` is
  # printed verbatim to stdout; `exit_code` is the process exit code.
  #
  # ISS-0171 (same hazard the old install_fake_mix/2 documented, generalized to any
  # executable name rather than hardcoded to "mix"): on Windows, System.find_executable/1
  # requires a PATHEXT-recognized extension (an extensionless file is invisible), and
  # PATH entries are ";"-separated, not ":"-separated. The Windows fake writes its
  # canned output to a companion file and has a .bat `type` it rather than `echo`-ing
  # inline, so arbitrary content (quotes, parens, colons) never has to survive batch's
  # own escaping rules -- verified directly: a `Mix.raise` message and a real compiler
  # warning line both contain characters batch's `echo` mangles.
  defp install_fake_executable(fake_bin_dir, name, output, exit_code) do
    case :os.type() do
      {:win32, _} ->
        output_path = Path.join(fake_bin_dir, "#{name}_output.txt")
        File.write!(output_path, output)

        fake_path = Path.join(fake_bin_dir, "#{name}.bat")
        windows_output_path = String.replace(output_path, "/", "\\")

        File.write!(fake_path, """
        @echo off
        type "#{windows_output_path}"
        exit /b #{exit_code}
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, name)

        File.write!(fake_path, """
        #!/bin/sh
        cat <<'FAKE_EXECUTABLE_OUTPUT'
        #{output}
        FAKE_EXECUTABLE_OUTPUT
        exit #{exit_code}
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # Prepends fake_bin_dir onto PATH (";"-joined on Windows, ":"-joined elsewhere) and
  # asserts System.find_executable/1 actually resolves each of `names` into it --
  # fail fast and legibly here rather than via a multi-minute real-subprocess timeout
  # if PATH resolution ever again picks the real executable instead of the fake
  # (exactly the ISS-0171 regression class both this file and its predecessor exist to
  # prevent).
  defp activate_fake_bin_dir(fake_bin_dir, names) do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"
    System.put_env("PATH", fake_bin_dir <> separator <> System.get_env("PATH", ""))

    Enum.each(names, fn name ->
      resolved = System.find_executable(name)
      expected_dir = fake_bin_dir |> Path.expand() |> String.downcase()
      resolved_dir = resolved && resolved |> Path.dirname() |> Path.expand() |> String.downcase()

      unless resolved_dir == expected_dir do
        flunk("""
        activate_fake_bin_dir/2 did not take effect for #{inspect(name)}: \
        System.find_executable(#{inspect(name)}) resolved to #{inspect(resolved)}, \
        expected a file inside #{inspect(fake_bin_dir)}. This would recurse into the \
        REAL executable (ISS-0171) instead of testing against the fake.
        """)
      end
    end)

    :ok
  end

  # Installs a passing fake `mix` (used by run_wasm_hang_tests/0 and
  # run_lua_wallclock_race_tests/0, both unchanged by ISS-0428 and still shelling
  # directly to `mix test --only ...`) so a test that only cares about
  # run_main_suite/0's behavior doesn't pay the cost -- or the nondeterminism -- of two
  # real `mix test --only wasm_hang`/`--only lua_wallclock_race` subprocess runs on
  # every case below. A test that specifically wants to exercise those two helpers can
  # override this by calling install_fake_executable/4 again with a different exit code
  # after this returns.
  defp install_passing_fake_mix(fake_bin_dir) do
    install_fake_executable(
      fake_bin_dir,
      "mix",
      "Finished in 0.0 seconds\nResult: 0 passed\n",
      0
    )
  end

  # Writes `name` under fixture_root/log_subdir with `content`, creating the directory
  # if needed. Returns the absolute, "/"-normalized path to log_subdir (the shape
  # find_partition_log_dir/1's regex expects, and what a real bash/MSYS subprocess on
  # this project's Windows host actually prints -- see resolve_native_path/1's own
  # commentary in the module under test).
  defp write_partition_log(fixture_root, log_subdir, name, content) do
    dir = Path.join(fixture_root, log_subdir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), content)
    dir |> Path.expand() |> String.replace("\\", "/")
  end

  # Builds the fake bash's own stdout: the required "test_parallel: N=..." line (not
  # parsed by the module under test, but present in every real invocation, so a
  # fixture omitting it would be unrealistic) plus, when log_dir is given, the
  # "test_parallel: partition logs in <dir>" line find_partition_log_dir/1 parses.
  defp fake_runner_stdout(log_dir) do
    header = "test_parallel: N=2 (source: fake)\n"

    case log_dir do
      nil -> header
      dir -> header <> "test_parallel: partition logs in #{dir}\n"
    end
  end

  defp run_and_capture_ok(fake_bin_dir) do
    activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])

    ExUnit.CaptureIO.capture_io(fn ->
      assert Mix.Tasks.Letflow.Check.Test.run([]) == :ok
    end)
  end

  describe "mix letflow.check.test's re-pointed ISS-0069 gate (design doc section 1)" do
    test "raises and reports the offending line, with partition attribution, when the target substring is present in a per-partition log even though the wrapper exited 0",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      offending_line =
        "test/letflow/some_helper_test.exs:42: warning: default values for the optional arguments in unique_idempotency_key/1 are never used, because all calls in this file are made with all arguments"

      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        Compiling 3 files (.ex)
        #{offending_line}
        Result: 5/5 passed
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
      install_passing_fake_mix(fake_bin_dir)

      exception =
        assert_raise Mix.Error, ~r/#{Regex.escape(@target_substring)}/, fn ->
          activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])

          ExUnit.CaptureIO.capture_io(fn ->
            Mix.Tasks.Letflow.Check.Test.run([])
          end)
        end

      # Partition attribution (design doc §1.2 step 5) -- the raised message must name
      # WHICH partition log the warning came from, not just that a warning exists
      # somewhere. "[partition 1]" and never "[partition 2]", since only
      # partition-1.log contains the offending line.
      assert exception.message =~ "[partition 1]"
      refute exception.message =~ "[partition 2]"
      assert exception.message =~ offending_line
    end

    test "passes (no raise) when the wrapper exits 0 and the target substring is absent from every partition log, even with unrelated warnings present",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        Compiling 3 files (.ex)
        warning: ExUnit.Case.register_test/4 is deprecated
        warning: variable "tenant" is unused
        Result: 5/5 passed
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
      install_passing_fake_mix(fake_bin_dir)

      io = run_and_capture_ok(fake_bin_dir)

      assert io =~ "OK -- no test failures, no ISS-0069 warnings"
      assert io =~ "2 partitions"
      refute io =~ @target_substring
    end

    test "raises when the wrapper itself exits nonzero (real test failure), regardless of the substring, and prints the failing partition's full log content before raising",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        1) test something (SomeTest)
           Assertion failed
        Failed: 1 test
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 2/2 passed\n")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 1)
      install_passing_fake_mix(fake_bin_dir)

      activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])

      {exception, io} =
        ExUnit.CaptureIO.with_io(fn ->
          assert_raise Mix.Error, ~r/exited 1/, fn ->
            Mix.Tasks.Letflow.Check.Test.run([])
          end
        end)

      assert exception.message =~ "exited 1"
      assert exception.message =~ "Partition logs:"
      # Failure-mode parity (design doc §4.2): the failing partition's full log content
      # must be printed (not just its count/existence) so an agent reading the terminal
      # sees the real assertion detail without needing the discarded tmp dir.
      assert io =~ "partition 1"
      assert io =~ "Assertion failed"
      assert io =~ "FAILED"
    end
  end

  describe "mix letflow.check.test's two new hard-failure paths (design doc section 1.2, must never pass silently)" do
    test "hard-fails when the wrapper exits 0 but never prints a parseable partition-log-directory line",
         %{fake_bin_dir: fake_bin_dir} do
      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(nil), 0)
      install_passing_fake_mix(fake_bin_dir)

      activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "never printed"
      assert exception.message =~ "partition logs in"
    end

    test "hard-fails when the log-dir line is present but the directory contains zero partition-*.log files",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      empty_dir = Path.join(fixture_root, "empty_logs")
      File.mkdir_p!(empty_dir)
      normalized = empty_dir |> Path.expand() |> String.replace("\\", "/")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(normalized), 0)
      install_passing_fake_mix(fake_bin_dir)

      activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "zero partition-*.log files"
    end
  end

  describe "mix letflow.check.test's ORDERING RULE (design doc section 1.2 step 1, CODE-DESIGN-VALIDATOR MINOR finding)" do
    test "when the wrapper exits nonzero AND the log-dir line is absent, reports the wrapper's nonzero exit FIRST, not \"log line missing\"",
         %{fake_bin_dir: fake_bin_dir} do
      # Mirrors the real, common case: `mix compile` fails inside test_parallel.sh's
      # own pre-compile step, so the script exits nonzero before its unconditional
      # "partition logs in <dir>" line is ever reached/printed.
      install_fake_executable(
        fake_bin_dir,
        "bash",
        "test_parallel: ERROR pre-compile failed with exit 1 -- no partition launched\n",
        1
      )

      install_passing_fake_mix(fake_bin_dir)

      activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      # Positive assertion: the message an agent sees leads with the wrapper's own
      # nonzero exit / compile-failure framing...
      assert exception.message =~ "exited 1 before ever printing"

      # ...and does NOT lead a reader toward hunting a nonexistent log-parsing bug.
      # This is the precise behavior the design doc's ordering rule exists to
      # guarantee: reporting "log line missing" here would send an agent looking in
      # the wrong place instead of at the real compile error in the streamed output.
      refute exception.message =~
               "never printed a \"test_parallel: partition logs in <dir>\" line. This " <>
                 "task cannot locate"
    end
  end
end
