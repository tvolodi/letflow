# DefinitionListPage search main-thread freeze — fix design (ISS-0729)

Design record for a MAJOR-severity fix blocking REQ-371's required e2e spec
(`web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`,
AC6) from being honestly claimed as passing. **No implementation code appears
in this document** — every change is described by call-site location and
prose, per this role's mandate.

**Location note:** ISS-0662's analogous fix design lives under
`docs/frontend/` (that file's own §0 states the project convention: a pure
frontend bug-fix note belongs there, not under `lib/letflow/design/`, which
is the backend Ecto/gen_statem convention). This document was explicitly
requested at `lib/letflow/design/` by the dispatching agent for ISS-0729, so
it is filed here instead — flagged, not silently diverged from precedent.
Whoever runs WF-03 Step Final for this fix should decide whether to also drop
a pointer file at `docs/frontend/iss-0729-*.md` for discoverability
consistent with ISS-0662; not required for this fix to be correct.

## 0. What ISSUE-FIXER established, and what is new here

From `docs/issues/ISS-0729.yaml`:

- Genuine, intermittent (60-80% across 11 real runs) main-thread freeze,
  reachable via `DefinitionListPage.tsx`'s debounced search shortly after
  navigation, hanging Playwright's `definition-search` fill/click step.
- **Dev-mode-only**: reproduces under `npm run dev` (StrictMode active),
  never under `npm run build && npm run preview`. This is a real,
  load-bearing difference from ISS-0662, whose freeze was never shown to be
  StrictMode-specific (ISS-0662's own design doc doesn't mention build mode
  as a variable at all — every one of its tests ran against whatever server
  ISSUE-FIXER/CODE-DESIGNER had up, and nothing in that investigation ruled
  production builds in or out).
- Chromium renderer pegged at ~106-107% CPU **continuously** during the
  freeze, zero network activity. CDP profiler cannot capture a stack
  (`Profiler.stop` itself hangs), mirroring ISS-0662.
- A second, independently-launched browser hitting the same dev server also
  hung on its own fresh page — rules out single-tab corrupted state as the
  *sole* cause (consistent with a server-adjacent or module-level condition,
  not solely per-tab React state).
- Cites ISS-0662 (`deferClickState.ts`'s `setTimeout(fn, 0)` pattern) and
  ISS-0296 (StrictMode double-invocation dev-only race) as precedent classes.

**One fact this design adds, verified here, not assumed:** ISS-0662's own
design doc (§1, test descriptions) characterizes *its* freeze as the main
thread being **"genuinely idle-blocked"** — no CPU-spin language anywhere in
that document. ISS-0729's freeze is explicitly **CPU-pegged at ~107%
continuously**. These are two different physical symptoms:

| | ISS-0662 | ISS-0729 |
|---|---|---|
| CPU during freeze | not spinning (idle-blocked / deadlocked) | pegged ~106-107%, continuously |
| Build mode | not investigated as a variable | confirmed dev/StrictMode-only |
| Trigger | any `setState` synchronously inside a real trusted click/keyboard-activation's native event-dispatch turn, on that one route | debounced-search interaction, "shortly after navigation" |
| Fix mechanism validated | `setTimeout(fn, 0)` deferral (tests 12-13) | not yet validated for this issue — see §2/§3 |

An idle-blocked deadlock and a CPU-pegged busy-loop are not the same failure
mode, even though both present to a test harness as "the page stopped
responding." **This distinction is the single biggest reason this design
does not simply prescribe "apply `deferClickState` and ship it"** — see §2's
ranked hypotheses and §3's empirical protocol, which is built specifically
to distinguish "deferring the input handler's `setState` removes the freeze"
(supports an ISS-0662-shaped cause) from "the freeze still occurs, merely
delayed by one tick" (would falsify that and point at a genuine render loop
instead, §2 H3).

## 1. Code read, with the exact suspect lines

`web/src/pages/definitions/DefinitionListPage.tsx`:

- L26-38: local `useState` calls — plain, unremarkable.
- L43: `const debouncedSearch = useDebounce(search, 300)`.
- L48-52: unrelated effect (`pendingNavId` → `navigate`), fires only after
  `handleCreate` succeeds — **not reachable by a plain search interaction**,
  ruled out as this freeze's direct trigger (the e2e spec's step 1 is a
  `definition-search` fill, not a create-then-navigate flow).
