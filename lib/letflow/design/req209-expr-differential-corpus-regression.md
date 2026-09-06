# REQ-209 — Condition-Evaluation Corpus Regression Port

**Status:** design (Step 1, WF-02, run `WF02-REQ209-20260902`)
**Owner module(s) under design:** `test/fixtures/simulation/differential_corpus.json`,
`test/letflow/engine/expr_differential_corpus_test.exs`
**Implements:** REQ-209 (S7)
**Depends on:** `lib/letflow/engine/expr.ex` (REQ-050, extended by REQ-197/REQ-198) —
read-only dependency, no changes to that module in scope.

---

## 1. Why this is a regression port, not a differential port

PROVENANCE (historical, not current decision authority):
R-Co's `tests/differential/differential_test.zig` (476+ lines, read in full at
`c:\Users\tvolo\dev\ai-dala\R-Co\tests\differential\differential_test.zig`) evaluated
every corpus entry's `condition_text` through **two** independent implementations —
`vendor/cel` (a vendored CEL library) and `src/expr` (R-Co's own hand-written
replacement) — and asserted the two agreed. That was R-Co's own EXP-102 cutover gate:
once green, `vendor/cel` was retired entirely and `src/expr` became the sole
implementation. `lib/letflow/engine/expr.ex`'s own moduledoc states this explicitly
under its "R-Co's `src/expr` is not a CEL implementation (AC11)" section: R-Co "cut
over *from* a vendored CEL (`vendor/cel`) *to* `src/expr`, retiring CEL entirely."

