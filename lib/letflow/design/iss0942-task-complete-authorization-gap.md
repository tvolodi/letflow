# ISS-0942 — `POST /tasks/:id/complete` authorization gap (`Letflow.Tasks`, `Letflow.Routers.Tasks`)

PROVENANCE (historical, not current decision authority):
**Issue:** `docs/issues/ISS-0942.yaml` ("D5: claim enforces the assigned role but
complete does not"), `severity: MAJOR`, discovered by UAT-RUNNER in ISS-0912's
re-run (`test/uat-reports/uat-2026-10-01-ISS0912-NARRATIVE.yaml`), filed by ORCH.
**SECURITY-REVIEWER determination (pre-established, not re-diagnosed by this
doc):** a GENUINE security gap, not by-design. `POST /tasks/:id/complete` →
`Letflow.Routers.Tasks.handle_complete/3` → `Letflow.Engine.complete_task/3`
performs **zero** assignee/role/group authorization — it is gated only by the
coarse tenant-wide `:TasksComplete` RBAC permission, which any `TASK_WORKER`
holds regardless of whether they are the task's actual assignee. Live UAT
confirmed the exploit: a non-member actor completed a ROLE-assigned task with
HTTP 200 after getting HTTP 409 on `/claim` for the same task. This was a
documented, explicit S4 deferral (`lib/letflow/design/req048-task-completion.md`
§12, `INV-EE48-10`: "that is the S4 auth plug's job") that was never actually
built once S4 landed. `docs/migration/decisions/0013-authorization-role-set.md`'s
IDN-03 role matrix establishes the intended behavior: `TASK_WORKER` completing a
task assigned to a different user/group/role → HTTP 403.
**Owner (implementer):** `ELIXIR-DEV`. **Gate:** `SECURITY-REVIEWER` is a
MANDATORY hard gate on the implementation of this design — see §7.
**No implementation code below** — signatures, `@spec`-style types, and
precedence logic in prose only, per `lib/letflow/design/req085-task-routes-write.md`'s
own documented rigor.

---

## 0. Sources read for this design

- `docs/issues/ISS-0942.yaml` (full).
- `lib/letflow/tasks.ex`: `resolve_principal_scope/2` (line 338), `claim_task/3`
  (line 412) and its five `apply_claim/5` clauses (lines 432–479), `fetch_and_lock_task/3`
  (line 601), `write_assignment/4` (line 613).
- `lib/letflow/routers/tasks.ex`: `handle_complete/3` (lines 315–329),
  `handle_complete_result/2` clauses (lines 331–369), `handle_claim/3` (lines 373–379),
  `handle_claim_result/3` clauses (lines 381–415) — read side by side to isolate the
  exact structural gap: `handle_claim` runs `Tasks.claim_task/3` (which internally calls
  `resolve_principal_scope/2` + `apply_claim/5`); `handle_complete` runs nothing but
  `Engine.complete_task/3`.
- `lib/letflow/engine.ex`: moduledoc section "`complete_task/3` (EE-04, REQ-048) — HTTP
  and assignee authorization are out of scope" (lines 114–127), and `complete_task/3`
  itself (line 1928 on) — confirmed the engine layer does no HTTP/authz and never
  inspects `assignee_type`/`assignee_ref`; this fix must not add such a check inside
  `Letflow.Engine`, preserving the module boundary REQ-048 established.
- `lib/letflow/design/req048-task-completion.md` §11/§12 (`INV-EE48-10`, the explicit
  "S4 auth plug's job" deferral this fix supersedes).
- `lib/letflow/api/response.ex`: `forbidden/2` (line 137, wraps `Error.forbidden/1`,
  RFC 9457 problem document) — already the established 403 shape, used today by
  `lib/letflow/plugs/authorize.ex` line 116 (`Response.forbidden("insufficient
  permissions")`) for the coarse RBAC `:Deny403` case.
- `docs/migration/decisions/0013-authorization-role-set.md` (IDN-03 role matrix).
- `docs/agents/instructions/security-invariants.md`.

---

## 1. What exists today, and the exact structural gap

`claim_task/3` (`lib/letflow/tasks.ex:412`) is a real per-resource authorization
check: it row-locks the task, resolves the caller's `group_ids`/`role_names` via
`resolve_principal_scope/2`, and `apply_claim/5` rejects with a typed error tuple
unless the caller is the `USER` assignee, a member of the `GROUP` assignee, holds
the `ROLE` assignee, or the task is currently unassigned.

`handle_complete/3` (`lib/letflow/routers/tasks.ex:315`) does none of this. It
reads `actor_id` off the authenticated session and calls
`Engine.complete_task/3` directly — no fetch of the task's assignee columns, no
`resolve_principal_scope/2` call, no comparison. `Engine.complete_task/3` itself
(confirmed, `lib/letflow/engine.ex:1928`) never inspects `assignee_type`/
`assignee_ref` either — by design (REQ-048 §12), that check was always meant to
live in the S4 HTTP layer, not the engine. It was simply never added there.

The only gate standing between an arbitrary `TASK_WORKER` and completing
*any* tenant's *any* task is the coarse, tenant-wide `:TasksComplete` RBAC
permission check `Letflow.Plugs.Authorize` runs before the handler, which every
`TASK_WORKER` passes unconditionally.

## 2. Fix shape — where the check lives, and why

The check is added as a new **pre-check step inside `handle_complete/3`**,
mirroring `handle_claim/3`'s shape: fetch the task's current assignment, resolve
the caller's scope, apply the same precedence `apply_claim/5` already uses, and
reject with 403 before `Engine.complete_task/3` is ever called.

The check's logic is implemented as a **new public function on
`Letflow.Tasks`**, not as a `Repo` call inlined into the router. This preserves
`Letflow.Routers.Tasks`'s own `INV-TW85-2` ("zero `Repo.` calls anywhere in this
module") exactly as `handle_claim/3`/`handle_assign/3`/`handle_get_by_id/3`
already do — every one of them reads/writes through `Letflow.Tasks`, never
`Repo` directly from the router module.

The check is **not** added to `Letflow.Engine.complete_task/3`. That would
violate the module boundary REQ-048 established and `Letflow.Engine`'s own
moduledoc still asserts (§5 below documents the moduledoc text this fix
supersedes — the boundary itself, "HTTP/authz is S4's job, not the engine's,"
is **kept**; only the stale claim that S4 actually built it is corrected).

### 2.1 New function: `Letflow.Tasks.authorize_completion/3`

```
@type complete_authz_opts :: opts()  # [prefix: String.t(), ...]

@type complete_authz_error ::
        {:error, :invalid_task_id}
        | {:error, :task_not_found}
        | {:error, :assigned_to_other_user}
        | {:error, :assignee_group_not_member}
        | {:error, :assignee_role_not_held}

@spec authorize_completion(task_id :: String.t(), actor_id :: Ecto.UUID.t(), opts :: complete_authz_opts()) ::
        :ok | complete_authz_error()
```

Behavior (prose, mirrors `claim_task/3`'s own resolution exactly — see §2.2 for
precedence):

1. `cast_task_id/1` (already private in `Letflow.Tasks`, reused) — malformed id
   → `{:error, :invalid_task_id}`.
2. Fetch the task by id (plain, **unlocked** read — this is an authorization
   admission check, not a mutation; see §2.3 for why no row lock is taken here).
   Not found → `{:error, :task_not_found}`.
3. `resolve_principal_scope(actor_id, prefix: prefix)` — the exact same call
   `claim_task/3` already makes, not a second resolution path.
4. Apply the precedence table in §2.2 against the fetched task's
   `assignee_type`/`assignee_ref` and the resolved scope. Return `:ok` or the
   matching error tuple.

This function performs **no write** — `Repo.update/2`/`write_assignment/4` are
never called from it. It is purely an admission check; the actual completion
mutation stays entirely inside `Engine.complete_task/3`'s own transaction,
unchanged.

### 2.2 Precedence table (mirrors `apply_claim/5` exactly, read-only)

| `assignee_type` | Condition | Result |
|---|---|---|
| `nil` (unassigned) | — | `:ok` — mirrors `apply_claim/5`'s own unassigned-permissive clause (line 432) exactly. `claim_task/3` already lets any authenticated actor claim (and thereby complete) an unassigned task; this fix does not introduce a stricter rule for complete than claim already has for the identical state. **This permissive-for-unassigned behavior is an explicit design decision this doc states, not a silent inheritance** — SECURITY-REVIEWER must confirm it is still intended per §7's gate, since widening or narrowing it here is itself a security-relevant choice. |
| `"USER"` | `assignee_ref == actor_id` | `:ok` |
| `"USER"` | `assignee_ref != actor_id` | `{:error, :assigned_to_other_user}` |
| `"GROUP"` | `assignee_ref in scope.group_ids` | `:ok` |
| `"GROUP"` | `assignee_ref not in scope.group_ids` | `{:error, :assignee_group_not_member}` |
| `"ROLE"` | `assignee_ref in scope.role_names` | `:ok` |
| `"ROLE"` | `assignee_ref not in scope.role_names` | `{:error, :assignee_role_not_held}` |

No `:not_claimable` analogue exists here — `apply_claim/5`'s catch-all clause
(line 479) exists because `claim_task/3` can observe assignee states claiming
doesn't make sense for (none currently reachable given the three typed values
above, but the clause exists defensively). `authorize_completion/3`'s precedence
table is total over `assignee_type ∈ {nil, "USER", "GROUP", "ROLE"}` — the same
set `Task.t()`'s own typed column already constrains it to — so no catch-all
error tuple is needed.