- L54: `const searchQuery = useDefinitionSearch(debouncedSearch, { limit: 20 })`
  — `{ limit: 20 }` is a **new object literal every render**. Traced into
  `useDefinitionSearch` (below): only its primitive fields (`limit`,
  `offset`) are read, and those feed `definitionKeys.search(query, limit,
  offset)`, a `[...] as const` tuple of primitives. TanStack Query hashes
  query keys structurally (deep value equality via its default
  `hashQueryKey`), not by object/array reference — a fresh `{ limit: 20 }`
  literal every render does **not** register as a "different" query key or
  force a new `QueryObserver` subscription. **Ruled out** as a cache-churn
  or refetch-loop source; also consistent with ISS-0729's own "no network
  activity during the freeze" finding (a refetch-loop hypothesis would
  produce network activity; this one doesn't, independently corroborating
  the ruling-out).
- L139-209: `columns` — a **new array of column-def objects, with new
  closures, built on every render** (not memoized). Each `accessor` closure
  captures `debouncedSearch`, `expandedDefId`, `activate`, `archive` by
  reference. This is passed as a prop into `<DataTable columns={columns} .../>`.
- L238-245: **the suspect input**:
  ```
  <input
    data-testid="definition-search"
    ...
    value={search}
    onChange={(e) => setSearch(e.target.value)}
    .../>
  ```
  `onChange` calls `setSearch` **synchronously, inside the native trusted
  `input`/`change` event's own dispatch turn** — exactly the trigger shape
  ISS-0662 confirmed (its own §2: "the freeze occurs precisely when a React
  `setState` call runs synchronously inside the same native browser
  event-dispatch turn... for *any* click handler that calls `setState`,
  however trivial"). React 18 classifies `input`/`change`, like `click`, as
  **discrete-priority** events — both flush synchronously within the same
  native dispatch turn under the legacy/default scheduling React uses for
  discrete events. Playwright's `fill()` dispatches a trusted `input` event
  (CDP `Input.insertText`/`dispatchKeyEvent` path, `isTrusted: true`), so
  this input's `onChange` is a structural match for ISS-0662's confirmed
  general trigger class, not merely an analogy.

`web/src/hooks/useDebounce.ts` (all 13 lines read):
```
useEffect(() => {
  const timer = setTimeout(() => setDebounced(value), delayMs)
  return () => clearTimeout(timer)
}, [value, delayMs])
```
Textbook-correct debounce with correct cleanup. React 18 StrictMode
double-invokes **effects at initial mount only** (mount → cleanup → mount),
not on every subsequent dependency change caused by later state updates —
so a single extra mount/cleanup/mount cycle happens once, at
`DefinitionListPage`'s first mount after navigation, and never again for
each subsequent keystroke. This effect, taken alone, does not explain a
freeze that reproduces "shortly after navigation" on typing — but see H2 in
§2 for why the *timing* of that one-time double-invoke, landing close to
when the search interaction starts, is still a live variable.

`web/src/hooks/useDefinitions.ts` `useDefinitionSearch` (L68-76): plain
`useQuery`, `enabled: query.trim().length > 0` — standard TanStack Query
usage, nothing StrictMode-hazardous (TanStack Query's `QueryClient` is
itself a stable module-level-ish instance created once in `main.tsx` and
provided via context — StrictMode's double-mount produces two
`QueryObserver` subscriptions briefly, both against the same
`QueryClient`/cache entry; this is TanStack Query's own explicitly-supported
StrictMode contract, not a known hazard class here).

`web/src/utils/deferClickState.ts` (all 22 lines read): `setTimeout(fn, 0)`,
documented as "the ONLY deferral mechanism tested and shown to work" for
ISS-0662, with an explicit warning not to substitute `queueMicrotask`/
`Promise.resolve().then()` since those resolve before the same
paint/compositor boundary a macrotask crosses. Generic, click-name aside —
nothing in its 3-line body is EntityCrudPage- or click-specific; it is
exactly "defer this callback by one macrotask," reusable verbatim for a
non-click discrete event.

`web/src/components/ui/DataTable.tsx` (all 229 lines read): already patches
its own `handleHeaderClick` (L83-94) via `deferClickState`, per ISS-0662 §3.1
OQ-1's resolution (fixed in the shared component, not just
`EntityCrudPage`). This means `DataTable`'s *own* sort-header interaction is
already covered for `DefinitionListPage` too — it is not itself a new
suspect for this issue, though it is the shared component through which
`columns`'s new-array-every-render pattern (L139-209 above) reaches
`useReactTable`. `toColumnDefs(columns)` is wrapped in
`useMemo(..., [columns])` (L63) — since `columns` is a new reference every
parent render, this memo recomputes every render (wasted work, not a loop:
nothing here schedules a `setState` as a result of that recomputation).

