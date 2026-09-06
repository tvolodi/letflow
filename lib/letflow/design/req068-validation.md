# REQ-068 — `Letflow.Api.Validation` / `Letflow.Plugs.ContentType` / `Letflow.Plugs.SafeJsonParser`

PROVENANCE (historical, not current decision authority):
Design for the request-body validation and typed-rejection contract. Ports
`src/api/validation.zig` (592 lines), `src/api/middleware/content_type.zig` (119
lines), `src/api/middleware/validate.zig` (86 lines). No implementation code below —
signatures and type shapes only.

## 0. Key decisions

### 0.1 Module split

Three modules, not one, matching R-Co's own three-file split but adapted to Plug's
request lifecycle:

PROVENANCE (historical, not current decision authority):
- **`Letflow.Api.Validation`** — pure (no `Plug.Conn`, no I/O). Ports `validation.zig`
  1:1: `FieldConstraint`, `FieldError`, `validate/2`. This is where
  `middleware/validate.zig`'s thin wrapper (`enforceValidation/4`) collapses to —
  Elixir has no separate "middleware calls pure module" ceremony once the pure
  module already returns a tagged result a Plug can pattern-match on directly, so
  `validate.zig`'s 86 lines are NOT ported as a second module. `validation.zig`'s
  `serialiseValidationErrors/2` becomes `Letflow.Api.Validation.problem/1`, returning
  a `Letflow.Api.Error.t()` with the errors list threaded through a new `errors`
  field (see §0.5) rather than hand-building JSON — `Letflow.Api.Error`/`Response`
  (REQ-066) already own JSON serialisation and `trace_id` resolution; duplicating
  that here would be the second-statement-of-one-rule problem this doc set warns
  against elsewhere.
PROVENANCE (historical, not current decision authority):
- **`Letflow.Plugs.ContentType`** — ports `content_type.zig`. A real `Plug`
  (`init/1` + `call/2`), since Content-Type enforcement is inherently
  conn-and-header-shaped, not a pure value transform.
