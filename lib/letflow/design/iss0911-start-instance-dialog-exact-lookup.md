# Design: ISS-0911 — Start Instance dialog exact-name version lookup

## 0. Sources read for this design

- `handoffs/WF03-ISS0911-20260930/step-01-issue-fixer-diagnose.json` — ISSUE-FIXER's
  diagnosis (`context.requirement_text`/`task` handed in full to this step; not
  re-derived here).
- `web/src/pages/instances/InstanceBoardPage.tsx` — full component, lines 1-260
  (state/hooks/handlers) and 420-467 (dialog JSX for the name/version fields).
- `web/src/api/definitions.ts` — `definitionsApi.getActive(name)` (lines 22-23),
  `definitionsApi.list` (lines 15-17).
- `web/src/hooks/useDefinitions.ts` — existing query-hook shapes (`useDefinitions`,
  `useDefinition`, `useDefinitionVersions`, `useDefinitionSearch`) and their
  tenant-scoped query-key wiring.
- `web/src/api/useTenantScopedQueryKeys.ts` — `definitions.active` key factory
  (line 59) already exists, bound to `queryKeys.definitions.active`, and is already
  invalidated by `useRollbackDefinition` (line 81) — this design is the first to
  actually *query* by that key, not just invalidate it.
- `web/src/hooks/useDebounce.ts` — existing generic value-debounce hook
  (`useDebounce<T>(value, delayMs): T`), already used by
  `web/src/pages/definitions/DefinitionListPage.tsx`. Reused as-is, not reinvented.
- `web/src/hooks/useDefinitions.ts`'s `useDefinitionSearch` — the codebase's existing
  precedent for "debounced value becomes the query key" (keystroke-driven search box
  backed by a live query), confirming query-key-per-input-value is an established,
  accepted pattern here, not a novel one for this fix.
- `web/src/api/client.ts` — `ApiError` shape (`status`, `message`, `code`, `details`)
  and `throwOnErrorResponse`'s 404 handling (generic non-2xx branch, lines 125-143):
  a 404 from `getActive` surfaces as `ApiError` with `status: 404`.
- `docs/guides/frontend_developer_guide.md` — TanStack Query conventions, tenant-scoped
  key discipline.

## 1. Scope boundary

This design changes exactly one behavior: how the Start Instance dialog's **own**
`start-definition-name` input resolves to a version/definition-id pair. It:

- Adds one new hook, `useActiveDefinitionByName`, to `web/src/hooks/useDefinitions.ts`.
- Changes `onStartDefinitionNameChange` in `InstanceBoardPage.tsx` to stop reading
  `definitionTypeahead.items` and instead drive/read the new hook.
- Adds a small pure derivation function, `deriveVersionLookupState`, used only by the
  dialog's version field to turn the new hook's raw TanStack Query result into one of
  four explicit UI states (§3).
- Does **not** touch `startDefinitionId`'s own synchronization discipline (ISS-0891,
  lines 65-77) — the new lookup still sets `startDefinitionVersion` and
  `startDefinitionId` together, in the same synchronous state-update pass, for exactly
  the same "must not go through `setSearchParams`" reason already documented there.
