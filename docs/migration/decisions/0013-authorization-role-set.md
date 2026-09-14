# 0013 — The authorization role set is five roles; the realm gains `PROCESS_OPERATOR`

Status: decided (2026-08-22). Owner: ELIXIR-DEV.

## Question

Three places in this system name a set of roles, and they do not agree:

| Source | Role set |
|---|---|
| `Letflow.Api.Authorization` (REQ-069, `done`) | `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, **`PROCESS_OPERATOR`**, `TASK_WORKER`, `AGENT_RUNNER` |
| R-Co's dev realm fixture, `infrastructure/keycloak/realms/bpm-default.json` | `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `TASK_WORKER`, `AGENT_RUNNER` — **no `PROCESS_OPERATOR`** |
| `web/src/components/layout/AppShell.tsx` nav gating | `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, **`PROCESS_OPERATOR`**, `TASK_WORKER` |

The SPA gates four nav entries — Instances, My Tasks, DLQ, Webhooks — on a role
that the realm cannot issue. R-Co worked around this in the same file by seeding
its `operator-user` with `PLATFORM_ADMIN` instead.

So: does Letflow reconcile *downward* (drop `PROCESS_OPERATOR` from the matrix
and the SPA, matching the realm), or *upward* (add the role to the realm)?

## Decision

**Upward. The five-role matrix in `Letflow.Api.Authorization` is the contract.
Every realm Letflow authenticates against must define all five roles, including
`PROCESS_OPERATOR`.** Nothing is reconciled downward; no role is removed from the
matrix or from the SPA's nav gating.

## Reasoning

This looked like a design question and turned out to be a defect. The evidence
decides it:

PROVENANCE (historical, not current decision authority):
**R-Co's own backend defines the role.** `src/api/authorization.zig` declares
`PROCESS_OPERATOR` in its `Role` enum, and the identifier appears **48 times**
across `src/` — including a full permission arm (`.PROCESS_OPERATOR => switch
(permission)`, line 197), a guard clause at line 145, and named tests such as
`TC-IDN-03-02: TASK_WORKER + PROCESS_OPERATOR can cancel instances`. The role is
load-bearing in the source Letflow ported from. `src/api/middleware/auth.zig`
maps the string `"PROCESS_OPERATOR"` onto it during claim parsing, so R-Co's
backend is built to *receive* the role from a token.

**REQ-069 ported it correctly.** `Letflow.Api.Authorization` is a faithful port
of a 281-line module. The five-role set is not an invention to be trimmed — it
is the thing the port was gated on.

PROVENANCE (historical, not current decision authority):
**The realm file is the odd one out, and it is a dev fixture.**
`bpm-default.json` is 175 lines of local bootstrap data, imported by
`start-dev --import-realm`. It is not a specification of the platform's role
model, and it was never validated against `authorization.zig` — which is
precisely how it came to omit a role the backend has 48 references to. The
`operator-user` seeded with `PLATFORM_ADMIN` is the tell: someone needed an
operator account, found the role missing, and granted admin instead of fixing
the fixture.

**Reconciling downward would silently widen privilege.** That workaround is not
cosmetic. Under it, an account named for the operator role holds full platform
administration — every admin route, every tenant. Copying the fixture into
Letflow unexamined would import a privilege escalation as a seed value, and it
would look intentional because it is checked in. Deleting `PROCESS_OPERATOR`
from the matrix instead would make that permanent: the four nav entries gated on
it would have to be regranted to some other role, and the only role that
currently covers them is `PLATFORM_ADMIN`.

**The cost is asymmetric.** Adding a role to a realm is a JSON entry. Removing a
role from an authorization matrix means re-deriving every permission arm it
appears in, changing the SPA's gating, and diverging from the R-Co contract that
S7's parity work will eventually be measured against.

## Consequences

- Letflow's realm configuration defines five realm roles. `REQ-128` creates it
  that way from the start rather than importing R-Co's file and patching it.
- The seeded operator account holds `PROCESS_OPERATOR`, **not** `PLATFORM_ADMIN`.
  Carrying R-Co's grant across would defeat the point of this record.
- `REQ-129` verifies the three sources agree, and adds a check that fails if they
  drift again. A mismatch between an authorization matrix and an identity
  provider's issuable roles is invisible at compile time in both languages and
  silent at runtime — the role simply never appears in a token — so it needs a
  test, not a convention.
- `AGENT_RUNNER` stays in the matrix and stays absent from the SPA's nav, which
  is correct and not part of this drift: it is a machine role for the deferred
  runtime-agent subsystem, and `Api.Authorization`'s moduledoc already records it
  as ported-but-unreachable. It should exist in the realm for the same reason it
  exists in the matrix — so the port stays faithful — but no human user is seeded
  with it.
- This record does **not** settle how roles map to Keycloak *groups*, or whether
  tenant-scoped roles (`Letflow.Identity.TenantRole`) ever feed the same matrix.
  `RoleRegistry`'s moduledoc is explicit that it has no coupling to the
  OIDC/claim-mapping pipeline; that separation is untouched here.

## Note on numbering

`REQ-123` (drafted 2026-08-21) reserved `0013-cutover-strategy.md` for S8's
cutover decision, which cannot be written until S7 produces a correctness signal.
This record took `0013` because it is being decided now; `REQ-123` was updated in
the same commit to name `0014-cutover-strategy.md`. Decision records are numbered
in the order they are actually decided, not the order they are anticipated.

## Addendum (2026-09-14, `CODE-DESIGNER`, ISS-0646) — the role set grows to six: `CANDIDATE`

### Question

REQ-335 minted five exam-session permissions
(`ExamSessionStart`/`ExamSessionRead`/`ExamSessionSave`/`ExamSessionSubmit`/
`ExamSessionReportEvent`) and granted them to `TASK_WORKER`, because this
record's five-role matrix had no role for an external exam candidate and
minting one was out of REQ-335's own scope (see
`lib/letflow/api/authorization.ex`'s "ExamSession*" moduledoc section and
`lib/letflow/routers/exam_sessions.ex`'s own moduledoc, both written at the
time as an explicit, non-blocking tradeoff). `TASK_WORKER` is this matrix's
only ordinary-tenant-user role, so gating exam routes to it was the only
option available without a stealth role decision — but it conflates two
distinct actor classes: an internal staff task-worker and an external exam
candidate now share one role, and the candidate implicitly inherits
`TASK_WORKER`'s other grants (`TasksRead`, `TasksComplete`,
`EntitiesQuery`, `EntitiesAggregate`, `AttachmentsRead`,
`EntitiesDefinitionsRead`) that have nothing to do with sitting an exam.
ISS-0646 asks this record to settle, by name, whether that conflation is
accepted as a deliberate interim tradeoff (with an exit condition) or
closed by adding a sixth role.

**Is a sixth role even buildable given how this platform actually
provisions users and roles, or would it be a premature, unbuildable
mechanism?** Re-verified directly before deciding:

- There is no tenant self-registration anywhere in this codebase (grepped;
  the only account-creation and role-assignment surfaces are
  `POST /users` — `UsersGroupsRolesManage`, `PLATFORM_ADMIN`-only via the
  catch-all clause — and `POST /tokens` — `TokensManage`,
  `PLATFORM_ADMIN`-only). Every account, staff or candidate, is
  provisioned by an admin today; a candidate is not a different
  provisioning *mechanism* from a task worker, only a different *role
  value* an admin assigns through the same mechanism.
- `Letflow.Identity.RoleRegistry`/`TenantRole` (`POST`/`GET /roles`) is a
  **separate, uncoupled** system — named custom roles bound to a group,
  with no feed into `Letflow.Api.Authorization`'s closed enum (this
  record's own Consequences section already states this separation).
  Adding a role to this matrix has nothing to do with that registry.
- `Letflow.Routers.Identity`'s `POST /tokens` handler
  (`handle_create_token/2`) already validates an arbitrary `roles` array
  against `Letflow.Api.Authorization`'s closed enum
  (`Identity.create_token/3` returns `{:error, :invalid_role_set}` for
  anything outside it) and mints a bearer token carrying exactly the roles
  the `PLATFORM_ADMIN` caller names. **An admin can issue a `CANDIDATE`
  token to any `user_id` the moment the atom exists in the enum — no new
  route, no new Keycloak realm change, is *required* for that path to
  work.**
- `priv/keycloak/realms/bpm-default.json`'s `roles.realm` list (the actual
  OIDC path) is exactly the five role names, one seeded user per role,
  confirmed by direct read. `test/letflow/api/authorization_role_realm_test.exs`
  (REQ-129) proves the realm file and `Authorization.roles/0` stay in
  lockstep, and **its own failure message already anticipates this exact
  situation**, quoted verbatim: *"Do not resolve this by editing this
  test — fix whichever source is wrong, or write a new decision record if
  the role set itself is changing."* This addendum is that decision
  record.
- `web/src/components/layout/AppShell.tsx`'s nav-gating `Role` type is
  already a *narrower* union than the matrix (`PLATFORM_ADMIN` /
  `PROCESS_DESIGNER` / `PROCESS_OPERATOR` / `TASK_WORKER` — no
  `AGENT_RUNNER`), and REQ-338's candidate pages
  (`web/src/pages/exam/ExamListPage.tsx`, `ExamSessionPage.tsx`, grepped
  directly) contain no role check of any kind — they call the
  exam-session API and let the server decide. Adding `CANDIDATE` requires
  **zero frontend changes**: a candidate-only token simply matches none of
  `AppShell`'s nav-gated roles, the same posture `AGENT_RUNNER` already
  has, and the exam pages don't branch on role at all.

Conclusion on buildability: **a sixth role is cheap and mechanical here,
for the same reason 0013's original body already argued adding a role to a
realm is cheap** — this platform's admin-provisions-everything model means
"issuing a role to an actor" is already a single generic mechanism
(`POST /tokens` roles array, or a realm-role grant), not a bespoke
onboarding flow that would need to be built per role. This is a materially
different (and easier) case than 0013's original PROCESS_OPERATOR
question, which was about reconciling three sources that had drifted; here
there is no drift to reconcile, only one enum, one realm file and one SPA
type to extend, each by one line/entry.

### Decision

**Direction (a). Add a sixth role, `CANDIDATE`, to `Letflow.Api.Authorization`'s
closed enum. `CANDIDATE` is granted exactly REQ-335's five
`ExamSession*` permissions and nothing else. `TASK_WORKER` loses all five
`ExamSession*` grants — a candidate sitting an exam is no longer
`TASK_WORKER` at all.** No other role gains or loses anything.
`PLATFORM_ADMIN`'s existing catch-all continues to cover an operator who
needs to probe a session, exactly as `Letflow.Api.Authorization`'s
pre-addendum moduledoc already described for `PROCESS_DESIGNER`/
`PROCESS_OPERATOR`'s deliberate exclusion.

This is a genuine matrix change, not a reconciliation, so it does **not**
retroactively invalidate this record's original "five roles" holding —
it supersedes it. Read this addendum, not the body above it, for the
current role count; the body above stays as the historical record of why
`PROCESS_OPERATOR` was five/five (not six) at the time it was decided.

Direction (b) (keep `TASK_WORKER`, write an accepted-risk exit condition)
was considered and rejected: ISS-0646's own related, more concrete finding
(ISS-0647 — a candidate can read `question.is_correct` via the generic
`POST /entities/query` route because `TASK_WORKER` already holds
`EntitiesQuery`) is not a hypothetical this record can wave off with an
exit condition — it is a live, exploitable-today confusion between two
actor classes that direction (a) closes as a structural side effect
(`CANDIDATE` never holds `EntitiesQuery`, so the bypass path does not
exist for a candidate holding only `CANDIDATE`). An exit-condition
addendum would leave that gap open until whatever future event the exit
condition names; adding the role closes it now, at a cost this record's
buildability analysis above shows is small.

### Spec for ELIXIR-DEV

See `lib/letflow/design/iss0646-candidate-role.md` for the full
signature-level design (enum/matrix changes, realm file, existing-token
handling). Summary: this is an additive, mechanical change to
`Letflow.Api.Authorization` (new `role/0` member, new `role_from_string/1`
clause, new `role_allows?/2` clause, five permissions removed from
`TASK_WORKER`'s existing clause), `priv/keycloak/realms/bpm-default.json`
(one realm role entry, one seeded `candidate-user`), and the two
moduledocs (`Letflow.Api.Authorization`, `Letflow.Routers.ExamSessions`)
that currently describe the `TASK_WORKER` tradeoff and must be corrected
to describe `CANDIDATE` instead. No route, no migration, no schema change.

### Consequences

- `Letflow.Api.Authorization.roles/0` returns six atoms, not five, from
  this addendum forward. Every place that hardcodes "five roles" or
  enumerates the role list by name (this record's own body, `REQ-129`'s
  test failure message, any other decision record or design doc that
  quotes the five-role set) is describing a historical count as of
  2026-08-22 through 2026-09-14, not the current one.
- `priv/keycloak/realms/bpm-default.json` must add `CANDIDATE` to
  `roles.realm` and MAY seed a `candidate-user` fixture (not required for
  `authorization_role_realm_test.exs` to pass — that test only checks the
  realm-role *list*, not seeded users — but useful for manual/UAT
  verification of the exam vertical).
- Any exam-candidate account provisioned before this addendum (via
  `TASK_WORKER`, in a dev/test/UAT context — there is no production
  deployment yet, per this project's own operating rules) is not migrated
  by this record; re-provisioning such accounts with `CANDIDATE` instead
  is an operational follow-up, not a code change, and is explicitly out of
  this addendum's scope.
- ISS-0647 (the `EntitiesQuery`/`is_correct` bypass) is expected to close
  as a side effect once `CANDIDATE` no longer holds `EntitiesQuery`, but
  this addendum does not itself resolve ISS-0647 — that issue's own gate
  (SECURITY-REVIEWER) must independently re-verify the bypass is closed
  once the matrix change lands, rather than taking this addendum's
  prediction on trust.
- `REQ-129`'s parity test (`authorization_role_realm_test.exs`) needs no
  code change — it is generic over `Authorization.roles/0` and the realm
  file's contents — but it WILL fail until both sides add `CANDIDATE`
  together, exactly as its own failure message anticipates.

### What this addendum does not decide

- Whether `CANDIDATE` should ever gain permissions beyond the five
  `ExamSession*` atoms (e.g. a future results-history view, REQ-339's
  named `GetExamHistory`/`HandleGetMyResults` gap) — left to whichever
  future requirement builds that surface, to decide against this
  addendum's "exactly five, nothing else" starting grant.
  `role_allows?(:CANDIDATE, _)` must not be widened by that requirement
  merely by analogy to this decision.
- Whether a real IdP deployment issues `CANDIDATE` through a different
  flow than the admin-driven `POST /tokens`/Keycloak-realm-role path
  analyzed above (e.g. a future self-service exam-registration flow) —
  no such flow exists in this codebase today, and none is proposed here.
- The `exam_assignment` no-op gap (REQ-330/REQ-332/REQ-338's own tracked
  open question, per REQ-339) — unrelated to which role reaches the exam
  routes; `CANDIDATE` changes *who may call* the exam-session routes, not
  *which exams a given candidate is eligible for*, which stays governed by
  `Letflow.Exam.Session`'s own (currently no-op) assignment check.

### SECURITY-REVIEWER sign-off

PENDING.

### REVIEWER sign-off

PENDING.
