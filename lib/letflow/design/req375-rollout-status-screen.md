# REQ-375 — Operator-facing rollout-status screen (frontend)

**Status:** design, pre-implementation. **Owner:** FRONTEND-DEV (next step). **Stage:** S8.
**Depends on:** REQ-374 (shipped — `Letflow.Platform.MigrationRollout`,
`Letflow.Routers.PlatformMigrations`, merged `eaa8abe6`, PR #1693). This design builds
against that real, already-shipped HTTP surface — no mock data, no new backend
endpoint, no change to `lib/letflow/`.

## 0. Scope fence (restated from the requirement)

In scope: one operator console screen (route + component tree) that (1) lets a
PLATFORM_ADMIN-equivalent operator start a named platform-wide change against every
active company by calling `POST /platform-migrations/rollouts`; (2) renders, one row
per company, whether the change arrived, its completion time, and — for non-succeeded
companies — a readable reason, sourced from `GET /platform-migrations/rollouts/:id`;
(3) shows a resume control, visible only while the rollout has outstanding companies,
that calls `POST /platform-migrations/rollouts/:id/resume`; (4) lets the operator
re-start an already-fully-succeeded rollout and see the EO-005 no-op result rendered
distinguishably from a fresh run; (5) is reachable only from operator-console
navigation gated to PLATFORM_ADMIN, matching the existing nav-role-gating mechanism
in `AppShell.tsx`.

Out of scope (do not build): any new backend endpoint or response field beyond what
`lib/letflow/routers/platform_migrations.ex` already returns (§4 below is a literal
restatement of that router's response shapes — this design invents no new field); a
generic "pick which kind of platform-wide change to run" picker — REQ-374 itself proves
the mechanism against exactly one concrete change (entity-attribute column promotion),
so this screen's start form collects exactly the fields `start_rollout/3` accepts
(`entity_type`, `attribute`, `column_spec`), not a broader catalog; a rollout **list**
screen (browsing all past rollouts) — REQ-374 exposes no `GET /platform-migrations/rollouts`
collection endpoint, only get-by-id, so there is nothing to list against without a
fabricated client-side index (see OQ-1, §9).

## 1. Route and navigation gating (AC4)

### 1.1 Route

One new route, added to `web/src/router.tsx`'s existing route array (same
`ProtectedRoute > AppShell` subtree every other admin screen sits in — no new layout):

```
{ path: 'admin/platform-migrations', element: <PlatformMigrationConsolePage /> }
```

Single route, not two. §2 explains why the start-form and the status view live in one
page component rather than a `/admin/platform-migrations` (start) +
`/admin/platform-migrations/:rolloutId` (status) pair: REQ-374 exposes no
`column_spec` field on `GET /platform-migrations/rollouts/:id`'s response (the router's
`rollout_map/1` only serializes `id`, `entity_type`, `attribute`, `status`,
`started_at`, `completed_at` — see `lib/letflow/routers/platform_migrations.ex:183-192`),
so a page that only knows a `rolloutId` from the URL cannot reconstruct the exact
`column_spec` needed to re-submit the identical rollout for EO-005's "start it again"
step. Keeping the start form and the status view on one page, with the form's own
component state retained across a start/resume/re-run cycle, is what makes "starting
the identical rollout again" (scenario step 6) possible without inventing a
`column_spec`-return field REQ-374 never shipped. A `rolloutId` query param
(`?rollout=<uuid>`) is supported for deep-linking to an in-progress rollout's status
view (optional convenience, not required by any acceptance criterion) — when present,
the page skips rendering the start form area and jumps straight to fetching status for
that id; the form remains reachable via a "Start a different rollout" affordance that
clears the param.

### 1.2 Route guard — PLATFORM_ADMIN-only (AC4)

