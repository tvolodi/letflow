# BPM Platform — Frontend Design System

**Version:** 0.1 · 2026-05-20  
**Agent ID:** `FRONTEND-DEV`  
**Audience:** Frontend Developer agent

---

## 1. Design Principles

1. **Clarity over cleverness** — operators under pressure need scannable information, not clever UI patterns.
2. **Status is always visible** — process status, task status, and instance state must be immediately identifiable without reading text.
3. **Destructive actions require confirmation** — cancel, delete, discard, revoke must never fire on a single click.
4. **Density with breathing room** — data tables are dense; cards have generous padding.

---

## 2. Color Tokens

**Not yet implemented, but now decided (`REQ-120`, `lib/letflow/design/req120-design-token-source.md`).**
This section's palette IS the chosen source of truth — `REQ-120` picked it over
`design-tokens/letflow.tokens.json` (superseded, smaller and internally
inconsistent with this palette) and over inline hex literals (rejected as "no design
system at all"). As migrated into Letflow, `web/src/styles/tokens.css` does not yet
exist — there is no `.css` file under `web/src/` at all — and components use inline
`style={{...}}` objects with literal hex values instead of the custom properties
described below. Building the file and migrating components to it is a follow-on
requirement `REQ-120` sized but did not implement (see the design artefact above);
until that lands, treat the palette below as the specification target, not as a
description of the code as it stands. See also `web/README.md`'s "Known drift"
section.

All colors are defined as CSS custom properties in `web/src/styles/tokens.css`. Never use raw hex/rgb values outside this file.

### 2.1 Base palette

```css
:root {
  /* Neutrals */
  --color-neutral-0:   #ffffff;
  --color-neutral-50:  #f8f9fa;
  --color-neutral-100: #f1f3f5;
  --color-neutral-200: #e9ecef;
  --color-neutral-300: #dee2e6;
  --color-neutral-400: #ced4da;
  --color-neutral-500: #adb5bd;
  --color-neutral-600: #6c757d;
  --color-neutral-700: #495057;
  --color-neutral-800: #343a40;
  --color-neutral-900: #212529;

  /* Brand */
  --color-brand-400: #4dabf7;
  --color-brand-500: #339af0;
  --color-brand-600: #228be6;
  --color-brand-700: #1971c2;

  /* Semantic */
  --color-success-light: #d3f9d8;
  --color-success:       #40c057;
  --color-success-dark:  #2f9e44;

  /* Success-state border addition (REQ-276 addendum, mirrors the
     REQ-144 --color-error-border / --color-warning-border pattern —
     no border accent existed yet for success banners) */
  --color-success-border: #86efac;  /* green-300; border accent for success alert blocks */

  --color-warning-light: #fff3bf;
  --color-warning:       #fcc419;
  --color-warning-dark:  #e67700;

  /* Warning-state additions (REQ-144 addendum) */
  --color-warning-tint:   #fffbeb;   /* amber-50; barely-amber white — warning banner bg */
  --color-warning-border: #fde68a;   /* amber-200; border accent for warning boxes */
  --color-warning-text:   #92400e;   /* amber-800; WCAG AA text on warning backgrounds */

  /* Warning-banner addition (REQ-145 addendum) */
  --color-warning-banner: #fef08a;   /* yellow-200; sticky env/test warning banners */

  --color-error-light:   #ffe3e3;
  --color-error:         #fa5252;
  --color-error-dark:    #c92a2a;

  /* Error-state border addition (REQ-144 addendum) */
  --color-error-border: #fecaca;     /* red-200; border accent for error alert blocks */

  /* Error-border-strong addition (REQ-145 addendum) */
  --color-error-border-strong: #fca5a5;  /* red-300; full-page error boundary card border */

  /* Tints and failure state (REQ-143 addendum) */
  --color-success-tint:  #f8fff8;   /* barely-green white; lighter than --color-success-light */
  --color-error-tint:    #fff5f5;   /* barely-red white; lighter than --color-error-light */
  --color-failure:       #a61e4d;   /* deep pink-crimson; "failed" system-error state — distinct from rejected (--color-error-dark) */

  --color-info-light:    #dbe4ff;
  --color-info:          #4c6ef5;
  --color-info-dark:     #3b5bdb;

  /* Info-state additions (REQ-145 addendum) */
  --color-info-tint: #eff6ff;   /* blue-50; near-white info banner background */
  --color-info-text: #1e3a8a;   /* blue-800; authoritative heading text on info backgrounds */
}
```

### 2.2 Semantic surface tokens

```css
:root {
  --surface-page:       var(--color-neutral-50);
  --surface-card:       var(--color-neutral-0);
  --surface-sidebar:    #1e293b;              /* slate-800; AppShell sidebar (REQ-145 correction) */
  --surface-overlay:    rgba(0, 0, 0, 0.5);

  /* Sidebar accent (REQ-145 addendum) */
  --color-sidebar-active: #334155;            /* slate-700; active-nav highlight and dividers on sidebar */

  --text-primary:       var(--color-neutral-900);
  --text-secondary:     var(--color-neutral-600);
  --text-disabled:      var(--color-neutral-400);
  --text-inverse:       var(--color-neutral-0);

  --border-default:     var(--color-neutral-200);
  --border-focus:       var(--color-brand-500);
  --border-error:       var(--color-error);

  --interactive-primary:        var(--color-brand-600);
  --interactive-primary-hover:  var(--color-brand-700);
  --interactive-danger:         var(--color-error);
  --interactive-danger-hover:   var(--color-error-dark);
}
```

### 2.3 Avatar accent palette (REQ-143 addendum)

Reserved for actor avatar backgrounds in `ActorAvatar.tsx`. **Not for use in semantic UI elements.**

```css
:root {
  /* Avatar accent palette — actor visual differentiation only */
  --color-avatar-blue:   #2563eb;
  --color-avatar-teal:   #0d9488;
  --color-avatar-violet: #7c3aed;
  --color-avatar-orange: #ea580c;
  --color-avatar-cyan:   #0891b2;
  --color-avatar-green:  #16a34a;
  --color-avatar-purple: #9333ea;
  --color-avatar-sky:    #0284c7;
  --color-avatar-rust:   #c2410c;
  --color-avatar-indigo: #4f46e5;
}
```

---

## 3. Typography

```css
:root {
  --font-sans: 'Inter', system-ui, -apple-system, sans-serif;
  --font-mono: 'JetBrains Mono', 'Fira Code', monospace;

  /* Scale */
  --text-xs:   0.75rem;   /* 12px */
  --text-sm:   0.875rem;  /* 14px */
  --text-base: 1rem;      /* 16px */
  --text-lg:   1.125rem;  /* 18px */
  --text-xl:   1.25rem;   /* 20px */
  --text-2xl:  1.5rem;    /* 24px */
  --text-3xl:  1.875rem;  /* 30px */

  /* Weights */
  --font-normal:   400;
  --font-medium:   500;
  --font-semibold: 600;
  --font-bold:     700;
}
```

---

## 4. Spacing & Layout

Use an 8 px base grid. Spacing values: `4, 8, 12, 16, 24, 32, 48, 64` px.

```css
:root {
  --space-1:  4px;
  --space-2:  8px;
  --space-3:  12px;
  --space-4:  16px;
  --space-6:  24px;
  --space-8:  32px;
  --space-12: 48px;
  --space-16: 64px;

  --radius-sm: 4px;
  --radius-md: 8px;
  --radius-lg: 12px;
  --radius-full: 9999px;

  --sidebar-width:     240px;
  --content-max-width: 1280px;
  --panel-width:       400px;
}
```

---

## 5. Status Badge Specifications

`<StatusBadge>` is used across all entity types. Each status has a fixed visual identity.

### 5.1 Definition status

| Status | Background | Text | Dot color |
|---|---|---|---|
| `DRAFT` | `--color-neutral-100` | `--text-secondary` | `--color-neutral-500` |
| `ACTIVE` | `--color-success-light` | `--color-success-dark` | `--color-success` |
| `DEPRECATED` | `--color-warning-light` | `--color-warning-dark` | `--color-warning` |
| `ARCHIVED` | `--color-neutral-200` | `--color-neutral-600` | `--color-neutral-400` |

### 5.2 Instance status

| Status | Background | Text | Dot |
|---|---|---|---|
| `ACTIVE` | `--color-info-light` | `--color-info-dark` | `--color-info` (animated pulse) |
| `COMPLETED` | `--color-success-light` | `--color-success-dark` | `--color-success` |
| `CANCELLED` | `--color-neutral-200` | `--color-neutral-600` | `--color-neutral-400` |
| `ERROR` | `--color-error-light` | `--color-error-dark` | `--color-error` |

### 5.3 Task status

| Status | Background | Text |
|---|---|---|
| `PENDING` | `--color-info-light` | `--color-info-dark` |
| `COMPLETED` | `--color-success-light` | `--color-success-dark` |
| `CANCELLED` | `--color-neutral-200` | `--color-neutral-600` |

### 5.4 Badge component API

```tsx
<StatusBadge
  status="ACTIVE"          // string key from above tables
  domain="instance"        // "definition" | "instance" | "task"
  size="sm"                // "sm" | "md" (default md)
/>
```

`domain` is limited to the three values with a defined status vocabulary above
(5.1-5.3). `timer` and `dlq` are not yet covered by this spec — no status
vocabulary or token mapping is defined for either domain. Add them back to
this list, alongside their own 5.1-5.3-equivalent status table, once a
timer- or DLQ-facing page actually needs them (ISS-0545).

---

## 6. Process Canvas Node Styles

### 6.1 Node dimensions

| Node type | Width | Min height |
|---|---|---|
| `START` | 48 px (circle) | 48 px |
| `END` | 48 px (circle, double border) | 48 px |
| `HUMAN_TASK` | 180 px | 72 px |
| `EXCLUSIVE_GATEWAY` | 56 px (diamond) | 56 px |
| `PARALLEL_GATEWAY` | 56 px (diamond with +) | 56 px |
| `SERVICE_TASK` | 180 px | 72 px |
| `TIMER` | 56 px (circle with clock icon) | 56 px |
| `SUB_PROCESS` | 200 px | 80 px (dashed border) |

### 6.2 Node states (runtime visualization)

| State | Visual treatment |
|---|---|
| Default | White card, neutral border |
| Active (has token) | Blue border (`--color-brand-500`), animated pulse ring |
| Completed | Green background tint (`--color-success-light`) |
| Error | Red border (`--color-error`), error icon in corner |
| Read-only | Cursor: `default`; no hover effects |

### 6.3 Edge styles

| Edge type | Style |
|---|---|
| Default transition | Solid line, arrow marker, neutral color |
| CEL condition edge | Solid line with a label bubble showing expression (truncated to 30 chars) |
| Default edge (gateway) | Dashed line with `D` marker bubble |
| Cancelled branch | Grey, reduced opacity |

---

## 7. Core UI Components

### 7.1 Button

```tsx
<Button
  variant="primary" | "secondary" | "danger" | "ghost"
  size="sm" | "md" | "lg"
  loading={boolean}           // shows spinner, disables click
  disabled={boolean}
  onClick={handler}
>
  Label
</Button>
```

- `primary`: filled brand color
- `secondary`: outlined, brand color text
- `danger`: filled error color — only for destructive actions
- `ghost`: no border, text only — for low-prominence actions

### 7.2 DataTable

```tsx
<DataTable
  columns={ColumnDef[]}       // TanStack Table column definitions
  data={rows}
  isLoading={boolean}         // shows skeleton rows
  emptyMessage="No instances found"
  onRowClick={(row) => void}  // optional row click handler
/>
```

- Skeleton loading: 5 grey animated rows shown while `isLoading`
- Empty state: centered icon + message
- Sticky header on scroll
- Sortable columns: click header to toggle asc/desc

### 7.3 Dialog (confirmation pattern)

```tsx
<ConfirmDialog
  open={boolean}
  onConfirm={() => void}
  onCancel={() => void}
  title="Cancel Instance?"
  body="All open tasks will be cancelled. This action cannot be undone."
  confirmText="Cancel Instance"
  cancelText="Cancel"          // defaults to "Cancel"
  confirmVariant="danger"
  isLoading={boolean}          // defaults to false; disables both buttons while true
/>
```

This spec previously documented `description`/`confirmLabel` in place of the real,
already-shipped `body`/`confirmText` props (ISS-0547) -- corrected here to match
`web/src/components/ui/ConfirmDialog.tsx` rather than renaming the shipped
component's props and its call site. `cancelText` and `isLoading` were undocumented
additive props on the real component; both are now recorded above.

All destructive actions (cancel instance, delete definition, revoke token, discard DLQ item) MUST use `ConfirmDialog`, not a plain `window.confirm`.

### 7.4 Toast

```tsx
import { useToast } from '../hooks/useToast'

const toast = useToast()
toast.success('Task completed successfully')
toast.error('Failed to cancel instance', { description: error.detail })
toast.warning('Instance is in an error state')
```

- Toasts appear top-right, stack vertically
- Auto-dismiss: success/info after 4 s; error after 8 s (with manual close)
- Max 4 toasts visible simultaneously (older ones drop off)
- Use `aria-live="polite"` for success; `aria-live="assertive"` for errors

### 7.5 JsonEditor

A controlled textarea with JSON syntax validation:

```tsx
<JsonEditor
  value={jsonString}
  onChange={(value, isValid) => void}
  label="Initial Variables"
  height={200}
  readOnly={false}
/>
```

- Shows red border + error message for invalid JSON
- Pretty-prints on blur
- Used for: initial variables, output variables, event payload inspection

### 7.6 DynamicForm

Renders a form from a JSON Schema object:

```tsx
<DynamicForm
  schema={jsonSchema}         // JSON Schema object from task node's form_schema
  onSubmit={(values) => void}
  submitLabel="Complete Task"
  isSubmitting={boolean}
/>
```

**Supported JSON Schema types → input mapping:**

| JSON Schema type/format | Rendered as |
|---|---|
| `string` | `<input type="text">` |
| `string, format: date` | `<input type="date">` |
| `string, format: date-time` | `<input type="datetime-local">` |
| `string, enum: [...]` | `<select>` |
| `number` / `integer` | `<input type="number">` |
| `boolean` | `<input type="checkbox">` |
| `string, maxLength > 200` | `<textarea>` |

### 7.7 FilterBar

```tsx
<FilterBar
  onClear={() => void}        // optional; shown only when at least one filter is active
  activeCount={number}        // optional; badge count of currently-applied filters
>
  {/* filter controls — inputs, selects, StatusBadge-driven toggles, etc. */}
</FilterBar>
```

- Renders its `children` (individual filter controls — the page composing
  `FilterBar` owns each control's own state and change handling) in a single
  horizontal row, wrapping to multiple rows on narrow viewports.
- An optional "Clear filters" action appears at the row's trailing edge when
  `onClear` is supplied and `activeCount` is greater than zero; clicking it calls
  `onClear`.
- `FilterBar` itself holds no filter *values* — it is a layout/chrome component
  only. Each filter control inside it (a text input, a `<select>`, a date range,
  etc.) is the composing page's own responsibility, consistent with `PageLayout`
  (§8) also being a pure layout wrapper around content it does not own the state
  of.
- Background/border matches the page's card surface (`--surface-card`,
  `--border-default`) so it reads as a distinct toolbar strip above `DataTable`.

### 7.8 PaginationControls

```tsx
<PaginationControls
  page={number}                      // 1-indexed current page
  pageSize={number}                  // current page size; one of 25, 50, 100
  totalItems={number | null}         // null when the total row count is unknown
                                      // (cursor-based pagination)
  onPageChange={(page: number) => void}
  onPageSizeChange={(pageSize: number) => void}  // optional; omit to hide the
                                                  // page-size selector
  hasNextPage={boolean}              // optional; only consulted when totalItems
                                      // is null — whether another page exists
                                      // beyond the current one (e.g. derived from
                                      // an API response's next_cursor being
                                      // non-null). Ignored when totalItems is a
                                      // number — next-disabled is computed from
                                      // page * pageSize >= totalItems instead.
                                      // Treated as false (Next disabled) when
                                      // omitted and totalItems is null.
/>
```

- Summary text, `totalItems` known: `Showing {start}-{end} of {totalItems}`, where
  `start = (page - 1) * pageSize + 1` and `end = min(page * pageSize, totalItems)`.
- Summary text, `totalItems` null (cursor pagination): `Showing {start}-{end}`
  (no "of Z" suffix), where `start = (page - 1) * pageSize + 1` and
  `end = page * pageSize`. This assumes a full page except where `hasNextPage` says
  otherwise; a partial last page may show an `end` slightly higher than the actual
  last row's ordinal — accepted because no per-page row count is available to this
  component.
- "Previous" is disabled when `page <= 1`.
- "Next" is disabled when: `totalItems` is a number and `page * pageSize >=
  totalItems`; or `totalItems` is `null` and `hasNextPage` is not `true`.
- Page-size selector (`<select>`, options `25`, `50`, `100`) renders only when
  `onPageSizeChange` is supplied; entirely absent otherwise.
- "Previous"/"Next" are real, focusable `<button>` elements (via this design
  system's own `Button`) with visible text labels ("Previous"/"Next") — their
  accessible name comes from that text content, and their disabled state is the
  native `disabled` HTML attribute (not a styling-only affordance), satisfying
  FNFR-03 (WCAG 2.1 AA).

**Correction note (REQ-287):** this section did not exist before REQ-287 — §8's
usage example referenced `<PaginationControls ... />` with no spec block behind it,
the same situation REQ-274 left explicitly out of scope. A sixth prop, `hasNextPage`,
was added beyond the requirement's originally recorded 5-prop list (`page`,
`pageSize`, `totalItems`, `onPageChange`, `onPageSizeChange`) because that recorded
API gave `PaginationControls` no way to compute the Next button's disabled state when
`totalItems` is `null`. Confirmed against the two real hand-rolled pagination UIs in
`web/src/pages/`: `AuditLogPage.tsx`'s `!nextCursor` and `InstanceBoardPage.tsx`'s
`!instancesQuery.data.next_cursor` both already compute and use exactly this boolean
today (gating their own "Next"/"Next page" buttons), so `hasNextPage` lets
`PaginationControls` consume that existing signal directly. See
`lib/letflow/design/req287-design-system-primitives-group4.md` §1 for the full
comparison.

---

## 8. Page Layout Template

```tsx
function SomePage() {
  return (
    <PageLayout
      title="Process Instances"
      actions={<Button variant="primary">Start Instance</Button>}
    >
      <FilterBar>
        {/* filters */}
      </FilterBar>
      <DataTable ... />
      <PaginationControls ... />
    </PageLayout>
  )
}
```

`PageLayout` provides:
- Page title (h1) + actions slot (top-right)
- Content area with `--content-max-width` constraint
- Consistent vertical spacing between sections

---

## 9. Responsive Breakpoints

| Name | Min width | Notes |
|---|---|---|
| `mobile` | 375 px | Task Inbox must work here |
| `tablet` | 768 px | Sidebar collapses to hamburger |
| `desktop` | 1024 px | Minimum for all other views (FNFR-07) |
| `wide` | 1280 px | Canvas editor benefits from this |

On `mobile`, the sidebar is hidden behind a hamburger menu (full-screen drawer). The Process Designer canvas is not available on mobile (shown as a notice with a link to open on desktop).
