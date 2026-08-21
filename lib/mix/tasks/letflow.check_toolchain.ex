defmodule Mix.Tasks.Letflow.CheckToolchain do
  @shortdoc "Warns (never fails) when the running Elixir/OTP differs from .tool-versions"

  @moduledoc """
  Advisory toolchain-drift check. Compares the Elixir and OTP versions this
  VM is actually running against the versions pinned in the repo-root
  `.tool-versions`, and prints a warning when they differ.

  Implements ISS-0106's Part A, specified in
  `lib/letflow/design/iss0106-toolchain-pin-and-format-fix.md` and authorised
  by `docs/migration/decisions/0005-pin-formatting-toolchain.md` (see that
  record's amendment dated `2026-08-21T01:25:50Z`, which supersedes the
  earlier version target in the same file).

  **This task is advisory and cannot fail a build.** `run/1` returns `:ok` on
  every path, including every failure path. Its only effect is text.

  ## The four load-bearing properties, and the mechanism of each

  ### (i) It runs first among the `letflow.check` alias's own steps

  The mechanism is alias data, not logic in this module: this task is the
  literal first element of the `letflow.check` alias list in `mix.exs`, and
  Mix executes an alias's steps in list order. There is no ordering logic
  inside this task, because ordering can only be enforced where the order is
  written down.

  Deliberately stated as *first among the alias's own steps* rather than
  "nothing can print before it": because this module lives in
  `lib/mix/tasks/`, Mix must load it before it can run it, which forces a
  project compile ahead of everything — so compiler output can and does
  precede this task's output on a cold build.

  ### (ii) It prints on drift regardless of the other checks, and cannot be silenced

  Three structural facts, not promises about behaviour:

    * *Independent of the later steps.* This task runs before them, never
      invokes them, never inspects their results, and returns before they
      start. Whether it prints depends only on `System.version/0`,
      `:erlang.system_info(:otp_release)`, and the contents of
      `.tool-versions`.

    * *Not silenceable through Mix.* Warning output goes straight to
      `:stderr` via `IO.puts(:stderr, ...)`. It deliberately does **not** go
      through Mix's replaceable shell abstraction, which a caller can swap
      out globally and which honours `--quiet` / `MIX_QUIET`. Writing to
      `:stderr` also means the warning survives a caller that pipes stdout
      into `grep` or `tee`, which is how gate output is commonly read here.

    * *There is no suppression surface to use.* This task reads no
      environment variable and parses no command-line switch. `run/1` accepts
      an argument list and ignores it entirely — there is no option parsing
      of any kind. Non-suppressibility is therefore an absence of mechanism.
      **A later change must not add one.**

  ### (iii) It never changes any other check's exit code

  A Mix alias aborts at the first step that aborts; a step's return value is
  otherwise ignored. So the only way this task could move the run's exit code
  is by aborting the VM or the alias, and it has no way to do either:

    * No path here contains a build-aborting construct of any kind — no `Mix`
      abort, no VM halt or stop, no exception-generating call, no non-local
      return. Their absence is checkable by grep over this file, and their
      presence would be a defect regardless of the surrounding logic.
    * Every external call on the path uses the non-aborting form:
      `File.cwd/0` rather than `File.cwd!/0`, `File.read/1` rather than
      `File.read!/1`, and plain string splitting rather than `Version` or
      integer parsing.
    * The whole body of `run/1` is additionally guarded (see `run/1`), so an
      unforeseen failure of any kind is caught, reported as F8 below, and
      turned into `:ok`. That guard covers both the exception case and the
      non-local-return/abnormal-termination case, so the guarantee does not
      depend on having anticipated every error.

  It cannot make a failing build look passing either: it does not wrap,
  invoke, retry, or intercept any other alias step, and never touches another
  task's status. Its power is strictly to *say more*.

  ### (iv) It degrades gracefully

  The parse is total: every readable byte sequence maps to some
  `{elixir_pin, erlang_pin}` pair, with `nil` standing for
  absent-or-malformed. There is no "parse error" outcome to fall off. The
  only genuinely failing operations — obtaining the working directory and
  reading the file — use non-aborting APIs whose `{:error, _}` results are
  named failure modes (F1, F6, F7) with their own messages. Each of these
  warns and returns `:ok`.

  ## Comparison rules, and the OTP asymmetry

  **Elixir.** The pinned token has the shape `<version>[-otp-<major>]`, e.g.
  `1.20.3-otp-29`. The token is split on the literal `"-otp-"`; part one is
  the expected Elixir version and the `-otp-NN` suffix is parsed off and
  **discarded**. The suffix names the OTP major that *asdf's Elixir build*
  was compiled against — a property of how the artefact was built, not a
  statement about the runtime — and the `erlang` line is the authoritative
  OTP expectation. Comparing both would produce two independent OTP verdicts
  that can disagree, with no rule for which one wins. The expected version is
  then compared to `System.version/0` by exact binary equality; that function
  returns a bare `MAJOR.MINOR.PATCH` string, so string equality is correct
  and no version parsing is needed.

  **OTP — the asymmetry.** `.tool-versions` pins a *full* Erlang version
  (`29.0.5`) because asdf requires one, but
  `:erlang.system_info(:otp_release)` returns only the **major** release, as
  a charlist (`~c"29"`). A naive equality check between `"29.0.5"` and `"29"`
  would report drift on a correctly-pinned host, permanently, on every run.
  Because property (ii) makes this warning unsuppressible, such a false
  positive would train every reader to ignore the one message the whole
  mechanism consists of. So: the running value is converted with
  `List.to_string/1`, the expected value keeps only the substring before the
  first `.`, and those two are compared by exact binary equality. The minor
  and patch of the `erlang` pin are shown in the warning but never compared.

  **Accepted, documented limitation:** a host running OTP 29.0.1 against a
  `29.0.5` pin is **not** warned, because `otp_release` cannot distinguish
  them. This is deliberate, not an omission. The full running OTP version is
  only obtainable by reading `OTP_VERSION` from the Erlang installation on
  disk, which is absent in stripped/embedded installs and would reintroduce a
  filesystem failure path into a task that must never fail; and decision 0005
  names `:erlang.system_info(:otp_release)` as the API to compare against,
  which is binding. Major-release granularity is also what actually matters
  for the failure this record exists to prevent — formatter and type-checker
  behaviour tracks the Elixir version and the OTP major, not the OTP patch.
  **A later run must not "fix" this by tightening the comparison**, which
  would only produce a permanent false mismatch.

  ## Failure modes

  Every one of these warns, continues, and returns `:ok`. All warning output
  goes to `:stderr` in the same block frame; where no comparison could be
  made at all, the block title reads `TOOLCHAIN PIN NOT CHECKED` instead of
  `TOOLCHAIN OFF PIN`.

    * **F1** — `.tool-versions` missing.
    * **F2** — present but empty, or only blank/comment lines.
    * **F3** — no `elixir` line; the Elixir row reads `<-- NOT PINNED` and
      the block is emitted even if the OTP comparison matched.
    * **F4** — no `erlang` line; symmetric to F3.
    * **F5** — a recognised tool name with no version token; that tool is
      treated as unpinned (F3/F4 row shape) and the raw line is quoted.
    * **F6** — present but unreadable for any other reason.
    * **F7** — working directory unavailable.
    * **F8** — anything unforeseen, caught by `run/1`'s outer guard.

  A version string that "does not parse" is **not** a failure mode, by
  construction: both comparisons are exact string equality on strings derived
  by splitting, so `elixir abc` is an ordinary mismatch rather than an error.
  Removing the parse step is what removes the parse-failure path.

  ## Usage

      mix letflow.check_toolchain

  Arguments are accepted and ignored. Normally invoked as the first step of
  `mix letflow.check`.
  """

  use Mix.Task

  @pin_file ".tool-versions"
  @record "docs/migration/decisions/0005-pin-formatting-toolchain.md"
  @rule String.duplicate("=", 72)
  @recognised_tools ["elixir", "erlang"]

  @doc """
  Runs the check. Always returns `:ok`.

  The body is wrapped in a guard covering both `rescue` and `catch`, so that
  no failure of any kind on this path can abort the alias this task runs
  from. `rescue` alone would miss a non-local return or an abnormal
  termination; the practical risk of either is nil, but the guard is what
  makes "never fails the build" a property of the design rather than a
  consequence of having thought of every error.
  """
  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    try do
      check()
    rescue
      error -> internal_error(inspect(error))
    catch
      kind, value -> internal_error(inspect({kind, value}))
    end
  end

  # -- top-level flow ---------------------------------------------------

  @spec check() :: :ok
  defp check do
    running_elixir = System.version()
    running_otp = List.to_string(:erlang.system_info(:otp_release))

    case File.cwd() do
      {:error, reason} ->
        # F7
        not_checked(
          [
            "  Could not determine the project directory (#{inspect(reason)}) -- " <>
              "cannot check the toolchain pin."
          ],
          running_elixir,
          running_otp
        )

      {:ok, cwd} ->
        cwd |> Path.join(@pin_file) |> read_and_report(running_elixir, running_otp)
    end
  end

  @spec read_and_report(String.t(), String.t(), String.t()) :: :ok
  defp read_and_report(path, running_elixir, running_otp) do
    case File.read(path) do
      {:ok, contents} ->
        contents |> parse() |> report(running_elixir, running_otp)

      {:error, :enoent} ->
        # F1
        not_checked(
          ["  #{@pin_file} not found at #{path} -- cannot check the toolchain pin."],
          running_elixir,
          running_otp
        )

      {:error, reason} ->
        # F6
        not_checked(
          [
            "  Could not read #{@pin_file} (#{inspect(reason)}) -- " <>
              "cannot check the toolchain pin."
          ],
          running_elixir,
          running_otp
        )
    end
  end

  # -- parsing ----------------------------------------------------------

  # Total by construction: every byte sequence yields a
  # {elixir_pin, erlang_pin, malformed_lines} triple, with nil for
  # absent-or-malformed. No step below can fail.
  @spec parse(String.t()) :: {String.t() | nil, String.t() | nil, [String.t()]}
  defp parse(contents) do
    {pins, malformed} =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reduce({%{}, []}, &parse_line/2)

    {Map.get(pins, "elixir"), Map.get(pins, "erlang"), Enum.reverse(malformed)}
  end

  @spec parse_line(String.t(), {map(), [String.t()]}) :: {map(), [String.t()]}
  defp parse_line(line, {pins, malformed} = acc) do
    tokens =
      line
      |> String.split("#", parts: 2)
      |> hd()
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case tokens do
      # First occurrence of a recognised tool wins, matching asdf's own
      # resolution; later ones and every unrecognised tool are ignored
      # silently. Tokens after the version (asdf's fallback versions) are
      # ignored too.
      [tool | rest] when tool in @recognised_tools ->
        if Map.has_key?(pins, tool) do
          acc
        else
          case rest do
            [version | _] -> {Map.put(pins, tool, version), malformed}
            # F5: recognised tool name, no version token.
            [] -> {Map.put(pins, tool, nil), [line | malformed]}
          end
        end

      _ ->
        acc
    end
  end

  # -- comparison -------------------------------------------------------

  @spec report({String.t() | nil, String.t() | nil, [String.t()]}, String.t(), String.t()) :: :ok
  defp report({nil, nil, malformed}, running_elixir, running_otp) do
    # F2 (and the both-malformed case of F5)
    not_checked(
      ["  #{@pin_file} contains no elixir pin and no erlang pin." | malformed_lines(malformed)],
      running_elixir,
      running_otp
    )
  end

  defp report({elixir_pin, erlang_pin, malformed}, running_elixir, running_otp) do
    expected_elixir = expected_elixir(elixir_pin)
    expected_otp = expected_otp_major(erlang_pin)

    if expected_elixir == running_elixir and expected_otp == running_otp do
      IO.puts(
        "letflow.check_toolchain: OK -- Elixir #{running_elixir} / OTP #{running_otp} " <>
          "matches #{@pin_file}."
      )

      :ok
    else
      # The block always carries BOTH rows, so a reader never has to infer
      # which comparison was silent.
      warn_block("TOOLCHAIN OFF PIN", [
        elixir_row(expected_elixir, running_elixir),
        otp_row(expected_otp, erlang_pin, running_otp) | malformed_lines(malformed)
      ])
    end
  end

  # The `-otp-NN` suffix is parsed off and discarded -- it is never compared
  # to anything. See the moduledoc.
  @spec expected_elixir(String.t() | nil) :: String.t() | nil
  defp expected_elixir(nil), do: nil

  defp expected_elixir(token) do
    token |> String.split("-otp-", parts: 2) |> hd()
  end

  # Only the major component of the erlang pin participates, because
  # :erlang.system_info(:otp_release) can report nothing finer.
  @spec expected_otp_major(String.t() | nil) :: String.t() | nil
  defp expected_otp_major(nil), do: nil

  defp expected_otp_major(token) do
    token |> String.split(".", parts: 2) |> hd()
  end

  # -- output -----------------------------------------------------------

  @spec elixir_row(String.t() | nil, String.t()) :: String.t()
  defp elixir_row(nil, running) do
    "  Elixir  expected (no elixir pin in #{@pin_file})   running #{running}   <-- NOT PINNED"
  end

  defp elixir_row(expected, running) do
    "  Elixir  expected #{expected}   running #{running}   #{verdict(expected == running)}"
  end

  @spec otp_row(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  defp otp_row(nil, _token, running) do
    "  OTP     expected (no erlang pin in #{@pin_file})   running #{running}   <-- NOT PINNED"
  end

  defp otp_row(expected, token, running) do
    "  OTP     expected #{expected} (from erlang #{token})   running #{running}   " <>
      verdict(expected == running)
  end

  @spec verdict(boolean()) :: String.t()
  defp verdict(true), do: "matches"
  defp verdict(false), do: "<-- MISMATCH"

  @spec malformed_lines([String.t()]) :: [String.t()]
  defp malformed_lines(lines) do
    Enum.map(lines, &"  Malformed line in #{@pin_file}, ignored: #{&1}")
  end

  @spec not_checked([String.t()], String.t(), String.t()) :: :ok
  defp not_checked(body_lines, running_elixir, running_otp) do
    warn_block(
      "TOOLCHAIN PIN NOT CHECKED",
      body_lines ++ ["  Running: Elixir #{running_elixir} / OTP #{running_otp}"]
    )
  end

  @spec internal_error(String.t()) :: :ok
  defp internal_error(inspected) do
    # F8. Reached only from run/1's outer guard, so it must not itself depend
    # on anything that could fail -- hence no version lookups here.
    warn_block("TOOLCHAIN PIN NOT CHECKED", [
      "  Internal error in letflow.check_toolchain (#{inspected}) -- check skipped.",
      "  This never fails the build."
    ])
  end

  @spec warn_block(String.t(), [String.t()]) :: :ok
  defp warn_block(title, body_lines) do
    lines =
      [@rule, "letflow.check_toolchain: #{title}"] ++
        body_lines ++
        [
          "  Pin file: #{@pin_file}",
          "  Record:   #{@record}",
          "  This is a WARNING. It does NOT fail the build and never changes an",
          "  exit code. Formatting or compiler output produced by an off-pin",
          "  toolchain may disagree with the pin.",
          @rule
        ]

    Enum.each(lines, &IO.puts(:stderr, &1))
  end
end
