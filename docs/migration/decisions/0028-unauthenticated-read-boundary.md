# 0028 — Letflow has exactly one unauthenticated read surface, and it is addressed by capability handle

Status: decided (2026-09-12, `CODE-DESIGNER`, REQ-323), pending its own
`SECURITY-REVIEWER` and `REVIEWER` gates. Owner: `ORCH` (stage S10, motivation
**S10 gap 6**, cited by number per decision 0022 rule 1).

Full mechanism: `lib/letflow/design/req323-unauthenticated-read-pattern.md`. This
record is deliberately short — it carries the decision and the prohibitions that bind
future requirements; the design doc carries the derivation, the round-trip analysis and
the source citations. Same division as `0024` and REQ-295's design.

## Question

Letflow's auth pipeline has no hole in it. `Letflow.Plugs.AuthPipeline` has no
public-path allowlist, no bypass and no `skip` option: every request reaching it without
a valid bearer token is 401'd and halted before dispatch. The three routes that are
public today (`/api/tenant-config` REQ-078, `/api/mobile/tenant-config` REQ-124,
`/metrics` REQ-194) are public by being mounted on `Letflow.Router` **ahead** of the
`/api/v1` forward, never by opting out from inside the pipeline.

None of those three reaches inside a tenant schema: the first two read the global
`tenants` table, the third reads only process-wide ETS. So Letflow has never had to
answer the question a read-only resource served to a credential-free caller forces:

**How is a tenant — and therefore an Ecto `:prefix` — resolved when there is no token,
given that `Letflow.Api.Context.scoped_repo_opts/1` reads
`conn.assigns.auth_context.tenant_id` and nothing else, and that field does not exist on
an unauthenticated request?**

Three sub-questions hang off it, and none of the three existing mounts answers any:

1. Where does such a route mount, and is the shape reusable or bespoke per instance?
2. What prevents the resolution mechanism from becoming a tenant-enumeration or
   resource-existence oracle (INV-5)?
3. What replaces `Letflow.Plugs.TenantStatus`, which is a silent no-op with no auth
   context?

## Decision

**Letflow has exactly one unauthenticated read surface, `/api/public`, and a resource is
reached on it by an opaque capability handle that is itself the credential.**

1. **One mount.** A fourth sibling `forward("/api/public", to: Letflow.Routers.PublicRead)`
   on `Letflow.Router`, declared before the `/api/v1` forward. Not inside
   `Letflow.Plugs.ApiPipeline`; not by adding an allowlist to `AuthPipeline`; not a
   bespoke top-level mount per resource type. Route shape:
   `GET /api/public/<kind>/:handle`, plus a catch-all.

2. **One resolution mechanism.** A global `public_read_handles` table (alongside
   `tenants`, outside every tenant schema) maps a handle to `{tenant_id, kind,
   resource_id}`. `tenant_id` from that row feeds the **same**
   `Letflow.TenantProvisioning.schema_name_for_tenant/1` derivation every authenticated
   path already uses; every tenant-scoped read is then `Repo.*(..., prefix:)` exactly as
   it would be behind auth. INV-1's storage mechanism is unchanged — only the source of
   `tenant_id` differs, and it is server-written at issue time, never caller-supplied.

3. **Handles are unguessable and structureless.** 32 bytes of
   `:crypto.strong_rand_bytes/1`, URL-safe base64, stored as SHA-256 only. Not derived
   from the resource id, tenant id, timestamp or counter. 2^256 space; guessing is not a
   threat model. This is the concrete property — not an assurance — that makes the
   surface unenumerable: there is no tenant-shaped, slug-shaped or id-shaped input to
   probe with.

4. **One refusal.** Every non-success outcome — malformed handle, unknown handle,
   revoked, expired, kind-mismatched, resource deleted, resource unpublishable,
   unregistered kind, wrong method, deactivated tenant — returns an identical `404`
   `application/problem+json` from `Letflow.Api.Response.not_found/1`, byte-identical to
   `Letflow.Router`'s own catch-all. Resolution performs exactly **one** database
   round-trip before any refusal decision and **two** on success; a malformed handle
   must not short-circuit ahead of that first query.

5. **Reusable, not one-off.** The mount, the router, the registry, the limiter, the
   refusal path and the response envelope are fixed platform machinery. A new
   unauthenticated read contributes a kind string and a projection module, and designs
   no boundary of its own.

6. **Rate limiting is a precondition of mounting, not a follow-on.** Per-IP (from
   `conn.remote_ip`, not an attacker-settable header) plus a global bucket, enforced as
   the first plug inside `Letflow.Routers.PublicRead` — before resolution, so a `429` is
   input-independent and discloses nothing.

