# ISS-0216 — non-empty `prefix` guard for `Letflow.Api.Pagination`

Design for the fix to ISS-0216. Diagnosis: `handoffs/WF03-ISS0216-20260826/step-01-issue-fixer.json`.
No implementation code below — clause changes, `@spec` deltas, and doc wording
only.

**File:** `lib/letflow/api/pagination.ex` (existing, REQ-067). No new file, no
new module, no migration, no route-handler change.

## 0. Restating the defect (from step-01's diagnosis)

`check_prefix/2` (lines 211-218):

```
byte_size(decoded) >= byte_size(prefix) and String.starts_with?(decoded, prefix)
```

When `prefix == ""`: `byte_size(prefix) == 0`, so the size conjunct is always
true, and `String.starts_with?(decoded, "")` is always true per Elixir's own
semantics — every binary starts with the empty string. `check_prefix/2`
therefore returns `:ok` for **any** `decoded` payload when `prefix` is `""`,
defeating the cross-endpoint isolation `decode_cursor/4`'s own moduledoc
(lines 174-177) documents this check as providing. Confirmed by step-01's
live reproduction: a cursor minted under prefix `"T:"` decodes successfully
against `decode_cursor(encoded, "", 2)`.

Step-01's call-site audit is the load-bearing fact this design turns on: all
nine real call sites (`identity.ex`, `tenants.ex`, `audit.ex`, `tasks.ex`,
`instances.ex` ×3, `definitions.ex` ×2) pass a compile-time,
non-empty, module-attribute string literal (`@users_cursor_prefix`,
`@tenants_cursor_prefix`, etc.) — none derive `prefix` from request/query/path
input, none pass `""`. **`prefix` is caller-internal configuration, never
externally-influenced data.** The empty-prefix case is unreachable through any
shipped HTTP request today; the exposure is a *future* call site (a new
endpoint, or a refactor that stops hard-coding the literal) silently losing
the isolation guarantee with no compiler or runtime signal, since nothing in
the module currently checks the precondition it documents as structural.

## 1. Error-shape decision (explicit, not deferred)

**Decision: treat an empty `prefix` as a caller-contract violation and `raise
ArgumentError`, not a new/reused tagged-tuple error.**

Rationale, weighed against the two alternatives step-01 flagged:

- **Why not reuse `{:error, :wrong_endpoint}`.** `:wrong_endpoint` is
  documented (moduledoc lines 173-177, `@doc` on `decode_cursor/4`) as meaning
  "the decoded *cursor* doesn't match this endpoint's prefix" — a statement
  about the untrusted, network-facing `encoded` argument. Folding "the
  caller's own `prefix` argument is malformed" into the same atom would make
  that atom mean two different things depending on which argument is at
  fault, which is exactly the kind of conflation `api-pagination.md` §5
  already flagged once (there, in the other direction — splitting
  `:invalid_cursor` out of `:invalid_base64` for the same reason). A route
  handler catching `{:error, :wrong_endpoint}` today reasonably treats it as
  "return 404/400 to this HTTP client" (untrusted-input territory); it must
  never treat "the developer who wrote this route hard-coded `prefix: \"\"`"
  the same way, because retrying the request or telling the client something
  changes nothing — the code itself is broken and needs a code fix, not a
  client-facing error path.
- **Why not a new tagged-tuple atom (e.g. `{:error, :invalid_prefix}`).** This
  would extend `decode_cursor/4`'s public error-tuple contract (§8 of
  `api-pagination.md`) for a condition that, per step-01's audit, **cannot
  occur through any code path that respects the module's own documented
  calling convention** (every real and intended caller supplies a hardcoded
  non-empty literal). Adding a fourth-argument-position error atom that every
  existing call site's `case`/`with`-`else` clause would need to newly account
  for (or silently fall through and crash on, since Elixir's `with` without a
  matching `else` clause raises `WithClauseError` anyway) buys nothing over
  raising directly, while growing the public error vocabulary for a
  programmer-error case that INV-8 (this module's own "no unhandled crashes"
  invariant) explicitly scopes to *"cursor/page-size values are
  caller-controlled, **network-facing** input"* (module moduledoc, line
  28-29). `prefix` is not network-facing input — INV-8 does not obligate a
  tagged-tuple return for it.
- **Why `raise ArgumentError`, and why that's still INV-8-compliant.** This is
  the idiomatic Elixir precondition-violation pattern (the same shape as
  `Keyword.fetch!/2`, `Map.fetch!/2`, or an `is_binary(x) or raise
  ArgumentError` guard): a function precondition violated by the *calling
  code itself*, not by the data flowing through the system, is a bug to
  surface immediately and loudly (crash the request, visible in logs/tests) —
  never to silently downgrade into a value some `case` clause might not
  handle. INV-8's own stated scope (caller-controlled *network-facing* input)
  does not cover this case, so raising here does not violate it. This also
  gives ELIXIR-DEV and TEST-DESIGNER a compile-time-adjacent signal: a test
  that calls `decode_cursor(encoded, "", offset)` must now assert
  `assert_raise ArgumentError, fn -> ... end`, not pattern-match a new atom
  into existing `case` branches across every route handler.

