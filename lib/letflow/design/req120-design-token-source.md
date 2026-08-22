# REQ-120 — Settle the design-token question: one token source

**Run:** WF02-REQ120-20260822 · **Step:** 1 (CODE-DESIGNER) · **Requirement:** REQ-120
(queue task 239, depends on REQ-119, done)

This is a design artefact. It contains no implementation code — no `.css`, `.ts`, or
`.tsx` file is written or edited by this requirement. It picks one of the three
approaches REQ-120 poses, states why, states what happens to the `literal-colour` guard
pattern, and sizes the follow-on implementation requirement from a real `grep`.

---

## 1. Decision: build `tokens.css`, migrate components to it in a follow-on requirement

**Chosen approach:** `docs/frontend/design-system.md` §2's `--color-neutral-*` /
`--color-brand-*` / semantic-token model becomes the one source of truth. Letflow builds
`web/src/styles/tokens.css` containing exactly the custom properties already specified in
`design-system.md` §2.1 and §2.2 (no new palette invented here), and a follow-on
requirement (drafted in §5 below) migrates `web/src/components/` from inline hex literals
to `var(--token-name)` references. `design-tokens/letflow.tokens.json` is **not** adopted
as the source (§3). Inline styles are **not** accepted as the standing approach (§3).

This is not a pros/cons list — the other two paths are named and rejected in §3, and this
section states the affirmative reason this one wins: `design-system.md` §2 is the only one
of the three positions that is both complete (base palette **and** semantic surface/text/
border/interactive tokens, §2.1–§2.2) and already the documented spec developers are told
to follow. Building it doesn't ask the codebase to adopt a new document — it asks the
codebase to catch up to the one that already exists and is cited elsewhere (`web/README.md`
"Known drift", `docs/guides/frontend_developer_guide.md`).

**Structural evidence this was already the intended design, not a new choice imposed here:**
`web/tests/guards/forbidlist.ts`'s `literal-colour` pattern already carries
`allowedPaths: ['web/src/styles/tokens.css']` — a guard exemption for a file that, until
this requirement, did not exist. The guard was written assuming `tokens.css` would be the
one legitimate place raw color literals live. This decision fulfills that assumption rather
than inventing a new one.

---

## 2. What ships in THIS requirement (design + decision only)

- This design artefact.
- `docs/frontend/design-system.md` §2's "Not yet implemented" preamble (added by REQ-119)
  is superseded by a short status line: `tokens.css` is now the recorded target, build
  tracked by the follow-on requirement in §5 — no palette values in §2.1/§2.2 change, since
  they are already the chosen source.
- `web/README.md`'s "Known drift" entry for REQ-120 (currently "not yet resolved") is
  updated to state the decision and point at the follow-on requirement's id once
  REQ-VALIDATOR assigns one — DOC-UPDATER's job at Step 6 of this run, not this design step.
- `design-tokens/letflow.tokens.json`'s disposition is *decided* here (§3: not adopted,
  superseded, slated for deletion) but the file itself is deleted by the follow-on
  requirement, not this one — deleting it is a `design-tokens/` change, not a
  `web/src/components/` change, but bundling it with the component migration keeps one PR
  responsible for the whole "old positions are gone" claim instead of leaving a dangling
  stub between two requirements.
- No file under `web/src/` is created or modified. No file under `web/src/components/` is
  touched. `web/tests/guards/forbidlist.ts` is not edited by this requirement — §4 states
  the target change; the follow-on requirement makes it.

## 3. Why the other two positions lose, by name

**(1) `docs/frontend/design-system.md` §2 / `web/src/styles/tokens.css`** — this is the
**winning** position, not a loser; restated here only to complete the "reasons about all
three by name" requirement. Its palette (11-step neutral scale, 4-step brand scale,
4 semantic families × light/base/dark, plus a full semantic-surface layer: `--surface-*`,
`--text-*`, `--border-*`, `--interactive-*`) is the only one of the three with enough
resolution to skin the actual component set (status badges, focus rings, disabled states,
sidebar surfaces) without inventing new tokens on the fly during migration.

**(2) `design-tokens/letflow.tokens.json`** — **not adopted.** Read in full for this
decision:

