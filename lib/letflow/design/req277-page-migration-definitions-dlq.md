# REQ-277 — Design: migrate `web/src/pages/definitions/` and `web/src/pages/dlq/` onto design-system primitives

**Requirement:** REQ-277 (stage S8), 2 of 3 sibling page-migration requirements implementing
decision `0020-frontend-architecture.md` D2/D2a. Independent of REQ-276/278.

**Scope:** `web/src/pages/definitions/` and `web/src/pages/dlq/` only. No implementation code
in this file — signatures, prop mappings, and disposition decisions only, per
`WF-02_requirement_implementation.md` Step 1 and `.claude/agents/code-designer.md`.

---

## 0. Files touched by this design

Design-time edits made now (small, addendum-only, precedented by REQ-287's own design step
authoring a missing spec section — see §6 for the one new token):

- `web/src/styles/tokens.css` — added `--shadow-modal-compact` (one new token; every other
  literal color in scope normalizes onto an *existing* token — see §6).
- `docs/frontend/design-system.md` — mirrored the same token with a REQ-277-addendum note.

Everything else below is FRONTEND-DEV's to implement in Step 2b:

- `web/src/pages/definitions/DefinitionListPage.tsx`
- `web/src/pages/definitions/DefinitionEditorPage.tsx`
- `web/src/pages/dlq/DlqPage.tsx`
- `web/src/pages/dlq/WebhooksPage.tsx`
- `web/src/pages/dlq/DlqItemsPage.tsx` — **no change**. It is a 5-line re-export
  (`export function DlqItemsPage() { return <DlqPage /> }`), 0 literal-colour hits. Confirmed
  by direct read; not part of the "2 of 3" files the requirement's measured-scope note refers
  to for either directory.
- `web/src/pages/definitions/__tests__/DefinitionEditorPage.promote.test.tsx` — 0 literal-colour
  hits, **no assertion changes needed** (see §8).

**Per this requirement's own acceptance criteria, no file outside `definitions/`, `dlq/` may be
modified except `tokens.css`/`design-system.md` in the addendum case.** §3 below flags two
places where the literal migration in scope collides with that constraint (a StatusBadge domain
gap, and ToastContainer never being mounted anywhere in the app) — both are stated as open
questions for CODE-DESIGN-VALIDATOR/ORCH, not resolved unilaterally by editing a third file.

---

## 1. Re-verified measured scope

Ran the guard's own regex (from `web/tests/guards/forbidlist.ts`'s `literal-colour` pattern:
`/#[0-9a-fA-F]{3,8}\b|(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)|(?<![.a-zA-Z0-9_$])hsla?\([^)]+\)/g`)
directly against each file in both directories (`node -e` script, 2026-09-09):

| File | Hits |
|---|---|
| `definitions/DefinitionEditorPage.tsx` | 50 |
| `definitions/DefinitionListPage.tsx` | 55 |
| `definitions/__tests__/DefinitionEditorPage.promote.test.tsx` | 0 |
| `dlq/DlqItemsPage.tsx` | 0 |
| `dlq/DlqPage.tsx` | 62 |
| `dlq/WebhooksPage.tsx` | 34 |
| **Total** | **201** |

Matches the requirement's stated counts exactly: definitions/ 105 (50+55), dlq/ 96 (62+34),
201 combined. **No drift** — the 2026-09-08 measurement still holds.

---

## 2. Primitive prop APIs consulted (as they exist today, not as designed)

Read in full: `DataTable.tsx`, `Button.tsx`, `StatusBadge.tsx`, `PaginationControls.tsx`,
`Toast.tsx`/`useToast.ts`, `PageLayout.tsx`, `JsonDiffView.tsx`, `JsonEditor.tsx`, plus
`FilterBar.tsx` and `ConfirmDialog.tsx` (both directly relevant here even though not named in
the task's explicit read list — DlqPage's discard dialog and both list pages' filter rows map
onto them).

- `Button({ variant: 'primary'|'secondary'|'danger'|'ghost', size: 'sm'|'md'|'lg', loading?, disabled?, onClick?, children, 'data-testid'? })` — **no 5th "neutral solid" variant.** Every `#6b7280`/`#0f766e`-style solid-gray/teal button in scope becomes `secondary` (outlined, brand-blue) or `ghost` (text-only) — see per-file tables.
- `DataTable<TRow>({ columns: {id, header, accessor, sortable?, sortValue?}[], data: TRow[], isLoading?, emptyMessage, onRowClick? })` — **no per-row style/className hook, no external-selection-highlight prop.** Two features in scope cannot be expressed: DlqPage's "selected row gets a tinted background" and WebhooksPage's "paused row gets a tinted background." Both are **decorative losses only** — `onRowClick` still drives the underlying behavior (row click still opens the detail panel; status is still visible via the StatusBadge cell). Documented per-file, not silently dropped.
- `StatusBadge({ status: string, domain: 'definition'|'instance'|'task'|'timer'|'dlq', size?: 'sm'|'md' })` — `dlq` domain exists in the type but has **no status table** (falls to a neutral `FALLBACK` for every status, per the component's own moduledoc, tracked as its pre-existing OQ-3 spec gap). **There is no `webhook` domain at all.** See §3, open question 1.
- `PaginationControls({ page: number (1-indexed), pageSize, totalItems: number|null, onPageChange, onPageSizeChange?, hasNextPage? })` — designed for exactly DlqPage's shape (cursor-based, `totalItems` unknown, `hasNextPage` derived from `next_cursor`). Requires wrapping DlqPage's `cursorStack`/`goNext`/`goPrev` state as a synthesized 1-indexed `page` — see §5.3.
- `useToast() -> { success(msg, opts?), error(msg, opts?), warning(msg, opts?) }`, rendered by a single `<ToastContainer/>` (module-level store via `useSyncExternalStore`, no provider needed). **`<ToastContainer/>` is not mounted anywhere in the app** (`grep` of `web/src` found zero call sites outside `Toast.tsx` itself and its own test) — mounting it requires editing `AppShell.tsx`/`main.tsx`, both outside this requirement's file-scope allowance, so **this design does not introduce any `useToast()` call site**. See §3, open question 2, for the resolution: every inline banner/error/success element in scope stays hand-rolled, tokenized, rather than migrated to a toast that would be a silent no-op today.
- `PageLayout({ title, actions?, children })` — pure title+actions+content wrapper, fits both list pages and both DLQ pages directly.
- `FilterBar({ children, onClear?, activeCount? })` — pure chrome; each filter control is the page's own responsibility, still needs `<input>`/`<select>` markup inside it (see §6 for their border/text token normalization).
- `JsonDiffView({ before: Record<string, unknown>|null|undefined, after: ... })` — renders a **before/after diff table**; every row is highlighted `--color-warning-light` whenever `before[k] !== after[k]`. Wrong shape for a single-object read-only dump (would highlight every field as "changed" against an empty `before`, which is misleading, not neutral). Not used anywhere in this scope — see §4.
- `JsonEditor({ value: string, onChange, label, height?, readOnly? })` — controlled textarea, JSON-validates on change, pretty-prints on blur, all tokens internal (moduledoc: "no hex/rgb/hsl literal appears in this file"). `readOnly=true` renders a labeled, bordered, monospace, non-interactive box — the correct shape for a single pretty-printed JSON dump. Used for all three JSON displays in scope — see §4.
- `ConfirmDialog({ open, title, body: string, confirmText?, cancelText?, confirmVariant?: 'primary'|'danger', onConfirm, onCancel, isLoading? })` — `body` is a **plain string**, no slot for a second, differently-styled paragraph. Matters for DlqPage's discard dialog — see §5.3.

---

## 3. Open questions (not silently resolved — flag for CODE-DESIGN-VALIDATOR/ORCH)

### OQ-1 — StatusBadge has no `webhook` domain, and `dlq` has no status table

`StatusBadgeDomain` is `'definition' | 'instance' | 'task' | 'timer' | 'dlq'`. Two problems in
this scope:

1. **DlqPage** (`pending`/`retrying`/`resolved`/`discarded`) uses the existing `dlq` domain,
   which is a valid domain value but has **no entries in `STATUS_TABLES`** — every status
   renders the same neutral `FALLBACK` badge. This is `StatusBadge`'s own pre-existing,
   already-tracked gap (OQ-3 in `lib/letflow/design/req272-design-system-primitives-group1.md`),
   not something REQ-277 introduces. Migrating still satisfies "status pill by StatusBadge"
   literally, but loses the current amber/blue/green/gray color coding — all four statuses
   become visually identical gray pills.
2. **WebhooksPage** (`ACTIVE`/`PAUSED`) has **no domain to use at all.** `'dlq'` is the least-
   wrong existing value (semantically closer to none of the five), but produces the same
   all-neutral outcome as (1).

**Why this isn't resolved here:** the fix (add a `webhook` domain and/or populate `dlq`'s status
table in `StatusBadge.tsx`) requires editing `web/src/components/ui/StatusBadge.tsx` — a file
outside `definitions/`, `dlq/`, `tokens.css`, `design-system.md`, which this requirement's own
acceptance criteria forbid touching. Extending `design-system.md`'s §5 spec table (which *is*
allowed) without also editing the component that reads it would leave the spec and the code
inconsistent, which is worse than the status quo.

