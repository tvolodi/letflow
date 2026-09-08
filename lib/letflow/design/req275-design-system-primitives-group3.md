# REQ-275 — Toast, useToast, JsonEditor design-system primitives (group 3 of 3)

**Run:** WF02-REQ275-20260909 · **Step:** 1 (CODE-DESIGNER) · **Requirement:** REQ-275

This is a design artefact. It contains no implementation code — no `.ts`/`.tsx` file is
written or edited by this requirement. It gives exact TypeScript interfaces, token
mappings (cited to `docs/frontend/design-system.md` section numbers), and structural
sketches for `Toast.tsx`, `useToast.ts`, and `JsonEditor.tsx`. Signatures and shapes
only, matching `lib/letflow/design/req272-design-system-primitives-group1.md`'s
convention (Elixir-side analogue: `@spec`s and schema shapes, not function bodies).

## 0. Pre-build re-verification (this requirement's own instruction)

- `ls web/src/components/ui/`: `Button.tsx, ConfirmDialog.tsx, ConfirmPromoteModal.tsx,
  ConflictResolver.tsx, FetchError.tsx, JsonDiffView.tsx, PageLayout.tsx,
  PermissionDenied.tsx, QueryStateBoundary.tsx, RateLimitBackpressure.tsx,
  SkeletonLayout.tsx, StaleVersionError.tsx, StatusBadge.tsx, __tests__/`. Neither
  `Toast.tsx` nor `JsonEditor.tsx` exists. (`Button.tsx`/`StatusBadge.tsx`/
  `PageLayout.tsx` are REQ-272's, already merged — confirms REQ-272 landed.)
- `ls web/src/hooks/`: `useAdminUsers.ts, useApiConnectivity.ts, useDebounce.ts,
  useDefinitions.ts, useHistoryScrubber.ts, useInstances.ts, useModules.ts,
  usePolling.ts, useProcessGraphWithTokens.ts, usePromotions.ts, useTasks.ts,
  __tests__/`. No `useToast.ts`/`useToast.tsx` exists, and `grep -rn "useToast" web/src`
  returns zero hits anywhere in the tree. The requirement's own re-verify instruction is
  satisfied — building fresh, not duplicating.
- Confirmed `docs/frontend/design-system.md` sections 7.3 (`ConfirmDialog`), 7.4
  (`Toast`), 7.5 (`JsonEditor`) read in full (lines 326–375).
- Confirmed `web/src/styles/tokens.css` read in full (131 lines, includes REQ-272's 13
  added tokens: `--text-xs/sm/base/lg`, `--font-medium`, `--space-1/2/3/4/6`,
  `--radius-sm/full`, `--content-max-width`).

## 1. `ConfirmDialog.tsx` divergence report (required finding, this requirement does not fix it)

Section 7.3's spec block:

```tsx
<ConfirmDialog
  open={boolean}
  onConfirm={() => void}
  onCancel={() => void}
  title="Cancel Instance?"
  description="All open tasks will be cancelled. This action cannot be undone."
  confirmLabel="Cancel Instance"
  confirmVariant="danger"
/>
```

Actual `web/src/components/ui/ConfirmDialog.tsx` (`ConfirmDialogProps`, lines 10–20):

```ts
export interface ConfirmDialogProps {
  open: boolean
  title: string
  body: string
  confirmText?: string
  cancelText?: string
  confirmVariant?: 'primary' | 'danger'
  onConfirm: () => void
  onCancel: () => void
  isLoading?: boolean
}
```

**Field-by-field comparison — it DOES diverge:**

| Spec field (7.3) | Actual field | Divergence |
|---|---|---|
| `open` | `open` | match |
| `onConfirm` | `onConfirm` | match |
| `onCancel` | `onCancel` | match |
| `title` | `title` | match |
| `description` | `body` | **name divergence** — same role (dialog body text), different prop name |
| `confirmLabel` | `confirmText` | **name divergence** — same role, different prop name |
| `confirmVariant` | `confirmVariant` | match (spec's example value `"danger"` is a valid member of the actual `'primary' \| 'danger'` union; spec doesn't enumerate the full union so no evidence of a value-level divergence, only that the actual type also allows `'primary'`, which the spec text doesn't rule out) |
| *(not in spec)* | `cancelText` | **additive** — actual has an extra optional prop with no spec counterpart, not a conflict |
| *(not in spec)* | `isLoading` | **additive** — actual has an extra optional prop with no spec counterpart, not a conflict |

**Conclusion: divergence confirmed, not nil.** Two required-role props are named
differently (`description`→`body`, `confirmLabel`→`confirmText`) than section 7.3
states. Per this requirement's explicit scope fence, `ConfirmDialog.tsx` is NOT
rebuilt or renamed here — this table is the reported finding for ORCH to route
(either as a `design-system.md` §7.3 correction to match the shipped API, or as a
future rename requirement) rather than resolved in this run.

## 2. Token audit

Values needed by Toast/JsonEditor, checked against the actual (131-line) `tokens.css`
read for this requirement, not assumed from REQ-272's audit:

| Spec need | Token(s) | Present in `tokens.css`? |
|---|---|---|
| Toast success bg/text/accent | `--color-success-light`, `--color-success-dark`, `--color-success` | Yes (lines 22–24) |
| Toast error bg/text/accent/border | `--color-error-light`, `--color-error-dark`, `--color-error`, `--border-error` | Yes (lines 38–40, 76) |
| Toast warning bg/text/accent | `--color-warning-light`, `--color-warning-dark`, `--color-warning` | Yes (lines 26–28) |
| Toast card elevation | `--shadow-card` | Yes (line 88) |
| Toast spacing (edge offset, internal padding, inter-toast gap) | `--space-2`, `--space-3`, `--space-4` | Yes (REQ-272 addendum, lines 119–123) |
| Toast message font size | `--text-sm` | Yes (REQ-272 addendum, line 113) |
| Toast border radius | `--radius-sm` | Yes (REQ-272 addendum, line 126) |
| Toast close-button color | `--text-secondary` | Yes (line 70) |
| Toast stacking z-index | *(none defined anywhere in `tokens.css` for any component — see note below)* | N/A, no token family exists |
| JsonEditor default/focus border | `--border-default`, `--border-focus` | Yes (lines 74–75) |
| JsonEditor error border | `--border-error` | Yes (line 76) |
| JsonEditor error message text | `--color-error-dark` | Yes (line 40) |
| JsonEditor label text | `--text-primary` | Yes (line 69) |
| JsonEditor textarea text | `--text-primary` | Yes |
| JsonEditor disabled/`readOnly` dimming | `--text-disabled` | Yes (line 71) |
| JsonEditor monospace font family | `--font-mono` | **No** — see addendum below |
| JsonEditor font size | `--text-sm` | Yes (REQ-272 addendum) |
| JsonEditor spacing (label-to-field gap, padding) | `--space-1`, `--space-2` | Yes (REQ-272 addendum) |
| JsonEditor border radius | `--radius-sm` | Yes (REQ-272 addendum) |

**Token gap found: `--font-mono` (design decision, addendum, same category as
REQ-272's §3/§4 gap — a value `design-system.md` §3 already specifies but `tokens.css`
never ported).** `design-system.md` §3 (line 155) declares
`--font-mono: 'JetBrains Mono', 'Fira Code', monospace;`. `tokens.css` has no
`--font-*` family token at all except `--font-medium` (a *weight*, added by REQ-272,
unrelated token family sharing the `--font-` prefix). `JsonEditor` is a code-editing
surface — the spec's own JSON-syntax-validation framing and this component's role
(editing/reviewing raw JSON) make a monospace font the correct choice, and
`--font-mono` is the only spec-defined token for that. No other component in this
requirement or REQ-272's needs a font-family token, so this is the first requirement
that needs one.

**Action for FRONTEND-DEV:** add to `web/src/styles/tokens.css`, inside the existing
`:root { ... }` block, near the other REQ-272-addendum entries:

```css
/* Font family (REQ-275 addendum, from design-system.md §3) */
--font-mono: 'JetBrains Mono', 'Fira Code', monospace;
```

Only `--font-mono` is added — `--font-sans` (line 154 of the spec) has no consumer
yet in any built component (`Button`/`StatusBadge`/`PageLayout`/`ConfirmDialog` all
render with the browser/UA default sans stack, no component sets `font-family`
explicitly), so adding it now would be speculative per the same "only what's actually
used" rule REQ-272's design applied to §3/§4. Not added here.

**Toast stacking z-index — explicit design decision, not a token gap.** No component
in the codebase uses a `--z-*` custom property; every existing `zIndex` value
(`ConfirmDialog.tsx: 600`, `ConfirmPromoteModal.tsx: 500`, `ConflictResolver.tsx:
550/560`, and page-level dialogs at 30–1000) is a plain numeric literal — there is no
established token family to reuse or extend, and `zIndex` is a numeric layout
property, not a colour value, so it is out of scope for the token-audit rule (that
rule, stated in REQ-272's design and this requirement's own text, is about colour
literals). **Design decision: Toast's `ToastContainer` uses `zIndex: 700`** — above
`ConfirmDialog`'s 600 (a toast confirming/reporting the outcome of an action taken
inside a dialog should remain visible/readable even if a dialog is still open above
page content) and above `ConflictResolver`'s 550/560, below nothing else since 1000 is
the highest existing value used only by full-page canvas/definition-editor overlays
that a toast is not expected to compete with simultaneously. Recorded here as a
decision, not silently picked with no rationale.

## 3. `useToast.ts` (`web/src/hooks/useToast.ts`)

### 3.1 Why a module-level store, not React Context

Section 7.4's spec block calls `useToast()` directly with no `<ToastProvider>` wrapper
shown anywhere, and this requirement's SCOPE FENCE explicitly excludes wiring a
provider into the app shell (`web/src/App.tsx` or any page — that's REQ-276..278's
"page migration" work). A hook that must be callable from many unrelated call sites
(any page/component that wants `toast.success(...)`) while a *single* rendered
`ToastContainer` (§4) shows the result needs shared state outside React's tree — the
established pattern for this is a module-level store subscribed to via
`useSyncExternalStore` (React 18+, already Letflow's React major per `web/package.json`
— FRONTEND-DEV to confirm the version at build time, but no other hook in
`web/src/hooks/` currently uses `useSyncExternalStore`, so this is new territory,
flagged as **OQ-1**: if the installed React version predates 18, an equivalent
subscribe/getSnapshot-via-`useState`+`useEffect` pattern is the fallback — either
satisfies this design, the store's public shape (§3.3) is React-version-agnostic).

### 3.2 Public types

```ts
export type ToastVariant = 'success' | 'error' | 'warning'

export interface ToastOptions {
  description?: string
}

export interface ToastEntry {
  id: string              // unique per toast, e.g. crypto.randomUUID() or an incrementing counter
  variant: ToastVariant
  message: string
  description?: string
  durationMs: number       // resolved per §3.4 timing table; Infinity is never used here
  createdAt: number         // Date.now() at creation; exposed for test assertions on ordering
}

export interface UseToastResult {
  success: (message: string, options?: ToastOptions) => void
  error: (message: string, options?: ToastOptions) => void
  warning: (message: string, options?: ToastOptions) => void
}

export function useToast(): UseToastResult
```

This matches design-system.md §7.4's spec block exactly:
`toast.success('Task completed successfully')`,
`toast.error('Failed to cancel instance', { description: error.detail })`,
`toast.warning('Instance is in an error state')` — all three methods take
`(message: string, options?: { description?: string })`, confirmed next to the spec
block per this requirement's own acceptance criterion wording.

### 3.3 Internal store shape (module-scoped, not exported as part of the public hook API, but must exist for `Toast.tsx` to consume — exported from this same file since both live in the `useToast.ts`/`Toast.tsx` pair)

```ts
// Exported for Toast.tsx's consumption and for TEST-DESIGNER's per-test cleanup —
// NOT part of the design-system.md §7.4 public contract (that contract is only
// UseToastResult above).
export function subscribeToasts(listener: () => void): () => void   // returns unsubscribe
export function getToastSnapshot(): ReadonlyArray<ToastEntry>
export function dismissToast(id: string): void                       // manual close; also clears that entry's pending timer
export function clearAllToasts(): void                                // test-only reset hook — module state
                                                                        // persists across renders/tests otherwise,
                                                                        // so TEST-DESIGNER MUST call this in afterEach
```

**Store invariants:**
- Backing state: a single in-module array of `ToastEntry`, newest-first (index 0 =
  most recently added). Never mutated in place — every add/dismiss produces a new
  array reference (required for `useSyncExternalStore`'s snapshot-identity
  contract — a mutated-in-place array with the same reference would not trigger a
  re-render).
- **Add:** `addToast(variant, message, options)` (internal, called by
  `success`/`error`/`warning`) creates a `ToastEntry`, unshifts it to index 0. If the
  resulting array length exceeds 4, the array is truncated to its first 4 entries —
  the dropped entry (always the current last / oldest, since new entries only ever
  enter at index 0) has its pending auto-dismiss timer cleared as part of the drop, no
  orphaned timer. This is the "cap of 4, oldest drops off" behaviour the AC requires.
  Schedules a `setTimeout(() => dismissToast(id), durationMs)` at creation time,
  stored in an internal `id -> timeoutHandle` map so `dismissToast`/`clearAllToasts`
  can `clearTimeout` it.
- **Dismiss (manual or timer-driven):** removes the entry with the matching `id` from
  the array (functional filter, new array reference), clears its timeout handle from
  the internal map if present.
- **Stacking/rendering order:** `ToastContainer` (§4) renders `getToastSnapshot()` in
  array order top-to-bottom inside a `flex-direction: column` container anchored
  `top`/`right` — so index 0 (newest) renders visually topmost, closest to the
  viewport corner. This is the concrete, testable definition of "top-right stacking
  order."

### 3.4 Timing table (durationMs resolution — explicit design decision, not silently guessed)

Section 7.4's prose states exactly two timing buckets: *"Auto-dismiss: success/info
after 4 s; error after 8 s (with manual close)."* The hook's public API (§3.2) exposes
only three methods — `success`, `error`, `warning` — with no fourth `info` method
anywhere in the spec block. Since the timing prose's two buckets are "non-error" (4s)
and "error" (8s), and `warning` is not `error`, **`warning` resolves to the same 4s
bucket as `success`/`info`** — there is no third timing value stated or implied
anywhere in section 7.4, and inventing one (e.g. splitting warning to some other
duration) would be adding behaviour the spec never asked for. Stated as a resolved
design decision with its reasoning, not left as a TBD, and flagged here (**not** as an
open question requiring a human answer, since the AC itself only requires the
success/error timing distinction to be tested — see the acceptance-criteria mapping
in §6):

| Variant | `durationMs` | Manual close available |
|---|---|---|
| `success` | `4000` | yes (see below) |
| `warning` | `4000` | yes |
| `error` | `8000` | yes (spec explicitly calls this out for error) |

All three variants render a close (X) control in `ToastItem` (§4.2) for consistent UX
— the spec singles out error's manual close because error is the long-lived (8s) case
where a user is most likely to want to dismiss early, not because success/warning lack
a close affordance. This is a design choice, flagged as **OQ-2**: if
CODE-DESIGN-VALIDATOR judges the close button should be error-only to track the spec's
literal wording, that is a one-line change to `ToastItem`'s structural sketch (§4.2);
either satisfies the AC's literal text ("a manual close on the error").

## 4. `Toast.tsx` (`web/src/components/ui/Toast.tsx`)

### 4.1 `ToastContainer` — the exported component

```ts
export function ToastContainer(): React.ReactElement | null
```

No props — it is a self-contained subscriber to the `useToast.ts` store (§3.3). Takes
no `children`. Returns `null` when `getToastSnapshot()` is empty (nothing rendered,
matches the "empty state = nothing in the DOM" convention already used by
`ConfirmDialog`'s `if (!open) return null`).

**Structural sketch:**

```
<div data-testid="toast-container"
     style={{ position: 'fixed', top: 'var(--space-4)', right: 'var(--space-4)',
              display: 'flex', flexDirection: 'column', gap: 'var(--space-2)',
              zIndex: 700 }}>
  {entries.map(entry => <ToastItem key={entry.id} entry={entry} />)}
</div>
```

`entries` is the array from `useSyncExternalStore(subscribeToasts, getToastSnapshot)`
(§3.1/§3.3) — capped at 4 by the store itself (§3.3), so `ToastContainer` never needs
its own slicing logic; rendering exactly what the store returns is sufficient to
satisfy the AC's "cap of 4, oldest drops off" behaviour, since the store already
enforces the cap before the container ever sees a 5th entry.

### 4.2 `ToastItem` — internal, not exported (rendered only by `ToastContainer`)

```ts
interface ToastItemProps {
  entry: ToastEntry
}
```

**Structural sketch:**

```
<div data-testid="toast-item"
     data-variant={entry.variant}
     role="status"                                  -- see aria-live note below
     aria-live={entry.variant === 'error' ? 'assertive' : 'polite'}
     style={{ background: VARIANT_BG[entry.variant], borderRadius: 'var(--radius-sm)',
              boxShadow: 'var(--shadow-card)', padding: 'var(--space-3) var(--space-4)',
              display: 'flex', alignItems: 'flex-start', gap: 'var(--space-2)',
              minWidth: '280px', maxWidth: '380px' }}>
  <div style={{ flex: 1 }}>
    <p data-testid="toast-message"
       style={{ color: VARIANT_TEXT[entry.variant], fontSize: 'var(--text-sm)', margin: 0 }}>
      {entry.message}
    </p>
    {entry.description && (
      <p data-testid="toast-description"
         style={{ color: VARIANT_TEXT[entry.variant], fontSize: 'var(--text-sm)',
                  margin: 'var(--space-1) 0 0' }}>
        {entry.description}
      </p>
    )}
  </div>
  <button data-testid="toast-close" type="button" aria-label="Dismiss notification"
          onClick={() => dismissToast(entry.id)}
          style={{ background: 'transparent', border: 'none', color: 'var(--text-secondary)',
                   cursor: 'pointer' }}>
    ×
  </button>
</div>
```

`VARIANT_BG`/`VARIANT_TEXT` are `Record<ToastVariant, string>` lookup tables, same
shape convention as `Button.tsx`'s `VARIANT_STYLES` (REQ-272 precedent):

| Variant | Background | Text |
|---|---|---|
| `success` | `var(--color-success-light)` | `var(--color-success-dark)` |
| `error` | `var(--color-error-light)` | `var(--color-error-dark)` |
| `warning` | `var(--color-warning-light)` | `var(--color-warning-dark)` |

**`aria-live` mechanics (accessibility contract, must be actually asserted per this
requirement's own text — FNFR-03/WCAG 2.1 AA):** `aria-live` is set directly on each
`ToastItem`'s root element, computed per-entry from `entry.variant` — `"assertive"`
when `entry.variant === 'error'`, `"polite"` for every other variant (`success` and
`warning` both get `"polite"`; section 7.4's bullet only distinguishes "success" vs.
"errors" by name, and `warning` is neither explicitly — the same non-error/error
binary reasoning as the timing table in §3.4 applies here, so `warning` groups with
`polite`). This is a per-item attribute (not a single `aria-live` region wrapping the
whole container) so a test can target one rendered `[data-testid="toast-item"]` and
assert its own `aria-live` value independent of what else is stacked above/below it —
this is the concrete mechanism the AC's "asserted against rendered DOM attributes"
requires.

**Timer wiring:** `ToastItem` itself does not own the auto-dismiss timer — the timer
is scheduled by the store at `addToast` time (§3.3), not inside `ToastItem`'s own
`useEffect`. This is a deliberate structural choice: if the timer lived in
`ToastItem`'s effect, unmounting/remounting `ToastContainer` (e.g. a parent
re-render) could reset or duplicate it; anchoring the timer to the store entry's
lifecycle means the toast disappears at the correct wall-clock offset regardless of
how many times the container itself re-renders.

**Note for TEST-DESIGNER (flagged per this requirement's own instruction to CODE-DESIGNER):**
because the auto-dismiss timer is `setTimeout`-based and lives in the store module
(§3.3), tests exercising the 4s/8s timing AC must use `vi.useFakeTimers()` +
`vi.advanceTimersByTime(...)`, and must call `clearAllToasts()` (§3.3) in `afterEach`
— no existing test file in `web/src/` currently uses `vi.useFakeTimers()` (confirmed
by `grep -rl useFakeTimers web/src` returning zero hits), so this is new test-pattern
territory, not an established convention to copy verbatim from an existing spec file.

## 5. `JsonEditor.tsx` (`web/src/components/ui/JsonEditor.tsx`)

### 5.1 Prop interface (matches `design-system.md` §7.5's spec block)

```ts
export interface JsonEditorProps {
  value: string
  onChange: (value: string, isValid: boolean) => void
  label: string
  height?: number      // default 200 — the spec's only shown example value
  readOnly?: boolean   // default false — the spec's own example passes it explicitly as false
}
```

`label` is required (spec's one example always passes it, same "no default shown in
the spec's example → required" convention REQ-272's design applied to `Button`'s
`variant`/`size`). `height` and `readOnly` are optional with the exact defaults the
spec's own example demonstrates.

### 5.2 Validity semantics (explicit design decision)

- `isValid` is computed by attempting `JSON.parse(value)` inside a `try`/`catch` —
  `true` if it does not throw, `false` if it does.
- **Empty string (`value === ''`) is treated as valid (`isValid: true`), not as a
  parse error**, even though `JSON.parse('')` throws. Rationale: an empty editor is
  the "nothing entered yet" state (e.g. optional initial-variables field with no
  default), not a user-authored malformed-JSON state — showing a red error border on
  an untouched empty field would misrepresent the field as broken before the user has
  typed anything. This mirrors the AC's own wording ("onChange reporting isValid false
  for malformed input" — an empty string is absence of input, not malformed input).
  **OQ-3, flagged:** if CODE-DESIGN-VALIDATOR judges empty-string-as-valid is wrong for
  this component's actual call sites (e.g. a required-variables field where empty
  should itself be an error), that's a one-line change to this validity rule; the
  spec text alone does not settle it either way, so it is stated as a decision with
  its rationale rather than silently assumed.

### 5.3 Structural / behavioral sketch (no bodies)

```
<div data-testid="json-editor">
  <label data-testid="json-editor-label"
         style={{ color: 'var(--text-primary)', fontSize: 'var(--text-sm)',
                  display: 'block', marginBottom: 'var(--space-1)' }}>
    {label}
  </label>
  <textarea
    data-testid="json-editor-textarea"
    value={value}
    readOnly={readOnly}
    onChange={(e) => onChange(e.target.value, isValidJson(e.target.value))}
    onBlur={handleBlur}                     -- pretty-print-on-blur, see below
    style={{
      width: '100%',
      height: `${height ?? 200}px`,
      fontFamily: 'var(--font-mono)',
      fontSize: 'var(--text-sm)',
      color: readOnly ? 'var(--text-disabled)' : 'var(--text-primary)',
      border: `1px solid ${isValid ? 'var(--border-default)' : 'var(--border-error)'}`,
      borderRadius: 'var(--radius-sm)',
      padding: 'var(--space-2)',
    }}
  />
  {!isValid && (
    <p data-testid="json-editor-error"
       style={{ color: 'var(--color-error-dark)', fontSize: 'var(--text-sm)',
                margin: 'var(--space-1) 0 0' }}>
      Invalid JSON
    </p>
  )}
</div>
```

- `isValidJson(value)`: the same empty-string-is-valid `try`/`catch` rule from §5.2,
  as a small pure helper (co-located in this file, not exported — internal detail).
- **`onChange` is called on every keystroke** with `(rawValue, isValidJson(rawValue))`
  — this is what makes "onChange reporting isValid false for malformed input"
  (the AC's third JsonEditor behaviour) directly testable by typing an invalid string
  and asserting the second callback argument.
- **`handleBlur`** (pretty-print-on-blur, the AC's second behaviour): on blur, if
  `isValidJson(value)` is true AND `value !== ''`, compute
  `pretty = JSON.stringify(JSON.parse(value), null, 2)`. If `pretty !== value`, call
  `onChange(pretty, true)` — this re-renders the controlled `value` prop with the
  pretty-printed form on the next parent re-render (component is fully controlled;
  it does not keep its own shadow copy of `value`, matching `ConfirmDialog`'s
  fully-controlled `open` pattern). If invalid or empty, blur is a no-op — no
  pretty-print attempted, error state (already shown live via `isValid`) persists
  as-is.
- Component is **fully controlled** — no internal `useState` mirrors `value`;
  `isValid` is derived directly from the `value` prop on every render via
  `isValidJson(value)`, not stored as separate state that could drift from the prop.

## 6. Guard compliance (acceptance criterion: zero literal-colour hits)

None of `Toast.tsx`, `JsonEditor.tsx`, or `useToast.ts`'s designs above introduce any
`#`/`rgb`/`rgba`/`hsl`/`hsla` literal — every colour value is a `var(--token-name)`
reference (§2's audit table lists every one; `--font-mono` is the only new token this
requirement's design adds, and it is a font-family value, not a colour). `zIndex: 700`
(§2's stacking decision) and pixel dimensions (`minWidth`/`maxWidth`/`height`,
`durationMs` numeric literals) are not colour values and are outside the
`literal-colour` guard's regex scope (`web/tests/guards/forbidlist.ts:51`, confirmed
by reading the pattern directly: `#[0-9a-fA-F]{3,8}\b|(?<!...)rgba?\(...\)|(?<!...)hsla?\(...\)`
— matches none of the above). FRONTEND-DEV must still run the literal-colour grep
scoped to these three files after building (this design cannot execute code) — this
section states the design intends zero hits, not that it has confirmed zero hits.

## 7. Open questions (summary, not silently resolved)

- **OQ-1** — `useSyncExternalStore` availability depends on the installed React major
  (no existing hook in `web/src/hooks/` currently uses it). If React < 18, an
  equivalent manual subscribe/`useState`+`useEffect` pattern is the fallback; the
  store's public shape (§3.3) doesn't change either way.
- **OQ-2** — whether the close (X) button renders on `success`/`warning` toasts too, or
  only on `error` (spec's literal text calls out manual close for error specifically).
  This design includes it on all three for UX consistency; flagged for
  CODE-DESIGN-VALIDATOR to confirm or override — a one-line change either way.
- **OQ-3** — whether an empty `JsonEditor` value should report `isValid: true` (this
  design's choice, rationale in §5.2) or `false`. Spec text doesn't settle it; flagged
  rather than silently assumed either way.

Toast's z-index value (`700`) and the `--font-mono` token addendum (§2) are stated as
resolved design decisions with rationale, not open questions, since both follow
directly from the spec text plus existing codebase precedent — but are called out
explicitly per the "no missing token silently invented" rule so FRONTEND-DEV doesn't
have to re-derive them.

## 8. Acceptance-criteria mapping

| Acceptance criterion | Where addressed |
|---|---|
| `Toast.tsx` + `useToast` exist; hook exposes `success`/`error`/`warning` incl. `{ description }` 2nd arg, quoted next to spec block | §3.2 (signature quoted directly beside the §7.4 spec block transcription in §0/§3.2) |
| Each of §7.4's four behaviours has its own test: 4s/8s auto-dismiss + manual close on error, cap of 4 with oldest dropping, top-right stacking order, `aria-live` polite/assertive | §3.4 (timing), §4.2 (manual close, aria-live), §3.3 (cap-of-4 + stacking order definition) — each independently testable per the concrete mechanisms stated |
| `JsonEditor.tsx` exists with §7.5's API; tests assert error state for invalid JSON, pretty-print on blur, `onChange` reporting `isValid` false for malformed input | §5.1 (API), §5.2 (validity semantics), §5.3 (all three behaviours' exact trigger points) |
| `ConfirmDialog.tsx` NOT rebuilt; divergence reported field-by-field (or nil stated) | §1 — divergence confirmed, not nil (`description`→`body`, `confirmLabel`→`confirmText`) |
| Zero literal-colour guard hits across `Toast.tsx`, `JsonEditor.tsx`, the new hook file | §6 |
| No `web/src/pages/` file modified | Out of scope by construction — this design touches only `web/src/components/ui/`, `web/src/hooks/`, and `web/src/styles/tokens.css` |
| `npm run type-check && lint && test && guards` all pass | Not verifiable at design time — FRONTEND-DEV's Step 2b responsibility; this design's token/type choices are constructed to satisfy `type-check` (exact prop types) and `guards` (no literals, §6) by construction |
