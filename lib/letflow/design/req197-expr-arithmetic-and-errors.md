# Design: REQ-197 — `expr.ex` arithmetic, unary negation, and a structured parse-error surface

**Requirement:** REQ-197 (stage S6), extends `lib/letflow/engine/expr.ex` (REQ-050, S3, done;
audited by REQ-111, S3, done). Depended on by REQ-198 (the 8 pure string/coalesce builtins).
**Owner (implementer):** ELIXIR-DEV.
**This document produces:** the extended `ast()` type (5 new node shapes), the extended
tokenizer/parser (new operator tokens, 2 new precedence levels), the extended `eval/2` arithmetic
semantics, a new position-tracking internal token/error representation, a new `parse_strict/1`
public entry point returning a structured `parse_failure()`, and the moduledoc text this
requirement's acceptance criteria require. Signatures and type shapes only — every fenced block
below is a `@type`/`@spec` declaration or a plain-English/BNF-pseudocode algorithm description,
never a working function body (no `def ... do ... end` anywhere in this document).

## 0. Sources read for this design, and the R-Co access gap (OPEN — inherited from REQ-050 §0)

- PROVENANCE (historical, not current decision authority):
  This handoff's `context.requirement_text` for REQ-197 (queue task 370, GH#716), read in full —
  quoted verbatim at load-bearing points below rather than paraphrased, since the requirement text
  itself already restates R-Co's `src/expr/ast.zig`, `lexer.zig`, and `error.zig` findings (line
  ranges, whitelist contents, semantics) as its own source of record.
- `lib/letflow/engine/expr.ex` (full, current `main`, REQ-050/111 shipped) — read directly, not
  from the design doc's description of it. Confirmed by direct inspection: current `ast()` (5
  variants: `:lit`, `:var`, `:not`, `:and`, `:or`, `:cmp`), the tokenizer's per-clause byte-pattern
  dispatch (`do_tokenize/2`, `expr.ex:209-268`), the number-literal regex's `-?\d+(\.\d+)?` prefix
  (`expr.ex:234`) which is **dead code today** — see §2.4 — the recursive-descent parser
  (`parse_or` → `parse_and` → `parse_not` → `parse_cmp` → `parse_operand`, `expr.ex:314-381`), the
  `@unsupported_call_markers` list (`expr.ex:59-77`), and `evaluate_condition/2`'s exact
  `with ... else _ -> false end` composition (`expr.ex:478-487`).
- `lib/letflow/engine/transition.ex` (full, current `main`) — confirmed the only two call sites of
  `Letflow.Engine.Expr` in `lib/`: `evaluate_conditioned_edges/3` (`transition.ex:670-671`) calls
  `Expr.evaluate_condition(edge.condition, variables)` and nothing else; a code comment
  (`transition.ex:654-660`) states explicitly that a malformed condition is folded to `false` by
  `evaluate_condition/2` itself, "there is no separate [error-handling] path" in `transition.ex`.
  This is the exact contract §5 below preserves byte-for-byte.
- `test/letflow/engine/expr_test.exs` (full, current `main`) — confirmed the exact assertions this
  design must not break: `Expr.parse(...)` is asserted against **exact** `{:ok, ast}` tuples in
  several places (e.g. line 144, 161, 166) and against `{:error, {:parse_error, _reason}}` with a
  **wildcard** `_reason` in exactly one place (line 157) — no test pins `parse/1`'s error-reason
  term shape, which is what makes §4's internal restructuring backward-compatible (§4.6).
  `Expr.eval/2` and `Expr.evaluate_condition/2` are also asserted directly in several places;
  none of those assertions touch arithmetic, so none are affected by this requirement's additions.
- `lib/letflow/design/req050-exclusive-gateway-cel.md` (full) — the established conventions this
  design matches: the moduledoc-citation style, the "signatures/types only, no bodies" fencing
  convention (its own §4.1/§4.2/§4.5 use `@type`/`@spec`-only elixir fences plus a separate
  BNF-shaped grammar fence — mirrored exactly in §2/§3 below), and its own §9 "open questions,
  flagged rather than silently resolved" pattern — mirrored in §8 below.
