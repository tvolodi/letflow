PROVENANCE (historical, not current decision authority):
# Design: REQ-050 — Exclusive gateway dispatch + CEL-subset expression evaluator (transition.zig EE-05)

**Requirement:** REQ-050 (stage S3), extends REQ-044's already-shipped `Letflow.Engine.Transition`
dispatch skeleton.
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the `dispatch_exclusive_gateway/4` rewrite (replacing the
`{:gateway_not_yet_implemented, ...}` stub at `transition.ex:256-259`), a new pure module
`Letflow.Engine.Expr` (`lib/letflow/engine/expr.ex`) with its public translate/parse/eval/
evaluate-condition signatures, the extended `transition_error()` variant, the declared-order
default-last evaluation algorithm, and the REQ-029 invariants this design relies on rather than
re-validates. Signatures and type shapes only — no implementation code, no function bodies, no
`.ex`/`.exs` code block contains real logic (any fenced block below is a `@type`/`@spec` signature
or a plain-English/pseudocode algorithm description, never a working function body).

## 0. Sources read for this design, and the R-Co access gap (CLOSED — see §0.1)

> **⚠️ AUDITED BY REQ-111 — three behavioural divergences found. Read §0.1 before
> trusting §4.3 or §4.4.** The R-Co source tree IS reachable and has now been read
> directly. The rules below were originally taken second-hand from REQ-050's
> requirement text; two of them are wrong in ways that change gateway routing.

PROVENANCE (historical, not current decision authority):
- This handoff's `context.requirement_text.REQ-050` (quoted in full where load-bearing — the
  requirement text itself already restates `evaluateGatewayCondition()`'s and
  `translateCelToExpr()`'s literal rewrite/boundary rules verbatim, which this design took as
  its source of record for those rules rather than reading `transition.zig` itself) and
  `task.acceptance_criteria` (8 items, traced in §10).
- `docs/guides/backend_developer_guide.md` (full) — §3.5's `{:ok, _} | {:error, _}` convention,
  already followed by `transition/3`; this design does not diverge from it.
- `docs/migration/stage-3-instance-engine.md` (full) — confirms "Gateway condition evaluation is
  not an open question" (REQ-050 has a real reference implementation to port, no build-vs-adopt
  decision record needed) and that HTTP/status-code mapping is S4's job, not this module's.
- `lib/letflow/design/req044-transition-kernel.md` (full) — the established conventions this
  design matches: purity contract + grep/`mix xref` verification method (its §8), the
  `transition_error()` type-union extension pattern (its §4/§7), the named-private-function stub
  replacement contract for `dispatch_exclusive_gateway/4` (its §6.4), and the moduledoc-citation
  style.
- `lib/letflow/engine/transition.ex`, `token.ex`, `instance_state.ex` (full, current `main`,
  REQ-044, `status: done`) — read as shipped, not just the design doc, per this handoff's own
  instruction. Confirms the stub's exact current shape (quoted in §1), `Token.t()`'s fields
  (`node_id`, `branch_id`, `token_id`, `waiting_child_instance_id`), and `InstanceState.t()`'s
  `variables :: map()` field — the map this design's evaluator reads condition variables from.
- `lib/letflow/definitions/graph.ex` (full, current `main`, REQ-028/029, `status: done`) —
  `Edge.t()`'s fields (`id`, `source`, `target`, `condition :: String.t() | nil`,
  `is_default :: boolean()`) and `Node.t()`'s fields (`id`, `node_type`, `label`, `attributes`).
  This design reuses these structs directly, exactly as REQ-044 did — no second copy.
- `lib/letflow/design/req029-node-attribute-edge-condition-validators.md` (full) — CHK-13..CHK-17,
  the exact invariants §6 below cites as relied-upon rather than re-validated, and
  `valid_cel_syntax?/1`'s existing scope (definition-time syntax check only, not evaluation — a
  distinct, already-shipped function this design does not call or duplicate).
- `docs/migration/decisions/` (`0001`..`0004`, `0006`) — none bears on this requirement.
  `stage-3-instance-engine.md` and the requirement text both state explicitly that no
  build-vs-adopt decision record is needed here (R-Co has a real reference implementation, not a
  stub, to port); confirmed by inspection — no decision file added by this design.

PROVENANCE (historical, not current decision authority):
**Access gap — CLOSED, and it was not harmless.** This section previously stated that the R-Co
checkout (`transition.zig`, `src/expr/`) was not present on this host, and that the design was
built entirely from `context.requirement_text.REQ-050`'s own inline restatement of the Zig
rules. The checkout **is** present (`c:\Users\tvolo\dev\ai-dala\R-Co`), and REQ-111 has now
read `src/engine/transition.zig` and `src/design/iss602_cel_expr_differential.md` directly.

### 0.1 REQ-111 audit result — what the second-hand sourcing got wrong

PROVENANCE (historical, not current decision authority):
Sources actually read: `R-Co/src/engine/transition.zig:1118-1157`
(`evaluateGatewayCondition`), `:1164-1205` (`translateCelToExpr`), `:1210-1241`
(`hasCelUnsupportedFeatures` + `isCelIdentChar`), `R-Co/src/expr/lexer.zig:46-48`, and
`R-Co/src/design/iss602_cel_expr_differential.md:236-278`.

