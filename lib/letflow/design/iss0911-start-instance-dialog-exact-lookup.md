# Design: ISS-0911 — Start Instance dialog exact-name version lookup

## Rework 2 (2026-09-30) — one-shot self-write guard, reset on dialog open/close

CODE-DESIGN-VALIDATOR's fresh re-check after rework 1
(`handoffs/WF03-ISS0911-20260930/step-02b-code-design-validator-recheck1.json`) found that
rework 1's merged single effect (§5.2) genuinely closes the two-effect race REVIEWER
originally found, but its `lookupWroteDefinitionId` ref is a **persistent, non-expiring**
guard token: it is only ever *overwritten* by steps 1/2, never cleared/consumed by step 3.
Concrete repro the validator traced: dialog session writes `definitionId = aliceId`
(ref = `aliceId`) → dialog closes (ref untouched) → an unrelated **external** change sets
`definitionId = bobId` (ref still `aliceId`, no match, correctly falls through to Bob's
data) → a **later**, also external, change sets `definitionId` back to `aliceId` (e.g.
page-level filter, browser back/forward — no dialog interaction at all) → step 3's guard
now sees `definitionId(aliceId) === lookupWroteDefinitionId.current(aliceId)` and wrongly
treats this fresh external cause as its own stale-cache self-write, so it does nothing —
`startDefinitionVersion`/`startDefinitionId` stay stuck at Bob's data while `definitionId`
now says Alice. This is a new instance of the exact ISS-0891 invariant (submitted id must
track current `definitionId` context) the whole fix exists to protect.

**Chosen fix: option (a), one-shot/expiring guard — consumed (cleared) the first time
step 3 examines it, whether or not it matches.** Rejected alternative and why:

- **Option (b) (generation/render-token counter) was considered and rejected as
  unnecessary complexity here**, not because it wouldn't work: a monotonically
  incrementing counter captured alongside the written id would also prevent a stale
  match. It was rejected because the underlying hazard window it would protect against
  — multiple effect re-runs between the self-write and `useDefinition(definitionId)`'s
  cache catching up, during which the plain ref could be legitimately needed more than
  once — does not exist in this design. The merged effect's dependency array is
  `[definitionId, activeDefinitionByName?.id, activeDefinitionByName?.version,
  versionLookupState]` (unchanged from rework 1); a `useEffect` body only re-runs when a
  dependency's identity changes, not on every component re-render. After step 1's
  self-write, exactly **one** subsequent effect run observes the new `definitionId` with
  `activeDefinitionByName` still reflecting the old/uncached lookup — the very next run
  after that is triggered either by `activeDefinitionByName` itself updating (at which
  point the data is correct and no guard is needed) or by `versionLookupState` changing
  again (already routed to steps 1/2, not step 3, whenever the debounced exact-name
  lookup is still `found`/settling). A background refetch of the exact-name lookup does
  not reopen this window either: `deriveVersionLookupState` (§5) only reports `loading`
  when `isFetching && !isSuccess` — a background refetch keeps `isSuccess: true` (cached
  data still present), so it stays classified `found` and is handled by step 1, never
  step 3. So step 3's guard only ever needs to suppress exactly **one** render per
  self-write, which is precisely what a one-shot consumed-on-first-check guard provides,
  with less state (`string | undefined` ref, same as rework 1 — no added counter type)
  and a simpler invariant to audit ("can this ever match twice?" → no, by construction,
  because it is cleared the instant it is read) than a generation counter would add.

