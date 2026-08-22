# REQ-115 — `npm run check`: a single fail-fast gate command for `web/`

Design artefact for WF-02 Step 1 (CODE-DESIGNER). This is a build-config change —
no new module, function, schema, or process. No implementation code appears below,
only the exact strings to add and their placement.

## Context read

- `web/package.json` `scripts` (current, verbatim):
  ```
  dev, build, preview, type-check, lint, test, test:watch, test:coverage, guards,
  test:e2e, test:e2e:list, test:e2e:obs04
  ```
- No cross-platform script-runner dependency exists in `web/package.json`
  (`dependencies` / `devDependencies` — checked in full): no `npm-run-all`,
  `concurrently`, `cross-env`, or similar. The existing scripts already assume a
  shell that understands `&&` (none currently chain, but this is the only
  compositing mechanism present in the repo's own conventions).
- Backend precedent: `mix.exs`'s `"letflow.check"` alias (lines 64–82) is a plain
  ordered list of task names. Mix aliases already stop at the first non-zero exit
  by default — no extra plumbing needed on the Elixir side. npm has no equivalent
  "alias that stops on first failure" primitive; the standard, dependency-free
  idiom for the same behavior in an npm `scripts` entry is shell `&&` chaining,
  since `&&` only runs the next command if the previous one exited 0.

## Design decision

### 1. New script in `web/package.json`

Add a `"check"` entry to `scripts`, using `&&` chaining over the four existing
script names named in the requirement, in the mandated order:

```
"check": "npm run type-check && npm run lint && npm run test && npm run guards"
```

Rationale for each element:
- `npm run type-check` first — cheapest, catches the most (per requirement text).
- `npm run lint` second.
- `npm run test` third — note: the existing unit-test script is named `"test"`,
  invoked here as `npm run test` (equivalent to bare `npm test`; `npm run test`
  is used for consistency with the other three `npm run <name>` invocations
  rather than mixing `npm test` and `npm run x` forms in one line).
- `npm run guards` last — most expensive, runs a full `vite build`
  (`tests/guards/bundle-scan.spec.ts`) per `web/README.md`'s existing guard-suite
  section.
- `&&` chaining (not `;`, not a script-runner package): matches the only
  composition idiom already implicit in this repo's shell-invoked scripts, adds
  zero new dependencies, and gives fail-fast semantics natively — each `&&` link
  only proceeds if the command to its left exited 0, so a non-zero exit from
  `type-check` prevents `lint`, `test`, and `guards` from running at all, and the
  overall `npm run check` process exits with that non-zero code.

### 2. Placement in `scripts`

Insert `"check"` as the **first** entry in `web/package.json`'s `scripts` object,
immediately before `"dev"`. Rationale: it is the single top-level gate entry
point a human or CI invokes (mirroring how `mix letflow.check` is the named,
discoverable gate on the backend side); placing it first makes it the first
thing visible when a reader opens the `scripts` block, rather than buried after
build/dev scripts. The four scripts it calls (`type-check`, `lint`, `test`,
`guards`) are left exactly where they already are — this change only adds the
one new `"check"` key, it does not reorder or rename any existing script.

Resulting `scripts` object shape (new key marked `<-- NEW`):

```
"scripts": {
  "check": "npm run type-check && npm run lint && npm run test && npm run guards",  <-- NEW
  "dev": "vite",
  "build": "tsc -b && vite build",
  "preview": "vite preview",
  "type-check": "tsc --noEmit",
  "lint": "eslint . --ext ts,tsx --report-unused-disable-directives --max-warnings 0",
  "test": "vitest run --passWithNoTests --exclude tests/e2e/** --exclude tests/guards/**",
  "test:watch": "vitest --exclude tests/e2e/** --exclude tests/guards/**",
  "test:coverage": "vitest run --coverage --exclude tests/e2e/** --exclude tests/guards/**",
  "guards": "vitest run tests/guards/meta-control.spec.ts tests/guards/source-scan.spec.ts tests/guards/bundle-scan.spec.ts tests/guards/role-set.spec.ts --reporter=verbose",
  "test:e2e": "playwright test --config=playwright.config.ts",
  "test:e2e:list": "playwright test --config=playwright.config.ts --list",
  "test:e2e:obs04": "playwright test --config=playwright.config.ts tests/e2e/obs04.timeline.e2e.spec.ts"
}
```

### 3. `web/README.md` script table

`web/README.md`'s existing `## Scripts` table (lines 79–87) lists scripts as
`npm run <name>` / `npm test` rows in the order they were introduced, not
strictly matching `package.json` key order (`npm run dev` is listed first even
though the file's own JSON key order will change once `check` is inserted first).
Add one new row for `check`. Placement: as the **first** row of the table, ahead
of `npm run dev`, for the same discoverability reason as its `package.json`
placement — it is the entry point a new contributor or CI job should see first.

New row, exact wording:

```
| `npm run check` | Runs type-check, lint, test, and guards, in that order, stopping at the first failure — the frontend's counterpart to `mix letflow.check` |
```

Full resulting table:

```
| Script | What it does |
|---|---|
| `npm run check` | Runs type-check, lint, test, and guards, in that order, stopping at the first failure — the frontend's counterpart to `mix letflow.check` |
| `npm run dev` | Vite dev server with the API proxy |
| `npm run build` | `tsc -b && vite build` → `dist/` |
| `npm run type-check` | `tsc --noEmit` |
| `npm run lint` | ESLint, zero-warning gate |
| `npm test` | vitest unit/component suite (excludes e2e + guards) |
| `npm run guards` | the three static-analysis guard specs (see below) |
| `npm run test:e2e` | Playwright, needs a running backend |
```

(Only the new row is added; no existing row's wording changes. Note the existing
table already undercounts guard specs as "three" while `guards`'s actual command
lists four spec files — that discrepancy predates this requirement and is out of
scope here; not touched.)

## Explicit scope boundary

No `.github/workflows/` file or directory is created or modified by this design.
This requirement delivers only the `npm run check` command and its README row.
**REQ-138** ("Add the frontend gate job to GitHub Actions CI") is the consumer
that wires this command into a GitHub Actions job. **REQ-136** ("Introduce GitHub
Actions CI running the backend gate") is backend-only, wires `mix letflow.check`,
and carries an acceptance criterion that `web/package.json` is unchanged by it —
this design does not touch anything REQ-136 owns.

## Acceptance criteria → design element map

1. `npm run check` exists in `web/package.json`, runs type-check → lint → test →
   guards, in that order → §1 "New script in `web/package.json`", exact string
   given.
2. Exits non-zero on first failing step, does not run subsequent steps → §1
   rationale: `&&` chaining is short-circuiting shell semantics — this is a
   property of the chosen composition mechanism itself, not something requiring
   further design; ELIXIR-DEV/FRONTEND-DEV verifies it empirically per the task's
   own instruction (introduce a temporary type error, quote real output) since
   this artefact must not claim results it hasn't run.
3. A clean run quoted in full — verification/build-step activity, not a design
   element; no design artefact is needed to satisfy it, FRONTEND-DEV runs it.
4. `web/README.md`'s script table lists `check` with a one-line description →
   §3, exact row text given, table placement specified.
5. No `.github/workflows/` file created; REQ-138 named as consumer, REQ-136 as
   backend-only sibling → "Explicit scope boundary" section above; the
   implementer confirms via `git diff` at build time (verification activity, not
   a design element).

## Open questions

None. The one candidate ambiguity — whether this repo has an established
cross-platform script-composition dependency that should be used instead of
plain `&&` — was checked directly against `web/package.json`'s `dependencies`
and `devDependencies` and resolved: no such dependency exists, so plain `&&`
chaining (already implicit in `mix.exs`'s alias-list convention on the backend
side) is the only idiom available and is adopted without needing a new
dependency.
