# REQ-066 — `Letflow.Api.Error` / `Letflow.Api.Response`

PROVENANCE (historical, not current decision authority):
Design for the RFC 9457 Problem Details builder and the conn-threading response
helpers that every S4 route will use. Ports `src/api/errors.zig` (272 lines) and
`src/api/response.zig` (69 lines). No implementation code below — signatures and
type shapes only.

## 0. Key decisions (answering the handoff's explicit design questions)

### 0.1 JSON library

PROVENANCE (historical, not current decision authority):
**Jason.** Already a direct dependency (`mix.exs`: `{:jason, "~> 1.4"}`) and already
in use in `lib/letflow/router.ex` (`Jason.encode!/1`) and
`lib/letflow/plugs/tenant_status.ex`. No new dependency. This is also a genuine
behavior *improvement* over the Zig source worth noting in the moduledoc:
`errors.zig`'s `serialise/2` builds the JSON body with `std.fmt.allocPrint` and a
literal `"{s}"` interpolation — it does **not** escape quote/backslash/control
characters inside `detail`. `Jason.encode!/1` does full RFC 8259 string escaping.
This is a strict correctness improvement, not a divergence to flag as a tradeoff —
state it in the moduledoc as "and this fixes an unescaped-string bug present in the
Zig source" so nobody "fixes" Jason back to raw interpolation later.

### 0.2 Constructor scope for this requirement

**Port only the generic HTTP-status family now; do not port the nine domain-specific
constructors in this requirement.**

PROVENANCE (historical, not current decision authority):
Ported now (10 constructors, covering every status code `errors.zig` maps to a
*generic* HTTP meaning): `bad_request/1` (400), `unauthorized/1` (401),
`forbidden/1` (403), `not_found/0` (404 — no detail param, see §0.4), `conflict/1`
(409), `unsupported_media_type/1` (415), `unprocessable/1` (422),
`rate_limited/1` (429), `internal/0` (500 — no detail param, see §0.4),
`service_unavailable/1` (503).

Deliberately deferred, not ported in this requirement: `problemPartitionMissingForWrite`
(503, PAR-01), `problemUnresolvedCatalogRef` / `problemUnresolvedModuleRef` /
`problemVariableSchemaViolation` / `problemUnresolvedPinOverride` (422, PIN-01),
`problemUnknownPinRef` / `problemInstanceNotRebindable` (PIN-05),
`problemEmptyPromotionPlan` / `problemInvalidPromotionSource` (422/409, PRM-01).

**Rationale:** every deferred constructor's own R-Co doc comment cites a specific
owning acceptance-criterion (PIN-01 AC1-4, PIN-05 AC2-3, PRM-01 AC3-4, PAR-01 AC4)
that is itself a separate, not-yet-landed Letflow requirement. Porting a
`problem_unresolved_pin_override/1`-shaped function now, before PIN-01's
`pin_overrides` resolution logic exists, would be a constructor with no real
caller and no way to verify its `detail` wording matches what the eventual PIN-01
handler actually needs to say — premature and undemonstrable. The generic family
is sufficient for this requirement's own acceptance criteria (400/401/403/404/409/
422/429/500 family + 201/204 success helpers) and is what every S4 route needs on
day one regardless of which domain-specific feature lands later.

**Extensibility for later requirements is by pattern-copy, not a shared public
builder.** `Letflow.Api.Error`'s ten constructors all share an identical five-line
shape (module attribute base + `%__MODULE__{type: ..., title: ..., status: ...,
detail: detail}`). A later requirement (PIN-01, PIN-05, PRM-01, PAR-01) adds its
own public constructor function to this same module, following that identical
shape — it does not need a shared "generic builder" export from this requirement.
This keeps `Letflow.Api.Error`'s public surface exactly the set of constructors
that are actually demonstrated by a real caller, which matches this project's
"don't add abstractions the current requirement doesn't need yet" rule
(`.claude/agents/elixir-dev.md`). Flagged as an open question in §5 in case
CODE-DESIGN-VALIDATOR or REVIEWER prefers a shared private helper instead.