PROVENANCE (historical, not current decision authority):
| Location | Disposition | Detail |
|---|---|---|
| §4.3 rule 1 — strip `variables.` | `confirmed` | `transition.zig:1171-1174` |
| §4.3 rule 2 — `&&` → `and` | **`divergent_behavioural`** | R-Co emits **`" and "`** with spaces (`transition.zig:1177`); this design's table shows `and` and only spaced examples. See **ISS-0085** / GH#302. **RESOLVED** 2026-08-20 — `expr.ex:106` now emits `" and "` with spaces, matching `transition.zig:1177`; table above restated with an unspaced example. |
| §4.3 rule 3 — `\|\|` → `or` | **`divergent_behavioural`** | R-Co emits **`" or "`** with spaces (`transition.zig:1183`). Same issue, **ISS-0085**. **RESOLVED** 2026-08-20 — `expr.ex:107` now emits `" or "` with spaces, matching `transition.zig:1183`. |
| §4.3 rule 4 — `!` → `not `, `!=` intact | `confirmed` | `transition.zig:1188-1197` — R-Co's `"not "` trailing space is reproduced correctly here |
| §4.2 step 1 — detect on the untranslated string, before any rewrite | `confirmed` | `transition.zig:1165` (`if (hasCelUnsupportedFeatures(...)) return null;`, first statement) |
| §5.2 — uniform catch-false over translate/parse/eval | `confirmed` | `transition.zig:1124`, `:1128`, `:1150-1156` (non-bool result → `false`) |
| §4.4 — macros | `divergent_doc_only` | Marker sets differ both ways (`transition.zig:1211`, `:1215`); all differences funnel to `false` via catch-false — **except `matches(`**, see §9.1. **RESOLVED** 2026-08-20, `matches(`/`map{` added to the marker list, tokenizer made total — WF03-ISS0086-20260820, PR #307. |
| §4.4 — type-conversion functions | `divergent_doc_only` | R-Co lists only `int(`/`string(`/`double(` (`transition.zig:1215`) |
| §4.4 — collection functions | `divergent_doc_only` | R-Co uses method-form `.size(`/`.map(` and adds `map{` literals (`transition.zig:1211`, `:1223`); it has **no `in` check** — but `in` is not an expr keyword (`R-Co/src/expr/lexer.zig:46-48` defines only `and`/`or`/`not`), so it fails to parse and still yields `false` |
| §4.4 — ternary | **`divergent_behavioural`** | The main case agrees (a literal `?` inside a quoted string is NOT treated as ternary, both sides). The escaped-quote case does not — see §9.1 and **ISS-0087** / GH#304. **RESOLVED** 2026-08-20 — decision: KEEP Letflow's escape-aware semantics (deliberate divergence, recorded in §9.1(b)) — WF03-ISS0087-20260820. |

**Rolled-up disposition for §4.3's rules and §4.2/§5.2's boundary rules:
`divergent_behavioural`** (most severe of the per-rule dispositions).

PROVENANCE (historical, not current decision authority):
Note this design's §4.3 already reasons that "rule ordering within the 4 does not observably
matter" because the rules touch disjoint token shapes. That reasoning is sound and survives the
audit — it is simply orthogonal to the spacing question, which the design never raised. R-Co
applies all four in a **single left-to-right pass** (`transition.zig:1168-1200`) rather than as
four sequential whole-string replacements, which is an implementation difference with no
observable effect once the spacing is corrected.

Per REQ-111 this audit records findings and changes **no** engine behaviour; the divergences are
routed through WF-03 via the issues cited above, not repaired here.

## 1. What is being replaced

`transition.ex:256-259`, current shipped code:

```elixir
@spec dispatch_exclusive_gateway(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:error, {:gateway_not_yet_implemented, :EXCLUSIVE_GATEWAY, node_id :: String.t()}}
defp dispatch_exclusive_gateway(_definition_snapshot, _instance_state, _token, node) do
  {:error, {:gateway_not_yet_implemented, :EXCLUSIVE_GATEWAY, node.id}}
end
```

This design replaces only this one private function's body and `@spec` (§2) — it does not touch
`dispatch_node/4`'s outer pattern-match structure, matching REQ-044 design doc §6.4's own framing
of this exact function as the extension point.

## 2. `dispatch_exclusive_gateway/4` — new signature

```elixir
@spec dispatch_exclusive_gateway(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [Transition.pending_event()]}
        | {:error, {:no_matching_edge, node_id :: String.t(), evaluated_conditions :: [Letflow.Engine.Transition.evaluated_condition()]}}
```

**Inputs**, unchanged shape from the stub (matches every other `dispatch_*/4` clause):
`definition_snapshot :: Graph.t()` (to resolve outgoing edges of `node`), `instance_state ::
InstanceState.t()` (its `variables :: map()` field is what condition strings are evaluated
against), `token :: Token.t()` (the token being advanced — its `node_id` already equals `node.id`
by the time `dispatch_node/4` calls this function, per `transition/3`'s own resolution in §6 of
the REQ-044 design), `node :: Node.t()` (the `:EXCLUSIVE_GATEWAY` node itself; `node.id` is what
both the `dispatch_start`-style edge lookup and the error tuple use).

