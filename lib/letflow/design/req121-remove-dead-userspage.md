# REQ-121 — Remove dead nested UsersPage.tsx and its now-orphaned deps

**Type:** deletion-only frontend cleanup, no new code. No Ecto schema, no DB, no
gen_statem, no public function signatures to design — this doc records the evidence
and the exact file-fate decisions per WF-02 Step 1's procedure.

## Evidence (independently re-derived, not copied from ORCH's pre-investigation)

All commands run from repo root against the working tree on
`feature/WF02-REQ121-20260823`.

### 1. Is `web/src/pages/admin/users/UsersPage.tsx` referenced anywhere in `web/`?

```
$ grep -rn "UsersPage" web/ --include=*.ts --include=*.tsx | grep -v node_modules
web/src/pages/admin/users/UsersPage.tsx:24:export default function UsersPage() {
web/src/pages/admin/UsersPage.tsx:23:export default function UsersPage() {
web/src/router.tsx:14:import UsersPage from '@/pages/admin/UsersPage'
web/src/router.tsx:58:      { path: 'admin/users', element: <UsersPage /> },
web/src/router.tsx:59:      { path: 'admin/users/:id', element: <UsersPage /> },
```

Only the two files' own `export default function UsersPage()` declarations and
`router.tsx`'s import of the **non-nested** `pages/admin/UsersPage.tsx` appear. No file
imports `pages/admin/users/UsersPage.tsx` by relative path, alias path, or bare
filename.

```
$ grep -rln "pages/admin/users/UsersPage\|users/UsersPage" web/ --include=* 2>/dev/null
web/README.md
```

