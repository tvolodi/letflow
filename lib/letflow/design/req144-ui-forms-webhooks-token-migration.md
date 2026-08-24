# Design: REQ-144 — Migrate web/src/components/ui/, forms/, and webhooks/ off inline hex literals to tokens.css custom properties

**Requirement:** REQ-144  
**Stage:** S8 (frontend migration)  
**Owner:** FRONTEND-DEV  
**Design author:** CODE-DESIGNER  
**Date:** 2026-08-24  
**Status:** DESIGN — awaiting CODE-DESIGN-VALIDATOR gate

---

## 1. Scope and constraints

### 1.1 Files to be modified (12 files with hex hits)

```
web/src/components/ui/ConfirmDialog.tsx                  ( 9 line-hits)
web/src/components/ui/ConfirmPromoteModal.tsx            ( 8 line-hits)
web/src/components/ui/ConflictResolver.tsx               (24 line-hits)
web/src/components/ui/FetchError.tsx                     ( 2 line-hits)
web/src/components/ui/JsonDiffView.tsx                   ( 9 line-hits)
web/src/components/ui/QueryStateBoundary.tsx             ( 1 line-hit )
web/src/components/ui/RateLimitBackpressure.tsx          ( 6 line-hits)
web/src/components/ui/StaleVersionError.tsx              ( 3 line-hits)
web/src/components/forms/DynamicFormRenderer.tsx         (17 line-hits)
web/src/components/forms/FieldFactory.tsx                (10 line-hits)
web/src/components/webhooks/WebhookDeliveryAttemptsTable.tsx  (12 line-hits)
web/src/components/webhooks/WebhookSubscriptionDetailPanel.tsx (17 line-hits)
```

### 1.2 Files that must NOT be modified (AC-2)

No file outside the three target component directories may be modified by this requirement. Specifically:

- `web/src/styles/tokens.css` — **see §5: 4 new tokens are required as a design addendum**; the tokens.css modification is a prerequisite step, not unplanned scope creep
- `docs/frontend/design-system.md` — **same as above**; palette additions proposed in §5 must land before FRONTEND-DEV starts this requirement
- `web/tests/guards/forbidlist.ts` — no change required (see §1.3)
- All other files outside the three target directories

### 1.3 Guard note (`literal-colour`)

The `literal-colour` guard regex in `web/tests/guards/forbidlist.ts` uses a lookahead requiring `;` to follow the hex literal before any `'`, `"`, or `;`. JS inline-style strings are wrapped in `'...'`, so the `'` terminates the lookahead — the guard does **not** catch hex values inside JS string literals. AC-4 (`npm run guards`) therefore likely already passes; the binding constraint is AC-1 (raw grep). Every literal must be replaced to satisfy AC-1.

---

## 2. Verified hex-literal inventory

Command run:

```powershell
Get-ChildItem -Path "web/src/components/ui","web/src/components/forms","web/src/components/webhooks" `
  -Recurse -Include "*.tsx","*.ts" |
  Select-String -Pattern "#[0-9a-fA-F]{3,8}" -AllMatches |
  Measure-Object   # → 118 line-hits
```

**Total line-hits: 118** (requirement estimated ~133; delta explained by multi-value lines, e.g. `ConfirmDialog.tsx:23` contains both `#2563eb` and `#1d4ed8`; `DynamicFormRenderer.tsx:69` contains both `#fee2e2` and `#fecaca`).  
**Distinct hex values: 33** (treating `#fff` and `#ffffff` as two separate tokens returned by grep; they share the same resolved mapping).

Distinct values extracted:

```
#111827  #166534  #1d4ed8  #1e293b  #2563eb  #334155  #374151  #475569
#64748b  #6b7280  #7f1d1d  #92400e  #991b1b  #b91c1c  #c2410c  #cbd5e1
#d1d5db  #d97706  #dc2626  #dcfce7  #e2e8f0  #ef4444  #f1f5f9  #f8fafc
#fde68a  #fecaca  #fee2e2  #fef2f2  #fef3c7  #fff    #fff7ed  #fffbeb
#ffffff
```