**Output on success:** `{:ok, new_instance_state, []}` — same shape as `dispatch_start/4`
(REQ-044 design §6.1): the matched/default edge's `target` becomes the token's new `node_id`,
`instance_state.tokens` is updated in place (matched token replaced, order otherwise preserved,
reusing `Transition`'s existing private `replace_token/2`), `variables`/`status`/
`pending_task_nodes` all unchanged. `pending_events` is always `[]` — this requirement's dispatch
never constructs a `pending_event()` value, same as every REQ-044 case (design doc §4/§12.5;
`pending_event/0` stays `term()`, not narrowed by this requirement — gateway routing produces no
split/join payload).

**Output on failure:** `{:error, {:no_matching_edge, node.id, evaluated_conditions}}` — §5 defines
the exact shape and construction of `evaluated_conditions`.

## 3. `Letflow.Engine.Transition` additions — extended `transition_error()` and new type

**`transition_error/0` gains one variant** (extending REQ-044's existing 5-variant union, matching
the exact extension mechanism REQ-044 design doc §12.5 already anticipated for this requirement):

```elixir
@type transition_error ::
        {:unknown_event_type, event :: term()}
        | {:unknown_token_id, token_id :: String.t()}
        | {:unknown_node_id, node_id :: String.t()}
        | {:gateway_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
        | {:node_type_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
        | {:no_matching_edge, node_id :: String.t(), evaluated_conditions :: [evaluated_condition()]}
```

`:gateway_not_yet_implemented` stays in the union (still returned by the sibling
`dispatch_parallel_gateway/4` stub, REQ-051's own extension point, untouched by this requirement)
even though `:EXCLUSIVE_GATEWAY` itself no longer produces it.

**New type, declared alongside `transition_error/0` in `Letflow.Engine.Transition`:**

```elixir
@type evaluated_condition :: %{
        edge_id: String.t(),
        condition: String.t(),
        result: boolean()
      }
```

One entry per **non-default** outgoing edge whose condition was actually evaluated before the
dispatch gave up (§5 states precisely which edges that is — declared order, short-circuiting at
the first `true`, so on the error path this list is *every* conditioned edge, all with `result:
false`, since reaching the error path means none matched). `condition` is always the edge's
**original CEL-syntax string** (`Edge.t().condition`, never the translated expr-syntax string or
the parsed AST) — an operator reading a persisted error tuple should see the same condition text
that was authored in the definition graph, not an internal representation, per AC4/EE-10 AC5's
"enough detail to diagnose without replaying." `edge_id` is `Edge.t().id`, letting an operator
cross-reference the exact edge in the definition graph. The default edge, if one exists, never
appears in `evaluated_conditions` — it carries no condition (§6's invariant) and, when this error
path is reached, no default edge exists at all (§5's algorithm only reaches
`{:no_matching_edge, ...}` when there is no default to fall back to).

## 4. `Letflow.Engine.Expr` — new pure CEL-subset expression evaluator module

**File:** `lib/letflow/engine/expr.ex`. **Module:** `Letflow.Engine.Expr`. A fourth sibling file
in `lib/letflow/engine/`, alongside `instance_state.ex`/`token.ex`/`transition.ex` — matching
REQ-044 design doc §1's "the module IS the [primary concern]" precedent: `Expr` is not scoped only
to gateway dispatch (`stage-3-instance-engine.md`'s scope note below states a fuller expression
surface, if a later stage needs one, extends this module rather than replacing it), so it earns
its own file rather than living inside `transition.ex`.

PROVENANCE (historical, not current decision authority):
**Scope note (moduledoc-carried, AC8):** this module ports the *subset* of R-Co's `src/expr/`
surface that `translateCelToExpr` can actually produce for a gateway condition — variable
references, the 6 comparison operators, boolean `and`/`or`/`not`, and literal values (numbers,
strings, booleans, `null`) — not a full port of all 7 `src/expr/` files (`lexer.zig`, `parser.zig`,
`ast.zig`, `evaluator.zig`, `error.zig`, `mod.zig`, `benchmark.zig`). `benchmark.zig` in particular
has no Elixir equivalent and is not ported at all. The moduledoc states this explicitly, citing
`transition.zig`'s `evaluateGatewayCondition()` (~L1118) and `src/expr/` as the ported reference,
per AC8's own wording.

### 4.1 Internal expr-AST type

```elixir
@type value :: number() | String.t() | boolean() | nil

@type ast ::
        {:lit, value()}
        | {:var, path :: [String.t()]}
        | {:not, ast()}
        | {:and, ast(), ast()}
        | {:or, ast(), ast()}
        | {:cmp, cmp_op(), ast(), ast()}

@type cmp_op :: :eq | :neq | :lt | :lte | :gt | :gte
```

`{:var, path}` holds a dotted-field path with the leading `variables.` token already stripped by
translation (§4.3 rule 1) — e.g. source `variables.request.amount` translates to expr source
`request.amount`, parsed as `{:var, ["request", "amount"]}`. `path` is `[String.t(), ...]`,
non-empty; a bare `variables` with nothing after the dot is a translation-time malformed-input
case, folded into the same `{:error, :translate_error}` result §4.2 already returns (§9 open
question notes this is this design's own reasoned default, not separately verified against
source).

### 4.2 `translate_cel_to_expr/1` — CEL string to expr-syntax string

```elixir
@spec translate_cel_to_expr(cel_condition :: String.t()) ::
        {:ok, expr_source :: String.t()}
        | {:error, :unsupported_cel_feature}
        | {:error, :translate_error}
```

Pure string-level rewrite — never touches `variables`, never parses, never evaluates. Composition
(§4.3 states the exact rules and their order):

1. Scan the **original, untranslated** `cel_condition` for any of the unsupported-feature markers
   §4.4 lists. If found, return `{:error, :unsupported_cel_feature}` immediately — none of the 4
   rewrite rules run on an unsupported expression.
2. Otherwise apply the 4 rewrite rules (§4.3) in the stated order and return
   `{:ok, expr_source}`.
3. `{:error, :translate_error}` is this design's own defensive addition (§9) for a malformed input
   the 4 rules cannot produce well-formed expr syntax from (e.g. an empty string, or a bare
   `variables.` with no field after it) — not a literal quote from the requirement text, added for
   totality the same way REQ-044 design doc §7.3 added `:unknown_token_id` beyond its literal ACs.

### 4.3 The 4 `translateCelToExpr` rewrite rules — exact, in this order

Ported verbatim from the requirement text's own restatement of `translateCelToExpr`. All 4 live
inside `translate_cel_to_expr/1` (§4.2) — no separate function per rule; this is one composed
string transformation, matching the Zig original being "small and fully specified."

| # | Rule | CEL input | expr-syntax output |
|---|---|---|---|
| 1 | Strip the `variables.` prefix | `variables.amount` | `amount` |
| 2 | `&&` → `" and "` (with surrounding spaces) | `variables.a&&variables.b` | `a and b` |
| 3 | `\|\|` → `" or "` (with surrounding spaces) | `variables.a\|\|variables.b` | `a or b` |
| 4 | `!` → `not ` (`!=` passes through unchanged) | `!variables.approved`, `variables.status != "x"` | `not approved`, `status != "x"` |

PROVENANCE (historical, not current decision authority):
**Rules 2/3's spaces are load-bearing, not cosmetic (ISS-0085 / GH#302):** `transition.zig:1177`/
`:1183` emit `" and "`/`" or "` with surrounding spaces, matching rule 4's own `"not "` (which
already carried its trailing space, `transition.zig:1194`, and was already ported correctly at
`expr.ex:134`). CEL does not require whitespace around `&&`/`||`, so unpadded CEL like
`variables.a&&variables.b` is valid input. An unpadded rewrite fuses the adjacent tokens into one
identifier (`aandb`) instead of `a and b`; that parses as a bare variable reference rather than
raising, resolves to an undefined-variable eval error, and folds into §5.2's catch-false
composition as a silent `false` — routing the token down the wrong outgoing edge with no crash and
no test signal (the existing suite only ever exercised spaced CEL). Already-spaced input can
produce a doubled space (`a  and  b`) after the fix; harmless, since `do_tokenize/2`
(`expr.ex:202-204`) skips whitespace exactly as R-Co's own lexer does. The prior table version
showed spaced-only examples for rows 2/3, which is what made the space requirement invisible;
the examples above are deliberately unspaced.

**Rule 4's carve-out is load-bearing, stated explicitly:** the rewrite must recognize `!=` as a
single token and leave it untouched — a naive `!` → `not ` substitution applied byte-for-byte would
corrupt `!=` into `not =`, an invalid expr-syntax token. ELIXIR-DEV implements rule 4 as "replace
every `!` that is **not** immediately followed by `=`" (a negative-lookahead-shaped rule, e.g. a
regex `!(?!=)` or an equivalent manual scan) — the exact mechanism (regex vs. manual char scan) is
ELIXIR-DEV's implementation choice, not pinned by this design, so long as `!=` is provably
untouched by an explicit test (AC7 requires this rule tested directly).

**Rule ordering within the 4 does not observably matter** for well-formed CEL input (the 4 rules
touch disjoint token shapes — `variables.`, `&&`, `||`, and bare `!`/`!=` never overlap
character-for-character in valid CEL), so this design does not mandate one fixed application order
beyond "all 4 apply, unsupported-feature detection (§4.4) happens first, on the untranslated
string." Flagged as a non-decision, not silently significant.

### 4.4 Supported/unsupported CEL feature boundary — ported from `hasCelUnsupportedFeatures()`

Cited by name per the requirement text's explicit instruction ("port that supported/unsupported
boundary explicitly rather than inferring it, and cite `hasCelUnsupportedFeatures()` as its
source"). An expression is **unsupported** — and therefore, via `translate_cel_to_expr/1` §4.2's
step 1, immediately `{:error, :unsupported_cel_feature}`, which composes into catch-false (§5.2) —
if it uses any of:

- **Macros** — CEL macro-call syntax: `has(...)`, `all(...)`, `exists(...)`, `exists_one(...)`.
- **Type-conversion functions** — `int(...)`, `uint(...)`, `double(...)`, `string(...)`,
  `bool(...)`, `bytes(...)`, `duration(...)`, `timestamp(...)`.
- **Collection functions** — `size(...)`, the `in` membership operator, `map(...)`, `filter(...)`.
- **The ternary operator** — `condition ? a : b` (`?`/`:` used as the conditional-expression
  operator, not as part of a string literal).

**Detection mechanism (this design's own choice, not literally pinned by the requirement text,
flagged in §9):** a fixed list of substring/regex markers checked against the raw CEL string
before any rewrite — function-name markers as `name(` (catches macros, type-conversion, and
collection functions in one pass since they share call syntax) plus a `?` marker for the ternary
operator (a `?` character outside a string-literal span is unsupported; a `?` inside a quoted
string, e.g. a literal question mark in a comparison value, is not a ternary use and must not
false-positive — ELIXIR-DEV's exact string-literal-aware scan is an implementation detail this
design leaves open per §9, not silently resolved).

**This boundary determines translation failure, not evaluation failure — stated once, not
re-derived per call site:** an unsupported-feature condition never reaches `parse/1` or `eval/2` at
all; it is rejected at the `translate_cel_to_expr/1` stage. It still ends up `false` for the
gateway's purposes because §5.2's catch-false composition treats every stage's error uniformly.

### 4.5 `parse/1` — expr-syntax string to AST

```elixir
@spec parse(expr_source :: String.t()) :: {:ok, ast()} | {:error, {:parse_error, reason :: term()}}
```

A small recursive-descent parser over the expr-syntax grammar this subset needs (algorithm shape,
not code):

```
expr       := or_expr
or_expr    := and_expr ("or" and_expr)*
and_expr   := not_expr ("and" not_expr)*
not_expr   := "not" not_expr | cmp_expr
cmp_expr   := operand (cmp_op operand)?
cmp_op     := "==" | "!=" | "<" | "<=" | ">" | ">="
operand    := literal | var_path | "(" expr ")"
var_path   := identifier ("." identifier)*
literal    := number | string | "true" | "false" | "null"
```

Operator precedence (lowest to highest): `or`, `and`, `not`, comparison, primary — standard
short-circuit-free boolean grammar (no CEL macros/ternary reach this parser at all, since §4.4
rejects them upstream). `{:parse_error, reason}`'s `reason` is an internal diagnostic term
(unexpected token, unbalanced parens, trailing input) — its exact shape is ELIXIR-DEV's
implementation choice; nothing outside `Expr` pattern-matches on `reason`'s internals, since §5.2's
catch-false composition only inspects the `:error`/`:ok` tag, never the payload.

### 4.6 `eval/2` — AST evaluation against a variables map

```elixir
@spec eval(ast(), variables :: map()) :: {:ok, value()} | {:error, {:eval_error, reason :: term()}}
```

Walks the AST (algorithm shape, not code):

- `{:lit, v}` → `{:ok, v}`.
- `{:var, path}` → resolves `path` against `variables` via successive `Map.get/2`-shaped lookups
  (string keys, since `variables` is a plain `map()` per `InstanceState.t()`, §0). Any missing key
  at any step of the path → `{:error, {:eval_error, {:undefined_variable, path}}}` — an **undefined
  variable is an eval error, not a special nil-propagating case** (matches AC3's "undefined
  variable" example verbatim).
- `{:not, sub}` → evaluates `sub`; if its value is not `boolean()`, `{:error, {:eval_error,
  {:type_mismatch, ...}}}`; otherwise the negation.
- `{:and, l, r}` / `{:or, l, r}` → both operands evaluated (no short-circuit skip of type-checking
  the unevaluated side — both must be `boolean()`-typed or `{:error, {:eval_error,
  {:type_mismatch, ...}}}` results); combines with ordinary boolean semantics otherwise.
- `{:cmp, op, l, r}` → evaluates both operands; `:eq`/`:neq` compare any two same-typed `value()`s
  by ordinary Elixir `==`/`!=` (also legal, and always `false`/`true` respectively, across
  differently-typed operands — not an error, matching CEL's own equality semantics); `:lt`/`:lte`/
  `:gt`/`:gte` require both operands to be `number()` — a `String.t()` or `boolean()` operand on
  either side of an ordering comparison is `{:error, {:eval_error, {:type_mismatch, ...}}}` (the
  literal "type mismatch" AC3 names).

`eval/2`'s own result, when `{:ok, value}`, may itself be a **non-boolean** `value()` (e.g. a
condition string that is really just a variable reference to a number, or a comparison operand
mistakenly used bare as the whole condition). §5.2 states this is folded into catch-false too — a
condition is only ever "true" when `eval/2` returns `{:ok, true}` exactly; every other `{:ok,
_}` shape and every `{:error, _}` shape both mean "false" for gateway-routing purposes.

### 4.7 `evaluate_condition/2` — the one function gateway dispatch calls

```elixir
@spec evaluate_condition(cel_condition :: String.t(), variables :: map()) :: boolean()
```

The composed, **always-boolean, never-`{:error, _}`** entry point `dispatch_exclusive_gateway/4`
(§2, §5) actually calls per edge. Composition: `translate_cel_to_expr/1` → (on `{:ok, expr}`)
`parse/1` → (on `{:ok, ast}`) `eval/2` → (on `{:ok, true}`) `true`; every other outcome at every
stage → `false`. §5.2 states this uniform catch-false rule as one rule, not per-stage rules.

## 5. The declared-order, default-last, first-true-wins algorithm

### 5.1 Edge selection and ordering

Outgoing edges of the gateway node are `Enum.filter(definition_snapshot.edges, &(&1.source ==
node.id))`, preserving `definition_snapshot.edges`'s own declaration order (the same "list order is
part of the argument, not derived" determinism argument REQ-044 design doc §8 already established
for `:START`'s edge lookup). This filtered list is partitioned into:

- **`conditioned_edges`** — every edge with `is_default != true`, in their relative declared order
  (not reordered relative to each other).
- **`default_edge`** — the at-most-one edge with `is_default == true` (§6's relied-upon invariant),
  or absent.

### 5.2 Evaluation loop — first-true-wins over `conditioned_edges`, catch-false uniform

Walk `conditioned_edges` in their declared order. For each edge, call
`Expr.evaluate_condition(edge.condition, instance_state.variables)` (§4.7) — this single call is
where translation errors, parse errors, and evaluation errors (including the unsupported-CEL-
feature case, §4.4) all become `false` **uniformly, as one rule** (AC3, AC6): there is no separate
"translation failed" vs. "evaluation raised" branch anywhere in the gateway dispatch or in
`Expr` itself — every non-`{:ok, true}` outcome at any stage of §4.7's composition is the same
`false` result, and a `false` result means "try the next edge," never "error the instance."

- First edge whose `evaluate_condition/2` call returns `true` **wins**: evaluation stops there
  (edges after it in `conditioned_edges` are never evaluated at all — true short-circuit, not just
  "first true recorded"). The token advances onto that edge's `target`. Return
  `{:ok, new_instance_state, []}` (§2).
- If the loop exhausts `conditioned_edges` with no `true` result: every edge in
  `conditioned_edges` was evaluated (none short-circuited it away), each contributing one
  `%{edge_id: edge.id, condition: edge.condition, result: false}` entry, in declared order, to the
  `evaluated_conditions` list (§3) carried forward to the next step.

### 5.3 Default-last

The default edge, if present, is **only ever considered after** `conditioned_edges` has been fully
walked with no match — never interleaved into the declared-order loop, regardless of the default
edge's own position in `definition_snapshot.edges` (AC2's explicit "default declared FIRST" case:
`default_edge` is computed once via the `is_default == true` filter in §5.1 and is structurally
excluded from `conditioned_edges`, so its declared position never participates in the ordering
loop at all — it is evaluated last by construction, not by a runtime position check). If
`default_edge` is present: the token advances onto its `target` **unconditionally** — no
`Expr.evaluate_condition/2` call happens for the default edge at all, since `Edge.t().condition` is
`nil` for it (§6's relied-upon invariant) and a default edge is definitionally "the edge taken when
nothing else matched," not itself a condition to evaluate. Return `{:ok, new_instance_state, []}`.

### 5.4 No match, no default — the error path

If `conditioned_edges` is exhausted with no match **and** `default_edge` is absent: return
`{:error, {:no_matching_edge, node.id, evaluated_conditions}}` (§3), where `evaluated_conditions`
is exactly the list accumulated in §5.2's loop (every conditioned edge, all `result: false`, in
declared order). If the gateway node has **zero** outgoing edges at all (`conditioned_edges == []`
and no default), this same error path fires with `evaluated_conditions: []` — a degenerate case not
separately named by an acceptance criterion, flagged in §9 as this design's own defensive extension
of the rule, matching REQ-044 design doc §7.3's precedent for undemanded-but-necessary totality.

### 5.5 Exactly one edge followed (AC5)

By construction, §5.2's loop takes at most one `conditioned_edges` branch (`true` stops the loop
immediately), and §5.3's default is only reached when no `conditioned_edges` branch matched — the
two paths are mutually exclusive and together with §5.4's error path (which takes **zero** edges,
by design: no instance-state change occurs on the error path, only an `{:error, _}` return) cover
every case. "Exactly one edge, never zero, never more than one" (AC5) holds for every **success**
path; the failure path takes zero edges and returns an error instead of a token position, which is
the intended non-routing outcome, not a violation of "exactly one" (AC5's own framing is about
routing decisions that do produce a `{:ok, ...}`).

