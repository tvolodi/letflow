# REQ-381 — Solution-pack update review screen

Third of three requirements from the same GUI-review finding as REQ-379 (backend
write path, done) and REQ-380 (backend update-review/apply API, done). See
`test/uat-reports/gui-review-2026-09-20-template-update-conflict-resolution.md` for
the originating finding and
`lib/letflow/design/req380-pack-update-review-apply-api.md` for the endpoints this
screen wires to. This document covers **only** the frontend: two new `web/src/`
pages, their supporting components/hooks/API module, and the Playwright pipeline
spec required by REQ-381's own acceptance criteria. No backend code changes.

Design-doc-only: every code block below is a type/interface/signature shape or a
route table, never a function body, a real API call, or real JSX.

## 1. What already exists (investigated before designing anything new)

| Artefact | Status | Evidence |
|---|---|---|
| `POST /solution-packs/:pack_id/update-review` | **Shipped** (REQ-380) | `lib/letflow/routers/solution_packs.ex:181-187,375-457`. Request: `target_version`, `theirs_artefacts[]`, `incoming_artefacts[]` (all three **caller-supplied**, no server-side auto-sourcing — see §2). Response: `{pack_id, target_version, entries: [{artefact_type, artefact_id, classification, resolved}], has_unresolved_conflicts}`. `classification` wire values: `"unchanged" \| "safe_to_update" \| "local_only" \| "both_sides_conflict"`. |
| `POST /solution-packs/:pack_id/update-apply` | **Shipped** (REQ-380) | Same file, `:459-573`. Request adds `resolutions[]` (`artefact_type`, `artefact_id`, `resolution: "keep_local"\|"take_incoming"\|"merged"`, `resolved_content` required iff `"merged"`). Success `200`: `{pack_id, target_version, applied_entries: [{artefact_type, artefact_id, classification, action}], resolutions_recorded}`. `409` on any unresolved `both_sides_conflict`, detail string names `artefact_type`/`artefact_id` verbatim (`solution_packs.ex:555-562`). |
| Attribution persistence (`resolved_by`/`resolved_at`) | **Persisted, NOT returned by any HTTP response** | `lib/letflow/definitions/pack_update_resolution.ex` — the `pack_update_resolutions` row carries `resolved_by`/`resolved_at`, proven by DB assertions in `test/letflow/routers/solution_packs_update_test.exs:397-398`, but neither `update_review_response_map/3` nor `apply_result_map/1` (the router's own INV-2 response allowlists) echoes them. **This is a real gap this design must design around — see §3.3, flagged as OQ-1.** |
| A GET endpoint listing installed packs / detecting "a newer version is available" | **Does not exist** | `lib/letflow/routers/solution_packs.ex` has exactly four routes: `POST /export`, `POST /install`, `POST /:pack_id/update-review`, `POST /:pack_id/update-apply`. No `GET`. Confirmed by grep. **This design must decide how the screen learns `pack_id`/`target_version`/the incoming pack document — see §2, OQ-2.** |
| Solution-pack screens under `web/src/` | **None** | Grepped `web/src/` for `solution_pack`/`solution-pack`/`SolutionPack`/`pack` — zero relevant hits. `web/src/components/ui/ConflictResolver.tsx` is confirmed unrelated (RND-UI-06, a single-record optimistic-concurrency modal, no solution-pack concept). **There is no "company's pack screen" to reach this from yet — see §4.1, OQ-2 again.** |
| `GET /definitions/:id` (existing, unrelated requirement) | **Shipped** | `lib/letflow/routers/definitions.ex:304`. Returns one process definition's current content for the tenant. Used in §2 to source `theirs_artefacts` automatically instead of asking the admin to type it. |
| Closest frontend precedent: promotion review (PRM-02–05, ISS-0730) | **Shipped** | `web/src/pages/definitions/PromotionReviewPage.tsx` + `web/src/components/promotions/PromotionReviewStateMachine.tsx` + `web/src/components/promotions/NonSkippableApprovalGate.tsx` + `web/src/api/promotions.ts` + `web/src/hooks/usePromotions.ts`. Direct-URL-only route (no nav entry), container/presentational split, TanStack Query mutations, attribution shown via plain `approved_by`/`approved_at` string fields already returned by that API (§3.3 contrasts this with REQ-380's own response, which omits the equivalent fields). This design follows the same file-layout convention (§4). |
| Second precedent: rollback/withdrawal screen (REQ-371) | **Shipped** | `web/src/pages/definitions/DefinitionRollbackPage.tsx`. Single container page, local `useState` phase machine (`idle → confirming → submitting`), a session-local attributed history array appended to on each successful mutation (`session.display_name` + client timestamp) — the direct precedent this design's own attribution workaround (§3.3) follows. |
| Frontend conventions | **Documented** | `docs/guides/frontend_developer_guide.md` §3 (guard suite): no raw `fetch`/`axios` outside `web/src/api/client.ts`; no inline query keys (must live in `web/src/api/queryKeys.ts`); every `useQuery` wrapped in `<QueryStateBoundary>`; no `window.confirm`/`alert` (use `ConfirmDialog`). `docs/frontend/design-system.md` §8: every page wrapped in `<PageLayout title=... actions=...>`. |

## 2. How the screen sources its three inputs — OQ-2 (real, disclosed gap) and the content-canonicalization gap (OQ-4 resolution)

`update-review`/`update-apply` take `target_version`, `theirs_artefacts`, and
`incoming_artefacts` as caller-supplied JSON, with **no existing endpoint that
supplies any of the three automatically** (§1's table; REQ-380's own design doc §1/§2
already discloses this as a standing limitation it does not lift). REQ-381's
requirement text says the screen is "reachable from the company's pack screen" and
"wires to REQ-380's real endpoints — no mock data" but does not itself build a pack
inventory/version-discovery endpoint (that is backend scope, not filed anywhere yet).
This design resolves the gap as follows, **not silently** — flagged as **OQ-2** for
REVIEWER:

- **`incoming_artefacts` + `target_version`**: supplied by the admin as a pasted/
  uploaded **pack document** — the exact same JSON shape `POST /solution-packs/export`
  already produces and `POST /solution-packs/install` already consumes
  (`lib/letflow/definitions/solution_pack.ex`'s `pack_document()` type:
  `{pack_id, version, bpm_export_schema_version, definitions: [...]}`). The launcher
  page (§4.1) parses this document client-side; `target_version` comes from the
  document's own `version` field; `incoming_artefacts` is built from its
  `definitions[]` entries (`artefact_type: "process_definition"`, `artefact_id` = each
  definition's `id`/`name`, `content` = **the entry's `graph` object run through
  `canonicalizeArtefactContent` — §2.1**, not the raw decoded object). This reuses an
  existing, already-shipped document shape rather than inventing a new one.
- **`theirs_artefacts`**: sourced **automatically**, not typed by the admin — for
  every `artefact_id` present in the parsed incoming document, the launcher calls the
  existing `GET /definitions/:id` (`lib/letflow/routers/definitions.ex:304-306`,
  `handle_get_by_id/2`, `:DefinitionsRead`) for the tenant's current content of that
  same artefact. **This is the one of the two candidate endpoints this design
  actually picks** — `GET /:id` is the tenant's plain "read this definition's current
  content" route; `GET /:id/export` (`:300-302`) is a distinct concern (pack-export
  shaping) with no evidence it's the more correct source for "what does the tenant
  currently have," so `GET /:id` is used and `GET /:id/export` is not — no ambiguity
  left for build time. Its response's `"graph"` field (`definition_map/1`'s own
  object, decoded, pre-canonicalization — §2.1) is likewise run through
  `canonicalizeArtefactContent` before being placed in `theirs_artefacts[].content`.
  A `404` (tenant never had this artefact) is treated as "no theirs content" —
  omit that artefact from `theirs_artefacts` entirely, which `compute_pack_update_plan/5`
  already handles (an artefact absent from `theirs_artefacts` is simply `theirs: nil`
  in its plan entry).
