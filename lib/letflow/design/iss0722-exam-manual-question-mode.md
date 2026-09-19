# ISS-0722 — Support `exam_question_rule.mode == "manual"` in session materialization

**Module:** `lib/letflow/exam/session.ex` (`fetch_question_pools/2` and its call site,
`materialize_session/5`)
**Not modified:** `lib/letflow/exam/question_set_resolver.ex` (see §2 — bypassed, not
extended)
**Route to:** ELIXIR-DEV (Elixir library code, no migration — `exam_manual_question` is
already a shipped, pack-installable entity type; no schema change needed)
**Related:** `docs/issues/ISS-0722.yaml` (queue ref Q-721), REQ-330/REQ-332 (this
module's own authorizing design, `lib/letflow/design/req330-exam-live-session.md`),
`priv/packs/bilimbaga/entity_definitions/exam_manual_question.json`,
`priv/packs/bilimbaga/entity_definitions/exam_question_rule.json`
**Security:** touches a tenant-data read path (materializes session questions from
tenant-scoped entity records) — **requires SECURITY-REVIEWER sign-off**, not eligible
for ORCH's direct-action sizing exception (per ISS-0722's own handoff instruction).

## 0. Root cause, re-verified against current code

Confirmed by direct read of `lib/letflow/exam/session.ex:743-767`
(`fetch_question_pools/2`):

```
random_rules =
  rule_records
  |> Enum.filter(&(fv(&1, "mode") == "random"))
  |> Enum.sort_by(&fv(&1, "sort_order"))
```

Every `exam_question_rule` row is fetched (unfiltered `query_all`), but the very next
step drops every row whose `mode` is not `"random"`. A `mode == "manual"` rule
contributes zero entries to `rules`, so `QuestionSetResolver.resolve/5` is called with
an empty (or missing-a-rule) `rules` list for that rule, producing zero materialized
questions for it — silently, no error, `write_record("session", ...)` still succeeds,
API caller sees HTTP 201. `exam_manual_question.json`'s own moduledoc-equivalent
description (cited in the issue) is a real, authored, pack-installable entity type
("the explicit pin list of questions used when an exam question-selection rule's mode
is 'manual'"), confirmed by reading the file directly — this is deliberate product
intent, not a stub, so the fix adds real support rather than rejecting `mode: "manual"`
at rule-creation time.

## 1. Data-model facts that drive this design (read directly, not assumed)

From `priv/packs/bilimbaga/entity_definitions/exam_question_rule.json`:

- `mode` is `:enum ["manual", "random"]`, required — no other value exists.
- The only uniqueness constraint is `uq_exam_question_rule_exam_id_sort_order`, over
  `(exam_id, sort_order)` — **not** scoped by `mode`. This proves an exam's rules share
  one `sort_order` sequence regardless of mode, and **nothing in the schema forbids an
  exam from having both `mode: "random"` and `mode: "manual"` rules simultaneously** —
  mixing rule modes on the same exam is a valid, supported configuration, not an edge
  case to reject.
- `count` is required even for a `mode: "manual"` row (the entity definition has no
  per-mode conditional-required field) — see §5 for how this design treats that field
  when `mode == "manual"` (it is present in the row but semantically unused; not an
  error to encounter it, not read by the new manual path).

From `priv/packs/bilimbaga/entity_definitions/exam_manual_question.json`:

- Fields: `rule_id` (required, FK to `exam_question_rule`), `question_id` (required, FK
  to `question`), `sort_order` (required integer).
- Unique constraint `uq_exam_manual_question_rule_id_question_id` over
  `(rule_id, question_id)` — a question can be pinned at most once per rule (not
  globally — the same `question_id` can appear under two different rules, including a
  rule on a different exam, or even two manual rules on the same exam if an author
  chose to split pins across two rules).
- Indexed on `rule_id` (`idx_exam_manual_question_rule_id`) — a per-rule query
  (`eq("rule_id", rule_id)`) is the efficient, intended access pattern, exactly
  mirroring how `fetch_pool_questions/2` already queries `question` by `category_id`.

## 2. Decision: manual-mode questions bypass `QuestionSetResolver` entirely — the
resolver is not touched

**Chosen: bypass.** `QuestionSetResolver.resolve/5`'s `rule :: %{pool_id, count}` shape
stays exactly as authorized by `req330-exam-live-session.md` §8 and its own moduledoc's
explicit "Never generalises beyond this vertical's own `rules :: [%{pool_id, count}]`
shape ... no second caller exists today (0022 rule 3)." No new field is added to
`rule()`, no new clause is added to `resolve/5`, `pick_from_rules/2` is untouched, and
no second caller of `QuestionSetResolver` is introduced — `Letflow.Exam.Session`
remains its only caller, exactly as today.

**Why bypass is correct, addressed against the "never generalises" comment directly
(not sidestepped):**

1. **The shapes are semantically incompatible, not just differently typed.**
   `resolve/5`'s whole contract is "pick `count` of `M` candidates from `pool_id`,
   uniformly at random, and fail loud on underflow" (`pick_from_rules/2`:
   `candidates |> Enum.shuffle() |> Enum.take(count)`). Manual mode has no pool, no
   count-vs-candidates comparison, and no drawing — it names an exact, ordered set of
   `question_id`s directly. Extending `resolve/5` to also accept "here is the exact
   list, don't touch it" is not a generalization of a pool-draw algorithm; it would be
   bolting an unrelated, no-op code path onto a function whose entire moduledoc is
   about seeded randomness guarantees (`:rand.seed/2`, the reproducibility contract in
   §"Reproducibility"). A manual pin list has no seed-dependent behavior to document or
   test at all, so it does not belong inside a module whose moduledoc's central
   contract is about seeded reproducibility.