Same mechanism as `DefinitionRollbackPage.tsx` and `PlatformDashboardPage.tsx`
(`web/src/pages/dashboard/PlatformDashboardPage.tsx:29-33`), not a new gating
primitive: the page component itself reads `useAuth().session.roles`, computes
`isPlatformAdmin = session?.roles.includes('PLATFORM_ADMIN') ?? false`, and renders
`<Navigate to="/instances" replace />` before returning any of the page's real markup.
React's rules of hooks require `useRolloutStatus`/`useTenantNameLookup`'s underlying
`useQuery` calls to be invoked unconditionally, ahead of this early return — so a
non-admin who deep-links directly to the URL does cause the component to issue its
`platform-migrations`/tenant-list requests before the redirect commits (mirroring
`PlatformDashboardPage.tsx:23-32`'s identical pattern, not a new gap this design
introduces). Those requests still 403 at the real backend gate (§7 of the REQ-374
design's `:TenantsManage` check), so no tenant data reaches the unauthorized client;
the guard's actual guarantee is "never render the screen," not "never issue a
request." This is a **client-side route guard**, not a new server permission decision — REQ-374's
`:TenantsManage` permission check on every one of the three HTTP endpoints (§7 of the
REQ-374 design, unchanged by this requirement) is what actually enforces the
restriction; the client-side check is a UX courtesy (hide the screen, avoid a 403
round-trip) exactly like the two existing precedents, not a substitute for it. No new
role/permission taxonomy is introduced — `PLATFORM_ADMIN` is read from the same
`session.roles` array every other admin screen already reads.

### 1.3 Navigation entry

One new entry in `web/src/components/layout/AppShell.tsx`'s nav-item array (same
array `admin/tenants`, `admin/onboarding/new`, etc. already live in, `roles:
['PLATFORM_ADMIN']`):

```
{ to: '/admin/platform-migrations', label: 'Platform Migrations', roles: ['PLATFORM_ADMIN'] }
```

`AppShell.tsx`'s existing nav-render logic already filters entries by
`session.roles` intersection before rendering `<Link>`s (this is the existing
mechanism every other `PLATFORM_ADMIN`-only nav entry already relies on — not a new
mechanism this design introduces) — so a non-PLATFORM_ADMIN operator never sees the
nav link at all, and even a hand-typed URL hits the §1.2 route guard.

## 2. Component tree

```
PlatformMigrationConsolePage                     (web/src/pages/admin/platform-migrations/PlatformMigrationConsolePage.tsx)
├── role gate (§1.2) — <Navigate> if not PLATFORM_ADMIN
├── RolloutStartForm                              (same file, or co-located component — see §3)
│     — entity_type / attribute / pg_type / references_entity / generated_as inputs
│     — "Start rollout" button (doubles as "start the same rollout again" — §5)
└── RolloutStatusPanel                             (rendered once a rolloutId is known —
      either just-started, deep-linked via ?rollout=, or found from a prior submit
      still held in page state)
      ├── QueryStateBoundary                        (existing shared component, same
      │     loading/error/success wrapper every other data screen in web/src uses —
      │     see PlatformDashboardPage.tsx:50, DefinitionRollbackPage.tsx:138)
      ├── RolloutSummaryHeader                       — entity_type/attribute, overall
      │     rollout.status ("running"/"completed"), started_at, completed_at
      ├── RolloutOutcomeTable                        — one row per outcome (AC1/EO-003)
      │     └── RolloutOutcomeRow × N                — tenant/company, status badge,
      │           completed_at, reason (non-succeeded only)
      ├── ResumeControl                               — visible only when the rollout has
      │     outstanding companies (§4)
      └── ReRunResultBanner                           — rendered after a start/re-run
            submission whose response shows every outcome already_current: true (§5)
```

No new shared UI primitives are invented — `PageLayout`, `Button`, `StatusBadge`,
`QueryStateBoundary` are reused verbatim from `web/src/components/ui/`, matching
`DefinitionRollbackPage.tsx`'s own reuse of exactly these four.

## 3. API client module — `web/src/api/platformMigrations.ts`

New, small, dedicated module (matching the existing one-module-per-backend-concern
precedent named in `definitionRollback.ts`'s own doc comment — `api/audit.ts`,
`api/definitionRollback.ts`). Field names copied **verbatim** from
`lib/letflow/routers/platform_migrations.ex`'s `rollout_map/1`/`outcome_map/1` — no
renaming, no camelCase conversion, same convention `definitionRollback.ts` follows.