- **`pack_id`**: a path segment the admin also supplies on the launcher form (it is
  the pack's own chosen string id, not derived from the document — matches
  `solution_pack_installs.pack_id`'s existing type, no format constraint).

This keeps the screen honest about what's real: it does NOT claim to auto-detect
"a newer version is available" (no endpoint could tell it that), but it DOES
auto-source the tenant's own current content rather than asking a human to paste it
by hand, which is the part a human genuinely cannot be expected to type correctly.
**A true installed-pack inventory / automatic new-version-detection screen is
follow-up scope**, noted for REQ-ANALYST to file separately if wanted — not invented
here.

### 2.1 Content canonicalization — a real gap, resolved by porting the algorithm to TypeScript (was OQ-4)

**The defect this section fixes.** Neither `GET /definitions/:id`'s `"graph"` field
nor the pack document's `definitions[].graph` field is canonical-JSON text — both are
plain decoded JSON objects. `lib/letflow/definitions/solution_pack.ex`'s own
`@type packed_definition` has `graph: map()`, and its `@type artefact_snapshot`'s doc
comment says `content` is "the artefact's own delivered content,
**pre-canonicalization**." `lib/letflow/routers/definitions.ex`'s `definition_map/1`
(`GET /:id`) and `export_document_map/1` (`GET /:id/export`) both emit
`"graph" => <the raw map>` — neither canonicalizes. The actual canonical string that
`base_content` is stored as, and that `classify_artefact/3`
(`lib/letflow/definitions.ex`) byte-compares against, comes from
`canonicalize_artefact_content/1` → `canonicalize_json/1`
(`lib/letflow/definitions/solution_pack.ex:1542-1565`):

1. A map has its keys sorted (`Enum.sort/1` on `Map.keys/1`, then rebuilt via
   `Jason.OrderedObject.new/1` so the sorted order survives encoding).
2. A list is mapped over recursively, order preserved (never sorted).
3. An atom (excluding booleans/`nil`) is converted via `Atom.to_string/1`.
4. Anything else (string, number, boolean, `nil`) passes through unchanged.
5. The whole structure is then `Jason.encode!/1`'d (default output, no insignificant
   whitespace).

This is `defp`, Elixir-only, never exposed over HTTP, and not replicated anywhere
under `web/src/` today (grepped for "canonicaliz" — zero hits). Since
`classify_artefact/3` requires **literal equality** between `base`/`theirs`/`incoming`
content strings, sending un-canonicalized `JSON.stringify(graph)` output (whatever key
order the JS engine happens to produce) would systematically misclassify artefacts —
a truly `unchanged` artefact could show as `both_sides_conflict` from whitespace/
key-order alone. This is resolved here, not deferred, because it is load-bearing for
AC1/EO-001 and AC4/EO-004 correctness.