Letflow never had two condition-evaluator implementations. `lib/letflow/engine/expr.ex`
is a direct Elixir port of R-Co's **post-cutover** `src/expr` grammar only — there is no
Letflow equivalent of `vendor/cel` and none is being built here. So there is nothing for
this requirement to diff `expr.ex` against. The corpus's only remaining value for
Letflow is as a **golden-value regression suite**: each entry's `condition_text` (CEL
surface syntax) is run through `expr.ex`'s own two-stage evaluation path —
`translate_cel_to_expr/1` (moduledoc, `expr.ex` L193-242) then the parse+eval path
`evaluate_condition/2` composes (`expr.ex` L1461-1479) — and the result is asserted
against the corpus's own recorded `expected_result`. This is the same two-stage path
`Letflow.Engine.Transition`'s `dispatch_exclusive_gateway/4` uses in production (per
`evaluate_condition/2`'s own moduledoc: "The composed, always-boolean, never-`{:error,
_}` entry point gateway dispatch calls per edge").

This doc's own moduledoc-content section (§5) restates this distinction for the test
module itself, since a future reader who sees `tests/differential/` named in the stage
doc's scope line could otherwise assume a second Elixir evaluator needs building.

---

## 2. Corpus entry count — independently re-confirmed

Read `c:\Users\tvolo\dev\ai-dala\R-Co\tests\differential\corpus\conditions_v1.json`
directly this session (not trusted from the requirement text's "15" figure). It is a
JSON array. Counted the `condition_id` fields by direct enumeration of the array
contents: **15 entries**, `condition_id` values `gw-001` through `gw-015` inclusive, no
gaps, no duplicates. This matches the requirement text's stated count, independently
re-derived rather than inherited.

---

## 3. Grammar boundary established from `expr.ex` (read in full this session)

Read `lib/letflow/engine/expr.ex` in full (1480 lines) — moduledoc, `@unsupported_call_markers`
(L173-191), `translate_cel_to_expr/1` (L193-242), `unsupported_cel_feature?/1` (L266-271),
`contains_in_operator?/1` (L275-278), `contains_bare_question_mark?/1` (L282-285),
`parse/1`+recursive-descent grammar (L297-324, L954-1103), `eval/2` (L1105-1226),
`evaluate_condition/2` (L1461-1479).

**Supported grammar** (what an EVALUATED entry may use):
- Variable references: `variables.<dotted.path>`, stripped to `{:var, path}` by
  `strip_variables_prefix/1`.
- The 6 comparison operators: `==`, `!=`, `<`, `<=`, `>`, `>=` (`cmp_op` tokens).
- Boolean `and`/`or`/`not` — CEL surface `&&`, `||`, `!` (not immediately followed by
  `=`) are rewritten to these by `translate_cel_to_expr/1`'s rules 2-4.
- Literals: numbers (int/float), strings (single- or double-quoted), `true`/`false`,
  `null`.
- Binary arithmetic `+ - * / %` and unary `-` (REQ-197).
- The 8 REQ-198 builtins: `length`, `lower`, `upper`, `trim`, `contains`, `startsWith`,
  `endsWith`, `coalesce` (none of the 15 corpus entries use any of these — noted for
  completeness, not because it is exercised).
- Parenthesized grouping.

**Rejected constructs** (`unsupported_cel_feature?/1`, checked against the ORIGINAL,
untranslated `cel_condition` before any rewrite rule runs — any one triggers
`{:error, :unsupported_cel_feature}` from `translate_cel_to_expr/1`, which
`evaluate_condition/2` then folds into a plain `false` return, never an exception and
never a distinguishable error tuple at that entry point):
- Any `@unsupported_call_markers` substring present anywhere in the raw condition text:
  `has(`, `matches(`, `all(`, `exists_one(`, `exists(`, `int(`, `uint(`, `double(`,
  `string(`, `bool(`, `bytes(`, `duration(`, `timestamp(`, `size(`, `map(`, `map{`,
  `filter(` — this one marker list covers CEL macros, type-conversion functions, and
  collection functions in a single pass (design doc for REQ-050 §4.4).
- The bare `in` membership operator, detected as a standalone word outside string
  literals (`contains_in_operator?/1`).
- A bare `?` outside string-literal spans, signalling the ternary operator
  (`contains_bare_question_mark?/1`).

**Two-stage evaluation path under test** (mirrors `evaluate_condition/2`'s own
composition, which is what this test suite calls — see §4 below): `translate_cel_to_expr/1`
→ `parse/1` → `eval/2`, collapsed to a single boolean by `evaluate_condition/2` itself
(`{:ok, true}` from `eval/2` ⇒ `true`; every other outcome at every stage — translation
error, unsupported-feature error, parse error, eval error, or a non-boolean `{:ok, _}` —
⇒ `false`, per `evaluate_condition/2`'s own "one catch-false rule, not several").

---

## 4. Per-entry classification (all 15, against the grammar boundary in §3)

Every `condition_text` string below was checked against `@unsupported_call_markers`,
`contains_in_operator?/1`'s pattern, and `contains_bare_question_mark?/1`'s pattern.
**None of the 15 entries contains any rejected construct.** Each uses only:
`variables.<path>` references, the comparators `>`, `>=`, `<=`, `<`, `==`, the boolean
connectives `&&`/`||`/`!` (all in-grammar via `translate_cel_to_expr/1`'s rewrite
rules), numeric/string/boolean literals, and parenthesized grouping — all within §3's
supported grammar.

| `condition_id` | `condition_text` | Disposition | Grammar elements exercised |
|---|---|---|---|
| `gw-001` | `variables.order_total > 1000` | EVALUATED | var ref, `>`, int literal |
| `gw-002` | `variables.order_total > 1000` | EVALUATED | var ref, `>`, int literal |
| `gw-003` | `variables.customer_status == "VIP"` | EVALUATED | var ref, `==`, string literal |
| `gw-004` | `variables.customer_status == "VIP"` | EVALUATED | var ref, `==`, string literal |
| `gw-005` | `variables.amount >= 100 && variables.amount <= 1000` | EVALUATED | var ref, `>=`, `<=`, `&&`→`and` |
| `gw-006` | `variables.amount >= 100 && variables.amount <= 1000` | EVALUATED | var ref, `>=`, `<=`, `&&`→`and` |
| `gw-007` | `variables.is_urgent == true` | EVALUATED | var ref, `==`, bool literal |
| `gw-008` | `variables.is_urgent == true` | EVALUATED | var ref, `==`, bool literal |
| `gw-009` | `variables.risk_score > 50 \|\| variables.is_flagged == true` | EVALUATED | var ref, `>`, `==`, `\|\|`→`or` |
| `gw-010` | `variables.risk_score > 50 \|\| variables.is_flagged == true` | EVALUATED | var ref, `>`, `==`, `\|\|`→`or` |
| `gw-011` | `!(variables.skip_review == true)` | EVALUATED | unary `!`→`not`, parens, `==`, bool literal |
| `gw-012` | `!(variables.skip_review == true)` | EVALUATED | unary `!`→`not`, parens, `==`, bool literal |
| `gw-013` | `variables.count < 10` | EVALUATED | var ref, `<`, int literal |
| `gw-014` | `variables.priority == 1` | EVALUATED | var ref, `==`, int literal |
| `gw-015` | `(variables.a > 10) && (variables.b < 20)` | EVALUATED | parens, `>`, `<`, `&&`→`and` |

**Result: 15 EVALUATED, 0 EXPECTED_UNSUPPORTED.** No corpus entry uses any construct
`@unsupported_call_markers`, `contains_in_operator?/1`, or `contains_bare_question_mark?/1`
rejects. This is a genuine finding, not an assumption — the corpus (R-Co's own
EXP-102 gate fixture set) happens to exercise only the comparator/boolean/literal
subset both `vendor/cel` and `src/expr` already agreed on at cutover time, so it
carries no CEL-macro/type-conversion/collection/`in`/ternary constructs at all. The
implementing test module (§6) must still carry the EXPECTED_UNSUPPORTED branch in its
per-entry dispatch logic (not omit it), because the corpus is versioned
(`conditions_v1.json`) and a future `conditions_v2.json` port could legitimately
introduce such an entry — the test structure must not silently assume 100% EVALUATED
forever. See §8 Open Questions for what a future EXPECTED_UNSUPPORTED entry's disposition
would look like mechanically, since none exists in this corpus to model it on directly.

---

## 5. `test/fixtures/simulation/differential_corpus.json` — exact fixture shape

**Location convention:** `test/fixtures/simulation/` already exists (used by
REQ-205/206/207/208's scenario fixtures) and already carries one co-located shape-check
test, `test/fixtures/simulation/fixture_shape_test.exs` — this fixture and its
schema-shape assertions follow that established sibling pattern, not a new one.

**Top-level shape:** a JSON array of exactly 15 objects, each object shaped identically
to its R-Co source entry in `conditions_v1.json`, field-for-field:

```jsonc
[
  {
    "condition_id": "gw-001",                    // string, verbatim from R-Co
    "source_definition_id": "aaaaaaaa-...",       // string (UUID-shaped), inert metadata
    "source_definition_version": 1,               // integer, inert metadata
    "source_gateway_node_id": "gateway_approval_check", // string, inert metadata
    "condition_text": "variables.order_total > 1000",   // string, CEL surface syntax, verbatim
    "context": { "order_total": 1500 },           // object, verbatim -- becomes `variables` at eval time
    "expected_result": true                        // boolean, verbatim -- the golden value
  },
  // ... 14 more entries, gw-002 .. gw-015, in source file order
]
```

**Field-by-field provenance and treatment:**

| Field | Type | Treatment |
|---|---|---|
| `condition_id` | `String.t()` | Preserved byte-for-byte from R-Co source. Used as the test-loop's per-entry label (ExUnit `describe`/failure-message context), never re-derived or renumbered. |
| `source_definition_id` | `String.t()` | R-Co-internal cross-reference (a definition-graph UUID with no Letflow equivalent). Carried as **inert metadata** — copied verbatim, never resolved against any Letflow schema, never asserted on by the test. |
| `source_definition_version` | `integer()` | Same treatment as `source_definition_id` — inert metadata, copied verbatim, not resolved or asserted on. |
| `source_gateway_node_id` | `String.t()` | Same treatment — inert metadata, copied verbatim, not resolved or asserted on. |
| `condition_text` | `String.t()` | Preserved byte-for-byte. This is the CEL-syntax input fed to `Expr.translate_cel_to_expr/1`. |
| `context` | `map()` (JSON object, arbitrary depth 1 in this corpus — every entry's `context` here is a flat single-level map of scalar values) | Preserved byte-for-byte. Bound as the `variables` argument to `Expr.eval/2` (via `Expr.evaluate_condition/2`'s second argument) — i.e. `context` IS `variables`, no key renaming or wrapping. |
| `expected_result` | `boolean()` | Preserved byte-for-byte. The golden value every EVALUATED entry's actual result is asserted to equal. |

**No entry is dropped, renumbered, or has its assertion loosened.** All 15 objects from
`conditions_v1.json` appear in `differential_corpus.json` in the same order, with the
same 7 fields, same key names, same value types and same values as the R-Co source —
this is a verbatim structural port of the array, not a re-authored fixture.

**JSON parsing on the Letflow side:** loaded via `Jason.decode!/1` (or the project's
established JSON-fixture-loading convention — grep `test/fixtures/simulation/fixture_shape_test.exs`
for the exact call the sibling fixture test already uses, and match it) into a list of
maps with **string keys** (`"condition_id"`, `"condition_text"`, `"context"`,
`"expected_result"`, etc. — standard `Jason.decode!/1` output, no atom-key mode). The
nested `"context"` map, once decoded, also has string keys — e.g. `%{"order_total" =>
1500}` — which is exactly the map shape `Expr.eval/2`'s `{:var, path}` resolution
(`resolve_var/3`, `expr.ex` L1446-1459) already expects, since `path` segments are
strings produced by `String.split(ident, ".")` and `Map.fetch/2` is called with those
string keys directly. No key-atomization step is needed or wanted.

---

## 6. `test/letflow/engine/expr_differential_corpus_test.exs` — test structure

**One property-style test, one loop over the 15 fixture entries — not 15 hand-written
test bodies.** Structure (signatures/shapes only, no implementation bodies per this
step's own constraint):

```
defmodule Letflow.Engine.ExprDifferentialCorpusTest do
  use ExUnit.Case, async: true
  # async: true is safe here on the same grounds expr_test.exs already
  # establishes: Expr is a pure module (moduledoc's own "Purity and
  # determinism (AC8)" section), no Letflow.Repo/Ecto.Sandbox dependency.

  alias Letflow.Engine.Expr

  @corpus_path "test/fixtures/simulation/differential_corpus.json"
```

**Fixture loading — module-level, once, not per-test:**

```
@spec load_corpus() :: [map()]
# Reads @corpus_path, Jason.decode!/1, returns the list of 15 fixture maps
# (string-keyed, per §5). Called once via a module attribute
# (`@corpus load_corpus()`) so all 15 entries are available to a single
# ExUnit test body's Enum.each/2 loop -- not re-read from disk per entry.
```

**The one test — a single `test "..."` block containing one `Enum.each/2` (or
`for entry <- @corpus do ... end`) loop over all 15 entries, not 15 separate `test`
macros:**

```
test "every differential_corpus.json entry evaluates to its recorded expected_result
      via Expr.evaluate_condition/2 (the same translate_cel_to_expr/1 -> parse/1 ->
      eval/2 path Letflow.Engine.Transition.dispatch_exclusive_gateway/4 uses)" do
  Enum.each(@corpus, fn entry ->
    # For each entry (labelled in every assertion failure message by its
    # condition_id, so a failing entry is immediately identifiable without
    # re-running in isolation):
    #
    # 1. actual = Expr.evaluate_condition(entry["condition_text"], entry["context"])
    #    -- calls the SAME composed entry point production dispatch uses
    #    (evaluate_condition/2, expr.ex L1461-1479), not a hand-assembled
    #    translate+parse+eval chain, so this test exercises exactly what
    #    Transition.dispatch_exclusive_gateway/4 exercises.
    #
    # 2. Per this design doc's §4 classification table (all 15 entries are
    #    EVALUATED -- 0 EXPECTED_UNSUPPORTED in this corpus version):
    #    assert actual == entry["expected_result"], labelled by
    #    entry["condition_id"] in the assertion/failure message (e.g. via
    #    a custom failure message string interpolating condition_id, OR
    #    ExUnit.Assertions.flunk/1 with the id embedded, on mismatch).
    #
    # 3. The classification (EVALUATED vs EXPECTED_UNSUPPORTED) is NOT
    #    re-derived at test-run time by re-implementing
    #    unsupported_cel_feature?/1's detection logic inside the test --
    #    that would duplicate expr.ex's own private logic in test code.
    #    Instead each fixture entry's disposition is a FIXED, DESIGN-TIME
    #    classification (this doc's §4 table), and the test's job is only
    #    to apply the correct assertion shape per entry:
    #      - EVALUATED entry -> assert actual == entry["expected_result"]
    #        (actual is always a plain boolean, since evaluate_condition/2
    #        never returns anything else -- @spec-guaranteed).
    #      - EXPECTED_UNSUPPORTED entry (none in this corpus version, but
    #        the branch must exist for forward-compatibility with a future
    #        conditions_v2.json corpus) -> assert actual == false, which is
    #        evaluate_condition/2's own guaranteed "one catch-false rule"
    #        outcome for an unsupported-feature translation error -- this
    #        is NOT a separate error-tuple assertion, because
    #        evaluate_condition/2's @spec return type is bare boolean(),
    #        never {:error, _}. An EXPECTED_UNSUPPORTED entry is therefore
    #        asserted the identical way a "condition correctly evaluates
    #        to false" EVALUATED entry would be, EXCEPT the assertion
    #        comment/label must state it is asserting a REJECTION (false
    #        because translate_cel_to_expr/1 could not translate it), not
    #        a computed false result -- see §8 OQ-1 for how this
    #        disposition is carried in fixture data once a real
    #        EXPECTED_UNSUPPORTED entry exists.
  end)
end
```

**Why one test, not `for entry <- corpus, do: test "#{entry[...]}" do ... end`
macro-generated tests:** the task's own acceptance criteria require "a single
property-style ExUnit test's structure (one loop over the 15 entries, not 15
hand-written tests)" — a macro-generated-per-entry `test` block would produce 15
distinct ExUnit test cases (technically satisfying "not 15 hand-written" only in the
sense that they're generated, not authored token-by-token, but violating the
"single...test" structural requirement, and diverging from `process_instance_test.exs`'s
established property-test convention WF-02 Step 3 points to, which uses one test body
with an internal loop/generator, not compile-time test-case expansion). This design
specifies the single-test-body-internal-loop shape unambiguously.

**No StreamData/generative property testing here.** "Property-style" in this
requirement's and WF-02's usage means "one test, looped over a data table" (the
existing `process_instance_test.exs` convention), not StreamData's generator-based
property testing — the corpus is a fixed, finite, 15-entry golden-value table, not a
generated input space. Confirm this reading against `process_instance_test.exs`'s
actual test bodies at implementation time if any ambiguity remains (this design
resolves it explicitly here so ELIXIR-DEV does not have to guess).

---

## 7. Moduledoc content for `expr_differential_corpus_test.exs`

The test module's `@moduledoc` must state, verbatim in substance (not necessarily
verbatim in wording, but covering every point below — this is prose content, not a
literal string to paste):

1. **What this module is:** a regression/golden-value port of R-Co's
   `tests/differential/corpus/conditions_v1.json` (15 entries) into an ExUnit suite for
   `Letflow.Engine.Expr`.
2. PROVENANCE (historical, not current decision authority):
   **Explicitly state this is NOT a differential test**, and name why: R-Co's
   `tests/differential/differential_test.zig` diffed `vendor/cel` against `src/expr` as
   R-Co's own EXP-102 cutover gate (both R-Co source files cited by their repo-relative
   paths: `tests/differential/corpus/conditions_v1.json`,
   `tests/differential/differential_test.zig`). Letflow's `Letflow.Engine.Expr` is a
   direct port of R-Co's **post-cutover** `src/expr` only — there is no second
   implementation in Letflow to diff against, so this suite's corpus entries are
   instead asserted as fixed golden values.
3. **Cite `expr.ex`'s own EXP-102/AC11 section by name** — point at
   `lib/letflow/engine/expr.ex`'s moduledoc section "R-Co's `src/expr` is not a CEL
   implementation (AC11)", which states the same cutover history from the
   implementation module's own side and is the authoritative source for why
   `@unsupported_call_markers` exists at all.
4. **State the two-stage evaluation path under test:** `translate_cel_to_expr/1` then
   `parse/1`+`eval/2`, exercised via the single composed `evaluate_condition/2` entry
   point — the same path `Letflow.Engine.Transition.dispatch_exclusive_gateway/4` uses
   in production.
5. **State the corpus version and count:** `conditions_v1.json`, 15 entries, all 15
   classified EVALUATED against `expr.ex`'s supported grammar as of this port (per §4
   above) — 0 EXPECTED_UNSUPPORTED in this version, with a note that a future corpus
   version could introduce one and the test structure accommodates that without
   modification (per §6's forward-compatible branch).
6. **Purity/async note**, matching `expr_test.exs`'s own precedent: `async: true` is
   safe because `Letflow.Engine.Expr` is a pure module with no `Letflow.Repo`/
   `Ecto.Sandbox` dependency.

---

## 8. Open questions (not silently resolved)

**OQ-1 — Fixture-level disposition field for a future EXPECTED_UNSUPPORTED entry.**
This corpus version (`conditions_v1.json`) has zero EXPECTED_UNSUPPORTED entries, so
§5's fixture shape (verbatim port of the R-Co 7-field object) has no field to record a
per-entry disposition — the design doc's own §4 table is the only place that
classification currently lives, external to the fixture JSON. If a future
`conditions_v2.json` (or any later corpus revision) introduces a genuinely unsupported
construct, ELIXIR-DEV/TEST-DESIGNER will need to decide whether to (a) add an inert
extra field to the fixture JSON itself (e.g. `"disposition": "evaluated" |
"expected_unsupported"`, breaking byte-for-byte verbatim-port purity for that future
version only) or (b) keep the classification external, e.g. as a second small JSON/YAML
sidecar keyed by `condition_id`, or a hardcoded list in the test module. This design
does not resolve that choice now, since it is moot for the 15 entries actually in
scope — flagging it explicitly rather than guessing, per this step's own constraint
against silently resolving open questions.

**OQ-2 — `context` object depth.** All 15 corpus entries' `context` objects are flat,
single-level maps of scalar values (e.g. `{"order_total": 1500}`), so `Expr.eval/2`'s
`resolve_var/3` is only ever exercised with single-segment `path` lists in this corpus
(no `variables.order.total`-shaped dotted access is exercised, even though `expr.ex`'s
grammar supports it). This design does not add a nested-context entry, since none
exists in the R-Co source and REQ-209's scope is a verbatim port — noted so nobody
mistakes the absence of dotted-path coverage here for a gap in `expr.ex` itself
(`expr_test.exs`, REQ-050's own suite, is where dotted-path coverage would belong if
it's missing there — out of scope for this requirement to check or add).

**OQ-3 — Exact JSON-loading call.** §5 states the fixture is loaded via `Jason.decode!/1`
"or the project's established JSON-fixture-loading convention," deferring to whatever
`test/fixtures/simulation/fixture_shape_test.exs` already uses for consistency, rather
than asserting a specific call this design doc did not itself verify byte-for-byte
against that file's implementation. ELIXIR-DEV must grep that file at implementation
time and match its exact loading mechanism rather than introducing a second convention.
