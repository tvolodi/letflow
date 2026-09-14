# ISS-0674 — Extend `session_view/1` with `score_pct`/`passed` so `GET /exam-sessions/:id` can render a candidate's own result

**Module:** `Letflow.Exam.Session` (`lib/letflow/exam/session.ex`), consumed by
`Letflow.Routers.ExamSessions` (`lib/letflow/routers/exam_sessions.ex`)
**Issue:** ISS-0674 / GitHub #1412 / letflow-queue task 674
**Stage:** S10 (bug/gap fix against REQ-351's landed implementation, REVIEWER-filed)
**Author:** CODE-DESIGNER, 2026-09-15

## Verdict: (a) — extend the existing read. This is NOT the reserved "sixth behaviour."

REVIEWER flagged this as genuinely close and asked for a real decision rather than a
quick field addition. Having read the router's scope-fence text, `outcome_from_session/1`,
`update_session_after_submit/4`, decision `0031`, and `ExamSessionResultPage.tsx`'s own
already-written analysis of this exact gap, my independent verdict is: **adding
`score_pct`/`passed` to `session_view/1`'s map, and threading them through
`session_view_json/1` in the router, stays inside `GET /exam-sessions/:id`'s already-
authorized state read. It does not build the reserved "sixth behaviour."**

### Reasoning

1. **The fenced-off "sixth behaviour" is a *route*, not a *field*.** The router
   moduledoc's "Deliberately NOT routed here" section names concrete, unbuilt
   capabilities: `GetExamHistory`/`HandleGetMyResults` (a cross-session results-LIST)
   and `GetSessionResult` (a bespoke single-result endpoint mirroring the Go reference
   backend's own separate handler). Both are entire request/response surfaces that do
   not exist today. What ISS-0674 proposes is neither: no new route, no new handler
   function, no new permission atom, no new module. It is two additional keys in a map
   a function already builds and a route already serves 200s from every time a
   candidate reads their own session.

2. **This exact data already leaves this exact router today, for the exact same
   caller.** `POST /exam-sessions/:id/submit` (`render_submit/2` →
   `submission_outcome_json/1`) already returns `percentage`/`passed` (via
   `total_score`/`percentage`, sourced from the same `score_pct` field) to the same
   authenticated candidate, over the same `ExamSessionSubmit` permission, the moment
   they submit. The only gap ISS-0674 closes is that a candidate who reloads the page
   *after* that response was already shown to them cannot re-fetch the same two facts
   through the sibling read route. That is a durability/idempotency gap in an already-
   authorized disclosure, not a new disclosure. `Letflow.Exam.Session` itself already
   proves this: `outcome_from_session/1` (session.ex:1087-1098) is the exact function
   `submit/3`'s idempotent re-submit path calls to reconstruct this exact triple from
   the persisted record — the ONLY thing standing between that helper's output and the
   GET route today is that `session_view/1` never calls it.

3. **`status` alone already leaks the outcome's headline fact.** `session_view/1`
   already returns `status`, and `:submitted`/`:auto_submitted` are visible today
   through the very same GET route this issue touches. A candidate who sees
   `status: "submitted"` already knows their exam finished; `score_pct`/`passed` are
   detail on a fact already exposed, not a new fact class.

4. **Decision 0031 treats this as already-settled, not as a reopening.** 0031's "What
   this record does not decide" section states verbatim: *"The single-result-by-id
   question. REQ-351 owns that half and the evidence already settles it independently
   of this record."* Its "measured evidence" section further characterizes REQ-351 as
   already closing "the higher-value half of the same gap (a candidate's own single
   just-submitted result, durably viewable by session id) ... **and does so with zero
   new backend surface — it reuses an already-routed, already-owned read**." 0031 is
   describing exactly the shape ISS-0674 asks for (reusing the existing GET-by-id read
   to surface a score) as the settled, lower-cost half of the results-surface question
   — the thing it declines to build is the *list*, not this. Extending the same read
   with the two fields it was always missing is consistent with 0031's own framing, not
   in tension with it.

5. **Ownership/tenant-isolation surface is unchanged.** `get_session_state_for_user/3`'s
   existing `(:session_not_found | :not_owner)` guard, and the router's INV-5
   identical-404 rendering, are untouched — `score_pct`/`passed` are read off the exact
   same already-ownership-checked `session` record every other field in this response
   comes from. No new `Repo` call, no new join, no new redaction surface (unlike the
   `is_correct`/`explanation` question-bank fields this router already hand-redacts,
   `score_pct`/`passed` are the candidate's own scalar facts about their own attempt,
   with no answer-key content embedded in them).

**What would have tipped this to verdict (b):** if the ask were a *new* route (a
`GetSessionResult`-shaped endpoint), a results-list, or exposure of any question/
answer-level correctness detail (`is_correct`, `explanation`, per-question scores) —
none of which ISS-0674 asks for. None of those apply here; the ask is bounded to two
scalar fields already computed and already disclosed once, on the same record, to the
same caller, through the same permission.

## Design for ELIXIR-DEV

**Scope: same route (`GET /exam-sessions/:id`), same delegate
(`get_session_state_for_user/3`), same private helper (`session_view/1`). No new
route, no new handler, no new permission atom, no new module.**

### 1. `Letflow.Exam.Session.session_view/1` (`lib/letflow/exam/session.ex:1151-1160`)

Add two keys to the map this private function returns:

```
defp session_view(session) do
  %{
    id: session.record_id,
    exam_id: fv(session, "exam_id"),
    candidate_id: fv(session, "user_id"),
    status: session_status_atom(fv(session, "status")),
    seed: fv(session, "seed"),
    started_at: parse_dt!(fv(session, "started_at")),
    expires_at: parse_dt!(fv(session, "expires_at")),
    score_pct: <new>,
    passed: <new>
  }
end
```

**Exact field semantics — replicate `outcome_from_session/1`'s existing nil-substitution
idiom exactly, do not invent new rules:**

- `score_pct :: float() | nil`
  - `nil` when the underlying persisted field is absent (an `:in_progress` session:
    `update_session_after_submit/4` has never run for it, so `fv(session, "score_pct")`
    reads `nil`). Do NOT default this to `0.0` the way `outcome_from_session/1` does
    (`to_float(fv(session, "score_pct") || 0)`) — that defaulting exists there because
    `submission_outcome()`'s `percentage :: float()` type has no `nil` variant; `session_view()`
    is free to keep `nil` meaning "no score yet," which is the more honest signal for an
    in-progress session and is what `ExamSessionResultPage.tsx`'s own gap analysis
    (its top comment, lines 43-56) expects it to distinguish.
  - `to_float(fv(session, "score_pct"))` (via the existing `to_float/1` private helper,
    already handles `float()`/`integer()`/`Decimal.t()`) once the field is present —
    i.e., for `:submitted`, `:auto_submitted`, and `:grading_pending` sessions, since
    `update_session_after_submit/4` persists `score_pct` unconditionally at submit time
    regardless of which of those three statuses the outcome lands on
    (`session.ex:1058-1083`).
- `passed :: boolean() | nil`
  - `nil` for `:in_progress` (field never persisted yet — same reasoning as `score_pct`).
  - `nil` for `:grading_pending` — **replicate `outcome_from_session/1`'s existing
    `if(status == :grading_pending, do: nil, else: fv(session, "passed"))` rule
    verbatim.** The DB row may already hold a boolean (`update_session_after_submit/4`
    always writes `outcome.passed || false`), but `outcome_from_session/1` already
    establishes that a `grading_pending` session's `passed` is not yet a decided fact
    (short-text answers are still pending manual grading, so pass/fail is not final) —
    `session_view/1` must not contradict that by exposing the DB's placeholder `false`
    as if it were a real value.
  - `fv(session, "passed")` (the persisted boolean) for `:submitted`/`:auto_submitted`.

**Do not introduce a third helper function duplicating this logic.** Since
`outcome_from_session/1` already encodes the identical `score_pct`/`passed` derivation
rules (modulo the `0.0`-default divergence on `score_pct` explained above, and modulo
`total_score`/`total_max_score`, which are outcome-specific and have no `session_view()`
equivalent), factor the shared nil-substitution logic for `passed` into one private
helper both functions call — e.g. `defp passed_for_status(status, session)` — rather
than writing the `if status == :grading_pending` conditional twice. Naming and exact
placement (next to `session_status_atom/1` in the "Shared plumbing" section) is
ELIXIR-DEV's implementation call; the requirement is only that the two call sites do
not silently drift from each other over time.

### 2. `@type session_view` (`session.ex:156-164`)

```
@type session_view :: %{
        id: String.t(),
        exam_id: String.t(),
        candidate_id: String.t(),
        status: :in_progress | :submitted | :auto_submitted | :grading_pending,
        seed: integer(),
        started_at: DateTime.t(),
        expires_at: DateTime.t(),
        score_pct: float() | nil,
        passed: boolean() | nil
      }
```

This type is shared by `create/3`'s return value too (`create_with_seed/4`'s
`@spec`). That is fine and requires no special-casing: a freshly created session is
always `:in_progress`, so `score_pct`/`passed` are simply `nil` on that path, matching
the semantics above without any conditional logic at the call site.

