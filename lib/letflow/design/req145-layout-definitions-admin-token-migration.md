# Design: REQ-145 — Migrate web/src/components/layout/, definitions/, and admin/ off inline hex literals to tokens.css custom properties

**Requirement:** REQ-145  
**Stage:** S8 (frontend migration)  
**Owner:** FRONTEND-DEV  
**Design author:** CODE-DESIGNER  
**Date:** 2026-08-24  
**Status:** DESIGN — awaiting CODE-DESIGN-VALIDATOR gate

---

## 1. Scope and constraints

### 1.1 Files to be modified (7 files with hex hits)

The requirement estimated 8 files and ~52 occurrences. Actual verified count from grep:

```
web/src/components/layout/ApiConnectivityBanner.tsx     ( 3 line-hits,  3 value occurrences)
web/src/components/layout/AppShell.tsx                  (13 line-hits, 15 value occurrences)
web/src/components/layout/ErrorBoundary.tsx             (13 line-hits, 13 value occurrences)
web/src/components/layout/TenantHeader.tsx              ( 2 line-hits,  3 value occurrences)
web/src/components/layout/TestEnvironmentBanner.tsx     ( 3 line-hits,  3 value occurrences)
web/src/components/definitions/DraftBanner.tsx          (10 line-hits, 10 value occurrences)
web/src/components/admin/users/DeactivateUserDialog.tsx ( 1 line-hit,   1 value occurrence )
```

Total: **45 line-hits, 48 value occurrences, 28 distinct hex values** (3 lines have 2 hex values each: AppShell.tsx:80, AppShell.tsx:100, TenantHeader.tsx:20).

Discrepancy from estimate: admin/ contains 1 file (not 2) and 1 occurrence (not ~4); the `rgba(15, 23, 42, 0.45)` overlay in DeactivateUserDialog.tsx is not a hex literal and is excluded from AC-1 scope (see §7 OQ-1).

### 1.2 Files that must NOT be modified (AC-2)

No file outside the three target component directories may be modified. Specifically:

- `web/src/styles/tokens.css` — **see §4: 1 prerequisite token update + 5 new tokens are required as a design addendum**; the tokens.css modification is a prerequisite step, not unplanned scope creep
- `docs/frontend/design-system.md` — same; palette additions proposed in §4 must be documented before FRONTEND-DEV starts
- All other files outside the three target directories

### 1.3 Guard note (`literal-colour`)

The `literal-colour` guard regex uses a lookahead requiring `;` before `'`, `"`, or `;`. JS inline-style strings are wrapped in `'...'`, so the `'` terminates the lookahead — the guard does **not** catch hex values inside JS string literals. AC-4 (`npm run guards`) therefore likely already passes; the binding constraint is AC-1 (raw grep). Every literal must be replaced to satisfy AC-1.

---

## 2. Verified hex-literal inventory

Command run:

```powershell
Get-ChildItem -Path "web/src/components/layout","web/src/components/definitions","web/src/components/admin" `
  -Recurse -Include "*.tsx","*.ts" |
  Select-String -Pattern "#[0-9a-fA-F]{3,8}" -AllMatches |
  Select-Object LineNumber, Line, Path   # → 45 line-hits
