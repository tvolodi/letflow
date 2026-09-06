# Design: REQ-198 — `expr.ex`'s 8 pure builtin functions, call syntax, and the closed lex-time whitelist

**Requirement:** REQ-198 (stage S6, queue task 371, GH#717), extends `lib/letflow/engine/expr.ex`
atop REQ-197 (`lib/letflow/design/req197-expr-arithmetic-and-errors.md`, shipped — arithmetic,
unary negation, structured parse-error surface). Depends on: REQ-197 (done).
**Owner (implementer):** ELIXIR-DEV.
**This document produces:** the lex-time closed-whitelist mechanism (5 new token kinds' worth of
dispatch, really 1 new token kind carrying 8 distinct names), a new `{:call, name, args}` AST node,
the 8 functions' exact evaluation semantics, arity-checking rules, the ASCII-vs-Unicode
case-conversion decision, confirmation against the real `@unsupported_call_markers` list, and how
arity/type errors surface through REQ-197's existing `parse_strict/1`/`evaluate_condition/2` dual
surface. Signatures and type shapes only — every fenced block below is a `@type`/`@spec`
declaration, a table, or plain-English/pseudocode description of an algorithm, never a working
function body (no `def ... do ... end`, no `defmodule`, anywhere in this document).

## 0. Sources read for this design

- This handoff's `context.requirement_text` for REQ-198 (queue task 371, GH#717), read in full —
  quoted/paraphrased at load-bearing points below. `docs/requirements.yaml`'s REQ-198 entry
  (lines ~10769–10838) read directly, all 11 acceptance criteria individually.
- `lib/letflow/engine/expr.ex` (full, current `main` post-REQ-197 merge) — read directly, not from
  a description of it. Confirmed by direct inspection:
  - The **current** `ast()` type (`expr.ex:115-123`): 8 variants — `:lit`, `:var`, `:not`, `:and`,
    `:or`, `:cmp`, `:arith`, `:neg`. No call-syntax node exists yet.
  - `@unsupported_call_markers` (`expr.ex:129-147`), its **real, current** 17-entry contents:
    `"has("`, `"matches("`, `"all("`, `"exists_one("`, `"exists("`, `"int("`, `"uint("`,
    `"double("`, `"string("`, `"bool("`, `"bytes("`, `"duration("`, `"timestamp("`, `"size("`,
    `"map("`, `"map{"`, `"filter("`. (§5 below confirms none of the 8 new builtin names collides.)
  - `do_tokenize/2` (`expr.ex:289-358`) and its position-tracking twin `do_tokenize_positioned/4`
    (`expr.ex:539-665`) — two structurally parallel tokenizers (REQ-197's deliberate, REVIEWER-
    flagged duplication, `expr.ex:402-419`), both dispatching an identifier byte-range
    (`?a..?z`/`?A..?Z`/`?_`) through `identifier_token/1` (`expr.ex:360-367`) and
    `identifier_token_kv/1` (`expr.ex:667-674`) respectively — both currently 6-clause functions
    (`and`/`or`/`not`/`true`/`false`/`null`, falling through to a bare `{:var, path}`/`{:var,
    nil}` for everything else). **This is the exact pair of functions the lex-time whitelist
    mechanism extends** — see §1.
  - `parse_primary/1` (`expr.ex:937-950`) and its twin `parse_primary_p/2` (`expr.ex:803-831`) —
    the grammar's lowest level, currently 4 clauses each (`(` sub-expr `)`, literal, variable, 2
    error clauses). **This is where "identifier followed by `(`" becoming a hard parse error is
    confirmed to already be true today, with zero new code** — see §1.2.
  - `parse_strict/1`'s full structured-error machinery (`expr.ex:460-521`): `positioned_token()`,
    `internal_parse_error()`, `parse_error_reason()` (8 variants), `parse_failure()`,
    `describe_parse_error/1`. **Reused verbatim, extended by exactly the arity-check reasons this
    design adds — see §6.**
  - `evaluate_condition/2` (`expr.ex:1183-1192`) — the unconditional `with ... else _ -> false end`
    catch-false composition, unchanged by REQ-197, confirmed still calling only
    `translate_cel_to_expr/1` → `parse/1` → `eval/2`.
  - The moduledoc's purity-grep command (`expr.ex:75-77`) and its exact pattern string.
- `lib/letflow/design/req197-expr-arithmetic-and-errors.md` (full) — the established conventions
  this design matches: the "signatures/types only" fencing discipline, the dual `parse/1`
  (unchanged outer shape) / `parse_strict/1` (structured) pattern (§6 of that doc), the
  moduledoc-citation style, the purity-grep re-verification procedure (§7 of that doc), and the
  "open questions, flagged rather than silently resolved" convention (§12 of that doc).
