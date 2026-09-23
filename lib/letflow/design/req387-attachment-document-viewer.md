# Design: REQ-387 — Frontend document-viewer screen for instance attachments

**Requirement:** REQ-387 (full text supplied via handoff `context.requirement_text`),
stage S8. Depends on REQ-386 (`status: done`, backend signed-link mechanism) and
REQ-212 (`status: done`, upload/list/get routes). Third of the `attachment-cross-tenant-probe`
(PW-09) finding's three requirements — REQ-386 and REQ-388 are both `done`.

**Owner (implementer):** FRONTEND-DEV
**This document produces:** one new API client module
(`web/src/api/attachments.ts`), one new `client.ts` method (`getBlob`), new
`web/src/types/api.ts` types, one new component
(`web/src/components/instances/AttachmentPanel.tsx`, upload/list widget) wired into
`InstanceDetailPage.tsx`, one new route/page
(`web/src/pages/instances/AttachmentViewerPage.tsx`) plus its three response-state
sub-components, one new `router.tsx` route entry, and the permanent Playwright spec
`web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts`. **No
implementation code** — no real `.tsx`/`.ts` file contents; signatures, type shapes,
component responsibilities, and the e2e spec's scenario design in prose only.
FRONTEND-DEV writes the actual code from this document.

**NOT in this document / explicitly out of scope (restated from the requirement):**
the signed-link issuance/expiry mechanism itself (REQ-386, shipped — this screen only
calls it); audit logging of denied attempts (REQ-388, shipped, and already fires on
every denied `fetch_scoped_attachment_content/3` branch server-side with no frontend
involvement needed).

---

## 0. Sources read for this design (confirming the REQ-386 shipped contract was read,
## not assumed)

- `lib/letflow/design/req386-attachment-signed-links.md` (full) — the design doc; used
  only to locate exact line numbers, cross-checked against the actual shipped code
  below since a design doc can drift from what merged.
