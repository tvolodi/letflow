# `web/` — Letflow frontend

React 18 + TypeScript 5 + Vite single-page application. This is **Letflow's own
frontend**, not a vendored read-only copy: changes to it are made here, reviewed
here, and merged here.

## Provenance

Migrated from R-Co (`c:\Users\tvolo\dev\ai-dala\R-Co\web\`) on **2026-08-21** as
part of the S8 re-scope. See
[`docs/migration/decisions/0011-frontend-ownership.md`](../docs/migration/decisions/0011-frontend-ownership.md)
for why the frontend became Letflow-owned rather than staying in R-Co, and
[`docs/migration/stage-8-frontend-cutover.md`](../docs/migration/stage-8-frontend-cutover.md)
for the stage that now covers it.

The migration copied R-Co's **git-tracked** `web/` files only, minus run
output that R-Co tracked but which is not a baseline:

| Not carried over | Why |
|---|---|
| `tests/screenshots/` (92 tracked files, 16 MB) | Written by `page.screenshot()` as debug evidence. Nothing asserts against them — there is no `toHaveScreenshot()` anywhere in the suite. |
| `tests/reports/` | a11y/guard run output, regenerated on every run. |
| `handoffs/`, `eo004-screenshots/`, `*-test-output.txt`, `test_output.log` | R-Co agent-run artifacts and captured console logs. |
| `*.tsbuildinfo`, `dist/`, `node_modules/` | Build artifacts. |

All four are now in `.gitignore` so they cannot creep back in.

Four things were changed on arrival, and nothing else:

1. `package.json` name `bpm-web` → `letflow-web`.
2. `index.html` title `R-Co` → `Letflow`.
3. `AppShell.tsx` sidebar brand `R-Co` → `Letflow`.
4. `vite.config.ts` dev-proxy default target `http://localhost:8080` (R-Co's Zig
   backend) → `http://localhost:4000` (Letflow's Plug/Bandit server).

Everything else is byte-identical to R-Co. Actually *pointing* the app at
Letflow's API — auth wiring, CORS, and the contract gaps that will surface — is
S8 requirement work, not part of this copy. **The app does not yet function
end-to-end against Letflow**, because Letflow's API surface (S4) is still being
built.

## Verified state at migration

Run on 2026-08-21 in this checkout, on Node 24.5.0 / npm 11.5.1, after
`npm ci` (502 packages):

| Command | Result |
|---|---|
| `npm run type-check` | clean, no output |
| `npm run lint` | clean, no output (`--max-warnings 0`) |
| `npm test` (vitest) | **30 files, 178 tests passed** |
| `npm run guards` | **3 files, 47 tests passed** (includes a full `vite build`) |

`npm run test:e2e` (Playwright) was **not** run: it needs a live backend and a
Keycloak realm, and Letflow's API doesn't serve those routes yet. Those specs are
carried over intact and become runnable during S8.

## Running it

```
cd web
npm ci
cp .env.example .env.local     # then edit
npm run dev                    # http://localhost:5173
```

The dev server proxies `/api` and `/health` to `VITE_API_BASE_URL`
(default `http://localhost:4000`), so start Letflow first:

```
# from the repository root
LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt
```

See [`.env.example`](.env.example) for every environment variable the app reads.

## Scripts

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

## Layout

```
src/
  api/          one module per resource; every call goes through api/client.ts
  auth/         OIDC (oidc-client-ts), tenant resolution, token handling
  components/   canvas/ (React Flow process designer), forms/ (schema-driven
                renderer), instances/, layout/, promotions/, ui/, webhooks/
  hooks/        TanStack Query wrappers, polling
  pages/        one per route — see src/router.tsx
  stores/       Zustand (canvas history, definition drafts)
  types/        API and form-schema types
  utils/        canvas layout, CEL editor language, error classification
tests/
  unit/         vitest component tests
  e2e/          Playwright, needs a live backend
  a11y/         axe configuration and the a11y gate
  guards/       static-analysis specs (below)
  specs/        test specs carried from R-Co
```

## The guard suite is load-bearing

`tests/guards/` enforces architectural invariants by scanning source and the
built bundle against a single pattern list in `tests/guards/forbidlist.ts` — no
mock HTTP adapters (`msw`, `axios-mock-adapter`), no raw `fetch()` outside
`api/client.ts`, no `window.confirm/alert/prompt`, no inline query keys or stale
times, no tenant slugs hardcoded in source, no `.only`/`.skip` left behind.

This is the frontend's structural equivalent of the backend's
producer/validator pairing: it catches whole classes of drift without a human
reading the diff. **Don't weaken a pattern to make a change pass** — that
inverts the point. Add to `forbidlist.ts` when you find a new class of mistake,
the same way `docs/anti-patterns.md` works on the backend.

## Known drift carried over from R-Co

Recorded honestly rather than silently fixed — each is a candidate S8
requirement, not something this migration changed:

- **React version — fixed by `REQ-119`.** `docs/frontend/frontend-requirements.md`
  and `docs/guides/frontend_developer_guide.md` used to say "React 19". The
  installed and locked version is **React 18.3.1** (`web/package-lock.json`).
  Both docs now state 18.3.1; this entry is kept as a record of the drift that
  existed at migration, not as a live discrepancy.
- **No stylesheet exists yet — decided by `REQ-120`, built by a follow-on
  requirement (`impl_order: UNREGISTERED`, pending `REQ-VALIDATOR`).**
  `docs/frontend/design-system.md` §2 says all colours live as CSS custom
  properties in `web/src/styles/tokens.css`. That file does not exist and
  never did — there is no `.css` file in `src/` at all, and components use
  inline `style={{...}}` objects with literal hex values. The `literal-colour`
  guard pattern only matches CSS-style declarations ending in `;`, so inline JS
  style strings slip past it. `REQ-120`
  (`lib/letflow/design/req120-design-token-source.md`) settled the question:
  `design-system.md` §2's palette is the one source of truth —
  `design-tokens/letflow.tokens.json` is superseded (smaller, and disagrees
  with §2's palette on the same semantic colours) and inline styles are
  rejected as "no design system at all." Building `tokens.css`, migrating the
  47 components that currently use inline hex literals (496 occurrences, real
  count from `grep -rEon "#[0-9a-fA-F]{3,8}" web/src/components/ --include='*.tsx' --include='*.ts'`),
  deleting `design-tokens/letflow.tokens.json`, and tightening the
  `literal-colour` guard to catch inline JS style literals (not just
  semicolon-terminated CSS declarations) is that follow-on requirement's scope
  — drafted in `docs/requirements.yaml` but not yet registered with a queue
  task id. The design system stays aspirational in exactly the place it claims
  to be enforced until that follow-on requirement lands.
- **Bundle size.** The production build emits a single 1.66 MB chunk
  (442 kB gzipped) and Vite warns about it. No code-splitting is configured
  beyond one lazy `autoLayout` chunk.
- **Orphaned `UserDetailPage.tsx`.** `pages/admin/UserDetailPage.tsx` is
  unreferenced by `src/router.tsx` (both `/admin/users` and `/admin/users/:id`
  route to the live `pages/admin/UsersPage.tsx`). It in turn is the only
  importer of `components/admin/users/DeactivateUserDialog.tsx`, which is
  otherwise unused. Flagged by `REQ-121`'s investigation as a third dead file
  outside that requirement's scope (only `pages/admin/users/UsersPage.tsx` and
  `components/admin/users/CreateUserDialog.tsx` were named there, and both
  have since been deleted) — not yet resolved.
- **`design-tokens/letflow.tokens.json` is wired to nothing — superseded by
  `REQ-120`, deletion is the follow-on requirement's scope, not yet deleted.**
  Carried over from R-Co's `design-tokens/r-co.tokens.json`. No source file,
  test, or build step reads it, and its palette disagrees with the
  `--color-neutral-*` scale in `docs/frontend/design-system.md` on shared
  semantic colours (e.g. `primary: #2563EB` here vs. `--color-brand-600:
  #228be6` there). `REQ-120` decided `design-system.md`'s palette is the one
  source of truth; this file is not adopted and is deleted by the follow-on
  requirement that builds `tokens.css`, not by `REQ-120` itself.
