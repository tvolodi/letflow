# Design: REQ-386 — Time-limited, expiring signed URLs for attachment content

**Requirement:** REQ-386 (full text supplied via handoff `context.requirement_text` —
not re-read from `docs/requirements.yaml`), stage S6/S7-adjacent (builds atop REQ-211/212,
both `done`).
**Owner (implementer):** ELIXIR-DEV
**This document produces:** a new context module (`Letflow.Repository.AttachmentLinks`),
two new routes on `Letflow.Routers.Instances`, two new `Letflow.Api.Error`/
`Letflow.Api.Response` helpers, and two new `Letflow.Api.Authorization.endpoint_policy_key/2`
clauses. **No implementation code** — no function bodies, no `.ex`/`.exs` file contents;
signatures, data shapes, and algorithm descriptions in prose only. ELIXIR-DEV writes the
actual code from this document at Step 2a.

**NOT in this document / explicitly out of scope (restated from the requirement):**
the frontend document-viewer screen (REQ-387); any change to REQ-211/212's existing
tenant/instance-scoping logic in `fetch_scoped_attachment_content/3` (unchanged, reused
verbatim); audit logging of denied attempts (REQ-388); any change to
`Letflow.Secrets`, `Letflow.Repository.Attachments`, or their migrations.

---

## 0. Sources read for this design

- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.
- `docs/guides/backend_developer_guide.md` (full).
- `docs/agents/instructions/security-invariants.md` (full) — INV-1, INV-4, INV-5, INV-6,
  INV-7, INV-8 as named in the requirement's own acceptance criterion 6.
- `lib/letflow/webhooks.ex` (shipped) — the only existing HMAC-signing precedent in this
  codebase: `:crypto.mac(:hmac, :sha256, signing_key, body)`, secret stored via
  `Letflow.Secrets.put/2` and resolved via `Letflow.Secrets.resolve/2`
  (`consumer: :webhook_dispatcher`), plaintext returned exactly once from `create/2`.
  This design reuses the same primitives (`:crypto.mac(:hmac, :sha256, ...)`,
  `Letflow.Secrets.put/2`/`resolve/2`) rather than introducing `Phoenix.Token` (confirmed
  absent from this codebase — zero hits grepping for `Phoenix.Token`).