**Reset on dialog open/close (the second gap the validator found, §1 lines 82-85):**
`openStartDialog` (`InstanceBoardPage.tsx` lines 223-234) already imperatively
re-initializes `startDefinitionVersion`/`startDefinitionId` once, at dialog-open time,
from the page-level `activeDefinitionByName`/`definitionId` — it is now also specified to
clear `lookupWroteDefinitionId.current = undefined` in that same pass, and
`closeStartDialog` (lines 236-238) is now specified to do the same on close. This is
**defense-in-depth, not load-bearing for correctness** given the one-shot consume above
already makes a cross-session stale match structurally impossible (the ref cannot survive
being read once, and it is only ever written by step 1/2 of the dialog's own effect, which
only runs while `versionLookupState` reflects the dialog's own live input) — but it keeps
the invariant "no guard state outlives the dialog session that created it" true by
construction as well as by argument, in case a future change to the effect's dependency
list or `deriveVersionLookupState` ever widens the one-render window above.

§5.2 below is rewritten in place to reflect the one-shot guard and the open/close reset;
rework 1's own account of *why one effect, not two* (unchanged) is preserved below it.

## Rework 1 (2026-09-30) — single write path for `startDefinitionVersion`/`startDefinitionId`

REVIEWER's Step 03d FAIL (`handoffs/WF03-ISS0911-20260930/step-03d-reviewer.json`) found
that the original version of this design (and its implementation) still had **two**
independent `useEffect`s writing `startDefinitionVersion`/`startDefinitionId`: the
pre-existing `definitionId`/`useDefinition(definitionId)`-driven effect (§5.2's old text,
now superseded) and the new `versionLookupState`-driven effect (§5.2, original). The new
effect's own `setSearchParams` call on a `found` transition changes the `definitionId`
prop on the next render, which re-triggers the *old* effect before
`useDefinition(newDefinitionId)` has any cache entry for that brand-new id — the old
effect then runs with `activeDefinitionByName` still `undefined` and blanks
`startDefinitionVersion` back to `''` while `startDefinitionId` stays correct (via its
`?? definitionId` fallback), transiently desyncing the two values — the exact class of
bug ISS-0891 already fixed once, reintroduced in a new shape via a URL-search-param
feedback loop between two effects.

**Explicit invariant this rework must hold** (this is now the binding acceptance
criterion for both AC1-3 above and the rework's own AC4): *the version display
(`startDefinitionVersion`) and the submitted definitionId (`startDefinitionId`) are
always the same value at the same time, with no intermediate render showing one updated
and not the other — even when a URL search-param write triggered by this fix's own new
effect re-renders the component.*

**Chosen direction: fold both effects into one, single write path** (option (b) from the
rework task, not a same-id skip-guard bolted onto two still-separate effects — see
rationale at the end of §5.2). §5.2 below is rewritten in full to specify this; §1's
former claim that the old effect is "a different, already-correct, untouched data path"
is retracted — it is no longer untouched; it is merged into the new single effect.

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
- Preserves `startDefinitionId`'s own synchronization discipline (ISS-0891) — the
  lookup-driven write still sets `startDefinitionVersion` and `startDefinitionId`
  together, in the same synchronous state-update pass, for exactly the same "must not go
  through `setSearchParams`" reason already documented there.
- **(Rework 1)** Merges the pre-existing `definitionId`/`useDefinition(definitionId)`-
  driven effect and the new `versionLookupState`-driven effect into **one** effect with
  one write path (§5.2) — the original design's claim that the pre-existing effect was
  "a different, already-correct, untouched data path" was wrong: that effect and the new
  one both write the same two state fields, and the new effect's own `setSearchParams`
  call re-triggers the old one. They can no longer be two independent effects.
- Does **not** touch `submitStartInstance`. **(Rework 2)** `openStartDialog` and
  `closeStartDialog` each gain exactly one added line each (clearing
  `lookupWroteDefinitionId.current`, §5.2) — `openStartDialog` otherwise still sets
  `startDefinitionVersion`/`startDefinitionId` imperatively, once, from
  `activeDefinitionByName`/`definitionId` at dialog-open time, not effect-driven, not part
  of the race.
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

### 5.2 Single write path for `startDefinitionVersion` / `startDefinitionId` (Rework 1 — ISS-0891 invariant preserved under the new race)

`onStartDefinitionNameChange` no longer scans `definitionTypeahead.items`, and — as
established in the original design — does **not** itself set
`startDefinitionVersion`/`startDefinitionId`:

1. `setStartDefinitionName(value)` — unchanged, still synchronous, still the source the
   debounce (§4.2) derives from.

Both fields are now written by **exactly one** `useEffect`, replacing the two effects
that previously existed (the `definitionId`/`useDefinition(definitionId)`-driven one and
the `versionLookupState`-driven one). This single effect takes **both** data sources as
inputs and arbitrates between them with an explicit precedence rule, so there is never a
render in which a second, independent effect can observe a `definitionId` change this
effect itself caused and act on stale/uncached data.

**New piece of state: a ref, `lookupWroteDefinitionId` (`useRef<string | undefined>
(undefined)`).** It records the id most recently written to `startDefinitionId` *by this
effect's own `found` branch* (i.e. what the effect itself just pushed into the URL via
`setSearchParams`), so that on the next render — triggered by that very
`setSearchParams` call changing the `definitionId` prop — the effect can tell "the
`definitionId` I'm now seeing is the one I just wrote" apart from "the `definitionId` I'm
now seeing changed for some other reason" (initial mount with a deep-linked
`definitionId`, `onResolveDefinition`'s own `setSearchParams`, `onDefinitionInputChange`
clearing the filter, browser back/forward).

