# Design: ISS-0845 — frontend module-boundary ESLint rule (relative-import bypass + missing depends_on enforcement)

Severity: MAJOR. Stage S11. Amends nothing in code; addresses a gap in how
0039 D3's frontend check was implemented, not a change to D3 itself (see
"0039 amendment needed?" at the end).

## 1. Current state (verified in this tree, 2026-09-26)

- `web/.eslintrc.json` is eslintrc (not flat config) — `web/package.json` pins
  `"eslint": "^8.57.0"`, no `eslint.config.*` file exists. All syntax below is
  eslintrc `overrides`/`rules` syntax, valid on this version.
- Current rule (verbatim):
  ```json
  "no-restricted-imports": [
    "error",
    { "patterns": ["@/modules/**", "!@/modules/registry", "!@/modules/types"] }
  ]
  ```
  plus one override: `files: ["src/modules/registry.ts"]` turns the rule off
  entirely for the registry.
- `web/tsconfig.app.json` maps `"@/*": ["src/*"]`; `web/vite.config.ts` aliases
  `'@'` to `./src`. So `@/modules/exam/X` and `../modules/exam/X` (from
  `src/pages/`) name the same file — the alias form is caught, the relative
  form is not (confirmed by the issue's own probe).
- `web/src/modules/` currently holds exactly **one** real module, `exam`
  (`web/src/modules/exam/`), plus the two core files `registry.ts` and
  `types.ts`. `ModuleDefinition` (in `types.ts`) already has a real, live
  `depends_on?: string[]` field — not aspirational. `exam`'s own definition
  (`web/src/modules/exam/index.ts`) sets `depends_on: []`. This is the single
  source of truth this design reads from; it does not invent a second one.
- No prior test in this repo invokes the ESLint Node API (`grep -rln
  "ESLint" web/src` found nothing). `web/src/modules/__tests__/registry.test.ts`
  is the existing convention this design's test sits next to.
- 0039 D3 (exact wording): "**Frontend** — an ESLint `no-restricted-imports`
  rule with the same two rules for `web/src/modules/<id>/`, with
  `web/src/modules/registry.ts` as the one sanctioned importer of module
  code." D3 names the rule family (`no-restricted-imports`) and the two
  invariants (rule a, rule b) but does not specify glob syntax or how
  per-module `depends_on` is expressed in config — that is this design's job
  to fill in, within D3's wording.

## 2. Mechanism chosen

**Core ESLint `no-restricted-imports`, via `.eslintrc.json` `overrides`, no
new npm dependency.** `eslint-plugin-import` stays uninstalled; nothing in
`web/package.json`/`package-lock.json` changes. This is one of the two
directions the issue allows, and it is the one that keeps the config
declarative JSON (reviewable, no local rule module to maintain, no custom
AST walker).

### 2a. Rule (a) — no relative-path bypass

Replace the single global pattern list with one that also blocks relative
spellings, keeping the same negations. The `patterns` array is order-
sensitive (later `!`-entries negate earlier matches), so order is preserved
top level, alias-form, then relative-form:

```json
"no-restricted-imports": [
  "error",
  {
    "patterns": [
      "@/modules/**",
      "!@/modules/registry",
      "!@/modules/types",
      "**/modules/**",
      "!**/modules/registry",
      "!**/modules/types"
    ]
  }
]
```

Why `**/modules/**` (double-star both sides) and not `**/modules/*/**`: the
existing alias pattern `@/modules/**` already matches a single-segment import
like `@/modules/exam` (importing a module's own index/directory, no file
segment) — `**` in minimatch matches zero-or-more path segments. The relative
pattern must have the same reach, so it mirrors the same shape rather than
requiring a third segment. `no-restricted-imports` `patterns` match against
the **literal import-specifier text**, not the resolved file path — this is
why `**/modules/exam/ExamListPage` (relative) is currently invisible to a
rule that only lists `@/modules/**`, and why adding the relative-shaped
pattern closes it without needing path resolution.

This rule stays global (top-level `rules`, applies everywhere) — it is what
currently exists, just widened. The existing `registry.ts` override (rule off
entirely for that one file) is unchanged; it remains the one sanctioned
importer, satisfying rule (a)'s stated exception.

### 2b. Rule (b) — module-to-module `depends_on` enforcement

**Design gap found by CODE-DESIGN-VALIDATOR, fixed in this revision:** the
first draft of this override only widened the `modules`-anchored forms
(alias `@/modules/<id>/**`, and relative-climbed-all-the-way-out-then-back-in
`**/modules/<id>/**`). Both require the literal path segment `modules` to
appear in the import specifier. That literal is present when a **core** file
(outside `src/modules/`) reaches into a module — any relative path from
outside `src/modules/` into it necessarily spells out `modules/<id>/...`.
It is *not* present when one module reaches a **sibling** module: a file in
`src/modules/exam/` importing `src/modules/beta/Thing` via relative syntax
writes `../beta/Thing` (or `../../beta/Thing`, `../../../beta/Thing`, … one
more `../` per level the importing file sits below its own module root) —
never `../modules/beta/Thing`, because it never climbs out of
`src/modules/` in the first place. `no-restricted-imports`'s `patterns`
option matches the **literal specifier text only**; a pattern set built
entirely from `modules`-anchored forms is structurally blind to this
spelling, not just under-tested — confirmed empirically (see verification
note at the end of this section).

**Fix:** add a second, `modules`-literal-free pattern family, anchored on
the *target module's own directory name* instead of the `modules/` segment.
Minimatch's `**` (globstar) matches zero or more whole path segments,
including a run of `..` segments — so `**/beta/**` matches `../beta/Thing`,
`../../beta/Thing`, `../../../../beta/Thing`, *and* `@/modules/beta/Thing`,
regardless of how many `../` precede it or whether the alias is used. This
means one pattern per sibling module id — not one per (depth, spelling)
combination — covers the relative sibling-form at any nesting depth, and
overlaps (harmlessly) with what the alias-form patterns already catch.

One `overrides` entry **per real module directory**, `files:
["src/modules/<id>/**"]`, that fully replaces `no-restricted-imports` for
files under that module with a set that:
- allows the module's own subtree (self-import, both alias and relative
  spelling, at any nesting depth),