- **`Letflow.Plugs.SafeJsonParser`** — NOT present in R-Co (Zig's HTTP layer has no
  analogue to Plug's raise-on-oversized-body behaviour). Wraps `Plug.Parsers` to
  convert `Plug.Parsers.RequestTooLargeError` / `ParseError` /
  `UnsupportedMediaTypeError` into `Letflow.Api.Response` problem documents instead
  of letting them propagate as uncaught exceptions past this router (which has no
  `Plug.ErrorHandler`) into a generic 500 from the adapter. This is the mechanism
  AC3 (413 on oversized body) and half of AC2 (invalid JSON → typed 400, not a
  crash) actually run through — see §0.3.

### 0.2 Content-Type decision table — ported verbatim

PROVENANCE (historical, not current decision authority):
`checkContentType/3`'s table (content_type.zig:34-41) is ported exactly, including
the PUT-with-no-body → 400 case (not 415) that a naive reading of the requirement's
own prose ("POST/PUT/PATCH without Content-Type → 415") would miss:

| method | has_body | Content-Type | Outcome |
|---|---|---|---|
| GET/HEAD/DELETE | — | — | pass, unchecked |
| PUT | false | — | 400 "body is required for PUT" |
| POST/PATCH | false | absent or ≠ `application/json` | 415 |
| POST/PATCH | false | `application/json` | pass |
| POST/PUT/PATCH | true | absent or ≠ `application/json` | 415 |
| POST/PUT/PATCH | true | `application/json` | pass |

PROVENANCE (historical, not current decision authority):
`stripParams/1` (content_type.zig:114) — strip everything from the first `;`
onward, trim trailing whitespace — is ported so `application/json; charset=utf-8`
passes. This plug reads `conn.method` and the raw `content-type` request header via
`Plug.Conn.get_req_header/2` (not `conn.body_params`, which does not exist yet at
this point in the pipeline) and `has_body` from `Plug.Conn.get_req_header(conn,
"content-length")` — a non-"0"/absent content-length, OR (defensively) `transfer
-encoding: chunked`, counts as `has_body = true`. Runs in the router's plug list
**before** `Letflow.Plugs.SafeJsonParser`, so a wrong-Content-Type request is
rejected before any parsing is attempted, per AC1.

### 0.3 Oversized/malformed body handling — the one real R-Co divergence

R-Co's Zig HTTP layer parses bodies manually with a caller-supplied allocator, so
"body too large" and "malformed JSON" are just more `error{...}` values the same
function returns — there is no separate "the framework crashes if you don't catch
this" failure mode. `Plug.Parsers` is not evaluator-of-values here; it's a Plug in
the router's pipeline that **raises** on both conditions
(`Plug.Parsers.RequestTooLargeError`, `plug_status: 413`;
`Plug.Parsers.ParseError`, `plug_status: 400`, wrapping the underlying
`Jason.DecodeError`). This router has no `use Plug.ErrorHandler` and none is added
by this requirement (that's a router-wide concern outside REQ-068's scope) — an
uncaught raise here would reach Bandit as an unhandled process crash and come back
as a bare-text 500, which is exactly the INV-8 failure this requirement exists to
prevent.

`Letflow.Plugs.SafeJsonParser` closes this the same way any Plug wrapping another
Plug that can raise does: `call/2` invokes `Plug.Parsers.call/2` inside a `rescue`,
translating the three `Plug.Exception`-carrying structs Plug's own parser code can
raise into `Letflow.Api.Response` problem documents and `halt/1`-ing the conn (so
`:match`/`:dispatch` never run against a body that was never actually parsed):

- `RequestTooLargeError` → `Response.payload_too_large/2` (413, new constructor,
  §0.4)
- `ParseError` → `Response.bad_request/2` (400) — malformed JSON is a syntax
  defect in the request, not a validation-schema violation, so it does not go
  through `Letflow.Api.Validation` at all; there is no parsed value to validate
  yet.
- `UnsupportedMediaTypeError` → `Response.unsupported_media_type/2` (415) —
  defensive: `Letflow.Plugs.ContentType` already runs first and should make this
  unreachable in practice (both plugs agree the accepted type is
  `application/json`), but `Plug.Parsers` itself still enforces its own `:pass`/
  media-type list independently, so this is not dead code to delete, it is a
  second independent check agreeing with the first.

### 0.4 New `Letflow.Api.Error` constructor: `payload_too_large/1` (413)

REQ-066 did not port this status (R-Co's `errors.zig` has no 413 constructor —
Zig's manual body-reading loop bounds the read itself rather than raising a typed
error for "too large"). Added here, following REQ-066's exact per-status-function
shape (`type`/`title`/`status`/`detail`), because this requirement is the first to
need it. `Letflow.Api.Response.payload_too_large/2` added to match.

### 0.5 `Letflow.Api.Error` gains an `errors` field (RFC 9457 extension member)

PROVENANCE (historical, not current decision authority):
`validation.zig`'s `serialiseValidationErrors/2` hand-builds a Problem Details JSON
object with a non-standard `errors` array appended after the four RFC 9457 members
(content_type.zig / errors.zig's `ProblemDetails` struct has no such field — this
extension is validation-specific). Rather than hand-building a second, parallel
JSON-serialisation path outside `Letflow.Api.Error` (duplicating REQ-066's
`trace_id` resolution and `Jason.encode!/1` call), `Letflow.Api.Error.t()` gains one
new **optional** field: `errors: [FieldError.t()] | nil`, `@derive`d into the same
`Jason.Encoder` list, encoded only when non-nil (`Jason` omits `nil` map/struct
values it is told to skip — implementation detail, verified in code, not asserted
here). Every existing constructor is unaffected (field defaults to `nil`, and
`nil` is not the same as an empty list — an *absent* `errors` key on every
non-validation problem document, not a `"errors":null` or `"errors":[]`).
`Letflow.Api.Validation.problem/1` is the one and only constructor that sets it,
always to a non-empty list (mirrors `validation.zig`'s own "`errors.len > 0` is
guaranteed" contract on `.errors`).

### 0.6 `FieldConstraint` — one real addition over R-Co: `:uuid` as its own type

PROVENANCE (historical, not current decision authority):
R-Co's `JsonType` enum has no `:uuid` variant — `validation.zig` was going to
express "this field must look like a UUID" via `expected_type: .string` plus
`pattern: "..."`, but `pattern` is a documented no-op in the ported source
(`validation.zig:239-244`: *"std.regex was removed in Zig 0.16; pattern matching is
deferred to a future implementation"*). REQ-068's acceptance criteria explicitly
lists "UUID shape" as a validator this port must have working, and the requirement
text says port intent, not an accidentally-stubbed upstream limitation. Elixir has
no equivalent stdlib gap, so `expected_type` gets an eighth variant, `:uuid`,
checked with `Ecto.UUID.cast/1` (already a transitive dependency via `ecto`, no new
dep) rather than a hand-rolled regex — `Ecto.UUID.cast/1` accepts the canonical
8-4-4-4-12 hex form and rejects everything else, returning `:error` rather than
raising on any input including non-string values, satisfying INV-8's
never-raise contract for free. `pattern` itself (arbitrary regex) is **not**
ported — it was never functional in the source being ported, so there is nothing
to port; a future requirement that needs it starts from a real spec, not from
reviving unreachable Zig dead code.

### 0.7 `reject_empty_string` default

PROVENANCE (historical, not current decision authority):
R-Co defaults `reject_empty_string: false` (`validation.zig:82`, an opt-in per
`FieldConstraint`). Ported as the same explicit opt-in with the same default —
not every empty string is invalid (e.g. an optional `description` field), so this
is a per-field author decision, not something this requirement should silently
strengthen.

### 0.8 Enum membership

Not a distinct field in R-Co's `FieldConstraint` (the requirement's own text lists
"enum membership" as a validator this port needs; R-Co achieves it today only via
the unimplemented `pattern` no-op, i.e. never, in the source as it exists). Added
as `allowed_values: [term()] | nil` — when set, the field's value (after type
checking) must be `in` the list, else a `FieldError` with `constraint:
"enum_membership"`. This is new relative to the literal Zig source for the same
reason as §0.6: the requirement's acceptance criteria is the contract being
ported, and R-Co's stub is not evidence the feature is unwanted.

### 0.9 Structural safety layer — INV-8, applies before any `FieldConstraint` runs

PROVENANCE (historical, not current decision authority):
Four checks that do not depend on the schema, run once per request body, ported as
`Letflow.Api.Validation.validate/2`'s first phase (mirrors `validate/4`
(`validation.zig:369-386`)'s own "must be a JSON object" check, which is schema-
independent, plus the requirement's explicit INV-8 list):

1. **Not valid JSON** — never reaches `Letflow.Api.Validation` at all; caught by
   `Letflow.Plugs.SafeJsonParser` per §0.3 before validation runs.
PROVENANCE (historical, not current decision authority):
2. **Valid JSON, not an object** (e.g. a top-level array or scalar) — ported
   exactly as `validate/4`'s existing `(root)`/`type.object` error
   (`validation.zig:377-386`).
3. **NUL byte in any string value, anywhere in the decoded body, not just in
   schema-declared fields** — new relative to R-Co (which has no such check at
   all — Zig's `[]const u8` strings are byte slices with no embedded-NUL
   restriction, but PostgreSQL `text`/`varchar` columns reject a NUL byte
   (`Postgrex` raises `ArgumentError`, not something this validator can leave for
   the DB layer to discover post-hoc, hence INV-8 naming it explicitly). Checked
   by a recursive walk over the **entire** decoded body (not per-`FieldConstraint`
   — a NUL byte in an unrecognised/unvalidated key must still be caught, since it
   would still reach `Repo` if any handler later reads it via `Map.get/2` outside
   the declared schema), before per-field constraint checks run. On a hit: one
   `FieldError` naming the dotted path to the offending value
   (`constraint: "no_null_byte"`), and structural checks stop there (per-field
   checks do not also run against a body already rejected structurally — mirrors
   `validate/4` returning immediately on its own non-object check rather than
   also running field checks).
4. **Excessive nesting depth is NOT a separate structural check.** A body that
   validates cleanly through the recursive NUL-byte walk and then hits ordinary
   `FieldConstraint` type-checking is handled by that machinery's own
   pattern-matched (never bare-`case`-without-an-else, never `Map.fetch!/2`)
   type comparisons — a deeply-nested object compared against a field expecting
   `:string` is exactly a `type.string` mismatch, the same as any other wrong
   shape, with no special-cased "depth" concept needed. §2 states the one
   INV-8-motivated implementation rule this depends on: every recursive
   walk/pattern match in this module has a `_ -> ...` fallback branch, never an
   assumed shape.
5. **SQL metacharacters in a string field are NOT specially checked or rejected
   here.** Parameterised queries (every `Ecto.Query`/`Repo` call in this
   codebase) are the actual defence against SQL injection; a validator that tried
   to reject `'`, `;`, `--`, etc. would both fail to add real security (Ecto
   never string-interpolates user input into SQL) and reject legitimate values
   (a `description` field containing an apostrophe). State this explicitly so a
   later reader does not "fix" the absence of such a check as a gap — it is a
   deliberate non-goal, named per this issue's own moduledoc-must-state-boundaries
   convention (§0.10 below applies the same discipline to the rate-limit/quota
   omission).

PROVENANCE (historical, not current decision authority):
### 0.10 Scope boundary — `rate_limit.zig` / `quota_enforcement.zig`

Not ported by this requirement. Both need per-tenant counter storage (`Letflow`
has none yet — no requirement has built one). Bolting a counter store onto a
validation requirement is exactly the partial-subsystem failure REQ-056's
boundary paragraph exists to prevent. They belong to their own later requirement,
or to S6 alongside the rest of the operational cross-cutting concerns (mirrors the
framing decision 0001's Dimension B already uses for this pair). Stated in
`Letflow.Api.Validation`'s moduledoc per the acceptance criteria, not left
unremarked.

## 1. `Letflow.Api.Validation` — public interface

```elixir
@type json_type ::
        :string | :number | :integer | :boolean | :object | :array | :uuid

@type field_constraint :: %FieldConstraint{
        name: String.t(),
        required: boolean(),
        type: json_type() | nil,
        reject_empty_string: boolean(),
        min_length: non_neg_integer() | nil,
        max_length: non_neg_integer() | nil,
        min_value: number() | nil,
        max_value: number() | nil,
        min_items: non_neg_integer() | nil,
        max_items: non_neg_integer() | nil,
        allowed_values: [term()] | nil
      }

@type field_error :: %FieldError{
        field: String.t(),
        constraint: String.t(),
        message: String.t(),
        received: term()
      }

@spec validate_field(field_constraint(), term() | :missing) :: field_error() | nil
@spec validate(schema :: [field_constraint()], body :: term()) ::
        {:ok, map()} | {:errors, [field_error(), ...]}
@spec problem([field_error(), ...]) :: Letflow.Api.Error.t()
```

`validate/2`'s `body` parameter is whatever `conn.body_params` holds after
`Letflow.Plugs.SafeJsonParser` runs (a `Jason`-decoded term — `map()` for a JSON
object, but `validate/2` itself must handle every other decoded shape without
raising, per §0.9 point 2). On `{:ok, map}`, the returned map contains exactly the
schema's declared fields (present-and-valid ones; this port does not attempt
R-Co's `std.json.parseFromValue`-into-a-typed-struct step, since Elixir has no
static struct type to parse into at this layer — callers pattern-match the
returned map themselves, same as every other `conn.body_params` consumer in this
codebase already does).

## 2. `Letflow.Plugs.ContentType` — public interface

```elixir
@behaviour Plug
@spec init(keyword()) :: keyword()
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
```

No options. `init/1` is the identity function (mirrors `Letflow.Plugs.TenantStatus`'s
own `init([]) -> []`). On reject: `Plug.Conn.halt/1` after sending the problem
response, so `:match`/`:dispatch` and `SafeJsonParser` never run.

## 3. `Letflow.Plugs.SafeJsonParser` — public interface

```elixir
@behaviour Plug
@max_body_bytes 1_000_000  # 1 MiB — see §4
@spec init(keyword()) :: keyword()
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
```

`init/1` merges caller opts over `[parsers: [:json], json_decoder: Jason, length:
@max_body_bytes]` (caller-supplied `:length` wins, same override precedent as
`Letflow.Api.Response.send_problem/2`'s `trace_id` precedence) and delegates to
`Plug.Parsers.init/1`. `call/2` delegates to `Plug.Parsers.call/2` inside a
`rescue` per §0.3.

## 4. The 1 MiB body-size limit — justification

No S4 route built so far, and none this requirement itself adds, has a documented
payload shape to size against (no route calls `Letflow.Api.Validation` yet — this
requirement is infrastructure for REQ-069 onward). Absent a concrete endpoint to
measure, **1 MiB (1,000,000 bytes)** is chosen as a conservative, round,
easily-overridable-per-route ceiling: comfortably above any plausible single
process-definition/task-payload JSON body (R-Co's own `PageResponse` default page
size is 50 items per REQ-067; even a generously verbose per-item JSON
representation stays multiple orders of magnitude under 1 MiB for 50 rows), while
still bounding the memory a single request can force this node to buffer — an
unbounded body is a memory-exhaustion vector against a shared node, per this
requirement's own text. `@max_body_bytes` is a module attribute with this comment
attached in the source, not a bare literal, and `Letflow.Plugs.SafeJsonParser`'s
`init/1` lets a future route override it via `plug(Letflow.Plugs.SafeJsonParser,
length: <n>)` without touching this module, for the day a real oversized-payload
route (e.g. a bulk-import endpoint) needs a different ceiling.

## 5. Open questions

None blocking. `Letflow.Router` does not currently install these plugs (no S4
route consumes them yet — REQ-069 onward wires the first real routes); this
requirement ships the modules and their own unit tests (`Plug.Test`-driven, same
convention as `test/letflow/api/response_test.exs` /
`test/letflow/plugs/tenant_status_test.exs`, exercising `call/2` directly rather
than through `Letflow.Router`), and leaves router wiring to whichever requirement
adds the first validated route — wiring an unused plug into the live router now
would be exactly the "no real caller yet" prematurity REQ-066's own design doc
(§0.2) already declined for its domain-specific constructors.