### 0.3 Plug-pipeline integration

**Neither module is a `Plug`.** `Letflow.Api.Error` and `Letflow.Api.Response` are
plain function libraries with no `@behaviour Plug`, no `init/1`/`call/2`. They are
called *from* route handlers and *from* plugs (e.g. a future rescue/error-handling
plug), the same way `Letflow.Plugs.TenantStatus`'s `reject_migrating/1` builds and
sends a response inline rather than delegating to a shared module today (this
requirement gives it — and every future S4 plug/handler — that shared module to
delegate to instead of hand-rolling `Jason.encode!/1` + `put_resp_content_type/2` +
`send_resp/3` locally, which is what `router.ex` and `tenant_status.ex` currently
do independently).

`lib/letflow/router.ex`'s private `send_json/3` becomes redundant once this lands —
ELIXIR-DEV should replace its body with a delegation to
`Letflow.Api.Response.send_json/3` (or remove it and call
`Letflow.Api.Response.send_json/3` directly at both call sites) as part of
implementing this requirement, since leaving two copies of the same
encode-and-send logic is exactly the duplication class
`docs/anti-patterns.md`'s fragment-literal entry warns against for a different
mechanism (SQL) but the same principle (single source of truth once one exists).

**A catch-all exception → 500 plug (`Plug.ErrorHandler` mounted in
`Letflow.Router`) is explicitly OUT OF SCOPE for this requirement.** This
requirement's job is to make `Response.internal_error/1` (§1.3) *safe to call* — a
function that structurally cannot leak exception internals — not to wire up the
router-level rescue that calls it automatically on every unhandled crash. That
wiring point does not exist yet (`router.ex` has no `use Plug.ErrorHandler` today)
and belongs to whichever later requirement actually builds the tenant-scoped
route pipeline (REQ-070 router decomposition, or REQ-071 mounting the auth/tenant
pipeline) — it is not implied or blocked by this one. **Consequence for
TEST-DESIGNER:** the INV-4 acceptance criterion ("a 500 produced from an
unexpected exception has a detail string identical across two different
underlying exception types") is tested by calling `Response.internal_error/1`
directly in two test cases that each simulate having caught a different
exception (e.g. `rescue e1 in RuntimeError -> ...` vs `rescue e2 in
Ecto.QueryError -> ...`, or more simply, two tests that just never pass the
caught exception to `internal_error/1` at all, since the function's own `@spec`
takes none) and asserting the two resulting JSON bodies are byte-identical — not
by triggering a real router-level crash-and-rescue round trip.

### 0.4 Structural enforcement of INV-4 and INV-5

Both invariants are enforced by **removing the parameter that could violate them**,
not by convention or a lint rule:

- **INV-4 (500 detail never varies with the exception).**
  `Letflow.Api.Error.internal/0` and `Letflow.Api.Response.internal_error/1` take
  **no `detail` argument at all** — `internal/0`'s arity is zero, `internal_error/1`'s
  only argument is `conn`. The detail string is a module attribute
  (`@internal_error_detail "an unexpected error occurred"`) baked into the
  function body. There is no parameter an exception's `Exception.message/1`,
  `__struct__`, or a formatted stacktrace could be threaded through, because the
  function signature has no slot for it — a caller physically cannot pass
  exception-derived text into this path even by mistake. This is stronger than a
  convention ("callers should pass a generic detail") because it removes the
  capability instead of trusting discipline at every call site, which is what
  "structurally impossible" in the handoff's task description requires.

- **INV-5 (404 byte-identical for true-not-found vs. cross-tenant).**
  `Letflow.Api.Error.not_found/0` and `Letflow.Api.Response.not_found/1` are
  likewise **zero-`detail`-argument** — `@not_found_detail "the requested
  resource was not found"` is a module attribute, not a parameter. Every caller
  in the codebase — the true-not-found path and the cross-tenant path (REQ-072's
  routing) alike — can only reach this 404 body through this one function with no
  way to supply a different `detail`, `type`, or `title`. Byte-identical output is
  therefore guaranteed by construction: there is exactly one code path that can
  produce a 404 problem document, and it has no input that varies. (This also
  means REQ-072's cross-tenant-lookup implementation has nothing to get wrong here
  — it just calls `Response.not_found(conn)`, the same call a genuine
  resource-does-not-exist path makes.)

  Every *other* status constructor (`bad_request/1`, `conflict/1`, etc.) keeps a
  `detail` parameter, since INV-4/INV-5 only constrain 500 and 404 — the handoff's
  broader "detail is a caller-safe string chosen by the handler" principle still
  applies to the rest of the family, and CODE-DESIGN-VALIDATOR should confirm this
  distinction (some constructors parameterized, two deliberately not) is not
  mistaken for an inconsistency.

## 1. `Letflow.Api.Error`

PROVENANCE (historical, not current decision authority):
**File:** `lib/letflow/api/error.ex` (new). **Pure** — no `Plug.Conn` dependency,
no I/O. Ports `errors.zig`'s `ProblemDetails` struct, its per-status constructors,
and `serialise/2`.

### 1.1 Types

```
@type t :: %__MODULE__{
        type: String.t(),      # absolute URI, "<base><slug>"
        title: String.t(),
        status: 400..599,
        detail: String.t(),
        trace_id: String.t()   # "" default; resolved by the caller (Response), see §1.4
      }
```

PROVENANCE (historical, not current decision authority):
Defined via `defstruct [:type, :title, :status, :detail, trace_id: ""]` — mirrors
`ProblemDetails`'s field set 1:1, including `trace_id`'s `""` default
(`errors.zig`'s own default).

PROVENANCE (historical, not current decision authority):
`@problems_base` — module attribute,
`Application.compile_env(:letflow, :problems_base_uri, "https://bpm.example.com/problems/")`.
Ported as a **configured** base (per the handoff's explicit requirement) rather
than `errors.zig`'s hardcoded `BASE` constant, so a later requirement/deploy can
point `type` URIs at a real Letflow domain without a code change — defaults to the
identical R-Co value for continuity in the meantime. `config/config.exs` does not
need a new key added by this requirement (the `compile_env/3` default covers it);
a later requirement may add an explicit `config :letflow, problems_base_uri: "..."`
if Letflow's real problem-type documentation domain is decided.

### 1.2 Serialisation

```
@spec serialise(t()) :: String.t()
```
JSON body: `{"type":...,"title":...,"status":...,"detail":...,"trace_id":...}` —
field order does not matter for JSON validity and is not asserted by name in
tests, only field *presence and value* per AC1. Implemented via `Jason.encode!/1`
against the struct (or `Map.from_struct/1` first, if `Jason.Encoder` is not
derived for the struct — CODE-DESIGN-VALIDATOR should confirm whichever the
implementer picks compiles; either is a valid `Jason` usage, not a design
ambiguity that changes the output shape).

PROVENANCE (historical, not current decision authority):
No `error{OutOfMemory}` equivalent — Elixir has no caller-managed allocator, so
`errors.zig`'s allocator-failure fallback body (the hand-written literal 500 JSON
string in `response.zig`'s `problemResponse`) has no Elixir analogue and is not
ported; state this explicitly in the moduledoc as a translation note, not a
silent drop.

### 1.3 Constructors (generic HTTP-status family — see §0.2 for scope)

```
@spec bad_request(String.t())           :: t()   # 400
@spec unauthorized(String.t())          :: t()   # 401 — caller sets WWW-Authenticate separately
@spec forbidden(String.t())             :: t()   # 403
@spec not_found()                       :: t()   # 404 — NO detail param, see §0.4
@spec conflict(String.t())              :: t()   # 409
@spec unsupported_media_type(String.t()) :: t()  # 415
@spec unprocessable(String.t())         :: t()   # 422
@spec rate_limited(String.t())          :: t()   # 429 — caller sets Retry-After separately
@spec internal()                        :: t()   # 500 — NO detail param, see §0.4
@spec service_unavailable(String.t())   :: t()   # 503
```

PROVENANCE (historical, not current decision authority):
Each constructor sets `type` to `@problems_base <> "<slug>"` (e.g.
`"bad-request"`, `"not-found"`, `"unauthorized"`, `"forbidden"`, `"conflict"`,
`"unsupported-media-type"`, `"unprocessable-entity"`, `"rate-limited"`,
`"internal-error"`, `"service-unavailable"`) and `title` to the matching
Title-Case phrase — both taken verbatim from `errors.zig`'s own constants (see
the source excerpts in the handoff). `trace_id` is left at its struct default
(`""`); §1.4 covers how it gets populated.

### 1.4 Trace ID resolution

PROVENANCE (historical, not current decision authority):
`errors.zig`'s `serialise/2` resolves `trace_id` itself (checking a thread-local
`trace_context.get()` if the struct's own field is empty). Per
`docs/migration/stage-4-api-surface.md`'s explicit guidance ("Prefer
`conn.assigns` ... do not port a thread-local global"), `Letflow.Api.Error` stays
conn-agnostic and does **not** do this resolution — it is `Letflow.Api.Response`'s
job (§2), since only the `Response` layer has a `conn` to read
`conn.assigns[:trace_id]` from. `Letflow.Api.Error`'s constructors always leave
`trace_id: ""`; `Response`'s error-sending functions overwrite that field with
`conn.assigns[:trace_id] || ""` before calling `serialise/1`. (Where `trace_id` is
actually populated onto `conn.assigns` is `trace.zig`'s port, a separate S4
requirement per `stage-4-api-surface.md`'s middleware table — not yet built, so
`conn.assigns[:trace_id]` reads as unset/`nil` and correctly serialises as `""`
until that requirement lands.)

## 2. `Letflow.Api.Response`

PROVENANCE (historical, not current decision authority):
**File:** `lib/letflow/api/response.ex` (new). Conn-threading — every function
takes a `Plug.Conn.t()` and returns a `Plug.Conn.t()`, replacing `response.zig`'s
`HandlerResult` value-returning shape. State this translation explicitly in the
moduledoc, per the handoff's explicit requirement: *"In Elixir the conn IS the
result carrier... `response.zig`'s `HandlerResult` struct is replaced by
conn-threading functions because Zig returns a value having no conn to thread
through; Elixir's `Plug.Conn` already is that carrier."*

PROVENANCE (historical, not current decision authority):
### 2.1 Success helpers (ports `response.zig`'s `ok`/`created`/`noContent`)

```
@spec send_json(Plug.Conn.t(), 100..599, map()) :: Plug.Conn.t()
@spec ok(Plug.Conn.t(), map())       :: Plug.Conn.t()   # send_json(conn, 200, body)
@spec created(Plug.Conn.t(), map())  :: Plug.Conn.t()   # send_json(conn, 201, body)
@spec no_content(Plug.Conn.t())      :: Plug.Conn.t()   # 204, empty body — no `body` param
```

- `send_json/3` is the shared primitive: `put_resp_content_type(conn,
  "application/json") |> send_resp(status, Jason.encode!(body))`. This is the
  single generalization of `router.ex`'s existing private `send_json/3` (already
  named identically and shaped identically) — see §0.3's note that `router.ex`
  should delegate to this instead of keeping its own copy.
- PROVENANCE (historical, not current decision authority):
  `ok/2` and `created/2` are thin `send_json/3` wrappers at fixed status codes,
  mirroring `response.zig`'s `ok`/`created` (which likewise just fix the status
  code onto the same body-passthrough shape).
