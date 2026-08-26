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

  ## H6 rework (ISS-0262 Step 8 change-approach, rework_count 2)

  H6 no longer uses per-file `@grandfathered` entries at all -- it is now
  governed by the commit-boundary rule in
  `lib/letflow/design/iss0262-h6-floor-commit-addendum.md`
  (`pre_floor_file?/2`, `h6_floor_commit/0`). The tests below that used to
  assert "these exact 12 paths are grandfathered by list membership" are
  rewritten to assert the equivalent property against real git history
  instead: a file whose content predates a given floor commit is
  `hard_grandfathered`; a file introduced after it is `hard_new`. See design
  addendum §6 for the fixture guidance this section follows.
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

  # These 10 real WF03-ISS0258-20260822 files are no longer list-grandfathered
  # (the 12 `{"H6", path}` `@grandfathered` entries were removed by the
  # ISS-0262 H6 floor-commit addendum) -- they are used here purely as real,
  # pre-existing fixtures to prove the commit-boundary rule reproduces the
  # same "grandfathered, not new" outcome the deleted list used to provide.
  # See design addendum §6 item 4.
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

      assert result.advisory == %{
               path: @fixture_file,
               warnings: [],
               size_info: %{desc_len: 0, summary_len: 0}
             }

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
      dir =
        Path.join(
          System.tmp_dir!(),
          "letflow-lint-handoffs-#{System.unique_integer([:positive])}"
        )

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

    test "F-PARSE-ADVISORY-SHAPE (ISS-0347 regression) -- parse-error advisory is the same map shape every other branch uses, so print_advisory/1's dot-access never raises BadMapError",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, "{not valid json")

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert result.parse_error != nil
      assert [violation] = result.hard_new
      assert violation.rule == "PARSE"

      # This reproduces exactly the access pattern print_advisory/1 performs
      # on every result (`r.advisory.warnings`, then
      # `size_info.desc_len`/`summary_len` when building the H-SIZE-3 report).
      # Pre-fix, lint_file/2's {:error, reason} branch set `advisory: []` --
      # a bare list -- so this same dot-access raised `%BadMapError{term: []}`
      # and crashed the whole `mix letflow.lint_handoffs` run on the first
      # handoff-shaped file with invalid JSON. Post-fix it is the same
      # %{path:, warnings:, size_info:} map every other branch produces.
      # Fail-then-pass evidence: test/specs/ISS-0347.md.
      assert result.advisory.warnings == []
      assert result.advisory.size_info.desc_len == 0
      assert result.advisory.size_info.summary_len == 0
    end

    test "F-BOM-PARSE-ADVISORY-SHAPE (ISS-0347 regression) -- a leading UTF-8 BOM also hits the parse-error branch without crashing",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      # ﻿ (UTF-8 BOM) prepended to otherwise-valid JSON -- Jason.decode/1
      # rejects the BOM byte sequence, landing lint_file/2 in the same
      # {:error, reason} branch as plain invalid JSON.
      File.write!(path, "﻿" <> ~s({"status": "COMPLETED"}))

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert result.parse_error != nil
      assert [violation] = result.hard_new
      assert violation.rule == "PARSE"

      assert result.advisory.warnings == []
      assert result.advisory.size_info.desc_len == 0
      assert result.advisory.size_info.summary_len == 0
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
  # The 10 real WF03-ISS0258-20260822 .md files -- now grandfathered by the
  # commit-boundary rule instead of a per-file list (ISS-0262 H6 floor-commit
  # addendum). `lint_file/2` is called exactly as production calls it (no
  # explicit `floor` argument), so this exercises the real
  # `h6_floor_commit/0` -> `pre_floor_file?/2` production path end to end.
  # ==================================================================

  describe "the 10 real WF03-ISS0258-20260822 .md files -- grandfathered by commit boundary" do
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
  # pre_floor_file?/2 and h6_floor_commit/0 -- the commit-boundary mechanism
  # itself (ISS-0262 H6 floor-commit addendum §6), tested directly against
  # real, already-resolvable commits in this repository's own history.
  # ==================================================================

  describe "pre_floor_file?/2 -- commit-boundary ancestry, real repo history" do
    test "T-PRE-FLOOR-TRUE -- a long-stable file predates a recent floor (HEAD)" do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      floor = String.trim(head)

      assert LintHandoffs.pre_floor_file?("mix.exs", floor) == true
    end

    test "T-PRE-FLOOR-FALSE -- a file added on this branch postdates the repo's root commit" do
      {root, 0} = System.cmd("git", ["rev-list", "--max-parents=0", "HEAD"])
      old_floor = root |> String.trim() |> String.split("\n", trim: true) |> List.first()

      refute LintHandoffs.pre_floor_file?(@fixture_file, old_floor)
    end

    test "T-PRE-FLOOR-NIL-FLOOR-FAILS-SAFE -- a nil floor (git resolution failure) returns false" do
      refute LintHandoffs.pre_floor_file?("mix.exs", nil)
    end

    test "T-PRE-FLOOR-UNTRACKED-PATH-FALSE -- a path with no git history at all is not pre-floor" do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      floor = String.trim(head)

      refute LintHandoffs.pre_floor_file?(
               "test/fixtures/lint_handoffs/h6/does-not-exist-#{System.unique_integer([:positive])}.md",
               floor
             )
    end

    test "T-NEW-AFTER-FLOOR-HARD-FAILS -- fixture postdating an old floor still hard-fails via lint_file/2" do
      # Design addendum §2.4/§6 item 3: proves the "added after floor always
      # hard-fails" acceptance criterion using lint_file/2's real production
      # call path (which uses the real h6_floor_commit/0, not an explicit
      # floor param) against a fixture that genuinely postdates any
      # reasonable floor.
      result = LintHandoffs.lint_file(@fixture_file, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "H6"
      assert violation.grandfathered == false
      assert result.hard_grandfathered == []
    end
  end

  # ==================================================================
  # run/1 -- H6 specifically stays green on the real corpus post-fix
  # ==================================================================
  #
  # NOTE (ISS-0262 H6 floor-commit addendum, rework_count 2): the original
  # design's T-TASK-GREEN asserted the whole task (`run/1`) exits `:ok`.
  # That assertion no longer holds independent of this fix: another,
  # already-merged run (WF03-ISS0260-20260822) has since landed a real H1 and
  # a real H3 violation on `main`
  # (`handoffs/WF03-ISS0260-20260822/step-04d-test-design-validator-recheck.json`)
  # that are unrelated to H6 and explicitly out of this fix's scope per
  # design addendum §3.1's last paragraph ("not in this fix's scope to
  # grandfather ... route to ISSUE-FIXER ... separately from this H6
  # rework"). Asserting full `run/1` greenness here would make this suite
  # flaky against `main`'s H1/H3 state exactly the way the deleted H6
  # per-file list was flaky against `main`'s H6 state -- the failure mode
  # this whole rework exists to eliminate, just for a different rule. This
  # test is therefore scoped to what this fix actually owns: zero *new* H6
  # violations anywhere in the real `handoffs/` tree.

  describe "H6 -- zero new violations on the real corpus post-fix" do
    test "T-H6-ZERO-NEW -- every non-JSON file in the real handoffs/ tree is grandfathered-or-absent, never new" do
      files = LintHandoffs.handoff_files()
      schema = %{required: [], optional: [], spent_exception_file: nil}

      results = Enum.map(files, &LintHandoffs.lint_file(&1, schema))
      new_h6 = results |> Enum.flat_map(& &1.hard_new) |> Enum.filter(&(&1.rule == "H6"))

      assert new_h6 == [],
             "expected zero new H6 violations against the real handoffs/ tree, got: #{inspect(new_h6)}"
    end
  end
end
