# ISS-0631 — Replace `String.to_existing_atom/1` on persisted session status with an explicit mapper

**Module:** `Letflow.Exam.Session` (`lib/letflow/exam/session.ex`)
**Issue:** ISS-0631 / GitHub #1330 / letflow-queue task 631
**Stage:** S0 (bug fix against REQ-332's landed implementation, no requirements.yaml entry)
**Author:** CODE-DESIGNER, 2026-09-13, on `issue/ISS-0631-20260913`

Root cause (ISSUE-FIXER, re-verified against current `main` — commit `ae2b808b`,
REQ-332 merged, no later commit touches this file): `session_view/1` (current line 911)
and `outcome_from_session/1` (current line 865) both call
`String.to_existing_atom(fv(session, "status"))` on a string read back from a persisted
`entity_record_latest` row. `:in_progress` never appears as an *executed code literal*
anywhere in `lib/` — only inside the `@type session_view`/`submission_outcome` specs
(lines 149/138), which are typespec metadata the BEAM loader does not eagerly populate
into the atom table. Whether `:in_progress` is already interned when
`session_view/1` runs depends on incidental load order, not on anything this module
guarantees. `outcome_from_session/1`'s three atoms (`:submitted`, `:auto_submitted`,
`:grading_pending`) are accidentally safe today only because they also appear as
executed literals elsewhere in this same module (confirmed: `:auto_submitted` at line
376, `:submitted` at line 336/743, `:grading_pending` at line 336/873) — a fragile
safety net that a future edit removing any of those three anchor lines would silently
break.

I re-read `lib/letflow/exam/session.ex` in full on this branch (clean tree, one
bookkeeping commit `5ad92b39` ahead of `ae2b808b`) and confirm both call sites and all
line numbers in ISSUE-FIXER's report are still current:

- line 865 — `outcome_from_session/1`
- line 911 — `session_view/1`
- lines 918–925 — `question_type_atom/1`/`polarity_atom/1`, the idiom to replicate
- lines 138/149 — the two `@type` specs enumerating the four status atoms

## 1. New private function: `session_status_atom/1`

**Name collision check:** `grep -n "session_status_atom" lib/letflow/exam/session.ex`
returns nothing pre-fix — no collision with any existing name in this module (or,
per a repo-wide search, anywhere else in `lib/`).

Placed in the "Shared plumbing" section, immediately next to `question_type_atom/1` and
`polarity_atom/1` (after line 925), matching their idiom exactly: one function clause
per known string, **no catch-all clause**.

```
@spec session_status_atom(String.t()) ::
        :in_progress | :submitted | :auto_submitted | :grading_pending
defp session_status_atom(status_string)
```

Exact clause set (verbatim strings confirmed against
`priv/packs/bilimbaga/entity_definitions/session.json`'s `status` field enum, and
matching `@type session_view`/`submission_outcome` at lines 138/149 exactly — no fifth
value exists anywhere):

```
defp session_status_atom("in_progress"), do: :in_progress
defp session_status_atom("submitted"), do: :submitted
defp session_status_atom("auto_submitted"), do: :auto_submitted
defp session_status_atom("grading_pending"), do: :grading_pending
```

A call with any other string (a corrupted/unexpected persisted value, a typo introduced
by a future entity-definition edit, etc.) matches no clause and raises
`FunctionClauseError`. This is intentional — see §3.

One shared function serves both call sites rather than two narrower ones
(`session_status_atom/1` for all four values, a hypothetical `outcome_status_atom/1`
for just the post-submission three) because:
- the four values are one closed enum (the `@type` specs already say so — two mappers
  for one enum would just be the same clause list split in half for no semantic reason),
- `outcome_from_session/1` is only ever reached (line 336, line 371) after a guard that
  already restricts `fv(session, "status")` to `["submitted", "auto_submitted",
  "grading_pending"]` — the `"in_progress"` clause is simply unreachable from that call
  site, which is harmless (dead clause from one caller's perspective, live from the
  other's), not a correctness problem,
- one mapper is one place to update if the enum ever grows (matching how
  `question_type_atom/1` is already the single mapper for its own five-value enum,
  shared across its three call sites at lines 640/780).

## 2. Scope: BOTH call sites, not just the one ISS-0631 names literally

ISS-0631's own acceptance criteria (per ISSUE-FIXER's report, verbatim): "session.ex no
longer calls `String.to_existing_atom` or `String.to_atom` on any persisted session
status string." Read literally, "any persisted session status string" is not scoped to
one function — it is scoped to the *value* (the status string read off the `session`
entity), and that value is read via `String.to_existing_atom` at exactly two call sites,
lines 865 and 911. A fix that only touches line 911 would leave the acceptance criterion
literally false: `String.to_atom`/`String.to_existing_atom` would still be called, at
line 865, on that same persisted status string.

