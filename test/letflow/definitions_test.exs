defmodule Letflow.DefinitionsTest do
  @moduledoc """
  Pure, no-I/O tests for REQ-041's `Letflow.Definitions.classify_artefact/3` and the
  moduledoc-level AC5 check on `Letflow.Definitions.SolutionPackInstall`. See
  `test/specs/REQ-041.md` for the full test-case rationale and the WF-02 Step 3
  scope-test verdict.

  `async: true` is safe here: `classify_artefact/3` performs no database I/O (pure
  string comparison) and moduledoc assertions read only compiled module metadata via
  `Code.fetch_docs/1` — no global `:telemetry` handler, no `Letflow.Repo` connection to
  check out. The DB-backed half of REQ-041's coverage (AC1, AC2, AC3's integration
  layer, AC4) lives in `test/letflow/definitions/pack_update_migration_test.exs`, which
  uses `Letflow.DataCase`.

  Mirrors `test/letflow/definitions/promotion_review_test.exs`'s established shape
  (moduledoc assertions via the compiled `Docs` chunk, whitespace-normalised so
  re-wrapping a paragraph isn't a failure while deleting or weakening a claim is)
  rather than inventing a parallel style.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions
  alias Letflow.Definitions.SolutionPackInstall

  # ---------------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------------

  # The module's published moduledoc with runs of whitespace collapsed to single
  # spaces, so an assertion on a sentence that happens to be line-wrapped in the source
  # still matches. Deliberately pattern-matches the "documented" shape: a module whose
  # moduledoc was deleted (`:none`) or hidden (`:hidden`) raises here, which is the
  # correct outcome for AC5.
  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "compute_pack_update_plan/5 against an artefact with no
  # matching solution_pack_artefact_bases row classifies it as conflict, not unchanged
  # or an error, per PRM-09 AC5" -- pure-layer half, exercising classify_artefact/3
  # directly. The DB-integration half (through the full 5-argument orchestration and a
  # real "no install/base row at all" fixture state) lives in
  # pack_update_migration_test.exs.
  # ---------------------------------------------------------------------------------

  describe "classify_artefact/3 -- AC2: a nil base (no matching solution_pack_artefact_bases row) always classifies :conflict" do
    test "nil base classifies :conflict when theirs and incoming differ" do
      assert Definitions.classify_artefact(nil, "theirs-content", "incoming-content") ==
               :conflict
    end

    test "nil base classifies :conflict even when theirs and incoming happen to be identical" do
      # The sharper case per PRM-09 AC5's "cannot prove no modification": a nil base
      # must not be treated as if it silently equalled itself just because theirs and
      # incoming coincide. A weaker implementation that special-cased "theirs ==
      # incoming, so nothing changed" would pass the test above but fail this one.
      assert Definitions.classify_artefact(nil, "same-content", "same-content") == :conflict
    end

    test "nil base classifies :conflict even when theirs and incoming are both nil" do
      # An artefact present in neither theirs_artefacts nor incoming_artefacts never
      # reaches classify_artefact/3 through compute_pack_update_plan/5 (it isn't a
      # member of the processed key set at all), but classify_artefact/3 itself is a
      # public function with its own documented contract ("nil is never treated as
      # equal to any other value, including another nil") -- asserted directly here.
      assert Definitions.classify_artefact(nil, nil, nil) == :conflict
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "base==theirs!=incoming classifies clean_update;
  # base==incoming!=theirs classifies local_only; base==theirs==incoming classifies
  # unchanged -- each with an explicit test", plus the both-differ conflict case the
  # design's truth table names as the fourth non-nil-base outcome.
  # ---------------------------------------------------------------------------------

  describe "classify_artefact/3 -- AC3: the four non-nil-base outcomes, each an explicit test" do
    test "base == theirs, base != incoming classifies :clean_update" do
      assert Definitions.classify_artefact("base-v1", "base-v1", "incoming-v2") ==
               :clean_update
    end

    test "base == incoming, base != theirs classifies :local_only" do
      assert Definitions.classify_artefact("base-v1", "theirs-v2", "base-v1") == :local_only
    end

    test "base == theirs == incoming classifies :unchanged" do
      assert Definitions.classify_artefact("base-v1", "base-v1", "base-v1") == :unchanged
    end

    test "base, theirs and incoming are three distinct values classifies :conflict (both sides changed)" do
      assert Definitions.classify_artefact("base-v1", "theirs-v2", "incoming-v3") ==
               :conflict
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "the moduledoc explicitly flags the GLOBAL-vs-PER_TENANT
  # classification question as unresolved beyond this requirement's own scope, per this
  # requirement's description"
  # ---------------------------------------------------------------------------------

  describe "AC5 -- SolutionPackInstall's moduledoc flags the GLOBAL-vs-PER_TENANT question as unresolved beyond REQ-041's scope" do
    test "the moduledoc states all three tables are GLOBAL, not tenant-scoped" do
      doc = normalized_moduledoc(SolutionPackInstall)

      assert doc =~
               "This table, `solution_pack_artefact_bases`, and `pack_update_resolutions` are all GLOBAL (public/default schema, no schema-per-tenant `:prefix`)",
             "moduledoc does not state the GLOBAL classification for all three tables"
    end

    test "the moduledoc names the GENERAL GLOBAL-vs-PER_TENANT rule as an explicit, unresolved open question" do
      doc = normalized_moduledoc(SolutionPackInstall)

      assert doc =~ "OPEN QUESTION, explicitly not resolved here",
             "moduledoc does not flag the open question explicitly"

      assert doc =~
               "nor any other Letflow decision record states a GENERAL rule for when a table earns this GLOBAL exception",
             "moduledoc does not state that no decision record settles the general rule"

      assert doc =~ "0003-ecto-schema-strategy.md",
             "moduledoc does not cite the decision record it checked and found silent"
    end

    test "the moduledoc defers the open question to a future REVIEWER/decision-record follow-up rather than resolving it itself" do
      doc = normalized_moduledoc(SolutionPackInstall)

      assert doc =~
               "the underlying general question is left open, flagged here as worth a future REVIEWER/decision-record follow-up rather than something each later requirement re-derives ad hoc",
             "moduledoc does not explicitly defer the general question rather than silently resolving it"

      # Negative control: this module's own scope is settled ("that part is settled")
      # -- the open question is specifically the GENERAL rule, not REQ-041's own
      # classification of these three tables, which the moduledoc must not muddy.
      assert doc =~ "that part is settled",
             "moduledoc does not distinguish REQ-041's own settled classification from the still-open general question"
    end
  end
end
