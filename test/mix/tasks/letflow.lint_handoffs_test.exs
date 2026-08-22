defmodule Mix.Tasks.Letflow.LintHandoffsTest do
  @moduledoc """
  Regression coverage for ISS-0262 -- `mix letflow.lint_handoffs` discovers
  non-JSON handoff-shaped files (H6) (`lib/mix/tasks/letflow.lint_handoffs.ex`).

  Spec: `test/specs/ISS-0262.md`. Design:
  `lib/letflow/design/iss0262-lint-handoffs-non-json-discovery.md` section 6.
  Run: `WF03-ISS0262-20260822`, WF-03 Step 4.

  ## Why this is the ordinary fail-then-pass case, not the mutant clause

  `handoff_files/0` and `lint_file/2` both existed pre-fix -- this is a change
  to EXISTING functions (`handoff_files/0` becomes `handoff_files/1` with a
  default arg; `lint_file/2` gains a new first branch), not a wholly new
  module. WF-03's "code under test does not exist" clause (mutation required)
  therefore does NOT apply here; the ordinary checkout-pre-fix-commit,
  confirm-red, confirm-green procedure is the right one, per this run's Step-4
  dispatch. See this test-designer's handoff
  (`handoffs/WF03-ISS0262-20260822/step-04-test-designer.json`) `result.summary`
  for the actual quoted fail/pass output from a throwaway `git worktree`.

  ## Fixture

  `test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md` -- a permanent,
  committed, non-JSON, `step`-prefixed file living OUTSIDE `handoffs/`, so it
  is never discovered by production `mix letflow.lint_handoffs` (which only
  ever calls `handoff_files/1` with its default `handoffs/` argument) and
  never needs a `@grandfathered` entry of its own (design section 6.1).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.LintHandoffs

  @fixture_dir "test/fixtures/lint_handoffs/h6"
  @fixture_file "test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md"

  # H4's schema is irrelevant to every assertion in this file: none of the
  # fixtures here carry a `not_agent_attested` key, so `check_h4_not_agent_attested/3`
  # short-circuits on its `nil`/absent clause before ever consulting this
  # value. A stub, not the real HANDOFF_PROTOCOL.md-derived schema, keeps
  # these tests independent of that file's prose.
  @empty_schema %{required: [], optional: [], spent_exception_file: nil}

  # The 10 real, already-grandfathered WF03-ISS0258-20260822 files (design
  # section 3.1), copied verbatim from `@grandfathered` in
  # `lib/mix/tasks/letflow.lint_handoffs.ex` so a drift between the two lists
  # is caught by this suite rather than silently diverging.
  @grandfathered_md_files [
    "handoffs/WF03-ISS0258-20260822/step-01-issue-fixer.md",
    "handoffs/WF03-ISS0258-20260822/step-02-code-designer.md",
    "handoffs/WF03-ISS0258-20260822/step-02b-code-design-validator.md",
    "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev-MISSING-RETRACTED.md",
    "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev.md",
    "handoffs/WF03-ISS0258-20260822/step-03b-security-scope-test.md",
    "handoffs/WF03-ISS0258-20260822/step-03c-reviewer.md",
    "handoffs/WF03-ISS0258-20260822/step-04-test-designer.md",
    "handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md",
    "handoffs/WF03-ISS0258-20260822/step-04c-test-design-validator-regate.md"
  ]

  # ==================================================================
  # H6 -- discovery finds the new fixture (the regression itself)
  # ==================================================================

  describe "handoff_files/1 -- discovers non-JSON handoff-shaped files (H6)" do
    test "F-H6-DISCOVERED -- the .md fixture is found under an isolated fixture root" do
      files = LintHandoffs.handoff_files(@fixture_dir)

      assert @fixture_file in files,
             "expected #{@fixture_file} to be discovered under #{@fixture_dir}, got: #{inspect(files)}"
    end

    test "F-H6-KIND -- handoff_kind/1 classifies the fixture as :non_json" do
      assert LintHandoffs.handoff_kind(@fixture_file) == :non_json
    end

    test "F-H6-DEFAULT-EXCLUDES-FIXTURE -- the real (default) discovery never sees the fixture" do
      # Per design section 6.1: the fixture lives outside handoffs/ precisely
      # so production discovery -- handoff_files/1 called with its default arg,
      # exactly as run/1 calls it -- never touches it and it never needs its
      # own @grandfathered entry.
      refute @fixture_file in LintHandoffs.handoff_files()
    end
  end

  # ==================================================================
  # H6 -- lint_file/2 classifies the fixture as a NEW, gating violation
  # ==================================================================

  describe "lint_file/2 -- H6 fires on the non-JSON fixture (un-grandfathered)" do
    test "F-H6-FIRES-NEW -- an un-grandfathered non-JSON file is a hard_new H6 violation" do
      result = LintHandoffs.lint_file(@fixture_file, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "H6"
      assert violation.path == @fixture_file
      assert violation.grandfathered == false
      assert violation.message =~ ".md"
      assert violation.message =~ "expected .json"

      assert result.hard_grandfathered == []
      assert result.advisory == %{path: @fixture_file, warnings: [], size_info: %{desc_len: 0, summary_len: 0}}
      assert result.parse_error == nil
    end

    test "F-H6-CONTENT-NEVER-READ -- classification is extension-only, not content-based" do
      # The fixture's prose is not JSON at all -- if lint_file/2 ever tried to
      # Jason.decode it, this would blow up with a decode error instead of
      # cleanly producing an H6 violation. Asserting rule: "H6" (not "PARSE")
      # is the discriminator between the two outcomes design section 4.2
      # states must never be merged.
      result = LintHandoffs.lint_file(@fixture_file, @empty_schema)
      assert [%{rule: "H6"}] = result.hard_new
    end
  end

  # ==================================================================
  # Existing .json handoff behavior (H1-H5) is unaffected by this fix
  # ==================================================================

  describe "existing .json handoff behavior (H1-H5) is unaffected" do
    setup do
      dir = Path.join(System.tmp_dir!(), "letflow-lint-handoffs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "F-JSON-KIND -- handoff_kind/1 classifies a .json path as :json" do
      assert LintHandoffs.handoff_kind("handoffs/some-run/step-01-agent.json") == :json
    end

    test "F-JSON-CLEAN-PASSES -- a well-formed .json handoff produces zero hard violations",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")

      File.write!(path, ~s({
        "status": "COMPLETED",
        "started_at": "2026-08-22T07:00:00Z",
        "completed_at": "2026-08-22T07:05:00Z",
        "context": {},
        "task": {},
        "result": {}
      }))

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert result.hard_new == []
      assert result.hard_grandfathered == []
      assert result.parse_error == nil
    end

    test "F-JSON-H1-STILL-FIRES -- an illegal status on a .json file still gates (unchanged)",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, ~s({"status": "BOGUS"}))

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "H1"
    end

    test "F-JSON-PARSE-STILL-FIRES -- broken JSON still reports PARSE, never H6",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, "{not valid json")

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "PARSE"
    end

    test "F-JSON-REAL-GRANDFATHERED-UNCHANGED -- a real pre-existing grandfathered .json entry still classifies as grandfathered, not new" do
      # handoffs/WF02-REQ023-20260816/step-06-doc-updater.json is one of the 6
      # pre-ISS-0190 H3 entries already in @grandfathered, untouched by this
      # fix per design section 5's backward-compatibility table.
      path = "handoffs/WF02-REQ023-20260816/step-06-doc-updater.json"
      result = LintHandoffs.lint_file(path, @empty_schema)

      assert Enum.any?(result.hard_grandfathered, &(&1.rule == "H3"))
      refute Enum.any?(result.hard_new, &(&1.rule == "H3"))
    end

    test "F-DEFAULT-DISCOVERY-STILL-FINDS-REAL-JSON -- the real handoffs/ corpus is still discovered" do
      # Both pre-fix naming styles (design section 0.1/1.1) must still be
      # found by the broadened glob -- this is the exact regression risk the
      # design flags: a naive `step-*.*` pattern would have dropped the
      # non-hyphenated style.
      files = LintHandoffs.handoff_files()

      assert "handoffs/WF02-REQ019-20260816/step00-git-setup.json" in files
      assert "handoffs/WF02-REQ023-20260816/step-06-doc-updater.json" in files
    end
  end

  # ==================================================================
  # The 10 grandfathered WF03-ISS0258-20260822 .md files
  # ==================================================================

  describe "the 10 grandfathered WF03-ISS0258-20260822 .md files" do
    test "F-GRANDFATHERED-COUNT -- exactly 10 real .md files exist at these exact paths" do
      assert length(@grandfathered_md_files) == 10
      assert Enum.all?(@grandfathered_md_files, &File.regular?/1)
    end

    test "F-GRANDFATHERED-DISCOVERED -- default discovery finds all 10" do
      files = LintHandoffs.handoff_files()

      for path <- @grandfathered_md_files do
        assert path in files, "expected #{path} to be discovered by handoff_files/1"
      end
    end

    test "F-GRANDFATHERED-NOT-NEW -- each classifies as hard_grandfathered H6, never hard_new" do
      for path <- @grandfathered_md_files do
        result = LintHandoffs.lint_file(path, @empty_schema)

        assert [violation] = result.hard_grandfathered,
               "#{path}: expected exactly one grandfathered violation, got #{inspect(result.hard_grandfathered)}"

        assert violation.rule == "H6"
        assert violation.grandfathered == true
        assert result.hard_new == [],
               "#{path}: a grandfathered H6 file must never contribute to hard_new (it must not fail the build)"
      end
    end
  end

  # ==================================================================
  # run/1 -- the exit code stays green on the real corpus post-fix
  # ==================================================================

  describe "run/1 -- the real corpus stays green" do
    test "T-TASK-GREEN -- mix letflow.lint_handoffs does not raise against the real handoffs/ tree" do
      import ExUnit.CaptureIO, only: [capture_io: 1]

      output =
        capture_io(fn ->
          assert LintHandoffs.run([]) == :ok
        end)

      assert output =~ "letflow.lint_handoffs: OK"
    end
  end
end