```
export interface ColumnSpecRequest {
  pg_type: string
  references_entity?: string | null
  generated_as?: string | null
}

export interface StartRolloutRequest {
  entity_type: string
  attribute: string
  column_spec: ColumnSpecRequest
}

export interface RolloutOutcome {
  tenant_id: string
  status: 'pending' | 'succeeded' | 'failed'
  completed_at: string | null   // ISO 8601, or null
  reason: string | null
  already_current: boolean
}

export interface Rollout {
  id: string
  entity_type: string
  attribute: string
  status: 'running' | 'completed'
  started_at: string            // ISO 8601
  completed_at: string | null
}

export interface RolloutResult {
  rollout: Rollout
  outcomes: RolloutOutcome[]
}

export const platformMigrationsApi = {
  start: (body: StartRolloutRequest) =>
    client.post<RolloutResult>('/api/v1/platform-migrations/rollouts', body),

  status: (rolloutId: string) =>
    client.get<RolloutResult>(`/api/v1/platform-migrations/rollouts/${encodeURIComponent(rolloutId)}`),

  resume: (rolloutId: string) =>
    client.post<RolloutResult>(`/api/v1/platform-migrations/rollouts/${encodeURIComponent(rolloutId)}/resume`, {}),
}
```

No mock/stub implementation anywhere — `client` is the same shared typed-fetch wrapper
(`web/src/api/client.ts`) every other API module uses, hitting the real backend base
URL. `column_spec.pg_type` is the only structurally-required key the router itself
requires (`column_spec_from_request/1`, `platform_migrations.ex:138-149`); `nullable`
is never sent by the client, matching the router's own "never caller-supplied" contract
(§7.1 of the REQ-374 design) — the form (§3.1) has no nullable input at all.

### 3.1 Query-key factory addition

`web/src/api/queryKeys.ts` gains one new top-level branch, same shape as the existing
`definitions`/`admin` branches:

```
platformMigrations: {
  all: ['platform-migrations'] as const,
  status: (rolloutId: string) => [...queryKeys.platformMigrations.all, 'status', rolloutId] as const,
}
```

### 3.2 Hooks — `web/src/hooks/usePlatformMigrations.ts` (new file)

```
useStartRollout(): UseMutationResult<RolloutResult, ApiError, StartRolloutRequest>
  — mutationFn: platformMigrationsApi.start
  — onSuccess: qc.invalidateQueries({ queryKey: queryKeys.platformMigrations.status(data.rollout.id) })
    (harmless if nothing was previously cached for this id — matches the
    invalidate-on-mutate pattern useRollbackDefinition already uses)

useRolloutStatus(rolloutId: string | null): UseQueryResult<RolloutResult, ApiError>
  — queryKey: queryKeys.platformMigrations.status(rolloutId ?? '')
  — queryFn: () => platformMigrationsApi.status(rolloutId!)
  — enabled: !!rolloutId   (same `enabled: !!id` gating useDefinition already uses)
  — refetchInterval: false — no polling; the page's own explicit actions (start/
    resume/manual refresh button) are what advance state, matching this codebase's
    existing preference for explicit refetch over polling on admin screens (no
    existing admin screen in web/src polls)

useResumeRollout(): UseMutationResult<RolloutResult, ApiError, string /* rolloutId */>
  — mutationFn: (rolloutId) => platformMigrationsApi.resume(rolloutId)
  — onSuccess: (data) => qc.invalidateQueries({ queryKey: queryKeys.platformMigrations.status(data.rollout.id) })
```

## 4. Resume-control visibility logic (AC2)

**Rule, computed purely from the already-fetched `RolloutResult`, no separate flag
requested from the server:**

```
hasOutstandingCompanies(result: RolloutResult): boolean =
  result.outcomes.some(o => o.status !== 'succeeded')
```