- allows `registry` and `types` (core, always reachable — rule (a)'s
  exception applies inside a module too, and modules read `types.ts` for
  `ModuleDefinition`),
- allows exactly the modules listed in that module's own
  `depends_on` (both spellings, any depth) — by construction, an allowed
  sibling id is simply left out of the deny list below; there is no
  separate negation to write for it,
- blocks every other `modules/*` path via the `modules`-anchored generic
  deny + negations (catches the alias form and the
  climb-all-the-way-out-then-back-in relative form), **and**
- blocks every *other* **registered** module id individually via a bare
  `**/<other-id>/**` deny pattern (catches the direct sibling-relative
  form) — this half cannot be a single generic wildcard. Minimatch has no
  way to express "any directory name except these known ones" without a
  literal anchor segment (`modules` serves that role for the first family);
  once that anchor is gone, the only way to say "not id X" is to enumerate
  every other id and deny each by name. This is genuinely required, not a
  simplification left for later — a module count of one today only means
  the per-module override in production currently omits this deny family
  outright (no other real module exists to enumerate); it is not optional
  once a second real module lands.

Because ESLint eslintrc cascades by **replacing** a rule's config for
matching files with what a later, more specific `overrides` entry declares
(it does not array-merge two `no-restricted-imports` configs), each
per-module override must be fully self-contained — it cannot just append a
`depends_on` allowance on top of the global rule.

Template, generalized for a module `id` with `depends_on: D`, given the full
set of other registered module ids `Others = REGISTERED_MODULES.map(id) -
{id}` (`registry`/`types` are core files, never part of `Others`):

```json
{
  "files": ["src/modules/<id>/**"],
  "rules": {
    "no-restricted-imports": [
      "error",
      {
        "patterns": [
          "@/modules/*/**",
          "!@/modules/<id>/**",
          "!@/modules/registry",
          "!@/modules/types",
          "**/modules/*/**",
          "!**/modules/<id>/**",
          "!**/modules/registry",
          "!**/modules/types",
          "!@/modules/<dep>/**" /* one pair per dep in D — alias form */,
          "!**/modules/<dep>/**" /* one pair per dep in D — modules-anchored relative form */,
          "**/<other>/**" /* one entry per id in (Others - D) — bare sibling-relative + alias catch-all */
        ]
      }
    ]
  }
}
```