```

**Total line-hits: 45.** (Requirement estimated ~52; actual is 45 distinct lines; 3 lines contain 2 hex values each → 48 total value occurrences.)  
**Distinct hex values: 28.**

Distinct values across all seven files:

```
#0f172a  #111827  #1e293b  #1e3a8a  #2563eb  #334155  #374151  #38bdf8
#3b82f6  #64748b  #6b7280  #713f12  #94a3b8  #bfdbfe  #cbd5e1  #d1d5db
#dc2626  #eab308  #ef4444  #eff6ff  #f1f5f9  #f3f4f6  #f59e0b  #f8fafc
#fca5a5  #fef08a  #fef9c3  #fff
```

---

## 3. Complete mapping table

### Legend

- **Exact / Near-exact** — hex value matches a token's resolved value within ΔE < 10; imperceptible at normal viewing.
- **Nearest** — nearest token by perceptual distance (CIE76 ΔE); same functional semantic role. ΔE noted.
- **NEW TOKEN** — no acceptable nearest match, or nearest match is not coverable for functional reasons; new token required in `tokens.css` and `design-system.md` before migration can proceed (see §4).

All ΔE values are CIE76 estimates.

### 3.1 Near-exact and exact matches (12 values, ΔE < 10)

| Hex literal | Token | ΔE | Semantic context notes |
|---|---|---|---|
| `#fff` | `var(--surface-card)` when used as **background**; `var(--text-inverse)` when used as **color** (text) | 0 | Card/dialog bg in ErrorBoundary and DeactivateUserDialog → `--surface-card`. Button text on colored bg in ErrorBoundary → `--text-inverse`. DraftBanner button backgrounds → `--surface-card`. FRONTEND-DEV must distinguish by CSS property. |
| `#f8fafc` | `var(--surface-page)` | ~1 | Full-page container bg (ErrorBoundary outer wrapper, AppShell main content). |
| `#f3f4f6` | `var(--color-neutral-100)` | ~2 | Code block background in ErrorBoundary dev-details `<pre>`, secondary "Go to dashboard" button background. |
| `#6b7280` | `var(--text-secondary)` | ~2 | Error-detail `<details>` muted text (ErrorBoundary). |
| `#f1f5f9` | `var(--color-neutral-100)` | ~4 | AppShell sidebar header "Letflow" text, active nav link text. |
| `#cbd5e1` | `var(--color-neutral-400)` | ~4 | Default sidebar body text color (AppShell `<aside>`). |
| `#fef9c3` | `var(--color-warning-light)` | ~7 | ApiConnectivityBanner background (pale-yellow offline indicator). |
| `#eab308` | `var(--color-warning)` | ~8 | Banner bottom borders (ApiConnectivityBanner, TestEnvironmentBanner). |
| `#38bdf8` | `var(--color-brand-400)` | ~7 | Known-tenant display name accent in TenantHeader (sky-blue highlight in dark sidebar). |
| `#64748b` | `var(--text-secondary)` | ~9 | Sidebar footer muted text: user roles, sign-out button, unknown-tenant color (AppShell, TenantHeader). |
| `#713f12` | `var(--color-warning-text)` | ~9 | Dark amber warning text on yellow backgrounds (ApiConnectivityBanner, TestEnvironmentBanner). |
| `#ef4444` | `var(--color-error)` | ~6 | DLQ "critical" badge background in AppShell sidebar nav. |

### 3.2 Nearest match — larger visual delta (11 values)

| Hex literal | Token | ΔE | Delta note |
|---|---|---|---|
| `#111827` | `var(--text-primary)` | ~10 | ErrorBoundary heading "Something went wrong". Near-black — imperceptible at heading scale. |
| `#0f172a` | `var(--text-primary)` | ~15 | DLQ badge label text on colored (red or amber) badge in AppShell. Very dark text on a bright small badge; ΔE ~15 is imperceptible at badge scale. Note: `rgba(15, 23, 42, 0.45)` in DeactivateUserDialog is not a hex literal and is out of scope for AC-1 (see §7 OQ-1). |
| `#374151` | `var(--color-neutral-700)` | ~13 | ErrorBoundary body text paragraph, "Go to dashboard" secondary button text. |
| `#334155` | `var(--color-sidebar-active)` *(new — §4.5)* | 0 | Active-nav highlight bg (AppShell.tsx:81), sidebar footer divider (AppShell.tsx:112), TenantHeader divider (TenantHeader.tsx:11). All three sit on the `#1e293b` sidebar surface — blue-slate progression is load-bearing. Exact match once §4.5 token is added. |
| `#94a3b8` | `var(--color-neutral-500)` | ~9 | AppShell inactive nav-link text, user display name in sidebar footer. |
| `#d1d5db` | `var(--color-neutral-300)` | ~13 | "Go to dashboard" secondary button border (ErrorBoundary). |
| `#dc2626` | `var(--interactive-danger)` | ~17 | ErrorBoundary error SVG icon `stroke`, DraftBanner "Discard draft" outline-button `border` and `color`. For icon `stroke` usage, `var(--interactive-danger)` carries the same "danger indicator" semantic as `var(--color-error)` (same resolved value). |
| `#bfdbfe` | `var(--color-info-light)` | ~17 | DraftBanner border accent (blue-200 vs indigo-100; color-family shift acceptable for a 1 px border). |
| `#2563eb` | `var(--interactive-primary)` | ~17 | ErrorBoundary "Try again" filled button `background`, DraftBanner "Re-apply draft" outline-button `border` and `color`. Note: `--color-avatar-blue: #2563eb` is an exact-value match but is semantically reserved for actor avatars only — do NOT use it here. See §3.4. |
| `#3b82f6` | `var(--interactive-primary)` | ~17 | AppShell active nav-item left-border indicator, DraftBanner field-count sub-text. Both are blue interactive accents; `--interactive-primary` carries the same brand-blue semantic. |
| `#f59e0b` | `var(--color-warning)` | ~18 | AppShell DLQ "warning" badge background. Amber-400 vs bright-yellow; same "non-critical warning" semantic for a small status badge. |