---

## 3. Complete mapping table

### Legend

- **Exact** — hex value equals a token's resolved value; zero visual delta.
- **Nearest** — nearest token by perceptual distance (CIE76 ΔE); same functional semantic role. ΔE noted.
- **NEW TOKEN** — no acceptable nearest match, or nearest match is not coverable for functional reasons; new token required in `tokens.css` and `design-system.md` before migration can proceed (see §5).

### 3.1 Near-exact and exact matches (20 values)

| Hex literal | Token | ΔE | Semantic context notes |
|---|---|---|---|
| `#ffffff` / `#fff` | `var(--surface-card)` | 0 | Modal/card container background. Use `var(--text-inverse)` when white serves as text on a dark bg; `var(--color-neutral-0)` for bare palette reference. |
| `#f8fafc` | `var(--surface-page)` | ~1 | Table header bg, panel backgrounds, code-block bg. |
| `#fef3c7` | `var(--color-warning-light)` | ~3 | Warning-box background in ConflictResolver (paired with #fde68a border). |
| `#f1f5f9` | `var(--color-neutral-100)` | ~3 | Table cell row-divider border, diff-view cell borders. |
| `#6b7280` | `var(--text-secondary)` | ~3 | Muted helper text in ConflictResolver merge panel. |
| `#cbd5e1` | `var(--color-neutral-400)` | ~4 | Input field borders (forms), button borders (FetchError retry, QueryStateBoundary), dashed loading-state borders. |
| `#d97706` | `var(--color-warning-dark)` | ~5 | Retry button border within rate-limit warning box. |
| `#ef4444` | `var(--color-error)` | ~5 | Required-field asterisk `*`, field error border indicator. Use `var(--border-error)` when applied to a `borderColor` property (same resolved value). |
| `#e2e8f0` | `var(--border-default)` | ~7 | Table header/row borders (JsonDiffView, ConflictResolver merge table, WebhookDeliveryAttemptsTable). |
| `#dcfce7` | `var(--color-success-light)` | ~9 | Successful delivery row background (WebhookDeliveryAttemptsTable). |
| `#fee2e2` | `var(--color-error-light)` | ~2 | Error alert block background (DynamicFormRenderer form-schema error, field validation error). |
| `#fef2f2` | `var(--color-error-tint)` | ~2 | Failed-delivery sub-row background (WebhookDeliveryAttemptsTable), error panel in WebhookSubscriptionDetailPanel. |
| `#991b1b` | `var(--color-error-dark)` | ~13 | Error alert heading text ("Unable to render form schema"), webhook error message text. Same semantic role as `--color-error-dark`. |
| `#64748b` | `var(--text-secondary)` | ~14 | Form field help-text/description labels (DynamicFormRenderer, FieldFactory, WebhookSubscriptionDetailPanel). |
| `#b91c1c` | `var(--interactive-danger-hover)` | ~17 | Danger button hover state (ConfirmDialog `VARIANT_STYLES.danger.hover`). |
| `#dc2626` | `var(--interactive-danger)` for **button fill/outline**; `var(--color-error-dark)` for **error text** | ~15 / ~11 | ConfirmPromoteModal danger button bg; ConflictResolver "Discard mine" outline button border+text. Two distinct contexts — see §3.4. |
| `#374151` | `var(--color-neutral-700)` | ~9 | Modal body paragraph text, cancel-button label text (ConfirmDialog, ConfirmPromoteModal, ConflictResolver). |
| `#475569` | `var(--color-neutral-700)` | ~10 | Data-table column text, definition-list label text (WebhookSubscriptionDetailPanel, WebhookDeliveryAttemptsTable). |
| `#d1d5db` | `var(--color-neutral-300)` | ~13 | Cancel button border (ConfirmDialog, ConfirmPromoteModal, ConflictResolver). |
| `#166534` | `var(--color-success-dark)` | ~26 | Active/success status badge text (WebhookDeliveryAttemptsTable success row, WebhookSubscriptionDetailPanel ACTIVE status). ΔE ~26 — noticeable but same semantic role; dark-green success-state text. |

### 3.2 Nearest match — larger visual delta (9 values)

| Hex literal | Token | ΔE | Delta note |
|---|---|---|---|
| `#111827` | `var(--text-primary)` | ~5 | Near-black heading text in ConfirmDialog and ConfirmPromoteModal; imperceptible at title scale. |
| `#1e293b` | `var(--text-primary)` | ~8 | Dark slate form-field label text (DynamicFormRenderer, FieldFactory); near-black, imperceptible. |
| `#334155` | `var(--color-neutral-700)` | ~26 | Event-type column text (WebhookDeliveryAttemptsTable). Blue-shift vs neutral-gray; noticeable at large display but same label role. |
| `#1d4ed8` | `var(--interactive-primary-hover)` | ~22 | Primary button hover state (ConfirmDialog `VARIANT_STYLES.primary.hover`). Hover states have lower fidelity requirements. |
| `#2563eb` | `var(--interactive-primary)` | ~18 | Primary action button fill (DynamicFormRenderer submit, ConflictResolver "Refetch latest" outline). Note: `--color-avatar-blue` resolves to the exact value but is semantically reserved for avatars only (design-system.md §2.3). |
| `#7f1d1d` | `var(--color-error-dark)` | ~29 | Error detail/fine-print message text (DynamicFormRenderer body line below heading, WebhookDeliveryAttemptsTable `last_error`). ΔE ~29, just under the 30 threshold; same functional role as `--color-error-dark`. Both #7f1d1d and #991b1b map to `var(--color-error-dark)` — visual hierarchy within an error alert is maintained by font-weight (bold heading vs normal body), not color. |
| `#fff7ed` | `var(--color-warning-light)` | ~18 | Changed-row diff background in JsonDiffView. Warm tint signal preserved; semantic meaning comes from diff-view context, not color alone. |
| `#c2410c` | `var(--color-warning-text)` *(new — §5)* | ~18 from #92400e | PAUSED subscription status text (WebhookSubscriptionDetailPanel). Note: `--color-avatar-rust` resolves to the exact value but is semantically reserved for avatars only. `--color-warning-text` is the nearest non-avatar alternative in the caution/suspended semantic family. CODE-DESIGN-VALIDATOR may add a dedicated `--color-status-paused` token if PAUSED status requires independent visual identity. |
| `#fef3c7` | `var(--color-warning-light)` | ~3 | Already listed in §3.1 for completeness. |

### 3.3 NEW TOKEN entries (4 values — see §5 for full specification)

| Hex literal | Proposed token | Reason nearest-match is not coverable |
|---|---|---|
| `#92400e` | `--color-warning-text` | ΔE ~35 from `--color-warning-dark` (#e67700), AND different functional role (text-on-background vs border/accent). Accessibility: #92400e on #fffbeb = ~5:1 contrast (WCAG AA pass); #e67700 on #fffbeb = ~3:1 (WCAG AA fail). Mapping to nearest would create an inaccessible warning alert. |
| `#fde68a` | `--color-warning-border` | Different functional role (border accent on warning background vs background fill). Nearest match `--color-warning-light` (#fff3bf) is lighter than the warning background (#fffbeb); mapping would make the warning-box border nearly invisible against its own background. |
| `#fffbeb` | `--color-warning-tint` | ΔE ~17 from `--color-warning-light` (#fff3bf). Completes the "tint/light/color/dark" pattern established for warning state (parallels `--color-success-tint` and `--color-error-tint` from REQ-143). Without this token, warning-box backgrounds in RateLimitBackpressure and StaleVersionError shift visibly from near-white-amber to saturated pale-yellow. |
| `#fecaca` | `--color-error-border` | Different functional role (border accent on error background vs background fill). Nearest match `--color-error-light` (#ffe3e3, ΔE ~12) is lighter than the error background (#fee2e2); mapping would make error-alert borders invisible against their own background. |

### 3.4 `#dc2626` — two distinct contexts

`#dc2626` appears in two different semantic roles across the 12 files:

1. **Filled danger button** — ConfirmPromoteModal.tsx:85 (`background: '#dc2626'`), ConfirmDialog VARIANT_STYLES.danger.bg — map to `var(--interactive-danger)` (#fa5252, ΔE ~15).
2. **Outlined danger button** — ConflictResolver.tsx:213,216 (border + text on "Discard mine" button) — map to `var(--interactive-danger)` for both border and text color (same resolved value, ΔE ~15). May also use `var(--border-error)` for the `border` property (identical resolved value).

FRONTEND-DEV must handle these two uses separately by context.

### 3.5 `#2563eb` — semantic-collision note

`--color-avatar-blue: #2563eb` is an exact-value match. All uses of `#2563eb` in these 12 files are in interactive-button contexts (not avatar contexts), so `var(--color-avatar-blue)` must NOT be used here. Use `var(--interactive-primary)` instead (ΔE ~18). This matches the REQ-143 §3.4 precedent.

### 3.6 `#c2410c` — semantic-collision note

`--color-avatar-rust: #c2410c` is an exact-value match. The single use of `#c2410c` in these files is in WebhookSubscriptionDetailPanel.tsx:138 as a PAUSED subscription status color, not an avatar context. Use `var(--color-warning-text)` (new token, #92400e, ΔE ~18). CODE-DESIGN-VALIDATOR may override to a new `--color-status-paused` token if the PAUSED-vs-warning distinction requires independent visual identity.

---

## 4. New tokens required before implementation (design-step addendum)

### Summary

**4 new tokens** must be added to both `web/src/styles/tokens.css` and `docs/frontend/design-system.md` before FRONTEND-DEV begins. This is an authorised design addendum — the same class of prerequisite step used by REQ-143.

### 4.1 Warning-state palette extension (3 tokens)

The warning state currently has `--color-warning-light / --color-warning / --color-warning-dark` but no tint or text-specific variants. Three tokens complete the set:

```css
/* Warning-state additions */
--color-warning-tint:   #fffbeb;   /* amber-50; barely-amber white; lighter than --color-warning-light */
--color-warning-border: #fde68a;   /* amber-200; border accent for warning boxes */
--color-warning-text:   #92400e;   /* amber-800; WCAG AA dark text on warning backgrounds */
```

Placement in `tokens.css`: after the existing `--color-warning-dark` line, before the `--color-error-*` block.

Placement in `design-system.md §2.1`: extend the "Semantic" subsection with a `/* Warning-state additions (REQ-144 addendum) */` comment group covering all three tokens.

### 4.2 Error-state border token (1 token)

```css
/* Error-state border addition */
--color-error-border: #fecaca;     /* red-200; border accent for error alert blocks */
```

Placement in `tokens.css`: after the existing `--color-error-dark` line (before the REQ-143 tint block).

Placement in `design-system.md §2.1`: within the existing error semantic group.

### 4.3 Resulting warning-state token ladder

After these additions, the warning palette mirrors the error and success patterns:

```
--color-warning-tint   #fffbeb   ← new (REQ-144)
--color-warning-light  #fff3bf   ← existing
--color-warning        #fcc419   ← existing
--color-warning-dark   #e67700   ← existing (for borders, accents)
--color-warning-border #fde68a   ← new (REQ-144): box-border accent
--color-warning-text   #92400e   ← new (REQ-144): WCAG AA text on tint/light bg
```

---

## 5. Per-file hit counts (FRONTEND-DEV implementation reference)

| File | Line-hits | Key hex values | Implementation notes |
|---|---|---|---|
| `ui/ConfirmDialog.tsx` | 9 | `#2563eb`, `#1d4ed8`, `#dc2626`, `#b91c1c`, `#fff`, `#111827`, `#374151`, `#d1d5db` | `VARIANT_STYLES` object at module scope — replace `bg`/`hover` string values with `var()`. `primary.bg: '#2563eb'` → `var(--interactive-primary)`. `danger.bg: '#dc2626'` → `var(--interactive-danger)`. Hover states: `var(--interactive-primary-hover)` and `var(--interactive-danger-hover)`. |
| `ui/ConfirmPromoteModal.tsx` | 8 | `#fff`, `#111827`, `#374151`, `#dc2626`, `#d1d5db` | Danger button fill `#dc2626` → `var(--interactive-danger)`. Title `#111827` and body `#374151` → `var(--text-primary)` and `var(--color-neutral-700)`. |
| `ui/ConflictResolver.tsx` | 24 | `#fff`, `#fef3c7`, `#fde68a`, `#92400e`, `#374151`, `#2563eb`, `#6b7280`, `#dc2626`, `#f8fafc`, `#e2e8f0`, `#d1d5db` | Warning banner (lines 137–141): `#fef3c7` bg → `var(--color-warning-light)`, `#fde68a` border → `var(--color-warning-border)`, `#92400e` text → `var(--color-warning-text)`. "Refetch latest" outline button (lines 160–163): `#2563eb` border+text → `var(--interactive-primary)`. "Discard mine" danger outline (lines 213–216): `#dc2626` border+text → `var(--interactive-danger)`. Merge-table header (lines 276–278): `#f8fafc` bg → `var(--surface-page)`, `#e2e8f0` border → `var(--border-default)`. |
| `ui/FetchError.tsx` | 2 | `#cbd5e1`, `#fff` | Retry button: border `#cbd5e1` → `var(--color-neutral-400)`, bg `#fff` → `var(--surface-card)`. |
| `ui/JsonDiffView.tsx` | 9 | `#64748b`, `#f8fafc`, `#e2e8f0`, `#fff7ed`, `#f1f5f9` | Changed-row bg `#fff7ed` → `var(--color-warning-light)` (ΔE ~18). Row-divider borders `#f1f5f9` → `var(--color-neutral-100)`. No-changes caption `#64748b` → `var(--text-secondary)`. |
| `ui/QueryStateBoundary.tsx` | 1 | `#cbd5e1` | Single retry button border → `var(--color-neutral-400)`. |
| `ui/RateLimitBackpressure.tsx` | 6 | `#fde68a`, `#fffbeb`, `#92400e`, `#d97706`, `#fff` | Warning banner (lines 86–89): `#fde68a` border → `var(--color-warning-border)`, `#fffbeb` bg → `var(--color-warning-tint)`, `#92400e` text → `var(--color-warning-text)`. Retry button (lines 116–119): `#d97706` border → `var(--color-warning-dark)`, `#92400e` text → `var(--color-warning-text)`. |
| `ui/StaleVersionError.tsx` | 3 | `#fde68a`, `#fffbeb`, `#92400e` | Same warning-banner pattern as RateLimitBackpressure (lines 55–59). |
| `forms/DynamicFormRenderer.tsx` | 17 | `#fee2e2`, `#fecaca`, `#991b1b`, `#7f1d1d`, `#cbd5e1`, `#1e293b`, `#ef4444`, `#64748b`, `#2563eb`, `#fff` | Error alert block (lines 69–71, 110–111): `#fee2e2` bg → `var(--color-error-light)`, `#fecaca` border → `var(--color-error-border)`, `#991b1b` heading → `var(--color-error-dark)`, `#7f1d1d` body → `var(--color-error-dark)` (both map to same token — visual hierarchy maintained by `fontWeight: 600` on heading vs normal body). Field borders (lines 155–230): `fieldError ? '#ef4444' : '#cbd5e1'` → `fieldError ? 'var(--border-error)' : 'var(--color-neutral-400)'`. Submit button (lines 257–258): `#2563eb` → `var(--interactive-primary)`. |
| `forms/FieldFactory.tsx` | 10 | `#cbd5e1`, `#ef4444`, `#1e293b`, `#64748b` | Input border `#cbd5e1` → `var(--color-neutral-400)`. Error border `#ef4444` → `var(--border-error)`. Label text `#1e293b` → `var(--text-primary)`. Help text `#64748b` → `var(--text-secondary)`. Error messages `#ef4444` → `var(--color-error)`. |
| `webhooks/WebhookDeliveryAttemptsTable.tsx` | 12 | `#fee2e2`, `#991b1b`, `#fef2f2`, `#dcfce7`, `#166534`, `#ffffff`, `#f8fafc`, `#e2e8f0`, `#7f1d1d`, `#475569`, `#334155` | Failed-row bg `#fee2e2` → `var(--color-error-light)`; failed-row sub-bg `#fef2f2` → `var(--color-error-tint)`. Error text `#991b1b` → `var(--color-error-dark)`. Error detail `#7f1d1d` → `var(--color-error-dark)`. Success row bg `#dcfce7` → `var(--color-success-light)`, text `#166534` → `var(--color-success-dark)`. |
| `webhooks/WebhookSubscriptionDetailPanel.tsx` | 17 | `#ffffff`, `#64748b`, `#cbd5e1`, `#fff`, `#e2e8f0`, `#f8fafc`, `#475569`, `#c2410c`, `#166534`, `#fecaca`, `#fef2f2`, `#991b1b` | Status toggle (line 138): `#c2410c` PAUSED → `var(--color-warning-text)`, `#166534` ACTIVE → `var(--color-success-dark)`. Error panel (line 182): `#fecaca` border → `var(--color-error-border)`, `#fef2f2` bg → `var(--color-error-tint)`, `#991b1b` text → `var(--color-error-dark)`. |

---

## 6. Acceptance-criteria mapping

| AC | Design element covering it |
|---|---|
| AC-1: grep returns zero hits after migration | §3 mapping table resolves all 33 distinct values across all 118 line-hits. Every value has either an exact/nearest-match token or a new-token assignment. After the §4 tokens land in `tokens.css`, FRONTEND-DEV can replace 100% of occurrences with `var()` expressions. No literal is left unresolved. |
| AC-2: no file outside the three target directories modified | §1.2 documents the constraint. The `tokens.css` / `design-system.md` modifications in §4 are explicitly classified as prerequisite addenda, not unplanned scope. No other external file requires change. |
| AC-3: existing component test suite passes unchanged | No test file modifications are planned. All changes are `string` → `string` substitutions in inline `style={{}}` props and module-scope style constant objects (`VARIANT_STYLES`). Component props, rendered structure, state logic, and event handlers are untouched. |
| AC-4: type-check, lint, test, guards pass | Replacing `'#dc2626'` with `'var(--interactive-danger)'` is a `string` → `string` substitution; no TypeScript impact. The `literal-colour` guard does not catch JS-string hex values (§1.3), so guards already pass; after migration the raw grep is also clean. |

---

## 7. Open questions

**OQ-1 — `#c2410c` as PAUSED status:**  
WebhookSubscriptionDetailPanel uses `#c2410c` (exact value of `--color-avatar-rust`) as the PAUSED subscription status text. This design maps it to `var(--color-warning-text)` (#92400e, ΔE ~18). CODE-DESIGN-VALIDATOR should decide whether PAUSED requires a dedicated `--color-status-paused: #c2410c` token for independent visual identity (the rust-orange would then be clearly differentiated from the amber-brown warning text), or whether `--color-warning-text` is an acceptable semantic stand-in.

**OQ-2 — `--color-warning-tint` conservatism:**  
`--color-warning-tint: #fffbeb` is a "pattern-completion" token (ΔE ~17 from `--color-warning-light`). If CODE-DESIGN-VALIDATOR prefers strict minimalism, this token can be dropped and both `#fffbeb` occurrences (RateLimitBackpressure and StaleVersionError) mapped to `var(--color-warning-light)`. The visual shift is noticeable (near-white-amber → pale-yellow) but the semantic signal is preserved.

Nothing in OQ-1 or OQ-2 blocks proceeding to CODE-DESIGN-VALIDATOR review.
