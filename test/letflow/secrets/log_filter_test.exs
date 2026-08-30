defmodule Letflow.Secrets.LogFilterTest do
  @moduledoc """
  Tests for REQ-190 AC7's second half -- proving `Letflow.Secrets.LogFilter` (the real
  `:logger` primary filter `Letflow.Application.start/2` registers) actually intercepts
  a real `Logger` call and redacts sensitive-keyed metadata before it reaches captured
  output, not just that the underlying pure function
  (`Letflow.Secrets.Redaction.redact_map/1`, covered by `redaction_test.exs`) is
  correct in isolation. See `test/specs/REQ-190.md`.

  `async: false`: `:logger.add_primary_filter/2` is a node-global registration this
  test relies on already being in place (via `Letflow.Application.start/2`, which ran
  once at suite boot) -- no per-test mutation of the filter itself, but log capture
  ordering is safer serialized alongside every other test file that touches `Logger`
  configuration in this codebase.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  # `capture_log/2`'s default formatter does not print metadata at all unless told
  # to -- this project sets no `config :logger` metadata anywhere (confirmed:
  # `grep -rn "config :logger" config/*.exs` finds nothing), so `metadata: :all` is
  # passed explicitly here to make the (possibly redacted) metadata visible in the
  # captured string. This is a test-visibility mechanism only; it does not change
  # which filter runs or what it redacts -- `Letflow.Secrets.LogFilter.filter/2`
  # (registered once, node-wide, by `Letflow.Application.start/2`) has already run
  # on `log_event.meta` before the formatter ever sees it.
  test "a Logger call carrying a value under a sensitive key emits [REDACTED] in captured output, not the plaintext" do
    log =
      capture_log([metadata: :all], fn ->
        Logger.info("webhook signing key resolved", secret: "sh-do-not-leak-me")
      end)

    assert log =~ "[REDACTED]"
    refute log =~ "sh-do-not-leak-me"
  end

  test "a Logger call with no sensitive-keyed metadata is unaffected" do
    log =
      capture_log([metadata: :all], fn ->
        Logger.info("ordinary log line", request_id: "req-123")
      end)

    assert log =~ "ordinary log line"
    assert log =~ "req-123"
    refute log =~ "[REDACTED]"
  end
end