This is a direct, literal read of REQ-374's own outcome-status enum
(`~w(pending succeeded failed)`, §3.2 of the REQ-374 design) — "outstanding" means
`pending` or `failed`, i.e. anything that is not yet `succeeded`. The `ResumeControl`
component (a `Button`) is conditionally rendered — not merely disabled — when this is
`false`: **absent from the DOM entirely** when every outcome is `succeeded`, matching
AC2's "visible only when." This also equals `!result.rollout.completed_at` in every
case this design's own data model can produce (REQ-374 design §4.6:
`recompute_rollout_completion/1` sets `completed_at` exactly when zero outcomes remain
non-succeeded) — the screen uses the outcome-array check above as the primary source of
truth (it is the literal per-company data the operator is looking at) and treats
`rollout.completed_at != nil` as a secondary, redundant confirmation only (e.g. for the
`RolloutSummaryHeader`'s own "running"/"completed" badge), never as a second,
independently-computed gate that could disagree with the outcome list.

Invoking the resume control calls `useResumeRollout().mutate(rollout.id)` — the real
`POST /platform-migrations/rollouts/:id/resume` endpoint, §3 — then re-renders
`RolloutOutcomeTable` from the mutation's own response (no separate manual refetch
needed; the mutation's resolved `RolloutResult` **is** the new status, matching how
`DefinitionRollbackPage.tsx` renders `successResult` straight from
`rollback.mutateAsync`'s own return value rather than issuing a follow-up GET).

## 5. Distinguishing a no-op re-run (EO-005) from a fresh run

**Signal, again read directly off the real response, no new client-side heuristic
invented beyond what REQ-374's `already_current` field already states:**

```
isNoOpResult(result: RolloutResult): boolean =
  result.outcomes.length > 0 && result.outcomes.every(o => o.already_current === true)
```

`already_current: true` is REQ-374's own documented field for exactly this purpose
(REQ-374 design §4: "This is the field REQ-375's screen ... use[s] to render/assert
EO-005's 'reports every company as already-current' language without needing to diff
two full snapshots" — this design follows that pointer literally). When the operator
presses "Start rollout" again with the same form values (§2's `RolloutStartForm`,
unchanged since the prior submission — the page never clears form state after a
successful start, specifically so a re-submission is trivially "the same request") and
`isNoOpResult(response)` is `true`, `ReRunResultBanner` renders instead of (not in
addition to) the ordinary "N companies received the change" success framing a fresh
run's response would produce:

- **Fresh run banner** (`isNoOpResult` false): informational-tone banner, e.g. "Rollout
  started — N of M companies now hold the change" (N = count where
  `status === 'succeeded'` in the just-returned response), `data-testid="rollout-fresh-run-banner"`.
- **No-op re-run banner** (`isNoOpResult` true): distinctly worded and distinctly
  styled banner — different background/icon token (e.g. a neutral/informational
  `--color-info-tint` rather than the fresh run's success-green), copy along the lines
  of "Every company already holds this change — nothing was applied," explicitly
  naming that this was a repeat, not a first run, `data-testid="rollout-noop-banner"`.

The two banners are mutually exclusive and keyed off the literal `already_current`
array, not off any timing/counter heuristic (e.g. "did outcomes change count") that
could be fooled by a coincidence — this is the same "derive from the real field the
backend already computed, don't reinvent a parallel signal" discipline
`classifyRollbackError`/`classifyApplyRehearsalError` apply to error responses,
applied here to a success response instead.

The `RolloutOutcomeTable` itself is unaffected by which banner shows — outcome rows
still render every company's `status`/`completed_at`/`reason` exactly as returned, so
"the no-op result is visually distinguishable from a fresh run" (AC3) is satisfied at
two levels: the banner (primary, always present) and, secondarily, the fact that
`completed_at` values in the table are provably unchanged from before the re-run
(observable by the operator comparing against what they saw before pressing Start
again — no new UI element requested here beyond the banner + unmodified table, since no
acceptance criterion asks for a diff view).

## 6. `RolloutStartForm` — fields and submit behavior (AC1 precondition)

Plain controlled form, same conventions as `DefinitionRollbackPage.tsx`'s own inputs
(`data-testid`-tagged, disabled while a mutation is in flight):

| Field | Input | `data-testid` | Maps to |
|---|---|---|---|
| Entity type | text input | `rollout-entity-type-input` | `entity_type` |
| Attribute | text input | `rollout-attribute-input` | `attribute` |
| Column PG type | text input | `rollout-pg-type-input` | `column_spec.pg_type` |
| References entity (optional) | text input | `rollout-references-entity-input` | `column_spec.references_entity` |
| Generated-as expression (optional) | text input | `rollout-generated-as-input` | `column_spec.generated_as` |
| Submit | button, `data-testid="rollout-start-btn"`, disabled while `entity_type`/`attribute`/`pg_type` are blank or a start/resume mutation is pending | — | calls `useStartRollout().mutate(...)` |

On successful submit, the page stores the returned `rollout.id` in local state
(`activeRolloutId`) — this is what makes `RolloutStatusPanel` render, and is
`RolloutStatusPanel`'s single source of truth for which rollout to display (never
re-derived from the form fields). Form values are **not** cleared on success — this is
the deliberate mechanism (§1.1, §5) that lets the operator press "Start rollout" a
second time with the identical payload to exercise EO-005 without retyping anything.

On error, an inline error block (reusing the `InlineError`-style pattern from
`NonSkippableApprovalGate.tsx`/`DefinitionRollbackPage.tsx`'s error blocks — same
visual language, new instance, not a new component) renders the raw problem-detail
message; REQ-374's own error surface here is narrow (`{:error, :column_spec_conflict}`
→ 409 "column_spec conflict", or a generic 500) — this design does not invent
additional classification beyond what the router actually returns (§9 OQ-2 notes the
backend's own conflict-detection is itself an open question in the REQ-374 design; this
screen surfaces whatever the backend actually sends, generically, rather than guessing
a taxonomy the backend hasn't committed to).

## 7. `RolloutOutcomeTable` / `RolloutOutcomeRow` — field mapping (AC1/EO-003)

One row per entry in `RolloutResult.outcomes`, ordered exactly as returned (REQ-374
design §4.3: "ordered by `tenant_id` — stable ordering for the screen"). Columns:

| Column | Source | Rendering notes |
|---|---|---|
| Company | `outcome.tenant_id` | Resolved to a human-readable name via a `tenant_id → display_name` lookup built client-side from `tenantsApi.list()` (existing `web/src/api/tenants.ts`, already used by `PlatformDashboardPage.tsx`) — see §9 OQ-1 for the one open question this lookup carries. Falls back to rendering the raw `tenant_id` UUID if no match is found in the fetched tenant list (e.g. a tenant deactivated after the rollout ran), so the row is never blank. `data-testid="rollout-outcome-company-{tenant_id}"`. |
| Outcome | `outcome.status` | `StatusBadge` (existing shared component, reused — not a new badge system) with a `domain="rollout-outcome"`-shaped variant: `succeeded` → success/green, `failed` → error/red, `pending` → neutral/in-progress. `data-testid="rollout-outcome-status-{tenant_id}"`. |
| Completed at | `outcome.completed_at` | Formatted via `formatDateTime` (existing `web/src/i18n/format.ts` helper, same one `DefinitionRollbackPage.tsx` uses) when non-null; em-dash placeholder when `null` (only possible while `status === 'pending'`). `data-testid="rollout-outcome-completed-{tenant_id}"`. |
| Reason | `outcome.reason` | Rendered **only** when `status !== 'succeeded'` (AC1's "reason for non-succeeded companies" — a `pending` row not yet attempted also has `reason: null` and renders nothing here, which is correct: it has no reason yet, not a placeholder reason). Plain text, the exact server string (REQ-374 design §5.3's `describe_failure_reason/1` output) — no client-side re-wording. `data-testid="rollout-outcome-reason-{tenant_id}"`. |

Table-level `data-testid="rollout-outcome-table"`; each row `data-testid="rollout-outcome-row-{tenant_id}"` (mirrors `datatable-row`/`def-name-{id}` scoping convention the rollback pipeline spec already relies on for disambiguating rows, §8).

## 8. E2E pipeline test — scenario outline (AC5)

File: `web/tests/e2e/pipelines/platform-migration-partial-failure-resume.pipeline.e2e.spec.ts`
(new). Drives `test/fixtures/uat/scenarios/platform/migration-partial-failure-resume.yaml`
end to end, same structural conventions as
`platform-definition-promotion-rollback.pipeline.e2e.spec.ts` (`createPipeline`,
`pl.step`, `pl.gate`, `navigateSpa`, `typeIntoTestIdInput`, `shot`, a `pl.onCleanup`
hook, `test.setTimeout(300_000)` for a multi-step real-backend flow).

**Pipeline state shape:**

```
interface RolloutPipelineState {
  adminToken: string
  targetEntityType: string          // unique per run, e.g. `pl-rollout-${fixtureId}`
  targetAttribute: string
  poisonedTenantId: string          // the tenant pre-arranged to fail (precondition 2)
  healthyTenantIds: string[]        // at least 2, per precondition 1 ("three or more")
  rolloutId: string
}
```

**Pre-step (API, not scenario step — establishes preconditions 1–3):** provision (or
select from an existing seeded fixture pool — reuse whatever helper the existing
REQ-374 backend test suite's tenant-provisioning fixture uses, matching
`test/letflow/platform/migration_rollout_test.exs`'s own EO-001 setup, §8 of the REQ-374
design) at least three real tenant schemas; in exactly one target tenant's schema,
pre-create the target entity's table with a same-named, conflicting-type column so the
real `check_additive_only/3` DDL path fails deterministically — the same real-failure
mechanism the REQ-374 backend regression test already relies on, not a mocked failure.
Confirm (via a `GET` against the not-yet-started rollout's natural key, or simply by
this being a freshly generated `entity_type`/`attribute` pair) that no rollout exists
yet for this pair (precondition 3).

- **Step 1 (GUI)** — `navigateSpa('/admin/platform-migrations')`; fill
  `rollout-entity-type-input`/`rollout-attribute-input`/`rollout-pg-type-input`
  (`data-testid`s per §6) targeting every active company (the form has no per-company
  scope input — `start_rollout/3` always targets every active/provisioned tenant, §4.1
  of the REQ-374 design); click `rollout-start-btn`. Capture `rolloutId` from the
  rendered `RolloutSummaryHeader` (a `data-testid="rollout-id-display"` element this
  design adds specifically so the pipeline spec can read it back, mirroring how the
  rollback pipeline spec reads `s.newCaseInstanceId` off the URL) — this is scenario
  step 1's `produces: rollout_id`.
- **Step 2** is `via: system` — no GUI action; the fanout already ran synchronously
  inside step 1's own `POST /rollouts` call (REQ-374 design §1: `start_rollout/3` is a
  synchronous transactional context function, not a background job), so its outcome is
  already visible the moment step 1's response renders. The spec asserts step 2's
  `produces: first_pass_result` by reading the outcome table rendered from step 1's own
  response: assert the poisoned company's row shows `failed` with a non-empty reason
  (`rollout-outcome-reason-{poisonedTenantId}` visible and non-empty), and every other
  seeded company's row shows `succeeded` with a non-null completed-at.
