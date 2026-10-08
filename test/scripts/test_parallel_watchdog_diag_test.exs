defmodule Letflow.Scripts.TestParallelWatchdogDiagTest do
  @moduledoc """
  Q-1037 / GH #2364: when a partition watchdog of `scripts/test_parallel.sh` fires, the
  job log must say where each partition was. Just before `kill -TERM`, the watchdog calls
  `test_parallel_watchdog_diag`, which prints

    * per partition, every line prefixed `test_parallel: DIAG partition N: `: the last 40
      lines of THAT partition's log (each cut to 300 columns), `approx tests finished: K`
      (K = number of characters on log lines made only of `.`, `F`, `*`) and
      `running for Xs of TEST_PARALLEL_PARTITION_TIMEOUT_S=Ys`;
    * once per run (atomic `mkdir diag-host.lock`), a host block prefixed
      `test_parallel: DIAG host: ` (df header, nproc, ...), however many watchdogs fire.

  The existing `WARNING ... sending TERM` line is unchanged, and nothing at all is printed
  on a run where no watchdog fires.

  Drives the REAL script under bash with stub `mix`/`psql` first on `PATH`, through
  `bash -c "set -o pipefail; bash script 2>&1 | cat"` (same harness as
  `test_parallel_watchdog_orphan_test.exs`). Needs a real `bash`; on Windows set
  `UAT_PF_BASH` (or `TEST_PARALLEL_BASH`). `async: false`: process trees, timing-sensitive.

  Cases:

    1. three hung partitions, each with partition-specific log text: each partition's DIAG
       block carries its OWN log tail (no swapped numbers), the exact K, the elapsed/timeout
       line, exactly one host block, DIAG after the WARNING line, prompt non-zero exit
    2. normal quick run: no `DIAG` anywhere in the output
    3. huge partition log (200k lines, many > 300 chars) then hang: diagnostics finish in
       bounded time and every DIAG partition line respects the 300-column cap
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @timeout_s 2
  @prompt_ms 40_000
  # `sed "s/^/${pfx}  /"` indents each tail line by two spaces after the prefix
  @indent 2

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Stub `mix test`, env-driven (STUB_MODE):
  #   pass   prints a Result line, exit 0
  #   marked every partition P writes: a dots line `.....F..` (line 1, i.e. OUTSIDE the
  #          last-40 window), 60 filler lines `P<P>-FILL-001..060`, a dots line of 3*P dots,
  #          decoys that must NOT count towards K, `P<P>-LAST`, then hangs (sleep 600)
  #   huge   200k lines, every 7th one 400 columns wide, the last 40 lines all 400 wide,
  #          one `....` line, then hangs
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    case "$1" in
      test) ;;
      *) exit 0 ;;
    esac
    part="${MIX_TEST_PARTITION:-0}"
    case "${STUB_MODE:-pass}" in
      pass)
        echo "Result: 1 passed"
        exit 0 ;;
      marked)
        echo ".....F.."
        i=1
        while [ "$i" -le 60 ]; do
          printf 'P%s-FILL-%03d\\n' "$part" "$i"
          i=$((i + 1))
        done
        d=""
        j=0
        while [ "$j" -lt $((3 * part)) ]; do d="$d."; j=$((j + 1)); done
        echo "$d"
        echo "  ..... not a dots-only line P$part"
        echo ".....F.. 12 tests so far P$part"
        echo "P$part-LAST"
        sleep 600 ;;
      huge)
        awk -v p="$part" 'BEGIN {
          long = sprintf("%400s", ""); gsub(/ /, "L", long)
          for (i = 1; i <= 200000; i++) {
            if (i % 7 == 0 || i > 199960) print "P" p "-" i "-" long
            else print "P" p "-" i
          }
          print "...."
        }'
        sleep 600 ;;
    esac
    """)

    File.write!(Path.join(bin, "psql"), "#!/usr/bin/env bash\nexit 1\n")
    File.chmod!(mix, 0o755)
    File.chmod!(Path.join(bin, "psql"), 0o755)
    bin
  end

  # Returns {exit_status | :timeout, output, elapsed_ms}.
  defp run_script(tmp, extra_env, limit_ms) do
    bin = write_stubs(tmp)
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "_build/test"))
    File.write!(Path.join(work, "_build/test/marker"), "x")
    tmpdir = Path.join(tmp, "tp_tmp")
    File.mkdir_p!(tmpdir)

    launcher =
      ~S{d=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1"); PATH="$d:$PATH"; export PATH; shift; set -o pipefail; bash "$@" 2>&1 | cat}

    env =
      [
        {"TEST_PARALLEL_N", "3"},
        {"TEST_POOL_SIZE", "6"},
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", Integer.to_string(@timeout_s)},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TMPDIR", tmpdir},
        {"LETFLOW_DB_PORT", "1"}
      ] ++ extra_env

    port =
      Port.open({:spawn_executable, bash()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, work},
        {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)},
        {:args, ["-c", launcher, "launcher", bin, script()]}
      ])

    started = System.monotonic_time(:millisecond)
    result = collect(port, [], started, limit_ms)
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, status, out} ->
        {status, out, elapsed}

      {:timeout, out} ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        {:timeout, out, elapsed}
    end
  end

  defp collect(port, acc, started, limit_ms) do
    remaining = limit_ms - (System.monotonic_time(:millisecond) - started)

    receive do
      {^port, {:data, chunk}} -> collect(port, [acc, chunk], started, limit_ms)
      {^port, {:exit_status, status}} -> {:ok, status, IO.iodata_to_binary(acc)}
    after
      max(remaining, 0) -> {:timeout, IO.iodata_to_binary(acc)}
    end
  end

  defp lines(out), do: String.split(out, ~r/\r?\n/)

  defp pfx(n), do: "test_parallel: DIAG partition #{n}: "

  defp partition_diag_lines(out, n), do: Enum.filter(lines(out), &String.starts_with?(&1, pfx(n)))

  test "hung partitions: each DIAG block has its own log tail, exact K, one host block",
       %{tmp_dir: tmp} do
    {status, out, elapsed} = run_script(tmp, [{"STUB_MODE", "marked"}], @prompt_ms)

    IO.puts("[watchdog-diag] marked case returned in #{elapsed} ms (timeout #{@timeout_s} s)")
    IO.puts("[watchdog-diag] SAMPLE OUTPUT:\n#{out}")

    refute status == :timeout, "script did not return within #{@prompt_ms} ms:\n#{out}"
    assert status == 1, "expected non-zero exit, got #{inspect(status)}:\n#{out}"
    assert elapsed < @prompt_ms

    all = lines(out)

    for n <- 1..3 do
      mine = partition_diag_lines(out, n)
      assert mine != [], "no DIAG lines for partition #{n}:\n#{out}"
      body = Enum.join(mine, "\n")

      # last 40 of 64 lines: FILL-025..FILL-060 are in, FILL-024 and earlier are out
      assert body =~ "P#{n}-FILL-025"
      assert body =~ "P#{n}-FILL-060"
      assert body =~ "P#{n}-LAST"
      refute body =~ "P#{n}-FILL-024"
      refute body =~ "P#{n}-FILL-001"

      # no other partition's text under this partition's number
      for other <- 1..3, other != n do
        refute body =~ "P#{other}-", "partition #{n} DIAG block contains partition #{other} text"
      end

      # K: 8 (line 1, outside the tail window) + 3n; the decoys must not count
      assert "#{pfx(n)}approx tests finished: #{8 + 3 * n}" in mine,
             "wrong K for partition #{n}: #{inspect(Enum.filter(mine, &(&1 =~ "approx")))}"

      running = Enum.find(mine, &(&1 =~ "running for"))
      assert running, "no 'running for' line for partition #{n}"

      assert [_, secs] =
               Regex.run(
                 ~r/running for (\d+)s of TEST_PARALLEL_PARTITION_TIMEOUT_S=#{@timeout_s}s$/,
                 running
               )

      assert String.to_integer(secs) in @timeout_s..(@timeout_s + 10)

      # ordering: the unchanged WARNING line precedes this partition's first DIAG line
      warning =
        "WARNING partition #{n} exceeded TEST_PARALLEL_PARTITION_TIMEOUT_S=#{@timeout_s}s" <>
          " -- sending TERM to its process group"

      warn_idx = Enum.find_index(all, &(&1 =~ warning))
      diag_idx = Enum.find_index(all, &String.starts_with?(&1, pfx(n)))
      assert warn_idx, "WARNING line for partition #{n} missing or changed:\n#{out}"
      assert warn_idx < diag_idx
    end

    # exactly one host block even though three watchdogs fire together
    host = Enum.filter(all, &String.starts_with?(&1, "test_parallel: DIAG host: "))
    assert host != [], "no host block:\n#{out}"
    assert Enum.count(host, &(&1 =~ ~r/Filesystem/)) == 1, Enum.join(host, "\n")
    assert Enum.count(host, &(&1 =~ ~r/Mounted on/)) == 1, Enum.join(host, "\n")
    assert Enum.count(host, &(&1 =~ ~r/DIAG host: \d+\s*$/)) <= 1, Enum.join(host, "\n")
  end

  test "normal quick run prints no DIAG lines", %{tmp_dir: tmp} do
    {status, out, elapsed} = run_script(tmp, [{"STUB_MODE", "pass"}], @prompt_ms)
    IO.puts("[watchdog-diag] quick case returned in #{elapsed} ms")

    assert status == 0, out
    refute out =~ "test_parallel: DIAG", out
    refute out =~ "WARNING", out
  end

  test "huge partition log: diagnostics stay bounded and respect the 300-column cap",
       %{tmp_dir: tmp} do
    {status, out, elapsed} = run_script(tmp, [{"STUB_MODE", "huge"}], @prompt_ms)

    IO.puts("[watchdog-diag] huge case returned in #{elapsed} ms (timeout #{@timeout_s} s)")

    refute status == :timeout, "script did not return within #{@prompt_ms} ms"
    assert status == 1, out
    assert elapsed < (@timeout_s + 15) * 1000, "diagnostics took too long: #{elapsed} ms"

    for n <- 1..3 do
      mine = partition_diag_lines(out, n)
      assert mine != [], "no DIAG partition lines for partition #{n}"
      cap = String.length(pfx(n)) + @indent + 300

      # +1: a possible trailing carriage return from the Windows pipe is not a column
      for l <- mine do
        assert String.length(l) <= cap + 1, "DIAG line wider than cap (#{String.length(l)}): #{l}"
      end

      # the cap really cut something: a 400-wide tail line came out at exactly the cap
      assert Enum.any?(mine, &(String.length(&1) in cap..(cap + 1))),
             "no DIAG line was cut to the cap for partition #{n}"

      assert Enum.any?(mine, &(&1 =~ "P#{n}-200000-"))
      assert "#{pfx(n)}approx tests finished: 4" in mine
    end
  end
end
