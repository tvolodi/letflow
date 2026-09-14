# ISS-0646 — Introduce `CANDIDATE`, a sixth `Letflow.Api.Authorization` role

Design only. No implementation code below — signatures, enum members,
matrix membership and file-level diffs described in prose, per
CODE-DESIGNER's own scope fence. Backing decision:
`docs/migration/decisions/0013-authorization-role-set.md`'s 2026-09-14
addendum (ISS-0646). Read that addendum first for the *why*; this document
is the *what*, precise enough for ELIXIR-DEV to implement without
re-deriving the decision.

## 1. Scope

In scope:

- `lib/letflow/api/authorization.ex` — add `:CANDIDATE` to `role/0` and
  `@roles`, add a `role_from_string/1` clause, add a `role_allows?/2`
  clause, remove the five `ExamSession*` permissions from `TASK_WORKER`'s
  `role_allows?/2` clause, update the moduledoc's "ExamSession*" section.
- `lib/letflow/routers/exam_sessions.ex` — update the moduledoc's
  "Permission vocabulary" section (the `TASK_WORKER` tradeoff prose is now
  wrong and must describe `CANDIDATE` instead). No route/handler code
  changes — `authz_post`/`authz_get`/`authz_put` macros take a policy-key
  atom, not a role, so nothing about the route declarations themselves
  changes.
- `priv/keycloak/realms/bpm-default.json` — add `{ "name": "CANDIDATE" }`
  to `roles.realm`. Optionally add a seeded `candidate-user` (see §5).
- **Correction (post-CODE-DESIGN-VALIDATOR FAIL):** the previous version of
  this bullet named `test/letflow/api/authorization_test.exs` and
  `test/letflow/api/authorization_ac9_test.exs` as holding "the
  `TASK_WORKER`-grants-`ExamSession*` assertions." That was wrong — neither
  file contains such an assertion. `authorization_test.exs`'s only
  `ExamSession*` references are in its `permissions/0` full-enumeration
  test (asserts the five `ExamSession*` atoms exist as permissions at all —
  unaffected by this design, since the permission atoms themselves don't
  move, only which role grants them). `authorization_ac9_test.exs` has no
  `ExamSession*`/`TASK_WORKER`/`CANDIDATE` reference whatsoever. Corrected
  scope, verified by direct read of every candidate file plus a full-suite
  grep for `TASK_WORKER`/`candidate`/`ExamSession`:

  - `test/letflow/api/authorization_test.exs` — one real, narrower change:
    the "`roles/0` returns exactly R-Co's five Role values" test (currently
    asserting the closed five-element list) must become a six-element list
    ending `:CANDIDATE`, matching §2's `roles/0` change. This is the only
    change this file needs; do not touch its `permissions/0` test or any
    `TASK_WORKER`-specific `role_allows?/2` test (none reference
    `ExamSession*`).
  - `test/letflow/api/authorization_ac9_test.exs` — **no change**. Removed
    from scope entirely; it has no `TASK_WORKER`/`CANDIDATE`/`ExamSession*`
    reference to fix.
  - **`test/letflow/routers/exam_sessions_test.exs` — the actual
    load-bearing file, omitted entirely from the prior pass.** This is
    REQ-335's functional/integration suite for the `ExamSessions` router,
    and every test in it that exercises a candidate-role happy path mints
    its token via a private helper that grants `TASK_WORKER`, not
    `CANDIDATE`:
    - Line 93: `defp candidate_ctx(tenant), do: user_ctx(tenant,
      ["TASK_WORKER"])`. **ELIXIR-DEV: change this line's literal to
      `["CANDIDATE"]`.** Do not rename the helper itself (`candidate_ctx/1`
      already names the concept correctly, independent of which role
      backs it) and do not touch any of its call sites — changing the
      helper's one-line body is sufficient because every call site already
      goes through it. (Rejected alternative: adding a second, differently
      named helper and migrating call sites one by one — strictly more
      edits for the same result, since every existing call site already
      wants the new role.)
    - Call sites needing no edit of their own (they inherit the fix via
      `candidate_ctx/1`): lines 212, 263, 281, 314, 336, 369, 405-406,
      492-493, 521.
    - Line 518: `test "TASK_WORKER (the candidate role) can start a
      session" do`. **ELIXIR-DEV: rename this test's title** to `"CANDIDATE
      (the candidate role) can start a session"` (or equally clear
      phrasing — the substance is the title must no longer claim
      `TASK_WORKER` is the candidate role). No assertion-body change is
      needed beyond what `candidate_ctx/1`'s fix already produces (the
      test calls `candidate_ctx(tenant)` at line 521 and asserts `201`,
      which stays correct once that helper mints `CANDIDATE`).
    - Line 509: `test "PROCESS_DESIGNER (no TASK_WORKER, no PLATFORM_ADMIN)
      is forbidden from starting a session" do` — optional, non-load-bearing
      cleanup. The assertion (403) stays correct regardless of this
      rename, but the title's parenthetical now names a role that is no
      longer the relevant contrast. ELIXIR-DEV may update the title to say
      "no CANDIDATE, no PLATFORM_ADMIN" for accuracy; not required for
      correctness, since the test's behavior doesn't change.
  - **Full-suite grep performed for this correction** (patterns:
    `TASK_WORKER`, `candidate` case-insensitive, `candidate_ctx`,
    `user_ctx.*TASK_WORKER`) across all of `test/` — confirms the above is
    now the *complete* list. Other `TASK_WORKER` hits found and confirmed
    unrelated to the candidate-role concept (no code change needed for
    any of them):
    - `test/support/exam_fixtures.ex` line 98 — a comment about
      `TASK_WORKER`-scoped callers reaching the generic
      `POST /entities/query` route via `Letflow.Packs.Bilimbaga`'s
      answer-key field restrictions (ISS-0647). Unrelated: about
      entity-query field redaction, not `ExamSession*` grants; `TASK_WORKER`
      keeps `EntitiesQuery` under this design (§4b only removes the five
      `ExamSession*` entries).
    - `test/letflow/api/authorization_test.exs` (several `TASK_WORKER`
      tests for `TasksComplete`/`InstancesStart`/`TasksList`
      row-scoping/`PLATFORM_ADMIN` combination) — unrelated, no
      `ExamSession*` involved, unaffected by this design.
    - `test/letflow/audit_dispositions_test.exs` line 495 — mints a
      `TASK_WORKER` token for an audit-disposition scenario, unrelated to
      exams.
    - `test/letflow/api/authorization_enforcement_test.exs` lines 68-104 —
      registers `Letflow.Routers.ExamSessions` in the router-walk table
      that checks every route's policy key resolves through
      `Authorization.endpoint_policy_key/2`; asserts nothing about which
      *role* holds the permission, only that the route's declared key
      exists in the matrix. Unaffected by this design (no policy-key
      atoms change, only role grants).
    - `test/letflow/exam/*_test.exs` (`session_test.exs`, `scoring_test.exs`,
      `anti_cheat_test.exs`) — no `TASK_WORKER`/`CANDIDATE`/role-token
      references at all; these test `Letflow.Exam.*` context modules
      directly, never through an HTTP role-gated route.

  This is TEST-DESIGNER's job under the normal pipeline gate for the
  `authorization_test.exs` `roles/0` change; the `exam_sessions_test.exs`
  changes above are functional-regression fixes tied directly to this
  design's `role_allows?/2` change (§4b) and are called out explicitly so
  ELIXIR-DEV makes them in the same change, not as a follow-up discovered
  by a failing test run.

