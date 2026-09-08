# REQ-272 — Button, StatusBadge, PageLayout design-system primitives (group 1 of 3)

**Run:** WF02-REQ272-20260908 · **Step:** 1 (CODE-DESIGNER) · **Requirement:** REQ-272

This is a design artefact. It contains no implementation code — no `.tsx` file is
written or edited by this requirement. It gives exact TypeScript prop interfaces,
token mappings (cited to `docs/frontend/design-system.md` section numbers), and
structural sketches for `Button`, `StatusBadge`, and `PageLayout`. Signatures and
shapes only, per this project's design-doc convention (see `lib/letflow/design/`'s
Elixir-side docs for the analogue: `@spec`s and schema shapes, not function bodies).

**Pre-build re-verification (2026-09-08→09):** `ls web/src/components/ui/` returns
`ConfirmDialog.tsx, ConfirmPromoteModal.tsx, ConflictResolver.tsx, FetchError.tsx,
JsonDiffView.tsx, PermissionDenied.tsx, QueryStateBoundary.tsx,
RateLimitBackpressure.tsx, SkeletonLayout.tsx, StaleVersionError.tsx, __tests__/`.
`Button.tsx`, `StatusBadge.tsx`, `PageLayout.tsx` do not exist. The requirement's own
"VERIFIED 2026-09-08" claim holds.

**Codebase conventions confirmed by reading `ConfirmDialog.tsx` and
`SkeletonLayout.tsx`** (both in `web/src/components/ui/`):
- Function components, named export, `export interface <Name>Props`.
- Styling via inline `style={{...}}` objects referencing `var(--token-name)` — no CSS
  modules, no styled-components, no `.css` files per component (`tokens.css` is the
  only stylesheet in the tree).
- `data-testid` attributes on interactive/structural elements for test targeting.
- Tests co-located at `web/src/components/ui/__tests__/<Name>.test.tsx`, Vitest +
  `@testing-library/react`, `// @vitest-environment jsdom` pragma at file top,
  `cleanup()` + `vi.clearAllMocks()` in `afterEach`. (`ConfirmPromoteModal.test.tsx`
  is the only existing example under `ui/__tests__/`.)
- No barrel `index.ts` in `web/src/components/ui/` — consumers import the file
  directly (e.g. `import { ConfirmDialog } from '../ConfirmDialog'`). The three new
  components follow the same pattern; no barrel is added by this requirement.

---

## 1. Token audit — re-run section-by-section against the actual `tokens.css` file