Concretely, for `exam` (`depends_on: []` today) with **no other real module
registered yet**, `Others` is empty, so the last pattern family has nothing
to enumerate — the override is unchanged from before this revision:

```json
{
  "files": ["src/modules/exam/**"],
  "rules": {
    "no-restricted-imports": [
      "error",
      {
        "patterns": [
          "@/modules/*/**",
          "!@/modules/exam/**",
          "!@/modules/registry",
          "!@/modules/types",
          "**/modules/*/**",
          "!**/modules/exam/**",
          "!**/modules/registry",
          "!**/modules/types"
        ]
      }
    ]
  }
}
```

This is *correct today only because `Others` is empty* — not because the
sibling-deny family is unnecessary in principle. §3's test table proves the
family works using a throwaway two-module fixture, since production has
nothing to prove it against yet.

If/when a second real module (e.g. `hr`) is registered alongside `exam`,
`exam`'s override must gain `"**/hr/**"` (`hr` is now in `Others`, not in
`exam`'s `depends_on`), and `hr`'s own new override must gain
`"**/exam/**"` symmetrically, unless one declares the other in
`depends_on` — in which case that side's alias+modules-anchored negation
pair is added instead of the bare deny entry, per the template above.

**Empirical verification of this fix:** re-running the exact probe
CODE-DESIGN-VALIDATOR used (throwaway `alpha`/`beta` fixture via ESLint's
`overrideConfig`, `alpha`'s override built from the template above with
`depends_on: []` and `Others = ["beta"]`, so `"**/beta/**"` is added) shows
both `import X from '@/modules/beta/Thing'` and `import X from
'../beta/Thing'` from `src/modules/alpha/Probe.tsx` now flagged with
`no-restricted-imports`, where before this revision only the alias form was
caught. Deep nesting (`import X from '../../../../beta/Thing'` from a file
four levels under `src/modules/alpha/`) is also flagged — confirms the
globstar reach is depth-independent. Symmetrically, once `beta` is added to
`alpha`'s `depends_on` (and correspondingly dropped from the deny
enumeration), both spellings — including the same four-level-deep relative
form — are allowed, and a same-module self-import (`../alpha/SiblingFile`)
is unaffected in either state.

**Hand-maintained, not generated** — reasoning: exactly one module exists
today, adding an override entry is a two-line JSON diff, and a generator
script would itself be a new build step with its own drift risk (does it run
in CI? on every lint? is its output checked in or produced fresh?) for a
problem that a **test**, not a build tool, already catches better (§2c).
Revisit "generate it" only if the module count grows enough that hand-editing
becomes the actual bottleneck — not decided here, flagged as an open
question in §5.

### 2c. Drift check (hand-maintained config vs. real `depends_on`)

A dedicated vitest test, `web/src/modules/__tests__/boundary-config.test.ts`
(separate from the lint-behavior test in §3, so a config-drift failure and a
lint-behavior failure are never conflated in one report):

- Reads `web/.eslintrc.json` from disk (`fs.readFileSync` + `JSON.parse` —
  data, not code) and extracts every `overrides` entry whose `files` glob
  matches `src/modules/<id>/**` (module id parsed out of the glob).
- Imports `REGISTERED_MODULES` from `../registry` (the real, live module
  list) and reads each entry's `id` and `depends_on`.
- Asserts, per registered module: an override exists for that module id, and
  the set of module ids its negated patterns allow (parsed back out of the
  `patterns` array: strip `!`, strip the `@/modules/`/`**/modules/` prefix
  and trailing `/**`, drop `registry`/`types`) equals exactly `{id} ∪
  (depends_on ?? [])`.
- **New in this revision:** also asserts the bare `**/<other>/**`
  sibling-deny family (§2b) is complete and exact — parses out every
  un-negated, `modules`-literal-free `**/<x>/**` pattern in the module's
  override, and checks that set equals exactly `Others - depends_on` (every
  other registered module id not covered by an allow, no more, no fewer). A
  module that gains a new sibling and forgets to add its deny entry, or one
  whose deny entry lists a since-deregistered module id, fails here.
- Asserts the reverse too: no `overrides` entry names a module id that is not
  in `REGISTERED_MODULES` (catches a module removed from the registry whose
  stale override was left behind).