2. **Extending the resolver would falsify its own moduledoc the moment it merges.**
   "No second caller exists today (0022 rule 3)" and "never generalises beyond this
   shape" are both stated as *current, load-bearing facts* justifying why this is a
   bucket-2 (not bucket-B/generic-capability) module. Adding a manual-mode clause
   inside `resolve/5` doesn't create a second caller, but it does generalise the shape
   — falsifying the literal moduledoc text on the same commit that's supposed to keep
   it true. Bypassing keeps that sentence true without requiring a moduledoc edit to
   paper over a contradiction.
3. **No shared mechanism would actually be reused.** The only thing manual mode and
   `resolve/5` share is "produce a `resolved_question()`" — a 3-field map literal, not
   an algorithm. There is nothing non-trivial to reuse by routing through the resolver;
   building the same 3-field map directly in `Session` (mirroring the existing
   `fetch_pool_questions/2` → `fetch_option_ids/2` pattern already in this file, per
   the issue's own suggestion) is strictly simpler and touches one fewer module.

## 3. New private helper: `fetch_manual_questions/2`

Added to `lib/letflow/exam/session.ex`, alongside the existing
`fetch_pool_questions/2`/`fetch_option_ids/2` pair, same visibility and calling
convention:

```
@spec fetch_manual_questions(rule_id :: String.t(), prefix :: String.t()) ::
        {:ok, [QuestionSetResolver.question_row()]} | {:error, :manual_rule_empty | term()}
```

Behavior, in words:

1. `query_all("exam_manual_question", [eq("rule_id", rule_id)], prefix)` — reuses the
   existing `query_all/3`/`eq/2` private helpers verbatim, same as every other query in
   this module.
2. If the result list is empty, return `{:error, :manual_rule_empty}` immediately (see
   §6 — this is the fix's own answer to "does the silent-empty problem recur for manual
   mode," and the answer is no, it must not).
3. Otherwise, sort the rows by `fv(&1, "sort_order")` (ascending) — this is the row's
   *pin position within this rule*, distinct from `exam_question_rule.sort_order` (the
   rule's own position among all of the exam's rules — see §4 for how the two compose).
4. For each row in that sorted order, call the **existing** `fetch_option_ids/2`
   unchanged (`fetch_option_ids(fv(row, "question_id"), prefix)`) — the same call
   `fetch_pool_questions/2` already makes per question, reused verbatim, not
   duplicated.
5. Assemble `%{question_id: fv(row, "question_id"), option_ids: option_ids}` per row,
   in the §3.3 sorted order, threading `{:error, _}` through a `reduce_while` exactly
   like `fetch_pool_questions/2`'s own existing loop shape (same idiom, new function).
6. Return `{:ok, ordered_rows}` on full success.

This function reads the tenant-scoped `exam_manual_question` table only via the
existing prefix-scoped `query_all/3` helper — no new tenant-data-access pattern is
introduced; this is the fact SECURITY-REVIEWER needs to confirm (§8).

## 4. `fetch_question_pools/2` and `materialize_session/5` — the combined-mode design

`fetch_question_pools/2` changes from "fetch pool rows for random rules only, drop
everything else" to "fetch and route rows for **both** modes, returning both cleanly":

```
@spec fetch_question_pools(exam_id :: String.t(), prefix :: String.t()) ::
        {:ok, rules :: [QuestionSetResolver.rule()],
             pool :: %{String.t() => [QuestionSetResolver.question_row()]},
             manual_questions :: [QuestionSetResolver.question_row()]}
        | {:error, :manual_rule_empty | term()}
```

Body, in words:

1. `query_all("exam_question_rule", [eq("exam_id", exam_id)], prefix)` — unchanged
   (still fetches every rule for the exam, both modes).
2. Split into `random_rules` and `manual_rules` by `fv(&1, "mode")`, **each sorted by
   its own `fv(&1, "sort_order")`** (both splits sorted the same way the current single
   `random_rules` list already is — no behavior change to that sort for the random
   split).
3. `random_rules` → `rules`/`pool` exactly as today: unchanged
   `%{pool_id: fv(r, "category_id"), count: fv(r, "count")}` mapping,
   unchanged `fetch_pool_questions/2` calls per unique `pool_id`. **Zero behavior
   change for an exam whose rules are all `mode: "random"`** — this is deliberate (see
   §4.1 below) and is the reason existing tests for random-only exams need no changes.
4. `manual_rules` → for each rule **in `exam_question_rule.sort_order` order**, call
   `fetch_manual_questions(rule.record_id, prefix)` (§3) and concatenate the per-rule
   results in that same rule order. Any `{:error, _}` (including `:manual_rule_empty`)
   short-circuits the whole function via the same `reduce_while`/`with` idiom already
   used for `pool_ids` above — one bad manual rule fails the entire session-create call,
   not just that rule's contribution.
5. Return `{:ok, rules, pool, manual_questions}` (or the first error encountered).

`materialize_session/5`'s call site changes from:

```
with {:ok, rules, pool} <- fetch_question_pools(exam_id, prefix),
     {:ok, resolved} <- QuestionSetResolver.resolve(rules, pool, shuffle_questions?, shuffle_options?, seed) do
```

to (in words, no implementation code): fetch all four values
(`rules, pool, manual_questions`), call `QuestionSetResolver.resolve/5` **unchanged**
with `rules`/`pool` (the random-only subset) and the exam's real `shuffle_questions?`/
`shuffle_options?` flags exactly as today, producing `{:ok, resolved_random}` whose
entries already carry `sort_order` `0..n-1` and shuffled/unshuffled `options_order` per
today's resolver logic — untouched. Then, independently, map `manual_questions` (§3's
ordered list) into `resolved_question()` entries:

- `options_order`: `if shuffle_options? do Enum.shuffle(option_ids) else option_ids end`
  — the exam's `shuffle_options?` flag, applied identically to manual-origin questions.
  This is a one-line reapplication of the same existing boolean the exam record already
  carries, computed independently in `Session` (not by calling into the resolver) — it
  does not require touching `QuestionSetResolver`, and does not conflict with §2's
  "resolver untouched" decision, since it's just `Enum.shuffle/1` gated by a flag, not a
  drawing/underflow algorithm.
- `sort_order`: assigned by re-indexing the **concatenation** `resolved_random ++
  resolved_manual_unindexed`, i.e. `Enum.with_index/1` over the whole combined list,
  same as the resolver's own existing `Enum.with_index/1` pattern (mirrored, not
  reused, since it now runs once over the combined list in `Session` rather than once
  inside the resolver over the random-only list).