**Implementation note (not a new function, a recommended refactor target for
ELIXIR-DEV, non-binding on this design's acceptance criteria):** the precedence
logic in this table is identical in substance to `apply_claim/5`'s own
precedence, minus the final `write_assignment/4` call on the `:ok` branches.
ELIXIR-DEV should consider factoring the shared "does `actor_id`/`scope`
authorize against this task's assignee" decision into one private helper both
`apply_claim/5` and `authorize_completion/3` call, so the two precedence tables
cannot silently drift apart in a future edit. This is a code-quality
recommendation for REVIEWER to weigh, not a functional requirement — either
structure (shared helper or two independently-written precedence chains) is
acceptable to SECURITY-REVIEWER as long as the table in §2.2 holds.

### 2.3 Why no row lock on the authorization read

`claim_task/3`'s lock exists because it **writes** (`write_assignment/4`) and
must avoid a lost-update race between two concurrent claims. `authorize_completion/3`
only reads and returns a verdict; the actual mutation path
(`Engine.complete_task/3`) already acquires its own `SELECT ... FOR UPDATE` on
the task row inside its own `Ecto.Multi` (EE-12 lock inventory, unchanged by
this fix). A task's `assignee_type`/`assignee_ref` could theoretically change
in the narrow window between this unlocked authorization read and the engine's
own locked fetch (e.g. a concurrent `reassign`) — but this is the same risk
class already accepted for the coarse `:TasksComplete` RBAC check, which also
runs unlocked, before any transaction, ahead of this one. `Engine.complete_task/3`
never inspects assignee columns at all, so a race here cannot cause the engine
to act on stale assignee data — at worst, a request is authorized against an
assignment that changes a moment later, which is the same class of
check-then-act race every permission gate in this codebase already carries
(`Letflow.Plugs.Authorize`'s own `:Deny403` check included). Not a new gap
introduced by this fix; not a regression against this fix's own `:TasksComplete`
precedent.

## 3. `handle_complete/3` — updated flow (`lib/letflow/routers/tasks.ex`)

Current flow (lines 315–329): build `attrs`, call `Engine.complete_task/3`,
map the result.

New flow:

1. Read `actor_id` from `conn.assigns.auth_context.user_id` (unchanged — already
   the first line of the existing function).
2. Call `Tasks.authorize_completion(id, actor_id, opts)` (`opts` =
   `conn.assigns.scoped_opts`, the same value already threaded to
   `Engine.complete_task/3` — no new opts construction).
3. On `:ok`: proceed exactly as today — build `output_variables`/`idempotency_key`/
   `attrs`, call `Engine.complete_task/3`, pipe into (the existing)
   `handle_complete_result/2`.
4. On `{:error, reason}`: skip `Engine.complete_task/3` entirely (no engine call
   attempted — no transaction opened, no `idempotency_key` even generated) and
   map `reason` to a response per §4 below.

`INV-TW85-2` ("zero `Repo.` calls anywhere in this module") is preserved: the
new step is a `Letflow.Tasks` call, same as every other handler in this router.

## 4. Error → HTTP response mapping (new clauses on `handle_complete_result/2`)

`handle_complete_result/2` already has clauses for `:invalid_task_id` (400),
`:task_not_found` (404), `{:task_not_pending, _}` (409), `%Ecto.Changeset{}`
(422), and a catch-all (500) — all sourced from `Engine.complete_task/3`'s own
error set. `authorize_completion/3` reuses `:invalid_task_id` and
`:task_not_found` as the exact same atoms, so **no new clause is needed for
those two** — the existing `{:error, :invalid_task_id}` → `Response.bad_request/2`
and `{:error, :task_not_found}` → `Response.not_found/1` clauses already match
them correctly regardless of which call (`authorize_completion/3` or
`Engine.complete_task/3`) produced the tuple. (`handle_complete_result/2`'s
clause ordering is error-atom-pattern-based, not call-site-based, so this is
safe without reordering.)

Three new clauses are added, before the catch-all, for the three
assignee-mismatch atoms `authorize_completion/3` introduces — these atoms are
**not** members of `Engine.complete_task/3`'s own `complete_error()` union, so
they cannot collide with any existing case:

| Error tuple | HTTP status | `Response` call | Detail string |
|---|---|---|---|
| `{:error, :assigned_to_other_user}` | 403 | `Response.forbidden/2` | `"task is assigned to a different user"` |
| `{:error, :assignee_group_not_member}` | 403 | `Response.forbidden/2` | `"caller is not a member of the assigned group"` |
| `{:error, :assignee_role_not_held}` | 403 | `Response.forbidden/2` | `"caller does not hold the assigned role"` |

**Status code is 403, not 409** — this is a deliberate divergence from
`handle_claim_result/3`'s own mapping of the *same three atoms* to `409
Conflict` (lines 397–407 of the router). The two endpoints' identical atoms
carry different HTTP semantics on purpose: `claim` is a self-assignment
*attempt* whose failure is a state-conflict (someone else already holds/could
hold the slot — retryable in principle, e.g. after a reassign), matching RFC
9457/HTTP's conflict semantics and `claim_task/3`'s own doc framing. `complete`
is an *authorization* decision — IDN-03's role matrix is explicit that a
`TASK_WORKER` completing a task they are not the assignee of is a `403
Forbidden`, the same status `Letflow.Plugs.Authorize` already returns for the
coarse RBAC failure one layer up. Reusing `Response.forbidden/2` (not a new
response helper) keeps this on the same RFC 9457 problem-document shape
`Letflow.Plugs.Authorize` already produces for `:Deny403` — detail string
differs, `type`/status are identical. Detail strings above are copied verbatim
from `handle_claim_result/3`'s own matching clauses (lines 398/402/406) for
consistency between the two endpoints' human-readable messages — only the
status code differs.

## 5. `Letflow.Engine` moduledoc update (lines ~114–127)

The section currently headed `## complete_task/3 (EE-04, REQ-048) — HTTP and
assignee authorization are out of scope` asserts: *"Whether the calling
`TASK_WORKER` is the task's own `assignee_ref` (HTTP 403 otherwise, per IDN-03's
role matrix) is not checked anywhere in this module — that is the S4 auth
plug's job, per REQ-021's precedent."*

This sentence is now stale in one specific way: the check **has** landed, just
not inside this module — it lives in `Letflow.Tasks.authorize_completion/3`,
called from `Letflow.Routers.Tasks.handle_complete/3` ahead of
`Engine.complete_task/3`. The module-boundary claim ("not checked anywhere in
this module," "not the engine's job") stays **true and unchanged** — only the
implicit suggestion that it remains unbuilt needs correcting.

Required edit: append a short note to this section (not a rewrite of the
existing boundary rationale, which is still correct) stating that the IDN-03
assignee check referenced here was implemented by ISS-0942 as
`Letflow.Tasks.authorize_completion/3`, called from
`Letflow.Routers.Tasks.handle_complete/3` before this function is ever invoked
— cross-reference this design doc and `lib/letflow/design/req048-task-completion.md`
§12's superseding note (§6 below). The section header's framing ("HTTP and
assignee authorization are out of scope [of this module]") remains accurate
and should not be changed — only the body sentence implying S4 never built it.

`complete_task/3`'s own `@doc` (immediately preceding its `@spec`, if it
contains the same "S4 auth plug's job" language or cross-references REQ-021's
precedent in the same way) gets the identical correction, same cross-reference.

## 6. `req048-task-completion.md` §12 superseding note

§12 ("Scope boundary (AC5) — required moduledoc content") and `INV-EE48-10`
("This module performs zero HTTP status-code mapping and zero
assignee-authorization checking (AC5)") both remain **true** — `Letflow.Engine`
still performs no such checking, by design, unchanged by this fix. Add a
superseding note at the end of §12 (not a rewrite — REQ-048's design record is
historical) stating: the assignee-authorization check this section defers to
"the S4 auth plug" was actually implemented by ISS-0942, not inside an S4 HTTP
*plug* but inside `Letflow.Tasks.authorize_completion/3` called from
`Letflow.Routers.Tasks.handle_complete/3` — functionally the same scope
boundary (HTTP-layer, pre-engine-call), implemented as a `Letflow.Tasks`
context function rather than a `Plug` module, consistent with how `claim_task/3`'s
own authorization resolution already lives in `Letflow.Tasks`, not a plug.
Cross-reference `lib/letflow/design/iss0942-task-complete-authorization-gap.md`
(this doc).

## 7. SECURITY-REVIEWER — mandatory hard gate

This is a direct authorization-boundary fix on a tenant-data mutation path
(`POST /tasks/:id/complete`) closing a confirmed, UAT-exploited privilege gap.
**SECURITY-REVIEWER sign-off is a mandatory hard gate on the implementation**,
per `docs/agents/instructions/security-invariants.md` and this project's
"every producing step has a validating step" rule — ELIXIR-DEV's own claim of
having implemented this design is not evidence the gap is closed. SECURITY-REVIEWER
must independently verify, at minimum:

- `Letflow.Tasks.authorize_completion/3` is actually called from
  `handle_complete/3` **before** `Engine.complete_task/3`, on every code path
  (no branch that reaches the engine call while skipping the authz call).
- The precedence table in §2.2 is implemented exactly — in particular, that
  `"USER"`/`"GROUP"`/`"ROLE"` mismatches all three produce 403, not 409 or 200.
- The unassigned-task permissive case (`nil` → `:ok`) is confirmed as still
  intended, not silently carried over from `apply_claim/5` without a fresh
  look — this is the one precedence-table branch this doc does not claim
  SECURITY-REVIEWER already settled.
- `Letflow.Engine.complete_task/3` itself gained no new assignee logic (module
  boundary preserved — REQ-048's "not the engine's job" framing holds).
- The regression test in §8 reproduces the exact live-UAT exploit scenario and
  now fails closed (403), not open (200).

## 8. Acceptance criteria

AC1 — **403 on mismatched `USER` assignee.** A `TASK_WORKER` who is not the
`USER`-type `assignee_ref` of a `PENDING` task, calling `POST
/tasks/:id/complete`, receives HTTP 403 (RFC 9457 problem document, detail
`"task is assigned to a different user"`), and no `TASK_COMPLETED` event is
appended, no token advances, no instance variables merge — `Engine.complete_task/3`
is never invoked for this request.

AC2 — **403 on `GROUP` assignee the caller is not a member of.** Same as AC1,
for a `GROUP`-type assignee, detail `"caller is not a member of the assigned
group"`.

AC3 — **403 on `ROLE` assignee the caller does not hold.** Same as AC1, for a
`ROLE`-type assignee, detail `"caller does not hold the assigned role"` — this
is the exact precedence branch the live UAT exploit hit (ROLE-assigned task,
non-member actor, HTTP 200 observed instead of the expected 403).

AC4 — **200 on matching/permitted assignee, unchanged.** A `USER`-type
assignee completing their own task, a `GROUP`-member completing a
`GROUP`-assigned task, a `ROLE`-holder completing a `ROLE`-assigned task, and
an actor completing a currently-unassigned (`nil`) task all still succeed with
HTTP 200 exactly as before this fix — no regression on the permitted paths.

AC5 — **`invalid_task_id`/`task_not_found` responses unchanged.** A malformed
task id still returns 400; a nonexistent task id still returns 404 — identical
status and detail to pre-fix behavior, regardless of whether
`authorize_completion/3` or `Engine.complete_task/3` is the atom's origin
(§4's dispatch-table note).

AC6 — **`{task_not_pending, _}` (409) and all of `Engine.complete_task/3`'s own
error mappings unchanged.** This fix adds no new behavior downstream of a
successful `authorize_completion/3` call — every existing `handle_complete_result/2`
clause for `Engine.complete_task/3`'s own error set keeps its current status
code and detail.

AC7 — **Regression test reproduces the live UAT exploit scenario.** TEST-DESIGNER
must write a test case that reproduces the exact scenario from
`test/uat-reports/uat-2026-10-01-ISS0912-NARRATIVE.yaml` (ISS-0912's re-run,
"Claudia"/evidence-collection scenario referenced by SECURITY-REVIEWER's
determination): a ROLE-assigned task, an actor who is not a member of that
role, that actor calling `POST /tasks/:id/claim` first (asserting the existing
409 — unchanged, already correct) and then `POST /tasks/:id/complete` directly
without claiming (asserting the **new** 403 — this is the exact exploit path:
skip `/claim`, call `/complete` directly). The test must fail against
pre-fix code (reproducing the exploit as HTTP 200) and pass against the fix
(HTTP 403) — a regression test that would pass against both is not sufficient
coverage.

AC8 — **`Letflow.Engine` moduledoc updated per §5.** The "HTTP and assignee
authorization are out of scope" section's stale implication (that the IDN-03
check was never built) is corrected per §5; the boundary claim itself
(engine performs none of this checking) is not weakened or removed, since it
remains true.

AC9 — **`req048-task-completion.md` §12 superseded per §6.** A superseding
note is appended (REQ-048's design record itself is not rewritten), per §6.

## 9. Cross-module dependencies

| Caller | Callee | What changes |
|---|---|---|
| `Letflow.Routers.Tasks.handle_complete/3` | `Letflow.Tasks.authorize_completion/3` (new) | New call, before `Engine.complete_task/3` |
| `Letflow.Tasks.authorize_completion/3` (new) | `Letflow.Tasks.resolve_principal_scope/2` (existing) | Reused verbatim, no new resolution path |
| `Letflow.Routers.Tasks.handle_complete_result/2` | — | Three new clauses (§4), existing clauses unchanged |
| `Letflow.Engine.complete_task/3` | — | **No change** — module boundary preserved (§2, confirmed by reading `lib/letflow/engine.ex` directly, not assumed) |
| `Letflow.Engine` moduledoc | — | Corrected per §5 |
| `lib/letflow/design/req048-task-completion.md` §12 | — | Superseding note per §6 |

## 10. Open questions

OQ-1 — Whether to extract the shared `apply_claim/5`/`authorize_completion/3`
precedence logic into one private helper (§2.2's implementation note) is left
to ELIXIR-DEV/REVIEWER's judgment — not a functional acceptance criterion,
listed here so it isn't silently decided as "obviously yes" by whoever
implements it without REVIEWER weighing in on `Letflow.Tasks`'s existing
function-organization conventions.

OQ-2 — This design does not add a row lock to `authorize_completion/3`'s read
(§2.3's reasoning). If SECURITY-REVIEWER's independent read of
`security-invariants.md` disagrees that the accepted-race framing in §2.3
holds for this specific check, that is grounds for SECURITY-REVIEWER to reject
this design outright (not just the implementation) — flagged explicitly so
that disagreement surfaces at the design gate, not after ELIXIR-DEV has
already built against this doc.