This mirrors the same reasoning `api-pagination.md` §0.3 already applied to
tenant scoping: *"remove the capability, don't rely on convention"* — here,
the capability being removed is "silently accept a config value that defeats
the module's core guarantee," replaced with "fail loudly and immediately
the first time it happens," rather than adding a return-value branch nobody
who reads the existing call sites would ever need to actually handle.

## 2. Exact clause changes

### 2.1 `check_prefix/2` — add the precondition, first

```
@spec check_prefix(binary(), String.t()) :: :ok | {:error, :wrong_endpoint}
```
**unchanged** — `check_prefix/2`'s own return type is not widened. The empty-
prefix case is intercepted *before* `check_prefix/2`'s existing logic runs,
not folded into its existing `if`/`else`.

A new function-head clause is added immediately above the existing
`check_prefix/2` clause (Elixir multiple-clause dispatch on function head,
not an `if` inserted into the existing single clause) — this keeps the
precondition check textually separate from, and evaluated strictly before,
the existing size/`starts_with?` logic, and keeps the existing clause's diff
to zero lines changed (only the new clause is added above it).

The new clause's head matches `check_prefix/2` when its second argument (the
`prefix`) is the empty string, disregarding the first argument (`decoded`)
entirely — i.e. it is decided purely by whether `prefix` is empty, before any
of the existing size/`starts_with?` computation runs on `decoded`. Because
Elixir clause dispatch tries clauses top-to-bottom, ordering this clause first
guarantees it intercepts the empty-`prefix` case before the existing clause's
body ever executes.

The new clause's body does exactly one thing: it raises `ArgumentError`. It
does not return `:ok` or `{:error, ...}` — execution does not fall through to
a return value at all, matching the `@spec` staying unchanged (a `raise` is
outside a function's `@spec` return type). The exception message must convey,
at minimum:

- which function was misused — `Letflow.Api.Pagination.decode_cursor/4` (the
  public entry point a caller actually invokes; `check_prefix/2` itself is
  private and not part of anyone's mental model of "what did I call"),
- what the precondition is — `prefix` must be a non-empty, hardcoded,
  per-endpoint literal, not derived from request/query/path input,
- why it matters — an empty `prefix` defeats the cross-endpoint cursor
  isolation this check exists to provide (ISS-0216),
- a pointer back to the moduledoc invariant that documents this contract
  (INV-9, added in §3), so a future reader hitting the crash can find the
  authoritative explanation rather than just the one-line message.

The existing clause (the current size/`starts_with?` logic) is otherwise
untouched — no line of its existing body changes; it simply becomes the
second of two clauses instead of the only one.

### 2.2 `decode_cursor/4` — no signature or `@spec` change

```
@spec decode_cursor(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
        {:ok, Cursor.t()}
        | {:error, :invalid_base64}
        | {:error, :wrong_endpoint}
        | {:error, :expired}
        | {:error, :invalid_cursor}
```

**Unchanged.** `decode_cursor/4`'s public contract does not grow a new error
tuple, since the fix raises rather than returns — a `raise` is not part of a
function's `@spec` return type in Elixir (matching how `Keyword.fetch!/2`'s
own `@spec` names no error case either). `decode_cursor/4`'s body itself
(lines 194-201, the `with` chain) is untouched: `check_prefix/2` is still
called as `:ok <- check_prefix(decoded, prefix)`, and the `raise` simply
propagates up through the `with` unwound, exactly like any other Elixir
exception would.

**No guard is added directly on `decode_cursor/4`'s own head** (e.g. no
`when byte_size(prefix) > 0` guard clause on the public function). Keeping
the single precondition check inside `check_prefix/2` (called only once,
from `decode_cursor/4`'s `with` chain) avoids duplicating the same check in
two places for one caller — `check_prefix/2` has exactly one caller today
(`decode_cursor/4`), so there is nothing else that could bypass it by calling
`check_prefix/2` directly (it is `defp`, module-private).

## 3. `@moduledoc`/`@doc` wording updates

- **Moduledoc, "Security invariants" section (currently INV-1/INV-5/INV-8/
  wall-clock, lines 14-35):** add a new invariant paragraph, **INV-9**, stating
  the guard is now structural:

  > **INV-9 (structural, not conventional).** `decode_cursor/4` never
  > silently accepts an empty `prefix`. `check_prefix/2` raises
  > `ArgumentError` immediately if `prefix == ""`, rather than allowing
  > `String.starts_with?/2`'s documented empty-string-always-matches
  > semantics to defeat cross-endpoint cursor isolation. This is a
  > precondition on the *caller's own hardcoded literal* (see the
  > "prefix is caller-internal configuration" note below), not a
  > network-facing input validation — it exists to catch a future call
  > site's programming mistake at the first test/request that exercises
  > it, not to sanitize untrusted data.

