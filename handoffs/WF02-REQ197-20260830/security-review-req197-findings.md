# SECURITY-REVIEWER findings — REQ-197 (expr.ex arithmetic/unary-negation/parse_strict)

Run: WF02-REQ197-20260830, step 02c. Reviewer: SECURITY-REVIEWER.
Verdict: **PASS**

## Scope test

`git diff main...HEAD --stat` confirms the only production code touched is
`lib/letflow/engine/expr.ex`. Other changed files are the design doc
(`lib/letflow/design/req197-expr-arithmetic-and-errors.md`), test files, handoff/status
bookkeeping, and `handoffs/registry.json`. No `priv/repo/migrations/*.exs`, no route, no
secret-resolution code.

This is nonetheless treated as a tenant-data path for review purposes: `expr.ex`
evaluates gateway conditions (`evaluate_condition/2`) that gate workflow transitions on
tenant-authored process definitions, and its purity/determinism is itself a
security-relevant property (replay/audit guarantees depend on it) — reviewed
substantively rather than waved through on the "no route/migration" technicality alone.

## Invariant-by-invariant (INV-1..INV-8)

- **INV-1 (tenant data isolation)** — NOT-APPLICABLE. `expr.ex` has zero `Letflow.Repo`
  calls; it is a pure function over an in-memory `variables` map passed by its caller.
  It is not a data-access path, so INV-1's scoping mechanism doesn't apply to it.
- **INV-2 (server-side field authorisation)** — NOT-APPLICABLE. No response
  serialization here.
- **INV-3 (untrusted runtime sandboxing)** — NOT-APPLICABLE. Scoped to S5 Lua/WASM
  service-task sandboxing; `expr.ex`'s small comparison/arithmetic grammar is pre-existing
  infrastructure, not new sandboxing surface, and this change adds no new host-capability
  surface.
- **INV-4 (secrets by reference only)** — NOT-APPLICABLE. No secret material anywhere in
  this diff.
- **INV-5 (not-found/forbidden indistinguishability)** — NOT-APPLICABLE. No lookup-by-ID
  handler.
- **INV-6 (new data-access paths prove scoping)** — NOT-APPLICABLE. No new data-access
  path introduced.
- **INV-7 (no SQL string interpolation)** — NOT-APPLICABLE. No SQL anywhere in this
  module.
- **INV-8 (no unhandled crashes on realistic failure paths)** — **APPLIES. PASS.**
  Verified directly: `apply_int_arith(:div, l, 0)` and `apply_int_arith(:mod, l, 0)`
  clauses are ordered ahead of the general `div/2`/`rem/2` clauses (lines 1072-1075), so
  a literal `0` divisor never reaches native `div`/`rem` (which would raise
  `ArithmeticError`). Likewise `apply_float_arith(:div, _l, r) when r == 0.0` (line 1088)
  is ordered ahead of the general `l / r` clause (line 1089), intercepting float division
  by zero before it reaches native `/` (which also raises `ArithmeticError` on the BEAM).
  Float modulo by zero never calls a native op at all — always returns a typed error
  tuple (line 1091-1093). `apply_neg/1` has an explicit clause for every input shape
  (`nil`, `:infinity`, `is_number`, catch-all `type_mismatch`) — no crash path.

## Purity grep (re-run myself, not trusted from the handoff)

```
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\.\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/expr.ex
```
Zero matches (exit code 1). Confirmed against the actual current file, not the
ELIXIR-DEV report. Purity contract holds — no I/O, no clock, no randomness, no crypto.

## Point 3 — parse_strict/1 structured error surface

Traced `parse_strict/1` (expr.ex:472-485) end to end:
- `mk_err/4` (line 489) builds `%{reason, line, column, token_text}` where `token_text`
  is a substring of the caller's own `expr_source` captured during tokenization — never
  interpolated from any other tenant's data or from process/VM internals.
- `package_failure/1` (line 493-496) maps this to the public `parse_failure()` shape
  `%{line, column, token_text, message}`.
- `describe_parse_error/1` (lines 503-510) is a fixed 8-clause table producing static
  English sentences ("unexpected end of input", "invalid numeric literal", etc.) with
  **no string interpolation of the `reason` payload's contents** — so no accidental
  leakage of internal term structure into the message field either.
- No stack trace, no exception struct, no other tenant's data, no internal
  configuration/state ever enters a `parse_failure()`. The only tenant-controlled content
  echoed back is a substring of the same string that tenant/caller passed in.
- Confirmed `evaluate_condition/2`'s call graph (`translate_cel_to_expr/1` -> `parse/1`
  -> `eval/2`) never calls `parse_strict/1` (moduledoc explicit statement, and no call
  site found in `evaluate_condition/2`, `parse/1`, or `eval/2`) — so this new function is
  not live on the gateway-evaluation path today; it's inert until a future caller wires
  it up. No new externally-reachable surface today, and the shape it will eventually
  expose is safe.

