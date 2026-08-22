# ISS-0274: fix `npm run type-check` no-op (solution-style root tsconfig)

Status: design, not yet implemented. Scope: narrow, single-line fix to
`web/package.json`'s `type-check` script plus one moduledoc-equivalent
consistency check. No `.ts`/`.ex` implementation code in this document.

## 1. Background (from ISSUE-FIXER diagnosis, step-01)

`web/tsconfig.json` is TypeScript's "solution style" root config:

```json
{
  "files": [],
  "references": [
    { "path": "./tsconfig.app.json" },
    { "path": "./tsconfig.node.json" }
  ]
}
```

A solution-style config is only meaningful to `tsc -b` (build mode).
`web/package.json`'s current `type-check` script is:

```
"type-check": "tsc --noEmit"
```

This is a **plain (non-build) invocation with no explicit project
argument**, so it resolves the root `tsconfig.json`, sees `"files": []`,
finds nothing to check, and exits 0 unconditionally — independent of any
real type errors in `tsconfig.app.json` / `tsconfig.node.json`, which hold
the actual `include` globs (`src/**` and `vite.config.ts` respectively)
and are where all real application source lives. Confirmed by ISSUE-FIXER
via `npx tsc --noEmit --listFiles` (0 files) vs. `npx tsc -b tsconfig.json
--dry` (reports it would build both referenced projects).

## 2. Fix: exact new `type-check` script

Change `web/package.json` line 10 from:

```
"type-check": "tsc --noEmit"
```

to:

```
"type-check": "tsc -b tsconfig.json"
```

### 2.1 Reasoning for this exact invocation form

- `tsc -b tsconfig.json` explicitly names the root config as the build
  entry point. This is deliberately more explicit than bare `tsc -b`
  (which would default to resolving `tsconfig.json` in cwd) — spelling
  out the filename keeps the script legible and matches the fact that
  `web/package.json`'s scripts run with `web/` as cwd, so there is no
  ambiguity, but explicit-over-implicit is preferred for a CI-facing
  gate that ISSUE-FIXER's diagnosis (and REQ-138) will depend on.
- This matches the existing `build` script's established pattern,
  `"build": "tsc -b && vite build"` (package.json line 8), which already
  uses build mode against the same root config with no reported issues.
  `type-check` becomes `build`'s pattern minus `&& vite build`.
- No `--noEmit` flag is added or needed: `tsc -b` does not accept
  `--noEmit` as a per-invocation override the way non-build mode does;
  emit is controlled per-project. Both `tsconfig.app.json` (line 12) and
  `tsconfig.node.json` (line 11) already set `"noEmit": true` in their own
  `compilerOptions`, confirmed by direct read in this design pass — so
  `-b` mode type-checks both referenced projects without emitting any
  `.js`/`.d.ts` output. No change to either referenced config is needed
  or in scope.
- Equivalent alternatives considered and rejected: `tsc -b
  tsconfig.app.json tsconfig.node.json` (lists the two leaf projects
  directly) is functionally identical but bypasses the root config
  entirely, which would silently stop catching a future third project
  reference added to `tsconfig.json` without a corresponding edit to this
  script — `tsc -b tsconfig.json` composes correctly with the root
  config's own reference list instead of duplicating it. Bare `tsc -b`
  (no argument) is functionally identical here but was rejected only for
  the explicitness reason above, not for any behavioral difference.

## 3. Incremental `.tsbuildinfo` caching — decision

**Decision: leave `-b` mode's default incremental caching as-is. No
`--force` flag, no clean step, no cache-clearing wrapper.**

Reasoning:

- `-b` mode writes `.tsbuildinfo` files (per referenced project, next to
  each project's `outDir`/root, governed by TypeScript's own defaults
  since neither `tsconfig.app.json` nor `tsconfig.node.json` sets
  `tsBuildInfoFile` or `incremental` explicitly) to skip re-checking
  files that haven't changed since the last successful build. This is a
  correctness-preserving cache: TypeScript invalidates a project's cached
  state on any change to its own input files, its `compilerOptions`, or
  a referenced project it depends on — it does not skip real type errors
  introduced by an edited file.
- ISSUE-FIXER flagged this as an open question because it did not test
  repeated invocations against a deliberately broken file across
  multiple runs of `tsc -b`. That gap is closed here by reasoning from
  TypeScript's documented incremental-build contract rather than by
  adding defensive machinery: a `.tsbuildinfo` cache can only cause a
  *stale pass* if the same untouched build-info file is reused after a
  file changed without TypeScript itself observing that change (e.g. if
  the file's mtime is manipulated backward independently of its content,
  or the `.tsbuildinfo` file is committed to the repo and manually
  edited) — neither scenario applies to a local dev invocation of
  `npm run type-check` or to `REQ-138`'s planned CI wiring.