## Standing prohibitions

These bind every future requirement that touches `/api/public`, and are the reason this
is a decision record rather than only a design doc:

- **No caller-supplied tenant hint, in any form.** No `?tenant=`/`?realm=` parameter, no
  tenant path segment, no `X-Tenant-Slug` header, no `Host`-based resolution (Letflow has
  no host→tenant binding, and one must not be added without an owning requirement — see
  `Letflow.Routers.TenantConfig`'s moduledoc). Any of these is an INV-1 violation.
- **No `401` and no `403`, ever, on this route class.** A `403` states "this exists and
  you may not have it", which is the distinction INV-5 forbids. `Letflow.Plugs.TenantStatus`'s
  `403 tenant_inactive` is correct behind auth and wrong here; a deactivated tenant's
  handle returns the standard `404`, decided from a join in the single existing
  round-trip rather than a second query.
- **No collection, index, search or pagination route under `/api/public`.** The only
  shape is fetch-one-by-handle.
- **No second lookup to produce a better error message.** Already forbidden for the
  authenticated case by `Letflow.Api.Context`'s moduledoc; forbidden here additionally
  because the extra query appears only on the miss path and is itself the timing signal.
- **Adding a top-level key to the public response envelope, or a field to any kind's
  projection, is a security change, not a feature** — SECURITY-REVIEWER sign-off against
  INV-2 and INV-5, in the requirement that adds it. Projections are hand-built maps with
  literal named keys, never derived from an Ecto struct.
- **`public_read_handles` must land with its first writer**, not ahead of one. A table
  with no producer is the REQ-056 failure mode.

## Why a record, and not the design doc alone

REQ-308 §10 set the test: an ordinary route-table or authorization-matrix choice stays in
its own design doc; a cross-cutting architectural question that is load-bearing for
future requirements gets a record (contrasting itself with `0024`). This clears that bar
on three counts. It establishes a **second source of `tenant_id`** parallel to
`conn.assigns.auth_context`, changing the set of ways INV-1 can be satisfied
platform-wide. Its prohibitions bind requirements that do not exist yet, which is
precisely what a record is for. And "why does Letflow have a public route class at all,
and why does it look like this" is a question that will be asked again in the form "why
not just add an allowlist to `AuthPipeline`" — answered once, here.

## Accepted bounded inference

Stated rather than claimed away, in the manner `Letflow.Routers.TenantConfig`'s moduledoc
documents its own:

1. A handle holder learns the handle is valid and its resource is publishable. That is
   the surface's purpose.
2. A former holder can distinguish live from revoked. Not reachable by probing — only by
   someone who already held a live handle and already had the data.
3. Anyone can learn which `<kind>` strings a deployment registers, from the zero-vs-one
   round-trip difference. A property of the installed feature set, naming no tenant and
   no resource — the same class as which top-level routes exist.

Not accepted, and closed: learning that a tenant exists, that it has published anything,
how much, or whether any particular id or slug is real.

## Consequences

- REQ-323 implements nothing. The first `/api/public` instance is a later requirement,
  which brings with it the router, the migration, its writer, the limiter and one
  projection — and is a named `SECURITY-REVIEWER` hard gate.
- `Letflow.Plugs.AuthPipeline` keeps its no-allowlist property permanently. Any future
  proposal to add one is a reopening of this record.
- The deferred `Letflow.Plugs.RateLimit` row in `Letflow.Plugs.ApiPipeline`'s table is
  **not** discharged by this record; the limiter specified here is narrower and
  differently keyed. Reuse is permitted if that module lands mount-point-agnostic.

## Open questions this record does not answer

Carried in the design doc §11: the authenticated issue path and its permission atom
(OQ-1), limiter reuse (OQ-2), handle rotation (OQ-3), multi-node limiting (OQ-4), and
whether a future non-JSON response body changes the `Referrer-Policy` analysis (OQ-5).

## Gates

**SECURITY-REVIEWER — 2026-09-12 — PASS.** INV-1, INV-5 (both halves) and INV-8 apply
and are satisfied; INV-2 and INV-4 also apply and pass; INV-3, INV-7 and INV-9 do not
apply to a design carrying no executable Elixir. Every source claim in the design and in
this record was re-derived from the tree rather than trusted, and no inaccurate claim was
found. The full verdict, with the concrete mechanism for each invariant and the seven
conditions binding the implementing requirement, is recorded in
[`lib/letflow/design/req323-unauthenticated-read-pattern.md`](../../../lib/letflow/design/req323-unauthenticated-read-pattern.md)
§12 rather than duplicated here.

*(Space reserved for `REVIEWER`'s sign-off.)*