- PROVENANCE (historical, not current decision authority):
  `no_content/1` takes **no body parameter** (mirrors `noContent()` taking no
  argument in `response.zig`) — it always sends an empty string body at 204.
  AC5 requires a test asserting the body is literally empty; `no_content/1`'s
  signature makes any non-empty body impossible to pass in, not just
  discouraged.

PROVENANCE (historical, not current decision authority):
### 2.2 Error-sending (ports `response.zig`'s `problemResponse`)

```
@spec send_problem(Plug.Conn.t(), Letflow.Api.Error.t()) :: Plug.Conn.t()
```
The one primitive every per-status wrapper below funnels through:
`conn.assigns[:trace_id] || ""` is spliced into the given `Error.t()`'s
`trace_id` field (§1.4), then the conn is sent with
`put_resp_content_type(conn, "application/problem+json")` (see §2.3 on this
Content-Type divergence) and `send_resp(pd.status, Error.serialise(pd))`.

Per-status wrappers (all conn-threading, all delegating to §1.3's `Error`
constructor then `send_problem/2`):

```
@spec bad_request(Plug.Conn.t(), String.t())           :: Plug.Conn.t()  # 400
@spec unauthorized(Plug.Conn.t(), String.t())          :: Plug.Conn.t()  # 401
@spec forbidden(Plug.Conn.t(), String.t())             :: Plug.Conn.t()  # 403
@spec not_found(Plug.Conn.t())                         :: Plug.Conn.t()  # 404 — no detail, INV-5
@spec conflict(Plug.Conn.t(), String.t())              :: Plug.Conn.t()  # 409
@spec unsupported_media_type(Plug.Conn.t(), String.t()) :: Plug.Conn.t() # 415
@spec unprocessable(Plug.Conn.t(), String.t())         :: Plug.Conn.t()  # 422
@spec rate_limited(Plug.Conn.t(), String.t())          :: Plug.Conn.t()  # 429
@spec internal_error(Plug.Conn.t())                    :: Plug.Conn.t()  # 500 — no detail, INV-4
@spec service_unavailable(Plug.Conn.t(), String.t())   :: Plug.Conn.t()  # 503
```