**Recommendation:** proceed with `domain='dlq'` for both DlqPage and WebhooksPage (uniform,
spec-compliant, honestly degraded — no invented behavior), and report this gap to ORCH as a new,
separate follow-up issue (small: add `WEBHOOK_STATUSES` + rename/extend the domain union in
`StatusBadge.tsx`, plus a `design-system.md` §5.5 entry) rather than expanding REQ-277's own
file scope to fix it in place. This is the finding CODE-DESIGNER reports per
`core-directives.md`'s "No Issue Left Local-Only" — filed by ORCH, not by this design step.

### OQ-2 — `<ToastContainer/>` is mounted nowhere in the app

Confirmed by `grep -rn "ToastContainer" web/src`: the only matches are `Toast.tsx`'s own
definition and `Toast.test.tsx`. `useToast().success(...)` updates the module-level store, but
with no `<ToastContainer/>` rendered anywhere, nothing subscribes to it — the call is a silent
no-op.

**Why this isn't resolved by mounting it here:** the natural mount point is the app shell
(`web/src/components/layout/AppShell.tsx`) or `web/src/main.tsx`, both outside this
requirement's file-scope allowance (`no file outside web/src/pages/definitions/ and
web/src/pages/dlq/ is modified except web/src/styles/tokens.css and docs/frontend/design-system.md`
— a literal, enumerated two-file exception list; no design step has standing to invent a third
exception mid-design).

**Resolution (revised): this design does not migrate any inline banner/error/success element to
`useToast()`.** Every element in scope that was previously going to become a toast call
(`importError`/`createError` in `DefinitionListPage.tsx`; `saved`/`exportError`/`promoteMessage`/
`promoteError` in `DefinitionEditorPage.tsx`; `actionError` in `DlqPage.tsx`; `formError` in
`WebhooksPage.tsx`) **stays exactly where it is today, as a hand-rolled inline element** — only
its literal colors are normalized onto existing tokens (the same literal→token mapping every
other in-scope literal gets, per §6), with no primitive swap and no behavior change. This is
option (a) of the two choices ORCH offered on rework: not migrating these call sites to
`useToast()` at all, versus deferring them to a future requirement. Option (a) is chosen because
(1) it fully satisfies this requirement's own AC2 (`DataTable`/`Button`/`StatusBadge`/
`PaginationControls` counts) and AC1 (zero literal-colour hits) without needing `ToastContainer`
mounted anywhere — AC2's enumerated construct list does not include toast at all, only table/
button/badge/pagination; (2) it ships zero regression risk (nothing currently visible moves or
disappears); (3) it avoids the inline-vs-toast UX tradeoff this design's earlier draft was
already flagging as a caution for `createError`/`formError` (see §5.1/§5.4) — keeping them inline
sidesteps that tradeoff entirely rather than resolving it under time pressure. **Filed as a
follow-up issue** for ORCH: mount `<ToastContainer/>` once in `AppShell.tsx` (shared
infrastructure, not duplicated per requirement) as its own small, separately-reviewable change,
after which a later requirement can migrate these call sites to `useToast()` if desired — not
this one's job, and not decided unilaterally here, per `core-directives.md`'s "No Issue Left
Local-Only."

### OQ-3 — WebhooksPage's cyan "one-time secret" panel: normalize hue, or add new tokens?

Four literals (`#ecfeff` bg, `#a5f3fc` border, `#cffafe` code bg, `#155e75` text) plus one
button (`#0891b2`, exact match to the *avatar-reserved* `--color-avatar-cyan` — not reusable
per `design-system.md` §2.3's "Not for use in semantic UI elements") together render a cyan
"reveal this secret once" callout. No existing non-avatar token is cyan; the closest semantic
match is the existing `--color-info-*` family, which is blue-violet (`#dbe4ff`/`#4c6ef5`), not
cyan.

**Option A (recommended): normalize onto `--color-info-*`.** Bg → `var(--color-info-light)`,
border → `var(--color-info)`, code bg → `var(--color-info-tint)`, text →
`var(--color-info-text)`, button → `Button variant="primary"`. Zero new tokens; consistent with
how every other color in this file's scope was resolved (§6). Visual cost: the panel's hue shifts
from cyan to blue — noticeable but not a functional change (it is still a distinctly-colored
informational callout).

**Option B: add 4 new cyan tokens** (e.g. `--color-notice-light: #ecfeff`,
`--color-notice-border: #a5f3fc`, `--color-notice-tint: #cffafe`, `--color-notice-text: #155e75`)
preserving the current cyan hue exactly, via the same `tokens.css`/`design-system.md` addendum
mechanism already used for `--shadow-modal-compact` in this design.

Recommendation is Option A (simpler, no addendum growth for a single one-off panel), but this is
a visible design call, not a mechanical token lookup — flagging explicitly rather than deciding
silently. If CODE-DESIGN-VALIDATOR or FRONTEND-DEV prefers Option B, adding the 4 tokens is a
same-shape addendum to §6 below and does not change any other part of this design.

---

## 4. JSON display disposition — required, explicit, one line each

Three JSON displays exist across the two directories (confirmed by reading every file in full;
no fourth hand-rolled JSON renderer exists in scope):

| # | Location | Current markup | Disposition | Why |
|---|---|---|---|---|
| 1 | `DefinitionEditorPage.tsx:855-871` — "Raw Graph JSON (debug)" drawer, `data-testid="raw-json-textarea"` | Read-only `<textarea readOnly value={currentGraphJson} rows={8}>` | **`JsonEditor` with `readOnly={true}`** | Single-object pretty-printed dump, not a before/after comparison — `JsonDiffView` requires two objects and would misrender. `JsonEditor(readOnly)` is exactly "labeled, bordered, monospace, non-editable JSON box," which is what this drawer already is. |
| 2 | `DlqPage.tsx:466-469` — "Context JSON" in the detail panel | `<pre>{toPrettyJson(...)}</pre>` | **`JsonEditor` with `readOnly={true}`** | Same shape: one object (`context_json ?? processor_metadata`), no diff semantics. |
| 3 | `DlqPage.tsx:471-474` — "Source payload" in the detail panel | `<pre>{toPrettyJson(...)}</pre>` | **`JsonEditor` with `readOnly={true}`** | Same shape: one object (`source_payload ?? original_payload`). |

**`JsonDiffView` is not used anywhere in this requirement's scope** — no location in
`definitions/` or `dlq/` compares a before-state and an after-state; every JSON display here is
a single-object read-only dump. This is stated explicitly per the requirement's own instruction
to examine every display, not left implicit.

**Prop note:** `JsonEditor`'s `value` prop is `string`, `onChange` is required by its type (not
optional) even though `readOnly` disables interaction — pass a no-op function
(`() => {}`/`() => undefined`) as `onChange` for all three read-only usages; this is a real,
minor prop-shape friction (an `onChange` a `readOnly` caller can never trigger) worth noting for
FRONTEND-DEV rather than silently working around.

