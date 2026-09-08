# REQ-274 — DataTable, FilterBar design-system primitives (group 2 of 3)

**Run:** WF02-REQ274-20260908 · **Step:** 1 (CODE-DESIGNER) · **Requirement:** REQ-274

This is a design artefact. It contains no implementation code — no `.tsx` file is
written or edited by this requirement. It gives exact TypeScript prop interfaces,
token mappings, behavioral mechanisms, and the new `docs/frontend/design-system.md`
§7.7 spec-block text. Signatures, shapes, and documentation prose only — no function
bodies. Matches the format/conventions of the sibling design
`lib/letflow/design/req272-design-system-primitives-group1.md` (REQ-272, merged:
`web/src/components/ui/Button.tsx`, `StatusBadge.tsx`, `PageLayout.tsx` now exist).

**Pre-build re-verification (2026-09-08):** `ls web/src/components/ui/` returns
`Button.tsx, ConfirmDialog.tsx, ConfirmPromoteModal.tsx, ConflictResolver.tsx,
FetchError.tsx, JsonDiffView.tsx, PageLayout.tsx, PermissionDenied.tsx,
QueryStateBoundary.tsx, RateLimitBackpressure.tsx, SkeletonLayout.tsx,
StaleVersionError.tsx, StatusBadge.tsx, __tests__/`. `DataTable.tsx` and
`FilterBar.tsx` do not exist. The requirement's own "VERIFIED 2026-09-08" claim
holds.

**False-premise correction re-confirmed:** `grep -n "^### 7\.7\|^### 7\.8"
docs/frontend/design-system.md` returns zero hits. Section 7.7 (FilterBar) does not
exist yet — this design specifies its content (§2 below) for FRONTEND-DEV to insert
in the same change as `FilterBar.tsx`. Section 7.8 (PaginationControls) is explicitly
**out of scope** for this requirement — not designed, not added, per the
requirement's own text.

**Codebase conventions confirmed by reading `Button.tsx`, `StatusBadge.tsx`,
`PageLayout.tsx` (all `web/src/components/ui/`, REQ-272):**
- Function components, named export, `export interface <Name>Props`.
- Styling via inline `style={{...}}` referencing `var(--token-name)` only — no CSS
  modules, no styled-components. A scoped `<style>` tag with a `@keyframes` block is
  the established pattern for animation (Button's spinner, StatusBadge's pulse).
- `data-testid` on every structural/interactive element.
- Local component state via `useState` for purely visual/interaction state (Button's
  `hovered`) — no external state library pulled in for a single component's own UI
  state.
- Tests co-located at `web/src/components/ui/__tests__/<Name>.test.tsx`.
- No barrel `index.ts`; consumers import the file directly.

---

## 1. `DataTable.tsx`

### 1.1 Prop interface (matches `design-system.md` §7.2 exactly, per AC1)

```ts
export interface DataTableColumn<TRow> {
  id: string
  header: string
  accessor: (row: TRow) => React.ReactNode   // rendered cell content
  sortable?: boolean                          // default false; enables header click-to-sort
  sortValue?: (row: TRow) => string | number  // value compared when sorting; falls back
                                               // to accessor's return value if omitted and
                                               // sortable is true
}

export interface DataTableProps<TRow> {
  columns: DataTableColumn<TRow>[]   // "TanStack Table column definitions" per §7.2
  data: TRow[]
  isLoading?: boolean                 // default false; shows skeleton rows
  emptyMessage: string                // e.g. "No instances found"
  onRowClick?: (row: TRow) => void    // optional row click handler
}
```

**Design decision — `DataTableColumn` shape vs. TanStack's raw `ColumnDef`.** §7.2's
comment reads `columns={ColumnDef[]} // TanStack Table column definitions`, which
names TanStack Table's own `ColumnDef<TRow>` type as the literal prop type. This
design instead specifies a **thin project-owned `DataTableColumn<TRow>` shape** that
`DataTable` accepts and internally converts into TanStack's `ColumnDef<TRow>[]` when
constructing the table instance (via `useReactTable`). Reasons:

1. TanStack's raw `ColumnDef` type is a large union (`accessorKey` vs. `accessorFn`
   vs. `columns` for grouups, `cell` renderer signature bound to TanStack's own
   `CellContext`) — exposing it directly on `DataTableProps` means every call site
   must import and understand TanStack's API surface, not just this design system's.
   `Button`/`StatusBadge`/`PageLayout` (REQ-272) all expose plain, project-owned prop
   shapes; matching that convention keeps `DataTable`'s public API consistent with
   its siblings.