## 6. Invariants relied upon from REQ-029 — stated as relied-upon, not re-validated

This design performs **no** structural re-validation of `is_default`/`condition` legality inside
`dispatch_exclusive_gateway/4` or anywhere in `Expr`. It relies on the following, already enforced
by `Letflow.Definitions.Graph.validate_edge_conditions/1` (REQ-029, `status: done`) at
definition-creation time (`lib/letflow/design/req029-node-attribute-edge-condition-validators.md`
§5, CHK-13..CHK-17), on every `definition_snapshot` this dispatch ever receives:

- **CHK-15 (`:default_with_condition`):** `edge.is_default == true` and `edge.condition != nil`
  never coexist on the same edge. This design's §5.3 therefore never needs to check whether the
  default edge also happens to carry a condition string — it is guaranteed `nil`, and `Expr` is
  never called for it.
- **CHK-16 (`:multiple_default_edges`):** at most one edge with `is_default == true` exists per
  gateway (per source node). §5.1's `default_edge` is therefore safely treated as "the one default,
  or none" — this design does not defend against, or define behavior for, two default edges
  reaching `dispatch_exclusive_gateway/4` simultaneously, since REQ-029 guarantees that shape is
  rejected before a definition is ever persisted/snapshotted.
- **CHK-13 (`:missing_edge_condition`) / CHK-14 (`:unexpected_edge_condition`):** every non-default
  outgoing edge of an `EXCLUSIVE_GATEWAY` node carries a non-empty `condition` string, and no edge
  outside that shape carries one. `conditioned_edges` (§5.1) is therefore assumed to always have a
  non-`nil`, non-empty `condition` on every member — `Expr.evaluate_condition/2` (§4.7) is never
  called with `nil` by this design's own construction, though its own `translate_cel_to_expr/1`
  (§4.2) still defensively returns `{:error, :translate_error}` rather than raising if that
  assumption is ever violated by a `definition_snapshot` that bypassed REQ-029's checks (§9).

