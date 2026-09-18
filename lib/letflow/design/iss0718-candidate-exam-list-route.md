# ISS-0718 — CANDIDATE 403 on the exam-list screen: dedicated `GET /exam-sessions/available`

Design only. No implementation code below — signatures, `@spec`s, route/permission
declarations and file-level diffs described in prose, per CODE-DESIGNER's own scope
fence. Source of truth for scope is `docs/issues/ISS-0718.yaml` (this run's
`context.requirement_text`), re-verified directly against
`lib/letflow/api/authorization.ex`, `lib/letflow/routers/exam_sessions.ex`,
`lib/letflow/routers/entities.ex`, `web/src/pages/exam/ExamListPage.tsx`,
`web/src/api/exam.ts`, and `test/letflow/api/authorization_test.exs` (all read in full
or in the relevant part for this run) — not re-derived from ISSUE-FIXER's diagnosis
alone.

---

## 0. The decision: option (b), and a stronger form of it than the issue sketched

**Chosen: option (b) — a dedicated route under the `ExamSession*` permission family.**
Option (a) (widen CANDIDATE's closed set, new atom or narrowed `:EntitiesQuery` grant)
is rejected. Reasoning in §0.1-§0.3; rejection of (a) in §0.4.

**Stronger than the issue's own framing of (b):** ISS-0718 assumed (b) still needs *some*
change to CANDIDATE's closed set (a route "scoped under the existing ExamSession*
permission family" reads as implying a still-new grant). It does not. Verified by direct
read of `lib/letflow/api/authorization.ex:1017-1032`: **`:ExamSessionStart` is granted to
exactly one role, `:CANDIDATE`** (grep for `:ExamSessionStart` across that file turns up
only the `CANDIDATE` `role_allows?/2` clause at line 1026 as a grantee — no other role's
clause lists it). Gating the new list route behind the **existing** `:ExamSessionStart`
permission, rather than minting a new atom, means:

- `role_allows?(:CANDIDATE, ...)`'s six-member list (authorization.ex:1023-1032) is
  **unchanged** — no new atom added to it.
- `test/letflow/api/authorization_test.exs`'s ISS-0646 closed-set invariant test
  (lines 1816-1847, "CANDIDATE... exactly its six... permissions and nothing else") is
  **unchanged** — it walks `Authorization.permissions()` (`permissions/0`), which is also
  unchanged, since no new permission atom is introduced anywhere in this design.
- No REVIEWER/SECURITY-REVIEWER sign-off is needed to *relax* a hardened invariant,
  because the invariant is never touched. (SECURITY-REVIEWER still gates this change as
  a new tenant-data-path route per usual process — §5 — just not for closed-set reasons.)

This is a genuine zero-change-to-CANDIDATE's-permission-set fix, not merely a smaller
diff than (a).

### 0.1 Why gating on `:ExamSessionStart` is the correct semantic, not a hack

`:ExamSessionStart` already means, precisely, "this caller may attempt to start a session
against some active exam" (`POST /exam-sessions`, `authorization.ex:724,878`). "Which
exams are currently startable" is not a distinct capability from "may start a session" —
it is the same capability applied to a list instead of a single `exam_id`. A candidate who
could call `POST /exam-sessions` with any given active exam's id already has, by
construction, everything the list route discloses (which exams exist, which are active) —
the list route adds no new disclosure surface beyond what `:ExamSessionStart` already
authorizes one exam at a time. Reusing the permission is therefore not a workaround; it is
the accurate name for what this route does.

### 0.2 Why this stays scoped (never becomes a generic entity-query backdoor)

The new route does **not** forward to `Letflow.Routers.Entities`' generic
`POST /entities/query` machinery, and does not accept caller-supplied `entity_type`,
`filters`, `sort`, or `join`. It takes **no query parameters that select what is queried**
— only pagination (`cursor`, `page_size`, mirroring `ExamQueryRequest`'s existing two
optional fields, §2.2). The entity type (`"exam"`) and the status filter (`status eq
"active"`) are **hardcoded server-side** in the new delegate function (§1.2), not derived
from any caller input. A CANDIDATE calling this route can therefore never see: any
non-`exam` entity type, or any `exam` record whose `status` is not `active`. This is a
strictly narrower capability than `:EntitiesQuery` — CANDIDATE gains no path to generic
entity querying, now or if this route's implementation is read carelessly later, because
the route's own request schema has no field through which a caller could widen the scope.

### 0.3 Why (b) is preferred over (a) generally, independent of the zero-diff finding

Per `docs/agents/instructions/security-invariants.md`'s posture and this project's own
established caution around ISS-0646 (REQ-366 flagged-but-deferred the analogous
`:HelpRead` question rather than resolving it by widening CANDIDATE), a new
narrowly-scoped route is a smaller, more auditable surface than adding a new permission
atom to a role whose defining property (per its own moduledoc) is a maintained CLOSED
set: every future auditor of "does CANDIDATE's permission list still match ISS-0646's
six?" continues to get a `true` answer without needing to also reason about a filtered
`:EntitiesQuery` carve-out's own correctness.

### 0.4 Why option (a) is rejected, explicitly

- Requires touching the ISS-0646 closed-set invariant test deliberately (widening "six" to
  seven, or adding an entity_type-scoped exception the test's current shape — a flat
  membership list — cannot express without a structural rewrite of the test itself).
- Requires either (a1) a filtered `:EntitiesQuery` grant (CANDIDATE gets a permission
  whose *name* implies unrestricted entity querying, with the restriction enforced only by
  convention in one call site — a latent widening risk if any other caller-facing code
  ever checks `:EntitiesQuery` and assumes it means "may query anything") or (a2) a new
  `:ExamListRead` atom — which still adds a seventh permission to CANDIDATE's set for a
  capability §0.1 shows is already implied by an existing one, making the new atom pure
  duplication with no independent meaning.
- No requirement-text or decision-record basis exists for widening CANDIDATE beyond
  ISS-0646's six — REQ-366 raised exactly this question for `:HelpRead` and did not
  resolve it in favor of widening; nothing has changed since to justify resolving it
  differently here.

---

## 1. Backend: `Letflow.Routers.ExamSessions` gets a new route

### 1.1 Route

`GET /exam-sessions/available?cursor=<string>&page_size=<integer>`, added to the existing
`lib/letflow/routers/exam_sessions.ex` route table (§0's confirmed convention: this
router already `use`s `Letflow.Api.AuthorizedRouter`, already declares routes via
`authz_get/3` with a compile-time policy-key atom, already reads `prefix!(conn)`, already
renders exclusively through `Letflow.Api.Response`). No new sub-router, no
`api_pipeline.ex` change — this mounts under the existing `/exam-sessions` forward.

Declared **above** `authz_get "/:id", :ExamSessionRead` (ordering note, not a functional
requirement: `Plug.Router` matches `/available` and `/:id` as siblings at the same single-
segment depth, and a literal segment `/available` always wins over a `:id` wildcard
regardless of declaration order in `Plug.Router`'s compiled matcher — so ordering here is
for readability only, mirroring this file's own existing comment convention at line
136-141 about `/:id` vs. the deeper write routes).

The route is declared through this router's existing `authz_get/3` macro (same declaration
form every other route in this file already uses, §0): path `"/available"`, required
policy key `:ExamSessionStart` (§0 — the existing atom, no new one minted), body
delegating straight to the new handler, `handle_list_available_exams(conn)` (§1.3). No
inline logic lives in the route declaration itself — same one-line-delegate shape as this
file's other `authz_get` clauses.