Out of scope (confirmed by direct inspection, see the decision addendum
§"buildability"):

- No change to `web/` — `AppShell.tsx`'s `Role` type and REQ-338's exam
  pages have no `TASK_WORKER`-specific branch tied to exam access.
- No change to `Letflow.Identity.RoleRegistry`/`TenantRole` — uncoupled
  from this enum (0013's own Consequences section).
- No new HTTP route, no migration, no schema change.
- No change to `is_task_worker_only?/1` — `CANDIDATE` is never combined
  with `TASK_WORKER` by this design, and `is_task_worker_only?/1`'s own
  contract (row-scoping `TasksList`) is untouched: a `CANDIDATE`-only
  caller has no `TasksRead` at all, so it never reaches that branch.

## 2. `role/0` and `@roles`

Add `:CANDIDATE` as a sixth member of the `role/0` union type and the
`@roles` list, alongside the existing five. Position: after `:AGENT_RUNNER`
(append-only, matching how `AGENT_RUNNER` itself was appended after the
original four in 0013's own history — do not reorder the existing five).

```
@type role ::
        :PLATFORM_ADMIN
        | :PROCESS_DESIGNER
        | :PROCESS_OPERATOR
        | :TASK_WORKER
        | :AGENT_RUNNER
        | :CANDIDATE
```

`roles/0`'s `@doc` ("All five `Role` values...") must be corrected to "All
six," and its pointer to `roles_from_strings/1` stays accurate unchanged.

## 3. `roles_from_strings/1` / `role_from_string/1`

Add one clause, same shape as the existing five, same position rule
(after the `AGENT_RUNNER` clause, before the catch-all `_other -> nil`):

```
role_from_string("CANDIDATE") :: :CANDIDATE
```

No change to `roles_from_strings/1`'s own body (`Enum.reduce/3` loop) — it
is generic over whatever `role_from_string/1` recognizes. No change to the
"untrusted input" moduledoc section's reasoning; it already generalizes to
six.

## 4. `role_allows?/2`

Two changes to this function, both additive-in-shape (no other clause's
body changes):

**4a. New `:CANDIDATE` clause**, granting exactly REQ-335's five
`ExamSession*` permissions and nothing else:

```
role_allows?(:CANDIDATE, permission) ::
  permission in [
    :ExamSessionStart,
    :ExamSessionRead,
    :ExamSessionSave,
    :ExamSessionSubmit,
    :ExamSessionReportEvent
  ]
```

Position: after the existing `:AGENT_RUNNER` clause (append-only, matching
`role_allows?(:AGENT_RUNNER, _permission) :: false`'s own position as the
last clause today).

**4b. `TASK_WORKER`'s existing clause loses the five `ExamSession*`
entries.** The five-item block currently ending `TASK_WORKER`'s permission
list (with the "REQ-335: TASK_WORKER is this module's only
non-privileged..." comment) is removed in full — both the five atoms and
the comment block explaining why they were there, since that reasoning no
longer applies to `TASK_WORKER`. `TASK_WORKER`'s remaining permissions
(`DefinitionsRead`, `InstancesRead`, `TasksRead`, `TasksComplete`,
`AttachmentsRead`, `EntitiesDefinitionsRead`, `EntitiesQuery`,
`EntitiesAggregate`, `EntitiesAttachmentsRead`) are unchanged.

No change to `PLATFORM_ADMIN` (catch-all already covers `CANDIDATE`'s five
permissions), `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, or `AGENT_RUNNER`'s
clauses.

## 5. `priv/keycloak/realms/bpm-default.json`

Add one entry to `roles.realm`:

```
{ "name": "CANDIDATE" }
```

Position: after `AGENT_RUNNER`, matching `@roles`'s append order (§2).
This is required for `test/letflow/api/authorization_role_realm_test.exs`
(REQ-129) to pass — that test asserts exact-set equality between
`Authorization.roles/0` and this file's `roles.realm` list, so both sides
must change together in the same commit.

Optional (not required by REQ-129's test, which checks only the role
*list*, not seeded users): add a `candidate-user` entry to the `users`
array, same shape as the existing four (`username`, `email`, `firstName`,
`lastName`, `enabled: true`, `emailVerified: true`, `requiredActions: []`,
one `password` credential, `realmRoles: ["CANDIDATE"]`), for manual/UAT
verification of the exam vertical end-to-end against a real Keycloak
instance. If added, follow the existing naming convention exactly
(`candidate-user` / `candidate@letflow.local` / `candidate-pass`).

## 6. Moduledoc corrections

**`lib/letflow/api/authorization.ex`'s "`ExamSession*` (REQ-335)" section**
currently states these permissions are granted to `TASK_WORKER` "because
this module's role set has no dedicated `:CANDIDATE` role." That premise
is now false. Replace the "Unlike every `Entities*` addition above..."
paragraph with prose stating: `CANDIDATE` (added by ISS-0646, see decision
0013's addendum) is a new, dedicated role holding exactly these five
permissions and nothing else; `TASK_WORKER` no longer holds them.
`PROCESS_DESIGNER`/`PROCESS_OPERATOR` continue to not hold them, for the
same reason as before (sitting an exam is not part of either role's grant
shape); `PLATFORM_ADMIN`'s catch-all still covers an operator probing a
session.

**`lib/letflow/routers/exam_sessions.ex`'s "Permission vocabulary" section**
makes the same now-false claim ("there is no dedicated `:CANDIDATE` role
anywhere... minting one is outside a route-surface requirement's scope").
Replace with a pointer to `CANDIDATE`'s real grant (naming
`Letflow.Api.Authorization`'s `role_allows?(:CANDIDATE, ...)` clause) and
drop the "outside scope" framing — it's been resolved. Keep the rest of
that section's reasoning about candidate identity always being
`conn.assigns.auth_context.user_id`, never caller-supplied — that part is
unaffected by which role reaches the route.

## 7. Invariants preserved

- **INV-2** (pure function of `AccessContext`/`endpoint_policy_key`) —
  unaffected; `role_allows?/2` stays a pure pattern match, no new
  parameter.
- **INV-5** (this module never distinguishes "exists, not yours" from
  "never existed") — unaffected; ownership is still enforced entirely
  inside `Letflow.Exam.Session`/`Letflow.Exam.AntiCheat`, never by role.
- **Closed-enum / no-`to_existing_atom`-on-untrusted-input property**
  (moduledoc's "untrusted input" section) — preserved: `CANDIDATE` is
  added the same way every other role was, as a literal
  `role_from_string/1` clause, never via dynamic atom creation.

## 8. Open questions

None left unresolved by this design for the permission-matrix change
itself. Two items are explicitly deferred (named, not silently dropped)
per the decision addendum's own "what this addendum does not decide"
section:

1. Whether `CANDIDATE` ever gains permissions beyond the five
   `ExamSession*` atoms (e.g. a future exam-history view) — a future
   requirement's call, not this one's.
2. Whether/when any pre-addendum `TASK_WORKER`-holding candidate account
   (dev/test/UAT only — no production deployment exists) is re-provisioned
   with `CANDIDATE` — an operational follow-up, not a code change this
   design covers.
