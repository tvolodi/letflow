# REQ-366 — Design: In-app help display panel

Stage S7. Owner: `FRONTEND-DEV`. Status: design only — no implementation code in this
document (signatures / type shapes only, per `.claude/agents/code-designer.md`).

Source of truth for scope is `docs/requirements.yaml`'s REQ-366 entry (this run's
`context.requirement_text`), plus REQ-363's landed design
(`lib/letflow/design/req363-help-content-data-model.md`) and REQ-364's landed
implementation (`lib/letflow/help.ex`, `lib/letflow/help/help_content.ex`), both read in
full for this run.

---

## 0. Premises verified against the tree (2026-09-18)

- **No HTTP route for help content exists anywhere in the tree.** `lib/letflow/help.ex`'s
  own moduledoc says so explicitly: "No HTTP route/controller wiring — REQ-364's own
  explicit scope boundary states this requirement stops at a working, tested context
  module... a route is a deliberately deferred fast-follow." Confirmed by grep: no
  `Letflow.Routers.Help` module exists, and `lib/letflow/plugs/api_pipeline.ex`'s
  `forward/2` list (lines 141-162) has no `/help` entry. **REQ-366's own requirement
  text assumes a reachable read path** ("fetches and renders the current screen's
  help_content... whichever REQ-363's design and REQ-364's read function resolve to for
  a given screen_id") but one does not exist yet. This design treats adding that route as
  in scope for this run (§1) rather than silently working around it — per WF-02 Step
  2b's own instruction ("a contract mismatch is closed on the LETFLOW side... never add a
  shim inside `web/` that normalises it"), the frontend cannot fabricate a network call
  against a route that isn't there. See §1's note on which agent implements it.
- **`platform_help_content` does not exist in the DB or in code.** Grep for
  `platform_help` across `lib/` and `priv/` returns nothing beyond REQ-363's own design
  prose. REQ-364's migration header (`priv/repo/migrations/20260917000001_create_help_content.exs`)
  confirms this is intentional and deferred to REQ-365 ("`platform_help_content`... is
  explicitly out of REQ-364's own acceptance criteria... left for REQ-365, whose own
  write path needs it to exist"). REQ-365 (`docs/requirements.yaml`, queue task 688) is
  `pending`, unclaimed as of this run. **Consequence for this design:** the resolve route
  (§1) can only query tenant-scoped `help_content` today; platform-scope resolution is
  designed as a named extension point (§1.4) filled in once REQ-365 lands, not built
  against a table that doesn't exist. See §6 for how this resolves REQ-366's AC3
  (login-routing screen, which is platform-scope content).
- `lib/letflow/help.ex`'s real function set (verified by direct read, not assumed):
  `create_draft/2`, `update_draft/3`, `publish/2`, `reconfirm/2`, `withdraw/2`,
  `get_by_screen/2` (returns `{:ok, [HelpContent.t()]}`, ALL rows for a screen_id —
  draft and live, no status filter), `get_by_process_definition_id/2` (same shape). Both
  read functions return every matching row unfiltered — resolving "the one row a panel
  should show" (status = live, most-specific match) is not something REQ-364 built; that
  resolution logic is this requirement's own job (§1.2), consistent with REQ-363's design
  §4.3 assigning the staleness *comparison* itself to REQ-366 and REQ-364's own moduledoc
  naming route wiring as deferred, not REQ-364's.
- `web/package.json` (read in full): no markdown-rendering or HTML-sanitizing package is
  currently a dependency (no `react-markdown`, `markdown-to-jsx`, `dompurify`,
  `rehype-sanitize`, or similar). This is load-bearing for §3's library recommendation —
  same "nothing to just call" situation REQ-363's design found on the backend side.
- No app-wide `<IntlProvider>` in `web/src/main.tsx` — confirmed by reading
  `web/src/i18n/EntitiesIntlProvider.tsx` and `web/src/i18n/ExamIntlProvider.tsx`, both of
  which state this explicitly in their own header comments and scope a local provider
  instead. §7 follows the same precedent.
- Router/response conventions verified against `lib/letflow/routers/exam_sessions.ex` and
  `lib/letflow/routers/onboarding.ex`: every sub-router `use`s
  `Letflow.Api.AuthorizedRouter` (not bare `Plug.Router`), declares routes via
  `authz_get/3` etc. with a compile-time `endpoint_policy_key()` atom, reads the caller's
  tenant prefix via `conn.assigns.scoped_opts` (helper `prefix!(conn)` seen in
  `exam_sessions.ex`), and renders exclusively through `Letflow.Api.Response`
  (`ok/2`, `not_found/1`, `send_problem/2`, etc. — never a hand-built JSON body).
  `lib/letflow/api/authorization.ex`'s six-role/`@permissions` closed lists (read in
  full) are the permission-matrix mechanism §1.3 extends.
- Frontend API-client convention verified against `web/src/api/exam.ts` and
  `web/src/api/client.ts`: one file per backend sub-router under `web/src/api/`, plain
  object of named functions wrapping `client.get/post/...`, types under
  `web/src/types/`. Token lives in-memory only (`client.ts`'s `_token` module variable),
  never `localStorage`/`sessionStorage` — unaffected by this design (§4 adds no new auth
  storage).

---

## 1. Backend addition required: `Letflow.Routers.Help` (cross-module dependency)

**Flagged explicitly, not silently built around:** REQ-366's `depends_on` names only
REQ-364, and its `owner` is `FRONTEND-DEV`, but §0 establishes there is no backend read
route for FRONTEND-DEV to call. This design specifies the minimal route needed. Because
`lib/letflow/routers/` and `lib/letflow/api/authorization.ex` are backend files
(`lib/letflow/`), **ELIXIR-DEV, not FRONTEND-DEV, must implement §1** in this run's own
Step 2a, running alongside FRONTEND-DEV's Step 2b — this is a routing note for ORCH, not
an assumption this design resolves by having FRONTEND-DEV touch `lib/`. §1.5 restates
this as an explicit open question so it is not missed.

### 1.1 Route

`GET /api/v1/help/resolved?screen_id=<string>[&process_definition_id=<uuid>]`, mounted by
adding `forward("/help", to: Letflow.Routers.Help)` to
`lib/letflow/plugs/api_pipeline.ex`'s existing `forward/2` list (§0), alongside the other
tenant-scoped sub-routers (i.e. inside the normal authenticated `/api/v1` chain — this is
not a public/pre-authentication route: help content, even platform-scope, is only ever
shown to an already-authenticated user browsing a screen).

`Letflow.Routers.Help` `use`s `Letflow.Api.AuthorizedRouter` (§0's mandatory mechanism —
no router in this tree bypasses `Letflow.Plugs.Authorize`):

```
authz_get "/resolved", :HelpRead do
  handle_resolve(conn)
end
```

### 1.2 Resolution algorithm (design-shape level, no implementation code)

`handle_resolve/1`:

1. Reads `screen_id` (required — 400 via `Response.bad_request/2` if missing/blank) and
   `process_definition_id` (optional) from `conn.params`.
2. `prefix = prefix!(conn)` (§0's established helper).
3. Calls `Letflow.Help.get_by_screen(screen_id, prefix: prefix)` — **not**
   `get_by_process_definition_id/2` alone, since `screen_id` is always present and is the
   primary lookup key per REQ-363 design §1.2's own stated index rationale
   ("`idx_help_content_screen`... serves the primary lookup pattern").
4. Filters the returned list, in order, to the first row satisfying (§1.2.1's tie-break,
   not left implicit):
   a. `status == :live` (a `:draft` row is never shown to an end user — REQ-363 design §2
      draft/live semantics: draft is unpublished, by construction not ready for display).
   b. If `process_definition_id` was supplied AND a live row has a matching
      `process_definition_id`, prefer that row over a live row with `process_definition_id
      == nil` (a process-specific entry outranks a generic screen entry when both exist
      and the caller identified which process it's asking about).
   c. If no row matches (b), fall back to the first live row with `process_definition_id
      == nil` (a generic, non-process-scoped entry for the screen).
   d. If multiple rows still tie (e.g. two live generic entries — REQ-363 design's OQ-1
      leaves multiplicity per screen open, §1.2.2), pick the most recently
      `updated_at`-ed one — deterministic, no arbitrary DB-order reliance. Flagged as
      **OQ-1 (frontend)**, mirroring REQ-363 design's own OQ-1: this codebase has no
      "at most one live entry per screen" invariant, so a tie-break rule has to exist;
      recording the choice here rather than leaving it to whichever row Postgres returns
      first.
5. If step 4 finds no row at all: §1.4 (platform fallback — today, always "not found").
6. If a row is found: compute `stale` (boolean) server-side —
   `row.process_definition_id != nil and row.confirmed_for_definition_version !=
   <that process definition's current :version>` (REQ-363 design §4.3's exact comparison,
   computed here rather than re-derived client-side so the frontend never needs a second
   fetch of the process definition's version just to answer one boolean). If
   `row.process_definition_id == nil`, `stale` is always `false` — no comparison target
   exists for non-process help (REQ-363 design §4.1's own stated limit; REQ-366's
   requirement text: "do not invent a comparison target that doesn't exist").
7. Render `Response.ok(conn, resolved_help_json(row, stale, scope))` (§1.6 for the JSON
   shape) or `Response.not_found(conn)` (§0's INV-5 no-detail-leak convention — same
   zero-detail shape every other router's "no such resource" case already uses) if no row
   resolved at all.

#### 1.2.1 Why a tie-break is designed explicitly here

Left implicit, an agent implementing this route would have to invent an ordering — the
exact "unstated assumption" `.claude/agents/code-designer.md` warns against leaving to
the implementer. Stated here so ELIXIR-DEV builds the one ordering this design specifies,
not whichever one seems natural in the moment.

#### 1.2.2 OQ-1 (frontend) — multiple live entries per screen

REQ-363 design's own OQ-1 (backend) already left "no uniqueness constraint on
`(screen_id, process_definition_id)`" open. This design's §1.2 step (d) supplies a
deterministic tie-break (`updated_at` descending) so the route always has *a* defined
answer, but does not resolve whether multiple live entries per screen is an intended
authoring pattern (e.g. multiple help "sections" for one screen) — if a future
requirement wants that, this route's single-row response shape (§1.6) would need to
become a list, which is a real design change, not a frontend rendering tweak. Left open,
not guessed.

### 1.3 Permission: new `:HelpRead`

Minted following the existing pattern (`lib/letflow/api/authorization.ex` §0):
- Added to `@type permission`, `@type endpoint_policy_key`, and the `@permissions` list.
- `required_permission(:HelpRead)`, `endpoint_policy_key("GET", "/help/resolved")` both
  return `:HelpRead`, mirroring `ExamSessionRead`'s own two-clause pattern (§0).
- **Granted to all six roles** (`:PLATFORM_ADMIN`, `:PROCESS_DESIGNER`,
  `:PROCESS_OPERATOR`, `:TASK_WORKER`, `:AGENT_RUNNER`, `:CANDIDATE`) — help content is a
  read-only UI affordance meant to assist every authenticated user regardless of role;
  there is no requirement-text basis for restricting it to a subset of roles (unlike
  `:TenantsManage`/`:RolesManage`, which gate genuinely privileged operations). This is a
  `role_allows?/2` clause returning `true` for `:HelpRead` unconditionally on any
  recognized role, not a per-role enumeration — same shape as any other
  every-role-grants-this permission already in that module, named here as the intended
  reading (flagged as **OQ-2** if REVIEWER judges a narrower grant is warranted instead).

### 1.4 Platform-scope fallback — extension point, not built against a missing table

Per §0's finding, `platform_help_content` does not exist. `handle_resolve/1`'s step 5
(§1.2) is therefore, in this run's implementation:

```
step 5 (today): row not found in tenant scope -> Response.not_found(conn)
```

**Once REQ-365 lands** (creates `platform_help_content` and its own
`Letflow.Help`-shaped platform read function, per REQ-365's own stated scope: "reusing
REQ-364's context-module shape... against wherever REQ-363's design placed platform
rows"), step 5 is filled in as:

```
step 5 (post-REQ-365): row not found in tenant scope
  -> call the platform-scope read function (REQ-365's, same status/tie-break rule as
     §1.2 steps 4a-4d, applied to platform rows) for the same screen_id
  -> found -> continue at step 6 with scope: :platform
  -> not found -> Response.not_found(conn)
```

This is a **small, scoped follow-up change to `handle_resolve/1`'s own body only** — it
does not touch `Letflow.Routers.Help`'s route declaration (§1.1), the response shape
(§1.6), or anything in `web/` (§2-§4): the frontend panel already renders whatever
`scope` the response reports (§1.6, §2.3) and was never written to assume tenant-only.
Named explicitly here so REQ-365's implementer has a concrete, pre-specified hook rather
than having to re-derive this route's shape from scratch. See §6 for the acceptance-
criterion consequence (AC3) this defers.

### 1.5 Open question — which agent builds §1

**OQ-3.** §1 is backend work (`lib/letflow/`) inside a requirement owned by
`FRONTEND-DEV`. This design does not silently assign it to FRONTEND-DEV (who has no
mandate to touch `lib/letflow/`, and WF-02 Step 2b's own text forbids adding a shim
instead of closing a contract mismatch on the Letflow side). Flagged for ORCH: this run's
Step 2a must include ELIXIR-DEV implementing §1 (route + permission), in parallel with
Step 2b's FRONTEND-DEV work (§2-§4), before Step 2c (SECURITY-REVIEWER — §1 is squarely a
tenant-data-path change: a new authenticated read route disclosing tenant-scoped rows,
INV-1/INV-5 relevant) can run.

### 1.6 Response JSON shape (`resolved_help_json/3`, design-shape only)

```
%{
  "id" => HelpContent.t()'s :id (string),
  "screen_id" => string,
  "process_definition_id" => string | nil,
  "title" => string,
  "body" => string,                      # markdown source, NOT pre-rendered HTML —
                                          # sanitization happens client-side too (§3),
                                          # defense in depth per REQ-366's own text
  "status" => "live",                    # always "live" -- a :draft row is never
                                          # returned by this route (§1.2 step 4a)
  "confirmed_at" => ISO-8601 string | nil,
  "confirmed_for_definition_version" => string | nil,
  "media" => [] | [map()],               # REQ-363's reserved field, passed through
                                          # verbatim -- see §5
  "scope" => "tenant" | "platform",      # "tenant" today (§1.4); "platform" once
                                          # REQ-365 lands
  "stale" => boolean                      # server-computed, §1.2 step 6
}
```

`404` (no help content resolved for this `screen_id`) and `400` (missing `screen_id`) are
the only non-2xx cases this route defines — no 403 body beyond `Response.forbidden/2`'s
existing zero-detail shape if `:HelpRead` were ever denied (not expected in practice given
§1.3's all-roles grant, but the pipeline's own `Letflow.Plugs.Authorize` always runs, §0).

---

## 2. Frontend: help trigger + panel components

### 2.1 Component tree

```
web/src/components/help/
  HelpTrigger.tsx     -- the "?" affordance, one per screen
  HelpPanel.tsx        -- the actual content panel (rendered when triggered)
  HelpMarkdown.tsx      -- §3's sanitizing markdown renderer, used only by HelpPanel
  StalenessBadge.tsx    -- §6's visible indicator, used only by HelpPanel
  useHelpContent.ts     -- the data-fetching hook (§2.2)
web/src/api/help.ts     -- API client for GET /help/resolved (§1), mirroring
                          web/src/api/exam.ts's shape (§0)
web/src/types/help.ts   -- ResolvedHelpContent type, mirroring §1.6's response shape
                          field-for-field
```

### 2.2 `useHelpContent(screenId, processDefinitionId?)` (type shapes only)

```
type ResolvedHelpContent = {
  id: string
  screenId: string
  processDefinitionId: string | null
  title: string
  body: string
  status: 'live'
  confirmedAt: string | null
  confirmedForDefinitionVersion: string | null
  media: unknown[]                 // §5 -- element shape not defined by REQ-363/366
  scope: 'tenant' | 'platform'
  stale: boolean
}

type UseHelpContentResult =
  | { status: 'loading' }
  | { status: 'not-found' }         // 404 from §1 -- a screen with no help authored yet;
                                    // NOT an error state (§2.2.1)
  | { status: 'error'; error: unknown }
  | { status: 'ready'; content: ResolvedHelpContent }

function useHelpContent(
  screenId: string,
  processDefinitionId?: string
): UseHelpContentResult
```

Built on `@tanstack/react-query` (§0's existing dependency, already the convention every
other `web/src/api/*.ts` consumer uses — no new data-fetching library). Query key:
`['help', 'resolved', screenId, processDefinitionId ?? null]` (mirrors
`web/src/api/queryKeys.ts`'s existing per-domain key-builder convention — this design adds
one key-builder entry there, not a parallel mechanism).

#### 2.2.1 404 is not an error

**Design decision, stated explicitly so FRONTEND-DEV does not render an error toast for
every screen that has no help authored yet.** Most screens will have no `help_content`
row at all in early rollout (only the login-routing screen has any real content planned,
and that's blocked on REQ-365, §6). `useHelpContent` must distinguish HTTP 404
(`status: 'not-found'`) from a genuine network/5xx failure (`status: 'error'`) — the
former renders `HelpTrigger` as either hidden or disabled-with-no-content (§2.3's own
open question, OQ-4), never an error state a user would read as "something is broken."

### 2.3 `HelpTrigger` / `HelpPanel` (component contract, no implementation)

```
function HelpTrigger(props: {
  screenId: string
  processDefinitionId?: string
}): JSX.Element
```

Renders the "?" affordance at a **consistent placement across screens** (REQ-366's own
text: "consistent placement... this requirement's own design choice, not fixed here").
**Design choice: fixed position, top-right of the screen's own content header/toolbar
region** (not a floating global corner button) — consistent with this app's existing
per-screen toolbar pattern (entities/process-designer toolbars already anchor
screen-level actions there, confirmed by `EntitiesIntlProvider`'s sibling components'
placement convention) rather than inventing a new global chrome element outside any
screen's own layout. `HelpTrigger` internally calls `useHelpContent` (§2.2) — if
`status === 'not-found'`, renders nothing (OQ-4: alternative is a disabled/greyed "?" —
left to FRONTEND-DEV's own judgement between these two, since the requirement text does
not mandate either and both are legitimate; **not** silently hidden AND not treated as an
open design question requiring a fresh decision, since neither choice touches this
requirement's own acceptance criteria).

```
function HelpPanel(props: {
  content: ResolvedHelpContent
  onClose: () => void
}): JSX.Element
```

Rendered by `HelpTrigger` on click (a side panel / popover — exact visual container,
e.g. `<dialog>` vs. a slide-in panel, is a UI-library-consistency choice FRONTEND-DEV
makes against this app's existing modal/panel components, not a new decision this design
needs to make; no new component library is introduced, per WF-02 Step 2b's own
self-review checklist: "no new state-management/routing/build tool introduced"). Renders,
in order:
1. `content.title`.
2. `<HelpMarkdown source={content.body} />` (§3).
3. `content.media` items, if any (§5) — rendered, not authored.
4. `content.stale ? <StalenessBadge kind="stale" /> : <StalenessBadge kind="reviewed" confirmedAt={content.confirmedAt} />` (§6).

---

## 3. Sanitizing markdown pipeline — library choice and mechanism

### 3.1 Library choice: `react-markdown` + `remark-gfm` + `rehype-sanitize`

No existing dependency covers this (§0). Three packages, all from the `remark`/`rehype`
unified ecosystem (the same ecosystem `react-markdown` itself is built on, not three
unrelated libraries bolted together):

- **`react-markdown`** — renders a markdown string to React elements directly. Chosen
  over any markdown-to-HTML-string + `dangerouslySetInnerHTML` approach **by
  construction**: `react-markdown` never produces an HTML string and never calls
  `dangerouslySetInnerHTML` internally (confirmed: it walks a `remark`/`rehype` AST and
  emits React elements directly via `React.createElement`) — this satisfies REQ-366's own
  explicit requirement ("no `dangerouslySetInnerHTML` on unsanitized content") as a
  structural property of the chosen library, not a rule this design has to separately
  enforce on top of it.
- **`rehype-sanitize`** — a `rehype` plugin (from the same maintainer/ecosystem,
  `unifiedjs`/`rehypejs`, as `react-markdown` itself) that walks the AST **before**
  `react-markdown` renders it and strips any node/attribute not on an explicit allowlist.
  This is the actual sanitization step REQ-366 requires as "an allowlisted
  markdown-to-React pipeline" — the requirement text's own phrase matches this plugin's
  actual mechanism (an allowlist schema, `hast-util-sanitize`'s `defaultSchema`-shaped
  object) exactly, not coincidentally: `rehype-sanitize` is the standard/canonical
  sanitizer for this exact ecosystem, used specifically to make `react-markdown` safe
  against untrusted markdown input (its own README states this as its primary use case).
- **`remark-gfm`** — adds GitHub-Flavored-Markdown extensions (tables, strikethrough,
  autolinks) `react-markdown`'s base CommonMark support doesn't include. Included so the
  frontend's rendering surface isn't narrower than what a future author might reasonably
  type; the *allowlist* (§3.2) still constrains what actually renders regardless of which
  syntax extensions are parsed — `remark-gfm` only affects what markdown *syntax* is
  recognized, never what HTML/attributes are allowed through.

**Maintenance/licence due diligence (mirrors REQ-363 design §5.4.1's own due-diligence
shape for its backend library choice):** all three packages
(`remark-gfm`/`react-markdown`/`rehype-sanitize`) are MIT-licensed, maintained under the
`remarkjs`/`rehypejs` GitHub orgs (the same unified-collective ecosystem `mdast`/`hast`
themselves come from), and are the de-facto standard choice for "render untrusted
markdown safely in React" in the current npm ecosystem — not a niche or unmaintained
pick. Pure JS, no native/WASM dependency, consistent with `web/`'s existing all-JS
dependency tree (§0: no native deps in `package.json` today).

**Flagged for REVIEWER sign-off, not self-approved** — same procedural weight as REQ-363
design §5.4.3's `earmark_parser` sign-off: this design names and justifies the choice; it
does not itself authorize adding three new dependencies to `web/package.json`.
FRONTEND-DEV's implementation must not merge without a recorded REVIEWER sign-off.

### 3.2 Allowlist schema (design-shape, no implementation code)

`rehype-sanitize`'s schema for this component starts from its own exported
`defaultSchema` (already a safe, conservative baseline — strips `<script>`,
`<style>`, all `on*` event-handler attributes, `javascript:`/`data:`/`vbscript:` URLs in
`href`/`src` by default) and is **not widened** beyond what REQ-363 design §5.2 already
defines as the allowed subset on the write side, for consistency between what the write
path accepts and what the render path trusts — even though render-time sanitization must
hold on its own regardless of what was written (defense in depth, REQ-366's own text):
tags allowed: `h1`-`h6`, `p`, `strong`, `em`, `ul`, `ol`, `li`, `a` (`href` attribute
only, scheme-restricted to `http`/`https`/`mailto` — narrower than write-time's
reject-list-of-three because render-time can afford to be an allowlist-of-schemes
instead of a denylist), `code`, `pre`, `blockquote`, `br`. No `img` tag in this
allowlist unless §5 needs it for `media` rendering (§5.2 addresses this). No raw HTML
passthrough of any other tag — matches REQ-363 design §5.2's own closed list.

### 3.3 `HelpMarkdown` component contract

```
function HelpMarkdown(props: { source: string }): JSX.Element
```

Internally: `HelpMarkdown` wraps `react-markdown`, passing `remark-gfm` as its remark
plugin and `rehype-sanitize` configured with §3.2's schema as its rehype plugin,
forwarding `props.source` as children (`helpContentSchema` = §3.2's schema object,
defined once in `HelpMarkdown.tsx`, not inlined at each call site). No other prop
accepts raw HTML or bypasses this pipeline —
`HelpPanel` (§2.3) never calls `dangerouslySetInnerHTML` anywhere in its own render path,
and this design's acceptance-criteria mapping (§8) requires a test asserting exactly that
(REQ-366's own AC2: "a test asserting a malicious payload... is neutralized in the
rendered output").

---

## 4. i18n

Per §0's confirmed precedent (no app-wide `<IntlProvider>`) and REQ-366's own text
("if this requirement's own scope needs i18n at all... scope a local provider rather than
assuming or building a new app-wide one"): **this design does not add an app-wide
provider.** `HelpPanel`/`HelpTrigger`'s own user-facing chrome strings (button labels,
"this help may be outdated", "last reviewed <date>") are few and static — following
`EntitiesIntlProvider`'s exact shape (§0), a `HelpIntlProvider` wrapping just
`HelpPanel`/`HelpTrigger`'s own subtree is added **only if** those strings need
translation; if English-only is acceptable for phase 1 (consistent with the rest of the
app per REQ-366's own text), no provider is added at all and the strings are plain JSX
text, deferring the provider to a later requirement exactly the way `main.tsx` itself
defers an app-wide one. **Left as FRONTEND-DEV's implementation-time choice between these
two, not resolved here** — REQ-366's own text explicitly permits "it may not [need i18n]"
as a valid outcome, so this design does not force a provider into existence where the
Why-section itself says one might not be warranted.

---

## 5. Media rendering (reserved field, no authoring path)

`content.media` (§1.6, §2.2) is `unknown[]` at the type level — REQ-363 design §6 defines
**no element shape**: "No element shape is defined by this requirement." This design
therefore cannot specify a concrete render function for `media` items beyond the
following, deliberately minimal, contract:

### 5.1 Render contract

`HelpPanel` renders `content.media` **only if non-empty**, via a guarded block that:
- Does nothing (renders nothing, no placeholder, no error) if `media` is `[]` — the
  common case for every row today, since no write path populates it (REQ-363 design §6,
  REQ-366's own text: "do not build any authoring path for populating it").
- If non-empty, attempts to render each item as an `<img>` if it has a recognizable
  `{ type: 'image', url: string }`-shaped entry, else skips the item silently (no crash on
  an unrecognized shape — since no shape is defined, this design cannot assume one, and a
  malformed/future-authored entry must not break the whole panel).

### 5.2 `img` and the sanitizer allowlist (§3.2)

If media rendering uses `<img>` directly (not through `HelpMarkdown`'s sanitized
markdown pipeline — media is a separate structured field, not markdown text, so it does
not pass through `rehype-sanitize` at all), its `src` attribute still needs the same
`javascript:`/`data:` scheme rejection §3.2 applies to markdown links, applied directly in
`HelpPanel`'s own media-rendering code (a small, explicit scheme check, not a second
sanitizer library) — named here so this isn't a silent gap between the two rendering
paths (markdown body vs. structured media) this component has.

### 5.3 Explicitly out of scope

No upload UI, no media-authoring form, no `POST` endpoint for populating `media` — per
REQ-366's own text and REQ-363 design §6, deferred to REQ-368 or later.

---

## 6. AC3 (login-routing screen, real browser check) — REQ-365 dependency resolution

**Explicit choice: option (b), blocked-pending-REQ-365, not option (a).** Option (a)
(directly-seeded platform-scope fixture rows via REQ-364's context module) is not
available: REQ-364's `Letflow.Help` module has no platform-scope functions and no
`platform_help_content` table exists to seed into (§0) — there is nothing to seed
directly against today. Building a throwaway platform table/seed path myself, solely to
satisfy this one AC, would duplicate REQ-365's own actual scope (which explicitly names
"wherever REQ-363's design placed platform-scope help content... this requirement adds
the write path/tooling" as REQ-365's job) — exactly the kind of unstated, silently-invented
mechanism this role is supposed to flag rather than build.

### 6.1 What this run CAN verify for AC3's underlying mechanism (tenant-scoped substitute)

The panel's fetch-and-render mechanism (§1-§3) is fully exercisable today using
**tenant-scoped** seeded content: `Letflow.Help.create_draft/2` then `publish/2` (both
real, already-implemented REQ-364 functions) against some real `screen_id` (e.g. a
constant this design does not invent — TEST-DESIGNER picks an actual existing screen id
from the SPA's own routing, at test-design time) in a test tenant schema. This proves the
full fetch -> resolve -> sanitize -> render pipeline end-to-end for the tenant-scope case,
including a real browser check and screenshot, satisfying AC3's *mechanism* even though
the *specific screen* (login-routing) and *specific content* (REQ-365's authored text)
are not yet real.

### 6.2 Concrete plan for the login-routing screen itself, once REQ-365 lands

1. REQ-365 authors and publishes real login-routing help content into
   `platform_help_content` (its own AC2: "the actual published text is quoted in this
   requirement's close-out").
2. §1.4's `handle_resolve/1` extension (platform fallback) is implemented — a small,
   pre-specified follow-up to `Letflow.Routers.Help`, not a new design.
3. FRONTEND-DEV (or a fast-follow requirement, ORCH's call at that time depending on
   whether REQ-365 lands mid-run or in a separate run) re-runs AC3's own real-browser
   check against the login-routing screen specifically and quotes the screenshot, exactly
   as AC3 demands — nothing in `HelpPanel`/`HelpTrigger`'s own code needs to change for
   this, since they render whatever `scope: "platform"` response §1.4/§1.6 returns
   identically to a `scope: "tenant"` one.

**This run's own close-out must state AC3 as BLOCKED-PENDING-REQ-365 explicitly**, not
silently marked done against the tenant-scoped substitute — §6.1's tenant-scoped check is
real, valuable verification of the mechanism, but it is not AC3 as literally written
(which names the login-routing screen and REQ-365's specific content).

---

## 7. Cross-module dependencies

- `Letflow.Routers.Help` (new, §1) depends on `Letflow.Help.get_by_screen/2` (existing,
  REQ-364) and `Letflow.Definitions.ProcessDefinition` (existing, for §1.2 step 6's
  staleness comparison — same schema REQ-363 design §4.2 already reads `:version` off).
- `lib/letflow/api/authorization.ex`'s permission/role matrix (§1.3) is a shared file
  every other router also extends — this design's change is additive only (`:HelpRead` is
  a new atom in existing lists), no existing permission's behavior changes.
- `lib/letflow/plugs/api_pipeline.ex`'s `forward/2` list (§1.1) is likewise a shared file
  with an additive-only change.
- `web/src/api/queryKeys.ts` (§2.2) gets one new key-builder entry, additive only.
- No change to `web/src/api/client.ts`'s token/auth mechanism (§0) — `help.ts` (§2.1) is a
  consumer of the existing `client.get` wrapper, nothing new.

---

## 8. Acceptance-criteria mapping

| Acceptance criterion (REQ-366, verbatim source) | Design element |
|---|---|
| help panel component exists, triggerable per-screen, fetching resolved help_content for that screen_id (tenant-scoped or platform, resolved server-side per REQ-364's read function) | §1 (new resolve route, since REQ-364 itself built no route — §0's finding), §2 (`HelpTrigger`/`HelpPanel`/`useHelpContent`) |
| markdown rendered through a sanitizing pipeline; close-out names library/approach, confirms no `dangerouslySetInnerHTML` on unsanitized content, test asserting malicious payload neutralized | §3 (`react-markdown` + `remark-gfm` + `rehype-sanitize`, named and justified; structural no-`dangerouslySetInnerHTML` argument in §3.1); test obligation stated in §3.3, actual test written by TEST-DESIGNER (Step 3) against this design |
| login-routing screen displays its help content end-to-end in a real browser check, screenshot quoted | §6 — explicitly BLOCKED-PENDING-REQ-365 (option b), with §6.1's tenant-scoped substitute proving the mechanism now and §6.2's concrete plan for the real screen once REQ-365 lands |
| process-scoped help with stale `confirmed_for_definition_version` shows visible staleness indicator, exercised for real (publish against one version, activate a new version, confirm indicator appears) | §1.2 step 6 (server-computed `stale`), §2.3 (`StalenessBadge`), §6.1's tenant-scoped seeding mechanism (`publish` against version A, then a real `ProcessDefinition` version bump, re-fetch) is exactly the exercise this AC demands — fully available today, no REQ-365 dependency |
| `npm run type-check`, `npm run lint`, `npm run test`, `npm run build` all pass, real output quoted | Not a design element — FRONTEND-DEV's own Step 2b obligation (WF-02's existing text), noted here only for completeness of the mapping |

---

## 9. Open questions

- **OQ-1** (§1.2.2) — whether multiple live help entries per screen is an intended
  authoring pattern; this design's tie-break (`updated_at` descending) makes the route
  well-defined either way but does not resolve the authoring-intent question, mirroring
  REQ-363 design's own unresolved OQ-1.
- **OQ-2** (§1.3) — `:HelpRead` granted unconditionally to all six roles; flagged in case
  REVIEWER judges a narrower grant (e.g. excluding `:AGENT_RUNNER`, which has no UI at
  all) more correct — this design's reasoning is "no requirement-text basis to narrow it,"
  not "verified narrower is wrong."
- **OQ-3** (§1.5) — which agent (ELIXIR-DEV vs. FRONTEND-DEV) implements §1's backend
  route inside this nominally-frontend-owned requirement; a routing question for ORCH,
  not a design ambiguity.
- **OQ-4** (§2.3) — whether `HelpTrigger` renders nothing or a disabled affordance when
  `useHelpContent` resolves `not-found`; left to FRONTEND-DEV's implementation-time
  judgement since neither choice affects any stated acceptance criterion.
- **OQ-5** (§6) — the concrete `screen_id` used for §6.1's tenant-scoped substitute
  verification is deliberately not picked here (this design does not invent a fixture
  value) — TEST-DESIGNER (Step 3) selects a real, existing SPA route id at test-design
  time, per its own role's access to `web/src/routes`-equivalent source, rather than this
  design guessing one that might not exist.