- CI runs typically start from a clean checkout — no stale
  `.tsbuildinfo` exists on the first invocation of any CI job, so
  `--force` (which disables incrementality and rebuilds everything from
  scratch) would only add wall-clock cost with no correctness benefit in
  that environment.
- `REQ-138` (CI wiring for `type-check`, not yet implemented) is the
  place where the actual CI invocation, working-directory state, and any
  job-level caching of `node_modules`/build artifacts get decided. Adding
  `--force` now, speculatively, would be designing for a CI environment
  that does not exist yet in this repo (`web/` has no CI workflow file as
  of this issue) — this violates the project's "don't over-engineer"
  guidance in the dispatch and the general anti-pattern of solving a
  problem before its shape is known. If REQ-138's CI wiring turns out to
  reuse a persistent `web/` checkout across runs (self-hosted runner with
  a cached working directory, for example), that is the point to
  reconsider `--force` or an explicit `tsc -b --clean` pre-step — flagged
  here as a forward pointer for REQ-138's own design, not resolved now.
- Local developer runs of `npm run type-check` benefit from the
  incremental cache (faster feedback loop on repeated runs), which is
  the normal, intended use of `-b` mode and is consistent with the
  existing `build` script already relying on the same incremental
  behavior without issue.

No code changes result from this section — it is a decision record
justifying why no additional flag is added.

## 4. Regression check on existing structure

Confirmed by direct read in this design pass, no changes required to:

- `web/tsconfig.app.json` — `"include": ["src"]`, `"noEmit": true`
  already set (line 12/24). Untouched.
- `web/tsconfig.node.json` — `"include": ["vite.config.ts"]`, `"noEmit":
  true` already set (line 11/15). Untouched.
- `web/tsconfig.json`'s `"files": []` / `"references"` structure —
  untouched. The fix is entirely on the invocation side (`package.json`),
  not the config side. Solution-style root configs are the documented,
  correct pattern for a multi-project TS setup driven by `tsc -b`; the
  bug was only ever the mismatched invocation.
- `"build": "tsc -b && vite build"` (package.json line 8) — untouched,
  unaffected by this fix; it already used the correct `-b` invocation.
- `"dev": "vite"` (package.json line 7) — untouched; Vite's own dev-server
  type handling is independent of the `tsc` CLI invocations and out of
  scope.
- `"check": "npm run type-check && npm run lint && npm run test && npm
  run guards"` (package.json line 6) — untouched as a script body; its
  behavior changes only because `type-check` (which it calls) now does
  real work instead of being a no-op. This is the intended effect of the
  fix, not a regression.

## 5. Acceptance-criteria mapping (ISS-0274.yaml)

ISS-0274.yaml's `description` field is the source of the three
acceptance criteria implied by the issue (no separate `acceptance_criteria`
list is present on the issue itself; mapping is against the concrete
requirements stated in `description`):

1. **"needs a fix (e.g. running tsc -b against the project references
   explicitly...) before or alongside REQ-138"** → §2: `type-check`
   changed to `tsc -b tsconfig.json`, exactly the `tsc -b` form the issue
   names as an acceptable fix shape. Delivered now, standalone, not
   blocked on REQ-138 (REQ-138 only wires this already-fixed script into
   CI later).
2. **"CI's type-check step will pass unconditionally and provide no real
   coverage" must stop being true** → §2 makes `type-check` actually walk
   `tsconfig.app.json`'s `src/**` and `tsconfig.node.json`'s
   `vite.config.ts` (the real source), so a genuine type error in either
   project now fails the script (non-zero exit) instead of the previous
   guaranteed-0-exit no-op. §3 confirms the incremental cache cannot mask
   this for CI's clean-checkout invocation pattern.
3. **"unrelated to REQ-115's own diff"** — i.e. the fix must not touch or
   regress `tsconfig.app.json`/`tsconfig.node.json`'s already-correct
   `noEmit`/`include` structure, nor REQ-115's other script additions
   (`lint`, `test`, `guards`, `check`) → §4 confirms zero changes to
   those files/scripts; the fix is a single-line change to one script
   value.

## 6. Open questions for implementer (ELIXIR-DEV is N/A here — this is
FRONTEND-DEV scope)

None outstanding. §3 resolves the one open question ISSUE-FIXER flagged.
FRONTEND-DEV should, after making the change, run `npm run type-check`
directly (real command, real output) to confirm non-zero-file coverage —
e.g. re-run `npx tsc -b tsconfig.json --listFiles`-equivalent evidence or
inspect exit code against a deliberately reverted/broken line if deeper
proof is wanted — and separately confirm `npm run build` and `npm run
check` still succeed, since `check` now depends on a `type-check` that
does real work for the first time.
