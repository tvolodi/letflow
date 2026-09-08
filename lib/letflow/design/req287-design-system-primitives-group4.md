# REQ-287 — PaginationControls design-system primitive (group 4 of 4)

**Run:** WF02-REQ287-20260909 · **Step:** 1 (CODE-DESIGNER) · **Requirement:** REQ-287

This is a design artefact. It contains no implementation code — no `.tsx` file is
written or edited by this requirement. It gives an exact TypeScript prop interface,
the text-generation formulas, disabled-state logic, token mapping, and the new
`docs/frontend/design-system.md` §7.8 spec-block text. Signatures, shapes, and
documentation prose only — no function bodies. Matches the format/conventions of the
sibling designs `lib/letflow/design/req272-design-system-primitives-group1.md` (REQ-272)
and `lib/letflow/design/req274-datatable-filterbar.md` (REQ-274).

---

## 0. Re-verification (2026-09-09)

**Section 7.8 does not exist yet.** `grep -n "^### 7\.7\|^### 7\.8\|^## 8\." docs/frontend/design-system.md`:

```
409:### 7.7 FilterBar
436:## 8. Page Layout Template
```

There is no `### 7.8` heading. §7.7 (FilterBar) ends, then §8 begins directly, and §8's
usage example references `<PaginationControls ... />` (line 449) with no prop values
shown — the same "bare usage example, no spec block" situation REQ-274 found and
resolved for §7.7. REQ-274's own design doc (§5) explicitly recorded "Section 7.8
(PaginationControls) is explicitly out of scope for this requirement — not designed,
not added" — confirming this requirement is the first to author it, not correct an
existing one. The requirement text's "Recorded API" (`page`, `pageSize`, `totalItems`,
`onPageChange`, `onPageSizeChange`) is therefore read as **the starting proposal this
design step is meant to validate against real usage and then commit to
`design-system.md` §7.8**, not as an existing spec block to diff against.

`ls web/src/components/ui/ | grep -i pagination` returns nothing — `PaginationControls.tsx`
does not exist. Confirmed via directory listing in §6 tooling below (component list
unchanged from REQ-274's own re-verification plus `DataTable.tsx`, `FilterBar.tsx` now
present from REQ-274 merge).

**Codebase conventions confirmed by re-reading `Button.tsx`, `FilterBar.tsx`,
`PageLayout.tsx` (all `web/src/components/ui/`):**
- Function components, named export, `export interface <Name>Props`.
- Styling via inline `style={{...}}` referencing `var(--token-name)` only.
- `data-testid` on every structural/interactive element.
- Composite controls reuse existing primitives rather than re-implement them —
  `FilterBar`'s "Clear filters" action reuses `Button variant="ghost" size="sm"`
  rather than a bespoke `<button>`. This design follows the same rule for
  Previous/Next (§3).
- Tests co-located at `web/src/components/ui/__tests__/<Name>.test.tsx`.

---

## 1. Reading the real hand-rolled pagination (per the requirement's own instruction)

Two pages in `web/src/pages/` hand-roll pagination today. Both were read in full.

### 1.1 `web/src/pages/admin/AuditLogPage.tsx`

- State: `cursorStack: string[]` (a stack of opaque cursor tokens) and
  `pageSize: number` (default 25).
- "Previous": `setCursorStack(prev => prev.slice(0, -1))` — pops the stack, disabled
  when `cursorStack.length === 0` (i.e. on the first page).
- "Next": pushes `data.next_cursor` onto the stack, disabled when `!nextCursor`
  (`nextCursor = data?.next_cursor`).
- Page-size selector: a raw `<select>` with options `25 / page`, `50 / page`,
  `100 / page` — changing it resets `cursorStack` to `[]`.
- **No "Showing X-Y of Z" (or X-Y) summary text is rendered anywhere.** The API
  (`CursorPage<T>` — see `web/src/types/api.ts`) carries `items` and `next_cursor`
  only; there is no total-count field anywhere in the response shape.
- No numeric page indicator is shown either — only Previous/Next buttons and the
  size selector.

### 1.2 `web/src/pages/instances/InstanceBoardPage.tsx`

- State: `cursor` and `pageSize` both live in the URL's `searchParams` (not
  component state), default `pageSize = 25`. No page-size selector is rendered in
  this page's UI — the value can only change via a direct URL edit today.
- "First page": clears the `cursor` search param, disabled when `!cursor`.
- "Next page": sets `cursor` to `instancesQuery.data.next_cursor`, disabled when
  `!instancesQuery.data.next_cursor`.
