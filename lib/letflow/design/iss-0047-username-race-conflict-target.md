# Design: ISS-0047 — `insert_or_fetch/4`'s `on_conflict` only arbitrates the
# `(external_realm, external_id)` index, not `users.username`

**Issue:** `docs/issues/ISS-0047.yaml` (severity: MINOR, tags: identity, concurrency,
pre-existing)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact conditional-logic shape added to
`lib/letflow/identity.ex`'s `insert_or_fetch/4`, one new private helper function
signature, and the corresponding new-test guidance for TEST-DESIGNER. No implementation
code — no `.ex`/`.exs` code blocks with real function bodies below; pseudocode blocks are
logic-shape descriptions only, matching this project's `req018-jit-provisioning.md` §3.3
convention (which itself uses numbered pseudocode steps, not Elixir source).

## 0. Sources read for this design

- `handoffs/WF03-ISS0047-20260818/step-01-issue-fixer.json` (`result.summary`, full) —
  ISSUE-FIXER's confirmed-by-reproduction root cause: `Repo.insert/2`'s
  `on_conflict: :nothing` / `conflict_target: {:unsafe_fragment, "(external_realm,
  external_id) WHERE external_id IS NOT NULL"}` only names the
  `users_external_identity_partial_index` arbiter — Postgres does not suppress a
  conflict on any other unique index (here, the separate `unique_index(:users,
  [:username])`) via that same `ON CONFLICT` clause, so a losing racer whose insert
  collides on `username` (not on the named arbiter) raises a normal unique-violation,
  which Ecto/the changeset's own `unique_constraint(:username)` surfaces as
  `{:error, %Ecto.Changeset{}}` instead of being suppressed and falling through to
  `re_select_on_conflict/3`. Reproduced directly against real Postgres, 4/6 runs, with
  the two racing calls sharing an IDENTICAL `(external_realm, external_id, username)`
  triple.
- `docs/issues/ISS-0047.yaml` (full) — issue history, TEST-DESIGNER's original
  discovery, `discovered_in_run: WF02-REQ063-20260818`, suggested fix shapes (a)
  second chained `on_conflict`/raw `ON CONFLICT ON CONSTRAINT` (ruled out — Postgres
  allows only one arbiter per `INSERT` statement, so no single-statement form covers
  two independent unique indexes at once) and (b) catching the username-constraint
  changeset error explicitly and checking whether the existing username-holder is
  this same identity before falling through to `re_select_on_conflict/3` — **this
  design adopts (b)**.