- `lib/letflow/secrets.ex` (shipped, full) — `put/2`'s `purpose :: :webhook_hmac |
  :generic` and `resolve/2`'s `consumer :: :webhook_dispatcher | :generic` matrix
  (`check_purpose_allowed/2`: `:generic` consumer may resolve `:generic`-purpose secrets
  only). This design uses `purpose: :generic` / `consumer: :generic` throughout — **no
  change to `Letflow.Secrets` is needed**, because `:generic`/`:generic` is already a
  legal pair in the shipped matrix.
- `lib/letflow/routers/instances.ex` (shipped, full) — REQ-212's four attachment routes,
  `fetch_scoped_attachment_content/3` and `fetch_scoped_attachment_metadata/3` (both
  reused verbatim, zero changes), `handle_get_attachment_content/3` (left untouched),
  the module's own "Route ordering" hazard-class discipline, `cast_instance_id/1`,
  `Context.scoped_repo_opts/1` / `conn.assigns.scoped_opts` / `conn.assigns.auth_context`
  usage patterns.
- `lib/letflow/api/authorized_router.ex` (shipped, full) — confirms **every** route
  declared on a router using `Letflow.Api.AuthorizedRouter` passes through
  `Letflow.Plugs.Authorize` unconditionally; "There is no route shape in a router using
  this module that bypasses `Letflow.Plugs.Authorize`." This is the structural fact that
  settles Open Question OQ-1 below.
- `lib/letflow/api/authorization.ex` (shipped) — confirms `:AttachmentsRead` already
  exists as a `permission()`/`endpoint_policy_key()` atom with a `required_permission/1`
  identity clause (REQ-212); confirms `endpoint_policy_key/2` needs two new clauses for
  the two new routes below, checked against
  `test/letflow/api/authorization_enforcement_test.exs`'s mechanism (every
  `__authz_routes__/0` entry must resolve through a matching `endpoint_policy_key/2`
  clause, or be allowlisted — this design adds real clauses, not an allowlist entry).
- `lib/letflow/api/response.ex` / `lib/letflow/api/error.ex` (shipped) — confirms the
  existing per-status helper shape (`Error.<status>/1` builds a fixed-or-caller-supplied
  detail; `Response.<status>/1-2` sends it) and that no existing helper fits "expired or
  invalid signed link" — a new pair is added (§4 below), following the same shape as
  `Error.not_found/0`/`Response.not_found/1` (no caller-supplied detail — see §7's INV-5
  reasoning for why this matters).
- `lib/letflow/identity.ex` — confirms `get_tenant/1` (`@spec get_tenant(id ::
  Ecto.UUID.t() | String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}`) as the
  tenant_id → slug lookup this design needs to build a `Letflow.Secrets` reference
  string.

---

## Acceptance-criteria map

| AC | Design element |
|---|---|
| 1. Authenticated `:AttachmentsRead` endpoint issues a signed link with a stated, bounded expiry | §3.1 (`POST .../link`, `:AttachmentsRead`); §2.1 (`@link_expiry_seconds 300`, stated + rationale) |
| 2. Same link refused after its expiry, no bytes returned, testable without a real sleep | §2.3 step 6 (`expires_at` check against injectable `now`); §2.2 step 1 (`opts[:now]` injection point); §4 (`attachment_link_expired`, no document bytes — response never reaches `send_attachment_content/2`) |
| 3. Fresh link for the same attachment_id after a prior one expired succeeds and serves the document | §2.2 (`issue/3` is stateless per-call — no record of prior issuances is consulted or blocks a new one; a fresh call mints a fresh, independently-valid token/expiry); §3.2 step 3 (a valid fresh token reaches `fetch_scoped_attachment_content/3` exactly as the pre-existing route already does) |
| 4. Expired-or-invalid response byte-identical for cross-tenant vs. never-issued attachment id | §7 INV-5 (full mechanical argument); §2.3 (single collapsed `{:error, :expired_or_invalid}`); §3.2 step 5-6 (id-mismatch folded into the same value, not a separate one) |
| 5. `fetch_scoped_attachment_content/3` unchanged, its existing tests still pass | §3.2 (new, separate route/handler; existing route/handler untouched); §8 table ("Changed? No" row) |
| 6. `mix compile --warnings-as-errors`/`mix test` pass; SECURITY-REVIEWER sign-off | §7 (INV-1/4/5/6/7/8 assessed explicitly, ready for SECURITY-REVIEWER's own independent re-check) |

---

## 1. Mechanism overview (plain-language)

1. A caller who already has `:AttachmentsRead` on a given attachment calls a new `POST
   .../link` route. The route re-runs the **exact same, unchanged** tenant/instance
   scoping check REQ-211/212 already built, then mints an opaque, self-contained,
   HMAC-signed token naming that attachment id and a short (5-minute) expiry, and
   returns it.
2. A caller presents that token to a new `GET .../link-content` route (same
   `:AttachmentsRead`-gated pipeline — see OQ-1). The route verifies the token's
   signature and expiry **before** doing anything else. Any failure of that
   verification — malformed token, wrong tenant's key, tampered payload, or a genuinely
   expired timestamp — collapses to **one** error value, rendered by **one** response
   call, with **no branch that inspects whether the named attachment id is real,
   belongs to another tenant, or was never issued**. Only once verification succeeds
   does the handler fall through to the existing, unchanged
   `fetch_scoped_attachment_content/3` call.
3. The signing key is per-tenant (not one global secret), stored via the existing
   `Letflow.Secrets` table (namespace `"attachments"`, name `"link_signing_key"`,
   purpose `:generic`) — lazily created on first issuance for a tenant. **No new
   database table or migration** — see §6.

---

## 2. New module: `Letflow.Repository.AttachmentLinks`

`lib/letflow/repository/attachment_links.ex`. Plain context module, no process, no
`Repo.*` call of its own beyond what `Letflow.Secrets`/`Letflow.Identity` already
perform internally (so it stays compliant with `INV-RT-1`'s router-layer
no-direct-`Repo.*` rule the same way `Letflow.Repository.Attachments` already is —
this module is called *from* the router, same as `Attachments`, never the reverse).

### 2.1 Constants

- `@link_secret_namespace "attachments"`
- `@link_secret_name "link_signing_key"`
- `@link_expiry_seconds 300` — **the exact chosen expiry value, flagged for REVIEWER**
  (judgment call, no requirement-stated value — same precedent class as REQ-211's own
  `@max_upload_bytes`). Rationale: short enough that a URL copy-pasted into a chat log,
  browser history entry, or proxy access log stops being useful within minutes even
  though the route stays behind the standard authenticated `:AttachmentsRead` pipeline
  (see OQ-1 — the expiry is defense-in-depth on top of that pipeline, not a
  substitute for it); long enough that a document viewer loading one attachment over a
  slow connection, or a user pausing briefly mid-review, does not routinely hit the
  boundary. 5 minutes (300s), not hours, per the requirement's own instruction.

### 2.2 `issue/3` — mint a token

```
@type issue_opts :: [now: (-> DateTime.t())]

