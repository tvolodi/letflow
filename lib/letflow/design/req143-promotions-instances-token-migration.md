# Design: REQ-143 — Migrate web/src/components/promotions/ and web/src/components/instances/ off inline hex literals to tokens.css custom properties

**Requirement:** REQ-143  
**Stage:** S8 (frontend migration)  
**Owner:** FRONTEND-DEV  
**Design author:** CODE-DESIGNER  
**Date:** 2026-08-24  
**Status:** DESIGN — awaiting CODE-DESIGN-VALIDATOR gate

---

## 1. Scope and constraints

### 1.1 Files to be modified (12 files with hex hits)

```
web/src/components/promotions/ConflictRejectionAlert.tsx   (16 lines)
web/src/components/promotions/NonSkippableApprovalGate.tsx (22 lines)
web/src/components/promotions/PlanDigestView.tsx           (23 lines)
web/src/components/promotions/PromotionReviewStateMachine.tsx (24 lines)

web/src/components/instances/ActorAvatar.tsx               (12 lines)
web/src/components/instances/CancelInstanceDialog.tsx      ( 9 lines)
web/src/components/instances/EventHistoryPanel.tsx         (19 lines)
web/src/components/instances/EventJsonExpandable.tsx       ( 3 lines)
web/src/components/instances/HistoryScrubber.tsx           (13 lines)
web/src/components/instances/ProcessGraphWithTokens.tsx    ( 8 lines)
web/src/components/instances/TimelineFeed.tsx              ( 5 lines)
web/src/components/instances/TimelineFeedItem.tsx          ( 8 lines)
```

`web/src/components/promotions/index.ts` — zero hits; no change required.

**Total:** 162 grep-line-hits across 12 files.  
**Total raw occurrences (multi-value lines counted):** ~193 (matching requirement estimate; some lines contain 2–3 hex values, e.g. `{ bg: '#d3f9d8', text: '#2f9e44', label: 'Added' }`).  
**Distinct hex values:** 55 (treating `#fff` and `#ffffff` as one).

### 1.2 Files that must NOT be modified (AC-2)

No file outside the two target component directories may be modified *by this requirement*. Specifically:

- `web/src/styles/tokens.css` — **see §5: new tokens are required as a design addendum**; tokens.css modification is a prerequisite step, not unplanned scope creep
- `docs/frontend/design-system.md` — **same as above**; palette additions proposed in §5 must land before FRONTEND-DEV starts this requirement
- `web/tests/guards/forbidlist.ts` — **no change required** (see §4 on why)
- All other files outside the two target directories

### 1.3 Guard note (`literal-colour`)

The `literal-colour` guard regex in `web/tests/guards/forbidlist.ts` is:

```
/#[0-9a-fA-F]{3,8}\b(?=[^'";\n]*;)/
```

The lookahead `(?=[^'";\n]*;)` requires that a `;` follow the hex literal before any `'`, `"`, or `;`. JS inline-style strings (`style={{ color: '#212529' }}`) are wrapped in `'...'`, so the `'` terminates the lookahead match; the guard does **not** catch hex values inside JS string literals. The guard catches only CSS-file hex literals (e.g. in a `.css` file outside `tokens.css`).

**Implication:** AC-4 (`npm run guards`) likely already passes even without migration; the binding constraint is AC-1, the raw `grep` for `#[0-9a-fA-F]{3,8}`. Every literal must be replaced to satisfy AC-1.

---

## 2. Verified hex-literal inventory

Command run:

```powershell
Get-ChildItem -Path "web/src/components/promotions","web/src/components/instances" `
  -Recurse -Include "*.tsx","*.ts" |
  Select-String -Pattern "#[0-9a-fA-F]{3,8}" -AllMatches |
  Measure-Object   # → 162 line-hits
