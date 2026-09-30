# REQ-294: Dart evaluator for the `Letflow.Engine.Expr` grammar (`apps/mobile/`)

**Requirement:** REQ-294 (stage S9, was dormant, now active).
**Owner (implementer):** MOBILE-DEV.
**Depends on:** REQ-290 (done — corpus drift guard + `manifest.json`), REQ-292 (done —
server-side re-evaluation on submit), REQ-293 (done — TypeScript evaluator, `web/src/utils/expr/`),
REQ-419 (done — MOB-1 app shell), REQ-420 (done — tenant bootstrap).

Signatures and type shapes only. No function bodies, no `class ... { ... }` blocks with
real logic, no `.dart` files. Two pseudocode blocks below are explicitly marked
ILLUSTRATIVE (mapping/dispatch shape only, not implementation) — CODE-DESIGN-VALIDATOR
should treat every other block as a Dart-style signature/type declaration, not code to
compile.

---

## 0. Context already verified by ORCH this run (not re-verified here)

- `apps/mobile/` exists, MOBILE-DEV is active (roster confirms status "ACTIVE").
- `.claude/agents/mobile-dev.md` constraint 2 (amended 2026-09-08 per D1a) permits this
  work: `visible_when`, `computed`, cross-field validation, expressed only in the
  `Letflow.Engine.Expr` grammar, no general scripting runtime, client has no authority.
- REQ-290/292/293/419/420 are `status: done`.

## 1. Sources read for this design, and what they confirmed

