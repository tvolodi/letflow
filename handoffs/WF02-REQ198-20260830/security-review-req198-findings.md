# SECURITY-REVIEWER findings — REQ-198 (`expr.ex` builtin functions, WF02-REQ198-20260830)

**Verdict: PASS.** No BLOCKER found. Routing to REVIEWER (step-02d).

## Scope test

Diff touches: `lib/letflow/engine/expr.ex`, `test/letflow/engine/expr_test.exs`,
`lib/letflow/design/req198-expr-builtin-functions.md`, handoff/registry/status-index
bookkeeping files. Confirmed via `git diff main...HEAD --stat` — no other paths.

- No `priv/repo/migrations/*.exs` touched.
- No API route touched.
- No config/secret-resolution code touched (`git diff main...HEAD --stat -- config/`
  empty).
- `expr.ex` is a pure expression evaluator on the gateway-condition path (not itself an
  API route or DB-facing schema), but per the handoff's own framing this is a
  tenant-data-adjacent condition-evaluation path, so it's reviewed substantively rather
  than waved through on the scope test alone (INV-6 spirit).

## Independent verification performed (not trusting ELIXIR-DEV's report)

1. **`mix compile --warnings-as-errors`** — ran directly, exit 0, no output (clean).
2. **`mix format --check-formatted lib/letflow/engine/expr.ex`** — exit 0.
3. **`mix test test/letflow/engine/expr_test.exs test/letflow/engine/transition_test.exs`**
   — ran directly: `Result: 148 passed (1 property, 147 tests)`. Matches the report.
4. **`mix letflow.lint_handoffs`** — ran directly: `OK -- 0 new violations across 1496
   handoff files (25 pre-existing grandfathered, traced to ISS-0190)`. Matches the
   report.
5. **Purity grep**, re-run against the current file myself:
   `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\.\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex`
   — zero matches (exit 1 / no output). Confirmed against the diffed lines directly,
   not merely trusting the moduledoc's claim.