```json
{
  "colors": {
    "background": "#FFFFFF", "surface": "#F5F5F5", "border": "#D4D4D4",
    "text-primary": "#111111", "text-secondary": "#555555",
    "primary": "#2563EB", "success": "#16A34A", "warning": "#D97706", "danger": "#DC2626"
  },
  "fonts": { "sans": { "family": "Inter", "weights": ["400","500","600","700"] } }
}
```

Nine flat color entries, no neutral scale (no way to express `--color-neutral-100` vs.
`-900` distinctions used throughout the codebase for surfaces/borders/disabled text), no
light/dark variants per semantic color (design-system.md's `--success-light` /
`--success` / `--success-dark` three-step families have no counterpart here — a single
`"success": "#16A34A"` cannot serve both a status-pill background and its border), and a
**different hex value for the same semantic role** where they do overlap (`primary:
#2563EB` here vs. `--color-brand-600: #228be6` in design-system.md — not a rounding
difference, a different blue). It is also, per REQ-120's own framing and confirmed by grep
during this design step, wired into zero source files, zero tests, and zero build steps
(`grep -rn "letflow.tokens" web/ package.json` outside `docs/` returns nothing). Adopting
it as the source would mean re-deriving the semantic-surface layer from scratch anyway
(§2.2 has no analogue in the JSON file) while discarding the richer, already-written
neutral scale — net loss, not net gain. Verdict: superseded, not adopted; deletion is
in the follow-on requirement's scope (§5).

**(3) Inline `style={{...}}` literal hex values** — **not accepted as the standing
approach.** Rejected on three grounds: (a) it is not a design system at all — "use
whatever hex value the component author typed" has no notion of a semantic token, so two
components can and do use visually-different reds for the same "error" meaning with no
mechanism to notice; (b) the `literal-colour` guard pattern exists specifically to forbid
raw color literals outside `tokens.css` (its `rationale: CMP-UI-06` and its
`allowedPaths` exemption for exactly that one file) — accepting inline styles as policy
would mean rewriting the guard's own stated rationale to "raw literals are fine
everywhere," which is a strictly worse invariant than either of the other two paths, not
a neutral one; (c) it is the status quo that created this requirement in the first place
— accepting it doesn't close the "design system claims enforcement it doesn't have" gap
the requirement names, it ratifies the gap.

---

## 4. The `literal-colour` guard pattern under this decision

**Current state** (`web/tests/guards/forbidlist.ts`, pattern `literal-colour`):

```
regex: /#[0-9a-fA-F]{3,8}\b(?=[^'";\n]*;)|.../
appliesTo: 'both'
allowedPaths: ['web/src/styles/tokens.css']
```

It only matches a hex/`rgba()`/`hsla()` literal that is followed, on the same line, by a
bare `;` before any quote/newline — i.e. a CSS-style declaration. An inline JSX prop like
`style={{ color: '#fa5252' }}` ends the literal with `'` then `}}`, never a bare `;`, so it
does not match. This is exactly the gap REQ-120 names: `tokens.css` is the one place raw
literals are *allowed*, but nothing currently stops them from also appearing everywhere
else in JS/TSX source.

**Target state, once the follow-on requirement lands:** the pattern's intent changes from
"catch a semicolon-terminated CSS declaration" to "catch a raw color literal anywhere in
JS/TSX source outside `tokens.css`, however it is written." Concretely, the follow-on
requirement's implementer:

- Drops the semicolon-lookahead requirement for the `'source'` half of the check (CSS
  files are gone under this decision — `tokens.css` is the only `.css` file in the tree
  and is already `allowedPaths`-exempt, so a plain `#[0-9a-fA-F]{3,8}\b` /
  `rgba?\(...\)` / `hsla?\(...\)` match against any `.ts`/`.tsx` file becomes safe to
  enable without the lookahead's original purpose of not-matching JS string literals that
  happened to contain a `#`).
- Keeps `allowedPaths: ['web/src/styles/tokens.css']` — unchanged, that exemption is still
  correct and now finally exercised by a real file.
- Adds a narrow additional exemption only if the migration finds a genuine non-token
  case (e.g. a third-party library requiring an inline literal it doesn't expose as a
  CSS variable) — the follow-on requirement's design step, not this one, decides that if
  and when it's found; no such case is known today.
