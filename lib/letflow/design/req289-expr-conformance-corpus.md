# Design: REQ-289 — Language-neutral expression conformance corpus

**Requirement:** REQ-289 (stage S6, queue task 544, GH#1100).
**Owner (implementer):** ELIXIR-DEV.
**Depends on:** REQ-197 (done), REQ-198 (done).
**Downstream dependents:** REQ-293 (TypeScript evaluator), REQ-294 (Dart evaluator). Neither may begin before this requirement lands.
**Decision authority:** `docs/migration/decisions/0020-frontend-architecture.md` §D1a ("must exist and be proven correct BEFORE any second client-side expression evaluator is built").

This document produces:
- The exact file path for the corpus JSON and the justification for that location (§1).
- The complete JSON schema with every required field, allowed types, and the canonical encoding of infinity markers and failure outcomes (§2).
- The companion schema-documentation path (§3, i.e. this document).
- Which decision record is amended and what that amendment adds (§4).
- The structure of `test/letflow/engine/expr_conformance_corpus_test.exs` (§5).
- The coverage-enumeration test design, including the runtime coupling to `builtin_function_names/0` (§6).
- The failure-entry schema and the tests that assert parse-failure ≠ eval-failure interchangeability (§7).

Signatures and type shapes only. No function bodies, no `def ... do ... end`, no `defmodule` blocks.

---

## 0. Sources read for this design

- `lib/letflow/engine/expr.ex` (full) — confirmed grammar surface, `@builtin_function_names`, `infinity_marker()` type, `ast()` shape, all error tuples.
- `test/letflow/engine/expr_test.exs` (full, 895 lines) — all 8 builtins exercised, all 6 comparison operators, all 5 arithmetic operators, unary negation, dotted paths, ASCII-only semantics, signed-infinity 3-way split, null asymmetry, parse_strict/1 surface. Corpus entries are derived from these tests; the test file itself is UNMODIFIED.
- `test/fixtures/simulation/differential_corpus.json` — confirmed 15 entries, confirmed gateway-specific keys (`source_gateway_node_id`, `source_definition_id`, `condition_text`) that the new corpus must NOT carry. This file is UNMODIFIED.
- `docs/migration/decisions/0020-frontend-architecture.md` (full) — D1a clause, Sequencing step 9, REQ-293/REQ-294 dependency statement.
- `test/letflow/engine/expr_differential_corpus_test.exs` — UNMODIFIED, not read for content (only existence/location confirmed).

---

## 1. Corpus file location: `priv/expr_conformance/corpus.json`

**Path:** `priv/expr_conformance/corpus.json`

**Justification:** The corpus is a cross-language artifact. Its primary consumer is the ExUnit test in this requirement, but its designed purpose — per 0020 D1a — is to be consumed by REQ-293 (TypeScript, lives in `web/`) and REQ-294 (Dart, lives in a future `apps/mobile/`). Placing the corpus inside `test/` would make it a test-only fixture scoped to the Elixir application; placing it inside `priv/` makes it a first-class application artifact shipped with the OTP release and accessible via `:code.priv_dir(:letflow)` from Elixir tests, and via a deterministic relative filesystem path from TypeScript and Dart consumers. This is the idiomatic Elixir convention for static files that are part of an application's distributed surface, not build-time-only test state.

The location is explicitly distinct from `test/fixtures/simulation/` on three axes: it is in a different top-level directory (`priv/` vs `test/`), it uses a subdirectory named after its purpose (`expr_conformance`), and it contains no gateway-lifecycle keys.

**REVIEWER gate:** This location must be recorded in `docs/migration/decisions/0020-frontend-architecture.md` (§4 below) before the implementation is merged. That amendment is part of this requirement's deliverables (AC7).

---

## 2. JSON schema for corpus entries

### 2.1 Top-level structure

The corpus file is a single JSON array. Every element of the array is a corpus entry.

```
corpus.json := [ entry, ... ]
```

### 2.2 Corpus entry fields

Every entry MUST have all of the following fields. No optional fields. No unknown fields.

| Field | JSON type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Stable, unique identifier for this entry. Format: `"expr-NNN"` (zero-padded to 3 digits, e.g. `"expr-001"`). Never reused after a delete. |
| `description` | string | yes | One sentence in plain English describing what semantic the entry demonstrates. |
| `grammar_constructs` | array of string | yes | Tags identifying which grammar constructs this entry exercises. Used by the coverage-enumeration test (§6). Must contain at least one tag. See §2.3 for the closed tag vocabulary. |
| `expression` | string | yes | The expression source in **expr-syntax** (not CEL). Already-translated — no `variables.` prefix. This is the string passed directly to `Letflow.Engine.Expr.parse/1`. |
| `variables` | object | yes | The input variable map passed to `eval/2`. Keys are strings. Values are JSON primitives (see §2.5 for type mapping). For entries where no variables are needed, use `{}`. |
| `outcome` | object | yes | The expected result. See §2.4 for the two legal shapes. |

### 2.3 `grammar_constructs` closed tag vocabulary

The coverage-enumeration test (§6) asserts that every tag in the required set is covered by at least one corpus entry. The tag vocabulary is:

**Comparison operators (6):**
- `"cmp:eq"`, `"cmp:neq"`, `"cmp:lt"`, `"cmp:lte"`, `"cmp:gt"`, `"cmp:gte"`

**Boolean operators (3):**
- `"bool:and"`, `"bool:or"`, `"bool:not"`

**Literal kinds (4):**
- `"lit:boolean"`, `"lit:integer"`, `"lit:float"`, `"lit:string"`

**Arithmetic operators (5):**
- `"arith:add"`, `"arith:sub"`, `"arith:mul"`, `"arith:div"`, `"arith:mod"`

**Unary negation (1):**
- `"arith:neg"`

**Variable reference (2):**
- `"var:simple"` — single-segment name (e.g. `amount`)
- `"var:dotted"` — multi-segment dotted path (e.g. `order.status`)

**Builtin functions (8) — coupled to `builtin_function_names/0` at test time (§6):**
- `"builtin:length"`, `"builtin:lower"`, `"builtin:upper"`, `"builtin:trim"`,
  `"builtin:contains"`, `"builtin:startsWith"`, `"builtin:endsWith"`, `"builtin:coalesce"`

Entries may carry multiple tags. An entry demonstrating `2 + 3 * 4 == 14` would carry `"arith:add"`, `"arith:mul"`, `"cmp:eq"`, `"lit:integer"`.

### 2.4 `outcome` object — two legal shapes

**Shape A — success outcome:**

```json
{
  "status": "ok",
  "value": <json-encoded-value>
}
```

The `value` field holds the expected return value of `Letflow.Engine.Expr.eval/2`'s inner `{:ok, v}`. See §2.5 for how Elixir values map to JSON. For infinity markers, see §2.6.

**Shape B — failure outcome:**

```json
{
  "status": "error",
  "error_kind": "parse_failure"
}
```

or

```json
{
  "status": "error",
  "error_kind": "eval_failure"
}
```

`error_kind` is a closed enum of exactly two values:
- `"parse_failure"` — `Letflow.Engine.Expr.parse/1` returns `{:error, {:parse_error, _}}`. The `expression` field is intentionally malformed. `eval/2` is never called for this entry.
- `"eval_failure"` — `Letflow.Engine.Expr.parse/1` returns `{:ok, ast}` (the expression is grammatically valid), and then `eval/2` returns `{:error, {:eval_error, _}}`. This entry's expression is well-formed but produces a runtime error given the supplied `variables`.

These two kinds are not interchangeable. An entry with `"error_kind": "parse_failure"` MUST fail at the parse stage. An entry with `"error_kind": "eval_failure"` MUST parse successfully. The test asserts this distinction (§7).

Shape B entries MUST NOT have a `value` field.

### 2.5 Value encoding — JSON ↔ Elixir type mapping

| Elixir type | JSON encoding | Example |
|---|---|---|
| `boolean()` (`true`/`false`) | JSON boolean | `true` |
| integer | JSON number (no decimal point) | `42` |
| float | JSON number (with decimal point) | `3.14` |
| `String.t()` | JSON string | `"hello"` |
| `nil` | JSON null | `null` |
| `infinity_marker()` | special object (see §2.6) | `{"$marker": "infinity"}` |

**The `variables` object** follows the same rules for leaf values. Nested maps are encoded as nested JSON objects (for dotted-path entries). JSON null in `variables` maps to Elixir `nil`.

### 2.6 Infinity marker encoding

IEEE 754 non-finite floats have no JSON representation (`Infinity`, `-Infinity`, `NaN` are not valid JSON). The corpus encodes them as tagged JSON objects:

| Elixir atom | JSON encoding |
|---|---|
| `:infinity` | `{"$marker": "infinity"}` |
| `:neg_infinity` | `{"$marker": "neg_infinity"}` |
| `:nan` | `{"$marker": "nan"}` |

The `$marker` key is reserved in the corpus schema. No corpus entry's `variables` map may use a key named `"$marker"`, and no success outcome's `value` may be a JSON object except in this exact tagged form.

The Elixir test helper `decode_marker/1` (private function in the test module) converts these to the corresponding atoms:

```
decode_marker(%{"$marker" => "infinity"}) → :infinity
decode_marker(%{"$marker" => "neg_infinity"}) → :neg_infinity
decode_marker(%{"$marker" => "nan"}) → :nan
decode_marker(other) → other (identity for all non-marker values)
```

The TypeScript and Dart consumers must implement equivalent decoding of the `$marker` sentinel before comparing against their own evaluator's output.

### 2.7 Encoding constraints

- No Elixir-specific encoding: no leading-colon atoms (`":infinity"` is WRONG), no tuple-brace arrays (`[":ok", 42]` is WRONG), no sigil syntax.
- All string values in `expression` use double-quoted JSON strings. If the expression source itself contains a double-quote character (e.g. a string literal inside the expression), it is JSON-escaped as `\"`.
- Integer division results in the corpus are always integers (JSON numbers without decimal points). Float division results are floats (JSON numbers with decimal points) or infinity markers.
- The `null` keyword in an expression (Elixir `nil`) is encoded as JSON `null` in the `value` field.

---

## 3. Companion document

This document — `lib/letflow/design/req289-expr-conformance-corpus.md` — is the companion schema document required by AC1. It is the authoritative source for:
- The file path (§1)
- The full JSON schema (§2)
- The infinity marker encoding (§2.6)
- The failure-kind enum (§2.4)
- The grammar-constructs tag vocabulary (§2.3)

The corpus file itself contains only data. Implementations must read this document for schema semantics.

---

## 4. Decision record amendment

**Record to amend:** `docs/migration/decisions/0020-frontend-architecture.md`

**What to add:** A new section under D1a titled "Implementation record: REQ-289 corpus location and schema" containing:
1. The canonical path: `priv/expr_conformance/corpus.json`
2. A pointer to this companion document: `lib/letflow/design/req289-expr-conformance-corpus.md`
3. Explicit statement that REQ-293 and REQ-294 MUST reference this path and are forbidden from building their own corpus or diverging from it.
4. Statement that adding a new builtin to `Letflow.Engine.Expr.builtin_function_names/0` without a corresponding corpus entry will cause the coverage-enumeration test (`test/letflow/engine/expr_conformance_corpus_test.exs`, §6 below) to fail, which is the intended gate.

The existing D1a prose ("a language-neutral conformance corpus … must exist … BEFORE any second client-side expression evaluator is built") is UNMODIFIED. The amendment adds the resolved implementation facts, not new design decisions.

This amendment is a deliverable of REQ-289 itself (AC7). ELIXIR-DEV must commit it alongside the corpus file and test.

---

## 5. ExUnit test file structure

**Path:** `test/letflow/engine/expr_conformance_corpus_test.exs`

**Module:** `Letflow.Engine.ExprConformanceCorpusTest`

```
use ExUnit.Case, async: true
alias Letflow.Engine.Expr
```

### 5.1 Corpus loading

The corpus is loaded once at module definition time using `@external_resource` + `File.read!`/`Jason.decode!`. The decoded corpus (a list of maps) is bound to a module attribute `@corpus`. All four test describes below access `@corpus` by name.

Loading must happen at compile time (not inside a `setup` callback) so that `@external_resource` causes a recompile when `corpus.json` changes.

The path is derived from `:code.priv_dir(:letflow)` rather than a hardcoded relative path, so the test works regardless of cwd.

### 5.2 Describe blocks and their test logic

**Describe 1: `"corpus success entries — parse and eval"`**

Iterates all corpus entries where `outcome["status"] == "ok"`. For each entry:
1. Calls `Expr.parse(entry["expression"])` — asserts `{:ok, ast}`.
2. Calls `Expr.eval(ast, decoded_variables(entry["variables"]))` — asserts `{:ok, decoded_value(entry["outcome"]["value"])}`.
3. Uses the entry's `id` in the failure message so ELIXIR-DEV can identify which entry failed.

`decoded_variables/1` is a private helper that recursively applies `decode_marker/1` to every leaf value of the variables map (for entries where a variable holds a marker, e.g. an infinity-valued variable used in a comparison test). In practice, all current variable values are plain scalars; the helper exists so this works correctly without special-casing.

`decode_marker/1` spec (see §2.6 above): converts `%{"$marker" => name}` to the corresponding atom, passes all other values through unchanged.

**Describe 2: `"corpus parse-failure entries"`**

Iterates all corpus entries where `outcome["error_kind"] == "parse_failure"`. For each entry:
1. Calls `Expr.parse(entry["expression"])`.
2. Asserts the result matches `{:error, {:parse_error, _}}`.
3. Does NOT call `eval/2`.

**Describe 3: `"corpus eval-failure entries"`**

Iterates all corpus entries where `outcome["error_kind"] == "eval_failure"`. For each entry:
1. Calls `Expr.parse(entry["expression"])` — asserts `{:ok, ast}` (entry MUST parse successfully).
2. Calls `Expr.eval(ast, decoded_variables(entry["variables"]))` — asserts `{:error, {:eval_error, _}}`.

**Describe 4: `"grammar coverage completeness"` (§6 below)**

Coverage-enumeration tests. See §6.

### 5.3 No dependency on `Letflow.Repo`, `Ecto.Sandbox`, or any process

The test has `async: true`. It calls only `Expr.parse/1` and `Expr.eval/2`, both of which are pure functions. No `use Letflow.DataCase`. No `setup` callback starting any process.

---

## 6. Coverage-enumeration test design

All coverage tests live in the `"grammar coverage completeness"` describe (§5.2, Describe 4).

The coverage proof is runtime, not inspection: each test reads `@corpus`, collects the union of all `grammar_constructs` arrays across all entries, and asserts that every required tag is present. This is not a count test (more than one entry per tag is fine); it is a presence test.

### 6.1 Per-construct-class coverage tests

One test per required tag class:

- `"covers all 6 comparison operators"` — asserts `"cmp:eq"`, `"cmp:neq"`, `"cmp:lt"`, `"cmp:lte"`, `"cmp:gt"`, `"cmp:gte"` are all present in the union of `grammar_constructs`.
- `"covers and, or, not"` — asserts `"bool:and"`, `"bool:or"`, `"bool:not"` are present.
- `"covers all 4 literal kinds"` — asserts `"lit:boolean"`, `"lit:integer"`, `"lit:float"`, `"lit:string"` are present.
- `"covers all 5 arithmetic operators"` — asserts `"arith:add"`, `"arith:sub"`, `"arith:mul"`, `"arith:div"`, `"arith:mod"` are present.
- `"covers unary negation"` — asserts `"arith:neg"` is present.
- `"covers dotted variable paths"` — asserts `"var:dotted"` is present.

### 6.2 Builtin coverage test — coupled to `builtin_function_names/0`

This is the key test for AC3's "future builtin must cause failure" requirement.

```
test "all builtins from builtin_function_names/0 have at least one corpus entry"
```

Algorithm (no implementation code — pseudocode only):

```
covered_builtin_names :=
  @corpus
  |> flat_map(fn entry -> entry["grammar_constructs"] end)
  |> filter(fn tag -> String.starts_with?(tag, "builtin:") end)
  |> map(fn tag -> String.replace_prefix(tag, "builtin:", "") end)
  |> into(MapSet)

required_builtin_names :=
  Expr.builtin_function_names()
  |> map(&Atom.to_string/1)
  |> into(MapSet)

missing := MapSet.difference(required_builtin_names, covered_builtin_names)

assert missing == MapSet.new(),
  "Builtins with no corpus entry: #{inspect(missing)}. " <>
  "Add a corpus entry for each missing builtin."
```

**Why this ensures a future builtin causes failure:** `Expr.builtin_function_names/0` is called at test runtime. If a new builtin is added to `@builtin_function_names` in `expr.ex`, `builtin_function_names/0` returns a list with one more atom. The test then computes a `missing` set that includes the new builtin's string name. `assert missing == MapSet.new()` fails. The only way to make it pass again is to add a corpus entry with the tag `"builtin:<new_name>"`.

No string-to-atom conversion of arbitrary corpus data occurs: the `covered_builtin_names` set contains plain strings from the corpus file, and the `required_builtin_names` set is produced by `Atom.to_string/1` on the atoms already defined by the module. No `String.to_atom/1` call exists in this test.

---

## 7. Failure-entry schema and parse-failure ≠ eval-failure interchangeability tests

### 7.1 Minimum failure-entry count

The corpus MUST contain at least one entry with `"error_kind": "parse_failure"` and at least one with `"error_kind": "eval_failure"`. The test asserts both counts are > 0 before iterating the respective describes (§5.2, Describes 2 and 3).

### 7.2 Divergence-prone failure cases to include

Parse-failure entries must include at least:
- An expression with a trailing binary operator and no right operand (e.g. `"amount +"`) — the canonical `parse_strict/1` test case.
- An expression using a non-whitelisted function name (e.g. `"frobnicate(1)"`) — the `parse/1` unrecognised-identifier-in-call-position case.

Eval-failure entries must include at least:
- An integer division-by-zero (`"5 / 0"` with empty variables, or a variable-based equivalent).
- An undefined variable (`"missing_var > 1"` with `variables: {}`).

### 7.3 Non-interchangeability tests

Two additional tests in Describe 4 (`"grammar coverage completeness"`):

**Test A: `"parse_failure entries fail at parse time, not eval time"`**

```
parse_failures := Enum.filter(@corpus, fn e -> e["outcome"]["error_kind"] == "parse_failure" end)
assert length(parse_failures) > 0

for each entry in parse_failures:
  result := Expr.parse(entry["expression"])
  assert result matches {:error, {:parse_error, _}},
    message: "entry #{entry["id"]} must fail at parse, got: #{inspect(result)}"
```

**Test B: `"eval_failure entries parse successfully (failure is at eval time, not parse time)"`**

```
eval_failures := Enum.filter(@corpus, fn e -> e["outcome"]["error_kind"] == "eval_failure" end)
assert length(eval_failures) > 0

for each entry in eval_failures:
  result := Expr.parse(entry["expression"])
  assert result matches {:ok, _},
    message: "entry #{entry["id"]} must parse successfully, got: #{inspect(result)}"
```

Together, Tests A and B demonstrate that `"parse_failure"` and `"eval_failure"` entries are structurally separated: a `parse_failure` entry never reaches `eval/2`, and an `eval_failure` entry always passes `parse/1`. A corpus entry that is miscategorised (e.g. an expression that actually fails to parse but is tagged `"eval_failure"`) will fail Test B. A corpus entry that should be a parse error but is tagged `"parse_failure"` and actually evaluates successfully would fail Describe 3's assertion (§5.2). This is a two-sided correctness gate.

---

## 8. Required corpus entries for AC4 divergence-prone semantics

The following entries MUST be present in the corpus. Their exact `id` values and additional grammar tags are ELIXIR-DEV's choice, but the specified expression, variables, and expected outcome are non-negotiable — they encode a permanent cross-language contract.

### 8.1 ASCII-only lower with non-ASCII input

| Field | Value |
|---|---|
| `expression` | `lower("CAFÉ")` |
| `variables` | `{}` |
| `outcome.status` | `"ok"` |
| `outcome.value` | `"cafÉ"` (NOT `"café"`) |
| Required tag | `"builtin:lower"` |
| `description` | must name "ASCII-only" and "non-ASCII input" |

### 8.2 ASCII-only upper with non-ASCII input

| Field | Value |
|---|---|
| `expression` | `upper("café")` |
| `variables` | `{}` |
| `outcome.status` | `"ok"` |
| `outcome.value` | `"CAFé"` (NOT `"CAFÉ"`) |
| Required tag | `"builtin:upper"` |
| `description` | must name "ASCII-only" and "non-ASCII input" |

### 8.3 trim's 4-character ASCII whitespace set

| Field | Value |
|---|---|
| `expression` | `trim(" \thi there\r\n ")` (space, tab, `\r`, `\n` present) |
| `variables` | `{}` |
| `outcome.status` | `"ok"` |
| `outcome.value` | `"hi there"` (interior space preserved) |
| Required tag | `"builtin:trim"` |
| `description` | must name "ASCII whitespace" and "4 characters: space, tab, \\n, \\r" |

The JSON encoding of the expression string must use `\t`, `\r`, `\n` as JSON escape sequences; the expected value retains the interior space literally.

### 8.4 Positive-infinity: positive float / 0.0

| Field | Value |
|---|---|
| `expression` | `1.0 / 0.0` |
| `variables` | `{}` |
| `outcome.status` | `"ok"` |
| `outcome.value` | `{"$marker": "infinity"}` |
| Required tags | `"arith:div"`, `"lit:float"` |
| `description` | must name "positive dividend / 0.0 → :infinity" |

### 8.5 Negative-infinity: negative float / 0.0

| Field | Value |
|---|---|
| `expression` | `-1.0 / 0.0` |
| `variables` | `{}` |
| `outcome.status` | `"ok"` |
| `outcome.value` | `{"$marker": "neg_infinity"}` |
| Required tags | `"arith:div"`, `"arith:neg"`, `"lit:float"` |
| `description` | must name "negative dividend / 0.0 → :neg_infinity" |

### 8.6 NaN: 0.0 / 0.0

| Field | Value |
|---|---|
| `expression` | `0.0 / 0.0` |
| `variables` | `{}` |
| `outcome.status` | `"ok"` |
| `outcome.value` | `{"$marker": "nan"}` |
| Required tags | `"arith:div"`, `"lit:float"` |
| `description` | must name "0.0 / 0.0 → :nan" |

---

## 9. Scope constraints (AC8, AC10)

- `lib/letflow/engine/expr.ex` is UNMODIFIED by this requirement. The corpus is derived from the existing implementation, not the reverse.
- `test/fixtures/simulation/differential_corpus.json` is UNMODIFIED.
- `test/letflow/engine/expr_differential_corpus_test.exs` is UNMODIFIED.
- The new corpus does not carry gateway-lifecycle keys (`source_gateway_node_id`, `source_definition_id`, `condition_text`).
- `mix letflow.check` must pass after the implementation is merged; the new test file is subject to the same formatter/typecheck requirements as all other test files.

---

## 10. Acceptance criterion traceability

| AC | Where addressed in this design |
|---|---|
| AC1 — corpus file + min fields + schema doc | §1 (path), §2.2 (required fields), this document as companion doc (§3) |
| AC2 — ExUnit test iterates corpus, asserts outcome, passes | §5 (full test structure) |
| AC3 — coverage-enumeration test, builtin_function_names/0 coupling | §6, specifically §6.2 |
| AC4 — divergence-prone entries: ASCII lower/upper, trim whitespace, 3 infinity markers | §8.1–§8.6 |
| AC5 — failure entries, schema distinguishes kinds, both kinds asserted, not interchangeable | §2.4, §7 |
| AC6 — infinity/failure encoding documented, no Elixir-specific encoding | §2.4, §2.6, §2.7 |
| AC7 — location recorded in decisions/ record, REVIEWER signed off | §4 |
| AC8 — differential_corpus.json and its test UNMODIFIED | §9 |
| AC9 — mix letflow.check passes | §9 |
| AC10 — expr.ex UNMODIFIED | §9 |

---

## 11. Open questions

None. All acceptance criteria map to concrete design elements. No deferred decisions.
