# ISS-0730 — Mount the promotion-review GUI flow (route + page + PLATFORM_ADMIN gating)

Status: design for CODE-DESIGN-VALIDATOR review. No implementation code below —
interfaces/props/route shapes only.

## 0. Independent verification of ISSUE-FIXER's diagnosis

Re-derived directly, not trusted on report alone:

- `web/src/router.tsx` (read in full): confirmed no route mentions `promotion`
  anywhere; `definitions/:id` (line 55) is the nearest sibling convention, a leaf
  under `AppShell`'s `children` array.
- `web/src/hooks/usePromotions.ts` and `web/src/api/promotions.ts` (read in full):
  `usePromotionContext`, `useApprovePromotion`, `useRejectPromotion`,
  `useApplyPromotion` all exist, typed, each mutation auto-invalidates
  `promotionKeys.context(reviewId)` on success — confirmed, no manual refetch
  needed.
- `PromotionReviewStateMachine.tsx` (read in full): props are exactly
  `{ review: PromotionReview; className?: string }` — confirmed.
- `NonSkippableApprovalGate.tsx` (read in full): props are exactly
  `{ context: PromotionContext; currentUserId: string; onTransition?: () => void;
  onApprove: (reviewId: string, planDigest: string) => Promise<void>; onReject:
  (reviewId: string) => Promise<void>; onApply: (reviewId: string, planDigest:
  string) => Promise<void>; className?: string }` — confirmed. It already renders
  `<PlanDigestView planDigest={review.plan_digest} plan={plan}
  digestVerified={digest_verified} />` internally (line 267) — confirmed
  `PlanDigestView` must **not** be rendered again by the new page.
- **Correction to the diagnosis:** `session.user_id` does **not** exist.
  `UserSession` (`web/src/types/api.ts:347`) has no `user_id`/`sub` field — only
  `token`, `display_name`, `roles`, `loginSource`, `tenant_*`. The project's
  established pattern for getting the current user's id is decoding the JWT
  `sub` claim from `session.token`, via the shared `decodeTokenPayload` helper in
  `web/src/auth/tokenUtils.ts` (already used by `AuthProvider.tsx`,
  `OidcCallbackPage.tsx`; `TaskInboxPage.tsx` does the equivalent with its own
  local duplicate — the new page uses the shared helper, not a third copy). See
  §2 for the exact call.
- `definitionsApi.promote` (`web/src/api/definitions.ts:55`) returns
  `PromoteResult { definition_id, version, status }` — **no `review_id` field**.
  This confirms ISSUE-FIXER's scope note: `DefinitionEditorPage.tsx`'s "Promote
  to Production" flow has no review id to link forward with, so a contextual
  link from that page is not possible without a new backend field — out of
  scope (§5).
- `AppShell.tsx`'s `NAV_ITEMS` (lines 19–47): confirmed every entry is a static,
  parameter-free path (`/definitions`, `/admin/users`, etc.); nothing in the
  array takes a dynamic id. Confirms a global nav entry has nothing meaningful
  to point at.

## 1. Decision: no nav entry, no contextual link — direct URL only

**Decision:** do not add anything to `AppShell.tsx`'s `NAV_ITEMS`, and do not add
a contextual "pending review" link to `DefinitionEditorPage.tsx` or
`DefinitionListPage.tsx` in this fix. The review page is reached only via a
direct URL (`/definitions/:id/promotions/:reviewId`) known to the reviewer
out-of-band — consistent with the UAT scenario's own actor model (step 1,
"create the review," is a system actor, not a GUI action; the reviewer receives
a known `reviewId`).

Rationale:

- No list endpoint exists (`GET /api/v1/promotions` is not in
  `lib/letflow/routers/promotions.ex` — confirmed by ISSUE-FIXER and not
  contradicted by my own read of `usePromotions.ts`/`promotions.ts`, which
  expose no `list`), so a static nav entry would 404 or need a placeholder
  list page nobody asked for.
- `PromoteResult` carries no `review_id`, so `DefinitionEditorPage.tsx` cannot
  build a real link to "the review that was just created" without a new
  backend field on the promote response — that is new backend scope, explicitly
  out of scope for this BLOCKER (§5).
- Adding a nav entry or contextual link that resolves to nothing (or requires
  new backend work) would be scope creep beyond "wire up the existing
  components," which is this issue's entire fix_direction.

This is a closed decision, not an open question — FRONTEND-DEV should not add a
nav entry or contextual link.

## 2. Route entry — `web/src/router.tsx`

Add one import, alongside the other page imports, matching the existing
`definitions/*` import block's ordering/style:

```
import PromotionReviewPage from '@/pages/definitions/PromotionReviewPage'
```

Add one leaf entry to the `children` array (immediately after
`definitions/:id`, i.e. after the existing line 55, to keep all `definitions/*`
routes grouped as they already are):

```
{ path: 'definitions/:id/promotions/:reviewId', element: <PromotionReviewPage /> },
```

