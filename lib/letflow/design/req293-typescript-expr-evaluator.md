# REQ-293: TypeScript evaluator for the `Expr` grammar, wired into `DynamicFormRenderer`

Status: design — awaiting CODE-DESIGN-VALIDATOR.
Implements decision 0020 D1a's Sequencing step 10. Depends on REQ-284 (done), REQ-290
(done), REQ-292 (done). Gates REQ-294 (Dart evaluator, S9, dormant) via its own
`depends_on`.

## 1. Re-verification (2026-09-11, this session)

Read in full before writing this design, superseding anything below that would
otherwise repeat REQ-293's own description from memory:

- `lib/letflow/engine/expr.ex` (1490 lines) — the grammar. Confirmed: 6 comparison ops,
  `and`/`or`/`not`, 5 arithmetic ops (`+ - * / %`) + unary `-`, literals (int, float,
  string, bool, `null`), dotted variable paths, 8 pure builtins (`length`, `lower`,
  `upper`, `trim`, `contains`, `startsWith`, `endsWith`, `coalesce`), the 3-way infinity
  marker (`:infinity | :neg_infinity | :nan`) for float division, ASCII-only
  `lower`/`upper` (`String.downcase/upcase(s, :ascii)`), 4-byte-ASCII-only `trim`
  (space/tab/CR/LF, not `String.trim/1`'s Unicode set), nil-propagation rules that differ
  between arithmetic (nil is an error) and ordering comparison (nil propagates as
  `{:ok, nil}`), NaN's self-inequality (`:nan != :nan` is `true`), the 11 CEL surface
  markers (`@unsupported_call_markers`) that make an authored condition rejected rather
  than silently mis-translated, and `now`/`date_add`/`date_diff` permanently absent
  (impure, moduledoc "decided, permanent disposition").
- `priv/expr_conformance/corpus.json` — **40 entries** (`expr-001`..`expr-040`), each
  `{id, description, grammar_constructs: [tag,...], expression, variables, outcome}`.
  `outcome` is `{"status":"ok","value": <scalar|null|{"$marker":"infinity"|"neg_infinity"|"nan"}>}`
  or `{"status":"error","error_kind":"parse_failure"|"eval_failure"}`. Confirmed by direct
  read: `expr-029`/`030`/`031` are the 3 infinity-marker entries; `expr-026`/`027` are the
  ASCII-only lower/upper entries (`lower("CAFÉ")` → `"cafÉ"`, `upper("café")` → `"CAFé"`);
  `expr-028` is the 4-ASCII-char trim entry (`trim(" \thi there\r\n ")` → `"hi there"`).
- `priv/expr_conformance/manifest.json` — sibling file, `{corpus_schema_version: "1.0.0",
  capabilities: [30 sorted tag strings]}` — the exact same `grammar_constructs` tag
  vocabulary used inside `corpus.json` entries (one vocabulary, confirmed).
- `lib/letflow/design/req289-expr-conformance-corpus.md` §13 ("Addendum: REQ-290
  client-behaviour contract for the version/capability marker") — **the authoritative
  client-behaviour contract this design implements verbatim**, quoted in full in §5 below.
  `req290-corpus-drift-guard.md` owns the manifest's mechanism/schema only, not client
  behaviour — its own §4.5 points back to req289 §13.
- `lib/letflow/definitions/form_schema_expressions.ex` (definition-time counterpart) and
  `lib/letflow/engine/form_expression_reevaluation.ex` (REQ-292, server-side
  re-evaluation at task completion) — both read in full. Confirmed `x-ui` shape on a
  `form_schema.properties[field]` entry: `{"x-ui": {"visible_when"?: string,
  "computed"?: string, "cross_field_validation"?: {"expression": string, "message":
  string}}}` — all three independently optional. Confirmed: every expression variable
  reference is a **single-segment, top-level `properties` key** — no dotted paths, no
  `variables.` prefix (unlike gateway-edge CEL) — enforced at definition time by
  `form_schema_expressions.ex`'s validator, which this port must not silently relax.
  Confirmed scope: `visible_when`/`computed`/`cross_field_validation` apply **only to
  top-level scalar `properties` entries** — never to `items` inside a `type: array`
  field or to a nested `type: object`'s own `properties`. Confirmed "Failure vs. false":
  an eval failure on `visible_when` or `cross_field_validation` is never collapsed to
  `false` server-side (unlike `Expr.evaluate_condition/2`'s own collapse-to-false rule
  used only for gateway edges) — this client port must preserve the same distinction.
  Confirmed the one D1a "constraints on the shared grammar" point that surfaces in the
  server module: computed-field disagreement — server value always wins, an event is
  recorded, never an error surfaced to the user, never a silent overwrite with no record.
- `web/src/components/forms/DynamicFormRenderer.tsx` (271 lines, current). **Correction
  to REQ-293's own description**: it does NOT currently render via `FieldFactory`. It
  inlines its own field-type switch (string/textarea/select/number/boolean/date)
  directly in the JSX. `web/src/components/forms/FieldFactory.tsx` exports
  `renderFormField(...)` but a repo-wide grep found **zero call sites** — it is dead
  code today (built for REQ-284's `x-ui.widget` registry but never wired in). This is a
  pre-existing divergence, not something this requirement fixes (out of scope — noted
  as a finding in §9); this design wires the three expression kinds into
  `DynamicFormRenderer.tsx`'s own inline rendering, in place, not through `FieldFactory`.
- `web/src/utils/formSchemaParser.ts` (121 lines) / `web/src/types/forms.ts` — `TaskFormField`
  has **no fields today** for `visible_when`/`computed`/`crossFieldValidation`. This
  design adds them (§3).
- `web/src/components/canvas/CelExpressionEditor.tsx` / `web/src/utils/cel/celLanguage.ts`
  — confirmed **highlight-only**. `celLanguage.ts` is a CodeMirror `StreamLanguage`
  token*izer* for syntax colouring (keywords include CEL's `in`/`as`/`matches`, which
  this grammar explicitly rejects) — it produces CodeMirror decoration tags, not an AST,
  and has no evaluation semantics, no arity checking, no infinity-marker handling. **Not
  reusable** for the evaluator; the evaluator is written from scratch as a straight port
  of `expr.ex`'s tokenizer/parser/evaluator. `CelExpressionEditor.tsx` is unmodified by
  this requirement (§8).
- `web/package.json` — no CEL library present today (confirmed by dependency list read).
  No new runtime dependency is added by this design (§7).
- `web/vite.config.ts`, `web/tests/guards/source-scan.spec.ts` — confirmed the project's
  existing pattern for a Node-environment vitest file that reads a repo file via
  `node:fs` (`// @vitest-environment node` pragma + `readFileSync(join(__dirname, ...))`).
  The corpus-runner test (§6) uses the identical pattern to read
  `priv/expr_conformance/corpus.json` and `manifest.json` directly — no copy, no
  hand-transcription.

## 2. Module structure under `web/src/`

```
web/src/utils/expr/
  types.ts        — Value, InfinityMarker, Ast, EvalError, ParseFailure, EvalOutcome types
  tokenizer.ts     — tokenize(source): TokenizeResult
  parser.ts        — parse(source): ParseResult   (uses tokenizer.ts)
  evaluator.ts      — evalAst(ast, variables): EvalOutcome
  capability.ts     — checkManifestCompatibility(...), STATIC_CAPABILITIES
  translateCel.ts   — translateCelToExpr(celCondition): TranslateResult
  index.ts          — evaluateCondition, evaluateExpression — the two composed entry points
  tokenizer.test.ts
  parser.test.ts
  evaluator.test.ts
  translateCel.test.ts
  capability.test.ts
  conformanceCorpus.test.ts   — reads priv/expr_conformance/{corpus.json,manifest.json}
  divergenceSemantics.test.ts — the three named divergence-prone cases, beyond the corpus
```

One file per pipeline stage, mirroring `expr.ex`'s own section structure
(`translate_cel_to_expr/1` → tokenizer/parser → `eval/2` → `evaluate_condition/2`) so a
reviewer can map each `.ts` file to the `.ex` section it ports 1:1. No file in this
directory imports React, react-hook-form, or any DOM API — the evaluator is a pure
computation module, importable from a vitest Node environment with zero DOM/browser
globals, matching `expr.ex`'s own purity discipline (moduledoc "Purity and
determinism").

## 3. Types (`types.ts`) — no implementation, signatures/shapes only

```ts
export type InfinityMarker = 'infinity' | 'neg_infinity' | 'nan'

export type Value = number | string | boolean | null | InfinityMarker

export type CmpOp = 'eq' | 'neq' | 'lt' | 'lte' | 'gt' | 'gte'
export type ArithOp = 'add' | 'sub' | 'mul' | 'div' | 'mod'
export type BuiltinName =
  | 'length' | 'lower' | 'upper' | 'trim' | 'contains' | 'startsWith' | 'endsWith' | 'coalesce'

export type Ast =
  | { kind: 'lit'; value: Value }
  | { kind: 'var'; path: string[] }
  | { kind: 'not'; sub: Ast }
  | { kind: 'and'; left: Ast; right: Ast }
  | { kind: 'or'; left: Ast; right: Ast }
  | { kind: 'cmp'; op: CmpOp; left: Ast; right: Ast }
  | { kind: 'arith'; op: ArithOp; left: Ast; right: Ast }
  | { kind: 'neg'; sub: Ast }
  | { kind: 'call'; name: BuiltinName; args: Ast[] }

// Mirrors expr.ex's parse_error_reason() / internal_parse_error() (§6.2/§6.3) — this
// port has exactly one parse-error entry point (no unstructured parse/1 vs. structured
// parse_strict/1 split: the client only ever needs positions, so there is one parser,
// always positioned).
export type ParseErrorReason =
  | { kind: 'invalid_number'; text: string }
  | { kind: 'invalid_identifier'; text: string }
  | { kind: 'unexpected_char'; char: string }
  | { kind: 'unterminated_string'; text: string }
  | { kind: 'expected_rparen' }
  | { kind: 'unexpected_end_of_input' }
  | { kind: 'unexpected_token'; text: string }
  | { kind: 'trailing_input' }
  | { kind: 'unsupported_construct'; tag: string } // this port's own addition, see §5.2

export interface ParseFailure {
  line: number
  column: number
  tokenText: string
  reason: ParseErrorReason
}

export type ParseResult =
  | { ok: true; ast: Ast }
  | { ok: false; failure: ParseFailure }

// Mirrors expr.ex's {:eval_error, reason} shapes (eval/2's own error tuples).
export type EvalErrorReason =
  | { kind: 'type_mismatch'; op: string; operands: Value[] }
  | { kind: 'undefined_variable'; path: string[] }
  | { kind: 'null_in_arithmetic'; op: ArithOp | 'neg' }
  | { kind: 'division_by_zero' }
  | { kind: 'modulo_by_zero' }
  | { kind: 'wrong_arity'; name: BuiltinName; got: number }
  // this port's own addition: a call to now/date_add/date_diff, or a construct the
  // static tokenizer/parser plain rejects as unrecognised, never reaches eval — it is
  // caught at parse time (§5.2) as unsupported_construct, not here. This kind exists
  // only for defence-in-depth if a future corpus entry names an eval-time-only gap.
  | { kind: 'unsupported_at_eval' }

export type EvalOutcome =
  | { ok: true; value: Value }
  | { ok: false; error: EvalErrorReason }

export type TranslateResult =
  | { ok: true; exprSource: string }
  | { ok: false; reason: 'unsupported_cel_feature' | 'translate_error' }
```

`Ast`, `Value`, `EvalOutcome` above are the direct structural counterpart of `expr.ex`'s
`ast()`, `value()`, and `eval/2`'s `{:ok, value()} | {:error, {:eval_error, reason}}`
return shape — same node set, same operator closed unions, same 3-way infinity marker.
No node kind exists here that `expr.ex` does not have (D1a constraint 1: no local
extension of the grammar).

## 4. Tokenizer (`tokenizer.ts`)

Port of `do_tokenize/2`/`do_tokenize_positioned/4` (expr.ex lines 342–747). Always
position-tracking (line/column) — this port has no non-positioned variant, since
`parse/1`'s un-positioned form exists in Elixir only because `evaluate_condition/2`'s
call graph doesn't need positions and REQ-197 didn't want to touch that call graph; the
TypeScript port has no such legacy caller to preserve byte-identically, so one tokenizer
suffices.

```ts
export interface Token {
  kind: 'lparen' | 'rparen' | 'comma' | 'cmpOp' | 'arithOp' | 'and' | 'or' | 'not'
      | 'lit' | 'var' | 'builtinCall'
  value?: CmpOp | ArithOp | Value | BuiltinName | string[]
  text: string
  line: number
  column: number
}

export type TokenizeResult =
  | { ok: true; tokens: Token[]; eofPos: { line: number; column: number } }
  | { ok: false; failure: ParseFailure }

export function tokenize(source: string): TokenizeResult
```

Byte-for-byte-equivalent lexical rules to `do_tokenize_positioned/4`:
- Whitespace class is exactly `[' ', '\t', '\n', '\r']` (§ same 4 ASCII chars `trim`
  also uses — one shared constant, `ASCII_WHITESPACE`, consumed by both this file and
  the builtin `trim` implementation in `evaluator.ts`, so the two can never drift
  relative to each other the way a hand-duplicated literal set could).
- Number regex: `/^-?\d+(\.\d+)?/` (decimal point makes it a JS `number` float
  internally regardless — TypeScript/JS has no native int/float type split the way
  BEAM does; §4.4's arithmetic port states explicitly how this port recovers the
  distinction it needs from source text, not from the runtime value's type).
- Identifier regex: `/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/`, with the same
  literal 8-clause keyword/builtin mapping table `identifier_token_kv/1` uses
  (`and`/`or`/`not`/`true`/`false`/`null`/8 builtin names), everything else becoming
  `{kind:'var', path: ident.split('.')}`.
- String literal scanning: same escaped-quote-only rule as `scan_string_literal/3`
  (a backslash immediately followed by the delimiter quote is consumed as one escaped
  unit; any other backslash sequence passes through literally — no `\n`/`\t` escape
  grammar).
- Every single-character/two-character operator token (`(` `)` `,` `==` `!=` `<=` `>=`
  `<` `>` `+` `-` `*` `/` `%`) — same set, same precedence-neutral tokenization (`-`
  always emits one `arithOp:'sub'` token regardless of unary/binary position, exactly
  as `expr.ex` does; the parser, not the lexer, decides which meaning applies).
- An unrecognised character is `{kind:'unexpected_char', char}`, matching
  `{:unexpected_char, <<c>>}`.

## 5. Parser (`parser.ts`)

Direct structural port of `parse_or_p`/`parse_and_p`/`parse_not_p`/`parse_cmp_p`/
`parse_additive_p`/`parse_multiplicative_p`/`parse_unary_p`/`parse_primary_p`/
`parse_call_args_p`/`parse_call_args_rest_p` (expr.ex lines 792–961) — same 8-level
precedence chain (lowest→highest: `or`, `and`, `not`, comparison, `+`/`-`, `*`/`/`/`%`,
unary `-`, primary), same left-associative folding, same right-recursive `not`/unary
`-`.

```ts
export function parse(source: string): ParseResult
```

### 5.1 One-for-one function correspondence (for REVIEWER to check against `expr.ex`)

| `.ts` function | `.ex` function | Precedence level |
|---|---|---|
| `parseOr` | `parse_or_p/2` | or (lowest) |
| `parseAnd` | `parse_and_p/2` | and |
| `parseNot` | `parse_not_p/2` | not |
| `parseCmp` | `parse_cmp_p/2` | comparison (non-associative — one `cmp_op` max per level, matching `expr.ex`'s own non-chaining `case rest do [%{kind: :cmp_op}...` clause, not a fold) |
| `parseAdditive` | `parse_additive_p/2` | `+`/`-` |
| `parseMultiplicative` | `parse_multiplicative_p/2` | `*`/`/`/`%` |
| `parseUnary` | `parse_unary_p/2` | unary `-` |
| `parsePrimary` | `parse_primary_p/2` | literal / var / `(...)` / builtin call (highest) |
| `parseCallArgs` | `parse_call_args_p/2` | comma-separated builtin-call arg list |

### 5.2 Unsupported-construct handling (this port's own addition — D1a constraint 1)

`expr.ex`'s tokenizer/parser has no separate "unsupported construct" concept at the
expr-syntax level — CEL-vocabulary rejection happens earlier, in
`translate_cel_to_expr/1`, against the *original CEL string*, before expr-syntax
tokenization ever runs. This port's `translateCel.ts` (§5.3) mirrors that same earlier
check. `parser.ts` itself never needs an `unsupported_construct` case in practice for
input that already passed `translateCel.ts` — the `ParseErrorReason` variant exists
purely as defence-in-depth (an internal consistency assertion, not a reachable path for
well-formed input) and is exercised by one dedicated test (§6.4) constructing an
already-translated expr-syntax string directly (bypassing `translateCel.ts`) that
contains a construct outside this grammar's AST node set, asserting the parser rejects
it rather than mis-parsing it into some other node. This is the same defence-in-depth
posture `form_expression_reevaluation.ex`'s cycle-recheck already uses ("should be
unreachable... treated as an error, never a silent no-op").

### 5.3 CEL translation (`translateCel.ts`)

Direct port of `translate_cel_to_expr/1` (expr.ex lines 215–304):
- Strip `variables.` prefix (`stripVariablesPrefix`).
- `&&` → `" and "`, `||` → `" or "` (padded, exact same ISS-0085/GH#302 rationale —
  unpadded rewrite fuses adjacent identifiers).
- `!` not immediately followed by `=` → `"not "` (negative lookahead, same as
  `rewrite_not/1`'s regex).
- `@unsupportedCallMarkers` — the same 17-entry literal array (`has(`, `matches(`,
  `all(`, `exists_one(`, `exists(`, `int(`, `uint(`, `double(`, `string(`, `bool(`,
  `bytes(`, `duration(`, `timestamp(`, `size(`, `map(`, `map{`, `filter(`), plus the
  same `in`-as-bare-word regex and bare-`?`-outside-string-literal detection, both
  checked against the *original*, untranslated CEL string, with the same
  `stripStringLiterals` pre-pass (regex-replace quoted-string bodies with an empty
  quoted string before running either detector) — copied constant-for-constant from
  `@unsupported_call_markers` and `unsupported_cel_feature?/1`, not re-derived.

```ts
export function translateCelToExpr(celCondition: string): TranslateResult
```

## 6. Evaluator (`evaluator.ts`)

Direct port of `eval/2` (expr.ex lines 1121–1468) and its private helpers
(`applyArith`/`applyIntArith`/`applyFloatArith`/`applyNeg`/`applyOrdering`/
`applyBuiltin`/`resolveVar`/`checkArity`).

```ts
export function evalAst(ast: Ast, variables: Record<string, unknown>): EvalOutcome
```

Semantics ported with no local extension, each cross-checked against the exact
`expr.ex` clause it corresponds to:

- **Comparison (`eq`/`neq`)**: `:nan` never equals anything including itself
  (`lv === 'nan' || rv === 'nan'` short-circuits to `op === 'neq'`), matching REQ-197
  §4.6's override, checked *before* the generic `===`/`!==` fallback — JS `===` would
  otherwise treat the two `'nan'` string literals as equal, which is coincidentally
  correct for `eq`/wrong for `neq`'s complement if left unguarded, so the explicit
  check stays regardless of representation choice (see §6.1 on why the marker is
  represented as a branded string, not `NaN`).
- **Ordering (`lt`/`lte`/`gt`/`gte`)**: `null` on either side → `{ok:true, value:null}`
  (propagates, not an error — REQ-197's asymmetry vs. arithmetic's null-is-error rule,
  §4.5). `'nan'` on either side → `{ok:true, value:false}` for every ordering operator.
  `'infinity'`/`'neg_infinity'` participate as the greatest/least possible value
  (`applyOrdering`, direct port of `apply_ordering/3`'s cond chain). Plain numbers
  compare via native `<`/`<=`/`>`/`>=`.
- **Arithmetic**: null on either operand → error (`null_in_arithmetic`), checked before
  any type/promotion logic (matches `apply_arith/3`'s clause order exactly).
  Non-number operand → `type_mismatch`. **Integer-vs-float dispatch is source-text-
  derived, not JS-runtime-derived**: the tokenizer (§4) already tagged each numeric
  literal as originating from an integer-shaped or decimal-shaped source token; `Ast`
  literal nodes and resolved variable values carry that provenance forward via a
  parallel `isFloatLiteral` flag threaded alongside the numeric AST node (an addition
  to the `{kind:'lit', value}` node not shown in §3's type for brevity — full shape:
  `{kind:'lit', value: number, numericKind?: 'int' | 'float'}`, `numericKind` present
  only when `value` is a `number`). Variables resolved from the caller's `variables`
  object have no such provenance (a plain JS `number` has no int/float tag) — see §6.2
  for how this port resolves that specific gap, since it is one `expr.ex` itself never
  has to answer (BEAM integers and floats are genuinely different runtime types).
  Integer `/`/`%` by zero → `division_by_zero`/`modulo_by_zero` errors (exact-int path,
  same as `apply_int_arith`'s `:div`/`:mod` zero clauses). Float `/` by `0.0` → the
  signed 3-way marker (`0.0/0.0` → `'nan'`, positive dividend → `'infinity'`, negative
  dividend → `'neg_infinity'`), constructed by explicit sign check — **never** by
  relying on native JS division, which would produce real `Infinity`/`-Infinity`/`NaN`
  (the divergence-prone semantic REQ-289's corpus AC4 pins, §6.4). Float `%` by any
  divisor is unconditionally an error (`modulo_by_zero`), matching
  `apply_float_arith(:mod, ...)`'s unconditional-error clause (float modulo is never
  attempted, zero divisor or not — ported literally, not "fixed" to behave like JS `%`).
- **Unary negation**: negating `'infinity'`/`'neg_infinity'` flips the marker;
  negating `'nan'` stays `'nan'`; negating `null` is `null_in_arithmetic`.
- **Builtins**: `length`/`lower`/`upper`/`trim`/`contains`/`startsWith`/`endsWith`/
  `coalesce`, arities `{exactly:1}` for the first four, `{exactly:2}` for the middle
  three, `{atLeast:1}` for `coalesce`, all args evaluated left-to-right before arity
  check before dispatch (same order as `eval({:call,...})`'s `with` chain). `lower`/
  `upper` use an explicit ASCII-only case table (§6.3), never `String.toLowerCase()`/
  `.toUpperCase()`. `trim` strips only `ASCII_WHITESPACE` (the same 4-char set §4
  defines), never `String.prototype.trim()`. `nil` (JS `null`) argument to any of the
  8 builtins propagates as `{ok:true, value:null}` before any type check, exactly
  mirroring each `apply_builtin(:name, [nil])` clause. `now`/`date_add`/`date_diff`
  **do not exist as implemented functions anywhere in this module or file** — not
  merely omitted from the closed builtin-name union in `types.ts` (§3), but absent as
  named functions, verified by the grep in AC2 (§10).
- **Variable resolution**: successive string-keyed lookups through nested plain
  objects (`resolveVar`, port of `resolve_var/3`); a missing key at any step, or a
  non-object encountered mid-path, is `undefined_variable`, never `undefined`/`null`
  silently substituted.

### 6.1 Why the infinity marker is a branded string, not JS `NaN`/`Infinity`

A design decision, stated explicitly rather than left implicit: `Value` represents
`:infinity`/`:neg_infinity`/`:nan` as the **string literals** `'infinity'`/
`'neg_infinity'`/`'nan'` (a closed 3-member string union, `InfinityMarker`), never as
native JS `Infinity`/`-Infinity`/`NaN`. Reasons: (1) native `NaN !== NaN` is already
JS's own self-inequality, which happens to *look* like a free ride for the `:nan`
comparison rule, but native `Infinity === Infinity` is `true` by IEEE-754-in-JS
already too — the risk is a future contributor "simplifying" `evaluator.ts` to just
use native division and native comparison operators, at which point the port silently
stops being a value-level port and starts depending on JS's arithmetic coercion rules
matching Erlang's by accident, which is exactly the divergence risk AC4 exists to catch
mechanically rather than by code review. A branded string forces every comparison and
every arithmetic clause touching these values through this module's own explicit
`if (v === 'infinity') ...` branches, the same way `expr.ex`'s own `:infinity` atom
forces every clause in `apply_ordering/3`/`apply_arith/3` to handle it by name. (2) JSON
round-tripping: the corpus's own `{"$marker": "infinity"}` encoding (§1) is a marker
object, not a bare numeric sentinel — the conformance test (§6.4) decodes it to this
same string union, so the two representations compose without a lossy numeric
intermediate.

### 6.2 Integer/float provenance for variables — an explicit open question, not silently resolved

`expr.ex` never has to ask "is this number an int or a float" for a *resolved variable*
either — a BEAM value already carries that distinction natively (`is_integer/1` vs.
`is_float/1`), same as for a literal. TypeScript/JS numbers carry no such tag. **This
design does not silently invent a heuristic** (e.g. "no fractional part → treat as
int") for a variable's runtime value, because `Number.isInteger(4.0)` is `true` in JS
even though `4.0` may have been intentionally authored as a float on the caller's side
(e.g. a value round-tripped from a JSON API that serializes `4.0` as `4`). Resolution
adopted here: **a resolved variable's numeric kind is always treated as `'float'`
promotion-wise if it is not a JS safe integer literal from the AST itself** — concretely,
`applyArith` promotes to the float path (§ apply_float_arith parity) whenever *either*
operand's provenance is unknown (i.e., came from `variables`, not from a `{kind:'lit'}`
node with a known `numericKind`), and only takes the integer path
(`apply_int_arith` parity — truncating `/`, `%` via `Math.trunc`) when *both* operands
are literal-provenanced `numericKind: 'int'`. This means a variable-vs-variable or
variable-vs-literal-float arithmetic expression always evaluates via the float path in
this client, which can diverge from the server's actual int/int division truncation for
an all-integer *variable* expression (e.g. `amount / 2` where `amount` is an integer
variable — this client's `amount / 2` runs float division, `7.0/2.0 = 3.5`, where the
server's `Expr.eval/2` — since `amount` really is a BEAM integer at that point — runs
`div(7, 2) = 3`). **This is flagged here as an explicit, unresolved divergence risk
against expr.ex's actual behavior for this one case (int-variable ÷ int-literal-or-
variable), not silently patched over.** It does not violate D1a constraint 1 (no local
grammar extension — no new syntax or semantics are added) but it is a genuine value-level
divergence the corpus's own 40 entries do not currently exercise (every corpus arithmetic
entry uses only literal operands, confirmed by re-reading `expr-011`..`expr-016`,
`expr-029`..`031`, `036`, `039` — none passes an integer through a `variables` map into
a `/` or `%`). Recommended follow-up, **not implemented by this requirement** (scope
fence, §8): either (a) REQ-289's corpus gains an int-variable-division entry that pins
the server's actual behaviour so both clients have something concrete to match, or (b)
`Letflow.Engine.FormExpressionReevaluation`'s task-completion authority (§1, "NO
AUTHORITY") is relied upon as the actual backstop for this one case, since this client's
`computed`-field output is always overwritten by the server's recomputation anyway
(§1) — meaning this specific divergence can only ever produce a *transient UI value*
between render and submission, never a persisted wrong number, for `computed` fields.
For `visible_when`/`cross_field_validation`, which the server also independently
re-evaluates and never trusts (§1, "NO AUTHORITY"), the exposure is a transient
UI-only mismatch on a form using this specific construct (int-variable division), report
this in the completion report as a named, deliberately-deferred finding rather than
silently shipping a heuristic fix.

### 6.3 ASCII-only `lower`/`upper` table

```ts
const ASCII_LOWER = new Map<string, string>() // 'A'-'Z' -> 'a'-'z', built once, module scope
const ASCII_UPPER = new Map<string, string>() // 'a'-'z' -> 'A'-'Z'
```

Implemented as a per-character map over `Array.from(s)` (iterating Unicode code points,
not UTF-16 code units, so a multi-code-unit character such as `É` — which JS represents
as a single code point outside the Latin-1 range — is visited once and left unchanged,
never split), replacing only characters present in the respective map and leaving every
other character (including `É`, `é`, digits, punctuation) byte-for-byte unchanged —
never `String.prototype.toLowerCase()`/`.toUpperCase()`, which are Unicode-aware and
would silently lowercase/uppercase `É`/`é` too.

### 6.4 The three divergence-prone semantics — explicit test obligations (AC4)

Each gets a dedicated test beyond the corpus run, in `divergenceSemantics.test.ts`:

1. `lower("CAFÉ")` → asserted `"cafÉ"` (not `"café"`, which is what
   `"CAFÉ".toLowerCase()` actually produces in JS — the test asserts against the
   corpus's own `expr-026` expected value, read from the corpus file, and separately
   asserts the raw JS `.toLowerCase()` result would have been `"café"`≠`"cafÉ"`, so the
   test is provably exercising the divergence, not merely restating the corpus).
2. `trim(" \thi there\r\n ")` → asserted `"hi there"` — plus a companion assertion that
   a Unicode-whitespace character (e.g. U+00A0 NO-BREAK SPACE or U+2003 EM SPACE)
   placed at either end of a string is **left in place** by this evaluator's `trim`,
   proving the 4-ASCII-char boundary is enforced, not merely that the 4 corpus
   characters happen to work.
3. `1.0 / 0.0` → `'infinity'`, `-1.0 / 0.0` → `'neg_infinity'`, `0.0 / 0.0` → `'nan'` —
   plus a companion assertion that plain native JS `1.0/0.0` (`Infinity`, a JS number)
   is strictly `!==` this evaluator's `'infinity'` string-branded result, proving the
   marker representation (§6.1) is actually load-bearing and not merely returning a
   value that happens to compare loosely-equal.

## 7. Capability/version check (`capability.ts`) — REQ-290's client contract, §13.1–13.2

```ts
export const STATIC_CAPABILITIES: ReadonlySet<string> // this evaluator's own
  // statically-known implemented-tag set, hand-maintained, one entry per
  // grammar_constructs tag this module actually implements — the 30 tags in
  // manifest.json today (§1), enumerated literally, not derived by introspection
  // (TypeScript has no equivalent of Code.Typespec-derived reflection over this
  // module's own dispatch tables at build time within this requirement's scope).

export interface ManifestCompatibility {
  compatible: boolean
  unsupported: string[]  // manifest.capabilities - STATIC_CAPABILITIES, empty iff compatible
}

// §13.1 point 1 — coarse, proactive, at load/startup.
export function checkManifestCompatibility(manifestCapabilities: string[]): ManifestCompatibility

// §13.1 point 2 — fine, reactive, per parsed AST, defense in depth. Walks `ast` and
// returns every grammar_constructs-shaped tag the AST actually uses that is NOT in
// STATIC_CAPABILITIES. In practice, for THIS client, always empty when
// checkManifestCompatibility already returned compatible: true, since this client
// implements everything it declares in STATIC_CAPABILITIES with no partial/best-effort
// node kinds. Kept as a real, separately-callable, separately-tested function (not
// inlined into checkManifestCompatibility) because the two checks answer different
// questions per §13.1 ("even with an empty difference at load time, a client that
// encounters a specific expression...") and a future capability could legitimately be
// declared-but-partially-implemented, at which point this function is what catches it.
export function checkAstCapabilities(ast: Ast): string[]
```

This is the **superset check** REQ-290's own reference implementation
(`test/support/req290_capability_check.ex`) establishes: compatible iff
`manifestCapabilities ⊆ STATIC_CAPABILITIES` (every tag the manifest requires is one this
client statically implements); `unsupported` names the specific missing tags for a
diagnosable failure message, never a bare "incompatible" boolean with no detail. This
is a **set-membership check on the tag vocabulary**, not a semver-string comparison —
`corpus_schema_version` itself is read and surfaced in the failure state's diagnostic
text (§8.3) but is never parsed/compared as a version number by this function; per
REQ-290's own design (§4.3, relayed by the research pass), semver classification is a
human/CI-time bump-policy concern, not a load-time mechanical gate.

```ts
// Composed startup check DynamicFormRenderer calls once per form_schema load.
export function evaluatorCompatibility(manifest: { capabilities: string[] }): ManifestCompatibility
```

## 8. Wiring into `DynamicFormRenderer.tsx`

### 8.1 `TaskFormField` additions (`web/src/types/forms.ts`)

```ts
export interface TaskFormField {
  // ...existing fields, unchanged...

  /** REQ-293 — x-ui.visible_when, the raw CEL-syntax condition string, or undefined. */
  visibleWhen?: string

  /** REQ-293 — x-ui.computed, the raw CEL-syntax expression string, or undefined. */
  computed?: string

  /** REQ-293 — x-ui.cross_field_validation, both sub-keys present together or absent
   *  together (matches the server's own %{"expression"=>_, "message"=>_} pairing —
   *  never one without the other). */
  crossFieldValidation?: { expression: string; message: string }
}
```

`formSchemaParser.ts`'s `parseField` gains a companion read of `schema['x-ui']`
alongside REQ-284's existing `xUiWidget`/`xUiMask` read (same object, same optional-key
pattern, three more keys added to the existing `if (xUi) { ... }` block) — additive,
matches how `x-ui.widget`/`x-ui.mask` were added previously; no existing `x-ui` read
path changes shape.

### 8.2 Evaluation context and the "unevaluable" per-field state — the AC5 design decision

`DynamicFormRenderer` builds one `variables: Record<string, unknown>` object per render
from the current `react-hook-form` `watch()`-observed values of every top-level field
(scoped to top-level `properties` keys only, per §1's confirmed scope — nested
object/array fields are never inputs to these three expression kinds). This is the
single evaluation context passed to every `visible_when`/`computed`/
`cross_field_validation` expression on this render, matching the server's own
`working` map construction in `form_expression_reevaluation.ex` (`current_variables`
merged with `output_variables` — here, the client's only source of "current" is the
form's own live values, since there is no separate server-fetched variable set at
render time).

**The three-way per-field expression state (this is the concrete UX mechanism AC5
requires, not left open):**

```ts
export type ExpressionFieldState<T> =
  | { kind: 'evaluated'; value: T }
  | { kind: 'unevaluable'; reason: string }  // reason is a short, field-scoped,
                                              // human-readable diagnostic (not the raw
                                              // EvalErrorReason/ParseFailure — those are
                                              // logged via console.error for developer
                                              // diagnosis, kept out of the rendered UI
                                              // text to avoid leaking internal grammar
                                              // vocabulary to an end user filling a form)
```

A `useFormExpressions(formFields, variables, manifestCompatibility)` hook (new,
`web/src/components/forms/useFormExpressions.ts`) computes, per render:

- `visibility: Record<fieldName, ExpressionFieldState<boolean>>` — for every field
  carrying `visibleWhen`.
- `computedValues: Record<fieldName, ExpressionFieldState<Value>>` — for every field
  carrying `computed`, evaluated in the same dependency-topological order
  `form_schema_expressions.ex`'s `build_computed_dependency_graph/1` establishes
  server-side (this hook re-derives the same topological order client-side from the
  same graph-construction rule — edge A→B iff A's `computed` AST references
  `{kind:'var', path:['B']}` and B also carries `computed` — using the same Kahn's-
  algorithm-with-sorted-ties approach as `kahn_topological_sort/1`, so tie-breaking
  matches the server's order exactly on the rare case where more than one valid order
  exists and a computed field observes another computed field mid-recompute).
- `crossFieldErrors: ExpressionFieldState<string | null>[]` — one entry per field
  carrying `crossFieldValidation`, each either `{kind:'evaluated', value: message |
  null}` (the failing field's message when the expression evaluates to `false`, `null`
  when `true`) or `{kind:'unevaluable', reason}`.

**Mapping `ExpressionFieldState` to the three AC5-required, distinguishable render
outcomes:**

| Field kind | `'evaluated'` outcome | `'unevaluable'` outcome (never confused with the above) |
|---|---|---|
| `visible_when` | Render normally if `value === true`; omit from the DOM if `value === false` | **Rendered, not omitted**, wrapped in a distinct "condition unavailable" banner state (see §8.4) — this is the mechanism that makes "not defaulted to visible, not defaulted to hidden" concretely true: the field's normal input is not rendered at all in this state (so it is not "visible" in the sense of being a usable input), but the field's *row* (label + banner) still occupies its place in the form (so it is not "hidden" either — a sighted user scanning the form sees every field-shaped slot, and a screen reader encounters an `role="alert"` region at that position, neither silence nor a normal control) |
| `computed` | Render the field as **read-only**, populated with `value` | Render the field as read-only but with its input **replaced by the same "condition unavailable" banner**, never left as an empty/blank input — this is what makes "not rendered blank as though empty" concrete: an empty read-only input and this banner are visually and semantically distinct nodes, verified by the rendering test in §9.3 querying for the banner's own `data-testid`, not merely asserting the input's value is non-empty (an empty string is itself sometimes the CORRECT server-agreeing value for a computed field, so "non-empty" cannot be the test's own bar — "banner present, ordinary input absent" is) |
| `cross_field_validation` | Surface `value` (the message) as a form-level validation error when non-null | Surface a **distinct** form-level "validation unavailable" banner, separate from the ordinary per-rule error banner, at the same location the ordinary error would occupy — never silently treated as "no error" (which would let the form submit as if the rule passed) |

`ExpressionFieldState` is deliberately not a boolean/nullable collapse of "did it work"
— rendering code branches on `.kind`, so a lint-level `switch` with no default case
(TypeScript exhaustiveness checking) makes it a compile error to add a state without
updating every consumer, which is the concrete mechanism (not merely a convention) that
keeps the three outcomes from silently degenerating into two.

### 8.3 What makes an expression "unevaluable"

An expression is `unevaluable` for a field in exactly these cases, computed once at
`useFormExpressions`'s startup-compatibility check (§7) and reused per-field:

1. `evaluatorCompatibility(manifest).compatible === false` at load time — **every**
   `visible_when`/`computed`/`cross_field_validation` field on the whole form is marked
   `unevaluable` immediately, with `reason` naming the missing capability tags (§13.1
   point 1 — coarse, proactive, whole-form).
2. Otherwise, per-expression: `translateCelToExpr` returns `ok: false`, or `parse`
   returns `ok: false`, or `evalAst` returns `ok: false` — that specific field (and, for
   `computed`, every field downstream of it in the dependency graph, since a downstream
   `computed` field's own input becomes unavailable) is marked `unevaluable`, other
   fields on the same form unaffected (§13.1 point 2 — fine, reactive, per-expression).
3. `crossFieldValidation`'s eval result is a non-boolean value — the same "Failure vs.
   false" rule REQ-292's server module enforces (§1) — treated as `unevaluable`, never
   coerced to a truthy/falsy JS boolean.

Case 1's manifest access is resolved concretely, **not** via a new HTTP endpoint (which
would require a `lib/` route change, violating AC10) and **not** via a runtime `fetch`
of any kind. It is a **build-time Vite virtual module**, entirely within `web/`:

- `web/vite.config.ts` gains one new local plugin, `exprManifestPlugin()` (defined
  inline in the same file — no new npm dependency, `vite`'s plugin API
  `resolveId`/`load` hooks are already available from the existing `vite` devDependency).
  It resolves the specifier `virtual:expr-manifest` (prefixed internally with Vite's
  own `\0` convention so no other plugin/loader treats it as a real file) and, on
  `load()`, synchronously `readFileSync`s `../priv/expr_conformance/manifest.json`
  (relative to `web/`, i.e. the repo-root `priv/` directory Rollup/Vite already has
  filesystem access to at build/dev time — the same directory
  `conformanceCorpus.test.ts`, per §1, already reads directly via `node:fs`), then
  returns `export default ${JSON.stringify(manifest)}` as the module's source.
- This plugin is registered in the same `plugins: [...]` array `react()` already lives
  in — one array entry added, nothing else in `vite.config.ts` restructured.
- Because `vite.config.ts` is also the config Vitest loads by default (confirmed: no
  separate `vitest.config.ts` exists in `web/`, per this session's directory listing;
  `package.json`'s `test`/`test:watch`/`test:coverage` scripts invoke bare `vitest`
  with no `--config` flag), `capability.test.ts` can `import manifest from
  'virtual:expr-manifest'` in a test exactly as production code does — same code path
  exercised in tests and in the built app, not two divergent manifest-access strategies.
- `web/src/utils/expr/virtual-expr-manifest.d.ts` (new, `web/`-only) declares the
  ambient module for TypeScript: `declare module 'virtual:expr-manifest' { const
  manifest: { corpus_schema_version: string; capabilities: string[] }; export default
  manifest }` — shape-checked, not `any`.
- Production consumption: `DynamicFormRenderer` (or `useFormExpressions`, §8.2) does
  `import manifest from 'virtual:expr-manifest'` and calls
  `evaluatorCompatibility(manifest)` (§7) once per form-schema load — synchronous, no
  network round-trip, no loading/error state to design for a manifest fetch that can no
  longer fail at runtime (it is baked into the JS bundle at build time).
- **Drift**: there is no second, checked-in copy of `manifest.json` to fall out of sync
  with `priv/expr_conformance/manifest.json` — the plugin's `load()` reads the source
  file directly at every dev-server request and at every production build, so the
  bundled value is always exactly the current `priv/expr_conformance/manifest.json`
  content by construction, not by a separately-run drift-guard test. (Optionally, for
  dev-server ergonomics only: the plugin's `configureServer` hook may `fs.watch` the
  source file and trigger Vite's own module-graph invalidation so an edit to
  `manifest.json` during `npm run dev` hot-reloads without a manual restart — a
  convenience, not required for correctness, since a fresh `load()` on the next request
  would pick up the change regardless.)
- **Why this satisfies AC10 concretely**: every file this mechanism touches or adds —
  `web/vite.config.ts` (edited), `web/src/utils/expr/virtual-expr-manifest.d.ts` (new) —
  is under `web/`. `priv/expr_conformance/manifest.json` itself is read, never written
  or modified, and no file under `lib/` is touched, so `git diff` shows nothing under
  `lib/` modified, matching AC10's own wording exactly. (`priv/` is a sibling top-level
  directory to `lib/`, not a subdirectory of it, and REQ-290's own manifest file living
  there is unaffected by this requirement either way.)

### 8.4 The "condition unavailable" banner

A small, shared, low-decoration UI element (`web/src/components/forms/ExpressionUnavailableBanner.tsx`,
new) rendered wherever §8.2's table says "banner" — one component, three call sites
(field-row for `visible_when`, input-replacement for `computed`, form-level for
`cross_field_validation`), each passing a `field`/`kind` prop so the rendered text names
which field and which of the three logic keys is affected
(`data-testid="expr-unavailable-{field}-{kind}"`, the exact `data-testid` §9.3's
rendering tests query). Not a native `<input disabled>` — an `<input>` element, even
disabled, is a "visible input" in the DOM-query sense the AC5 tests must distinguish
from "not rendered visible."

### 8.5 `cross_field_validation` and Zod — no bypass of server authority (AC8)

`compileFormSchemaToZod` (existing, `jsonSchemaToZod.ts`) is **not** extended to encode
`cross_field_validation` rules as a Zod `.refine()` — this design deliberately keeps
the client-side cross-field check as a separate, parallel `crossFieldErrors` render
concern (§8.2), never merged into the `ZodSchema` react-hook-form's `zodResolver`
consumes for its own pass/fail gate on `handleFormSubmit`. Concretely:
`handleFormSubmit` (`DynamicFormRenderer.tsx` line 78, unchanged in this design) still
calls `onSubmit(values)` whenever react-hook-form's own Zod-driven validation passes,
**regardless of `crossFieldErrors`'s contents** — a client-side cross-field pass is
informational UI feedback shown alongside the form, never a submission gate, and a
client-side cross-field *failure* is likewise never wired to `form.handleSubmit`'s
own validity gate (it renders the banner from §8.2's table but does not call
`form.setError`/block the submit button). The actual authority remains
`Letflow.Engine.FormExpressionReevaluation.reevaluate/3` at task completion (§1), which
can still reject the submission (`:form_cross_field_validation_failed`) even when this
client's own check passed, agreed, or was itself `unevaluable` — the server path is
unconditional and does not consult anything this client computed. AC8's test (§9)
asserts this directly: a fixture where the client's `crossFieldErrors` evaluates to
"passing" is submitted, and the test asserts `onSubmit` is called with the client
values untouched by any cross-field gate — proving the pass is advisory, not a gate —
plus the completion report states this paragraph's mechanism verbatim as "where server
authority is retained" (AC8's own wording).

## 9. Open questions (explicit, not silently resolved)

1. ~~**Manifest transport**~~ — resolved in this rework (§8.3 case 1): a build-time Vite
   virtual module (`virtual:expr-manifest`, defined by a new `exprManifestPlugin()` in
   `web/vite.config.ts`) reads `priv/expr_conformance/manifest.json` at build/dev time
   and bundles it into the SPA — no runtime fetch, no new Phoenix route, no `lib/`
   change, no second copy to drift. No longer open.
2. **Integer-variable arithmetic divergence** (§6.2) — a genuine, corpus-unexercised
   value-level gap between this client and `expr.ex`'s actual int/int division
   truncation when both operands trace back to a `variables`-sourced integer rather
   than a literal. Recommended as a follow-up corpus entry or an accepted, bounded,
   transient-UI-only exposure (never a persisted-value exposure, per §1's "NO
   AUTHORITY"). Not fixed by inventing a client-side heuristic that could itself
   silently diverge a different way.
3. **`FieldFactory.tsx` dead code** (§1) — `renderFormField` has zero call sites
   today; this requirement does not wire it in (that would be an unscoped rewrite of
   `DynamicFormRenderer`'s entire rendering strategy, well past this requirement's
   fence) but the finding is worth a future requirement's attention independent of
   this one.

## 10. Acceptance-criteria mapping

| AC (abbreviated) | Where addressed |
|---|---|
| 1 — vitest suite reads real corpus, count-matches | §2 `conformanceCorpus.test.ts`; test asserts `parsedCorpus.length === 40` before running a single case, so a truncated read (e.g. a JSON parse that silently stops early) fails immediately rather than passing on a partial run |
| 2 — impure builtins absent, grep + rejection test | §6 (absence), grep command in completion report: `grep -rn "\bnow\b\|date_add\|date_diff" web/src/utils/expr/` expected zero hits as *implemented functions* (the string `"date_add"` may legitimately appear only inside a comment citing this exclusion, same as `expr.ex`'s own moduledoc does — the grep in the completion report is run with `-w`/function-call context, matching AC2's own phrasing "as implemented functions"); rejection test constructs `date_add(x, 1)` and asserts `translateCelToExpr`/`parse` rejects it (falls through `parsePrimary`'s unmatched-identifier-as-plain-var path — `date_add` is not a keyword, not a builtin, so it tokenizes as `{kind:'var', path:['date_add']}`, and the call-syntax `date_add(...)` then fails to parse as anything but a bare var followed by an unexpected `(` token, `unexpected_token` — exactly mirroring `expr.ex`'s own behaviour, since `date_add` was never added to *its* builtin whitelist either) |
| 3 — no CEL package added | §1 (verified), §7 (no such dependency touched) |
| 4 — three divergence-prone semantics, explicit tests | §6.4 |
| 5 — unevaluable state, three distinguishable outcomes | §8.2, §8.4 |
| 6 — REQ-290 marker triggers detection | §7, §8.3 case 1 — `evaluatorCompatibility(manifest)` called with the build-time-bundled `virtual:expr-manifest` module |
| 7 — one rendering test per key | §8.2's table drives three tests in `DynamicFormRenderer.test.tsx` (new, or extended if it exists — re-verify at implementation time): hidden-by-visible_when, computed-value-updates-on-input-change, cross-field-error-surfaced-with-message |
| 8 — client output never authoritative | §8.5 |
| 9 — no general scripting capability | §2's module set contains no `eval(`/`new Function`/`Function(`/dynamic `import(` — grep command for the completion report: `grep -rn "eval(\|new Function\|Function(\|import(" web/src/utils/expr/ web/src/components/forms/useFormExpressions.ts web/src/components/forms/ExpressionUnavailableBanner.tsx` |
| 10 — `lib/` untouched, `CelExpressionEditor.tsx` unmodified or stated why | §1 (confirmed unmodified — no reason to change it found; this requirement does not add gateway-condition client validation, per its own scope fence); §8.3's manifest-access mechanism is confirmed `web/`-only (edits `web/vite.config.ts`, adds `web/src/utils/expr/virtual-expr-manifest.d.ts`) specifically so this AC holds — no static route or other `lib/` change is introduced to serve the manifest |
| 11 — full `npm run check` chain passes | implementation-time, not a design concern |
| 12 — `expr.ex` unmodified, gaps reported not patched | §6.2 is exactly this: a found gap, reported, not silently closed by extending `expr.ex` or by adding client-only capability |

## 11. Scope-fence checklist (restated from the requirement's own text)

- Only `web/` changes. No `lib/` file touched, confirmed by this design adding no
  Elixir code anywhere.
- No CEL npm package added.
- No general scripting capability (`eval(`, `new Function`, `Function(`, dynamic
  `import(`) in any file this requirement adds.
- `CelExpressionEditor.tsx` unmodified (§1) — gateway-condition client-side validation
  is explicitly a separate, future requirement, not silently added here.
- No offline caching, no offline submission — this design's `useFormExpressions` hook
  reads `variables` from the form's own live, in-memory `watch()` state only; it does
  not read from or write to any persistent client-side store.