---

## 5. Per-file migration plan

### 5.1 `definitions/DefinitionListPage.tsx` (426 lines, 55 literal-colour hits)

**Hand-rolled → primitive, before/after counts:**

| Construct | Current | Count | Becomes |
|---|---|---|---|
| Outer page wrapper (`<div style={{padding:'1.5rem'}}>` + `<h2>Process Definitions</h2>`) | hand-rolled | 1 | `<PageLayout title="Process Definitions" actions={...}>` — `actions` slot holds the Import/New-Definition buttons (currently right-aligned via `marginLeft:'auto'`) |
| Filter/search row (`data-testid="filter-bar"` div, search input, status `<select>`) | hand-rolled | 1 | `<FilterBar activeCount={status ? 1 : 0} onClear={() => setStatus(undefined)}>` wrapping the existing search `<input>` and status `<select>` unchanged (FilterBar is pure chrome — see §2). Preserve `data-testid="filter-bar"` **on the FilterBar's own outer div is already `data-testid="filter-bar"` internally** — FilterBar renders its own `data-testid="filter-bar"`, so the page must **not** also set `data-testid="filter-bar"` on a wrapping `<div>` (duplicate-testid conflict); drop the page's own `data-testid="filter-bar"` and rely on FilterBar's. |
| Import button | `<button data-testid="btn-import-definition" ...>` | 1 | `<Button variant="secondary" size="sm" data-testid="btn-import-definition" onClick={handleImport}>Import</Button>` |
| New Definition button | `<button data-testid="btn-new-definition" ...>` | 1 | `<Button variant="primary" size="sm" data-testid="btn-new-definition" onClick={...}>+ New Definition</Button>` |
| Definitions table (`<table>` with Name/Version/Status/Updated/Actions) | hand-rolled `<table>` | 1 | `DataTable<ProcessDefinition>` — 5 columns: `name` (sortable, custom accessor rendering the clickable/highlighted name span + description), `version` (sortable via `sortValue: (d) => d.version`), `status` (accessor renders `<StatusBadge status={def.status} domain="definition"/>`, sortable via `sortValue: (d) => d.status`), `updated_at` (sortable, `sortValue: (d) => d.updated_at`, accessor formats via `toLocaleDateString()`), `actions` (accessor renders Activate/Archive `Button`s, not sortable). |
| Activate button | `<button onClick={() => activate.mutate(def.id)} ...>` | 1 | `<Button variant="primary" size="sm" onClick={...} loading={activate.isPending}>Activate</Button>` |
| Archive button | `<button onClick={() => archive.mutate(def.id)} ...>` | 1 | `<Button variant="secondary" size="sm" onClick={...} loading={archive.isPending}>Archive</Button>` |
| Status pill (`STATUS_BADGE[def.status]` colored `<span>`, both in the main row and the version-history expansion) | hand-rolled `<span>` | 2 (main row + version row) | `<StatusBadge status={def.status} domain="definition"/>` (main), `<StatusBadge status={v.status} domain="definition" size="sm"/>` (version history) |
| Create Definition modal | hand-rolled fixed-position `<div>` overlay + form | 1 | **Stays hand-rolled** (tokenized) — not a confirm dialog (`ConfirmDialog`'s `body` is a plain string; this modal has 3 labeled text inputs plus per-field validation errors, a shape `ConfirmDialog` cannot express). No primitive in the current design-system covers an arbitrary multi-field form modal. Cancel/Create buttons inside it become `Button variant="secondary"`/`Button variant="primary"` respectively. |
| Import-error banner, create-error text | hand-rolled colored `<div>`/`<p>` | 2 | **Stays hand-rolled, tokenized — not migrated to `useToast()`** — see §3 OQ-2 (resolved: `<ToastContainer/>` is mounted nowhere in the app, so no `useToast()` call site is introduced by this design; these two elements keep their current inline placement, only their literal colors move onto tokens per §6) |
| Pagination | **none exists** | 0 | **N/A** — `useDefinitions`/`useDefinitionSearch` return the full unpaginated `items` array (no `next_cursor`/`page`/`total` field anywhere in this file). No `PaginationControls` migration applies here; nothing to migrate. |

**Before/after table-construct counts, re-verified by direct grep against the real file**
(`grep -n "<button"`/`"<table"`/`"STATUS_BADGE\["` `DefinitionListPage.tsx`): **6** `<button>`
elements total (lines 173 Import, 190 New Definition, 280 Activate, 288 Archive, 401 Cancel, 408
Create — the last two inside the still-hand-rolled create modal), **1** `<table>` (line 231),
**2** `STATUS_BADGE[...]` status-pill spans (lines 271 main row, 312 version-history row). 1
hand-rolled `<table>` → 1 `DataTable`. 2 hand-rolled status-pill spans → 2 `StatusBadge` call
sites. 4 of the 6 `<button>`s (Import, New Definition, Activate, Archive) → 4 `Button` call sites;
the remaining 2 (Cancel/Create) also → `Button`, inside the still-hand-rolled create modal — all
6 migrate, matching the grepped total exactly.

**Toast migration: none, by design.** `importError` (currently a red banner,
`data-testid="import-error-dialog"`) and `createError` (currently red text inside the modal) are
**not** migrated to `useToast().error(...)` — per §3 OQ-2, `<ToastContainer/>` is mounted nowhere
in the app, so any `useToast()` call this design introduced would be a silent no-op today. Both
elements stay exactly where they are (`importError` as the banner, `createError` inline next to
the field it blocks), with only their literal colors normalized onto tokens per §6 (no primitive
swap, no placement change, no behavior change). This sidesteps what would otherwise have been a
real UX tradeoff (inline blocking error vs. transient top-right toast, and the accessibility
concern of a toast alone not reaching a screen-reader user mid-form) rather than resolving it
under this rework's constraints — a future requirement that mounts `ToastContainer` can revisit
whether either becomes a toast.

**Remaining non-primitive literal colors** (create-modal chrome, since it stays hand-rolled): see
§6's mapping table — all resolve to existing tokens, no new hex needed.

### 5.2 `definitions/DefinitionEditorPage.tsx` (1009 lines, 50 literal-colour hits)

**This file is structurally different from the other three: every `style` prop already uses
`var(--token, #hexFallback)` — never a bare literal.** The guard trips on the `#hexFallback`
half, not on an unmigrated raw literal. Verified (by reading `tokens.css` and cross-checking
every fallback in this file, all 50 occurrences): **every fallback hex value already exactly
equals its token's real value in `tokens.css`** (e.g. `var(--surface-page, #f8f9fa)` —
`--surface-page` really is `#f8f9fa`; `var(--interactive-primary, #228be6)` —
`--interactive-primary` really is `#228be6`; checked all 50, table below covers the handful that
are *not* simply "strip the fallback").