- No true single-step "Previous" — only "First page" (jump to page 1) and "Next
  page". No numeric page indicator, no "Showing X-Y" text; only a plain
  `Page size: {pageSize}` label with no control to change it.

### 1.3 What this means for the "Recorded API" in the requirement text

Both real pages are **cursor-based**, never learn a total row count from the API,
and both already gate their "Next" button on a concrete signal: "is there a
`next_cursor` in the last response." Neither page currently renders a "Showing X-Y"
summary at all — so there is no existing precedent to copy for that text's exact
wording, only for the *disabling* mechanism.

The requirement's recorded 5-prop API (`page`, `pageSize`, `totalItems`,
`onPageChange`, `onPageSizeChange`) has no prop through which the composing page can
tell `PaginationControls` "there is/isn't a next page" when `totalItems` is `null`.
Without such a signal, `PaginationControls` cannot compute the Next button's disabled
state in the cursor variant at all — it would have to guess, which contradicts both
the requirement's stated behavior ("next disabled on last page") and its own
instruction to resolve exactly this kind of gap rather than hand-wave it.

**Correction made to `design-system.md` §7.8 (added in the same change as this
design, since §7.8 does not yet exist — see §2 below): a sixth prop,
`hasNextPage`, optional but semantically required whenever `totalItems` is
`null`.** Motivating real usage: `AuditLogPage`'s `!nextCursor` and
`InstanceBoardPage`'s `!instancesQuery.data.next_cursor` are exactly this boolean,
already computed by both pages today from `CursorPage<T>.next_cursor`; adding
`hasNextPage` lets `PaginationControls` consume that existing signal directly
instead of inventing a new one, and keeps `PaginationControls` itself agnostic to
what a "cursor" is (it never receives or touches `next_cursor` — only the derived
boolean). This is the one addition beyond the requirement's literal 5-prop list;
everything else in the recorded API (`page`, `pageSize`, `totalItems`,
`onPageChange`, `onPageSizeChange`) is adopted as-is because nothing in either real
page contradicts it.

`page` itself stays a **caller-maintained sequential counter**, not a value
`PaginationControls` derives from the data. Both real pages already do this
implicitly (`cursorStack.length` for Audit Log, an implicit "am I past page 1"
boolean for Instances); this design makes it an explicit integer prop so
`PaginationControls` can render/increment/decrement it uniformly, but it does not
imply random-access "jump to page N" — only sequential prev/next, matching both real
pages and the requirement's own four stated behaviors (no "jump to page" behavior is
listed).

---

## 2. New `docs/frontend/design-system.md` §7.8 — PaginationControls

**Insertion point:** immediately after the existing §7.7 (FilterBar, ends at the `---`
before `## 8. Page Layout Template`), as `### 7.8 PaginationControls` — preceding §8,
matching how §7.1–7.7 are already ordered.

**Spec-block text to insert:**

