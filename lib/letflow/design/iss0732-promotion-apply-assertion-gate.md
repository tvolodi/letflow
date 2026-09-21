# ISS-0732 — `apply_review/4` must gate on a matching-digest, passed assertion run

Status: DESIGN (pending CODE-DESIGN-VALIDATOR)
Owner module: `lib/letflow/definitions/promotion.ex` (`Letflow.Definitions.Promotion`)
Related: `lib/letflow/routers/promotions.ex` (R7 `handle_apply/2`/`render_apply/2`)
Scope: **BACKEND ONLY.** The frontend surfacing piece
(`web/src/components/NonSkippableApprovalGate.tsx` showing a "rehearsal
required"/"rehearsal stale"/"rehearsal failed" blocked state) is deliberately
out of scope for this design — it is tracked separately as ISS-0767
(letflow-queue task 767) and must be designed and implemented there, not here.

## 1. Problem (from ISSUE-FIXER's diagnosis, `handoffs/WF03-ISS0732-20260921/step-01-issue-fixer-diagnosis.json`)

`apply_review/4`'s `with` chain (`lib/letflow/definitions/promotion.ex:586-592`)
is exactly:

1. `PromotionReviewStore.get_review/2`
2. `verify_apply_digest/2` (review's stored `plan_digest` vs. the caller-supplied
   `plan_digest` — constant-time via `PromotionDigest.verify_digest/2`)
3. `verify_approved/1` (review `status == :approved`)
4. unconditionally `do_apply_review/3` → `promote_definition/3`

There is no precondition anywhere in this chain (or in `do_apply_review/3`/
`promote_definition/3`) requiring that the plan was ever rehearsed via
`Letflow.Definitions.apply_promotion_assertion_rerun/6`, let alone that the
rehearsal passed. A review can go straight from `:approved` to `:applied` with
zero `PromotionAssertionRun` ever having existed for it, or with only a stale
run against an earlier `plan_digest`, or with a run that recorded failing
assertions. This design adds the missing precondition.

## 2. New precondition — placement and behaviour

Inserted into `apply_review/4`'s `with` chain **after `verify_approved/1`
and before `do_apply_review/3` is called** — i.e. as a fourth clause, changing
nothing about the first three:

```
with {:ok, review} <- PromotionReviewStore.get_review(review_id, opts),
     :ok <- verify_apply_digest(review, plan_digest),
     :ok <- verify_approved(review),
     :ok <- verify_rehearsed(review, plan_digest, opts) do
  do_apply_review(review, actor_id, opts)
end
```

(Shown here as prose/pseudocode describing the ordering only — not a literal
code block to be copied; ELIXIR-DEV writes the actual clause.)

Rationale for the ordering: `verify_rehearsed/2` reads `promotion_assertion_runs`,
a real I/O round-trip, so it must run only after the two cheaper, purely
struct-local checks (`verify_apply_digest/2`, `verify_approved/1`) have already
short-circuited — same "cheapest check first" shape the existing chain already
follows (digest check before status check). It must also run before
`do_apply_review/3`/`promote_definition/3`, which is the point that actually
starts mutating `process_definitions` rows — nothing about the promotion may
begin until the rehearsal gate has cleared, matching how `verify_approved/1`
already guarantees "no `process_definitions` row touched" for an illegal
transition (see this module's own `apply_review/4` `@doc`, step 3).

### 2.1 `verify_rehearsed/2` (new private function)

```
@spec verify_rehearsed(
        review :: PromotionReview.t(),
        plan_digest :: String.t(),
        opts :: [prefix: String.t()]
      ) :: :ok | {:error, apply_review_error()}
```

Behaviour (three sub-checks, each short-circuiting, each producing a distinct
error reason per §3):

1. Call `Letflow.Definitions.get_latest_assertion_run(review.id, opts)`.
   - `{:error, :not_found}` → `{:error, :assertion_run_missing}` (§3.1). No
     rehearsal has ever been recorded for this review at all.
   - `{:ok, assertion_run}` → continue to step 2.
2. Compare `assertion_run.plan_digest` against the `plan_digest` argument
   (the plan digest currently being applied — the same value already
   threaded through `apply_review/4` and used by `verify_apply_digest/2`)
   using `PromotionDigest.verify_digest/2` — the same constant-time
   comparison `verify_apply_digest/2` already uses, not a raw `==`. This is a
   **different pair of values** than `verify_apply_digest/2` compares
   (`review.plan_digest` vs. caller-supplied `plan_digest`): here it is
   `assertion_run.plan_digest` (the digest the *rehearsal ran against*) vs.
   the same caller-supplied `plan_digest`. A stale rehearsal — one recorded
   against an older plan, before the review's plan was amended/resubmitted —
   must not satisfy the gate.
   - Mismatch → `{:error, :assertion_run_digest_mismatch}` (§3.2) — a name
     chosen specifically so it can never be confused with the existing
     top-level `:digest_mismatch` (review-vs-caller digest) in a log line,
     error match clause, or test failure message.
   - Match → continue to step 3.
3. Check `assertion_run.assertions_failed == 0` — **not**
   `assertion_run.status == :passed`, per ISSUE-FIXER's diagnosis and
   `lib/letflow/routers/promotions.ex`'s own documented R8 gate condition
   (moduledoc "## The assertion-run gate condition (design §7.5)"): a
   `status: :teardown_failed` run with `assertions_failed == 0` is still a
   green gate; mirroring `status == :passed` here would silently disagree
   with that already-documented contract.
   - `assertions_failed > 0` → `{:error, :assertion_run_failed}` (§3.3).
   - `assertions_failed == 0` → `:ok`.

`verify_rehearsed/2` does no writes; it is a pure read-then-branch function,
consistent with `verify_apply_digest/2`/`verify_approved/1`'s own shape (both
private, both side-effect-free, both called only from `apply_review/4`'s
`with` chain).

`opts` here is the same `opts` keyword list already threaded through
`apply_review/4` (it must carry `:prefix` — `get_latest_assertion_run/2`
`Keyword.fetch!/2`'s it, same as every other call in this chain that reaches
the database via `opts[:prefix]`).

## 3. `apply_review_error()` — new @spec union

Current (`lib/letflow/definitions/promotion.ex:536-540`):

```
@type apply_review_error ::
        :review_not_found
        | :digest_mismatch
        | :invalid_transition
        | {:promotion_failed, promote_error()}
```

New (three new union members added; nothing removed or widened; no existing
catch-all member is touched):

```
@type apply_review_error ::
        :review_not_found
        | :digest_mismatch
        | :invalid_transition
        | :assertion_run_missing
        | :assertion_run_digest_mismatch
        | :assertion_run_failed
        | {:promotion_failed, promote_error()}
```

### 3.1 `:assertion_run_missing`

No `promotion_assertion_runs` row exists at all for `review.id`
(`get_latest_assertion_run/2` returned `{:error, :not_found}`). Distinct from
`:invalid_transition` per the acceptance criteria and per ISSUE-FIXER's
diagnosis — callers/tests/the frontend must be able to tell "review is in the
right state but was never rehearsed" apart from "review is in the wrong
state entirely."

### 3.2 `:assertion_run_digest_mismatch`

The most recent assertion run's `plan_digest` does not match the `plan_digest`
being applied — the rehearsal was for a different (stale) plan. Distinct from
the top-level `:digest_mismatch` (which compares `review.plan_digest` against
the caller-supplied `plan_digest`, a different pair entirely) — the two names
share no substring beyond "digest_mismatch" by coincidence of English, and the
`assertion_run_` prefix is deliberate so grepping either name in logs, error
matches, or test assertions never returns a false positive for the other
check.

### 3.3 `:assertion_run_failed`

A matching-digest assertion run exists but `assertions_failed > 0`.

## 4. Worked examples (plain English — the four paths through the new chain)

All four assume `get_review/2` already returned `{:ok, review}` with
`review.status == :approved` and `verify_apply_digest/2` already returned
`:ok` (i.e. the request has already cleared the three pre-existing checks) —
these examples describe only what `verify_rehearsed/2` adds.

1. **Success.** `get_latest_assertion_run(review.id, opts)` returns
   `{:ok, run}`; `run.plan_digest` matches the applied `plan_digest`;
   `run.assertions_failed == 0`. `verify_rehearsed/2` returns `:ok`;
   `apply_review/4` proceeds to `do_apply_review/3` exactly as it does today;
   final result is `{:ok, %{review_id: ..., ...}}` on a successful promotion,
   unchanged from today's success shape.

2. **No rehearsal.** `get_latest_assertion_run(review.id, opts)` returns
   `{:error, :not_found}` (no `promotion_assertion_runs` row has ever been
   inserted for this review). `verify_rehearsed/2` returns
   `{:error, :assertion_run_missing}`; `apply_review/4` short-circuits and
   returns `{:error, :assertion_run_missing}`. Nothing is written —
   `do_apply_review/3` is never called, so neither `promote_definition/3` nor
   `PromotionReviewStore.mark_review_applied/2`/`mark_review_failed/2` runs.

3. **Stale rehearsal.** `get_latest_assertion_run(review.id, opts)` returns
   `{:ok, run}` where `run.plan_digest` was computed for an earlier version
   of the plan (e.g. the review was resubmitted after an amendment, and a
   rehearsal from before the amendment is still the most recent row).
   `PromotionDigest.verify_digest(run.plan_digest, plan_digest)` returns
   `false`. `verify_rehearsed/2` returns
   `{:error, :assertion_run_digest_mismatch}`; `apply_review/4` short-circuits
   with that error. Nothing is written.

4. **Failed rehearsal.** `get_latest_assertion_run(review.id, opts)` returns
   `{:ok, run}` where `run.plan_digest` matches, but `run.assertions_failed`
   is e.g. `2` (regardless of `run.status`, which could be `:failed` or even
   `:teardown_failed`). `verify_rehearsed/2` returns
   `{:error, :assertion_run_failed}`; `apply_review/4` short-circuits with
   that error. Nothing is written.

In all three failure paths, `apply_review/4`'s overall
`{:ok, ...} | {:error, apply_review_error()}` contract is preserved — these
are new leaves of the existing `{:error, apply_review_error()}` branch, not a
new return shape.

## 5. R7 router changes — `lib/letflow/routers/promotions.ex`

### 5.1 What must change

`handle_apply/2` itself needs **no change** — it already forwards
`Promotion.apply_review/4`'s raw result to `render_apply/2`
(`lib/letflow/routers/promotions.ex:598-620`), and the new error reasons flow
through the same `result` variable unchanged. Only `render_apply/2` needs
three new clauses, one per new error reason, added alongside its existing
per-reason clauses (`:625-659`).

### 5.2 New `render_apply/2` clauses — HTTP status and rationale

All three new reasons get **409 Conflict**, each with its own `detail`
string — extending, not replacing, this module's own documented
"single-atom 409 rule" (design §6.1, moduledoc lines 91-103). That rule
currently covers `:invalid_transition` alone (one 409, one fixed detail
string, deliberately never naming the row's actual status, because
`:invalid_transition` itself conflates an illegal edge with a lost
optimistic-lock race and must not be asked to distinguish them). The three
new reasons are a different situation: each is already a *single, specific,
non-ambiguous* fact (no rehearsal recorded / rehearsal is for a stale plan /
rehearsal recorded failures) with no race-condition-conflation problem behind
it, so each is free to carry its own distinguishing `detail` text — matching
how `:digest_mismatch` (`:627-628`) and the various `{:promotion_failed, ...}`
reasons already each get their own specific 409 `detail` rather than being
folded into `invalid_transition_response/1`.

409 (not 422, not 403, not 400) is chosen because, like the existing
`:invalid_transition` and `:digest_mismatch` cases on this same route, this is
a state-transition-not-permitted case: the review's current state (no
matching-digest, zero-failure rehearsal on record) conflicts with the apply
operation being requested — the same "conflict with current state of the
resource" semantics 409 already carries for every other precondition failure
`handle_apply/2` returns. It is deliberately **not** folded into
`invalid_transition_response/1` (which would make it indistinguishable from an
actual `:invalid_transition`), and deliberately **not** a 422 (422 is reserved
on this router for R8's `run-assertions` outcome-shape response, a different
kind of "request was well-formed but semantically failed" case with its own
response body shape — not a fit for a `with`-chain precondition failure).

