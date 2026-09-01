# Design: REQ-212 — Instance-attachment route surface (POST/GET/DELETE /api/v1/instances/:id/attachments)

**Requirement:** REQ-212 (`docs/requirements.yaml:12144-12220`, stage S6,
`depends_on: [REQ-211, REQ-069, REQ-072, REQ-070]`)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the route/controller layer atop REQ-211's shipped
`Letflow.Repository.Attachments` context module — route definitions, request/response
shapes, the multipart-upload parsing mechanism, the two new permissions
(`AttachmentsManage`/`AttachmentsRead`) added to `Letflow.Api.Authorization`'s matrix,
and the two-distinct-check tenant/instance 404 scoping logic. **No implementation
code** — no function bodies, no `.ex`/`.exs` file contents. ELIXIR-DEV writes the
actual code from this document at Step 2a.

**NOT in this document:** no change to `Letflow.Repository.Attachments`,
`Letflow.Repository.Attachment`, or their migrations (REQ-211's scope, already shipped
and `done` — this document does not reopen it). No `web/` frontend work.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-212's full entry (lines 12144-12220) — description and
  all 9 acceptance criteria, read in full.
- `lib/letflow/design/req211-instance-attachments-core.md` in full — the binding
  contract this route layer builds on. Key facts this design depends on, confirmed
  directly against the *shipped* code (not the design doc's own earlier, now-corrected
  draft — REQ-211's design doc itself records a revision where an earlier version's
  §4.3 was wrong before ORCH's §2A addendum fixed it):
    - `Letflow.Repository.Attachments.upload/2` — `@spec upload(upload_attrs(), opts()) ::
      {:ok, Attachment.t()} | {:error, :file_too_large} | {:error, Ecto.Changeset.t()}`.
      `upload_attrs()` requires `:instance_id, :raw_bytes, :file_name, :content_type,
      :uploaded_by`, optional `:description`.
    - `Letflow.Repository.Attachments.list/2` — `@spec list(list_params(), opts()) ::
      {:ok, %{items: [Attachment.t()], next_cursor: String.t() | nil}} | {:error,
      :invalid_cursor | :wrong_endpoint | :expired | :page_size_too_large}`.
      `list_params()` requires `:instance_id`, plus `:cursor`/`:page_size`.
    - `Letflow.Repository.Attachments.get/2` — `@spec get(id :: String.t(), opts()) ::
      {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}`. **Returns metadata
      only** (`Attachment.t()` — `id, tenant_id, instance_id, content_hash, file_name,
      content_type, byte_size, uploaded_by, description, created_at`), never byte
      content.
    - `Letflow.Repository.Attachments.delete/2` — `@spec delete(id :: String.t(),
      opts()) :: {:ok, Attachment.t()} | {:error, :invalid_id | :not_found}`.
    - `Letflow.Repository.Attachments.opts()` = `[prefix: String.t()]`, every function's
      only tenant input.
    - `@max_upload_bytes 26_214_400` (25 MiB) — the module's own ceiling, enforced
      inside `upload/2` on the measured `raw_bytes` size. REQ-211's design §4.4
      explicitly asks this route layer to configure its own multipart parser `:length`
      at or near this same ceiling as a consistency note (§4 below).
    - `get/2`'s own moduledoc states the concrete byte-retrieval mechanism this route
      layer must use (design §4.3, confirmed against the shipped module's `@doc` on
      `get/2`, `lib/letflow/repository/attachments.ex:256-268`): call `get/2` (or
      `list/2`) to obtain `attachment.content_hash`, then perform a **second, separate**
      lookup — `Repo.get(Letflow.Repository.Artifact, content_hash, prefix: prefix)` —
      against `repository_artifacts`, reading its `content` field (the `:bytea` column
      REQ-211's §2A addendum added, confirmed present in the shipped
      `lib/letflow/repository/artifact.ex` schema module read for this design). This
      module never performs that second lookup itself — it is explicitly this route
      layer's job.
- `lib/letflow/repository/attachment.ex` (shipped) — confirms `Attachment.t()`'s exact
  field list used for §3's response-shape allowlist below.
- `lib/letflow/repository/artifact.ex` (shipped, current state after REQ-211's §2A) —
  confirms `Letflow.Repository.Artifact` now has `field(:content, :binary)` alongside
  `content_hash` (primary key, `:binary`), `tenant_id`, `content_type`, `byte_size` —
  the second-lookup target §4.3/§5 below reads.
- `lib/letflow/routers/dlq.ex` (REQ-178, shipped) and `lib/letflow/routers/webhooks.ex`
  (REQ-181/182, shipped) — the two most recent core/route-split precedents, read in
  full. Conventions this design reuses verbatim:
    - `use Letflow.Api.AuthorizedRouter`, routes declared via `authz_get`/`authz_post`/
      `authz_delete` with a compile-time-literal policy-key atom (never a plain
      `get`/`post`/`delete` — every route in this router gets a real policy key, no
      allowlist entry needed).
    - `{"items": [...], "next_cursor": ...}` exactly-two-key list-response shape (DLQ's
      own moduledoc states this is deliberately not `CursorPage<T>`'s fuller shape —
      REQ-212 has no existing TS consumer type to match either way, so this design just
      states the shape directly, §3.2).
    - A hand-built response allowlist function (`dlq_entry_json/1`'s pattern) — never a
      raw `Jason.Encoder` derivation over an Ecto struct, which would leak `__meta__`/
      `tenant_id`. Directly load-bearing here: REQ-212's AC1 explicitly forbids leaking
      raw `content_hash` bytes into the upload/list response (§3 below).
    - `:invalid_id` (malformed UUID) and `:not_found` both fold to the same
      `Response.not_found/1` call — DLQ's own moduledoc states this explicitly for the
      same cross-tenant-probeable-UUID reasoning REQ-212's AC5/AC6 restate for
      attachment/instance ids.
    - Webhooks' `authz_patch`/`authz_delete` usage confirms `AuthorizedRouter` supports
      every verb this design needs (`authz_post`, `authz_get`, `authz_delete` — REQ-212
      needs no `authz_put`/`authz_patch`).
- `lib/letflow/routers/instances.ex` (REQ-078/079/080, shipped) — the sub-router this
  design mounts into (§1 below). Read in full for: the "MUST precede any future bare
  `POST /:id` / `GET /:id`" route-ordering hazard its own moduledoc documents (§1.2
  below applies the same discipline to `/attachments`); its INV-5 cross-tenant-404
  statement (`Letflow.Api.Response.not_found/1` takes no detail, so a cross-tenant and
  a genuinely-missing instance are the same call, same bytes); its `scoped_repo_opts/1`/
  `actor_id/1` helper pattern (`Context.scoped_repo_opts/1`,
  `conn.assigns.auth_context.user_id`) reused directly, §5.4; and its
  `Response.internal_error/1`-catches-everything-else discipline for INV-4.
- `lib/letflow/plugs/api_pipeline.ex` (shipped) — confirms `/instances` is mounted via
  `forward("/instances", to: Letflow.Routers.Instances)` at line 59, and confirms the
  **only** existing body-size ceiling anywhere in this pipeline is `Plug.Parsers`'s
  `[:json]`-only, 2 MB (`2_097_152`) cap, scoped to `Letflow.Plugs.ApiPipeline` itself.
  This module's `Plug.Parsers` declaration does not include a `:multipart` parser at
  all today — §2 below is a genuinely new mechanism, not a reuse of an existing one.
  Grepped `lib/` for `multipart`/`Plug.Upload` (`grep -rn "multipart\|Plug.Upload"
  lib/`) — the only hits are REQ-211's own design doc's forward-looking prose citing
  this exact gap; zero hits in any `.ex` source file. Confirms REQ-211's design's own
  claim that there is no multipart precedent in this codebase to match.
- `lib/letflow/design/req070-router-decomposition.md` — confirms `Letflow.Routers.
  Instances` is the sub-router `/instances`-prefixed routes belong on (`forward
  "/instances", to: Letflow.Routers.Instances` in `ApiPipeline`, table at line 128) —
  this design does not add a new top-level sub-router.
- `lib/letflow/api/authorization.ex` (REQ-069, shipped) — the matrix this design
  extends. Confirmed current shape: `permission()` is a 16-atom closed union (14 R-Co
  ports + `WebhooksManage`/`DlqOperate` + REQ-076's `RolesManage`);
  `endpoint_policy_key/2` maps `{method, path_template}` to an `endpoint_policy_key()`
  atom; `required_permission/1` maps that atom to exactly one `permission()`;
  `role_allows?/2` is the 5-role matrix. `DlqOperate`/`WebhooksManage` were both ported
  *ahead of* their consuming routes (REQ-069's own moduledoc: "ported anyway so the
  matrix matches R-Co's exactly") — **REQ-212's two permissions are the opposite case,
  genuinely new atoms with no R-Co counterpart, added *for* this requirement's own
  routes, not pre-ported** — stated explicitly per the requirement's own instruction to
  name this distinction (§6 below).
- `lib/letflow/api/authorized_router.ex` (REQ-131, shipped) — confirms `authz_get/3`/
  `authz_post/3`/`authz_delete/3` macro shape, that `Letflow.Plugs.Authorize` runs for
  every route unconditionally, and that every route in a router using this module
  either carries a policy key or must be named on the enforcement test's allowlist —
  this design gives every one of its four routes a real policy key (§6), so no
  allowlist entry is needed.
- `lib/letflow/api/context.ex` (REQ-072, shipped) — `Context.scoped_repo_opts/1`'s
  exact contract (`{:ok, prefix: schema_name} | {:error, :missing_auth_context |
  :invalid_tenant_id}`, tenant id read **only** from
  `conn.assigns[:auth_context][:tenant_id]`, never from the request) — the sole
  mechanism this design uses to derive `opts[:prefix]/opts` passed into every
  `Letflow.Repository.Attachments` call (§5.1/§7 INV-1).
- `lib/letflow/api/response.ex` (REQ-066, shipped) — the response-helper contract:
  `ok/2`, `created/2`, `not_found/1` (no detail — INV-5), `unprocessable/2`,
  `forbidden/2`, `internal_error/1` (no detail — INV-4), `send_json/3`. **No existing
  helper sends a raw-bytes/non-JSON body** — `send_json/3` always calls
  `Jason.encode!/1`. §3.3/§5.3 below therefore call `Plug.Conn.put_resp_content_type/2`
  + `Plug.Conn.put_resp_header/3` + `Plug.Conn.send_resp/3` directly for the
  byte-content GET route, the same primitives `Letflow.Api.Response` itself is built
  from — **not** a new helper added to that module (see §7 OQ-2: this document does not
  resolve whether a shared `Response.send_binary/4`-shaped helper should be extracted).
- `lib/letflow/routers/metrics_exposition.ex` (REQ-194, shipped) — the one existing
  precedent in this codebase for a route sending a non-JSON body directly via
  `put_resp_content_type/2` + `send_resp/2` rather than through `Letflow.Api.Response`.
  Confirms the mechanism compiles and runs in this codebase already, though for a
  different reason (Prometheus text, not binary file content, and outside
  `AuthorizedRouter`/tenant scoping entirely) — this design's use of the same
  `Plug.Conn` primitives (§3.3) is not a novel mechanism in this codebase, just a novel
  *combination* with tenant-scoped, authorized routing.
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation), INV-2
  (no unintended data exposure via a response allowlist), INV-4 (no detail-bearing
  500), INV-5 (cross-tenant 404, not 403) all directly apply to this route surface
  (§7 below).

---

## 1. Mount point

**`Letflow.Routers.Instances`** (`lib/letflow/routers/instances.ex`) — REQ-212 adds
four new routes to this existing sub-router, mounted at `/instances` by
`Letflow.Plugs.ApiPipeline` (line 59). This is the correct mount per the requirement's
own instruction and per §0's `req070-router-decomposition.md` confirmation: the
resource is instance-scoped (`/api/v1/instances/:id/attachments...`), matching every
other instance-scoped route already on this router (`/:id/history`, `/:id/timeline`,
`/:id/pins`), and `Plug.Router.forward/2` is prefix-exclusive so a separate
`Letflow.Routers.Attachments` sub-router could not be mounted under `/instances` at
all — the same reasoning this router's own moduledoc already gives for why pin-rebind
has no separate sub-router.

**No new top-level `forward` entry in `Letflow.Plugs.ApiPipeline`** — this design adds
zero lines to that module.

### 1.1 Full paths

| Method | Path | Policy key (§6) |
|---|---|---|
| `POST` | `/api/v1/instances/:id/attachments` | `:AttachmentsManage` |
| `GET` | `/api/v1/instances/:id/attachments` | `:AttachmentsRead` |
| `GET` | `/api/v1/instances/:id/attachments/:attachment_id` | `:AttachmentsRead` |
| `DELETE` | `/api/v1/instances/:id/attachments/:attachment_id` | `:AttachmentsManage` |

### 1.2 Route-ordering hazard — must be checked against this router's existing routes

`Letflow.Routers.Instances`'s existing moduledoc states a hard ordering constraint:
`/:id/rebind-pins`, `/:id/cancel`, `/:id/reconstruct` (all `POST`) must precede any
future bare `post "/:id"`, and `/:id/history`, `/:id/timeline`, `/:id/pins` (all `GET`)
must precede the existing `get "/:id"`/`get "/"` pair, because `Plug.Router` matches
declaration order within one HTTP-method dispatch table.

This design's four new routes are **all literal path suffixes** under `/:id/` — none
of them collides with the existing bare `/:id` routes' *matching*, because
`/:id/attachments` and `/:id/attachments/:attachment_id` are distinct, longer literal
templates from plain `/:id`, exactly like the already-shipped `/:id/history` etc. But
**this router's existing `get "/:id"` (line 204) and `authz_post "/"` do not currently
exist below any `/:id/attachments...` declaration**, so ELIXIR-DEV must declare this
requirement's four new routes **above** the existing bare `authz_get "/:id"` (line
204) and, for the `POST` route specifically, the relative order versus `authz_post
"/"` (line 184, a *different* path template, `/` vs `/:id/attachments` — no collision
possible, order-independent) does not matter. **Concretely: place the four new routes
immediately after the existing `/:id/pins` block (line 202) and before the existing
`authz_get "/:id"` (line 204)** — this preserves every existing route's relative order
unchanged (Unblock-Everything discipline: this is an additive change to a shared file,
not a rewrite) and keeps the new `/:id/attachments/:attachment_id` GET/DELETE pair
above the bare `/:id` GET that would otherwise swallow `attachments` as a literal `:id`
value.

---

## 2. Multipart upload handling — the concrete mechanism

**No existing multipart precedent exists in this codebase (§0) — this is a fresh
mechanism, stated concretely per the assigning agent's instruction.**

### 2.1 Why a scoped `Plug.Parsers` addition, not a change to `Letflow.Plugs.ApiPipeline`'s existing declaration

`Letflow.Plugs.ApiPipeline`'s current `Plug.Parsers` declaration
(`plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 2_097_152)`) runs
**once**, before `:match`/`:dispatch`, for **every** request across **every**
sub-router mounted under `/api/v1` — DLQ, webhooks, tasks, everything. `Plug.Parsers`
itself supports multiple parser modules in one list (`parsers: [:json, :multipart]`),
each trying to claim the request based on its `Content-Type`, so it is technically
possible to add `:multipart` to this one shared declaration.

**This design does not do that.** Two reasons, both stated explicitly rather than
silently deciding:

1. **Length ceiling collision.** `Plug.Parsers`'s `:length` option is a single
   per-plug-instance value applied to whichever parser claims the request. Today's `2
   MB` value is sized for JSON API bodies (`ApiPipeline`'s own comment: "large enough
   for any single-workflow payload"). REQ-211's design already establishes this
   module's own ceiling must be **25 MiB** (`@max_upload_bytes`, independent of the
   JSON cap, design §4.4) — one shared `Plug.Parsers` declaration cannot carry two
   different `:length` values for two different content types reaching the same plug
   instance.
2. **Blast radius.** Every other route on every other sub-router would silently start
   accepting 25 MiB multipart bodies if the shared declaration's ceiling were simply
   raised to accommodate attachments — a DoS-surface change with no acceptance
   criterion asking for it, affecting subsystems (DLQ, webhooks, tasks) this
   requirement has no business touching.

**Mechanism: a second, route-scoped `Plug.Parsers` plug, mounted inside
`Letflow.Routers.Instances` itself, applied only to the `POST
/instances/:id/attachments` route.** `Plug.Router`'s `plug/2` macro supports a `guard`/
scoping via `Plug.Builder.plug/2`'s standard per-plug options, but the simplest,
most-precedented shape in this codebase (matching how `Plug.Parsers` is already
invoked exactly once, declaratively, at module scope in `ApiPipeline`) is:

- **`Plug.Parsers` is NOT re-declared as a second plug in `Letflow.Routers.Instances`'s
  own plug pipeline**, because `Letflow.Api.AuthorizedRouter`'s `__using__/1` macro
  (§0) already fixes this router's plug chain to exactly `plug(:match)`,
  `plug(Letflow.Plugs.Authorize)`, `plug(:dispatch)` — inserting a third plug ahead of
  `:match` would need to change that shared macro, which is out of this requirement's
  scope and would affect every other `AuthorizedRouter`-based router.
- **Instead, `Letflow.Plugs.ApiPipeline`'s existing `Plug.Parsers` declaration is
  extended to a two-parser list, `parsers: [:json, :multipart]`, keeping `length:
  2_097_152` as the shared floor for the `:json` branch, and multipart's *own*, larger
  ceiling is enforced by this module's own code path, not by `Plug.Parsers`'s
  `:length` option at all.** `Plug.Parsers`'s `:length` option is a single value
  shared across every parser module invoked from one `Plug.Parsers` declaration — it
  cannot itself express two different ceilings for two different content types. This
  design's actual size enforcement for uploads is **REQ-211's `upload/2` itself**
  (`@max_upload_bytes 26_214_400`, already shipped and already the authoritative
  ceiling per that module's own design §4.4, which explicitly anticipates exactly this
  situation: "a caller of this context module that is not the REQ-212 route... must
  get the same rejection" and "REQ-212's own route layer, when built, should
  additionally configure its multipart parser's own `:length` option **at or near**
  this same ceiling" — a consistency recommendation, not a requirement that the two
  numbers be mechanically identical). **This design sets `Plug.Parsers`'s own `:length`
  for the multipart branch to `26_214_400` (the same 25 MiB constant, duplicated as a
  literal in `ApiPipeline` with a comment cross-referencing
  `Letflow.Repository.Attachments.@max_upload_bytes`, since `Plug.Parsers` options must
  be compile-time literals and cannot reference another module's private module
  attribute)** — this makes `Plug.Parsers` itself reject an oversized multipart body
  before it is even fully read into memory (a `Plug.Parsers.RequestTooLargeError`,
  §2.3 below), which is a stronger DoS defense than only rejecting after full buffering
  inside `upload/2`. **Both ceilings must be changed together if `@max_upload_bytes`
  ever changes** — named here explicitly as a two-file synchronization hazard for a
  future reader (flagged for REVIEWER at Step 2d, since this duplicates a numeric
  constant across module boundaries, the same class of judgment call REQ-211's design
  flagged its own `@max_upload_bytes` choice for).
- `Plug.Parsers`'s `:multipart` parser is the plug's own built-in
  `Plug.Parsers.MULTIPART` module (ships with the `plug` dependency already in this
  project's `mix.exs` — no new dependency). No explicit `:multipart` module reference
  is needed in the parser list; the atom `:multipart` resolves to it exactly as `:json`
  resolves to `Plug.Parsers.JSON`.

### 2.2 What the route handler receives

`Plug.Parsers`'s multipart branch populates `conn.body_params` with a map whose
non-file fields are plain strings and whose file-upload fields are `%Plug.Upload{}`
structs (`path` — a temp file path on disk, `filename`, `content_type`). **This design
requires the multipart form to carry:**

| Multipart field name | Shape | Maps to `upload_attrs()` key |
|---|---|---|
| `file` | file part → `%Plug.Upload{}` | `raw_bytes` (via `File.read!/1` on `%Plug.Upload{}.path`, §2.4), `file_name` (`%Plug.Upload{}.filename`, **not** the client-declared `content_type` sub-field of the multipart part — see below), `content_type` |
| `description` | plain text part (optional) | `description` |

**`content_type` is sourced from the multipart file part's own `Content-Type` header
(`%Plug.Upload{}.content_type`), not re-derived or sniffed** — this is consistent with
REQ-211's own INV-a (`content_type` is caller-supplied metadata, never a validated
fact, design §4.0 item 3): the multipart part's declared content type is exactly as
trustworthy (i.e., not trusted at all beyond storage) as a JSON body field would have
been, so no extra validation step is introduced here that REQ-211's own module doesn't
already perform.

### 2.3 Reading the file into memory — `File.read!/1` on `%Plug.Upload{}.path`

`Plug.Parsers.MULTIPART` streams the uploaded part to a temp file on disk (this is
`Plug.Upload`'s whole purpose — avoiding holding arbitrarily large uploads fully in
memory during parsing) and hands the handler a `%Plug.Upload{path: tmp_path}` struct.
**This route handler calls `File.read!/1` on that `tmp_path` to obtain the `raw_bytes`
binary `upload/2` requires** — `upload_attrs().raw_bytes` is a plain `binary()`, not a
file-path/stream, per REQ-211's own signature (§0), so this route layer is the one
place a full read-into-memory happens. This is bounded by the 25 MiB ceiling already
enforced twice over (§2.1's `Plug.Parsers` `:length` on the way in, `upload/2`'s own
`@max_upload_bytes` check on the way through) — never an unbounded read.

**A `Plug.Parsers.RequestTooLargeError` raised by `Plug.Parsers` itself (an oversized
multipart body rejected before this handler code ever runs) is not caught by this
router's own code** — `Plug.Parsers`'s own documented behavior for this exception is a
`413` response emitted by the underlying `Plug.Exception`-aware server adapter
(Bandit), independent of this router. **Open question, not silently resolved — see §7
OQ-1**: whether that Bandit-level 413 response body matches this project's own RFC
9457 `application/problem+json` shape (`Letflow.Api.Error`/`Letflow.Api.Response`'s
established error-body convention) or is a different, unstyled body — this design does
not verify Bandit's default 413 body shape and flags it for ELIXIR-DEV to check at Step
2a (a real HTTP request with an oversized body, observing the actual response) rather
than asserting an answer here.

### 2.4 Temp file cleanup

`Plug.Upload`'s temp file is cleaned up automatically by Plug's own upload-handler
lifecycle (`Plug.Upload.random_file/1` registers the path for deletion when the owning
process — here, the request-handling process — terminates, per `Plug.Upload`'s own
documented behavior). This design adds no explicit `File.rm/1` call — relying on Plug's
existing lifecycle guarantee is the idiomatic behavior every `Plug.Parsers.MULTIPART`
consumer in the wider Elixir ecosystem relies on, not a Letflow-specific decision.

---

## 3. Response shapes — DEFINED by this requirement, not matched against an existing contract

Per the requirement's own text: no `web/` SPA consumer contract and no R-Co route
exist for this surface. The shapes below are this document's own binding decision,
stated plainly here and to be restated in the shipped module's moduledoc verbatim
(§3.4), so a future FRONTEND-DEV requirement has a real contract to build against —
the same way REQ-176/181's core modules became REQ-178/182's routes' binding contract.

### 3.1 `POST /api/v1/instances/:id/attachments` — 201 Created

```json
{
  "id": "3fa6...uuid",
  "instance_id": "9c21...uuid",
  "file_name": "delivery-note.pdf",
  "content_type": "application/pdf",
  "byte_size": 48213,
  "uploaded_by": "a001...uuid",
  "description": "Signed delivery note",
  "created_at": "2026-09-01T14:22:03.123456Z"
}
```

**`content_hash` is never included in this response** — AC1's own text: "never the raw
content_hash bytes in this response, only the hash value itself if surfaced at all."
This design does not surface `content_hash` in **any** JSON response at all (not even
as a hex/base64 string) — no acceptance criterion or future-consumer need is named
that requires a caller to see it, and omitting it entirely is strictly safer than
encoding it and hoping no caller misuses it as an opaque download token (§7 INV-2).
`description` is `null` when absent (REQ-211's schema allows a `nil` value, §1.2 of
that design).

### 3.2 `GET /api/v1/instances/:id/attachments` — 200 OK

```json
{
  "items": [
    {
      "id": "3fa6...uuid",
      "instance_id": "9c21...uuid",
      "file_name": "delivery-note.pdf",
      "content_type": "application/pdf",
      "byte_size": 48213,
      "uploaded_by": "a001...uuid",
      "description": "Signed delivery note",
      "created_at": "2026-09-01T14:22:03.123456Z"
    }
  ],
  "next_cursor": "SUE6MTc1Njc..."
}
```

Exactly the `{items, next_cursor}` two-key shape (matching REQ-178/REQ-202's
convention, per the requirement's own text and DLQ's shipped precedent, §0) — no
`count`/`has_more` key (unlike `Letflow.Routers.Instances`'s own `list`/`history`/
`timeline` handlers, which do add a `"count"` key, §5.2's `render_page_result/3`
helper — **this design deliberately does not reuse that existing helper as-is**, see
§5.2). Each item is the same per-attachment shape as §3.1's response (minus the fact
that it's a list) — one shared `attachment_json/1` allowlist function backs both
(§5.5).

Query params: `cursor` (opaque, REQ-067 contract), `page_size` (optional, REQ-067
defaults/bounds via `Letflow.Api.Pagination.validate_page_size/1`). No other filter —
REQ-211's `list/2` takes only `instance_id`/`cursor`/`page_size` (§0); `instance_id` is
always the path's `:id`, never a query param.

### 3.3 `GET /api/v1/instances/:id/attachments/:attachment_id` — 200 OK, raw bytes

**Content-vs-metadata distinction, stated explicitly per the requirement's own
instruction:** this route's 200 response body is the **raw uploaded file bytes**,
byte-for-byte identical to what was uploaded (AC3) — **not** a JSON document, and
**not** the same shape as §3.1/§3.2. A caller wanting this attachment's metadata
(`file_name`, `content_type`, `byte_size`, etc. as JSON) uses `GET
/instances/:id/attachments` (§3.2, filtering client-side, since `list/2` has no
single-item-by-id mode of its own — REQ-211 deliberately keeps `get/2` a metadata-only
fetch, §0) or is expected to already have that metadata from the original upload
response (§3.1) or a prior list call. **This byte-content route never returns a JSON
body under any 2xx status.**

Response headers:

| Header | Value |
|---|---|
| `Content-Type` | the attachment's stored `content_type` value, exactly as declared at upload time (INV-a — never re-derived, never sniffed) |
| `Content-Disposition` | `attachment; filename="<file_name>"` — the stored `file_name`, quoted. See §3.3.1 for the escaping rule. |

Status: `200`. Body: the raw bytes read from `repository_artifacts.content` (§4.2).

#### 3.3.1 `Content-Disposition` filename escaping

`file_name` is caller-supplied (up to 255 characters, REQ-211 schema, §0) and may
contain characters that are unsafe or ambiguous inside an HTTP header value (a `"`
character, a `\`, a CR/LF that could otherwise inject a header). **This design requires
the `file_name` value to be escaped before being interpolated into the
`Content-Disposition` header**, specifically: backslash-escape any literal `"` and `\`
character inside the filename, and reject (or strip — ELIXIR-DEV's Step-2a choice,
named as an open question, §7 OQ-3) any control character (`\r`, `\n`, other C0
controls) rather than passing it through raw into a header value, since `Plug.Conn.
put_resp_header/3` does not perform CRLF-injection sanitization itself for a
handler-constructed header value the way it does for a handler-controlled *header
name*. This mirrors the byte-bound-truncation care `Letflow.Routers.Instances`'s own
`idempotency_key/1`/`truncate/2` helpers already take for a different caller-supplied
header value (§0) — the same discipline, applied to a different field.

### 3.4 `DELETE /api/v1/instances/:id/attachments/:attachment_id` — 204 No Content

Empty body, matching `Letflow.Api.Response.no_content/1`'s existing contract (§0) —
**not** 200-with-the-deleted-attachment's-metadata (unlike `Letflow.Routers.Dlq`'s
`handle_retry`/`handle_discard`, which return the mutated entry at 200 — a considered
divergence: DLQ's retry/discard return a *changed* resource the caller may want to see
the new state of; a delete has no "new state" to show, so 204 matches
`Letflow.Api.Response.no_content/1`'s own existing precedent for a true removal, the
same as this codebase's convention for any other hard-delete-with-nothing-to-return
endpoint — no other shipped router deletes a resource today, so this is this
codebase's first hard-delete route and this design sets the convention rather than
matching one, flagged for REVIEWER as a judgment call).

### 3.5 Required moduledoc content (binding on ELIXIR-DEV at Step 2a)

The shipped router module's moduledoc must state, verbatim in substance:

1. No existing `web/` SPA consumer or R-Co route contract exists for this surface —
   this requirement defines the response shapes (§3.1-§3.4) rather than matching one
   (AC8).
2. The content-vs-metadata distinction between the two `GET` routes (§3.3's opening
   paragraph, AC8).
3. `content_hash` is never surfaced in any response body (§3.1).
4. The multipart mechanism (§2) and its two-ceiling synchronization hazard (§2.1).

---

## 4. `GET .../:attachment_id` byte-retrieval mechanism — concrete

Per REQ-211's own `get/2` moduledoc (§0), this route performs **two** sequential
lookups, both inside the same `opts[:prefix]` tenant scope:

1. `Letflow.Repository.Attachments.get(attachment_id, opts)` → `{:ok, attachment}` |
   `{:error, :invalid_id | :not_found}`. This is also the **only** place the
   two-distinct-404-checks logic (§5.1) is evaluated for this route — both the
   cross-tenant and cross-instance checks are folded into this one call plus one
   in-handler equality check (§5.1), not into a second query.
2. On `{:ok, attachment}`: a second Repo lookup against `Letflow.Repository.Artifact`,
   scoped to the **same** `opts[:prefix]`, keyed by `attachment.content_hash` —
   `Repo.get(Letflow.Repository.Artifact, attachment.content_hash, prefix: prefix)`.
   Per REQ-211's design §4.3/§2A (confirmed against shipped `artifact.ex`, §0), this
   returns `%Letflow.Repository.Artifact{content_hash: ..., content: <raw bytes>,
   content_type: ..., byte_size: ..., tenant_id: ...}` or `nil`.

**This second lookup's `nil` case is a structural-invariant violation, not a normal
caller-facing error** — `instance_attachments.content_hash` has a `null: false,
references(:repository_artifacts, ..., on_delete: :restrict)` FK (REQ-211 design §1.2/
§2), so a row returned by step 1 is guaranteed by the database itself to have a
matching `repository_artifacts` row in the *same* tenant schema (both tables live in
the same per-tenant Postgres schema, Decision B — there is no cross-schema FK
concern). If step 2 nonetheless returns `nil`, that means the FK constraint was
violated at the database level or the two lookups ran against different prefixes by a
handler bug — **this design maps that case to `Response.internal_error/1` (INV-4, no
detail), never to a 404** (a 404 here would incorrectly suggest the attachment itself
doesn't exist, when step 1 just proved it does) — named explicitly as a defensive
branch this route's own code must include even though it should be unreachable in
correct operation, the same "unreachable but mapped, for completeness" style
`Letflow.Routers.Instances`'s own `render_create/2` already uses for several of its
own clauses (§0).

**No separate `content` field is ever read from `Letflow.Repository.Artifact` for the
metadata routes (§3.1/§3.2/§3.4)** — those three routes never touch
`repository_artifacts` at all, exactly matching REQ-211's own `get/2`/`list/2`
moduledoc statement that those calls are single-table, no-join, and cheap regardless
of referenced content size (§0). Only the byte-content `GET .../:attachment_id` route
performs step 2.

---

## 5. Handler design (per route)

### 5.1 Tenant + instance scoping — the two distinct checks (AC5, AC6, INV-5)

**Every one of the four routes performs check (a) below. The two `:attachment_id`
routes (byte-content GET and DELETE) additionally perform check (b).**

**(a) Cross-tenant check — structural, via `opts[:prefix]` (REQ-072's existing
mechanism, INV-5).** `opts` is derived once per request from `Context.
scoped_repo_opts(conn)` (§0), whose `:prefix` comes solely from
`conn.assigns[:auth_context][:tenant_id]` — never from the request path/query/body.
Every `Letflow.Repository.Attachments.*` call in this design threads that same `opts`
through. A real attachment id or instance id belonging to another tenant is, by
construction, a row that does not exist in the caller's own Postgres schema — REQ-211's
`get/2`/`list/2` (§0) already resolve that to `{:error, :not_found}` / an empty
`items` list respectively, the same "cannot distinguish absent from another tenant's"
guarantee `Letflow.Routers.Instances`'s own moduledoc states for the existing routes on
this router (§0). This route layer adds **no second cross-tenant query of any kind** —
per `Letflow.Api.Context`'s own moduledoc (§0), adding one "for a better error message"
is explicitly forbidden (INV-5).

**(b) Cross-instance-same-tenant check — an explicit, in-handler equality check, NOT
delegated to REQ-211's `get/2` (AC6).** REQ-211's `Attachments.get/2` (§0) takes only
`id` and `opts` — it has **no `instance_id` parameter**, so it cannot itself verify an
attachment belongs to the `:id` named in this route's own path; it can only prove the
attachment exists *somewhere* in the caller's tenant schema. **This design's byte-content
GET and DELETE handlers must therefore, after `get/2` returns `{:ok, attachment}`,
compare `attachment.instance_id == path_instance_id` (both already-cast UUID strings)
and treat a mismatch identically to `{:error, :not_found}`** — i.e., render the same
`Response.not_found/1` call, not a 403 and not a different error body, per AC6's own
text ("returns 404 even when both instance and attachment belong to the caller's own
tenant"). **This is a distinct code path from check (a) — it runs even when check (a)
already passed (the attachment genuinely exists in this tenant's schema), and it must
not be skipped because the request already cleared tenant scoping**, exactly as the
requirement's own text warns. Concretely, in sequence:

```
with {:ok, opts}          <- scoped_repo_opts(conn),
     {:ok, instance_id}   <- cast_uuid(path "id"),
     {:ok, attachment_id} <- cast_uuid(path "attachment_id"),
     {:ok, attachment}    <- Attachments.get(attachment_id, opts),
     :ok                  <- check_instance_match(attachment, instance_id) do
  ...
else
  {:error, :invalid_id} -> Response.not_found(conn)   # malformed UUID folds to 404, DLQ precedent (§0)
  {:error, :not_found}  -> Response.not_found(conn)
  {:error, :instance_mismatch} -> Response.not_found(conn)  # check (b)'s own tag, same rendering
  ...
end
```

(Shown as a sequencing sketch per this document's own signature-only convention — not
literal code; ELIXIR-DEV writes the actual `with`/`case` at Step 2a.)

`check_instance_match/2`'s own signature:

```
@spec check_instance_match(Attachment.t(), Ecto.UUID.t()) :: :ok | {:error, :instance_mismatch}
```

**AC6's demonstration** (an attachment real, tenant-correct, but wrong `instance_id`,
returns 404) is exactly this function returning `{:error, :instance_mismatch}`, folded
to the same `Response.not_found/1` call as every other not-found case in this router.

**`POST` and list-`GET` do not need check (b) in this same shape**, because they take
no `:attachment_id` path segment to cross-check — `POST`'s `instance_id` comes
entirely from the path and is passed straight into `upload_attrs()` (§5.4), and
list-`GET`'s `instance_id` filter (§0, REQ-211 `list/2`) is itself the *only* scoping
mechanism for that route, not a check performed after the fact.

**Neither instance-existence itself is checked by this route layer** — REQ-211's
design's own OQ-1 (§0) states plainly that `Attachments.upload/2` will happily create
an attachment for a nonexistent `instance_id`, since `instance_attachments.instance_id`
carries no FK to an instance-identifying table. **This design does not add such a
check either** — no acceptance criterion here asks for "reject upload to a nonexistent
instance," and REQ-211's own OQ-1 explicitly left that decision to "a future
route-layer" without resolving it. **Named here as inherited, not silently resolved:
this design does NOT validate that `:id` names a real, existing instance before
calling `upload/2`/`list/2`** — see §7 OQ-1 (renumbered from REQ-211's OQ-1 into this
document's own open-questions list, since it is now genuinely this layer's decision to
make or defer, and this document defers it).

### 5.2 `list/2`'s own error tuples — not reused via `render_page_result/3` as-is

`Letflow.Routers.Instances`'s existing `render_page_result/3` helper (§0) is shared
across that router's `list`/`history`/`timeline` handlers and adds a `"count"` key this
design's §3.2 shape deliberately does not include (matching DLQ's own two-key
precedent instead, per the requirement's own instruction). **This design does not call
the existing `render_page_result/3` for the attachments list route** — it writes its
own two-key rendering (`%{"items" => ..., "next_cursor" => next_cursor}`, no `"count"`
key), reusing `render_page_result/3`'s existing error-tuple mapping *pattern*
(`:invalid_cursor`/`:wrong_endpoint` → `unprocessable`, `:expired` →
`Response.send_problem(conn, Error.cursor_expired())`) but as a small,
locally-scoped private function, since sharing the existing function directly would
require changing its shape for every one of its other three call sites — out of this
requirement's scope. **`list/2`'s own error union also includes `:page_size_too_large`**
(§0 — REQ-211's shipped `list/2` returns it, distinct from the existing router's own
`list`/`history`/`timeline` handlers, which validate `page_size` themselves *before*
calling their context function and so never see that tag from their own callee) — this
design's list handler must map it to `Response.bad_request/2`, matching how this same
router's own `handle_list/1` (§0) already maps its own pre-validation
`:page_size_too_large` today, for consistency of the same error condition producing the
same status code regardless of which layer detected it.

### 5.3 Byte-content GET's response is NOT built via `Letflow.Api.Response`

Per §0's confirmation that no existing `Letflow.Api.Response` helper sends a
non-JSON/raw-bytes body: this route's success path calls `Plug.Conn.
put_resp_content_type/2` (the attachment's stored `content_type`, no forced charset
suffix — a binary file has no text charset to declare, unlike this codebase's existing
JSON responses), `Plug.Conn.put_resp_header/3` (`"content-disposition"`, §3.3.1's
escaped value), and `Plug.Conn.send_resp/3` (`200`, the raw bytes read in §4 step 2) —
the same three primitives `Letflow.Api.Response.send_json/3` itself is built from
(§0), just not funneled through that module, since every existing helper there is
JSON-body-shaped by construction (`send_json/3` always calls `Jason.encode!/1`) and
this response is never JSON. **Every error path from this same handler still goes
through `Letflow.Api.Response`** (`not_found/1`, `internal_error/1`, etc.) — only the
one 200-success path bypasses it, and only because there is no existing helper shaped
for it (§7 OQ-2 names the possible future refactor).

### 5.4 `POST` handler — request parsing and `upload_attrs()` construction

```
@spec upload_attrs_from_conn(Plug.Conn.t(), Ecto.UUID.t()) ::
        {:ok, Attachments.upload_attrs()} | {:error, :missing_file | :invalid_multipart}
```

Sourced fields (§2.2):

| `upload_attrs()` key | Source |
|---|---|
| `instance_id` | path `:id`, already cast to a valid UUID before this function is called (an invalid path `:id` is rejected earlier in the `with` chain, same as every other route on this router) |
| `raw_bytes` | `File.read!/1` on `conn.body_params["file"].path` (§2.3) |
| `file_name` | `conn.body_params["file"].filename` |
| `content_type` | `conn.body_params["file"].content_type` |
| `uploaded_by` | `conn.assigns.auth_context.user_id` — the authenticated caller, never a request field (matches `Letflow.Routers.Instances`'s own existing `actor_id/1` helper pattern, §0) |
| `description` | `conn.body_params["description"]`, if present and a non-empty string; otherwise omitted (matches REQ-211's `optional(:description)`, §0) |

A multipart request with no `file` part (`conn.body_params["file"]` absent or not a
`%Plug.Upload{}`) maps to `{:error, :missing_file}` → `Response.unprocessable(conn,
"a file part named \"file\" is required")`, not a 500 and not an attempt to call
`upload/2` with a missing `raw_bytes` key.

`render_upload/2`'s result mapping:

| `upload/2` result | Response |
|---|---|
| `{:ok, attachment}` | `201`, §3.1 shape |
| `{:error, :file_too_large}` | `413` (`Response.payload_too_large/2`, REQ-068's existing helper, §0 confirms it exists) |
| `{:error, %Ecto.Changeset{}}` | `422` (`Response.unprocessable/2`) — a changeset failure here means `file_name` exceeded 255 characters (REQ-211 schema's only realistic changeset-rejection path, §0) or another `required_fields` gap this route's own construction should make unreachable in practice; mapped anyway for completeness, matching this codebase's existing "map every documented tag, even an effectively-unreachable one" discipline (§0, `Letflow.Routers.Instances`'s own `render_create/2`) |

### 5.5 Shared response-allowlist function — `attachment_json/1`

```
@spec attachment_json(Attachment.t()) :: map()
```

One hand-built allowlist function (matching `dlq_entry_json/1`'s precedent, §0),
shared by §3.1 (`POST`'s 201 body) and §3.2 (each item in the list's `items` array) —
never a raw `Jason.Encoder` derivation over `%Attachment{}`, which would leak
`__meta__`/`tenant_id` (INV-2). Emits exactly the eight keys shown in §3.1/§3.2:
`id, instance_id, file_name, content_type, byte_size, uploaded_by, description,
created_at` (`created_at` via `DateTime.to_iso8601/1`, matching every other
timestamp-rendering call site already in this router, §0). **`content_hash` and
`tenant_id` are never included** — the two fields on `Attachment.t()` (§0) this
allowlist deliberately omits, for the reasons §3.1 already states.

---

## 6. Authorization — `Letflow.Api.Authorization` matrix additions

### 6.1 New permission atoms — genuinely new, not pre-ported

Per the requirement's own instruction to state this distinction explicitly: unlike
`DlqOperate`/`WebhooksManage` (REQ-069's own moduledoc: ported ahead of their
consuming routes, matching R-Co's matrix exactly even though no S4 route consumed them
yet), **`AttachmentsManage` and `AttachmentsRead` have no R-Co counterpart at all** —
`instance_attachments` (REQ-211) is new functionality this migration invents, not a
ported R-Co subsystem (REQ-211's own description confirms this, §0 of that design).
These two atoms are added *for* this requirement's own routes, immediately consumed,
never in a "ported but currently unreachable" state the way `DlqOperate`/
`WebhooksManage` briefly were.

`@type permission ::` (§0's current 16-atom union) gains two members:
`:AttachmentsManage` and `:AttachmentsRead`. `@permissions` (the `permissions/0`
runtime list) gains the same two atoms.

### 6.2 Why two permissions, not one collapsed permission (a genuine split, unlike DLQ/webhooks' single-permission precedent)

DLQ's `:DlqReadRetryDiscard` and webhooks' `:WebhookSubscriptionsManage` each collapse
their whole route surface (including both reads and mutations) into **one** policy key
→ **one** required permission. **REQ-212's own requirement text explicitly asks for
two**: `AttachmentsManage` gates upload/delete (mutation), `AttachmentsRead` gates
list/download (read). This is a genuinely different shape from either existing
core/route precedent — stated explicitly here since a reader familiar with DLQ/
webhooks' single-permission pattern might otherwise assume this router should collapse
the same way. **Not resolved by silently picking the more familiar single-permission
shape** — the requirement's own AC4 requires the two-permission split as a testable
fact ("every route requires the AttachmentsManage... or AttachmentsRead... permission
**as appropriate**"), so this design implements exactly that.

### 6.3 `endpoint_policy_key/2` — new clauses

```
def endpoint_policy_key("POST", "/instances/:id/attachments"), do: :AttachmentsManage
def endpoint_policy_key("DELETE", "/instances/:id/attachments/:attachment_id"), do: :AttachmentsManage
def endpoint_policy_key("GET", "/instances/:id/attachments"), do: :AttachmentsRead
def endpoint_policy_key("GET", "/instances/:id/attachments/:attachment_id"), do: :AttachmentsRead
```

`@type endpoint_policy_key ::` gains the same two new atoms as their own policy-key
values — this design does **not** introduce a third, separate set of policy-key atoms
distinct from the permission atoms (matching every existing 1:1 policy-key-to-
permission pattern in this table except the `TasksList`/`TasksGetById` →
`:TasksRead`-many-to-one cases, which do not apply here since AC4 requires the split
kept, not collapsed).

### 6.4 `required_permission/1` — new clauses

```
def required_permission(:AttachmentsManage), do: :AttachmentsManage
def required_permission(:AttachmentsRead), do: :AttachmentsRead
```

### 6.5 `role_allows?/2` — which roles hold which new permission

**This is a genuine policy decision this document must make explicitly, not silently
default.** No requirement text and no R-Co precedent states which of the five existing
roles (`PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER`)
should hold `AttachmentsManage`/`AttachmentsRead`. Reasoning, by analogy to the closest
existing capability class already in the matrix — **instance-mutation and
instance-read permissions** (`InstancesStart`/`InstancesCancel`/`InstancesRead`),
since an attachment is data scoped to one workflow instance, the same resource class
those three permissions already govern:

| Role | Holds `InstancesCancel`/`InstancesStart` today? | → `AttachmentsManage` | Holds `InstancesRead` today? | → `AttachmentsRead` |
|---|---|---|---|---|
| `PLATFORM_ADMIN` | yes (catch-all) | yes (catch-all, unchanged) | yes (catch-all) | yes (catch-all, unchanged) |
| `PROCESS_DESIGNER` | `InstancesStart` only, not `InstancesCancel` | **no** | yes | **yes** |
| `PROCESS_OPERATOR` | both | **yes** | yes | **yes** |
| `TASK_WORKER` | neither | **no** | yes (`InstancesRead`) | **yes** |
| `AGENT_RUNNER` | neither (`role_allows?(:AGENT_RUNNER, _)` is unconditionally `false`) | **no** | no | **no** |

Rationale: `PROCESS_OPERATOR` already holds every instance-mutating permission
(`InstancesStart`, `InstancesCancel`) plus `DlqOperate`/`WebhooksManage` — the role
this codebase's existing matrix already treats as "operates on live instances," making
it the natural holder of attachment upload/delete too. `PROCESS_DESIGNER` holds
`InstancesStart` (can kick off an instance) but not `InstancesCancel` (cannot mutate a
running one) — attaching/deleting a file on an in-flight instance is an operational
action closer to cancel than to start, so `PROCESS_DESIGNER` does **not** get
`AttachmentsManage`, mirroring its own `InstancesCancel: false` today. `TASK_WORKER`
holds `InstancesRead` (can see instance state to do its job) but no instance-mutation
permission — reading an attachment (e.g. a delivery note it needs to complete a task)
fits its existing read-only relationship to instances; uploading/deleting one does not.
`AGENT_RUNNER` holds nothing today (`role_allows?(:AGENT_RUNNER, _permission), do:
false` unconditionally) and gets neither new permission, consistent with that
blanket-false clause.

**This mapping is a design decision, not a requirement-stated fact — flagged for
REVIEWER at Step 2d (§8), same as REQ-211 flagged its own `@max_upload_bytes` judgment
call.** If REVIEWER or a future requirement wants a different role/permission
assignment, that is a follow-up change to this same matrix, not a defect in this
document for stating an explicit, reasoned default rather than leaving it unresolved.

`role_allows?/2`'s existing five clauses (§0) gain `:AttachmentsManage`/
`:AttachmentsRead` into `PROCESS_OPERATOR`'s list (both) and `PROCESS_DESIGNER`'s/
`TASK_WORKER`'s lists (`:AttachmentsRead` only, added to each) — `PLATFORM_ADMIN`'s
catch-all clause and `AGENT_RUNNER`'s blanket-`false` clause need no textual change.

---

## 7. Security-relevant design decisions (SECURITY-REVIEWER's Step 2c gate)

- **INV-1 (tenant isolation).** Every handler derives `opts` exactly once per request
  via `Context.scoped_repo_opts(conn)` (§5.1(a)), threaded into every
  `Letflow.Repository.Attachments.*` call and into the second `repository_artifacts`
  lookup (§4) — no handler accepts or derives a prefix any other way.
- **INV-2 (no unintended data exposure).** `attachment_json/1` (§5.5) is a hand-built
  allowlist; `content_hash`/`tenant_id` never appear in any JSON response.
  `Content-Type`/`Content-Disposition` on the byte-content route (§3.3) expose only
  caller-supplied metadata that caller already knew (their own `file_name`/
  `content_type` from upload time) — no internal field leaks through those headers.
- **INV-4 (no detail-bearing 500).** Every handler's fallback error clause maps to
  `Response.internal_error/1` (no detail) — including §4's defensive FK-violation
  branch. No caught exception's message or raw Postgrex error ever reaches a response
  body.
- **INV-5 (cross-tenant 404, never 403).** §5.1(a)/(b) — both checks fold to the same
  `Response.not_found/1` call with no distinguishing detail, for every one of the four
  routes, matching this codebase's established DLQ/webhooks/instances precedent
  exactly. **This is the requirement's own explicit two-distinct-checks demand (AC5,
  AC6)** — check (a) (cross-tenant) is structural/REQ-072-derived; check (b)
  (cross-instance-same-tenant) is this design's own new in-handler equality check,
  because REQ-211's `get/2` has no `instance_id` parameter to enforce it itself (§5.1).
- **DoS surface (upload size).** Enforced twice: `Plug.Parsers`'s own `:length` on the
  multipart parser (§2.1, rejects before full buffering) and REQ-211's existing
  `@max_upload_bytes` inside `upload/2` (defense in depth — this route's own
  `Plug.Parsers` ceiling could in principle be misconfigured or bypassed by a future
  change to `ApiPipeline`; REQ-211's own check does not depend on this route's
  correctness).
- **Constant-duplication hazard (§2.1).** The 25 MiB ceiling exists as two independent
  literals (`Letflow.Repository.Attachments.@max_upload_bytes` and
  `Letflow.Plugs.ApiPipeline`'s `Plug.Parsers` `:length` option for the multipart
  branch) that must be changed together — flagged for REVIEWER explicitly, same
  judgment-call flagging discipline REQ-211's design used for the number itself.
- **`role_allows?/2` mapping (§6.5)** is a genuine policy judgment call with no
  requirement-stated answer — flagged for REVIEWER explicitly, per §6.5's own text.
- **§3.3.1's header-injection escaping** for `Content-Disposition`'s `filename` value
  is load-bearing: an un-escaped caller-supplied `file_name` containing a raw CR/LF or
  unescaped `"` could otherwise inject additional header lines or break the
  `Content-Disposition` value's own quoting. Flagged for SECURITY-REVIEWER explicitly
  since it is the one place in this design where caller-supplied text is written
  directly into a raw HTTP header rather than into a JSON body value (where Jason's own
  encoder already handles escaping structurally).

---

## 8. Functions/behaviors deliberately NOT built (scope discipline)

| Item | Why not |
|---|---|
| Any change to `Letflow.Repository.Attachments`/`Attachment`/their migration | REQ-211's scope, already shipped and `done` — explicitly out of this requirement per its own text. |
| Instance-existence validation before `upload/2`/`list/2` | Not asked for by any AC; inherited from REQ-211's own OQ-1 as a deferred decision (§5.1, §9 OQ-1). |
| A shared `Response.send_binary/4`-shaped helper in `Letflow.Api.Response` | Only one route in this codebase needs a raw-bytes response today (§5.3) — extracting a shared helper for a single call site is premature; named as a possible future refactor (§9 OQ-2), not built here. |
| Content-type sniffing/validation on upload | REQ-211's own INV-a explicitly forbids treating `content_type` as verified (§0) — this route layer must not add a check REQ-211's own module deliberately omits. |
| A single collapsed `AttachmentsOperate`-style permission | AC4 requires the two-permission split kept (§6.2) — not collapsed for implementation convenience. |

---

## 9. Open questions (stated explicitly, not silently resolved)

- **OQ-1 (inherited from REQ-211's own OQ-1, now this layer's decision to make or
  defer — deferred here).** This route layer does not validate that the path's `:id`
  names a real, existing instance before calling `upload/2`/`list/2`. A caller can
  upload/list against a syntactically-valid-UUID `instance_id` that doesn't correspond
  to any actual instance — `upload/2` will happily create the row (REQ-211's own OQ-1),
  and `list/2` will simply return an empty page. No acceptance criterion here asks for
  a "does this instance exist" check, and adding one would require this router to call
  into `Letflow.Instances`/`Letflow.EventStore` (a new cross-module dependency this
  requirement's own text does not name). Left as a future decision.
- **OQ-2 — no shared raw-bytes response helper extracted.** §5.3/§8 — this design uses
  `Plug.Conn` primitives directly for the one byte-content route rather than adding a
  new `Letflow.Api.Response` function. If a future requirement adds a second
  raw-bytes-response route, extracting a shared helper at that point (not now, not
  speculatively) would be the natural next step — not resolved here.
- **OQ-3 — reject vs. strip a control character in `file_name` before building
  `Content-Disposition` (§3.3.1).** This design requires *some* sanitization but leaves
  the reject-vs-strip choice to ELIXIR-DEV at Step 2a, since neither approach changes
  this route's observable JSON-facing behavior (the raw `file_name` is still stored
  and still returned verbatim in `attachment_json/1`'s metadata responses, §5.5 — only
  the header-value rendering differs) and no acceptance criterion distinguishes the
  two. Flagged for REVIEWER to confirm whichever choice ELIXIR-DEV makes still
  satisfies §7's header-injection concern.
- **OQ-4 — Bandit's default 413 body shape for a `Plug.Parsers.RequestTooLargeError`
  (§2.3)** is not verified against this project's own RFC 9457 error-body convention.
  ELIXIR-DEV must check the actual response at Step 2a (a real oversized-upload
  request) rather than assume it matches `Letflow.Api.Error`'s shape — if it doesn't,
  that is either an accepted, documented divergence (matching `Letflow.Api.Response`'s
  own moduledoc precedent for documenting a deliberate divergence, §0) or a case this
  router's own code must catch and re-render explicitly, which is itself a further
  design decision this document does not make here.

---

## 10. Traceability — acceptance criteria to design elements

| AC (paraphrased) | Design element |
|---|---|
| AC1 — `POST` accepts multipart, 2xx with id/file_name/content_type/byte_size/created_at, shape defined here | §2 (multipart mechanism), §3.1 (response shape), §5.4 |
| AC2 — `GET` list returns `{items, next_cursor}`, cursor-paginated, instance-scoped | §3.2, §5.2, §5.1 |
| AC3 — `GET .../:attachment_id` returns raw bytes byte-for-byte, correct Content-Type/Content-Disposition | §3.3, §3.3.1, §4 |
| AC4 — every route requires AttachmentsManage/AttachmentsRead as appropriate, 403 test per route | §6 (all subsections) |
| AC5 — cross-tenant real instance/attachment id → 404 for every route | §5.1(a), §7 |
| AC6 — cross-instance-same-tenant attachment id → 404 | §5.1(b) |
| AC7 — `DELETE` on already-deleted/nonexistent → 404, not duplicate success | §3.4, §4.5's `get/2`-then-delete idiom inherited from REQ-211 (§0) |
| AC8 — moduledoc states no existing consumer contract, defines shapes, states content-vs-metadata distinction | §3.5 |
| AC9 — `mix test`/`mix compile --warnings-as-errors` pass | Step 2a/4 execution, not a design-stage artifact |