**Permission: `:ExamSessionStart`** (§0 — the existing atom, no new one minted). No change
to `lib/letflow/api/authorization.ex`'s `@type permission`, `@permissions` list, or any
`role_allows?/2` clause. One addition only: `endpoint_policy_key("GET",
"/exam-sessions/available")` must return `:ExamSessionStart` — a new clause in
`endpoint_policy_key/2` (mirroring the existing `endpoint_policy_key("POST",
"/exam-sessions")` clause at authorization.ex:724), since every route's path+method needs
its own policy-key resolution regardless of which permission atom it maps to. This is an
**additive-only** change to that function (one new clause, matching an existing pattern),
not a widening of any role's grant.

### 1.2 Delegate: `Letflow.Exam.Session.list_available_exams/2` (new function)

Added to the existing `lib/letflow/exam/session.ex` module (the same module
`start_session`/`get_session_state_for_user`/`autosave_answer`/`submit` already live in —
this is exam-session-lifecycle-adjacent read logic, not a new subsystem).

```
@spec list_available_exams(prefix :: String.t(), opts :: keyword()) ::
        {:ok, %{items: [exam_row()], next_cursor: String.t() | nil}}
        | {:error, term()}
```

where `opts` accepts `:cursor` (`String.t() | nil`) and `:page_size`
(`pos_integer() | nil`, default mirrors `ExamListPage.tsx`'s existing `page_size: 100`
call-site default — §2.2 keeps that default in the frontend call, this function's own
default is `100` if omitted, for callers other than the router), and `exam_row()` is the
**same shape** `Letflow.Entities.Query.Compiler`'s plain (non-joined) row already
produces for an `exam` entity — i.e. a `Letflow.Entities.Record.Latest`-shaped record
(`record_id`, `field_values`, `deleted`, `entity_def_version`, `last_event_global_seq`) —
so the router's JSON rendering (§1.3) can reuse the **existing** `entity_row_map/1`-style
shaping the generic query route already has (`Letflow.Routers.Entities`'s
`query_item_map/1`, entities.ex:2327-2332), not a new response shape.