**Consequence stated explicitly:** if a caller ever passes `dispatch_exclusive_gateway/4` a
`definition_snapshot` that violates these invariants (e.g. constructed directly in a test without
going through REQ-030's `create/1` validation pipeline), this design's behavior is
best-effort-defensive (§4.2's `:translate_error` catch-all) but not a verified total specification
of that misuse — the same "ordering contract enforced by the caller, not this module" framing
REQ-029's own design doc §1 already establishes for its own two validator functions.

## 7. Purity — zero I/O, deterministic (AC8)

**Same verification method as REQ-044 (design doc §8) and `Letflow.Definitions.Graph` (REQ-028
design doc §8), applied to the two new/changed files:**

```bash
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex lib/letflow/engine/transition.ex
```

must return zero matches. `mix xref graph Letflow.Engine.Expr` (or the equivalent call-graph
query) must confirm `Letflow.Repo` never appears as a callee, direct or transitive, from either
module. `Letflow.Engine.Expr` depends on Elixir/Erlang stdlib only (`Enum`, `Map`, `String`,
`Kernel`, `Regex` if ELIXIR-DEV chooses a regex-based rule-4/rule-1 implementation) — no `Ecto`,
no `Letflow.Repo`, no `Logger.*`, no clock read, no `:rand`/`:crypto`, no `File.*`/HTTP/
process-mailbox call anywhere in `translate_cel_to_expr/1`, `parse/1`, `eval/2`, or
`evaluate_condition/2`'s call graphs. `dispatch_exclusive_gateway/4`'s own call graph is pure by
the same argument, since its only new callee is `Expr.evaluate_condition/2`.

PROVENANCE (historical, not current decision authority):
**Determinism:** every one of `Expr`'s 4 functions is a pure function of its typed arguments alone
— no external state, no randomness, no `:ets`/mailbox read anywhere in `Expr`'s call graph; two
calls with `==`-equal arguments return `==`-equal results, both times, matching REQ-044 design doc
§8's precise definition of "deterministic" for this codebase. The moduledoc states both the purity
and determinism claims explicitly, citing `transition.zig`'s own header text quoted in the
requirement ("`expr.parse()` and `expr.evaluate()` are pure computations") as the ported
guarantee, per this handoff's instruction to match REQ-044's own moduledoc pattern.

## 8. Cross-module dependencies

- **`Letflow.Engine.Transition`** (REQ-044, `status: done`) — `dispatch_exclusive_gateway/4` is
  replaced in place; `Transition`'s `transition_error/0` gains the `:no_matching_edge` variant and
  a new `evaluated_condition/0` type (§3). No other `Transition` function changes.
- **`Letflow.Engine.Expr`** (new, this requirement) — called only from
  `dispatch_exclusive_gateway/4`'s §5.2 loop, via `evaluate_condition/2`. Nothing else in
  `Letflow.Engine.*` calls `Expr` yet; `stage-3-instance-engine.md`'s scope note (§4's opening)
  anticipates a later stage may extend `Expr`'s surface for other engine needs (e.g. a future
  `:TIMER` duration expression, unconfirmed/not in scope here).