### 3. `Letflow.Routers.ExamSessions.session_view_json/1` (`lib/letflow/routers/exam_sessions.ex:466-484`)

Add both fields to the destructuring pattern and the returned JSON map, rendering
`nil` as JSON `null` (no key omission — keep the shape uniform across all four
statuses so the frontend can pattern-match on presence/absence of a non-null value
rather than key presence):

```
defp session_view_json(%{
       id: id,
       exam_id: exam_id,
       candidate_id: candidate_id,
       status: status,
       seed: seed,
       started_at: started_at,
       expires_at: expires_at,
       score_pct: score_pct,
       passed: passed
     }) do
  %{
    "id" => id,
    "exam_id" => exam_id,
    "candidate_id" => candidate_id,
    "status" => Atom.to_string(status),
    "seed" => seed,
    "started_at" => DateTime.to_iso8601(started_at),
    "expires_at" => DateTime.to_iso8601(expires_at),
    "score_pct" => score_pct,
    "passed" => passed
  }
end
```

No change to `session_state_json/1` itself (session.ex-router:486-499) — it already
delegates to `session_view_json/1` for the `"session"` key, so the new fields flow
through automatically. No change to `render_start_session/4`'s call path either — it
reuses the same `session_state_json/1`, and a freshly started session simply carries
`score_pct: null, passed: null`.