**Implementation-shape (no code, per role fence), internal composition only:**

1. Builds a request map with `entity_type: "exam"`, `filters: [%{field: "status", op:
   :eq, value: "active"}]`, `sort: []`, `join: []` — **hardcoded**, never accepting any of
   these four fields from a caller (§0.2). This is the *same* request shape
   `Letflow.Routers.Entities`'s `build_query_request/1` produces from a caller body
   (entities.ex:1684-1691), just constructed directly in code instead of parsed from JSON.
2. Calls the same three-step pipeline `Letflow.Routers.Entities`'s `run_query/4` already
   calls (entities.ex:1598-1613): `Letflow.Entities.Query.Compiler.compile/2`, then
   `Letflow.Entities.Query.Allowlist.load/2`, then `Letflow.Entities.Query.Cursor.paginate/5`
   — reusing these library-level modules directly (they are not HTTP-route-specific; they
   already take `(request, prefix)`/`(entity_type, prefix)`-shaped arguments independent
   of any Plug conn), rather than duplicating the entity-record read pipeline.
3. **No `FieldGrants` redaction step is called.** `run_query/4`'s `redact/4` step exists to
   enforce per-field, per-user, per-entity-type grants for the *generic* query route,
   where the caller and entity type are both unconstrained (entities.ex:1637-1659,
   §0's read). Here, the entity type is fixed to `"exam"` and the field set exposed is
   whatever `field_values` the `exam` entity type's schema carries — **flagged as OQ-1
   (§6)**: this design does not independently re-verify whether any `exam`-type field
   currently carries `entity_field_restrictions` a CANDIDATE should not see (e.g. an
   internal-only cost/vendor field on the `exam` entity). If such a restriction exists,
   omitting the `FieldGrants` step would leak it. §6 states this as an explicit open
   question for ELIXIR-DEV to check against the live `exam` entity definition (and its
   `entity_field_restrictions` rows, if any) before implementing, rather than this design
   assuming either "there are none" or "the generic redaction step must be reused."
4. Returns `{:ok, %{items: page.items, next_cursor: page.next_cursor}}` on success, or
   `{:error, reason}` passing through whatever `compile/2`/`Allowlist.load/2`/
   `Cursor.paginate/5` themselves can return (the same error union `run_query/4` already
   handles via `render_query_error/2` — §1.3 reuses that rendering, not a new one).

### 1.3 Router rendering (`handle_list_available_exams/1`)

`handle_list_available_exams/1`, a private handler local to `exam_sessions.ex` (same
placement convention as this file's other `handle_*` delegates), behaves as follows, in
order:

1. Resolves `prefix = prefix!(conn)` (§0's established helper — same call every other
   route in this router makes).
2. Validates `conn.params` via `parse_available_exams_opts/1` (§1.3's next paragraph).
   - On success (`{:ok, opts}`): calls `Session.list_available_exams(prefix, opts)`
     (§1.2) and passes its result to `render_list_available_exams/2` for rendering.
   - On validation failure (`{:errors, field_errors}`): renders the problem response
     directly — `Response.send_problem/2` with the validation problem built from
     `field_errors` — and never calls `Session.list_available_exams/2` at all.

- `parse_available_exams_opts/1` validates `cursor` (optional string) and `page_size`
  (optional, positive integer, same `FieldConstraint`-based validation shape
  `Letflow.Routers.Entities`'s own query-param parsing uses elsewhere in that router) from
  `conn.params` (query-string params on a `GET`, not a body — no `object_body/1` call,
  since this route defines no request body).
- `render_list_available_exams(conn, {:ok, %{items: items, next_cursor: next_cursor}})`
  renders `Response.ok(conn, %{"items" => Enum.map(items, &exam_row_json/1), "next_cursor"
  => next_cursor})`.
- `exam_row_json/1` is a **new private function local to `exam_sessions.ex`**, structurally
  identical to `Letflow.Routers.Entities`'s `query_item_map/1`'s plain-row clause
  (entities.ex:2327-2329, itself just `record_map(record)`) — duplicated rather than
  imported cross-router, matching this codebase's existing convention that each router
  owns its own JSON-shaping functions (`session_state_json`, `certificate_json`, etc. are
  all router-local in this same file already, §0's read of exam_sessions.ex's own "JSON
  shaping" section, lines 704-827). No new shared module is introduced for one field-for-
  field-identical shaping function used by two callers.
- `render_list_available_exams(conn, {:error, reason})` reuses (delegates to, or
  structurally mirrors) `Letflow.Routers.Entities`'s existing `render_query_error/2`
  clause set — **flagged as OQ-2 (§6)**: whether to literally call into
  `Letflow.Routers.Entities`'s private function (not possible — it's `defp`, module-
  private) or duplicate the small clause set locally. This design specifies duplicating
  the clause set locally (consistent with the `exam_row_json/1` precedent just above and
  this file's existing all-local-rendering convention), not adding a cross-router public
  API just for error rendering.

### 1.4 Response shape

```
200: { "items": [ { "record_id": string, "field_values": object, "deleted": boolean,
                     "entity_def_version": string, "last_event_global_seq": integer } ],
       "next_cursor": string | null }
400: RFC 9457 problem body (malformed page_size, e.g. non-positive or non-integer)
403: Response.forbidden/2's existing zero-detail shape (unreachable for CANDIDATE given
     §1.1's grant; reachable in principle for a role that does NOT hold
     :ExamSessionStart -- i.e. every role except CANDIDATE, §0's finding -- if such a
     role's token ever reaches this route, which is the intended/correct behavior: this
     route is CANDIDATE-only by construction, same as every other ExamSession* route)
```

No `404` case — an empty result set (`"items": []`) is a valid, successful answer (zero
currently-active exams), not a not-found condition; matches `POST /entities/query`'s own
existing behavior for an empty match (§0's read of `run_query/4` — it never renders 404
for an empty page).

---

## 2. Frontend changes

### 2.1 `web/src/api/exam.ts`

- Add one new function to the `examApi` object:

```
/** `GET /exam-sessions/available` -- lists exams a CANDIDATE may currently start a
 *  session against (status=active, exam_id filtering is server-side and NOT
 *  caller-controlled -- see lib/letflow/design/iss0718-candidate-exam-list-route.md
 *  §1). Replaces this file's prior queryExamRecords/POST /entities/query call, which
 *  CANDIDATE cannot reach (ISS-0718 -- :EntitiesQuery is outside CANDIDATE's ISS-0646
 *  closed set). */
listAvailableExams: (opts: { cursor?: string; page_size?: number } = {}) =>
  client.get<ExamRecordsPage>(`${BASE}/available`, opts),
```

  (exact `client.get` query-param-passing convention matches however this codebase's
  other `GET`-with-query-params callers already pass them — verified against
  `web/src/api/client.ts`'s `get` signature at implementation time; not re-specified here
  since it is a pre-existing mechanism, not a new one this design introduces.)

- **`queryExamRecords` (the current `POST /entities/query` call, exam.ts:122-123) is
  removed** — it is CANDIDATE's *only* caller (`ExamListPage.tsx`, §2.2) and CANDIDATE can
  never successfully call it (that is this issue's entire root cause), so leaving it in
  place as dead/broken code would be misleading. `ExamQueryFilterClause`/`ExamQueryRequest`
  (exam.ts's own minimal mirror types, only ever used to build the removed call's request
  body) are removed with it. `ExamRecord`/`ExamRecordsPage` (the response-shape types) are
  **kept** — §1.4's new route returns the identical shape, so these two types are reused
  as-is, now documented as `GET /exam-sessions/available`'s response shape instead of
  `POST /entities/query`'s.

### 2.2 `web/src/pages/exam/ExamListPage.tsx`

- The `examsQuery` call (lines 57-64) changes from:
  `examApi.queryExamRecords({ filters: [...], page_size: 100 })` to
  `examApi.listAvailableExams({ page_size: 100 })` — **no `filters` argument at all**,
  since `status: active` filtering is now server-side and non-optional (§1.2 step 1), not
  a caller-supplied filter clause. `queryKeys.exam.list({ page_size: 100 })` (line 58) is
  unchanged — the query key's own shape does not encode which route backs it.
- The file's header comment (lines 1-38, in particular the "Read exclusively via the
  existing generic entity-read route... no new backend route is needed" paragraph, lines
  22-28) **must be rewritten** to describe the new route instead — it currently documents
  a decision (REQ-338's "no new route needed") that this design deliberately reverses.
  Rewrite the paragraph to state: this screen now reads via the dedicated
  `GET /exam-sessions/available` route (ISS-0718), gated by CANDIDATE's existing
  `:ExamSessionStart` permission, added specifically because the generic
  `POST /entities/query` route CANDIDATE previously called is outside CANDIDATE's ISS-0646
  closed permission set — cross-reference `lib/letflow/design/iss0718-candidate-exam-list-
  route.md`. The REQ-366 addendum paragraph (lines 30-37, about `HelpTrigger`) is
  unaffected and stays as-is.
- No other change to this file: the `exams` derivation (`examsQuery.data?.items ?? []`,
  line 66), the provisional-notice rendering, and every downstream render of `exams` all
  consume the same `ExamRecord[]` shape as before (§1.4/§2.1 keep that shape identical) —
  this is a data-source swap, not a rendering change.

---

## 3. Cross-module dependencies

- `Letflow.Routers.ExamSessions` (existing router, §1.1) gains a dependency on
  `Letflow.Entities.Query.Compiler`, `Letflow.Entities.Query.Allowlist`, and
  `Letflow.Entities.Query.Cursor` — **but only transitively, through
  `Letflow.Exam.Session.list_available_exams/2` (§1.2)**, not directly: the router itself
  still only calls into `Letflow.Exam.Session`, matching this router's own moduledoc
  invariant ("this router performs no `Repo` call of any kind... every session-scoped
  delegate call passes straight through to `Letflow.Exam.Session`'s... guard",
  exam_sessions.ex:79-82). `Letflow.Exam.Session` itself gains the new dependency on the
  three `Entities.Query.*` modules — a genuinely new cross-subsystem dependency (exam
  session logic depending on the generic entity-query engine) worth SECURITY-REVIEWER/
  REVIEWER noting, though not a new *runtime* coupling risk: those three modules already
  have no dependency back on `Letflow.Exam.*`, so this is a one-directional, acyclic
  addition.
- `lib/letflow/api/authorization.ex`: one additive `endpoint_policy_key/2` clause (§1.1).
  No change to `@type permission`, `@permissions`, `role_allows?/2`, or any existing
  clause.
- `test/letflow/api/authorization_test.exs`: **no change** to the ISS-0646 closed-set
  invariant test (§0). A new test *may* be warranted for the new
  `endpoint_policy_key("GET", "/exam-sessions/available")` clause (matching this file's
  own existing per-route `endpoint_policy_key/2` test convention, e.g. the assertions
  around line 1790) — that is TEST-DESIGNER's call at Step 3, not specified further here.
- `web/src/api/exam.ts` / `web/src/pages/exam/ExamListPage.tsx`: §2.

---

## 4. How the fix stays scoped (explicit invariants)

1. CANDIDATE's `role_allows?/2` clause (`authorization.ex:1023-1032`) is **byte-for-byte
   unchanged** — verifiable by diff; §0 is the load-bearing argument for why this is
   possible at all.
2. The new route accepts **no caller-supplied entity-type or filter selection** — its
   request schema (query params only) has exactly two optional fields, `cursor` and
   `page_size`, neither of which can alter *what* is queried, only pagination through the
   one fixed query (§0.2, §1.2 step 1).
3. The new route's delegate (`list_available_exams/2`) hardcodes `entity_type: "exam"` and
   `filters: [status eq "active"]` in its own body — not configuration, not a parameter,
   not derived from any request data.
4. No other role's permission grant changes. `:ExamSessionStart` remains held by exactly
   `:CANDIDATE` (§0) — this design adds no new grantee.
5. `:EntitiesQuery` itself, and every role that holds it today, is completely untouched —
   this design does not touch `Letflow.Routers.Entities` at all.

---

## 5. Security review note (for SECURITY-REVIEWER, not self-cleared here)

This is a new authenticated, tenant-scoped read route (INV-1: no caller-supplied identity
accepted, prefix always from `conn.assigns.scoped_opts`, matching every existing route in
this router — §0's read of `exam_sessions.ex`'s own "Ownership and tenant isolation"
section). It is flagged for SECURITY-REVIEWER specifically on:
- **OQ-1 (§1.2 step 3)** — whether skipping `FieldGrants` redaction for the `exam` entity
  type is safe given the *current* live `entity_field_restrictions` configuration (not a
  general design flaw, but a fact about live data this design cannot verify from the
  tree alone).
- Confirmation that `:ExamSessionStart`'s single-grantee fact (§0) is not expected to
  change soon in a way that would make gating this list route on it stop being accurate
  (e.g. if a future requirement grants `:ExamSessionStart` to `PLATFORM_ADMIN` for
  support/ops purposes, this list route would silently become reachable by that role too
  — which may be fine, or may not; not this design's call, flagged as **OQ-3**, §6).

---

## 6. Open questions

- **OQ-1** (§1.2 step 3, §5) — whether the `exam` entity type currently has any
  `entity_field_restrictions` row that `FieldGrants` redaction would enforce for the
  generic query route but this new route (which skips that step) would not. ELIXIR-DEV
  must check this against live/seeded `entity_field_restrictions` data for `exam` before
  implementing; if any restriction exists, this design's §1.2 step 3 needs revisiting
  (either add the `FieldGrants` step back, accepting its cost, or explicitly confirm the
  restricted field(s) are acceptable to expose to CANDIDATE for a `status=active` list).
- **OQ-2** (§1.3) — whether `render_list_available_exams/2`'s error-rendering clause set
  is hand-duplicated locally in `exam_sessions.ex` (this design's stated choice) versus
  some other de-duplication FRONTEND— no, ELIXIR-DEV — judges preferable at implementation
  time; not expected to change any externally-observable behavior either way.
- **OQ-3** (§5) — whether a future grant of `:ExamSessionStart` to a role other than
  `:CANDIDATE` should also make it reachable for this list route, or whether the list
  route should eventually get its own dedicated permission once/if that happens. Not
  resolved here — no such grant exists today (§0), so there is nothing to design against
  yet.

---

## 7. Acceptance-criteria mapping

ISS-0718 does not itself enumerate a structured `acceptance_criteria` list (it is an
issue, not a requirement) — the mapping below is against the issue's own stated
resolution obligations (its two-option framing, its "affected_files" list, and its
description's implicit pass condition: a CANDIDATE token gets a real 200 with active
exams, not a 403).

| Obligation (ISS-0718, derived) | Design element |
|---|---|
| CANDIDATE-role user can list active exams without a 403 | §1 (new `GET /exam-sessions/available`, gated on CANDIDATE's existing `:ExamSessionStart`) |
| Decision made explicitly between options (a)/(b), not silently picked | §0 (full reasoning, both directions) |
| Closed-set invariant (ISS-0646) not silently re-decided | §0 (proves zero change to CANDIDATE's permission list), §3 |
| `ExamListPage.tsx` / `exam.ts` updated to match | §2 |
| Fix stays scoped -- CANDIDATE never gains non-exam or non-active-exam visibility | §0.2, §4 |
| `lib/letflow/api/authorization.ex` change, if any, is minimal and reviewed | §1.1 (one additive `endpoint_policy_key/2` clause only), §5 |
| `test/letflow/api/authorization_test.exs` change, if any, is identified | §3 (none required for the closed-set test; a new route-specific test is TEST-DESIGNER's call) |
