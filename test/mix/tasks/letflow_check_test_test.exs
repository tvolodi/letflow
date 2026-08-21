defmodule Mix.Tasks.Letflow.Check.TestTest do
  @moduledoc """
  Regression coverage for ISS-0069 Part 2: `mix letflow.check.test`
  (`lib/mix/tasks/letflow.check.test.ex`).

  ISS-0069's own class is "an unused default value on a `defp` optional
  argument in a test helper" -- and this task's entire job is to *gate on
  a recurrence of that class* by shelling out to `mix test` and scanning
  the captured combined output for the fixed substring `"default values
  for the optional arguments"`. The design doc
  (`lib/letflow/design/iss0069-unused-default-warnings-fix.md`, "Verification"
  item 3) already had ELIXIR-DEV prove this manually once, by hand,
  uncommitted -- reintroduce a default, watch the gate fail, revert. This
  file is that same negative-control check, captured permanently and
  reproducibly instead of a one-off manual demonstration.

  ## Why this test is shaped the way it is

  The detection logic (`String.contains?/2` against the fixed substring,
  plus the exit-code contract) lives entirely inline inside
  `Mix.Tasks.Letflow.Check.Test.run/1`, which shells out to a real `mix
  test` subprocess via an OS-level `Port`. Actually running `mix test` as
  a subprocess from inside this test would mean the whole suite recurses
  into itself -- slow, and pointless for proving *this* task's decision
  logic (which cares only about the captured text and the exit code, not
  about actually re-running 1000+ unrelated tests).

  So instead of calling `run/1` against the real `mix test` subprocess,
  this test calls the real, unmodified `run/1` and only fakes what it
  shells out to: it prepends a temp directory containing a fake
  executable named `mix` onto `PATH`, so `System.find_executable("mix")`
  (used internally by `run/1`) resolves to a tiny shell script that
  prints controlled, canned output and exits with a controlled status --
  standing in for what a real `mix test` subprocess would have printed.
  Every other line of `run/1` (the `Port.open/2` call, the streaming
  `collect/2` loop, the `String.contains?/2` check, the `Mix.raise/1`
  calls, the offending-line extraction) executes exactly as committed;
  nothing about the module under test is mocked, stubbed, or refactored.

  This tests the task at the boundary its current (unrefactored)
  implementation actually allows: the "subsystem" being faked is the
  `mix test` subprocess this task shells out to, not the task's own
  decision logic, which runs for real in every case below.

  ## Fail-then-pass, proven not asserted

  Verified manually before this file was finalized (see the TEST-DESIGNER
  handoff report for the literal command transcript): with
  `lib/mix/tasks/letflow.check.test.ex`'s substring check deliberately
  broken (target substring temporarily changed to a string that cannot
  appear in the fixture output below), `mix test test/mix/tasks/letflow_check_test_test.exs`
  fails -- specifically the "detects and fails" case below stops raising,
  and the assertion on the raised message fails instead. Reverting the
  file back to its committed content makes the same run pass again. That
  is the fail-then-pass proof this file's tests provide: they are not
  tautological (asserting on the implementation's own literals), they
  fail if the detection logic that ships in `run/1` is absent or broken.
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

    :ok
  end

  # Builds a temp dir containing an executable named `mix` that prints
  # `output` to stdout and exits with `exit_code`, then prepends that dir
  # onto PATH so `System.find_executable("mix")` -- exactly what `run/1`
  # calls internally -- resolves to this fake instead of the real `mix`.
  #
  # ISS-0171: this branches on `:os.type/0` because a single POSIX-shaped
  # fake cannot work on Windows, in two independent ways that both had to
  # be fixed together:
  #
  #   1. `System.find_executable/1` resolves a bare name like "mix" against
  #      Windows PATHEXT-style extensions (.exe/.bat/.cmd/...) -- an
  #      extensionless file is never matched, so the POSIX fake was
  #      silently invisible to `run/1` and the REAL `mix` got picked off
  #      PATH instead, recursing into a full nested `mix test`.
  #   2. `PATH` itself uses `;` as the entry separator on Windows, not `:`
  #      -- prepending with `:` produced one PATH entry containing a
  #      literal colon rather than two entries, so even a correctly-named
  #      fake would not have been found either.
  #
  # Verified directly (see docs/issues/ISS-0171.yaml): `Port.open({:spawn_executable,
  # ...})` DOES run a `.bat` file natively on Windows (no `cmd.exe /c`
  # indirection needed) -- the missing piece was purely getting
  # `System.find_executable/1` to resolve to it. The Windows fake writes its
  # canned output to a companion file and has `mix.bat` `type` that file
  # instead of `echo`-ing it inline, so arbitrary content (quotes, parens,
  # colons -- exactly what a real compiler warning line contains) never has
  # to survive batch's own escaping rules.
  defp install_fake_mix(output, exit_code) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "letflow_check_test_fake_mix_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    case :os.type() do
      {:win32, _} ->
        output_path = Path.join(dir, "output.txt")
        File.write!(output_path, output)

        fake_mix_path = Path.join(dir, "mix.bat")
        # cmd.exe's `type` does not reliably resolve a mixed-separator path
        # (Elixir's Path.join always uses "/", but System.tmp_dir!/0 on
        # Windows returns a "\"-separated base) -- reproduced directly:
        # `cmd /c type "C:\...\Temp/dir/output.txt"` fails with "The system
        # cannot find the file specified." Normalize to native "\" first.
        windows_output_path = String.replace(output_path, "/", "\\")

        File.write!(fake_mix_path, """
        @echo off
        type "#{windows_output_path}"
        exit /b #{exit_code}
        """)

        System.put_env("PATH", dir <> ";" <> System.get_env("PATH", ""))

      _ ->
        fake_mix_path = Path.join(dir, "mix")

        File.write!(fake_mix_path, """
        #!/bin/sh
        cat <<'FAKE_MIX_OUTPUT'
        #{output}
        FAKE_MIX_OUTPUT
        exit #{exit_code}
        """)

        File.chmod!(fake_mix_path, 0o755)

        System.put_env("PATH", dir <> ":" <> System.get_env("PATH", ""))
    end

    # Fail fast and legibly (not via a 60s subprocess timeout) if PATH
    # resolution ever again picks the real `mix` instead of this fake --
    # exactly the ISS-0171 regression class this file exists to prevent.
    # Both sides are normalized through Path.expand/1 (and downcased --
    # Windows drive letters/paths are case-insensitive) before comparing,
    # since `dir` and the OS's own resolved path can differ in separator
    # style and drive-letter case despite naming the same location.
    resolved = System.find_executable("mix")
    expected_dir = dir |> Path.expand() |> String.downcase()
    resolved_dir = resolved && resolved |> Path.dirname() |> Path.expand() |> String.downcase()

    unless resolved_dir == expected_dir do
      flunk("""
      install_fake_mix/2 did not take effect: System.find_executable("mix") \
      resolved to #{inspect(resolved)}, expected a file inside #{inspect(dir)}. \
      This would recurse into the REAL `mix test` (ISS-0171) instead of testing \
      against the fake.
      """)
    end

    dir
  end

  describe "mix letflow.check.test detects a recurrence of ISS-0069's own warning class" do
    test "raises and reports the offending line when the target substring is present, even though the underlying subprocess exited 0" do
      offending_line =
        "test/letflow/some_helper_test.exs:42: warning: default values for the optional arguments in unique_idempotency_key/1 are never used, because all calls in this file are made with all arguments"

      install_fake_mix(
        """
        Compiling 3 files (.ex)
        #{offending_line}
        Finished in 0.3 seconds
        5 tests, 0 failures
        """,
        0
      )

      assert_raise Mix.Error, ~r/#{Regex.escape(@target_substring)}/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Letflow.Check.Test.run([])
        end)
      end
    end

    test "passes (no raise) when the subprocess exits 0 and the target substring is absent, even with unrelated warnings present" do
      install_fake_mix(
        """
        Compiling 3 files (.ex)
        warning: ExUnit.Case.register_test/4 is deprecated
        warning: variable "tenant" is unused
        Finished in 0.3 seconds
        5 tests, 0 failures
        """,
        0
      )

      io =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Mix.Tasks.Letflow.Check.Test.run([]) == :ok
        end)

      assert io =~ "OK"
      refute io =~ @target_substring
    end

    test "raises when the subprocess itself exits nonzero, regardless of the substring" do
      install_fake_mix(
        """
        Compiling 3 files (.ex)
        1) test something (SomeTest)
           Assertion failed
        1 test, 1 failure
        """,
        1
      )

      assert_raise Mix.Error, ~r/exited 1/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Letflow.Check.Test.run([])
        end)
      end
    end
  end
end