**Correction from validator rework:** the prior version of this section checked
`design-system.md` §2 (colors) against `tokens.css` and found it in sync, then
incorrectly assumed §3 (Typography) and §4 (Spacing & Layout) were in the same state
without actually checking them. They are not. `web/src/styles/tokens.css` was read in
full again for this rework (110 lines, reproduced above in the validator's own FAIL
message) and contains **only** `--color-*`, `--surface-*`, `--text-primary/secondary/
disabled/inverse`, `--border-*`, `--interactive-*`, `--shadow-*`, `--minimap-mask-
color`, `--drop-shadow-overlay`, and `--color-avatar-*` — i.e. §2 (colors) plus a few
later color-addendum tokens (REQ-144/145/146). **§3 (Typography) and §4 (Spacing &
Layout) were never ported into `tokens.css` at all** — no `--space-*`, no `--text-xs/
sm/base/lg/xl/2xl/3xl` type-scale entries (`tokens.css` does separately define
`--text-primary/secondary/disabled/inverse`, which are unrelated *color* tokens that
happen to share the `--text-` prefix — not to be confused with the type-scale
`--text-xs/sm/base/lg` this design needs), no `--font-*` weight tokens, no `--radius-*`
family. REQ-141 (which built `tokens.css`) scoped itself to `design-system.md` §2.1–2.2
only (per REQ-120's design), so §3/§4 were out of that requirement's scope and remain
unbuilt.

| Spec need | Token(s) | Present in `tokens.css`? |
|---|---|---|
| Button primary fill/hover | `--interactive-primary`, `--interactive-primary-hover`, `--text-inverse` | Yes (lines 78–79, 72) |
| Button secondary outline/text | `--interactive-primary` (border+text), `--surface-card` (bg) | Yes |
| Button danger fill/hover | `--interactive-danger`, `--interactive-danger-hover`, `--text-inverse` | Yes (lines 80–81) |
| Button ghost text | `--text-secondary`, hover bg `--color-neutral-100` | Yes |
| Button disabled/loading dimming | reuse `opacity`/`cursor` pattern already used in `ConfirmDialog.tsx` (no token, plain CSS values — consistent with existing precedent, not a literal *color*) | N/A |
| Button size padding (§4 scale) | `--space-1`, `--space-2`, `--space-3`, `--space-4`, `--space-6` | **No** — see addendum below |
| Button size font | `--text-sm`, `--text-base`, `--text-lg` | **No** — see addendum below |
| Button size font weight | `--font-medium` | **No** — see addendum below |
| Button border radius | `--radius-sm` | **No** — see addendum below |
| StatusBadge — definition domain (5.1) | `--color-neutral-100/200/400/500/600`, `--text-secondary`, `--color-success-light/-dark/-success`, `--color-warning-light/-dark/-warning` | Yes |
| StatusBadge — instance domain (5.2) | `--color-info-light/-dark/-info`, `--color-success-*`, `--color-neutral-*`, `--color-error-light/-dark/-error` | Yes |
| StatusBadge — task domain (5.3) | `--color-info-light/-dark`, `--color-success-*`, `--color-neutral-200/-600` | Yes |
| StatusBadge size padding | `--space-1`, `--space-2`, `--space-3` | **No** — see addendum below |
| StatusBadge size font | `--text-xs`, `--text-sm` | **No** — see addendum below |
| StatusBadge border radius | `--radius-full` | **No** — see addendum below |
| PageLayout content constraint | `--content-max-width` | **No** — see addendum below |
| PageLayout vertical rhythm | `--space-6` (24px) | **No** — see addendum below |

**OQ-1 (flagged, not silently resolved) — now folded into the addendum below:**
`--content-max-width` is declared in `design-system.md` §4 (`--content-max-width:
1280px;`) but does not exist in `tokens.css`, for the same reason none of §3/§4 exists
there: REQ-141 never ported that section. This was previously treated as an isolated
one-token gap; the rework above shows it's one entry in a larger missing family, all
handled together below.

**Resolution (design-step addendum, not silently invented):** every value below is
copied verbatim from `design-system.md` §3 (Typography) and §4 (Spacing & Layout) —
already-specified spec values the token layer missed, same category of fix as
REQ-144/145/146's addenda visible elsewhere in `tokens.css`. Only the subset actually
used by Button/StatusBadge/PageLayout is added; `design-system.md` §3/§4 also defines
`--text-xl`, `--text-2xl`, `--text-3xl`, `--font-normal`, `--font-semibold`,
`--font-bold`, `--space-8`, `--space-12`, `--space-16`, `--radius-md`, `--radius-lg`,
`--sidebar-width`, `--panel-width` — none of which any of these three components need,
so none of those are added speculatively.

**Action for FRONTEND-DEV:** add the following to `web/src/styles/tokens.css` inside
the existing `:root { ... }` block, as new grouped sections (matching this file's
existing addendum-comment convention, e.g. `/* Warning-state additions (REQ-144
addendum) */`) placed near the end of the block, before the closing `}`:

```css
/* Typography scale (REQ-272 addendum, subset of design-system.md §3) */
--text-xs:   0.75rem;   /* 12px */
--text-sm:   0.875rem;  /* 14px */
--text-base: 1rem;      /* 16px */
--text-lg:   1.125rem;  /* 18px */
--font-medium: 500;

/* Spacing scale (REQ-272 addendum, subset of design-system.md §4) */
--space-1: 4px;
--space-2: 8px;
--space-3: 12px;
--space-4: 16px;
--space-6: 24px;

/* Radius scale (REQ-272 addendum, subset of design-system.md §4) */
--radius-sm:   4px;
--radius-full: 9999px;

/* Content layout (REQ-272 addendum, from design-system.md §4) */
--content-max-width: 1280px;
```

**Naming collision note (must not be missed at implementation time):** `tokens.css`
already declares `--text-primary`, `--text-secondary`, `--text-disabled`,
`--text-inverse` (lines 69–72) — semantic *color* tokens for text color. The new
`--text-xs/sm/base/lg` type-scale tokens this addendum adds are a **different token
family** (font-size, not color) that happens to share the `--text-` prefix, exactly as
`design-system.md` itself defines both families side by side (§2.2 vs. §3). This is
not a collision in practice — the four existing names and the four new names are
disjoint strings — but FRONTEND-DEV should not conflate `--text-secondary` (a color)
with `--text-sm` (a font size) when implementing.

No change to `docs/frontend/design-system.md` §3/§4 is required for any of the above —
the addendum is "`tokens.css` catches up to spec values it missed," the same category
REQ-120's design doc anticipated (§5 of that doc), not a new design decision. This
design doc specifies the exact names/values FRONTEND-DEV must add; adding them to the
actual `tokens.css` file is FRONTEND-DEV's Step 3 implementation work, not this
design step's.

---

## 2. `Button.tsx`

### 2.1 Prop interface (matches `design-system.md` §7.1 exactly)

```ts
export interface ButtonProps {
  variant: 'primary' | 'secondary' | 'danger' | 'ghost'
  size: 'sm' | 'md' | 'lg'
  loading?: boolean            // default false; shows spinner, disables click
  disabled?: boolean           // default false
  onClick?: () => void
  children: React.ReactNode    // "Label" in the spec example
}
```

`variant` and `size` are spec'd as required in §7.1's example (no defaults shown), so
they are required props here — matches the acceptance criterion's "props exactly
match ... variant, size, loading, disabled, onClick, children."

### 2.2 Variant → token mapping (§7.1's prose: "primary: filled brand color",
"secondary: outlined, brand color text", "danger: filled error color", "ghost: no
border, text only")

| Variant | Background | Border | Text | Hover background |
|---|---|---|---|---|
| `primary` | `var(--interactive-primary)` | none | `var(--text-inverse)` | `var(--interactive-primary-hover)` |
| `secondary` | `var(--surface-card)` (transparent-equivalent, matches `ConfirmDialog`'s cancel-button precedent) | `1px solid var(--interactive-primary)` | `var(--interactive-primary)` | `var(--color-neutral-100)` |
| `danger` | `var(--interactive-danger)` | none | `var(--text-inverse)` | `var(--interactive-danger-hover)` |
| `ghost` | transparent | none | `var(--text-secondary)` | `var(--color-neutral-100)` |

### 2.3 Size → spacing/typography mapping (§4's spacing scale, §3's type scale)

| Size | Padding (block/inline) | Font size | Font weight |
|---|---|---|---|
| `sm` | `var(--space-1) var(--space-3)` (4px/12px) | `var(--text-sm)` | `var(--font-medium)` |
| `md` | `var(--space-2) var(--space-4)` (8px/16px) | `var(--text-base)` | `var(--font-medium)` |
| `lg` | `var(--space-3) var(--space-6)` (12px/24px) | `var(--text-lg)` | `var(--font-medium)` |

Border radius: `var(--radius-sm)` for all sizes (consistent with `ConfirmDialog`'s
`4px` button radius, which predates `--radius-sm` but is the same 4px value).

### 2.4 Structural / behavioral sketch (no bodies)

- Root element: `<button type="button" data-testid="ds-button">`, `disabled={disabled
  || loading}`.
- `onClick` wired to the button's native `onClick`, but a no-op guard applies when
  `loading` is true (mirrors §7.1's "shows spinner, disables click" — `disabled`
  attribute already prevents native click, so no extra JS guard needed beyond that).
- When `loading`: render a spinner element before `children` (e.g.
  `<span data-testid="ds-button-spinner" aria-hidden="true" style={{ ...css spin
  animation using currentColor, no color literal... }} />`), and `children` remains
  rendered alongside it (spec doesn't say to hide the label, only that click is
  disabled) — CODE-DESIGN-VALIDATOR note: FRONTEND-DEV's implementation choice on
  exact spinner markup (SVG vs. CSS-only) is unconstrained by the spec; either is
  acceptable as long as it introduces no raw color literal (`currentColor` inherits
  `color`, which is already token-driven, so no new literal is introduced either way).
- When `disabled` (not loading): `opacity: 0.6`, `cursor: 'not-allowed'` — same pair
  of values `ConfirmDialog.tsx` already uses for its disabled buttons (lines 125,
  128/145/149), kept for visual consistency across `ui/`.
- Hover styles: since this codebase's precedent (`ConfirmDialog.tsx`) uses only
  inline `style` (no `:hover` pseudo-class available inline), FRONTEND-DEV will need
  either (a) a small `onMouseEnter`/`onMouseLeave` state toggle, or (b) a scoped
  `<style>` tag / CSS class for `:hover` — **open question OQ-2** (implementation
  mechanism, not a token question): this design doc does not mandate which; either
  keeps all colors token-sourced and neither introduces a literal.

---

## 3. `StatusBadge.tsx`

### 3.1 Prop interface (matches `design-system.md` §5.4 exactly)

```ts
export type StatusBadgeDomain = 'definition' | 'instance' | 'task' | 'timer' | 'dlq'

export interface StatusBadgeProps {
  status: string             // key into the resolved domain's status table
  domain: StatusBadgeDomain
  size?: 'sm' | 'md'          // default 'md', per §5.4's comment
}
```

### 3.2 Status → token resolution tables (cited verbatim from §5.1/5.2/5.3)

Structural shape: a lookup keyed first by `domain`, then by `status`, resolving to
`{ background: string; text: string; dot?: string; pulse?: boolean }` (a `var(...)`
string per field, `dot` optional since 5.3's task table has no Dot column at all).

**`definition` domain (§5.1):**

| status | background | text | dot |
|---|---|---|---|
| `DRAFT` | `var(--color-neutral-100)` | `var(--text-secondary)` | `var(--color-neutral-500)` |
| `ACTIVE` | `var(--color-success-light)` | `var(--color-success-dark)` | `var(--color-success)` |
| `DEPRECATED` | `var(--color-warning-light)` | `var(--color-warning-dark)` | `var(--color-warning)` |
| `ARCHIVED` | `var(--color-neutral-200)` | `var(--color-neutral-600)` | `var(--color-neutral-400)` |

**`instance` domain (§5.2):**

| status | background | text | dot | pulse |
|---|---|---|---|---|
| `ACTIVE` | `var(--color-info-light)` | `var(--color-info-dark)` | `var(--color-info)` | **true** (§5.2: "animated pulse", `instance`+`ACTIVE` only) |
| `COMPLETED` | `var(--color-success-light)` | `var(--color-success-dark)` | `var(--color-success)` | false |
| `CANCELLED` | `var(--color-neutral-200)` | `var(--color-neutral-600)` | `var(--color-neutral-400)` | false |
| `ERROR` | `var(--color-error-light)` | `var(--color-error-dark)` | `var(--color-error)` | false |

**`task` domain (§5.3 — no Dot column in the spec table; `dot` is `undefined` for
every task status, and the component must not render a dot element at all when
resolving a `task`-domain status, not render one with a missing/blank color):**

| status | background | text |
|---|---|---|
| `PENDING` | `var(--color-info-light)` | `var(--color-info-dark)` |
| `COMPLETED` | `var(--color-success-light)` | `var(--color-success-dark)` |
| `CANCELLED` | `var(--color-neutral-200)` | `var(--color-neutral-600)` |

**OQ-3 (flagged, not silently resolved): `timer` and `dlq` domains have no status
table anywhere in `design-system.md`** — §5.4's API example lists them as valid
`domain` values, but sections 5.1–5.3 only cover `definition`/`instance`/`task`. This
requirement's acceptance criteria only require the token-resolution test to cover
"at least one status from EACH of sections 5.1, 5.2 and 5.3," so `timer`/`dlq` are not
blocking — but the component's TypeScript type must still include them (per §5.4's
literal API) since narrowing the type would itself deviate from the spec. Resolution
for this requirement: `timer` and `dlq` resolve through the same lookup structure but
with **no entries** — FRONTEND-DEV must decide a defined fallback behavior for an
unresolved `(domain, status)` pair (e.g. a neutral/default badge using
`--color-neutral-100`/`--text-secondary`/no dot, logged via existing dev-console
warning conventions if any exist in `ui/`) rather than throwing or rendering
`undefined` styles. This fallback also covers any *unknown status string* passed for
a domain that does have a table (e.g. a future status value not yet added to this
component). Do not invent `timer`/`dlq` status tables — that is a follow-on
requirement's job once product defines them, not a silent invention here.

### 3.3 Size → typography/spacing mapping

| Size | Padding | Font size | Dot diameter |
|---|---|---|---|
| `sm` | `var(--space-1) var(--space-2)` | `var(--text-xs)` | `6px` |
| `md` (default) | `var(--space-1) var(--space-3)` | `var(--text-sm)` | `8px`  |

Dot diameter is a plain pixel size (shape, not color) — no token exists or is needed
for element sizing at this granularity; consistent with `SkeletonLayout.tsx`'s own
plain-pixel `1.25rem` row height.

### 3.4 Structural sketch

- Root: `<span data-testid="status-badge" data-status={status} data-domain={domain}
  style={{ background: resolved.background, color: resolved.text, borderRadius:
  'var(--radius-full)', ... }}>`.
- Dot: rendered as a child `<span data-testid="status-badge-dot"
  style={{ background: resolved.dot, ... }} />` **only when `resolved.dot` is
  defined** — omitted entirely for `task`-domain statuses and for the unresolved
  fallback case unless the fallback defines one.
- Pulse: when `resolved.pulse` is true (only `instance`/`ACTIVE` per §3.2), the dot
  element gets an additional animation (CSS `@keyframes` pulse, opacity/scale — no
  color literal introduced, animates only opacity/transform).
- Label text: the `status` string rendered as-is (spec shows raw status keys like
  `ACTIVE`, `DRAFT` — no title-casing transform specified, so none is added here to
  avoid inventing unspec'd behavior).

### 3.5 What the acceptance-criterion test must assert (for TEST-DESIGNER, not built
here)

Per REQ-272's own acceptance criterion: at least one status from **each** of
definition/instance/task must have its resolved background/text/dot asserted — e.g.
`DEPRECATED`+`definition` (bg `--color-warning-light`, text `--color-warning-dark`,
dot `--color-warning`), `ERROR`+`instance` (bg `--color-error-light`, text
`--color-error-dark`, dot `--color-error`), and `PENDING`+`task` (bg
`--color-info-light`, text `--color-info-dark`, **no dot rendered** — the task-domain
test must also assert `queryByTestId('status-badge-dot')` is null, so a partially-
implemented "always render a dot" mistake is caught, not just a missing-token
mistake).

---

## 4. `PageLayout.tsx`

### 4.1 Prop interface (matches `design-system.md` §8's usage example)

```ts
export interface PageLayoutProps {
  title: string
  actions?: React.ReactNode
  children: React.ReactNode
}
```

§8's example passes `title` and `actions` and wraps children (`<FilterBar>`,
`<DataTable>`, `<PaginationControls>`) as JSX children — no other prop appears
anywhere in the spec section, so the interface is exactly these three.

### 4.2 Token mapping

| Feature | Token(s) |
|---|---|
| Content max width | `var(--content-max-width)` (added to `tokens.css` per §1's OQ-1 resolution) |
| Vertical spacing between sections | `var(--space-6)` (24px, §4's grid — "consistent vertical spacing between sections") |
| Page background (optional, matches app shell convention) | `var(--surface-page)` |

### 4.3 Structural sketch (§8: "Page title (h1) + actions slot (top-right)",
"Content area with `--content-max-width` constraint", "Consistent vertical spacing
between sections")

```
<div data-testid="page-layout" style={{ ... }}>
  <div data-testid="page-layout-header" style={{ display:'flex',
       justifyContent:'space-between', alignItems:'center', marginBottom:'var(--space-6)' }}>
    <h1 data-testid="page-layout-title">{title}</h1>
    {actions && <div data-testid="page-layout-actions">{actions}</div>}
  </div>
  <div data-testid="page-layout-content"
       style={{ maxWidth: 'var(--content-max-width)', margin: '0 auto',
                 display: 'flex', flexDirection: 'column', gap: 'var(--space-6)' }}>
    {children}
  </div>
</div>
```

- `h1` is unconditional — always rendered, always contains `title` verbatim (matches
  acceptance criterion "an h1 page title ... asserted by a test against rendered
  output").
- `actions` slot renders only when `actions` is passed (spec's example always passes
  it, but the prop being optional in a layout component is a reasonable, low-risk
  inference — not a spec-contradicting choice, since §8 doesn't show a no-actions
  case either way). **OQ-4:** if CODE-DESIGN-VALIDATOR judges `actions` should be
  required rather than optional to stay strictly literal to the one example shown,
  that's a one-line interface change; flagged rather than silently picked.
- Content wrapper carries `var(--content-max-width)` directly on `maxWidth` — this is
  the element the acceptance criterion's test targets ("content area constrained by
  `var(--content-max-width)`... asserted by a test against rendered output", i.e. the
  test reads the element's inline style / computed style, not the source).

---

## 5. Guard compliance (acceptance criterion: zero literal-colour hits)

None of the three components' designs above introduce any `#`/`rgb`/`rgba`/`hsl`/
`hsla` literal — every color value is a `var(--token-name)` reference. Non-color
values (padding in px via `--space-*` tokens which are themselves px, pixel dot
diameters, border-radius via `--radius-*` tokens) are not in scope of the
`literal-colour` guard pattern (`web/tests/guards/forbidlist.ts`'s regex only matches
hex/`rgba?()`/`hsla?()`). FRONTEND-DEV must still run the literal grep specified in
the acceptance criteria after building, as this design cannot execute code — this
section states the design intends zero hits, not that it has confirmed zero hits.

---

## 6. Open questions (summary, not resolved here)

- **OQ-1** — resolved as a design addendum: §1 now specifies the full set of missing
  tokens (`--space-1/2/3/4/6`, `--text-xs/sm/base/lg`, `--font-medium`, `--radius-sm`,
  `--radius-full`, `--content-max-width`) FRONTEND-DEV must add to `tokens.css`, with
  exact names/values/comments. Not silent — stated as the fix, corrected from the
  original narrower "just `--content-max-width`" framing after CODE-DESIGN-VALIDATOR's
  rework feedback showed the whole §3/§4 family was missing, not just that one entry.
- **OQ-2** — Button hover-state mechanism (inline JS toggle vs. scoped `<style>`
  block) is an implementation choice, not a token/spec question; either is
  acceptable.
- **OQ-3** — `timer`/`dlq` `StatusBadge` domains have no status table in
  `design-system.md`; FRONTEND-DEV needs a defined (non-throwing) fallback for any
  unresolved `(domain, status)` pair, including these two domains entirely.
- **OQ-4** — whether `PageLayout`'s `actions` prop is required or optional; this
  design picks optional as the lower-risk default, flagged for
  CODE-DESIGN-VALIDATOR to confirm or override.

---

## 7. Acceptance-criteria mapping

| Acceptance criterion | Where addressed |
|---|---|
| `Button.tsx` props exactly match §7.1's API | §2.1 |
| `StatusBadge.tsx` API (status, domain, size) + one status per 5.1/5.2/5.3 token-tested | §3.1, §3.2, §3.5 |
| `PageLayout.tsx` renders h1 title, actions slot, content area constrained by `--content-max-width` | §4.1, §4.3 |
| Zero literal-colour guard hits across the three files | §5 |
| New-token-or-explicit-nil statement | §1 (OQ-1: twelve new tokens — `--space-1/2/3/4/6`, `--text-xs/sm/base/lg`, `--font-medium`, `--radius-sm`, `--radius-full`, `--content-max-width` — added to `tokens.css`; no `design-system.md` edit needed since §3/§4 already had the values, `tokens.css` just never ported them) |
| No `web/src/pages/` file modified | Out of scope by construction — this design touches only `web/src/components/ui/` and `web/src/styles/tokens.css` |
| `npm run type-check && lint && test && guards` all pass | Not verifiable at design time — FRONTEND-DEV's Step 3 responsibility; this design's token/type choices are constructed to satisfy `type-check` (exact prop types) and `guards` (no literals) by construction |