**Resolution: port the algorithm to TypeScript.** A new shared utility,
`web/src/lib/canonicalizeArtefactContent.ts` (same `web/src/lib/` location as the
codebase's other single-purpose pure helpers — `classifyError.ts`,
`jsonSchemaToZod.ts`, §1's guide reference):

```ts
// web/src/lib/canonicalizeArtefactContent.ts

// Input: an already-JSON-decoded value (object/array/string/number/boolean/null) —
// e.g. GET /definitions/:id's response.graph, or a pack document's
// definitions[].graph. This is the type of value fetch()/JSON.parse() ever produce;
// there is no JS equivalent of an Elixir atom for this function to handle, so step 3
// of canonicalize_json/1 has no TS counterpart and is intentionally omitted (see
// "steps that don't carry over" below) — not a partial port, a complete one for the
// input shape this function will ever actually receive.
type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue }

// Recursively sorts object keys (Object.keys(...).sort(), the same default
// lexicographic/code-unit ordering JS provides with no comparator argument),
// preserves array element order, passes strings/numbers/booleans/null through
// unchanged, then JSON.stringify()s the result with no separators/indentation
// argument (JSON.stringify's default output already has no insignificant
// whitespace, matching Jason.encode!/1's default).
declare function canonicalizeArtefactContent(value: JsonValue): string
```

Steps that don't carry over from `canonicalize_json/1`, spelled out explicitly so
nothing is silently dropped: step 3 (atom → string) has no JS input to apply to,
because every value `canonicalizeArtefactContent` will ever receive is already
plain decoded JSON (never an Elixir term) — this is a property of the two call
sites (§2's bullets), not an assumption this function makes about its argument.

**Byte-for-byte equivalence is not free — it must be proven, not assumed, and this
is flagged explicitly for REVIEWER/TEST-DESIGNER as the residual risk of this whole
resolution:**

- **Key ordering.** `Enum.sort/1` on Elixir binaries orders by UTF-8 byte value;
  JS's default `Array.prototype.sort()` on strings orders by UTF-16 code unit value.
  These coincide for ASCII keys (which is what process-definition graph keys are in
  every case this codebase currently produces — `id`, `type`, `nodes`, `edges`,
  transition/node ids, etc. — grepped `lib/letflow/definitions/graph.ex`'s own
  `"nodes"`/`"edges"`/`"id"`/`"node_type"` field-name literals to confirm no
  non-ASCII field names exist) but are **not guaranteed identical** for
  keys containing non-BMP (astral-plane) characters. This is a real, disclosed risk,
  not resolved further here — the golden-fixture test below (bullet 3) must include
  at least one non-ASCII key case so the risk is measured, not assumed away.
- **Number formatting.** `Jason.encode!/1` encodes Elixir numbers via Erlang's
  shortest-round-trip float/integer formatting; `JSON.stringify` encodes JS numbers
  via V8's (or the runtime's) own shortest-round-trip formatting. These coincide for
  integers within `Number.MAX_SAFE_INTEGER` and typical decimal floats, but are a
  second real risk for large integers or edge-case floats — also required in the
  golden-fixture set.
- **String escaping.** Both `Jason.encode!/1` and `JSON.stringify` use minimal
  (non-HTML-safe) JSON string escaping by default; verified, not assumed, by
  including control characters and multi-byte UTF-8 strings in the golden-fixture
  set.
- **Verification mechanism (required before this can be considered done, not
  optional polish):** a checked-in golden-fixture file, e.g.
  `test/fixtures/canonical_json/golden_cases.json` — an array of
  `{name, input}` cases covering: nested objects with keys needing reordering, mixed
  ASCII/non-ASCII keys, arrays (order-preserving), booleans/`null`, small and large
  integers, decimal floats, empty object/array, and strings with control characters
  and multi-byte UTF-8. TEST-DESIGNER adds (a) an ExUnit test that, for each case,
  round-trips the input through `capture_artefact_bases/5` (the only existing public
  seam that reaches the private `canonicalize_artefact_content/1` —
  `lib/letflow/definitions/solution_pack.ex:1505` — since a test cannot call a `defp`
  directly) and reads back `base_content`, recording the resulting canonical string
  into the same golden file's `expected` field per case (a small `mix` task or
  `iex -S mix` snippet regenerates it — implementation detail for ELIXIR-DEV, not
  designed further here); and (b) a Vitest test at
  `web/src/lib/__tests__/canonicalizeArtefactContent.test.ts` that loads the same
  golden file and asserts `canonicalizeArtefactContent(input) === expected` for
  every case, matching this codebase's existing `<dir>/__tests__/<name>.test.ts`
  convention (`web/src/api/__tests__`, `web/src/hooks/__tests__`, §1's precedent
  list). An unverified reimplementation of a byte-exact-matching algorithm is itself
  a risk — this golden-fixture cross-check is what retires it, and it must exist
  before this design is considered complete, not deferred as a follow-up.

**Why Option A (port) over Option B (new backend surface):** REQ-381's own scope
fence is frontend-only, and REQ-380 (the backend surface this screen wires to) is
already done and closed — reopening it for a purely additive "give me the canonical
string too" field is possible (e.g. widening `definition_map/1`/pack-document export
to add a canonical text field) but is a backend change this requirement's text does
not ask for. Porting is fully within REQ-381's own file scope (`web/src/lib/` only)
and, per the risk analysis above, is provably verifiable via the golden-fixture
cross-check rather than trusted blindly. **Flagged for REVIEWER, same disclosed-
judgment-call discipline as OQ-1/OQ-2/OQ-3**: if REVIEWER prefers Option B (a
canonical-string-emitting backend field) instead, that is a small, additive backend
change to `lib/letflow/routers/definitions.ex` (and, for the pack-document side, to
whatever produces `pack_document()`s) reusing
`canonicalize_artefact_content/1`/`PromotionDigest.canonicalize/1`'s own algorithm
server-side — out of this design's chosen path, but not invented as a silent
alternative; a follow-up requirement would be needed since it touches a router this
design does not otherwise change.