PROVENANCE (historical, not current decision authority):
Callers needing `WWW-Authenticate` (401) or `Retry-After` (429) set the header
themselves before calling, since `put_resp_header/3` composes ahead of
`send_resp/3` in the conn pipeline — e.g.
`conn |> put_resp_header("retry-after", "30") |> Response.rate_limited("too many requests")`
— matching both `errors.zig`'s own doc comments ("caller MUST set ... separately")
and the existing precedent in `lib/letflow/plugs/tenant_status.ex`'s
`reject_migrating/1`, which already does exactly this header-then-body ordering
by hand (and which ELIXIR-DEV may now simplify to call `Response.service_unavailable/2`
plus its own `put_resp_header/3` for `retry-after`, optional cleanup, not required
by this requirement's scope).

### 2.3 Content-Type divergence — stated explicitly per the handoff's requirement

PROVENANCE (historical, not current decision authority):
**Success responses:** `Content-Type: application/json` (unchanged from R-Co;
`response.zig`'s `CONTENT_TYPE_JSON = "application/json"` is the default on every
`HandlerResult`, including the success ones).

PROVENANCE (historical, not current decision authority):
**Error responses:** `Content-Type: application/problem+json`. **This diverges
from R-Co.** Re-reading `response.zig`'s `problemResponse/2` directly: its
returned `HandlerResult` literal (`.{ .status_code = pd.status, .body = body }`)
does **not** set a `content_type` field, so it falls through to the struct's own
default — `CONTENT_TYPE_JSON = "application/json"`. **R-Co's error responses are
therefore served as `application/json`, not `application/problem+json`, despite
building an RFC 9457-shaped body.** Letflow's `send_problem/2` deliberately emits
the RFC 9457-correct `application/problem+json` instead — this is a considered
divergence, not an oversight, made because AC2 explicitly requires it and RFC 9457
§3 defines `application/problem+json` as the media type for exactly this document
shape. State both halves of this (R-Co's actual behavior, and that Letflow
intentionally does not replicate it) in the moduledoc, per the handoff's explicit
instruction.

## 3. Data / DB / cross-module

**No DB schema changes.** Both modules are pure/conn-threading libraries with no
Ecto schema, no migration.

**Cross-module dependencies:**
- `Jason` (existing `mix.exs` dependency) — both `Error.serialise/1` and
  `Response`'s success helpers.
- `Plug.Conn` (existing `plug` dependency) — `Response` only; `Error` has none.
- Consumed by: every future S4 route handler/controller (REQ-073 through
  REQ-085), and by existing/future plugs — `lib/letflow/plugs/tenant_status.ex`'s
  `reject_migrating/1` is a candidate to simplify onto `Response.service_unavailable/2`
  (optional, not required by this requirement), and `lib/letflow/router.ex`'s
  `send_json/3` should be replaced by a delegation to
  `Letflow.Api.Response.send_json/3` (§0.3, required cleanup as part of this
  requirement since it directly duplicates what this requirement ships).
- REQ-072 (tenant-scoped request context / cross-tenant 404 mechanism) will call
  `Response.not_found/1` for both its true-not-found and cross-tenant paths — this
  requirement's `not_found/1` is what makes REQ-072's INV-5 guarantee trivial to
  satisfy (§0.4).

## 4. Invariants (restated compactly)

- **INV-4.** `Error.internal/0` / `Response.internal_error/1` take zero
  detail-bearing arguments; `detail` is a `@internal_error_detail` module
  attribute. No exception value, message, module name, or stacktrace can reach
  the body through any parameter, because no such parameter exists.
- **INV-5.** `Error.not_found/0` / `Response.not_found/1` take zero
  detail-bearing arguments; `detail`/`type`/`title` are fixed module attributes.
  Every 404-producing call site (true-not-found and cross-tenant alike) shares
  this one function, so the two bodies are byte-identical by construction — there
  is no second code path and no parameter that could make them diverge.
- **Content-Type split.** Success → `application/json`; error →
  `application/problem+json` (§2.3) — a deliberate divergence from R-Co, stated
  in the moduledoc.
- **Every acceptance criterion → design element:**
  - AC1 (type/title/status/detail JSON body per constructor) → §1.1/§1.3, one
    test per constructor asserting all four fields.
  - AC2 (Content-Type split, header-asserted) → §2.3.
  - AC3 (500 detail invariant across exception types) → §0.4, §1.3's `internal/0`
    zero-arity, tested per §0.3's note (two tests calling `internal_error/1`
    directly, not via a live crash path).
  - AC4 (404 byte-identical not-found vs. cross-tenant) → §0.4, §1.3's
    `not_found/0` zero-arity.
  - AC5 (201/204 success helpers, 204 body empty) → §2.1.
  - AC6 (moduledoc states the HandlerResult→conn translation and the
    Content-Type divergence) → §2 (opening paragraph) and §2.3.