This is what "catches drift" concretely — a config author who adds `"hr"` to
`exam`'s `depends_on` in `index.ts` but forgets the matching `.eslintrc.json`
negation fails this test on the next `npm test`, before it fails a build or
(worse) silently ships a bypassable boundary.

## 3. Lint-behavior test (AC1)

`web/src/modules/__tests__/boundary-lint.test.ts`, using the ESLint Node API
(`ESLint#lintText` with `filePath`), per the issue's own direction. Eight
probe cases (widened from six in this revision — see cases 3b/6b below,
added to close the exact gap CODE-DESIGN-VALIDATOR found). Cases 1, 2, 4, 5
exercise the **real, shipped** `.eslintrc.json` against the real `exam`
module and real `registry.ts` — no fixture files, no config duplication, so
a pass genuinely proves the shipped tree behaves. Cases 3, 3b, 6, 6b need a
*second* module and a *declared* dependency to prove rule (b) generalizes
beyond the single-module, empty-`depends_on` state `exam` is in today; since
inventing a second real module directory only to lint-test it would be scope
creep, these cases use the ESLint Node API's own `overrideConfig` layering
(an `ESLint` instance's `overrideConfig` merges on top of whatever
`.eslintrc.json` it finds via `cwd`, at the highest precedence — this is a
documented Node-API composition feature, not a production config change) to
add two throwaway module overrides (`alpha` depends on `beta`; `beta`
depends on nothing), each built from §2b's full template (both the
`modules`-anchored family and the bare sibling-deny family) that exist only
inside that one test's ESLint instance. Nothing under `web/src/modules/`
gains an `alpha` or `beta` directory; the `filePath` passed to `lintText`
need not exist on disk for `no-restricted-imports` to evaluate (it does not
touch the filesystem).

| # | Case | `filePath` | import specifier under test | ESLint instance | Expected |
|---|---|---|---|---|---|
| 1 | core → module, relative | `src/pages/Probe.tsx` | `import X from '../modules/exam/ExamListPage'` | real config | 1 error, `no-restricted-imports` |
| 2 | core → module, alias | `src/pages/Probe.tsx` | `import X from '@/modules/exam/ExamListPage'` | real config | 1 error, `no-restricted-imports` (regression guard — already passed before this fix) |
| 3 | module a → module b, alias form, b not in a's `depends_on` | `src/modules/alpha/Probe.tsx` | `import X from '@/modules/beta/Thing'` where `alpha`'s test-only `depends_on` is `[]` | real config + throwaway `overrideConfig` for `alpha`/`beta` | 1 error, `no-restricted-imports` |
| 3b | module a → module b, **relative** form, b not in a's `depends_on` — the exact bypass CODE-DESIGN-VALIDATOR found | `src/modules/alpha/Probe.tsx` | `import X from '../beta/Thing'` where `alpha`'s test-only `depends_on` is `[]` | real config + throwaway `overrideConfig` for `alpha`/`beta` | 1 error, `no-restricted-imports` |
| 4 | `registry.ts` → module index, allowed | `src/modules/registry.ts` | `import { examModuleDefinition } from './exam/index'` | real config | 0 errors |
| 5 | module → core, allowed | `src/modules/exam/Probe.tsx` | `import { ModuleGuard } from '@/components/routing/ModuleGuard'` | real config | 0 errors |
| 6 | module a → module b, alias form, b declared in a's `depends_on` | `src/modules/alpha/Probe.tsx` | `import X from '@/modules/beta/Thing'` where `alpha`'s test-only `depends_on` is `['beta']` | real config + throwaway `overrideConfig` for `alpha`/`beta` (dependency direction flipped from case 3) | 0 errors |
| 6b | module a → module b, **relative** form, b declared in a's `depends_on` | `src/modules/alpha/Probe.tsx` | `import X from '../beta/Thing'` where `alpha`'s test-only `depends_on` is `['beta']` | real config + throwaway `overrideConfig` for `alpha`/`beta` | 0 errors |