> ### 7.8 PaginationControls
>
> ```tsx
> <PaginationControls
>   page={number}                      // 1-indexed current page
>   pageSize={number}                  // current page size; one of 25, 50, 100
>   totalItems={number | null}         // null when the total row count is unknown
>                                       // (cursor-based pagination)
>   onPageChange={(page: number) => void}
>   onPageSizeChange={(pageSize: number) => void}  // optional; omit to hide the
>                                                   // page-size selector
>   hasNextPage={boolean}              // optional; only consulted when totalItems
>                                       // is null — whether another page exists
>                                       // beyond the current one (e.g. derived from
>                                       // an API response's next_cursor being
>                                       // non-null). Ignored when totalItems is a
>                                       // number — next-disabled is computed from
>                                       // page * pageSize >= totalItems instead.
>                                       // Treated as false (Next disabled) when
>                                       // omitted and totalItems is null.
> />
> ```
>
> - Summary text, `totalItems` known: `Showing {start}-{end} of {totalItems}`, where
>   `start = (page - 1) * pageSize + 1` and `end = min(page * pageSize, totalItems)`.
> - Summary text, `totalItems` null (cursor pagination): `Showing {start}-{end}`
>   (no "of Z" suffix), where `start = (page - 1) * pageSize + 1` and
>   `end = page * pageSize`. This assumes a full page except where `hasNextPage` says
>   otherwise; a partial last page may show an `end` slightly higher than the actual
>   last row's ordinal — accepted because no per-page row count is available to this
>   component (see OQ-1).
> - "Previous" is disabled when `page <= 1`.
> - "Next" is disabled when: `totalItems` is a number and `page * pageSize >=
>   totalItems`; or `totalItems` is `null` and `hasNextPage` is not `true`.
> - Page-size selector (`<select>`, options `25`, `50`, `100`) renders only when
>   `onPageSizeChange` is supplied; entirely absent otherwise.
> - "Previous"/"Next" are real, focusable `<button>` elements (via this design
>   system's own `Button`) with visible text labels ("Previous"/"Next") — their
>   accessible name comes from that text content, and their disabled state is the
>   native `disabled` HTML attribute (not a styling-only affordance), satisfying
>   FNFR-03 (WCAG 2.1 AA).

**Correction note recorded in §7.8 itself (mirrors this design's §1.3):** a sixth
prop, `hasNextPage`, was added beyond the requirement's originally recorded 5-prop
list because the recorded API gave `PaginationControls` no way to compute the Next
button's disabled state when `totalItems` is `null` — confirmed against
`AuditLogPage.tsx`'s `!nextCursor` and `InstanceBoardPage.tsx`'s
`!instancesQuery.data.next_cursor`, both of which already compute and use exactly
this boolean today. See REQ-287 design doc §1 for the full comparison.

---

## 3. `PaginationControls.tsx`

### 3.1 Prop interface (matches §7.8 as just authored in §2)

```ts
export interface PaginationControlsProps {
  page: number                                  // 1-indexed current page
  pageSize: number                              // one of 25, 50, 100
  totalItems: number | null                     // null when total is unknown
  onPageChange: (page: number) => void
  onPageSizeChange?: (pageSize: number) => void  // omit to hide the size selector
  hasNextPage?: boolean                          // consulted only when totalItems is null
}

export const PAGE_SIZE_OPTIONS = [25, 50, 100] as const
```

### 3.2 Derived values (pure computation, no state of its own)

- `start = (page - 1) * pageSize + 1`
- `end = totalItems === null ? page * pageSize : Math.min(page * pageSize, totalItems)`
- `summaryText = totalItems === null ? \`Showing ${start}-${end}\` : \`Showing ${start}-${end} of ${totalItems}\``
- `isPrevDisabled = page <= 1`
- `isNextDisabled = totalItems === null ? hasNextPage !== true : page * pageSize >= totalItems`
- `showSizeSelector = onPageSizeChange !== undefined`

`PaginationControls` holds no internal `useState` — every value above is derived
directly from props on each render (no local mirror of `page`/`pageSize`, consistent
with `FilterBar` holding no filter values of its own, per §7.7's own stated
principle applied here).

### 3.3 Event wiring

- Previous button `onClick`: calls `onPageChange(page - 1)`. Never fires while
  `isPrevDisabled` (native `disabled` prevents the click).
- Next button `onClick`: calls `onPageChange(page + 1)`. Never fires while
  `isNextDisabled`.
- Page-size `<select>` `onChange`: calls `onPageSizeChange(Number(event.target.value))`
  with the selected option's numeric value (25, 50, or 100). `PaginationControls`
  does not reset `page` itself when size changes — that is the composing page's
  responsibility (matches `FilterBar` not owning filter-value reset either; each
  primitive owns layout/chrome, not cross-cutting page state).

### 3.4 Token mapping

| Feature | Token(s) |
|---|---|
| Root container layout | `display: flex`, `justify-content: space-between`, `align-items: center`, `gap: var(--space-4)` |
| Root top separator (visually detaches from `DataTable` above it) | `border-top: 1px solid var(--border-default)`, `padding-top: var(--space-3)` |
| Summary text | `var(--text-secondary)`, `var(--text-sm)` |
| Previous/Next buttons | reuse `Button` (`variant="secondary"`, `size="sm"`) — no bespoke button styling in this file |
| Page-size `<select>` border | `1px solid var(--border-default)` |
| Page-size `<select>` border radius | `var(--radius-sm)` |
| Page-size `<select>` padding | `var(--space-1) var(--space-2)` |
| Page-size `<select>` text | `var(--text-sm)`, `var(--text-primary)` |
| Page-size `<select>` background | `var(--surface-card)` |
| Inter-control gap (size selector to Previous/Next group) | `var(--space-3)` |

Every token above is already present in `web/src/styles/tokens.css` (re-checked
directly, not from memory — full listing in §4). **No new token is needed; nil
addendum.**

### 3.5 Structural sketch (no bodies)

```
<div data-testid="pagination-controls" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--space-4)', borderTop: '1px solid var(--border-default)', paddingTop: 'var(--space-3)' }}>
  <span data-testid="pagination-summary" style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
    {summaryText}
  </span>
  <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-3)' }}>
    {showSizeSelector && (
      <select
        data-testid="pagination-size-select"
        aria-label="Items per page"
        value={pageSize}
        onChange={...}
        style={{ ... }}
      >
        {PAGE_SIZE_OPTIONS.map(size => <option key={size} value={size}>{size} / page</option>)}
      </select>
    )}
    <Button data-testid="pagination-prev" variant="secondary" size="sm" disabled={isPrevDisabled} onClick={...}>
      Previous
    </Button>
    <Button data-testid="pagination-next" variant="secondary" size="sm" disabled={isNextDisabled} onClick={...}>
      Next
    </Button>
  </div>
</div>
```

Note: `Button` does not currently accept a `data-testid` prop (its own `ButtonProps`,
`web/src/components/ui/Button.tsx`, has no such field — it hardcodes
`data-testid="ds-button"` internally). FRONTEND-DEV must either query by role/text
(`getByRole('button', { name: 'Previous' })`) in tests, matching how REQ-272's own
`Button` tests already work, or wrap each `Button` in a `data-testid`-bearing `<span>`
the way `FilterBar` wraps its own "Clear filters" `Button` (§7.7's `FilterBar.tsx`,
`data-testid="filter-bar-clear"` on the wrapping `<span>`) — this design recommends
the same wrapping pattern for consistency: `<span data-testid="pagination-prev"><Button ...>Previous</Button></span>`.
Either is a one-line implementation choice; not spec-bearing.

### 3.6 Page-size selector option text

`{size} / page` (e.g. `25 / page`) — matches `AuditLogPage.tsx`'s existing literal
option text exactly (`<option value={25}>25 / page</option>`), so a later migration
of that page onto `PaginationControls` (out of this requirement's scope) changes no
visible copy.

---

## 4. Accessibility (FNFR-03 / WCAG 2.1 AA)

- Previous/Next are real `<button>` elements (via `Button`), reachable by `Tab`,
  activatable by `Enter`/`Space` — native semantics, no custom keydown handling
  needed.
- Disabled state uses the native `disabled` HTML attribute (inherited from `Button`,
  §Button.tsx line `disabled={isDisabled}`), which both removes the element from the
  tab order in the disabled state and is exposed to assistive technology via the
  accessibility tree's disabled/state property — not conveyed by opacity/color alone
  (`Button` does dim disabled buttons visually too, but that is additive, not the
  sole signal).
- Accessible name for each button comes from its visible text content ("Previous",
  "Next") — no icon-only button with a missing accessible name.
- The page-size `<select>` carries `aria-label="Items per page"` since it has no
  adjacent visible `<label>` element in this design (matches the compact toolbar
  layout of the real `AuditLogPage.tsx` selector, which also has no visible label
  today) — the `aria-label` is a new addition this design makes to close that gap
  rather than carry it forward, since AC4 explicitly requires an accessible name in
  the built component, not merely "keep parity with today's page."
- The summary text (`<span data-testid="pagination-summary">`) is plain static text,
  read normally by assistive technology; no `aria-live` region is added since a page
  change already moves focus/content elsewhere (the `DataTable` above it), and no
  acceptance criterion requires an announcement on page change.

---

## 5. Token-literal confirmation (per AC "zero literal-colour hits")

Re-verified directly against `web/src/styles/tokens.css` (not from memory), one
`grep -n -- "--<name>:" web/src/styles/tokens.css` per token cited in §3.4:

```
--space-1: 4px            (line 119)
--space-2: 8px             (line 120)
--space-3: 12px            (line 121)
--space-4: 16px            (line 122)
--border-default            (line 74, = var(--color-neutral-200))
--radius-sm: 4px            (line 129)
--text-secondary            (line 70, = var(--color-neutral-600))
--text-primary               (line 69, = var(--color-neutral-900))
--text-sm: 0.875rem          (line 113)
--surface-card                (line 62, = var(--color-neutral-0))
```

All ten present. **No token gap — nil result, explicitly.** `PaginationControls.tsx`
introduces zero literal-colour values; every `style={{...}}` value is either a
`var(--token)` reference or a non-color layout primitive (`flex`, `space-between`,
`center`, `pointer` via `Button`'s own existing cursor logic, numeric/px-free
CSS keywords) — none of which the `literal-colour` guard's regex
(`#[0-9a-fA-F]{3,8}\b|rgba?\(...\)|hsla?\(...\)`) matches.

---

## 6. Scope fence confirmation

- **No `web/src/pages/` file is touched or referenced by this design's build
  target.** `AuditLogPage.tsx` and `InstanceBoardPage.tsx` were read only to inform
  the API design (§1) — neither is edited by this requirement. Migrating either page
  onto `PaginationControls` is out of scope, same pattern as REQ-274 §5 for
  `DataTable`/`FilterBar`.
- **`web/tests/guards/forbidlist.ts` is not modified.** `PaginationControls.tsx`
  lives under `web/src/components/ui/`, which is not in `literal-colour`'s (or any
  other pattern's) `allowedPaths` — it is fully subject to the existing guard as-is;
  no exemption is needed or added.
- **Component + tests only.** `PaginationControls.tsx` and its co-located test file
  `web/src/components/ui/__tests__/PaginationControls.test.tsx` are the only new
  files this design targets.

---

## 7. Open questions (summary, not resolved here)

- **OQ-1** — the null-`totalItems` "Showing X-Y" formula uses `end = page * pageSize`
  (assumes a full page), which can overstate the true last-row ordinal on a partial
  final page, since no per-page row count is passed to `PaginationControls`. Neither
  real page today renders this text at all, so there is no existing behavior to
  contradict. If this proves visibly wrong in practice once a page adopts it, the
  fix is an additional optional prop (e.g. `itemsOnPage: number`) used only to refine
  `end` when supplied — a small additive change, not a breaking one. Flagged for
  CODE-DESIGN-VALIDATOR to confirm this approximation is acceptable for this
  requirement's acceptance criteria (which only requires the "Showing X-Y" format to
  appear, not a specific numeric precision guarantee for partial pages).
- **OQ-2** — `Button`'s `ButtonProps` has no `data-testid` field; §3.5 recommends
  wrapping each `Button` in a `data-testid`-bearing `<span>` (matching `FilterBar`'s
  own precedent) rather than modifying `Button.tsx` to accept a passthrough
  `data-testid`/`aria-label`. If CODE-DESIGN-VALIDATOR or FRONTEND-DEV prefers
  extending `Button.tsx` instead, that is a small, contained change outside this
  design's stated scope fence (component + tests only, implying no edits to sibling
  primitives) — flagged rather than silently done.
- **OQ-3** — the `hasNextPage` addition (§1.3, §2) is this design's correction to
  the requirement's originally recorded 5-prop API. It is added, not merely
  proposed, because without it the null-`totalItems` "next disabled on last page"
  behavior (an explicit acceptance criterion) is not implementable at all — this is
  judged a required correction, not an optional inference (unlike REQ-274's OQ-3 for
  `FilterBar`'s `onClear`/`activeCount`, which were usability additions with a valid
  children-only fallback). CODE-DESIGN-VALIDATOR should confirm this reasoning holds
  rather than treat `hasNextPage` as scope creep.

---

## 8. Acceptance-criteria mapping

| Acceptance criterion | Where addressed |
|---|---|
| `PaginationControls.tsx` exists, prop interface matches §7.8 exactly, spec vs. implementation quoted side by side | §2 (new §7.8 text), §3.1 (interface) — both authored together so they match by construction |
| Tests assert all four stated behaviors (summary "of Z", prev disabled p.1, next disabled last page, null-total "Showing X-Y") | §3.2 (formulas), §2 (spec text) — behaviors to test enumerated in §7.8's bullet list |
| Page size options 25/50/100; selector absent when `onPageSizeChange` omitted | §3.1 (`PAGE_SIZE_OPTIONS`), §3.2 (`showSizeSelector`), §3.6 (option text) |
| Keyboard operability + accessible names (FNFR-03/WCAG 2.1 AA), disabled state not styling-only | §4 |
| Zero literal-colour hits | §5 |
| Missing-token addendum or explicit nil | §5 — nil, all ten tokens pre-exist |
| §7.8 correction quoted with motivating page, or stated not needed | §1.3 and §2's "Correction note" — quoted, motivated by both `AuditLogPage.tsx` and `InstanceBoardPage.tsx` |
| No `web/src/pages/` file touched; `forbidlist.ts` untouched | §6 |