Concretely (prose, not literal code — ELIXIR-DEV writes the actual clauses,
following the exact pattern of the adjacent existing `render_apply/2`
clauses at `:627-628`/`:642-643`):

- `{:error, :assertion_run_missing}` → `Response.conflict/2` with detail
  along the lines of "no assertion run has been recorded for this review;
  run assertions before applying" (mirrors the existing
  `Response.conflict(conn, "...")` call shape used for `:source_definition_missing`
  at `:642-643`).
- `{:error, :assertion_run_digest_mismatch}` → `Response.conflict/2` with
  detail along the lines of "the most recent assertion run does not match
  the plan_digest being applied; re-run assertions against the current plan".
- `{:error, :assertion_run_failed}` → `Response.conflict/2` with detail along
  the lines of "the most recent assertion run recorded failing assertions;
  applying is blocked until a rehearsal with zero failures is recorded".

No new `Letflow.Api.Error` problem-detail helper is required (unlike
`Error.invalid_promotion_source/1` or `Error.promotion_conflict/2`, which
carry structured `details`) — these three are plain `Response.conflict/2`
calls with a fixed string, the same shape as `:digest_mismatch`'s own clause
(`:627-628`), because there is no per-request structured detail (like a list
of conflicting versions) to attach.

## 6. Cross-module dependencies / call graph impact