- `lib/letflow/identity.ex` (full, current state) — `insert_or_fetch/4` (lines
  174-219), `re_select_on_conflict/3` (lines 221-229), `get_by_external_identity/3`
  (lines 239-250), and the module-attribute-adjacent comment above
  `upsert_by_external_identity/4` (lines 156-163: "deliberately not a naive
  insert-then-rescue-unique-constraint-error pattern") — this design's own §3.4
  addresses why the fix below does not violate that constraint despite pattern-
  matching on a changeset error.
- `lib/letflow/identity/user.ex` (full) — `jit_changeset/2`'s
  `unique_constraint(:username)` (no explicit `name:`, so it uses Ecto's inferred
  default) and `unique_constraint([:external_realm, :external_id], name:
  :users_external_identity_partial_index)`.
- `priv/repo/migrations/20260816000004_create_users.exs` line 48 and
  `priv/repo/migrations/20260819000003_create_users_tenant_scoped.exs` line 77 —
  both create `unique_index(:users, [:username], ...)` via `Ecto.Migration`'s
  `unique_index/3` with no explicit `:name` option, so Ecto's migration DSL assigns
  the default generated name `users_username_index` (table name + column list +
  `_index`, Ecto's documented default-naming convention) — confirmed this is the
  same default name `unique_constraint(:username)` (no `name:` override in
  `jit_changeset/2`) itself expects when matching a Postgres unique-violation to a
  changeset field, per Ecto's own `unique_constraint/3` doc ("By default, the
  constraint name is inferred from the table and column, so it may differ from the
  actual constraint name in the adapter").
- `test/letflow/identity_test.exs` lines 259-355 (REQ-018 acceptance-criterion-3
  race test, `:manual` mode + `Sandbox.allow/3`, single shared connection — cannot
  and does not exercise this path) and lines 378-394 (REQ-063's genuine-collision
  test, two DIFFERENT `IdentityContext`s racing for the same `username`,
  **sequential**, not concurrent — must keep asserting `{:error, %Ecto.Changeset{}}`
  with `%{username: ["has already been taken"]}`).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation: the
  new helper below is scoped by the same `prefix:` opt as every other call in this
  module — no cross-schema read introduced), INV-8 (no unhandled crash on a
  realistic failure path — this design's new branch must not introduce a new raise;
  every branch below still terminates in `{:ok, _}` or `{:error, _}`).
- `docs/anti-patterns.md` — read in full; no entry directly applicable, but this
  design adds one (see bottom of this file's companion note to CODE-DESIGN-VALIDATOR
  in §6) about `on_conflict:`'s single-arbiter limitation being easy to
  under-scope when a table has more than one unique index.

## 1. Restated bug, precisely

`insert_or_fetch/4`'s `Repo.insert/2` call (identity.ex lines 188-194) names exactly
one `conflict_target:` — the `(external_realm, external_id)` partial index. Postgres's
`INSERT ... ON CONFLICT (<arbiter>) DO NOTHING` only suppresses a conflict detected
against **that specific named arbiter**; a conflict on `users.username`'s separate
unique index is a different, unrelated unique-violation that Postgres still raises
normally, and Ecto surfaces it as `{:error, %Ecto.Changeset{}}` via the changeset's own
`unique_constraint(:username)` declaration (this part already works correctly — the
changeset error is well-formed, not a raw unhandled exception; INV-8 is not at risk
today). The bug is purely about **which case is treated as a permanent failure vs. a
resolvable race**: today, every `username`-constraint changeset error is treated as
permanent, even when it is actually this call's own opponent racer (identical
`external_realm`/`external_id`/`username`) that won.

Two cases must be told apart, both surfacing identically as `{:error,
%Ecto.Changeset{}}` with a `username` uniqueness error today:

| Case | Existing row's `(external_realm, external_id)` | Correct outcome |
|---|---|---|
| **Race** (this design's target) | Same as this call's `identity_context` | `{:ok, %{user: existing, created: false}}` — same contract as the already-working `(external_realm, external_id)` conflict path |
| **Genuine collision** (`identity_test.exs:379-394`, must keep passing) | Different from this call's `identity_context` | `{:error, %Ecto.Changeset{}}` — unchanged, must still propagate |

## 2. Fix mechanism selected: option (b), adapted

**Not chosen: a second `on_conflict`/raw `ON CONFLICT ON CONSTRAINT` clause (issue's
option (a)).** Postgres's `INSERT ... ON CONFLICT` grammar accepts exactly one
conflict target (one arbiter index or constraint) per `INSERT` statement — there is no
SQL form that says "suppress on conflict with index A OR index B" in a single
statement. A single `WHERE`-qualified expression covering both indexes' columns is not
possible either, since the two indexes are on disjoint column sets
(`(external_realm, external_id)` vs. `(username)`) with no shared expression that
represents "conflicts with either." This option is ruled out as structurally
unavailable, not merely undesirable — confirmed against Postgres's own `INSERT`
documentation (`ON CONFLICT` grammar: `conflict_target` is a single
parenthesized-column-list-or-constraint-name clause, not a list of alternatives).

**Chosen: option (b) — catch the `username`-constraint changeset error in
`insert_or_fetch/4`, re-query for the row now holding that `username`, and compare its
`(external_realm, external_id)` against this call's own `identity_context` before
deciding whether to fall through to `re_select_on_conflict/3` or propagate the original
error.**

### 2.1 Why this is not the forbidden "naive insert-then-rescue" pattern

PROVENANCE (historical, not current decision authority):
`identity.ex`'s own comment above `upsert_by_external_identity/4` (lines 156-163)
forbids "a naive insert-then-rescue-unique-constraint-error pattern (that would change
the concurrency semantics R-Co's own implementation chose)." That prohibition targets
replacing the **entire** select-first / `INSERT ... ON CONFLICT` / re-select algorithm
with a bare `try/rescue Ecto.ConstraintError` around a plain `Repo.insert/2` with no
`on_conflict:` at all — a fundamentally different (and weaker) concurrency strategy
than R-Co's `registry.zig` port. This design does **not** do that: the existing
select-first step, the existing `on_conflict: :nothing` / `conflict_target:`
`Repo.insert/2` call, and the existing `re_select_on_conflict/3` fallback are all left
completely unchanged. This design adds one **additional, narrowly-scoped** branch that
only activates when `Repo.insert/2` already returned `{:error, %Ecto.Changeset{}}`
tagged specifically with a `username` unique-constraint error (an Ecto changeset
return value, not a rescued exception — `unique_constraint(:username)` in
`jit_changeset/2` already converts the underlying Postgres unique-violation into this
changeset error shape today; this design adds no `rescue`/`try` clause anywhere). The
`(external_realm, external_id)` conflict path's behavior is byte-for-byte unchanged.
This is pattern-matching on an already-returned, already-typed value
(`Ecto.Changeset.t()`), the same idiom `insert_or_fetch/4` already uses at line 216 —
not a rescue-based control-flow substitute for the on_conflict mechanism.

### 2.2 Exact new logic shape — `insert_or_fetch/4`

Replaces the existing `{:error, %Ecto.Changeset{}} = error -> error` clause (lines
216-217) with a three-way branch. Everything above it (lines 174-215, the select
changeset build and the `on_conflict:` `Repo.insert/2` call and its `{:ok, ...}`
branch) is **unchanged**.

```
case Repo.insert(changeset, on_conflict: ..., conflict_target: ..., returning: true, prefix: prefix) do
  {:ok, %User{id: id} = inserted} ->
    <unchanged — lines 195-214>

  {:error, %Ecto.Changeset{} = changeset} ->
    IF username_unique_conflict?(changeset):
      # Opponent may have raced us with the identical (external_realm, external_id,
      # username) triple — find out who actually holds that username now.
      CASE get_by_username(identity_context.preferred_username, opts) OF
        %User{} = holder WHEN identity_matches?(holder, identity_context) ->
          # Same identity as ours -> this is our own race opponent, already
          # persisted under the (external_realm, external_id) conflict this
          # INSERT statement's arbiter didn't even need to fire for, because
          # the username constraint raised first. Resolve exactly like the
          # already-working on_conflict path does.
          re_select_on_conflict(tenant_id, identity_context, opts)

        %User{} ->
          # A DIFFERENT identity already holds this username -> genuine,
          # unrelated collision. Propagate the original changeset error
          # unchanged (identity_test.exs:379-394's pinned contract).
          {:error, changeset}

        nil ->
          # Should not happen (Repo.insert/2 just told us a username
          # conflict occurred) but handled defensively rather than assumed
          # unreachable, matching this module's existing defensive-fallback
          # discipline (re_select_on_conflict/3's own :external_identity_collision
          # branch). Propagate the original error — do not fabricate a
          # {:ok, _} result for a row this call cannot actually locate.
          {:error, changeset}
      END
    ELSE:
      # Not a username-constraint error at all (e.g. a future validation
      # rule this changeset gains later) -> unchanged existing behavior.
      {:error, changeset}
end
```

### 2.3 New private helper #1 — `username_unique_conflict?/1`

```
@spec username_unique_conflict?(changeset :: Ecto.Changeset.t()) :: boolean()
```

Inspects `changeset.errors` (the list `Ecto.Changeset` populates on a failed
`Repo.insert/2`, each entry shaped `{field :: atom(), {message :: String.t(), keyword()}}`)
for an entry whose field is `:username` and whose keyword metadata list contains
`constraint: :unique`. Does **not** match on the human-readable message string
(`"has already been taken"`) — Ecto's own `unique_constraint/3` guarantees the
`constraint: :unique` keyword tag on every error it produces regardless of the message
text supplied, so matching on that tag (not the string) is the stable, idiomatic way
to identify a unique-constraint-sourced changeset error, per
`Ecto.Changeset.unique_constraint/3`'s own documented error shape. Returns `false` for
every other changeset error shape (a validation failure, a different field's unique
violation, etc.) — this function answers exactly one question ("was this specific
failure a `username` uniqueness conflict") and nothing broader.

**Not reused for the `(external_realm, external_id)` arbiter** — that conflict never
reaches this function at all, because Postgres's `on_conflict: :nothing` already
suppresses it before Ecto ever builds a changeset-error return for it (confirmed by
`insert_or_fetch/4`'s own existing `{:ok, ...}` branch, lines 195-214, which is the
only branch that path reaches).

### 2.4 New private helper #2 — `get_by_username/2`

```
@spec get_by_username(username :: String.t(), opts :: opts()) :: User.t() | nil
```

`Repo.get_by(User, [username: username], prefix: Keyword.fetch!(opts, :prefix))` in
shape — same idiom, same `prefix:`-scoping discipline (INV-1) as the existing
`get_by_external_identity/3` (identity.ex lines 239-250), just keyed on `username`
instead of `(external_realm, external_id)`. Scoped to the same tenant schema this
whole call is already operating in (`opts[:prefix]`) — `users.username`'s unique index
is per-schema (per Decision 0006/REQ-063 — global uniqueness ended when `users` moved
per-tenant-schema), so this lookup is automatically tenant-scoped by virtue of
targeting the same `prefix:` the failed insert itself used; no additional filter is
needed or correct to add.

Placement: private function in `Letflow.Identity`, defined alongside
`get_by_external_identity/3` (same section of the module, same visibility, same
calling convention).

### 2.5 New private helper #3 — `identity_matches?/2`

```
@spec identity_matches?(user :: User.t(), identity_context :: IdentityContext.t()) :: boolean()
```

`user.external_realm == identity_context.realm and user.external_id ==
identity_context.external_user_id` — the same two-field comparison
`get_by_external_identity/3`'s own `Repo.get_by/3` filter already expresses as a query,
expressed here instead as a boolean predicate over an already-fetched struct (needed
because `get_by_username/2` fetches by a different key, so this design cannot reuse
`get_by_external_identity/3`'s query form directly — it must compare the row
`get_by_username/2` already returned against the fields on `identity_context`).
`nil == nil` case: if a row's `external_id`/`external_realm` were themselves `nil`
(a non-OIDC, `auth_source: :internal` user that happens to hold a colliding
username — a real, distinct scenario, not this issue's race, since only OIDC/JIT rows
ever reach `insert_or_fetch/4`), this predicate correctly returns `false` whenever
`identity_context.realm`/`external_user_id` (never `nil` per REQ-017's own
non-nullability guarantee, cited in `req018-jit-provisioning.md` §4.1) don't match the
row's — internal users are automatically excluded from the "this is our own race
opponent" branch without needing a separate `auth_source` check, since their
`external_realm`/`external_id` are `nil` and `identity_context`'s corresponding fields
are guaranteed non-`nil`.

## 3. Why this correctly separates the two cases (worked through both)

### 3.1 Race case (must resolve to `{:ok, created: false}`)

Two independent connections both build a changeset from an **identical**
`identity_context` (same `realm`, `external_user_id`, `preferred_username`). One
commits first. The loser's `Repo.insert/2` raises on whichever unique index Postgres's
internal constraint-checking order happens to evaluate first for that specific insert
attempt — per ISSUE-FIXER's own reproduction, this is not always the
`(external_realm, external_id)` arbiter (which `on_conflict: :nothing` would have
suppressed cleanly) but can instead be the `username` index, which is not the named
arbiter and so raises normally. When that happens, this design's `username_unique_conflict?/1`
returns `true`, `get_by_username/2` finds the winner's row (already committed, same
`username`), and `identity_matches?/2` returns `true` (winner's row has the identical
`external_realm`/`external_id` the loser was itself trying to insert, since both
callers built their changeset from the same `identity_context`) — so this design falls
through to `re_select_on_conflict/3`, which re-queries by `(external_realm,
external_id)` (unaffected by which index actually raised) and returns
`{:ok, %{user: existing, created: false}}`, exactly matching the already-working
`(external_realm, external_id)`-arbiter-conflict path's outcome. Both racers now
resolve identically regardless of which index Postgres happened to check first.

### 3.2 Genuine collision case (`identity_test.exs:379-394`, must keep propagating the error)

Two **different** `identity_context`s (`ctx_a`, `ctx_b` in the pinned test — different
`external_user_id`s per `identity_context/1`'s test helper) pick the same
`preferred_username`. `ctx_a`'s call commits first (`created: true`, asserted at line
387-388). `ctx_b`'s call's `Repo.insert/2` raises on the `username` unique index (the
`(external_realm, external_id)` arbiter never conflicts at all here — `ctx_a` and
`ctx_b` have different `external_id`s, so `on_conflict: :nothing`'s arbiter isn't even
touched; this was already true before this design and remains true). This design's
`username_unique_conflict?/1` returns `true` (same detection as §3.1 — a real
`username`-constraint error either way), `get_by_username/2` finds `ctx_a`'s
already-committed row, but `identity_matches?/2` returns `false` (`ctx_a`'s row's
`external_realm`/`external_id` differ from `ctx_b`'s `identity_context`) — so this
design's new branch propagates `{:error, changeset}` unchanged, exactly the outcome
`identity_test.exs:379-394` already pins (`%{username: ["has already been taken"]}`
via `errors_on/1`). **This test requires no modification.**

## 4. What ELIXIR-DEV must NOT change

- The `(external_realm, external_id)`-arbiter `Repo.insert/2` call itself (lines
  188-194) — `on_conflict:`, `conflict_target:`, `returning:` all unchanged.
- The `{:ok, %User{id: id} = inserted} -> ...` branch (lines 195-214) — unchanged.
- `re_select_on_conflict/3` (lines 221-229) — unchanged, reused as-is by the new
  branch (§2.2).
- `get_by_external_identity/3` (lines 239-250) — unchanged, still the sole helper
  `re_select_on_conflict/3` and `upsert_by_external_identity/4`'s select-first step
  use.
- `jit_changeset/2` (`lib/letflow/identity/user.ex`) — no changeset-level change
  needed; `unique_constraint(:username)` already exists and already produces the
  `constraint: :unique` tag §2.3 depends on. **Confirmed no migration change either**
  — both unique indexes this design reasons about already exist per §0's migration
  citations.
- No `Ecto.Multi` introduced (per this issue's own acceptance criteria) — every new
  helper is a plain `Repo.get_by/3` read, matching this module's existing
  read-helper idiom.

## 5. New test TEST-DESIGNER must add

`identity_test.exs`'s existing race test (lines 259-355) cannot exercise this fix —
it uses `:manual` mode + `Sandbox.allow/3`, which routes both `Task`s through one
shared connection/transaction (serializing the two inserts, per that test's own inline
comment), so the two inserts never genuinely race at the Postgres level and the
`username` index's conflict-ordering nondeterminism this issue depends on never has a
chance to occur.

A new test is needed, structurally promoting ISSUE-FIXER's own repro shape (per
ISS-0047.yaml's and the issue-fixer handoff's own suggestion): **two genuinely
independent Postgres connections** (`Ecto.Adapters.SQL.Sandbox` `:auto` mode, NOT
`:manual` + `allow/3` — the same mode `provisioned_tenant!/0` already uses for its own
migration-replay step, confirmed compatible with genuine two-connection races per the
issue-fixer's own repro) racing two `Task.async/1`-spawned calls to
`Identity.provision_oidc_user/4` with an **identical** `identity_context` (same
`realm`/`external_user_id`/`preferred_username`), barrier-synchronized the same way
the existing race test already barrier-synchronizes (lines 282-316's pattern, reused).
Run it enough times (or loop N iterations within one test, since ISSUE-FIXER's own
data shows the failure is genuinely nondeterministic — 4/6 runs, not 100% — so a
single run is not sufficient proof; TEST-DESIGNER should either loop multiple race
attempts within the test or otherwise argue why a single run is adequate evidence)
to give confidence the fix closes the gap, asserting on every run: both `Task` results
are `{:ok, %{user: %User{id: same_id}, created: _}}` (never `{:error,
%Ecto.Changeset{}}`), exactly one of the two has `created: true`, and exactly one row
exists afterward — mirroring the existing race test's own assertions (lines 321-345),
but under `:auto` mode so the assertions are actually meaningful for this specific
gap. This is a new test, additive to (not replacing) the existing `:manual`-mode race
test, since the existing test still legitimately proves the original REQ-018
acceptance criterion under its own documented concurrency model.

The existing genuine-collision test (`identity_test.exs:379-394`) needs **no changes**
— §3.2 above shows it remains correctly pinned by this fix.

## 6. Open questions (explicit, not silently resolved)

1. **OQ-1 — should `username_unique_conflict?/1` also be reused anywhere else in this
   module?** No other call site in `identity.ex` currently inserts a `User` row, so
   no reuse opportunity exists today. Not generalized into a public/shared utility
   beyond `Letflow.Identity`'s own private scope — flagged only so ELIXIR-DEV doesn't
   feel obligated to extract it further than this module.
2. **OQ-2 — anti-pattern entry.** This design recommends DOC-UPDATER (or ELIXIR-DEV
   directly, per this project's "add to `docs/anti-patterns.md` when you find a
   mistake worth not repeating" rule) add an entry along the lines of: "A table with
   more than one unique index needs its own `on_conflict:`-conflict-target
   reasoning per index — naming only one arbiter in `Repo.insert/2`'s
   `conflict_target:` silently leaves every *other* unique index's conflicts
   unsuppressed, which only surfaces as a bug under genuine cross-connection
   concurrency (not under `Sandbox` `:manual`-mode single-connection races, which
   this project's original REQ-018 test used and which cannot expose this class of
   gap)." Not added directly by this design step (CODE-DESIGNER writes design docs,
   not `docs/anti-patterns.md` entries) — named here for whichever downstream role
   closes this issue out to action.
3. **OQ-3 — should the new `:auto`-mode race test (§5) also cover the "loser hits the
   `(external_realm, external_id)` arbiter, not `username`" ordering, to confirm both
   orderings resolve identically?** This design's §3.1 argument holds regardless of
   which index Postgres happens to check first (both paths converge on
   `re_select_on_conflict/3`), so a single new test asserting only the outcome (not
   which internal branch fired) is sufficient to prove the fix — but TEST-DESIGNER
   may judge that asserting the specific `username_unique_conflict?/1` branch fired
   at least once across N loop iterations (e.g. via a test-only telemetry hook or by
   trusting ISSUE-FIXER's own 4/6-of-6 reproduction rate as sufficient evidence the
   new test's loop will exercise it) adds confidence. Left to TEST-DESIGNER's
   judgment, not mandated by this design.

## 7. Acceptance-criteria traceability

| ISS-0047 CODE-DESIGNER task acceptance criterion | Concrete design element |
|---|---|
| "Design document written to lib/letflow/design/ ... filename references iss0047" | This file: `lib/letflow/design/iss-0047-username-race-conflict-target.md` |
| "Design explicitly covers both the race-resolves-cleanly case and the genuine-unrelated-collision case ... must not weaken or break identity_test.exs:379-394" | §3.1 (race case), §3.2 (genuine collision, worked through against the exact pinned test) |
| "Design does not require Ecto.Multi or change the 'not a naive insert-then-rescue' constraint ... unless justified" | §2.1 (explicit justification: this is changeset-error pattern-matching on an already-returned typed value, not a rescue-based replacement of the on_conflict algorithm); §4 (no Ecto.Multi) |
| "Design specifies exactly which function(s)/lines change and how, precisely enough for ELIXIR-DEV to implement without further judgment calls" | §2.2 (exact replacement of identity.ex lines 216-217), §2.3/§2.4/§2.5 (three new private helper @specs), §4 (explicit do-not-change list) |
| "No implementation code in the design artifact" | §2.2's block is labeled pseudocode (`IF`/`CASE`/`END`, not Elixir `case`/`do`/`end` syntax), matching `req018-jit-provisioning.md` §3.3's own precedent for this project |
| "next_action set to 'Route to CODE-DESIGN-VALIDATOR'" | Set in the handoff file, not this document |
