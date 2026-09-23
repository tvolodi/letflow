# Design: REQ-399 — Case-detail dependency-version/provenance screen (`GET /api/v1/instances/{id}/pins`)

**Requirement:** REQ-399 (`docs/requirements.yaml`, search `id: REQ-399`, stage S6,
`depends_on: [REQ-373]`, letflow-queue task 775, GH-1694)
**Owner (implementer):** FRONTEND-DEV overall; the backend half (§1) is
ELIXIR-DEV-shaped and carries a mandatory SECURITY-REVIEWER gate per REQ-399's own AC3
**This document produces:** the backend-route disposition (§1 — a major finding: the
route already exists), the typed frontend API client/hook shape (§2), the new
`InstancePinsPanel` component's prop/state shapes and its mounting into
`InstanceDetailPage.tsx` (§3–§5), the four-value source-taxonomy label map (§4.2), the
loading/error/empty-state design (§5), the SECURITY-REVIEWER surface area this
requirement's AC3 mandates (§6), and a traceability map against all 8 acceptance
criteria (§7). **No implementation code** — no function bodies, no `.tsx`/`.ts`/`.ex`
files.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-399 entry in full (title, description, all 8
  acceptance criteria, `depends_on: [REQ-373]`, OUT OF SCOPE section).
- `lib/letflow/engine/pin_resolver.ex` (full read) — `reconstruct_effective_pins/2`'s
  moduledoc and implementation (line 615 onward), the `effective_pin()` type (`kind`,
  `ref`, `resolved_id`, `version`, `source`, `source_event_id`), the `source()` type
  (`:resolved | :override | :inherited | :rebound`, exactly four values, no fifth),
  and the moduledoc's own statement that AC7 ("issues zero reads against any catalog
  or module registry") is satisfied **by construction** — the function accepts no
  `Lookup.t()` parameter at all, so there is no capability to call a catalog/module
  lookup anywhere in this call path.
- `lib/letflow/routers/instances.ex` (full read, particularly lines 363–423 and
  978–1007) — **major finding, see §1**: `GET /:id/pins` already exists, already
  wired to `PinResolver.reconstruct_effective_pins/2`, already tenant-scoped, already
  tested.
- `test/letflow/routers/instances_test.exs` (lines 804–819, 931–1011) — the existing
  route's test coverage: a 200 response asserting `pins` shape, and an explicit
  cross-tenant/nonexistent-id 404 test (INV-5 shape).
- `lib/letflow/design/req080-instance-routes-read.md` — REQ-080's own design doc for
  this exact route (confirms `handleGetPins` was ported deliberately, "route to the
  existing pin resolver context; add no pin logic here" — i.e. REQ-080 already
  committed to the same "thin projection, zero new resolution logic" shape REQ-399's
  text independently re-derives).
- `docs/requirements.yaml` REQ-080 entry (`status: done`, stage S4, `owner:
  ELIXIR-DEV`) — confirms the route shipped and passed the full pipeline (REVIEWER +
  SECURITY-REVIEWER gates) under REQ-080, not as an unreviewed side effect.
- `web/src/api/instances.ts` (full read, 50 lines) — existing `instancesApi` object
  convention: one arrow function per route, `client.get<T>(path, params?)`, typed
  against `@/types/api`.
- `web/src/pages/instances/InstanceDetailPage.tsx` (full read, 382 lines) — **the live
  file**; confirms the filename REQ-399's own text flagged as possibly-stale is in
  fact still correct and live (not renamed, not replaced). Confirms the page's
  established "one focused panel component per concern, mounted as its own `<section>`
  with its own `QueryStateBoundary`" pattern — `AttachmentPanel` (§0 next item) is
  this exact pattern already in use on the same page, and is the design's chosen
  precedent over the whole-page-level pattern REQ-398/`PromotionReviewListPage.tsx`
  uses (see §3.1 for why).
- `web/src/components/instances/AttachmentPanel.tsx` and
  `web/src/hooks/useAttachments.ts` (both full read) — the closest structural
  precedent: a `<section>`-scoped panel component, taking `instanceId` as its only
  prop, with its own `useQuery`-backed hook, its own `rendererState` derivation, its
  own `QueryStateBoundary`+`DataTable` composition, and its own `emptyMessage` string
  for the zero-rows case — exactly the shape §3–§5 of this design reuses.