**(Rework 2) The guard is one-shot/expiring, not persistent.** It is consumed — set back
to `undefined` — the first time step 3 examines it, unconditionally, whether or not
`definitionId` matched it (see step 3 below for the exact point of consumption). A value
this ref ever held can therefore influence at most one subsequent effect run; it can never
be matched again by any later render, including one where an unrelated external
`definitionId` change happens to revisit the same id value (the defect
`step-02b-code-design-validator-recheck1.json` found). It is additionally cleared
whenever the dialog closes or (re-)opens — see the added line in `openStartDialog`/
`closeStartDialog`, §1 — as defense-in-depth, though the one-shot consumption above
already makes a cross-session match structurally impossible on its own (rationale in the
"Rework 2" section at the top of this document, including why a generation-token counter
was considered and rejected as unneeded: the effect's dependency array only allows
exactly one run to ever observe a self-written `definitionId` before
`activeDefinitionByName` either resolves for it, correctly ending the need for the guard,
or `versionLookupState` moves the next run to step 1/2 instead of step 3).

The single effect's dependencies are `[definitionId, activeDefinitionByName?.id,
activeDefinitionByName?.version, versionLookupState]`. Its control flow, evaluated in
this fixed priority order every time it runs:

1. **`versionLookupState.kind === 'found'`** — the debounced exact-name lookup is the
   most authoritative signal available (it is a confirmed, current backend exact match
   on what the user is actively typing/selecting), and takes precedence over the
   `definitionId`-driven source unconditionally:
   - `setStartDefinitionVersion(definition.version)` and
     `setStartDefinitionId(definition.id)`, set together in this one effect pass — the
     ISS-0891 invariant is preserved because both still originate from one state
     transition, not two independently-scheduled effects.
   - `lookupWroteDefinitionId.current = definition.id` — records that this effect, not
     an external navigation, is the author of the `definitionId` change about to happen.
   - Then pushes `definitionName`/`definitionId` into `searchParams` via
     `setSearchParams` (same URL-sync behavior the original design already specified —
     unchanged, not removed).
2. **`versionLookupState.kind === 'not_found' | 'error'`** — the debounced lookup has
   settled as a definite miss/failure for the currently-typed name:
   - `setStartDefinitionVersion('')` and `setStartDefinitionId(undefined)`.
   - `lookupWroteDefinitionId.current = undefined` — a miss/error means the dialog's
     typed value no longer resolves to anything, so any earlier self-write is no longer
     "current truth"; this also re-arms the guard in step 3 so a subsequent
     externally-sourced `definitionId` (e.g. the user clears the dialog and the page-
     level filter's own `definitionId` is still present) is not mistaken for a stale
     self-write.
3. **`versionLookupState.kind === 'idle' | 'loading'`** — the lookup branch has no
   opinion this render (nothing has settled yet, or the input is empty). Fall through to
   the `definitionId`-driven source, but only if this render's `definitionId` was **not**
   caused by this effect's own step-1 write:
   - **Guard (Rework 2 — one-shot):** first, read and immediately clear the ref in one
     step: `const wroteId = lookupWroteDefinitionId.current;
     lookupWroteDefinitionId.current = undefined`. This unconditional clear is what makes
     the guard one-shot — every execution of step 3 consumes whatever the ref held,
     regardless of the comparison's outcome, so no value the ref ever held can be
     compared against on a later run.
     - If `definitionId === wroteId` (using the just-read, pre-clear value): this render
       is the direct result of this effect's own `setSearchParams` call from a prior
       pass — `activeDefinitionByName` (from `useDefinition(definitionId)`) is known to
       be uncached/stale for this brand-new id at this exact moment. **Do nothing** —
       leave `startDefinitionVersion`/`startDefinitionId` exactly as step 1 already set
       them. This is the guard that eliminates the original bug: the old effect's
       blanking write simply never happens for a self-caused `definitionId` change. Per
       the one-shot rule above, this comparison can succeed for at most one effect run
       per self-write — the very next run either sees `activeDefinitionByName` resolved
       for this id (falls to the "otherwise" branch below with now-correct data) or sees
       `versionLookupState` no longer `idle`/`loading` (handled by step 1/2 instead).
     - **Otherwise** (`definitionId !== wroteId` — an externally-sourced
       `definitionId`: initial mount with a deep-linked id, `onResolveDefinition`,
       `onDefinitionInputChange`, browser navigation, or a self-written id being
       revisited after its one-shot guard was already consumed on an earlier run) —
       behave exactly as the original pre-existing effect did:
       - if `definitionId` is set: `setStartDefinitionVersion(activeDefinitionByName?.version
         ?? '')` and `setStartDefinitionId(activeDefinitionByName?.id ?? definitionId)`.
       - if `definitionId` is unset: `setStartDefinitionVersion('')` and
         `setStartDefinitionId(undefined)`.
   - `lookupWroteDefinitionId.current` is already `undefined` on exit from step 3 in
     both branches above (cleared at the top, and never re-armed by step 3 — it is only
     ever set again by a future step-1 run), so a run of step 3 never fabricates a false
     "self-caused" signal for a later render, and never leaves stale guard state for a
     future unrelated `definitionId` value to coincidentally match.

**(Rework 2) Reset on dialog open/close.** `openStartDialog` (`InstanceBoardPage.tsx`
lines 223-234) sets `lookupWroteDefinitionId.current = undefined` as part of its existing
imperative initialization pass (alongside `setStartDefinitionVersion`/
`setStartDefinitionId`/etc.), and `closeStartDialog` (lines 236-238) does the same. This
does not change either function's existing behavior toward
`startDefinitionVersion`/`startDefinitionId` themselves — only the guard ref, which is
dialog-session-scoped state and must not leak a stale self-write tag from one dialog
session into the next (the second gap `step-02b-code-design-validator-recheck1.json`
found). Combined with the one-shot consumption above, this ref can now never hold a value
across a dialog close, and can never be matched more than once even within a single
session.

**Why one effect, not two effects plus a same-id skip guard (rework's option (a)).** A
skip-guard bolted onto the *old* effect alone, while the *new* effect stays separate,
still leaves two effects racing on every other dimension (mount order, dependency-array
timing, React's effect-scheduling relative order is not part of either effect's own
contract) — the fix would be correct only by accident of both effects currently being
declared adjacent to each other in source order. Folding them into one effect makes the
precedence between the two data sources an explicit, single, ordered piece of logic
(§5.2 steps 1-3) that cannot depend on effect-scheduling order, because there is only one
effect left to schedule. This also directly answers REVIEWER's finding: there is no
longer a second effect for a `setSearchParams` call to "re-trigger" independently of the
first — there is one effect, and it recognizes its own prior write via
`lookupWroteDefinitionId`.

**Invariant check.** At any render, `startDefinitionVersion`/`startDefinitionId` are
either both untouched (step 3 guard fires, or idle/loading with an unrelated
`definitionId`) or both freshly written together in the same branch (step 1 or step 2's
pair, or step 3's externally-sourced pair) — there is no code path in which one is
written and the other is not, and no code path in which this effect's own
`setSearchParams` causes a *second* write pass with different (stale) data, because
there is no second effect left to run one.

**(Rework 2) Second invariant check — the guard cannot desync the pair either.** The
one-shot guard only ever causes step 3 to do *nothing* (leaving the pair exactly as step 1
already wrote it, together) or to fall through to the "otherwise" branch's own
together-written pair — it never itself writes only one of the two fields, and, being
consumed on every read (matched or not), it cannot cause "do nothing" to fire for a
`definitionId` value it has no business vouching for anymore, closing the specific defect
`step-02b-code-design-validator-recheck1.json` found (an indefinitely-stale ref wrongly
vouching for a `definitionId` value that recurred long after the self-write it was meant
to describe).

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
| **(Rework 1)** Single write path for `startDefinitionVersion`/`startDefinitionId`, no possibility of the new effect's own `setSearchParams` re-triggering a second, independent effect that transiently desyncs the two values | §5.2 (rewritten) — one merged effect, `lookupWroteDefinitionId` ref guard against acting on a self-caused `definitionId` change while `activeDefinitionByName` is still uncached for the new id; explicit invariant statement at top of doc under "Rework 1" |
| **(Rework 2)** Guard/token distinguishing a self-caused `definitionId` change from an external one must be one-shot/expiring (or generation-token based), cannot be revived by an unrelated later event reaching the same id value, and is reset on dialog open/close | §5.2 step 3 guard rewritten to read-then-immediately-clear `lookupWroteDefinitionId` (one-shot, option (a) — chosen over a generation-token counter; rationale at top of doc under "Rework 2"); `openStartDialog`/`closeStartDialog` (§1, §5.2) both clear the ref; second invariant check added at end of §5.2 |