- `lib/letflow/design/req111-...` — **not found under `lib/letflow/design/`** (only
  `req050-exclusive-gateway-cel.md` exists for the S3 CEL work; REQ-111's audit findings are
  folded into req050's own doc, per that doc's §0 banner "AUDITED BY REQ-111 — three behavioural
  divergences found. Read §0.1"). Read req050 §0.1 in full; none of its three divergences
  (all about the `translateCelToExpr`/`hasCelUnsupportedFeatures` boundary) bear on arithmetic,
  unary negation, or the parse-error surface, so none are revisited here.
- `docs/anti-patterns.md` (full) — most relevant entries: the H6 handoff-lint naming rule (a
  free-text report must not be named `step-*` unless it is the `.json` handoff itself — observed
  when preparing this run's step-01b handoff), and the "test helper default argument goes dead"
  entry (not directly applicable here, no test code is written by this role).
- PROVENANCE (historical, not current decision authority):
  **THE GAP, restated honestly (mirrors req050 §0's own framing):** R-Co's actual source tree
  (`src/expr/ast.zig`, `lexer.zig`, `evaluator.zig`, `error.zig`) is **not reachable from this
  sandbox** — confirmed by a filesystem search finding no `R-Co`/`ai-dala` checkout and no
  `*.zig` file anywhere on this host. Every semantic rule below is therefore taken from
  REQ-197's own requirement text (which itself quotes specific R-Co line ranges and behaviours),
  the same posture req050's original design took before REQ-111's live audit — and, like req050,
  this design flags every point where the requirement text under-specifies a concrete detail as
  an **explicit open question** (§8) rather than inventing an answer that could silently diverge
  from R-Co's real `evaluator.zig`. A future ELIXIR-DEV or auditor with real R-Co access should
  resolve §8's items against the actual source before this design's assumptions are trusted as
  ported rather than reasoned.

## 1. Scope recap (from the requirement text, restated for traceability)

PROVENANCE (historical, not current decision authority):
REQ-197 extends `expr.ex` with: (1) binary arithmetic `+ - * / %` and unary negation, at R-Co's
stated precedence; (2) R-Co's exact arithmetic semantics (int/float promotion, by-zero behaviour,
the null-in-comparison-vs-null-in-arithmetic asymmetry); (3) a structured parse-error surface
(line, column, offending token text, message) via a new strict entry point, while
`evaluate_condition/2` keeps collapsing every failure to `false` unchanged (EE-05); (4) explicit,
un-deferred confirmation that the purity contract still holds; (5) an explicit, decided (not
open) disposition on `now()`/`date_add`/`date_diff`. It explicitly excludes REQ-198's 8 string/
coalesce builtins, all CEL macros/collections/ternary/`in`, and any port of `benchmark.zig`.

## 2. Extended `ast()` — 5 new node shapes, R-Co's precedence

```elixir
@type value :: number() | String.t() | boolean() | nil | infinity_marker()

@typedoc """
Sentinel results for float arithmetic outcomes that IEEE 754 represents as
non-finite floats but the BEAM cannot (§4.3) — never produced by a literal
or a variable, only by `eval/2`'s own `:fdiv`/`:fmod` clauses.
"""
@type infinity_marker :: :infinity | :neg_infinity | :nan

@typedoc "The 5 binary arithmetic operators this requirement adds."
@type arith_op :: :add | :sub | :mul | :div | :mod

@type ast ::
        {:lit, value()}
        | {:var, path :: [String.t()]}
        | {:not, ast()}
        | {:and, ast(), ast()}
        | {:or, ast(), ast()}
        | {:cmp, cmp_op(), ast(), ast()}
        | {:arith, arith_op(), ast(), ast()}
        | {:neg, ast()}

@type cmp_op :: :eq | :neq | :lt | :lte | :gt | :gte
```

**Design choice:** one tagged node `{:arith, arith_op(), left, right}` for all 5 binary operators
(rather than 5 separate 2-tuple node tags like `{:add, l, r}`), and a separate `{:neg, ast()}` for
unary negation. This mirrors the existing `{:cmp, cmp_op(), l, r}` shape already in the module
(one tag, an operator atom, two operands) rather than inventing a second convention — `eval/2`
gains one new `eval({:arith, op, l, r}, variables)` clause dispatching internally on `op`, exactly
parallel to the existing `eval({:cmp, op, l, r}, variables)` clause's `op in [...]` guards.
`value()` gains `infinity_marker()` — see §4.3 for why the BEAM cannot represent these as plain
floats and why they must be distinct atoms rather than special float values.

### 2.1 Precedence table — loosest to tightest, per the requirement text verbatim

| Level (loosest first) | Grammar rule | Existing / new |
|---|---|---|
| 1 | `or` | existing |
| 2 | `and` | existing |
| 3 | `not` (prefix, right-recursive) | existing |
| 4 | comparison (`== != < <= > >=`, non-chainable — at most one per expression, unchanged) | existing |
| 5 | `+` `-` (binary, left-associative) | **new** |
| 6 | `*` `/` `%` (binary, left-associative) | **new** |
| 7 | unary `-` (prefix, right-recursive, so `- - x` parses) | **new** |
| 8 | primary (literal, variable, `(` expr `)`) | existing, renamed `parse_operand` → `parse_primary` in this design's call chain (§3.1) |

This is an **insertion**, not a replacement: levels 1–4 keep their existing grammar functions
unchanged in every respect except what they call at their base (`parse_cmp` now calls the new
level-5 function instead of calling `parse_operand` directly — see §3.1's exact call-graph diff).

### 2.2 Example precedence resolutions (traced against the AC that names them)

- `"2 + 3 * 4"` parses as `{:arith, :add, {:lit, 2}, {:arith, :mul, {:lit, 3}, {:lit, 4}}}`,
  evaluating to `14`, not `20` — the AC1/AC2 "expression mixing `+` and `*` groups the `*` first"
  case, with the concrete expected value stated here as this design's own worked example.
- `"1 + 1 == 2"` parses as `{:cmp, :eq, {:arith, :add, {:lit, 1}, {:lit, 1}}, {:lit, 2}}`,
  evaluating to `true` — the AC2 "comparison with arithmetic evaluates the arithmetic first" case.
- `"- - 5"` parses as `{:neg, {:neg, {:lit, 5}}}`, evaluating to `5` — unary negation is
  right-recursive at its own precedence level exactly like the existing `not` handling (§3.1's
  `parse_unary` mirrors `parse_not`'s own recursive-call shape).
- `"3 - 1 - 1"` parses left-associatively as `{:arith, :sub, {:arith, :sub, {:lit, 3}, {:lit, 1}},
  {:lit, 1}}`, evaluating to `1`, not `3` — left-associativity is load-bearing for `-` and `/`
  specifically (right-associating would silently invert subtraction/division results) and is
  called out explicitly since the existing `or`/`and` folding loops (`parse_or_rest`,
  `parse_and_rest`) already establish this same left-associative accumulation pattern this design
  reuses at levels 5/6 (§3.1).

### 2.3 Unary negation is a grammar-level construct, not a lexer-level negative literal

**Explicit finding, stated so ELIXIR-DEV does not have to rediscover it mid-implementation:**
today's tokenizer dispatches to its number-literal clause only when the byte stream *starts* with
an ASCII digit (`expr.ex:229`, `when c in ?0..?9`) — the number regex's own `-?\d+(\.\d+)?`
pattern (`expr.ex:234`) can therefore never actually match a leading `-`, because dispatch never
reaches that regex on a `-`-first input in the first place. This makes the regex's `-?` prefix
dead code under the current dispatch, not a working negative-literal path. Confirmed by reading
`do_tokenize/2`'s full clause list: there is currently no clause at all for a bare `-` byte, so
today `Expr.parse("-5")` fails with `{:error, {:parse_error, {:unexpected_char, "-"}}}` rather than
producing a `-5` literal. This requirement's unary negation is implemented as a **parser-level**
node (`{:neg, ast()}`, §2.1 level 7) built from a **new lexer token** for the `-` character
(§3.2), not by reviving the dead literal-regex prefix. **Decision, stated explicitly rather than
left for ELIXIR-DEV to guess:** the dead `-?` prefix in the number-literal regex may be deleted (it
never fires and deleting it changes no observable behaviour) or left in place (equally inert) —
this design does not mandate either, since neither choice affects any test; ELIXIR-DEV should pick
one and is not required to treat this as an open question requiring sign-off.

## 3. Tokenizer and parser extensions

### 3.1 Parser call-graph diff

Exactly one edge changes in the existing call graph, plus two new levels are inserted between it
and the primary-expression parser:

```
BEFORE (existing, unchanged above this line):
  parse_or -> parse_and -> parse_not -> parse_cmp -> parse_operand

AFTER (this requirement):
  parse_or -> parse_and -> parse_not -> parse_cmp -> parse_additive -> parse_multiplicative
    -> parse_unary -> parse_primary
```

`parse_primary/1` is `parse_operand/1` renamed (same 4 clauses: `(` sub-expr `)`, literal,
variable, and the 2 error clauses for empty/unexpected-token input) — a rename for clarity given
"operand" no longer describes only-ever-a-primary once arithmetic sits between comparison and
primary; ELIXIR-DEV may keep the name `parse_operand/1` instead if preferred, since nothing
external calls it by name (it is a private function in both cases) — **not** an open question,
just a non-binding naming note.

```elixir
@spec parse_cmp([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
# unchanged signature; body now calls parse_additive/1 where it previously called
# parse_operand/1, on both the left operand and (when a cmp_op token follows) the right
# operand -- the non-chainable single-comparison structure is otherwise byte-identical.

@spec parse_additive([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
# level 5: parse_multiplicative/1 for the left operand, then a left-folding loop exactly
# like the existing parse_or_rest/parse_and_rest shape: while the next token is a `+` or
# `-` operator token, consume it, parse_multiplicative/1 the right operand, and fold into
# {:arith, :add, acc, right} or {:arith, :sub, acc, right}, continuing left-associatively.

@spec parse_multiplicative([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
# level 6: parse_unary/1 for the left operand, then the same left-folding loop pattern for
# `*` / `/` / `%` operator tokens, folding into {:arith, :mul | :div | :mod, acc, right}.

@spec parse_unary([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
# level 7: if the next token is a `-` operator token, consume it and recurse into
# parse_unary/1 itself (right-recursive, exactly like the existing parse_not/1 shape at
# expr.ex:344-351) wrapping the result in {:neg, sub}; otherwise delegate straight to
# parse_primary/1 with no token consumed.
```

**Only a `-` token is consulted by `parse_unary/1`.** There is no unary `+` in R-Co's stated
surface (the requirement text names only "+ - * / % and unary negation") and none is added here —
a leading `+5` is therefore a parse error (`{:unexpected_token, {:arith_op, :add}}`, or equivalent,
falling out of `parse_primary/1`'s existing unmatched-token clause with no new code needed), which
is this design's deliberate, stated choice, not an oversight.

### 3.2 New lexer tokens

Five new single-character clauses in `do_tokenize/2`, parallel in shape to the existing 6
comparison-operator clauses (`expr.ex:219-224`) and placed anywhere among the existing
single/double-character dispatch clauses (order among clauses matching disjoint characters is
not observable):

```elixir
# `+` -> {:arith_op, :add}
# `-` -> {:arith_op, :sub}   -- this ONE token feeds BOTH parse_additive/1 (binary `-`)
#                                and parse_unary/1 (unary `-`); which meaning applies is
#                                determined purely by grammar POSITION (§3.1), never by
#                                the lexer -- the lexer only ever emits one token kind for `-`.
# `*` -> {:arith_op, :mul}
# `/` -> {:arith_op, :div}
# `%` -> {:arith_op, :mod}
```

No new whitespace/string/number/identifier tokenizer clauses are needed — arithmetic introduces
no new literal syntax, only new single-character operators, each disjoint from every existing
clause's leading byte (`(`, `)`, `=`, `!`, `<`, `>`, `"`, `'`, digits, letters/`_`, whitespace).

## 4. Arithmetic evaluation semantics

### 4.1 `eval/2`'s new clause (dispatch shape)

```elixir
@spec eval(ast(), variables :: map()) :: {:ok, value()} | {:error, {:eval_error, reason :: term()}}
# new clause, parallel to the existing eval({:cmp, op, l, r}, variables) clauses:
#   eval({:arith, op, l, r}, variables) evaluates l and r (each via the existing `with
#   {:ok, lv} <- eval(l, variables), {:ok, rv} <- eval(r, variables) do ... end` shape
#   already used by every existing binary clause), then dispatches on {op, type(lv), type(rv)}
#   per the semantics table below (§4.2) before producing {:ok, result} or an
#   {:error, {:eval_error, reason}}.
#   eval({:neg, sub}, variables) evaluates sub, then negates per §4.4.
```

### 4.2 Type/promotion/error semantics — decided, matching the requirement text's exact rules

Checked **in this order** for every binary arithmetic node, both operands already evaluated to
`lv`/`rv`:

| Check (in order) | Condition | Result |
|---|---|---|
| 1. Null check | `lv == nil or rv == nil` | `{:error, {:eval_error, {:null_in_arithmetic, op, lv, rv}}}` — **the deliberate asymmetry** (§4.5) |
| 2. Type check | either operand is not `number()` (i.e. is a `String.t()` or `boolean()`) | `{:error, {:eval_error, {:type_mismatch, op, lv, rv}}}` — reusing the exact `:type_mismatch` shape the existing `:not`/`:and`/`:or`/`:cmp` clauses already use, for one consistent error-tag family across the whole module |
| 3. Both integers | `is_integer(lv) and is_integer(rv)` | integer semantics, §4.3 row A |
| 4. Mixed or both float | otherwise (at least one is a float) | **promote**: convert any integer operand to float, then float semantics, §4.3 row B |

Row 4 is the literal "an integer and a float mix by promoting the integer to float" rule; row 3
is the "otherwise stays integer" case the requirement text implies but does not need to state
separately, since "mix" only describes the cross-type case.

### 4.3 Per-operator semantics, integer row (A) and float row (B)

| Operator | Row A (both int) | Row B (float, or int promoted to float) |
|---|---|---|
| `+` `-` `*` | native Elixir integer arithmetic — exact, no overflow handling needed (BEAM integers are arbitrary-precision) | native Elixir float arithmetic (IEEE 754 double, BEAM-native) |
| `/` | **non-zero divisor:** integer result via truncating division (Elixir's `div/2` semantics — truncate toward zero); **zero divisor:** `{:error, {:eval_error, {:division_by_zero, :int, lv, rv}}}` | **any divisor:** `dividend / 0.0` — see the infinity-sentinel rule below; non-zero divisor: native float division |
| `%` | **non-zero divisor:** integer result via `rem/2` semantics (result sign follows the dividend); **zero divisor:** `{:error, {:eval_error, {:modulo_by_zero, :int, lv, rv}}}` | **any divisor:** `{:error, {:eval_error, {:modulo_by_zero, :float, lv, rv}}}` — float modulo is **always** an error per the requirement text ("float modulo is an error"), not only on a zero divisor |

**The IEEE-infinity sentinel rule (float `/`, zero divisor) — a representation gap, stated
explicitly rather than left for ELIXIR-DEV to discover via a crash:** the BEAM's native float
arithmetic operators **raise** `ArithmeticError` rather than returning IEEE 754 infinity/NaN — a
platform constraint absent from R-Co's Zig `f64` arithmetic, which can represent these values
directly. `eval/2`'s float-division clause must therefore **detect a zero float divisor before
calling any native `/` operator** and construct one of `infinity_marker()`'s 3 atom values
directly, never routing through native division for this case:

- Dividend `> 0.0`, divisor `== 0.0` → `{:ok, :infinity}`.
- Dividend `< 0.0`, divisor `== 0.0` → `{:ok, :neg_infinity}`.
- Dividend `== 0.0`, divisor `== 0.0` → `{:ok, :nan}` (true IEEE `0.0/0.0` behaviour).

This 3-way split is this design's own reasoned extension of the requirement text's single
un-signed phrase "float division by zero yields the IEEE infinity" (§8 open question OQ-1 flags
that R-Co's actual signed/NaN behaviour here is not independently verified against source, since
§0's access gap prevents it — the un-signed positive-dividend case is the one the requirement
text and every plausible AC-1 test can be written against without ambiguity).

### 4.4 Unary negation semantics

`{:neg, sub}` evaluates `sub` to `v`, then:

- `v == nil` → `{:error, {:eval_error, {:null_in_arithmetic, :neg, nil}}}` (same asymmetry as
  binary arithmetic — §4.5).
- `v` is a `String.t()` or `boolean()` → `{:error, {:eval_error, {:type_mismatch, :neg, v}}}`.
- `v` is an integer or float → `{:ok, -v}` (native negation; exact for integers, IEEE-negation
  for floats — `-0.0`'s sign bit is not specially handled, matching plain float negation).
- `v` is one of `:infinity` / `:neg_infinity` / `:nan` (only reachable via `-(-1.0/0.0)`-shaped
  nested expressions) → negation flips `:infinity` ↔ `:neg_infinity`; `:nan` negated is `:nan`
  (matching real IEEE 754 NaN negation, which flips an unobservable sign bit only).

### 4.5 The deliberate null asymmetry — comparison vs. arithmetic (REVISED, rework iteration 1)

**Superseded note:** this section's original text (iteration 0, failed CODE-DESIGN-VALIDATOR's
Step 1b gate — see `handoffs/WF02-REQ197-20260830/step-01b-code-design-validator.json`) left
`eval/2`'s ordering-comparison clause (`expr.ex:437-446`) unchanged, reading the requirement's
"null in a comparison propagates (yields null)" as satisfied only at the `evaluate_condition/2`
catch-false boundary. That reading was wrong: `docs/requirements.yaml`'s REQ-197 text states the
asymmetry as a SCOPE instruction to preserve/implement, not an ambiguous aside, and AC5 requires
two tests demonstrating two **different** `eval/2`-level outcomes (a value vs. an error) — under
the superseded reading, both comparison-with-null and arithmetic-with-null produced an
`{:error, {:eval_error, ...}}` tuple, leaving no observable asymmetry to test. This revision makes
`eval/2` itself produce the asymmetric outcomes. No existing test in `test/letflow/engine/
expr_test.exs` pins the old nil-ordering-comparison error behaviour (grepped for `nil`/`null`:
zero matches, confirmed independently by CODE-DESIGN-VALIDATOR), so this is a safe, unconstrained
behavioural change to make.

**This is the single most important semantic rule this requirement carries, called out on its own
per the requirement text's own instruction to make it "explicit and deliberate":**

| Context | `null` operand behaviour |
|---|---|
| Ordering comparison (`{:cmp, op, l, r}` where `op in [:lt, :lte, :gt, :gte]`, existing node, **changed clause**) | **Propagates: `eval/2` returns `{:ok, nil}`.** The existing `is_number(lv) and is_number(rv)` guard (`expr.ex:440`) gains a **new guard clause inserted immediately ahead of it**: if `lv == nil or rv == nil`, return `{:ok, nil}` — checked before the `is_number` guard is ever reached, so a nil operand never falls through to today's `{:error, {:eval_error, {:type_mismatch, op, lv, rv}}}` outcome. This is a genuine, deliberate behavioural change to `expr.ex:437-446`, not merely a re-reading of existing behaviour — stated explicitly so ELIXIR-DEV does not mistake it for a no-op. |
| Equality/inequality (`{:cmp, op, l, r}` where `op in [:eq, :neq]`, existing node, **unchanged**) | Already correct today via plain Elixir `lv == rv` / `lv != rv`: `nil == nil` is `true`, `nil == 5` is `false`, `nil != 5` is `true` — ordinary Elixir equality already "propagates" a null operand into a real (non-error, non-null) boolean result with no code change needed. **Explicit decision, not left ambiguous:** eq/neq needs no new nil-check clause; the new nil-check clause above applies only to the four ordering operators (`< <= > >=`), where a nil operand today reaches the numeric guard and errors, unlike eq/neq which never did. |
| Arithmetic (`{:arith, op, l, r}` and `{:neg, ast()}`, new node, **unchanged from iteration 0**) | **Always an error**, unconditionally, checked **first**, before any type/promotion logic runs (§4.2 row 1 — the null check is check 1 of 4, ahead of the type check and both promotion rows / §4.4's `v == nil` clause, evaluated before the integer/float/type dispatch) — `variables.missing + 1` and `null + 1` both yield `{:error, {:eval_error, {:null_in_arithmetic, ...}}}`, never a value, regardless of the other operand's type. |

**Two worked test cases, matching AC5's own wording ("asserted as two explicit tests") and this
design's corrected `eval/2`-level disposition — concrete enough for TEST-DESIGNER to transcribe
directly:**

1. **Comparison-with-null yields null:** `Expr.eval({:cmp, :lt, {:var, ["amount"]}, {:lit, 100}},
   %{"amount" => nil})` returns `{:ok, nil}` — a real, non-error value, propagated exactly as an
   ordinary Elixir `nil` would propagate through a chain of nil-tolerant operations, matching the
   requirement text's literal "yields null" (not "yields an error that later collapses to
   `false`").
2. **Arithmetic-with-null errors:** `Expr.eval({:arith, :add, {:var, ["amount"]}, {:lit, 1}},
   %{"amount" => nil})` returns `{:error, {:eval_error, {:null_in_arithmetic, :add, nil, 1}}}` —
   never a value, regardless of the other operand.

These two outcomes are now observably different at the `eval/2` level itself (`{:ok, nil}` vs.
`{:error, _}`), which is what makes the asymmetry a real, testable property rather than something
that only exists in prose.

**Consequence for the gateway path:** `evaluate_condition/2`'s own `with {:ok, true} <- eval(ast,
variables) do true else _ -> false end` composition (§5) already treats `{:ok, nil}` as "not
`true`," so it falls through to `else _ -> false` exactly like an error tuple would — this revision
changes **nothing** about `evaluate_condition/2`'s external behaviour (a condition that compares
against a null variable still routes the edge to `false`, same as before), only about what `eval/2`
itself returns internally. This is why §5's "byte-for-byte unchanged" claim for
`evaluate_condition/2`'s own source still holds even though `eval/2`'s comparison clause changes —
the asymmetry is now real and testable at the `eval/2` boundary, but invisible at the
`evaluate_condition/2` boundary, exactly matching AC5's own framing that the two tests are
`eval/2`-level tests, not `evaluate_condition/2`-level ones.

### 4.6 Equality/inequality and ordering involving an `infinity_marker()` result (guard ordering
re-checked against §4.5's revised nil-check branch)

**This design's own necessary extension, since arithmetic results (§4.3) can flow directly into a
comparison node in the same expression (e.g. `"1.0 / 0.0 > 100"`) — not literally stated in the
requirement text, flagged here rather than left for `eval/2`'s existing generic `==`/ordering code
to handle by accident:**

- `:nan` compares as **false** against everything, including another `:nan`, for **every**
  comparison operator (`==`, `!=` included — `:nan != :nan` is `true`, matching real IEEE 754 NaN
  semantics exactly). This requires one new guard clause ahead of the existing generic `lv ==
  rv`/`lv != rv` eq/neq clauses and ahead of the existing `is_number(lv) and is_number(rv)`
  ordering guard (which already correctly rejects `:nan`/`:infinity`/`:neg_infinity` as
  non-numbers today with no change needed — `is_number(:nan)` is `false`) **except** for the eq/neq
  case, where plain `lv == rv` would otherwise wrongly return `true` for `:nan == :nan` (two equal
  atoms) — this one case needs an explicit override.
- `:infinity`/`:neg_infinity` participate in ordering comparisons as the greatest/least possible
  value respectively (`:infinity > n` is `true` for any real number `n` and for `:neg_infinity`;
  `:infinity > :infinity` is `false`; `:neg_infinity < n` is `true` for any real number `n` and for
  `:infinity`). This needs one new ordering-comparison branch ahead of the existing
  `is_number(lv) and is_number(rv)` guard, since these sentinels are atoms, not numbers, and would
  otherwise incorrectly type-mismatch-error out of a comparison that should succeed.
- Equality (`==`/`!=`) between two `:infinity` atoms, or between `:infinity` and a real number,
  needs no special handling beyond the `:nan` override above — plain atom/number `==` already gives
  the right answer (`:infinity == :infinity` is `true`, `:infinity == 5` is `false`).

**Guard ordering re-check (rework iteration 1) — confirms §4.5's new nil-check branch does not
shadow or reorder incorrectly against the `:nan`/infinity-marker branches above:** the ordering-
comparison clause (`< <= > >=`) now has, in order: **(1)** the nil-check from §4.5 — `lv == nil or
rv == nil` → `{:ok, nil}`; **(2)** the `:nan` guard — either operand is `:nan` → `{:ok, false}`;
**(3)** the `:infinity`/`:neg_infinity` ordering branch above; **(4)** the pre-existing
`is_number(lv) and is_number(rv)` guard, unchanged, for the plain-number case; **(5)** the
pre-existing fallback → `{:error, {:eval_error, {:type_mismatch, op, lv, rv}}}` for any remaining
type combination (e.g. a string operand). This ordering is safe: nil, `:nan`, and the infinity
sentinels are three **mutually exclusive** operand shapes (a value is never simultaneously `nil`
and `:nan`), so placing the nil-check first cannot shadow the `:nan`/infinity branches — a `:nan`
or infinity-marker operand always fails the `== nil` test and falls through to clause (2)/(3)
exactly as before this revision, and a `nil` operand always fails the `:nan`/infinity/`is_number`
tests and would have fallen through to the old type-mismatch fallback had clause (1) not been
inserted ahead of it. No clause reordering beyond inserting (1) at the front is needed.

## 5. `evaluate_condition/2` — byte-for-byte unchanged (EE-05's contract)

**No change to this function's source at all.** Its existing composition already delegates
entirely to `translate_cel_to_expr/1`, `parse/1`, and `eval/2` (§5's own moduledoc, `expr.ex:469-
487`) — since none of those three functions' *signatures* or *success/failure tagging convention*
change (only `parse/1`'s and `eval/2`'s *internal* vocabulary of possible reasons grows, and both
still return exactly `{:ok, _}` or `{:error, _}, `never anything else), the existing `with {:ok,
expr_source} <- translate_cel_to_expr(cel_condition), {:ok, ast} <- parse(expr_source), {:ok,
true} <- eval(ast, variables) do true else _ -> false end` body requires zero edits and continues
collapsing every new failure mode this requirement introduces — a division-by-zero eval error, a
null-in-arithmetic eval error, an unrecognized `+`/`-`/`*`/`/`/`%` parse error on malformed
arithmetic syntax — into the same `false` it already produces for every pre-existing failure mode.
This is the literal mechanism by which EE-05's contract stays intact: there is no new branch to
add, because the `else _ -> false` clause is already unconditional over every possible `{:error,
_}` shape from any stage, including shapes that did not exist yet when it was written.

**Verification obligation for ELIXIR-DEV (not a design element, a build-time check named here so
it is not skipped):** after implementation, `test/letflow/engine/expr_test.exs`'s existing
`evaluate_condition/2` assertions must still pass unmodified, and a **new** test (per the
requirement's own AC) must assert that `evaluate_condition/2` given a deliberately malformed
arithmetic expression (e.g. `"variables.amount / "` — trailing operator, incomplete right
operand) returns `false`, not an error tuple and not a raised exception — proving the catch-false
composition really does absorb the new failure classes, not just that the source text is
unchanged.

## 6. The structured parse-error surface — `parse_strict/1`, a new, separate entry point

### 6.1 Why a *new* function rather than changing `parse/1`'s return shape

`parse/1`'s existing `@spec` is `{:ok, ast()} | {:error, {:parse_error, reason :: term()}}`.
Changing what `reason` contains is safe (§0 confirms no test pins its shape beyond a wildcard),
but changing the **outer** tuple shape (e.g. to return a bare map instead of `{:error,
{:parse_error, reason}}}`) would break the one existing test that pattern-matches
`{:error, {:parse_error, _reason}}` (`expr_test.exs:157`) and would be an unannounced,
unnecessary behavioural change to a function `evaluate_condition/2` itself still calls (§5) — the
requirement's own instruction is "Provide **both**: a strict entry point returning the structured
error, and the existing `evaluate_condition/2` behaviour unchanged," which this design reads as
also implying `parse/1` (the function `evaluate_condition/2` composes through) keeps its outer
shape unchanged, since a changed `parse/1` outer shape would itself be an unannounced ripple into
`evaluate_condition/2`'s call graph even though `evaluate_condition/2`'s *own* source stays
literally unedited. `parse/1` therefore keeps its exact current `@spec` and outer tuple shape.
A new sibling function is added instead.

### 6.2 New internal position-tracking token representation

Both `parse/1` and `parse_strict/1` share **one** underlying tokenizer and **one** underlying
recursive-descent grammar implementation (no duplicated parsing logic) — they differ only in how
a failure is packaged for return, at the outermost layer. This requires every token to carry its
source position from now on:

```elixir
@typedoc "One lexed token plus the source position where it started."
@type positioned_token :: %{
        kind: token_kind(),
        value: term(),
        text: String.t(),
        line: pos_integer(),
        column: pos_integer()
      }

@typedoc """
Every distinct token shape this grammar's lexer produces. Value-bearing kinds
(`:lit`, `:var`, `:cmp_op`, `:arith_op`) carry their payload in `positioned_token().value`;
value-less kinds (`:lparen`, `:rparen`, `:and`, `:or`, `:not`) carry `value: nil`.
"""
@type token_kind :: :lparen | :rparen | :cmp_op | :arith_op | :and | :or | :not | :lit | :var
```

`text` is the exact substring the tokenizer consumed to produce this token (e.g. `"=="`, `"42"`,
`"order.status"`, `"-"`) — this is what the requirement's "offending token text" field surfaces
verbatim, not a re-serialization of the parsed value (a `{:lit, "42"}` token's `text` is the
2-character string `"42"`, not `Integer.to_string(42)` recomputed after parsing — the distinction
matters for a malformed numeric literal the tokenizer itself rejects before any value exists).

**Line/column bookkeeping:** the tokenizer's internal accumulator gains two counters (`line`,
starting at `1`, incremented on every consumed `\n`; `column`, starting at `1`, incremented per
consumed byte and reset to `1` immediately after a `\n`), threaded through the same recursive
byte-consuming structure `do_tokenize/2` already has — this is a mechanical addition to an
existing accumulator-passing function, not a new algorithm. Since every gateway condition in
practice is a single line (`Edge.t().condition` is authored as one string field, never observed
multi-line in any existing test fixture), `line` will be `1` for every realistic input, but the
field is still tracked correctly for the general case rather than hardcoded, per the requirement's
own framing that R-Co's `EvalError` declaring line/column and then "every construction site passes
zero" is precisely the defect this requirement must not reproduce.

### 6.3 Internal error record (shared by both entry points, before final packaging)

```elixir
@typedoc """
The one internal error shape every tokenizer/grammar failure site produces internally,
before `parse/1` and `parse_strict/1` each package it differently for their own callers.
"""
@type internal_parse_error :: %{
        reason: parse_error_reason(),
        line: pos_integer(),
        column: pos_integer(),
        token_text: String.t()
      }

@typedoc """
Every distinct failure reason, carried in `internal_parse_error().reason`. The 6 existing
reason shapes (unchanged in name/arity from today's `expr.ex`) plus 0 new ones — arithmetic
introduces no new grammar failure modes beyond "unexpected token"/"unexpected end of input",
which already exist and already fire correctly for a `+`/`-`/`*`/`/`/`%` token appearing
somewhere the grammar does not accept it (e.g. two operators in a row).
"""
@type parse_error_reason ::
        {:invalid_number, text :: String.t()}
        | {:invalid_identifier, text :: String.t()}
        | {:unexpected_char, char :: String.t()}
        | {:unterminated_string, text :: String.t()}
        | {:expected_rparen, found :: term()}
        | :unexpected_end_of_input
        | {:unexpected_token, token :: term()}
        | {:trailing_input, tokens :: [term()]}
```

For `:unexpected_end_of_input` (the grammar ran out of tokens): `line`/`column` are the position
immediately after the last successfully consumed token (or `%{line: 1, column: 1}` if the source
was empty), and `token_text` is `""` — an empty offending-token string is this design's documented
convention for "there was no offending token, only an absence of one," not an omission.

### 6.4 The two public entry points, side by side

```elixir
@spec parse(expr_source :: String.t()) :: {:ok, ast()} | {:error, {:parse_error, reason :: term()}}
# UNCHANGED @spec and outer shape (§6.1). Internally: runs the shared tokenizer+grammar,
# and on failure discards the internal_parse_error()'s line/column/token_text fields,
# returning only {:error, {:parse_error, internal_error.reason}} -- byte-identical to
# today's returned reason terms for every case that existed before this requirement, since
# parse_error_reason() above is the same 6 shapes expr.ex already has (extended by zero).

@typedoc "The structured parse-failure record this requirement's new entry point returns."
@type parse_failure :: %{
        line: pos_integer(),
        column: pos_integer(),
        token_text: String.t(),
        message: String.t()
      }

@spec parse_strict(expr_source :: String.t()) :: {:ok, ast()} | {:error, parse_failure()}
# NEW. Runs the identical shared tokenizer+grammar (same input contract as parse/1: an
# expr-syntax string, i.e. already post-translate_cel_to_expr/1 -- parse_strict/1 does NOT
# take raw CEL syntax, matching parse/1's own existing input contract exactly). On success,
# returns {:ok, ast} -- the identical ast() parse/1 would have returned for the same input.
# On failure, returns {:error, parse_failure()}: line/column/token_text copied straight from
# the internal_parse_error(), and `message` produced by a new pure lookup function (§6.5)
# from `internal_error.reason` alone -- no I/O, no clock, no randomness (§7).
```

### 6.5 `message` field — fixed template per reason, no interpolation beyond the token text

```elixir
@spec describe_parse_error(parse_error_reason()) :: String.t()
# Pure function, one clause per parse_error_reason() variant, returning a fixed English
# sentence, e.g.: :unexpected_end_of_input -> "unexpected end of input"; {:unexpected_token,
# _} -> "unexpected token"; {:expected_rparen, _} -> "expected closing parenthesis";
# {:unterminated_string, _} -> "unterminated string literal"; {:invalid_number, _} ->
# "invalid numeric literal"; {:invalid_identifier, _} -> "invalid identifier";
# {:unexpected_char, _} -> "unexpected character"; {:trailing_input, _} -> "trailing input
# after expression". The offending token's own text is already carried separately in
# parse_failure().token_text (§6.3/§6.4) -- `message` is a fixed category label, not a
# rendered sentence embedding the token text, so this function needs no string formatting
# beyond a case/cond dispatch on the reason shape.
```

### 6.6 The precise behaviour boundary between `parse/1`/`evaluate_condition/2` and `parse_strict/1`

**Stated explicitly, once, so ELIXIR-DEV cannot blur it during implementation:**

1. `evaluate_condition/2`'s call graph (`translate_cel_to_expr/1` → `parse/1` → `eval/2`) **must
   never call `parse_strict/1`, anywhere, directly or indirectly.** The gateway path only ever
   sees `parse/1`'s existing `{:error, {:parse_error, reason}}` shape, which its unconditional
   `else _ -> false` clause already absorbs (§5) — this is what "Do not change what
   `transition.ex` sees" (the requirement text's own words) means concretely.
2. `parse_strict/1` is for **new callers this requirement does not itself add** — the requirement
   text names "validation, authoring, a future editor" as the intended future consumers. This
   design does not wire `parse_strict/1` into any existing call site (`Graph`'s definition-time
   `valid_cel_syntax?/1`, if it exists, is out of scope — not read or touched by this design,
   since REQ-197's scope is `expr.ex` only and no requirement text names that integration).
3. `eval/2` gains **no** analogous "strict" sibling in this requirement — only the parse layer
   gets a structured-error surface, matching the requirement's title ("a structured PARSE-error
   surface") and its AC6, which asserts field-by-field on "a deliberately malformed expression,"
   i.e. a parse-time failure, not an eval-time one. An eval-time structured-error surface (for a
   division-by-zero or null-in-arithmetic error surfaced richly to a future caller) is
   **explicitly out of scope for this requirement** — §8 OQ-3 notes this as a candidate for a
   future requirement if a caller ever needs it, not silently built here.

## 7. Purity contract re-verification (AC8) — exact procedure for ELIXIR-DEV

The moduledoc's existing grep (`expr.ex:29-33`) must still return zero matches after this
requirement's changes. **Concretely, before this requirement's PR is considered done:**

1. Run the exact command already documented in the moduledoc, unmodified:
   `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\.\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex`
2. Confirm it returns **zero lines of output** — quote the actual empty-result invocation (or its
   absence of output) in the PR description, per the requirement's own AC8 wording ("quoted in
   the PR"), not merely a claim that it was run.
3. **Specific new code this check must cover, named so it is not skipped by accident:** the new
   `eval({:arith, ...}, ...)`/`eval({:neg, ...}, ...)` clauses (§4.1), the infinity-sentinel
   construction in the float-division clause (§4.3 — this must **not** be implemented by reaching
   for `:erlang.float_to_binary`'s `:short` options, `:math` module tricks that touch the clock,
   or any timestamp-bearing struct), the position-tracking tokenizer changes (§6.2 — line/column
   counters are pure integer bookkeeping over the input string, never `DateTime.utc_now/0` or any
   wall-clock read for a "when this was parsed" field — `parse_failure()`, §6.4, deliberately has
   **no** timestamp field at all, exactly because one would require a clock read), and
   `describe_parse_error/1` (§6.5 — a pure, argument-only case/cond, no I/O).
4. This is a **grep-level, textual** check, matching the moduledoc's own stated verification
   method exactly (not `mix xref`, not a runtime probe) — consistent with how REQ-050's original
   moduledoc already framed this as "grep/`mix xref`-checkable."

## 8. `now()` / `date_add` / `date_diff` — explicit decision, not left open

**Decision: none of the three is added by this requirement, or by any future requirement, without
first threading an injected evaluation timestamp through `eval/2`'s call signature — reading the
system clock from inside `expr.ex` is permanently ruled out, not deferred pending a future
decision.**

**Reasoning, stated in full per the requirement's own instruction to decide with reasons rather
than leave it open:**

1. PROVENANCE (historical, not current decision authority):
   R-Co's own `evaluator.zig` documents, in its own comment (quoted by the requirement text),
   that `now()` is "inherently impure; all other built-ins are pure." This is not a Letflow
   invention — R-Co's own authors already singled out exactly this one builtin (plus the two that
   depend on it) as the one impure member of an otherwise-pure 11-function whitelist.
2. `expr.ex`'s moduledoc carries a **grep-verified, hard** purity contract (§7) — "Every function
   here is a pure function of its typed arguments alone... Two calls with `==`-equal arguments
   return `==`-equal results, both times." A `now()` implementation reading `DateTime.utc_now/0`
   (or any wall-clock source) would make this statement false for the first time in this module's
   history, and would fail the moduledoc's own documented grep command the moment `DateTime\.` or
   `System\.os_time`/`System\.system_time` appeared in the file.
3. REQ-050's determinism guarantee — the same "two calls, equal arguments, equal results" property
   — is a property `transition.ex`'s gateway dispatch and every future auditor/replay mechanism
   may come to rely on (event-sourced replay of a past instance's condition evaluation, in
   particular, requires exactly this: re-evaluating a historical gateway condition against
   historically-recorded variables must reproduce the historical routing decision bit-for-bit).
   A clock-reading `now()` breaks this the instant it is called from two different wall-clock
   moments, which a replay necessarily does.
4. **If a future requirement genuinely needs clock-dependent evaluation** (e.g. a condition like
   `deadline - now() < 0`), the correct mechanism — decided here, not left as a blank slot — is an
   **injected evaluation timestamp passed in by the caller**, not a clock read inside `expr.ex`:
   `eval/2`'s `variables :: map()` argument (or a new, explicitly-named third argument such as
   `eval_context :: %{now: DateTime.t()}`, whichever a future requirement's own design settles,
   since this requirement adds neither) would carry a value the **caller** (e.g. `transition.ex`,
   which already has access to whatever "current time" concept the engine uses at the moment of
   evaluation) resolves and passes in, keeping `expr.ex` itself a pure function of its arguments —
   preserving the "pure function of its typed arguments alone" property, since a value passed as
   an argument does not violate purity even if a caller's caller sourced it from a clock.
5. **This requirement adds none of this machinery.** `eval/2`'s signature stays exactly
   `eval(ast(), variables :: map())` — no new parameter, no context struct, no `now` field
   anywhere in this design. `now()`, `date_add()`, and `date_diff()` are simply not implemented as
   call-syntax builtins at all yet (call syntax itself does not exist until REQ-198 adds the
   whitelist-checked function-call grammar) — there is nothing partially built here that a future
   requirement must unwind.

The moduledoc (§9) states this disposition in the exact terms the requirement's AC9 asks for:
that `now()` is documented by R-Co's own evaluator as the one impure builtin, that adding it would
break both this module's purity contract and REQ-050's determinism guarantee, and that the
decided disposition is deferral via a future injected-timestamp mechanism, not an open question.

## 9. Moduledoc additions (AC9, AC10, AC11) — content this design specifies verbatim in substance

Three moduledoc passages this requirement's acceptance criteria require, each mapped to the AC
that names it (ELIXIR-DEV writes the actual prose; this design specifies exactly what fact each
passage must state so nothing is left to improvisation):

PROVENANCE (historical, not current decision authority):

| AC | Required moduledoc content |
|---|---|
| AC9 | States that `now()` is not added; that R-Co's own evaluator documents `now()` as the one inherently-impure builtin while every other builtin is pure; that adding it would break both this module's grep-verified purity contract and REQ-050's determinism guarantee; and states the decided disposition (§8: a future injected-evaluation-timestamp mechanism, clock reads permanently ruled out) rather than leaving the builtin's fate open. |
| AC10 | States that `src/expr/benchmark.zig` is deliberately not ported, naming it exactly as the requirement text does: a Zig latency-benchmarking harness (1,000 warm-up plus 10,000 measured iterations against a 10 microsecond target) with no production behaviour — this is a **restatement** of a fact the moduledoc already carries from REQ-050 (`expr.ex:9-11` already lists `benchmark.zig` among the unported files and calls it "a Zig benchmarking harness with no Elixir equivalent"); this requirement's job is to confirm that sentence is still present and still accurate, not to write a new one from scratch. |
| AC11 | States that R-Co's `src/expr` is not a CEL implementation — that EXP-102 cut over *from* a vendored CEL (`vendor/cel`) *to* `src/expr`, retiring CEL — and that `@unsupported_call_markers` (`expr.ex:59-77`) therefore rejects CEL vocabulary (macros, type-conversion functions, collection functions, `in`, the ternary operator) that **neither** R-Co **nor** Letflow implements, rather than describing a Letflow gap against a CEL surface R-Co never had. This is the requirement text's own "CORRECTION" section, restated in the moduledoc as a permanent, load-bearing fact for any future reader of this module (a later contributor tempted to "complete" CEL support against `@unsupported_call_markers` would be acting against a closed EXP-102 decision, not filling a gap). |

**No change to `@unsupported_call_markers` itself (confirmed, not assumed):** arithmetic operators
are single-character tokens, not `name(`-shaped call syntax, and this requirement adds no new
identifier or call form — every one of the 16 existing markers (`expr.ex:60-76`) continues to
match exactly the same inputs it matched before this requirement, confirmed by inspection (§3.2's
5 new tokens are `+`, `-`, `*`, `/`, `%`, none of which is a substring of any existing marker).

## 10. Non-goals — explicit, matching the requirement text's own "NOT IN THIS REQUIREMENT" list

Stated here so CODE-DESIGN-VALIDATOR and ELIXIR-DEV both see the boundary in one place, not
scattered across the requirement text:

- **REQ-198's 8 pure string/coalesce builtins** (`length`, `lower`, `upper`, `trim`, `contains`,
  `startsWith`, `endsWith`, `coalesce`) — no call-syntax grammar, no builtin-function AST node, no
  whitelist-at-lex-time mechanism is added by this design. REQ-198 depends on this requirement's
  extended grammar/precedence/error surface but adds its own AST node and its own moduledoc
  content; nothing here anticipates or partially implements it.
- **No CEL macros** (`has`/`matches`/`all`/`exists`/`exists_one`), **no collections**
  (`size`/`map`/`filter`), **no list/map literals, no indexing, no ternary operator, no `in`
  membership operator** — none of these exist in R-Co's actual `src/expr` surface (§9/AC11), so
  none is added here; `@unsupported_call_markers` and the existing `contains_in_operator?`/
  `contains_bare_question_mark?` translation-time rejections (unchanged by this requirement)
  continue to reject all of them at the CEL-translation layer, before this requirement's grammar
  ever runs.
- PROVENANCE (historical, not current decision authority):
  **No port of `src/expr/benchmark.zig`** (§9/AC10) — a Zig latency-measurement harness with no
  production behaviour and no Elixir equivalent; already recorded as deliberately unported in the
  existing moduledoc (REQ-050), restated rather than newly decided by this requirement.
- **No `now()`, `date_add()`, or `date_diff()`** — §8's decision, not a deferral-without-reasoning.
- **No changes to `translate_cel_to_expr/1`'s rewrite rules or unsupported-feature detection** —
  arithmetic operators (`+ - * /` `%`) appear in CEL syntax identically to expr syntax (unlike
  `&&`/`||`/`!`, which needed rewriting), so no new translation rule is needed; confirmed by
  inspection that none of the 4 existing rewrite rules (§4.3 of req050's design) touches any
  arithmetic character.
- **No change to `Letflow.Engine.Transition`** — `evaluate_conditioned_edges/3`'s single call site
  (`transition.ex:671`) is untouched; this requirement's entire surface is internal to `expr.ex`.

## 11. Traceability — every REQ-197 acceptance criterion to a concrete design element

PROVENANCE (historical, not current decision authority):

| # | Acceptance criterion (verbatim, abbreviated) | Design element |
|---|---|---|
| 1 | Each of `+ - * / %` and unary negation evaluates correctly, one test per operator | §2 (`ast()` node shapes), §4.1–§4.4 (eval semantics per operator) |
| 2 | Precedence matches R-Co's: `+`/`*` grouping, comparison-vs-arithmetic ordering | §2.1 (precedence table), §2.2 (both worked examples with concrete expected values), §3.1 (parser call-graph) |
| 3 | Int+float mix promotes to float, on a case where int arithmetic would differ | §4.2 row 4 (promotion rule) |
| 4 | Int div/mod by zero are errors; float div by zero is infinity — 3 tests | §4.3 table (all 3 cases enumerated with exact error/result shapes) |
| 5 | Null in comparison yields null; null in arithmetic is an error — 2 tests | §4.5 REVISED (asymmetry table with the changed ordering-comparison clause, plus the two worked test cases: `eval({:cmp, :lt, ...}, %{"amount" => nil})` → `{:ok, nil}`; `eval({:arith, :add, ...}, %{"amount" => nil})` → `{:error, {:eval_error, {:null_in_arithmetic, ...}}}`), §4.6 (guard-ordering re-check confirming the new nil-check branch doesn't shadow the `:nan`/infinity branches) |
| 6 | Strict entry point returns structured failure: line, column, token text, message — field by field on a malformed expression | §6.2–§6.5 (`positioned_token()`, `internal_parse_error()`, `parse_failure()`, `parse_strict/1`, `describe_parse_error/1`) |
| 7 | `evaluate_condition/2` unchanged: same malformed condition still yields `false`; transition.ex behaviour unchanged | §5 (byte-for-byte unchanged source, verification obligation naming the exact new test needed) |
| 8 | Purity grep still zero matches after this change, quoted in the PR | §7 (exact command, exact new-code coverage list) |
| 9 | `now()` not added; moduledoc states why and states the decided disposition | §8 (full reasoning), §9 table row AC9 |
| 10 | Moduledoc states `benchmark.zig` deliberately not ported | §9 table row AC10 |
| 11 | Moduledoc states R-Co's expr is not CEL, EXP-102 cutover, marker list rejects CEL vocabulary neither system has | §9 table row AC11, §10 (non-goals list) |
| 12 | `mix test` and `mix compile --warnings-as-errors` both pass, real output quoted | Not a design element — an ELIXIR-DEV/TEST-RUNNER build-time obligation; this design's signatures (§2–§6) are chosen so both commands can meaningfully enforce them (no dialyzer-only types, no dynamic dispatch that would compile but warn) |

## 12. Open questions (§8's decision above is final and NOT one of these — listed separately since it required its own reasoning, not a guess)

- PROVENANCE (historical, not current decision authority):
  **OQ-1 (§4.3) — genuine open question, needs REVIEWER's explicit sign-off before ELIXIR-DEV
  implements it, carried forward unchanged from iteration 0:** the signed-infinity / NaN-for-
  `0.0/0.0` 3-way split for float division by zero is this design's own reasoned extension of the
  requirement text's single un-signed phrase ("yields the IEEE infinity"). Not independently
  verified against R-Co's real `evaluator.zig` (§0's access gap — confirmed no `*.zig` file
  reachable on this host) — this bakes new machinery (a 3-variant `infinity_marker()` type, new
  `value()`/`ast()` surface, new comparison-ordering branches in §4.6) into concrete `@spec`/table
  content on the strength of this design's own guess, untested by any AC. **This must not be
  implemented by ELIXIR-DEV until REVIEWER has explicitly signed off on §4.3's 3-way split**,
  mirroring how REQ-191's global-table divergence and REQ-192's INV-RT-1 resolution were escalated
  to REVIEWER rather than silently decided — do not treat this design's §4.3 content as
  pre-approved for this specific point. A future reader with real R-Co source access should confirm
  R-Co actually produces signed infinity/NaN here rather than a single unsigned sentinel, and
  adjust §4.3 if not.
- **OQ-2 (§4.5) — RESOLVED in this rework iteration, no longer open:** iteration 0 read "null in a
  comparison yields null" as satisfied at the `evaluate_condition/2` boundary alone, leaving
  `eval/2`'s ordering-comparison clause unchanged. CODE-DESIGN-VALIDATOR's Step 1b BLOCKER (see
  `handoffs/WF02-REQ197-20260830/step-01b-code-design-validator.json`) confirmed the requirement
  text states this as a SCOPE instruction, not an ambiguous aside, and that AC5 is unsatisfiable
  under the old reading. §4.5 above now specifies the actual fix: `eval/2`'s ordering-comparison
  clause gains a new nil-check guard ahead of the `is_number` guard, returning `{:ok, nil}` for a
  nil operand. This is a real, deliberate behavioural change to `expr.ex:437-446` (not merely a
  re-reading), confirmed safe because no existing test pins the old behaviour. No further action
  needed on this item.
- **OQ-3 (§6.6 point 3) — relabelled (rework iteration 1): this is a requirement-text-confirmed
  scope exclusion, not an open question.** An eval-time structured-error surface (rich detail for a
  division-by-zero/null-in-arithmetic error, analogous to `parse_strict/1`'s parse-time surface) is
  not built here — and this is not something a future reader needs to resolve, because the
  requirement text's own SCOPE item 3 asks only for a **parse**-error surface ("line, column,
  offending token text, message" via a new strict entry point), never an eval-time one. §6.6 point
  3's scoping-out is therefore already the requirement's own answer, restated here for clarity, not
  a guess awaiting confirmation. (Noted as a candidate for a *future requirement* if REQ-198 or a
  later consumer ever needs an eval-time structured surface — but that is a scope-expansion
  proposal for later, not an unresolved question about *this* requirement's own scope.)
- PROVENANCE (historical, not current decision authority):
  **OQ-4 (§4.3 row A, `/` and `%`) — low-risk, flagged for REVIEWER's awareness only, not blocking,
  carried forward unchanged from iteration 0:** the truncate-toward-zero (`div/2`/`rem/2`-style)
  rounding direction for integer division/modulo with **negative** operands (e.g. `-7 / 2`,
  `-7 % 2`) is this design's own decision, chosen as the most common convention among
  C-family/Zig-heritage languages, but **not independently verified against R-Co's real
  `evaluator.zig`** (§0's access gap) — no acceptance criterion tests a negative-operand case, so
  this is a real, currently untested assumption. Unlike OQ-1, this does not block ELIXIR-DEV's
  implementation: it reuses Elixir's native `div/2` and `rem/2` semantics directly, with no new
  type or AST surface, and no AC depends on the negative-operand direction. A future reader with
  real R-Co source access should confirm the rounding direction (truncate-toward-zero vs. floor)
  before this assumption is treated as ported rather than reasoned, and add a negative-operand test
  once confirmed.
