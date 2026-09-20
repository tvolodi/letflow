# WF-03 Fix Design — ISS-0737

Run-id: WF03-ISS0737-20260920
Type: frontend bug fix, one-file, one-handler `deferClickState` wrap (same fix class as
ISS-0662). No backend (`lib/`, `priv/`) changes.

## 1. Root cause (from ISSUE-FIXER, not re-derived)

`web/src/pages/definitions/DefinitionListPage.tsx`'s `name` column definition
(current lines 159-182) renders each row's `def-name-${def.id}` span with an inline
`onClick` that calls `setExpandedDefId`/`setExpandedDefName` synchronously, inside the
same native trusted click's event-dispatch turn:

```
def-name-${def.id} span onClick (lines 163-171, current main):
  if (expandedDefId === def.id) {
    setExpandedDefId(null)
    setExpandedDefName(null)
  } else {
    setExpandedDefId(def.id)
    setExpandedDefName(def.name)
  }
```

This is the same trigger class ISS-0662 confirmed and fixed via
`web/src/utils/deferClickState.ts` (`setTimeout(fn, 0)`, tests 12-13 of
`docs/frontend/iss-0662-entity-crud-page-click-freeze-fix.md`), and the same pattern
already applied to `DataTable.tsx`'s `handleHeaderClick` (lines 83-94: the whole
`setSortState` call wrapped in `deferClickState(() => { ... })`, with a `// ISS-0662:
deferred by one macrotask` comment). ISS-0737 is the same defect surfacing in a
bespoke inline handler that ISS-0662's original fix pass never touched (it patched
`DataTable.tsx` and `EntityCrudPage.tsx` only). ISSUE-FIXER already reproduced the
freeze against the real backend+Keycloak stack in both `npm run dev` and
`npm run build && vite preview`, and empirically validated that wrapping this exact
handler body in `deferClickState(() => {...unchanged...})` eliminates it in both
filtered and unfiltered search states, with `version-history-row` correctly appearing
in under 1s post-click.

## 2. Fix — exact change

File: `web/src/pages/definitions/DefinitionListPage.tsx`.

**Import** (top of file, alongside the other `web/src/utils/` and `web/src/components/`
imports already present) — add:

```
import { deferClickState } from '@/utils/deferClickState'
```

(`DataTable.tsx` imports `deferClickState` via the `@/utils/deferClickState` path alias,
not a relative path; `DefinitionListPage.tsx` itself uses the `@/` alias for 100% of its
existing imports, with zero relative imports anywhere in the file. Use the same alias
form here for consistency with this file's own convention.)

**Handler body** (current lines 163-171) — wrap the existing, unchanged `if/else` in
`deferClickState`:

Before:
```
onClick={() => {
  if (expandedDefId === def.id) {
    setExpandedDefId(null)
    setExpandedDefName(null)
  } else {
    setExpandedDefId(def.id)
    setExpandedDefName(def.name)
  }
}}
```

After:
```
onClick={() => {
  deferClickState(() => {
    if (expandedDefId === def.id) {
      setExpandedDefId(null)
      setExpandedDefName(null)
    } else {
      setExpandedDefId(def.id)
      setExpandedDefName(def.name)
    }
  })
}}
```

Add a one-line comment above the `deferClickState` call matching `DataTable.tsx`'s own
convention: `// ISS-0737: deferred by one macrotask — see web/src/utils/deferClickState.ts.`

No other line in the `name` column's `accessor` (the `isSearching`/`highlightText`
render branch, the description sub-row) changes.

### 2.1 Closure-capture check (explicitly confirmed, not assumed)