@spec issue(attachment_id :: String.t(), tenant_id :: Ecto.UUID.t(), issue_opts()) ::
        {:ok, %{token: String.t(), expires_at: DateTime.t()}}
        | {:error, :invalid_tenant}
        | {:error, {:secret_write_failed, term()}}
```

**Preconditions the caller (router) must already have satisfied before calling this:**
`attachment_id` has already been confirmed to exist, be UUID-well-formed, and be
tenant/instance-scoped to the caller (via the existing, unchanged
`fetch_scoped_attachment_metadata/3` — see §3.1). This function does **not**
re-validate the attachment; it only mints a token for an attachment_id the caller has
already proven access to.

**Behavior, in order:**
1. `now = Keyword.get(opts, :now, &DateTime.utc_now/0).()`; `expires_at = now` plus
   `@link_expiry_seconds`, truncated to second precision (matches this codebase's
   existing `current_timestamp/0` convention in `Letflow.Webhooks`/`Letflow.Secrets`).
   `opts[:now]` is the AC2 test-injection point — a test supplies a fixed function
   rather than sleeping.
2. Resolve `tenant_id` → `tenant.slug` via `Letflow.Identity.get_tenant/1`.
   `{:error, :not_found}` → `{:error, :invalid_tenant}` (structurally unreachable in
   practice — `tenant_id` here always comes from `conn.assigns.auth_context.tenant_id`,
   an already-authenticated tenant — mapped anyway per this codebase's own INV-8
   "don't leave an external-I/O-reachable path as a bare match" discipline).
3. **Get-or-create the tenant's link-signing secret** (private helper, §2.4): resolve
   the unpinned `Letflow.Secrets` reference for
   `(tenant_id, "attachments", "link_signing_key")`; if `{:error, :not_found}`, create
   one via `Letflow.Secrets.put/2` (`purpose: :generic`, 32 random bytes via
   `:crypto.strong_rand_bytes/1`, `created_by: "system:attachment_links.issue"`) and use
   the newly created `key_id`. **Concurrent-first-issuance race, stated explicitly, not
   a defect:** two requests racing to create the first-ever secret for a tenant can both
   succeed, leaving two active key-id versions — harmless, because every token pins its
   own `key_id` (§2.3) and verification always resolves that exact pinned version, never
   "the latest." Flagged for REVIEWER as an accepted behavior, not silently decided.
4. Resolve the **pinned** secret (`tenant_slug`, namespace, name, the `key_id` from step
   3) via `Letflow.Secrets.resolve/2` (`consumer: :generic`) to get the signing-key
   plaintext. (This is a second `resolve/2` call distinct from step 3's
   existence-check — kept separate because step 3's unpinned resolve answers "does an
   active secret exist" while this one fetches the plaintext for the exact version this
   token will be pinned to, which step 3 does not itself return.)
5. Build `payload = Jason.encode!(%{"attachment_id" => attachment_id, "expires_at" =>
   DateTime.to_unix(expires_at), "key_id" => key_id})` (a JSON object, three keys,
   deterministic field set).
6. `signature = :crypto.mac(:hmac, :sha256, signing_key, payload)` — computed over the
   **exact raw JSON bytes** produced in step 5, same "sign the exact bytes sent/stored"
   discipline `Letflow.Webhooks.sign/2` already establishes for its own HMAC.
7. `token = Base.url_encode64(payload, padding: false) <> "." <> Base.url_encode64(signature, padding: false)`
   — one opaque string, two base64url segments joined by a literal `.`, no other
   structure a caller could usefully parse.
8. Return `{:ok, %{token: token, expires_at: expires_at}}`.

### 2.3 `verify/3` — validate a token and recover the attachment id

```
@spec verify(token :: String.t(), tenant_id :: Ecto.UUID.t(), issue_opts()) ::
        {:ok, attachment_id :: String.t()} | {:error, :expired_or_invalid}