No other route entries change. `:id` here is the process definition id (unused
by the page itself — see §3, kept in the URL only for breadcrumb/context and to
match the "child of a definition" convention `definitions/:id` already
establishes); `:reviewId` is the `PromotionReview.id` the page actually reads.

## 3. `web/src/pages/definitions/PromotionReviewPage.tsx` — new file

### 3.1 Top-level shape

- **Default export**, no props (`export default function PromotionReviewPage():
  React.ReactElement`) — same shape as every other routed page in this
  codebase (`UserDetailPage`, `AuditLogPage`, etc.), no `PromotionReviewPageProps`
  type needed.
- `useParams<{ id: string; reviewId: string }>()` — destructure `{ reviewId }`.
  `id` (the definition id) is read but not used for any query in this design;
  it exists only because the route is a child of `definitions/:id` per §2's
  convention. Do not thread it into any API call — `usePromotionContext` takes
  only `reviewId`.
- `useAuth()` → `{ session }`.
- Role gate, the identical pattern verified in `AuditLogPage.tsx:1,45,75-76`,
  `HealthDashboardPage.tsx:1,30,33-34`, and `MetricsPage.tsx:1,39,42-43` — all
  three use exactly this check-and-redirect, not `PermissionDenied` or
  `QueryStateBoundary`'s `'permission-denied'` state (that state/component is
  reserved for the server-side 403 case in §3.2, never for this client-side
  gate):
  ```
  const isPlatformAdmin = Boolean(session?.roles.includes('PLATFORM_ADMIN'))
  ...
  if (!isPlatformAdmin) {
    return <Navigate to="/instances" replace />
  }
  ```
  This is the single required pattern for the client-side role gate — not a
  choice between alternatives.
- Current-user id, decoded once via `useMemo`, matching `TaskInboxPage.tsx`'s
  established pattern but using the shared helper instead of a local
  duplicate:
  ```
  const currentUserId = useMemo(
    () => (session?.token ? decodeTokenPayload(session.token)?.sub ?? null : null),
    [session?.token],
  )
  ```
  imported as `import { decodeTokenPayload } from '@/auth/tokenUtils'`.
- Data: `const { data, isLoading, isError, error, refetch } =
  usePromotionContext(reviewId)`.
- Derive `state: RendererState` via `classifyError(error)` when `isError`,
  `'loading'` while `isLoading`, else `'success'` — same
  `isLoading`/`isError`/`classifyError` composition every other page in this
  codebase uses (e.g. `AuditLogPage.tsx`).
- Mutation hooks, called unconditionally at top level (rules-of-hooks): `const
  approveMutation = useApprovePromotion()`, `const rejectMutation =
  useRejectPromotion()`, `const applyMutation = useApplyPromotion()`.

### 3.2 Loading / error / not-found / wrong-tenant states

All routed through the existing `QueryStateBoundary` + `classifyError`
machinery — no new state-rendering component needed:

