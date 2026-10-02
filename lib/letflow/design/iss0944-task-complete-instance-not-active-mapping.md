# ISS-0944 — `POST /tasks/:id/complete` returns 500 instead of 409 when the owning instance is not ACTIVE

## 0. Problem recap (do not re-derive — trust ISSUE-FIXER's diagnosis, confirmed independently this session)

`Letflow.Engine.complete_task/3` row-locks and fetches the owning
`InstanceProjection` via `fetch_and_lock_instance_projection/3`
(`lib/letflow/engine.ex:2203-2213`):

```
InstanceProjection
|> where([p], p.instance_id == ^instance_id)
|> lock("FOR UPDATE")
|> repo.one(prefix: prefix)
|> case do
  nil -> {:error, :instance_not_found}
  %InstanceProjection{status: :active} = projection -> {:ok, projection}
  %InstanceProjection{status: status} -> {:error, {:instance_not_active, status}}
end
```

`{:error, {:instance_not_active, status}}` is a documented member of
`@type complete_error` (`lib/letflow/engine.ex:1882`):

```
| {:error, {:instance_not_active, status :: :completed | :cancelled | :error}}
```

This is working as designed on the engine side — three possible
`status` values, all meaning "the instance is no longer accepting task
completions."

`lib/letflow/routers/tasks.ex`'s `handle_complete_result/2` has clauses for
`:invalid_task_id`, `:invalid_output_variables`, `:task_not_found`,
`{:task_not_pending, _status}`, `%Ecto.Changeset{}`, and the three ISS-0942
assignee-mismatch atoms (lines 345-384, confirmed by direct read this
session), but **no clause matches `{:instance_not_active, _status}`**. It
falls through to the catch-all at lines 394-404:

```
defp handle_complete_result({:error, _reason}, conn) do
  Response.internal_error(conn)
end
```

— producing HTTP 500 instead of a 4xx conflict response.

**Precedent already in the same handler**, the exact pattern to mirror
(`lib/letflow/routers/tasks.ex:361-363`):

```
defp handle_complete_result({:error, {:task_not_pending, _status}}, conn) do
  Response.conflict(conn, "task is not pending")
end
```

`Response.conflict/2` is `lib/letflow/api/response.ex:159`:
`def conflict(conn, detail), do: send_problem(conn, Error.conflict(detail))`
— a 409 RFC 9457 problem document with `detail` as the free-text member.

## 1. Explicitly out of scope — do not touch

