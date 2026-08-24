# Design: REQ-146 — Delete design-tokens/letflow.tokens.json, tighten literal-colour guard, resolve README drift

**Owner:** FRONTEND-DEV  
**Stage:** S8  
**Depends on:** REQ-142, REQ-143, REQ-144, REQ-145 (all component-migration requirements — must be fully landed before this guard is tightened)

---

## 1. Scope

Five concrete changes, no new palette tokens, no backend code:

| # | Change | File(s) affected |
|---|--------|-----------------|
| A | Update `literal-colour` regex (drop semicolon-lookahead) | `web/tests/guards/forbidlist.ts` |
| B | Replace offender fixture with inline-style case | `web/tests/guards/fixtures/offender/literal-colour.txt` |
| C | Resolve "No stylesheet exists" drift entry | `web/README.md` |
| D | Resolve "design-tokens/letflow.tokens.json is wired to nothing" drift entry | `web/README.md` |
| E | Delete superseded token file | `design-tokens/letflow.tokens.json` |

No changes to `meta-control.spec.ts`, `source-scan.spec.ts`, `bundle-scan.spec.ts`, or `bystander/literal-colour.txt` — existing structure handles the updated fixture automatically.

---

## 2. Pre-condition verification (AC-5)

Before applying the tightened guard, FRONTEND-DEV **must** run:

```
grep -rEon "#[0-9a-fA-F]{3,8}" web/src/components/ --include='*.tsx' --include='*.ts'
```

Expected: zero output. If any line is returned that is not inside a `//` or `/* */` comment, the component-migration requirements (REQ-142..145) have not fully landed and this requirement must not proceed. The AC says pre-verified: 0 hits; re-verify at implementation time because the count can drift between design and implementation.

---

## 3. Change A — `literal-colour` regex in `web/tests/guards/forbidlist.ts`

### 3.1 Current regex (exact, from forbidlist.ts lines 51–57)

```js
regex: /#[0-9a-fA-F]{3,8}\b(?=[^'";\n]*;)|(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)(?=[^'";\n]*;)|(?<![.a-zA-Z0-9_$])hsla?\([^)]+\)(?=[^'";\n]*;)/,
```

The comment block above it reads:
> "Catches unquoted CSS colour literals: hex or rgba()/hsl() followed by `;` on same line.  
> JS inline-style strings end with `'` not `;` so they don't match."

The three lookaheads `(?=[^'";\n]*;)` are the **only** thing preventing `style={{ color: '#fa5252' }}` from being caught: the `'` immediately after the hex is in the excluded character class `[^'";\n]`, so the lookahead fails.

### 3.2 Proposed new regex

Per REQ-120 design §4 ("drops the semicolon-lookahead requirement"):

```js
regex: /#[0-9a-fA-F]{3,8}\b|(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)|(?<![.a-zA-Z0-9_$])hsla?\([^)]+\)/,
```

**What changed:** the `(?=[^'";\n]*;)` lookahead is removed from all three arms. The word boundary `\b` and the negative lookbehind on the `rgba?`/`hsla?` arms are retained unchanged.

**Side-by-side:**

```
OLD: /#[0-9a-fA-F]{3,8}\b(?=[^'";\n]*;)|(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)(?=[^'";\n]*;)|(?<![.a-zA-Z0-9_$])hsla?\([^)]+\)(?=[^'";\n]*;)/
NEW: /#[0-9a-fA-F]{3,8}\b             |(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)              |(?<![.a-zA-Z0-9_$])hsla?\([^)]+\)/
```

### 3.3 Why dropping the lookahead is safe (req120 §4 rationale)

`tokens.css` is now the **only** `.css` file in the tree and is already `allowedPaths`-exempt. Every other file scanned by source-scan (`web/src/**/*.{ts,tsx,css}`) is a TypeScript file. Any raw `#hex`, `rgba(...)`, or `hsla(...)` in a `.ts`/`.tsx` file is a violation — there is no legitimate inline-CSS context remaining. The lookahead's original purpose was to avoid false-positive on JS string literals that happened to contain a `#`; that distinction is now irrelevant for the source half.

### 3.4 Updated comment block

Replace the existing four-line comment above the `literal-colour` entry:

```
// Catches raw colour literals anywhere in TS/TSX source and the built bundle.
// web/src/styles/tokens.css is allowedPaths-exempt — that is the one place raw hex values
// are permitted. Negative lookbehind on rgba?/hsla? prevents matching zero-arg calls from
// colour-manipulation libraries (e.g. `color.rgba()` method calls).
```

### 3.5 `allowedPaths` — unchanged

```js
allowedPaths: ['web/src/styles/tokens.css'],
```

No change. The exemption is still exercised (tokens.css exists and contains hex values), satisfying AC-4.

---

## 4. Change B — offender fixture (fail-first / pass-after)

### 4.1 Fixture file

`web/tests/guards/fixtures/offender/literal-colour.txt`

**Proposed new content** (replaces the current CSS-block content):

```
const style = { color: '#fa5252' };
```

This is a single-line JS/TSX inline style object with a raw hex literal — the exact pattern that AC-3 names.

### 4.2 Why the OLD regex fails against this fixture

```
regex: /#[0-9a-fA-F]{3,8}\b(?=[^'";\n]*;)|.../
```

Scanning `const style = { color: '#fa5252' };`:
- `#fa5252` is found (6 hex chars, `\b` satisfied after `2`).
- Lookahead `(?=[^'";\n]*;)` starts at the position immediately after `#fa5252`: next char is `'`.
- `[^'";\n]` is a character class that excludes `'`, `"`, `;`, `\n`. The next char `'` does **not** match this class → the zero-or-more `*` matches zero chars, but then `;` is required and the next char is `'`, not `;` → lookahead fails → no match.
- `rgba?` and `hsla?` arms: not present in the line → no match.
- **Result: `OLD_REGEX.test(content)` → `false`.**

The `meta-control.spec.ts` test `'regex matches offender'` would therefore **FAIL** when this fixture is in place and the old regex is still active — this is the expected fail-first state.

### 4.3 Why the NEW regex passes against this fixture

```
regex: /#[0-9a-fA-F]{3,8}\b|.../
```

Scanning `const style = { color: '#fa5252' };`:
- `#fa5252` is found, `\b` satisfied → **match**.
- **Result: `NEW_REGEX.test(content)` → `true`.**

The `meta-control.spec.ts` test `'regex matches offender'` passes — this is the expected pass-after state.

### 4.4 Bystander fixture — unchanged

`web/tests/guards/fixtures/bystander/literal-colour.txt` current content:

```
.button {
  color: var(--text-primary);
  background: var(--surface-page);
}
```

Contains no hex literals, no `rgba(...)`, no `hsla(...)`. Both old and new regex return `false` against this content. No change required.

### 4.5 meta-control.spec.ts — no changes required

`meta-control.spec.ts` iterates over `PATTERNS` by name and resolves the fixture path as `fixtures/offender/${pattern.name}.txt`. The file name stays `literal-colour.txt`. The test structure (exists + matches offender / does not match bystander) is unchanged — it already exercises the fail-first/pass-after behaviour through the fixture content.

---

## 5. Change C & D — `web/README.md` "Known drift" section

### 5.1 Entry 1 — "No stylesheet exists yet"

Current text begins at the bullet:

> **No stylesheet exists yet — decided by `REQ-120`, built by a follow-on requirement (`impl_order: UNREGISTERED`, pending `REQ-VALIDATOR`).**  
> `docs/frontend/design-system.md` §2 says all colours live as CSS custom properties in `web/src/styles/tokens.css`. That file does not exist…

FRONTEND-DEV must **remove this entire bullet** (it is multi-paragraph, ends just before the "Bundle size" entry). Replace with nothing — the entry is fully resolved: `tokens.css` exists (built by REQ-141/142/143/144/145), components no longer use inline hex, and the `literal-colour` guard now enforces the boundary. If FRONTEND-DEV wishes to leave a one-line resolved note for the record, acceptable form:

> - **No stylesheet exists — resolved by REQ-141..145** (tokens.css built, 47 component files migrated off inline hex). Guard enforcement completed by REQ-146.

Either full removal or the one-line resolved note satisfies AC-2. Full removal is preferred (the drift section is for live discrepancies).

### 5.2 Entry 2 — "design-tokens/letflow.tokens.json is wired to nothing"

Current text begins:

> **`design-tokens/letflow.tokens.json` is wired to nothing — superseded by `REQ-120`, deletion is the follow-on requirement's scope, not yet deleted.**  
> Carried over from R-Co's `design-tokens/r-co.tokens.json`. No source file, test, or build step reads it…