Beyond the literal text, leaving line 865 alone would also be inconsistent with the
issue's own audit finding: `outcome_from_session/1`'s current safety is exactly the
fragile, accidental kind ISSUE-FIXER flagged and *recommended* fixing in the same pass,
precisely so a
later removal of one of the three anchor literals (`:auto_submitted` at line 376,
`:submitted` at line 336/743, `:grading_pending` at line 336/873) can't silently
reintroduce this exact bug in the other call site. Fixing only one call site would leave
that recommendation unaddressed for no scope-discipline reason — this is not a case of
"the fix does more than the issue asked and risks scope creep," it's the same one-line
root cause (an implicit-load-order-dependent atom conversion on the same field) appearing
twice.

**Decision: replace both call sites.**
- Line 911 (`session_view/1`): `status: session_status_atom(fv(session, "status"))`
- Line 865 (`outcome_from_session/1`): `status = session_status_atom(fv(session, "status"))`

No other behavior in either function changes. `outcome_from_session/1`'s existing
comment above it (line 862–863, the moduledoc's "second flagged gap") is unaffected and
stays as-is — it concerns raw-sum reconstruction, an unrelated topic.

## 3. Error shape for an unexpected/corrupted status string: no catch-all, `FunctionClauseError` propagates uncaught

Per ISS-0631's acceptance criterion: "a test proves an unexpected/corrupted status
string produces a clear, explicit error rather than an opaque `ArgumentError`."

I checked how the existing idiom's two mappers are actually called today, to decide
whether "clear, explicit" requires new catch/rewrap machinery or whether the bare
idiom already satisfies it:

- `question_type_atom/1` is called at line 640 (`check_answer_shape/2`, inside the
  `autosave_answer/4` `with`-chain) and line 780 (`build_question_row/2`, inside
  `score_and_persist/3`'s pipeline). Neither caller wraps the call in `try`/`rescue`,
  nor does anything upstream of them (`autosave_answer/4`, `submit/3`,
  `finalize_expired/3`) — a non-matching `type` string propagates
  `FunctionClauseError` all the way out uncaught.
- `polarity_atom/1` is called at line 791, same pipeline, same absence of any rescue.

So the existing idiom's "clear, explicit error" already **is** an uncaught
`FunctionClauseError` — this project has already decided, at REQ-332 implementation
time, that letting it propagate is the correct behavior for this exact class of
mismatch (an internally-inconsistent persisted string that should never occur if the
rest of the system is behaving correctly), not something to catch and downgrade to a
tagged `{:error, ...}` return that callers would need a new branch to handle.

**Decision: replicate the idiom exactly — no catch-all clause for
`session_status_atom/1`, `FunctionClauseError` propagates uncaught at both call
sites.** Reasoning for why this satisfies "clear, explicit" without extra machinery:
- `FunctionClauseError`'s message names the exact function, arity, module, and the
  literal argument value that failed to match (e.g. `no function clause matching in
  Letflow.Exam.Session.session_status_atom/1` with the bad string shown in the
  argument list) — strictly more diagnosable than `to_existing_atom/1`'s bare
  `ArgumentError`, which does not name the call site or module at all in its top-line
  message.
- Introducing a bespoke exception or an `{:error, :invalid_status}` tuple here would be
  a **second, inconsistent** error idiom sitting three lines away from
  `question_type_atom/1`/`polarity_atom/1`'s established one, for a caller-visibility
  question the issue doesn't actually raise (nothing asks for `session_view/1` or
  `outcome_from_session/1` to return `{:error, _}` on a corrupted status — every one of
  their callers, `get_session_for_user/3`, `submit/3`, `finalize_expired/3`, treats a
  successfully-read session row as a should-always-succeed conversion, same as it does
  for `question_type_atom/1` today).
- A corrupted status string reaching this function at all means either the entity
  definition's own enum constraint was bypassed (a store-level bug elsewhere) or a
  future edit narrowed/renamed a status value without updating this mapper — both are
  programmer errors this module cannot recover from meaningfully; crashing loudly
  (raising, so a supervisor/caller boundary sees the failure and logs a stacktrace
  naming this exact clause) is the right behavior, not swallowing it into a value
  the caller might treat as a normal `{:error, _}` outcome.

No new code around `session_status_atom/1`'s call sites is needed beyond the
substitution itself — no `try`/`rescue`, no wrapping.

## 4. Test design guidance (for TEST-DESIGNER — no test code in this doc)

Two of ISS-0631's acceptance criteria need care because a literal reading of one of them
("prove `Session.create/3` succeeds even when `:in_progress` has never been referenced
as an executed atom literal anywhere else in the running node... asserting the fix does
not rely on load order") describes a runtime property that **cannot be honestly proven
by a normal ExUnit test running inside the shared test node** — every other test file in
the suite that touches session status runs in the same BEAM instance and will have
already interned `:in_progress` (and the other three atoms) as a side effect of running
earlier, regardless of whether this fix is correct or not. A test that merely calls
`create/3` and passes cannot distinguish "the fix removed the load-order dependency"
from "the atom happened to already be interned by an earlier test in the same run" —
both look identical from inside a single node. Spawning a genuinely fresh, isolated BEAM
node per test (`:peer`/`:slave`) to get a truly empty atom table is disproportionate
here: `create/3`'s transitive dependencies (`Repo`, `Ecto`, `TenantProvisioning`,
`Letflow.Exam.QuestionSetResolver`, `Letflow.Exam.Scoring`) would all need to be started
fresh in that node too, for a property this fix already eliminates structurally rather
than probabilistically.

**Recommended test design — two complementary tests, each honest about what it proves:**

1. **Functional/behavioral test** (proves the fix doesn't break the happy path): call
   `Letflow.Exam.Session.create/3` (or `create_with_seed/4` for a seeded, reproducible
   variant) under normal test setup and assert the returned `session_view().status ==
   :in_progress`. This is a regression test for correctness, not by itself proof of the
   load-order claim — state that limitation in the test's own comment rather than
   overclaiming what it demonstrates.

2. **Structural/static test** (the only test that can *honestly* prove "does not rely on
   load order," since that is now a structural property of the source, not a runtime
   one): read `lib/letflow/exam/session.ex`'s own source text (e.g.
   `File.read!(Path.join([Application.app_dir(:letflow, "priv"), ...]))` — actually,
   simplest is `File.read!("lib/letflow/exam/session.ex")` relative to the project root,
   or via `__ENV__.file` from a test living in the same repo) and assert it contains
   neither the literal substring `"to_existing_atom"` nor `"to_atom("`. This directly
   proves the structural change (no such call exists anywhere in the module any more),
   which is *why* the load-order dependency is gone — a stronger, more honest claim
   than any runtime test making a probabilistic argument from atom-table state it
   cannot control or observe from inside the same node. Document in the test's own
   comment exactly this reasoning, so a future reader doesn't mistake it for an
   arbitrary style-lint test.

3. **Error-shape test** (covers acceptance criterion 3, §3 above): call
   `session_status_atom/1` — or, since it's private, exercise it through a public entry
   point with a corrupted persisted status (e.g. seed a `session` entity row with
   `"status" => "not_a_real_status"` directly via `Letflow.Entities.Records.create_record/2`
   in the test, bypassing any application-level validation, then call
   `get_session_for_user/3` or `submit/3` against it) and assert the call raises
   `FunctionClauseError` (via `assert_raise FunctionClauseError, fn -> ... end`) — NOT
   `ArgumentError`. Asserting the specific exception module is what makes this test
   actually distinguish "fixed" from "still calls `to_existing_atom`" (both would crash
   on a bad string; only the fixed version crashes with `FunctionClauseError` instead of
   `ArgumentError`).

4. **Enum-coverage test** (basic mapper correctness, cheap to add): one test exercising
   all four legitimate values end-to-end (`"in_progress"`, `"submitted"`,
   `"auto_submitted"`, `"grading_pending"`) through `session_view/1`'s or
   `outcome_from_session/1`'s public callers, asserting each maps to the expected atom.
   Existing REQ-332 tests may already cover most of these incidentally through
   `create/3`/`submit/3`/`finalize_expired/3` — TEST-DESIGNER should check for overlap
   before adding duplicate coverage, but the `"grading_pending"` value (no code path
   currently sets it via `update_session_after_submit/4`, since no grading-pending
   producer exists yet per the moduledoc) likely needs a directly-seeded row, same
   technique as test 3.

## 5. Invariants preserved

- No change to the `session` entity's persisted schema, its JSON definition, or the
  four-value status enum itself.
- No change to `@type session_view`/`submission_outcome` — both specs already listed
  exactly these four/three atoms; this fix makes the runtime conversion match what the
  specs already promised, rather than changing the promise.
- No change to REQ-045/decision-0022's "no per-session process" invariant — this is a
  pure private-function refactor within the same plain module.
- `outcome_from_session/1`'s existing "raw sums reconstructed, not replayed" flagged gap
  (moduledoc, lines 90–100) is untouched.

## 6. Open questions

None. This fix is self-contained: one new private function, two call-site
substitutions, no new persisted data, no new public API, no interaction with the
still-open `:not_assigned`/`exam_assignment` gap or the raw-sums gap documented
elsewhere in this module's moduledoc.