The only hit outside `src/` is `web/README.md:159-161`, which is prose *documenting*
this exact dead-file finding (a "Known issues" bullet: "Duplicated admin user
pages... `pages/admin/users/UsersPage.tsx` (9 407 bytes, imported by nothing)") — not a
code reference. Confirms the finding, isn't a caller.

Test surface (tests, config, e2e, unit) — full listing of `web/tests/` and every
`__tests__`/`.test.tsx` file under `web/src/` was enumerated; none touches
`pages/admin/users/` or `admin/users/CreateUserDialog`/`DeactivateUserDialog`:

```
$ grep -rln "UsersPage\|CreateUserDialog\|DeactivateUserDialog\|UserDetailPage" web/tests
(no output — zero matches)
```

`web/src/pages/admin/users/` and `web/src/components/admin/users/` have no
`__tests__/` subdirectory (confirmed by directory listing), unlike e.g.
`web/src/pages/admin/tenants/__tests__/TenantsPage.test.tsx` which does exist for a
comparable page.

**Conclusion: zero references to `web/src/pages/admin/users/UsersPage.tsx` anywhere in
`web/` (src, tests, config, README is descriptive-only). AC1 evidence quoted above.**

### 2. `web/src/components/admin/users/` — CreateUserDialog and DeactivateUserDialog

```
$ grep -rln "CreateUserDialog" web/ --include=*.ts --include=*.tsx
web/src/components/admin/users/CreateUserDialog.tsx      (its own definition)
web/src/pages/admin/users/UsersPage.tsx                  (the dead page — its only importer)

$ grep -rln "DeactivateUserDialog" web/ --include=*.ts --include=*.tsx
web/src/components/admin/users/DeactivateUserDialog.tsx  (its own definition)
web/src/pages/admin/UserDetailPage.tsx                   (imports it)
```

`CreateUserDialog.tsx`'s only importer is the dead nested `UsersPage.tsx` — confirmed
by reading `web/src/pages/admin/users/UsersPage.tsx:4`:
`import { CreateUserDialog } from '@/components/admin/users/CreateUserDialog'`. No
other file imports it. **CreateUserDialog is dead — deleted with the page (REQ-121's
literal instruction: "if those are imported only by the dead page they are dead too and
go with it").**

`DeactivateUserDialog.tsx` is imported only by `web/src/pages/admin/UserDetailPage.tsx`
— not by either UsersPage.tsx. Is `UserDetailPage.tsx` the "live page"? Checked
`router.tsx` directly:

```
web/src/router.tsx:58:  { path: 'admin/users', element: <UsersPage /> },
web/src/router.tsx:59:  { path: 'admin/users/:id', element: <UsersPage /> },
```

Both routes resolve to the live (non-nested) `UsersPage`, imported from
`@/pages/admin/UsersPage`. `UserDetailPage` is not routed anywhere, and:

```
$ grep -rln "UserDetailPage" web/ --include=*.ts --include=*.tsx
web/src/pages/admin/UserDetailPage.tsx    (its own definition)
```

— no other file in `web/` imports `UserDetailPage.tsx` either. It is itself an orphan,
independently of REQ-121's two named pages.

## Decision: DeactivateUserDialog stays, findings routed as follow-up

**Kept.** `DeactivateUserDialog.tsx` is not deleted by this requirement.

**Reasoning, stated explicitly per the open-question resolution ORCH flagged:**
REQ-121's scope, both in its `description` and its acceptance criteria, is the two
named `UsersPage.tsx` files and `web/src/components/admin/users/`. It does not name
`UserDetailPage.tsx`, and AC2 requires either deleting the nested `UsersPage.tsx` or
reporting a discovered reference and making no deletion for *that file* — it says
nothing about deleting a third file this requirement never named. Deleting
`UserDetailPage.tsx` (and, as a consequence, `DeactivateUserDialog.tsx`) was not asked
for; doing it anyway inside this run would be exactly the kind of silent scope
expansion `core-directives.md`'s "Unblock-Everything" scope boundary reserves for a
*separate*, forwarded finding rather than an in-run fix, because `UserDetailPage.tsx`
being dead is not something blocking REQ-121's own acceptance criteria — REQ-121 is
satisfiable in full without touching it.

REQ-121's literal AC3 test ("if those are imported only by the dead page they are dead
too and go with it; if the live page imports them, they stay") was written assuming
every relevant importer is one of the two named pages. `DeactivateUserDialog` is a
genuine third case: its only importer (`UserDetailPage.tsx`) is neither the dead nested
`UsersPage.tsx` this requirement deletes, nor the live `UsersPage.tsx` `router.tsx`
actually serves. Under a literal reading of "if the live page imports them, they stay,"
`DeactivateUserDialog` does not qualify to stay (the live page never imports it) — but
under "if imported only by the dead page they go with it," it also does not qualify for
deletion (its importer isn't the dead page this requirement is deleting). The resolving
principle applied here is scope, not the literal AC3 wording taken alone: deleting a
component still imported by a file this run is not deleting would leave
`UserDetailPage.tsx` with a broken import — an unambiguous regression this run must not
introduce, whether or not `UserDetailPage.tsx` itself is reachable by any route. **A
component with a live (non-deleted) importer is kept, full stop, regardless of whether
that importer is itself routed.** `DeactivateUserDialog.tsx` therefore stays.

**Follow-up finding, out of scope for this deletion, to be reported to ORCH for
filing as its own requirement/issue (not resolved here, per `core-directives.md`'s "No
Issue Left Local-Only" and "Unblock-Everything" scope boundary):**
`web/src/pages/admin/UserDetailPage.tsx` (9-ish KB, exact size not needed for the
finding) is itself unreferenced anywhere in `web/src`, including `router.tsx` — neither
`admin/users` nor `admin/users/:id` route to it; both route to `UsersPage`. It is a
third orphan file, structurally identical to REQ-121's own motivating case, one level
deeper. If it is later deleted, `DeactivateUserDialog.tsx` should be re-examined at
that time (it would very likely become dead too, by the same test REQ-121 applies here)
— but that is a separate run's decision, made with `UserDetailPage.tsx`'s deletion
actually in scope, not this one's.

## Exact file actions

| File | Action | Reason |
|---|---|---|
| `web/src/pages/admin/users/UsersPage.tsx` | **Delete** | Zero references anywhere in `web/` (AC1 grep above) |
| `web/src/components/admin/users/CreateUserDialog.tsx` | **Delete** | Only importer is the file being deleted |
| `web/src/components/admin/users/DeactivateUserDialog.tsx` | **Keep** | Imported by `UserDetailPage.tsx`, a file this requirement does not delete (see reasoning above) |
| `web/src/pages/admin/UsersPage.tsx` | **No change** | The live page `router.tsx` imports at both `/admin/users` and `/admin/users/:id`; untouched, so AC5 (no behavioural change to the live route) holds by construction |
| `web/src/pages/admin/UserDetailPage.tsx` | **No change here** — report as a follow-up finding | Out of scope for REQ-121 (see above); orphan status is a new finding, not this requirement's job |

After the two deletions, `web/src/components/admin/users/` contains only
`DeactivateUserDialog.tsx` — the directory itself is **not** deleted, since it still
holds a live file.

## Acceptance-criteria mapping

1. **AC1** (grep quoted, zero refs before deletion) → satisfied by the "Evidence"
   section above; FRONTEND-DEV re-runs the same grep immediately before deleting, in
   its own handoff, as the final zero-refs confirmation (design doc's evidence is not a
   substitute for FRONTEND-DEV's own pre-deletion check — same "re-derive, don't
   inherit" principle CODE-DESIGN-VALIDATOR will apply to this doc).
2. **AC2** (delete, or report reference and stop) → no reference found; delete
   `web/src/pages/admin/users/UsersPage.tsx`.
3. **AC3** (fate of `web/src/components/admin/users/` decided on evidence, stated
   explicitly) → decided per file above: `CreateUserDialog.tsx` deleted (dead-page-only
   importer), `DeactivateUserDialog.tsx` kept (live importer `UserDetailPage.tsx`,
   itself out of scope) — reasoning given in full above, including the third-case
   resolution ORCH flagged.
4. **AC4** (frontend check passes, output quoted) → FRONTEND-DEV runs `npm run check`
   (`type-check && lint && test && guards`, per `web/package.json`'s `check` script)
   from `web/` after the deletion and quotes the real output in its handoff. No test
   currently exercises the two deleted files (confirmed above: no `__tests__/` under
   `pages/admin/users/` or `components/admin/users/`), so no test file needs editing or
   deleting as a consequence.
5. **AC5** (no behavioural change to live `/admin/users` route) → `web/src/router.tsx`
   and `web/src/pages/admin/UsersPage.tsx` are untouched by this change; the route
   continues to resolve to the same component it does today. FRONTEND-DEV's existing
   test suite passing (AC4's `npm test`) is the demonstration; no route-level test
   currently exists solely for this page beyond what `npm run check` already covers, so
   no new test is required by this deletion-only change (TEST-DESIGNER's Step 3 scope
   test should find no new executable surface here — this is a pure deletion, nothing
   new to write a test against).

## Non-goals / explicitly out of scope

- Deleting `web/src/pages/admin/UserDetailPage.tsx` — separate finding, report to ORCH
  for filing as its own requirement/issue, not touched by this run.
- Re-evaluating `DeactivateUserDialog.tsx` once `UserDetailPage.tsx`'s fate is decided
  — deferred to that future run.
- Updating `web/README.md`'s "Duplicated admin user pages" known-issues bullet
  (`web/README.md:159-161`) to reflect that the duplication no longer exists — this is
  documented current behavior per `core-directives.md`'s File Placement / WF-02 Step 6
  ("Update README.md if the change altered documented current behavior"), so it is
  **DOC-UPDATER's Step 6 job**, not FRONTEND-DEV's Step 2b job; flagged here so it
  isn't missed later.

## Open questions

None left unresolved. The one substantive ambiguity ORCH flagged (DeactivateUserDialog's
third-case fate) is resolved above with reasoning, not left as a "TBD."
