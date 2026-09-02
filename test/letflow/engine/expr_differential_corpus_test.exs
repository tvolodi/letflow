defmodule Letflow.Engine.ExprDifferentialCorpusTest do
  @moduledoc """
  Regression/golden-value port of R-Co's `tests/differential/corpus/conditions_v1.json`
  (15 entries) into an ExUnit suite for `Letflow.Engine.Expr` (REQ-209,
  `lib/letflow/design/req209-expr-differential-corpus-regression.md`).

  ## This is NOT a differential test

  R-Co's `tests/differential/differential_test.zig` diffed a vendored CEL library
  (`vendor/cel`) against R-Co's own hand-written replacement (`src/expr`) as R-Co's
  EXP-102 cutover gate: once that suite went green, `vendor/cel` was retired entirely
  and `src/expr` became the sole implementation. `Letflow.Engine.Expr` is a direct
  Elixir port of R-Co's **post-cutover** `src/expr` grammar only -- Letflow never had a
  second condition-evaluator implementation, so there is nothing left for this suite to
  diff `Letflow.Engine.Expr` against. Instead, each corpus entry's `condition_text` is
  run through `Letflow.Engine.Expr`'s own evaluation path and the result is asserted
  against the corpus's own recorded `expected_result` as a fixed golden value.

  See `Letflow.Engine.Expr`'s own moduledoc section "R-Co's `src/expr` is not a CEL
  implementation (AC11)" for the same cutover history from the implementation module's
  own side -- it is the authoritative source for why `@unsupported_call_markers` (and
  this suite's forward-compatible EXPECTED_UNSUPPORTED branch, see below) exist at all.

  ## Evaluation path under test

  Each entry's `condition_text` (CEL surface syntax) is run through
  `Letflow.Engine.Expr.evaluate_condition/2` -- the single composed entry point that
  chains `translate_cel_to_expr/1` -> `parse/1` -> `eval/2` and collapses every outcome
  to a plain boolean. This is the exact same path
  `Letflow.Engine.Transition.dispatch_exclusive_gateway/4` calls per edge in production,
  so this suite exercises production behaviour, not a hand-assembled substitute chain.

  ## Corpus version, count, and disposition

  `conditions_v1.json`, 15 entries (`gw-001` .. `gw-015`). All 15 are classified
  EVALUATED against `Letflow.Engine.Expr`'s supported grammar as of this port (design
  doc §4) -- zero EXPECTED_UNSUPPORTED entries in this corpus version. The per-entry
  loop below still carries an EXPECTED_UNSUPPORTED branch as forward-compatible
  scaffolding: a future `conditions_v2.json` port could legitimately introduce a
  corpus entry using a construct `Letflow.Engine.Expr` rejects
  (`unsupported_cel_feature?/1`, the bare `in` operator, or a bare `?`), and this
  structure must not silently assume 100% EVALUATED forever. `evaluate_condition/2`'s
  own `@spec` guarantees a bare `boolean()` return, never `{:error, _}` -- so an
  EXPECTED_UNSUPPORTED entry is asserted identically to an EVALUATED entry (`actual ==
  expected_result`), the difference being purely one of classification/comment, not
  assertion shape.

  ## Purity and async

  `async: true` is safe on the same grounds `expr_test.exs` already establishes:
  `Letflow.Engine.Expr` is a pure module (see its own moduledoc's "Purity and
  determinism (AC8)" section) with no `Letflow.Repo`/`Ecto.Sandbox` dependency.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Expr

  @corpus_path "test/fixtures/simulation/differential_corpus.json"

  @corpus @corpus_path |> File.read!() |> Jason.decode!()

  # Fixed, design-time classification (design doc §4), keyed by condition_id --
  # NOT re-derived at test-run time by reimplementing Expr's private
  # unsupported-feature detection logic in test code. Any condition_id absent from
  # this map is EVALUATED by default; a future conditions_v2.json port that
  # introduces a genuinely unsupported construct would add its condition_id here
  # (see design doc OQ-1). This corpus version (conditions_v1.json) lists none, so
  # the map is empty -- kept as forward-compatible scaffolding, not dead code, since
  # the lookup (and both branches below) still run for every entry.
  @expected_unsupported_ids MapSet.new([])

  test "every differential_corpus.json entry evaluates to its recorded expected_result via Expr.evaluate_condition/2" do
    assert length(@corpus) == 15

    {evaluated_count, expected_unsupported_count} =
      Enum.reduce(@corpus, {0, 0}, fn entry, {evaluated_acc, unsupported_acc} ->
        condition_id = Map.fetch!(entry, "condition_id")
        condition_text = Map.fetch!(entry, "condition_text")
        context = Map.fetch!(entry, "context")
        expected_result = Map.fetch!(entry, "expected_result")

        actual = Expr.evaluate_condition(condition_text, context)

        disposition =
          if MapSet.member?(@expected_unsupported_ids, condition_id) do
            :expected_unsupported
          else
            :evaluated
          end

        case disposition do
          :evaluated ->
            assert actual == expected_result,
                   "corpus entry #{condition_id} (#{inspect(condition_text)}): expected #{inspect(expected_result)}, got #{inspect(actual)}"

            {evaluated_acc + 1, unsupported_acc}

          :expected_unsupported ->
            # evaluate_condition/2's @spec guarantees a bare boolean(), never
            # {:error, _} -- an unsupported CEL feature folds to `false` through the
            # same "one catch-false rule" every other failure stage folds to. This
            # branch asserts that guaranteed-false outcome, not a computed result.
            assert actual == false,
                   "corpus entry #{condition_id} (#{inspect(condition_text)}): expected translation rejection (false), got #{inspect(actual)}"

            {evaluated_acc, unsupported_acc + 1}
        end
      end)

    assert evaluated_count == 15
    assert expected_unsupported_count == 0
    assert evaluated_count + expected_unsupported_count == 15
  end
end