```

**This is the single function AC4's byte-identical requirement rests on.** Its internal
control flow is one `with` chain ending in exactly one `else` clause that matches
**any** failure and returns the **same** `{:error, :expired_or_invalid}` value,
regardless of which step failed:

1. Split `token` on the first `.` into two base64url segments; `Base.url_decode64/2`
   (`padding: false`) each. Malformed shape (no `.`, extra segments, invalid base64) →
   falls through to the shared `else`.
2. `Jason.decode/1` the first (payload) segment's raw bytes; must be a JSON object with
   exactly the three string/integer keys `issue/3` step 5 wrote (`attachment_id`,
   `expires_at`, `key_id`), all present and correctly typed. Any decode failure or
   missing/mistyped key → shared `else`.
3. Resolve `tenant_id` → `tenant.slug` via `Letflow.Identity.get_tenant/1` — `tenant_id`
   here is always `conn.assigns.auth_context.tenant_id`, the **requester's own**
   authenticated tenant (never anything decoded from the token — the token carries no
   tenant information at all, by design, see §7). Not-found → shared `else`.
4. Resolve the **pinned** secret for `(tenant.slug, "attachments", "link_signing_key",
   key_id)` via `Letflow.Secrets.resolve/2` (`consumer: :generic`), using the
   requester's own tenant. `{:error, :not_found | :tenant_mismatch | :disabled |
   :deleted | :invalid_reference | :purpose_not_allowed}` (any of `resolve/2`'s
   documented error atoms) → shared `else`.

   **This step is what makes cross-tenant presentation fail mechanically, not just by
   convention:** if the requester's tenant differs from the tenant that originally
   issued the token, this step resolves a **different** signing key (the requester's
   own tenant's key, possibly not even existing yet) than the one the signature in step
   5 was computed with — so step 5 fails regardless of whether this step itself errors
   or returns a real-but-wrong key.
5. Recompute `:crypto.mac(:hmac, :sha256, resolved_signing_key, payload_bytes)` (the
   *raw decoded payload bytes* from step 1, not a re-encoding of the parsed map — avoids
   any JSON key-ordering/whitespace re-serialization mismatch) and compare against the
   token's own decoded signature segment using `:crypto.hash_equals/2` (constant-time;
   an OTP-builtin, available on the pinned Erlang/OTP 29 toolchain, so no new
   dependency). Mismatch → shared `else`.
6. Check `expires_at_unix > DateTime.to_unix(Keyword.get(opts, :now,
   &DateTime.utc_now/0).())`. Not-in-the-future (i.e. expired, or equal — strictly
   greater-than, so a token expiring at exactly `now` is already treated as expired) →
   shared `else`.
7. All six steps passed → `{:ok, attachment_id}` (the string from the decoded payload).

**Shared `else`:** `_ -> {:error, :expired_or_invalid}` — one clause, one return value,
reached from every one of steps 1-6's failure branches with no intervening computation
that could vary the returned value by which step failed.

### 2.4 Private helpers (signatures only, no bodies)

```
@spec get_or_create_signing_key_id(tenant_id :: Ecto.UUID.t(), tenant_slug :: String.t()) ::
        {:ok, key_id :: pos_integer()} | {:error, {:secret_write_failed, term()}}

@spec unpinned_reference(tenant_slug :: String.t()) :: String.t()
# "sec://tenant/#{tenant_slug}/attachments/link_signing_key"

@spec pinned_reference(tenant_slug :: String.t(), key_id :: pos_integer()) :: String.t()
# "sec://tenant/#{tenant_slug}/attachments/link_signing_key##{key_id}"
```

---

## 3. Router changes: `lib/letflow/routers/instances.ex`

### 3.1 New route — issue a link

```
authz_post "/:id/attachments/:attachment_id/link", :AttachmentsRead do
  handle_issue_attachment_link(conn, conn.params["id"], conn.params["attachment_id"])