- `lib/letflow/design/req398-promotion-review-list-page.md` (full read) — the sibling
  frontend design-doc convention this document follows in structure (§0 sources list,
  explicit scope boundary, `QueryStateBoundary`/`classifyError` empty-vs-fetch-failure
  reasoning, acceptance-criteria traceability table, open questions section). Its
  `RendererState`-is-closed-union finding (no `'empty'` member, empty-vs-fetch-failure
  must be a page/component-level render decision inside the `'success'` branch) is
  reused unchanged in §5.2.
- `web/src/pages/promotions/PromotionReviewListPage.tsx` (skimmed) — confirms the same
  `QueryStateBoundary`/`classifyError` pattern REQ-398's design doc describes is what
  actually shipped, not just what was designed.
- `web/src/components/ui/QueryStateBoundary.tsx` (full read) — `RendererState` prop,
  `columns?: SkeletonColumn[]` for the loading skeleton, `onRetry`, `rateLimitRetryAfter`.
  Confirms the union is closed (`'loading' | 'success' | 'fetch-failure' |
  'permission-denied' | 'stale-version' | 'rate-limit'`), same finding as REQ-398's design.
- `web/src/utils/classifyError.ts` — `classifyError(error): RendererState`, existing
  convention reused unchanged.
- `web/src/types/api.ts` (`Attachment` interface, lines 211–220, and the `CursorPage<T>`
  interface) — the plain-interface-per-response-shape convention this design's new
  `EffectivePin` type (§2.1) follows.
- `web/src/api/queryKeys.ts` and `web/src/api/useTenantScopedQueryKeys.ts`
  (`instances:` blocks) — existing `instances.attachments(tenantId, instanceId)`
  sibling pattern this design's new `instances.pins(tenantId, instanceId)` key
  follows verbatim (§2.3).
- `web/src/api/attachments.ts` — confirms the "cite the real, shipped route table at
  the top of the file, not the design doc's paraphrase" documentation convention this
  design's §1.3 note for `instancesApi.getPins` follows.
- `docs/agents/instructions/security-invariants.md` (INV-1, INV-2, INV-5, INV-6 read
  in full) — the invariants SECURITY-REVIEWER's re-review (§6) checks against.
- `docs/anti-patterns.md` — no directly-applicable entry found for this change.

---

## 1. Backend route: already shipped — no new route, no new code (AC1, AC2)

### 1.1 The major finding

**`GET /api/v1/instances/:id/pins` already exists and already does everything REQ-399's
AC1/AC2 ask for.** REQ-399's own requirement text states "THIS REQUIREMENT NEEDS A NEW
BACKEND ROUTE THAT DOES NOT YET EXIST" — this is **stale**. The route shipped as part
of REQ-080 ("Instance routes 2/2 — read path", `status: done`, stage S4, merged via
PR referenced by commit `4f7dddcb`, well before REQ-373/REQ-399 were filed) and has
been live and tested since. Confirmed by direct read of the shipped source
(`lib/letflow/routers/instances.ex:375-377, 978-1007`), not assumed from the
requirement text or from REQ-080's own design doc alone. **This design does not
reproduce that code here** (it is already-shipped, unmodified by this requirement,
and reproducing it would blur the line CODE-DESIGN-VALIDATOR checks between "citing
an existing fact" and "proposing implementation" — ELIXIR-DEV/SECURITY-REVIEWER
should read the cited lines directly rather than trust a copy pasted into this doc).
In prose, what the cited lines do:

- The router mounts `authz_get "/:id/pins", :InstancesRead` above the bare `/:id`
  route (ordering matters per this router's own documented `Plug.Router`
  first-match-wins hazard, §0), dispatching to a private `handle_get_pins/2`.
- `handle_get_pins/2` casts the raw path param to a UUID (`{:error,
  :invalid_instance_id}` → 422), then calls `PinResolver.reconstruct_effective_pins(id,
  opts)` with `opts` taken directly from `conn.assigns.scoped_opts` (the same
  tenant-prefix-carrying options struct every other route in this module uses, §1.2).