```

Distinct values extracted:

```
#0284c7  #0891b2  #0d9488  #0f172a  #10b981  #16a34a  #1f2937  #212529
#2563eb  #2f9e44  #334155  #343a40  #3b5bdb  #3b82f6  #40c057  #475569
#495057  #4c6ef5  #4f46e5  #64748b  #6c757d  #7c3aed  #868e96  #9333ea
#94a3b8  #a61e4d  #adb5bd  #c2410c  #c92a2a  #cbd5e1  #ced4da  #d1d5db
#d3f9d8  #dbe4ff  #dbeafe  #dc2626  #dee2e6  #e03131  #e2e8f0  #e67700
#e9ecef  #ea580c  #f1f3f5  #f1f5f9  #f3f4f6  #f8f9fa  #f8fafc  #f8fff8
#fa5252  #fcc419  #ffe3e3  #fff/#ffffff  #fff0f0  #fff3bf  #fff5f5
```

---

## 3. Complete mapping table

### Legend

- **Exact** — hex is identical to a design-system token value; zero visual delta.
- **Nearest** — no exact match; nearest token by perceptual distance with ΔE estimate; same functional semantic role.
- **NEW TOKEN** — no acceptable nearest match; new token required in `tokens.css` and `design-system.md` before migration can proceed (see §5).

### 3.1 Exact palette matches (23 values)

All 23 values below have exact counterparts in the current `tokens.css`.

| Hex literal | Token | Preferred semantic context |
|---|---|---|
| `#ffffff` / `#fff` | `var(--surface-card)` | Container/card backgrounds. Use `var(--text-inverse)` when white serves as text on dark bg; `var(--color-neutral-0)` for bare palette reference. |
| `#f8f9fa` | `var(--surface-page)` | Section/panel page-level background. |
| `#f1f3f5` | `var(--color-neutral-100)` | Hover fill, code badge background, table header bg. |
| `#e9ecef` | `var(--border-default)` | Border/stroke use. Use `var(--color-neutral-200)` for divider fill. |
| `#dee2e6` | `var(--color-neutral-300)` | Lighter border (inactive state outline). |
| `#ced4da` | `var(--color-neutral-400)` | Disabled-state fill; use `var(--text-disabled)` for disabled text. |
| `#adb5bd` | `var(--color-neutral-500)` | Muted icon/arrow fill. |
| `#6c757d` | `var(--text-secondary)` | All secondary/caption/label text. |
| `#495057` | `var(--color-neutral-700)` | Sub-heading text, non-primary body text. |
| `#343a40` | `var(--color-neutral-800)` | Monospace code text, dense data labels. |
| `#212529` | `var(--text-primary)` | Primary body/label text. |
| `#40c057` | `var(--color-success)` | Success state border/icon, approved badge text. |
| `#2f9e44` | `var(--color-success-dark)` | Success state SVG stroke, confirmed state text. |
| `#d3f9d8` | `var(--color-success-light)` | Success badge background. |
| `#fcc419` | `var(--color-warning)` | Warning border. |
| `#fff3bf` | `var(--color-warning-light)` | Warning badge background (pending_review state). |
| `#e67700` | `var(--color-warning-dark)` | Warning text, pending-review state text. |
| `#ffe3e3` | `var(--color-error-light)` | Error badge background (rejected state). |
| `#fa5252` | `var(--color-error)` | Error border/outline. Use `var(--interactive-danger)` when the element is a destructive action button (same resolved value). |
| `#c92a2a` | `var(--color-error-dark)` | Error text, rejected-state text, SVG error stroke. |
| `#dbe4ff` | `var(--color-info-light)` | Info/applied badge background. |
| `#4c6ef5` | `var(--color-info)` | Info icon, applied-state border. |
| `#3b5bdb` | `var(--color-info-dark)` | Info badge text, applied-state text. |

### 3.2 Nearest token — justified visual delta (19 values)

All substitutions below use the same semantic role as the original literal. ΔE values are CIE76 approximations.