**Fix for the majority (44 of 50 occurrences): delete the second `var()` argument.**
`var(--token, #hex)` → `var(--token)`. Mechanical, file-wide, safe — confirmed by the audit above
that no fallback disagrees with its token's real value, so nothing changes visually.

**The remaining 6 occurrences are bare literals, not `var()` fallbacks — these need the token
wrapper added, not just a fallback stripped:**

| Line | Literal | Context | Fix |
|---|---|---|---|
| 649 | `color: '#fff'` | Save button text color (bg is `var(--interactive-primary,...)`) | `color: 'var(--text-inverse)'` |
| 901 | `background: 'rgba(0,0,0,0.5)'` | Unsaved-changes dialog backdrop | `background: 'var(--surface-overlay)'` (exact value match) |
| 915 | `boxShadow: '0 8px 32px rgba(0,0,0,0.15)'` | Unsaved-changes dialog box shadow | `boxShadow: 'var(--shadow-lg)'` (exact value match — `--shadow-lg` is literally `0 8px 32px rgba(0, 0, 0, 0.15)`) |
| 944 | `background: '#fff'` | "Stay" button background | `background: 'var(--surface-card)'` |
| 959-960 | `background: 'var(--interactive-danger, #fa5252)'`, `color: '#fff'` | "Discard" button | strip fallback on the first; `color: 'var(--text-inverse)'` on the second |
| 995 | `color: bg ? '#fff' : 'var(--text-primary, #212529)'` | `toolbarButtonStyle` ternary | `color: bg ? 'var(--text-inverse)' : 'var(--text-primary)'` |

**Hand-rolled → primitive, before/after counts** (this page is a canvas editor, not a table/list
page — most acceptance-criteria constructs don't apply; each is addressed explicitly rather than
skipped silently):