## 3. Wire types (mirror the backend response/request shapes exactly — INV-2 discipline applies to the frontend too: no field this screen doesn't name)

```ts
// web/src/api/solutionPacks.ts

type PackArtefactClassification =
  | 'unchanged'
  | 'safe_to_update'
  | 'local_only'
  | 'both_sides_conflict'

type PackUpdateAction = 'advanced_to_incoming' | 'advanced_to_merged' | 'left_unchanged'

type PackResolutionChoice = 'keep_local' | 'take_incoming' | 'merged'

interface PackArtefactInput {
  artefact_type: string
  artefact_id: string
  content: string
}

interface PackUpdateReviewRequest {
  target_version: string
  theirs_artefacts: PackArtefactInput[]
  incoming_artefacts: PackArtefactInput[]
}

interface PackUpdateReviewEntry {
  artefact_type: string
  artefact_id: string
  classification: PackArtefactClassification
  resolved: boolean
}

interface PackUpdateReviewResponse {
  pack_id: string
  target_version: string
  entries: PackUpdateReviewEntry[]
  has_unresolved_conflicts: boolean
}

interface PackResolutionInput {
  artefact_type: string
  artefact_id: string
  resolution: PackResolutionChoice
  resolved_content: string | null
}

interface PackUpdateApplyRequest extends PackUpdateReviewRequest {
  resolutions: PackResolutionInput[]
}

interface PackUpdateAppliedEntry {
  artefact_type: string
  artefact_id: string
  classification: PackArtefactClassification
  action: PackUpdateAction
}

interface PackUpdateApplyResponse {
  pack_id: string
  target_version: string
  applied_entries: PackUpdateAppliedEntry[]
  resolutions_recorded: number
}

// 409 detail shape (RFC 9457, parsed by client.ts into ApiError.details):
// "unresolved conflict on artefact_type=<type> artefact_id=<id>" — parsed by a
// dedicated regex helper, parseUnresolvedConflictDetail(detail: string):
//   { artefactType: string; artefactId: string } | null
// (mirrors DefinitionRollbackPage.tsx's classifyRollbackError's own exact-string/
// regex convention over err.details.detail — never err.message).
```

### 3.1 API module

`web/src/api/solutionPacks.ts` — one small module per backend concern, matching
`definitionRollback.ts`/`promotions.ts`'s own precedent:

```ts
solutionPacksApi.updateReview(
  packId: string,
  body: PackUpdateReviewRequest,
): Promise<PackUpdateReviewResponse>

solutionPacksApi.updateApply(
  packId: string,
  body: PackUpdateApplyRequest,
): Promise<PackUpdateApplyResponse>

// Existing generic definitions endpoint, reused (not new) — sources theirs_artefacts,
// §2. Returns the decoded graph object, NOT a canonical string — the caller (§4.1)
// runs it through canonicalizeArtefactContent (§2.1) before placing it in
// theirs_artefacts[].content.
solutionPacksApi.fetchTenantArtefactGraph(
  artefactType: string,
  artefactId: string,
): Promise<{ graph: Record<string, unknown> } | null>   // null on 404, per §2
```

### 3.2 Query keys (`web/src/api/queryKeys.ts` addition — guard-enforced, no inline keys)

```ts
solutionPackUpdate: {
  all: ['solutionPackUpdate'] as const,
  review: (packId: string, targetVersion: string) =>
    [...queryKeys.solutionPackUpdate.all, 'review', packId, targetVersion] as const,
}
```

### 3.3 Attribution — OQ-1 resolution (flagged, not silently guessed)

REQ-380's response shapes never echo `resolved_by`/`resolved_at` (§1's table). EO-003
requires the screen to show "who/when" for a `keep_local` decision. Two components,
neither of which requires a backend change:

1. **Session-local attribution, captured at the moment of decision** — when the
   current user submits a resolution via the Apply gate (§5), the frontend already
   knows who (the authenticated session's `display_name`/`sub`, same source
   `DefinitionRollbackPage.tsx`'s own local history panel already uses — see §1's
   table) and when (client `Date.now()` at submission). This is held in a
   `Map<artefactKey, {resolvedBy: string; resolvedAt: string}>` local component state
   (§5.2) and rendered next to that artefact's entry immediately after a successful
   apply (§6.3) — this is what makes EO-003 literally true within the one review→
   resolve→apply session flow the scenario itself drives (steps 4–5 then
   verification, same session, same as `platform-definition-promotion-*` specs'
   own single-session pattern).