### 4.1 Explicit decision: `shuffle_questions?` does NOT reorder manual-origin questions

`shuffle_questions?` is applied **only within the random-drawn block** (via the
resolver's own existing, untouched `Enum.shuffle/1` on `selected` inside `resolve/5`) —
manual-origin questions are **never** reordered by this flag; their relative order is
always `exam_question_rule.sort_order` (across manual rules) then
`exam_manual_question.sort_order` (within a rule), exactly as authored, regardless of
the exam's `shuffle_questions?` setting.

**Justification:** "manual" mode's entire product intent (per BilimBaga's own spec
citation in `exam_manual_question.json`'s description — "the explicit pin list...used
when an exam question-selection rule's mode is manual") is "pin these exact questions,
no drawing, no pool." Randomizing *presentation order* of a hand-curated, sequenced pin
list (the reason `sort_order` exists as a real field on `exam_manual_question` at all —
otherwise it would be redundant with insertion order) would silently defeat half of why
an author chooses manual mode over random: a manually-ordered walkthrough (e.g. a fixed
tutorial-style sequence building in difficulty) is exactly the case manual mode exists
to serve, and `shuffle_questions?` reshuffling it regardless would be a second, subtler
silent-correctness bug layered on top of the one this fix closes. Random-drawn
questions have no analogous authored order to protect — resolver-side shuffling of
that block is unchanged from today.

### 4.2 Explicit decision: block order is random-block-first, then manual-block

The combined list is **not** fully interleaved by `exam_question_rule.sort_order`
across mode boundaries (i.e. a manual rule with `sort_order: 0` does not necessarily
appear before a random rule with `sort_order: 1` in the final materialized list) — the
random-resolved block always comes first, followed by the manual-pinned block (itself
internally ordered by rule `sort_order` then `exam_manual_question.sort_order`, per
§4/§3).

**Justification, since this is a real simplification and must be owned, not
smuggled in:**

- Full cross-mode interleaving would require `QuestionSetResolver.resolve/5` to expose
  which output rows came from which rule (it currently returns one flat list with no
  rule-boundary information), which is exactly the kind of shape change to the resolver
  §2 already rejected. Preserving full interleaving without touching the resolver
  would require re-implementing its per-rule draw-and-concatenate logic
  (`pick_from_rules/2`) a second time in `Session` — a straight duplication of
  existing, working logic for a purely cosmetic ordering refinement.
- Zero behavior change for any exam whose rules are all one mode (random-only: today's
  exact output; manual-only: the manual block is the entire list, in its own rule/pin
  order) — the only exams affected by this ordering choice are the *newly-supported*
  mixed-mode exams, which have never previously produced any correct output at all (the
  manual portion was previously silently dropped), so there is no regression risk for
  any exam that could `mix test` green before this fix.
- Neither `docs/issues/ISS-0722.yaml` nor BilimBaga's own product-spec citation demands
  cross-mode interleaving specifically — the issue's complaint is "manual rules produce
  zero questions," not "mixed-mode block order is wrong." Building full interleaving
  now would be precision beyond what any current acceptance criterion or product-spec
  citation asks for. If a future requirement needs true interleaving, that is a
  `docs/requirements.yaml` entry against `QuestionSetResolver`'s own shape (a real
  second caller/shape change, at which point its moduledoc's "never generalises"
  claim would need a deliberate, reviewed revision) — not something to speculatively
  half-build here.