Each case: instantiate `ESLint` with `cwd` pointed at `web/`, call
`lintText(<the one-line import statement + a trailing no-op statement so the
file parses>, { filePath })`, then assert against the returned
`results[0].messages` — for a "flagged" case, exactly one message with
`ruleId === 'no-restricted-imports'`; for an "allowed" case, an empty
`messages` array. (This table specifies inputs/outputs only; the actual
`describe`/`it` bodies and assertion code are FRONTEND-DEV's to write, per
TEST-DESIGNER's test spec, once this design passes CODE-DESIGN-VALIDATOR.)

Cases 3/3b and 6/6b sharing one throwaway two-module fixture (opposite
`depends_on` direction, alias vs. relative spelling) is deliberate: it is the
minimal fixture that proves all four corners of rule (b) — undeclared vs.
declared, crossed with alias-form vs. relative-form — without needing
separate synthetic pairs per corner. 3b in particular is not a
nice-to-have: it is the literal reproduction of CODE-DESIGN-VALIDATOR's
finding, and a design revision that fixed §2b without adding it to the test
table would leave the exact regression it found unguarded.

**Empirical re-verification of this table's premise (done directly, ahead of
FRONTEND-DEV writing the actual test file):** re-ran the alpha/beta
`overrideConfig` fixture described above, built from §2b's revised template,
against both spellings of case 3b/6b. Result: alias form
(`@/modules/beta/Thing`) and relative form (`../beta/Thing`) are BOTH flagged
when `beta ∉ alpha.depends_on`, and BOTH allowed when `beta ∈
alpha.depends_on` — including a deep-nesting variant
(`../../../../beta/Thing` from a file four directories under
`src/modules/alpha/`), confirming the globstar-based sibling-deny pattern is
depth-independent, not merely depth-1-lucky. Full command/output quoted in
§2b's verification note and reproduced in this design's companion probe
scripts (not checked into the repo — throwaway, per the issue's own
direction on how to prove this without inventing a real second module).

## 4. Acceptance-criteria traceability

| AC | Requirement | Design element that satisfies it |
|---|---|---|
| AC1 | Probe cases via ESLint Node API, `lintText`+`filePath`, all pass; output quoted | §3 table — eight cases (widened from six in this revision to add 3b/6b, the relative-form module-to-module cases CODE-DESIGN-VALIDATOR found missing) specified with exact `filePath`, import specifier, and expected `messages` shape. FRONTEND-DEV writes `web/src/modules/__tests__/boundary-lint.test.ts` to this table; TEST-RUNNER quotes the actual `npm test` / vitest output. |
| AC2 | `npm run lint` passes in `web/` on resulting tree | §2a widens the global `no-restricted-imports` pattern list; §2b adds one `overrides` entry (currently just `exam`, `depends_on: []`, so it forbids all other modules — none exist yet, so no false positive). No existing file in the tree uses a relative cross-module or core-into-module import today (only the `exam` module exists, and its own internal files only reference each other via same-directory relative paths, which never contain a `modules/` segment) — FRONTEND-DEV must run `npm run lint` after applying §2a/§2b and quote the result per AC2; this design does not claim it in advance. |
| AC3 | `git diff main -- web/package.json web/package-lock.json` empty | §2 mechanism is `.eslintrc.json`-only (data changes); no package is added, no version is bumped. FRONTEND-DEV runs the exact `git diff` command from the issue and quotes it (expected: empty output). |
| AC4 | 0039 amendment + REVIEWER sign-off if mechanism deviates from D3's wording | §5 below — reasoned "no" with the specific wording comparison. |

## 5. Does this need a 0039 amendment? (AC4)

**No amendment.** D3's frontend sentence is: "an ESLint `no-restricted-imports`
rule with the same two rules for `web/src/modules/<id>/`, with
`web/src/modules/registry.ts` as the one sanctioned importer of module
code." This design:
- uses `no-restricted-imports` (unchanged rule family — not
  `import/no-restricted-paths`, not a custom local ESLint rule module),
- implements exactly the "same two rules" D3 names (rule a and rule b) —
  today's tree implements only rule (a), and only its alias-import half; this
  design completes what D3 already specified but ISS-0845 found half-built,
- keeps `registry.ts` as the one sanctioned importer (unchanged — same
  override, same file).

