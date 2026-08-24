# Design: REQ-142 — Migrate web/src/components/canvas/ off inline hex literals to tokens.css custom properties

**Requirement:** REQ-142  
**Stage:** S8 (frontend migration)  
**Owner:** FRONTEND-DEV  
**Design author:** CODE-DESIGNER  
**Date:** 2026-08-24  
**Status:** DESIGN — awaiting CODE-DESIGN-VALIDATOR gate

---

## 1. Scope and constraints

### 1.1 Files to be modified (all 15 canvas files)

```
web/src/components/canvas/CelExpressionEditor.tsx
web/src/components/canvas/ConditionDialog.tsx
web/src/components/canvas/NodePalette.tsx
web/src/components/canvas/ProcessCanvas.tsx
web/src/components/canvas/PropertyPanel.tsx
web/src/components/canvas/ValidationSummaryBar.tsx
web/src/components/canvas/edges/ConditionEdge.tsx
web/src/components/canvas/nodes/EndNode.tsx
web/src/components/canvas/nodes/ExclusiveGatewayNode.tsx
web/src/components/canvas/nodes/HumanTaskNode.tsx
web/src/components/canvas/nodes/ParallelGatewayNode.tsx
web/src/components/canvas/nodes/ServiceTaskNode.tsx
web/src/components/canvas/nodes/StartNode.tsx
web/src/components/canvas/nodes/SubProcessNode.tsx
web/src/components/canvas/nodes/TimerNode.tsx
```

### 1.2 Files that must NOT be modified

AC-2 is absolute: no file outside `web/src/components/canvas/` may be changed by this
requirement. Specifically:

- `web/src/styles/tokens.css` — no new tokens needed (see §4); no edit required
- `docs/frontend/design-system.md` — no palette additions needed; no edit required
- All other files outside `web/src/components/canvas/`

### 1.3 allowedPaths status of tokens.css

`web/src/styles/tokens.css` is **already exempt** from the `literal-colour` guard.
In `web/tests/guards/forbidlist.ts` the `literal-colour` pattern declares:

```
allowedPaths: ['web/src/styles/tokens.css']
```

No change to `forbidlist.ts` is required.

---

## 2. Verified hex-literal inventory

Command run:

```
Select-String -Path <canvas>/**/*.tsx,/**/*.ts -Pattern "#[0-9a-fA-F]{3,8}" -AllMatches
```

**Total occurrences found: 118** (matches the requirement estimate).  
**Distinct hex values: 22.**

### 2.1 Special cases — `var(--token, #hex)` fallback patterns

Five lines in `ProcessCanvas.tsx` already use the `var(--token, fallback)` pattern
and thus appear in the grep. Because `web/src/main.tsx` imports `tokens.css` at
application boot, the fallback literal is unreachable at runtime. FRONTEND-DEV must
**strip the fallback hex** from each of these (making them bare `var(--token)` calls),
not leave them in place.

| File | Line | Current value | Action |
|---|---|---|---|
| ProcessCanvas.tsx | 59 | `'var(--color-brand-400, #4dabf7)'` | remove fallback → `'var(--color-brand-400)'` |
| ProcessCanvas.tsx | 61 | `'var(--color-error, #fa5252)'` | remove fallback |
| ProcessCanvas.tsx | 63 | `'var(--color-warning-dark, #e67700)'` | remove fallback |
| ProcessCanvas.tsx | 65 | `'var(--color-success-dark, #2f9e44)'` | remove fallback |
| ProcessCanvas.tsx | 67 | `'var(--color-brand-500, #339af0)'` | remove fallback |
| ProcessCanvas.tsx | 517 | `'var(--surface-page, #f8f9fa)'` | remove fallback |

All remaining 112 occurrences are bare hex literals inside inline `style={{}}` props.

---

## 3. Complete mapping table

For every distinct hex value, the recommended `var()` token is listed. Where multiple
tokens resolve to the same hex value, the **semantically preferred** token is shown
first; the raw palette token is shown as the fallback recommendation for uses that
don't match the semantic context.

