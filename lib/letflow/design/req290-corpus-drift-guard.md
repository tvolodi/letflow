# Design: REQ-290 — Corpus drift guard + version/capability marker

**Requirement:** REQ-290 (stage S8).
**Owner (implementer):** ELIXIR-DEV.
**Depends on:** REQ-289 (done — `priv/expr_conformance/corpus.json`,
`test/letflow/engine/expr_conformance_corpus_test.exs`,
`lib/letflow/design/req289-expr-conformance-corpus.md`).
**Downstream dependents:** REQ-293 (TypeScript evaluator), REQ-294 (Dart evaluator) — both
must read the marker scheme this document settles (§4) rather than invent their own.

Signatures and type shapes only. No function bodies, no `def ... do ... end`, no
`defmodule` blocks. Two illustrative pseudocode blocks appear (§2.3, §3.2) — both are
explicitly marked ILLUSTRATIVE, not implementation.

---

## 0. Sources read for this design, and what they confirmed

- `lib/letflow/engine/expr.ex` (full, both halves). Confirmed current accepted surface:
  - `@type cmp_op :: :eq | :neq | :lt | :lte | :gt | :gte` (6 atoms)
  - `@type arith_op :: :add | :sub | :mul | :div | :mod` (5 atoms — `:neg` is NOT a member;
    unary negation is its own `ast()` variant, `{:neg, ast()}`)
  - `@type builtin_name :: :length | :lower | :upper | :trim | :contains | :startsWith | :endsWith | :coalesce`
    (8 atoms), backed by `@builtin_function_names` and exposed via
    `builtin_function_names/0` (already public, already mechanically consulted by
    REQ-289's own coverage test).
  - `@type ast :: {:lit, value()} | {:var, path} | {:not, ast()} | {:and, ast(), ast()} |
    {:or, ast(), ast()} | {:cmp, cmp_op(), ast(), ast()} | {:arith, arith_op(), ast(), ast()}
    | {:neg, ast()} | {:call, builtin_name(), args :: [ast()]}` — 9 tuple variants, tagged
    by their first element: `:lit :var :not :and :or :cmp :arith :neg :call`.
  - **Re-verified per the requirement's instruction to check for drift since REQ-289**:
    no change to any of these four type definitions or to `@builtin_function_names` since
    REQ-289 landed. REQ-288 (`lib/letflow/design/req288-expr-definition-validator.md`,
    confirmed present) routes `Expr.parse_strict/1` into definition-time validation but
    adds no new grammar construct — it is a caller, not a surface change. So the corpus
    and this guard start from a currently-accurate baseline; nothing is already missing.
- `test/letflow/engine/expr_conformance_corpus_test.exs` (full). Confirmed: Describe 4
  ("grammar coverage completeness") already has ONE mechanically-derived test —
  `"all builtins from builtin_function_names/0 have at least one corpus entry"`,
  driven by `Expr.builtin_function_names/0` directly, zero hardcoded names. **This
  already satisfies AC1/AC2 for the builtin dimension specifically** — REQ-290 does not
  re-implement it, it is retained unchanged and is one of the two components this guard
  relies on (§1). The other five coverage tests in that same describe
  (comparison/bool/literal/arithmetic/unary-negation tag presence) are `~w(...)` literal
  lists copied from the design doc's own prose — i.e. exactly the "hand-copied list that
  itself drifts" pattern AC2 forbids for a *new* check, just not yet closed for
  `cmp_op`/`arith_op`/`ast()`. **This is the actual gap REQ-290 closes.**
- `lib/letflow/design/req289-expr-conformance-corpus.md` (full). Confirmed the corpus's
  JSON schema (§2 there), the `grammar_constructs` closed tag vocabulary (§2.3 there —
  6 cmp + 3 bool + 5 lit + 5 arith + 1 neg + 2 var + 8 builtin = 30 tags), and that this
  document is REQ-289's "companion document" AC4 requires the marker semantics to live
  in. §12 of that document is a prior addendum (ORCH, same requirement) — precedent for
  adding a dated `§13` addendum here rather than a second document.
- `mix.exs` (`aliases/0`) and `.github/workflows/ci.yml` (full). Confirmed `mix letflow.check`
  is the CI command (`ci.yml`'s only `backend` step), and its last alias step,
  `letflow.check.test`, shells to `scripts/test_parallel.sh`, which runs the full ExUnit
  suite (`mix test --partitions N`) — **every `test/**/*_test.exs` file is discovered and
  run automatically; no `mix.exs`/`ci.yml` edit is needed to wire a new test file in.**
  This directly shapes §1's implementation-shape decision (ExUnit test, not a `Mix.Task`).
- `test/support/` (directory listing). Confirmed the existing convention of
  requirement-scoped test-support modules (e.g. `req072_probe.ex`, `req076_broken_migration_fixture.ex`)
  — precedent for `test/support/req290_capability_check.ex` (§3).

---

## 1. Implementation shape: an ExUnit test file, not a `Mix.Task`

**Decision:** the guard is `test/letflow/engine/expr_corpus_drift_guard_test.exs`
(module `Letflow.Engine.ExprCorpusDriftGuardTest`), not a new `lib/mix/tasks/letflow.check_*.ex`
task.

**Justification (AC5 — "runs as part of the standard CI command, not manually invoked"):**
`mix letflow.check`'s final step, `letflow.check.test`, already runs the *entire* ExUnit
suite via `scripts/test_parallel.sh`'s `mix test --partitions N`. Any file under `test/`
matching `*_test.exs` is discovered and executed automatically — zero edits to `mix.exs`'s
`aliases/0` or `.github/workflows/ci.yml` are needed. A new `Mix.Task` would instead
require a new alias-list entry (an extra moving part, an extra place drift could
silently stop being wired in — exactly the "a check nobody runs is not a check" risk
`mix.exs`'s own `letflow.check` comments already warn about for `lint_handoffs`). An
ExUnit test file inherits the existing, already-hardened wiring for free.

**Justification (AC8 — "the CI command that runs the surface guard ALSO runs REQ-289's
own corpus ExUnit runner"):** both `expr_conformance_corpus_test.exs` (REQ-289) and
`expr_corpus_drift_guard_test.exs` (this requirement) are ExUnit test files under
`test/letflow/engine/`, both discovered and run by the same `scripts/test_parallel.sh`
invocation inside the same `mix letflow.check` command. This is not a coincidence to be
verified after the fact — it is a structural consequence of choosing the ExUnit shape
in the first place, and RELEASE-VALIDATOR's demonstration (§8) states it explicitly by
name rather than leaving it implied.

---

## 2. The surface-extraction mechanism (the crux)

### 2.1 Investigated and rejected: parsing `@type` from source text

Grepping `expr.ex` for `@type cmp_op ::` and splitting on `|` was considered and
rejected. It would work today, but it is source-text pattern matching wearing the
costume of introspection — a reformatted typespec (e.g. one atom per line) or a
`@type` written via a macro would silently stop matching, and nothing about the
technique is different in kind from the "grep for a hardcoded count of 8" pattern the
requirement text explicitly forbids. Rejected.

### 2.2 Investigated and rejected: exercising `parse/1`/`eval/2` behaviourally

Feeding synthetic expressions through `Expr.parse/1` to see which operators are
"accepted" was considered. Rejected because it cannot enumerate a *closed* set — there
is no way to ask "have I tried every accepted token" without already knowing the
answer, so this degenerates back into a hardcoded probe list (the same class of defect
as "grep for 8").

### 2.3 Adopted: `Code.Typespec.fetch_types/1` — real, load-bearing, standard-library introspection

**This is genuinely mechanically feasible in Elixir**, and is not a workaround —
`Code.Typespec` is the same public API `IEx.Info`, `ExDoc`, and typespec-consuming
tools like Dialyzer's own ecosystem use to read a compiled module's `@type` definitions
back out of its BEAM file at runtime. Elixir's default compiler options (`mix compile`,
unmodified by this project) embed the debug-info chunk `Code.Typespec.fetch_types/1`
reads; nothing in `mix.exs` disables it. This is a compile/test-time capability only —
it would not survive a `mix release`'s `:strip_beams` step, but this guard runs under
`mix test`, never against a stripped release artifact, so that is not a constraint here.

**Shape of the data returned** (Erlang abstract-code terms, confirmed against the
standard `Code.Typespec` contract):

```
Code.Typespec.fetch_types(Letflow.Engine.Expr)
  :: {:ok, [{:type | :typep | :opaque, {name :: atom(), type_ast :: term(), params :: [term()]}}]}
   | :error
```

For `@type cmp_op :: :eq | :neq | :lt | :lte | :gt | :gte`, the matching entry's
`type_ast` is (annotations elided):

```
ILLUSTRATIVE — shape of the abstract-code term, not implementation:
{:type, _anno, :union, [
  {:atom, _anno, :eq}, {:atom, _anno, :neq}, {:atom, _anno, :lt},
  {:atom, _anno, :lte}, {:atom, _anno, :gt}, {:atom, _anno, :gte}
]}
```

For `ast()`, each union member is a tuple type whose first element is the variant's
tag atom, e.g. `{:cmp, cmp_op(), ast(), ast()}` becomes
`{:type, _, :tuple, [{:atom, _, :cmp}, {:user_type, _, :cmp_op, []}, {:user_type, _, :ast, []}, {:user_type, _, :ast, []}]}`.

### 2.4 One generic walker serves all four types — `extract_tag_atoms/1`

```
ILLUSTRATIVE PSEUDOCODE — not implementation. Signature only is load-bearing:

@spec extract_tag_atoms(type_ast :: term()) :: MapSet.t(atom())

extract_tag_atoms({:type, _, :union, members}):
    union of extract_tag_atoms(m) for m in members
extract_tag_atoms({:type, _, :tuple, [{:atom, _, tag} | _rest]}):
    MapSet.new([tag])
extract_tag_atoms({:atom, _, value}):
    MapSet.new([value])
extract_tag_atoms(_other):
    MapSet.new([])   # remote types, params, literals inside a variant's non-tag
                      # positions — deliberately not descended into; see §2.5
```

One function, no per-type special-casing:
- Applied to `cmp_op`'s `type_ast` → hits the `{:atom, _, value}` clause on each union
  member → `MapSet.new([:eq, :neq, :lt, :lte, :gt, :gte])`.
- Applied to `arith_op`'s `type_ast` → same clause → `MapSet.new([:add, :sub, :mul, :div, :mod])`.
- Applied to `builtin_name`'s `type_ast` → same clause →
  `MapSet.new([:length, :lower, :upper, :trim, :contains, :startsWith, :endsWith, :coalesce])`
  (used only for the self-consistency check, §6.3 — the primary builtin-drift signal
  remains `builtin_function_names/0` directly, per REQ-289's existing test).
- Applied to `ast()`'s `type_ast` → hits the `{:type, _, :tuple, [{:atom,_,tag}|_]}`
  clause once per variant → `MapSet.new([:lit, :var, :not, :and, :or, :cmp, :arith, :neg, :call])`.

### 2.5 Documented limitation (not silently resolved)

`extract_tag_atoms/1`'s catch-all clause discards anything it does not recognize as a
union, a tagged tuple, or a bare atom — it does not attempt to resolve `{:user_type, ...}`
references (e.g. it does not descend into `cmp_op()` when walking `ast()`'s `{:cmp,
cmp_op(), ast(), ast()}` variant; it only takes that variant's leading tag, `:cmp`). This
is intentional, not an oversight: `ast()`'s own union is walked once for its 9 tags, and
`cmp_op()`/`arith_op()` are walked separately, each keyed by name via
`fetch_types/1`'s own `name` field — there is no need for the walker to also chase
cross-references, and attempting to would risk infinite recursion on `ast()`'s
self-referential variants (`{:and, ast(), ast()}` etc.) for no benefit. Stated here so a
future reader does not "fix" this as a perceived bug.

---

## 3. `test/letflow/engine/expr_corpus_drift_guard_test.exs`

**Module:** `Letflow.Engine.ExprCorpusDriftGuardTest`
**`async: true`** — reads only `Code.Typespec`, `Letflow.Engine.Expr`, and the corpus/
manifest JSON files, all pure/no-Repo, same justification as REQ-289's own test.

### 3.1 Compile-time loading

```
@corpus_path Path.join(:code.priv_dir(:letflow), "expr_conformance/corpus.json")
@manifest_path Path.join(:code.priv_dir(:letflow), "expr_conformance/manifest.json")
@external_resource @corpus_path
@external_resource @manifest_path
@corpus <load + Jason.decode!, same shape as REQ-289's test>
@manifest <load + Jason.decode!>
```

### 3.2 Private helper signatures

```
@spec cmp_op_atoms() :: MapSet.t(atom())
@spec arith_op_atoms() :: MapSet.t(atom())
@spec builtin_name_atoms() :: MapSet.t(atom())
@spec ast_tag_atoms() :: MapSet.t(atom())
# Each fetches Code.Typespec.fetch_types(Letflow.Engine.Expr) once (memoized via a
# module attribute computed at compile time — @typespec_types), locates the entry
# whose name matches, and applies extract_tag_atoms/1 (§2.4) to its type_ast.

@spec corpus_tags_with_prefix(prefix :: String.t()) :: MapSet.t(String.t())
# Flat-maps @corpus's grammar_constructs arrays, keeps tags starting with `prefix`.

@spec required_cmp_tag_names() :: MapSet.t(String.t())   # cmp_op_atoms/0 |> Atom.to_string
@spec required_arith_tag_names() :: MapSet.t(String.t()) # arith_op_atoms/0 minus :neg |> Atom.to_string

# ast() tag -> required corpus tag-PREFIX mapping. A hand-maintained table — see §3.3
# for why this is safe despite being one.
@ast_tag_prefix_map %{
  lit: "lit:", var: "var:", not: "bool:not", and: "bool:and", or: "bool:or",
  cmp: "cmp:", arith: "arith:", neg: "arith:neg", call: "builtin:"
}
```

Rationale for `ILLUSTRATIVE PSEUDOCODE` on the cmp/arith extraction path only (not
repeated per-function): every `@spec` above is the real, load-bearing deliverable;
their bodies are one call each to `extract_tag_atoms/1` plus a lookup by `name` in
`Code.Typespec.fetch_types/1`'s result — mechanically implied by §2.4 and not repeated
here to avoid drifting into function bodies, which CODE-DESIGN-VALIDATOR gates against.

### 3.3 Tests

**Describe `"cmp_op/arith_op surface, mechanically derived"`:**

- `test "every cmp_op/0 atom has a corpus entry tagged cmp:<atom>"` — asserts
  `MapSet.difference(required_cmp_tag_names(), <cmp:-prefixed tags actually present>) == MapSet.new()`.
  Failure message names the missing atom(s) by value, e.g. `"cmp_op atoms with no
  corpus coverage: [:neq]"` (illustrative — actual set is currently empty).
- `test "every arith_op/0 atom (excluding :neg) has a corpus entry tagged arith:<atom>"`
  — same shape, over `required_arith_tag_names()`.

**Describe `"ast() node-kind surface, mechanically derived"`:**

- `test "every ast() tag is known and mapped to a required corpus tag-prefix"` —
  computes `ast_tag_atoms()` (currently 9 tags), and for each, asserts it is a key of
  `@ast_tag_prefix_map`. **This is the test that fails when an entirely new construct
  class is added** (e.g. a future ternary `{:ternary, ast(), ast(), ast()}` variant) —
  `ast_tag_atoms()` would return a 10th atom (`:ternary`) with no entry in
  `@ast_tag_prefix_map`, and the test fails with `"unmapped ast() tag: :ternary — add
  it to @ast_tag_prefix_map and a corresponding corpus entry"` rather than silently
  passing because nothing else noticed.
- `test "every ast() tag's mapped corpus prefix has at least one covering entry"` — for
  each `{tag, prefix}` pair in `@ast_tag_prefix_map` that IS present in
  `ast_tag_atoms()` (i.e. currently real, not a stale leftover mapping for a removed
  tag), asserts `corpus_tags_with_prefix(prefix)` is non-empty.

**Why `@ast_tag_prefix_map` being hand-maintained does not reintroduce AC2's forbidden
pattern:** AC2 forbids a hardcoded list being *load-bearing for detecting drift* — i.e.
a list whose staleness would let the check silently keep passing. `@ast_tag_prefix_map`
is the opposite shape: it is consulted only as a lookup *after* `ast_tag_atoms()` is
mechanically derived from the live typespec, and a lookup miss is a hard test failure,
not a silent skip. A stale `@ast_tag_prefix_map` (one entry short of the live tag set)
cannot cause a false PASS — it can only cause a (correct) FAIL demanding the map be
updated. That is the same property `mix.exs`'s own comment stresses for
`check_requirements_registration`/`lint_handoffs`: "a check nobody runs is not a
check," inverted here to "a check that can go stale and still pass is not a check" —
this map structurally cannot do that.

**Describe `"builtin_name self-consistency"`:**

- `test "builtin_name/0 typespec and builtin_function_names/0 agree"` — asserts
  `builtin_name_atoms() == MapSet.new(Expr.builtin_function_names())`. Bonus coverage
  (not required by any AC) catching the specific class the moduledoc itself flags as a
  manual-sync risk (`expr.ex:154`: "kept in sync ... by construction (both are
  hand-written from the same closed list)") — if that construction-time discipline is
  ever violated, this is the test that would catch it, distinct from AC1's
  demonstration.

**Describe `"corpus manifest capabilities are drift-guarded too"`:** see §4.4.

---

## 4. Version/capability marker

### 4.1 File: `priv/expr_conformance/manifest.json`

A **new sibling file** to `corpus.json`, in the same `priv/expr_conformance/` directory
— not a change to `corpus.json`'s own top-level shape. **Rejected alternative:**
wrapping `corpus.json`'s existing bare-array top level in `{"version": ..., "entries":
[...]}` was considered and rejected — REQ-289's own `expr_conformance_corpus_test.exs`
already treats `@corpus` as a bare list (`Enum.filter(@corpus, ...)`, four times) and
so does the design doc's own schema (§2.1 there: `corpus.json := [ entry, ... ]`).
Changing that shape would force an edit to REQ-289's already-shipped, already-passing
test file for a concern (versioning) that is orthogonal to entry content — a sibling
file avoids that coupling entirely and keeps `corpus.json` byte-shape-stable for its
existing three consumers (this Elixir test, and the not-yet-built REQ-293/REQ-294
readers, which will read `manifest.json` as a second, independent file).

### 4.2 Schema

```
manifest.json := {
  "corpus_schema_version": string,   // semver "MAJOR.MINOR.PATCH", see §4.3
  "capabilities": [ string, ... ]    // sorted, deduplicated list of every
                                      // grammar_constructs tag this corpus version
                                      // asserts conformance for — the same closed
                                      // vocabulary as REQ-289 doc §2.3, mechanically
                                      // checked against Expr's live typespecs (§4.4)
}
```

No other top-level fields. `capabilities` entries use the identical tag strings as
`grammar_constructs` (`"cmp:eq"`, `"builtin:lower"`, etc.) — one vocabulary, not two.

### 4.3 `corpus_schema_version` bump policy (documented, not mechanically enforced)

- **MINOR** bump (`1.0.0` → `1.1.0`): a new `capabilities` entry is added (a new
  construct, operator, or builtin) with new corpus entries covering it. Backward
  compatible — a client on an older manifest version simply doesn't know about the new
  construct yet, and per `req289-expr-conformance-corpus.md` §13 must fail loudly only
  if it actually *encounters* an expression using it.
- **MAJOR** bump (`1.x.y` → `2.0.0`): an *existing* corpus entry's documented outcome
  changes for the same `expression`/`variables` pair (a semantic change to an existing
  construct — the requirement's own example: `lower/1` going ASCII-only →
  Unicode-aware), or a `capabilities` entry is removed. Not backward compatible — an
  older client would silently compute the old (now-wrong) answer.
- **PATCH**: corpus additions that add no new `capabilities` entry (more coverage of an
  already-listed construct) — no semantic surface change.

This policy is process discipline for ELIXIR-DEV/REVIEWER (same class of manual rule as
this project's own semver-adjacent conventions elsewhere), not something
`ExprCorpusDriftGuardTest` can verify — correctly classifying MINOR vs. MAJOR requires
diffing *previous* corpus content against new content, which is out of this
requirement's scope (no corpus-history diffing tool exists or is requested by any AC).
Flagged explicitly as **not mechanically enforced** rather than silently implying it is.

### 4.4 `capabilities` content IS mechanically guarded

Unlike the version number, the `capabilities` array's *content* is checked by
`ExprCorpusDriftGuardTest` (§3.3's last describe):

```
@spec mechanically_derived_capabilities() :: MapSet.t(String.t())
# Union of: required_cmp_tag_names(), required_arith_tag_names(),
# "arith:neg" (from ast_tag_atoms()'s :neg entry via @ast_tag_prefix_map),
# the 3 bool: tags (hardcoded here ONLY as the fixed {and,or,not} <-> ast() tag
# correspondence already established by @ast_tag_prefix_map — not a separate
# unguarded list), the 5 lit: tags (see open question, §7), the 2 var: tags (same),
# and Expr.builtin_function_names/0 mapped through "builtin:" <> Atom.to_string(name).
```

- `test "manifest.json's capabilities list matches the mechanically-derived required set"`
  — asserts `MapSet.new(@manifest["capabilities"]) == mechanically_derived_capabilities()`,
  failing loudly (naming both the missing and the extra entries) on any mismatch. This
  means a `capabilities` array that has gone stale relative to `corpus.json`'s own
  coverage, or relative to `expr.ex`'s live surface, is caught by the SAME run that
  catches an under-covered corpus — one failing test names both problems distinctly if
  both exist (missing corpus coverage is a Describe-1/2 failure above; a stale manifest
  is this test's own failure), never conflated into one ambiguous message.

### 4.5 Client behaviour contract — lives in REQ-289's companion document (AC4)

**Resolved (Option A, no longer open — see §8):** the marker's client-behaviour
semantics are NOT stated in this document. They are stated in
`lib/letflow/design/req289-expr-conformance-corpus.md` §13 ("Addendum: REQ-290
client-behaviour contract for the version/capability marker (AC4)"), appended to that
file as part of this design. That is the SAME companion document REQ-289 produced, per
AC4's literal wording, and per that file's own §3 precedent ("Implementations must read
this document for schema semantics") and its §12 addendum precedent (a later
requirement appending a dated section to the same file rather than opening a second
one). REQ-293/REQ-294 implementers, and ELIXIR-DEV building this requirement's own
`test/support/req290_capability_check.ex` reference implementation (§5), MUST read
`req289-expr-conformance-corpus.md` §13 for the contract text — it is not duplicated
here. This document (`req290-corpus-drift-guard.md`) remains the authoritative source
for the marker's *mechanism*: the file path and schema (§4.1–§4.2), the version-bump
policy (§4.3), and the mechanical guard that keeps `capabilities` accurate (§4.4).

**ELIXIR-DEV implementation-checklist item (this design's own deliverable list):**
append `req289-expr-conformance-corpus.md` §13 (already written, verbatim, as part of
this design's rework) alongside `manifest.json`, the drift-guard test, and the
`req290_capability_check.ex` reference implementation when this requirement's changeset
is committed — i.e. confirm via `git diff` that `req289-expr-conformance-corpus.md`'s
new §13 is included in the same commit/PR as this requirement's other deliverables, not
dropped as "already done by CODE-DESIGNER so no need to commit it." The design-time
edit and the implementation-time commit are two different actions on the same file;
ELIXIR-DEV must not skip the second one.

### 4.6 Amendment to `docs/migration/decisions/0020-frontend-architecture.md`

Add a dated addendum under D1a (same location as REQ-289's own amendment, §4 of the
REQ-289 design doc) recording: the marker's path (`priv/expr_conformance/manifest.json`),
its two fields, and a one-line pointer to `req289-expr-conformance-corpus.md` §13 (not
this document) as the authoritative client-behaviour contract. This is a REVIEWER-gated
deliverable (AC4/AC7-equivalent for this requirement), same discipline as REQ-289's own
amendment.

---

## 5. Test-support reference implementation: `test/support/req290_capability_check.ex`

**Purpose:** AC3 requires "a test asserts the documented client behaviour on an
unrecognised marker: fail loudly, not skip and not guess — the test must distinguish
those three outcomes." No TypeScript/Dart client exists yet (out of this requirement's
scope per its own SCOPE FENCE), so this is proven with a small, pure Elixir reference
implementation of `req289-expr-conformance-corpus.md` §13's contract, living under `test/support/` (compiled only for
`Mix.env() == :test`, per `mix.exs`'s `elixirc_paths/1`) — test-support fixture code,
not production `lib/` code, following this project's existing `test/support/req072_probe.ex`-style
convention for requirement-scoped test helpers.

### 5.1 Signatures

```
@spec check_compatibility(
        client_capabilities :: MapSet.t(String.t()),
        manifest_capabilities :: [String.t()]
      ) :: :compatible | {:incompatible, unsupported :: [String.t()]}

@spec evaluate_or_fail(
        compatibility :: :compatible | {:incompatible, [String.t()]},
        evaluate_thunk :: (-> {:ok, term()} | {:error, term()})
      ) :: {:ok, term()} | {:error, {:stale_version, unsupported :: [String.t()]}}
```

`evaluate_or_fail/2`'s return type is a **closed 2-arm union**:
`{:ok, term()} | {:error, {:stale_version, [String.t()]}}`. This closure is itself part
of the proof: there is no third arm this function's type permits for "silently
returned nothing" (skip) or "silently returned a substituted default without the
`:stale_version` tag" (guess) — any implementation satisfying this `@spec` structurally
cannot produce either forbidden outcome without violating its own declared type, which
`mix compile --warnings-as-errors`/Dialyzer-adjacent tooling would not save it from at
runtime, but which the test below verifies behaviourally.

### 5.2 Test: `test/support/req290_capability_check_test.exs`

Three cases, asserting three **distinguishable** outcomes explicitly (not just
"succeeds/fails" — the actual return shape is asserted each time):

- `test "compatible manifest: evaluation proceeds and returns the thunk's own {:ok, _}"`
  — `check_compatibility(client_caps, manifest_caps)` with `manifest_caps ⊆ client_caps`
  returns `:compatible`; `evaluate_or_fail(:compatible, fn -> {:ok, 42} end)` returns
  `{:ok, 42}` — the real evaluation path ran.
- `test "incompatible manifest: fails loudly with the specific unsupported tag(s), never :ok"`
  — `manifest_caps` containing a tag not in `client_caps` (e.g. a simulated future
  `"builtin:regexMatch"`) makes `check_compatibility/2` return
  `{:incompatible, ["builtin:regexMatch"]}`; `evaluate_or_fail/2` on that returns
  `{:error, {:stale_version, ["builtin:regexMatch"]}}` — asserted by exact pattern
  match, and **the thunk is never invoked** (assert via a test-local counter/`Agent`
  that the evaluate_thunk's side effect did not run) — proving the fail-loud path does
  not fall through to a guessed evaluation.
- `test "the incompatible case is neither a silent-skip shape nor a silent-guess shape"`
  — explicit negative assertions distinguishing the three outcomes named in AC3:
  `refute match?(:skip, result)` (no such atom is ever producible — the closed
  `@spec` in §5.1 makes this true by construction, and this assertion documents that
  fact operationally rather than only in prose), and
  `refute match?({:ok, _}, result)` for the SAME incompatible input that produced
  `{:error, {:stale_version, _}}` in the previous test — i.e., one incompatible input,
  checked against both "is it the fail-loud shape" (positive, previous test) and "is it
  NOT the ok/guessed shape" (negative, this test), so the guess-outcome is ruled out by
  measurement on the actual return value, not merely inferred from the `@spec`.

---

## 6. Demonstration procedure for AC1 (operational, for TEST-RUNNER/RELEASE-VALIDATOR)

AC1 requires the check to be **demonstrated** failing and passing again, not merely
asserted to have that property. Exact steps:

1. On a scratch/local working copy (never committed to the feature branch — this is a
   throwaway verification, per this project's own "scratch commit/fixture" wording in
   the AC):
   - Add a 9th atom to `expr.ex`'s `@type builtin_name` union and its
     `@builtin_function_names` list, e.g. append `:reverseString` to both (mirroring
     the existing 8-entry shape exactly — this is the literal scratch edit AC1 names).
2. Run `mix test test/letflow/engine/expr_conformance_corpus_test.exs
   test/letflow/engine/expr_corpus_drift_guard_test.exs` and capture real output.
   **Expected: both files report a failure** — REQ-289's own
   `"all builtins from builtin_function_names/0 have at least one corpus entry"` test
   (already mechanically driven, §0) fails naming `:reverseString` as missing corpus
   coverage, AND this requirement's `"builtin_name/0 typespec and builtin_function_names/0 agree"`
   self-consistency test (§3.3) passes (both sides changed together) while the manifest
   capabilities test (§4.4) ALSO fails, naming `"builtin:reverseString"` as present in
   the mechanically-derived required set but absent from `manifest.json`'s
   `capabilities` array. Quote the real `mix test` failure output — not a paraphrase —
   in the run's handoff/report.
3. Revert `expr.ex` to its committed state (`git checkout -- lib/letflow/engine/expr.ex`
   or equivalent) — confirm via `git diff lib/letflow/engine/expr.ex` that it is clean.
4. Re-run the same `mix test` command. **Expected: all tests pass.** Quote the real
   passing output.
5. This satisfies AC6 as a side effect: step 3's `git diff` being empty for
   `expr.ex` is itself the proof `expr.ex` is unmodified by the requirement's actual
   (committed) changeset — distinct from, but consistent with, the scratch edit in
   step 1 never being committed at all.

A second, optional demonstration (not required by AC1's literal wording, but available
using the exact same mechanism, worth running if time permits): temporarily add a 7th
atom to `@type cmp_op` (e.g. `:approx_eq`) with no corresponding
`{:cmp, :approx_eq, ...}` handling anywhere and no corpus entry. Expect
`"every cmp_op/0 atom has a corpus entry tagged cmp:<atom>"` (§3.3) to fail naming
`:approx_eq` — demonstrating that the NEW mechanism (not just REQ-289's pre-existing
builtin test) independently catches drift outside the builtin dimension, which is the
actual gap this requirement was written to close.

---

## 7. Acceptance criterion traceability

| AC | Where addressed |
|---|---|
| AC1 — CI check fails on surface growth, demonstrated (not asserted) | §3.3 (tests), §6 (operational demonstration procedure, both required builtin case and optional cmp_op case) |
| AC2 — driven by `builtin_function_names/0` + closed type unions, no hardcoded list/count load-bearing | §2 (typespec introspection mechanism), §3.2 (signatures), §3.3's "why `@ast_tag_prefix_map` does not reintroduce the forbidden pattern" |
| AC3 — version/capability marker, documented meaning, fail-loud-not-skip-not-guess test distinguishing 3 outcomes | §4 (marker + contract), §5 (reference implementation + 3-outcome test) |
| AC4 — marker semantics in the SAME companion document REQ-289 produced | §4.5 — the contract text is appended as `req289-expr-conformance-corpus.md` §13, the same companion document REQ-289 produced; this document's §4.5 is a pointer to it, not a second copy. §4.6's decision-record amendment also points to that same §13 |
| AC5 — runs as part of standard CI command, not manually invoked | §1 (ExUnit shape rides the existing `letflow.check.test` wiring, zero `mix.exs`/`ci.yml` edits) |
| AC6 — `expr.ex` unmodified, proven by `git diff` | §6 step 5; also true structurally — no design element in §1–§5 touches `expr.ex` |
| AC7 — `mix letflow.check` passes, real output quoted | Operational — TEST-RUNNER/RELEASE-VALIDATOR run it and quote it; no design element changes this except adding files `mix letflow.check` already discovers |
| AC8 — same CI command runs REQ-289's own corpus runner, stated explicitly | §1's "Justification (AC8)" paragraph |

---

## 8. Open questions

AC4's "SAME companion document" question is **resolved, not open** — see §4.5. The
marker's client-behaviour contract is appended to `req289-expr-conformance-corpus.md`
as its new §13 (done as part of this design's rework), matching that file's existing
§12-addendum precedent exactly. This document's own §4.5 holds only a pointer, never a
second copy of that content.

One genuinely open item remains:

1. **`lit:*`/`var:*` tags have no `expr.ex` type union backing them directly** — they
   are structural properties of `{:lit, value()}`'s and `{:var, path}`'s *contents*
   (Elixir value type / list-length-1-vs-N), not closed atom unions `Code.Typespec` can
   enumerate the way `cmp_op`/`arith_op`/`builtin_name` can. §4.4's
   `mechanically_derived_capabilities/0` therefore still hardcodes the 5 `lit:` and 2
   `var:` tag strings as a fixed pair alongside the `@ast_tag_prefix_map`-derived
   `:lit`/`:var` entries. This is the same "hardcoded but fails loudly on staleness,
   never silently passes" shape as `@ast_tag_prefix_map` itself (§3.3's rationale
   applies equally here: these two tags cannot drift silently because their SOURCE
   claim — that `ast()` has exactly one `:lit` variant and one `:var` variant — is
   itself mechanically re-verified every run) — not a genuinely open question, but
   worth stating plainly rather than letting it look like an oversight: `value()`'s own
   sub-kinds (`number() | String.t() | boolean() | nil | infinity_marker()`) are a
   SEPARATE closed union this design does not introspect further, because the corpus's
   5-way `lit:` split (`boolean/integer/float/string/null`) is finer-grained than
   `value()`'s own type (which merges `integer`/`float` under `number()` and does not
   distinguish them at the type level at all — REQ-289's own design doc §12.1 already
   makes this exact point about why `integer`/`float` needed to be split by hand). Fully
   automating this last mile is not achievable without a change to `expr.ex`'s own
   `value()` type (out of scope — `expr.ex` is unmodified), so it is left as documented,
   intentional residual manual coverage rather than a silently-taken shortcut.