- **`Letflow.Definitions.Graph`, `.Edge`, `.Node`** (REQ-028/029, `status: done`) — reused
  directly, no redefinition, same as REQ-044 (§0 above).
- **None on `Letflow.Repo` or any `Ecto.Schema` module** — §7's purity contract.
- **Forward dependents (not yet built):** REQ-061 (EE-10 execution error handling) is the future
  consumer that interprets a `{:error, {:no_matching_edge, node_id, evaluated_conditions}}` tuple
  and actually marks an instance `ERROR` in the DB — explicitly out of this requirement's own
  scope per ORCH's clarification note in the requirement text (quoted in full in this handoff);
  this design's pure module only returns the tagged tuple, never calls into REQ-061 code (which
  does not exist yet).

## 9. Open questions — not resolved here

### 9.1 Unsupported-feature detection — VERIFIED against source by REQ-111

§4.4's "fixed marker list + string-literal-aware `?` scan" was this design's own reasonable
implementation strategy for `hasCelUnsupportedFeatures()`'s boundary, reconstructed from the
requirement text's enumeration of the 4 unsupported categories (macros, type-conversion functions,
collection functions, ternary). The exact detection algorithm (regex vs. hand-written scanner, and
precisely how string-literal spans are tracked so a literal `?` inside a quoted CEL string value is
never mistaken for the ternary operator) was left to ELIXIR-DEV, not pinned by this design.