- `lib/letflow/routers/instances.ex` (shipped, full route table + handlers read,
  lines ~1000–1260 plus the route declarations, `authz_post
  "/:id/attachments/:attachment_id/link"` / `authz_get
  "/:id/attachments/:attachment_id/link-content"`): confirms the **exact shipped**
  contract this design builds against —
  - `POST /api/v1/instances/:id/attachments/:attachment_id/link` (`:AttachmentsRead`)
    → `200 {"attachment_id", "token", "url", "expires_at" (ISO8601), "expires_in_seconds": 300}`
    on success; `404` (`Response.not_found/1`, no body detail) for
    cross-tenant/cross-instance/never-issued/malformed-id, folded identically;
    `422` for a malformed `:id` (instance id) path segment; `500` for the two
    structurally-unreachable-but-mapped internal errors.
  - `GET /api/v1/instances/:id/attachments/:attachment_id/link-content?link_token=...`
    (`:AttachmentsRead`) → `200` raw bytes, `Content-Type` = the attachment's own
    stored content type, on a valid unexpired token whose embedded attachment id
    matches the URL's `:attachment_id` segment; `410 Gone` (`Response.attachment_link_expired/1`,
    fixed body, no caller-suppliable detail — confirmed in `lib/letflow/api/error.ex`'s
    shipped `attachment_link_expired/0`) for **every** verification failure class
    (missing/malformed/tampered/wrong-tenant/mismatched-attachment/genuinely-expired
    token) — collapsed to one response by construction, per REQ-386 design §2.3/§7
    INV-5; `404` only in the rare case the token verified but the now-decoded
    attachment id is no longer tenant/instance-scoped (e.g. deleted post-issuance);
    `422` for a malformed `:id` path segment (checked before the token is even
    inspected); `500` when the verified token's attachment record still exists but its
    stored content object is missing (`:content_missing`, `instances.ex:1398-1402`) —
    a data-integrity fault, not a normal denial path; `409` when the attachment's
    content exists but is not currently retrievable (`:not_available`,
    `instances.ex:1398-1402`, e.g. an in-progress scan/quarantine state) — both read
    directly from the shipped route handler, not the REQ-386 design doc's paraphrase.
    Both fall through this design's `ViewerStatus` catch-all `kind: 'error'` branch
    (§3.2 step 3, §3.3's `AttachmentErrorScreen`) alongside 422 — no special-casing
    needed since neither is a 404/410 the two-screen-equality guarantee (AC3) or the
    expired-link screen (AC4) has any contract with.
  - `Letflow.Api.Error.attachment_link_expired/0`'s fixed detail string: "This link has
    expired or is no longer valid. Request a new link and try again." (read directly
    from `lib/letflow/api/error.ex`, not the design doc's paraphrase) — this design's
    GUI copy is written to be consistent with, but need not be byte-identical to, that
    backend string (the backend body is not itself rendered to the user — see §3.3).
  - `POST /api/v1/instances/:id/attachments` (`:AttachmentsManage`, multipart, field
    `file` required + optional `description`) → `201` with `attachment_json/1` shape
    (`id, instance_id, file_name, content_type, byte_size, uploaded_by, description,
    created_at`); `GET /api/v1/instances/:id/attachments` (`:AttachmentsRead`) → `200
    {"items": [...same shape...], "next_cursor"}`; `DELETE
    /api/v1/instances/:id/attachments/:attachment_id` (`:AttachmentsManage`) → `204`.
    (REQ-212, unchanged by REQ-386/387.)
- `test/uat-reports/gui-review-2026-09-20-attachment-cross-tenant-probe.md` (full,
  including the 2026-09-23 DOC-UPDATER closing note) — confirms REQ-386/388 are both
  merged to `main`, REQ-387 is the last of the three still `pending`, and that no
  frontend surface of any kind exists yet (zero `attachment` hits grepped in `web/src/`
  as of that review).
- `test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml` (full) —
  the origin scenario: actors (`swiftroute_dispatcher`, `swiftroute_ops`,
  `vortex_user`), five steps, EO-001..EO-005, and the stale ISS-0527 `NOTE` block this
  requirement's own AC6 requires removing.
- `web/src/api/entities.ts` (full) — the named convention example: plain object of
  named functions wrapping `client.get/post/put/delete`, typed against
  `web/src/types/api.ts`, route table documented in a moduledoc-style file comment,
  `encodeURIComponent` on every path-interpolated id.
- `web/src/api/definitions.ts` (route table skim) — second convention example,
  confirms the same shape used across the codebase, not just `entities.ts`.
- `web/src/api/client.ts` (full) — confirms **no existing binary/blob fetch method**:
  `request()`'s success path only ever calls `response.json()` or, for `getText`,
  `response.text()`; there is no `getBlob`/`getArrayBuffer` anywhere in this file. This
  is a real gap this design must close (§2.2) — the document-viewer screen cannot
  render/download attachment bytes without one. Also confirms: token is held
  in-memory only (`_token` module variable, "never localStorage/sessionStorage per
  FNFR-06"), attached as `Authorization: Bearer <token>` inside `request()` itself —
  **this is the load-bearing fact that rules out a plain `<img src="...">` /
  `<a href="...">` pointed directly at the backend link-content URL** (§1, decision D1).
- `web/src/pages/instances/InstanceDetailPage.tsx` (imports/top-of-file structure
  read) — confirms the page's existing composition pattern (hooks from `@/hooks/`,
  components from `@/components/instances/`, `QueryStateBoundary`, `DataTable`,
  `Button`, `useToast`) that `AttachmentPanel` must match.
- `web/src/router.tsx` (full) — confirms the flat `{ path, element }` array-of-children
  convention under the single `ProtectedRoute`-wrapped `AuthenticatedShellRoot`, and
  the existing `instances/:id` entry this design's new route sits beside.
- `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts` (full, 632 lines) — the
  most recent, most rigorous e2e-pipeline precedent in this session: `createPipeline`/
  `pl.step`/`pl.gate`/`pl.onCleanup` structure, real second-tenant onboarding via
  direct-SQL `tenant_memberships` insertion (`db-exec.ts`), `navigateSpa`,
  `loginWithToken`, `getKeycloakToken`, `authHeaders`, `shot`, and — critically — this
  session's own established practice of **stating a defect found live rather than
  loosening the spec to pass around it**, which this design's own test-authoring
  guidance (§4) follows.
- `web/tests/e2e/pipeline.ts` (signatures read: `getKeycloakToken`, `loginWithToken`,
  `navigateSpa`, `authHeaders`, `shot`, `createPipeline`) and `web/tests/e2e/db-exec.ts`
  (function names only) — confirms the exact helper signatures §4 calls.
- `lib/letflow/design/req388-attachment-access-denial-audit.md` — skimmed to confirm
  (per this requirement's own handoff note) that REQ-388's audit write is
  server-side-only, fires on the existing content route's denied branches, and
  requires no frontend change of any kind — nothing in this design duplicates it.

---

## Acceptance-criteria map

| AC | Design element |
|---|---|
| 1. `web/src/api/` gains a typed client for upload/list/signed-link, matching `entities.ts`'s conventions | §2 (`web/src/api/attachments.ts`, `client.getBlob`) |
| 2. Document-viewer screen renders the document for a same-tenant, valid, unexpired link | §3.2 (`AttachmentViewerPage`), §3.3 state `success` |
| 3. Same screen, foreign-tenant vs never-issued attachment reference → byte-identical markup/text | §3.3 state `not-found` (`AttachmentNotFoundScreen`, zero per-request interpolation); §5.1 (snapshot/DOM-equality assertion design) |
| 4. Same screen, expired-link response → distinct expired message, no document content, fresh-link affordance | §3.3 state `expired` (`AttachmentLinkExpiredScreen`); §3.4 (`requestFreshLink`) |
| 5. `attachment-cross-tenant.pipeline.e2e.spec.ts` exists, real, passes | §4 (full scenario design, steps 1–5, EO-001..EO-005 mapped to concrete assertions) |
| 6. Stale ISS-0527 NOTE removed once REQ-386 and REQ-387 both ship | §6 |

---

## 1. Mechanism overview and the one load-bearing decision (D1)

**D1 — the viewer never points a plain HTML element (`<img src>`, `<a href>`,
`<iframe src>`) directly at a backend attachment URL.** `client.ts`'s `request()`
attaches the bearer token as an `Authorization` header on every call it makes; nothing
in this codebase persists the token anywhere a browser-native resource-fetch (image
load, anchor navigation, iframe navigation) could attach it (§0, `client.ts` finding).
A bare `<img src="/api/v1/instances/.../link-content?link_token=...">` would be
fetched by the browser with **no** `Authorization` header and would 401 against the
same `:AttachmentsRead`-gated pipeline every other route in this codebase requires
(confirmed by REQ-386 design §9 OQ-1: the link-content route stays behind the standard
auth pipeline, deliberately, and building an unauthenticated variant was explicitly
left as unscoped follow-up work, not assumed done here).

Consequence: every fetch of attachment bytes — for inline rendering *and* for
"download" — goes through the typed API client using `fetch()` + the existing
`Authorization` header machinery, is read into memory as a `Blob`, and is displayed/
offered for download via a browser-local `URL.createObjectURL(blob)` reference. This
is why §2.2 adds `client.getBlob` rather than treating attachment viewing as "just a
link."

**Flow, in order:**
1. User opens `AttachmentViewerPage` at `/instances/:id/attachments/:attachmentId`
   (no query string) — reached either from a fresh click of `AttachmentPanel`'s
   "View" action, or by direct/bookmarked navigation (the scenario's "using the
   reference he was given ... navigates directly to the address").
2. On mount, if the URL carries no `link_token` query param, the page calls
   `attachmentsApi.issueLink(instanceId, attachmentId)` (`POST .../link`). On success
   it **rewrites its own URL** (via `useNavigate(..., { replace: true })`) to append
   `?link_token=<token>`, then proceeds to step 3. On a `404`, it renders
   `AttachmentNotFoundScreen` and stops (no further calls).
3. The page calls `attachmentsApi.fetchLinkContent(instanceId, attachmentId, token)`
   (`GET .../link-content`, via `client.getBlob`). `200` → renders `success` state
   (§3.3). `410` → renders `AttachmentLinkExpiredScreen`. `404` (the rare
   deleted-after-issuance case) → renders the **same** `AttachmentNotFoundScreen` as
   step 2's 404 (one shared component, one shared render path — see §3.3's note on
   why this is not a second, subtly-different "not found" surface).
4. If the URL **does** carry a `link_token` on mount (a reload/bookmark/copied-URL of
   step 2's rewritten address), the page skips straight to step 3 with that token —
   this is the mechanism that makes the scenario's step 4 ("keeps the link the screen
   used ... waits until it is older than the platform allows, and tries it again")
   concretely reproducible: "the link the screen used" is this page's own URL after
   its step-2 rewrite, which a user can copy, bookmark, or simply reload after the
   5-minute expiry.

This flow is the same for every caller — same-tenant, foreign-tenant, and
never-issued-reference alike take the identical two-network-call sequence with the
identical branching logic; only the two HTTP responses differ, per REQ-386's own
server-side folding (§0).

**D2 — the signed link token is deliberately placed in the browser URL
(`setSearchParams({ link_token: token }, { replace: true })`, §1 step 2 / §3.2 step 2),
and this is a disclosed security tradeoff, not a side-effect-free convenience.**

- **What this costs.** Once written, `link_token` sits in the visible address bar for
  the remainder of the link's lifetime (up to the shipped 300-second expiry,
  `@link_expiry_seconds`, §0). It is therefore: visible to anyone glancing at the
  screen or a screen-share; captured by browser history (`replace: true` avoids
  pushing a *second* history entry on top of the pre-rewrite URL, but does **not**
  remove the token from the *current* entry — that entry, carrying the token, is what
  history sync, "recently visited" surfaces, and omnibox autocomplete persist);
  syncable to a user's other signed-in devices via browser history sync where enabled;
  and recoverable from local browser history/autocomplete on a shared or
  since-compromised machine, for as long as that browser retains history (which
  routinely outlives the token's own 300-second server-side validity, but the token is
  useless past expiry regardless — see below).
- **What bounds it.** The token is single-purpose (scoped to one attachment id,
  embedded and verified server-side per REQ-386 §2.3) and expires in ≤300 seconds
  server-side regardless of how long the URL persists in history. A history entry
  recovered after expiry yields a `410` (§3.3 `AttachmentLinkExpiredScreen`), not
  renewed access — the exposure window for actually *usable* replay is the same
  ≤300-second bound the design already accepts for reload/bookmark reproducibility
  (§1 step 4's stated purpose), not an unbounded one. This design accepts the
  history/omnibox/sync exposure described above **given that bound** — this is a
  considered tradeoff (reproducible reload/bookmark UX vs. a short-lived credential
  sitting in browser-persisted surfaces), not an overlooked one, and is flagged here
  explicitly rather than folded silently into D1's "no bearer-token-less browser
  navigation" framing, which is a different concern (missing `Authorization` header)
  than this one (token visible in a browser-persisted surface at all).
- **Referer-leak check — verified against this design's actual page structure, not
  assumed safe.** A tokened URL sitting in the address bar is only a leak risk if the
  page itself *navigates away* to a third-party/cross-origin destination while that
  URL is current (the browser's `Referer` header on such a navigation would carry the
  full current URL, tokened query string included, to that third party). Checked
  against §3.3's full enumeration of everything `AttachmentViewerPage` and its four
  state sub-components render:
  - `AttachmentSuccessView`: `<iframe>`/`<img>` point at `URL.createObjectURL(blob)` —
    a same-origin, browser-local `blob:` URL, not the tokened backend URL (per D1);
    the download affordance is a `download`-attributed `<a>` also pointed at the same
    `blob:` object URL, which triggers a same-origin save rather than a navigation.
    No third-party origin appears anywhere in this component.
  - `AttachmentNotFoundScreen`, `AttachmentLinkExpiredScreen`, `AttachmentErrorScreen`:
    fixed heading/body text only, plus (on the expired screen) one in-page `Button`
    wired to `requestFreshLink` (§3.4) — an internal state-machine call, not a
    navigation or anchor of any kind.
  - No "download original," "open in new tab," support/help link, or any other
    outbound `<a>`/`<iframe>` to an external or third-party origin exists anywhere in
    this design's component set for `AttachmentViewerPage` — confirmed by this
    enumeration, not assumed. (`AttachmentPanel`, §3.1, is a **different** page —
    `InstanceDetailPage` — and its "View" affordance is a same-origin React Router
    `Link` to this very route, not an external link either.)
  - Conclusion: with no outbound cross-origin navigation anywhere on this page while
    the tokened URL is current, the `Referer`-leak vector does not apply to this
    design as built. This conclusion is scoped to *this* design's component set — it
    would need re-checking if a future requirement adds any external-facing link
    (e.g. a "view in external viewer" affordance) to this page.

---

## 2. API client layer

### 2.1 New types — `web/src/types/api.ts` additions

```
export interface Attachment {
  id: string
  instance_id: string
  file_name: string
  content_type: string
  byte_size: number
  uploaded_by: string
  description: string | null
  created_at: string
}

export interface AttachmentsPage {
  items: Attachment[]
  next_cursor: string | null
}

export interface AttachmentLink {
  attachment_id: string
  token: string
  url: string
  expires_at: string          // ISO8601
  expires_in_seconds: number
}

/** Result of a successful attachment-bytes fetch — never persisted, only ever
 *  held in page-local state for the lifetime of one viewer-page mount. */
export interface AttachmentBlob {
  blob: Blob
  contentType: string
}
```

Field names/casing match the shipped JSON verbatim (`attachment_json/1` and the
`POST .../link` response body, both read from source in §0) — no camelCase
translation layer, consistent with `entities.ts`'s own untranslated field names.

### 2.2 `client.ts` addition — `getBlob`

**New method, additive only — no existing `client.*` method is changed.**

```
/** Fetches a binary response as a Blob, attaching the same Authorization/
 *  x-bpm-user-id headers request() already attaches for json/text calls.
 *  On a non-2xx response, parses the RFC 9457 problem body exactly as
 *  request()'s existing !response.ok branch does and throws the same
 *  ApiError shape (status, message, code, details) -- callers branch on
 *  err.status (404 / 410 / other), not on a blob-specific error type. */
getBlob(path: string, params?: Record<string, unknown>): Promise<{ blob: Blob; contentType: string }>
```

**Behavior description (no body):** builds the query string the same way `get`
already does; issues `window.fetch` with the same header-building logic `request()`
uses today (`Authorization`, `x-bpm-user-id`, no `Content-Type` since there is no
request body); on `response.status` in `{401, 429, 409}` or `!response.ok`, delegates
to the **same** error-construction logic `request()` already has (this is a shared
concern — implementer's choice whether `getBlob` calls a refactored-out
`handleErrorResponse(response)` helper or duplicates the four branches; either is
acceptable, this document does not mandate an internal refactor of `request()`, only
that the four existing error branches — 401/429/409/generic-!ok — are not
silently skipped for blob calls, since a signed-link 410 must still surface with
`status: 410` on the thrown `ApiError` for §3.3's branching to work); on success,
reads `response.blob()` and `response.headers.get('Content-Type')`, returns both.

No new dependency — `Blob`/`response.blob()` are native `fetch` API surface, already
available in every browser this codebase targets (Playwright's Chromium included).

### 2.3 New module — `web/src/api/attachments.ts`

Follows `entities.ts`'s file shape exactly (moduledoc-style top comment naming the
real route table, `encodeURIComponent` on every interpolated id, plain object of named
functions).

```
import { client } from './client'
import type { Attachment, AttachmentsPage, AttachmentLink, AttachmentBlob } from '@/types/api'

export const attachmentsApi = {
  /** `POST /api/v1/instances/:id/attachments`, multipart. `file` required,
   *  `description` optional -- matches upload_attrs_from_conn/3's own two
   *  accepted body_params fields exactly (lib/letflow/routers/instances.ex,
   *  REQ-212 design §5.4). Caller builds and passes the FormData; this
   *  function does not construct it, to avoid this file taking a dependency
   *  on browser File/FormData construction conventions beyond passing it
   *  through -- matches client.post's own existing `body instanceof FormData`
   *  passthrough (client.ts, unchanged). */
  upload: (instanceId: string, formData: FormData) => Promise<Attachment>

  /** `GET /api/v1/instances/:id/attachments` -- cursor-paginated, matching
   *  Attachments.list/2's {items, next_cursor} shape (REQ-212). */
  list: (instanceId: string, params?: { cursor?: string; page_size?: number }) => Promise<AttachmentsPage>

  /** `POST /api/v1/instances/:id/attachments/:attachment_id/link` -- REQ-386.
   *  Issues a fresh, independently-valid 5-minute signed link every call (no
   *  idempotency/reuse contract -- REQ-386 design §2.2 AC3). */
  issueLink: (instanceId: string, attachmentId: string) => Promise<AttachmentLink>

  /** `GET /api/v1/instances/:id/attachments/:attachment_id/link-content` --
   *  REQ-386. `token` is passed as the `link_token` query param, matching the
   *  shipped route's own query-param name exactly (verified in §0, not
   *  guessed). Uses client.getBlob (§2.2), not client.get -- attachment bytes
   *  are binary, never JSON. */
  fetchLinkContent: (instanceId: string, attachmentId: string, token: string) => Promise<AttachmentBlob>
}
```

Every path segment (`instanceId`, `attachmentId`) is `encodeURIComponent`-wrapped,
matching `entities.ts`'s own discipline — attachment/instance ids are UUIDs in
practice but this design does not special-case that assumption into the client.

---

## 3. Frontend components

### 3.1 Upload/list widget — `AttachmentPanel`

`web/src/components/instances/AttachmentPanel.tsx`. Mounted inside
`InstanceDetailPage.tsx` (alongside the existing `EventHistoryPanel`/`TimelineFeed`
components it already composes — same "one focused panel component per concern"
pattern that page already follows, per §0's read of its import list).

**Props:**
```
interface AttachmentPanelProps {
  instanceId: string
}
```

**Responsibilities (prose, no implementation):**
- On mount, and after every successful upload, calls `attachmentsApi.list(instanceId)`
  (via a `useQuery`-style hook, matching this page's existing `useInstance`/`useTasks`
  hook-per-concern convention — a new `useAttachments(instanceId)` hook in
  `web/src/hooks/useAttachments.ts` is the natural home, mirroring `useInstances.ts`'s
  own shape; this document does not mandate the exact hook-file split, only that the
  panel does not call `attachmentsApi` directly inline without going through this
  codebase's established query-hook layer).
- Renders the list via `DataTable` (matching `InstanceDetailPage`'s own existing use
  of `DataTable` for its pending-task rows) with columns: file name, size
  (human-readable), uploaded-by, uploaded-at, and a "View" action per row —
  `<Link to={"/instances/" + instanceId + "/attachments/" + attachment.id}>` (a real
  SPA route link, React Router `Link`, not a raw anchor to the backend — consistent
  with D1).
- Renders a file-picker + optional description field + "Upload" `Button` above the
  table. On submit: builds a `FormData` (`file`, and `description` only if
  non-empty — matching the backend's own `attachment_description/1` "empty string
  treated as absent" convention read in §0), calls `attachmentsApi.upload`, shows a
  `useToast` success/error notification (matching this page's existing toast usage for
  `useCancelInstance`), and triggers a list refetch.
- Client-side validation: none beyond "a file must be selected" — the backend's own
  `@max_upload_bytes` / infection-scan / content-type rules are the enforcement point
  (REQ-211/REQ-399 design precedent); this panel surfaces whatever `ApiError` those
  produce (413 `file_too_large`, 422 `infected`/`scan_unavailable` detail strings) via
  the same toast mechanism, not a duplicated client-side size check that could drift
  from the server's real limit.

### 3.2 Document-viewer page — `AttachmentViewerPage`

`web/src/pages/instances/AttachmentViewerPage.tsx`. New `router.tsx` entry:

```
{ path: 'instances/:id/attachments/:attachmentId', element: <AttachmentViewerPage /> },
```

Placed directly after the existing `{ path: 'instances/:id', element:
<InstanceDetailPage /> }` line — same file, same flat array, no new nesting level (this
router has no `<Route>`-with-`children` JSX shape at all per §0's read; it is a plain
`createBrowserRouter` array, so "nested under the instance detail route" (the
requirement's own phrasing) means path-prefix nesting only, not a React-Router
parent/child route relationship).

**Route params consumed:** `id` (instance id), `attachmentId` — both via
`useParams<{ id: string; attachmentId: string }>()`, matching
`InstanceDetailPage.tsx`'s own `useParams` usage (confirmed in its imports, §0).
**Query param consumed:** `link_token` (optional), via `useSearchParams()`.

**Internal state machine (one `status` field driving §3.3's rendering):**

```
type ViewerStatus =
  | { kind: 'loading' }
  | { kind: 'success'; blob: Blob; contentType: string; fileName: string | null }
  | { kind: 'not-found' }
  | { kind: 'expired' }
  | { kind: 'error' }   // any other status (422/500/etc) -- see §3.3 note
```

**Effect/behavior, per §1's flow:**
1. `loading` is the initial and only pre-network state.
2. If `link_token` search param is absent: call `issueLink`. Success →
   `setSearchParams({ link_token: token }, { replace: true })` then proceed to step 3
   with that token (no extra render in between — the token is threaded directly into
   the immediately-following `fetchLinkContent` call, not round-tripped through a
   re-render first, so there is no visible intermediate "issued but not yet fetched"
   flash). Failure with `err.status === 404` → `status = { kind: 'not-found' }`.
   Failure with any other status → `status = { kind: 'error' }` (§3.3 note).
3. Call `fetchLinkContent(id, attachmentId, token)`. Success → `status = { kind:
   'success', blob, contentType, fileName: null }` (§2.2's `getBlob` does not surface
   a filename — REQ-386's shipped response has none either; §3.3 addresses this).
   Failure with `err.status === 410` → `status = { kind: 'expired' }`. Failure with
   `err.status === 404` → `status = { kind: 'not-found' }` (same value/same rendered
   component as step 2's 404 — see §3.3). Any other status → `status = { kind: 'error'
   }`.
4. If `link_token` search param **is** present on mount, skip step 2 entirely and go
   straight to step 3 with that token — this is the "reload the same URL" replay path
   (§1 step 4).

### 3.3 Three response-state renderings

**`AttachmentSuccessView`** (rendered for `status.kind === 'success'`):
- `contentType` starting with `application/pdf` → `<iframe>` (or `<embed>`, either is
  an implementation-time choice not load-bearing to this design) pointed at
  `URL.createObjectURL(blob)`, revoked (`URL.revokeObjectURL`) on unmount — standard
  React-cleanup-effect discipline, called out explicitly here because a leaked object
  URL is a real memory-leak risk this design does not want silently glossed over.
- `contentType` starting with `image/` → `<img>` at the same object URL, with
  `alt="attachment"` (no real filename available from the response — §3.2 step 3
  note; §9 OQ-1 flags whether REQ-212/386 should be extended to surface `file_name`
  on the link/link-content response, not resolved here).
- Any other `contentType` → a download affordance: an `<a>` whose `href` is the same
  object URL and `download` attribute is set (a `download`-attributed anchor pointed
  at a `blob:` URL triggers a same-origin, browser-native save — it does **not**
  re-request the backend, so D1's "no bearer-token-less browser navigation to the
  backend" constraint is not violated; the bytes are already in memory from step 3's
  authenticated fetch).

**`AttachmentNotFoundScreen`** (rendered for `status.kind === 'not-found'`, reached
from either the issuance 404 or the content-fetch 404): **zero props, zero
interpolated data.** Fixed heading + fixed body text (e.g. "Document not found." / "This
document does not exist or you do not have access to it.") — no attachment id, no
instance id, no error `detail` string from the response body, nothing derived from
which of the two calls (issuance vs content-fetch) produced the 404. This is the
mechanical guarantee AC3/EO-001/EO-002 rest on: since the component takes no
data-bearing props at all, it is **structurally impossible** for its rendered output
to differ between a foreign-tenant reference and a never-issued one — there is no
code path by which per-request information could reach this component's render output,
mirroring REQ-386's own server-side INV-5 argument (§0) at the GUI layer, by the same
"the differing information is never passed across the boundary" technique rather than
merely "the two current call sites happen to produce the same string."

**`AttachmentLinkExpiredScreen`** (rendered for `status.kind === 'expired'`): fixed
heading (e.g. "Link expired") + fixed body text distinct in wording from the
not-found screen (e.g. "This link has expired. Request a new link to view this
document.") + one `Button` labelled "Request new link" wired to `requestFreshLink`
(§3.4). No document content of any kind is rendered in this state — `status.kind ===
'expired'` and `status.kind === 'success'` are mutually exclusive by construction (one
`ViewerStatus` union, one `status` field), so there is no code path that could render
both simultaneously.

**`AttachmentErrorScreen`** (rendered for `status.kind === 'error'` — 422/500/other):
a generic "Something went wrong loading this document." fallback. **Deliberately a
separate component from `AttachmentNotFoundScreen`**, not folded into the same 404
bucket — folding a 422 (malformed id, effectively unreachable via normal in-app
navigation but reachable via a hand-edited URL) or a 500 into the same
byte-identical-required not-found surface would blur AC3's strict "404-only" contract
with an unrelated error class the requirement never asked to be indistinguishable from
anything. Flagged as a deliberate scope boundary, not silently folded — see §9 OQ-2.

### 3.4 `requestFreshLink`

Not a full re-mount: calls `issueLink` again, on success calls `setSearchParams({
link_token: newToken }, { replace: true })` and re-runs step 3 of §3.2's flow with the
new token (`status` returns to `loading` in between). On a repeat failure, follows the
same branching as §3.2 step 2. This is the concrete mechanism behind EO-004's "a fresh
link works" and AC4's "offers a way to request a fresh link."

---

## 4. Permanent Playwright spec design —
## `web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts`

Structured as `createPipeline`/`pl.step`/`pl.gate` (matching
`tenant-cache.pipeline.e2e.spec.ts`'s own shape, §0) inside one
`test.describe('Pipeline: attachment-cross-tenant-probe (PW-09)', ...)` block. Two
real tenants are required (`swiftroute` and `vortex`, matching the scenario's own
actor company names) — this is the same "genuinely separate tenant" cost class
`tenant-cache.pipeline.e2e.spec.ts`'s EO-001 test already pays (real schema migration,
`test.setTimeout(300_000)`), reused via the same `db-exec.ts` helpers
(`runSqlAgainstDevPostgres`, `insertTenantMembershipSql`/`deleteTenantMembershipSql`,
`tenantSchemaName`) rather than inventing a second provisioning technique. If a
SwiftRoute-equivalent tenant already exists as a stable seeded fixture elsewhere in
this suite (not confirmed in this design pass — FRONTEND-DEV should check
`priv/keycloak/realms/*.json` and existing e2e fixture tenants before provisioning a
new one), reusing it is preferable to onboarding a fresh tenant per run; this document
does not mandate which, since it is an implementation-time cost/stability tradeoff, not
a scenario-design question.

**Fixture data:**
- `swiftrouteTenant`: existing default tenant (`bpm-default`) or a freshly onboarded
  one — houses the shipment-approval instance and its attached delivery note.
- `vortexTenant`: a second, genuinely separate tenant (own Postgres schema, per
  `tenant-cache.pipeline.e2e.spec.ts`'s own established technique) — houses the
  `vortex_user` actor, who has **no** membership or visibility into SwiftRoute's
  tenant at all.
- One process definition with a single human-task node (reusing the minimal
  start→task→end graph shape `tenant-cache.pipeline.e2e.spec.ts` step 01 already
  established) started as one instance in SwiftRoute's tenant — real work, not a
  synthetic-fixture-only object, matching this scenario's own "an open shipment
  approval task exists" precondition.

**Step design (mirrors the scenario's five steps and `expected_outcomes`):**

- **Step 1 (SwiftRoute dispatcher attaches a document, captures its reference).**
  Log in as a SwiftRoute user (`getKeycloakToken` + `loginWithToken`), `navigateSpa` to
  the instance detail page, use `AttachmentPanel`'s real upload UI (file input +
  Upload button) to attach a real small PDF fixture (or via `request.post`'s
  `multipart` option directly against the API, matching the "seed via real HTTP write
  path" precedent `tenant-cache.pipeline.e2e.spec.ts` step 01 uses for definitions —
  either is acceptable; using the real UI upload at least once is preferred per this
  session's established practice of driving the real screen, not just seeding via API,
  wherever the scenario's own step says "logs in ... attaches"). Capture the resulting
  `attachment_id` and `instance_id` — the "reference the screen shows," concretely
  `AttachmentPanel`'s list row now visible after upload, whose "View" link's `href`
  names both ids. `pl.gate` on the row being visible and the ids being extractable
  (via `extractIdFromUrl` on the `Link`'s `href`, matching this helper's existing use
  elsewhere in the suite per §0).

- **Step 2 (Vortex user opens the foreign reference; EO-001/EO-002).** Log in as the
  Vortex user, `navigateSpa` directly to
  `/instances/${swiftrouteInstanceId}/attachments/${swiftrouteAttachmentId}` (the
  "using the reference he was given ... navigates directly to the address" language,
  realized as a direct SPA URL navigation — this is the concrete GUI analog of
  "typing/pasting a URL," which is what the scenario's own prose describes). Wait for
  `AttachmentNotFoundScreen`'s fixed heading/body to render (a stable `data-testid`,
  e.g. `data-testid="attachment-not-found"`, is the assertion anchor — not raw text
  matching, to stay resilient to copy changes, matching this session's established
  `data-testid`-first assertion convention seen in `tenant-cache.pipeline.e2e.spec.ts`'s
  own `tenant-switcher-*` testid references). `shot(page, ..., 'foreign-tenant-attachment')`.
  Capture the full rendered text content of the screen's root container (e.g.
  `page.locator('[data-testid="attachment-not-found"]').innerText()`) for step 3's
  comparison. Assert: no text anywhere on the page contains the real document's file
  name (`delivery-note-hamburg.pdf`) or any digits matching its `byte_size` — the
  concrete EO-002 assertion ("no partial preview... no file name... no size").

- **Step 3 (Vortex user opens a never-issued reference; EO-001).**
  `navigateSpa` to `/instances/${randomUUID()}/attachments/${randomUUID()}` — a
  syntactically valid but never-issued instance/attachment id pair (matching the
  scenario's own "a reference that has never been issued" and REQ-386's own AC4 test
  precedent of exercising a genuinely-never-issued id, not just a foreign-tenant one).
  Wait for the same `data-testid="attachment-not-found"` element, `shot(...,
  'never-issued-attachment')`, capture its `innerText()`. **The core EO-001 assertion:**
  `expect(step3Text).toBe(step2Text)` — direct string equality between the two
  captured texts, not "both show an error" (the requirement's own AC3 wording,
  satisfied literally). Additionally assert the two screenshots' pixel dimensions/DOM
  structure match via `expect(await page.locator('[data-testid="attachment-not-found"]').screenshot()).toEqual(...)`-style
  buffer comparison **only if** Playwright's visual-comparison baseline tooling is
  already established elsewhere in this suite (not confirmed in this design pass —
  FRONTEND-DEV should check for an existing `toMatchSnapshot`/pixel-diff convention
  before introducing image-snapshot baselines here for the first time; the `innerText`
  equality check alone already satisfies AC3's literal wording and is this design's
  required minimum, the pixel comparison is a nice-to-have addition, not a blocking
  requirement of this design).

- **Step 4 (SwiftRoute ops opens the real document, then reuses an expired link;
  EO-003/EO-004 first half).** Log in as a second SwiftRoute user (`swiftroute_ops`,
  distinct from the dispatcher — matching the scenario's own two-actor split within
  one tenant), `navigateSpa` to the real
  `/instances/${swiftrouteInstanceId}/attachments/${swiftrouteAttachmentId}` URL (no
  `link_token` yet). Assert `AttachmentSuccessView` renders (e.g.
  `data-testid="attachment-content"` wrapping the `<iframe>`/`<img>`/download-`<a>`,
  whichever the fixture's PDF content type resolves to), `shot(..., 'ops-first-open')`
  — the EO-004-first-half assertion ("the delivery note is displayed... at step 4 on
  his first attempt"). Capture `page.url()` — this now carries the rewritten
  `?link_token=...` query param (§3.2 step 2's `setSearchParams` behavior) — this is
  "the link the screen used." **Expiry, without a real 5-minute wait:** REQ-386's own
  AC2 test precedent (§0) established "inject/mock the clock or use a sub-second
  expiry in the test" as this codebase's accepted technique for testing expiry without
  a real sleep; the equivalent frontend-testable mechanism is **not** mocking
  `Date.now()` inside the SPA (the expiry is enforced server-side, not client-side —
  the SPA has no clock-dependent logic of its own to mock) but rather **re-navigating
  to the captured expired-eventually URL after the real token has already expired** —
  concretely, this spec should either (a) accept a real ~300s wait here bounded by
  `test.setTimeout`, mirroring this same file's own tenant-onboarding steps' generous
  budgets, or (b) — preferred, avoids a 5-minute real sleep — call
  `attachmentsApi`-equivalent raw HTTP (`request.post(.../link)`) a second time with a
  **direct, test-only backend clock-injection** if one exists for this endpoint. **No
  such test-only injection was found or built by REQ-386** (§0: `AttachmentLinks.issue/3`'s
  `opts[:now]` injection point is an *Elixir-internal* test hook, per REQ-386 design
  §2.2/§2.3 — it is not exposed through any HTTP parameter, so a Playwright test
  cannot reach it). **Flagged explicitly, not silently resolved (§9 OQ-3):** this
  design's default is option (a), a real wait using the shipped 300-second expiry
  (`@link_expiry_seconds`, REQ-386 design §2.1), inside a `test.setTimeout(420_000)`
  budget generous enough to absorb it — the same class of real-time cost this session's
  own tenant-onboarding specs already accept, not a novel pattern. After the wait,
  `navigateSpa` to the **same captured URL** (the one carrying the now-expired
  `link_token`) and assert `AttachmentLinkExpiredScreen` renders
  (`data-testid="attachment-link-expired"`), `shot(..., 'ops-expired-link')` — the
  concrete EO-003 assertion, and confirm no `data-testid="attachment-content"` element
  exists on the page at this point (the "no document content" half of AC4).

- **Step 5 (fresh link succeeds; EO-004 second half).** Click the "Request new link"
  button (`requestFreshLink`, §3.4) on the still-open expired-link screen — matching
  the scenario's own step 5 ("returns to the task and asks for the delivery note
  again"), realized as the in-page affordance rather than a fresh navigation (either
  is a faithful realization of the scenario's prose; using the in-page button
  additionally exercises §3.4's own mechanism, which a fresh `navigateSpa` would not).
  Assert `AttachmentSuccessView`/`data-testid="attachment-content"` renders again,
  `shot(..., 'ops-fresh-link')` — completes EO-004.

- **EO-005 (audit trail) is explicitly NOT re-verified by this spec.** REQ-388
  (`status: done`) already ships and independently tests the audit write on the
  denied-fetch branches server-side (§0); this spec's step 2/3 navigations do
  incidentally exercise those same denied branches (each 404 in steps 2/3 is a real
  `fetch_scoped_attachment_content`-adjacent denial), which is a reasonable
  side-confirmation, but this design does not add a `web/src/pages/admin/AuditLogPage.tsx`
  assertion here — that would duplicate REQ-388's own already-passing test coverage
  rather than testing anything this requirement's own scope owns. Stated explicitly
  per this document's own "OUT OF SCOPE" section, not silently skipped.

**Cleanup (`pl.onCleanup`):** delete the Vortex tenant's membership row (if freshly
provisioned) and best-effort Keycloak realm deletion, mirroring
`tenant-cache.pipeline.e2e.spec.ts`'s own cleanup exactly; the uploaded attachment and
instance are left in place, matching the origin scenario's own `cleanup:` block
("cancel_open_instances: true... The recorded history... is deliberately left in
place" — REQ-387's frontend spec does not need to duplicate instance-cancellation
logic the scenario's `cleanup:` block describes at the UAT-scenario level, since this
Playwright spec is the permanent regression artifact, not a UAT-scenario run itself;
FRONTEND-DEV may add an instance-cancel cleanup step if convenient, but it is not
required by this design to satisfy AC5).

---

## 5. Snapshot/DOM-equality assertion design (AC3 detail)

Restated concretely for TEST-DESIGNER/FRONTEND-DEV: AC3 requires "a snapshot or
explicit DOM assertion compares the two, not just 'both show an error.'" This design's
concrete mechanism (§4 step 3) is a **direct string-equality assertion** between the
two screens' captured `innerText()` — this satisfies the letter of AC3 (an explicit,
automated comparison of the two renders' actual content, immune to a future refactor
that keeps both screens "similar-looking" but subtly different) without requiring a
pixel-snapshot baseline file (which would need to be committed, re-generated on
intentional copy changes, and is a heavier CI dependency than this requirement's own
wording demands — "snapshot **or** explicit DOM assertion," and this design picks the
DOM-assertion branch of that "or").

---

## 6. ISS-0527 NOTE removal plan

`test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml`'s
`pipeline_test:` key currently carries:

```yaml
pipeline_test: web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts
# NOTE (ISS-0527): this spec file does not exist in R-Co's own web/ tree at the
# pinned commit either -- it is an aspirational forward-reference to a Playwright
# test that was never authored anywhere, gated on the same missing feature this
# scenario's own steps exercise. UAT-RUNNER cannot drive this pipeline_test yet;
# treat any run of this scenario as BLOCKED/UNBUILT_FEATURE on the frontend leg
# until FRONTEND-DEV authors it against a real shipped feature.
# UAT-RUNNER drives this Playwright pipeline test for all steps. If this file does
# not exist or the test cannot run, that is a BLOCKER (missing UI) and must be
# routed to FRONTEND-DEV before UAT can proceed.
```

**Once §4's spec file exists, passes, and this requirement plus REQ-386 are both
`status: done`** (REQ-386 already is), the four comment lines starting at `# NOTE
(ISS-0527)` through `... before UAT can proceed.` are deleted in full, leaving only
the file's own top-of-file header block (the "Ported verbatim from R-Co..." comment,
unrelated to ISS-0527, left untouched) and the bare `pipeline_test:` key. This is a
one-time, straightforward text deletion — no other line in the scenario file changes.
**This edit is FRONTEND-DEV's own responsibility as part of implementing this
requirement** (the requirement's own AC6 states it directly: "removed once this
requirement and REQ-386 both ship" — REQ-386 already has, so this requirement's own
completion is the sole remaining gate), not a follow-up DOC-UPDATER task, since it is
mechanically tied to this requirement's own AC5 (the spec existing and passing) rather
than a documentation-only status flip.

---

## 7. Cross-module dependencies

| Module | What this design uses from it | Changed? |
|---|---|---|
| `web/src/api/client.ts` | `get`/`post` (existing, reused by `attachments.ts` for JSON calls); new `getBlob` | Yes — additive only |
| `web/src/api/attachments.ts` | new module | Yes — new file |
| `web/src/types/api.ts` | new `Attachment`/`AttachmentsPage`/`AttachmentLink`/`AttachmentBlob` types | Yes — additive only |
| `web/src/hooks/useAttachments.ts` (new, natural home) | query-hook wrapper over `attachmentsApi` | Yes — new file |
| `web/src/components/instances/AttachmentPanel.tsx` | new component | Yes — new file |
| `web/src/pages/instances/AttachmentViewerPage.tsx` | new page + its 4 state sub-components | Yes — new file(s) |
| `web/src/pages/instances/InstanceDetailPage.tsx` | mounts `<AttachmentPanel instanceId={id} />` | Yes — additive (one new import + one new JSX element in its existing composition) |
| `web/src/router.tsx` | one new route entry | Yes — additive only |
| `test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml` | ISS-0527 NOTE removal | Yes — deletion only, per §6 |
| `web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts` | new spec | Yes — new file |
| `lib/letflow/routers/instances.ex` (REQ-386/212, shipped) | consumed as-is, read-only | No |

---

## 8. Open questions

**OQ-1 — no filename/original-name surfaces on the link/link-content response.**
REQ-386's shipped `POST .../link` response and `GET .../link-content` response both
omit `file_name` (§0 — confirmed from the actual route handlers, not assumed); the
viewer therefore cannot show "delivery-note-hamburg.pdf" as a heading or use it as the
`download` attribute's suggested filename, only a generic fallback (`alt="attachment"`,
no `download="..."` value, so the browser falls back to its own default save-name,
usually derived from the blob URL rather than a real name). Not resolved here — a
future requirement could extend either response to include `file_name`/`content_type`
explicitly (content_type is already available via the `Content-Type` response header
for `link-content`, but not the JSON body of `link` itself, and `file_name` is on
neither). Flagged for REVIEWER; this design does not silently invent a client-side
filename lookup (e.g. a third API call to the list endpoint to cross-reference) since
that would add a third network round-trip and a new race (the list could have changed)
not asked for by this requirement's own acceptance criteria.

**OQ-2 — 422/500 responses render a third, non-byte-identical-required
`AttachmentErrorScreen` (§3.3).** This is a deliberate scope boundary this design
draws (not blurring an unrelated error class into the AC3 not-found guarantee), stated
explicitly per this document's own design-doc discipline of never silently resolving
an assumption. Flagged for REVIEWER in case a stricter reading of AC3 is intended to
cover every error class, not just 404 (this design's reading is that AC3's own wording
— "given a foreign-tenant attachment reference and a never-issued reference" — is
specifically about the 404-producing cases the requirement's own EO-001/EO-002
describe, not every possible HTTP error).

**OQ-3 — the e2e spec's expiry step (§4 step 4) has no test-only clock-injection
available through HTTP**, unlike REQ-386's own backend-level ExUnit test (which
injects `opts[:now]` directly, an Elixir-internal mechanism unreachable from
Playwright). This design's default is a real ~300-second wait inside a generous
`test.setTimeout`, the same cost class this session's tenant-onboarding specs already
accept. If that real-time cost proves unacceptable in CI, the alternative is a new,
separately-reviewable REQ-386 follow-up that exposes a test-only expiry override
(e.g. an `X-Test-Link-Expiry-Override` header honored only when a test-mode config
flag is set, mirroring how other short-TTL mechanisms in comparable codebases are
commonly tested) — not invented here, since REQ-386 is already `done` and reopening
its scope is a REVIEWER-level call, not this design's to make unilaterally. Flagged
for REVIEWER/TEST-DESIGNER.