## 5. Open questions (not silently resolved)

1. **Shared private builder vs. pattern-copy for future domain-specific
   constructors (§0.2).** This design has each of the ten constructors write out
   its own five-line struct literal rather than funneling through a shared
   private `defp new(slug, title, status, detail)`. A shared private helper would
   save a few lines per future constructor at the cost of one more indirection to
   read. Left unresolved here — CODE-DESIGN-VALIDATOR/REVIEWER should pick a
   position; either is compatible with this design's public API and INV-4/INV-5
   enforcement (the zero-arity constructors would still not accept a `detail`
   parameter either way).
2. **`Jason.Encoder` derive vs. `Map.from_struct/1` before `Jason.encode!/1`
   (§1.2).** Both compile and produce identical JSON for this struct (no nested
   structs, no fields needing custom encoding). Left to ELIXIR-DEV as a
   style choice, not a behavior-affecting one.
3. **`config :letflow, problems_base_uri`** (§1.1) is read via
   `Application.compile_env/3` with R-Co's literal value as the default and no
   explicit `config/config.exs` entry added by this requirement. If a real
   Letflow problem-type documentation domain is decided later, that is a config
   change only, not a code change — flagged so nobody mistakes the placeholder
   domain for a decision that needs a `docs/migration/decisions/` record.
