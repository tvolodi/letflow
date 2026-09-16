# ISS-0694 fix design — `web/src/config/__tests__/bilimbagaEntities.test.ts`

Rework (attempt 2 of 3). Supersedes the prior report-only design; this file is the
complete design CODE-DESIGN-VALIDATOR should gate against — no need to consult the
prior attempt.

## Root cause (unchanged, confirmed correct by validator)

`web/src/config/__tests__/bilimbagaEntities.test.ts`'s exclusion set
(`RUNTIME_STATE_ENTITY_TYPES`) was written to describe exactly one reason an entity
type is legitimately absent from `BILIMBAGA_ENTITY_TYPES`: it is a runtime-state type
written by the exam-session engine, never authored through an admin CRUD screen. That
was true for all 5 excluded types at the time (`session`, `session_answer`,
`session_event`, `session_question`, `session_question_score`).

REQ-355 added a 16th pack entity-definition file, `certificate.json`,
whose own description states plainly: "this is a declarative record shape with no
execution semantics of its own" (Bucket A, same reasoning as the session types) — but
`certificate` is excluded from admin management for a *different* reason than the
session types. Per `lib/letflow/exam/certificate.ex`'s moduledoc (guard-order note,
point 1, "Ownership, unless admin"): "REQ-355's own scope fence is 'an authenticated
route by which a candidate requests issuance for their own session,' not an admin
route, so there is no caller today that could ever pass `is_admin: true`... Adding an
admin bypass is future work for whichever requirement [picks it up]." I.e. `certificate`
is not written by a runtime engine process the way `session*` rows are — it is written
by `Letflow.Exam.Certificate`'s idempotent issue-on-first-request context-module logic,
triggered by a candidate's own action — but there is deliberately no admin-authoring
route for it either, and that deferral is REQ-355's own explicit scope decision, not an
architectural "runtime-state" fact.

The test's exclusion set and its prose currently only account for reason (a). Fixing
the test to pass (`certificate` correctly absent from `BILIMBAGA_ENTITY_TYPES`) requires
broadening the set and its prose to name reason (b) as well, without misrepresenting
either.

## Fix

All changes confined to
`web/src/config/__tests__/bilimbagaEntities.test.ts`. No change to
`web/src/config/bilimbagaEntities.ts` (REQ-355's admin-route deferral stands; this fix
does not add an admin screen for `certificate`).

### 1. Rename identifier, everywhere it occurs