6. **Diff-scoped read of the actual code** (not the design doc's paraphrase): read the
   full `git diff main...HEAD -- lib/letflow/engine/expr.ex` (289 inserted lines) end
   to end.

## Point-by-point findings (per the dispatching agent's specific asks)

### 3. Closed-whitelist genuinely closed; `now()`/`date_add()`/`date_diff()` rejected as parse errors

Read the real tokenizer/parser code directly (not test names):

- `identifier_token/1` and its positioned twin `identifier_token_kv/1` each gained
  exactly 8 new literal clauses (`"length"`, `"lower"`, `"upper"`, `"trim"`,
  `"contains"`, `"startsWith"`, `"endsWith"`, `"coalesce"`), each mapping to a fixed
  atom via `{:builtin_call, :atom}`, inserted before the existing catch-all
  `identifier_token(ident) -> {:var, String.split(ident, ".")}` clause. No
  `String.to_atom/1` or `String.to_existing_atom/1` call was introduced anywhere in the
  diff (`grep -n "String.to_atom\|String.to_existing_atom" lib/letflow/engine/expr.ex`
  hits only two comments, not code) — the mapping is a genuinely closed, literal,
  8-clause dispatch, not a dynamic atom conversion. No registration hook, no runtime
  mutation of `@builtin_function_names` exists anywhere in the diff.
- `parse_primary/1`/`parse_primary_p/2` gained exactly one new clause each, matching
  `[{:builtin_call, name}, {:lparen} | rest]` specifically — a `{:builtin_call, _}`
  token with no immediately-following `{:lparen}` falls through to the pre-existing
  unmatched-token error clause, so a bare whitelisted name with no call parens is
  itself a parse error (not silently treated as a variable).
- `now`, `date_add`, `date_diff` do **not** appear anywhere in `@builtin_function_names`
  or in any `identifier_token`/`identifier_token_kv` clause — confirmed by direct grep
  (`grep -n "\"now\"\|\"date_add\"\|\"date_diff\"\|:now\b\|:date_add\|:date_diff"
  lib/letflow/engine/expr.ex` returns nothing). They therefore tokenize as ordinary
  `{:var, [...]}` tokens, and `name(args)` for any non-whitelisted name leaves the `(`
  token unconsumed, which propagates to the top-level `with` in `parse/1`/
  `parse_strict/1` as `{:trailing_input, leftover}` — a genuine parse failure, not a
  silently-accepted no-op.
- **Verified by direct execution** (`mix run --no-start` against the compiled module,
  not just reading test names):
  ```
  Expr.parse("now()")            => {:error, {:parse_error, {:trailing_input, [{:lparen}, {:rparen}]}}}
  Expr.parse("date_add(a,b)")    => {:error, {:parse_error, {:trailing_input, [...]}}}
  Expr.parse("frobnicate(1)")    => {:error, {:parse_error, {:trailing_input, [...]}}}
  Expr.parse("contains(\"abcdef\", \"cd\")") => {:ok, {:call, :contains, [lit: "abcdef", lit: "cd"]}}
  Expr.evaluate_condition("contains(variables.x, \"cd\")", %{"x" => "abcdef"}) => true
  Expr.evaluate_condition("length(a,b)", %{}) => false   (wrong-arity call collapses to false, never raises)
  ```
  This confirms the whitelist-exclusion mechanism actually rejects clock builtins at
  parse time, exactly as claimed, and that a wrong-arity builtin call safely collapses
  through `evaluate_condition/2`'s catch-false rather than crashing (relevant to INV-8).

**Finding: closed, verified genuinely closed. No bypass path found.**

### 4. No resource-exhaustion/ReDoS surface in the 8 builtins

Read the real implementations directly (`apply_builtin/2` clauses, `string_predicate/4`,
`ascii_trim/1` + helpers):

- `length` → `byte_size/1` (O(1), BEAM binaries carry their size).
- `lower`/`upper` → `String.downcase(s, :ascii)` / `String.upcase(s, :ascii)` — a single
  linear byte-range mapping, no regex, no backtracking construct.
- `trim` → hand-rolled `ascii_trim_leading/1` (linear recursive byte-strip) +
  `ascii_trim_trailing/1` (linear `binary_part` shrink from the tail) — both O(n), no
  regex compilation.
- `contains`/`startsWith`/`endsWith` → `String.contains?/2`, `String.starts_with?/2`,
  `String.ends_with?/2` respectively, confirmed by reading the exact call sites
  (`apply_builtin(:contains, [a, b]), do: string_predicate(:contains, a, b,
  &String.contains?/2)`, and the `startsWith`/`endsWith` twins) — these are Elixir
  stdlib binary-search primitives operating on the BEAM's native binary representation,
  not `Regex`-backed. Grepped the whole file for `Regex\.` and confirmed all 7 hits are
  pre-existing CEL-translation-layer code (`translate_cel_to_expr/1`'s macro/string-
  literal handling, unchanged by this diff, all operating on the tenant-authored
  *source string* at fixed points, not on values produced by these builtins) — none of
  the 8 new builtins builds, compiles, or invokes any pattern object.
- `coalesce` → `Enum.find/3` over an already-evaluated, already-arity-checked argument
  list — linear scan, no recursion depth beyond the argument count itself, which is
  bounded by how many comma-separated arguments a tenant can type into one condition
  string (bounded transitively by whatever max-condition-length limit the gateway
  layer already enforces upstream of this module; this module itself imposes no new
  unbounded-recursion risk since `parse_call_args`/`parse_call_args_rest` and
  `eval_args/3` are both straightforwardly tail-recursive over the token/argument list,
  same shape as REQ-197's existing arithmetic parsing).

**Finding: no regex, no pattern compilation, no exponential-time construct in any of
the 8 builtins. All are genuinely O(n) or O(1) in input length. No ReDoS surface.**

### 5. ASCII-only casing/trim decision — no injection/encoding-confusion risk

This module's only consumer is `evaluate_condition/2`, whose return value is always
collapsed to a `boolean()` used purely to select a gateway edge — the string values
themselves are never re-serialized, stored, rendered, or fed into a second
interpretation layer (SQL, HTML, shell, etc.) by this module. That significantly narrows
the relevant threat model:

- **No injection surface:** `lower`/`upper`/`trim`'s output never leaves this module as
  a value that could subsequently be interpolated into a query, template, or command —
  it only participates in further `Expr` evaluation (e.g. as an operand to
  `contains`/`==`) within the same pure, sandboxed evaluator. ASCII-only vs. Unicode
  casing changes *which boolean a condition evaluates to*, not *what gets executed*
  anywhere.
- **Encoding-confusion / bypass-a-downstream-check risk:** the only "downstream check"
  reachable from this module's output is itself — i.e. a tenant could author
  `lower(x) == "café"` expecting Unicode-aware lowering and get a different boolean than
  R-Co would for non-ASCII input if the ASCII-only decision were wrong, but that is a
  **correctness/fidelity** divergence risk (already flagged and reasoned through in the
  design doc §3.2.1), not a security bypass — there is no authorization decision, no
  access-control check, and no cross-tenant boundary anywhere in this module whose
  behavior depends on casing normalization. A tenant can only affect the outcome of
  their *own* gateway routing decision this way, never another tenant's data or a
  security-relevant control.
- Confirmed the ASCII-only implementation is faithful to its own spec: a byte-range
  check (`0x41-0x5A`/`0x61-0x7A`) via `String.downcase/upcase(s, :ascii)`, not a
  hand-rolled regex or lookup table that could itself be a source of subtle bugs.

**Finding: no security-relevant risk from the ASCII-only decision — it is a pure
fidelity/correctness choice confined to this module's own boolean output, not a
control that anything downstream trusts for authorization or tenant isolation.**

### 6. `@unsupported_call_markers` unchanged

`git diff main...HEAD -- lib/letflow/engine/expr.ex | grep -n
"unsupported_call_markers"` returns **zero lines** — confirmed the attribute (and its
17-entry list) has zero diff churn.

## INV-1..INV-8 gate check

- **INV-1 (tenant data isolation)** — NOT-APPLICABLE. No Ecto schema, no migration, no
  query against a tenant-scoped table anywhere in this diff. `expr.ex` takes a
  caller-supplied `variables` map and a condition string; it never touches `Repo` (grep
  confirms). Scope test confirms no tenant-scoped table/schema/migration touched.
- **INV-2 (server-side field authorisation)** — NOT-APPLICABLE. No API response type,
  no serialization boundary in this diff; still pre-S4 as the file itself notes.
- **INV-3 (untrusted runtime sandboxing)** — NOT-APPLICABLE. S5 not started; this is
  not the Lua/WASM sandbox, it's the pre-existing pure expr evaluator, extended with
  more pure builtins.
- **INV-4 (secrets by reference only)** — APPLIES (live invariant) but no secret-
  resolution code touched. Ran both prescribed greps against the diffed file: no
  `System.get_env`, no hardcoded-secret-shaped literal anywhere in `expr.ex`. Verdict:
  satisfied by absence — nothing in this diff resolves or handles a secret.
- **INV-5 (not-found/forbidden indistinguishability)** — NOT-APPLICABLE. No lookup-by-ID
  endpoint in this diff; S4 not started.
- **INV-6 (new data-access paths prove their scoping)** — APPLIES as the meta-invariant
  this handoff itself discharges. This report is the explicit statement of which
  invariants apply and why, per INV-6's own requirement.
- **INV-7 (no SQL string interpolation)** — NOT-APPLICABLE. No `Repo.query`/SQL
  anywhere in this diff (confirmed no `Repo.` matches at all).
- **INV-8 (no unhandled crashes on realistic failure paths)** — APPLIES (live
  invariant, general-purpose). Ran `grep -n "^\s*{:ok, .*} = " lib/letflow/` — no new
  hits introduced by this diff inside `expr.ex`'s new code (`eval_args/3`,
  `check_arity/2`, `apply_builtin/2`, `string_predicate/4`, `ascii_trim/1` and helpers
  all return tagged tuples or plain values via `with`/pattern-matched function clauses,
  never a bare `{:ok, x} =` on a call that can fail). Directly verified a wrong-arity
  builtin call (`length(a,b)`) collapses to `false` via `evaluate_condition/2`'s
  existing catch-false composition rather than raising — a malformed/hostile tenant
  condition cannot crash the evaluating process.

## Overall verdict: PASS

No BLOCKER on any applicable invariant. Substantive review of points 3-5 (closed
whitelist, ReDoS/resource-exhaustion, ASCII-casing risk) found no defect. Routing to
REVIEWER per WF-02 Step 2d.