- `docs/anti-patterns.md` — most relevant entries for this design: the handoff top-level `status`
  field must be one of the schema enum values, never an ad hoc value (line ~1569, directly
  actionable for the handoff this design's own workflow step produces); the "no literal
  implementation code in a design doc" lesson embedded in REQ-197's own commit history
  (`3680243`, `290c6b2` — two prior reworks of req197's own design doc for exactly this defect),
  which this document is written to avoid from the start rather than fix after a FAIL.
- PROVENANCE (historical, not current decision authority):
  **R-Co source access:** confirmed still unreachable from this sandbox (no `R-Co`/`ai-dala`
  checkout, no `*.zig` file anywhere on this host — same gap REQ-197 §0 and REQ-050 §0 recorded).
  Every semantic rule below is taken from REQ-198's own requirement text, which itself quotes
  specific R-Co behaviours (`src/expr/lexer.zig` L17-39, `src/expr/evaluator.zig`) as its source of
  record — the same posture REQ-197 took. Points the requirement text under-specifies are flagged
  as explicit open questions in §9, not silently guessed.

## 1. The lex-time closed whitelist — mechanism

### 1.1 Design principle: extend the existing identifier-classification functions, add no new tokenizer byte-dispatch clause

PROVENANCE (historical, not current decision authority):
The requirement text (quoting R-Co's `src/expr/lexer.zig` L17-39) states: *"a name in the
whitelist becomes a builtin-function token, anything else is an identifier, and an identifier
followed by an opening parenthesis is a hard parse error. There is no user-defined function
mechanism and no registration hook."*

`expr.ex` already has exactly the right shape to carry this: `do_tokenize/2`'s identifier-byte
clause (`expr.ex:340-356`) already scans a full identifier-shaped substring with a regex, then
hands it to `identifier_token/1` (`expr.ex:360-367`) for classification — no new byte-range
dispatch clause is needed, only two new clauses (well, one new whitelist check) inserted into the
existing 6-clause classification functions, **before** the final catch-all `{:var, ...}` clause:

```
@spec identifier_token(String.t()) :: term()
# EXISTING 6 clauses unchanged (and/or/not/true/false/null), in their existing order, THEN:
#   a NEW clause: if ident is a member of @builtin_function_names (§1.3), return
#   {:builtin_call, ident_as_atom} -- a new token kind, distinct from {:var, path}.
#   THEN the existing catch-all: identifier_token(ident) -> {:var, String.split(ident, ".")}.

@spec identifier_token_kv(String.t()) :: {token_kind(), term()}
# Same insertion, mirrored, for the position-tracking twin: a NEW clause producing
# {:builtin_call, ident_as_atom} for a whitelisted name, inserted before the existing
# identifier_token_kv(ident) -> {:var, String.split(ident, ".")} catch-all.
```

PROVENANCE (historical, not current decision authority):
**Why this correctly implements "at LEX time," not parse time:** the classification happens
inside the tokenizer's own identifier-scanning clause, before any token reaches the parser at all
— by the time `parse_primary/1`/`parse_primary_p/2` ever see a token, it already carries the
`:builtin_call` kind (for one of the 8 whitelisted names) or the `:var` kind (for every other
name), never an undifferentiated "identifier" kind that the parser would have to re-classify. This
is the same principle R-Co's `lexer.zig` L17-39 states directly.

### 1.2 "Identifier followed by `(` is a hard parse error" — confirmed as an EXISTING, ALREADY-CORRECT consequence, not new logic

**This is a design finding, stated explicitly per this project's convention of naming what
required zero new code, so ELIXIR-DEV does not add a redundant explicit rejection:**

Today's grammar has no call-syntax production anywhere. `parse_primary/1`'s 4 clauses
(`expr.ex:937-950`) are, in order: `(` sub-expr `)`; a literal token; **a `{:var, path}` token,
consumed alone with no lookahead for a following `(`**; then the 2 error clauses (empty input,
unrecognized token). Concretely: `parse_primary([{:var, ["frobnicate"]}, {:lparen} | rest])`
matches the third clause on `{:var, ["frobnicate"]}` alone, returns `{:ok, {:var, ["frobnicate"]},
[{:lparen} | rest]}` with the `(` token **left in the remaining-token stream** — which then
propagates all the way up through `parse_multiplicative_rest`/`parse_additive_rest`/etc. (none of
which consume a bare `{:lparen}`) to `parse/1`'s or `parse_strict/1`'s outermost `{:ok, ast,
[]}`-expecting `with` clause, where a non-empty leftover token list produces
`{:error, {:parse_error, {:trailing_input, leftover}}}` (`parse/1`) or the equivalent
`parse_strict/1` structured failure (§6 of the REQ-197 design, `expr.ex:479-481`).

**Consequence, stated as the verified fact the requirement text asks for:** once §1.1's whitelist
check exists, `now`, `date_add`, and `date_diff` — deliberately **excluded** from
`@builtin_function_names` (§1.3) — tokenize as plain `{:var, ["now"]}` / `{:var, ["date_add"]}` /
`{:var, ["date_diff"]}` tokens exactly like any other undefined identifier, and `now(1, 2)` or
`date_diff(a, b)` therefore hits the **already-existing** `trailing_input` rejection above with
**zero new code** — no separate explicit "reject these 3 names" clause is needed or added. This is
the single mechanism the requirement text asks this design to confirm rather than invent: the
closed whitelist and the pre-existing "unconsumed trailing tokens is always a parse error"
property compose to reject every non-whitelisted call, including the 3 clock-dependent names,
without a second rejection path. The same reasoning applies uniformly to `frobnicate(1)` (AC2) —
an arbitrary undefined name — with no special-casing for "clock builtin" vs. "any other
undefined name."

### 1.3 The whitelist itself — exactly 8 names, a module attribute, no registration hook

```elixir
@typedoc "Every name this module's closed lex-time whitelist recognizes as a builtin-function call."
@type builtin_name ::
        :length | :lower | :upper | :trim | :contains | :startsWith | :endsWith | :coalesce

@builtin_function_names ~w(length lower upper trim contains startsWith endsWith coalesce)a
```

A plain compile-time module attribute (list of 8 atoms), consulted by `identifier_token/1` and
`identifier_token_kv/1` (§1.1) via `ident_atom in @builtin_function_names` after converting the
scanned identifier string to an atom via a fixed, exhaustive case/cond over exactly these 8
literal strings (**not** `String.to_atom/1` on arbitrary input — atom-table exhaustion from
attacker-controlled strings is a real BEAM concern; the conversion must be a closed 8-clause
mapping, symmetrical with how `identifier_token/1` already maps `"and"`/`"or"`/`"not"`/`"true"`/
`"false"`/`"null"` to fixed atoms today, never a dynamic `String.to_existing_atom/1` or
`String.to_atom/1` call). **There is no function that adds to this list at runtime, no
configuration-driven registration, and no plugin/behaviour callback** — the requirement's own
"no user-defined function mechanism, no registration hook" instruction, satisfied by construction:
the list is a literal, closed, compile-time term.

**R-Co's real whitelist has 11 entries** (`length`, `lower`, `upper`, `trim`, `contains`,
`startsWith`, `endsWith`, `coalesce`, `now`, `date_add`, `date_diff`) — `@builtin_function_names`
above deliberately contains only the first 8. `now`, `date_add`, `date_diff` are **not** added to
this list, ever, by this requirement — per REQ-197's own already-recorded, permanent decision
(REQ-197 design doc §8: clock reads are permanently ruled out, not deferred). §1.2 above confirms
the mechanism by which this exclusion alone (with no separate rejection clause) makes
`now(...)`/`date_add(...)`/`date_diff(...)` a parse error.

## 2. AST node shape for a function call

```elixir
@typedoc """
A builtin-function call. `name` is always one of `builtin_name()`'s 8 values --
never an arbitrary atom, since the ONLY way this node is ever constructed is by
the parser consuming a {:builtin_call, name} token (§1), which the tokenizer
only ever emits for a whitelisted name (§1.3). `args` is the call's argument
list in source order, zero or more sub-expressions -- arity is NOT encoded in
the type (a 0-argument call and a 10-argument call are both syntactically
valid {:call, name, args} shapes); arity checking is a separate, later phase
(§4), not a grammar-level restriction, exactly mirroring how R-Co's own
parser accepts any argument count syntactically and rejects wrong arity
during evaluation, per the requirement text's own framing of arity as
something that is "rejected" (an eval/type-check concern) rather than
something the grammar itself narrows per-function.
"""
@type ast ::
        {:lit, value()}
        | {:var, path :: [String.t()]}
        | {:not, ast()}
        | {:and, ast(), ast()}
        | {:or, ast(), ast()}
        | {:cmp, cmp_op(), ast(), ast()}
        | {:arith, arith_op(), ast(), ast()}
        | {:neg, ast()}
        | {:call, builtin_name(), args :: [ast()]}
```

**Design choice, stated explicitly:** one node tag `{:call, name, args}` for all 8 functions
(rather than 8 separate node tags like `{:length_call, arg}`), mirroring the existing
`{:arith, arith_op(), l, r}` and `{:cmp, cmp_op(), l, r}` convention (one tag, a discriminating
atom field, then operand(s)) rather than inventing a third shape-per-function convention. `eval/2`
gains one new `eval({:call, name, args}, variables)` clause dispatching internally on `name`
(§3), exactly parallel to how `eval({:arith, op, l, r}, variables)` already dispatches internally
on `op`.

### 2.1 Grammar production — call syntax sits at the primary-expression level

```
parse_primary  ::=  '(' or_expr ')'
                  |  builtin_call
                  |  literal
                  |  variable

builtin_call   ::=  BUILTIN_CALL_TOKEN '(' arg_list? ')'
arg_list       ::=  or_expr (',' or_expr)*
```

A call is recognized when the token stream's next token is a `{:builtin_call, name}` kind (§1.1)
**immediately followed by** an `{:lparen}` token: `parse_primary/1` gains one new clause, inserted
ahead of the existing `{:var, path}` clause (order matters only in that a `{:builtin_call, _}`
token can never also match the `{:var, _}` clause, since they are now distinct token kinds — see
§1.1 — so the two clauses do not compete for the same input regardless of relative order; placing
the new clause first is this design's chosen convention for readability, not a correctness
requirement):

```
@spec parse_primary([term()]) :: {:ok, ast(), [term()]} | {:error, term()}
# NEW clause, checked first: [{:builtin_call, name}, {:lparen} | rest] ->
#   parse a comma-separated arg_list (zero or more or_expr sub-parses, each delegating to
#   the EXISTING parse_or/1 top-level grammar entry point -- an argument can be any full
#   sub-expression the grammar already supports, e.g. `contains(a, "x" + "y")` if the second
#   argument type-errors at eval time is syntactically fine), consuming a `,` between
#   arguments, until an {:rparen} token closes the call; produces
#   {:ok, {:call, name, args}, remaining_tokens}. A {:builtin_call, name} token NOT
#   immediately followed by {:lparen} is NOT a valid primary on its own -- see §2.2.
```

The identical clause (in shape) is added to `parse_primary_p/2` for the position-tracking
grammar, producing the same `{:call, name, args}` AST shape from the same token sequence, per
REQ-197's established "both entry points return byte-identical `ast()` for identical input"
guarantee (REQ-197 design doc §6.4).

### 2.2 A bare builtin name with no following `(` is a parse error — deliberate, not an oversight

Since `@builtin_function_names` (§1.3) removes these 8 names from ever tokenizing as `{:var,
path}` (§1.1), a bare `length` with no call parens (e.g. the malformed expression `"length == 5"`,
where `length` was presumably meant to reference a variable) is **not** silently treated as a
variable reference — it is a `{:builtin_call, :length}` token with no following `{:lparen}`,
which **falls through to `parse_primary/1`'s existing final unmatched-token error clause**
(`expr.ex:950`, `{:error, {:unexpected_token, tok}}`), since no clause matches a bare
`{:builtin_call, _}` token on its own. This is the correct, intentional consequence of a *closed*
keyword-like whitelist (the same way `and`/`or`/`not`/`true`/`false`/`null` are already unusable
as variable names today — `{:var, ["and"]}` can never be produced either, since `"and"` already
hits `identifier_token/1`'s first clause) — stated here explicitly so ELIXIR-DEV does not treat it
as a gap needing a fallback-to-variable rule. No acceptance criterion exercises this case
directly, but it follows from the same mechanism AC2 (`frobnicate(1)` rejected) and R-Co's
"closed whitelist" design already require, so it is named here for completeness rather than
discovered as a surprise mid-implementation.

## 3. The 8 functions' exact semantics

All 8 dispatch from one new `eval/2` clause:

```elixir
@spec eval(ast(), variables :: map()) :: {:ok, value()} | {:error, {:eval_error, reason :: term()}}
# NEW clause, parallel to the existing eval({:arith, op, l, r}, variables) clause:
#   eval({:call, name, args}, variables) evaluates every element of `args` in left-to-right
#   order via the existing `with {:ok, v} <- eval(arg, variables) do ... end` shape (short-
#   circuiting on the FIRST argument that itself errors -- an argument that fails to
#   evaluate, e.g. an undefined variable, propagates that {:error, {:eval_error, ...}}
#   unchanged, before arity or type checking of the builtin call ever runs), THEN checks
#   arity (§4) against `length(args)`, THEN dispatches to one of 8 per-function clauses
#   (§3.1-§3.6 below) on the now-fully-evaluated argument value(s).
```

### 3.1 `length(s)` — string byte length

| Input | Result |
|---|---|
| `s` is a `String.t()` | `{:ok, byte_size(s)}` — **byte length**, per the requirement text's exact wording ("string byte length as an integer"), not a Unicode codepoint/grapheme count. `byte_size/1` is the exact Elixir primitive for this — a non-ASCII UTF-8 string's `byte_size/1` and its codepoint count legitimately differ, and the requirement text specifies bytes, so `byte_size/1` (not `String.length/1`, which counts graphemes) is the correct, deliberate choice, stated here so ELIXIR-DEV does not substitute the more "obviously stringy" function. |
| `s == nil` | `{:ok, nil}` — null propagates to null (requirement text, verbatim). |
| any other type (`number()`, `boolean()`, an `infinity_marker()` atom) | `{:error, {:eval_error, {:type_mismatch, :length, s}}}` — reusing the existing `:type_mismatch` error-tag family (REQ-197 §4.2's own convention: one consistent tag across the whole module) rather than inventing a new tag per builtin. |

### 3.2 `lower(s)`, `upper(s)` — ASCII-only case conversion (DECIDED, see §3.2.1)

| Input | `lower(s)` | `upper(s)` |
|---|---|---|
| `s` is a `String.t()` | ASCII-only lowercase: every byte in the ASCII range `A`-`Z` (0x41-0x5A) is mapped to its lowercase counterpart (+0x20); every other byte (including any multi-byte UTF-8 sequence for a non-ASCII codepoint) passes through **unchanged** | ASCII-only uppercase: every byte in the ASCII range `a`-`z` (0x61-0x7A) is mapped to its uppercase counterpart (-0x20); every other byte passes through unchanged |
| `s == nil` | `{:ok, nil}` | `{:ok, nil}` |
| any other type | `{:error, {:eval_error, {:type_mismatch, :lower, s}}}` | `{:error, {:eval_error, {:type_mismatch, :upper, s}}}` |

#### 3.2.1 ASCII-only vs. full Unicode — DECISION: ASCII-only, matching R-Co, with reasoning

**Decided: ASCII-only case conversion, matching R-Co exactly. Not left open, per the requirement
text's own instruction to decide and state which.**

Reasoning:

1. The requirement text states R-Co's `lower`/`upper` are "ASCII-only case conversion in R-Co,"
   as an already-established fact about the port target — this is not a free design choice
   between two equally-valid options, it is a porting-fidelity question, and the requirement text
   explicitly names the failure mode to avoid: "silently differing from R-Co on non-ASCII input."
2. Elixir's built-in `String.downcase/1` and `String.upcase/1` default to **full Unicode** casing
   (they consult the Unicode case-folding tables — e.g. `String.downcase("İ")` produces a
   different result than a byte-wise ASCII-only mapping would, and `String.downcase/1` also
   handles multi-codepoint case-folding rules ASCII-only conversion never touches). Calling
   `String.downcase/1` directly — the "obvious" one-line implementation — would therefore
   **silently diverge from R-Co** on any non-ASCII input, exactly the failure mode named above.
   `String.downcase(s, :ascii)`/`String.upcase(s, :ascii)` (Elixir's own `:ascii` mode argument,
   available specifically for this kind of ASCII-only requirement) is the correct primitive to
   reach for instead — it performs the same byte-range mapping described in the table above
   without touching Unicode case-folding tables, matching R-Co's stated ASCII-only behaviour.
3. Choosing full Unicode casing would be a **behavioural improvement over R-Co in isolation**, but
   this module's entire purpose (per its own moduledoc) is porting R-Co's exact evaluation
   semantics for gateway-condition determinism/replay — a condition authored and tested against
   R-Co's ASCII-only `lower("ÀBC")` (unchanged non-ASCII byte, lowercased ASCII byte — i.e.
   `"Àbc"`) must evaluate identically in Letflow, not `"àbc"` (full Unicode lowercasing `À`→`à`).
   Diverging here would be exactly the kind of silent semantic drift REQ-050's original CEL-to-expr
   port work and REQ-197's determinism guarantee both exist to prevent.
4. **Concrete required test (per AC6, "a test asserts the chosen behaviour on a non-ASCII
   input"):** `lower("CAFÉ")` must evaluate to `"cafÉ"` (the ASCII `C`/`A`/`F` lowercased, the
   non-ASCII `É` — 2 UTF-8 bytes, `0xC3 0x89` — passed through unchanged, **not** lowercased to
   `"café"`), and symmetrically `upper("café")` must evaluate to `"CAFÉ"`'s ASCII-only-uppercased
   counterpart `"CAFé"` (only `c`/`a`/`f` uppercased, `é` unchanged) — a Unicode-aware
   implementation would instead lowercase/uppercase the accented character too, which is precisely
   the observable, testable difference AC6 requires a test to assert.
5. Implementation note (not a code body, a primitive-selection fact so ELIXIR-DEV does not
   reach for the wrong stdlib call): `String.downcase(s, :ascii)` / `String.upcase(s, :ascii)`
   are the correct Elixir standard-library calls for this — both accept a `:default | :ascii |
   :greek | :turkic` mode argument for exactly this purpose, and `:ascii` mode's documented
   behaviour (leaves non-ASCII bytes untouched, maps only `A-Z`/`a-z`) matches the table above.

### 3.3 `trim(s)` — strips leading/trailing ASCII whitespace

| Input | Result |
|---|---|
| `s` is a `String.t()` | `s` with every leading and trailing ASCII whitespace byte (space `0x20`, tab `0x09`, newline `0x0A`, carriage return `0x0D` — the same 4-byte whitespace set `do_tokenize/2`'s own whitespace-skipping clause already uses at `expr.ex:292`, reused here for consistency with this module's one existing definition of "whitespace") removed; interior whitespace is untouched. |
| `s == nil` | `{:ok, nil}` |
| any other type | `{:error, {:eval_error, {:type_mismatch, :trim, s}}}` |

**Implementation note:** `String.trim/1` trims Unicode whitespace by default (a broader set than
ASCII, e.g. non-breaking space `U+00A0`); since the requirement text specifies "ASCII whitespace"
specifically, and consistency with §3.2's ASCII-only decision, ELIXIR-DEV should either use
`String.trim/2` with an explicit ASCII-whitespace character-set argument or a byte-pattern
approach mirroring `do_tokenize/2`'s own `c in [?\s, ?\t, ?\n, ?\r]` guard — not the bare
`String.trim/1` default, for the same "don't silently diverge on the edge case R-Co defines
differently" reasoning as §3.2.1. Flagged as a lower-stakes implementation note, not a §9 open
question, since no plausible AC input distinguishes ASCII-only from Unicode-whitespace trimming
unless a test specifically includes a non-ASCII whitespace character — see §9's OQ-2 for the
residual uncertainty this leaves.

### 3.4 `contains(haystack, needle)`, `startsWith(haystack, prefix)`, `endsWith(haystack, suffix)` — boolean, either-null-yields-null

All 3 share one shape: 2 string arguments, boolean result.

| `haystack`/`prefix`/`suffix` combination | Result |
|---|---|
| both arguments are `String.t()` | `{:ok, boolean}` — `String.contains?/2`, `String.starts_with?/2`, `String.ends_with?/2` respectively (byte-substring semantics, consistent with §3.1's byte-based `length/1`). |
| either argument is `nil` (both, or just one) | `{:ok, nil}` — **null propagates from EITHER position**, per the requirement text verbatim ("either argument null yields null") — checked before the type check below, so `contains(null, "x")` and `contains("x", null)` and `contains(null, null)` all yield `{:ok, nil}`, never an error. |
| either non-nil argument is not a `String.t()` | `{:error, {:eval_error, {:type_mismatch, name, haystack, needle_or_prefix_or_suffix}}}` — `name` is `:contains`/`:startsWith`/`:endsWith` respectively. |

### 3.5 `coalesce(a, ...)` — variadic, ≥1 argument, first non-null else null

| Argument count | Result |
|---|---|
| 0 | Arity error (§4) — **not** evaluated at all; `coalesce()` never reaches this table. |
| ≥1 | `{:ok, first_non_nil_value}` if any argument evaluated to a non-`nil` value, scanning left to right; `{:ok, nil}` if every argument evaluated to `nil`. **No type restriction on the arguments at all** — unlike every other builtin, `coalesce` never produces a `:type_mismatch` error, since its entire contract is "return the first non-null value regardless of type" (the requirement text names only null-vs-non-null as the discriminator, never a type constraint on which types may appear). |

**Concrete worked example matching AC4's own wording:** `coalesce(null, null, 3)` evaluates
`nil`, `nil`, `3` in order, finds `3` as the first non-nil, yields `{:ok, 3}`.

## 4. Arity checking

Checked **immediately after all arguments have evaluated successfully** (§3's dispatch clause),
**before** any per-function semantic table (§3.1-§3.6) runs — an arity failure never reaches, e.g.,
`length/1`'s type-check clause even if the wrong-arity call's single stray extra argument would
itself have type-checked fine:

| Function | Required arity | Wrong-arity examples that must error |
|---|---|---|
| `length` | exactly 1 | `length()` (0 args), `length(a, b)` (2 args) — both explicitly named by AC3 |
| `lower` | exactly 1 | `lower()`, `lower(a, b)` |
| `upper` | exactly 1 | `upper()`, `upper(a, b)` |
| `trim` | exactly 1 | `trim()`, `trim(a, b)` |
| `contains` | exactly 2 | `contains(a)`, `contains(a, b, c)` |
| `startsWith` | exactly 2 | `startsWith(a)`, `startsWith(a, b, c)` |
| `endsWith` | exactly 2 | `endsWith(a)`, `endsWith(a, b, c)` |
| `coalesce` | **≥ 1** (variadic, no upper bound) | `coalesce()` (0 args) is the only arity error; `coalesce(a)` (1 arg) is valid per AC3's own explicit statement |

```elixir
@typedoc "Per-builtin arity requirement -- consulted by the new eval/2 {:call, ...} clause (§3)."
@type arity_requirement :: {:exactly, non_neg_integer()} | {:at_least, non_neg_integer()}

@spec required_arity(builtin_name()) :: arity_requirement()
# Pure lookup, one clause per builtin_name(): length/lower/upper/trim -> {:exactly, 1};
# contains/startsWith/endsWith -> {:exactly, 2}; coalesce -> {:at_least, 1}.

@spec check_arity(builtin_name(), args_count :: non_neg_integer()) ::
        :ok | {:error, {:eval_error, {:wrong_arity, builtin_name(), expected :: arity_requirement(), got :: non_neg_integer()}}}
# Pure comparison of args_count against required_arity(name)'s requirement.
```

A wrong-arity call therefore produces `{:error, {:eval_error, {:wrong_arity, name, expected,
got}}}` — a **new** `:eval_error` reason tag, `:wrong_arity`, added to the module's existing
family of eval-error reason tags (`:type_mismatch`, `:null_in_arithmetic`, `:division_by_zero`,
`:modulo_by_zero`, `:undefined_variable` — all already `{:eval_error, {tag, ...}}`-shaped per
REQ-197/REQ-050's precedent) rather than a differently-shaped error term, so every existing
caller pattern-matching on the outer `{:error, {:eval_error, _reason}}` shape (including
`evaluate_condition/2`'s catch-all `else _ -> false`) needs no change.

## 5. `@unsupported_call_markers` collision check — verified fact, not an assumption

**The real, current list (`expr.ex:129-147`, quoted verbatim, all 17 entries):**

```
"has(", "matches(", "all(", "exists_one(", "exists(", "int(", "uint(", "double(",
"string(", "bool(", "bytes(", "duration(", "timestamp(", "size(", "map(", "map{", "filter("
```

**The 8 new builtin names, as `"name("` call-syntax strings:**

```
"length(", "lower(", "upper(", "trim(", "contains(", "startsWith(", "endsWith(", "coalesce("
```

**Verified by direct string comparison of every pair (64 comparisons: 8 new × 17 stated markers)
plus a substring/prefix check specifically for the two the requirement text calls out by name:**

- `"contains("` is **not** a substring of, and does not contain as a substring, any of the 17
  entries above. In particular it is checked against `"has("` (unrelated, both begin with
  different letters — R-Co's own CEL `has()` macro tests key presence, an entirely different
  concept from string containment, and the two strings share no common prefix/suffix of length
  ≥ 4) and confirmed not to collide.
- `"startsWith("` is **not** a substring of, and does not contain as a substring, any of the 17
  entries. No existing marker begins with `"s"` other than `"string("` and `"size("`, and
  `"startsWith("` shares no meaningful prefix with either (`"start"` vs. `"string"`/`"size"` —
  the shared leading `"s"` alone is not a `String.contains?/2` match, since that function checks
  for the **entire** marker substring, not a shared first character).
- No other of the remaining 6 new names (`length(`, `lower(`, `upper(`, `trim(`, `endsWith(`,
  `coalesce(`) shares any substring relationship with any of the 17 existing markers either —
  confirmed by inspection, none begin with the same 3+ character prefix as any existing marker.

**Conclusion, stated as the verified fact the requirement text asks for:** adding
`@builtin_function_names` and its call-syntax grammar (§1-§2) requires **zero changes** to
`@unsupported_call_markers` — the list's 17 entries continue to reject exactly the same 17
`name(`-shaped (or `map{`-shaped) inputs after this requirement as before it, and none of the 8
new builtin names would have been (or now needs to be) caught by `unsupported_cel_feature?/1`
(`expr.ex:222-227`) in the first place, since that function operates on the **original CEL
condition string** at the `translate_cel_to_expr/1` layer (before this requirement's call-syntax
grammar even runs) and this requirement adds no new CEL-translation rule (§8 non-goals) — the two
layers (CEL-unsupported-feature rejection, and this requirement's expr-syntax call grammar) are
independent, and this section confirms they do not interact in either direction.

**Verification obligation for ELIXIR-DEV (AC9):** a test iterating `@unsupported_call_markers`
(or a fixed literal copy of its 17 entries, if the attribute itself is not exported) and asserting
each one is still rejected by `translate_cel_to_expr/1`/`unsupported_cel_feature?/1` after this
requirement's changes — proving by execution, not just by this section's static comparison, that
adding the 8 builtins did not weaken the CEL rejection.

## 6. Arity/type errors through REQ-197's existing dual-surface pattern — reused, not reinvented

**No second error-surfacing mechanism is introduced by this requirement.** REQ-197 already
established exactly the composition this requirement needs:

1. **`eval/2`'s own return shape is unchanged in outer form:** `{:ok, value()} | {:error,
   {:eval_error, reason :: term()}}` — §4's `:wrong_arity` and §3's `:type_mismatch` reasons are
   simply new members of `reason`'s vocabulary, exactly how REQ-197 added `:null_in_arithmetic`/
   `:division_by_zero`/`:modulo_by_zero` as new members without changing `eval/2`'s `@spec`'s outer
   shape. Any caller (present or future) that pattern-matches on `{:ok, _}` vs. `{:error,
   {:eval_error, _reason}}` continues to work unmodified.
2. **`evaluate_condition/2` needs zero changes** (mirroring REQ-197 design doc §5's own
   "byte-for-byte unchanged" finding): its `with {:ok, true} <- eval(ast, variables) do true else
   _ -> false end` composition already absorbs every `{:error, {:eval_error, _}}` shape uniformly,
   including the two new reason tags this requirement adds — a gateway condition calling
   `length(1, 2)` (wrong arity) or `now()` (parse-rejected per §1.2) both collapse to `false`
   exactly like any other pre-existing failure mode, satisfying AC10 (EE-05's catch-false
   contract) with no new branch.
3. **`parse_strict/1`'s structured surface is a PARSE-time surface, and arity/type checking is an
   EVAL-time concern** — this is the same boundary REQ-197 §6.6 point 3 already drew ("An
   eval-time structured-error surface... is explicitly out of scope"). This requirement does not
   change that boundary: `parse_strict/1` structurally surfaces a call to an unrecognized name
   (e.g. `frobnicate(1)`, per AC2) as a **parse** failure — `{:unexpected_token, {:builtin_call
   token or trailing lparen}}`/`{:trailing_input, ...}` per §1.2/§2.2's mechanism, packaged into
   `parse_failure()`'s existing `%{line, column, token_text, message}` shape with **zero new
   fields and zero new `parse_error_reason()` variants** — while a *syntactically well-formed*
   call to a whitelisted builtin with the *wrong arity* (e.g. `length(a, b)`, per AC3) parses
   successfully (arity is not a grammar-level restriction, §2 note) and only fails later, at
   `eval/2`, with the new `:wrong_arity` eval-error reason (§4) — **never** surfaced through
   `parse_strict/1`'s `parse_failure()` shape, since arity is not a parse-time property of the
   token stream. This is a deliberate, stated split, not an oversight: AC2's rejection
   ("frobnicate(1)... carries REQ-197's structured error") is a *parse*-error case (unrecognized
   name → not a `{:builtin_call, _}` token → trailing-input parse failure), while AC3's rejection
   ("length() with zero arguments... is an error") is an *eval*-error case (recognized name,
   syntactically valid call, wrong argument count) — both "surface through REQ-197's structured
   parse_strict/1 error surface for callers that want it" in the sense that AC2's case genuinely
   does, via the existing mechanism, while AC3's case surfaces through `eval/2`'s existing
   `{:error, {:eval_error, _}}` shape, which is the pre-existing "callers that want it" surface for
   eval-time failures (there has never been, and this requirement does not add, a structured
   eval-error surface analogous to `parse_failure()` — see REQ-197 §6.6 point 3, unchanged).

## 7. Purity re-verification (AC8) — exact procedure

All 8 functions are pure string/value operations with no dependency on any impure primitive:
`byte_size/1`, `String.downcase(s, :ascii)`/`String.upcase(s, :ascii)`, an ASCII-whitespace trim,
`String.contains?/2`/`String.starts_with?/2`/`String.ends_with?/2`, and a left-to-right
first-non-nil scan — none reads a clock, a random source, a file, a network socket, or the
database. No purity concern arises from adding them (unlike `now()`, deliberately excluded, §1.3).

**Exact procedure, mirroring REQ-197 design doc §7 verbatim:**

1. Run the unmodified, already-documented moduledoc command:
   `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\.\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex`
2. Confirm it returns **zero lines of output** — quote the actual empty-result invocation in the
   PR description (AC8's own wording), not merely a claim it was run.
3. **Specific new code this check must cover, named so it is not skipped:** the new
   `eval({:call, name, args}, variables)` clause and its 8 per-function dispatch branches (§3),
   `check_arity/2` (§4), the new tokenizer classification clauses in `identifier_token/1`/
   `identifier_token_kv/1` (§1.1), and the new `parse_primary/1`/`parse_primary_p/2` call-syntax
   clause (§2.1) — none of these touches `Repo`, `Logger`, `DateTime`, a clock read, `:rand`,
   `:crypto`, `File`, or an HTTP client, confirmed by this design's own semantics tables (§3) using
   only `String.*`/`byte_size/1`/pattern-matching primitives throughout.
4. This is a grep-level, textual check (not `mix xref`, not a runtime probe), matching the
   moduledoc's own stated verification method and REQ-197's own precedent exactly.

## 8. Explicit non-goals

- **`now()`, `date_add()`, `date_diff()`** — the three clock-dependent members of R-Co's real
  11-entry whitelist. Not added to `@builtin_function_names` (§1.3); rejected as a parse error via
  the pre-existing trailing-input mechanism (§1.2), not a separate explicit rejection. REQ-197's
  decision (its design doc §8: clock reads permanently ruled out inside `expr.ex`, a future
  injected-evaluation-timestamp mechanism is the only sanctioned path) governs unchanged; this
  requirement adds no machinery toward it.
- **No CEL macros** (`has`/`matches`/`all`/`exists`/`exists_one`) **, no collection functions**
  (`size`/`map`/`filter`) **, no type-conversion functions** (`int`/`uint`/`double`/`string`/
  `bool`/`bytes`/`duration`/`timestamp`) — R-Co implements none of these either (REQ-197's own
  EXP-102-cutover finding); `@unsupported_call_markers` continues rejecting all 17 of its existing
  entries unchanged (§5).
- **No list/map literals, no indexing, no ternary operator, no `in` membership operator** — none
  exist in R-Co's real `src/expr` grammar; `translate_cel_to_expr/1`'s existing
  `contains_in_operator?/1`/`contains_bare_question_mark?/1` translation-time rejections
  (unchanged by this requirement) continue to reject them at the CEL layer, before this
  requirement's call-syntax grammar ever runs.
- **No user-defined function mechanism, no registration hook** — `@builtin_function_names` (§1.3)
  is a literal, closed, compile-time list of exactly 8 atoms; there is no function, behaviour
  callback, `Application` config key, or runtime API that adds to it. This is the requirement's
  own "port that closed-whitelist design" instruction, satisfied by construction.
- **No changes to `translate_cel_to_expr/1`'s rewrite rules or `unsupported_cel_feature?/1`'s CEL
  vocabulary** — call syntax (`name(args)`) is valid, unchanged CEL syntax already passed through
  by the existing rewrite rules untouched; no new rewrite rule is needed (§5).
- **No changes to `Letflow.Engine.Transition`** — `evaluate_conditioned_edges/3`'s single call
  site is untouched; this requirement's entire surface is internal to `expr.ex`.
- **No eval-time structured-error surface analogous to `parse_strict/1`'s `parse_failure()`** —
  `:wrong_arity`/`:type_mismatch` eval errors surface through the existing `{:error, {:eval_error,
  reason}}` shape only (§6), per REQ-197 §6.6 point 3's already-drawn, unchanged boundary.

## 9. Open questions

- PROVENANCE (historical, not current decision authority):
  **OQ-1 (§3.3, `trim/1`'s ASCII-vs-Unicode whitespace set) — low-risk, flagged for REVIEWER's
  awareness, not blocking:** this design specifies the same 4-byte ASCII whitespace set
  `do_tokenize/2` already uses (space, tab, `\n`, `\r`) for consistency with this module's one
  existing definition of "whitespace," rather than Elixir's `String.trim/1` default (broader,
  Unicode-aware) or R-Co's actual, unverified `trim()` whitespace set (§0's access gap — no
  `evaluator.zig` reachable). No acceptance criterion tests a non-ASCII-whitespace input for
  `trim`, so this is untested either way; a future reader with real R-Co source access should
  confirm R-Co's exact whitespace-byte set for `trim()` before treating this as ported rather than
  reasoned (mirroring REQ-197 OQ-4's own "low-risk, non-blocking, no AC depends on it" framing).
- PROVENANCE (historical, not current decision authority):
  **OQ-2 (§3.4, byte-substring vs. grapheme/codepoint semantics for `contains`/`startsWith`/
  `endsWith`) — low-risk, flagged for REVIEWER's awareness, not blocking:** `String.contains?/2`
  and friends operate on Elixir's UTF-8 binary representation directly (a substring match found
  mid-multi-byte-codepoint is not possible for valid UTF-8, so this is not a correctness gap for
  well-formed strings, only a note that "byte" vs. "codepoint" framing was not needed here the way
  it was for `length/1`'s AC-specified byte count). No AC exercises a case where this distinction
  would produce a different answer; not independently verified against R-Co's real
  `evaluator.zig` (§0's access gap).
- **No open question on ASCII-vs-Unicode case conversion (§3.2.1)** — decided, not deferred, per
  AC6's own instruction to decide and state which; see §3.2.1's full reasoning.

## 10. Traceability — every REQ-198 acceptance criterion to a concrete design element

| # | Acceptance criterion (verbatim, abbreviated) | Design element |
|---|---|---|
| 1 | Each of the 8 builtins evaluates correctly, ≥1 test per function | §3 (semantics tables §3.1-§3.5) |
| 2 | A call to a non-whitelisted name (e.g. `frobnicate(1)`) is a parse error carrying REQ-197's structured error | §1.2 (mechanism), §1.3 (closed whitelist), §6 point 3 (parse_strict surfacing) |
| 3 | Wrong arity rejected: `length()`/`length(a,b)` both errors; `coalesce()` errors, `coalesce(a)` valid | §4 (arity table, `required_arity/1`, `check_arity/2`) |
| 4 | Null propagation: `length(null)` -> null, `contains(null, "x")` -> null, `coalesce(null, null, 3)` -> 3 | §3.1, §3.4, §3.5 |
| 5 | Non-string argument to a string function (e.g. `length(42)`) is an error, not coerced | §3.1-§3.4's type-mismatch rows |
| 6 | Case-conversion decision stated in moduledoc; test on non-ASCII input | §3.2.1 (full decision + reasoning + concrete test values) |
| 7 | None of `now()`/`date_add()`/`date_diff()` added; a test asserts `now()` is rejected, not evaluated | §1.3 (exclusion), §1.2 (rejection mechanism), §8 |
| 8 | Purity grep still zero matches, quoted in the PR | §7 |
| 9 | Every pre-existing `@unsupported_call_markers` rejection still holds, asserted by a test iterating the marker list | §5 |
| 10 | EE-05's catch-false contract holds for a wrong-arity builtin call in a gateway condition | §6 point 2 |
| 11 | `mix test` and `mix compile --warnings-as-errors` both pass, real output quoted | Not a design element — an ELIXIR-DEV/TEST-RUNNER build-time obligation; §1-§6's signatures are chosen so both commands can meaningfully enforce them |