- `Letflow.Definitions.Promotion.apply_review/4` gains one new call to
  `Letflow.Definitions.get_latest_assertion_run/2` (already public, already
  stable — no change needed to `definitions.ex`) and one new call to
  `Letflow.Definitions.PromotionDigest.verify_digest/2` (already public,
  already used elsewhere in this same module — no change needed to that
  module either).
- No schema/migration change — `PromotionAssertionRun` already carries both
  `plan_digest` and `assertions_failed` (`lib/letflow/definitions/promotion_assertion_run.ex:55,65`).
- No change to `PromotionReviewStore` (`get_review/2`,
  `mark_review_applied/2`, `mark_review_failed/2` are untouched).
- `promote_definition/3` and everything it calls are untouched — this gate
  runs strictly before it in the `with` chain.

## 7. Invariants this design preserves or adds

- **INV-NEW-1**: `apply_review/4` never calls `do_apply_review/3` unless a
  `promotion_assertion_runs` row exists for `review.id` whose `plan_digest`
  matches the plan_digest being applied AND whose `assertions_failed == 0`.
- **INV-NEW-2**: the three new error reasons are structurally
  indistinguishable in *shape* from the existing plain-atom error reasons
  (`:review_not_found`, `:digest_mismatch`, `:invalid_transition`) — none is
  wrapped in a tuple — so no caller pattern-matching on
  `{:error, atom()}` needs to change its matching shape, only add clauses.