2. AC1 requires the prop **named** `columns` to exist and to drive the table — it
   does not require the prop's element type to be TanStack's own type verbatim. The
   internal mechanism (§1.4 below) still uses TanStack Table for the actual sort/row
   model logic, satisfying §7.2's "TanStack Table column definitions" comment as an
   implementation detail rather than a public-API literal.
3. **Flagged as OQ-1, not silently resolved:** if CODE-DESIGN-VALIDATOR judges
   `columns` must accept TanStack's raw `ColumnDef<TRow>[]` type directly to stay
   strictly literal to §7.2's comment, that is a one-line type change in this
   design's §1.1 (`columns: ColumnDef<TRow>[]` imported from `@tanstack/react-table`)
   with no change to the behavioral mechanism in §1.4. Both readings satisfy AC1's
   "props exactly match ... columns, data, isLoading, emptyMessage, onRowClick";
   they differ only in whether the array element type is project-owned or
   library-owned.

### 1.2 New dependency required

`@tanstack/react-table` (the headless table library; **not** `@tanstack/table-core`'s
full "React Table" UI-kit distribution some docs also call "TanStack Table" —
`@tanstack/react-table` is the headless-logic package with a thin React hook
wrapper, no rendered markup of its own) is **not currently a dependency** —
confirmed via `grep -n "tanstack" web/package.json`, which returns only
`@tanstack/react-query` and `@tanstack/react-query-devtools`. FRONTEND-DEV must add
`@tanstack/react-table` to `web/package.json` `dependencies` as part of this
requirement's implementation step. See §5 for why this does not conflict with the
"no component library" scope fence.

### 1.3 Token mapping

| Feature | Token(s) |
|---|---|
| Header row background | `var(--surface-card)` |
| Header row border (bottom, separates from body) | `1px solid var(--border-default)` |
| Header text | `var(--text-secondary)`, `var(--text-sm)`, `var(--font-medium)` |
| Header sort-active text | `var(--text-primary)` (swap from secondary when a column is the active sort key) |
| Body row border (between rows) | `1px solid var(--border-default)` |
| Body row hover background (only when `onRowClick` is provided) | `var(--color-neutral-50)` |
| Body cell text | `var(--text-primary)`, `var(--text-sm)` |
| Body cell padding | `var(--space-2) var(--space-4)` |
| Header cell padding | `var(--space-2) var(--space-4)` |
| Sort indicator glyph color | `var(--text-secondary)` (inactive), `var(--text-primary)` (active) |
| Empty-state icon color | `var(--color-neutral-400)` |
| Empty-state message text | `var(--text-secondary)`, `var(--text-base)` |
| Empty-state vertical padding | `var(--space-12)` |
| Row-click cursor (only when `onRowClick` set) | plain CSS value `pointer` — not a color token, no token needed |

No token gap: every value above already exists in `web/src/styles/tokens.css`
(confirmed by reading the file in full — `--surface-card`, `--border-default`,
`--text-secondary`, `--text-primary`, `--text-sm`, `--text-base`, `--font-medium`,
`--space-2`, `--space-4`, `--space-12`, `--color-neutral-50`, `--color-neutral-400`
are all present, several of them added by REQ-272's addendum). See §4 for the
explicit confirmation this criterion requires.

### 1.4 Behavioral mechanism — the four §7.2 behaviors

**(a) Skeleton loading — decision: reuse `SkeletonLayout`, concretely.**

`DataTable`, when `isLoading` is true, renders `SkeletonLayout` in place of the
`<tbody>` content, passing it a `columns` array derived from `DataTableColumn[]`
(one `{ widthPercent }` entry per column, evenly divided as `100 / columns.length`
unless a future column-width hint is added — none is needed now) and no explicit
`rowCount` (its own default of `5` already matches §7.2's "5 grey animated rows").
Call-site shape: `<SkeletonLayout columns={columns.map(() => ({ widthPercent: 100 /
columns.length }))} />`. Reason this is a reuse, not a second implementation:
`SkeletonLayout.tsx` (read in full) already renders exactly "5 grey animated rows"
using `--color-neutral-200`/`--color-neutral-100` alternating bars sized by
`widthPercent` — identical to §7.2's stated requirement, so building a second
skeleton would duplicate working code with no behavioral difference. `SkeletonLayout`
is rendered **inside** `DataTable`'s own table chrome (header row still renders
normally above it; see (c)) rather than replacing the whole component, so the sticky
header remains visible during a loading state — a reasonable inference the spec
doesn't contradict (§7.2 says skeleton rows appear "while `isLoading`", not that the
header itself is hidden).