FRONTEND-DEV must **remove this entire bullet** (ends just before the end of the Known drift section). This is the final drift entry — after its removal the "Known drift" section will contain only "React version", "Bundle size", and "Orphaned UserDetailPage.tsx" entries (the React version entry is already marked resolved as a record). If FRONTEND-DEV wishes to leave a one-line note:

> - **design-tokens/letflow.tokens.json — deleted by REQ-146.** No replacement; design-system.md §2's palette is the source of truth.

---

## 6. Change E — Delete `design-tokens/letflow.tokens.json`

**File to delete:** `design-tokens/letflow.tokens.json` (workspace root level)

**Verification:** no source file, test file, or build script reads this file. Confirmed by:
- No import or require of the path in `web/src/`
- Not referenced in `web/package.json` scripts
- Not referenced in `vite.config.ts`
- Not referenced in any `web/tests/` file
- No Elixir source reads it (it was a frontend artefact only)

Delete with `git rm design-tokens/letflow.tokens.json` so the deletion is tracked.

---

## 7. Acceptance criteria map

| AC | Design element |
|----|---------------|
| AC-1: file no longer exists | Change E — `git rm design-tokens/letflow.tokens.json` |
| AC-2: both README drift entries removed/resolved | Changes C and D — remove the two bullets from "Known drift" |
| AC-3: guard catches inline style; fixture demonstrates fail-first/pass-after | Change A (new regex) + Change B (updated offender fixture); §4.2 and §4.3 show why old fails and new passes |
| AC-4: `tokens.css` allowedPaths exemption unchanged and exercised | §3.5 — exemption field left as-is; tokens.css exists with hex values, source-scan properly exempts it |
| AC-5: zero hex hits in components before tightening | §2 — pre-condition verification step; FRONTEND-DEV re-runs grep before changing forbidlist.ts |
| AC-6: all four npm commands pass | Source of truth is the actual CI run output; design assumes AC-5 is satisfied and all prior migration requirements are landed |

---

## 8. Open questions

### OQ-1: Does the bundle-scan also need changes or only source-scan?

**Current state:** `literal-colour` has `appliesTo: 'both'`, meaning the same regex runs against `dist/assets/*.js` after a Vite build. After dropping the lookahead, any hex literal in the built bundle (from any source, including third-party libraries) will trigger a violation.

**Recommendation:** proceed with `appliesTo: 'both'` unchanged, and run `npm run guards` (which runs bundle-scan) as part of AC-6 verification. If the new broad regex produces false positives from third-party library code in the bundle, the fix is one of:
- Add specific bundle chunk paths to `allowedPaths` (acceptable but fragile across Vite chunk hashing)
- OR keep the pattern at `appliesTo: 'source'` and accept that the bundle scan no longer catches this class of violation (weaker, not recommended)

No false positive from third-party code is expected because: Vite compiles CSS into separate `.css` files and injects them at runtime; raw hex in third-party JS is rare; the `rgba?`/`hsla?` negative lookbehind prevents method-call false positives. If bundle-scan fails, that is new information to bring back rather than a pre-decided outcome.

### OQ-2: Does rgba/hsla also need the JS-string extension?

Yes. The proposed new regex `(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)` already catches `rgba(255, 0, 0, 0.5)` in JS source without a semicolon, whether it appears in a CSS file or in a JS string like `style={{ color: 'rgba(255,0,0,0.5)' }}`. Dropping the semicolon-lookahead from all three arms covers hex, rgba, and hsla uniformly. No separate extension is needed.

### OQ-3: Does `meta-control.spec.ts` already have a fixture named `inline-style-literal` or is a new file needed?

The fixture directory listing (`web/tests/guards/fixtures/offender/`) contains `literal-colour.txt` — no separate `inline-style-literal.txt` exists, and none should be created. The meta-control architecture has exactly one offender and one bystander per pattern name. The existing `literal-colour.txt` files are updated in place. No new test file, no new pattern entry, no changes to `meta-control.spec.ts`.

### OQ-4: Should the `tokens.css` comment in forbidlist.ts mention that the lookahead was dropped intentionally?

Recommendation: yes — the updated comment in §3.4 above makes this explicit. Without it, a future reader might mistake the absence of the lookahead for an oversight and re-add it.