PROVENANCE (historical, not current decision authority):
**This section asked to be re-checked once R-Co source access became available. REQ-111 has now
done so, reading `R-Co/src/engine/transition.zig:1210-1241` directly.** Rolled-up disposition:
**`divergent_behavioural`**. Per-category dispositions are tabulated in §0.1; what follows is
what the source actually says and which parts matter.

PROVENANCE (historical, not current decision authority):
**R-Co's actual detection**, `transition.zig:1210-1234`, in four steps:

1. `:1211` — method-form markers, plain substring, no boundary guard:
   `{ ".all(", ".exists(", ".size(", ".map(" }`.
2. `:1215-1222` — standalone markers `{ "has(", "matches(", "int(", "string(", "double(" }`,
   each scanned with an **identifier-boundary guard**: `if (idx == 0 or
   !isCelIdentChar(expression[idx - 1])) return true` (`isCelIdentChar` at `:1236-1241`), so
   `recall(` does not trip an `all(`-shaped marker.
3. `:1223` — map literals, `map{`.
4. `:1224-1232` — ternary: a `?` seen while outside every quoted span, where spans are tracked
   by a simple `in_double`/`in_single` toggle **with no backslash-escape handling**.

**The algorithm difference is NOT the finding.** §4.4's marker-list-plus-regex strategy and
R-Co's hand-written scan are different mechanisms, and this design deliberately left the
mechanism open — that difference is out of scope and is not recorded as a divergence. Two
*outcome* differences are in scope:

PROVENANCE (historical, not current decision authority):
**(a) `matches(` is absent from Letflow's marker list, and it does not fail safe.** Most
marker-set differences are harmless: an unlisted construct survives translation, then fails to
parse, and §5.2's catch-false folds it to `false` — the same answer R-Co reaches by rejecting it
earlier. That holds for every difference in both directions **except** `matches(`, whose
`ident.ident(` shape reaches an unhandled clause in the shipped tokenizer and **raises
`CaseClauseError`** instead of returning `false`. That breaks §4.7's own "always-boolean,
never-`{:error, _}`" contract and propagates out of `Transition.transition/3`, which calls
`evaluate_condition/2` unguarded. R-Co returns `false` here (`transition.zig:1215` → `:1165` →
`:1124`). See **ISS-0086** / GH#303 — which also covers making the tokenizer total, the more
important half of the fix.

**RESOLVED 2026-08-20 (WF03-ISS0086-20260820, PR #307).** `matches(`/`map{` added to
`@unsupported_call_markers`; `do_tokenize/2`'s identifier and number clauses fixed to be total
over every input shape (the actual bug was broader than this repro — see the issue's own
resolution notes in `docs/issues/ISS-0086.yaml`).

**(b) The string-literal span boundary differs in outcome on escaped quotes.** The case this
section names explicitly — a literal `?` inside a quoted CEL string must not be mistaken for the
ternary operator — **is handled correctly and agrees with R-Co** for ordinary literals
(`variables.q == "what?"` is supported by both), and a genuine ternary is rejected by both. But
for a literal containing a backslash-escaped quote followed by `?` (`variables.q == "a\"?b"`),
R-Co's toggle has no escape handling, sees the `?` as outside the literal, and rejects the
condition as ternary; Letflow's escape-aware regex sees it as inside and evaluates the
comparison. This is an outcome difference on exactly the boundary this section flags, so it is
recorded as a divergence rather than dismissed as a mechanism difference — even though
Letflow's behaviour is arguably the more correct of the two. See **ISS-0087** / GH#304, which
leaves the parity-vs-correctness choice explicitly open for the fix design.

**RESOLVED 2026-08-20 (WF03-ISS0087-20260820) — decision: KEEP Letflow's escape-aware
semantics.** Verifying this end-to-end (not just at the `translate_cel_to_expr/1` stage this
paragraph describes) surfaced that the outcome this section predicted did not actually occur in
shipped code, for a reason this audit missed: `parse/1`'s own string-literal tokenizer
(`tokenize_string/3`, upstream of and independent from the CEL-detection stage discussed above)
had **no escape handling of its own** — it terminated on the first raw quote byte regardless of
a preceding backslash. So `variables.q == "a\"?b"` was classified `supported` at the CEL stage
(as described above) but then failed to *parse* at the expr-syntax stage, catch-falsing to
`false` — coincidentally agreeing with R-Co's `false`, but for an unrelated reason, and as a
symptom of a materially worse bug: **any** expr-syntax string literal containing an escaped
quote of its own delimiter failed to parse at all, with no relationship to ternary detection —
e.g. `variables.name == "O'Brien"`-shaped comparisons using the *other* quote style were fine,
but `variables.name == "O\"Brien"` silently always evaluated `false` regardless of `name`'s
actual value. Fixed by making `tokenize_string/3` escape-aware (mirrors
`strip_string_literals/1`'s existing `\\.` handling, which this stage had never been brought in
line with). Post-fix, the outcome this section originally predicted is now real: Letflow
evaluates the escaped-quote-then-`?` comparison correctly (`true` for a matching value); R-Co
still returns `false` (ternary misdetection, uncorrected on that side). Decision: **keep**
Letflow's semantics — reverting to R-Co's non-escape-aware parity would mean deliberately
reintroducing a basic string-literal correctness bug just to match a known-wrong R-Co behavior,
which is a worse trade than the recorded divergence. See ISS-0087's resolution notes for the
regression tests locking this in.

Per REQ-111 this audit changes no engine behaviour; both findings are routed through WF-03.

### 9.2 `{:error, :translate_error}` — this design's own defensive addition, not a literal AC

§4.2's `:translate_error` result (malformed input the 4 rewrite rules cannot sensibly translate,
e.g. an empty condition string or a bare `variables.` with nothing after it) is not literally named
by the requirement text or by any of the 8 ACs — added the same way REQ-044 design doc §7.3 added
`:unknown_token_id` beyond its literal ACs, for `translate_cel_to_expr/1` to stay total rather than
raising on a shape REQ-029's CHK-13 should already prevent reaching this code in practice (§6).
TEST-DESIGNER should still cover it if practical, though no AC explicitly demands it.

