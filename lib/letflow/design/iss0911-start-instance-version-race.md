# Design: ISS-0911 — Start Instance version field stuck empty on late typeahead data

Status: design (pre-implementation)
Owner (implementation): FRONTEND-DEV
Security review required: **No.** Pure client-side UI/state-derivation fix in
`web/src/pages/instances/InstanceBoardPage.tsx`. No new API calls, no new
endpoints, no change to what is sent to the server (the eventual
`startInstance.mutateAsync({ definition_id, ... })` payload shape is
unchanged), no tenant-data-path change. SECURITY-REVIEWER's gate
(`docs/agents/instructions/security-invariants.md`) does not apply; route
straight to REVIEWER.

## 1. Confirmed current source (read 2026-09-30, not trusting stale line numbers)

File: `web/src/pages/instances/InstanceBoardPage.tsx` (525 lines total).

Relevant current line ranges (re-verified against the live file, differ
slightly from ISSUE-FIXER's approximate 181-200/457):

- L85-88: `const { data: definitionTypeahead } = useDefinitions({ status: 'ACTIVE', name: definitionName || undefined })`
  — keyed on the **page-level** `definitionName` (sourced from
  `searchParams`, L50), not on the dialog-local `startDefinitionName`
  (L63). `isLoading`/`isFetching` are not currently destructured.
- L90-92: `const { data: activeDefinitionByName, isLoading: isLoadingActiveDefinition } = useDefinition(definitionId ?? '')`
  — keyed on page-level `definitionId` (L51).
- L63-64, L77: dialog's own three pieces of mutable state —
  `startDefinitionName` (`useState`), `startDefinitionVersion` (`useState`),
  `startDefinitionId` (`useState<string | undefined>`).
- L104-112: a `useEffect` keyed on
  `[definitionId, activeDefinitionByName?.id, activeDefinitionByName?.version]`
  that writes `startDefinitionVersion`/`startDefinitionId` from the
  page-level `useDefinition` result whenever `definitionId` is present, and
  clears them otherwise. **Runs regardless of whether the dialog is open.**
- L164-175 (`openStartDialog`): on click, re-seeds
  `startDefinitionName`/`startDefinitionVersion`/`startDefinitionId` from
  the current page-level `definitionName`/`activeDefinitionByName`/
  `definitionId`, then sets `showStart(true)`.
- L181-200 (`onStartDefinitionNameChange`): the buggy handler. On every
  keystroke it sets `startDefinitionName`, then does a **one-shot**
  `definitionTypeahead?.items?.find(item => item.name === value)` against
  whatever `definitionTypeahead.items` happens to hold *at that render*. If
  found, synchronously sets `startDefinitionVersion`/`startDefinitionId`
  *and* pushes `definitionName`/`definitionId` into `searchParams`. If not
  found (including "list hasn't arrived yet"), it clears both to `''`/
  `undefined`. Nothing else ever re-invokes this matching logic — a later
  render where `definitionTypeahead.items` finally contains the match is
  never consulted again for this dialog-open.
- L434-447: the dialog's "Definition name" `<input>`, `onChange` wired to
  `onStartDefinitionNameChange`.
- L452-466: the dialog's read-only "Active version (auto-selected)"
  `<input>`, value `startDefinitionVersion`, `placeholder={isLoadingActiveDefinition ? 'Loading active version…' : ''}`
  (line ~457). `isLoadingActiveDefinition` comes only from `useDefinition`
  (L90), which never starts fetching in the failing race because
  `definitionId` is never set (see below) — so no loading affordance is
  visible during the actual race window.
- L208-211 (`submitStartInstance`): blocks submission with
  `'Select a valid active definition name.'` whenever `!startDefinitionId`.

## 2. Root cause (confirmed, matches ISSUE-FIXER)

`startDefinitionVersion`/`startDefinitionId` are **imperatively-written
`useState`**, written only at two discrete moments: dialog-open
(`openStartDialog`) and keystroke (`onStartDefinitionNameChange`). Neither
moment is guaranteed to coincide with `definitionTypeahead.items` actually
containing the entry the user is typing, because `useDefinitions` is an
async TanStack Query fetch that may still be in flight (cold fetch on
first page mount — exactly the `platform-definition-promotion-rollback` UAT
path: land on the instance board, immediately open Start Instance, type the
process key before the ACTIVE-definitions list has resolved). Once that
keystroke's `find` misses, there is no second chance: no effect is keyed on
`definitionTypeahead.items` itself, so a match that becomes available one
render later is silently ignored for the remainder of that dialog-open.

A second, independent defect compounds the missing affordance: the
"Loading active version…" placeholder is gated solely on
`isLoadingActiveDefinition` (from `useDefinition(definitionId)`), a query
that is `enabled: !!id` (see `useDefinitions.ts` L16-23) and therefore
**never starts** in the failing race, since `definitionId` is never set
when the typeahead match never succeeds. The user sees a bare empty,
non-loading field, indistinguishable from "no such definition."

## 3. Fix mechanism — derive, don't sync

Core idea: stop storing `startDefinitionVersion`/`startDefinitionId` as
`useState` written by event handlers/effects that fire once. Compute them
as plain **render-time derived values** (a `useMemo`, not a `useEffect`),
so they automatically recompute on *every* render that changes either the
typed name or the typeahead data — including the render triggered when a
slow `useDefinitions` fetch finally resolves. This is the React idiom of
"derive state instead of syncing it" and is what closes the race
structurally (no moment is special-cased; every render recomputes).

### 3.1 State shape changes

| Symbol | Before | After |
|---|---|---|
| `startDefinitionName` | `useState<string>` | **unchanged** — still `useState<string>`, written only by `onStartDefinitionNameChange` and `openStartDialog`/dialog-open seeding. This one legitimately needs to be state: it mirrors the literal keystrokes in a controlled `<input>`. |
| `startDefinitionVersion` | `useState<string>`, written by L104-112 effect, `openStartDialog`, `onStartDefinitionNameChange` | **removed as state.** Becomes a derived `const` computed each render from `matchedStartDefinition` (see 3.2), with a `''` fallback. |
| `startDefinitionId` | `useState<string \| undefined>`, written by the same three sites | **removed as state.** Becomes a derived `const`, same source. |
| `useEffect` at L104-112 | keeps `startDefinitionVersion`/`startDefinitionId` in sync with `definitionId`/`activeDefinitionByName` | **deleted.** Its job is now subsumed by the 3.2 derivation, which already falls back to `activeDefinitionByName`/`definitionId` — see 3.2's second branch. Keeping it alongside the new derivation would reintroduce exactly the "stale `useState` fighting a derived value" shape this fix removes. There is no other reader of `startDefinitionVersion`/`startDefinitionId` outside the dialog (confirmed by search — only the dialog JSX and `submitStartInstance` reference them), so deleting the effect has no effect on anything besides the dialog. |
| `openStartDialog` (L164-175) | sets `startDefinitionName`, `startDefinitionVersion`, `startDefinitionId`, plus the other dialog-reset fields | **simplify:** still sets `startDefinitionName` (seed from page-level `definitionName`) and the other reset fields (`startCorrelationKey`, `startVariablesJson`, `startError`, `startValidationError`, `showStart`); **stop** setting `startDefinitionVersion`/`startDefinitionId` explicitly — they are derived and will already reflect the right value the instant `startDefinitionName` is seeded, because the derivation's second branch (3.2) falls back to the already-loaded `activeDefinitionByName`/`definitionId` exactly as the deleted effect did. |
| `onStartDefinitionNameChange` (L181-200) | sets `startDefinitionName`, then imperatively matches + sets version/id + pushes searchParams | **simplify to:** sets `startDefinitionName` only. All matching moves to the derivation (3.2); the searchParams-push side effect moves to a new effect keyed on the match (3.3). |

### 3.2 The derivation itself

Add a new derived value, `matchedStartDefinition`, next to the existing
`useMemo`/`useEffect` block, after `definitionTypeahead`/
`activeDefinitionByName` are destructured. It is a memoized lookup —
recomputed whenever either the typed dialog name (`startDefinitionName`) or
the typeahead result's item list (`definitionTypeahead?.items`) changes — of
the first item in `definitionTypeahead.items` whose `name` exactly equals
`startDefinitionName`. Its shape when found is the matched item
(`{ id, version, name }`); when no list is present yet or nothing matches,
it is `undefined`.

`startDefinitionId` and `startDefinitionVersion` are then two plain derived
`const`s (no `useState`, no `useEffect`) computed each render from
`matchedStartDefinition`, in this precedence order:

1. **Exact typeahead match** (`matchedStartDefinition`) — covers the
   "user is typing a new process key in the dialog" path, and is now
   reactive: it recomputes whenever `definitionTypeahead?.items` updates
   (the fetch resolving), not only when `startDefinitionName` changes. This
   is the direct fix for the reported bug: a match that lands one or more
   renders after the keystroke is picked up automatically.
2. **Page-level fallback** (`activeDefinitionByName`/`definitionId`), used
   only when the dialog's typed name still equals the page-level
   `definitionName` the dialog was opened/seeded with (i.e., the user
   hasn't changed it since opening). This preserves the pre-existing
   behavior of `openStartDialog` + the deleted L104-112 effect for the
   common "Start Instance" click from an already-filtered board (where
   `useDefinition(definitionId)` may have already resolved even if the
   unfiltered typeahead list hasn't).
3. Otherwise, `startDefinitionId` is `undefined` and `startDefinitionVersion`
   is `''` — submission stays blocked
   (`'Select a valid active definition name.'`), correctly, until a match
   resolves.

Concretely: `startDefinitionId` takes `matchedStartDefinition.id` when a
match exists; otherwise, only if the typed name still equals the page-level
`definitionName`, it falls back to `activeDefinitionByName?.id` (or, absent
that, the page-level `definitionId`); otherwise `undefined`.
`startDefinitionVersion` follows the identical shape, substituting
`matchedStartDefinition.version` / `activeDefinitionByName?.version` / `''`
at each step.

`onStartDefinitionNameChange` becomes: sets `startDefinitionName` to the new
value and does nothing else — no matching logic, no `searchParams` push. All
of that responsibility moves to the derivation above (matching) and to the
new effect in §3.3 (the `searchParams` push).

### 3.3 Preserving the searchParams side effect

The deleted matching code also had a side effect: on an exact match, it
pushed `definitionName`/`definitionId` into the URL (keeping the page-level
instance-list filter in sync with what was just typed in the dialog). To
preserve this without reintroducing "only fires at keystroke time," move it
into a new effect keyed on the *resolved match itself*, so it too benefits
from re-firing when the match resolves late.

The effect's dependency array is
`[showStart, matchedStartDefinition?.id, matchedStartDefinition?.name, definitionId, definitionName]`.
Its body is three sequential guard clauses followed by the push:

1. If the dialog is not open (`!showStart`), do nothing.
2. If there is no resolved match (`!matchedStartDefinition`), do nothing.
3. If the page-level `definitionId`/`definitionName` already equal
   `matchedStartDefinition.id`/`.name` (no-op case — nothing has actually
   changed), do nothing.
4. Otherwise, push `matchedStartDefinition.name`/`.id` into `searchParams`
   as `definitionName`/`definitionId`, the same values the old inline logic
   pushed, and also reset the cursor stack (`setCursorStack([])`), matching
   `onDefinitionInputChange`'s existing convention whenever the page-level
   filter changes.

Guarded by `showStart` so it only fires while the dialog is actually open
(no background URL churn from stale `startDefinitionName` after close —
`startDefinitionName` is not reset on `closeStartDialog`, matching current
behavior, but the guard makes that harmless). Guarded against a no-op
update (`definitionId`/`definitionName` already matching) to avoid a
render loop between this effect and the `useSearchParams`-driven
`definitionName`/`definitionId` derivation.

### 3.4 Loading indicator fix

At the existing `useDefinitions({...})` call site (L85-88), rename the
destructured result to also pull out the query's loading flag under a new
local name, `isLoadingDefinitionTypeahead` — today only `data:
definitionTypeahead` is destructured; this adds `isLoading:
isLoadingDefinitionTypeahead` alongside it. No change to the query's
arguments.

Add a second, independent boolean, `isResolvingStartDefinitionVersion`,
distinct from the existing `isLoadingActiveDefinition`. It is `true` exactly
when all four of the following hold simultaneously, and `false` otherwise:
the dialog is open (`showStart`); the typed name is non-blank
(`startDefinitionName.trim().length > 0`); no match has been found yet
(`!matchedStartDefinition`); and the typeahead query is still loading
(`isLoadingDefinitionTypeahead`).

Widen the version field's `placeholder` so it reads "Loading active
version…" when *either* of the two loading signals is true —
`isLoadingActiveDefinition` (the pre-existing page-level signal) or the new
`isResolvingStartDefinitionVersion` — and is empty otherwise.

This covers exactly the window the bug report calls out: typed name
present, no match yet, and the typeahead fetch is still in flight — visible
even when `definitionId`/`useDefinition` never starts (the race case),
because it no longer depends on `isLoadingActiveDefinition` at all.

**Error-path note:** if the `useDefinitions` typeahead query settles into an
error state rather than resolving with data, TanStack Query's `isLoading`
flag goes `false` on that transition (it reflects "no data and a fetch is in
flight," not "still pending"). `isResolvingStartDefinitionVersion` therefore
also becomes `false`, the loading placeholder is no longer shown, and
`matchedStartDefinition` stays `undefined` (no items to match against) — the
UI falls through to the ordinary "no match" path (empty version, submission
blocked with the existing validation message). No special-cased error
handling is required; this is a safe degradation of the existing branches.

### 3.5 Net diff shape (no implementation code, just the change list)

1. Delete `useState` declarations for `startDefinitionVersion` and
   `startDefinitionId` (L64, L77); delete their doc-comment block (L65-76)
   or fold its ISS-0891 rationale into a comment on the new derivation
   (the reasoning — "must not route through `setSearchParams`/URL
   `definitionId` for the submit target" — still holds and should not be
   lost; the derivation's `startDefinitionId` remains a plain local
   value read directly by `submitStartInstance`, never round-tripped
   through `searchParams`).
2. Delete the `useEffect` at L104-112.
3. Add `matchedStartDefinition` `useMemo` + the two derived `const`s (3.2).
4. Simplify `openStartDialog` (drop the two explicit sets).
5. Simplify `onStartDefinitionNameChange` (drop all matching/searchParams
   logic).
6. Add the searchParams-sync `useEffect` (3.3).
7. Destructure `isLoading` from `useDefinitions(...)` and add the
   `isResolvingStartDefinitionVersion` const + widened placeholder (3.4).

## 4. Explicit acceptance criteria

- AC1: Typing a process key into the Start Instance dialog's
  `start-definition-name` field, when `useDefinitions({status:'ACTIVE'})`
  has not yet resolved at keystroke time, and the key matches a definition
  present in the list **once it resolves**, results in
  `start-definition-version` populating with that definition's version —
  without any further keystroke, blur, or dialog re-open — as soon as the
  query resolves.
- AC2: During the window between keystroke and the typeahead query
  resolving (AC1's setup), `start-definition-version`'s placeholder reads
  "Loading active version…" (not blank-with-no-affordance).
- AC3: `submit-start-instance` remains blocked with "Select a valid active
  definition name." for as long as no match is resolved (typed value
  doesn't match any item once the list is loaded, or the list is still
  loading and no page-level fallback applies) — i.e., the fix must not
  relax the existing validation, only its timing.
- AC4: Opening the Start dialog while the page is already filtered to a
  known `definitionId` (the common path, unaffected by this bug) continues
  to prefill `start-definition-version` immediately from
  `activeDefinitionByName`, matching current behavior exactly (regression
  guard on the 3.2 second branch / deleted L104-112 effect).
- AC5: Typing a name that exactly matches the page-level filter's already-
  resolved definition still sets `startDefinitionId` to the *dialog's own*
  submit target (never silently reads `definitionId` from `searchParams`
  after `setSearchParams` has raced ahead of it) — preserves the ISS-0891
  invariant referenced in the deleted comment block; re-assert this as a
  regression test, not just inherited by re-reading old code.
- AC6: No infinite render loop between the new searchParams-sync effect
  (3.3) and the `definitionName`/`definitionId` `useSearchParams`-derived
  values — verified by the component test remaining in a settled DOM state
  (no unbounded `act()` warnings / no repeated `setSearchParams` calls)
  after the match resolves.

## 5. Test coverage design (component test, not e2e)

New file:
`web/src/pages/instances/__tests__/InstanceBoardPage.start-dialog-version-race.test.tsx`
(sibling of the existing
`InstanceBoardPage.tenant-isolation.test.tsx`, same mocking conventions —
confirmed from that file: `vi.mock('@/hooks/useDefinitions', ...)`,
`vi.mock('@/hooks/useInstances', ...)`, `vi.mock('@/auth/AuthContext', ...)`,
`vi.mock('@/hooks/usePolling', ...)`, `vi.mock('@tanstack/react-query', ...)`
for `useQueryClient`, `vi.mock('react-router-dom', ...)` for
`useNavigate`/`useSearchParams`/`Link`).

Mechanism to simulate "late-resolving `useDefinitions`": mock
`useDefinitions` (from `@/hooks/useDefinitions`) as a `vi.fn()` whose return
value the test controls across two phases — not TanStack Query's real
async machinery, so timing is deterministic:

- Phase 1 (initial render): `useDefinitions` mock returns
  `{ data: undefined, isLoading: true }`.
- Phase 2 (after a controlled re-render, e.g. via `rerender()` or by having
  the mock read from a `let` the test mutates then triggers a state update
  to force re-render): `useDefinitions` mock returns
  `{ data: { items: [{ id: 'def-1', name: 'sample-process', version: '2.0.0', status: 'ACTIVE' }] }, isLoading: false }`.

Test cases (interfaces only — no test body code per CODE-DESIGNER scope,
just what each must assert):

1. **`start-definition-version populates after late typeahead resolve`**
   (AC1/AC2 — the core regression test):
   - Render with `useDefinitions` in Phase 1 shape, `useAuth` mocked with a
     `START_ROLES`-eligible session.
   - Click `start-instance-button` to open the dialog.
   - Type `sample-process` into `start-definition-name` (fire a change
     event) — at this point `useDefinitions` is still Phase 1.
   - Assert `start-definition-version`'s value is `''` and its
     `placeholder` attribute is `'Loading active version…'` (AC2).
   - Assert `submit-start-instance` click still produces the
     `'Select a valid active definition name.'` validation message (AC3),
     confirming no premature/false match.
   - Transition the mock to Phase 2 and force a re-render (mirroring how a
     resolved `useQuery` triggers a React re-render in the real app).
   - Assert — **without any further interaction with
     `start-definition-name`** — `start-definition-version`'s value is now
     `'2.0.0'` (AC1, the exact regression this issue reports).
   - Assert clicking `submit-start-instance` now calls the mocked
     `useStartInstance().mutateAsync` with `definition_id: 'def-1'` (AC3's
     converse — submission unblocks once the match resolves).
2. **`no match found keeps version empty and validation blocked`**
   (negative control for AC3): Phase 2 data present from the start, typed
   value `'does-not-exist'`, assert version stays `''`, no loading
   placeholder (`isLoading: false` means `isResolvingStartDefinitionVersion`
   must be `false`), and submit still blocked.
3. **`page-level prefill still works when dialog opens with a known definitionId`**
   (AC4, regression guard for the deleted L104-112 effect): mock
   `useSearchParams` to return `definitionId=def-1&definitionName=sample-process`
   already set, mock `useDefinition` (not `useDefinitions`) to resolve
   `{ id: 'def-1', version: '3.1.0' }` synchronously, open the dialog
   without typing anything new, assert `start-definition-version` shows
   `'3.1.0'` immediately.
4. **`typed match does not leak stale URL definitionId into submit target`**
   (AC5, ISS-0891 regression guard): simulate the `setSearchParams` mock
   being a no-op spy (as the existing tenant-isolation test already does)
   so `definitionId` from `searchParams` never actually updates within the
   test; type a name that matches a **different** id than whatever
   `definitionId` the searchParams mock reports; assert `mutateAsync` is
   called with the *typed match's* id, not the stale searchParams one.

Each test must use the same provider/mocking shape as
`InstanceBoardPage.tenant-isolation.test.tsx` (`QueryClientProvider` is not
even required if `useDefinitions`/`useDefinition`/`useInstances` are fully
mocked, matching that file's existing pattern of not wrapping in one).

## 6. Explicit open questions / out-of-scope observations

- **Typeahead query is keyed on page-level `definitionName`, not the
  dialog's own `startDefinitionName`.** `useDefinitions({..., name:
  definitionName || undefined})` (L85-88) filters server-side by the
  *page* filter box's text, not by what's typed into the dialog. When the
  page filter is empty (the common "fresh board, click Start Instance"
  entry path — and the one the failing UAT scenario exercises), this
  fetches **all** ACTIVE definitions unfiltered, and the dialog's exact-
  match `find` works client-side over that full list — consistent with
  this fix. But if the page filter is *non-empty* and does not match what
  the user types into the dialog, the fetched list will never contain the
  dialog's typed name at all, match or no race. This is a **pre-existing,
  separate behavior** (not changed by this fix, not the subject of
  ISS-0911, and not exercised by the failing UAT scenario per
  ISSUE-FIXER's diagnosis) — flagging rather than silently folding a fix
  for it into this change. Recommend a follow-up issue if product wants
  the dialog's typed name to independently drive its own
  `useDefinitions({name: startDefinitionName})` query instead of piggy-
  backing on the page filter's.
- **`onResolveDefinition`** (L140-151, the page-level filter's `onBlur`
  handler) has the same "one-shot `find` against whatever `items` happens
  to hold at that instant" shape as the deleted
  `onStartDefinitionNameChange` matching code, but for the *page* filter
  input, not the dialog. Out of scope for ISS-0911 (issue and UAT failure
  are specifically about the Start Instance dialog), left unchanged; flag
  as a candidate for a similar fix if the same race is ever reported there.
- **Whether `isLoadingDefinitionTypeahead` should use TanStack's
  `isFetching` instead of `isLoading`** for the loading placeholder: this
  design uses `isLoading` (true only while there is no cached data at all),
  which covers the reported "cold fetch on first mount" case exactly.
  If a later report shows the same empty-field symptom on a *background
  refetch* (cached data present but stale, e.g. after an unrelated
  invalidation), `isFetching` would be the more correct signal — deferring
  that choice rather than guessing, since nothing in ISS-0911's evidence
  indicates a refetch (not cold-fetch) scenario.
