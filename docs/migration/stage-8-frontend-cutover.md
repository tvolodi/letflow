# Stage 8 — Frontend integration & cutover

Status: not started. Depends on: S7. Requirements: `REQ-115` … `REQ-122`.

**Re-scoped 2026-08-21.** This stage previously read *"`web/` itself is out of
scope to rewrite — this stage is about the integration boundary, not porting the
frontend."* That is no longer true. The frontend was migrated into this
repository on 2026-08-21 and Letflow owns it; see
[`decisions/0011-frontend-ownership.md`](decisions/0011-frontend-ownership.md)
for the full reasoning. Anything citing the old framing is stale.

## Scope

Make Letflow's own React SPA (`web/`) work against Letflow's Elixir API, and
retire the Zig backend.

1. **Point it at Letflow.** API base URL, auth-token wiring, and CORS. The
   dev-proxy default already targets `:4000`; nothing else is wired.
2. **Close the contract gaps.** This is where undocumented behaviour that the
   earlier stages' route-by-route port missed actually surfaces — a missing
   field, a different pagination cursor, a status code the UI branches on. Gaps
   are closed on the **Letflow side**, not papered over with an adapter layer
   inside `web/`.
3. **Give the frontend a CI gate.** `type-check` + `lint` + `test` + `guards`,
   the frontend counterpart of `mix letflow.check`.
4. **Reconcile the documented drift.** `web/README.md`'s "Known drift" section
   lists what arrived broken-on-paper from R-Co. Each item is either a doc
   correction or a real build task; none were silently fixed during the
   migration.
5. **Decide and execute cutover**, then deprecate the Zig backend.

## What is already true

The migrated tree stands on its own. Verified in this checkout on 2026-08-21,
Node 24.5.0 / npm 11.5.1:

| Command | Result |
|---|---|
| `npm run type-check` | clean |
| `npm run lint` (`--max-warnings 0`) | clean |
| `npm test` | 30 files, 178 tests passed |
| `npm run guards` | 3 files, 47 tests passed, includes a full `vite build` |

`npm run test:e2e` was **not** run and cannot be until this stage does its work:
Playwright needs a live backend and a Keycloak realm. Those specs (37
`*.e2e.spec.ts` files plus two shared helpers) came over intact and are a
substantial part of this stage's acceptance evidence.

## Sequencing note

S8 `depends_on: [S7]` is unchanged, and the dependency is real: S7 produces the
correctness signal that a cutover decision has to be made from. But the
migration itself did not wait for S7, and neither must the gap-closing work —
a contract gap found by loading a screen is worth fixing whenever it is found.
What waits for S7 is **cutover**, not **integration**.

## Decisions

- [`decisions/0011-frontend-ownership.md`](decisions/0011-frontend-ownership.md)
  — the frontend is migrated, not referenced. Settles the ownership question
  this stage used to leave open.
- [`decisions/0015-cutover-strategy.md`](decisions/0015-cutover-strategy.md)
   — explicit decision recorded: S7 signal is currently insufficient to choose
   big-bang or gradual/dual-running, so cutover selection is deferred until S7
   parity evidence exists.

## The guard suite is part of this stage's gate

`web/tests/guards/` enforces architectural invariants statically — no mock HTTP
adapters, no raw `fetch()` outside `api/client.ts`, no `window.confirm`, no
inline query keys, no tenant slugs in source, no `.only`/`.skip`. It is the
frontend's structural equivalent of the backend's producer/validator pairing,
and it is why a weak model can change this codebase without a human reading the
diff.

**Weakening a pattern in `tests/guards/forbidlist.ts` to make a change pass
inverts the point.** If a gap-closing change trips a guard, the change is
usually wrong. If the guard is genuinely wrong, that is a REVIEWER conversation
with a recorded rationale, not an edit.

## REVIEWER sign-off

(None yet — the stage has not started. The 2026-08-21 migration landed the code
and the re-scope; it did not begin the integration work this stage covers.)