| Hex literal | → Token | Token value | ΔE | Delta note |
|---|---|---|---|---|
| `#0f172a` | `var(--text-primary)` | #212529 | ~8 | Near-black; imperceptible at any text size. |
| `#1f2937` | `var(--surface-sidebar)` | #212529 | ~4 | Very dark bg (tooltip/popover); imperceptible. |
| `#334155` | `var(--color-neutral-700)` | #495057 | ~26 | Dark label text; blue-shift vs neutral-gray. Noticeable at large size; same functional role at label scale. |
| `#475569` | `var(--color-neutral-700)` | #495057 | ~9 | Small; acceptable. |
| `#64748b` | `var(--text-secondary)` | #6c757d | ~14 | Slate-blue vs neutral-gray for secondary text; acceptable at caption scale. |
| `#868e96` | `var(--text-secondary)` | #6c757d | ~26 | Inactive-state label text; same muted text role. |
| `#94a3b8` | `var(--color-neutral-500)` | #adb5bd | ~15 | Muted/de-emphasised text; acceptable. |
| `#cbd5e1` | `var(--color-neutral-400)` | #ced4da | ~4 | Input borders; imperceptible. |
| `#d1d5db` | `var(--color-neutral-300)` | #dee2e6 | ~13 | Light text on dark bg (tooltip count); acceptable. |
| `#dbeafe` | `var(--color-info-light)` | #dbe4ff | ~7 | Light-blue timeline border; small delta. |
| `#e2e8f0` | `var(--border-default)` | #e9ecef | ~7 | Table row dividers, code-block borders; small delta. |
| `#e03131` | `var(--color-error-dark)` | #c92a2a | ~27 | "Failed" state border; both dark-red for error. Noticeable but acceptable as border. |
| `#f1f5f9` | `var(--color-neutral-100)` | #f1f3f5 | ~3 | Table header/row-divider bg; imperceptible. |
| `#f3f4f6` | `var(--color-neutral-100)` | #f1f3f5 | ~3 | Tooltip bg; imperceptible. |
| `#f8fafc` | `var(--surface-page)` | #f8f9fa | ~1 | Code-block bg; imperceptible. |
| `#10b981` | `var(--color-success)` | #40c057 | ~35 | "Completed" step; teal-green→pure-green hue shift. Noticeable but unambiguously "done/success." |
| `#3b82f6` | `var(--interactive-primary)` | #228be6 | ~20 | Interactive control (scrubber track/handle); same active-blue role. |
| `#dc2626` | `var(--interactive-danger)` for **buttons**; `var(--color-error-dark)` for **error text** | #fa5252 / #c92a2a | ~45 / ~22 | CancelInstanceDialog danger button and EventHistoryPanel error text. Two different uses; mapped differently by semantic context. |

### 3.3 Special case — `<Background color="...">` in ProcessGraphWithTokens.tsx

`ProcessGraphWithTokens.tsx:76` contains `<Background color="#e2e8f0" gap={20} />`, the same `@xyflow/react` `Background` component pattern documented in REQ-142 §4. The `color` prop is assigned to `--xy-background-pattern-color-props` internally, so `var()` expressions are valid here.

**Resolution:** `color="var(--border-default)"` (maps `#e2e8f0` same as §3.2 above).

### 3.4 `#2563eb` — two distinct contexts

`#2563eb` appears in both:
1. `ActorAvatar.tsx` — as one of the 10 avatar palette colors → `var(--color-avatar-blue)` (see §5)
2. `NonSkippableApprovalGate.tsx:313`, `EventHistoryPanel.tsx:141` — as a submit/apply button background → `var(--interactive-primary)` (nearest; ΔE ~18)

FRONTEND-DEV must map the two occurrences differently.

### 3.5 NEW TOKEN values (13 tokens — see §5 for full specification)