**Verdict: safe.** No sensitive-data leak risk in the structured error.

## Point 4 — nil-propagation-through-comparison bypass check

Read `transition.ex`'s actual usage (lines 660-676):
```elixir
defp evaluate_conditioned_edges([edge | rest], variables, acc) do
  if Expr.evaluate_condition(edge.condition, variables) do
    ...
```
And `evaluate_condition/2`'s actual composition (expr.ex:1146-1155):
```elixir
with {:ok, expr_source} <- translate_cel_to_expr(cel_condition),
     {:ok, ast} <- parse(expr_source),
     {:ok, true} <- eval(ast, variables) do
  true
else
  _ -> false
end
```
The `with` clause pattern-matches literally `{:ok, true}`. The changed ordering-comparison
clause's new nil-propagation path produces `{:ok, nil}`, which does **not** match
`{:ok, true}` and falls to `else _ -> false`. This is exactly the same outcome the
pre-change code produced for a nil operand (it used to be `{:error, {:eval_error,
{:type_mismatch, ...}}}`, also caught by `else _ -> false`). So the set of gateway
outcomes for a nil-comparison operand is unchanged: both before and after this
requirement, a nil operand in an ordering comparison can only ever result in that edge
being treated as not-taken (`false`) — never in forcing a `true` branch decision. There is
no route by which null-propagation through comparison can flip an exclusive-gateway
branch to true. Scope of the change is also confirmed textually limited to `<`/`<=`/`>`/
`>=` (expr.ex:1005 guard `op in [:lt, :lte, :gt, :gte]`) — the separate `:eq`/`:neq` clause
(line 998, unconditional `lv == rv`/`lv != rv`) is untouched by this diff and already
handled nil correctly (Elixir term equality) before this requirement.

**Verdict: no bypass.** Safe.

## Point 5 — unsigned-`:infinity` fallback (OQ-1) exploitability check

`apply_float_arith(:div, _l, r) when r == 0.0, do: {:ok, :infinity}` (line 1088) collapses
**every** float division by a zero divisor to the same unsigned `:infinity` marker,
regardless of the dividend's sign (so `-1.0 / 0.0` and `1.0 / 0.0` produce the identical
value). `apply_ordering/3` (lines 1109-1120) then treats `:infinity` as the greatest
possible value in every ordering comparison.

This is a genuine correctness gap with a concrete exploitable shape: a gateway condition
of the form `amount / 0.0 > threshold` would evaluate to `true` for *both* a large
positive `amount` and a large-magnitude *negative* `amount` — a signed-infinity
implementation would put a negative dividend at `-infinity`, which is `< threshold` for
any finite positive threshold, i.e. `false`. So a tenant supplying a negative value into
an expression that divides by a zero-valued (tenant- or default-configured) divisor could
force an ordering-comparison gateway condition to `true` when the "correct" (signed)
semantics would give `false`, or vice versa depending on the branch's comparison
direction — a real branch-decision divergence, not just a display/formatting nuance.

This does **not**, however, cross an INV-1..INV-8 boundary: it is a single tenant's own
process definition producing a wrong-but-internally-consistent decision on that same
tenant's own data — no cross-tenant leakage, no secret exposure, no crash, no SQL/auth
bypass. It is a business-logic-correctness risk scoped entirely within a single tenant's
own workflow, which is why it is correctly modeled as an open design question (OQ-1)
requiring an explicit accept/reject decision, not a BLOCKER under this file's INV list.
Confirmed the ELIXIR-DEV/CODE-DESIGN-VALIDATOR framing of this as "not obviously a
vulnerability" is accurate, but "not obviously a vulnerability" undersells it slightly —
it is a real, demonstrable divergence in gateway-decision output for a plausible tenant
input (negative dividend), not merely a hypothetical corner case. Flagging this
explicitly and forcefully for REVIEWER's OQ-1 sign-off decision below.

**Verdict: not a security-invariant violation (no INV applies), but not a rubber-stamp
either — REVIEWER must treat this as a substantive correctness question when deciding
OQ-1, with the concrete `amount / 0.0 > threshold` sign-flip scenario above as the
reason it matters for gateway correctness, not just spec completeness.**

## Overall

All applicable invariants (INV-8 only) PASS. No tenant-data path, no secret-handling
path. Routing onward to REVIEWER per workflow, with the three carry-forward items in the
step-02d handoff (OQ-1 sign-off decision — including the concrete exploit-shape finding
above, OQ-4 awareness, and the parse_strict/1 tokenizer-duplication design-preference
deviation).