- A private `render_get_pins/3` maps `{:ok, pins}` → 200 with body
  `%{"instance_id" => id, "pins" => Enum.map(pins, &pin_map/1)}`; `{:error,
  :instance_not_found}` → 404; any other error → 500 (no detail leaked, matching this
  router's established no-detail-on-500 convention, §0).
- A private `pin_map/1` projects each `effective_pin()` (§0's type) to a five-key
  string-keyed map: `"kind"`, `"ref"`, `"resolved_id"`, `"version"`, `"source"` —
  `kind`/`source` stringified via `Atom.to_string/1`, the rest passed through
  unchanged.

### 1.2 Why this already satisfies AC1 and AC2

- **AC1** ("returns, for a real instance, each dependency's `ref`, `resolved_id`,
  `version` and `source`, tenant-scoped..., proven by an integration test") —
  `pin_map/1` emits exactly these four fields (plus `kind`, which AC1 doesn't name but
  doesn't forbid either — needed by the frontend to group/label entries, §4.1).
  Tenant-scoping is `conn.assigns.scoped_opts` → `opts` → passed as `reconstruct_effective_pins/2`'s
  `opts` argument, which extracts `Keyword.get(opts, :prefix)` and threads it into
  `Reconstruction.read_full_log/3` — the same `:prefix`-scoping mechanism every other
  route in this module uses (INV-1). An integration test already exists:
  `test/letflow/routers/instances_test.exs:804-819` ("GET /:id/pins returns the
  effective pin set") and `:931-1011` (cross-tenant/nonexistent id → 404, INV-5
  shape). **AC1 is already met by shipped, tested code.**
- **AC2** ("pure read of `reconstruct_effective_pins/2`'s already-computed effective
  pin set (zero additional catalog/module reads), proven by the test asserting no new
  Repo query against `service_catalog` or `module` tables is introduced") — the
  handler's only data call is `PinResolver.reconstruct_effective_pins/2`, which (per
  `pin_resolver.ex`'s own moduledoc, §0) accepts no `Lookup.t()` argument at all — the
  zero-new-catalog-reads property holds **by construction**, not by convention that
  could regress silently. **The "no new `Repo` query" proof AC2 asks for does not yet
  exist as its own test** — the existing coverage (§1.2 AC1 above) proves the response
  shape, not the query-telemetry absence. This is new test-design work, not new
  application code (§1.4).

### 1.3 What this requirement DOES add on the backend side

**Nothing.** No migration, no schema, no router change, no context-module change. The
only backend-adjacent work item this requirement contributes is the AC2 telemetry
test named in §1.4, and the SECURITY-REVIEWER re-review named in §6 — both test/review
artefacts, not application code.

### 1.4 AC2's telemetry test — design note for TEST-DESIGNER

REQ-399's AC2 requires a test asserting **no** `Repo` query against `service_catalog`
or `module` tables occurs during this route's request. `test/letflow/routers/
instances_test.exs:1332-1378` (REQ-200's own `AC7 telemetry` test) is the direct
precedent: it attaches a named (not anonymous) `:telemetry` handler to `[:letflow,
:repo, :query]` (or this repo's equivalent Ecto telemetry event name — confirm the
exact event name from `config/config.exs`'s `Letflow.Repo` telemetry prefix at
implementation time, not guessed here), asserts the request completes successfully,
and then asserts the handler's collected `metadata.source` (or `metadata.query`,
depending on adapter telemetry shape — confirm at implementation time) never names
`service_catalog` or any module-catalog table, before detaching the handler in an
`on_exit` callback (`Ecto.Adapters.SQL.Sandbox`-safe, matching REQ-200's own pattern
exactly). This is TEST-DESIGNER's job (WF-02 Step 4), not this design's to write —
flagged here so TEST-DESIGNER doesn't have to independently discover the REQ-200
precedent.

### 1.5 Explicitly out of scope (restated from REQ-399's own text)

- **PLC-01/`module_ref` catalog versioning** — `pin_resolver.ex`'s own moduledoc
  SCOPE GAP section (§0) already names this unscoped to any stage; this requirement
  does not touch it, does not stub it, does not surface any UI hinting it exists.
- **Any UI to CHANGE a pin.** The existing PIN-05 rebind route
  (`POST /api/v1/instances/:id/rebind-pins`, `lib/letflow/routers/instances.ex:444`)
  is untouched. This screen is read-only (§3–§5); no mutation, no button, no form
  field anywhere in this design writes to that route or any other.
- **Any modification to `Letflow.Engine.PinResolver` itself.** §1.1 quotes its
  consumer, not itself; no line of `pin_resolver.ex` changes. This is directly
  checkable via `git diff` per REQ-399's own AC7.

---

## 2. `web/src/api/instances.ts` addition (AC1's frontend half)

### 2.1 New exported type

Added to `web/src/types/api.ts`, following the `Attachment` interface convention
(§0) — a plain interface, no `Raw*` adapter needed since the wire shape and the
desired shape are identical (§1.1's `pin_map/1` output maps field-for-field):

```
EffectivePinSource ::= 'resolved' | 'override' | 'inherited' | 'rebound'
  — exactly PinResolver.source() (pin_resolver.ex:186), no fifth value, string-typed
    (not a TS enum) matching this codebase's existing convention for backend atom-as-
    string wire fields (e.g. InstanceStatus, ReviewStatus, §0).

EffectivePin:
  kind: 'catalog_entry' | 'variable_schema' | 'module'   // PinResolver.kind() (pin_resolver.ex:183)
  ref: string
  resolved_id: string | null
  version: string
  source: EffectivePinSource

InstancePinsResponse:
  instance_id: string
  pins: EffectivePin[]
```

`InstancePinsResponse` is a direct, unadapted match to §1.1's `render_get_pins/3`
response body (`{"instance_id": ..., "pins": [...]}`) — no field-renaming/reshaping
step, same "no adapter needed" situation REQ-398's design found for its own list
route (§0).

### 2.2 New client function

```
instancesApi.getPins: (id: string) => Promise<InstancePinsResponse>
```

Behavior, in prose: `client.get<InstancePinsResponse>(\`/api/v1/instances/${id}/pins\`)`
— no query params, matching the route's own no-params shape (§1.1). Added as a new
entry in the existing `instancesApi` object (`web/src/api/instances.ts`, §0), placed
after `reconstruct` (the file's existing last entry) or grouped near `events`/
`timeline` (FRONTEND-DEV's call, no acceptance criterion constrains placement).

### 2.3 Query-key plumbing (additive, existing pattern — not a new one)

`web/src/api/queryKeys.ts`, inside the existing `instances:` block (§0, sibling to
`attachments`):

```
pins: (tenantId: string, instanceId: string) =>
  [...queryKeys.instances.all(tenantId), 'pins', instanceId] as const
```

— byte-for-byte the same shape as the existing `attachments` key one line above it.

`web/src/api/useTenantScopedQueryKeys.ts`, inside the existing `instances:` block:

```
pins: queryKeys.instances.pins.bind(null, tenantId)
```

---

## 3. `web/src/hooks/useInstancePins.ts` (or `useInstances.ts` addition) — new hook

### 3.1 Location decision: new focused hook, following `useAttachments.ts`'s precedent

**Decision:** add `useInstancePins` either as a new small file
`web/src/hooks/useInstancePins.ts` (mirroring `useAttachments.ts`'s own one-hook-per-
file granularity, §0) or as an addition to the existing `web/src/hooks/useInstances.ts`
(which already holds five sibling instance-scoped hooks, §0) — **FRONTEND-DEV's call**,
no acceptance criterion constrains the file boundary. This design writes the hook's
shape once, independent of which file it lands in.

### 3.2 Hook shape

```
useInstancePins(instanceId: string): UseQueryResult<InstancePinsResponse>
```

Behavior: `const instanceKeys = useTenantScopedQueryKeys().instances; useQuery({
queryKey: instanceKeys.pins(instanceId), queryFn: () =>
instancesApi.getPins(instanceId), enabled: !!instanceId })` — identical shape to
`useAttachments(instanceId)` (§0: `enabled: !!instanceId` guard, since this hook, like
`useAttachments`, is only ever called with an already-resolved instance id from a
detail-page route param that could transiently be empty during the first render). No
`refetchInterval` — pins are set once at instance start and only change via an
explicit PIN-05 rebind (a separate, infrequent, already-out-of-scope action, §1.5);
polling this route on the interval `InstanceDetailPage.tsx`'s own `usePolling` already
drives for the *instance* itself (§0) is unnecessary — a considered omission, not an
oversight, same reasoning REQ-398's design used for its own list hook (§0).

---

## 4. `InstancePinsPanel` component — new file, `web/src/components/instances/InstancePinsPanel.tsx`

### 4.1 Why a panel component, not a page-level section (structural decision)

**Decision: follow `AttachmentPanel.tsx`'s shape (§0), not `PromotionReviewListPage.tsx`'s
whole-page shape.** REQ-399's own AC4/AC5/AC6 describe behavior scoped to "the
case-detail screen," and `InstanceDetailPage.tsx` already establishes, via
`AttachmentPanel`, the precedent of "one focused, self-contained, independently-
data-fetching `<section>` component per concern, taking `instanceId` as its only
prop, mounted directly in the page body" (§0) rather than folding a second
`useQuery` and a second `rendererState` derivation into the page's own already-large
top-level state (the page already juggles `instance`, `definition`, `pendingTasks`,
`timelineQuery`, and `scrubber` state, §0 lines 96–137). A new panel component keeps
the pin-provenance concern testable in isolation (mirroring
`test/.../__tests__/InstanceDetailPage.definitionRow.test.tsx`'s existing per-concern
test-file granularity, §0) and keeps `InstanceDetailPage.tsx` itself from growing a
sixth independent query. This is a structural choice with no acceptance-criterion
consequence either way — noted as Open Question 1 (§8) for FRONTEND-DEV/REVIEWER in
case a stronger convention is preferred at implementation time.

### 4.2 Source-taxonomy label map (AC4 — the exact four-value requirement)

A single, private, non-exported lookup **inside** `InstancePinsPanel.tsx` (not a
shared util — this label set is specific to this one screen's copy, not a
codebase-wide taxonomy the way `EffectivePinSource` itself is):

```
SOURCE_LABELS: Record<EffectivePinSource, string> = {
  resolved:  'Chosen automatically',
  override:  'Requested explicitly',
  inherited: 'Inherited from parent case',
  rebound:   'Changed via rebind',
}
```

Exactly PinResolver's four `source()` values (§0/§2.1), each with exactly one label,
**no fifth key, no key omitted** — `Record<EffectivePinSource, string>` is a mapped
type over the closed `EffectivePinSource` union (§2.1), so TypeScript itself rejects a
build where this map is missing a key or has an extra one, structurally enforcing
AC4's "renders every one of PinResolver's four source values... no fifth bucket
invented, no taxonomy value silently dropped" as a compile-time guarantee, not just a
runtime convention. This is the load-bearing mechanism satisfying REQ-399's own
OUT-OF-SCOPE line about not inventing a fifth bucket (§1.5) — TEST-DESIGNER's AC4 test
(a mocked response containing all four values) exercises this map's completeness at
runtime as the independent proof; the `Record<EffectivePinSource, string>` type is the
static proof.

A pin's rendered label is `SOURCE_LABELS[pin.source]` — no fallback string, no default
case, no `?? 'Unknown'`: if a fifth backend value ever appeared (a regression this
requirement's own AC7 `git diff` check on `pin_resolver.ex` guards against at the
source), TypeScript would fail the build before this reaches a browser, which is the
correct failure mode for "an unstated taxonomy value" rather than silently rendering
a blank/undefined label.

### 4.3 Component shape

```
interface InstancePinsPanelProps {
  instanceId: string
}

export function InstancePinsPanel({ instanceId }: InstancePinsPanelProps): React.ReactElement
```

Mirrors `AttachmentPanel`'s prop shape exactly (§0) — `instanceId` only, no other
props, no default export (named export, matching `AttachmentPanel`'s own convention).

### 4.4 Internal state derivation

```
pinsQuery = useInstancePins(instanceId)

rendererState: RendererState =
  pinsQuery.isLoading ? 'loading'
  : pinsQuery.isError ? classifyError(pinsQuery.error)
  : 'success'

pins: EffectivePin[] = pinsQuery.data?.pins ?? []
hasPins: boolean = pins.length > 0
```

Identical shape to `AttachmentPanel`'s own `rendererState`/`rows` derivation (§0).

### 4.5 Row shape and columns (AC4)

Following `AttachmentPanel`'s `DataTable`+`DataTableColumn<T>` composition (§0), not
a hand-rolled `<table>` — this codebase's `DataTable` is already the established
choice for an in-panel row-per-item list on this exact page (`AttachmentPanel`,
`pendingTaskColumns` on the page itself, §0), so this design follows that precedent
rather than `PromotionReviewListPage.tsx`'s native-`<table>` choice, which REQ-398's
design itself flagged as page-specific, not a codebase-wide rule (§0, that doc's Open
Question 2).

```
interface PinRow {
  key: string                    // `${pin.kind}:${pin.ref}` — unique per row, no id field on EffectivePin itself
  pin: EffectivePin
}

columns: DataTableColumn<PinRow>[] = [
  { id: 'ref',      header: 'Dependency',    accessor: (row) => row.pin.ref },
  { id: 'kind',     header: 'Kind',          accessor: (row) => KIND_LABELS[row.pin.kind] },
  { id: 'version',  header: 'Version',       accessor: (row) => row.pin.version },
  { id: 'source',   header: 'How it was set', accessor: (row) => SOURCE_LABELS[row.pin.source] },
]

rows: PinRow[] = pins.map((pin) => ({ key: `${pin.kind}:${pin.ref}`, pin }))
```

`KIND_LABELS` is a small sibling map (`{ catalog_entry: 'Service', module: 'Module',
variable_schema: 'Variable schema' }`) — not itself acceptance-criteria-bearing (AC4
only names the `source` taxonomy), included so the `kind` column isn't a raw
`snake_case` string; exact wording is FRONTEND-DEV's call. `resolved_id` is
**deliberately not its own column** — it is an internal identifier with no
established human-readable rendering (unlike `ref`/`version`), and no acceptance
criterion names it; available on `row.pin.resolved_id` for FRONTEND-DEV to add later
if desired, not required now.

### 4.6 Mounting into `InstanceDetailPage.tsx`

One new `<section>`, placed after the existing `Attachments` section (§0, line
311–314) and before the tab strip (§0, line 316), following the page's own established
section-ordering/spacing convention (`style={{ marginBottom: '1.25rem' }}`, `<h3>`
heading):

```
<section style={{ marginBottom: '1.25rem' }}>
  <h3 style={{ marginBottom: '.5rem' }}>Dependency Versions</h3>
  <InstancePinsPanel instanceId={id!} />
</section>
```

One new import line grouped with the other `@/components/instances/*` imports (§0,
alongside `AttachmentPanel`). No change to any existing section, any existing hook
call, or the page's own `rendererState`/`QueryStateBoundary` (the page-level one, §0
line 227) — `InstancePinsPanel` owns its own independent query and its own
`QueryStateBoundary` instance, exactly as `AttachmentPanel` already does.

---

## 5. Loading/error/empty states (AC5, AC6)

### 5.1 Loading and fetch-failure — `QueryStateBoundary`, unchanged pattern

```
<QueryStateBoundary
  state={rendererState}
  onRetry={() => { void pinsQuery.refetch() }}
  rateLimitRetryAfter={rendererState === 'rate-limit' ? getRetryAfterSeconds(pinsQuery.error) : undefined}
>
  {/* success-branch content, §5.2 */}
</QueryStateBoundary>
```

Identical composition to `AttachmentPanel`'s own `QueryStateBoundary` usage (§0) — no
new `RendererState` value, no change to `QueryStateBoundary.tsx` itself. A fetch
failure (network error, 5xx, etc.) renders `QueryStateBoundary`'s existing
`<FetchError onRetry={...} />` branch (AC6's "fetch failure... renders this codebase's
existing `QueryStateBoundary`/`classifyError` failure state").

### 5.2 Empty state — "no dependencies," distinct from fetch-failure (AC5)

**No new `RendererState` value** — same closed-union finding REQ-398's design made
(§0), reused unchanged. Inside `QueryStateBoundary`'s `success`-branch children
(reachable only when `rendererState === 'success'`, i.e. the fetch itself succeeded
and returned `{instance_id, pins: []}` for a case with zero recorded pins — a
structurally different code path than a fetch failure, which never reaches this
branch at all):

```
{hasPins
  ? <DataTable columns={columns} data={rows} emptyMessage="No dependencies recorded for this case." />
  : <p style={{ color: 'var(--text-secondary)' }}>No dependencies recorded for this case.</p>}
```

(`DataTable`'s own `emptyMessage` prop, per `AttachmentPanel`'s convention, §0,
already renders a plain message when `data` is empty — the explicit `hasPins ? ... :
...` branch above is one way to satisfy AC5's "distinct plain state"; passing
`emptyMessage` alone to `DataTable` and always rendering it, matching
`AttachmentPanel`'s own `emptyMessage="No attachments yet."` one-liner exactly, is
equally acceptable and arguably simpler — **FRONTEND-DEV's call between these two
equivalent renderings**, both satisfy AC5 since both are structurally reached only
from the `'success'` branch, never from `'fetch-failure'`.) This structurally
guarantees AC5/AC6's "distinct... not the fetch-failure state" the same way REQ-398's
design's §6.4 reasoned about its own list page: the empty message and `<FetchError
/>` come from different branches of `QueryStateBoundary`'s own exhaustive `switch`
(§0), never from an `if/else` this component has to get right on its own.

---

## 6. SECURITY-REVIEWER surface area (AC3 — mandatory, explicit)

**REQ-399's AC3 is unconditional: "SECURITY-REVIEWER sign-off is required and
obtained before merge... same class as REQ-397's list route."** This holds even
though §1 establishes that the route's own code is unchanged — AC3's wording names
this requirement's own merge, not "if new route code is added," so ELIXIR-DEV/ORCH
must not skip this gate on the reasoning that "nothing changed on the backend." (This
differs from REQ-398's own design doc, §0, which found *no* new SECURITY-REVIEWER
gate was triggered for that requirement — that finding does not transfer here, because
REQ-398's requirement text itself said no new gate was needed while REQ-399's AC3
explicitly demands one regardless.)

SECURITY-REVIEWER's re-review has real, checkable surface area even with a zero-line
route diff:

1. **INV-1 (tenant data isolation) — re-confirm, don't assume.** Trace
   `handle_get_pins/1` → `conn.assigns.scoped_opts` → `PinResolver.
   reconstruct_effective_pins(id, opts)` → `Reconstruction.read_full_log(instance_id,
   prefix, 1)` and confirm `prefix` genuinely reaches the underlying event-store
   query (not merely passed and silently dropped) — read `Reconstruction.
   read_full_log/3`'s own body, don't take the call site's naming as proof. Confirm
   the existing cross-tenant test (`test/letflow/routers/instances_test.exs:931-1011`,
   §0) actually exercises this path (a tenant-B session against a tenant-A instance id
   returns 404, not another tenant's pins).
2. **INV-5 (not-found/forbidden indistinguishability).** Confirm
   `render_get_pins/3`'s `{:error, :instance_not_found} -> Response.not_found(conn)`
   branch is the **same** branch and same response shape a genuinely-nonexistent
   instance id hits — `reconstruct_effective_pins/2`'s own moduledoc (§0) states
   `{:ok, []}` (no events at all) maps to `{:error, :instance_not_found}` before this
   handler ever sees a cross-tenant-vs-truly-absent distinction, so there is
   structurally only one error branch to audit, not two that could diverge.
3. **AC2's "zero new catalog/module reads" property — verify it holds by construction,
   not just by the new telemetry test's pass/fail.** Confirm `reconstruct_effective_pins/2`'s
   signature genuinely has no `Lookup.t()` parameter (§0/§1.2) — i.e. this isn't a
   property that could regress via a future edit to this one function without a type
   signature change flagging it. This is the single most load-bearing check AC2 asks
   for: a `Lookup.t()` parameter added to `reconstruct_effective_pins/2` in a future
   change would silently reopen a catalog-read surface this requirement's whole
   "zero new reads" claim depends on remaining closed.
4. **Response-shape leak risk (the new consumer, not new code).** Confirm the five
   fields `pin_map/1` emits (`kind`, `ref`, `resolved_id`, `version`, `source`) carry
   no tenant-identifying or cross-tenant-inferable data beyond what INV-2 already
   permits an authenticated, tenant-scoped, `:InstancesRead`-authorized caller to see
   for their own instance — `resolved_id` in particular is an internal catalog/module
   identifier (§1.1's `pin_map/1`); confirm it does not leak another tenant's private
   catalog-entry naming scheme (it does not, by construction: `resolved_id` comes
   from the tenant-scoped `Lookup.catalog_lookup`/`module_lookup` calls made at
   *resolution* time, which happened inside the same tenant's own resolution context
   — SECURITY-REVIEWER confirms this reasoning against `resolve/4`'s own body, §0,
   rather than taking it on trust from this design doc).
5. **Frontend half — no new client-side authorization boundary claimed.** Confirm
   `InstancePinsPanel`/`useInstancePins` performs no client-side role/permission
   gating of its own (per INV-2, "no client is ever the authorisation boundary") —
   the panel renders whatever the server returns for an already-`:InstancesRead`-
   authorized session; the 403/404 cases are handled entirely by `classifyError`/
   `QueryStateBoundary`'s existing server-driven state machine (§5.1), not a new
   `if (!hasRole) return null` this design does not introduce anywhere.

SECURITY-REVIEWER's handoff result must explicitly state which of INV-1/INV-2/INV-5/
INV-6 were assessed and how, per INV-6's own "explicit statement... not 'it compiles'"
requirement (§0) — a rubber-stamp "route unchanged, no new SECURITY-REVIEWER work
needed" verdict does not satisfy AC3's own wording and must be rejected by whichever
role reads that handoff next (ORCH, per core-directives.md's "every producing step
has a validating step").

---

## 7. Acceptance-criteria traceability

| # | REQ-399 acceptance criterion | Design section(s) |
|---|---|---|
| AC1 | New route returns ref/resolved_id/version/source, tenant-scoped, proven by integration test | §1.1–§1.2 (already shipped + already tested); §2 (frontend client/type) |
| AC2 | Pure read of `reconstruct_effective_pins/2` (zero additional catalog/module reads), proven by a "no new Repo query" test | §1.2 (property holds by construction), §1.4 (new telemetry test design note), §6 item 3 (SECURITY-REVIEWER re-verification) |
| AC3 | SECURITY-REVIEWER sign-off mandatory before merge | §6 (full surface area, explicit even though route diff is empty) |
| AC4 | Screen renders all four source values with distinct human-readable labels, proven by a mocked-all-four test | §4.2 (`SOURCE_LABELS` map, compile-time-closed), §4.5 (column rendering) |
| AC5 | Zero-pins case renders distinct plain "no dependencies" state, not fetch-failure | §5.2 |
| AC6 | Fetch failure renders existing `QueryStateBoundary`/`classifyError` failure state | §5.1 |
| AC7 | `git diff` confirms `pin_resolver.ex` unmodified | §1.1 (explicit "zero changes" statement), §1.5 (OUT OF SCOPE restated) |
| AC8 | `mix letflow.check` and frontend test suite pass, real output quoted | Not a design-section concern — TEST-RUNNER's job at WF-02 Step 6; no design decision needed here |

Test-file/AC mapping for TEST-DESIGNER (not written here — design only): AC1's
integration test already exists (§0, `instances_test.exs:804-819`) — TEST-DESIGNER
need only confirm it still passes, not write a new one, unless REVIEWER wants an
additional explicit assertion on all five `pin_map/1` fields (currently the existing
test only pattern-matches `kind`/`ref`/`source` for a single-pin case, §0 quoted
lines — extending it to assert `resolved_id`/`version` presence too is a reasonable
TEST-DESIGNER addition, not a new test file). AC2 needs the new telemetry test (§1.4).
AC4/AC5/AC6 are new `InstancePinsPanel` component tests, mocking/stubbing
`useInstancePins`'s return value (all-four-sources fixture for AC4, `{pins: []}` for
AC5, an error for AC6) — no real HTTP needed, following `AttachmentPanel`'s own
existing test file's mocking convention (confirm that file's exact shape at
TEST-DESIGNER time; not read in full for this design since AC4–AC6 concern the new
panel, not the existing one).

---

## 8. Open questions (do not silently resolve — FRONTEND-DEV/REVIEWER to weigh in)

1. **§4.1: panel-component vs. whole-page-state placement.** This design follows
   `AttachmentPanel.tsx`'s precedent (self-contained `<section>` component with its
   own query) over `PromotionReviewListPage.tsx`'s precedent (page-level state) because
   the pin-provenance concern is naturally page-*section*-scoped, not a distinct
   routed page. No acceptance criterion requires either shape; if REVIEWER prefers
   folding the query into `InstanceDetailPage.tsx`'s own existing `rendererState`
   instead, that is a structural alternative with identical AC coverage, not a defect
   in this design.
2. **§4.5: exact column set/order, and whether `resolved_id` gets its own column.**
   No acceptance criterion names `resolved_id` or `kind` as required visible columns
   (only `ref`, `version`, and the `source` label are AC4-bearing); this design
   includes both as reasonable additions but leaves the final call to FRONTEND-DEV.
3. **§1.4: exact Ecto/telemetry event name and metadata field for the "no `service_catalog`/module query" assertion.** This design points at REQ-200's own precedent
   test (`instances_test.exs:1332-1378`) rather than guessing the exact telemetry
   event/metadata shape from this design doc alone — TEST-DESIGNER should read that
   precedent test directly at implementation time rather than trust a paraphrase here.
4. **§6 item 4: whether `resolved_id` should be included in the API response at all
   for a `catalog_entry`/`module` pin, long-term.** Out of this requirement's scope to
   change (§1.1's "zero backend changes" holds) — noted only because SECURITY-REVIEWER's
   response-shape-leak check (§6 item 4) is the first time this field's cross-tenant
   safety has been explicitly re-examined since REQ-080; if that review surfaces a
   real concern, it is a new issue/requirement, not something this design silently
   patches by narrowing the frontend's rendering (the backend would still leak it to
   any direct API caller regardless of what the UI chooses to show).