**(b) Empty state.** When `data.length === 0` and `isLoading` is false: render a
centered block (`display: flex; flex-direction: column; align-items: center;
justify-content: center`) inside the table body area containing an icon (any
`lucide-react` icon already a project dependency — e.g. `Inbox`, unconstrained by
this design since §7.2 only says "centered icon + message", not which icon) and
`emptyMessage` as text. `data-testid="datatable-empty-state"`. This state and the
loading state are mutually exclusive and both take priority over rendering `data`
rows — `isLoading` checked first, then emptiness, per the natural precedence of
"still loading" over "loaded and empty."

**(c) Sticky header.** CSS approach: the `<thead>` (or header row wrapper, if not
using a semantic `<table>` — see OQ-2) gets `position: sticky; top: 0; z-index: 1;
background: var(--surface-card)` and the table's scroll container
(`data-testid="datatable-scroll-container"`) gets `overflow-y: auto` with a bounded
`max-height` — **OQ-2, flagged, not silently resolved:** this design does not fix a
specific `max-height` value (e.g. a viewport-relative value vs. a fixed px value)
since §7.2 says only "Sticky header on scroll" with no numeric constraint; the AC2
test only needs to assert the sticky CSS properties are present on the header
element (via computed/inline style), not that a specific max-height is chosen.
Background token is required on the sticky header specifically so header content
doesn't visually blend with scrolled-under body rows — `var(--surface-card)` matches
§1.3's header background already.

**(d) Sortable columns — asc/desc toggle, component-local state.**

State lives **inside `DataTable`**, not as a controlled prop, because §7.2's prop
list (verbatim: `columns, data, isLoading, emptyMessage, onRowClick`) has no
`sortState`/`onSortChange`-shaped prop — AC1 requires the props to *exactly* match
that list, so adding a controlled-sort prop pair would violate AC1. Shape:

```ts
// component-internal, not exported
interface SortState {
  columnId: string | null   // null = no active sort (insertion order)
  direction: 'asc' | 'desc'
}
```