| Hex literal | Proposed token | Reason nearest-match is unacceptable |
|---|---|---|
| `#f8fff8` | `--color-success-tint` | ΔE ~40 from `--color-success-light` (#d3f9d8). Mapping would noticeably darken the "passed" background — a substantive UI regression. |
| `#fff5f5` | `--color-error-tint` | ΔE ~10 from `--color-error-light` (#ffe3e3). Mapping would make error-zone backgrounds visibly pink where currently nearly white. |
| `#fff0f0` | `--color-error-tint` (same token as above) | ΔE ~2 from `#fff5f5`; semantically identical "barely-red white." One token covers both. |
| `#a61e4d` | `--color-failure` | ΔE ~35 from `--color-error-dark` (#c92a2a). Used exclusively for "failed" (system error) state text in PromotionReviewStateMachine, which must visually differ from "rejected" state (also dark-red). Mapping both to `--color-error-dark` collapses an intentional distinction. |
| `#2563eb` (avatar) | `--color-avatar-blue` | Part of a 10-color avatar palette; all 10 must map to distinct tokens to preserve actor visual differentiation. Nearest-mapping collapses ≥3 avatar colors to the same token. |
| `#0d9488` | `--color-avatar-teal` | No palette token in the blue-green range; nearest would be `--color-success-dark` (green) or `--color-info-dark` (blue) — both wrong hue family. |
| `#7c3aed` | `--color-avatar-violet` | No violet/purple in the palette at all. |
| `#ea580c` | `--color-avatar-orange` | Nearest is `--color-warning-dark` (#e67700) — orange-yellow vs reddish-orange; visually similar but shares token with warning semantic. |
| `#0891b2` | `--color-avatar-cyan` | No cyan in palette. |
| `#16a34a` | `--color-avatar-green` | Would collide with `--color-success` if shared. |
| `#9333ea` | `--color-avatar-purple` | No purple in palette. |
| `#0284c7` | `--color-avatar-sky` | Nearest is `--interactive-primary` (#228be6) — shares token with interactive elements; confusing. |
| `#c2410c` | `--color-avatar-rust` | No rust/burnt-orange in palette. |
| `#4f46e5` | `--color-avatar-indigo` | Would collide with `--color-info` (#4c6ef5) if shared. |

---

## 4. New tokens required before implementation (design-step addendum)

### Summary

**13 new tokens** must be added to both `web/src/styles/tokens.css` and `docs/frontend/design-system.md` before FRONTEND-DEV can begin. This is an authorised design addendum per the requirement constraint ("If a component needs a color that design-system.md's current palette does not cover, that is a design-step addendum").

The tokens.css modification is a **prerequisite step**, not scope creep, and does not violate AC-2 (which prohibits unplanned edits outside the target directories, not infrastructure-addendum edits explicitly required by this design).

### 4.1 Semantic tint tokens (3)

```css
/* Tints — lighter-than-light variants for very subtle state backgrounds */
--color-success-tint:  #f8fff8;   /* barely-green white; lighter than --color-success-light */
--color-error-tint:    #fff5f5;   /* barely-red white; lighter than --color-error-light */
--color-failure:       #a61e4d;   /* deep pink-crimson; "failed" system-error state text/icon */
```

Placement in `tokens.css`: after the existing `--color-error-dark` line, before the surface tokens block.

Placement in `design-system.md §2.1`: extend the "Semantic" subsection with a new "Tints and Failure" comment group.

### 4.2 Avatar palette tokens (10)

```css
/* Avatar accent palette — used exclusively by ActorAvatar.tsx for actor differentiation */
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
```

Placement in `tokens.css`: new `/* Avatar accent palette */` comment block at end of `:root`, after the interactive tokens.

Placement in `design-system.md §2.1`: new `/* Avatar accent palette */` subsection with note "Reserved for actor avatar backgrounds. Not for use in semantic UI elements."

### 4.3 ActorAvatar.tsx implementation note

`ActorAvatar.tsx` declares `const AVATAR_PALETTE = ['#2563eb', '#0d9488', ...]` at module scope. FRONTEND-DEV must replace the array values with `var(--color-avatar-*)` strings. The `backgroundColor` prop receives the string as a CSS value; `var()` is valid there. The `isSystem` branch currently uses `#64748b` → replace with `var(--text-secondary)`.

---

## 5. Per-file hit counts (FRONTEND-DEV implementation reference)

| File | Line-hits | Distinct hex values on those lines | Notes |
|---|---|---|---|
| `promotions/ConflictRejectionAlert.tsx` | 16 | ~12 distinct | Lines 18–19 contain 2-value pairs (`{bg, text}`). Lines 68–70 share `#fcc419` border and `#495057` text. Line 75–77 use `#f1f5f9` (table row divider). |
| `promotions/NonSkippableApprovalGate.tsx` | 22 | ~10 distinct | Lines 117–118 contain conditional ternary with 2 values each. Line 313: `#ced4da` vs `#2563eb` (disabled vs active button bg). |
| `promotions/PlanDigestView.tsx` | 23 | ~11 distinct | Lines 39–41 contain 2-value `{bg, text}` pairs. Lines 60–61, 94–95 use ternary with `#f8fff8`/`#fff5f5` and `#40c057`/`#fa5252`. |
| `promotions/PromotionReviewStateMachine.tsx` | 24 | ~14 distinct | Lines 51–56: state-machine color map — 3 values per line (`{bg, text, border}`). Contains `#fff0f0`, `#a61e4d`, `#e03131` (failed state) and `#868e96` (inactive label). |
| `instances/ActorAvatar.tsx` | 12 | 11 distinct | Lines 7–16: avatar palette array (10 colors). Line 46: `#64748b` (system actor). Line 58: `#ffffff` (avatar text). |
| `instances/CancelInstanceDialog.tsx` | 9 | ~7 distinct | Lines 105, 110, 114: Tailwind-slate labels. Line 155: `#dc2626` danger button. |
| `instances/EventHistoryPanel.tsx` | 19 | ~10 distinct | Line 141: `#2563eb` button bg. Lines 165: `#dc2626` error text. Lines 189–201: table row/cell colors (Tailwind slate). |
| `instances/EventJsonExpandable.tsx` | 3 | 3 distinct | `#334155` label, `#f8fafc` bg, `#e2e8f0` border. |
| `instances/HistoryScrubber.tsx` | 13 | ~9 distinct | `#10b981` (completed), `#3b82f6` (active), `#1f2937` (tooltip bg), `#f3f4f6` (tooltip text). |
| `instances/ProcessGraphWithTokens.tsx` | 8 | ~7 distinct | Line 76: Background component `color="#e2e8f0"` (see §3.3). Lines 99–100, 206: dark tooltip. |
| `instances/TimelineFeed.tsx` | 5 | 4 distinct | `#dbeafe` timeline border, `#64748b` caption, `#cbd5e1` card border, `#fff` bg. |
| `instances/TimelineFeedItem.tsx` | 8 | ~7 distinct | `#0f172a` heading, `#475569` metadata text, `#f8fafc` code-block bg, `#e2e8f0` code-block border. |

---

## 6. Acceptance-criteria mapping

| AC | Design element covering it |
|---|---|
| AC-1: grep returns zero hits after migration | §3 mapping table accounts for all 55 distinct values across all 162 line-hits. Every value has either an exact token mapping, a nearest-match mapping with justified delta, or a new-token assignment. No literal is left unresolved. After the §5 tokens land, FRONTEND-DEV can replace 100% of occurrences. |
| AC-2: no file outside promotions/ and instances/ modified | §1.2 documents the constraint. The tokens.css / design-system.md modifications in §5 are explicitly classified as a prerequisite addendum, not unplanned scope. No other external file requires change. |
| AC-3: existing component test suite passes unchanged | No test file modifications are planned. All changes are string-value substitutions in inline `style={{}}` props. Component props, rendered structure, and logic are untouched. |
| AC-4: type-check, lint, test, guards pass | Replacing `'#fa5252'` with `'var(--color-error)'` is a `string` → `string` substitution; no TypeScript impact. The `literal-colour` guard (§1.3) does not catch JS-string hex values, so guards already pass; after migration the grep is also clean. |

---

## 7. Open questions

None that block this design from proceeding to CODE-DESIGN-VALIDATOR. All 55 values are resolved. The one judgment call — whether `#a61e4d` ("failed" state text) requires its own `--color-failure` token vs. mapping to `--color-error-dark` — is decided conservatively in favour of a new token, because the "failed" (system error) and "rejected" (human rejection) states are deliberately distinguishable in PromotionReviewStateMachine and collapsing them loses that distinction. CODE-DESIGN-VALIDATOR may override this to a nearest-match with noted delta if palette minimalism is preferred.