- **`decode_cursor/4`'s own `@doc` (lines 169-187):** append, after the
  existing three-step description, a short paragraph noting the precondition
  and pointing at INV-9:

  > `prefix` must be a non-empty, hardcoded, per-endpoint literal — never a
  > value derived from the request, query string, path, or any other
  > caller-controlled input; see the moduledoc's INV-9. An empty `prefix`
  > raises `ArgumentError` rather than returning an error tuple, since this
  > is a caller-contract violation, not cursor-payload validation (contrast
  > with `{:error, :wrong_endpoint}`, which is about the decoded payload,
  > never about `prefix` itself).

- **`check_prefix/2`'s own inline context:** no `@doc` today (private
  function, undocumented) — no new doc needed beyond a one-line comment at
  the new clause matching the `@moduledoc`/`@doc` wording above, to keep a
  future reader from mistaking the `raise` for a missed `{:error, ...}` case.

No other doc changes. `@spec`-adjacent docs for `parse_page_size_param/1`,
`validate_page_size/1`, `encode_cursor/1`, `build_raw_cursor/3`,
`build_raw_cursor_timestamp_key/4`, `parse_int_from_cursor/3`,
`find_nth_colon/2` are untouched — none of them take or forward a `prefix`
argument.

## 4. What TEST-DESIGNER must cover

1. **The empty-prefix case itself (mandatory, mirrors step-01's
   reproduction).** Build a raw cursor via `build_raw_cursor/3` under a
   real non-empty prefix (e.g. `"T:"`), encode it, then call
   `decode_cursor(encoded, "", 2)` and assert it **raises `ArgumentError`**
   (`assert_raise ArgumentError, fn -> ... end`) — not that it returns an
   error tuple. This directly closes the gap step-01 identified: no existing
   test in `test/letflow/api/pagination_test.exs` constructs `prefix: ""`.
2. **Non-regression on the non-empty-prefix paths already covered.** The
   existing `:ok`, `{:error, :wrong_endpoint}` (non-empty mismatching
   prefix), `{:error, :expired}`, `{:error, :invalid_cursor}`,
   `{:error, :invalid_base64}` cases must still pass unchanged — the fix adds
   a function clause, it does not alter the existing clause's behavior for
   any non-empty `prefix`. TEST-DESIGNER should re-run/confirm the existing
   suite rather than assume the new clause is additive-only.
3. **Boundary check: a real non-empty prefix that happens to be a prefix of
   another endpoint's prefix (e.g. `"T:"` vs. `"TL:"`).** Not new to this
   fix — this exercises the *existing* size/`starts_with?` logic, unchanged
   by §2.1 — but worth a regression test alongside the empty-prefix case
   since both are "is the prefix check actually doing real work" tests. Not
   a hard requirement of this design (the existing behavior here is already
   correct per step-01's `"X:"` vs `"T:"` reproduction); listed for
   completeness, not as a new acceptance criterion this fix introduces.
4. **Do not test `check_prefix/2` directly.** It is `defp` — TEST-DESIGNER
   must exercise the guard exclusively through the public `decode_cursor/4`,
   consistent with how the rest of `pagination_test.exs` already tests this
   module (no test reaches into a private function).

No test for a `nil` or non-binary `prefix` is required by this fix —
`decode_cursor/4`'s `@spec` already types `prefix :: String.t()`, and a
non-binary argument is out of scope for ISS-0216 (which is specifically about
the *empty string* case defeating `String.starts_with?/2`'s semantics, not
about type-safety of the argument in general). If CODE-DESIGN-VALIDATOR wants
non-binary `prefix` guarded too, that is a one-line addition to §2.1's new
clause's guard — flagged in §5 rather than silently added, since it is a
larger blast radius than what ISS-0216 actually reported.

## 5. Open questions (not silently resolved)

1. **`raise ArgumentError` vs. a new `{:error, :invalid_prefix}` tuple.** §1
   makes an explicit choice and states its rationale. If
   CODE-DESIGN-VALIDATOR or REVIEWER judges that this module's existing
   "every fallible operation returns a tagged tuple" framing (INV-8) should
   be read more broadly than this design reads it — i.e. as covering *any*
   argument, not only network-facing ones — the alternative is a one-line
   change: `check_prefix("", _) -> {:error, :invalid_prefix}` (or reusing
   `:wrong_endpoint`) instead of the `raise` clause in §2.1, with a matching
   `@spec` widening on both `check_prefix/2` and `decode_cursor/4`, and every
   real call site's `else`/`case` block gaining one more clause. This
   design's recommendation is the `raise`, for the reasons in §1.
2. **Whether to also guard non-binary `prefix`.** Out of scope per §4's last
   paragraph; flagged in case CODE-DESIGN-VALIDATOR wants it folded into the
   same fix rather than left to `@spec`/Dialyzer.
3. **Should INV-9 be numbered INV-9, or folded into the existing INV-1/INV-5
   paragraph as an addendum?** This design adds it as a new, separately
   numbered invariant since it protects a different property (prefix
   non-emptiness) than INV-1/INV-5 (no tenant-scope field on `Cursor.t()`) —
   flagged in case REVIEWER prefers consolidating moduledoc invariants
   differently.