- Does **not** touch `submitStartInstance` (lines 202-239), `openStartDialog`
  (lines 164-175), or the mount-time effect (lines 104-112) — all three already resolve
  their version/id from `activeDefinitionByName` (the **page-level** `useDefinition(
  definitionId)` query, keyed off the URL's `definitionId`), which is a different,
  already-correct data path untouched by this bug (§4).
- Does **not** remove `definitionTypeahead` — it has a legitimate remaining use
  (§4) that must be preserved untouched.

## 2. Root cause recap (from Step 01, restated only as the design's starting contract)

`onStartDefinitionNameChange` resolved the dialog's typed value by scanning
`definitionTypeahead.items`, a list fetched once by `useDefinitions({ status: 'ACTIVE',
name: definitionName || undefined })` — `definitionName` being the **page-level** URL
filter (`searchParams.get('definitionName')`), not `startDefinitionName` (the dialog's
own local input state). Typing in the dialog never changes `definitionName`, so the
scanned list is fetched once, unscoped to what the user is actually typing, and capped
at the backend's default list page size — a just-created/just-activated definition can
fall outside that page and never resolve, leaving the version field empty until the
test's own timeout. The fix must resolve the dialog's typed value against a lookup
**keyed on that typed value itself**.

## 3. New hook — `useActiveDefinitionByName`

Added to `web/src/hooks/useDefinitions.ts`, alongside the existing hooks in that file.

```typescript
/** Exact-name active-definition lookup, keyed on the CALLER-supplied name — used by
 *  any input that must resolve a name the user is actively typing (not a page-level
 *  filter). See ISS-0911. `enabled` is false for a blank/whitespace-only name, so no
 *  request fires for an empty dialog input. */
export function useActiveDefinitionByName(
  name: string,
): UseQueryResult<ProcessDefinition, ApiError>
```

Control flow (no request-body/implementation code — this is the whole of its
observable contract):

- `name` is trimmed before being used as both the query key and the request argument.
  Two inputs differing only in leading/trailing whitespace must not be treated as
  different lookups (and must not both hit the network).
- `queryKey`: `definitionKeys.active(trimmedName)` — the **already-existing**
  tenant-scoped key factory (`useTenantScopedQueryKeys().definitions.active`,
  `web/src/api/useTenantScopedQueryKeys.ts` line 59). Reusing it (rather than adding a
  new key shape) means this lookup's cache entries are the same ones
  `useRollbackDefinition`'s `onSuccess` already invalidates (line 81) — a rollback that
  changes which version is active for a name is picked up by this hook for free, with
  no additional invalidation wiring.
- `queryFn`: calls `definitionsApi.getActive(trimmedName)` — no client-side list scan,
  no pagination, a single exact-match backend lookup per distinct trimmed name.
- `enabled`: `trimmedName.length > 0`. A blank dialog input performs no request and
  produces no query state transition (stays fully idle, not "loading" or "errored").
- `retry`: must not retry on a 404 (`error.status === 404`) — a 404 here means "no
  active definition with this exact name," a normal, expected outcome of the user still
  typing, not a transient failure. A small bounded retry (matching whatever default the
  rest of this codebase's `useQuery` calls already use, if any) is acceptable for
  non-404 errors (network blip, 5xx), but is not load-bearing for this fix.
- `staleTime`: `0` (or left at the query client's default) — this lookup must reflect
  the current server state on every distinct name, not serve a stale cached miss/hit
  across renders of the same key; unlike a page-level filter list, this dialog is
  explicitly for finding *newly created/activated* definitions, so an eager staleness
  window is actively wrong here.

## 4. Race-guard against out-of-order responses (rapid typing) — explicit design

Two layers, one structural (always correct) and one cosmetic (reduces request volume):

### 4.1 Structural guard: per-value query-key isolation (this is what makes it correct)

`InstanceBoardPage.tsx` does **not** call `useActiveDefinitionByName(startDefinitionName)`
directly on every keystroke. It first debounces the typed value with the **existing**
`useDebounce` hook:

```typescript
const debouncedStartDefinitionName = useDebounce(startDefinitionName, 300)
const activeDefinitionLookup = useActiveDefinitionByName(debouncedStartDefinitionName)
```

The race-guard itself is **not** the debounce (debouncing only reduces how often a
request fires — it does not, by itself, prevent a stale response from a still-in-flight
older request from overwriting a newer one). The actual guard is that
`useActiveDefinitionByName`'s `queryKey` is `definitionKeys.active(trimmedName)` —
**a distinct cache entry per distinct name value**, not one shared mutable slot. TanStack
Query's contract for this shape (already the pattern this codebase uses for
`useDefinitionSearch`, `web/src/hooks/useDefinitions.ts` lines 89-96, keyed on the
search query string) guarantees:

- A request in flight for `name = "Foo"` that resolves *after* the user has typed
  `"Foobar"` writes its result into the `"Foo"` cache entry only. The component, by that
  point, is subscribed to the `"Foobar"` query object (a different `useQuery` observer,
  because the key changed), so the late `"Foo"` response is never rendered — it cannot
  overwrite `"Foobar"`'s `data`/`isFetching`/`isError`, because they live in different
  cache slots addressed by different keys.
- This holds regardless of network ordering — there is no "last response wins" race at
  all, because there is no single mutable variable two responses could both write into.
  This is a stronger guarantee than an `AbortController`/generation-counter guard would
  add on top: those patterns exist to stop a stale response from landing in **one**
  shared piece of state; per-key query caching removes the shared state entirely, so
  there is nothing left for a stale response to corrupt.
- No `AbortController` is required for correctness. Cancelling the superseded in-flight
  request on every keystroke is a valid *efficiency* optimization (fewer wasted
  in-flight requests against the backend) but is explicitly **out of scope** for this
  fix — flagged as an open question (§7 OQ-1), not silently added, since
  `web/src/api/client.ts`'s `request()` does not currently accept a `signal` and wiring
  one through would touch a shared primitive used by every API call in the app, which
  this fix's scope (`owned_modules: ["InstanceBoardPage.tsx"]`) does not license.

### 4.2 Cosmetic layer: the 300ms debounce

Chosen to match the interaction shape already established by `useDebounce`'s existing
call site (`DefinitionListPage.tsx`) rather than inventing a new delay convention.
Effect: while the user is actively typing, no request fires per keystroke; a request
fires only once typing pauses for 300ms, and again if the value changes after that.
This is purely a request-volume reduction — §4.1's key-isolation guarantee holds with or
without it, at 0ms or 300ms.

## 5. Version field UI states — explicit, derived state

New pure function (not exported from a hook — a plain derivation, co-located with the
dialog or in a small shared helper module):

```typescript
export type VersionLookupState =
  | { kind: 'idle' }
  | { kind: 'loading' }
  | { kind: 'found'; definition: ProcessDefinition }
  | { kind: 'not_found' }
  | { kind: 'error'; message: string }

export function deriveVersionLookupState(
  trimmedName: string,
  query: Pick<UseQueryResult<ProcessDefinition, ApiError>,
    'data' | 'isFetching' | 'isError' | 'error' | 'isSuccess'>,
): VersionLookupState
```

Control flow (prose, no bodies):

1. `trimmedName === ''` → `{ kind: 'idle' }`. The dialog input is empty (freshly
   opened, or cleared) — no lookup was even attempted (`enabled: false`, §3), so this
   is distinct from "not found."
2. Else if `query.isFetching` (covers both the initial fetch for a brand-new debounced
   value and a refetch) and `!query.isSuccess` for the **current** key → `{ kind:
   'loading' }`.
3. Else if `query.isSuccess` → `{ kind: 'found', definition: query.data }`.
4. Else if `query.isError`:
   - `query.error.status === 404` → `{ kind: 'not_found' }` — this is the case ISS-0911
     itself reproduces (a legitimately-just-created definition the lookup hasn't found
     yet is `'loading'`, not `'not_found'`; `'not_found'` is reserved for a genuine
     404 response, i.e. the backend has confirmed no active definition exists under
     that exact name).
   - any other status → `{ kind: 'error', message: query.error.message }` (network
     failure, 5xx, etc. — must be visually distinguishable from "not found," since the
     remediation differs: retype the name vs. the service being unavailable).
5. (Implicit else, unreachable in practice — `isFetching`/`isSuccess`/`isError` are
   mutually exhaustive for a settled-or-in-flight TanStack Query result — but the
   function's return type has no catch-all `default` case to silently paper over a
   future TanStack Query version changing this invariant; a missing-case branch should
   fail a type-check, not fall through.)

### 5.1 Rendering each state on `start-definition-version`

The existing read-only `<input id="start-definition-version" ... />` (lines 452-466)
keeps its shape; only what feeds its `value`/`placeholder` changes:

| `VersionLookupState.kind` | `value` | `placeholder` |
|---|---|---|
| `idle` | `''` | `''` (unchanged from today's blank-input default) |
| `loading` | `''` | `'Looking up active version…'` |
| `found` | `definition.version` | — |
| `not_found` | `''` | `'No active definition named "<trimmedName>".'` |
| `error` | `''` | `'Could not check active version — <message>'` |

This is a strict refinement of the existing single `isLoadingActiveDefinition ?
'Loading active version…' : ''` placeholder ternary (line 457) — that ternary is driven
by the **page-level** `isLoadingActiveDefinition` (from `useDefinition(definitionId)`)
and is untouched by this design (§6); the dialog's own placeholder is now driven by
`deriveVersionLookupState(debouncedStartDefinitionName, activeDefinitionLookup)`
instead, replacing the dialog-typed-value branch of what that field shows.

### 5.2 Effect on `startDefinitionVersion` / `startDefinitionId` (ISS-0891 invariant preserved)

`onStartDefinitionNameChange` no longer scans `definitionTypeahead.items`. Its new
control flow:

1. `setStartDefinitionName(value)` — unchanged, still synchronous, still the source the
   debounce (§4.2) derives from.
2. It does **not** itself set `startDefinitionVersion`/`startDefinitionId` — those two
   are now driven by a `useEffect` (or equivalent derived-state sync) keyed on
   `activeDefinitionLookup`'s `found`/`not_found`/`error` transitions, specifically:
   - On `found`: `setStartDefinitionVersion(definition.version)` and
     `setStartDefinitionId(definition.id)`, set together in the same effect pass — the
     ISS-0891 invariant ("version text and submit-target id are set atomically, never
     one render apart") is preserved because both still originate from one state
     transition (the query settling), not two independent handlers.
   - On `not_found` or `error`: `setStartDefinitionVersion('')` and
     `setStartDefinitionId(undefined)` — matches today's else-branch behavior (lines
     196-199), just retriggered by the query's settled-miss state instead of a
     synchronous list-scan miss.
   - On `idle`/`loading`: leaves `startDefinitionVersion`/`startDefinitionId` at
     whatever they currently are — critically, this means a value that was `found` a
     moment ago (e.g. user backspaces one character mid-edit) is **not** eagerly
     cleared the instant the debounce window reopens; it only clears once the new
     debounced lookup actually settles as `not_found`/`error`. This avoids a visible
     "flicker to empty" on every keystroke, which the old synchronous list-scan did not
     have to worry about (it resolved same-render) but a debounced async lookup would
     introduce if state were cleared eagerly on every raw keystroke instead of on
     settled lookup state.
3. The existing side effect of pushing the resolved name/id into the **page-level**
   `searchParams` (lines 192-195, `updated.set('definitionName', exact.name)` /
   `updated.set('definitionId', exact.id)`) is preserved, moved into the same `found`
   branch of the new effect — this fix does not remove that URL-sync behavior, since
   nothing in ISS-0911's diagnosis implicates it and removing it would be scope creep
   beyond the owned bug.

## 6. `definitionTypeahead` — confirmed remaining legitimate use

`definitionTypeahead` (from `useDefinitions({ status: 'ACTIVE', name: definitionName ||
undefined })`, lines 85-88) is **not** removed. It still backs:

- The `<datalist id="instance-definition-filter-options">` referenced by both the
  page-level filter input (`instance-definition-filter`) and, via the dialog input's
  own `list="instance-definition-filter-options"` attribute (line 437), the dialog's
  typeahead suggestion dropdown. The dialog input still benefits from
  browser-native autocomplete suggestions sourced from this list — that is a
  suggestion/autocomplete affordance, not the actual resolution path (which this design
  moves to `useActiveDefinitionByName`), so the list being page-filter-scoped and
  possibly-incomplete is cosmetically imperfect (a just-created definition might not
  appear as a *suggestion*) but no longer **functionally** load-bearing — the user can
  still type the full exact name manually and have it resolve correctly via the new
  hook even if it never appeared in the suggestion list.
- `onResolveDefinition` (lines 140-151), the page-level filter's own `onBlur` handler —
  entirely separate code path from the dialog, untouched by this design.

No change to `definitionTypeahead`'s own query (`useDefinitions` call, lines 85-88) or
its declaration is in scope for this fix.

## 7. Open questions (not silently resolved)

- **OQ-1 (§4.1).** Whether the superseded in-flight request for a stale debounced name
  should be actively cancelled (`AbortController`/query-level `signal`) for network
  efficiency, given `web/src/api/client.ts`'s `request()` does not currently accept an
  abort signal. Correctness does not require this (§4.1), so this fix does not add it;
  flagged for ELIXIR-DEV/FRONTEND-DEV or a follow-up issue if wasted in-flight lookups
  become a measured concern.
- **OQ-2 (§3).** Exact debounce delay (300ms proposed, matching `DefinitionListPage.tsx`'s
  existing convention) is not dictated by any acceptance criterion; FRONTEND-DEV may
  tune it without changing this design's structure, since §4.1's correctness guarantee
  is independent of the chosen delay.
- **OQ-3 (§5.2).** Whether `not_found` should message differently for "still typing, not
  yet a full valid name" vs. "typed a complete name that genuinely doesn't exist" — this
  design does not distinguish those (both are a settled 404 on the trimmed value),
  since no acceptance criterion asks for that distinction and the debounce (§4.2)
  already suppresses a lookup firing mid-keystroke for the common case.

## 8. Acceptance-criteria → design-element map

| AC | Design element |
|---|---|
| Lookup calls `definitionsApi.getActive(name)` keyed on the dialog's own typed value | §3 `useActiveDefinitionByName`, §4.2 `useDebounce(startDefinitionName, ...)` feeding it — never `definitionTypeahead` |
| Race-guard against out-of-order async responses (rapid typing), explicit | §4.1 (per-value query-key cache isolation, explicitly reasoned, not left implicit) |
| Loading/not-found/found version-field states specified | §5 `VersionLookupState`, §5.1 state→UI table (plus `error`, a state the AC's own three-state framing didn't name but the design must not collapse into "not found") |
| No implementation code in the design doc | Type signatures (§3, §5) and control-flow prose only — no request bodies, no effect bodies, no component render output |
