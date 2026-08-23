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

  ## REQ-030 moduledoc-content checks (AC6 and part of AC9)

  Two of REQ-030's describe blocks below reuse this same `normalized_moduledoc/1`
  helper against `Letflow.Definitions` itself (not `SolutionPackInstall`) to check
  AC6's "documented explicitly in the moduledoc" requirement and AC9's tenant_id
  contract statement -- pure doc-content assertions, no database needed. The rest
  of REQ-030's coverage (all database-backed: `create/2`, `activate/2`, etc.) lives
  in `test/letflow/definitions/store_test.exs`, which uses `Letflow.DataCase` -- see
  that file's moduledoc for why the split follows this module's established
  pure-vs-DB-backed convention.
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

  # ---------------------------------------------------------------------------------
  # REQ-030 acceptance criterion 6: "activate/1's signature includes a nil-able/
  # optional service-scope-validation hook parameter that REQ-031 wires in,
  # documented explicitly in the moduledoc as the SVC-03 integration point." The
  # hook's *behavioral* effect (both :ok and {:error, reason} outcomes) is tested
  # against real Postgres in `test/letflow/definitions/store_test.exs`; this is the
  # doc-content half of AC6 specifically -- a pure, database-free assertion.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC6: activate/2's service_scope_validator hook is documented as the SVC-03 integration point (REQ-030)" do
    test "the moduledoc documents the :service_scope_validator option and names the SVC-03/REQ-031 integration point" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "service_scope_validator",
             "moduledoc does not mention the :service_scope_validator option"

      assert doc =~ "SVC-03",
             "moduledoc does not name the SVC-03 integration point"

      assert doc =~ "REQ-031",
             "moduledoc does not attribute the hook's own logic to REQ-031"

      assert doc =~ "This module builds only the injection point",
             "moduledoc does not state that REQ-030 builds only the injection point, not the hook's logic"
    end

    test "the moduledoc documents the hook's 2-arity :ok | {:error, term()} contract" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "2-arity function",
             "moduledoc does not describe the hook as a 2-arity function"

      assert doc =~ ":ok | {:error, term()}",
             "moduledoc does not document the hook's :ok | {:error, term()} return contract"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-030 acceptance criterion 9 (doc-content half): the moduledoc states the
  # tenant_id-derivation contract create/2's own rejection behavior implements. The
  # behavioral half (an actual create/2 call with a disagreeing tenant_id, and a
  # positive check that a written row's tenant_id matches the real tenant) is
  # tested against real Postgres in `store_test.exs`'s "create/2 (AC9)" block.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC9 (doc-content half): tenant_id is always derived, never accepted (REQ-030)" do
    test "the moduledoc states create/2 never accepts a caller-supplied tenant_id and names the rejection error" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "tenant_id_not_accepted",
             "moduledoc does not name the :tenant_id_not_accepted rejection error"

      assert doc =~ "never accepts a `:tenant_id`",
             "moduledoc does not state that create/2's attrs never accepts a :tenant_id key"

      assert doc =~ "tenant_id_for_schema_name",
             "moduledoc does not name the derivation function tenant_id is sourced from"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-042 acceptance criterion 6: "the moduledoc states no new migration/table was
  # added, explicitly citing definition.md's PD-10 section for that boundary." A pure
  # doc-content assertion, no database needed -- the behavioral half of REQ-042
  # (search/2's ranking, error, and pagination behavior) lives in
  # test/letflow/definitions/search_test.exs, which uses Letflow.DataCase.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC6: search/2 states no new migration/table was added, citing PD-10 (REQ-042)" do
    test "the moduledoc cites PD-10 and definition.md as search/2's source" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "PD-10",
             "moduledoc does not cite PD-10 for search/2's boundary"

      assert doc =~ "src/design/definition.md",
             "moduledoc does not cite definition.md as search/2's ported source"
    end

    test "the moduledoc states no new Zig source file or SQL migration is required" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~
               "PD-10 states explicitly that search lives inside the existing store -- no new Zig source file or SQL migration is required",
             "moduledoc does not state that PD-10 requires no new Zig source file or SQL migration"
    end

    test "the moduledoc states zero new migrations and zero new indexes were added" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "zero new `priv/repo/migrations/` files",
             "moduledoc does not state that zero new migration files were added"

      assert doc =~ "zero new indexes",
             "moduledoc does not state that zero new indexes were added"

      assert doc =~ "REQ-027 shipped it",
             "moduledoc does not state the query runs against process_definitions exactly as REQ-027 shipped it"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-040 acceptance criterion 4: "the moduledoc explicitly states the apply
  # pipeline gate condition is assertions_failed == 0, not status == passed, citing
  # the teardown_failed green-gate case." A pure doc-content assertion, no database
  # needed -- the behavioral half of REQ-040 (idempotency, sandbox isolation, the
  # distinct :failed/:teardown_failed outcomes, the try/rescue span) lives in
  # test/letflow/definitions/promotion_assertion_rerun_test.exs, which uses
  # Letflow.DataCase. See test/specs/REQ-040.md for the full rationale.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC4: apply_promotion_assertion_rerun/6's gate condition is assertions_failed == 0, not status == passed (REQ-040)" do
    test "states the gate condition literally as assertions_failed == 0, NOT status == \"passed\"" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "`assertions_failed == 0` -- NOT on `status == \"passed\"`",
             "moduledoc does not state the gate condition literally as assertions_failed == 0, NOT status == \"passed\""
    end

    test "states the teardown_failed green-gate case explicitly, with assertions_failed remaining 0" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~
               "`status = :teardown_failed` with `assertions_failed` still `0`",
             "moduledoc does not state the teardown_failed outcome with assertions_failed remaining 0"

      assert doc =~ "`teardown_failed` row is therefore a **green gate**",
             "moduledoc does not call a teardown_failed row a green gate explicitly"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-040 acceptance criterion 6: "the moduledoc names the crash-safety/
  # guaranteed-teardown open question explicitly, per this requirement's description
  # and stage-2-event-store-definitions.md's Early findings." A pure doc-content
  # assertion, no database needed.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC6: crash-safety/guaranteed-teardown open question is named explicitly (REQ-040)" do
    test "states the try/rescue wraps the claim-through-record-outcome span and names the three exit classes it covers" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "wrapped in a single `try/rescue`",
             "moduledoc does not state the claim-through-record-outcome span is wrapped in try/rescue"

      assert doc =~
               "normal completion, a typed error return from any step, and a raised exception",
             "moduledoc does not name the three exit classes the try/rescue covers"

      assert doc =~
               "fail-closed accounting (`assertions_failed >= 1`) rather than left stuck at `status = :running`",
             "moduledoc does not state the fail-closed-accounting-instead-of-stuck-running guarantee"
    end

    test "explicitly discloses the residual gap: a hard process kill, a BEAM node crash, and System.halt/0 are NOT covered" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "does **not** cover a hard process kill",
             "moduledoc does not disclose that a hard process kill is not covered"

      assert doc =~ "`Process.exit(pid, :kill)`",
             "moduledoc does not name Process.exit(pid, :kill) explicitly"

      assert doc =~ "BEAM node crash",
             "moduledoc does not name a BEAM node crash explicitly"

      assert doc =~ "`System.halt/0`",
             "moduledoc does not name System.halt/0 explicitly"

      assert doc =~ "disclosed, deferred limitation, not an oversight",
             "moduledoc does not frame the residual gap as a disclosed, deferred limitation"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-125 acceptance criterion 2 (MOB-3 delta sync): "the choice between timestamp
  # and monotonic cursor is stated in the moduledoc with its reasoning, and clock
  # skew is addressed explicitly." Per this run's own task instructions this is a
  # doc check, not a behavioural test -- delta/2's actual query behaviour (AC1,
  # AC3, AC4) is covered in test/letflow/definitions/store_test.exs, which needs a
  # real tenant schema; this is the pure doc-content half, same convention as
  # every other moduledoc-content block in this file.
  # ---------------------------------------------------------------------------------

  describe "moduledoc -- AC2: delta/2's cursor-choice reasoning and clock-skew treatment are stated explicitly (REQ-125)" do
    test "states since is a monotonically increasing integer, never a wall-clock timestamp" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "monotonically increasing integer",
             "moduledoc does not state since is a monotonically increasing integer"

      assert doc =~ "never a wall-clock timestamp",
             "moduledoc does not state since is never a wall-clock timestamp"
    end

    test "addresses clock skew explicitly as the failure mode this endpoint runs under" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "Clock skew is exactly the failure mode this endpoint runs under",
             "moduledoc does not address clock skew explicitly"

      assert doc =~ "device clock's drift, timezone misconfiguration, or leap-second smear",
             "moduledoc does not name the concrete clock-skew failure modes"

      assert doc =~ "has no notion of \"now\" on either side",
             "moduledoc does not state the monotonic counter's independence from wall-clock time"
    end

    test "states the counter is server-assigned inside the same transaction as the row mutation it sequences" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "server-assigned and bumped inside the same transaction",
             "moduledoc does not state the counter is server-assigned and bumped in the same transaction"
    end

    test "states a since that predates retained history is not a distinguishable error state, and why" do
      doc = normalized_moduledoc(Definitions)

      assert doc =~ "predates retained history",
             "moduledoc does not address the since-predates-history case"

      assert doc =~ "has no expiry and no pruning",
             "moduledoc does not state the counter has no expiry and no pruning"

      assert doc =~ "give me full history",
             "moduledoc does not state since: nil/0 means full history"
    end
  end
end