### 4. Field-name confirmation (not guessed)

Confirmed directly against the persisted attrs `update_session_after_submit/4` writes
(`session.ex:1058-1069`): the entity's persisted keys are exactly `"score_pct"` (float)
and `"passed"` (boolean, never nil in storage — `outcome.passed || false`). These are
the same names `priv/packs/bilimbaga/entity_definitions/session.json` declares
(`queried: false`, per decision 0031's §"decisive technical fact" — readable via
`fv/2`, just not filterable/sortable through the entity query DSL, which is irrelevant
here since this read goes through `Letflow.Entities.Record.Latest.get/3`, not the
query compiler). No new persisted field, no migration, no entity-definition change.

### 5. What does NOT change

- No new route, handler, or permission atom.
- No change to `get_session_state_for_user/3`'s error shape
  (`:session_not_found`/`:not_owner`) or the router's identical-404 rendering (INV-5).
- No change to `question_state_json/1`'s redaction (`is_correct`/`explanation` etc.
  remain excluded) — this design touches only the session envelope, never question/
  answer-option fields.
- No change to `submission_outcome()`/`submission_outcome_json/1` — the submit route's
  response shape is untouched; this design only makes the GET route able to reconstruct
  the same two scalar facts on a later read.
- `outcome_from_session/1`'s own moduledoc-flagged "raw sums reconstructed, not
  replayed" gap is untouched and out of scope for this fix.

### 6. Frontend follow-up (not built here)

`web/src/pages/exam/ExamSessionResultPage.tsx`'s `score_unavailable` branch
(lines 105-111) is the consumer that needs updating once `score_pct`/`passed` exist on
`ExamSessionStateResponse.session`. That file's own top-of-file comment (lines 25-56)
already names this exact fix as its tracked follow-up and states the field names it is
waiting on — FRONTEND-DEV's task is to read `response.session.score_pct`/`.passed`
(both possibly `null`) for `submitted`/`auto_submitted` statuses and render
`exam-result-score` instead of `exam-result-scoreUnavailable` when they are non-null,
constructing whatever `ExamSubmissionOutcome`-shaped value `ExamResultView` expects
(e.g. `total_score: score_pct, total_max_score: 100.0, percentage: score_pct, passed`)
— exact TypeScript changes are FRONTEND-DEV's own design/implementation call, not
specified further here.

## Open questions

None for the backend half. `total_max_score`'s constant-`100.0` convention
(`outcome_from_session/1`'s own existing choice, unchanged by this design) is an
existing, not a new, simplification — not reopened here.
