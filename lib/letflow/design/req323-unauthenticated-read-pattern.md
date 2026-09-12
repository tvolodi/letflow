# REQ-323 — Design: the unauthenticated read pattern, its mount point and its disclosure boundary

Stage S10 (motivation: **S10 gap 6** — cited by number only, per decision 0022 rule 1).
Per that rule this document uses no domain-vertical vocabulary of any kind; see §13.
Bucket **B** (generic platform capability).
Owner: `CODE-DESIGNER`. Status: design only — this requirement mounts no route, adds no
plug, adds no permission atom, writes no migration and writes no test.

This document designs **the pattern**: how Letflow serves a read-only resource to a
caller that presents no credential, where such a route mounts, and where its disclosure
boundary sits. It deliberately designs **no particular endpoint**. A later
`ELIXIR-DEV` requirement builds the first instance from this document without
re-deriving the mount point, the resolution mechanism or the response allowlist.

---

## 0. Premises re-verified against the tree (2026-09-12)

Every claim below was re-derived from the current working tree, not inherited from the
requirement text.

### 0.1 `Letflow.Router` has exactly three public pre-forward mounts

```
$ grep -n 'forward(' lib/letflow/router.ex
101:  forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)
108:  forward("/api/mobile/tenant-config", to: Letflow.Routers.MobileTenantConfig)
114:  forward("/metrics", to: Letflow.Routers.MetricsExposition)
116:  forward("/api/v1", to: Letflow.Plugs.ApiPipeline)
```

Four `forward/2` calls total; **three** of them are public mounts, and all three appear
at lines 101/108/114 — that is, **all three precede** the `/api/v1` forward at line 116.
Confirmed: `/api/tenant-config` (REQ-078), `/api/mobile/tenant-config` (REQ-124),
`/metrics` (REQ-194). Plus `get "/health"` inline at `lib/letflow/router.ex:95-97`.
The count is three; the requirement's stated premise holds.

`Letflow.Router`'s own plug chain is (`lib/letflow/router.ex:89-92`):

```
plug(Letflow.Plugs.Cors)
plug(Letflow.Plugs.HttpMetrics)
plug(:match)
plug(:dispatch)
```

Two plugs, both response-header/telemetry-only. No parser, no auth, no trace id.
`Letflow.Api.Context.assign_trace_id/1` is deliberately **not** mounted here
(`lib/letflow/router.ex:31-35`) because it would change `GET /health`'s response
headers, which `deploy/redeploy-test.sh` pins.

### 0.2 `Letflow.Plugs.AuthPipeline` has no allowlist, no bypass, no skip

Read in full (`lib/letflow/plugs/auth_pipeline.ex`, 336 lines). Its entry point
(`:107-119`) is:

```
def call(conn, _opts) do
  case extract_bearer_token(conn) do
    {:ok, raw_token} -> if api_token?(raw_token), do: ..., else: ...
    {:error, reason} -> handle_auth_error(conn, {:error, reason})
  end
end
```

There is **no** `conn.request_path` read anywhere in the module, no `:except`/`:only`
option (`init/1` at `:96-97` is `def init(opts), do: opts` — opts are never consulted
by `call/2`, which pattern-matches `_opts`), and no public-path list. Every failure
funnels into `handle_auth_error/2` (`:151-184`), whose *first* clause — the missing or
malformed `Authorization` header case — is:

```
{:error, {:header, _reason}} ->
  reject(conn, 401, "unauthorized", "missing or malformed Authorization header")
```

and `reject/4` (`:329-336`) `send_resp`s and `halt()`s. A credential-free request that
reaches this plug therefore **always** receives 401 and is halted before dispatch.

**This is the whole reason a public route must mount outside the pipeline rather than
opt out from inside it.** There is nothing to opt out of; the plug offers no seam.

### 0.3 `Letflow.Api.Context.scoped_repo_opts/1` is structurally unavailable here

Quoted verbatim from `lib/letflow/api/context.ex:217-237`:

```elixir
@spec scoped_repo_opts(Plug.Conn.t()) ::
        {:ok, prefix: String.t()} | {:error, :missing_auth_context | :invalid_tenant_id}
def scoped_repo_opts(conn) do
  case tenant_id_from_auth_context(conn) do
    {:ok, tenant_id} ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> {:ok, prefix: schema_name}
        {:error, :invalid_tenant_id} -> {:error, :invalid_tenant_id}
      end

    :error ->
      {:error, :missing_auth_context}
  end
end

defp tenant_id_from_auth_context(conn) do
  case conn.assigns[:auth_context] do
    %{tenant_id: tenant_id} when not is_nil(tenant_id) -> {:ok, tenant_id}
    _other -> :error
  end
end
```

Its own moduledoc (`lib/letflow/api/context.ex:59-63`) states the constraint that makes
it unusable on an unauthenticated route:

> `scoped_repo_opts/1` — takes only `conn`, and reads exactly one field from it,
> `conn.assigns[:auth_context][:tenant_id]`. There is no parameter slot into which a
> caller could pass a path/query/header tenant hint, so it cannot happen by mistake,
> not merely "by convention."

On a route with no token, `conn.assigns[:auth_context]` is never set — `AuthPipeline`
is the only writer (`attach_auth_context/4`, `lib/letflow/plugs/auth_pipeline.ex:325-327`),
and it never ran. So `tenant_id_from_auth_context/1` falls to its `_other -> :error`
clause and `scoped_repo_opts/1` returns `{:error, :missing_auth_context}`, whose own
`@doc` (`:211-215`) is explicit:

> **Neither error case falls through to an unscoped query.** A caller receiving
> `{:error, _}` MUST NOT proceed to call `Repo.*` without a prefix.

**Therefore: INV-1's standard mechanism is unavailable on this route class, by
construction, and cannot be made available by adding a parameter to it.** §3 designs
what replaces it.

### 0.4 The prefix-derivation primitive itself is pure and reusable

`lib/letflow/tenant_provisioning.ex:212-219`:

```elixir
@spec schema_name_for_tenant(tenant_id :: Ecto.UUID.t()) ::
        {:ok, schema_name :: String.t()} | {:error, :invalid_tenant_id}
def schema_name_for_tenant(tenant_id) do
  case Ecto.UUID.cast(tenant_id) do
    {:ok, canonical} -> {:ok, "tenant_" <> String.replace(canonical, "-", "")}
    :error -> {:error, :invalid_tenant_id}
  end
end
```

Pure, no I/O, total. It is *not* the part that is unavailable — what is unavailable is
the trustworthy `tenant_id` to feed it. That distinction is the hinge of §3.

### 0.5 `Letflow.Plugs.TenantStatus` reads only the auth context

`lib/letflow/plugs/tenant_status.ex:71-81`:

```elixir
def call(conn, _opts) do
  tenant_id = get_in(conn.assigns, [:auth_context, :tenant_id])
  check_tenant_status(conn, tenant_id)
end

defp check_tenant_status(conn, nil), do: conn
```

With no auth context it is a **no-op pass-through** — and its own comment (`:76-80`)
says this case is "explicitly not a defended-against case." Its two real checks are the
deactivation gate (403 when `status == :inactive` and the caller is not
`PLATFORM_ADMIN`) and the write-pause gate (503 when `status == :migrating` and the
method is one of `POST/PUT/PATCH/DELETE`, `:63`). Both reuse **one**
`Repo.get(Tenant, tenant_id)` (`:84`). §7 addresses what this means here.

### 0.6 Problem-document shaping degrades gracefully outside the pipeline

`lib/letflow/api/response.ex:196-197`:

```elixir
defp effective_trace_id("", conn), do: conn.assigns[:trace_id] || ""
defp effective_trace_id(trace_id, _conn) when is_binary(trace_id), do: trace_id
```

So `Response.send_problem/2` and every helper funnelling through it (`not_found/1` at
`:146-147`, etc.) **work correctly with no trace id** — they emit
`application/problem+json` with `trace_id: ""`. This is a fact the `TenantConfig`
precedent did not need to establish (it never emits a problem document) and which this
design relies on; see §8.