- **Step 3 (GUI)** — re-read (or simply keep asserting against) the same
  `RolloutOutcomeTable` — this is literally "opens the rollout status screen and reads
  company by company," already satisfied by the page the operator is still on;
  `shot(page, 'platform-migration-partial-failure-resume', '03-status')`. Assert
  `ResumeControl` (`rollout-resume-btn`) **is visible** (§4 — outstanding company
  present).
- **Step 4 (GUI)** — correct the poisoned tenant's schema (API call, real DDL fix —
  drop/retype the conflicting column, same technique the REQ-374 backend EO-004 test
  uses) then click `rollout-resume-btn`. This calls the real
  `POST /rollouts/:id/resume` endpoint (§4) — no mock.
- **Step 5** is `via: system`, satisfied the moment step 4's mutation response renders:
  assert the previously-poisoned company's row now shows `succeeded` with a fresh
  completed-at, and every already-succeeded company's row shows a completed-at
  byte-identical to what was captured after step 1/3 (captured into pipeline state for
  comparison, same "record before, assert unchanged after" technique the REQ-374
  backend EO-004 test uses). Assert `ResumeControl` is now **absent** (every outcome
  `succeeded`, §4).
- **Step 6 (GUI)** — click `rollout-start-btn` again with the same (untouched) form
  values — "starts the same rollout once more." Assert `rollout-noop-banner` (§5) is
  visible and `rollout-fresh-run-banner` is **not**; assert every row's completed-at in
  the outcome table is unchanged from post-step-5 (same byte-identical comparison
  technique); `shot(page, 'platform-migration-partial-failure-resume', '06-noop')`.
  This is EO-005, and the spec's own assertion set is exactly what distinguishes it from
  a fresh run per AC3: a different banner, not merely "the table still looks
  succeeded."