- Initial state: `{ columnId: null, direction: 'asc' }` — no column sorted by
  default (§7.2 doesn't specify a default-sorted column).
- Click on a `sortable: true` column's header: if it is not the active `columnId`,
  set `columnId` to it and `direction` to `'asc'`. If it is already the active
  column, toggle `direction` between `'asc'`/`'desc'` (matches §7.2: "click header to
  toggle asc/desc"). A third click does **not** clear the sort back to unsorted —
  §7.2 only describes a two-state toggle, so a three-state (asc → desc → none) cycle
  is not introduced without spec support.
- Clicking a header where `sortable` is falsy/omitted is a no-op — no state change,
  no visual affordance (no sort icon rendered for non-sortable columns).
- Row ordering: derived at render time as `useMemo`-computed sorted copy of `data`
  when `sortState.columnId` is non-null, using the matching column's `sortValue`
  (falling back to its `accessor`'s return value, per §1.1) compared with a
  locale/numeric-aware comparator, reversed when `direction === 'desc'`. `data` prop
  itself is never mutated.
- Visual affordance: an up/down chevron (`lucide-react`'s `ChevronUp`/`ChevronDown`,
  already available) rendered next to a sortable column's header label, pointing per
  current `direction` only when that column is the active sort key; a neutral
  double-chevron or no icon at all for sortable-but-inactive columns (unconstrained
  choice, not spec-bearing).
- Internal mechanism note (§7.2's "TanStack Table column definitions" comment): the
  actual `useReactTable` call (from `@tanstack/react-table`, §1.2) is configured with
  `getSortedRowModel()` and a `state.sorting` array derived from the `SortState`
  above, translated at the TanStack boundary — TanStack's sorting model is the
  execution engine, `SortState` is `DataTable`'s own public-shape-adjacent internal
  state that keeps the exported prop surface exactly as small as §7.2/AC1 require.

### 1.5 Structural sketch (no bodies)

```
<div data-testid="data-table" style={{ ... }}>
  <div data-testid="datatable-scroll-container" style={{ overflowY: 'auto', maxHeight: ... }}>
    <table style={{ width: '100%', borderCollapse: 'collapse' }}>
      <thead data-testid="datatable-header" style={{ position: 'sticky', top: 0, ... }}>
        <tr>
          {columns.map(col => <th data-testid={`datatable-header-${col.id}`} onClick={...} />)}
        </tr>
      </thead>
      <tbody data-testid="datatable-body">
        {isLoading
          ? <SkeletonLayout columns={...} />              /* rendered as a row-spanning cell, not literal <tr> markup specified here */
          : data.length === 0
            ? <EmptyStateRow emptyMessage={emptyMessage} />
            : sortedRows.map(row => <tr data-testid="datatable-row" onClick={onRowClick ? () => onRowClick(row) : undefined}>{...cells...}</tr>)
        }
      </tbody>
    </table>
  </div>
</div>
```

This is a structural sketch (element nesting and prop wiring), not implementation
code — no attribute values, event-handler bodies, or JSX expressions beyond what's
needed to show which element gets which behavior are filled in.

**OQ-2 (restated for visibility):** whether the root is a semantic `<table>` (shown
above) or a CSS-grid-based div structure is FRONTEND-DEV's implementation choice —
both can satisfy "sticky header" and "TanStack Table" integration (TanStack Table is
markup-agnostic; it only supplies row/column/sort *models*, not DOM). A semantic
`<table>` is recommended for accessibility (native `<th>`/`<td>` semantics, screen
reader table navigation) and is assumed by the structural sketch above, but nothing
in §7.2 mandates it.

### 1.6 What the acceptance-criterion tests must assert (for TEST-DESIGNER, not built here)

Per AC2, each of the four behaviors needs its own test against rendered output:
- `isLoading=true` renders `SkeletonLayout`'s output (assert on `SkeletonLayout`'s
  own rendered row/column bar elements appearing inside `DataTable`, e.g. by count
  or by a `data-testid` `SkeletonLayout` itself exposes) — not merely that
  `isLoading` was passed through, but that skeleton content is actually visible.
- `data=[]`, `isLoading=false` renders `emptyMessage` text and the empty-state
  container (`queryByTestId('datatable-empty-state')` non-null).
- The header element (`datatable-header`) carries `position: sticky` (assert via
  computed style or the element's inline `style` object, matching REQ-272's own test
  convention of asserting rendered/computed style rather than source).
- Clicking a sortable column's header twice: first click asserts row order matches
  ascending `sortValue`/`accessor` order, second click on the same header asserts
  descending order — using a small fixture dataset with a known unsorted order so
  both directions are distinguishable from the original array order.

---

## 2. New `docs/frontend/design-system.md` §7.7 — FilterBar

**Insertion point:** immediately after the existing §7.6 (DynamicForm, ends at the
`---` before `## 8. Page Layout Template`), as a new `### 7.7 FilterBar` subsection
under the existing `## 7. Core UI Components` heading — matching the numbering the
requirement's title names, and preceding §8 exactly as §7.1–7.6 already do.

**Derivation basis:** §8's usage example is the only existing signal —

```tsx
<FilterBar>
  {/* filters */}
</FilterBar>
```

— which shows `FilterBar` used as a children-wrapping container with no props
supplied in the example. Everything beyond "it wraps children" is inference, stated
explicitly below rather than silently assumed.

**Spec-block text to insert (documentation prose/table, not application code —
matches the format of §7.1–7.6's existing spec blocks):**

> ### 7.7 FilterBar
>
> ```tsx
> <FilterBar
>   onClear={() => void}        // optional; shown only when at least one filter is active
>   activeCount={number}        // optional; badge count of currently-applied filters
> >
>   {/* filter controls — inputs, selects, StatusBadge-driven toggles, etc. */}
> </FilterBar>
> ```
>
> - Renders its `children` (individual filter controls — the page composing
>   `FilterBar` owns each control's own state and change handling) in a single
>   horizontal row, wrapping to multiple rows on narrow viewports.
> - An optional "Clear filters" action appears at the row's trailing edge when
>   `onClear` is supplied and `activeCount` is greater than zero; clicking it calls
>   `onClear`.
> - `FilterBar` itself holds no filter *values* — it is a layout/chrome component
>   only. Each filter control inside it (a text input, a `<select>`, a date range,
>   etc.) is the composing page's own responsibility, consistent with `PageLayout`
>   (§8) also being a pure layout wrapper around content it does not own the state
>   of.
> - Background/border matches the page's card surface (`--surface-card`,
>   `--border-default`) so it reads as a distinct toolbar strip above `DataTable`.

**Design rationale for the two inferred props (`onClear`, `activeCount`):** §8's
example passes no props to `FilterBar`, so a stricter reading could argue for zero
props (`children`-only). This design adds these two specifically because:
1. A filter bar with no way to clear filters is a known usability gap in every other
   part of this design system's stated principles (§1 "Clarity over cleverness" —
   operators need a fast reset, not to hunt for it per-control).
2. Both are optional, so `<FilterBar>{...}</FilterBar>` (§8's exact example, no
   other props) remains valid and unchanged.
3. **Flagged as OQ-3, not silently final:** if CODE-DESIGN-VALIDATOR judges this is
   inventing product behavior beyond what a "design-system primitive" doc should
   assert, the safe fallback is `children`-only (`FilterBarProps { children:
   React.ReactNode }`) with `onClear`/`activeCount` removed from both §7.7 and
   §2.1 below — a small, contained change if overridden.

---

## 3. `FilterBar.tsx`

### 3.1 Prop interface (matches the §7.7 spec just designed in §2)

```ts
export interface FilterBarProps {
  children: React.ReactNode
  onClear?: () => void        // optional; renders a "Clear filters" action when provided
  activeCount?: number        // optional; default 0 — number of currently-applied filters
}
```

### 3.2 Token mapping

| Feature | Token(s) |
|---|---|
| Bar background | `var(--surface-card)` |
| Bar border | `1px solid var(--border-default)` |
| Bar border radius | `var(--radius-sm)` |
| Bar padding | `var(--space-3) var(--space-4)` |
| Inter-control gap | `var(--space-3)` |
| "Clear filters" action text | `var(--interactive-primary)` (rendered as a `Button variant="ghost"` reuse — see below — or equivalent text-link styling) |
| Active-count badge | reuse `StatusBadge`-style pill: `var(--color-neutral-200)` background, `var(--text-secondary)` text, `var(--radius-full)` — not a new `StatusBadge` *domain*, just the same visual pattern (a small numeric pill), since `StatusBadge`'s own domains (5.1–5.3) don't have a "filter count" status vocabulary and inventing one would be out of scope here |

No token gap: every value above already exists in `tokens.css`.

### 3.3 Structural / behavioral sketch (no bodies)

- Root: `<div data-testid="filter-bar" style={{ display: 'flex', flexWrap: 'wrap',
  alignItems: 'center', gap: 'var(--space-3)', ... }}>`.
- `children` rendered directly, unwrapped (`FilterBar` does not clone or inspect
  its children — it is a pure layout wrapper, per §2's rationale).
- Trailing "Clear filters" control: rendered conditionally
  (`onClear && (activeCount ?? 0) > 0`) as `data-testid="filter-bar-clear"`,
  reusing `Button` (`variant="ghost"`, `size="sm"`) from REQ-272 rather than a new
  bespoke element — consistent with this design system's own "primitives compose"
  intent (`PageLayout`'s `actions` slot already accepts a `Button`; nothing prevents
  `FilterBar` from importing and rendering one directly).
- Active-count badge: rendered next to the clear action when `activeCount` is
  greater than zero, as `data-testid="filter-bar-count"`, a small pill showing the
  number.

### 3.4 What the acceptance-criterion tests must assert (for TEST-DESIGNER, not built here)

- `children` render inside `FilterBar` unmodified.
- With `onClear` provided and `activeCount={2}`: the clear action is present, and
  clicking it invokes `onClear`.
- With `onClear` omitted (or `activeCount={0}`): the clear action is absent
  (`queryByTestId('filter-bar-clear')` is null).

---

## 4. Token-literal confirmation (per AC "zero literal-colour hits", carried from REQ-272's convention)

**No new tokens need to be added to `tokens.css` or `design-system.md` §2 for either
component.** Every token referenced in §1.3 and §3.2 above (`--surface-card`,
`--border-default`, `--text-secondary`, `--text-primary`, `--text-sm`, `--text-base`,
`--font-medium`, `--space-2`, `--space-3`, `--space-4`, `--space-12`,
`--color-neutral-50`, `--color-neutral-200`, `--color-neutral-400`, `--radius-sm`,
`--radius-full`, `--interactive-primary`) already exists in
`web/src/styles/tokens.css` as read in full for this design — including the
`--space-*`/`--text-*`/`--font-medium`/`--radius-*` family REQ-272 already ported in
(lines 111–130 of the current file). Non-color values used above (padding
magnitudes already expressed via `--space-*`, which are themselves the only
sizing tokens this design needs) require no new token family. FRONTEND-DEV must
still run the literal-color grep from the acceptance criteria after building; this
section states the design's intent, not a post-build confirmation this design step
cannot perform.

---

## 5. Scope fence confirmation

- **No `web/src/pages/` file is touched or referenced by this design.** `DataTable`
  and `FilterBar` are built and tested only under `web/src/components/ui/` and
  `web/src/components/ui/__tests__/`. Migrating any existing page's hand-rolled
  table onto `DataTable` is explicitly REQ-276..278's scope, not this one's.
- **No full component library is adopted.** `@tanstack/react-table` (§1.2) is a
  **headless** logic library — it ships no rendered markup, no CSS, and no styled
  components; it supplies row/column/sort *models* that `DataTable` itself renders
  using this project's own tokens, exactly the same relationship `react-hook-form`
  (already a dependency) has to this project's own form markup. This satisfies the
  requirement's own framing ("TanStack Table for logic/sorting is fine ... if it's a
  headless table library, not a full component library").
- **Record `docs/migration/decisions/0020-frontend-architecture.md` could not be
  read to verify D2's exact wording — flagged as OQ-4, a process gap, not a design
  gap.** `grep -rln "0020-frontend-architecture" docs/` finds only requirement-text
  references to that filename (in `docs/requirements.yaml` and a status volume);
  `git log --all` for that path and `ls docs/migration/decisions/` (which runs
  0001–0019, no 0020) both confirm the file itself does not exist anywhere in this
  repository's history. This design proceeds on REQ-274's own requirement text,
  which already states D2's substance directly ("DO NOT adopt a component library —
  record 0020 D2 rejects that") — a self-contained instruction this design follows —
  but the missing decision file itself is a real gap: nothing can independently
  verify D2's full wording (e.g. whether it names TanStack Table specifically, or
  states the headless/full-library distinction this design relies on in §5). Per
  core-directives.md's "Never resolve a conflict silently," this is reported here for
  ORCH to route as a filed finding rather than silently trusted or silently ignored.

---

## 6. Open questions (summary, not resolved here)

- **OQ-1** — whether `DataTableProps['columns']` should be `DataTableColumn<TRow>[]`
  (this design's choice, project-owned shape) or TanStack's raw `ColumnDef<TRow>[]`
  (strictly literal to §7.2's comment). Both satisfy AC1's named-prop requirement;
  differ only in the array element's type. Flagged for CODE-DESIGN-VALIDATOR.
- **OQ-2** — sticky-header `max-height` value and `<table>` vs. grid-based markup
  are both implementation choices with no spec-mandated value; either satisfies
  §7.2's "sticky header on scroll."
- **OQ-3** — `FilterBar`'s `onClear`/`activeCount` props are this design's inference
  beyond §8's bare `<FilterBar>{children}</FilterBar>` example. Fallback if
  overridden: `children`-only prop interface, §7.7 spec text trimmed to match.
- **OQ-4** — `docs/migration/decisions/0020-frontend-architecture.md` does not exist
  in this repository despite being referenced by filename in `docs/requirements.yaml`
  (REQ-274's own text and REQ-272's sibling entry both cite it). This design relied
  on REQ-274's requirement text's own paraphrase of D2 rather than the primary
  record, which could not be located. Not a blocker for this design (the paraphrase
  is self-contained and unambiguous), but a process gap worth ORCH's attention.

---

## 7. Acceptance-criteria mapping

| Acceptance criterion | Where addressed |
|---|---|
| `DataTable.tsx` props exactly match §7.2's API (columns, data, isLoading, emptyMessage, onRowClick) | §1.1 (with OQ-1 on the `columns` element type) |
| Each of §7.2's four behaviors has its own rendered-output test | §1.4 (mechanism), §1.6 (what the test must assert) |
| SkeletonLayout reuse decision stated explicitly, with call site or concrete reason | §1.4(a) — reused, call site shown |
| FilterBar's API recorded in `design-system.md` before/with its implementation | §2 (full §7.7 text to insert) |
| No color literals / new-token-or-explicit-nil statement | §4 |
| No `web/src/pages/` file touched | §5 |
| No component library adopted (headless table library only) | §5 |
