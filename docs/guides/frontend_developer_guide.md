# Letflow — Frontend Developer Guide

**Audience:** `FRONTEND-DEV`, `CODE-DESIGNER` (when a design touches the API contract
`web/` consumes), `REVIEWER`.

**Read this first: your scope is narrower than a typical "frontend developer guide"
implies.** Letflow does not own a frontend codebase to build UI features in. R-Co's
`web/` (React 19 + TypeScript SPA) already exists and already has the pages, components,
and API-client pattern it needs. Per `docs/migration/stage-8-frontend-cutover.md`:

> `web/` itself is out of scope to rewrite — this stage is about the integration
> boundary, not porting the frontend.

Your job is making `web/` talk to Letflow's Elixir API instead of R-Co's Zig one, and
closing contract gaps that surface in practice. This guide is deliberately short
because the work is deliberately narrow — a long guide here would itself be a sign of
scope creep.

---

## 1. What "integration" means concretely

1. **API base URL.** `web/`'s existing env-var pattern (`VITE_API_BASE_URL` or
   equivalent — check `web/.env.local` / `web/vite.config.ts` for the actual name)
   points at Letflow's running Plug/Bandit (or, post-0001, Phoenix) server instead of
   the Zig backend's port.
2. **CORS.** If the browser rejects cross-origin requests against Letflow's API, add
   CORS headers on the Letflow side (a `Plug` in `lib/letflow/router.ex`, or the
   framework-native mechanism once `docs/migration/decisions/0001-web-framework.md`
   lands) — don't work around it inside `web/`.
3. **Auth token wiring.** MVP-1 uses a dev bootstrap token (REQ-103) pasted into
   `web/`'s existing token-paste login field — this is a real path `web/`'s own spec
   (`BPM_Platform_Frontend_Requirements.md`, Constraints & Assumptions section)
   documents, not an invented shortcut. Use `web/`'s existing token storage/injection
   pattern; don't introduce a new one.
4. **Contract gaps.** If `web/` expects a response shape (a field, a status code, a
   pagination cursor format) that Letflow's API doesn't yet produce, that's a gap to
   close on the **Letflow side** (route to ELIXIR-DEV via CODE-DESIGNER) — not a reason
   to add a shim/adapter layer inside `web/` that papers over the mismatch.

## 2. What is explicitly NOT your job

- Adding new pages, components, or UI features to `web/`.
- Redesigning any existing `web/` component or interaction pattern.
- Introducing a new state-management library, routing library, or build tool into
  `web/` — it already has React Router, TanStack Query, Zustand, etc. per its own
  existing structure.
- "Improving" `web/`'s code style to match some other convention.

If a task looks like any of the above, it is either out of scope entirely (defer to
when S8 formally starts and re-scopes this), or it's actually backend work
(ELIXIR-DEV) being misrouted to you.

## 3. When a real `web/` code change is unavoidable

Occasionally closing a contract gap requires a small change inside `web/` itself (e.g.
a type in `web/src/types/api.ts` needs a new optional field). When this happens:

1. Keep the change minimal — the smallest edit that closes the actual gap.
2. Name it explicitly in your handoff's `result.summary` with a one-line reason. Don't
   let it pass silently as if it were pure config.
3. Match `web/`'s own existing conventions in that file — don't introduce a new pattern
   even for a small change.

## 4. Verification

A build that compiles (`npm run build` or the project's actual build command) is not
proof the integration works. Load the running app in a browser and confirm real data
flows from Letflow's API — per REQ-106/REQ-107's precedent, this means an actual
described browser session (what was clicked, what was seen), not just "the build
passed." `docs/guides/test_developer_guide.md`'s Directive T-2 ("real backend, not
mocked") applies to this verification too.

## 5. Self-review checklist

- [ ] Build exits 0
- [ ] No hardcoded API base URL — uses `web/`'s existing env-var pattern
- [ ] Auth token uses `web/`'s existing storage/injection pattern, not a new one
- [ ] Any change inside `web/`'s own component/type code is named explicitly with a
      reason, not silently bundled into "config wiring"
- [ ] Verified by actually loading the app and observing real data, not just a green
      build