### 0.7 No rate limiter exists in the tree today

```
$ grep -rn "Plugs.RateLimit" lib/ --include=*.ex
lib/letflow/plugs/api_pipeline.ex:59:  | `Letflow.Plugs.RateLimit`        | `rate_limit.zig`         | S4 (to port)  |
```

One hit, and it is the **deferred-plugs table row**, not a mount. `lib/letflow/plugs/`
contains `admission.ex, api_pipeline.ex, auth_pipeline.ex, authorize.ex,
content_type.ex, cors.ex, http_metrics.ex, safe_json_parser.ex, tenant_status.ex` — no
rate-limit module. `Letflow.Plugs.Admission` exists but is mounted only inside
`ApiPipeline` (`lib/letflow/plugs/api_pipeline.ex:88, :135`) and is a concurrency
admission gate, not a request-rate limiter. §5 is written against this fact.

### 0.8 The opaque-credential precedent in this codebase

`lib/letflow/identity.ex:1055`:

```elixir
"lf_tok_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
```

32 CSPRNG bytes rendered as lowercase hex, behind a literal prefix. §3 reuses this
construction shape (not this function) for the public handle.

---

## 1. Route table for the pattern

In the same Handler/Method-path/Delegate/Auth/Response column form as
`Letflow.Routers.TenantConfig`'s moduledoc (`lib/letflow/routers/tenant_config.ex:8-10`).

The precedent's table, for side-by-side comparison:

| Handler | Method/path            | Delegate                                | Auth     | Response |
|---------|------------------------|-----------------------------------------|----------|----------|
| config  | `GET /api/tenant-config` | `Letflow.Identity.get_tenant_by_slug/1` | **none** | always 200, `{oidc_authority, client_id, branding}` |

This design's table (`<kind>` and `<handle>` are the pattern's two path variables; a
concrete instance substitutes a literal for `<kind>`):

| Handler | Method/path                      | Delegate                                        | Auth     | Response |
|---------|----------------------------------|-------------------------------------------------|----------|----------|
| show    | `GET /api/public/<kind>/:handle` | `Letflow.PublicRead.resolve/2` → the kind's own projection function | **none** | `200` with the kind's allowlisted projection on a resolved handle; `404` `application/problem+json` on **every** other input (see §4) |
| catch-all | `match _` (any method/path under `/api/public`) | — | **none** | `404` `application/problem+json`, identical to the miss body |

Two rows, deliberately. The catch-all row is load-bearing, not boilerplate: it is what
makes an unrecognised `<kind>`, a wrong HTTP method and an unresolvable `<handle>` all
produce the same response (§4.3).

---

## 2. Where such a route mounts

**Decision: a fourth sibling `forward/2` on `Letflow.Router`, at `/api/public`,
declared after `/metrics` (line 114) and before the `/api/v1` forward (line 116),
delegating to one new sub-router module `Letflow.Routers.PublicRead`.**

Rejected alternatives, with reasons:

| Option | Rejected because |
|---|---|
| A sub-path *inside* `Letflow.Plugs.ApiPipeline` (i.e. under `/api/v1`) | `AuthPipeline` offers no seam (§0.2). Every credential-free request is 401'd and halted before `:dispatch`. This is precisely REQ-070's mistake that REQ-078 had to undo (`lib/letflow/plugs/api_pipeline.ex:75-80`). Non-starter, not a preference. |
| Adding a public-path allowlist to `AuthPipeline` so a public route can live under `/api/v1` | Turns one plug that is trivially auditable ("no request without a valid bearer token gets past this") into one whose correctness depends on a path list staying right forever. The property in §0.2 is worth more than URL tidiness. A path-allowlist bug is silent and total. |
| A sub-path of an existing public mount (e.g. `/api/tenant-config/...`) | Those three routers each answer one narrow question (login bootstrap, mobile login bootstrap, scrape target). Hanging an unrelated resource read off one of them would couple its never-error posture (§0.9 of the precedent / §6 here) to a route class that must *not* be never-error. |
| A separate Bandit endpoint on its own port | Real isolation, but it changes the deployment surface (`deploy/`, compose, health checks) for a capability that has no instance yet. Disproportionate. Revisit only if the first instances prove to need independent resource limits. |
| One new top-level forward per concrete public resource | Would repeat `/api/tenant-config`, `/api/mobile/tenant-config`, `/metrics`'s pattern of one bespoke top-level path per capability. Fine at three; not fine as a growth rule. `/api/public` is one mount that absorbs every future instance as a `<kind>` segment. |

Justification against the three existing mounts, each cited:

- **`/api/tenant-config` (REQ-078)** — mounted at top level for exactly the §0.2 reason
  (`lib/letflow/router.ex:99-101`: "declared BEFORE the /api/v1 forward so it never
  enters Letflow.Plugs.AuthPipeline, which has no bypass"). This design's mount is the
  same tier for the same reason, so the precedent is followed rather than diverged from.
- **`/api/mobile/tenant-config` (REQ-124)** — establishes that a *second* mount at the
  same tier is acceptable rather than something to be folded into the first
  (`lib/letflow/router.ex:103-108`). Precedent that adding a sibling forward is a normal,
  already-taken step.
- **`/metrics` (REQ-194)** — establishes that a top-level public mount may serve
  something that is not login bootstrap at all, and that "unauthenticated" is decided
  per-route on a disclosure argument rather than by category
  (`lib/letflow/routers/metrics_exposition.ex`, the "tenant-safety invariant" section).
  This design's §4 is the same kind of argument for a different route class.

**Why `/api/public` and not a bare `/public`:** every non-`/health`, non-`/metrics`
HTTP surface Letflow serves is under `/api`; `/metrics` is outside it only because
Prometheus scrape targets conventionally are. A resource read is an API read.

**Module shape:** one `use Plug.Router` module, `Letflow.Routers.PublicRead`, with
`plug(:match)` / `plug(:dispatch)` and no other plug in its own chain — identical in
shape to `Letflow.Routers.TenantConfig` (`lib/letflow/routers/tenant_config.ex:150,
183-192`). It fetches whatever it needs off the conn itself (`fetch_query_params/1` if
a future instance needs query params; none is needed for the pattern as designed, which
takes its only input from the path).

The `<kind>` segment dispatches to a **registered** projection module (§4.4) rather
than to a `case` over string literals, so adding an instance does not edit this router's
control flow. `Letflow.Routers.PublicRead` itself must never contain a
resource-type-specific branch.

---

## 3. The disclosure boundary, part 1: resolving a tenant with no token (INV-1)

### 3.1 The problem stated precisely

`scoped_repo_opts/1` cannot run (§0.3). But INV-1 is not relaxed by the absence of a
token — its rule is unconditional: *"Every access to tenant business data is scoped to
exactly one tenant, with no exception for internal, admin, or system-worker paths"*
(`docs/agents/instructions/security-invariants.md:48-49`). An unauthenticated path is
not on that exception list either, because there is no exception list.

So the requirement on this design is: produce a **trustworthy `tenant_id`** from the
request, with no token, such that the request cannot influence *which* tenant is
resolved beyond the one the resource itself belongs to.

### 3.2 The mechanism: a capability handle, and a global handle registry

**A public read is addressed by an opaque capability handle, not by a resource id plus
a tenant hint. The handle is the credential.**

Concretely:

1. A **global** table, `public_read_handles`, living in the `public` schema alongside
   `tenants` (`priv/repo/migrations/20260816000001_create_tenants.exs:26` establishes
   that global-table tier). Its columns are specified in §3.5. This table is **not**
   tenant-scoped, and that is deliberate — it is the *lookup* that determines which
   tenant scope to enter, so it cannot itself live inside one, exactly as `tenants`
   cannot.
2. The route's only input is `:handle`, a path segment. Resolution is
   **one** `Repo.get_by(PublicReadHandle, handle_hash: hash_of(handle))` against that
   global table — no prefix, because the table is global.
3. That row carries `tenant_id`. The prefix is then derived by feeding it to
   `Letflow.TenantProvisioning.schema_name_for_tenant/1` (§0.4) — the **same pure
   derivation** `scoped_repo_opts/1` itself uses at `lib/letflow/api/context.ex:222`,
   and the same one `AuthPipeline` uses at `lib/letflow/plugs/auth_pipeline.ex:305`.
   The derivation step is unchanged; only the source of `tenant_id` differs.
4. Every subsequent read is `Repo.*(..., prefix: schema_name)` with that prefix, exactly
   as an authenticated route's would be. INV-1's *storage-level* mechanism —
   schema-per-tenant via Ecto `:prefix`, per decision 0003 Dimension B — is fully
   intact and unchanged.

**What replaces `scoped_repo_opts/1` is therefore not a weaker scoping mechanism but a
different `tenant_id` source feeding the identical derivation.** The substitution is:

| | Authenticated route | This pattern |
|---|---|---|
| `tenant_id` source | `conn.assigns.auth_context.tenant_id`, set by `AuthPipeline` from a verified token | the `tenant_id` column of the handle row, read from the global registry |
| Is it caller-supplied? | No — derived from a signature-verified JWT or a hashed API token | No — the caller supplies a handle, never a tenant id; the *binding* handle→tenant is server-written at handle-issue time |
| Prefix derivation | `TenantProvisioning.schema_name_for_tenant/1` | **identical call** |
| Query scoping | `Repo.*(q, prefix: schema)` | **identical** |

The critical property both columns share: **the caller never names a tenant.** There is
no path segment, query parameter or header in this design from which a tenant identity
is taken. A caller who wants data from tenant *X* cannot ask for it; they can only
present a handle, and the handle decides. This is the same structural property
`lib/letflow/api/context.ex:194-198` claims for `scoped_repo_opts/1` ("never a request
path, query string, or header value... so there is no code path where a
request-supplied tenant hint could win a precedence fight (INV-1)"), preserved by a
different route.

**Explicitly forbidden by this design, and a later reader must not add them:**

- a `?tenant=` / `?realm=` / `X-Tenant-Slug` parameter on any `/api/public` route;
- a `<tenant>` path segment (`/api/public/:tenant/:kind/:id`);
- deriving the tenant from `Host` (Letflow has no host→tenant binding of any kind —
  `lib/letflow/routers/tenant_config.ex:93-96` records that and records why adding one
  without an owning requirement is forbidden; that finding still holds);
- accepting a raw resource id in place of a handle "for convenience."

Each of these reintroduces a caller-supplied tenant hint and each is an INV-1 violation
on its own.

### 3.3 Why this cannot be used to enumerate or probe tenants

The concrete property, named rather than asserted:

**The handle is an opaque, uniformly-random, unguessable identifier drawn from a
CSPRNG, and it is the *only* input to resolution.**

- **Construction:** `:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)`
  — 256 bits of CSPRNG entropy, rendered as 43 URL-safe characters. This is the same
  construction `Letflow.Identity`'s API tokens already use
  (`lib/letflow/identity.ex:1055`, 32 `strong_rand_bytes` rendered hex), differing only
  in the encoding alphabet, chosen here because a handle appears in a URL path.
- **Entropy, stated:** 2^256 handle space. An attacker making 10^9 guesses per second
  for 10^9 years covers ~3·10^25 ≈ 2^85 of it — a fraction of about 2^-171 of the
  space. Guessing is not a threat model, it is arithmetic.
- **Not derived from anything:** the handle is **not** a hash, HMAC, encoding or
  encryption of the resource id, the tenant id, a timestamp, or a counter. It is drawn
  fresh from the CSPRNG and *stored*, so it carries zero recoverable structure. A
  caller holding one handle learns nothing about any other handle, and holding two
  handles from the same tenant reveals no relation between them.
- **Nothing enumerable is exposed:** the resolution input space is the handle space,
  not the tenant space. There is no input to any `/api/public` route that names a
  tenant, a slug, a realm, or a resource id, so there is nothing tenant-shaped to
  enumerate. A wordlist of tenant slugs — the attack
  `lib/letflow/routers/tenant_config.ex:49-51` names as the reason that endpoint never
  404s — has no field to be typed into here.
- **No listing surface:** the pattern specifies exactly one route shape,
  `GET .../:handle`. There is deliberately **no** collection route, no `GET /api/public/<kind>`
  index, no search and no pagination anywhere under `/api/public`. Adding one would be a
  security change of the same class §4.5's rule covers. A future instance that believes
  it needs a public listing needs a new design and SECURITY-REVIEWER sign-off, not an
  extra route in this router.

Contrast, deliberately: `Letflow.Routers.TenantConfig` accepts `?realm=<slug>`, an
enumerable, human-chosen namespace, and is only safe because it *never varies its
status or body shape* by whether the slug resolved
(`lib/letflow/routers/tenant_config.ex:44-51`). This design takes the other route to the
same place: it makes the input space unenumerable **and** keeps the response invariant
(§4). Both defences, not one, because they fail differently — the never-vary rule
protects against a guessed input, the unguessable input protects against a future
change that accidentally introduces a distinguishable response.

### 3.4 Handles are revocable and may expire — and revocation must not become an oracle

The handle row carries `revoked_at` and `expires_at`. A handle that is revoked, expired,
or whose underlying resource has been deleted must produce **the response of a handle
that never existed** — same status, same body, same round-trip count (§4.3). "This link
used to work" is exactly as much of a signal as "this link exists"; both are refused.

### 3.5 The handle-registry table (design; the owning requirement writes the migration)

Global table `public_read_handles`, in `public`:

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | |
| `handle_hash` | `bytea` NOT NULL | **SHA-256 of the handle**, not the handle. Unique index. See below. |
| `tenant_id` | `uuid` NOT NULL | FK → `tenants(id)`. **The load-bearing column** — the sole source of the `:prefix` this pattern derives. |
| `kind` | `text` NOT NULL | Which registered projection module resolves this handle (§4.4). Constrains a handle to one resource type; a handle for kind *A* presented at kind *B*'s path does not resolve. |
| `resource_id` | `uuid` NOT NULL | The tenant-scoped row this handle points at. Read **only** inside the derived prefix. |
| `expires_at` | `utc_datetime_usec` NULL | NULL = no expiry. |
| `revoked_at` | `utc_datetime_usec` NULL | |
| `inserted_at` / `updated_at` | timestamps | |

**Why the hash and not the handle:** a handle is a bearer credential — anyone holding it
can read the projection. Storing it in plaintext means a database read, a backup, or a
log of a `SELECT` discloses live credentials. This mirrors the existing treatment of API
tokens (`lib/letflow/identity.ex` stores `token_hash`, never the plaintext, and
`insert_token/3` derives the stored value via `hash_token_value/1`). SHA-256 with no salt
and no stretching is correct **here specifically** because the input is 256 bits of
uniform CSPRNG output: there is no dictionary to attack and no work factor that would
add anything, and the lookup must be a single indexed equality read (§4.3's round-trip
argument depends on that).

**Who writes rows:** an authenticated, authorized `/api/v1` route belonging to whichever
later requirement needs the first public instance. **This design deliberately does not
specify that write path** — it is out of scope (§10 open question OQ-1), and the
`REQ-056` failure mode `lib/letflow/routers/tenant_config.ex:99-106` names (a backing
table shipped with no producer) means the migration for this table must land **with**
its first writer, not ahead of it. **A later reader must not create
`public_read_handles` on the strength of this design alone.**

---

## 4. The disclosure boundary, part 2: INV-5 and what is safe to return

### 4.1 INV-5 by name

`docs/agents/instructions/security-invariants.md:156-159`:

> **Rule.** A cross-tenant probe against a resource that exists (but belongs to another
> tenant) returns a response indistinguishable from probing a resource that never
> existed — same status code, same body shape, no timing signal that lets a prober
> distinguish "exists, not yours" from "never existed."

and its verification note (`:166-171`):

> ...confirms... that the not-found and forbidden-cross-tenant code paths return
> byte-identical responses and take a comparable number of DB round-trips (a
> cross-tenant existence check that short-circuits earlier than an equivalent not-found
> check is itself a timing signal).

An unauthenticated route is the easiest place in the system to build an existence oracle
by accident, because *every* caller is, formally, "not entitled" — so every distinction
this route can draw is a distinction drawn for an anonymous attacker.

### 4.2 The mechanism: one refusal, reached by every non-success path

**Every input that does not resolve to a live, unexpired, unrevoked handle whose
resource still exists produces the identical response:**

- status **404**;
- `Content-Type: application/problem+json`;
- body: `Letflow.Api.Response.not_found/1`'s document (`lib/letflow/api/response.ex:146-147`),
  which is the same document `Letflow.Router`'s own catch-all already emits
  (`lib/letflow/router.ex:118-120`) — i.e. a `/api/public/...` miss is byte-identical to
  a request for a path Letflow does not serve at all, up to the `trace_id` field, which
  is `""` on every response from this router (§0.6, §8);
- no header that varies by case: no `WWW-Authenticate`, no `Retry-After`, no custom
  header, no distinct `Cache-Control` per branch.

The enumerated cases that must **all** land here, with no case producing 401, 403, 410,
400, 422 or 500:

1. handle syntactically malformed (wrong length, non-base64url characters);
2. handle well-formed but not present in the registry;
3. handle present but `revoked_at` is set;
4. handle present but `expires_at` has passed;
5. handle present, live, but its `kind` does not match the path's `<kind>` segment;
6. handle present and live, but the tenant-scoped resource row is gone;
7. handle present and live, but the resource is in a state the projection declines to
   publish (a per-kind publishability predicate);
8. `<kind>` is not a registered kind at all;
9. wrong HTTP method on a valid path;
10. any other path under `/api/public`.

**403 must never appear on this route class**, for any reason. A 403 is by definition
the statement "this exists and you may not have it" — the exact distinction INV-5
forbids. Similarly **401 must never appear**: a route that has no credential concept
cannot meaningfully demand one, and a 401 on some handles and 404 on others would be a
perfect oracle.

### 4.3 The round-trip / timing half, addressed explicitly

This is where the design must be structural rather than careful, because "remember to
keep the paths symmetric" is not a mechanism.

**Rule: resolution performs exactly ONE database round-trip before any refusal
decision, and exactly TWO on the success path, and the count never varies within
either.**

- **Round-trip 1 — the registry read.** `Repo.get_by(PublicReadHandle, handle_hash: h)`
  against the global table. This runs for cases 1–7 identically. Case 1 (malformed
  handle) **must not short-circuit before it**: a syntactic pre-check that rejects a
  malformed handle without querying would make malformed inputs measurably faster than
  well-formed-but-unknown ones, which is precisely INV-5's named
  "short-circuits earlier than an equivalent not-found check" signal. The handler
  therefore hashes whatever it was given — SHA-256 accepts any binary — and queries with
  the result. Cases 2, 3, 4, 5 (miss, revoked, expired, kind mismatch) are then decided
  **in memory from the row already fetched**, with no second query, and the row's
  liveness fields are checked *after* the query in every case, never used to skip it.
- **Round-trip 2 — the resource read.** Reached **only** when round-trip 1 produced a
  live, kind-matching row: `Repo.get(Schema, resource_id, prefix: derived_prefix)`.
  Cases 6 and 7 (resource gone, resource unpublishable) are decided from *this* query's
  result, so they cost two round-trips — the same two the success path costs.
- Cases 8, 9, 10 are decided by `Plug.Router`'s own `match`, before any query
  (**zero** round-trips).

The resulting profile:

| Outcome | Round-trips | Response |
|---|---|---|
| unrecognised kind / method / path (8, 9, 10) | 0 | 404 problem+json |
| handle malformed, unknown, revoked, expired, kind-mismatched (1–5) | 1 | 404 problem+json, **identical** |
| resource gone or unpublishable (6, 7) | 2 | 404 problem+json, **identical** |
| success | 2 | 200 projection |

**The honest statement of what this achieves, and what it does not:** the response is
identical in status, headers and body across every refusal. The *round-trip count* is
identical **within each equivalence class an attacker can actually choose between**, and
this is the property that matters:

- An attacker choosing among **handle values** (the only unenumerable-but-attackable
  input) is always in the 1-or-2-round-trip band. The 1-vs-2 boundary is crossed only by
  possessing a handle that *did* resolve to a live registry row — which, per §3.3,
  requires 2^256 luck or already having been given the handle. So the timing difference
  between "unknown handle" and "known handle, dead resource" is not reachable by
  probing; it is only observable by someone who was given a valid handle, and telling
  *that* person "your link is dead" is not a disclosure — it is what they are entitled
  to infer (§6).
- The 0-round-trip band is reachable freely, but it discloses only which `<kind>`
  strings are registered — a property of the *deployment's feature set*, not of any
  tenant's data. See §6, where this is recorded as accepted bounded inference rather
  than hidden.

**Structurally forbidden, and a later reader must not add them:**

- any "does this exist in some other tenant / under some other kind" second lookup,
  added for a better error message. This is the exact addition
  `lib/letflow/api/context.ex:78-88` already forbids for the authenticated case, for the
  same three reasons it lists; it is forbidden here for a fourth reason too — the
  asymmetric query it adds *only* on the miss path is the timing signal itself;
- any early-return that skips round-trip 1 on the basis of the handle's syntax, length,
  or character set;
- any per-case logging that writes at a different level or volume per branch (a log
  line is a side channel when it costs I/O, and it becomes a disclosure directly if
  logs are ever exposed). One log line, one level, same fields, for every refusal —
  and the handle itself is a credential and must **never** be logged in plaintext (INV-4).

### 4.4 What is safe to return: the projection

**Rule: the response body is a hand-built map with named literal keys, built by a
per-kind projection function. It is never derived from an Ecto schema struct, never
`Map.from_struct/1`'d, never `Jason.encode`d from a struct, never built by dropping
fields from a full record, and never built by iterating a map of stored attributes.**

This is the same construction discipline `Letflow.Routers.TenantConfig` applies at
`lib/letflow/routers/tenant_config.ex:253-259` (`config_map/2`, "EXACTLY three keys,
hand-built, never derived from `%Tenant{}` as a whole") and `271-288`
(`branding_from_settings/1`, three named `Map.get/3` reads, never a merge). The reason
it is copied verbatim is stated in the precedent at `:266-270`: an explicit-key read
means an out-of-allowlist field *could not surface even if a write-time enforcement
elsewhere were bypassed*. Allowlist-by-construction, not allowlist-by-filter.

The projection *contract* — every `<kind>` implements this shape, and the router knows
only this shape:

- **input:** the tenant-scoped resource struct, already fetched inside the correct
  prefix, plus the handle row's own metadata;
- **output:** `{:ok, map()}` — a map with string keys, or `:skip`, meaning "this
  resource is not publishable in its current state," which the router turns into the
  standard 404 (case 7).

The **pattern-level** response envelope is exactly three top-level keys, and no
projection may add a fourth:

| Key | Type | Content |
|---|---|---|
| `"kind"` | `String.t()` | the registered kind string, echoing the path segment |
| `"issued_at"` | `String.t()` | ISO-8601 UTC — when the handle was issued (`inserted_at`), **not** when the resource was created or last modified |
| `"data"` | `map()` | the kind's own hand-built projection, its keys enumerated and justified in that kind's own design |

**What the envelope must never carry, enumerated:** no `tenant_id`, tenant slug, tenant
display name or tenant status; no `resource_id` or any other internal primary key; no
`user_id`, actor id, author identity, email address or any personal identifier; no
`inserted_at`/`updated_at` of the *resource*; no counts, totals or aggregates that could
be differenced across handles; no free-text field that a tenant user authored for
internal consumption; no field whose value the platform cannot see the tenant having
deliberately chosen to publish.

**Why `issued_at` and not the resource's own timestamps:** a resource's `updated_at`
tells any holder of the handle when the tenant last touched the row, which is internal
operational information that publication does not imply consent to. The handle's own
issue time is information the holder already has (they were given the link then).

**The governing rule, stated in the same spirit as the precedent's:**

> **Adding a fourth top-level key to the public envelope, or a field to any kind's
> `data` projection, is a security change, not a feature.** It requires SECURITY-REVIEWER
> sign-off against INV-2 and INV-5 in the requirement that adds it, and a stated reason
> why an unauthenticated, unauthenticated-forever, world-readable-if-the-link-leaks
> audience is entitled to that field.

The audience clause matters and is part of the rule: a handle is a bearer credential
with no revocation of *copies*. The right question for any proposed field is never "is
this sensitive?" but "would the tenant accept this being world-readable the moment
someone forwards the link?"

### 4.5 Registration, so the router stays generic

Kinds register a `{kind_string, projection_module}` pair — a compile-time list read from
application config, in the same style `Letflow.Oidc.ClaimMappingConfig`/`JitProvisioningConfig`
are consulted per-realm (`lib/letflow/plugs/auth_pipeline.ex:288, :301`). An unregistered
`<kind>` falls to the catch-all 404 with zero round-trips (case 8). The router contains
no kind-specific branch, and adding a kind touches config plus one new projection module,
never `Letflow.Routers.PublicRead` itself.

---

## 5. Rate limiting and abuse posture

**Rate limiting IS specified by this design, concretely, and it is a precondition of the
first instance rather than a follow-on.** An unauthenticated route is reachable by
anyone; leaving it unbounded is not an option, and §0.7 establishes there is nothing
already in the tree to inherit.

| Dimension | Decision |
|---|---|
| **What is limited** | Every request reaching the `/api/public` forward, counted before dispatch and before any database work. |
| **Keyed by** | The client IP, as resolved from the connection peer (`conn.remote_ip`), **not** from an `X-Forwarded-For` header unless a trusted-proxy configuration explicitly authorises it — an attacker-settable header as a limiter key is a bypass, not a key. Deliberately **not** keyed by handle: keying by handle would give each guessed handle its own bucket, which is the opposite of what a brute-force limiter is for. |
| **Second key** | A separate, much tighter global bucket for `/api/public` as a whole, so a distributed source cannot bypass the per-IP bucket by spreading across addresses. |
| **Where it sits** | As the first plug **inside** `Letflow.Routers.PublicRead`'s own chain, ahead of `plug(:match)` — i.e. after the forward, so it covers this route class and only this route class. Explicitly **not** on `Letflow.Router`, which would put it in front of `GET /health` (whose contract `deploy/redeploy-test.sh` pins, `lib/letflow/router.ex:17-19`) and `GET /metrics` (whose scrape must not be throttled). |
| **Algorithm** | Token bucket over ETS, one process-local table, same hand-rolled-over-a-dependency posture `Letflow.Metrics.Registry` already established for this codebase. Single-node semantics, and that limitation is disclosed rather than hidden: with multiple nodes each enforces its own bucket, so the effective global limit multiplies by node count. Acceptable for a first instance; a distributed limiter is a separate requirement if and when Letflow runs multi-node. |
| **Response when limited** | `429` via `Letflow.Api.Response.rate_limited/2` (`lib/letflow/api/response.ex:173`), which already exists. **This is the one permitted departure from §4.2's single-response rule**, and it is safe precisely because it is *input-independent*: a limited caller gets 429 for **every** request, valid handle or not, so the 429/404 boundary carries no information about any handle. It must be enforced before resolution so that this stays true. |
| **Owner** | The requirement that mounts the first `/api/public` instance. This design makes the limiter a **hard prerequisite of that mount**: the route class must not be mounted with the limiter deferred. Stated here so a later reader cannot read "deferred plug, S4, to port" (`lib/letflow/plugs/api_pipeline.ex:59`) as licence to ship without one. |

**Relationship to `Letflow.Plugs.RateLimit`:** the deferred-plug row at
`lib/letflow/plugs/api_pipeline.ex:59` reserves that module name for the general
`/api/v1` limiter. The limiter specified here is a distinct, narrower thing (different
key, different mount, different response class), and this design does **not** claim to
discharge that deferred row. If the general limiter lands first and is
mount-point-agnostic, reusing it here is preferable to a second implementation — that is
a judgement for the implementing requirement, not a decision to pre-empt now (OQ-2).

**Other abuse considerations, decided:**

- **Caching.** Responses must set `Cache-Control: private, no-store`. A handle in a URL
  will end up in shared caches, proxy logs and browser history otherwise. `no-store` also
  keeps a revoked handle from being served from a cache after revocation.
- **Referrer leakage.** Responses set `Referrer-Policy: no-referrer`. A handle sitting in
  a URL path leaks to every third-party origin a rendering page links to, otherwise.
- **Robots.** `X-Robots-Tag: noindex, nofollow`. A public read that gets crawled and
  indexed has been disclosed to everyone, not to the link's recipient.
- **Body size / parsing.** These are `GET`s with no body and there is no `Plug.Parsers`
  on this mount (§8), so there is no body-parsing DoS surface to bound.

---

## 6. Bounded inference this shape openly accepts

The precedent does this rather than claiming none
(`lib/letflow/routers/tenant_config.ex:53-56`, `:74-77`), and this design does the same.
Three inferences are accepted, each with the reason it is tolerable:

1. **A holder of a valid handle learns that the handle is valid, and that the resource
   behind it exists and is publishable.** Unavoidable — it is the endpoint's entire
   purpose, in the same sense the precedent's realm id is. The holder was given the
   link deliberately.
2. **A holder of a previously-valid handle can distinguish "still live" from "no longer
   live"** — they get a projection or they get 404, and they know which they used to
   get. Accepted: revocation that the revoked party cannot detect is not achievable
   while also serving them anything, and the party in question already had the data.
   Note this is *not* reachable by a prober (§4.3), only by someone who held a live
   handle.
3. **Anyone can learn which `<kind>` strings are registered on a deployment**, by
   observing that an unregistered kind costs zero round-trips while a registered one
   costs one. This is a property of the deployment's installed feature set — the same
   class of information as which top-level routes exist, which
   `lib/letflow/router.ex`'s route table already treats as non-secret — and it names no
   tenant and no resource. Accepted, and recorded here rather than papered over with a
   claim of perfect uniformity. Closing it would require the registered and unregistered
   kinds to perform an identical dummy query, which buys nothing against an attacker who
   cannot enumerate handles anyway.

**Not accepted, and closed:** anything that lets an unauthenticated caller learn a
tenant exists, that a tenant has published anything, how many things a tenant has
published, or whether any particular resource id or slug is real.

---

## 7. Interaction with `AuthPipeline` and `TenantStatus`

### 7.1 Itemised: what must not run, and what must

**Must NOT run:**

| | Why |
|---|---|
| `Letflow.Plugs.AuthPipeline` | It 401s and halts any credential-free request (§0.2). Running it makes the route unreachable by its only caller. Structurally guaranteed by mounting outside `ApiPipeline`, not by an option. |
| `Letflow.Plugs.Authorize` / any permission-atom check | There is no principal to authorize. **No permission atom is defined for this route class**; the handle is the authorization decision, made once at issue time by an authenticated actor on an authenticated route. |
| `Letflow.Plugs.Admission` (`pool: :tenant`) | It reads `conn.assigns.auth_context.tenant_id` (`lib/letflow/plugs/admission.ex:15-16`), which is absent. §5's limiter is this route class's load defence instead. |
| `Plug.Parsers` | `GET` with no body; nothing to parse, and no parser is a smaller DoS surface than a parser (§8). |

**Must STILL run:**

| | Why |
|---|---|
| `Letflow.Plugs.Cors` | Already mounted on `Letflow.Router` (`lib/letflow/router.ex:89`), so it covers this forward automatically — the same way it already covers `/api/tenant-config` (`:37-48`). A public read is very likely to be fetched cross-origin. |
| `Letflow.Plugs.HttpMetrics` | Also already on `Letflow.Router` (`:90`), and it never changes status/body/headers (`:66-69`). An unauthenticated route is the one whose traffic shape most needs to be observable. |
| Ecto `:prefix` scoping on every tenant-scoped read | §3.2. INV-1 is not relaxed. |
| §5's rate limiter | The one plug this route class adds to its own chain, and a hard prerequisite of mounting. |

### 7.2 `TenantStatus` specifically: skipping it is NOT acceptable; a replacement is specified

Read in full (`lib/letflow/plugs/tenant_status.ex`, 133 lines). Two facts decide this:

1. With no auth context it is a **no-op** — `call/2` reads
   `get_in(conn.assigns, [:auth_context, :tenant_id])`, gets `nil`, and
   `check_tenant_status(conn, nil), do: conn` returns the conn untouched
   (`:71-81`). So mounting it on this route would not merely be useless; it would be
   *actively misleading*, appearing to gate something it structurally cannot.
2. Its deactivation check is unconditional across methods and is described as authorized
   in exactly that shape by REVIEWER (`:11-19`): *"A request against a tenant whose
   `status` is `:inactive`... is rejected with 403... Runs for every HTTP method,
   including GET/HEAD."* A deactivated tenant's data is not to be served on a `GET`.

**Therefore: leaving the tenant-status question unanswered on this route is not
acceptable, and this design replaces the plug with an inline check on the same fact.**

**Replacement — the status gate folds into round-trip 1.** The registry read (§4.3)
already touches the `public` schema and already yields `tenant_id`. The design specifies
that this read is a **join** from `public_read_handles` to `tenants`, returning the
handle row together with the tenant's `status` in **one** query. The handler then treats
a `status` of `:inactive` exactly as it treats a revoked handle — case 3 of §4.2 — i.e.
a **404**, not the 403 `TenantStatus` returns.

Three points, each deliberate:

- **404, not 403.** `TenantStatus`'s 403 with body `{"error": "tenant_inactive"}`
  (`:107-118`) is correct for an authenticated caller who already knows which tenant
  they belong to; it discloses nothing they don't have. Returning it here would tell an
  anonymous caller "this handle is real and its tenant is deactivated" — two disclosures
  at once, and a direct INV-5 violation. The information is collapsed into the standard
  404.
- **No extra round-trip.** The join keeps the count at one, so the deactivated-tenant
  case is timing-indistinguishable from the unknown-handle case, per §4.3's rule. An
  implementation that instead added a second `Repo.get(Tenant, tenant_id)` after the
  handle lookup would violate that rule and must not be written.
- **The write-pause check does not apply.** `TenantStatus`'s second check fires only for
  `POST/PUT/PATCH/DELETE` (`@write_methods`, `:63`, applied at `:98`). This route class
  is `GET`-only, so a `:migrating` tenant is unaffected — and correctly so: a migration
  window is a write-integrity concern, not a read-visibility one. A `:migrating` tenant's
  public reads continue to be served. Stated explicitly so a later reader does not
  "restore parity" by blocking them.
- **Fail-closed on error is inherited.** `TenantStatus` deliberately lets a lookup
  failure crash rather than fail open (`:38-48`). This route class inherits that posture
  in a form appropriate to it: a database error during round-trip 1 must **not** be
  rescued into a 200 or into a "default" projection. It produces the same 404 as every
  other refusal (never-error is the precedent's rule, and §9 explains why this design
  does *not* copy it wholesale) — or, if unrescued, crashes the request process under
  Bandit's existing isolation. What it must never do is serve content.

---

## 8. Consequences of mounting outside `ApiPipeline`: accepted or addressed

`Letflow.Routers.TenantConfig`'s moduledoc documents three
(`lib/letflow/routers/tenant_config.ex:127-139`). Each, decided:

| Consequence | This design |
|---|---|
| **No `Plug.Parsers`** | **Accepted, and preferred.** The pattern is `GET`-only with no request body and takes its sole input from a path segment, so there is nothing to parse. Not having a parser on a world-reachable mount is a smaller attack surface, not a gap. If a future instance believes it needs a request body, it needs a new design — a public route that accepts a body is a materially different security object. The precedent calls `fetch_query_params/1` itself (`:139`, `:200`); this design does not even need that, since it takes no query parameters (§3.2's forbidden list). |
| **No trace id / no `x-trace-id` response header** | **Accepted, with the consequence checked rather than assumed.** `Letflow.Api.Context.assign_trace_id/1` is not mounted on `Letflow.Router` and must not be (`lib/letflow/router.ex:31-35`: it would change `GET /health`'s pinned response headers). Mounting it *inside* `Letflow.Routers.PublicRead`'s own chain was considered and **rejected** on disclosure grounds: `assign_trace_id/1` propagates a caller-supplied `x-trace-id` header back verbatim (truncated to 256 bytes, `lib/letflow/api/context.ex:123-131`, explicitly with "no UUID-shape validation... on incoming values"). Reflecting an attacker-chosen string on a world-reachable, cacheable endpoint is a reflection surface this route class has no need for. Correlation for this route class is served instead by §5's limiter metrics and by `Letflow.Plugs.HttpMetrics`, both already mounted. |
| **No problem-document shaping** | **Addressed, not accepted — and the precedent's own statement is superseded here by a verified fact.** `Letflow.Api.Response.send_problem/2` works fine outside the pipeline: `effective_trace_id/2` falls back to `conn.assigns[:trace_id] \|\| ""` (`lib/letflow/api/response.ex:196`), so a problem document is emitted correctly with an empty `trace_id`. The precedent could state "no problem-document shaping" only because it never emits one (`:137`, "this endpoint emits no problem document, ever"). This design **does** emit one, on every refusal, deliberately: reusing `Response.not_found/1` is what makes an `/api/public` miss byte-identical to `Letflow.Router`'s own catch-all (`lib/letflow/router.ex:118-120`), which is §4.2's mechanism. A hand-rolled 404 body unique to this router would itself be a fingerprint distinguishing "a path under the public router" from "a path Letflow does not serve." |

One consequence the precedent does not list, added here: **no `Letflow.Plugs.Admission`
global gate.** `ApiPipeline` mounts it first in its chain
(`lib/letflow/plugs/api_pipeline.ex:88`); a mount outside the pipeline gets no
concurrency admission control. §5's rate limiter is the substitute, and it sits earlier
in the request (before `:match`) than `Admission` does relative to its own dispatch, so
the protection is comparable in placement even though the algorithm differs.

---

## 9. Generic or one-off

**Position, in one sentence: this is a generic, reusable mount-plus-plug shape — one
`/api/public` forward, one `Letflow.Routers.PublicRead` router, one handle registry, one
rate limiter, and a per-kind projection module — and every future unauthenticated read
adopts it rather than designing a fourth bespoke public mount.**

The reasoning, which has to account for the fact that the three existing public mounts
share no abstraction:

- **The three existing mounts are not evidence against reuse; they are three different
  problems.** `/api/tenant-config` and `/api/mobile/tenant-config` read the **global**
  `tenants` table and touch no tenant schema at all — `TenantConfig`'s own moduledoc says
  so at `lib/letflow/routers/tenant_config.ex:141-147` ("reads only the **global**
  `tenants` table... there is no prefix to derive and no per-tenant row to reach").
  `/metrics` reads **no database at all**, only process-wide ETS
  (`lib/letflow/routers/metrics_exposition.ex`, the DB-unavailable section). None of the
  three has the problem this design exists to solve — reaching **inside a tenant schema**
  without a token. They share no abstraction because they share no problem. This design's
  instances will all share exactly one problem.
- **The hard part is the boundary, not the route.** What a new instance needs is not a
  `forward/2` line — that is two minutes of work — but the handle registry, the
  unguessable-identifier construction, the single-refusal rule, the round-trip
  discipline, the limiter, the projection contract and the cache/referrer headers. Every
  one of those is instance-independent, and every one of them is a thing a hand-rolled
  fourth mount would get subtly wrong. §4.3's round-trip symmetry in particular is not a
  rule a designer reliably re-derives; it is a rule to inherit.
- **Bespoke public mounts scale badly in exactly the dimension that hurts.** Three
  bespoke unauthenticated surfaces are auditable. Eight are not, and the audit question
  ("can any of these be used as an existence oracle?") has to be re-answered from scratch
  per mount. One mount with one refusal path is answered once.
- **The counter-argument, and why it loses.** A reasonable objection is that no instance
  exists yet, so this generalises from zero examples — normally a strong argument for
  one-off. It loses here for a specific reason: the thing being generalised is a
  *security boundary*, and the cost asymmetry is severe. Building the shape reusable and
  finding only one user costs a config-driven dispatch that was going to be a `case`
  anyway. Building it one-off and finding a second user means a second bespoke boundary
  designed by whoever happens to draw that requirement — which is the failure mode this
  requirement was filed to prevent.

**The generic parts** (fixed by this design; an instance does not redesign them): the
mount point, the router module, the handle registry and its hashing, the resolution
sequence, the single-refusal rule and its round-trip discipline, the rate limiter, the
three-key envelope, the cache/referrer/robots headers.

**The per-instance parts** (each new kind's own design decides them): the kind string,
which tenant-scoped schema is read, the `data` projection's exact keys and their INV-2
justification, the publishability predicate, expiry policy, and who is authorized to
issue a handle on the authenticated side.

---

## 10. Does this warrant a `docs/migration/decisions/` record?

**Yes — and this requirement files one:
`docs/migration/decisions/0028-unauthenticated-read-boundary.md`.**

REQ-308's §10 is the precedent for making this judgement rather than filing by reflex,
and it declined a record with this test: an ordinary route-table or
authorization-matrix choice, of the kind already made and recorded inside router
moduledocs, is *not* decision-record material; a "genuinely cross-cutting architectural
question... load-bearing for every future requirement" is (contrasting itself with
decision 0024). Applying that same test here gives the opposite answer, on three counts:

1. **It is a deliberate hole in a platform-wide invariant's enforcement mechanism.**
   Every other data path in Letflow reaches tenant data through
   `conn.assigns.auth_context` → `scoped_repo_opts/1`. This design establishes a second,
   parallel source of `tenant_id`. That is not a route-table choice; it is a change to
   the set of ways INV-1 can be satisfied, and a future reader who finds
   `public_read_handles` needs to find the reasoning without having to know which design
   doc to open.
2. **It is a standing prohibition, not a local one.** §3.2's forbidden list (no
   `?tenant=`, no tenant path segment, no host-based resolution, no raw resource id) and
   §4.2's "no 403, ever, on this route class" bind *future* requirements that this design
   doc has no authority over. Decision records are where Letflow puts rules that bind
   work that has not been written yet — `CLAUDE.md` says decision records are
   "load-bearing for every later stage" and must not be silently re-decided.
3. **It answers a question that will be asked again in the form "why not just...".** The
   mount-point question and the generic-vs-one-off question are each individually
   design-doc-sized — REQ-308's test would decline a record for either alone. Their
   combination with the disclosure boundary is not: "why does Letflow have a public
   route class at all, and why does it look like this" is exactly the question decision
   records exist to answer once.

The record is short and states the decision and its standing prohibitions; this design
doc remains the place for the full mechanism, the way `0024` is short and REQ-295's
design carries the detail.

---

## 11. Open questions — stated, not silently resolved

- **OQ-1 — the issue path.** Who may issue a handle, on which authenticated route, under
  which permission atom, and whether issuing is idempotent per resource, is **not**
  designed here. It is authenticated-side work and belongs to the requirement that needs
  the first instance. The `public_read_handles` migration must land with that writer, not
  ahead of it (§3.5, and the `REQ-056` failure mode at
  `lib/letflow/routers/tenant_config.ex:99-106`).
- **OQ-2 — limiter reuse.** Whether §5's limiter is a new module or a reuse of a
  by-then-landed `Letflow.Plugs.RateLimit` (`lib/letflow/plugs/api_pipeline.ex:59`)
  depends on whether that module arrives mount-point-agnostic. Decided by the
  implementing requirement; either satisfies §5 as long as key, mount position and
  429-before-resolution ordering hold.
- **OQ-3 — handle rotation.** Whether a handle can be rotated in place (new handle, same
  resource, old one revoked) or whether rotation is issue-plus-revoke is not decided.
  No pattern-level property depends on it.
- **OQ-4 — multi-node limiting.** §5's ETS limiter is per-node and the effective global
  limit multiplies by node count. Disclosed, not solved. If Letflow runs multi-node
  before the first public instance ships, this needs revisiting.
- **OQ-5 — `Referrer-Policy` reach.** `Referrer-Policy` on the API response governs
  requests the *API response* originates, which for a JSON body is none. If a future
  instance serves an HTML page from a handle rather than JSON, the header becomes
  load-bearing in a way this design has not analysed. Flagged; the pattern as designed is
  JSON-only.

---

## 12. For SECURITY-REVIEWER

This design is a tenant-data-path change: it establishes a route class that reads inside
a tenant schema with no authenticated principal. REQ-323's acceptance criteria name
**INV-1, INV-5 and INV-8** as requiring by-name treatment with a concrete mechanism.

- **INV-1** — §3. `scoped_repo_opts/1` is unavailable (§0.3, quoted). Replaced by:
  handle → global registry row → `tenant_id` column → the identical
  `TenantProvisioning.schema_name_for_tenant/1` derivation → `Repo.*(prefix:)`. No
  request input names a tenant; §3.2 enumerates the four forbidden reintroductions.
- **INV-5** — §4.2 (one refusal shape, ten enumerated cases, no 401 and no 403 ever) and
  §4.3 (one round-trip before any refusal decision; malformed input must not
  short-circuit ahead of the query; no second lookup for a better message). §6 states the
  three bounded inferences accepted rather than claiming zero.
- **INV-8** — the design's typed-result posture: resolution is a `with` chain over
  `{:ok, _} | {:error, _}`; the handler must contain no bare `{:ok, x} = ...` match on
  any externally-reachable value, and the only inputs are a path segment (any binary,
  hashed without validation, so no parse can raise) and the registry row. `Ecto.UUID.cast/1`
  inside `schema_name_for_tenant/1` returns `:error` rather than raising
  (`lib/letflow/tenant_provisioning.ex:215-218`). No realistic input to this route class
  reaches a raising call — and because the route is reachable by anyone with no
  credential, that is a hard requirement, not a preference.
- **INV-2** (also engaged) — §4.4: hand-built projection with literal named keys,
  never derived from a struct; enumerated never-return list; the "fourth key is a
  security change" rule.
- **INV-4** (also engaged) — §4.3: the handle is a bearer credential and is never
  logged in plaintext; §3.5: only its SHA-256 is stored.

### SECURITY-REVIEWER verdict — 2026-09-12 — **PASS**

Reviewed against `docs/agents/instructions/security-invariants.md` INV-1..INV-9. Every
source claim this design makes was re-derived from the tree rather than trusted; **no
inaccurate claim was found in either new file.**

**INV-1 (tenant data isolation) — APPLIES, PASS.** Mechanism: `:handle` → SHA-256 →
`Repo.get_by(PublicReadHandle, handle_hash:)` on the global `public_read_handles` table →
that row's `tenant_id` column → `TenantProvisioning.schema_name_for_tenant/1` →
`Repo.*(..., prefix: schema_name)`. The design's central claim — only the SOURCE of
`tenant_id` differs, the storage mechanism is unchanged — is verified true against
`lib/letflow/api/context.ex:217-237` (`scoped_repo_opts/1` reads exactly
`conn.assigns[:auth_context][:tenant_id]` and is genuinely unavailable here) and
`lib/letflow/tenant_provisioning.ex:214-216` (the derivation is pure, total, and is the
identical call `AuthPipeline` and `Admission` already make). **No path exists where a
caller-influenced value reaches the prefix**: the caller supplies only a handle, and the
handle→tenant binding is a server-written row. §3.2's four forbidden reintroductions
(`?tenant=`, a tenant path segment, `X-Tenant-Slug`, `Host`-derivation) are correctly
enumerated and elevated to standing prohibitions in 0028.

The global `public_read_handles` table does NOT create a cross-tenant surface, and is
narrower than the precedent already signed off: `Letflow.ServiceCatalog` needs an explicit
`scope == :global or owner_tenant_id == ^tenant_id` read predicate
(`service_catalog.ex:274`) because a global table has no prefix to scope into;
`public_read_handles` needs none, because it is never listed, searched or paginated — only
exact-matched on a 256-bit key — and it holds a pointer, not tenant business data.

The bearer-capability posture is sound rather than an auth mechanism smuggled in without
AuthPipeline's protections: revocation (`revoked_at`), expiry (`expires_at`), leak posture
(`Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag:
noindex, nofollow` — verified NONE is set anywhere in the current response layer, so these
are genuinely new work), the plaintext-logging prohibition, and SHA-256-only storage
mirroring `identity.ex:1058` are each addressed. The residual risk — a leaked link is
readable by its holder and copies cannot be revoked — is stated openly as §4.4's governing
test, not hidden. Anti-enumeration rests on a named property, not an assurance:
`:crypto.strong_rand_bytes(32)`, 256 bits stated with the arithmetic shown,
drawn-and-stored rather than derived, and **no collection/index route exists** (locked at
record level in 0028, which is the check most likely to be quietly violated later).

**INV-5 (not-found/forbidden indistinguishability) — APPLIES, PASS, both halves.**
*Body/status:* `Error.serialise/1` does `Map.take([:type, :title, :status, :detail,
:trace_id])`, so `trace_id` is always one of the five keys — an empty trace id yields
`"trace_id":""`, not an absent key. A `/api/public` miss is therefore **byte-identical** to
`Letflow.Router`'s own catch-all (`router.ex:118-120`), both calling `Response.not_found/1`
with no `conn.assigns[:trace_id]`. `Error.not_found/0` takes no `detail` argument, so the
body cannot vary by case even by mistake. *Timing:* exactly one round-trip before any
refusal, two on success; the malformed-handle case is explicitly forbidden from
short-circuiting ahead of the query (SHA-256 accepts any binary, so the handler hashes
whatever it received) — this closes by construction the exact signal INV-5's own text
names; cases 2-5 are decided in memory from the already-fetched row. The 1-vs-2
round-trip boundary is crossed only by possessing a handle that resolved to a live row,
i.e. by someone already entitled to the data, and is disclosed rather than claimed away.
The 429-before-resolution ordering is load-bearing and correct: a limited caller gets 429
for *every* request, valid handle or not, so the boundary carries no information about any
handle. An inactive tenant returning 404 rather than `TenantStatus`'s 403
(`tenant_status.ex:107-118`) is the sharpest call in the design and is right — that 403
would disclose two facts at once to an anonymous caller.

**INV-8 (no unhandled crashes) — APPLIES, PASS.** Walked each realistic failure: a
malformed or oversized handle is hashed, never parsed, so nothing raises; a handle for a
deprovisioned tenant returns `:error` from `Ecto.UUID.cast/1` rather than raising
(`tenant_provisioning.ex:215-218`); a resolved row whose tenant schema no longer exists
raises a Postgres error and crashes the request under Bandit's per-request isolation,
which §7.2's fail-closed posture correctly requires must never be rescued into a 200 or a
default projection. The design deliberately does NOT copy the precedent's
always-200-with-defaults rule — serving a default projection for a public resource read
would be a fabrication.

**INV-2 — APPLIES, PASS.** Hand-built maps with literal named keys, three-key envelope,
enumerated never-return list. The `issued_at`-not-`updated_at` choice is a genuine catch: a
resource's `updated_at` tells a handle holder when the tenant last touched the row, which
publication does not imply consent to.

**INV-4 — APPLIES, PASS.** Handle stored as SHA-256 only, never logged in plaintext;
heuristic grep over both new files returns zero hits.

**INV-7 — NOT APPLICABLE** (the diff adds no executable Elixir; the design specifies the
parameterised Ecto query API). **INV-3, INV-9 — NOT APPLICABLE.** **INV-6 — discharged by
this review.**

Rejecting `assign_trace_id/1` is judged CORRECT. The premise is verified
(`context.ex:123-131` propagates a caller-supplied `x-trace-id` as-is with no shape
validation, documented as deliberate): reflecting an attacker-chosen string on a
world-reachable endpoint is a gratuitous surface, the correlation `assign_trace_id/1`
exists to provide is meaningless for an anonymous caller, and the correlation that does
matter is already served by `Letflow.Plugs.HttpMetrics`, confirmed mounted on
`Letflow.Router:90` and covering `/api/public`. Mounting it on `Letflow.Router` instead was
correctly ruled out — it would change `GET /health`'s headers, which
`deploy/redeploy-test.sh` pins.

Nothing in this design is unimplementable as specified, and no security decision is
improperly deferred. Rate limiting in particular is NOT deferred: §5 specifies it and makes
it a hard prerequisite of mounting.

**Conditions binding the implementing requirement** (each already stated in this design;
restated so its gate can check them mechanically): (1) round-trip 1 must be a single joined
query over `public_read_handles` → `tenants.status`; (2) no syntactic pre-check may
short-circuit ahead of it; (3) the limiter ships WITH the mount, enforced before
resolution, keyed on `conn.remote_ip`, never on `X-Forwarded-For` absent a trusted-proxy
config; (4) the migration lands with its first writer, not ahead of it; (5) every refusal
goes through `Response.not_found/1` — a hand-rolled 404 would itself fingerprint the
router; (6) the three cache/referrer/robots headers must be added; (7) no 401, no 403, no
collection route, ever. One further note for that gate: confirm Bandit's request-line limit
rejects a pathological path segment before the handler, so the hash is never computed over
an unbounded input — a DoS-bounding check, not an INV-8 defect.

— SECURITY-REVIEWER


---

## 13. Decision 0022 rule 1 — vocabulary check

This is a bucket-B requirement, so rule 1 binds this artefact textually: it may not name
the vertical that motivated it, in its prose, its identifiers or its examples.

Applied. **S10 gap 6** is cited by number in the header and nowhere is it said what the
gap is for. The pattern is described throughout as "a read-only resource",
"an externally-linkable resource", "the resource behind a handle" — never by domain. The
`<kind>` path segment and the projection-module registry (§4.5) exist precisely so that
this design names no concrete resource type: the first instance supplies its own kind
string in its own requirement, and this document is unchanged by it. Every identifier
proposed here — `/api/public`, `Letflow.Routers.PublicRead`, `public_read_handles`,
`Letflow.PublicRead.resolve/2`, `handle_hash`, `resource_id`, `kind` — is
domain-neutral, and each would read identically had a different vertical motivated it.

Verification:

```
$ grep -rnwiE "exam|exams|certificate|certificates|certification|candidate|candidates|quiz|grading|grader|proctor|bilimbaga|student|teacher|course|diploma|assessment" \
    lib/letflow/design/req323-unauthenticated-read-pattern.md \
    docs/migration/decisions/0028-unauthenticated-read-boundary.md
```

Zero hits across both files this requirement produces, other than this section's own
grep pattern. A reviewer reading either file cannot tell which vertical motivated it —
which is the test rule 1 sets.