## 5. Coexistence of manual and random rules on the same exam

Confirmed possible by §1's constraint reading (`uq_exam_question_rule_exam_id_sort_order`
is not mode-scoped). This design fully supports it: §4 always computes both
`resolved_random` (empty list if the exam has no random rules) and `resolved_manual`
(empty list if the exam has no manual rules — modulo §6, empty is only reachable when
there are zero manual *rules*, not zero manual rules-with-zero-rows, which errors) and
concatenates unconditionally. An exam with only random rules, only manual rules, or
both, all materialize correctly with no special-case branch needed in
`materialize_session/5` — the two fetch paths are simply always both run and always
both concatenated (concatenating an empty list is a no-op).

## 6. Zero-row manual rule: must error, not recur the silent-empty bug

**Decision: error, not silently empty.** §3 step 2 makes `fetch_manual_questions/2`
return `{:error, :manual_rule_empty}` the moment any single manual rule has zero
`exam_manual_question` rows, and §4 step 4 propagates that error out of
`fetch_question_pools/2` immediately (short-circuiting before any write), which
`materialize_session/5`'s `with` chain propagates out of `create_txn/4` un-rescued,
same as any other error already returned from that chain.

**Why this must error rather than silently contribute zero questions (unlike
`:pool_underflow`'s "fail the whole resolution," this is the same principle applied to
the new path):** a `mode: "manual"` rule with zero pinned rows is not a valid
"intentionally empty" configuration — nothing in `exam_manual_question.json`'s spec
describes an empty pin list as meaningful (unlike, say, an optional filter that's valid
when absent). An author who created a manual rule but never pinned any questions to it
has an incomplete or broken exam configuration, and this is exactly the same silent
failure mode ISS-0722 itself reports — reintroducing it for the "zero rows" case while
fixing the "any rows" case would leave the underlying defect class (a broken rule
producing zero questions with no error) only partially fixed.