The wrap adds one nesting level of arrow function; it does not move the callback across
a render boundary or defer *which* render's closure runs it — `deferClickState(fn)` is
called synchronously (only `fn`'s *execution* is deferred via `setTimeout(fn, 0)`), so
`fn` closes over the exact same `def`, `def.id`, `def.name`, `expandedDefId`, and
`expandedDefName` bindings that the current render's `onClick` closure already captured
before the wrap — identical to how `DataTable.tsx`'s `handleHeaderClick` closes over
`col` and the current `setSortState` setter through its own `deferClickState` call.
`expandedDefId` is read via the closure both before and after the change (React's
`setState` setters are stable across renders, and `def`/`def.id`/`def.name` come from
the same `columns` array's `accessor(def)` call, re-created each render exactly as
before) — so the one-macrotask delay in when the `if/else` comparison against
`expandedDefId` actually runs is the *only* behavioral difference, and it is the exact
behavior ISS-0662 already validated as safe (the comparison still reads the value from
the click's own render, since no other state-setting code runs between the click and
the deferred callback firing on a modern single-threaded JS event loop with no
intervening render of `DefinitionListPage` before the macrotask fires — nothing else in
this component's synchronous render path sets `expandedDefId`/`expandedDefName`
between the click and the deferred fn's execution).

## 3. Security review: not required

Pure client-side interaction-timing fix. `deferClickState` changes *when* an existing,
already-shipped state update runs (one macrotask later) — it does not change what
data is fetched, what is displayed, or introduce any new network call, auth check, or
tenant-data read/write path. `expandedDefId`/`expandedDefName` are local UI state
driving `versionsQuery = useDefinitionVersions(expandedDefName ?? '')` (line 69,
unchanged) — the query itself, its auth headers, and its backend endpoint are
untouched by this fix. No `lib/letflow/` route, migration, or response-shaping code is
touched. SECURITY-REVIEWER's gate is scoped to tenant-data-path changes per
`docs/agents/instructions/security-invariants.md`; this fix has none. Skip
SECURITY-REVIEWER for this change.

## 4. Fail-then-pass regression test TEST-DESIGNER should write

Follow `web/tests/e2e/iss-0662-entity-crud-click-freeze.e2e.spec.ts`'s established
convention (a dedicated e2e spec file per freeze-class fix, named
`iss-<NNNN>-<short-slug>.e2e.spec.ts`, alongside the existing `iss-0729-*` sibling) —
create `web/tests/e2e/iss-0737-definition-name-click-freeze.e2e.spec.ts`:

- **Real trusted click only** — `locator.hover()` + `page.mouse.down()` +
  `page.mouse.up()` against a `def-name-${id}` span on `/definitions` (or whatever
  route mounts `DefinitionListPage`), exactly as ISS-0662's and ISS-0729's own specs
  do. Do NOT use `dispatchEvent('click')` — per §3.3 of the ISS-0662 design doc, that
  method never exhibited the freeze and would not catch a regression.
- **Must fail against pre-fix `main`**: assert `page.mouse.up()` resolves within a
  bounded timeout (5s is the convention already used by the ISS-0662/ISS-0729 specs —
  generous above the fix's measured ~1s resolution, tight enough that the freeze
  reliably trips it).
- Cover both branches ISSUE-FIXER validated: (a) unfiltered list — click a
  `def-name-${id}` span directly; (b) filtered list — type into the search box first
  (matching the e2e spec's own existing flow in
  `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`),
  then click the matching row's `def-name-${id}` span. ISSUE-FIXER confirmed the freeze
  reproduces in both cases, ruling out `isSearching`/`highlightText` as causal — the
  regression test should keep proving that, not just cover one branch.
- **After the fix**, in addition to the bounded-time assertion, assert the resulting UI
  state actually applied: `version-history-row` (or this page's equivalent expanded-row
  testid — confirm the exact testid FRONTEND-DEV's expanded-row markup uses, at line
  ~361's `expandedDefId === def.id ? (...)` branch) becomes visible after the click, and
  clicking the same span again collapses it (`expandedDefId` reset branch) — this
  guards against the fix silently swallowing the state update rather than merely
  deferring it by one tick, the same swallow-regression risk ISS-0662 §4 flags.
- Once this new spec is green, `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`
  (REQ-371 AC6's own required spec, the one ISSUE-FIXER was root-causing this issue
  from) should be re-run in full — it is expected to now pass past the point this
  freeze previously blocked it.

## 5. Scope confirmation

- No new public function, component, module, or route.
- No new testid needed in product code — `def-name-${def.id}` already exists and is
  already the selector ISSUE-FIXER's reproduction and the promotion-rollback e2e spec
  use.
- Only `web/src/pages/definitions/DefinitionListPage.tsx` (product code) and the new
  e2e spec file (test code) change. `web/src/utils/deferClickState.ts` is reused
  as-is — no change to that file.

## 6. Open questions

None. The fix is a single, already-validated wrap of an already-established helper
around an already-identified handler; no design decision here is left unresolved.

## 7. Acceptance-criteria mapping

| Requirement (from ISS-0737's diagnosis) | Design element covering it |
|---|---|
| Real click on `def-name-${id}` (unfiltered) must not freeze | §2 wrap + §4 unfiltered test case |
| Real click on `def-name-${id}` (filtered/search active) must not freeze | §2 wrap (handler body identical regardless of `isSearching`) + §4 filtered test case |
| Fix must not change resulting UI state (expand/collapse still correct) | §2.1 closure-capture check + §4's post-click visibility/toggle assertions |
| Fix must follow the established `deferClickState` pattern, not a bespoke mechanism | §2 (reuses `web/src/utils/deferClickState.ts` unchanged) |
| REQ-371 AC6's e2e spec must be unblocked | §4's closing note (re-run `platform-definition-promotion-rollback.pipeline.e2e.spec.ts` after this fix lands) |
| SECURITY-REVIEWER scoping must be stated, not assumed | §3 |
