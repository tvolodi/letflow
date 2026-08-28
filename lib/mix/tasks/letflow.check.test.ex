defmodule Mix.Tasks.Letflow.Check.Test do
  @shortdoc "Runs the test suite, gated only on ISS-0069's own warning class (unused defaults)"

  @moduledoc """
  ISS-0069 Part 2 (revised): the `test` step used by `mix letflow.check`.

  Shells out to `mix test` as a subprocess -- which, invoked this way from
  the command line, already resolves through this project's own `test`
  alias (`ecto.create --quiet`, `ecto.migrate --quiet`, `test`) exactly as
  a developer's plain `mix test` would -- streaming its combined
  stdout+stderr live to the invoking terminal so nothing a developer or CI
  reader would normally see is hidden or buffered away, while also
  capturing that output for the check below.

  ISS-0352: after the default (`:keycloak`/`:wasm_hang`-excluded) run above
  passes, this task runs a SECOND subprocess, `mix test --only wasm_hang`,
  in its own fresh BEAM node. `:wasm_hang` tags a handful of tests in
  `test/letflow/engine/wasm/` that deliberately, genuinely hang a real
  `wasmex` NIF call to prove REQ-170's own live-verified finding that no
  BEAM-side mechanism can reclaim that thread -- it permanently occupies one
  slot of `wasmex`'s shared, node-global native worker pool for the rest of
  the OS process. Run in the same process as every other WASM NIF test, this
  starved unrelated tests once the pool was exhausted (PR #691, then worse on
  PR #692 -- 18 cascading `ExUnit.TimeoutError`s). Running them as their own
  short-lived subprocess means their leaks die with that process instead of
  touching anything else's pool. Both subprocess runs must exit `0` for this
  task to pass.

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

    * Exits `0` only if the subprocess itself exited `0` (no real test
      failures/errors) **and** the target substring is absent from the
      captured output.
    * Exits `1` if the subprocess exited nonzero, regardless of the
      substring check.
    * Exits `1` if the subprocess exited `0` but the target substring is
      present anywhere in the captured output, printing the offending
      line(s) so the failure is immediately actionable.

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

  @impl Mix.Task
  def run(_args) do
    {output, exit_code} = stream_and_capture("mix", ["test"])

    cond do
      exit_code != 0 ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- underlying `mix test` run exited " <>
            "#{exit_code} (real test failure/error)."
        )

      String.contains?(output, @target_substring) ->
        offending_lines =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, @target_substring))
          |> Enum.join("\n")

        Mix.raise(
          "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found " <>
            "(ISS-0069's own class recurring):\n#{offending_lines}"
        )

      true ->
        Mix.shell().info("mix letflow.check.test: OK -- no test failures, no ISS-0069 warnings.")
        run_wasm_hang_tests()
    end
  end

  # ISS-0352: run the deliberately-hanging :wasm_hang tests in their own
  # subprocess, isolated from the main run above -- see moduledoc.
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