- This is a **behavior change to an existing guard pattern**, which
  `docs/agents/workflows/WF-02_requirement_implementation.md` Step 2b explicitly flags
  ("Do NOT weaken a pattern in `forbidlist.ts` to make a change pass") — note for the
  follow-on requirement's FRONTEND-DEV: this is the opposite direction, *tightening* the
  pattern to catch more, and is the requirement's own stated purpose, not an
  end-run around a failing gate.

`docs/frontend/design-system.md` §2's line "All colors are defined as CSS custom
properties in `web/src/styles/tokens.css`. Never use raw hex/rgb values outside this
file." stops being aspirational and becomes an accurate statement of both the code and
the enforcement once the follow-on requirement lands — no further doc correction needed
at that point beyond what DOC-UPDATER already does in Step 6 of *this* run (§2).

---

## 5. Follow-on requirement (drafted, not registered — impl_order: UNREGISTERED)

Drafted directly into `docs/requirements.yaml` per this run's Step Final instructions, for
routing through REQ-VALIDATOR before a queue slot is assigned. Summarized here for the
design record:

**Title:** Build `web/src/styles/tokens.css` and migrate `web/src/components/` off inline
hex literals

**Real scope, from grep (run against this worktree, 2026-08-22):**

```
$ grep -rEln "#[0-9a-fA-F]{3,8}" web/src/components/ --include='*.tsx' --include='*.ts' | wc -l
47
$ grep -rEon "#[0-9a-fA-F]{3,8}" web/src/components/ --include='*.tsx' --include='*.ts' | wc -l
496
```

**47 files, 496 individual hex-literal occurrences** under `web/src/components/`. Full
file list captured in this run's handoff for the follow-on requirement's CODE-DESIGNER to
re-verify against the tree at implementation time (counts may drift between this design
step and that requirement's start).

**Scope for that requirement:**
1. Create `web/src/styles/tokens.css` with the custom properties already specified in
   `design-system.md` §2.1–§2.2 (copy, not invent).
2. Import it once (`web/src/main.tsx` or equivalent app entry point — that requirement's
   own design step picks the exact import site).
3. Migrate all 47 files' inline hex literals to the matching `var(--token-name)`, adding
   any token `design-system.md` doesn't yet cover as a design-step addendum (not silently
   during implementation).
4. Delete `design-tokens/letflow.tokens.json` (superseded per §3 above) and its
   `web/README.md` "Known drift" entry.
5. Tighten the `literal-colour` guard pattern per §4 above.
6. Update `web/README.md`'s "No stylesheet exists" drift entry to record resolution.

This is a large, mechanical, component-touching change — correctly out of scope for
REQ-120 itself per REQ-120's own acceptance criteria ("no component under
`web/src/components/` is modified by this requirement").

---

## 6. Open questions

- Some of the 496 occurrences may be non-color hex-like tokens (e.g. hash fragments in
  URLs, non-color `#` usage) — the grep pattern is a coarse superset. The follow-on
  requirement's own design step should re-derive the true color-literal count against the
  actual tree, not carry this document's number forward verbatim, per this project's own
  "recount every time" convention seen elsewhere in the run-history index.
- Whether any of the 47 files need a *new* token (a color used nowhere in
  `design-system.md`'s current palette) is not knowable without doing the migration —
  flagged for the follow-on requirement's CODE-DESIGNER, not resolved here.
- Whether `design-tokens/letflow.tokens.json`'s existence implies an intended non-web
  consumer (e.g. a design-tool import format) was checked: no reference to it exists
  anywhere in `docs/`, `web/`, or `package.json` outside `docs/frontend/design-system.md`'s
  own mention of the three positions and `docs/requirements.yaml`/`docs/status/` — no
  evidence of an intended consumer was found, so §3's "supersede and delete" verdict
  stands without qualification.

---

## 7. Acceptance-criteria mapping

| Acceptance criterion | Where addressed |
|---|---|
| Design artefact under `lib/letflow/design/` naming one approach explicitly | §1 |
| Decision reasons about all three positions by name, including why the JSON file is/isn't adopted | §3 |
| States what happens to the `literal-colour` guard pattern | §4 |
| Follow-on requirement drafted with scope and a real grep count if component changes are implied | §5 |
| No component under `web/src/components/` modified by this requirement | §2 (stated), confirmed via `git diff` at Step Final |