| Condition | `RendererState` | What renders |
|---|---|---|
| `usePromotionContext` in flight | `'loading'` | `QueryStateBoundary`'s skeleton (`SkeletonLayout`) |
| Reviewer is not `PLATFORM_ADMIN` (client-side gate, before any query) | n/a — short-circuit | `PermissionDenied` (same as `AuditLogPage.tsx` et al.) |
| Backend returns 403 (wrong tenant, or role check fails server-side per `promotions.ex`'s `Deny403`) | `'permission-denied'` | `QueryStateBoundary`'s `PermissionDenied` |
| Backend returns 404 (`reviewId` does not exist) | `'fetch-failure'` (no dedicated 404 state exists anywhere in this codebase's `RendererState` union — confirmed by reading `classifyError.ts` in full; every non-401/403/409/429 status falls through to `'fetch-failure'`, which is the established convention, not a gap introduced here) | `QueryStateBoundary`'s `FetchError`, with `onRetry={() => void refetch()}` |
| Any other network/5xx failure | `'fetch-failure'` | Same as above |
| Success | `'success'` | The two composed child components (§3.3) |

This means: the page does **not** need a bespoke "review not found" message
distinct from a generic fetch failure — that matches how every other
`:id`-keyed detail page in this codebase (`UserDetailPage.tsx`,
`InstanceDetailPage.tsx`) already handles a bad id, so this is consistency with
convention, not a shortcut.

### 3.3 Child component wiring (success state only)

```
<QueryStateBoundary state={state} onRetry={() => void refetch()}>
  {data && (
    <>
      <PromotionReviewStateMachine review={data.review} />
      <NonSkippableApprovalGate
        context={data}
        currentUserId={currentUserId ?? ''}
        onApprove={(reviewId, planDigest) =>
          approveMutation.mutateAsync({ reviewId, body: { plan_digest: planDigest, approved_by: currentUserId ?? '' } }).then(() => {})
        }
        onReject={(reviewId) => rejectMutation.mutateAsync(reviewId).then(() => {})}
        onApply={(reviewId, planDigest) =>
          applyMutation.mutateAsync({ reviewId, body: { plan_digest: planDigest } }).then(() => {})
        }
      />
    </>
  )}
</QueryStateBoundary>
```

Notes for FRONTEND-DEV (still design-level, not code — the block above is
illustrative shape only, exact statements are implementation's call):

- `onApprove`/`onReject`/`onApply` must return `Promise<void>` per
  `NonSkippableApprovalGateProps` — each mutate call's resolved value must be
  discarded (`.then(() => {})` or equivalent `void`-returning wrapper), since
  `mutateAsync` resolves to the mutation's data type, not `void`.
  `NonSkippableApprovalGate` already catches rejections internally (its own
  `try/catch` around each `on*` call, per the read in §0) and renders the
  matching inline error (`SelfApprovalError`, `DigestMismatchError`,
  `TransitionError`, `ExtraFieldsError`) — the page does not need its own
  try/catch around these calls.
- `ApprovePromotionRequest.approved_by` is a required field on the request
  body — populate it from the same decoded `currentUserId` used for the
  self-approval check, per `api/promotions.ts`'s `ApprovePromotionRequest`
  shape (`{ plan_digest: string; approved_by: string }`).
- No `onTransition` prop is wired — `NonSkippableApprovalGate`'s own mutation
  callers already invalidate `promotionKeys.context(reviewId)` on success
  (confirmed in `usePromotions.ts`, §0), so the page's own `usePromotionContext`
  refetches automatically; no manual `refetch()`/`onTransition` handler is
  needed for the page to reflect a state transition.
- Do not render `PlanDigestView` on this page directly — `NonSkippableApprovalGate`
  already composes it (§0).
- Do not render `ConflictRejectionAlert` on this page (§5).

### 3.4 Imports the new file needs

```
import { useParams } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { decodeTokenPayload } from '@/auth/tokenUtils'
import { usePromotionContext, useApprovePromotion, useRejectPromotion, useApplyPromotion } from '@/hooks/usePromotions'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { PermissionDenied } from '@/components/ui/PermissionDenied'  // if used for the client-side role gate
import { PromotionReviewStateMachine } from '@/components/promotions/PromotionReviewStateMachine'
import { NonSkippableApprovalGate } from '@/components/promotions/NonSkippableApprovalGate'
import { classifyError, type RendererState } from '@/utils/classifyError'
```

(Exact import paths for `PermissionDenied`/`SkeletonLayout` etc. — verify
against `web/src/components/ui/` at implementation time; `QueryStateBoundary.tsx`
itself imports `PermissionDenied` from `./PermissionDenied` alongside itself, so
`@/components/ui/PermissionDenied` is the corresponding public import path.)

## 4. `@spec`-equivalent TypeScript signatures

```
// New file: web/src/pages/definitions/PromotionReviewPage.tsx
export default function PromotionReviewPage(): React.ReactElement

// Route params (via useParams, not a named type — matches this codebase's
// convention of inline useParams<{...}>() generics rather than exported
// param types)
useParams<{ id: string; reviewId: string }>()
```

No new exported types are needed — every type consumed (`PromotionReview`,
`PromotionContext`, `PromotionReviewStateMachineProps`,
`NonSkippableApprovalGateProps`, `ApprovePromotionRequest`,
`ApplyPromotionRequest`, `RendererState`) already exists in
`web/src/api/promotions.ts` / `web/src/utils/classifyError.ts` and is imported,
not redefined.

## 5. Explicit non-goals

- **No new backend endpoint.** No `GET /api/v1/promotions` list route, no
  `review_id` added to `PromoteResult`. `lib/letflow/routers/promotions.ex` is
  unchanged by this fix.
- **No `ConflictRejectionAlert` wiring.** It handles submit-time 409 conflicts
  from a "start promotion" flow, which has no GUI entry point today (only
  `DefinitionEditorPage.tsx`'s `handlePromoteConfirm` calls
  `definitionsApi.promote`, and that call site is unaffected by this fix). It
  stays orphaned after this fix — a known, accepted scope boundary, not a bug
  this fix must also close.
- **No "start promotion" GUI change.** `DefinitionEditorPage.tsx`'s existing
  "Promote to Production" button/`ConfirmPromoteModal` flow is untouched.
- **No nav entry, no contextual link** — per §1's closed decision.
- **No new `RendererState` value / no bespoke "review not found" component** —
  per §3.2, a 404 falls through the existing `'fetch-failure'` path, matching
  every other detail page in this codebase.

## 6. Files this fix touches

- `web/src/router.tsx` — one import, one route entry (§2).
- `web/src/pages/definitions/PromotionReviewPage.tsx` — new file (§3).

No other file changes. `AppShell.tsx`, `PromotionReviewStateMachine.tsx`,
`PlanDigestView.tsx`, `NonSkippableApprovalGate.tsx`, `ConflictRejectionAlert.tsx`,
`usePromotions.ts`, `api/promotions.ts`, `lib/letflow/routers/promotions.ex` are
all unchanged.