| Construct | Present in this file? | Disposition |
|---|---|---|
| Table | No | N/A |
| Status pill | The read-only banner (`data-testid="read-only-banner"`, "Read-only — {status}") is informational text, not a status-domain badge tied to `def.status`'s DRAFT/ACTIVE/etc. vocabulary — it's a fixed warning string. **Not migrated to `StatusBadge`** (wrong semantics: `StatusBadge` renders `{status}` as its own label; this banner's text is "Read-only — DRAFT status", a full sentence, not a bare status word) — stays hand-rolled, tokenized per the table above. The small "DRAFT" tag next to "New Definition" (line ~594-598, `isNew` case) **is** a bare status word and **does** migrate: `<StatusBadge status="DRAFT" domain="definition" size="sm"/>`. |
| Pagination | No | N/A |
| Buttons (Export, Promote to Production, Show/Hide Raw JSON, Re-layout, Save, toolbar "Stay"/"Discard" in the unsaved-changes dialog) | Re-grepped directly (`grep -n "<button" DefinitionEditorPage.tsx`): **7 total** `<button>` elements in this file — 5 via the shared `toolbarButtonStyle()` helper (lines 607 Export, 616 Promote to Production, 626 Show/Hide Raw JSON, 633 Re-layout, 648 Save) plus 2 styled inline, not via the helper (line 938 Stay, line 952 Discard, in the unsaved-changes dialog) | All 7 → `Button`: Export/Show-Raw-JSON/Re-layout/Stay → `variant="secondary"`; Promote to Production → `variant="secondary"` (not primary — it's a secondary action relative to Save); Save → `variant="primary"`, `loading={create.isPending}`; Discard → `variant="danger"`. `toolbarButtonStyle()` helper function is deleted once all its call sites migrate to `Button`. **Preserve every existing `data-testid`** (`btn-export-definition`, `promote-to-production-btn`, `btn-show-raw-json`, `btn-auto-layout`, `btn-save-definition`, `unsaved-discard`) via `Button`'s `data-testid` prop — the promote test (§8) depends on `promote-to-production-btn` staying exactly that string. |
| Toast (saved/exportError/promoteMessage/promoteError banners) | Yes, 4 inline colored banners (`save-success-toast`, `promote-success-toast`, `promote-error-toast` testids, plus untested `error`/`exportError`) | **Stays hand-rolled, tokenized — not migrated to `useToast()`** (per §3 OQ-2: `<ToastContainer/>` is mounted nowhere in the app, so a `useToast()` call here would be a silent no-op). All 4 banners keep their current markup, placement, and the existing `setTimeout(() => setSaved(false), 2000)`/`setTimeout(() => setPromoteMessage(null), 4000)` auto-dismiss logic unchanged — only their literal colors move onto tokens per §6. |
| JSON display | Yes, 1 (raw JSON drawer) | See §4, disposition #1 |
| Unsaved-changes dialog (Stay/Discard) | Yes, hand-rolled fixed-overlay dialog | **Candidate for `ConfirmDialog`** (`title="Unsaved Changes"`, `body="You have unsaved changes. Do you want to discard them?"`, `confirmText="Discard"`, `cancelText="Stay"`, `confirmVariant="danger"`, `onConfirm={handleDiscardAndProceed}`, `onCancel={handleCancelNavigation}`). Straightforward fit — single string body, two buttons, danger confirm. **Preserve `data-testid="unsaved-changes-dialog"` and `data-testid="unsaved-discard"`** — `ConfirmDialog` renders its own fixed `data-testid="confirm-dialog"`/`data-testid="confirm-dialog-confirm"`/`data-testid="confirm-dialog-cancel"` internally and does **not** accept a `data-testid` override prop (checked its prop list in §2 — no such prop exists). This is a real prop gap: nothing in `ConfirmDialogProps` lets a caller rename its internal testids. Two options for FRONTEND-DEV: (a) use `ConfirmDialog` as-is and accept the testid rename (then update this page's own component — no external test currently asserts on `unsaved-changes-dialog`/`unsaved-discard`, confirmed by the `grep` in §8, so this is safe), or (b) keep this one dialog hand-rolled specifically to preserve the existing testids for the e2e specs that do reference similar names elsewhere. **Recommend (a)** — no in-scope or e2e test asserts these exact strings (verified), and using the primitive is the point of the migration; note it here rather than silently picking without stating the tradeoff. |

**Confirm-Promote modal** (`ConfirmPromoteModal`) — already a design-system-adjacent component
(imported from `@/components/ui/ConfirmPromoteModal`), **out of scope**: it is not one of the
four files listed in this requirement, and REQ-277's scope is `definitions/`+`dlq/` page files,
not `components/ui/`.

### 5.3 `dlq/DlqPage.tsx` (528 lines, 62 literal-colour hits)

**Re-verified by direct grep against the real file:** `grep -n "<button"` finds **9** total
`<button>` elements (lines 253 Apply, 332 Details, 346 Retry, 358 Discard, 380 Previous, 389 Next,
405 Close, 507 discard-dialog Cancel, 514 discard-dialog Discard-confirm); `grep -n "<table"`
finds **3** (line 274 main DLQ table, line 414 detail-panel key/value table, line 442 retry-history
table). Of the 9 buttons, **7 migrate to `Button`** (Apply, Details, Retry, Discard, Previous,
Next, Close — table below); the remaining **2 (lines 507/514, the discard-confirmation dialog's
own Cancel/Discard buttons) stay hand-rolled, tokenized**, consistent with that dialog itself
staying hand-rolled (see the "Discard-confirmation dialog" row below) — 7 + 2 = 9, matching the
grepped total exactly, no undercount.

**Hand-rolled → primitive, before/after counts:**

| Construct | Current | Count | Becomes |
|---|---|---|---|
| Page wrapper + heading | `<div data-testid="dlq-page" style={{padding:'1.5rem'}}><h2>Dead-Letter Queue</h2>` | 1 | `<PageLayout title="Dead-Letter Queue">` — **preserve `data-testid="dlq-page"`**; `PageLayout` doesn't accept a `data-testid` override either (same gap as `ConfirmDialog`, see above) — wrap `PageLayout` in a `<div data-testid="dlq-page">` if any test depends on it (checked: `web/tests/e2e/f6-dlq.e2e.spec.ts` references `dlq-page`-adjacent testids — e2e specs don't run against Letflow yet per `frontend_developer_guide.md` §2, but preserve the testid anyway since it costs nothing and keeps e2e specs viable when REQ-122 eventually wires them up). |
| Filter row (search input, status `<select>`, source `<select>`, Apply button) | hand-rolled `<div style={{display:'flex',...}}>` | 1 | `<FilterBar activeCount={[search, statusFilter, sourceTypeFilter].filter(Boolean).length} onClear={() => { setSearch(''); setStatusFilter(''); setSourceTypeFilter(''); applyFilters() }}>` wrapping the 3 existing controls + Apply `Button` |
| Apply button | `<button data-testid="dlq-filter-apply" ...>` | 1 | `<Button variant="secondary" size="sm" data-testid="dlq-filter-apply" onClick={applyFilters}>Apply</Button>` |
| Main DLQ table | `<table data-testid="dlq-table">` | 1 | `DataTable<DlqEntry>` — 7 columns: `source` (accessor renders the uppercase pill span — see status-pill row below for why this specific pill is **not** `StatusBadge`), `instance` (accessor renders the `Link` or `—`), `reason` (accessor `extractFailureReason`), `retry_count` (sortable, `sortValue: (e) => e.retry_count`), `created` (sortable, `sortValue: (e) => e.created_at`, accessor `toShortDate`), `status` (accessor `<StatusBadge status={normalizeStatus(e, transientStatusById[e.id])} domain="dlq"/>` — see OQ-1), `actions` (Details/Retry/Discard buttons). **Row-level `data-testid={`dlq-row-${toRowTestId(e.id)}`}`** — `DataTable`'s row `<tr>` sets a fixed `data-testid="datatable-row"`, no per-row override prop. This is a real testid-fidelity loss: nothing in `web/tests` (checked, §8) currently asserts on `dlq-row-<id>`, but `f6-dlq.e2e.spec.ts` does reference row-scoped testids. Flag for FRONTEND-DEV: either accept the loss (dormant e2e, not gating this requirement's `npm test` acceptance criterion) or extend `DataTableColumn`/`DataTableProps` with an optional per-row testid accessor — that would be a `DataTable.tsx` edit, outside this requirement's file scope, so **not** proposed as this requirement's own fix; note as a candidate for the same follow-up issue as OQ-1. |
| "Source" pill (`entry_type`/`item_type`, uppercase gray badge) | hand-rolled `<span>` | 1 | **Stays hand-rolled, tokenized** (not `StatusBadge`) — this is not a *status*, it's a *category label* (`event`/`timer`/`webhook`). `StatusBadge`'s prop is literally named `status`, and its five domains are all status vocabularies (DRAFT/ACTIVE/etc.), not category taxonomies. Forcing a category label through `StatusBadge` would be a semantic misuse of the component for a superficial "differently-colored pill" resemblance — named explicitly here rather than silently forced through the primitive because the acceptance criterion mentions "status pill." |
| Status pill (pending/retrying/resolved/discarded) | hand-rolled `<span>`, `renderStatus()` helper | 2 call sites (table row + detail panel) | `<StatusBadge status={normalized} domain="dlq"/>` at both call sites — see OQ-1 for the color-fidelity caveat |
| Details/Retry/Discard row-action buttons | 3 hand-rolled `<button>`s | 3 | `Button` — Details → `variant="secondary" size="sm"`, Retry → `variant="primary" size="sm" loading={retry.isPending}`, Discard → `variant="danger" size="sm" loading={discard.isPending}` (opens the discard-confirm dialog, doesn't mutate directly — unchanged) |
| Previous/Next pagination buttons | 2 hand-rolled `<button>`s, disabled via `cursorStack.length`/`data?.next_cursor` | 2 | `PaginationControls` — see wrapper design below |
| Close button (detail panel) | hand-rolled `<button>` | 1 | `Button variant="secondary" size="sm"` |
| Detail-panel "table" (Item ID/Source/Instance/Status key-value rows) | hand-rolled `<table>` | 1 | **Stays hand-rolled, tokenized** — this is a 2-column key/value definition list, not tabular data with sortable columns/rows; `DataTable`'s column model (`{id, header, accessor}[]` rendered as `<th>`/`<td>` per row of `data: TRow[]`) doesn't fit a fixed 4-row key/value layout without inventing a fake single-row dataset, which is a worse fit than leaving it as a semantic `<table>`. Named explicitly rather than silently forced. |
| Retry-history table | hand-rolled `<table>` | 1 | `DataTable<RetryAttempt>` — 4 columns: `attempt` (`attemptNo`), `time` (`attemptedAt`, `toShortDate`), `outcome`, `error` (`errorMessage ?? '—'`) |
| Discard-confirmation dialog | hand-rolled fixed-overlay `<div role="dialog">` | 1 | **Stays hand-rolled, tokenized** — see §2's `ConfirmDialog` note: this dialog has a conditional second paragraph (the amber "tied to instance X" warning box, rendered only `if (discardConfirmItem.instance_id)`) with distinct visual treatment (background/border/color) from the primary body text. `ConfirmDialog`'s `body` prop is a single plain string with no slot for a second, differently-styled block — using it would either silently drop the instance-tied warning or flatten it into the same plain-text paragraph as the primary body, losing its visual emphasis. Since that warning exists specifically to flag a higher-stakes consequence (discarding may cancel a running instance), silently downgrading its visibility is a real UX regression, not a cosmetic one — flagged and left hand-rolled (tokenized per §6) rather than forced through a mismatched prop shape. |
| "Queue is empty" / action-error text | hand-rolled `<p>` | 2 | `actionError` **stays hand-rolled, tokenized — not migrated to `useToast()`** (per §3 OQ-2: `<ToastContainer/>` is mounted nowhere in the app; a `useToast()` call here would be a silent no-op), keeping its current inline placement and only normalizing its literal color per §6. "Queue is empty" **stays as `DataTable`'s own `emptyMessage` prop** (`emptyMessage="Queue is empty."`) — not a toast either way, since `DataTable` already has a dedicated, better-fitting empty-state slot (§2: `Inbox` icon + message) than firing a toast for a steady-state (non-error, non-transient) condition. |

**`PaginationControls` wrapper design (Open question resolved, not left as TBD):** DlqPage's
pagination is cursor-stack-based (`cursorStack: string[]`, `goNext`/`goPrev` push/pop),
`PaginationControls` wants `page: number` + `onPageChange(page: number)`. Synthesize:

```
page := cursorStack.length + 1        // 1-indexed, matches PaginationControls' contract
pageSize := 25                         // matches the existing dlqApi.list({ page_size: 25 })
totalItems := null                     // no total-count field anywhere in DlqEntry list response
hasNextPage := data?.next_cursor != null
onPageChange := (nextPage) => { nextPage > page ? goNext() : goPrev() }
```

`onPageChange`'s direction-inference (`nextPage > page ? goNext : goPrev`) works because
`PaginationControls` only ever calls it with `page - 1` or `page + 1` (checked its source, §2) —
never an arbitrary jump — so the comparison is always unambiguous. No `onPageSizeChange` passed
(page size is fixed at 25 server-side in this file today; adding a size selector would be a
behavior change beyond "replace the pagination control," not proposed here).

### 5.4 `dlq/WebhooksPage.tsx` (323 lines, 34 literal-colour hits)

**Re-verified by direct grep against the real file:** `grep -n "<button"` finds **8** total
`<button>` elements (line 158 + New Subscription, lines 185/191 secret-panel Copy-and-dismiss/
Dismiss, lines 248/249 create-form Save/Cancel, lines 288/294/300 row-action View-details/
Pause-Resume/Delete); `grep -n "<table"` finds **1** (line 259). All 8 buttons and the 1 table are
accounted for in the table below — 1 (New Subscription) + 2 (secret panel) + 2 (create form) + 3
(row actions) = 8, matching the grepped total exactly.

**Hand-rolled → primitive, before/after counts:**

| Construct | Current | Count | Becomes |
|---|---|---|---|
| Page wrapper + heading + New-Subscription button | `<div style={{padding:'1.5rem'}}><h2>Webhook Subscriptions</h2><button ...>+ New Subscription</button>` | 1 wrapper + 1 button | `<PageLayout title="Webhook Subscriptions" actions={<Button variant="primary" size="sm" onClick={() => setCreating(true)}>+ New Subscription</Button>}>` |
| One-time HMAC secret panel | hand-rolled cyan `<div>` | 1 | **Stays hand-rolled** (no primitive for an arbitrary informational callout panel exists in this design system — `PageLayout`/`FilterBar` are pure chrome, not content panels), tokenized per §6/OQ-3. "Copy and dismiss" / "Dismiss" buttons inside it → `Button variant="primary"` / `Button variant="ghost"` respectively. |
| Create-subscription form panel | hand-rolled `<div>` with Target URL/Secret inputs, event-type checkboxes | 1 | **Stays hand-rolled** (arbitrary multi-field form, same reasoning as DefinitionListPage's create modal — no form-panel primitive exists), tokenized. Save/Cancel buttons → `Button variant="primary" loading={createWebhook.isPending}"` / `Button variant="secondary"`. `formError` text **stays hand-rolled, tokenized — not migrated to `useToast()`** (per §3 OQ-2: `<ToastContainer/>` is mounted nowhere in the app; a `useToast()` call here would be a silent no-op) — keeps its current inline placement right above the Save/Cancel buttons, same reasoning as §5.1's `createError`, only its literal color normalized per §6. |
| Subscriptions table | `<table>` | 1 | `DataTable<WebhookSubscription>` — 5 columns: `target_url` (monospace accessor, `resolveTargetUrl`), `event_types` (`w.event_types?.join(', ') ?? '—'`), `status` (accessor `<StatusBadge status={resolveStatus(w)} domain="dlq"/>` — see OQ-1, no `webhook` domain exists), `created_at` (sortable, `toLocaleString`), `actions` (View details/Pause-Resume/Delete buttons) |
| **Paused-row background tint** (`background: isPaused ? '#fff7ed' : '#ffffff'` on the `<tr>`) | row-level conditional style | 1 | **Dropped — `DataTable` has no per-row style hook** (checked its prop list, §2: no `rowStyle`/`rowClassName`/similar). This is a decorative-only loss: pause/resume status is still fully conveyed by the status `StatusBadge` cell in the same row; only the whole-row tint disappears. Named explicitly rather than silently vanishing. |
| View details / Pause-Resume / Delete row buttons | 3 hand-rolled `<button>`s | 3 | `Button` — View details → `variant="secondary" size="sm"`, Pause/Resume → `variant="secondary" size="sm"` (was solid teal `#0f766e`; no teal variant exists — see §2), Delete → `variant="danger" size="sm" loading={deleteWebhook.isPending}` |
| Status text color (`isPaused ? '#c2410c' : '#166534'`, inside the pill) | folded into the pill above | — | eliminated — becomes part of the `StatusBadge` cell, no separate literal |
| Event-type checkboxes, fieldset/legend | hand-rolled | — | **Stays hand-rolled** (no checkbox-group primitive exists), tokenized per §6 |

**No pagination control exists in this file** — `webhooksApi.list()` (via a bare `useQuery`,
no `cursor`/`page_size` params passed) returns the full subscription list unpaginated. No
`PaginationControls` migration applies; nothing to migrate, consistent with §5.1's finding for
`DefinitionListPage`.

**Detail panel:** `WebhookSubscriptionDetailPanel` is imported from
`@/components/webhooks/WebhookSubscriptionDetailPanel.tsx` — **out of scope**, not a file under
`definitions/`/`dlq/`.

---

## 6. Token audit — every literal color's replacement

**Method:** for each distinct literal value found across the four in-scope files, determine (a)
whether it disappears automatically because the construct it styled is replaced by a primitive
(Button/DataTable/StatusBadge/PaginationControls carry zero literal colors internally, confirmed
by reading each), or (b) if it survives migration (styles a hand-rolled-and-staying element),
which token it maps to. Per decision `0020-frontend-architecture.md` D1a's own precedent — "one
canonical value, not competing options" — a literal is **normalized onto an existing token**
whenever it plays the same semantic role as that token already; a **new token is added only**
when no existing token's role matches. Applying that rule, **exactly one new token was needed**
(`--shadow-modal-compact`, already added in §0) — every other literal in scope resolves onto a
token that already exists in `tokens.css`.

| Literal(s) | Semantic role | Token |
|---|---|---|
| `#cbd5e1`, `#e2e8f0` (as border) | default border/divider | `var(--border-default)` |
| `#64748b`, `#94a3b8`, `#475569` | muted/secondary text | `var(--text-secondary)` |
| `#374151`, `#0f172a` | strong/label/primary text | `var(--text-primary)` |
| `#f1f5f9` | table header row background | `var(--color-neutral-100)` |
| `#f8fafc`, `#e2e8f0` (as background) | subtle panel/detail background, row-hover | `var(--surface-page)` (page-level) or `var(--color-neutral-50)` (row-hover — same value, pick per context: page/section background → `--surface-page`; row/cell hover or alternate-row tint → `--color-neutral-50`) |
| `#fff`, `#ffffff` (background/card) | card surface | `var(--surface-card)` |
| `#fff` (text on colored button) | inverse text | `var(--text-inverse)` |
| `#dc2626` (text) | strong error text | `var(--color-error-dark)` |
| `#dc2626` (button bg — pre-`Button`-migration hand-rolled spots, if any survive) | strong danger action | `var(--interactive-danger)` |
| `#f59e0b` (non-badge: DLQ discard-dialog warning border) | warning callout border | `var(--color-warning-border)` |
| `#fef3c7` | warning callout background | `var(--color-warning-tint)` |
| `#92400e` | warning callout text | `var(--color-warning-text)` (exact match already) |
| `#2563eb` (non-button remaining uses, e.g. DefinitionListPage's clickable definition-name span) | primary interactive/link color | `var(--interactive-primary)` |
| `#f8fafc`/`#e2e8f0` pre/code blocks (DlqPage detail panel) | code/mono block background+border | `var(--surface-page)` background, `var(--border-default)` border |
| `rgba(0,0,0,0.4)` (DefinitionListPage create-modal backdrop) | modal backdrop | `var(--surface-overlay)` — **note:** existing token is `rgba(0,0,0,0.5)`, a 0.1-opacity normalization, same reasoning as D1a's own canonicalization |
| `rgba(0,0,0,0.5)` (DefinitionEditorPage unsaved-dialog backdrop) | modal backdrop | `var(--surface-overlay)` (exact match) |
| `rgba(0,0,0,0.15)` as `0 8px 32px rgba(0,0,0,0.15)` | modal box-shadow | `var(--shadow-lg)` (exact match) |
| `rgba(0,0,0,0.15)` as `0 4px 24px rgba(0,0,0,0.15)` | compact modal box-shadow | `var(--shadow-modal-compact)` (new token, §0) |
| `rgba(15, 23, 42, 0.45)` | dark-slate modal backdrop | `var(--surface-overlay-slate)` (exact match) |
| `#ecfeff`/`#a5f3fc`/`#cffafe`/`#155e75`/`#0891b2` (WebhooksPage cyan panel) | informational callout | see OQ-3 — recommended `var(--color-info-light)`/`var(--color-info)`/`var(--color-info-tint)`/`var(--color-info-text)`, button → `Button variant="primary"` |
| `#0f766e` (Pause/Resume button) | neutral toggle action | eliminated — `Button variant="secondary"` |
| `#166534`/`#c2410c` (webhook status text) | status color | eliminated — folded into `StatusBadge` cell (OQ-1 covers the resulting fidelity loss) |
| `#fff7ed` (paused-row tint) | row highlight | dropped — see §5.4 |
| `#f59e0b`/`#16a34a`/`#9ca3af`/`#6b7280`/`#374151` (definition/DLQ status badge maps: `STATUS_BADGE`, `STATUS_COLOR`) | status badge colors | eliminated — `StatusBadge`'s own internal token table takes over; `STATUS_BADGE`/`STATUS_COLOR` constants are **deleted** once their only call sites migrate to `<StatusBadge domain="definition"/>`/`<StatusBadge domain="dlq"/>` |
| Every literal inside a `<button style={{...}}>` that migrates to `Button` | button chrome | eliminated — `Button` carries zero literal colors internally (confirmed, §2) |
| Every literal inside a `<table>`/`<th>`/`<td>` that migrates to `DataTable` | table chrome | eliminated — `DataTable` carries zero literal colors internally (confirmed, §2) |

---

## 7. `forbidlist.ts`

**Not modified.** Confirmed by re-reading the file in full (§ read at design time) — the `pages/`
exemption in the `literal-colour` pattern's `allowedPaths` stays until REQ-279 removes it, per
this requirement's own explicit instruction. Nothing in this design requires touching it; the
guard's re-run (post-implementation) is expected to show zero literal-colour hits in
`definitions/`+`dlq/` **because the files no longer contain any**, not because the exemption was
edited.

---

## 8. Test impact

**Existing test files covering this scope:** exactly one —
`web/src/pages/definitions/__tests__/DefinitionEditorPage.promote.test.tsx` (197 lines, 3 test
cases, 0 literal-colour hits). No test file exists anywhere for `DefinitionListPage.tsx`,
`DlqPage.tsx`, or `WebhooksPage.tsx` (confirmed: `grep -rl "DefinitionListPage\|DlqPage\|WebhooksPage\|DefinitionEditorPage" web/src web/tests --include=*.test.* --include=*.spec.*` returns only the one file above).

**`DefinitionEditorPage.promote.test.tsx` — no assertion changes required.** All 3 test cases
assert on `data-testid="promote-to-production-btn"` (existence + `toHaveTextContent('Promote to
Production')`). §5.2's migration plan explicitly preserves this testid via `Button`'s
`data-testid` prop and keeps the same children text — the button's rendered DOM changes (from a
raw `<button style={...}>` to `Button`'s internal markup) but the queryable testid and text
content do not. `screen.getByTestId(...)`/`toHaveTextContent(...)` assertions are DOM-shape
agnostic beyond the testid attribute itself, so no change needed. **If FRONTEND-DEV finds this
test breaks in practice** (e.g. `Button`'s `disabled` attribute or wrapping element interacts
with `toBeInTheDocument()` differently than expected), that is a genuine, unanticipated DOM-shape
difference — list it file-by-file with reason per this requirement's own acceptance criterion,
don't silently alter the assertion to force a pass.

**E2E specs** (`web/tests/e2e/f2-canvas.e2e.spec.ts`, `f2-definition-list.e2e.spec.ts`,
`f6-dlq.e2e.spec.ts`, `f6-webhooks.e2e.spec.ts`, `pdui07-export-import.e2e.spec.ts`,
`pdui08-debounced-search.e2e.spec.ts`) reference several of the testids this migration touches
(`btn-new-definition`, `dlq-table`, `dlq-row-*`, `webhook-secret-once-panel`, etc.) — **not part
of `npm test`** (Playwright, needs a live backend + Keycloak realm per
`frontend_developer_guide.md` §2, "has never run against Letflow," `REQ-122`'s scope). Preserving
testids where the primitives allow it (most cases) costs nothing and keeps these specs viable
once REQ-122 wires them up; where a primitive genuinely has no override hook (`ConfirmDialog`,
`PageLayout`, `DataTable`'s per-row testid), §5's per-construct notes name the gap rather than
silently breaking it.

**No new test files are in this design's scope** — REQ-277 is Step 1 (design) of WF-02; test
authorship is Step 3 (`TEST-DESIGNER`), gated by Step 2d (`REVIEWER`) first. Per WF-02's own Step
3 scope test, this requirement *does* have application-executable surface (four page files with
real behavior), so Steps 3/3b/4 are not skipped — noted here only so CODE-DESIGN-VALIDATOR does
not expect test code to already exist as part of this design artefact.

---

## 9. Acceptance-criteria mapping

| Acceptance criterion | Where addressed |
|---|---|
| Fresh guard regex run scoped to `definitions/`+`dlq/`, zero hits or every hit justified | §1 (re-verified 201, matches exactly); §5/§6 account for every one of the 201 occurrences — eliminated via primitive migration, normalized onto an existing token, or (one case, `--shadow-modal-compact`) a new token |
| Per-file, per-construct before/after counts (table→DataTable, button→Button, status pill→StatusBadge, pagination→PaginationControls) | §5.1-§5.4, one table per file |
| Each JSON display resolved to one disposition, file:line, counts summing to total found | §4 — 3 found, 3 → `JsonEditor(readOnly)`, 0 → `JsonDiffView`, 0 hand-rolled-justified |
| `forbidlist.ts` unmodified | §7 |
| No file outside `definitions/`, `dlq/` modified except `tokens.css`/`design-system.md` addendum | §0 states exactly what was touched (2 files, addendum-only); §3 (OQ-1, OQ-2) names the two places where full literal compliance would require a third file, and defers those to ORCH rather than silently expanding scope |
| Existing test suite passes, no assertion altered for a colour/markup change; any genuine change listed file-by-file with reason | §8 — the one existing test needs no changes; reasoning given for why |
| `npm run type-check && npm run lint && npm test && npm run guards` all pass, real output quoted | FRONTEND-DEV's Step 2b responsibility — not run here (design step produces no implementation code, per this role's Forbidden list) |

---

## 10. Open questions summary (for CODE-DESIGN-VALIDATOR)

1. **OQ-1** — `StatusBadge` has no `webhook` domain and `dlq`'s status table is empty; recommend
   proceeding with `domain='dlq'` for both DlqPage and WebhooksPage (uniform, spec-honest,
   degraded color-coding) and filing a follow-up issue to extend `StatusBadge.tsx`, rather than
   touching it in this requirement's scope.
2. **OQ-2** — `<ToastContainer/>` is mounted nowhere in the app; **resolved (revised on rework):**
   this design introduces **no** `useToast()` call sites at all — every banner/error/success
   element in scope (`importError`/`createError`, `saved`/`exportError`/`promoteMessage`/
   `promoteError`, `actionError`, `formError`) stays hand-rolled and inline, only its literal
   colors normalized onto tokens per §6. Mounting `<ToastContainer/>` in `AppShell.tsx` is filed
   as a separate follow-up issue for ORCH, not done as part of this design or requirement — AC5's
   file-scope fence is a literal two-file exception list, not something a design step can expand.
3. **OQ-3** — WebhooksPage's cyan one-time-secret panel has no matching existing token family;
   recommend Option A (normalize onto `--color-info-*`, zero new tokens, hue shifts cyan→blue)
   over Option B (add 4 new cyan-specific tokens, preserves current hue exactly).

None of these three block the rest of the design — §5's per-file plans work under either
resolution of each (domain name is a one-line swap; toast mount location doesn't change any
call-site code; OQ-3's two options are both drop-in token-name swaps in the same handful of
`style` props).