end
```

**Placement:** declared immediately after the existing
`authz_delete "/:id/attachments/:attachment_id"` route and **before** the bare
`authz_get "/:id"` — per the requirement's explicit instruction to place it before the
bare `authz_get "/:id/attachments/:attachment_id"` route, and consistent with this
router's own "Route ordering" moduledoc discipline for every `/:id/...` suffix (§3.3
below places both new routes together, ahead of the bare `/:id` route).

**Handler, `handle_issue_attachment_link/3` (signature + behavior, no body):**

```
@spec handle_issue_attachment_link(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
```

1. `opts = conn.assigns.scoped_opts`; `tenant_id = conn.assigns.auth_context.tenant_id`
   (same established pattern as `lib/letflow/routers/exam_sessions.ex:546` and this
   router's own `actor_id/1`).
2. `with {:ok, instance_id} <- cast_instance_id(raw_id), {:ok, _attachment} <-
   fetch_scoped_attachment_metadata(raw_attachment_id, instance_id, opts), {:ok,
   %{token: token, expires_at: expires_at}} <-
   AttachmentLinks.issue(raw_attachment_id, tenant_id) do ...`
   — reuses `fetch_scoped_attachment_metadata/3` **verbatim, unmodified** (the same
   private helper `DELETE` already uses) to prove existence + tenant + instance scope
   before minting anything. This is the metadata-only sibling, not
   `fetch_scoped_attachment_content/3` — issuing a link needs proof of access, not the
   byte content itself, so it does not touch `repository_artifacts` at all.
3. Success → `Response.ok(conn, %{"attachment_id" => raw_attachment_id, "token" =>
   token, "url" => link_content_url(raw_id, raw_attachment_id, token), "expires_at" =>
   DateTime.to_iso8601(expires_at), "expires_in_seconds" => 300})` — 200, not 201: no
   persisted resource is created (no migration, no row — see §6), so there is nothing
   for a `Location` header to point at, matching this codebase's existing precedent of
   reserving 201 for routes that create a durable row (`POST .../attachments` itself).
4. Errors: `{:error, :invalid_instance_id} → Response.unprocessable/2` (existing
   message, existing precedent); `{:error, :not_found} → Response.not_found/1`
   (identical call already used by every other attachment route — no new not-found
   shape introduced); `{:error, :invalid_tenant} → Response.internal_error/1` (INV-4,
   structurally unreachable per §2.2 step 2's own note, mapped defensively);
   `{:error, {:secret_write_failed, _}} → Response.internal_error/1` (INV-4 — no
   secret-subsystem detail ever reaches the response body, same discipline
   `Letflow.Webhooks`'s own `create/2` establishes for its identically-shaped error).

`link_content_url/3` (private helper, string-building only, no DB/Repo call):

```
@spec link_content_url(instance_id :: String.t(), attachment_id :: String.t(), token :: String.t()) :: String.t()
# "/instances/#{instance_id}/attachments/#{attachment_id}/link-content?link_token=#{URI.encode_www_form(token)}"
```

Relative path only (no scheme/host) — matches every other response shape in this
codebase, none of which construct absolute URLs.

### 3.2 New route — retrieve content by token

```
authz_get "/:id/attachments/:attachment_id/link-content", :AttachmentsRead do
  handle_get_attachment_link_content(conn, conn.params["id"], conn.params["attachment_id"])
end
```

**A deliberately separate route/handler from the existing
`GET /:id/attachments/:attachment_id` — not a modification of
`handle_get_attachment_content/3`.** This is what makes AC5 ("`fetch_scoped_
attachment_content/3`'s existing behavior is unchanged; its existing tests still pass")
trivially true: the existing route, its existing handler, and every function it calls
are **byte-for-byte unmodified** by this requirement. `fetch_scoped_attachment_content/3`
is *reused* (called a second time, from a second call site) but not edited.

**Handler, `handle_get_attachment_link_content/3` (signature + behavior, no body):**

```
@spec handle_get_attachment_link_content(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
```

1. `opts = conn.assigns.scoped_opts`; `tenant_id = conn.assigns.auth_context.tenant_id`.
2. `conn = fetch_query_params(conn)`; `link_token = conn.query_params["link_token"]`
   (existing `fetch_query_params/1` pattern already used by the list/history routes in
   this same file).
3. `with {:ok, instance_id} <- cast_instance_id(raw_id), {:ok, decoded_attachment_id} <-
   verify_link_token(link_token, tenant_id), :ok <-
   check_attachment_id_matches(decoded_attachment_id, raw_attachment_id), {:ok,
   attachment, artifact} <- fetch_scoped_attachment_content(decoded_attachment_id,
   instance_id, opts) do send_attachment_content(conn, attachment, artifact) end`
   — the **exact same** `fetch_scoped_attachment_content/3` and `send_attachment_content/2`
   the existing route already uses, called with the attachment id **recovered from the
   verified token**, not the raw path segment (see step 4).
4. `verify_link_token/2` (private, thin wrapper): `nil` or non-binary `link_token` →
   `{:error, :expired_or_invalid}` without calling `AttachmentLinks.verify/3` at all
   (a missing token is exactly as invalid as a malformed one — same shared response,
   see §7); otherwise delegates to `AttachmentLinks.verify(link_token, tenant_id)`.
5. `check_attachment_id_matches/2` (private): `decoded_attachment_id ==
   raw_attachment_id` (the path's own `:attachment_id` segment) → `:ok`; otherwise
   `{:error, :expired_or_invalid}` — **not** `{:error, :not_found}`. A token that is
   validly signed and unexpired but names a *different* attachment than the URL it was
   presented on is treated as an integrity failure of the token/URL pairing, folded into
   the same expired-or-invalid response as every other verification failure, not as a
   "resource doesn't exist" response — keeps exactly one failure class for
   "the token doesn't check out," matching §7's structural requirement.
6. Errors, exhaustively: `{:error, :invalid_instance_id} → Response.unprocessable/2`
   (unchanged existing precedent — this check runs first, before the token is even
   inspected, same order the plain content route already uses for its own instance-id
   cast); `{:error, :expired_or_invalid} → Response.attachment_link_expired/1` (new,
   §4); `{:error, :not_found} → Response.not_found/1` (existing, unchanged — reached
   only once verification and the id-match check both already passed, i.e. only when
   the token itself checked out but the now-decoded attachment id is not
   tenant/instance-scoped to the caller — e.g. the attachment was deleted after the
   token was issued); `{:error, :content_missing} → Response.internal_error/1`
   (existing, unchanged); `{:error, :not_available} → Response.conflict/2` (existing,
   unchanged).

### 3.3 Route ordering (full picture)

```
authz_post "/:id/attachments", :AttachmentsManage
authz_get  "/:id/attachments", :AttachmentsRead
authz_post "/:id/attachments/:attachment_id/link", :AttachmentsRead         # NEW
authz_get  "/:id/attachments/:attachment_id/link-content", :AttachmentsRead # NEW
authz_get  "/:id/attachments/:attachment_id", :AttachmentsRead              # unchanged
authz_delete "/:id/attachments/:attachment_id", :AttachmentsManage          # unchanged
authz_get  "/:id", :InstancesRead
```

Both new routes have one more literal path segment than
`/:id/attachments/:attachment_id`, so — unlike the historical `/:id` vs. `/:id/history`
hazard this router's own moduledoc documents — there is no segment-count collision
either way; they are placed above the bare 3-segment route anyway, matching the
existing declared convention of listing longer, more-specific suffixes first, and
satisfying the requirement's own explicit placement instruction for the `POST .../link`
route.

---

## 4. New `Letflow.Api.Error` / `Letflow.Api.Response` helpers

```
# lib/letflow/api/error.ex
@spec attachment_link_expired() :: t()
def attachment_link_expired
# status: 410, detail: a fixed, plain-language string along the lines of
# "This link has expired or is no longer valid. Request a new link and try again."
# No caller-supplied detail parameter -- same "no slot for per-call variation" shape
# as not_found/0 and internal/0, and for the identical reason: AC4 requires this
# call's output to never vary by caller/input, so the function signature itself must
# make that impossible, not just the call site's current usage.

# lib/letflow/api/response.ex
@spec attachment_link_expired(Plug.Conn.t()) :: Plug.Conn.t()
def attachment_link_expired(conn), do: send_problem(conn, Error.attachment_link_expired())
```

410 Gone chosen over 404 (would blur into the unrelated not-found class this response
must stay distinguishable from in its *wording*, even while staying indistinguishable
from it in *cause*) and over 401/403 (this is not an authentication/authorization
failure of the request's own bearer token — the request may be otherwise fully
authenticated and permitted; it is the separate, additional signed-link layer that
failed). `Error.cursor_expired/0` (410, existing) is not reused verbatim because its
message is cursor-specific and REQ-386's own EO-003 requires attachment-link-specific
wording — but it is the shape this new function copies.

---

## 5. `Letflow.Api.Authorization` changes

Two new `endpoint_policy_key/2` clauses (both map to the already-existing
`:AttachmentsRead` atom — no new permission, no new `required_permission/1` clause, no
role-matrix change):

```
def endpoint_policy_key("POST", "/instances/:id/attachments/:attachment_id/link"),
  do: :AttachmentsRead

def endpoint_policy_key("GET", "/instances/:id/attachments/:attachment_id/link-content"),
  do: :AttachmentsRead
```

Required so `test/letflow/api/authorization_enforcement_test.exs`'s introspection
(`__authz_routes__/0` vs. `endpoint_policy_key/2`) resolves both new routes through a
real clause rather than needing an allowlist entry.

---

## 6. Database — no migration needed

**No new table, no new column, no change to `priv/repo/migrations/`.** Verification is
stateless computation: `AttachmentLinks.verify/3` recovers everything it needs
(attachment id, expiry, which secret version to check against) from the token itself
plus a `Letflow.Secrets.resolve/2` call against the **already-existing** `secrets` table
(REQ-190). There is no "issued links" registry — nothing is written to the database at
issuance time beyond, at most, a lazily-created row in the pre-existing `secrets` table
the very first time a given tenant ever issues an attachment link (§2.2 step 3), which
is `Letflow.Secrets`' own existing schema, not a new one.

---

## 7. Invariants (security-invariants.md, per AC6)

- **INV-1 (tenant data isolation) — APPLIES, satisfied.** Both new routes derive their
  `opts[:prefix]` exactly the way every other route in this router does
  (`conn.assigns.scoped_opts`, itself derived solely from
  `conn.assigns.auth_context.tenant_id`, never from the token or any request body/path
  value). The `secrets` table rows this design reads/writes are also `tenant_id`-scoped
  via `Letflow.Secrets`' own existing, already-reviewed mechanism (0016 §B) — this
  design adds no new query against `secrets` that bypasses it.
- **INV-4 (secrets by reference only) — APPLIES, satisfied.** The signing-key plaintext
  is resolved via `Letflow.Secrets.resolve/2` and used **only** as the immediate second
  argument to `:crypto.mac(:hmac, :sha256, ...)` inside `AttachmentLinks.issue/3` and
  `verify/3` — never returned from either function, never logged, never placed in a
  response body, error tuple, or handoff-adjacent artefact. The opaque `token` string
  returned to the caller contains the **payload and its signature**, never the signing
  key itself — recovering the key from a token requires inverting HMAC-SHA256, not
  reading a field.
- **INV-5 (not-found/forbidden indistinguishability) — APPLIES, satisfied, by
  construction (§1/§2.3/§3.2).** This is the invariant AC4 is a direct instance of.
  Mechanical argument, restated once more explicitly: `handle_get_attachment_link_content/3`'s
  `with` chain calls `verify_link_token/2` **before** `check_attachment_id_matches/2`
  and **before** `fetch_scoped_attachment_content/3` are ever reached. `AttachmentLinks.verify/3`
  itself (§2.3) has exactly one failure-side return value
  (`{:error, :expired_or_invalid}`) reachable from six structurally different failure
  causes (malformed token, bad JSON, unknown tenant, unresolvable/wrong-tenant
  secret, signature mismatch, expiry). The router's own `else` clause for that value
  calls exactly one function, `Response.attachment_link_expired/1`, which itself takes
  no caller-suppliable argument (§4) — there is no code path between "verification
  failed" and "response sent" in which the identity of the failing attachment id (real,
  foreign-tenant, or never-issued) could influence the bytes written to the connection,
  because that identity is never inspected on the failure path at all — the handler
  does not call `Attachments.get_content/2`/`fetch_scoped_attachment_content/3` until
  *after* verification has already succeeded. A cross-tenant real attachment id and a
  fabricated never-issued attachment id therefore take the **identical set of function
  calls** on this route whenever the presented token is expired-or-invalid, differing
  only in which of the six `AttachmentLinks.verify/3` sub-checks happens to be the one
  that fails first — a difference invisible outside that function, since only its
  single collapsed return value crosses the boundary back to the router.

  This existing route's own INV-5 guarantee (real-but-foreign-tenant vs.
  never-existed, for a **valid, unexpired** token) is unchanged and still holds,
  because it is still `fetch_scoped_attachment_content/3` — untouched — doing that
  folding, exactly as before REQ-386.
- **INV-6 (new data-access paths prove their scoping) — this document is that proof**
  for both new routes, per the INV-1/INV-4/INV-5 entries above.
- **INV-7 (no SQL string interpolation) — APPLIES, satisfied.** No `Repo.query`/raw SQL
  anywhere in this design; every DB touch goes through `Letflow.Secrets`' and
  `Letflow.Identity`'s existing `Ecto.Query`-based functions.
- **INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, satisfied.**
  Every function in `AttachmentLinks` returns a tagged tuple; the `with`/`else` shape in
  `verify/3` specifically exists so a malformed/attacker-controlled token (external
  input, arrives on every call) can never raise — `Base.url_decode64/2` and
  `Jason.decode/1` failures are both explicitly caught by the `with` chain's `else`,
  never left as a bare match. The one place this design tolerates a raise (`Letflow.Secrets.resolve/2`'s
  own documented GCM-authentication-failure raise inside `decrypt/1`, unchanged,
  upstream of this design) is pre-existing, already-reviewed `Letflow.Secrets` behavior,
  not something this design introduces or widens.

---

## 8. Cross-module dependencies

| Module | What this design uses from it | Changed? |
|---|---|---|
| `Letflow.Secrets` | `put/2`, `resolve/2` | No — `:generic`/`:generic` already legal |
| `Letflow.Identity` | `get_tenant/1` | No |
| `Letflow.Repository.Attachments` | (indirectly, via the router's unchanged private helpers) `get_content/2`/`get/2` | No |
| `Letflow.Routers.Instances` | new routes, two new private handlers, two new private helpers, reuses `fetch_scoped_attachment_content/3`/`fetch_scoped_attachment_metadata/3`/`cast_instance_id/1`/`send_attachment_content/2` verbatim | Yes — additive only |
| `Letflow.Api.Response` / `Letflow.Api.Error` | new `attachment_link_expired/0-1` pair | Yes — additive only |
| `Letflow.Api.Authorization` | two new `endpoint_policy_key/2` clauses | Yes — additive only |
| `Letflow.Api.AuthorizedRouter` | `authz_post`/`authz_get` macros (unchanged) | No |
| `Letflow.Api.Context` | `scoped_repo_opts/1` (indirectly, already resolved into `conn.assigns.scoped_opts` before this router's code runs) | No |

New module `Letflow.Repository.AttachmentLinks` (`lib/letflow/repository/attachment_links.ex`)
depends on `Letflow.Secrets`, `Letflow.Identity`, `Jason`, `:crypto`, `Base`.

---

## 9. Open questions

**OQ-1 — should the token-serving route ever be reachable without the standard
`:AttachmentsRead`-gated bearer-token pipeline (e.g. for a `web/` `<img>`/`<iframe>`
embed that cannot attach an `Authorization` header)?** Not decided here, deliberately.
`Letflow.Api.AuthorizedRouter`'s own moduledoc states as a structural guarantee that
**no route on a router using it bypasses `Letflow.Plugs.Authorize`** — every route,
`authz_*`-declared or not, passes through it. Building a genuinely unauthenticated,
token-only route would require a new sub-router mounted outside
`Letflow.Plugs.ApiPipeline`'s auth stage, which is a materially larger and separately
security-relevant architecture change than "the mechanism" this requirement scopes
("backend only... builds the mechanism"), and none of REQ-386's six acceptance criteria
require it (all are phrased in terms of an authenticated endpoint / a caller who already
has `:AttachmentsRead`). This design therefore keeps the token-serving route behind the
same mandatory auth pipeline as every other route in this file, with the signed-token
check layered in front of/alongside the existing lookup exactly as the requirement's own
wording describes. If REQ-387 (the frontend document viewer, currently blocked on this
requirement) turns out to need a truly unauthenticated fetch, that is a distinct,
separately-reviewable follow-up requirement, not something to guess at here. Flagged for
REVIEWER.

**OQ-2 — token format is not versioned.** The JSON payload has no `"v"`/version key.
If a future requirement needs to change the token's field set, older still-valid
(un-expired) tokens minted under the old format would fail to decode under a naive
schema change and would need to be treated as `:expired_or_invalid` (which is safe —
never silently misinterpreted — but does mean an in-flight token is invalidated by a
deploy that changes the payload shape). Given the token's own 5-minute lifetime, this
was judged not worth a version field's added complexity for this requirement, but is
worth a REVIEWER sanity check.

**OQ-3 — response body key names (`"url"`, `"token"`, `"expires_at"`,
`"expires_in_seconds"`) are this design's own choice**, since REQ-387 (the only
consumer) does not exist yet to bind against, the same "this requirement DEFINES the
response shape" situation REQ-212's own moduledoc already documents for the attachment
routes generally. Not silently resolved — stated here as a deliberate choice REQ-387
will consume as a fixed contract, flagged in case REVIEWER wants a different shape
before it is load-bearing for a real frontend.