`RUNTIME_STATE_ENTITY_TYPES` → `NO_ADMIN_AUTHORING_ENTITY_TYPES`, at every occurrence:
- the `const` declaration (current line 33)
- current line 54 (`for (const runtimeType of RUNTIME_STATE_ENTITY_TYPES)`) — also
  rename the loop variable `runtimeType` → `excludedType` for consistency with the new,
  broader meaning (it's no longer only runtime-state types being iterated)
- current line 55 (`expect(allTypes).toContain(runtimeType)`) → use the renamed loop
  variable
- current line 61 (`(t) => !RUNTIME_STATE_ENTITY_TYPES.has(t)`)
- current line 72 (`expect(RUNTIME_STATE_ENTITY_TYPES.has(entityType)).toBe(false)`)

No other identifier in the file references the old name.

### 2. Add `'certificate'` to the set's members

```
const NO_ADMIN_AUTHORING_ENTITY_TYPES = new Set([
  'session',
  'session_answer',
  'session_event',
  'session_question',
  'session_question_score',
  'certificate',
])
```

Verified: pack directory has 16 `.json` entity-definition files (per validator's prior
confirmation); 16 − 5 session-family − 1 certificate = 10 = current
`BILIMBAGA_ENTITY_TYPES.length`. This makes the currently-failing assertion (`every
admin-manageable pack entity type has a BILIMBAGA_ENTITY_TYPES entry` /
`BILIMBAGA_ENTITY_TYPES declares no runtime-state type and no type absent from the
pack`) pass, since `certificate` is now excluded from the "admin-manageable" set the
test computes instead of being wrongly expected to have an admin entry.

### 3. Exact replacement text for both prose locations (the gap this rework closes)

Both current wordings are exhaustive/closed ("the pack's runtime-state entity types
(session and its four session_* satellites)" / "Runtime-state entity types") and become
factually wrong once `certificate` — not runtime-state, not engine-written — joins the
set for an unrelated reason. Replace both, verbatim, as follows.

**Location A — file-level header comment, current lines 12–21** (the whole paragraph
starting "This test reads the real pack directory..."). Replace lines 12–21 in full
with:

```
 * This test reads the real pack directory on disk (not a hard-coded
 * mirror of it) and asserts every ADMIN-MANAGEABLE entity type there has a
 * corresponding BILIMBAGA_ENTITY_TYPES entry, so the two lists cannot
 * silently diverge again. "Admin-manageable" excludes pack entity types that
 * have no admin-authoring path, for either of two distinct reasons: (a)
 * runtime-state types (session and its four session_* satellites), written
 * by the exam-session engine at runtime, not authored through an admin CRUD
 * screen -- there is deliberately no admin screen for any of them; and (b)
 * other pack entity types that are declarative, system-written records with
 * no admin-authoring path by their own requirement's explicit scope
 * decision rather than by architectural necessity -- currently just
 * `certificate` (REQ-355): per certificate.json's own description this is a
 * "declarative record shape with no execution semantics of its own," issued
 * by `Letflow.Exam.Certificate`'s idempotent issue-on-first-request logic
 * triggered by a candidate's own action (not the session engine), and
 * lib/letflow/exam/certificate.ex's moduledoc states plainly that an admin
 * bypass/route "is future work for whichever requirement" picks it up --
 * i.e. deferred, not ruled out. Neither type family is expected to appear
 * in BILIMBAGA_ENTITY_TYPES.
 */
```

(This keeps the file's existing block-comment style — each line starting ` * ` — and
the closing ` */` on its own line, matching current line 21.)

**Location B — inline comment immediately above the `const` declaration, current lines
30–32.** Replace lines 30–32 in full with:

```
// Entity types with no admin-authoring path, for two distinct reasons:
// (a) runtime-state types written by lib/letflow/exam/session.ex's engine as
// a session progresses (session and its four session_* satellites); and
// (b) certificate (REQ-355) -- a declarative, system-written record (see
// certificate.json's description) issued by lib/letflow/exam/certificate.ex
// on a candidate's own request, not the session engine, but with its own
// admin-authoring route deliberately deferred rather than architecturally
// impossible (see that module's moduledoc, guard-order note 1). Both
// families are deliberately excluded from admin-manageable coverage.
```

### 4. No other file changes

`web/src/config/bilimbagaEntities.ts` is untouched — this fix does not add an admin
route/screen for `certificate`; REQ-355's own scope fence (candidate-facing issuance
route only, admin bypass explicitly future work) stands as-is. Test file name, describe
block title, and the four `it(...)` block titles are unchanged (their wording already
says "admin-manageable pack entity type," which remains accurate under the broadened
exclusion set).

## Acceptance criteria mapping

- ISS-0694's failing assertion (`certificate` missing an admin entry) → fixed by adding
  `'certificate'` to `NO_ADMIN_AUTHORING_ENTITY_TYPES` (§2), so `certificate` is
  correctly excluded from the "admin-manageable" set the test computes, rather than
  wrongly expected to appear in `BILIMBAGA_ENTITY_TYPES`.
- No change to REQ-355's admin-route-deferral decision → confirmed; `bilimbagaEntities.ts`
  untouched (§4).
- Exclusion-set naming/rationale must stay factually accurate once `certificate` joins
  for a reason distinct from the session types → renamed identifier (§1) plus exact
  replacement prose at both locations (§3), naming both exclusion reasons explicitly and
  citing their sources (`certificate.json`'s description, `certificate.ex`'s moduledoc).

## Open questions

None. Every prose location needing new wording has exact replacement text above; no
"as needed" or deferred judgment calls remain.