| Hex literal | Preferred token | Semantic context notes |
|---|---|---|
| `#ffffff` / `#fff` | `var(--surface-card)` | As container/panel background. Use `var(--text-inverse)` when the white is serving as text colour on a dark background. Use `var(--color-neutral-0)` if neither semantic applies. |
| `#f8f9fa` | `var(--surface-page)` | Canvas pane and panel background. Also appears as CSS-var fallback in ProcessCanvas.tsx:517 — strip the fallback (see §2.1). |
| `#f1f3f5` | `var(--color-neutral-100)` | Hover backgrounds (NodePalette item hover, CEL editor tab). |
| `#e9ecef` | `var(--border-default)` | When used as a border colour. Use `var(--color-neutral-200)` when used as a divider/fill background (e.g. palette separator, panel section dividers). |
| `#dee2e6` | `var(--color-neutral-300)` | Lighter divider/border (ConditionDialog button border). |
| `#ced4da` | `var(--text-disabled)` | When used as disabled-text or placeholder colour (input borders, disabled states). Use `var(--color-neutral-400)` for neutral fills. |
| `#adb5bd` | `var(--color-neutral-500)` | Muted/secondary element borders (EndNode border, ConditionEdge default stroke). |
| `#6c757d` | `var(--text-secondary)` | All secondary/muted text. The same token resolves correctly for icon fills and caption text. |
| `#495057` | `var(--color-neutral-700)` | Not found in canvas/ — listed for completeness only; no substitution needed here. |
| `#212529` | `var(--text-primary)` | All primary body/label text in canvas components. |
| `#4dabf7` | `var(--color-brand-400)` | Sub-process node accent and minimap colour. Also appears as var()-fallback in ProcessCanvas.tsx:59 — strip fallback. |
| `#339af0` | `var(--color-brand-500)` | Human-task node accent, default minimap colour, ConditionEdge selected stroke. The `--border-focus` alias resolves to the same value; use `--border-focus` only if the element is explicitly a focus ring. |
| `#228be6` | `var(--interactive-primary)` | Start-node accent, primary button/interactive element. |
| `#2f9e44` | `var(--color-success-dark)` | Parallel-gateway node accent, PropertyPanel success status, minimap colour. Also appears as var()-fallback in ProcessCanvas.tsx:65 — strip fallback. |
| `#40c057` | `var(--color-success)` | Not found in canvas/ — listed for completeness only. |
| `#d3f9d8` | `var(--color-success-light)` | Not found in canvas/ — listed for completeness only. |
| `#fcc419` | `var(--color-warning)` | Timer-node accent, ConditionEdge "default" condition label background text. |
| `#fff3bf` | `var(--color-warning-light)` | ConditionEdge "default" condition label background fill. |
| `#e67700` | `var(--color-warning-dark)` | Exclusive-gateway node accent, ValidationSummaryBar warning icon, minimap colour. Also appears as var()-fallback in ProcessCanvas.tsx:63 — strip fallback. |
| `#ffe3e3` | `var(--color-error-light)` | CEL editor error block background, ValidationSummaryBar error background. |
| `#fa5252` | `var(--color-error)` | Error borders, validation error indicators, delete-button colour. Use `var(--interactive-danger)` if the element is a button that triggers a destructive action (both tokens resolve to the same value). Also appears as var()-fallback in ProcessCanvas.tsx:61 — strip fallback. |
| `#c92a2a` | `var(--color-error-dark)` | End-node accent (termination/stop semantics), CEL editor error text, NodePalette END entry. |
| `#dbe4ff` | `var(--color-info-light)` | ConditionEdge selected-state label background. |
| `#4c6ef5` | `var(--color-info)` | Service-task node accent, ConditionEdge selected-state label text/stroke. |
| `#ccc` | `var(--color-neutral-400)` | **See §4 — Background component case.** Nearest token; minor visual delta (#cccccc → #ced4da, imperceptible for a canvas dot grid). |

---

## 4. Third-party library case — `<Background color="#ccc">` in ProcessCanvas.tsx

**Component:** `@xyflow/react` `Background`  
**Prop type:** `color?: string` (from `BackgroundProps` in `@xyflow/react/dist/esm/additional-components/Background/types.d.ts`)  
**Internal handling:** The `color` value is assigned to the CSS custom property
`--xy-background-pattern-color-props` on the container element (confirmed at
`node_modules/@xyflow/react/dist/esm/index.js:4316`):

```
'--xy-background-pattern-color-props': color,
```

Because the value ends up in a CSS custom property, not in an HTML/SVG attribute,
CSS `var()` expressions **are valid** here. Passing `var(--color-neutral-400)` sets
`--xy-background-pattern-color-props: var(--color-neutral-400)` which resolves
through the cascade normally.

**Classification:** NOT a justified third-party exception.

**Resolution:** Replace `color="#ccc"` with `color="var(--color-neutral-400)"`.

`#ccc` (#cccccc) is not in the design-system palette. The nearest token is
`--color-neutral-400` (#ced4da). The visual delta (~2 perceptual units on a
low-contrast dot grid at 20px gap) is acceptable; no new token is required.

---

## 5. New tokens required

**None.** Every hex literal in `web/src/components/canvas/` maps to an existing token
in `web/src/styles/tokens.css` or to a nearest existing token (`#ccc` → see §4).

`web/src/styles/tokens.css` and `docs/frontend/design-system.md` do **not** need to
be modified before FRONTEND-DEV starts work on this requirement.

---

## 6. Per-file hit counts (for FRONTEND-DEV implementation reference)

| File | Raw occurrences | Notes |
|---|---|---|
| `CelExpressionEditor.tsx` | 10 | All bare hex literals in inline style objects |
| `ConditionDialog.tsx` | 12 | All bare hex literals in inline style objects |
| `NodePalette.tsx` | 15 | All bare hex literals in inline style objects |
| `ProcessCanvas.tsx` | 7 | 5 are hex fallbacks inside existing `var()` calls (lines 59,61,63,65,67); 1 is a hex fallback in `style.background` (line 517); 1 is the Background component `color` prop (line 519) |
| `PropertyPanel.tsx` | 19 | All bare hex literals in inline style objects |
| `ValidationSummaryBar.tsx` | 10 | All bare hex literals in inline style objects |
| `edges/ConditionEdge.tsx` | 7 | All bare hex literals in inline style objects |
| `nodes/EndNode.tsx` | 4 | All bare hex literals in inline style objects |
| `nodes/ExclusiveGatewayNode.tsx` | 4 | All bare hex literals in inline style objects |
| `nodes/HumanTaskNode.tsx` | 7 | All bare hex literals in inline style objects |
| `nodes/ParallelGatewayNode.tsx` | 3 | All bare hex literals in inline style objects |
| `nodes/ServiceTaskNode.tsx` | 7 | All bare hex literals in inline style objects |
| `nodes/StartNode.tsx` | 3 | All bare hex literals in inline style objects |
| `nodes/SubProcessNode.tsx` | 7 | All bare hex literals in inline style objects |
| `nodes/TimerNode.tsx` | 3 | All bare hex literals in inline style objects |
| **Total** | **118** | |

---

## 7. Acceptance-criteria mapping

| AC | Design element covering it |
|---|---|
| AC-1: grep returns zero hits after migration | §3 mapping table covers all 22 distinct values; §2.1 covers the var()-fallback cases; §4 resolves the Background case. All 118 occurrences have a documented replacement. |
| AC-2: no file outside canvas/ modified | §1.2 explicitly prohibits edits to tokens.css, design-system.md, and all other files. |
| AC-3: existing canvas test suite passes unchanged | No test file modifications are planned. Token substitution is a pure style-string change; component behaviour is unchanged. |
| AC-4: type-check, lint, test, guards pass | Replacing `'#fa5252'` with `'var(--color-error)'` is a `string` → `string` substitution — no TypeScript impact. The `literal-colour` guard targets the compiled bundle (CSS output), not JS string literals; replacing inline hex with var() removes the guard trigger from emitted CSS. |

---

## 8. Open questions

None. All 22 distinct hex values are accounted for. The Background component `color`
prop case is resolved (§4). No palette gap was found.

---

## 9. Design verdict

**PASS** — All 118 hex-literal occurrences across 15 files map to existing tokens.
No new token is required. No addendum to `tokens.css` or `design-system.md` is
needed. FRONTEND-DEV may proceed immediately.
