defmodule Mix.Tasks.Letflow.CheckDeferralStalenessTest do
  @moduledoc """
  Regression coverage for ISS-0258 -- `mix letflow.check_deferral_staleness`
  (`lib/mix/tasks/letflow.check_deferral_staleness.ex`).

  Spec: `test/specs/ISS-0258.md`. Design:
  `lib/letflow/design/iss0258-deferral-staleness-detection.md`, built to its
  section 7.4 as amended by section 11 (the Step-2b gate record, which added
  rule S6, mutants MS14/MS15/MS16 and the fixture `F-HISTORICAL-S4-STALE`).
  Run: `WF03-ISS0258-20260822`, WF-03 Step 4.

  ## Why this suite is almost entirely hermetic

  The fix ADDS a module, so the pre-fix failure of every test here is
  `UndefinedFunctionError` -- which proves the module is new and nothing
  else. WF-03's "when the pre-fix failure is 'the code under test does not
  exist'" clause governs: discrimination is demonstrated by mutating the
  shipped logic and recording which tests go red, and the tests have to be
  shaped so the mutants actually bite.

  Design section 7.2 is the load-bearing constraint here, and it was
  re-measured on this branch: the live `docs/requirements.yaml` holds

      0 deferred of 115 entries; 0 stale

  With **zero** deferred entries, every live-corpus assertion about S1, S2,
  S3 and S6 passes *vacuously* and would keep passing under almost every
  mutation of the staleness rules. This is not hypothetical -- ISS-0231 hit
  exactly this when PR #495 emptied the deferred set mid-run and made its
  headline M1 mutant invisible to every live test.

  So, stated plainly: **the hermetic fixture group is the whole test.** The
  `T-LIVE-*` tests below are over-firing guards plus genuine signal for the
  status-parsing (MS4, MS5) and stage-activity (MS1, MS2, MS3) halves only.
  No mutant is cited as detected by a live test alone.

  ## Fixture shape

  Fixtures are built by string concatenation, never by heredoc: indentation
  is load-bearing for the parser this module reuses
  (`CheckRequirementsRegistration.scan/1` and its >= 4-space attribution
  rule), so it is spelled out rather than left to heredoc stripping. Every
  fixture is wrapped in a realistic two-key file with a `stages:` section
  ahead of `requirements:`, so the section guard stays exercised.

  ## Note for a future reader of T-LIVE-ACTIVITY (design OQ-5)

  `T-LIVE-ACTIVITY` pins the derived *set* of active stages, not any count.
  It will change legitimately when S5/S6/S7 are expanded into requirements,
  or when the first S8 requirement is started. A failure there reads
  "expected update", not "regression" -- check whether a stage genuinely
  started before touching the rule.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckDeferralStaleness, as: Check
  alias Mix.Tasks.Letflow.CheckRequirementsRegistration, as: Registration

  @project_root Path.expand("../../..", __DIR__)
  @live_corpus Path.join(@project_root, "docs/requirements.yaml")

  # ------------------------------------------------------------------
  # Fixture construction
  # ------------------------------------------------------------------

  @stages_section [
                    "stages:",
                    "  - id: S1",
                    "    name: Runtime skeleton",
                    "  - id: S4",
                    "    name: API surface",
                    "  - id: S7",
                    "    name: Not yet expanded",
                    "  - id: S8",
                    "    name: Multi-tenant hardening",
                    "  - id: S9",
                    "    name: Mobile",
                    "  - id: S10",
                    "    name: A stage whose id has S1 as a prefix",
                    ""
                  ]
                  |> Enum.join("\n")

  defp doc(body), do: @stages_section <> "requirements:\n" <> body

  defp req(id, fields) do
    Enum.join(["  - id: " <> id | Enum.map(fields, &("    " <> &1))], "\n") <> "\n"
  end

  # A normally registered requirement: carries an `impl_order` field, so the
  # registration module classifies it :registered and it is never a deferral.
  defp registered(id, stage, status) do
    req(id, ["stage: #{stage}", "status: #{status}", "impl_order: 7"])
  end

  # A deferred requirement: the marker form. `rationale` is the text that
  # follows `UNREGISTERED` and is what parse_scope/1 reads.
  defp deferred(id, stage, status, rationale) do
    req(id, [
      "stage: #{stage}",
      "status: #{status}",
      "# impl_order: UNREGISTERED #{rationale}"
    ])
  end

  defp audit(body), do: Check.audit(doc(body))

  defp deferral(result, id), do: Enum.find(result.deferrals, &(&1.id == id))
  defp stage_facts(result, stage), do: Enum.find(result.stages, &(&1.stage == stage))
  defp rules(result), do: result.violations |> Enum.map(& &1.rule) |> Enum.sort()
  defp for_rule(result, rule), do: Enum.filter(result.violations, &(&1.rule == rule))
  defp rendered(result), do: result |> Check.render() |> IO.iodata_to_binary()

  defp verdicts(result) do
    Map.new(result.deferrals, fn d -> {d.id, d.verdict} end)
  end

  # ==================================================================
  # normalise_status/1 -- the totality function (S4, I7)
  # ==================================================================

  describe "normalise_status/1" do
    test "F-STATUS-TOKEN -- every declared status maps to its atom" do
      assert Check.normalise_status("pending") == :pending
      assert Check.normalise_status("in_progress") == :in_progress
      assert Check.normalise_status("done") == :done
      assert Check.normalise_status("blocked") == :blocked
      assert Check.normalise_status("cancelled") == :cancelled
      assert Check.normalise_status("  done  ") == :done
    end

    test "F-STATUS-TRAILING-COMMENT -- first token only, not rest-of-line (MS4)" do
      # Copied verbatim from the real corpus, where 8 of 115 status lines
      # carry a trailing comment. A rest-of-line extractor turns all 8 into
      # :unknown and reds this gate on day one for a non-reason.
      assert Check.normalise_status("cancelled  # MVP-1 milestone dropped, see REQ-101's note") ==
               :cancelled

      assert Check.normalise_status("done  # landed in PR #446") == :done
    end

    test "F-STATUS-UNKNOWN-TOTAL -- anything else is :unknown, never a default (I7)" do
      assert Check.normalise_status(nil) == :unknown
      assert Check.normalise_status("") == :unknown
      assert Check.normalise_status("donee") == :unknown
      assert Check.normalise_status("DONE") == :unknown
      assert Check.normalise_status("in-progress") == :unknown
    end
  end

  # ==================================================================
  # stage_activity/1 -- the section 3.3 ruling, pinned value by value
  # ==================================================================

  describe "stage_activity/1 -- the activity ruling" do
    defp activity_of(status) do
      result = audit(registered("REQ-900", "S4", status))
      stage_facts(result, "S4")
    end

    test "F-DONE-IS-ACTIVE -- :done confers activity (MS3, the mandatory mutant)" do
      facts = activity_of("done")

      assert facts.activity == :active
      assert facts.witnesses == ["REQ-900"]
    end

    test "F-IN-PROGRESS-IS-ACTIVE -- :in_progress confers activity" do
      assert activity_of("in_progress").activity == :active
    end

    test "F-BLOCKED-IS-ACTIVE -- :blocked confers activity (design OQ-1)" do
      # OQ-1 ruled `blocked` IN, against the Step-1 recommendation, on the
      # asymmetric-cost argument. Reversing that ruling is one token in
      # @active_statuses and flipping this test -- deliberately loud.
      assert activity_of("blocked").activity == :active
    end

    test "F-PENDING-NOT-ACTIVE -- :pending does not confer activity (MS2)" do
      facts = activity_of("pending")

      assert facts.activity == :inactive
      assert facts.witnesses == []
    end

    test "F-CANCELLED-NOT-ACTIVE -- abandonment is not activity (MS1)" do
      facts = activity_of("cancelled")

      assert facts.activity == :inactive
      assert facts.witnesses == []
    end

    test "F-UNKNOWN-NOT-ACTIVE -- an unrecognised status confers nothing" do
      assert activity_of("donee").activity == :inactive
    end

    test "F-EMPTY-STAGE-INACTIVE -- a stage with no requirements is absent, by rule" do
      # S7 is declared in the stages section and holds no requirement. It is
      # :inactive by the same rule as everything else -- the empty set holds
      # no active status -- and produces no violation of any kind.
      result = audit(registered("REQ-900", "S4", "done"))

      assert stage_facts(result, "S7") == nil
      assert Enum.map(result.stages, & &1.stage) == ["S4"]
      assert result.violations == []
    end

    test "F-STAGE-EXACT-MATCH -- S10 work must not activate S1 (MS13)" do
      body =
        registered("REQ-900", "S10", "done") <>
          deferred("REQ-901", "S1", "pending", "-- waits on the S1 kernel")

      result = audit(body)

      assert stage_facts(result, "S10").activity == :active
      assert stage_facts(result, "S1").activity == :inactive
      assert deferral(result, "REQ-901").verdict == :legitimate
      assert result.violations == []
    end

    test "F-STAGE-EXACT-MATCH-REVERSE -- S1 work must not activate S10 (MS13)" do
      body =
        registered("REQ-900", "S1", "done") <>
          deferred("REQ-901", "S10", "pending", "-- waits on the S10 kernel")

      result = audit(body)

      assert stage_facts(result, "S1").activity == :active
      assert stage_facts(result, "S10").activity == :inactive
      assert deferral(result, "REQ-901").verdict == :legitimate
      assert result.violations == []
    end
  end

  # ==================================================================
  # S1 / S2 -- the staleness verdict itself
  # ==================================================================

  describe "staleness verdicts (S1, S2)" do
    test "F-STALE-BASIC -- deferred in a stage with a done sibling is STALE" do
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on the S8 note above")

      result = audit(body)
      d = deferral(result, "REQ-901")

      assert d.verdict == :stale
      assert d.scope == :stage_scoped
      assert result.stale_count == 1
      assert result.deferral_count == 1

      assert [v] = for_rule(result, "S1")
      assert v.id == "REQ-901"
      assert v.line == d.line
      assert v.message =~ "STALE deferral"
      assert v.message =~ "stage S4 is ACTIVE"
      assert v.message =~ "REQ-900 (done)"
    end

    test "F-LEGIT-BASIC -- deferred in an all-pending stage is LEGITIMATE" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- waits on the S8 kernel")

      result = audit(body)

      assert deferral(result, "REQ-901").verdict == :legitimate
      assert result.stale_count == 0
      assert result.deferral_count == 1
      assert result.violations == []
    end

    test "F-STALE-EXITS -- a stale deferral is a violation, not just a roster line (MS11)" do
      # Design MS11: demoting S1 to a printed advisory makes the whole gate a
      # report nobody's exit code depends on -- ISS-0258's own root cause one
      # level up. The violation list is the exit-code-bearing surface.
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      refute result.violations == [],
             "a stale deferral must produce a violation, not merely a printed verdict"

      assert rules(result) == ["S1"]
    end

    test "F-LEGIT-NEVER-GATES -- a legitimate deferral never gates, at any count (I4)" do
      body =
        Enum.map_join(1..5, "", &deferred("REQ-90#{&1}", "S8", "pending", "-- waits on S8"))

      result = audit(body)

      assert result.deferral_count == 5
      assert result.stale_count == 0
      assert result.violations == []
    end

    test "F-DEFERRED-NO-STAGE -- no `stage:` is undecidable and gates (S2, MS12)" do
      body =
        registered("REQ-900", "S4", "done") <>
          req("REQ-901", ["status: pending", "# impl_order: UNREGISTERED -- no stage at all"])

      result = audit(body)
      d = deferral(result, "REQ-901")

      assert d.stage == nil
      assert d.verdict == :undecidable
      refute d.verdict == :legitimate

      assert [v] = for_rule(result, "S2")
      assert v.id == "REQ-901"
      assert v.message =~ "no `stage:`"
      assert v.message =~ "undecidable"
    end

    test "F-SELF-EXCLUSION -- a deferral does not activate its own stage (MS10)" do
      # The only non-pending requirement in S4 is the deferred entry itself.
      # Without self-exclusion it activates its own stage and flags itself --
      # an unfixable red.
      body = deferred("REQ-900", "S4", "done", "-- deferred but itself done")

      result = audit(body)
      d = deferral(result, "REQ-900")

      assert d.verdict == :legitimate
      assert result.violations == []

      # Section 3.5's residual: the anomaly is annotated rather than judged.
      assert rendered(result) =~ "(NOTE: deferred entry is itself done)"
    end

    test "F-SELF-EXCLUSION-NOT-GAMEABLE -- two deferrals do not excuse each other" do
      body =
        deferred("REQ-900", "S4", "done", "-- deferred but itself done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      assert deferral(result, "REQ-900").verdict == :legitimate
      assert deferral(result, "REQ-901").verdict == :stale
      assert [v] = for_rule(result, "S1")
      assert v.id == "REQ-901"
      assert v.message =~ "REQ-900 (done)"
    end
  end

  # ==================================================================
  # The historical corpus -- the one real-world signal this gate has
  # ==================================================================

  describe "the historical corpus at 75f553d" do
    # Re-derived from `git show 75f553d:docs/requirements.yaml` rather than
    # inherited: the 21 pre-PR#495 deferrals were 9 x S8 + 4 x S9 + 8 x S4,
    # and the stage/status cross-tab at that commit was
    #   S4  10 done, 21 pending, 2 cancelled
    #   S8  9 pending, 1 cancelled
    #   S9  4 pending
    # So 13 were legitimate and 8 (the S4 ones, whose rationale pointed at
    # the wrong stage) were genuinely stale weeks before anyone noticed and
    # registered them by hand. Asserted as ONE group on purpose: a rule that
    # gets one half right and the other wrong is invisible to either half
    # alone.
    @historical_rationale "-- see the S8 note above"

    defp historical_corpus do
      s8_deferred =
        Enum.map_join(
          115..123,
          "",
          &deferred("REQ-#{&1}", "S8", "pending", @historical_rationale)
        )

      s8_cancelled = registered("REQ-114", "S8", "cancelled")

      s9_deferred =
        Enum.map_join(
          124..127,
          "",
          &deferred("REQ-#{&1}", "S9", "pending", @historical_rationale)
        )

      s4_deferred =
        Enum.map_join(
          128..135,
          "",
          &deferred("REQ-#{&1}", "S4", "pending", @historical_rationale)
        )

      s4_done = Enum.map_join(201..210, "", &registered("REQ-#{&1}", "S4", "done"))
      s4_pending = Enum.map_join(301..313, "", &registered("REQ-#{&1}", "S4", "pending"))
      s4_cancelled = Enum.map_join(401..402, "", &registered("REQ-#{&1}", "S4", "cancelled"))

      s8_cancelled <>
        s8_deferred <> s9_deferred <> s4_done <> s4_pending <> s4_cancelled <> s4_deferred
    end

    test "F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE -- the 13/8 split (MS1, MS2, MS3)" do
      result = audit(historical_corpus())
      by_id = verdicts(result)

      legitimate = for id <- 115..127, do: "REQ-#{id}"
      stale = for id <- 128..135, do: "REQ-#{id}"

      assert result.deferral_count == 21

      for id <- legitimate do
        assert by_id[id] == :legitimate, "#{id} (S8/S9, inactive stage) must be legitimate"
      end

      for id <- stale do
        assert by_id[id] == :stale, "#{id} (S4, 10 done siblings) must be stale"
      end

      assert result.stale_count == 8

      assert stage_facts(result, "S8").activity == :inactive
      assert stage_facts(result, "S9").activity == :inactive
      assert stage_facts(result, "S4").activity == :active

      assert rules(result) == List.duplicate("S1", 8)
      assert Enum.map(for_rule(result, "S1"), & &1.id) |> Enum.sort() == stale
    end
  end

  # ==================================================================
  # S4 -- status parsing and the totality defence
  # ==================================================================

  describe "status parsing (S4)" do
    test "F-STATUS-TRAILING-COMMENT -- a commented `done` still activates (MS4)" do
      # Two-way discriminator. Under a rest-of-line extractor REQ-900 becomes
      # :unknown, which BOTH fires a spurious S4 AND un-activates S4, so the
      # real stale deferral reads legitimate.
      body =
        req("REQ-900", ["stage: S4", "status: done  # landed in PR #446", "impl_order: 7"]) <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      assert result.statuses["REQ-900"] == :done
      assert for_rule(result, "S4") == []
      assert stage_facts(result, "S4").activity == :active
      assert deferral(result, "REQ-901").verdict == :stale
    end

    test "F-STATUS-RAW-TOKEN -- the parser stores the first token, not rest-of-line (MS4)" do
      # Closes a coverage hole found by measurement at Step 4. The trailing-
      # comment trap is defended TWICE -- `@status_re` in the parser and the
      # token split in `normalise_status/1` -- so mutating `@status_re` alone
      # is absorbed by the second layer and no behavioural test can see it.
      # The raw stored token is the only observable that distinguishes them,
      # and design D4 states explicitly that this field is stored raw.
      body =
        req("REQ-900", [
          "stage: S4",
          "status: cancelled  # MVP-1 milestone dropped, see REQ-101's note",
          "impl_order: 7"
        ])

      assert [entry] = Registration.scan(doc(body)).entries
      assert entry.status == "cancelled"
      assert Check.normalise_status(entry.status) == :cancelled
    end

    test "F-STATUS-BLOCK-NOTE -- an unattributed `status:` is not swept in (MS5)" do
      # A 2-space `status:` line between entries stands for any block-level or
      # mis-indented key. The >= 4-space attribution rule is what keeps it out
      # of REQ-900's entry. Two-way discriminator: dropping that rule both
      # silences the real S4 violation and activates S4, flipping REQ-901.
      body =
        req("REQ-900", ["stage: S4", "impl_order: 7"]) <>
          "  status: done\n" <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      assert result.statuses["REQ-900"] == :unknown
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert stage_facts(result, "S4").activity == :inactive
      assert deferral(result, "REQ-901").verdict == :legitimate
    end

    test "F-UNKNOWN-STATUS-FAILS -- `status: donee` is :unknown and gates (MS6)" do
      result = audit(registered("REQ-900", "S4", "donee"))

      assert result.statuses["REQ-900"] == :unknown
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert v.message =~ "unrecognised status"
      assert v.message =~ "donee"
      assert v.message =~ "failing bucket"
    end

    test "F-TYPO-DOES-NOT-DEACTIVATE -- a typo'd sibling reds the run (MS6)" do
      # The silent-absorption failure: if `donee` were absorbed into :pending,
      # S4 would go quiet AND inactive, and REQ-901 would read legitimate on a
      # green run. The run must be red instead.
      body =
        registered("REQ-900", "S4", "donee") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      refute result.violations == [], "a typo'd status must never produce a quiet green run"
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert deferral(result, "REQ-901").verdict == :legitimate
      assert deferral(result, "REQ-901").reason =~ "inactive"
    end

    test "F-NO-STATUS-LINE -- an entry with no `status:` at all is :unknown (S4)" do
      result = audit(req("REQ-900", ["stage: S4", "impl_order: 7"]))

      assert result.statuses["REQ-900"] == :unknown
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert v.message =~ "nil"
    end

    test "F-S4-ALL-ENTRIES -- S4 applies to non-deferred entries too (design OQ-2)" do
      body =
        registered("REQ-900", "S8", "donee") <>
          deferred("REQ-901", "S8", "pending", "-- waits on S8")

      result = audit(body)

      assert deferral(result, "REQ-901").verdict == :legitimate
      assert Enum.map(for_rule(result, "S4"), & &1.id) == ["REQ-900"]
    end
  end

  # ==================================================================
  # S3 / D6 -- the blocked-by escape hatch
  # ==================================================================

  describe "parse_scope/1 -- the hatch grammar" do
    test "F-HATCH-GRAMMAR -- anchored, well-formed, with free text" do
      assert Check.parse_scope("-- blocked-by: REQ-042 -- waiting on the token kernel") ==
               {:blocked_by, "REQ-042"}

      assert Check.parse_scope("blocked-by: REQ-042 -- waiting on the token kernel") ==
               {:blocked_by, "REQ-042"}
    end

    test "F-HATCH-ANCHOR -- a mid-rationale mention is not a hatch (MS7)" do
      # ISS-0231's M8 absorption bug wearing this issue's clothes: prose that
      # merely mentions the form must not suppress a real staleness.
      assert Check.parse_scope("-- unlike the blocked-by: REQ-042 cases, this waits on S8") ==
               :stage_scoped
    end

    test "F-HATCH-MALFORMED -- near-misses never become a silent hatch" do
      assert Check.parse_scope("-- blocked-by: REQ_042 -- malformed id") == :stage_scoped
      assert Check.parse_scope("-- blocked-by: -- no id at all") == :stage_scoped
      assert Check.parse_scope("-- blockedby: REQ-042 -- no hyphen") == :stage_scoped
      assert Check.parse_scope(nil) == :stage_scoped
      assert Check.parse_scope("-- see the S8 note above") == :stage_scoped
    end

    test "F-HATCH-NO-RATIONALE -- a bare id is rejected as a hatch (MS16)" do
      # D6's fourth property: free text is still required, so R3's spirit --
      # a human-readable reason -- survives the hatch instead of being
      # replaced by it.
      assert Check.parse_scope("-- blocked-by: REQ-042") == :stage_scoped
      assert Check.parse_scope("-- blocked-by: REQ-042 --") == :stage_scoped
      assert Check.parse_scope("blocked-by: REQ-042") == :stage_scoped
    end
  end

  describe "the blocked-by hatch (S3)" do
    defp hatch_corpus(blocker_status, rationale) do
      registered("REQ-900", "S4", "done") <>
        registered("REQ-042", "S4", blocker_status) <>
        deferred("REQ-901", "S4", "pending", rationale)
    end

    test "F-HATCH-BASIC -- a live hatch survives an active stage" do
      result = audit(hatch_corpus("pending", "-- blocked-by: REQ-042 -- waits on the kernel"))
      d = deferral(result, "REQ-901")

      assert d.scope == {:blocked_by, "REQ-042"}
      assert d.verdict == :legitimate
      assert d.reason =~ "still open"
      assert stage_facts(result, "S4").activity == :active
      assert result.violations == []
    end

    test "F-HATCH-BLOCKER-DONE -- the hatch expires when the blocker is done (MS9)" do
      # The second mandatory mutant. The hatch is not an exemption; it is a
      # machine-checkable assertion that goes stale on its own.
      result = audit(hatch_corpus("done", "-- blocked-by: REQ-042 -- waits on the kernel"))
      d = deferral(result, "REQ-901")

      assert d.verdict == :stale
      assert d.reason =~ "EXPIRED"

      assert rules(result) == ["S1", "S3"]
      assert [v] = for_rule(result, "S3")
      assert v.id == "REQ-901"
      assert v.message =~ "REQ-042"
      assert v.message =~ "EXPIRED"
      assert v.message =~ "done"
    end

    test "F-HATCH-BLOCKER-CANCELLED -- a cancelled blocker expires it too (MS9)" do
      result = audit(hatch_corpus("cancelled", "-- blocked-by: REQ-042 -- waits on the kernel"))
      d = deferral(result, "REQ-901")

      assert d.verdict == :stale
      assert [v] = for_rule(result, "S3")
      assert v.message =~ "cancelled"
    end

    test "F-HATCH-DANGLING -- an absent blocker is rejected, not honoured (MS8)" do
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- blocked-by: REQ-999 -- waits on a ghost")

      result = audit(body)

      assert [v] = for_rule(result, "S3")
      assert v.id == "REQ-901"
      assert v.message =~ "REQ-999"
      assert v.message =~ "not present in the corpus"

      # The unusable hatch does not suppress the stage-activity judgement:
      # the entry is judged on stage activity alone, and the run is red.
      refute result.violations == []
      assert deferral(result, "REQ-901").verdict == :stale
      assert rules(result) == ["S1", "S3"]
    end

    test "F-HATCH-SELF -- naming your own id is an unfalsifiable self-license" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-901 -- waits on itself")

      result = audit(body)

      assert [v] = for_rule(result, "S3")
      assert v.id == "REQ-901"
      assert v.message =~ "own id"
      refute result.violations == []
    end

    test "F-HATCH-INVALID-STILL-JUDGED -- an unusable hatch falls back to stage activity" do
      # Characterises REVIEWER MINOR-1: with an inactive stage the roster's
      # one-word verdict column reads LEGITIMATE while S3 independently gates.
      # There is no gate hole -- the run is red -- but the column and the
      # outcome disagree. Pinned so a later relabelling is a deliberate change.
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-999 -- waits on a ghost")

      result = audit(body)

      assert deferral(result, "REQ-901").verdict == :legitimate
      assert deferral(result, "REQ-901").reason =~ "unusable"
      assert rules(result) == ["S3"]
      refute result.violations == [], "S3 gates even when the roster column reads LEGITIMATE"
    end
  end

  # ==================================================================
  # S6 -- the hatch graph is acyclic
  # ==================================================================

  describe "hatch cycles (S6)" do
    test "F-HATCH-CYCLE-2 -- two deferrals may not license each other (MS14)" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-902 -- waits on B") <>
          deferred("REQ-902", "S8", "pending", "-- blocked-by: REQ-901 -- waits on A")

      result = audit(body)

      assert [v] = for_rule(result, "S6")
      assert v.message =~ "cycle"
      assert v.message =~ "REQ-901"
      assert v.message =~ "REQ-902"
      assert v.message =~ "never expires"

      # Both members read :legitimate individually -- that is exactly why the
      # cycle needs its own file-level rule (design section 6.2).
      assert verdicts(result) == %{"REQ-901" => :legitimate, "REQ-902" => :legitimate}
      refute result.violations == []
    end

    test "F-HATCH-CYCLE-3 -- a three-node chain, so pairs cannot be special-cased" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-902 -- waits on B") <>
          deferred("REQ-902", "S8", "pending", "-- blocked-by: REQ-903 -- waits on C") <>
          deferred("REQ-903", "S8", "pending", "-- blocked-by: REQ-901 -- waits on A")

      result = audit(body)

      assert [v] = for_rule(result, "S6")
      assert v.message =~ "REQ-901 -> REQ-902 -> REQ-903 -> REQ-901"
    end

    test "F-HATCH-CHAIN-NO-CYCLE -- an acyclic chain is not a cycle" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-902 -- waits on B") <>
          deferred("REQ-902", "S8", "pending", "-- blocked-by: REQ-900 -- waits on the root")

      result = audit(body)

      assert for_rule(result, "S6") == []
      assert result.violations == []
    end
  end

  # ==================================================================
  # S5 -- the corpus is non-empty and shaped
  # ==================================================================

  describe "corpus shape (S5)" do
    test "F-NO-REQUIREMENTS-KEY -- no `requirements:` key is never a green pass (MS15)" do
      result = Check.audit("nothing: here\nother: stuff\n")

      assert result.deferral_count == 0
      refute result.violations == [], "a scan that finds nothing must never pass silently"

      assert [v] = for_rule(result, "S5")
      assert v.id == nil
      assert v.message =~ "zero entries"
    end

    test "F-EMPTY-SECTION -- `requirements:` with zero entries is an S5 violation (MS15)" do
      result = Check.audit(@stages_section <> "requirements:\n")

      assert result.deferral_count == 0
      assert [v] = for_rule(result, "S5")
      assert v.message =~ "zero entries"
    end

    test "F-SHAPELESS-CORPUS -- entries but no recognised status anywhere is S5" do
      body =
        req("REQ-900", ["stage: S4", "impl_order: 7"]) <>
          req("REQ-901", ["stage: S4", "impl_order: 8"])

      result = audit(body)

      assert Enum.any?(for_rule(result, "S5"), &(&1.message =~ "no entry in the corpus"))
    end

    test "F-DUPLICATE-ID-DENOMINATOR -- characterises REVIEWER MINOR-2" do
      # Duplicate ids collapse in the `statuses` map, so the totality line's
      # denominator under-reports. Gated upstream by the registration check's
      # R4, which runs first in the `letflow.check` alias. Pinned as a known
      # characteristic rather than claimed as correct.
      body = registered("REQ-900", "S4", "done") <> registered("REQ-900", "S4", "pending")

      result = audit(body)

      assert map_size(result.statuses) == 1
      assert Registration.scan(doc(body)).entry_count == 2

      assert Enum.any?(Registration.scan(doc(body)).violations, &(&1.rule == "R4")),
             "the registration check is what gates duplicate ids"
    end
  end

  # ==================================================================
  # render/1 -- the always-printed blocks
  # ==================================================================

  describe "render/1" do
    test "F-ROSTER-EXPLAINS -- a stale roster names id, stage and a witness" do
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      out = body |> audit() |> rendered()

      assert out =~ "STAGE ACTIVITY (derived, always reported, never gates):"
      assert out =~ "S4  ACTIVE"
      assert out =~ "DEFERRALS (legitimate ones are reported and never gate):"
      assert out =~ "REQ-901"
      assert out =~ "STALE"
      assert out =~ "REQ-900 (done)"
      assert out =~ "VIOLATIONS (each one fails the run):"
      assert out =~ "[S1] REQ-901"
      assert out =~ "1 deferred of 2 entries; 1 stale"
    end

    test "F-ROSTER-GREEN -- a legitimate roster explains itself and shows no violations" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- waits on the S8 kernel")

      out = body |> audit() |> rendered()

      assert out =~ "S8  INACTIVE"
      assert out =~ "REQ-901"
      assert out =~ "LEGITIMATE"
      assert out =~ "stage S8 is inactive"
      assert out =~ "1 deferred of 2 entries; 0 stale"
      refute out =~ "VIOLATIONS"
    end

    test "F-ROSTER-EMPTY -- an empty roster still prints both blocks" do
      out = registered("REQ-900", "S4", "done") |> audit() |> rendered()

      assert out =~ "DEFERRALS (legitimate ones are reported and never gate): none"
      assert out =~ "0 deferred of 1 entries; 0 stale"
      refute out =~ "VIOLATIONS"
    end
  end

  # ==================================================================
  # T-LIVE-* : the real docs/requirements.yaml.
  # Read-only, unpinned to counts. Per design section 7.2 these are
  # over-firing guards; genuine signal only for MS1-MS5.
  # ==================================================================

  describe "T-LIVE-* -- the real docs/requirements.yaml" do
    setup do
      %{result: @live_corpus |> File.read!() |> Check.audit()}
    end

    test "T-LIVE-GREEN -- the real corpus produces zero violations", %{result: result} do
      assert result.violations == [],
             "live corpus violations: " <>
               Enum.map_join(result.violations, "\n", &"[#{&1.rule}] #{&1.id}: #{&1.message}")
    end

    test "T-LIVE-STATUS-TOTAL -- no entry resolves to :unknown (MS4, MS5)", %{result: result} do
      unknown = for {id, :unknown} <- result.statuses, do: id

      assert unknown == [], "entries with an unrecognised status: #{inspect(unknown)}"
      assert map_size(result.statuses) > 0
    end

    test "T-LIVE-ACTIVITY -- S0..S4 active, S8/S9 inactive (MS1, MS2, MS3)", %{result: result} do
      # Design OQ-5: this pins the SET, not the counts, which move with every
      # merge. It will change legitimately when S5/S6/S7 are expanded or when
      # S8 starts -- a failure here means "expected update", not "regression".
      active = for s <- result.stages, s.activity == :active, do: s.stage
      inactive = for s <- result.stages, s.activity == :inactive, do: s.stage

      assert active == ["S0", "S1", "S2", "S3", "S4"]
      assert inactive == ["S8", "S9"]
    end

    test "T-LIVE-DEFERRED-COUNT-IS-ZERO -- documents today's vacuous green", %{result: result} do
      # NOT a permanent invariant. It records that S1/S2/S3/S6 are vacuously
      # green on today's corpus, so a future reader who adds a real deferral
      # and sees this test change knows the staleness rule has just become
      # load-bearing -- rather than reading it as a regression.
      assert result.deferral_count == 0
      assert result.stale_count == 0
    end

    test "T-REG-STILL-GREEN -- the bounded `status` addition kept ISS-0231 green" do
      report = @live_corpus |> File.read!() |> Registration.scan()

      assert report.violations == []
      assert report.entry_count > 0
      assert report.counts.registered + report.counts.deferred == report.entry_count

      # The one addition of design D4: a raw, uninterpreted token.
      assert Enum.all?(report.entries, &Map.has_key?(&1, :status))
      assert Enum.all?(report.entries, &(is_binary(&1.status) or is_nil(&1.status)))
    end
  end

  # ==================================================================
  # T-ALIAS-* : ISS-0258 AC2 -- "wired into an actual gate, not built and
  # left unwired". `mix letflow.check` is the ONLY gate surface this repo
  # has (design section 1.1: no .github, no .gitlab-ci.yml, no .circleci),
  # so alias membership IS the wiring. Without this test the line can be
  # deleted from mix.exs and the whole suite stays green -- measured.
  # Precedent for reading mix.exs from a test:
  # test/letflow/engine/lua_script_audit_test.exs, "mix.exs and moduledoc
  # guardrails".
  # ==================================================================

  describe "the letflow.check alias wiring (AC2)" do
    setup do
      %{aliases: Mix.Project.config()[:aliases][:"letflow.check"]}
    end

    test "T-ALIAS-WIRED -- the detector is a step of `mix letflow.check`", %{aliases: aliases} do
      assert "letflow.check_deferral_staleness" in aliases,
             "the detector is unwired -- `mix letflow.check` steps are: #{inspect(aliases)}"
    end

    test "T-ALIAS-SLOT -- it runs after registration and before the slow steps (D5)", %{
      aliases: aliases
    } do
      # Design D5 rules slot 3: immediately after the check it shares a parse
      # with, and BEFORE `format --check-formatted` / `compile
      # --warnings-as-errors` / the test run, so a stale deferral is reported
      # in a second rather than after a full compile+test cycle. Asserted as
      # relative order, not a hard index, per OQ-4.
      at = &Enum.find_index(aliases, fn step -> step == &1 end)

      assert at.("letflow.check_requirements_registration") <
               at.("letflow.check_deferral_staleness")

      assert at.("letflow.check_deferral_staleness") < at.("format --check-formatted")
    end
  end
end

defmodule Mix.Tasks.Letflow.CheckDeferralStalenessTaskTest do
  @moduledoc """
  Task-level coverage for `mix letflow.check_deferral_staleness` -- the thin
  `run/1` shell around the pure core exercised above.

  `run/1` reads a hard-coded relative path (`docs/requirements.yaml`) and has
  no path argument; adding one would be a design change and is not this
  file's to make. So these tests `File.cd!/2` into a temp directory holding a
  fixture corpus, which changes the working directory for the whole VM --
  hence `async: false`. The cd window is kept to the single `run/1` call.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Mix.Tasks.Letflow.CheckDeferralStaleness, as: Check

  @green """
  stages:
    - id: S8
      name: Multi-tenant hardening
  requirements:
    - id: REQ-900
      stage: S8
      status: pending
      impl_order: 7
    - id: REQ-901
      stage: S8
      status: pending
      # impl_order: UNREGISTERED -- waits on the S8 kernel
  """

  @red """
  stages:
    - id: S4
      name: API surface
  requirements:
    - id: REQ-900
      stage: S4
      status: done
      impl_order: 7
    - id: REQ-901
      stage: S4
      status: pending
      # impl_order: UNREGISTERED -- waits on something
  """

  defp in_corpus(content, fun) do
    dir = Path.join(System.tmp_dir!(), "letflow-cds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/requirements.yaml"), content)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.cd!(dir, fun)
  end

  test "T-TASK-PRINTS-ON-GREEN -- both blocks print unconditionally" do
    {result, out} = in_corpus(@green, fn -> with_io(fn -> Check.run([]) end) end)

    assert result == :ok
    assert out =~ "STAGE ACTIVITY (derived, always reported, never gates):"
    assert out =~ "S8  INACTIVE"
    assert out =~ "DEFERRALS (legitimate ones are reported and never gate):"
    assert out =~ "REQ-901"
    assert out =~ "LEGITIMATE"
    assert out =~ "1 deferred of 2 entries; 0 stale"
    refute out =~ "VIOLATIONS"
  end

  test "T-TASK-RAISES -- a stale deferral raises Mix.Error" do
    {error, out} =
      in_corpus(@red, fn ->
        with_io(fn -> assert_raise Mix.Error, fn -> Check.run([]) end end)
      end)

    # The report is written before the raise -- the table and the roster are
    # visible on a red run too, not swallowed by the exception.
    assert out =~ "S4  ACTIVE"
    assert out =~ "1 deferred of 2 entries; 1 stale"
    assert out =~ "VIOLATIONS (each one fails the run):"

    message = Exception.message(error)
    assert message =~ "[S1]"
    assert message =~ "REQ-901"
    assert message =~ "1 violation(s)"
  end

  test "T-TASK-MISSING-FILE -- an unreadable corpus raises rather than passing" do
    dir = Path.join(System.tmp_dir!(), "letflow-cds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.cd!(dir, fn ->
      error = assert_raise Mix.Error, fn -> Check.run([]) end
      assert Exception.message(error) =~ "[S5]"
      assert Exception.message(error) =~ "docs/requirements.yaml"
    end)
  end
end