**Error surface (`create/3`'s caller-facing contract, matching existing precedent):**
`:manual_rule_empty` is **not** added to `eligibility_error()` — it is a materialization
error, exactly like the existing `:pool_underflow` (also absent from `eligibility_error()`,
confirmed by reading `session.ex:133-139`), which already falls through
`create_with_seed/4`'s broader `{:ok, session_view()} | {:error, eligibility_error() |
term()}` spec via the `| term()` clause. `lib/letflow/routers/exam_sessions.ex`'s
`render_start_session/4` needs **no new clause** — `:manual_rule_empty` falls through
to the existing generic `defp render_start_session(conn, {:error, reason}, ...)` clause
(line 297) exactly as `:pool_underflow` already does today: `Logger.warning` +
`Response.internal_error(conn)` (HTTP 500). This is a deliberate parity choice, not an
oversight — both error atoms represent the same category of problem ("this exam's rule
configuration cannot produce a valid question set"), and giving `:pool_underflow` a
500-with-log while giving `:manual_rule_empty` a friendlier 4xx would be an unjustified
asymmetry between two structurally identical failure modes. ELIXIR-DEV should add
`:manual_rule_empty` next to `:pool_underflow` in any type/spec comment that already
lists materialization-error atoms together, but must not add a `render_start_session/4`
clause for it.

## 7. Test fixtures TEST-DESIGNER must extend

Confirmed by direct read of `test/letflow/exam/session_test.exs:66-103`:

- **`create_rule!/5`** (line 66) currently hardcodes `"mode" => "random"` unconditionally
  and has no way to create a manual-mode rule. TEST-DESIGNER must either (a) add a
  `mode` parameter/option to this existing helper (default `"random"`, preserving every
  existing call site unchanged), or (b) add a sibling `create_manual_rule!/3` — either
  is acceptable; (a) is preferred since it keeps one rule-creation helper rather than
  two nearly-identical ones, consistent with this file's existing style of adding
  optional args with defaults (`sort_order \\ 0` is already exactly this pattern on the
  same function).
- **New fixture needed, none exists today:** a helper to create `exam_manual_question`
  rows (e.g. `create_manual_question!(schema, rule_id, question_id, sort_order)`,
  mirroring `create_option!/4`'s existing shape at line 55) — `ExamFixtures.create_record!`
  (already used by every other helper in this file) is the right primitive to call
  it with, same as every other fixture helper here.
- **`build_minimal_exam!/2`** (line 87) currently always builds exactly one
  `mode: "random"` rule via `create_rule!/5` and returns `%{exam:, category_id:,
  questions:}` — no `question_id` list of *pinned* questions is returned today because
  none exists to pin. TEST-DESIGNER needs a manual-mode-aware variant: either extend
  `build_minimal_exam!/2` with a `:mode` opt (`:random` default, unchanged behavior) that
  when set to `:manual` builds a manual rule plus `exam_manual_question` rows for each
  of the `pool_size` questions it already creates (reusing `build_single_choice_question!/2`
  unchanged), or add a sibling `build_minimal_manual_exam!/2`. Given `build_minimal_exam!/2`
  already threads `pool_size`/`count`/`exam_attrs` through `opts`, adding one more `:mode`
  key is the lower-footprint choice and keeps one builder rather than two.
- **New coverage required** (not exhaustive — TEST-DESIGN-VALIDATOR will gate the full
  list against this design's acceptance criteria, this is the minimum implied by the
  design decisions above): manual-only exam materializes all pinned questions in
  `sort_order`; mixed random+manual exam materializes both blocks, random block first
  (§4.2); `shuffle_questions?: true` on a manual-only exam does **not** reorder the
  manual block (§4.1) — a seeded-reproducibility-style assertion, not a "shuffle
  happened" assertion, since manual order must be deterministic regardless of seed;
  zero-row manual rule → `{:error, :manual_rule_empty}` (or the create/3 caller-facing
  500, per which layer the test targets) (§6); a duplicate `(rule_id, question_id)` pin
  is already prevented at the fixture layer by `exam_manual_question`'s own DB unique
  constraint — no application-level duplicate check is needed or should be tested as
  application logic, since the constraint is the enforcement mechanism, not
  `fetch_manual_questions/2`.

## 8. Acceptance-criteria / SECURITY-REVIEWER mapping

| Concern | Design element |
|---|---|
| `mode: "manual"` rules materialize real questions, not silently zero | §3 `fetch_manual_questions/2`, §4 combined fetch/concatenation |
| `QuestionSetResolver`'s "never generalises" invariant explicitly addressed | §2 (bypass chosen and justified against the literal moduledoc text, not sidestepped) |
| Mixed-mode exam (both `random` and `manual` rules) explicitly specified | §1 (schema proves it's allowed), §4/§5 (both blocks always computed and concatenated) |
| Ordering fully specified: rule `sort_order`, `exam_manual_question.sort_order`, interaction with `shuffle_questions?` | §3 step 3 (within-rule), §4 step 4 (across manual rules), §4.1 (shuffle carve-out), §4.2 (block order, justified) |
| Zero-row manual rule does not recur the silent-empty bug | §6 (`{:error, :manual_rule_empty}`, propagated, mapped to existing generic 500 clause — parity with `:pool_underflow`) |
| Tenant-data read path stays within existing access pattern (no new query mechanism) | §3 step 1 (reuses `query_all/3`/`eq/2` verbatim), noted for SECURITY-REVIEWER in §3's closing paragraph |
| No implementation code, no silently-resolved open question | Whole document — every branch point in ISS-0722's own handoff instruction is resolved with a stated justification (§2, §4.1, §4.2, §6), not left as a TBD |

## 9. Explicitly NOT an open question (resolved above, listed here for scan-ability)

1. Bypass vs. extend `QuestionSetResolver` → **bypass** (§2).
2. Mixed-mode exams → **allowed by the schema, fully supported** (§1, §5).
3. Ordering (rule sort_order, manual sort_order, shuffle_questions? interaction) →
   **specified in full** (§3, §4, §4.1, §4.2).
4. Zero-row manual rule → **errors (`:manual_rule_empty`), does not recur the bug**
   (§6).
5. Test fixtures to extend → **`create_rule!/5`, a new `create_manual_question!/4`-shaped
   helper, `build_minimal_exam!/2`** (§7), confirmed against the file's current content.

No item in this list is left for ELIXIR-DEV, TEST-DESIGNER, or SECURITY-REVIEWER to
decide on their own judgment beyond ordinary implementation-level discretion (exact
raise/error-tuple wording, variable naming) — every structural decision the issue asked
CODE-DESIGNER to make has a stated answer and justification above.