`web/src/utils/highlightText.tsx` (all 21 lines read) — see §4; independently
confirmed (§4) not implicated in the freeze itself, but a real, separate
correctness defect regardless.

`web/src/main.tsx` (all 39 lines read): confirms `<React.StrictMode>` wraps
the entire `<RouterProvider>` tree (L28-37) — every routed page, including
`DefinitionListPage`, mounts under StrictMode in dev.

## 2. Ranked hypotheses

**H1 — Search input's synchronous `setState` inside a trusted discrete-event
dispatch turn (same general class ISS-0662 confirmed).** `onChange={(e) =>
setSearch(e.target.value)}` (L243) runs `setSearch` synchronously inside the
native `input` event's dispatch turn, matching ISS-0662's confirmed general
trigger ("any `setState` call... inside the same native browser
event-dispatch turn," proven route-independent-in-mechanism across two
different pages' worth of handlers in that investigation, tests 8-13).
**Strongest structural match**, but **does not by itself explain the
CPU-pegged / dev-mode-only discrepancy from §0's table** — ISS-0662's
mechanism was idle-blocked and was never shown to be StrictMode-specific.
If H1 is the whole story, the empirical protocol in §3 Step 1 will show it
(0/N hangs after deferring `setSearch` alone); if it isn't, Step 1 will show
a persisting (even if reduced-rate) hang, which is the signal to move to H2.

**H2 — StrictMode double-invocation race specific to this route's mount
timing (ISS-0296-class).** ISS-0729's freeze is explicitly dev/StrictMode-only,
unlike ISS-0662. `useDebounce`'s effect double-invokes once at
`DefinitionListPage`'s initial mount (mount → cleanup → mount, all
synchronous in the same tick per React's StrictMode contract). "Shortly
after navigation" is exactly the window in which that double-invoke
happens. A plausible race: if the e2e spec's fill/type happens to land
**during** that double-mount window (StrictMode's phantom first mount,
already-scheduled-then-cancelled effect, real second mount), two
overlapping `useDebounce` instances (the phantom's and the real one's) could
transiently exist with two live `setTimeout` timers and two `debounced`
state slots, backed by the same underlying DOM node's `onChange` firing
against whichever instance's fiber React currently considers current — this
is speculative, **explicitly flagged as unconfirmed**, and needs the
`console.count`/timestamp instrumentation in §3 Step 2 to either confirm or
rule out, since nothing in a static read of `useDebounce.ts` shows an actual
bug (the hook's cleanup is textbook-correct) — the hazard, if real, would be
in the *interaction* between the mount-timing race and something else, not
in `useDebounce.ts` alone.

**H3 — Genuine synchronous re-render loop (best fit for "CPU pegged
continuously," the discrepancy H1 doesn't explain).** A tight
React `setState` → re-render → `setState` → re-render cycle that doesn't hit
React's own "Maximum update depth exceeded" dev-mode circuit-breaker (that
breaker only fires for updates scheduled *from inside a render or effect
body of the same component*, at a fixed iteration ceiling — a loop bouncing
through more than one component/hook boundary, or one gated by conditions
that are only sometimes true 60-80% of the time, would present as sustained
high CPU rather than a clean thrown error) would look exactly like
"CPU pegged at ~107%, no network, no capturable stack" (the profiler
attaching mid-loop would itself contend for the same main thread,
consistent with `Profiler.stop` hanging). No single line in the files read
here is *confirmed* to cause such a loop — `columns`'s new-reference-per-render
shape (§1) is the most structurally suspicious candidate (it feeds
`useReactTable` fresh options every render), but `DataTable` is used
elsewhere (e.g. inside `EntityCrudPage`, and presumably other list pages)
without a standing report of this shape of freeze, arguing against a
render-loop bug generic to `DataTable`/`useReactTable` itself and toward
something specific to how `DefinitionListPage` drives it (the closures in
`columns` change identity on every keystroke because they capture
`debouncedSearch`, which changes over the search interaction — still,
identity churn alone doesn't imply a *loop* without something feeding a
`setState` back from inside that render). Rated below H1/H2 because it
requires an as-yet-unidentified feedback path, but rated above H4 because it
best fits the specific "CPU pegged, not idle" symptom.

**H4 — `highlightText`'s regex (lowest prior).** Ranked last because: (a)
the escaped-literal pattern used (`new RegExp('(' + escaped + ')', 'gi')`)
has no nested quantifiers, so catastrophic backtracking is not
constructible from a plain literal substring match regardless of input; (b)
this function is not on the search **input's** critical path at all — it
only runs inside `DataTable`'s row-cell `accessor` calls, i.e. after
`searchResults` has already arrived and rows are being rendered, whereas
ISS-0729 specifically says the hang is at the `fill`/click step, before any
results could plausibly exist yet for a fresh query; (c) empirically
exhaustive-tested (§4) across an alphabet/length space large enough to
raise real confidence — zero mismatches found, i.e. no evidence this
function even produces wrong output for typical inputs, let alone hangs.
Still worth ruling out mechanically in §3 Step 4 since it's cheap to test
and is explicitly in `affected_files`.

## 3. Empirical verification protocol (mandatory before implementing a fix)

Mirrors ISS-0662's design doc §1 methodology: a throwaway, uncommitted
Playwright script driving the real dev server (`npm run dev`), never
committed, working tree returned to `git status --porcelain web/` empty
after each step and at the end. Given the CDP profiler cannot capture a
stack during the freeze (confirmed by ISSUE-FIXER, consistent with
ISS-0662), this protocol substitutes **mutation + repeated real-run
reproduction rate** for a stack trace, exactly as ISS-0662's own
investigation did.

**Baseline (must run first, unmodified `main`):** navigate to
`/definitions`, then real-gesture-fill (`locator.click()` +
`locator.pressSequentially(text, {delay: 20})` — NOT `.fill()`, since a
single-shot `.fill()` dispatches one `input` event rather than one per
character and may not reproduce a per-keystroke race; use per-character
keyboard events to match what a real user, and StrictMode's mount timing
in relation to a multi-keystroke sequence, would actually produce) into
`[data-testid=definition-search]` immediately after `page.goto`/navigation
completes DOM-ready. Repeat **N=20** times in a fresh browser context each
time (matching ISS-0729's own "11 real runs" methodology, sized up for
tighter confidence given the 60-80% reported rate — 20 runs at a true 70%
hang rate has <0.1% chance of showing zero hangs by luck, so 0/20 after a
fix is meaningful, and the pre-fix baseline should land in a 12-16/20
range, consistent with 60-80%). Record hang count. **This step confirms the
harness reproduces at the reported rate before any code changes are
trusted to have done something** — do not skip it.

**Step 1 — test H1.** Apply *only* this change:
`web/src/pages/definitions/DefinitionListPage.tsx`'s `onChange` handler
(L243) — capture `e.target.value` into a local variable synchronously (React
18 does not pool `SyntheticEvent`s, so this is a safety/clarity measure, not
a correctness requirement, but do it anyway to avoid depending on that
non-pooling fact remaining true), then call `setSearch` via
`deferClickState`, i.e. `deferClickState(() => setSearch(value))`. Import
`deferClickState` from `@/utils/deferClickState` (already a shared,
generically-named-enough utility — no rename needed; its doc comment is
ISS-0662-specific prose, which should get one added sentence noting a second
confirmed consumer, not a rewrite). Re-run the same N=20 loop.
- **0/20 hangs** → H1 confirmed as sufficient. Stop here, this is the fix.
  Proceed to §5 (regression test) using this exact change.
- **Hangs persist at any rate close to baseline** → H1 is not sufficient by
  itself (does not rule out that deferring is *part* of the answer — see
  Step 2's combination note) — proceed to Step 2.
- **Hangs persist but the timing shifts** (e.g., the freeze now happens
  slightly later, or is now shorter, but does not fully disappear) → this is
  the specific signature that would falsify H1-as-sole-cause and support H3
  (a real feedback loop merely delayed by the one macrotask, not removed) —
  proceed to Step 3 directly (H3 is now the leading hypothesis), noting this
  finding explicitly rather than re-running Step 2 first.

**Step 2 — test H2.** With Step 1's change reverted (back to baseline),
temporarily remove the `<React.StrictMode>` wrapper in `web/src/main.tsx`
(unwrap `<QueryClientProvider>` to be the tree's root, keep everything
else), still running `npm run dev` (not `preview` — isolate the StrictMode
variable alone, not the dev-vs-prod build variable, which ISS-0729 already
confirmed separately). Re-run the same N=20 baseline-gesture loop.
- **0/20 hangs** → confirms this is StrictMode-double-invoke-class
  (ISS-0296 precedent), independent of H1. Before committing to removing
  StrictMode app-wide (a large blast-radius change this design does **not**
  recommend, since StrictMode's dev-time safety checks protect the whole
  app, not just this page), add the following narrower instrumentation to
  find the actual double-invoke interaction: add temporary
  `console.log(Date.now(), 'debounce-effect-run')` inside `useDebounce`'s
  effect body and `console.log(Date.now(), 'render')` at the top of
  `DefinitionListPage`'s function body (both temporary, reverted after this
  investigation — never leave debug logging in the shipped fix), run the
  same repro 5 times with DevTools console capture, and inspect the
  timestamped sequence around the failure window for: (a) an actual
  unbounded/very-large count of `debounce-effect-run` or `render` lines
  (thousands, not the small single-digit count StrictMode's one-time
  double-invoke would produce) — a large count here reclassifies this as H3
  after all, just gated by a StrictMode-specific window rather than
  present in prod; or (b) exactly the expected small bounded count with the
  hang appearing to occur *between* two specific logged lines — pinpointing
  the exact synchronous window to defer. Whichever call site turns out to
  sit inside that window is the actual fix location — defer that call via
  `deferClickState`, in addition to or instead of Step 1's change per what
  Step 1 found.
- **Hangs persist with StrictMode removed** → H2 ruled out as sole cause.
  Restore `<React.StrictMode>` (never ship it removed based on this test
  alone — a negative result here doesn't license weakening the app's dev
  safety net) and proceed to Step 3.

**Step 3 — test H3.** With all prior test changes reverted to baseline,
apply this isolation: `web/src/pages/definitions/DefinitionListPage.tsx` —
temporarily wrap the existing `columns` array construction in
`useMemo(() => [...existing columns array...], [isSearching,
debouncedSearch, expandedDefId, activate.isPending, archive.isPending])`
(a real, correctly-dependency-tracked memoization, not a throwaway stub —
if this turns out to be the fix, keep it permanently rather than reverting).
Re-run the same N=20 loop.
- **0/20 hangs** → H3 confirmed: the previously-unmemoized `columns` array
  (new closures every render, feeding `useReactTable` fresh options every
  render) was creating enough synchronous re-render/recompute pressure
  during the rapid-fire renders a multi-keystroke `pressSequentially`
  sequence produces to manifest as the observed CPU-pegged freeze. Keep the
  `useMemo` as the permanent fix (this is a real, generally-good practice
  independent of this bug — an unmemoized column-def array recreated every
  render was always wasted work; this investigation just confirms it was
  more than "wasted," it was load-bearing for the freeze). Combine with
  whichever of Step 1/2's changes also independently helped, if any, and
  re-run baseline-style N=20 once more with **all** surviving changes
  together as the final combined fix, to confirm 0/20 holistically before
  calling it done.
- **Hangs persist** → H3 (at least in this specific form) ruled out.
  Proceed to Step 4 as a completeness check, then escalate: if H1, H2, and
  H3 (as specified here) all fail to eliminate the freeze, this is now a
  genuinely unresolved investigation requiring the Chrome DevTools
  Performance-trace approach ISS-0662 itself flagged as needed but
  unavailable in a sandboxed CDP session (OQ-4 there) — do not guess further
  at a fourth candidate without that trace; escalate to ISSUE-FIXER with
  this document's full empirical trail (which candidates were tested and
  falsified) rather than re-investigating from scratch.

**Step 4 — test H4 (cheap completeness check, run regardless of Steps 1-3's
outcome, in parallel if convenient).** Temporarily stub
`web/src/utils/highlightText.tsx`'s exported function to
`return text` unconditionally (no regex construction at all). Re-run N=20.
- **Hangs persist unchanged** (expected, per §2's reasoning) → H4 ruled out
  as the freeze's cause; still apply §4's independent correctness fix
  (not conditional on this result).
- **0/20 hangs** → would contradict this design's §1/§2 reasoning about
  `highlightText` being off the pre-results critical path; if this actually
  happens, that reasoning was wrong somewhere (e.g., the e2e spec's repro
  does reach a rendered-results state before the hang, not just the
  fill step) — re-read the actual spec file once it exists and revise this
  document's §1 rather than silently accepting a result that contradicts
  the stated reasoning.

**Reporting requirement for whoever runs this protocol:** record the exact
per-step hang count (e.g., "14/20" not "mostly hung") in the implementation
run's handoff/commit message, the same rigor ISS-0662's design doc's table
used. A fix landed without running this protocol and quoting real counts is
not verified per this project's No Speculation rule — "the deferral pattern
worked for ISS-0662 so it should work here too" is exactly the kind of
inherited, unverified claim `docs/anti-patterns.md`'s "Inheriting a claim
from a record instead of re-deriving it from the source" entry warns
against.

## 4. `highlightText.tsx` — separate, confirmed-real fix (independent of the freeze)

Read in full (21 lines). Current shape:
```
const regex = new RegExp(`(${escaped})`, 'gi')
const parts = text.split(regex)
...
return parts.map((part, i) =>
  regex.test(part) ? <mark ...>{part}</mark> : part,
)
```

**Empirical finding, stated honestly:** this design ran an exhaustive
brute-force check (Node, not a guess) of this exact code shape — binary and
ternary alphabets, query lengths 1-3, text lengths up to 10-14 characters
(3,454,347 cases at the widest sweep) — comparing this function's per-part
match/no-match decisions against the objectively-correct answer
(`part.toLowerCase() === query.toLowerCase()`). **Zero mismatches found.**
The reason: `String.prototype.split` constructs its own internal regex
clone per the ECMAScript spec (`RegExp[Symbol.split]`) and never reads or
mutates the `regex` object's own `lastIndex` — so `regex.lastIndex` is still
0 going into the `.map()`. From there, every failed `RegExp.prototype.test`
call on a global-flagged regex resets `lastIndex` to 0 (per spec, on any
failed match), and because `.split()` with a capturing group always
produces a strict alternation of `[non-match, match, non-match, match, ...]`
segments, every non-match segment sits between two match segments and
reliably fails its `.test()` call (it cannot itself equal the query,
otherwise `.split()` would have carved it out as its own match segment),
which resets `lastIndex` to 0 before the next match segment is tested. The
described "alternating incorrect results" failure mode is the textbook
symptom of this exact anti-pattern *when independent candidate strings are
tested against a shared global regex* (e.g. `candidates.map(c =>
sharedRegex.test(c))`) — but is not reachable for candidates that are
specifically `.split()`'s own strictly-alternating output, which is what
this function actually does.

**This does not mean "leave it as-is."** Three reasons to fix it anyway,
none of them "because the issue said so":
1. It is a genuine shared-mutable-regex-state anti-pattern that happens to
   be safe **only** because of an implementation detail of `.split()`'s
   spec behavior that isn't visible at this call site — a future edit to
   this function (e.g., changing the map to iterate a differently-sourced
   array, or someone "simplifying" by hoisting `regex` further out) could
   silently reintroduce the classic bug with no test currently pinned to
   catch it structurally, only behaviorally.
2. It is needlessly re-deriving information `.split()` already gave for
   free: the capturing group's own alternation *is* the match/no-match
   signal. Calling `.test()` a second time is redundant work on every
   render, for every matched row, every keystroke.
3. `mix`/`npm` idiom aside, "this specific reuse happens not to be
   exploitable today, verified by brute force" is a materially different,
   weaker claim than "this code is correct by construction" — the fix
   should make it the latter.

**The fix:** drop the `test()` re-check entirely. `String.prototype.split`
with a single capturing group guarantees odd array indices are exactly the
captured (matched) substrings and even indices are the non-matched
segments — verified by the same brute-force sweep (3,454,347 cases, zero
mismatches) against the parity-based decision `i % 2 === 1`. Concretely:
- Drop the `g` flag from the constructed `RegExp` (`.split()` does not need
  it — verified identical segment output with/without `g` across the full
  sweep above; keep only `'i'` for case-insensitivity).
- Replace `regex.test(part)` with an index-parity check on the `.map`'s
  index argument (`i % 2 === 1`) — no `RegExp` object needs to be
  read/mutated after the `.split()` call at all.
- No signature change: `highlightText(text: string, query: string):
  ReactNode` stays exactly as-is. Purely an internal-implementation fix.

## 5. Regression test strategy — stated honestly per testability

**`highlightText.tsx` (§4) — fully unit-testable, Vitest.** Since the old
code was empirically shown (§4) not to misbehave for this call shape, a
literal "prove the alternating bug, then prove it's fixed" test would be
dishonest framing (there is no failing-on-`main` fixture to point at
truthfully). Instead, TEST-DESIGNER should write:
- A **general correctness property test** (not tied to reproducing a
  specific historical bug): for a curated set of fixtures with 3+
  occurrences of the query substring at varying spacing/overlap (e.g. `"cat
  catalog cat scatter cat"` / `"cat"`, adjacent-match fixtures like `"aaaa"`
  / `"aa"`, and a case-insensitive-mixed-case fixture like `"CaT cat CAT"` /
  `"cat"`), assert that **every** occurrence renders inside a `<mark>` (not
  just some — count matched-vs-plain parts in the returned array and assert
  the count of `<mark>`-tagged parts equals the fixture's known true
  occurrence count) and that concatenating every part's text content
  reconstructs the original `text` exactly (guards against a fix that drops
  or duplicates characters).
- A regression test locking in the parity-based implementation choice
  itself is optional/redundant once the correctness property test above
  passes — don't test the *mechanism* (parity check) directly, test the
  *behavior* (every occurrence highlighted, text preserved), so a future
  reimplementation isn't needlessly constrained.
- State in the test file's own comment, honestly, that this is a general
  correctness/robustness test, not a "was broken, now fixed" regression
  test — because §4's own investigation could not construct a failing
  case for the prior implementation. This is exactly the kind of "name
  coverage limits honestly" this session has already established as the
  norm elsewhere (see e.g. ISS-0662's design doc §5 OQ-4 openly stating what
  wasn't pinned down).

**The main-thread freeze itself — largely NOT unit-testable, and TEST-DESIGNER
should say so rather than fabricate a Vitest test that can't actually
exercise it.** A genuine main-thread timing race under React 18 StrictMode's
real double-invoke behavior, triggered by a real trusted DOM event's
dispatch-turn timing, cannot be reproduced by React Testing
Library/jsdom (jsdom has no compositor/paint pipeline and no real
event-dispatch-turn semantics — `fireEvent`/`userEvent` in RTL synchronously
call handlers with no native browser dispatch turn to be "inside," making
the ISS-0662/ISS-0729 trigger condition structurally unreachable in that
environment). What IS testable, and should be written:
- **A Playwright e2e regression test** (mirroring ISS-0662's design doc §4),
  using the real gesture from §3's protocol (`pressSequentially`, not
  `.fill()`), against `/definitions`, immediately after navigation:
  assert the fill sequence completes and `debouncedSearch`'s effect (search
  results appearing, or the empty-state text updating to reference the
  query) is visible within a bounded timeout (e.g. 5s — generous above the
  ~1-2s a healthy interaction takes, tight enough that a genuine freeze
  reliably trips it, same reasoning ISS-0662's design used). This test
  **must** run in a mode that reproduces dev/StrictMode conditions
  (`npm run dev`, not `preview`) to be meaningful for this specific issue —
  note this explicitly in the test file's own comment, since it is an
  inversion of the *general* e2e convention (ISS-0296's own resolution
  says to prefer `build && preview` for e2e stability); this one test is a
  deliberate, commented exception that must keep targeting dev mode, or it
  stops testing anything for this issue.
- Given the reproduction rate is 60-80% (not 100%), a **single** green run
  of this test is not proof of a fix — TEST-RUNNER/whoever verifies this
  fix should run it in a loop (**N=20 per §3's protocol**, not once) and
  report the actual pass count, exactly as this design's own §3 verification
  protocol requires for the fix's own validation. A single-shot CI run of
  this spec passing is necessary but not sufficient evidence; say so in the
  test file's comment so a future reader doesn't over-trust one green run.
- REQ-371's own pipeline e2e spec
  (`platform-definition-promotion-rollback.pipeline.e2e.spec.ts`) already
  exercises this exact interaction as part of its step 1 — once the fix
  lands, that spec passing (run enough times per the reproduction-rate
  caveat above) is itself part of the evidence, not a substitute for the
  narrower regression test above (the narrower test isolates the search
  interaction alone, without the rest of that pipeline's setup/state being a
  confound).

## 6. SECURITY-REVIEWER — explicitly not required, with reasoning

**No.** This fix touches four files (`DefinitionListPage.tsx`,
`useDebounce.ts` or none of it depending on §3's outcome, `DataTable.tsx`'s
existing pattern reused as-is, `highlightText.tsx`) — all client-side
rendering/UI-timing code. None of the candidate fixes in §3 touch: an API
route, a request/response shape, an auth/session boundary, tenant-scoping
logic, or any data persisted server-side. `highlightText`'s fix changes only
which array indices get wrapped in `<mark>` for already-fetched,
already-authorized search results already rendered client-side — it does
not change what data is fetched or from where. Per
`docs/agents/instructions/security-invariants.md`'s INV-1..INV-8 (tenant-data
paths, auth boundaries, secrets, response shaping), none apply here. This is
a client-side performance/correctness bug with no tenant-data or
authorization implication, stated explicitly per this role's mandate not to
silently assume a gate is unnecessary — REVIEWER (idiom/scope-creep gate)
remains the applicable gate for this change, not SECURITY-REVIEWER.

## 7. Acceptance-criteria mapping

| ISS-0729 requirement | Design element covering it |
|---|---|
| Root cause hypothesis, reasoned from actual code, not guessed | §1 (line-level read) + §2 (ranked H1-H4 with explicit reasoning and the ISS-0662 CPU/idle discrepancy) |
| Concrete fix approach, confirming or rejecting `deferClickState`'s applicability | §2 H1 + §3 Steps 1-3 (each with a fully specified concrete fix action, not left open) |
| Empirical verification protocol given the profiler can't capture a stack | §3, staged/falsifiable, N=20 runs per step, explicit escalation path if all hypotheses fail |
| `highlightText.tsx` stateful-global-regex fix | §4 (fix specified: drop `g` flag, replace `.test()` with index-parity check) |
| Regression test proving the `highlightText` fix | §5 first bullet, with an honest note that no failing-on-`main` fixture could be constructed (§4's own brute-force finding) |
| SECURITY-REVIEWER applicability stated explicitly | §6 |
| Test strategy honest about Vitest vs. e2e limits | §5, explicit on jsdom's structural inability to reproduce the trigger condition, and on the 60-80% rate meaning single-run green ≠ proof |
| REQ-371 AC6 unblocked | §3's protocol + §5's e2e test are the path to a defensible "passing," not merely "no error observed once" |

## 8. Open questions

None left unresolved in the "guessed and moved on" sense — every branch of
§3's protocol specifies its own concrete fix action for whichever hypothesis
the empirical run confirms, and §3's own escalation path (all of H1-H3 fail)
is itself the honest answer for that case, not a gap. The one genuinely
unresolved question, stated the same way ISS-0662's OQ-4 was:

- **OQ-1**: if §3 reaches its escalation branch (H1, H2, and H3 all fail to
  eliminate the freeze), the true underlying mechanism remains unknown and
  needs a real Chrome DevTools Performance trace outside a sandboxed CDP
  session — the same tooling gap ISS-0662's OQ-4 already flagged as
  unresolved for *that* issue. If both issues reach this same wall, that is
  itself worth escalating as its own finding (a standing tooling gap
  affecting more than one investigation), not re-diagnosed independently a
  third time.