`{:error, {:instance_execution_error, error_type, affected}}` is a
**different** member of the same `complete_error` union
(`lib/letflow/engine.ex`, the member immediately below
`:instance_not_active` in the type declaration), reached via a different
code path inside `complete_task/3` (the dispatch/execution step, not
`fetch_and_lock_instance_projection/3`'s row fetch). It is also currently
unmapped in `handle_complete_result/2` and also falls into the same
catch-all — but it belongs to ISS-0917 (the still-open catalog
SERVICE_TASK dispatcher issue), not this one. This design adds **one**
clause, for `{:instance_not_active, status}` only. The catch-all's comment
block (lines 377-393) must be updated to drop `{:instance_not_active, _}`
from its list of "still falls through" members, but
`{:instance_execution_error, _, _}` stays listed there, unresolved,
exactly as ISSUE-FIXER flagged.

## 2. The fix

### 2.1 New clause in `handle_complete_result/2`

Insert a new private-function clause for
`handle_complete_result/2` in `lib/letflow/routers/tasks.ex`, placed
**immediately after** the existing `{:task_not_pending, _status}` clause
(after line 363) and, as with every other named-error clause in this
handler, **before** the catch-all clause at the bottom of the function
group.

- **Match pattern:** `{:error, {:instance_not_active, status}}` — bind
  `status` (do not discard it with `_status`; the message interpolates it,
  unlike the `task_not_pending` precedent which has no need to since its
  message is generic).
- **Guard:** none needed. The pattern alone is unambiguous — no other
  `complete_error` member has this two-element tagged-tuple shape with
  `:instance_not_active` as the first element.
- **Response:** `Response.conflict(conn, detail)` where `detail` is a
  string that names the instance's actual status, e.g.
  `"instance is #{status}"`. `status` is an atom (`:completed`,
  `:cancelled`, or `:error`) coming directly off the `InstanceProjection`
  schema's own `status` enum field — no additional validation or
  allowlist needed before interpolating it; it is never derived from
  request-controlled input (INV-8 — this is a typed-tuple match on a value
  the engine itself produced from a DB row, not a bare/raising pattern).
- This single clause covers all three status values in the union
  (`:completed | :cancelled | :error`) — same reasoning as the existing
  `{:task_not_pending, _status}}` clause above it, which likewise covers
  multiple task states (`:completed | :cancelled`) with one clause and one
  generic message. Do not write three separate clauses per status; that
  would diverge from the established precedent in this same file for no
  behavioral gain.

Resulting HTTP response: `409 Conflict`, RFC 9457 problem document, with
`detail` one of:
  - `"instance is completed"`
  - `"instance is cancelled"`
  - `"instance is error"`

### 2.2 Catch-all comment update

The catch-all clause's comment block (`lib/letflow/routers/tasks.ex:377-393`)
currently lists `{:instance_not_active, _}` among the `complete_error`
members it still swallows into 500. Remove that item from the list — the
new clause in §2.1 now handles it before the catch-all is ever reached.
Leave every other listed member (including
`{:instance_execution_error, _, _}`) untouched, per §1.

### 2.3 No change to `handle_claim_result/3`, `Tasks.claim_task/3`, or `Engine.complete_task/3`

`handle_claim_result/3` (lines 415-446) has its own, already-correct
mapping for its own state-conflict atoms (`{:task_not_pending, _status}`,
`:assigned_to_other_user`, `:assignee_group_not_member`,
`:assignee_role_not_held`, `:not_claimable}` — all → `Response.conflict/2`)
and is not touched by this design; `Tasks.claim_task/3` has no
`instance_not_active`-shaped error member in its own return type (claim
never row-locks the instance projection), so there is nothing analogous
to add there. `Engine.complete_task/3`'s `@type complete_error` and its
return value at the `fetch_and_lock_instance_projection/3` call site are
unchanged — this is a pure router-layer response-mapping fix, confirmed
working-as-designed on the engine side per §0.

## 3. Acceptance criteria (maps to ISS-0944's description)

1. `POST /tasks/:id/complete` against a task whose owning instance has
   `InstanceProjection.status == :error` returns HTTP 409 (not 500), with
   an RFC 9457 problem document whose `detail` names the instance status
   (`"instance is error"`) — this is the originally reported case
   (UAT narrative `test/uat-reports/uat-2026-10-01-ISS0912-NARRATIVE.yaml`).
2. Same 409 mapping holds for `status == :completed` and
   `status == :cancelled` (same union member, same new clause — §2.1).
3. `{:task_not_pending, _status}}`'s existing 409 mapping
   (`lib/letflow/routers/tasks.ex:361-363`) is unaffected — unchanged
   clause, unchanged message, unchanged position in the function clause
   order.
4. `handle_claim_result/3`'s own state-conflict mappings are unaffected —
   no edits made to that function (§2.3).
5. Every other currently-passing `handle_complete_result/2` clause
   (`:invalid_task_id`, `:invalid_output_variables`, `:task_not_found`,
   the three ISS-0942 403 clauses, `%Ecto.Changeset{}`, and the catch-all
   for every other still-unmapped `complete_error` member) is unaffected.
6. A regression test exists for at least the `:error` case — the one
   actually reported in the UAT narrative: seed/update an
   `InstanceProjection` row to `status: :error` (or exercise whatever
   fixture path already drives an instance into ERROR status elsewhere in
   the test suite), call `POST /tasks/:id/complete` for a pending task
   owned by that instance, and assert HTTP 409 with a problem-document
   body (not 500). Covering `:completed` and `:cancelled` too is good
   practice but only `:error` is a hard acceptance criterion, since it is
   the only status this issue's UAT narrative actually reproduced.
7. `{:instance_execution_error, _, _}` remains unmapped (still 500 via the
   catch-all) — explicitly NOT an acceptance criterion here; that is
   ISS-0917's scope (§1).

## 4. SECURITY-REVIEWER

Not needed. This is a pure error-response-shape mapping inside an existing,
already-authorized handler: no new authorization logic, no new data access
or query, no new input accepted from the request, and no information
disclosed beyond the instance's own lifecycle status (an enum value already
observable indirectly via `GET /tasks/:id`/`GET /instances/:id` for any
caller with read access to the task). `:instance_not_active`'s `status`
payload is engine-internal and not request-controlled, so no injection or
disclosure concern in the interpolated `detail` string (§2.1). Routine
ELIXIR-DEV-owned fix; REVIEWER's normal idiom/scope-creep gate still
applies as usual, but no security-invariant from
`docs/agents/instructions/security-invariants.md` is implicated.

## 5. Open questions

None. The fix is a single new case clause mirroring an established,
in-file precedent; no ambiguity in match pattern, response shape, or
scope boundary remains.