2. **Explicit, disclosed limitation**: this session-local attribution does **not**
   survive a page reload or a different browser session — a user who reloads the
   review screen, or a different admin who opens it later, sees `resolved: true` on
   that entry (from the API) but no who/when, because the API genuinely does not
   carry it. The UI renders this fallback state as "Resolved by a previous decision
   (attribution not available — server does not return resolved_by/resolved_at yet)"
   rather than fabricating a value. **This is OQ-1, explicitly not resolved by this
   requirement** — a follow-up backend requirement (widening
   `update_review_response_map/3`'s `plan_entry_map/1` to also echo
   `resolved_by`/`resolved_at`, and `apply_result_map/1`'s applied-entry map likewise)
   would close it without a breaking change (additive fields only, same note REQ-380's
   own design doc already makes about widening `entries[]` — §3.3 there). Filed here
   for REQ-ANALYST to pick up if a durable attribution display is wanted; not invented
   as a fake endpoint.

## 4. Component breakdown

Follows the `pages/<domain>/` (route-bound container) + `components/<domain>/`
(presentational) + `api/<domain>.ts` + `hooks/use<Domain>.ts` split the promotions/
rollback precedents already establish (§1's table).

### 4.1 `web/src/pages/solution-packs/SolutionPackUpdateLauncherPage.tsx` (container)

Route: `/solution-packs` (new nav entry — since no "company's pack screen" exists
yet, per §1/§2 OQ-2, this page **is** the minimal form of that screen: it is not a
full pack inventory, only the entry point REQ-381's own text requires). Responsibility:

- A `pack_id` text input (admin-typed, matches the existing `POST /install` flow's
  own convention of a caller-chosen string).
- A pack-document paste/upload control (JSON textarea or file input — reuses
  `JsonEditor`, `docs/frontend/design-system.md` §7's existing component) producing
  the parsed `pack_document()` shape (§2).
- Client-side parse validation: rejects a document missing `version` or
  `definitions[]`, or one whose `bpm_export_schema_version` isn't recognised — same
  error vocabulary `render_install/2`'s `{:error, :invalid_pack_document}`/
  `{:error, {:unknown_schema_version, _}}` already uses, reused here as a **client-
  side pre-check** only (the actual `update-review` call still performs the same
  validation server-side; this is a fast-fail UX convenience, never a substitute).
- On submit: derives `theirs_artefacts` per §2 (one `GET` per artefact id via
  `fetchTenantArtefactGraph` — a `Promise.all`-style fan-out, each wrapped by the
  shared `client.ts`, §3.1 — each returned `graph` passed through
  `canonicalizeArtefactContent`, §2.1, to produce `content`), and derives
  `incoming_artefacts` the same way from the parsed pack document's own
  `definitions[].graph` fields (§2.1), then navigates to the review page (§4.2),
  passing `packId`/`targetVersion`/the parsed-and-canonicalized
  `incoming_artefacts`/the fetched-and-canonicalized `theirs_artefacts` via
  `react-router-dom`
  `navigate(path, { state })` — held in router state, not re-typed by the user on
  the next page, and not persisted to `localStorage` (this payload can contain
  tenant process content, no different sensitivity from any other in-memory-only
  API response this app already holds).
- Role gate: `PLATFORM_ADMIN` only, `<Navigate>` redirect otherwise — same pattern
  `PromotionReviewPage.tsx`/`DefinitionRollbackPage.tsx` both already use, matching
  REQ-380's own `:DefinitionsCreate`-gated apply route (§1 of the REQ-380 design,
  `PLATFORM_ADMIN`/`PROCESS_DESIGNER` hold write; this screen restricts further to
  `PLATFORM_ADMIN` only, since it is the tenant-admin-equivalent surface the
  scenario's own `actor-platform-admin` names — a narrower, safe default, flagged
  for REVIEWER same as REQ-380 §3.1/§4.1's own "reuses closest policy key" judgment
  calls).

### 4.2 `web/src/pages/solution-packs/SolutionPackUpdateReviewPage.tsx` (container)

Route: `/solution-packs/:packId/update-review` (reached only via the launcher's
`navigate(..., { state })`, same "direct-URL-only, no independent deep link without
state" constraint `PromotionReviewPage.tsx` itself accepts — if `location.state` is
absent (e.g. a raw URL paste), the page renders a "start a new review from the pack
list" empty state rather than crashing, and does NOT attempt to silently re-derive
the missing input).

Responsibility:
- Reads `packId` from `useParams`, and `targetVersion`/`incomingArtefacts`/
  `theirsArtefacts` from `location.state` (typed via a `SolutionPackReviewLocationState`
  interface).
- `useSolutionPackUpdateReview(packId, targetVersion, theirsArtefacts, incomingArtefacts)`
  (§4.5) — a `useQuery` wrapping `solutionPacksApi.updateReview`, wrapped in
  `<QueryStateBoundary>` (guard-enforced, §1's table).
  Note: this is a `useQuery` over a `POST` body — the same pattern the codebase
  already accepts for `compute_pack_update_plan/5`'s pure/read-only classification
  (REQ-380 §3.1's own "read-only, :DefinitionsRead" framing); `queryFn` issues the
  `POST`, `enabled: !!targetVersion`.
- Local resolution-decision state (§5.2) + `useSolutionPackUpdateApply` mutation
  (§4.5).
- Renders `<PageLayout title="Review pack update">` containing, in order:
  `<UpdateReviewGroupList>` (§4.3), the apply gate (`<UpdateApplyGate>`, §4.4), and
  — once an apply has succeeded in this session — `<UpdateAttributionPanel>` (§4.3.4).

### 4.3 `web/src/components/solution-packs/UpdateReviewGroupList.tsx` (presentational)

Props:

```ts
interface UpdateReviewGroupListProps {
  entries: PackUpdateReviewEntry[]
  resolutionChoices: Map<string, PackResolutionChoice>       // keyed by `${type}:${id}`
  onChooseResolution: (artefactType: string, artefactId: string, choice: PackResolutionChoice) => void
  attribution: Map<string, { resolvedBy: string; resolvedAt: string }>  // session-local, §3.3
  appliedEntries: PackUpdateAppliedEntry[] | null   // non-null once an apply has succeeded
}
```

#### 4.3.1 Four-group display logic (EO-001)

Partitions `entries` into exactly the four `classification` wire values, one
`data-testid`-tagged section per group, group heading names the count
(`"Unchanged (N)"`, `"Safe to update (N)"`, `"Your own change (N)"`,
`"Changed on both sides (N)"`) — matching the scenario's own step-3 language
("unchanged, safe to update, the company's own change with nothing coming from the
pack, and changed on both sides"). Each entry row shows `artefact_type`/
`artefact_id` (no raw content diff is required by any acceptance criterion; if
`JsonDiffView`, §1's ConflictResolver precedent, is reused for a nice-to-have
before/after view, it needs `base`/`theirs`/`incoming` content, which the review
response does NOT return — §3.2 of REQ-380's design explicitly scoped that out. A
content diff is therefore **out of this requirement's scope**, consistent with
REQ-380's own disclosed scope fence; the screen shows classification/status,
not a diff body).

#### 4.3.2 `both_sides_conflict` sub-partition — resolved vs unresolved (EO-002 / EO-005)

Within the fourth group, entries split further by their own `resolved` boolean:

- `resolved: false` → rendered under a "Needs a decision" subsection, each with the
  keep/take resolution control (§5).
- `resolved: true` → rendered under an "Already resolved" subsection, no control,
  attribution shown if present in the `attribution` map (§3.3), else the disclosed
  fallback string (§3.3 point 2). **This is EO-005's display**: a same-`target_version`
  re-review after a prior apply shows the resolved entry here, not re-presented as
  needing a fresh decision.

#### 4.3.3 `local_only` and `unchanged` groups (EO-004)

Rendered read-only, no control — these are exactly the "untouched" artefacts
EO-004 concerns. After an apply, re-fetching the review (§4.2's query, invalidated
on apply success) must show these unchanged in both `classification` and
`resolved` — the assertion the e2e spec checks (§7).

#### 4.3.4 `UpdateAttributionPanel` (EO-003)

A small sub-component, rendered only once `appliedEntries` is non-null: for every
`kept_local` decision made in this session (i.e. present in `attribution`), shows
`"<artefact_id> kept as-is by <resolvedBy> at <formatDateTime(resolvedAt)>"` — reuses
`formatDateTime` from `@/i18n/format`, same helper `PromotionReviewStateMachine.tsx`'s
own `MetadataItem` already uses for `approved_at` (§1's table).

### 4.4 `web/src/components/solution-packs/UpdateApplyGate.tsx` (presentational, blocking-apply UX — EO-002)

Props:

```ts
interface UpdateApplyGateProps {
  hasUnresolvedConflicts: boolean
  unresolvedCount: number
  onApply: () => void
  applyState: 'idle' | 'submitting'
  blockedDetail: { artefactType: string; artefactId: string } | null  // from a 409, §3
}
```

- The Apply button (`Button variant="primary"`) is `disabled={hasUnresolvedConflicts
  || applyState === 'submitting'}` — a **client-side** pre-block, mirroring
  `DefinitionRollbackPage.tsx`'s own `canContinue`-gated Continue button (§1's
  table). `hasUnresolvedConflicts` is computed identically to
  `has_unresolved_conflicts` server-side (any `both_sides_conflict` entry with
  `resolved: false` AND no resolution chosen this session) — recomputed from
  `resolutionChoices` (§4.3) as choices are made, so the button re-enables live as
  the admin resolves each conflict, without waiting on a server round-trip.
- **Server-side block is still authoritative** (EO-002's actual acceptance
  criterion: "shows the endpoint's named unresolved process"): even though the
  client pre-blocks, `onApply` always fires the real `update-apply` call when
  clicked-while-enabled; if the server itself returns `409` (e.g. a race, or a
  conflict the client-side computation didn't yet know about), `blockedDetail` is
  populated via `parseUnresolvedConflictDetail` (§3) and rendered as a named banner:
  `"Update blocked — <artefactType> <artefactId> still needs a decision."` — this is
  the literal on-screen text the acceptance criterion and EO-002's `verification.detail`
  ("shows a message naming the process that still needs one") requires, and it is
  driven from the endpoint's own response, never a client-only guess.
- No update is applied in the blocked case — the mutation's `onError` does not
  invalidate the review query, so nothing on screen changes except the banner
  (matches REQ-380's "applies nothing in that case" all-or-nothing semantics, §1's
  table).

### 4.5 `web/src/hooks/useSolutionPackUpdate.ts`

```ts
useSolutionPackUpdateReview(
  packId: string,
  targetVersion: string,
  theirsArtefacts: PackArtefactInput[],
  incomingArtefacts: PackArtefactInput[],
): UseQueryResult<PackUpdateReviewResponse, ApiError>

useSolutionPackUpdateApply(): UseMutationResult<
  PackUpdateApplyResponse,
  ApiError,
  { packId: string; body: PackUpdateApplyRequest }
>
// onSuccess: invalidateQueries(queryKeys.solutionPackUpdate.review(packId, targetVersion))
//   — forces the re-fetch that makes EO-004/EO-005's "after apply" assertions real,
//   not a locally-patched cache guess.
```

## 5. Keep/take-per-process resolution interaction

### 5.1 Control shape (per unresolved `both_sides_conflict` entry, §4.3.2)

A three-way radio/segmented control: **Keep ours** (`keep_local`) / **Take theirs**
(`take_incoming`) / **Merge manually** (`merged`, optional — REQ-381's own
acceptance criteria only require keep/take "at minimum," per its description; a
`merged` choice, if offered, opens a text/JSON editor for `resolved_content` and is
otherwise out of this requirement's required-path testing, §7). No default
selection — an entry with no choice made is still `resolved: false` client-side and
still blocks apply (§4.4).

### 5.2 Local state shape (`SolutionPackUpdateReviewPage`)

```ts
type ArtefactKey = string   // `${artefact_type}:${artefact_id}`

interface ResolutionDraft {
  choice: PackResolutionChoice
  resolvedContent: string | null   // non-null only when choice === 'merged'
}

// Component state:
resolutionDrafts: Map<ArtefactKey, ResolutionDraft>
sessionAttribution: Map<ArtefactKey, { resolvedBy: string; resolvedAt: string }>  // §3.3
applyPhase: 'idle' | 'submitting'
blockedDetail: { artefactType: string; artefactId: string } | null
```

### 5.3 Submission shape (on Apply click, `hasUnresolvedConflicts === false`)

`resolutions[]` sent on the `update-apply` call is built from `resolutionDrafts`
(only entries the admin actually made a choice for in this session — an
already-`resolved: true` entry from a prior session is NOT re-submitted, matching
REQ-380's own first-attribution-wins immutability, `lib/letflow/design/req380-...md`
§4.3 step 3/OQ-3: resubmitting a different choice for an already-resolved artefact
is silently a no-op server-side, so this design does not bother re-sending it).
`theirs_artefacts`/`incoming_artefacts` sent unchanged from what the review call
used (§2's already-fetched values, held in page state — REQ-380 §4.2 requires them
on every apply call, "same shape as the review call").

## 6. State-shape summary (whole-page)

```ts
interface SolutionPackReviewLocationState {
  targetVersion: string
  theirsArtefacts: PackArtefactInput[]
  incomingArtefacts: PackArtefactInput[]
}

interface SolutionPackUpdateReviewPageState {
  // from route + navigation state:
  packId: string
  targetVersion: string
  theirsArtefacts: PackArtefactInput[]
  incomingArtefacts: PackArtefactInput[]
  // query:
  review: PackUpdateReviewResponse | undefined   // via useSolutionPackUpdateReview
  // resolution UI:
  resolutionDrafts: Map<ArtefactKey, ResolutionDraft>
  sessionAttribution: Map<ArtefactKey, { resolvedBy: string; resolvedAt: string }>
  // apply UI:
  applyPhase: 'idle' | 'submitting'
  blockedDetail: { artefactType: string; artefactId: string } | null
  lastAppliedEntries: PackUpdateAppliedEntry[] | null
}
```

## 7. Router entry

```
{ path: 'solution-packs', element: <SolutionPackUpdateLauncherPage /> },
{ path: 'solution-packs/:packId/update-review', element: <SolutionPackUpdateReviewPage /> },
```

Add both to `web/src/router.tsx`'s route table, alongside the existing
`definitions/:id/promotions/:reviewId` entry (§1's precedent). A nav-menu entry for
`/solution-packs` is in scope (unlike `PromotionReviewPage.tsx`'s deliberate
no-nav-entry choice) — REQ-381's own text requires the review screen be "reachable
from the company's pack screen," and §4.1 makes the launcher page serve that role,
so it needs a discoverable nav link, not a direct-URL-only route.

## 8. e2e test scenario design (`web/tests/e2e/pipelines/template-update-conflict.pipeline.e2e.spec.ts`)

Follows the `pl.step`/`pl.gate`/`createPipeline` convention every existing spec in
`web/tests/e2e/pipelines/` uses (`platform-definition-promotion-conflict-rejected...
.spec.ts` read in full as the structural precedent). Real backend, `BPM_TEST_URL`,
`getKeycloakToken`/`loginWithToken`, no mocks — matches REQ-381's own "wires to
REQ-380's real endpoints — no mock data."

### 8.1 Chain topology

1. **Setup** — login as `PLATFORM_ADMIN` (or the scenario's own
   `actor-platform-admin` fixture equivalent), resolve tenant context (matches
   `resolveTenantContext` helper).
2. **Install a pack version 1** — `POST /solution-packs/install` with a document
   containing three artefacts (`unchanged-proc`, `adapted-proc`, `untouched-proc`),
   via `request.post` (API-level, matching how the promotion specs create their own
   fixture data directly against the API rather than through a GUI form, since the
   scenario's own steps 1/preconditions are `via: system`/setup, not GUI).
3. **Adapt one process** — via the existing definitions-update path (`PUT`/`POST
   /definitions/:id`, whatever the existing mutation route is — reused, not
   invented), so the tenant's live content for `adapted-proc` differs from the
   installed base, while `unchanged-proc` stays byte-identical.
4. **Publish pack version 2** — build the incoming pack document: changes
   `adapted-proc` (this is the artefact that will land in `both_sides_conflict`,
   matching the scenario's step 1: "changes one of the two processes the company
   already adapted") and `untouched-proc` (lands in `safe_to_update`, matching
   step 1's other clause), leaves `unchanged-proc` identical (lands in `unchanged`).
5. **`pl.step` "EO-001 — review shows all four groups"**: `navigateSpa` to
   `/solution-packs`, fill the launcher form (`pack_id`, paste the v2 document),
   submit, land on the review page. Assert via `page.getByTestId(...)` that
   `adapted-proc` appears under the `both_sides_conflict`/"Needs a decision"
   section, `untouched-proc` under `safe_to_update`, `unchanged-proc` under
   `unchanged` — `pl.gate` on each locator's visibility/text.
6. **`pl.step` "EO-002 — blocked apply names the unresolved process"**: click Apply
   with no resolution chosen. `pl.gate` that the review page's own URL/content is
   unchanged (nothing navigated away, nothing applied) and that the blocked-apply
   banner text contains `adapted-proc`'s artefact id, sourced from the real `409`
   response (§4.4) — not a client-only guess.
7. **`pl.step` "step 5 / EO-003 + EO-004 — resolve, apply, verify"**: choose "Keep
   ours" on `adapted-proc`, leave `untouched-proc`'s decision as its default
   `safe_to_update` classification requires no decision at all (only
   `both_sides_conflict` entries need one), click Apply. `pl.gate` on `200`
   response. Assert on screen: `adapted-proc` shows under "Already resolved" with
   attribution text containing the logged-in admin's display name and a recent
   timestamp (EO-003); `unchanged-proc`'s content/version display (if surfaced —
   `artefact_id` and `classification` at minimum, per §4.3.3) is unchanged from
   step 5's assertion (EO-004).
8. **`pl.step` "EO-005 — re-review does not re-flag the resolved process"**:
   navigate back to `/solution-packs`, resubmit the SAME v2 document/`target_version`
   (a same-version re-review, matching the requirement text's exact wording, §... "a
   further update offered afterwards" interpreted as the same offered version being
   looked at again — the backend's own `resolution_exists?/5` is keyed by exact
   `target_version`, `lib/letflow/definitions.ex:513-523`, so a genuinely different
   future version is out of this scenario's scope, per §3 of this document). `pl.gate`
   that `adapted-proc` is present under `both_sides_conflict`/"Already resolved", NOT
   under "Needs a decision" — the literal EO-005 assertion.
9. **Cleanup** — none required beyond what the scenario's own `cleanup:
   cancel_open_instances: false` already states (matches
   `test/fixtures/uat/scenarios/platform/template-update-conflict-resolution.yaml`'s
   own cleanup block) — pack installs/resolutions are not instance state.

### 8.2 EO-to-assertion mapping (summary table for TEST-DESIGNER/TEST-DESIGN-VALIDATOR)

| EO | Scenario step(s) | Spec step | Concrete assertion |
|---|---|---|---|
| EO-001 | step 2/3 | §8.1.5 | All three fixture artefacts appear under their correct one of the four `data-testid`-tagged group sections |
| EO-002 | step 4 | §8.1.6 | Apply-with-no-resolution leaves the page unchanged; blocked-apply banner names `adapted-proc`'s real artefact id, sourced from the live `409` |
| EO-003 | step 5 ("keep our version") | §8.1.7 | Post-apply, `adapted-proc` shows under "Already resolved" with attribution text naming the actor and a timestamp |
| EO-004 | step 5 ("take the new version" on the untouched process) + implicit unchanged-artefact check | §8.1.7 | `unchanged-proc`'s displayed classification/id is identical before and after apply |
| EO-005 | (post-scenario, "a further update offered afterwards") | §8.1.8 | Same-`target_version` re-review shows `adapted-proc` under "Already resolved", not "Needs a decision" |

## 9. Fixture NOTE removal

Once this screen is built, wired to REQ-380's real endpoints (no mocks), and the
Playwright spec (§8) passes against a real running instance, remove the entire NOTE
block (lines 29–56, the ISS-0527 note plus its 2026-09-20 UPDATE addendum) from
`test/fixtures/uat/scenarios/platform/template-update-conflict-resolution.yaml` —
the file's own last line already names the removal condition verbatim: "This NOTE
stays in place (not removed) until REQ-381 ships a real screen to remove it
against." Nothing else in that file changes (the header provenance comment, the
`pipeline_test` field's value, and every line from `actors:` onward stay
byte-identical — the file was ported verbatim from R-Co and that constraint is
independent of this requirement).

## 10. Open questions (explicit, not silently resolved)

- **OQ-1** (§3.3): REQ-380's response shapes never echo `resolved_by`/`resolved_at`.
  This design satisfies EO-003 within a single review→resolve→apply session via
  client-captured attribution, and explicitly degrades (documented fallback text,
  not a fabricated value) for a resolution made in an earlier session. A follow-up
  requirement widening `update_review_response_map/3`/`apply_result_map/1` to echo
  those two fields would close this cleanly and additively.
- **OQ-2** (§2/§4.1): no endpoint lists installed packs or detects an offered newer
  version. This design's `SolutionPackUpdateLauncherPage` is a manual entry form
  (admin pastes/uploads the new pack document), not a real "your installed packs,
  here's what's new" inventory screen. That inventory is real, wanted, future scope
  — not built here, and not faked with mock data.
- **OQ-3**: role gate on the launcher/review pages is `PLATFORM_ADMIN`-only (§4.1),
  narrower than REQ-380's own `:DefinitionsCreate` apply-route gate (which also
  admits `PROCESS_DESIGNER`). Flagged for REVIEWER, same "narrower-than-the-API,
  disclosed, not silently decided" pattern REQ-380's own design doc uses for its own
  policy-key reuse calls (§3.1/§4.1 there).
- **OQ-4** (resolved, §2.1): neither `GET /definitions/:id` nor
  `GET /definitions/:id/export` returns canonical-JSON text — both return a decoded
  `graph` object, pre-canonicalization. This design ports the server's
  `canonicalize_json/1` algorithm to a new `web/src/lib/canonicalizeArtefactContent.ts`
  utility (applied to both `theirs_artefacts` and `incoming_artefacts` content before
  either is sent), verified against the real algorithm via a checked-in
  cross-language golden-fixture test (ExUnit + Vitest, §2.1). `GET /definitions/:id`
  (not `/export`) is the one endpoint used for `theirs_artefacts` — a concrete choice,
  not left open. Two residual risks (key-order and number-format equivalence between
  Elixir and JS) are disclosed in §2.1, not silently assumed away, and are exactly
  what the golden-fixture test set is required to cover. Flagged for REVIEWER: an
  alternative (a small additive backend field emitting the canonical string directly)
  was considered and rejected in favor of staying within REQ-381's frontend-only
  scope fence — §2.1's closing paragraph.