- **`lib/letflow/engine/expr.ex`** (full, both halves — tokenizer, position-tracking
  tokenizer, both parsers, `eval/2` and every `apply_*` helper). This is the single
  source-of-truth grammar. Confirmed surface (unchanged since REQ-290's own re-check):
  - `cmp_op` (6): `eq neq lt lte gt gte`.
  - `arith_op` (5): `add sub mul div mod`. Unary negation is a separate `ast()` variant
    (`{:neg, ast()}`), not a 6th `arith_op` member.
  - `builtin_name` (8, closed): `length lower upper trim contains startsWith endsWith coalesce`.
    `now`/`date_add`/`date_diff` are deliberately absent (moduledoc lines 37–58) — not a
    gap, a permanent decision.
  - `ast()` (9 tagged variants): `:lit :var :not :and :or :cmp :arith :neg :call`.
  - `value()` = `number() | String.t() | boolean() | nil | infinity_marker()`, where
    `infinity_marker() :: :infinity | :neg_infinity | :nan` — never real BEAM
    `:infinity`/float-inf, always this 3-atom sentinel (`apply_float_arith/3`,
    lines 1403–1415).
  - Divergence-prone semantics pinned in `expr.ex` itself:
    - `lower/1`/`upper/1`: `String.downcase(s, :ascii)`/`String.upcase(s, :ascii)` —
      ASCII-only, not Unicode (lines 1286–1292).
    - `trim/1`: strips only `[?\s, ?\t, ?\n, ?\r]` — space, tab, `\n`, `\r` — via
      `ascii_trim_leading/1`/`ascii_trim_trailing/1` (lines 1296, 1336–1358), byte-level,
      not `String.trim/1`.
    - Float division by zero: `l == 0.0 and r == 0.0 -> :nan`; `l > 0.0 and r == 0.0 ->
      :infinity`; `l < 0.0 and r == 0.0 -> :neg_infinity` (lines 1408–1410). Integer
      division/modulo by zero are separate eval errors (`:division_by_zero`,
      `:modulo_by_zero`, lines 1387/1389), never routed through the float sentinel path.
    - Ordering with an infinity marker: marker is greatest/least possible value
      (`apply_ordering/3`, lines 1439–1447); `:nan` compares `false` against everything
      including itself, and `:nan == :nan` is `false` / `:nan != anything` is `true`
      (lines 1165–1176, 1192–1198).
    - Null in an ordering comparison **propagates** (`{:ok, nil}`), asymmetric with null
      in *arithmetic*, which is an eval error (`:null_in_arithmetic`, lines 1189–1190 vs.
      1365–1367).
  - No change to any of these since REQ-290/REQ-293 landed (re-grepped this session;
    `expr.ex`'s line count and the exact clauses above match what both prior designs
    quote).
- **`lib/letflow/design/req290-corpus-drift-guard.md`** (full). Confirmed the
  version/capability marker lives at `priv/expr_conformance/manifest.json`, its schema
  (`corpus_schema_version` semver string + `capabilities: [string]`, a sorted/deduped
  tag list in the `"cmp:eq"`/`"builtin:lower"` vocabulary), and that REQ-289's own
  companion doc §13 (not this file) holds the authoritative client-behaviour contract
  REQ-293 already implemented against — REQ-294 reads that same §13, not a Dart-specific
  reinterpretation.
- **`lib/letflow/design/req289-expr-conformance-corpus.md`** §13 (client-behaviour
  contract, read in full) and §2/§2.3 (corpus JSON schema, the closed `grammar_constructs`
  tag vocabulary — 6 cmp + 3 bool + 5 lit + 5 arith(+1 neg) + 2 var + 8 builtin = 30 tags).
- **`priv/expr_conformance/corpus.json`** — read directly (not the design doc's
  description of it). **40 entries**, ids `expr-001`..`expr-040`, bare JSON array (no
  wrapper object, no in-file version field — the version marker lives in the sibling
  `manifest.json` per REQ-290 §4.1's explicit design decision to keep `corpus.json`
  byte-shape-stable). First entry (`expr-001`, equality of a variable against an integer
  literal) and last entry (`expr-040`, null-in-ordering-comparison asymmetry) inspected
  directly to confirm shape:
  ```
  { "id": string, "description": string, "grammar_constructs": [string],
    "expression": string, "variables": object,
    "outcome": { "status": "ok", "value": <any JSON value, or {"$marker": "infinity"|"neg_infinity"|"nan"}> }
             | { "status": "error", "error_kind": "parse_failure" | "eval_failure" } }
  ```
- **`priv/expr_conformance/manifest.json`** — read directly. `corpus_schema_version:
  "1.0.0"`, `capabilities`: exactly 30 tags, alphabetically sorted, matching the §2.3
  vocabulary above one-for-one.
- **`web/src/utils/expr/`** (REQ-293, full: `types.ts`, `tokenizer.ts`, `parser.ts`,
  `translateCel.ts`, `evaluator.ts`, `capability.ts`, `index.ts`,
  `conformanceCorpus.test.ts`, `divergenceSemantics.test.ts`) and
  `lib/letflow/design/req293-typescript-expr-evaluator.md` (full, 759 lines). Confirmed:
  - `conformanceCorpus.test.ts` reads `priv/expr_conformance/corpus.json` and
    `manifest.json` from disk at test time via `readFileSync` + a relative path from
    `__dirname`, asserts `corpus.length === 40` **before** running any per-entry case,
    and generates one `it(...)` per corpus entry, mechanically, from the parsed array —
    exactly the "real test suite reading the corpus itself" shape AC3 requires. This is
    the direct model for the Dart suite (§6 below).
  - **Corpus/version alignment (AC4/AC12): no drift found.** REQ-293's suite ran against
    the same 40-entry `corpus.json` (`git log` shows exactly one commit ever touched
    `priv/expr_conformance/corpus.json` — `81f005d8`, REQ-289's own — no revision since)
    and the same `manifest.json` (`corpus_schema_version: "1.0.0"`, same 30 capabilities)
    that this design just re-read. **Finding: no discrepancy to report.** The Dart suite
    this design specifies must assert `length == 40` the same way, so any future drift
    is caught the same way REQ-293's suite would catch it.
  - The three divergence-prone semantics' TypeScript resolutions (ASCII case tables over
    `Array.from(s)` code points, a 4-character ASCII-whitespace `Set`, a branded 3-member
    `InfinityMarker` string union never compared against native JS `Infinity`/`NaN`) —
    read for cross-checking design *intent* against `expr.ex`, not ported blind; Dart's
    own idioms are used where they differ (§4 below).
  - **REQ-293's own flagged, unresolved finding (§6.2 of its design doc): int/float
    provenance for a *resolved variable's* arithmetic.** TypeScript/JS numbers carry no
    int-vs-float tag at the value level, so REQ-293 could only distinguish int/float
    arithmetic by tracking *AST-node* provenance (was this operand a literal
    `{kind:'lit', numericKind:'int'}`, or anything else) — and explicitly could not do
    better than "treat any variable-sourced operand as float-promotion-eligible," a
    documented, corpus-unexercised divergence risk against `expr.ex`'s true int/int
    `div`/`mod` truncation for an all-integer *variable* expression. **This finding does
    not transfer to Dart** — see §4.4 for why, and why this design does not need REQ-293's
    workaround or its open question.
  - `web/src/components/forms/useFormExpressions.ts` / `ExpressionUnavailableBanner.tsx`
    (REQ-293's renderer-wiring layer) — read for pattern only, not ported: REQ-294's own
    acceptance criteria do not require wiring this evaluator into a Dart form renderer
    (no such renderer exists yet to wire into — see next bullet), only that the evaluator
    exist and pass the corpus.
- **`apps/mobile/lib/renderers/form/form.dart`** — currently a tracked placeholder
  (`library;`, no logic), moduledoc states: "Form renderer: interprets `form`
  definitions, including on-device evaluation of `visible_when`/`computed`/cross-field
  validation ... Built starting REQ-426." **Confirms REQ-294's evaluator is a
  standalone, renderer-independent module** consumed by a future requirement
  (REQ-426/427, not in this requirement's `depends_on` and not built yet), not something
  this requirement wires into a live renderer itself.
- **`apps/mobile/lib/renderers/renderer_state.dart`** (full, `RendererState<T>`,
  `StaleVersionReason` sealed hierarchy, REQ-426's own design doc
  `lib/letflow/design/req426-mobile-renderer-state-and-list.md` §1). Confirmed
  **`UnevaluableExpression` already exists** as a `StaleVersionReason` variant:
  ```dart
  final class UnevaluableExpression extends StaleVersionReason {
    const UnevaluableExpression({required this.expression, required this.reason});
    final String expression;
    final String reason;
  }
  ```
  with its own doc comment: "Not exercised by the list renderer — reserved for the form
  renderer (REQ-427)." **This is the exact target shape REQ-294's evaluator must feed.**
  This design's own eval-failure surface (§5) is built so a future REQ-426/427 can
  construct `UnevaluableExpression(expression: <source>, reason: <this design's error
  description string>)` with no impedance mismatch and no re-interpretation needed.
- **`docs/mobile/requirements.md`** MOB-3, MOB-4 (full text), MOB-8 (full text). MOB-4's
  six mandatory states: **loading, fetch-failure, permission-denied, stale-version,
  validation-error, 429-backpressure.** MOB-4's 2026-09-08 addendum states the exact
  contract this requirement implements: pure CEL-subset grammar only, client has no
  authority, one shared conformance corpus across Elixir/TypeScript/Dart, unevaluable →
  stale-version, never silent-skip or silent-guess. MOB-8: offline **writes** excluded
  (unchanged, untouched by this design).
- **`docs/mobile/architecture.md`** §2 (dependency policy — "no runtime dependency
  beyond this list plus REQ-423's local cache store," referenced from `pubspec.yaml`'s
  own comment) and §5 (six-state rationale, "fails loudly instead of mis-rendering").
- **`docs/mobile/build-order.md`** — M5 (`MOB-4`) depends on M4 (`MOB-3`) and the
  form/list/task APIs; confirms REQ-294 sits logically *underneath* MOB-4's future form
  renderer (REQ-426/427), consistent with the "standalone module, not yet wired" finding
  above.
- **`docs/migration/decisions/0020-frontend-architecture.md`** D1a (full clause) — CEL
  subset only, client has no authority, one corpus across all three implementations,
  unevaluable → stale-version.
- **`apps/mobile/pubspec.yaml`** (full) — current runtime deps: `dio`, `flutter`,
  `flutter_appauth`, `flutter_riverpod`, `flutter_secure_storage`, `go_router`, `intl`,
  `path`, `path_provider`, `sembast`. No JSON/parsing package beyond Flutter's bundled
  `dart:convert` (already sufficient for this design — see §6).
- **`apps/mobile/test/guards/forbidden_dependencies_guard_test.dart`** (full) — **already
  blocks a CEL package structurally**, pre-dating this requirement: its own header
  comment reads "REQ-419 §6b: pubspec.yaml and pubspec.lock must contain no script
  runtime, no CEL package (REQ-294 forbids one on-device) ... `_forbiddenSubstrings =
  ['lua', 'wasm', 'cel']`." **This satisfies AC6 mechanically already** — this design
  adds no new guard, only confirms the existing one covers this requirement's own
  constraint and that `pubspec.yaml`/`pubspec.lock` need no edit (§7).

---

## 2. Module layout

New top-level directory, sibling to `apps/mobile/lib/{api,auth,bootstrap,definitions,design_system,features,i18n,renderers,shared}/`, following that same one-barrel-file-per-directory convention:

```
apps/mobile/lib/expr/
  expr.dart                  -- barrel: exports the public surface below
  expr_types.dart            -- ExprValue, InfinityMarker, CmpOp, ArithOp, BuiltinName, Ast subtypes
  expr_tokenizer.dart        -- tokenize()
  expr_parser.dart           -- parse(), ParseFailure
  expr_evaluator.dart        -- eval(), EvalOutcome, EvalErrorReason
  expr_translate_cel.dart    -- translateCelToExpr()
  expr_capability.dart       -- STATIC_CAPABILITIES, checkManifestCompatibility, checkAstCapabilities
  expr_field_outcome.dart    -- FieldExpressionOutcome (the 4-way stale/visible/hidden/blank sum type, §5)
```

One Dart file per pipeline stage, mirroring `web/src/utils/expr/`'s own module split
one-for-one (tokenizer / parser / translateCel / evaluator / capability / types), so a
REVIEWER comparing the two ports for one-for-one correspondence (the same check
`req293-typescript-expr-evaluator.md` §5.1 names for TS-vs-`expr.ex`) has an equally
direct Dart-vs-TS-vs-`expr.ex` three-way mapping.

Test layout, mirroring `apps/mobile/test/`'s existing per-directory convention
(`test/api/`, `test/auth/`, `test/definitions/`, ...):

```
apps/mobile/test/expr/
  expr_conformance_corpus_test.dart   -- §6: reads corpus.json + manifest.json directly
  expr_divergence_semantics_test.dart -- §4: the 3 divergence-prone semantics, explicit
  expr_capability_test.dart           -- capability.ts-equivalent: manifest/AST capability checks
  expr_impure_builtin_rejection_test.dart -- §5.5: now/date_add/date_diff rejection
```

---

## 3. Types (`expr_types.dart`) — signatures/shapes only

```dart
/// Mirrors expr.ex's infinity_marker() (AC7 — never Dart's double.infinity/
/// double.nan; a branded, closed, 3-member type so it cannot be confused with
/// a real IEEE 754 double at any call site).
enum InfinityMarker { infinity, negInfinity, nan }

/// Mirrors expr.ex's value(). Dart's `num` already subsumes `int`/`double`
/// distinctly (§4.4) — no separate "numeric provenance" flag is needed here,
/// unlike REQ-293's TypeScript port.
typedef ExprValue = Object?; // effectively: num | String | bool | null | InfinityMarker
// (Dart has no closed union types; call sites narrow via `is`/switch patterns
// on the 5 permitted runtime shapes. A `sealed`-class-wrapped alternative was
// considered and rejected — see §8 OQ-1.)

enum CmpOp { eq, neq, lt, lte, gt, gte }               // 6, matches cmp_op()
enum ArithOp { add, sub, mul, div, mod }                // 5, matches arith_op()
enum BuiltinName { length, lower, upper, trim, contains, startsWith, endsWith, coalesce }
// exactly 8 — structurally the only names apply_builtin can dispatch to (§5.5)

/// Mirrors expr.ex's ast() — 9 tagged variants, sealed so a switch over
/// ExprAst is exhaustiveness-checked by the Dart analyzer (AC8's "structurally
/// distinguishable" requirement, same discipline applied to the AST itself).
sealed class ExprAst {
  const ExprAst();
}

final class LitNode extends ExprAst {
  const LitNode(this.value, {this.numericKind});
  final ExprValue value;
  /// Present only when `value` is a `num` literal from the tokenizer — Dart's
  /// own `num` already distinguishes `int`/`double` at runtime (`value is int`),
  /// so this field is informational/diagnostic only, never load-bearing for
  /// arithmetic dispatch the way REQ-293's TS `numericKind` had to be (§4.4).
  final NumericKind? numericKind;
}
enum NumericKind { intKind, floatKind }

final class VarNode extends ExprAst {
  const VarNode(this.path);
  final List<String> path; // non-empty
}

final class NotNode extends ExprAst { const NotNode(this.sub); final ExprAst sub; }
final class AndNode extends ExprAst { const AndNode(this.left, this.right); final ExprAst left; final ExprAst right; }
final class OrNode extends ExprAst  { const OrNode(this.left, this.right);  final ExprAst left; final ExprAst right; }
final class CmpNode extends ExprAst { const CmpNode(this.op, this.left, this.right); final CmpOp op; final ExprAst left; final ExprAst right; }
final class ArithNode extends ExprAst { const ArithNode(this.op, this.left, this.right); final ArithOp op; final ExprAst left; final ExprAst right; }
final class NegNode extends ExprAst { const NegNode(this.sub); final ExprAst sub; }
final class CallNode extends ExprAst { const CallNode(this.name, this.args); final BuiltinName name; final List<ExprAst> args; }

/// Mirrors expr.ex's parse_error_reason() (8 shapes) plus this port's own
/// addition for a syntactically-valid-but-unrecognized construct (§5.4),
/// mirroring REQ-293's `unsupported_construct` addition one-for-one.
sealed class ParseErrorReason {
  const ParseErrorReason();
}
final class InvalidNumber extends ParseErrorReason { const InvalidNumber(this.text); final String text; }
final class InvalidIdentifier extends ParseErrorReason { const InvalidIdentifier(this.text); final String text; }
final class UnexpectedChar extends ParseErrorReason { const UnexpectedChar(this.char); final String char; }
final class UnterminatedString extends ParseErrorReason { const UnterminatedString(this.text); final String text; }
final class ExpectedRparen extends ParseErrorReason { const ExpectedRparen(); }
final class UnexpectedEndOfInput extends ParseErrorReason { const UnexpectedEndOfInput(); }
final class UnexpectedToken extends ParseErrorReason { const UnexpectedToken(this.text); final String text; }
final class TrailingInput extends ParseErrorReason { const TrailingInput(); }
/// This port's own addition (not in expr.ex, same class as REQ-293's TS
/// addition) — see §5.4/§5.5 for when this fires (impure-builtin rejection).
final class UnsupportedConstruct extends ParseErrorReason { const UnsupportedConstruct(this.tag); final String tag; }

@immutable
final class ParseFailure {
  const ParseFailure({required this.line, required this.column, required this.tokenText, required this.reason});
  final int line;
  final int column;
  final String tokenText;
  final ParseErrorReason reason;
}

sealed class ParseResult {
  const ParseResult();
}
final class ParseOk extends ParseResult { const ParseOk(this.ast); final ExprAst ast; }
final class ParseErr extends ParseResult { const ParseErr(this.failure); final ParseFailure failure; }

/// Mirrors expr.ex's {:eval_error, reason} shapes.
sealed class EvalErrorReason {
  const EvalErrorReason();
}
final class TypeMismatch extends EvalErrorReason { const TypeMismatch(this.op, this.operands); final String op; final List<ExprValue> operands; }
final class UndefinedVariable extends EvalErrorReason { const UndefinedVariable(this.path); final List<String> path; }
final class NullInArithmetic extends EvalErrorReason { const NullInArithmetic(this.op); final String op; }
final class DivisionByZero extends EvalErrorReason { const DivisionByZero(); }
final class ModuloByZero extends EvalErrorReason { const ModuloByZero(); }
final class WrongArity extends EvalErrorReason { const WrongArity(this.name, this.got); final BuiltinName name; final int got; }
/// This port's own addition, defence-in-depth only (parallel to REQ-293's
/// `unsupported_at_eval`) — should be unreachable in practice because
/// `parse()` already rejects unsupported constructs before `eval()` ever
/// sees an ExprAst (§5.4), kept only so eval()'s own switch is exhaustive.
final class UnsupportedAtEval extends EvalErrorReason { const UnsupportedAtEval(); }

sealed class EvalOutcome {
  const EvalOutcome();
}
final class EvalOk extends EvalOutcome { const EvalOk(this.value); final ExprValue value; }
final class EvalErr extends EvalOutcome { const EvalErr(this.error); final EvalErrorReason error; }

sealed class TranslateResult {
  const TranslateResult();
}
final class TranslateOk extends TranslateResult { const TranslateOk(this.exprSource); final String exprSource; }
final class TranslateErr extends TranslateResult { const TranslateErr(this.reason); final TranslateErrorReason reason; }
enum TranslateErrorReason { unsupportedCelFeature, translateError }

/// The 4-ASCII-char whitespace set shared by the tokenizer and `trim` — one
/// constant so the two can never drift relative to each other (§4.2), same
/// discipline as REQ-293's `ASCII_WHITESPACE`.
const Set<int> kAsciiWhitespaceCodeUnits = {0x20, 0x09, 0x0A, 0x0D}; // space, tab, \n, \r
```

---

## 4. The three divergence-prone semantics — Dart-specific designs

### 4.1 ASCII-only `lower`/`upper`

Dart's `String.toLowerCase()`/`toUpperCase()` are Unicode-aware (ICU-backed on most
platforms) — same divergence risk `expr.ex`'s moduledoc names for Elixir's own
`String.downcase/1`/`upcase/1` defaults, and the same one REQ-293 avoided for
JavaScript's `.toLowerCase()`/`.toUpperCase()`. Neither may be called directly.

**Design:** a fixed, module-scope `Map<int, int>` (or two 26-entry arrays indexed by
`codeUnit - 0x41`/`- 0x61`) mapping `'A'.codeUnitAt(0)..'Z'.codeUnitAt(0)` (0x41–0x5A) to
their lowercase counterparts (+0x20) and vice versa, applied per Unicode **rune** (via
`String.runes`, i.e. code points, not UTF-16 code units) so a surrogate-pair character
(anything outside the BMP) or a precomposed accented character like `É` (U+00C9, a
single rune, outside the 0x41–0x5A ASCII range) is visited once and left byte-for-byte
unchanged — never split, never mapped.

```dart
@spec asciiLower(String s) -> String
@spec asciiUpper(String s) -> String
// Implementation shape (illustrative signature comment, not code):
// String.fromCharCodes(s.runes.map((r) => (r >= 0x41 && r <= 0x5A) ? r + 0x20 : r))
// and the mirror-image for upper (0x61..0x7A -> -0x20).
```

Corpus cross-check: `expr-026`'s `lower("CAFÉ")` (confirmed present in `corpus.json`)
must assert `"cafÉ"` (È untouched), not `"café"` (what `'CAFÉ'.toLowerCase()` in Dart
actually produces — Dart's `String.toLowerCase()` is Unicode-aware exactly like JS's).
`expr_divergence_semantics_test.dart` must assert both: the corpus's expected value, AND
that `'CAFÉ'.toLowerCase() != 'cafÉ'` (proving the test exercises the real divergence,
not a coincidence — same double-assertion discipline REQ-293's test used, §6.4 of its
design doc).

### 4.2 Exact-4-ASCII-char `trim`

The 4 characters, exactly (matching `do_tokenize/2`'s own whitespace guard,
`expr.ex` lines 345–347 and 1344/1353): **space (U+0020), tab (U+0009), line feed
(U+000A), carriage return (U+000D)** — `kAsciiWhitespaceCodeUnits` above.

Dart's `String.trim()` strips Unicode whitespace per the `Characters`/ICU default
(a broader set including U+00A0 NO-BREAK SPACE, U+2003 EM SPACE, U+FEFF, etc.) — must
not be called directly, same class of divergence as `expr.ex`'s moduledoc names against
Elixir's own `String.trim/1`.

**Algorithm (exact, no further judgment call needed):**
```dart
@spec asciiTrim(String s) -> String
// 1. Walk s.runes from the front; while the current rune's code point is a member
//    of kAsciiWhitespaceCodeUnits, advance the start index by 1 rune.
// 2. Walk from the back; while the current trailing rune is a member of
//    kAsciiWhitespaceCodeUnits, retreat the end index by 1 rune.
// 3. Return the substring between the resulting start/end rune boundaries
//    (using String.substring on rune-boundary-safe indices derived from
//    Runes iteration, never raw UTF-16 code-unit slicing, so a >0xFFFF
//    character adjacent to a boundary is never split).
```
Test obligation (`expr_divergence_semantics_test.dart`): `asciiTrim(" \thi there\r\n ")
== "hi there"`, PLUS a companion assertion that a Unicode-whitespace character (e.g.
U+00A0 or U+2003) placed at either end is **left in place** — proving the 4-character
boundary is enforced, not merely that the corpus's own literal test characters happen to
work (mirrors REQ-293's `divergenceSemantics.test.ts` obligation #2 exactly).

### 4.3 Division-by-zero → the corpus's infinity encoding

`expr.ex`'s float-division-by-zero result is never a real BEAM float-infinity — it is
the 3-atom `infinity_marker()` sentinel, constructed by explicit sign comparison against
`0.0` (never via a float-formatting trick), per the exact table at `expr.ex` lines
1408–1410: `0.0/0.0 -> :nan`; `+/0.0 -> :infinity`; `-/0.0 -> :neg_infinity`.

Dart's native `/` on `double` **does** produce IEEE 754 `double.infinity`/
`double.negativeInfinity`/`double.nan` (Dart doubles are real IEEE 754, unlike the BEAM,
which raises `ArithmeticError` on `1.0/0.0` — this is a real platform difference from
`expr.ex`'s own implementation constraint, but the *design intent* — a branded sentinel,
never a raw platform float — must still hold so the evaluator's `ExprValue` never leaks a
real `double.nan`/`double.infinity` into a comparison or JSON-encoding call site where
`==` semantics would silently differ from the grammar's own NaN/infinity rules (§4.3.1)).

**Design:** `apply_float_arith` for `ArithOp.div` **never uses Dart's native `/`
directly on the zero-divisor path** — it checks `r == 0.0` first (mirroring `expr.ex`'s
own clause order) and returns the `InfinityMarker` enum value directly, by explicit sign
comparison of `l`, exactly matching the 3-row table above:

```dart
@spec applyFloatDiv(double l, double r) -> EvalOutcome
// r != 0.0  -> EvalOk(l / r)                         // ordinary Dart double division
// r == 0.0 && l == 0.0 -> EvalOk(InfinityMarker.nan)
// r == 0.0 && l > 0.0  -> EvalOk(InfinityMarker.infinity)
// r == 0.0 && l < 0.0  -> EvalOk(InfinityMarker.negInfinity)
```

Integer division/modulo by zero (`ArithOp.div`/`ArithOp.mod` on two Dart `int` operands)
are **not** routed through this at all — mirroring `apply_int_arith`'s own separate
`:division_by_zero`/`:modulo_by_zero` eval-error clauses (`expr.ex` lines 1387/1389),
they produce `EvalErr(DivisionByZero())`/`EvalErr(ModuloByZero())` directly, never a
marker. This distinction (int-path errors vs. float-path sentinel) must not be
collapsed.

#### 4.3.1 `==`/ordering must dispatch on `InfinityMarker`, never on `double.nan`/`double.infinity`

Because `ExprValue`'s infinity representation is the `InfinityMarker` enum (§3), not a
real Dart `double`, `EvalOutcome`'s `==`/`cmp`/ordering logic (mirroring `expr.ex`'s
`eval/2` `:cmp` clauses, lines 1161–1211) dispatches on `InfinityMarker.nan` explicitly —
`enum ==` in Dart is ordinary identity-based equality (unlike IEEE 754 `NaN != NaN`), so
the grammar's `:nan == :nan -> false` / `:nan != anything -> true` rule must be
implemented as an explicit `cond`-style check *before* falling through to generic `==`,
exactly mirroring `expr.ex`'s own ordering (lines 1169–1170, checked first) and
REQ-293's TS port (`evaluator.ts` lines 100–105) — never relying on `InfinityMarker.nan
== InfinityMarker.nan` evaluating to Dart's ordinary (and here, *wrong*) `true`.
Ordering (`lt/lte/gt/gte`) against `InfinityMarker.infinity`/`.negInfinity` as
greatest/least value mirrors `apply_ordering/3` (lines 1439–1447) exactly, one-for-one.

Test obligation: `1.0 / 0.0 -> InfinityMarker.infinity`, `-1.0 / 0.0 ->
InfinityMarker.negInfinity`, `0.0 / 0.0 -> InfinityMarker.nan`, PLUS a companion
assertion that Dart's own native `1.0 / 0.0` (`double.infinity`) is **not** `identical`
to nor `==` this evaluator's `InfinityMarker.infinity` (different types entirely — the
comparison itself should be a compile-time type mismatch if attempted directly, which is
itself part of the proof the marker representation is load-bearing, same discipline as
REQ-293's `divergenceSemantics.test.ts` obligation #3).

### 4.4 Why REQ-293's int/float-provenance open question does not transfer to Dart

REQ-293's TypeScript port (design doc §6.2) could not distinguish, for a value read out
of a JS `variables` object, whether that JS `number` was "really" an int or a float at
the grammar's own semantic level — JS has exactly one `number` type, so REQ-293 had to
fall back to *AST-node provenance* (was this operand a `{kind:'lit', numericKind:'int'}`
node) and documented an explicit, unresolved, corpus-unexercised divergence for an
all-integer-*variable* `/`/`%` expression (this client would wrongly run float division
where `expr.ex`'s real BEAM integer would truncate).

**Dart's `num` type does not have this problem.** Dart has genuinely distinct `int` and
`double` runtime types (`4 is int`, `4.0 is double`, checkable via `is`/`runtimeType` at
any point, including on a value freshly read out of a decoded-JSON `Map<String,
Object?>` `variables` binding) — `dart:convert`'s `jsonDecode` already preserves this
distinction from the JSON source text exactly the way `Jason.decode!/1` does on the
Elixir side (a JSON number token with no `.`/exponent decodes to Dart `int`; one with
either decodes to Dart `double`), which is the same encoding convention the corpus's own
`variables` objects and `expr.ex`'s own `Jason`-decoded definition payloads already rely
on. **Design decision: `apply_arith`'s int-vs-float dispatch is based on the *runtime
type of the evaluated operand values* (`lv is int && rv is int` → integer path;
otherwise → float path, promoting via `.toDouble()`), exactly mirroring `expr.ex`'s own
`is_integer(lv) and is_integer(rv)` dispatch (line 1373) — not on AST-node literal
provenance at all.** This is strictly more faithful to `expr.ex` than REQ-293's TS port
needed to settle for, and it closes REQ-293's own documented gap for the Dart client:
an int-variable-only `/`/`%` expression truncates exactly the way the server does,
because the variable's Dart `int`-ness survived the JSON decode intact. **No open
question is carried forward for this dimension** — this is a genuine, reportable
improvement over the TS port's necessarily-weaker approach, not a silently-taken
shortcut (contrast with §8's actually-open items).

`LitNode.numericKind` (§3) is retained anyway, purely as a diagnostic/self-documentation
field for the tokenizer's own literal-parsing step (does `"3"` vs `"3.0"` parse to `int`
vs `double` — itself already handled correctly by Dart's own `int.parse`/`double.parse`
dispatch on whether the literal text contains a `.`, mirroring `expr.ex`'s own
`String.contains?(match, ".")` check at tokenize time, lines 384–386/712–715) — it is
never consulted by `apply_arith`'s dispatch logic.

---

## 5. The impure-builtin-rejection design (AC5)

### 5.1 Structural impossibility, not a runtime blocklist

`BuiltinName` (§3) is a Dart `enum` with **exactly 8 values**:
`length, lower, upper, trim, contains, startsWith, endsWith, coalesce`. There is no
`now`, `date_add`, or `date_diff` member. The tokenizer's identifier-to-token mapping
(mirroring `expr.ex`'s `identifier_token/1`/`identifier_token_kv/1`, lines 415–433/
749–765) is a **fixed, exhaustive `switch` over string literals** dispatching to either
one of the 8 `BuiltinName` enum values or falling through to the catch-all
`VarNode(path)` clause — there is no enum-extension mechanism, no dynamic registration,
and no `String`-to-arbitrary-symbol conversion (Dart has no `String.to_atom/1`
equivalent risk to guard against, but the design still uses a closed literal `switch`,
never a `Map<String, BuiltinName>` built from external/config data, for the same
"grep-verified, not runtime-mutable" property `expr.ex`'s own moduledoc requires of
`@builtin_function_names`, lines 145–150).

**Consequence for AC5's "structurally impossible to add these without a visible diff":**
adding `now`/`date_add`/`date_diff` support would require (a) adding a 9th `BuiltinName`
enum value (a one-line diff any reviewer sees in `expr_types.dart`), AND (b) adding a
matching tokenizer `switch` clause (a one-line diff in `expr_tokenizer.dart`), AND (c)
adding an `applyBuiltin` dispatch clause (`expr_evaluator.dart`) — three separate,
visibly-diffed files, none of which can be done by data/config alone. This mirrors
`expr.ex`'s own `@builtin_function_names` + `identifier_token/1` + `apply_builtin/2`
three-site-consistency property exactly.

### 5.2 What happens when `now`/`date_add`/`date_diff` is referenced in an expression

Exactly the behaviour `expr.ex` itself exhibits for these three names (never added to
its whitelist either) and the behaviour REQ-293's TS port already verified matches:
`now`/`date_add`/`date_diff` tokenize as a **bare `VarNode(['now'])`** (an ordinary,
unrecognized identifier — the tokenizer's `switch` has no case for these strings, so
they fall to the catch-all variable clause), and a subsequent `(` makes the *parser*
fail with `UnexpectedToken` (a bare variable node cannot be immediately followed by a
call-argument list in this grammar's `parse_primary`/`parsePrimary` production — only a
`{kind: builtin_call, ...}` token, which these three names never produce, can be
followed by `(`). **Rejection shape:** `ParseErr(ParseFailure(reason:
UnexpectedToken(text: "(")))` — a structured parse failure, at the exact same
grammar-derived reason `expr.ex`'s own `parse/1` would independently produce for the
identical input (never a special-cased "impure builtin" error message; the rejection is
a side effect of the closed whitelist, not a separate check that could itself drift out
of sync).

### 5.3 Test obligation (`expr_impure_builtin_rejection_test.dart`)

Three test cases (`now()`, `date_add(x, 1)`, `date_diff(x, y)`), each asserting:
`parse(translateCelToExpr(expression is TranslateOk).exprSource) is ParseErr` with
`.failure.reason is UnexpectedToken`. Plus a grep-shaped structural assertion (run as
part of the same test file, reading `expr_types.dart`'s own source text via `dart:io`
`File.readAsStringSync()` — same self-verifying pattern `expr.ex`'s own moduledoc uses
via its documented `grep` command, §"Purity and determinism" lines 95–102): the string
`'now'` may appear only inside `BuiltinName`'s doc comments (never as an enum value name
or a tokenizer `switch` case target) — asserted via a regex that would fail if a future
edit added `now` as an actual `BuiltinName` member or tokenizer case, not just as prose.

---

## 6. Corpus-loading design (AC3/AC4/AC9/AC12)

### 6.1 File location (exact, no guessing required)

Both files are read from the **shared, single-source location** — no copy under
`apps/mobile/`:
- `priv/expr_conformance/corpus.json` (repo root)
- `priv/expr_conformance/manifest.json` (repo root)

`flutter test`, run from `apps/mobile/` (the Flutter package root — confirmed by
`apps/mobile/pubspec.yaml`'s presence there and every existing `apps/mobile/test/**`
file's own relative-path conventions), has its process working directory set to
`apps/mobile/`. The relative path from there to the corpus is therefore
**`../../priv/expr_conformance/corpus.json`** (`apps/mobile` → `apps` → repo root →
`priv/...`), and the same two-levels-up prefix for `manifest.json`.

```dart
@spec corpusFilePath() -> String
// p.normalize(p.join(Directory.current.path, '..', '..', 'priv', 'expr_conformance', 'corpus.json'))
// using package:path (already a transitive dependency via flutter_test / flutter
// itself -- no new pubspec entry required, see §7) so path separators are
// platform-correct on both the Windows dev host and any Linux CI runner.
@spec manifestFilePath() -> String
// same shape, "manifest.json"
```

**Why not `rootBundle`/an asset path:** this is a `flutter test` (pure-Dart-VM host
test), not a running app widget test — `rootBundle` requires a bound Flutter engine
this test does not need and should not require, mirroring why REQ-293's own
`conformanceCorpus.test.ts` uses a raw `node:fs` `readFileSync` (`// @vitest-environment
node`) rather than a bundler-mediated import for its own corpus read. `dart:io`'s
`File` is the direct equivalent.

### 6.2 Decoding and count assertion

```dart
@spec loadCorpus() -> List<CorpusEntry>
@spec loadManifest() -> ManifestData

@immutable
class CorpusEntry {
  const CorpusEntry({required this.id, required this.description, required this.grammarConstructs,
                      required this.expression, required this.variables, required this.outcome});
  final String id;
  final String description;
  final List<String> grammarConstructs;
  final String expression;
  final Map<String, Object?> variables;
  final CorpusOutcome outcome; // sealed, see below
}

sealed class CorpusOutcome { const CorpusOutcome(); }
final class CorpusOkOutcome extends CorpusOutcome {
  const CorpusOkOutcome(this.expectedValue);
  final ExprValue expectedValue; // decoded via decodeExpectedValue, see 6.3
}
final class CorpusErrorOutcome extends CorpusOutcome {
  const CorpusErrorOutcome(this.errorKind);
  final CorpusErrorKind errorKind;
}
enum CorpusErrorKind { parseFailure, evalFailure }

@immutable
class ManifestData {
  const ManifestData({required this.corpusSchemaVersion, required this.capabilities});
  final String corpusSchemaVersion;
  final List<String> capabilities;
}
```

`loadCorpus()`/`loadManifest()` are pure functions of the file's bytes (read once via
`File(...).readAsStringSync()`, decoded via `dart:convert`'s `jsonDecode` — no new
pubspec dependency, `dart:convert` is part of the Dart SDK) — no network, no platform
channel, no Flutter engine dependency (§9).

**Mandatory first assertion, before any per-entry test runs** (mirrors
`conformanceCorpus.test.ts` line 41's `expect(corpus.length).toBe(40)`):

```dart
test('has exactly 40 entries (a truncated read fails this before any case runs)', () {
  expect(loadCorpus().length, 40);
});
```

If a future corpus revision changes this count, this single assertion fails loudly and
by name before the 40 (or N) per-entry tests even attempt to run — exactly the
"structural read-completeness gate" REQ-293's suite already established, ported
unchanged in intent.

### 6.3 `$marker`-wrapped infinity values in the corpus JSON

The corpus's `outcome.value` field encodes an expected `InfinityMarker` result as
`{"$marker": "infinity" | "neg_infinity" | "nan"}` (confirmed by reading
`conformanceCorpus.test.ts`'s own `decodeExpectedValue` helper, lines 28–33 — this is
REQ-289's own corpus JSON encoding convention, not a TypeScript-specific one, so the
Dart reader needs the exact same decode step):

```dart
@spec decodeExpectedValue(Object? raw) -> ExprValue
// if raw is a Map<String, Object?> containing key "$marker", return the matching
// InfinityMarker enum value (raw["$marker"] as String, mapped "infinity" ->
// InfinityMarker.infinity, "neg_infinity" -> InfinityMarker.negInfinity,
// "nan" -> InfinityMarker.nan); otherwise return raw unchanged (already one of
// num | String | bool | null, all of which dart:convert produces natively for
// the corpus's non-marker outcome values).
```

### 6.4 Per-entry test generation

One `test(...)` per corpus entry, generated by iterating `loadCorpus()`'s returned list
(never a hand-copied subset — this is what makes the suite "run as a real Dart test
suite that reads the corpus file itself," AC3's literal wording):

```dart
@spec runCorpusEntry(CorpusEntry entry) -> void
// for entry.outcome is CorpusOkOutcome(expectedValue: v):
//   evaluateExpression(entry.expression, entry.variables) must be an ok-shaped
//   result (§6.5) whose value == decodeExpectedValue(v)  (Dart's own == on two
//   InfinityMarker enum values is ordinary identity equality here, which is
//   CORRECT for this assertion -- comparing the two SIDES' encodings of "this
//   entry expects :nan", not comparing IEEE NaN self-equality, which is a
//   distinct concern already covered by §4.3.1's evaluator-internal test)
// for entry.outcome is CorpusErrorOutcome(errorKind: k):
//   evaluateExpression(...) must be an error-shaped result whose STAGE matches
//   k (parseFailure -> the translate/parse stage; evalFailure -> the eval stage)
```

### 6.5 The composed entry point under test: `evaluateExpression`

```dart
sealed class EvaluateExpressionResult { const EvaluateExpressionResult(); }
final class EvaluateOk extends EvaluateExpressionResult { const EvaluateOk(this.value); final ExprValue value; }
final class EvaluateTranslateFailure extends EvaluateExpressionResult { const EvaluateTranslateFailure(this.reason); final TranslateErrorReason reason; }
final class EvaluateParseFailure extends EvaluateExpressionResult { const EvaluateParseFailure(this.failure); final ParseFailure failure; }
final class EvaluateEvalFailure extends EvaluateExpressionResult { const EvaluateEvalFailure(this.error); final EvalErrorReason error; }

@spec evaluateExpression(String celCondition, Map<String, Object?> variables) -> EvaluateExpressionResult
// Composition: translateCelToExpr -> parse -> eval, each stage's failure
// surfaced distinctly (never collapsed to one boolean) -- direct counterpart
// of expr.ex's own composition (evaluate_condition/2) MINUS its collapse-to-
// false rule, matching REQ-293's own `evaluateExpression` (index.ts lines
// 42-62) rather than its collapse-to-boolean sibling `evaluateCondition` --
// this is the function the conformance-corpus test and any future form-
// renderer caller both use, because both need distinguishable failure stages
// (the corpus test to assert the right stage failed; the form renderer to
// build the right StaleVersionReason, §5's design).
```

A second, boolean-collapsing entry point (`evaluateCondition`, mirroring
`expr.ex`'s own `evaluate_condition/2` one-catch-false-rule and REQ-293's
`index.ts` sibling function) is included in the barrel for parity/completeness but is
not the corpus test's own subject — same relationship REQ-293's design doc states
(`index.ts` lines 64–76).

---

## 7. `pubspec.yaml` — explicit non-change (AC6)

**No `pubspec.yaml` or `pubspec.lock` edit is part of this requirement's deliverables.**
Every capability this design needs — `dart:convert` (JSON decode), `dart:io` (`File`
read, test-only), `package:path` (already present transitively via `flutter_test`'s own
dependency graph — confirmed present in `pubspec.lock` today) — is already available.
No CEL package, no expression-evaluation package of any kind, is added.
`apps/mobile/test/guards/forbidden_dependencies_guard_test.dart` **already enforces
this mechanically** (its `_forbiddenSubstrings` list includes `'cel'`, added under this
exact requirement's own name in that test file's header comment) — MOBILE-DEV's
implementation does not need to add a new guard; it needs to confirm this existing one
still passes (it will, since no dependency is added).

If MOBILE-DEV's implementation genuinely needs a dev-only test-support package not
already present (none is anticipated by this design — `flutter_test`, `dart:convert`,
`dart:io`, `package:path` cover every need in §3–§6), it must be named and justified in
the implementation's own completion report before being added, per this design's own
instruction — this design itself identifies no such need.

---

## 8. Purity / no I/O (AC9) and no offline queue (AC10)

**Purity, by construction:** every function in `expr_tokenizer.dart`, `expr_parser.dart`,
`expr_translate_cel.dart`, `expr_evaluator.dart`, and `expr_capability.dart` is a pure
function of its typed arguments alone. None of them imports `dart:io`, `package:dio`
(this project's only HTTP client, per `docs/mobile/architecture.md` §2's "single API
client" invariant, already guarded by `apps/mobile/test/guards/single_api_client_guard_test.dart`),
any `flutter_secure_storage`/`sembast`/`path_provider` symbol, or any `async`/`Future`
return type — every signature in §3–§5 is synchronous. (`dart:io`'s `File` **is** used,
but only inside the two test-time loader functions in §6, which live under
`apps/mobile/test/`, never under `apps/mobile/lib/expr/` — the evaluator's own
production code path has zero I/O, only the test suite's corpus-reading fixture code
does, exactly mirroring `conformanceCorpus.test.ts`'s own `node:fs` import being
confined to the `.test.ts` file, never `web/src/utils/expr/`'s production modules.)

**How a test demonstrates "fillable with zero network reachable" (AC9's own instruction):**
`expr_conformance_corpus_test.dart` (§6) and `expr_divergence_semantics_test.dart` (§4)
both call `evaluateExpression`/the tokenizer/parser/evaluator functions **directly**,
against **fixture `Map<String, Object?>` variable bindings constructed in-test**, with no
`Dio`/`ApiClient`/`http` import anywhere in the call path — this is true by construction
(no such import exists to remove), not by a runtime network-disabled flag. A future
REQ-426/427 form renderer demonstrating the same property for a *cached* form would
follow the identical pattern: load a cached `form_schema` from `SembastCacheRepository`
(already offline-capable, REQ-423), then call `evaluateExpression` against that cached
schema's `computed`/`visible_when` expressions and the in-memory field values the user
has typed — no network call anywhere in that path either. This design does not build
that renderer-level demonstration (out of scope, §1's "standalone module" finding) but
states the shape precisely enough for REQ-426/427 to reuse.

**No offline submission queue (AC10):** nothing in `expr_types.dart` /
`expr_evaluator.dart` / `expr_capability.dart` persists an evaluation result anywhere —
`EvalOutcome`, `EvaluateExpressionResult`, and `FieldExpressionOutcome` (§5's design,
next section) are all plain, transient, in-memory value objects, never written to
`sembast`, `flutter_secure_storage`, or any file. No queue, no persistence layer, no
"pending submission" concept appears anywhere in this design. MOB-8's boundary
(offline **writes** excluded) is untouched — this requirement produces a pure
computation library, not a storage or sync mechanism.

---

## 9. The stale-version / default-visible / default-hidden / blank result type (AC8)

This is the structural bridge between this requirement's pure evaluator and the
already-existing `RendererState`/`StaleVersionReason` hierarchy (`renderer_state.dart`,
§1) that a future REQ-426/427 form renderer will consume. AC8 names exactly four
outcomes — this design gives them one closed, exhaustively-`switch`able sealed class,
`expr_field_outcome.dart`:

```dart
/// The four structurally distinguishable outcomes AC8 requires. A future
/// form renderer's `switch` over this type is exhaustiveness-checked by the
/// Dart analyzer -- there is no fifth "fell through" case possible without a
/// compile error, and no way to silently collapse StaleVersion into one of
/// the other three (each is its own sealed subtype, not a boolean flag on a
/// shared shape).
sealed class FieldExpressionOutcome {
  const FieldExpressionOutcome();
}

/// visible_when evaluated to `true` (or visible_when is absent -- a field
/// with no visible_when is always DefaultVisible, per D1a/MOB-4's own
/// "defaults to shown" convention -- confirmed against no contradicting
/// statement in expr.ex, requirements.md, or architecture.md; this is the
/// same default REQ-293's own web renderer uses per its design doc §8.2,
/// re-derived here rather than silently assumed).
final class DefaultVisible extends FieldExpressionOutcome {
  const DefaultVisible();
}

/// visible_when evaluated to `false`.
final class DefaultHidden extends FieldExpressionOutcome {
  const DefaultHidden();
}

/// A `computed` field's expression evaluated successfully to `null` (either
/// the expression's own result was `null` -- e.g. `coalesce(a, b)` where both
/// are null -- or a referenced input the computation depends on is itself
/// blank/unset, which resolves to `null` through ordinary variable
/// resolution, never a separate code path). Distinct from StaleVersion:
/// a well-formed, evaluable expression producing `null` is not a failure.
final class Blank extends FieldExpressionOutcome {
  const Blank();
}

/// AC8's mandatory failure state -- an expression this client could not
/// evaluate at all: a parse failure, an eval error (type mismatch, undefined
/// variable, null-in-arithmetic, division/modulo by zero surfacing as an
/// error rather than a marker, wrong arity), or a REQ-290 manifest
/// incompatibility detected before evaluation is even attempted (§10).
/// Never silently mapped to DefaultVisible/DefaultHidden/Blank -- see
/// evaluateFieldExpression's own totality argument below.
final class StaleVersion extends FieldExpressionOutcome {
  const StaleVersion({required this.expression, required this.reason});
  final String expression;
  /// Human-readable, matches the shape renderer_state.dart's own
  /// UnevaluableExpression.reason field already expects (String) -- this
  /// design's error descriptions (§10) are written to be passed straight
  /// through with no re-formatting needed by REQ-426/427.
  final String reason;
}
```

### 9.1 The two producing functions, and why StaleVersion cannot be reached silently

```dart
@spec evaluateVisibility(String? visibleWhenExpr, Map<String, Object?> variables) -> FieldExpressionOutcome
// visibleWhenExpr == null            -> DefaultVisible()   (no condition authored)
// evaluateExpression(...) is EvaluateOk(value: true)   -> DefaultVisible()
// evaluateExpression(...) is EvaluateOk(value: false)  -> DefaultHidden()
// evaluateExpression(...) is EvaluateOk(value: <non-bool>) -> StaleVersion(...)
//     (a visible_when authored against a non-boolean-producing expression is
//     itself a definition-time defect -- REQ-288's Expr.parse_strict/1-backed
//     definition validator, confirmed present server-side, see §1, is
//     supposed to reject this before it ever ships to a client; reaching
//     this client with one anyway is exactly the "drifted from the server's
//     definition format" case the six-state mechanism exists for, per
//     architecture.md §5 -- so StaleVersion, not a silent bool-cast guess,
//     is the correct outcome here too)
// evaluateExpression(...) is any *Failure -> StaleVersion(expression: visibleWhenExpr,
//     reason: describeFailure(result))   (§10)

@spec evaluateComputed(String? computedExpr, Map<String, Object?> variables) -> FieldExpressionOutcome
// computedExpr == null                          -> Blank()   (no computed expression authored)
// evaluateExpression(...) is EvaluateOk(value: null) -> Blank()
// evaluateExpression(...) is EvaluateOk(value: <non-null>) -> ??? -- see OQ-2, §11
//     (this design deliberately does NOT invent a fifth "ComputedValue(v)"
//     variant here -- see §11 OQ-2 for why that decision is left to
//     REQ-426/427, which owns the actual field-rendering contract)
// evaluateExpression(...) is any *Failure -> StaleVersion(expression: computedExpr,
//     reason: describeFailure(result))
```

**Totality argument for AC8:** `FieldExpressionOutcome` is `sealed` with exactly 4
subtypes; `evaluateVisibility`/`evaluateComputed`'s own return type is declared as
`FieldExpressionOutcome`, so the Dart analyzer requires every code path inside them to
produce one of the 4 — there is no `default:`/implicit-fallthrough branch a future edit
could quietly add that returns something else, and a *caller* `switch`-ing over the
result is itself exhaustiveness-checked the same way. This is the same "closed by
construction" argument `renderer_state.dart`'s own `RendererState<T>` sealed hierarchy
already relies on (§1) and the same argument REQ-290's `test/support/req290_capability_check.ex`
reference implementation makes for its own 2-arm union (`req290-corpus-drift-guard.md`
§5.1) — applied here to a 4-arm union instead of 2.

---

## 10. Failure-description mapping (`describeFailure`) and the REQ-290 capability gate

```dart
@spec describeFailure(EvaluateExpressionResult result) -> String
// EvaluateTranslateFailure(reason: r)  -> a fixed English sentence per TranslateErrorReason
//     value (2 cases: "unsupported CEL feature" / "malformed condition")
// EvaluateParseFailure(failure: f)     -> a fixed English sentence per ParseErrorReason
//     variant (mirrors expr.ex's own describe_parse_error/1, lines 580-588,
//     one clause per reason, INCLUDING this port's own UnsupportedConstruct
//     addition -- "references an unsupported builtin or construct")
// EvaluateEvalFailure(error: e)        -> a fixed English sentence per
//     EvalErrorReason variant (type mismatch, undefined variable, null in
//     arithmetic, division/modulo by zero, wrong arity, unsupported-at-eval)
// Never includes raw user input verbatim in a way that could be mistaken for
// executable text -- plain descriptive prose only, matching
// UnevaluableExpression.reason's own String type (renderer_state.dart, §1).
```

### 10.1 Manifest-capability check, gating BEFORE evaluation is attempted

Mirrors REQ-293's `capability.ts` (`checkManifestCompatibility`/`checkAstCapabilities`/
`evaluatorCompatibility`) one-for-one:

```dart
/// This evaluator's own statically-known implemented-tag set -- the 30 tags
/// in priv/expr_conformance/manifest.json today, hand-enumerated (same
/// "hardcoded but fails loudly on staleness" shape req290-corpus-drift-guard.md
/// §3.3 already accepts for its own @ast_tag_prefix_map -- a STATIC_CAPABILITIES
/// entry drifting from manifest.json's real content can only ever cause an
/// incompatibility to be (correctly) reported, never a silent pass).
const Set<String> kStaticCapabilities = { /* the 30 tags, §1's manifest.json read */ };

@immutable
class ManifestCompatibility {
  const ManifestCompatibility({required this.compatible, required this.unsupported});
  final bool compatible;
  final List<String> unsupported; // manifest.capabilities - kStaticCapabilities
}

@spec checkManifestCompatibility(List<String> manifestCapabilities) -> ManifestCompatibility
@spec checkAstCapabilities(ExprAst ast) -> List<String>
  // walks the AST (mirrors capability.ts's visit()) collecting every
  // grammar_constructs-shaped tag actually used, filtered to those NOT in
  // kStaticCapabilities -- defence in depth, catching a case the coarse
  // manifest-level check alone would miss (an old manifest whose
  // capabilities list itself hasn't been updated yet, but whose actual
  // corpus/server now emits a construct this client doesn't implement)
```

A future REQ-426/427 form-load sequence calls `checkManifestCompatibility` once per
cached `manifest.json` fetch/bundle (this requirement does not itself decide how the
Dart client obtains `manifest.json` at runtime — that is REQ-426/427's own
definition-sync-integration decision, analogous to REQ-293's build-time Vite virtual
module, §9 item 1 of its design doc — flagged as an open item for that future
requirement, §11 OQ-1 below, not resolved here) and, on incompatibility, treats every
field whose expression references one of the `unsupported` tags as `StaleVersion`
up front, before ever calling `evaluateVisibility`/`evaluateComputed` — the same
"coarse, proactive, at load/startup" check REQ-293's design doc §7 describes (its own
`req293-typescript-expr-evaluator.md` §"Capability/version check" section).

---

## 11. Open questions / findings (explicit, not silently resolved)

1. **How the Dart client obtains `priv/expr_conformance/manifest.json` at *app* runtime
   (not test time) is not decided by this design.** REQ-293 resolved the equivalent
   question for the SPA via a Vite build-time virtual module (`virtual:expr-manifest`).
   Flutter has no direct analogue to a Vite virtual module; the two live options —
   (a) bundle `manifest.json` as a Flutter asset (`pubspec.yaml` `flutter.assets:`,
   requiring a build-time copy step from `priv/expr_conformance/` into
   `apps/mobile/assets/` or an equivalent symlink/script) or (b) have the server expose
   it over an existing API surface and let REQ-424's definition-sync machinery fetch it
   alongside form definitions — are both genuinely open and belong to whichever future
   requirement (REQ-426/427) actually wires this evaluator into a live renderer, since
   only that requirement's own definition-sync design can settle it correctly. **Not
   resolved here, not silently defaulted to option (a) or (b).**
2. **Whether `evaluateComputed`'s success case needs a 5th outcome shape (a
   `ComputedValue(value)` variant) is left to REQ-426/427.** This design's own
   `FieldExpressionOutcome` (§9) covers exactly the 4 outcomes AC8 names by literal
   text (stale-version, default-visible, default-hidden, blank) — a successfully
   computed non-null value is arguably a 5th distinct case ("has a value to display"),
   but AC8 does not name it, and inventing a 5th sealed variant not requested by any
   AC risks the same "unscoped extension" CODE-DESIGN-VALIDATOR gates against.
   **Recommendation, not a resolution:** REQ-426/427's own design should either extend
   `FieldExpressionOutcome` with a `ComputedValue` variant (a compile-time-total
   addition, cheap given the sealed-class discipline already established here) or wrap
   `evaluateComputed`'s successful non-null case in its own return type layered on top
   of this one — either is compatible with this design, and this design takes no
   position on which.
3. **`expr.ex` itself has no concept of "this expression is a `visible_when` vs. a
   `computed` vs. a `cross_field_validation`"** — that distinction lives entirely in
   the *caller* (the field-schema shape a future form renderer reads), never in the
   grammar or `Expr` module itself. This design's `evaluateVisibility`/`evaluateComputed`
   split (§9) is this requirement's own invention for organizing the 4-outcome mapping,
   not something `expr.ex` defines or constrains — flagged so a future reader does not
   mistake it for a grammar-level distinction that must be kept "in sync" with
   `expr.ex` the way the tokenizer/parser/evaluator proper must be.
4. **`cross_field_validation` is not designed with its own outcome mapping at all** in
   this document — only `visible_when` (→ `DefaultVisible`/`DefaultHidden`) and
   `computed` (→ `Blank`/eventual value) are given explicit producing functions in §9,
   because AC8's own four named outcomes map naturally onto those two expression kinds
   and MOB-4's acceptance criteria list `computed`/`visible_when`/cross-field validation
   as the three expression sites without further specifying cross-field validation's own
   success/failure shape (a boolean valid/invalid plus an error message, most likely,
   given `renderer_state.dart`'s existing `RendererValidationError` state already
   carries `List<ApiFieldError>` for the *server's* validation errors) — **left for
   REQ-426/427 to design**, using this document's `evaluateExpression`/`EvalOutcome`
   primitives (§6.5/§3) as the building block, exactly as `evaluateVisibility`/
   `evaluateComputed` do.

None of these four items propose extending `expr.ex`, adding a client-only grammar
capability, or silently guessing an unstated behaviour — each is reported for the
requirement that actually needs the answer to decide, per this requirement's own
"never a proposal to extend expr.ex" instruction.

---

## 12. Acceptance-criteria traceability

| AC | Where addressed |
|---|---|
| 1 — apps/mobile/ + MOBILE-DEV active before start | §0 (ORCH's verification recorded, no action needed here) |
| 2 — mobile-dev.md constraint 2 re-read, permits this work | §0 (quoted, already verified) |
| 3 — Dart evaluator passes real corpus, own test suite reads the file | §6 (full corpus-loading design: path, schema, decode, per-entry generation) |
| 4 — corpus entry count/version matches REQ-293's suite; discrepancy reported if any | §1 (re-verification: 40 entries, `corpus_schema_version 1.0.0`, **no drift found** — single git commit `81f005d8` ever touched `corpus.json`) |
| 5 — impure builtins structurally absent + rejection behaviour specified | §5 (closed 8-member `BuiltinName` enum, 3-site-consistency argument, `UnexpectedToken` rejection shape, test obligation) |
| 6 — no CEL package; pubspec.yaml unchanged except a named/justified dev dep | §7 (explicit non-change; existing `forbidden_dependencies_guard_test.dart` already enforces this; no dev dependency needed at all) |
| 7 — 3 divergence-prone semantics designed precisely | §4 (ASCII lower/upper §4.1, exact-4-char trim §4.2, division-by-zero infinity encoding §4.3/§4.3.1, plus §4.4's int/float-provenance finding, which is a Dart-specific *improvement* over REQ-293, not a divergence) |
| 8 — unhandled expression → stale-version, structurally distinguishable from the other 3 | §9 (sealed `FieldExpressionOutcome`, 4 closed variants, totality argument §9.1) |
| 9 — pure function, zero I/O, demonstrable offline | §8 (no I/O in `lib/expr/`, only test-fixture loading in `test/expr/`; demonstration procedure stated) |
| 10 — no offline submission queue | §8 (explicit: no persistence anywhere in this design's types) |
| 11 — `git diff` shows nothing under lib/ or web/, expr.ex unmodified | This design touches only `apps/mobile/lib/expr/`, `apps/mobile/test/expr/`, and this file under `lib/letflow/design/` — no `lib/letflow/**` or `web/**` path is named as a deliverable anywhere above; §11's open questions explicitly decline to propose any `expr.ex` change |
| 12 — corpus/version alignment cross-check (restated) | §1 (same re-verification as AC4) |

---

## 13. Scope-fence checklist (restated from the requirement's own text)

- Only `apps/mobile/` (plus this file under `lib/letflow/design/`) changes. No
  `lib/letflow/**` file is a deliverable of this design. `lib/letflow/engine/expr.ex`
  specifically is read-only throughout (§1's full read, no edit proposed anywhere).
- No `web/**` file is a deliverable — REQ-293's implementation is read for cross-check
  only (§1), never modified.
- No CEL pub package; `pubspec.yaml`/`pubspec.lock` unchanged (§7).
- No `now`/`date_add`/`date_diff` support, anywhere (§5).
- No general scripting runtime — the entire surface is the same 9-variant `ExprAst`
  `expr.ex` defines, nothing added, nothing dynamic (§3).
- No offline submission queue, no persistence of any evaluation result (§8, §9's types
  are all transient value objects).
- The client has no authority — nothing in this design claims a computed value is final;
  §1 records `Letflow.Engine.FormExpressionReevaluation`/REQ-292's server-side
  re-evaluation as the actual authority, unchanged and untouched by this design.