D3 does not specify glob syntax, `overrides` structure, or how per-module
`depends_on` is expressed in ESLint config — it leaves "how" to the
implementer, the same way the backend half of D3 names `mix xref graph
--format plain` as the mechanism but leaves the exact CLI invocation and
output-parsing to `ELIXIR-DEV`/`ISSUE-FIXER`. Filling in an unspecified "how"
inside an already-decided "what" is implementation, not a decision reversal.
If `CODE-DESIGN-VALIDATOR` or `REVIEWER` judges the per-module `overrides`
shape (§2b) to be a big enough structural choice to warrant recording, the
right home is a short addendum under D3 documenting the `overrides`-per-
module pattern for future module authors to follow — not a re-decision of
D3's substance. This design does not add that addendum itself (out of scope
for a design doc; it would be a docs/DOC-UPDATER action after REVIEWER
agrees it's warranted), and flags it as an open question below rather than
silently deciding "no addendum, ever."

## 6. Invariants

- Rule (a): every file outside `web/src/modules/<id>/` that imports a path
  whose specifier (alias or relative) resolves under `web/src/modules/<id>/`
  is rejected, except `web/src/modules/registry.ts` and except imports of
  `web/src/modules/registry.ts` / `web/src/modules/types.ts` themselves from
  anywhere (those two files are core, not "a module").
- Rule (b): a file under `web/src/modules/<id>/` that imports a path under
  `web/src/modules/<other>/` is rejected unless `other === id` or `other` is
  listed in `id`'s own `ModuleDefinition.depends_on` — **regardless of
  spelling**: this holds for the alias form (`@/modules/<other>/...`), the
  climb-all-the-way-out-then-back-in relative form
  (`../../modules/<other>/...`), and the direct sibling-relative form
  (`../<other>/...`, `../../<other>/...`, … at any nesting depth the
  importing file happens to sit at inside its own module directory) alike.
  The first draft of this design only enforced the first two spellings; the
  direct sibling-relative form is closed by the bare `**/<other-id>/**`
  pattern family in §2b, which — because it has no `modules`-literal anchor
  to rely on — must enumerate every other **registered** module id
  individually rather than express "any other module" as a single generic
  wildcard.
- The `.eslintrc.json` `overrides` list and `REGISTERED_MODULES[*].depends_on`
  never disagree — enforced by §2c's test, not by convention.
- No new runtime or dev dependency is introduced (Stage-11 hard constraint 3).

## 7. Cross-module / cross-file dependencies

- `web/.eslintrc.json` — the only file this design changes for the fix
  itself (widened global rule + one `overrides` entry per real module
  directory; today that's one entry, for `exam`).
- `web/src/modules/types.ts` (`ModuleDefinition.depends_on`) — read by the
  new drift test (§2c); not modified.
- `web/src/modules/registry.ts` (`REGISTERED_MODULES`) — read by the drift
  test to get the live module id list; not modified.
- New test files: `web/src/modules/__tests__/boundary-lint.test.ts` (§3),
  `web/src/modules/__tests__/boundary-config.test.ts` (§2c).
- No backend (`lib/letflow/`) file is touched — this issue is frontend-only.

## 8. Open questions

1. Whether the per-module `overrides`-in-`.eslintrc.json` pattern should be
   documented as a short addendum under 0039 D3 for future module authors
   (see §5) — left to `CODE-DESIGN-VALIDATOR`/`REVIEWER` to decide whether
   it rises to that bar; this design does not assume either answer.
2. If the module count grows past a handful, hand-maintaining one `overrides`
   block per module may become the actual bottleneck the issue's "generated
   or hand-maintained" question anticipated — not a problem today (one
   module), flagged for whoever adds the second real module to reassess,
   not resolved here.
3. `no-restricted-imports`'s `patterns` array only inspects the **literal
   import-specifier text**, never the resolved file path. A theoretical
   third spelling that also currently bypasses rule (a) unaddressed by this
   design: a dynamic `import(computedPath)` where `computedPath` is built at
   runtime from a template string (e.g. `` import(`../modules/${id}/index`) ``)
   is invisible to any static ESLint text-pattern rule, static or
   dynamic-relative alike. This mirrors the backend's own accepted limit
   (D3: "xref does not see `apply/3` or string-built module names") and is
   not solvable inside "no new npm dependency" + "no local custom rule" —
   flagged, not fixed, consistent with how the backend check already accepts
   the analogous gap.