### 3.3 NEW TOKEN entries (5 values — see §4 for full specification)

| Hex literal | Proposed token | Reason nearest-match is not coverable |
|---|---|---|
| `#1e293b` | Update `--surface-sidebar: #1e293b` | ΔE ~10 from current `--surface-sidebar` value (`var(--color-neutral-900)` → `#212529`). The sidebar background is a large, visually prominent element — neutral-gray vs blue-slate shift would visibly break the sidebar's intended visual identity. The existing token is semantically correct ("the sidebar surface") but carries the wrong colour; this is a prerequisite correction, not a new token. See §4.1. |
| `#eff6ff` | `--color-info-tint: #eff6ff` | ΔE ~14 from `--color-info-light` (#dbe4ff). `--color-info-light` is indigo-100 (noticeably more saturated and purple-blue); using it as a full-width banner background would shift the DraftBanner from a near-white blue to a visible indigo tint. Parallels the `--color-error-tint` / `--color-success-tint` / `--color-warning-tint` pattern already in the palette. See §4.2. |
| `#1e3a8a` | `--color-info-text: #1e3a8a` | ΔE ~24 from `--color-info-dark` (#3b5bdb). Deep navy-blue reads as "authoritative label"; medium-bright blue reads as "interactive / link-like." Mapping DraftBanner's heading text to `--color-info-dark` would give it an interactive visual character mismatched with its role as a static heading. No WCAG failure either way, but the semantic collapse is deliberate (deep navy heading vs interactive blue) and cannot be accepted. See §4.2. |
| `#fef08a` | `--color-warning-banner: #fef08a` | ΔE ~4 from `--color-warning-border` (#fde68a) — nearly identical visually, but `--color-warning-border` is semantically a border accent. Using a "border" token for a full-width sticky banner background inverts the token's documented semantic role (banner bg should be lighter than its border; `--color-warning-border` used as bg and `--color-warning` used as border would make the border token lighter than the base colour, which is an antipattern). A dedicated `--color-warning-banner` is the correct semantic home. See §4.3. |
| `#fca5a5` | `--color-error-border-strong: #fca5a5` | ΔE ~18 from `--color-error-border` (#fecaca). ErrorBoundary deliberately uses red-300 (#fca5a5) for its card border while typical inline error alerts use red-200 (#fecaca). The distinction signals visual severity (full-page catastrophic error vs inline field error). Mapping to `--color-error-border` would reduce the error boundary's visual weight, collapsing a deliberate severity distinction. See §4.4. |

### 3.4 `#2563eb` — avatar-collision note

`--color-avatar-blue: #2563eb` is an exact-value match. All uses of `#2563eb` in these files are interactive-button contexts (filled primary button in ErrorBoundary, outline button border/text in DraftBanner). `var(--color-avatar-blue)` must **NOT** be used here — it is semantically reserved for actor avatar backgrounds. Use `var(--interactive-primary)` (ΔE ~17). This matches the REQ-143 §3.4 precedent.

---

## 4. New tokens required before implementation (design-step addendum)

### Summary

**1 prerequisite update + 5 new tokens = 6 total prerequisite changes** must land in `web/src/styles/tokens.css` and `docs/frontend/design-system.md` before FRONTEND-DEV begins. This is an authorised design addendum — the same class of prerequisite step used by REQ-143 and REQ-144.

### 4.1 `--surface-sidebar` correction

**Change:** update `--surface-sidebar` from its current chained value to the colour actually used by AppShell:

```css
/* Before */
--surface-sidebar: var(--color-neutral-900);   /* resolves to #212529 */

/* After */
--surface-sidebar: #1e293b;                    /* slate-800; matches AppShell.tsx sidebar bg */
```

Placement in `tokens.css`: replace the `--surface-sidebar` line in the surface block (no insertion needed). Placement in `design-system.md`: update the surface-token table entry for `--surface-sidebar`.

### 4.2 Info-state palette additions (2 tokens)

The info state currently has `--color-info-light / --color-info / --color-info-dark` but no tint or text-specific variant. Two tokens complete the set:

```css
/* Info-state additions (REQ-145 addendum) */
--color-info-tint: #eff6ff;   /* blue-50; near-white blue; lighter than --color-info-light */
--color-info-text: #1e3a8a;   /* blue-800; authoritative deep-navy text on info backgrounds */
```

Placement in `tokens.css`: after the existing `--color-info-dark` line, before the `--surface-*` block.

Placement in `design-system.md §2.1`: extend the "Semantic" subsection with an `/* Info-state additions (REQ-145 addendum) */` comment group.

The resulting info-state token ladder:

```
--color-info-tint   #eff6ff   ← new (REQ-145): near-white blue background for info banners
--color-info-light  #dbe4ff   ← existing: indigo-100 border accent
--color-info        #4c6ef5   ← existing
--color-info-dark   #3b5bdb   ← existing
--color-info-text   #1e3a8a   ← new (REQ-145): WCAG AA dark text on info backgrounds
```

### 4.3 Warning-banner token (1 token)

The yellow warning palette currently spans `tint → light → base → dark → border → text`. The banner-background use case (TestEnvironmentBanner) sits between `light` and `border` in saturation — distinct from both:

```css
/* Warning-banner addition (REQ-145 addendum) */
--color-warning-banner: #fef08a;  /* yellow-200; deeper yellow for environmental/test warning banners */
```

Placement in `tokens.css`: after `--color-warning-border` (within the REQ-144 warning-state additions comment group).

Resulting warning-state token ladder after this addition:

```
--color-warning-tint   #fffbeb   ← REQ-144: near-white amber background
--color-warning-light  #fff3bf   ← existing: pale yellow background (connectivity banner)
--color-warning-banner #fef08a   ← new (REQ-145): deeper yellow (test environment banner)
--color-warning        #fcc419   ← existing: base yellow (banner borders)
--color-warning-dark   #e67700   ← existing: dark amber accent
--color-warning-border #fde68a   ← REQ-144: amber-200 inline box-border accent
--color-warning-text   #92400e   ← REQ-144: WCAG AA dark text on warning backgrounds
```

### 4.4 Error-border-strong token (1 token)

```css
/* Error-border-strong addition (REQ-145 addendum) */
--color-error-border-strong: #fca5a5;  /* red-300; prominent error border for full-page error UI */
```

Placement in `tokens.css`: after `--color-error-border` (within the REQ-144 error additions comment group, or immediately after `--color-error-border`).

The resulting error-border ladder:

```
--color-error-border        #fecaca   ← REQ-144: red-200; subtle inline error-alert borders
--color-error-border-strong #fca5a5   ← new (REQ-145): red-300; full-page error boundary card border
```

### 4.5 Sidebar-active token (1 token)

```css
/* Sidebar-active addition (REQ-145 addendum) */
--color-sidebar-active: #334155;   /* slate-700; active-nav highlight and dividers on the blue-slate sidebar */
```

Placement in `tokens.css`: adjacent to (or after) `--surface-sidebar` in the surface/sidebar token block.

Placement in `design-system.md §2.2`: add to the sidebar surface-token group.

---

## 5. Per-file hit counts (FRONTEND-DEV implementation reference)

| File | Line-hits | Value occurrences | Key hex values | Implementation notes |
|---|---|---|---|---|
| `layout/ApiConnectivityBanner.tsx` | 3 | 3 | `#fef9c3`, `#eab308`, `#713f12` | Single style object (lines 30–45). `background: '#fef9c3'` → `var(--color-warning-light)`. `borderBottom: '1px solid #eab308'` → `var(--color-warning)`. `color: '#713f12'` → `var(--color-warning-text)`. |
| `layout/AppShell.tsx` | 13 | 15 | `#1e293b`, `#cbd5e1`, `#f1f5f9` (×2), `#94a3b8` (×2), `#334155` (×2), `#3b82f6`, `#0f172a`, `#ef4444`, `#f59e0b`, `#64748b` (×3), `#f8fafc` | Aside bg (line 58): `'#1e293b'` → `var(--surface-sidebar)` (after §4.1 prereq update). Active-nav ternary (line 80): `'#f1f5f9'` → `var(--color-neutral-100)`, `'#94a3b8'` → `var(--color-neutral-500)`. Active-nav bg (line 81): `'#334155'` → `var(--color-sidebar-active)`. Nav indicator border (line 84): `'#3b82f6'` → `var(--interactive-primary)`. DLQ badge (lines 99–100): `'#0f172a'` → `var(--text-primary)`; `'#ef4444'` → `var(--color-error)`; `'#f59e0b'` → `var(--color-warning)`. Footer divider + text (lines 112, 121, 128): `'#334155'` → `var(--color-sidebar-active)`; `'#64748b'` → `var(--text-secondary)`. Main bg (line 136): `'#f8fafc'` → `var(--surface-page)`. |
| `layout/ErrorBoundary.tsx` | 13 | 13 | `#f8fafc`, `#fff` (×2), `#fca5a5`, `#dc2626`, `#111827`, `#374151` (×2), `#6b7280`, `#f3f4f6` (×2), `#2563eb`, `#d1d5db` | Outer bg (line 57): `'#f8fafc'` → `var(--surface-page)`. Card bg (line 65): `'#fff'` → `var(--surface-card)`. Card border (line 66): `'#fca5a5'` → `var(--color-error-border-strong)` (new token). SVG stroke attr (line 79): `"#dc2626"` → `"var(--interactive-danger)"` — note: SVG `stroke` attribute takes a string value; same `'var(…)'` substitution applies. Heading text (line 88): `'#111827'` → `var(--text-primary)`. Body paragraph (line 93): `'#374151'` → `var(--color-neutral-700)`. Details text (line 102): `'#6b7280'` → `var(--text-secondary)`. Pre-block bg (line 107): `'#f3f4f6'` → `var(--color-neutral-100)`. Primary button (lines 127–128): `'#2563eb'` → `var(--interactive-primary)`; `'#fff'` → `var(--text-inverse)`. Secondary button (lines 144–146): `'#f3f4f6'` → `var(--color-neutral-100)`; `'#374151'` → `var(--color-neutral-700)`; `'#d1d5db'` → `var(--color-neutral-300)`. |
| `layout/TenantHeader.tsx` | 2 | 3 | `#334155`, `#64748b`, `#38bdf8` | Sidebar divider (line 11): `'#334155'` → `var(--color-sidebar-active)`. Tenant name ternary (line 20): `'#64748b'` → `var(--text-secondary)` (unknown); `'#38bdf8'` → `var(--color-brand-400)` (known). |
| `layout/TestEnvironmentBanner.tsx` | 3 | 3 | `#fef08a`, `#713f12`, `#eab308` | Single style object (lines 22–30). `background: '#fef08a'` → `var(--color-warning-banner)` (new token). `color: '#713f12'` → `var(--color-warning-text)`. `borderBottom: '1px solid #eab308'` → `var(--color-warning)`. |
| `definitions/DraftBanner.tsx` | 10 | 10 | `#eff6ff`, `#bfdbfe`, `#1e3a8a`, `#3b82f6`, `#2563eb` (×2), `#fff` (×2), `#dc2626` (×2) | Banner wrapper (lines 27–28): `'#eff6ff'` → `var(--color-info-tint)` (new); `'#bfdbfe'` → `var(--color-info-light)`. Heading (line 39): `'#1e3a8a'` → `var(--color-info-text)` (new). Sub-text (line 42): `'#3b82f6'` → `var(--interactive-primary)`. "Re-apply" button (lines 56–59): `'#2563eb'` border → `var(--interactive-primary)`; `'#fff'` bg → `var(--surface-card)`; `'#2563eb'` text → `var(--interactive-primary)`. "Discard" button (lines 72–75): `'#dc2626'` border → `var(--interactive-danger)`; `'#fff'` bg → `var(--surface-card)`; `'#dc2626'` text → `var(--interactive-danger)`. |
| `admin/users/DeactivateUserDialog.tsx` | 1 | 1 | `#fff` | `dialogStyle.backgroundColor: '#fff'` (line 56) → `var(--surface-card)`. The `overlayStyle.backgroundColor: 'rgba(15, 23, 42, 0.45)'` is **not a hex literal** and is out of scope for AC-1 (see §7 OQ-1). |

---

## 6. Acceptance-criteria mapping

| AC | Design element covering it |
|---|---|
| AC-1: grep returns zero hits after migration | §3 mapping table resolves all 28 distinct values across all 48 value occurrences. Every value has either an exact/nearest-match token or a new-token assignment. After the §4 tokens land in `tokens.css`, FRONTEND-DEV can replace 100% of occurrences with `var()` expressions. No literal is left unresolved. |
| AC-2: no file outside the three target directories modified | §1.2 documents the constraint. The `tokens.css` / `design-system.md` modifications in §4 are explicitly classified as prerequisite addenda, not unplanned scope. No other external file requires change. |
| AC-3: existing component test suite passes unchanged | No test file modifications are planned. All changes are `string` → `string` substitutions in inline `style={{}}` props and module-scope style constant objects. Component props, rendered structure, state logic, and event handlers are untouched. |
| AC-4: type-check, lint, test, guards pass | `'#1e293b'` → `'var(--surface-sidebar)'` is a `string` → `string` substitution; no TypeScript impact. The `literal-colour` guard does not catch JS-string hex values (§1.3), so guards already pass; after migration the raw grep is also clean. |

---

## 7. Open questions

**OQ-1 — `rgba(15, 23, 42, 0.45)` overlay in DeactivateUserDialog.tsx:**  
`overlayStyle.backgroundColor` uses `rgba(15, 23, 42, 0.45)`. The RGB values are those of `#0f172a` (Tailwind slate-950), but it is not a hex literal and is not caught by AC-1 grep. `--surface-overlay` in tokens.css is `rgba(0, 0, 0, 0.5)` — different colour and opacity. Two options:
1. Leave as-is (not a hex literal, out of AC-1 scope; DeactivateUserDialog remains untouched).
2. Add `--surface-overlay-slate: rgba(15, 23, 42, 0.45)` as a new token and migrate it, broadening scope slightly.

This design leaves it out of scope (option 1). CODE-DESIGN-VALIDATOR should decide whether option 2 is worth pursuing in a follow-on requirement.

**OQ-2 — `--surface-sidebar` update vs. separate `--color-sidebar-bg` token:**  
§4.1 proposes correcting `--surface-sidebar` to `#1e293b`. If `--surface-sidebar` is intentionally defined as neutral-900 for other uses in the design system (e.g. a future admin panel or modal that differs from AppShell), a separate `--color-sidebar-bg: #1e293b` token would be safer. This design favours updating `--surface-sidebar` directly since AppShell is the only sidebar-rendering component and the token's sole documented purpose is "sidebar surface." CODE-DESIGN-VALIDATOR should confirm if any planned future component depends on `--surface-sidebar: #212529`.

**OQ-3 — `#334155` in sidebar vs. `--color-neutral-700`:**  
**Resolved (CODE-DESIGN-VALIDATOR, 2026-08-24):** `--color-sidebar-active: #334155` was added as §4.5. All three uses in AppShell.tsx (active-nav bg, footer borderTop) and TenantHeader.tsx (borderBottom) use `var(--color-sidebar-active)`. `--color-neutral-700` is not used for `#334155`.

Nothing in OQ-1 or OQ-2 blocks proceeding to implementation.