### 9.3 Zero-outgoing-edge gateway — degenerate case, not separately named by an AC

PROVENANCE (historical, not current decision authority):
§5.4's closing note (a gateway with no conditioned edges and no default at all) is this design's
own totality-completing extension, matching REQ-044 design doc §6.6/§12.5's precedent for
catch-all totality additions beyond the literal ACs. Not separately verified against
`transition.zig`'s literal source (§0).

### 9.4 Comparison of mismatched-but-both-scalar types under `==`/`!=` — this design's own call

PROVENANCE (historical, not current decision authority):
§4.6 states `:eq`/`:neq` never error even across differently-typed operands (e.g. comparing a
string to a number always yields `false` for `==`, never a type-mismatch error), reasoning by
analogy to CEL's own general equality semantics. This is this design's own interpretive choice for
a case the requirement text does not explicitly walk through (it only names "type mismatch" as an
error case for the **ordering** comparisons, `<`/`<=`/`>`/`>=`) — not verified against
`evaluator.zig`'s literal source (§0). Flagged rather than silently assumed.

## 10. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-050 task acceptance criterion | Concrete design element |
|---|---|
| "a gateway whose second declared edge is the first to evaluate true routes the token down that edge, not the first or third" | §5.1 (declared-order `conditioned_edges` list) + §5.2 (first-true-wins loop, short-circuit on first `true`) |
| "a gateway with a default edge declared FIRST and two non-default edges that both evaluate false routes the token down the default edge, proving the default is evaluated last regardless of declared position" | §5.1 (`default_edge` structurally excluded from `conditioned_edges` regardless of its declared position) + §5.3 (default only considered after `conditioned_edges` exhausted, evaluated unconditionally, no condition check) |
| "a condition expression that raises a runtime error (undefined variable or type mismatch) is treated as false and evaluation continues to the next edge, rather than transitioning the instance to ERROR" | §4.6 (`eval/2`'s `:undefined_variable`/`:type_mismatch` error shapes) + §4.7/§5.2 (`evaluate_condition/2`'s catch-false composition folds any `eval/2` error into `false`, loop continues to the next `conditioned_edges` member) |
| "a gateway where no condition matches and no default edge exists transitions the instance to ERROR with a structured reason naming the gateway node_id AND the conditions that were evaluated" | §3 (`{:no_matching_edge, node_id, evaluated_conditions}` tuple shape, `evaluated_condition/0` type) + §5.4 (exact construction: node.id plus every conditioned edge's `edge_id`/`condition`/`result: false`) |
| "exactly one outgoing edge is followed in every passing case, asserted directly rather than inferred" | §5.5 (mutual-exclusivity argument: §5.2's match, §5.3's default, and §5.4's zero-edge error path are exhaustive and non-overlapping) |
| "a condition using an unsupported CEL feature (a macro, a type-conversion function, a collection function, or the ternary operator) evaluates to false via the catch-false rule rather than raising or erroring the instance, matching hasCelUnsupportedFeatures()'s boundary" | §4.4 (the 4 unsupported categories, ported and named) + §4.2 step 1 (`{:error, :unsupported_cel_feature}`, checked before any rewrite) + §4.7/§5.2 (folds into the same uniform catch-false as every other error) |
| "the CEL-to-expr translation is tested directly on each of its four documented rewrites (variables. prefix stripped, && -> and, || -> or, ! -> not with != passing through unchanged), rather than only end-to-end through gateway evaluation" | §4.3 (the 4 rules table, each independently statable/testable against `translate_cel_to_expr/1` directly, not only via `dispatch_exclusive_gateway/4`) |
| "the evaluator performs zero I/O and is deterministic, confirmed by inspection of its call graph and stated in the moduledoc, which cites src/engine/transition.zig's evaluateGatewayCondition() and src/expr/ as the ported reference and records which subset of the expression surface landed" | §7 (purity + determinism, grep/`mix xref` verification method) + §4 opening (moduledoc scope note: cites `evaluateGatewayCondition()`/`src/expr/`, states the landed subset, states `benchmark.zig` has no port) |

**Also addressed, matching this handoff's own explicit coverage list beyond the 8 formal ACs:**

| Handoff item | Concrete design element |
|---|---|
| Exact function signature and `@spec`/body-shape for the `EXCLUSIVE_GATEWAY` dispatch replacing the stub | §2 |
| New pure evaluator module's public signatures for CEL→expr translation and expr evaluation against variables | §4.2 (`translate_cel_to_expr/1`), §4.5/§4.6 (`parse/1`, `eval/2`), §4.7 (`evaluate_condition/2`) |
| The 4 exact `translateCelToExpr` rewrite rules and where each lives | §4.3 (table) + "all 4 live inside `translate_cel_to_expr/1`" |
| Catch-false semantics as one uniform rule, not several | §4.7, §5.2 (stated explicitly: "one rule, not separate branches") |
| Default-edge-last, first-true-wins declared-order algorithm | §5 (full algorithm, 4 subsections) |
| Exact shape of the no-match/no-default error tuple, extending `transition_error()` | §3 |
| REQ-029 invariants relied upon, stated as relied-upon not re-validated | §6 |
| Purity confirmed by call-graph inspection, same pattern as REQ-044's own moduledoc | §7 |
| Open questions listed explicitly | §9 (4 items) |