**Cleanup:** per the scenario's own `cleanup.description` ("The change remains applied
to every company; that is the intended end state"), no rollback of the rollout itself.
`pl.onCleanup` only tears down the fixture tenants if they were provisioned fresh for
this run (not if reused from a shared pool) — matching the "restore only what this run
uniquely created" discipline the rollback pipeline spec's own `onCleanup` follows.

**Known, disclosed gaps this spec does NOT assert** (stated explicitly, not silently
omitted, matching `platform-definition-promotion-rollback...spec.ts`'s own §8.3-style
disclosure block): this spec runs against one fixed set of tenants provisioned/selected
for this run; it does not prove behavior at "every active company on the real platform"
scale, and it does not re-verify OQ-1 of the REQ-374 design (scope-drift on a repeat
`start_rollout/3` call against a newly-onboarded tenant) since no tenant is onboarded
mid-scenario.

## 9. Open questions (not silently resolved)

- **OQ-1 — company-name resolution for the outcome table (§7).** REQ-374's
  `outcome.tenant_id` is a bare UUID; this design resolves it to a display name via a
  client-side `tenantsApi.list()` lookup rather than a new backend join, because
  REQ-374 introduces no `display_name`-carrying field on the outcome response and this
  requirement's own scope fence names REQ-374 as already-shipped/unchangeable by this
  requirement. Two consequences flagged, not silently assumed: (a) `tenantsApi.list()`
  is itself paginated (`TenantListResponse.next_cursor`) — for a platform with more
  active companies than one page, a naive single-page fetch will fail to resolve some
  `tenant_id`s to names. This design's stated behavior (§7: fall back to the raw UUID)
  handles that failure mode gracefully, but does not solve pagination — if REVIEWER or
  CODE-DESIGN-VALIDATOR judges that a full-listing fetch (looping `next_cursor` until
  exhausted) is required rather than the graceful-degradation fallback, that is a
  choice ELIXIR-DEV/FRONTEND-DEV should make explicitly, not one this design silently
  picks. (b) `Tenant.tenant_id` (`web/src/api/tenants.ts`'s existing type) is marked
  optional (`tenant_id?: string`) in the current frontend type — this design assumes it
  is always present for any tenant capable of appearing in a rollout outcome (i.e. any
  *provisioned* tenant per REQ-374 design §4.5's `active_company_tenant_ids/0`
  definition), but this was not independently re-verified against a real `GET /tenants`
  response's actual field presence at design time; FRONTEND-DEV should confirm this
  before relying on it as a join key, and fall back to raw-UUID display (already the
  stated behavior) if it is ever absent.
- **OQ-2 — should the start form validate `entity_type`/`attribute` against a known
  entity/attribute list before submit?** This design does not add client-side
  cross-reference validation beyond non-empty-string checks (§6) — REQ-374's own
  `register_column_promotion/4` (REQ-297, reused unchanged) is the actual source of
  truth for whether an `(entity_type, attribute)` pair is valid, and it already returns
  a real error the form surfaces generically (§6). Adding a second, client-side
  validation layer risks disagreeing with the real backend rule as that rule evolves.
  Flagged as a deliberate no-build, not an oversight.
- **OQ-3 — should `RolloutStatusPanel` auto-poll while `rollout.status === "running"`
  but the just-returned response still shows outstanding companies?** Not needed for
  this requirement's own scenario, because `start_rollout/3`/`resume_rollout/1` are
  synchronous (§8) — the full first-pass or resume result is already known the instant
  the mutation resolves, so there is no "still processing in the background, check back
  later" state this design's data model can even produce today. If a future requirement
  makes the fanout asynchronous, this design's no-polling choice (§3.2) would need
  revisiting; not pre-built here since nothing in REQ-374 or REQ-375's acceptance
  criteria calls for it.