- **INV-NEW-3** (carried over, unchanged): on every new failure path,
  nothing is written — `do_apply_review/3` (and therefore
  `PromotionReviewStore.mark_review_applied/2`/`mark_review_failed/2` and
  `promote_definition/3`) is never invoked. Same "nothing written on a
  short-circuit" property `verify_approved/1` already guarantees for
  `:invalid_transition`.
- **INV-NEW-4**: `verify_rehearsed/2`'s digest comparison
  (`assertion_run.plan_digest` vs. applied `plan_digest`) always uses
  `PromotionDigest.verify_digest/2` (constant-time), never `==`, for the same
  timing-attack-avoidance reason `verify_apply_digest/2` already uses it.

## 8. Open questions (explicitly not resolved here)

- **OQ-1**: Should `:assertion_run_missing` vs. `:assertion_run_digest_mismatch`
  vs. `:assertion_run_failed` be distinguishable in the *frontend's* UI copy
  (three different blocked-state messages) or collapsed to one generic
  "rehearsal required" state? Out of scope for this design — that is
  ISS-0767's decision to make, not this one's. This design only guarantees
  the backend emits three distinct, named reasons so ISS-0767's frontend
  design has the information available to make that call either way.
- **OQ-2**: Whether a concurrent rehearsal (a `run-assertions` call racing
  with an `apply` call) could observe a `promotion_assertion_runs` row
  mid-`update_changeset/2` (i.e. still `status: :running`, `assertions_failed`
  still at its `0` default) and let a not-yet-completed rehearsal
  incorrectly satisfy the gate. `get_latest_assertion_run/2`'s query has no
  `status` filter today. This design does not add one — REQ-077 §9.2's
  existing `@doc` for `get_latest_assertion_run/2` does not filter on status
  either (R3/R4 read whatever the latest row is, running or not), and this
  gate reuses that same read verbatim rather than diverging from it. Flagged
  for SECURITY-REVIEWER/REVIEWER to confirm whether a `status: :running` row
  (whose `assertions_failed` is always `0` by construction, per
  `insert_changeset/2`'s defaults) is an acceptable false-pass, or whether a
  follow-up should add `status: :passed` (or "not `:running`") to the
  `verify_rehearsed/2` check specifically — NOT resolved by silently adding
  a `status`-based check here, since ISSUE-FIXER's diagnosis and this
  design's §2.1 step 3 explicitly reject gating on `status` for the
  documented-elsewhere reason (R8's own `assertions_failed == 0` contract).
  This OQ is about a *different*, narrower question (an in-flight run) than
  that already-settled one (a completed run's outcome field).
