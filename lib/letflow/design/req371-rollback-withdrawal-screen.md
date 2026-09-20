# REQ-371 design — Operator-facing rollback/withdrawal screen for a released process definition

Design for `docs/requirements.yaml` REQ-371 (owner FRONTEND-DEV, stage S8, queue task
728, GH#1589). Scope: `web/src` only — the backend rollback path
(`Letflow.Definitions.rollback_definition_version/4`, `POST
/api/v1/definitions/:process_key/rollback`) is already built, wired, and out of scope
to change. This design was produced against `origin/main` at commit `97e99ebf`.

## 0. Traceability matrix (AC → design element)

| AC | Design element |
|---|---|
| AC1 (action reachable, gated to same role(s) as DefinitionListPage.tsx's destructive actions) | §2 Entry point, §6 Role gating (states explicitly why the actual gate diverges from DefinitionListPage's own `DESIGNER_ROLES`) |
| AC2 (confirm calls POST .../rollback with target_version, real HTTP response handled) | §3 API client, §4 UI flow steps 3–4 |
| AC3 (all four error responses render distinctly, exercised for real) | §5 Error rendering |
| AC4 (new case after rollback shows restored version, exercised for real) | §4 step 5, §8 e2e spec step 5 |
| AC5 (change-history/audit view shows actor/timestamp/restored version) | §7 Change-history view (states the real backend gap and the scoped resolution) |
| AC6 (UAT yaml NOTE updated, pipeline_test authored and passing) | §8.0 (exact fixture-file NOTE-block replacement) + §8.2 (spec authored) |
| AC7 (type-check/lint/test/build all pass) | FRONTEND-DEV execution gate, not a design element |

## 1. Facts confirmed by reading the real code (not assumed)

1. **Backend contract** (`lib/letflow/definitions.ex:962-981`, `rollback_definition_version/4`):
   - Args: `process_key` (== `process_definitions.name` — confirmed at
     `definitions.ex:2523`, `where([d], d.name == ^process_key)` — there is no
     separate `process_key` column), `target_version`, `actor_id`, `opts`.
   - Returns `{:ok, rollback_result()}` or one of exactly four error shapes:
     `{:error, :forbidden}`, `{:error, :process_key_not_found}`,
     `{:error, :version_never_active}`, `{:error, :already_active}` (plus an
     unreachable-from-the-UI `{:error, term()}`/`common_error()` catch-all).
   - `rollback_result` fields: `definition_id`, `version` (the newly-active,
     i.e. restored, version), `rolled_back_from_version`, `superseded_review_id`
     (nilable), `event_id`.
   - **No `reason` field anywhere** — not in the input, not in `rollback_result`,
     not in the `DEFINITION_VERSION_ROLLED_BACK` event payload
     (`process_key`/`from_version`/`to_version`/`actor_id` only,
     `definitions.ex:2594-2600`). See §7.1 for how this design handles the UAT
     scenario's step-3 `reason` field given this gap.

2. **HTTP contract** (`lib/letflow/routers/definitions.ex:1122-1195`):
   - `POST /api/v1/definitions/:process_key/rollback`, body `{"target_version":
     "<string>"}` (`@rollback_schema`: required, non-empty, max 64 chars — no
     other accepted field; an unrecognized `reason` key would simply be
     ignored by `Validation.validate/2`, not rejected, but nothing on the
     server ever reads it).
   - Success: `200`, body exactly `{definition_id, version,
     rolled_back_from_version, superseded_review_id, event_id}`
     (`rollback_map/1`, `routers/definitions.ex:1186-1195`).
   - `403` — `Response.forbidden(conn, "insufficient permissions")` → RFC 9457
     problem document `{type, title: "Forbidden", status: 403, detail:
     "insufficient permissions", trace_id}`.
   - `404` — `Response.not_found(conn)` (zero-detail, INV-5) → `{title: "Not
     Found", status: 404, detail: "the requested resource was not found"}`.
     Covers both "process_key never existed" and "every version already
     deprecated/archived" (`process_key_not_found`) — no version-specific
     detail is available for this case.
   - `422 version_never_active` — `Response.unprocessable(conn,
     "target_version was never active")` → `{title: "Unprocessable Entity",
     status: 422, detail: "target_version was never active"}`.
   - `422 already_active` — `Response.unprocessable(conn, "target_version is
     already the active version")` → `{title: "Unprocessable Entity", status:
     422, detail: "target_version is already the active version"}`.
   - **Route is `:Unknown`-gated, i.e. PLATFORM_ADMIN-only** — declared with a
     plain `post` macro, not `authz_post` (`routers/definitions.ex:20-23`,
     confirmed against `Letflow.Api.Authorization.evaluate_access/2`'s
     `:Unknown` catch-all in `promotions.ex:37-45`'s moduledoc, which this
     route's own moduledoc explicitly points to as "the same deliberate
     decision"). `opts[:permission_checker]` passed at the call site
     (`PromotionPlan.default_permission_checker/2`) always returns `true` — it
     is a placeholder with **no real enforcement** (its own `@doc` states
     this) — so the *only* real enforcement on this endpoint today is the
     route-level PLATFORM_ADMIN-only gate, not anything `rollback_definition_version/4`
     itself checks. See §6.

3. **`web/src/api/client.ts`'s error-mapping trap** (confirmed by reading
   `request<T>`'s non-2xx branch, `client.ts:127-145`): for every status
   other than 401/409/429, `ApiError.message` is built from `body['title']`,
   **not** `body['detail']`. Since both 422 cases share the identical `title`
   ("Unprocessable Entity"), **`error.message` cannot distinguish
   `version_never_active` from `already_active`** — both would render
   identically if a component naively displayed `error.message`. The real
   distinguishing text lives in `body['detail']`, which survives only inside
   `ApiError.details` (`client.ts:134-137`: the whole raw problem body is
   spread into `details` when there is no `errors` array). §5 specifies the
   exact classifier that must be used instead of `error.message`.

4. **No backend read path exists for `DEFINITION_VERSION_ROLLED_BACK` events
   today** (confirmed, not assumed — see §7 for the full trail: `GET
   /api/v1/audit` reads `audit_entries` (REQ-195/196), a table
   `finish_rollback/7` never writes to; `EventStore.read_global/1` can read
   the table the rollback event actually lands in, but no router mounts it
   any more since REQ-196 repointed `/audit` away from it). This is a real
   backend gap, not a frontend design choice — §7 states the scoped
   resolution and the disclosed limitation, following this session's own
   established precedent (`platform-definition-promotion-approved.pipeline.e2e.spec.ts`'s
   own EO-004 comment: "no `DEFINITION_PROMOTED` audit/event entry was found
   via either `/api/v1/audit` or the platform-instance timeline... not
   independently re-verified by this spec (ISS-0733)" — the identical gap,
   one event type over).

5. **Version history data already available**: `definitionsApi.getVersions(name)`
   (`web/src/api/definitions.ts:52-53`) calls `GET /api/v1/definitions?name=`,
   returning every version row for that name — already used by
   `DefinitionListPage.tsx`'s expandable "Version history" row
   (`versionsQuery`, lines 55/310-323). This is the exact data needed to
   populate a target-version picker (every version whose `status` is
   `ACTIVE` or `DEPRECATED`, matching the backend's own lookup set — `DRAFT`/
   `ARCHIVED` rows are never valid rollback targets per
   `rollback_definition_version/4`'s doc, design §5 step 2b).

6. **`InstanceBoardPage.tsx` already surfaces the live active version** —
   the "start new case" form auto-selects `activeDefinitionByName?.version`
   (`InstanceBoardPage.tsx:337`, `useDefinition`-style query keyed by
   `queryKeys.definitions.active(name)`), and the instance list column
   renders `${inst.definition_name} v${inst.definition_version}`
   (`InstanceBoardPage.tsx:231`). Invalidating
   `queryKeys.definitions.active(name)` after a successful rollback is
   therefore sufficient for AC4/EO-001/step-4 to show the restored version
   with zero new UI in the instances area — no change to
   `InstanceBoardPage.tsx` is needed, only the query-key invalidation
   specified in §3.

## 2. Entry point: new page, reached from `DefinitionListPage.tsx`

**New page**, not an extension of `DefinitionEditorPage.tsx` or
`PromotionReviewPage.tsx`: this is a distinct operator action (withdraw a
released change) with its own confirmation/error/history concerns, and
`DefinitionEditorPage.tsx` is the *designer's* canvas-editing surface, a
different persona/permission tier (PROCESS_DESIGNER-reachable) than
PLATFORM_ADMIN-only rollback.

- **File**: `web/src/pages/definitions/DefinitionRollbackPage.tsx`.
- **Route** (added to `web/src/router.tsx`, alongside the existing
  `definitions/:id` and `definitions/:id/promotions/:reviewId` entries):
  `{ path: 'definitions/:id/rollback', element: <DefinitionRollbackPage /> }`.
  `:id` is the definition row id of the **currently active** version (matches
  the `definitions/:id/promotions/:reviewId` precedent of keying the URL off
  a definition id for breadcrumb/context) — the page resolves `process_key`
  itself via `useDefinition(id).data.name` (§3).
- **Reached from `DefinitionListPage.tsx`**: a new "Rollback…" button is added
  to the `actions` column's per-row button group (`DefinitionListPage.tsx:191-208`),
  visible only when `def.status === 'ACTIVE'` (rollback only ever makes sense
  against the currently-active row — a `DEPRECATED`/`ARCHIVED`/`DRAFT` row has
  no "current version" to withdraw) **and** `isPlatformAdmin` (§6). Clicking
  it navigates to `/definitions/${def.id}/rollback`.
- The version-history expandable row `DefinitionListPage.tsx` already has
  (`data-testid="version-history-row"`, lines 304-326) is left unchanged —
  it's a read-only list, not this feature's concern — but
  `DefinitionRollbackPage.tsx` reuses the identical `useDefinitionVersions`
  data source (§1.5) to build its own target-version picker, so an operator
  who already expanded that row and a rollback-page visitor see the exact
  same set of versions.

## 3. API client

New file `web/src/api/definitionRollback.ts` (kept separate from
`definitions.ts` rather than added to `definitionsApi`, matching this
codebase's precedent of a dedicated small API module per distinct backend
concern — c.f. `web/src/api/audit.ts` being its own file rather than folded
into another domain module):

```
export interface RollbackRequest {
  target_version: string
}

export interface RollbackResult {
  definition_id: string
  version: string
  rolled_back_from_version: string
  superseded_review_id: string | null
  event_id: string
}

export const definitionRollbackApi = {
  rollback: (processKey: string, body: RollbackRequest) =>
    client.post<RollbackResult>(
      `/api/v1/definitions/${encodeURIComponent(processKey)}/rollback`,
      body,
    ),
}
```

Field names are copied verbatim from `rollback_map/1` (§1.2) — no renaming,
no camelCase conversion (matching every other API module in `web/src/api/`,
which all pass server field names straight through).

**Hook**, in `web/src/hooks/useDefinitions.ts` (co-located with the other
definition mutations, not a new hooks file — this is one mutation, not a
new domain):

```
export function useRollbackDefinition() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (args: { processKey: string; targetVersion: string }) =>
      definitionRollbackApi.rollback(args.processKey, { target_version: args.targetVersion }),
    onSuccess: (_data, args) => {
      qc.invalidateQueries({ queryKey: definitionKeys.active(args.processKey) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
      qc.invalidateQueries({ queryKey: queryKeys.definitions.versions(args.processKey) })
    },
  })
}
```

No `onSuccess` cache write of the local change-history entry happens here —
that is `DefinitionRollbackPage.tsx`'s own local state (§7.2), not a query
cache concern, since there is no query backing it.

## 4. UI flow

`DefinitionRollbackPage.tsx` state machine (`idle` → `confirming` →
`submitting` → `succeeded` | `failed`), rendered as a single page (not a
modal layered over `DefinitionListPage.tsx` — this action has enough
surface, per acceptance criteria, that it earns its own screen, matching
`PromotionReviewPage.tsx`'s own precedent of a dedicated page for one
focused operator decision rather than a dialog):

1. **Header**: definition name, current active version, status badge
   (`StatusBadge`, `domain="definition"`) — sourced from `useDefinition(id)`.
2. **Version picker** (`data-testid="rollback-target-version-select"`): a
   `<select>` populated from `useDefinitionVersions(name)`'s items, filtered
   to `status !== 'ACTIVE'` (the current active version is never a valid
   rollback target of itself — this is a client-side convenience filter only,
   not a substitute for the server's own `already_active` check, since a
   stale/cached version list could still let an operator pick the version
   that has since become active — §5 handles that case as the
   `already_active` 422). Each option shows `"{version} — {STATUS}"` (e.g.
   `"1.0.0 — DEPRECATED"`) so an ARCHIVED/DRAFT row, if ever present in the
   list, is visibly distinguishable — though only ACTIVE/DEPRECATED rows are
   valid per §1.5, the picker does not client-side-block a DRAFT/ARCHIVED
   selection (there is no reliable client mapping from status to "will the
   server accept this" beyond what the four wired error cases already cover)
   — an attempt against a never-active version surfaces the real
   `version_never_active` 422 (§5), which is the accurate, server-verified
   answer for exactly this case (EO-004's own scenario: "a version that has
   never been live in this workspace").

   The `<select>`'s last option is always a fixed sentinel,
   `data-testid="rollback-target-version-other"`, value `"__other__"`,
   labelled "Other version…" — selecting it swaps the `<select>` for a plain
   text `<input data-testid="rollback-target-version-manual">` in the same
   position. This is a real, permanent product affordance (an operator
   legitimately may need to target a version the list didn't happen to
   include, e.g. one paginated out of `useDefinitionVersions`'s result), not
   a test-only hook — and it is what makes EO-004's "attempt a version that
   never ran here" reachable through the real GUI at all: the fixed dropdown
   can, by construction, only ever offer versions that **did** run here
   (§1.5's `ACTIVE`/`DEPRECATED` filter), so without this escape a genuinely
   never-active version could never be typed in through the UI, and the
   pipeline spec's step 5 (§8.2) would have no DOM path to reach it.
3. **Reason field** (`data-testid="rollback-reason-input"`): a required
   plain-text `<textarea>`, client-side only (§7.1) — required for the UI
   flow to proceed to confirmation (empty reason keeps the "Continue" button
   disabled), **not sent to the backend** (§1.1 — there is no field for it).
   A one-line note under the field states this explicitly:
   *"Recorded in this session's change history below. Not sent to the
   server — see design note in REQ-371 if this needs to persist across
   reloads."* (verbatim copy is FRONTEND-DEV's call; the semantic content —
   disclosing that it's local-only — is the design requirement).
4. **Confirmation step** (`data-testid="rollback-confirm-dialog"`): clicking
   "Continue" (disabled until a target version and a non-empty reason are
   set) shows an inline confirmation panel (not a separate route) naming the
   exact from/to versions: *"Roll back {name} from {currentVersion} to
   {targetVersion}? Every case started after this completes will run on
   {targetVersion}. Cases already in progress are not affected."* — this
   sentence structure is deliberate: it directly asserts EO-001/EO-002's own
   guarantees to the operator at the moment of decision, not just after the
   fact. Two buttons: `data-testid="rollback-cancel-btn"` (returns to
   `confirming`→`idle`, i.e. back to editing target version fields) and
   `data-testid="rollback-confirm-btn"` (fires the mutation).
5. **On success**: `useRollbackDefinition`'s mutation resolves with
   `RollbackResult`. The page:
   - Shows a success banner (`data-testid="rollback-success-banner"`):
     *"Rolled back to {result.version}. Every new case will run on this
     version."*
   - Appends one entry to the page-local change-history list (§7.2) built
     from `{actor: current session user, timestamp: client Date.now() at
     confirm-click time, restored_version: result.version,
     rolled_back_from_version: result.rolled_back_from_version, reason: the
     locally-held reason string, event_id: result.event_id}`.
   - Because §3's `onSuccess` already invalidated
     `definitionKeys.active(processKey)`, any already-mounted
     `InstanceBoardPage.tsx` picks up the restored version automatically on
     its next render (§1.6) — nothing further to wire for AC4.
6. **On failure**: transitions to `failed`, renders the classified error
   (§5) inline above the confirmation panel, and stays on the `confirming`
   state (target version and reason are preserved, not cleared) so the
   operator can pick a different version without re-entering the reason.

## 5. Error rendering — the four wired shapes, exercised for real

A `classifyRollbackError` helper, colocated in `DefinitionRollbackPage.tsx`
(small enough not to warrant its own `utils/` file — if FRONTEND-DEV later
needs it elsewhere, promote it then):

```
type RollbackErrorKind = 'forbidden' | 'not_found' | 'version_never_active' | 'already_active' | 'unknown'

function classifyRollbackError(err: ApiError): RollbackErrorKind {
  const detail = typeof err.details?.detail === 'string' ? err.details.detail : undefined
  if (err.status === 403) return 'forbidden'
  if (err.status === 404) return 'not_found'
  if (err.status === 422 && detail === 'target_version was never active') return 'version_never_active'
  if (err.status === 422 && detail === 'target_version is already the active version') return 'already_active'
  return 'unknown'
}
```

This reads `err.details.detail` (§1.3's finding), **never `err.message`**,
to disambiguate the two 422s — `err.message` is documented above as
identical ("Unprocessable Entity") for both and must not be used for this
decision. Exact-string comparison against the two literal server strings
(copied verbatim from §1.2) is deliberate, not a substring/`.includes()`
match — an exact match is the only way to be certain which of the two 422
cases occurred rather than guessing from a partial string, and both strings
are stable literals baked into `routers/definitions.ex` (§1.2), not
user-influenced text.

Rendered copy, one `data-testid`'d block per kind
(`data-testid="rollback-error-{kind}"`), each visually and textually
distinct (AC3's "distinct, clear message" — not a single generic error box
with a status code):

| Kind | `data-testid` | Message shown |
|---|---|---|
| `forbidden` | `rollback-error-forbidden` | "You don't have permission to roll back this process definition. Rollback is restricted to platform administrators." |
| `not_found` | `rollback-error-not-found` | "{name} has no active version to roll back — it may have been archived or deprecated since this page loaded." |
| `version_never_active` | `rollback-error-version-never-active` | "Version {targetVersion} has never been live in this workspace and cannot be selected. Choose a version that was previously active." — this is EO-004's own required shape: names the requested version, states it was never live, verbatim. |
| `already_active` | `rollback-error-already-active` | "Version {targetVersion} is already the active version — there is nothing to roll back to." |
| `unknown` (network/5xx/anything else) | `rollback-error-unknown` | "The rollback could not be completed ({err.message}). No change was made — try again." |

`{targetVersion}` and `{name}` above are the client's own already-known
values (the selected option, the page's definition name) — never derived
from the error body, since (§1.2) the 404/422 bodies carry no version-specific
text of their own.

## 6. Role gating — a deliberate, reasoned divergence from `DefinitionListPage.tsx`'s `DESIGNER_ROLES`

**Confirmed, not assumed** (§1.2): `POST .../rollback` is `:Unknown`-gated,
i.e. **PLATFORM_ADMIN-only** — strictly narrower than `DefinitionsWrite`
(held by both `PROCESS_DESIGNER` and `PLATFORM_ADMIN`, per
`DefinitionListPage.tsx`'s own `DESIGNER_ROLES = ['PROCESS_DESIGNER',
'PLATFORM_ADMIN']`, gating that page's Import/Activate-adjacent actions).
AC1's own wording — "gated to the same role(s) DefinitionListPage.tsx
already uses for destructive definition actions" — describes the *pattern*
(gate the destructive action to whatever role the backend actually
requires), not a literal copy of `DESIGNER_ROLES`'s specific role list: if
this page used `DESIGNER_ROLES`, a `PROCESS_DESIGNER`-only caller would see
and be able to attempt the Rollback action, then always receive a real 403
from the server (§1.2 — `PROCESS_DESIGNER` does not hold whatever
`:Unknown` requires), which is the exact "distinct, clear message"
`forbidden` case in §5 but reached needlessly, and worse, presents a
button that always fails for that role as if it might work.

**Decision**: gate on `PLATFORM_ADMIN` alone, matching
`PromotionReviewPage.tsx`'s own precedent (`isPlatformAdmin =
session?.roles.includes('PLATFORM_ADMIN')`, `PromotionReviewPage.tsx:32`) —
not `DefinitionListPage.tsx`'s `DESIGNER_ROLES` — because
`PromotionReviewPage.tsx` is gating an equally `:Unknown`-gated,
PLATFORM_ADMIN-only backend route (`Letflow.Routers.Promotions`, §1.2's
citation), the same backend enforcement shape rollback has, whereas
`DefinitionListPage.tsx`'s `DESIGNER_ROLES` gates `DefinitionsWrite` routes,
a different, broader permission. Concretely, in both
`DefinitionListPage.tsx` (the "Rollback…" row button, §2) and
`DefinitionRollbackPage.tsx` itself:

```
const isPlatformAdmin = Boolean(session?.roles.includes('PLATFORM_ADMIN'))
```

`DefinitionRollbackPage.tsx` itself follows `PromotionReviewPage.tsx`'s own
`if (!isPlatformAdmin) return <Navigate to="/instances" replace />` pattern
verbatim — a non-admin who reaches the URL directly is redirected, not shown
a client-side "forbidden" screen (the two are different concerns: this is
route-level UI gating, §5's `forbidden` rendering is for the case a
still-admin-looking session's token has since lost the role server-side, or
any other real 403 from a call the UI did permit).

## 7. Change-history / audit view

### 7.1 The `reason` field: client-side only, disclosed

Confirmed (§1.1): the backend has no `reason` concept anywhere in this path
— not accepted by `@rollback_schema`, not in `rollback_result`, not in the
`DEFINITION_VERSION_ROLLED_BACK` event payload. The UAT scenario's step 3
still asks the operator to record one (`reason: "Released version routes
high-value requests to the wrong reviewer."`) and EO-005 requires the
change-history view to show it. This design collects the reason in the UI
(§4 step 3) and displays it only in the page-local history panel built
below — it is never sent to the server and does not survive a page reload
or become visible to a different operator/session. This is a **named,
disclosed limitation of REQ-371's scope**, not a silent gap: FRONTEND-DEV
must not attempt to invent a place to persist it (e.g. `localStorage`, a
hidden field bolted onto an unrelated request) — that would be exactly the
kind of unstated assumption this design exists to prevent. A real, durable,
cross-session reason record requires a backend schema/route change, which is
out of REQ-371's scope (owner FRONTEND-DEV, `depends_on: []`, `web/src`
only) — see §7.3 for the explicit follow-up recommendation.

### 7.2 What ships: a page-local "Recent rollback" panel

`DefinitionRollbackPage.tsx` renders a `data-testid="rollback-history-panel"`
section below the confirmation area, populated **only** by rollback(s)
performed in the current page session (component-local `useState`, cleared
on navigation away/reload — no persistence layer). Each entry
(`data-testid="rollback-history-entry"`) shows:

- **Actor**: the current session's display name/user id (`useAuth()`'s
  `session` — the operator performing the rollback is definitionally the
  only actor this client-rendered panel can ever show, since there is no
  server read path for anyone else's rollback history, §7.3).
- **Timestamp**: captured client-side at the moment `rollback-confirm-btn`
  was clicked (`new Date()`), rendered via the existing `formatDateTime`
  helper (`@/i18n/format`, already used by `AuditLogPage.tsx`).
- **Restored version**: `result.version` (the real server-confirmed value,
  not merely the operator's selection — using the response guarantees the
  displayed value matches what the server actually activated).
- **Rolled back from**: `result.rolled_back_from_version`.
- **Reason**: the locally-held string from §4 step 3.
- **Event id**: `result.event_id`, shown in a monospace, secondary-styled
  span — a forward-compatible breadcrumb: if a later requirement adds a real
  GET path for this event (§7.3), this id is already on screen and could
  become a link with zero rework to this panel's data model.

This satisfies AC5 ("a change-history/audit view shows a completed rollback
actor, timestamp, and restored version, exercised for real") and EO-005's
verification literally — the panel is real, on-screen, and populated from a
real HTTP response, not a mock — while being honest that it is scoped to
"this operator's current page session," not a durable, queryable audit
trail. §8's e2e spec exercises exactly this (the pipeline's own operator
session performs the rollback and then reads this same panel back,
matching how EO-005 is actually reachable end to end today).

### 7.3 Explicit follow-up (not built here): a real backend read path

Recommended, but **out of REQ-371's scope** (frontend-only, no backend
files touched) — flagged here so ORCH/REQ-ANALYST can route it rather than
this gap being silently absorbed into "REQ-371 didn't fully deliver EO-005":
`DEFINITION_VERSION_ROLLED_BACK` events are appended to the event store
(`EventStore.append_platform_event/2`, via
`PlatformEvents.append_definition_version_rolled_back/2`) but never to
`audit_entries` (`Letflow.Audit`) — `finish_rollback/7` calls only
`opts[:event_appender]`, never `Letflow.Audit.append_multi/4`
(`activation.ex`'s own call sites are the only current `Letflow.Audit`
callers, §1.4). `GET /api/v1/audit` therefore will never show a rollback,
regardless of any frontend change, and `EventStore.read_global/1` — which
*can* read the table the rollback event actually lands in — is not mounted
behind any route since REQ-196 repointed `/audit` away from it. A durable,
cross-session, cross-operator rollback history needs one of: (a) a new
`Letflow.Audit.append_multi/4` call added to `finish_rollback/7` (a
`lib/letflow/` change, ELIXIR-DEV/CODE-DESIGNER territory, and would need
its own design pass for the `resource_type`/`before_state`/`after_state`
shape), or (b) a new GET route exposing `EventStore.read_global/1` filtered
to `event_type: "DEFINITION_VERSION_ROLLED_BACK"` (also a `lib/letflow/`
change). Neither is this design's to decide unilaterally — noted as an open
item for a future requirement, not silently resolved by, e.g., quietly
writing to `audit_entries` from frontend code (impossible) or fabricating a
client-only "audit trail" that outlives this scope's disclosed
page-session limitation.

## 8. Test strategy

### 8.0 Fixture file update (AC6, required — distinct from authoring the spec file itself)

`test/fixtures/uat/scenarios/platform/definition-promotion-rollback.yaml` lines
28-36 (confirmed by reading the file directly against `origin/main` at this
design's pinned commit, §header) currently hold the `# NOTE (ISS-0527): this
spec file does not exist ...` block, ending "...must be routed to FRONTEND-DEV
before UAT can proceed." FRONTEND-DEV must **REPLACE** lines 28-36 in full
(not merely delete them — line 27, `pipeline_test: web/tests/e2e/pipelines/...`,
is kept unchanged) once the spec in §8.2 is authored and passing, matching the
precedent set by the sibling scenario file
`test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml` at
its own lines 28-37: that file's own ISS-0527 NOTE was replaced, on the spec
shipping, with a block stating the resolution date, which steps ran via GUI
vs. system/API (per that scenario's own `via:` declarations), a pointer to a
dated pilot-history report, and any `expected_outcomes` gaps still open with
their own ISS numbers.

This scenario's own step declarations (confirmed directly, §8.2/§header) are
**all five `via: gui`** — no step here is `via: system`, unlike the sibling
scenario's steps 1/4 — so the replacement text must say all five ran via the
real GUI, not reuse the sibling's system/API framing. The two gaps this
design leaves open (§8.3) are EO-003 (single-tenant run only, cannot prove
platform-wide non-interference) and EO-005 (the change-history panel is this
page-session's local state only — no durable backend read path, §7.3). Exact
replacement text (FRONTEND-DEV substitutes the real authoring date and two
real, newly-assigned ISS numbers for the `<ISS-nnnn>` placeholders, per this
project's own issue-numbering convention — minting issue numbers is not this
design's job):

```
# ISS-0527 resolved <YYYY-MM-DD>: the spec above now exists and drives the real
# withdrawal flow end to end -- all five steps run via the real GUI, matching
# this scenario's own `via: gui` declaration on every step (no step here is
# `via: system`, unlike the sibling promotion-approved scenario). See
# test/uat-reports/gui-review-<YYYY-MM-DD>-definition-promotion-rollback.md for
# the full pilot history. EO-003's platform-wide non-interference (single-tenant
# run only) and EO-005's durability (change history is this page session's local
# state only, no backend read path yet -- see REQ-371 design Sec 7.3) remain open --
# <ISS-nnnn> and <ISS-nnnn+1>.
```

FRONTEND-DEV also authors the pilot-history report file named in the block
above (matching the sibling's own `test/uat-reports/gui-review-2026-09-20-
definition-promotion-approved.md` precedent) — its content is FRONTEND-DEV's
to write from the real pilot run, not specified further here.

### 8.1 Vitest unit tests

New file `web/src/pages/definitions/__tests__/DefinitionRollbackPage.test.tsx`
(matching the existing `__tests__/` co-location convention, e.g.
`TenantsPage.pagination.test.tsx`, `router.iss-0730.test.tsx`). Mocks
`definitionRollbackApi.rollback` (MSW or a direct `vi.mock` of
`@/api/definitionRollback`, matching whichever this codebase's existing
definition-page tests use — check `DefinitionListPage`'s own test file, if
one exists, for the established mocking convention before picking a new
one). Cases required (one test each, minimum):

1. Non-`PLATFORM_ADMIN` session redirects to `/instances` (mirrors
   `PromotionReviewPage`'s own gating test, if any exists — otherwise this is
   the first such test for this pattern and should follow §6's code exactly).
2. `PLATFORM_ADMIN` session renders the version picker populated from
   `useDefinitionVersions`, excluding the current `ACTIVE` row.
3. Empty reason keeps "Continue" disabled; filling it enables progression to
   the confirmation panel.
4. Confirming calls `definitionRollbackApi.rollback` with the exact selected
   `target_version` and renders the success banner + one history-panel entry
   with the mocked response's `version`/`rolled_back_from_version`/`event_id`.
5. Four separate tests, one per `classifyRollbackError` branch: a mocked
   403/404/422("target_version was never active")/422("target_version is
   already the active version") each render their own distinct
   `data-testid="rollback-error-*"` block (§5's table) — this is the
   file where `classifyRollbackError`'s exact-string-match logic (§5) is
   pinned, since a future edit to either backend detail string would
   silently break this classifier without a test catching it here.
6. `classifyRollbackError` itself gets direct unit coverage (no rendering)
   for all five branches including `unknown` (e.g. a 500 with no matching
   `detail`), since it's easy to get the `err.details.detail` vs
   `err.message` distinction wrong (§1.3) and a rendering-level test alone
   might pass by accident if the wrong field happens to contain a similar
   string in test fixtures.

New file `web/src/api/__tests__/definitionRollback.test.ts` (or co-located
per this codebase's existing api-test convention — check whether
`api/__tests__/` exists already, else colocate as
`api/definitionRollback.test.ts`): confirms `rollback()` hits the exact URL
(`/api/v1/definitions/{encoded name}/rollback`) with the exact body shape
`{target_version}`, and that a name containing characters needing
URL-encoding is encoded (`encodeURIComponent`, matching `getActive`'s own
precedent at `definitions.ts:23`).

### 8.2 Playwright e2e spec — `platform-definition-promotion-rollback.pipeline.e2e.spec.ts`

New file `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`,
structured exactly like `platform-definition-promotion-approved.pipeline.e2e.spec.ts`
(§ imports: `createPipeline`, `getKeycloakToken`, `loginWithToken`,
`navigateSpa`, `resolveTenantContext`, `authHeaders`, `shot`, plus
`assertServiceReadiness`/`resolveCredential` from `../helpers`). Drives
`test/fixtures/uat/scenarios/platform/definition-promotion-rollback.yaml`'s
five steps:

- **Pre-step (API, not one of the 5 scenario steps but required setup)**:
  create+activate a definition version 1 (`processKey`), then create+activate
  version 2 — this establishes "a newly released version is live, and the
  version that preceded it is still recorded as having been live"
  (preconditions block). Both via `POST /api/v1/definitions` +
  `POST /api/v1/definitions/:id/activate` (API, admin token), same pattern as
  the approved-pipeline spec's step 01.
- **Step 1 (GUI)** — `pl.step('01: operator confirms current/previous version on process detail')`:
  `navigateSpa` to `/definitions` (list page), assert the row shows
  `def.version === version2` and `status === 'ACTIVE'`; expand the
  version-history row (`data-testid="version-history-row"`, already shipped)
  and assert `version1` appears with `status === 'DEPRECATED'`. Sets
  `s.releasedVersion = version2`, `s.previousVersion = version1`.
- **Step 2 (GUI — required: `definition-promotion-rollback.yaml`'s own step 2
  is declared `via: gui`, confirmed by reading the scenario file directly; the
  sibling promotion-approved spec's API-driven steps 1/4 were themselves
  declared `via: system` by *their own* scenario, so that precedent does not
  transfer to this step)** — `pl.step('02: start an in-flight case on the
  released version')`: reuse the identical GUI mechanism §8.2 step 4 below
  already drives for starting a case (`InstanceBoardPage.tsx`'s "Start
  Instance" dialog): `navigateSpa` to `/instances`, click
  `data-testid="start-instance-button"`, type `processKey` into
  `data-testid="start-definition-name"`, wait for the read-only
  `data-testid="start-definition-version"` field (auto-populated from the
  live active version, `InstanceBoardPage.tsx:422-439`) to display
  `s.releasedVersion` (== version2 — still the active version at this point;
  the rollback in step 3 hasn't happened yet), leave correlation
  key/variables at their defaults (or the minimal valid JSON
  `submitStartInstance` requires — confirm against `InstanceBoardPage.tsx`'s
  own validation before writing this), click
  `data-testid="submit-start-instance"`, and wait for the real client-side
  navigation to `/instances/{instance_id}` (`InstanceBoardPage.tsx:207`) —
  capture `s.inFlightInstanceId` from that resulting URL, not from an API
  response. Then navigate away (to `/definitions` for step 3) without
  completing or cancelling the case — "leaves it part-way through" per the
  scenario, the same way step 4's own new case is left untouched.
- **Step 3 (GUI)** — `pl.step('03: EO-005 setup — operator withdraws the release with a reason')`:
  `navigateSpa` to `/definitions/{version2 row id}/rollback`; select
  `s.previousVersion` in `rollback-target-version-select`; fill
  `rollback-reason-input` with the scenario's own literal reason string
  ("Released version routes high-value requests to the wrong reviewer.");
  click `rollback-confirm-btn` (after the confirmation panel appears — click
  it, then the real confirm button); wait for
  `rollback-success-banner`. Capture the event id shown for later assertion.
- **Step 4 (GUI)** — `pl.step('04: EO-001/EO-004 — new case runs on the restored version, in-flight case undisturbed')`:
  `navigateSpa` to `/instances`; start a new case against `processKey` (the
  "Active version (auto-selected)" field, `InstanceBoardPage.tsx:420-430`,
  must show `s.previousVersion` — assert this directly, this is EO-001's own
  verification detail: "a case started after step 3 shows that same
  version"); then open `s.inFlightInstanceId`'s detail page
  (`InstanceDetailPage.tsx`) and assert its `definition_version` is still
  `s.releasedVersion` (unaffected by the pointer swap) and its status is
  still in-progress / it has an available next step (EO-002).
- **Step 5 (GUI)** — `pl.step('05: EO-004 — a version that never ran here is refused')`:
  back on `/definitions/{id}/rollback`, select the
  `rollback-target-version-other` sentinel option (§4 step 2), type a
  version string never created for this `processKey` (e.g.
  `"9.9.9-never-existed"`) into `rollback-target-version-manual`, fill the
  reason field, continue to the confirmation panel, and click
  `rollback-confirm-btn`. Assert `data-testid="rollback-error-version-never-active"`
  renders, containing the literal typed version string (§5's table:
  "Version {targetVersion} has never been live..."). Assert
  `/definitions` still shows `s.previousVersion`'s row unaffected (the
  refusal made no change) and the earlier-restored active version
  (`s.previousVersion`, since step 3 already rolled back to it) is still
  active — this is EO-004's own "the live version is unchanged" clause.
- **Cleanup**: cancel `s.inFlightInstanceId` and the step-4 new case, per
  the scenario's own `cleanup` block; leave the live workspace on
  `s.previousVersion` (also per `cleanup.description`).

### 8.3 Known, disclosed gaps this spec does NOT assert (state in the spec's own header comment, per this session's established precedent)

1. **EO-003** ("does not affect any other company using the platform") —
   like the approved-promotion spec's own EO-003/EO-004 disclosures, this
   spec runs against one tenant only; it cannot, by itself, prove platform-wide
   non-interference. Not asserted; noted as a manual/ops-level check, same
   disposition as the sibling spec.
   
2. **EO-005's durability** — per §7.3, the change-history panel this spec
   reads back in step 3 is real and on-screen, but it is this same
   browser page's local state, populated in the same test run that performed
   the rollback — it is not evidence that the entry would still be visible
   after a reload, in a different tab, or to a different operator, because
   (§7.3) no backend read path exists to make that true yet. State this
   explicitly in the spec's header comment, the same way the sibling spec's
   header states its own EO-004 gap (ISS-0733) — file a follow-up issue
   number for it rather than leaving an unnumbered comment, if this
   project's ISS-numbering convention requires one at authoring time.

### 8.4 What this test strategy can and cannot prove against a live QA deployment

Following this session's own precedent (the approved-promotion pipeline
spec's header comment, and ISS-0726/ISS-0728's design docs): passing Vitest
unit tests prove the component logic and error classifier are correct in
isolation, against mocked responses shaped exactly like the real ones (§1
confirms those shapes against the actual server code, not guessed). Passing
the Playwright pipeline spec proves the full flow works against a real
running backend in CI/local-dev conditions. Neither proves the feature
works against `qa.bizdala.com` or any other specific deployed environment
at any specific point in time — that requires a real UAT-RUNNER pass against
that environment, the same gap the sibling promotion-approved spec's own
header discloses ("independently confirmed live... during this pilot" is a
manual step, not something the automated spec re-proves on every run).
