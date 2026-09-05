# REQ-067 — `Letflow.Api.Pagination`

PROVENANCE (historical, not current decision authority):
Design for the shared cursor-based pagination module every S4 list endpoint
delegates to. Ports `src/api/pagination.zig` (406 lines, API-06). No
implementation code below — signatures, `@spec`-style types, and struct/type
shapes only.

**File:** `lib/letflow/api/pagination.ex` (new). Depends on `Letflow.Api.Error`
/ `Letflow.Api.Response` (REQ-066, already shipped) only at the call-site level
(route handlers translate this module's error atoms into problem documents —
see §0.1); `Letflow.Api.Pagination` itself has no dependency on either.

## 0. Key decisions (answering the handoff's explicit design questions)

### 0.1 Where the non-numeric `page_size` check lives

R-Co's `validatePageSize(raw: ?u16)` takes an **already-parsed** `?u16` —
Zig's type system rejects a non-numeric `page_size` query string before
`validatePageSize` is ever called, at the point some earlier (unshown, HTTP
framework-level) code parses the query string into a `u16`. Elixir has no
compile-time equivalent: `conn.query_params["page_size"]` is always a
`String.t() | nil`, and a `String.t() | nil -> pos_integer() | nil` parse can
fail at runtime in a way Zig's type boundary makes unreachable.

This design ports that type boundary as an explicit **parse step in this same
module**, run first and separately from the range-validation step:

- **`parse_page_size_param/1`** — the parse-time concern (Zig's implicit type
  boundary made explicit). Takes the raw query-param value
  (`String.t() | nil`) and returns `{:ok, pos_integer() | nil}` for
  a `nil` or a fully-numeric non-negative integer string, or
  `{:error, :invalid_page_size}` for anything else (non-numeric, decimal,
  negative, trailing garbage after digits — e.g. `"abc"`, `"20x"`, `"-5"`,
  `"3.5"`). This is the **new** check that has no direct Zig-source
  counterpart, because Zig's boundary made it unreachable.
- **`validate_page_size/1`** — ports `validatePageSize/1` almost verbatim:
  takes an **already-parsed** `pos_integer() | nil` (never a string) and
  applies only the range check R-Co's own body has (`nil` → default; `0` or
  `> MAX_PAGE_SIZE` → reject; otherwise pass through).

**Call site (route handler), the intended composition, stated here so
ELIXIR-DEV does not have to guess the wiring:**

```
with {:ok, raw_size} <- Pagination.parse_page_size_param(conn.query_params["page_size"]),
     {:ok, page_size} <- Pagination.validate_page_size(raw_size) do
  ...
else
  {:error, :invalid_page_size}     -> Response.bad_request(conn, "page_size must be a positive integer")
  {:error, :page_size_too_large}   -> Response.bad_request(conn, "page_size must be between 1 and 200")
end
```

This is not wrapped in a single combined function in this design (no
`fetch_page_size/1` convenience) — keeping the two steps separate mirrors the
Zig source's own separation (a type-boundary concern vs. a range-check
concern) and lets a future requirement (REQ-068, request-body/query
validation) absorb `parse_page_size_param/1`'s job into a shared plug without
this module's range-check function needing to change. Flagged as an open
question in §5 in case CODE-DESIGN-VALIDATOR prefers one combined function.

**No new Plug is introduced by this requirement.** Query-param parsing stays a
per-route-handler call into this module's two functions, the same way
`Letflow.Api.Error`/`Letflow.Api.Response` are called directly from handlers
(REQ-066 §0.3). A shared validation plug is REQ-068's scope, not this one's.

PROVENANCE (historical, not current decision authority):
### 0.2 Reject, not clamp — and the HTTP status divergence from `pagination.zig`'s own comment

PROVENANCE (historical, not current decision authority):
**R-Co's `validatePageSize/1` rejects, never clamps** — confirmed by reading
the source directly (`pagination.zig:100-105`): `raw == null` returns
`DEFAULT_PAGE_SIZE`; `v == 0` returns `error.PageSizeTooLarge`; `v >
MAX_PAGE_SIZE` returns `error.PageSizeTooLarge`; otherwise the value passes
through unchanged. There is no clamping branch anywhere in the function. This
port preserves reject-not-clamp exactly: `validate_page_size/1` never rounds
an out-of-range value to `MIN_PAGE_SIZE`/`MAX_PAGE_SIZE` — every out-of-range
input becomes an error tuple.

PROVENANCE (historical, not current decision authority):
**Status code — a deliberate, explicitly-flagged divergence from
`pagination.zig`'s own doc comment.** The Zig source's own comment at
`pagination.zig:97` states `0 → error.PageSizeTooLarge (HTTP 422 per API-06
requirement)` — i.e. R-Co's own documentation says this should map to 422.
However, this requirement's dispatch (`REQ-067`'s `requirement_text` and
`task.description`, both reviewed against the live source) explicitly
instructs: *"A requested page size above MAX_PAGE_SIZE, below MIN_PAGE_SIZE,
or non-numeric is a 400 via REQ-066's problem document... Port this exactly: a
page size of 0 or >200 is a 400."* This design follows the requirement
dispatch's explicit 400 instruction, not the Zig comment's 422 — stated here
prominently, not silently resolved, so REVIEWER/CODE-DESIGN-VALIDATOR can
confirm this is the intended override rather than an oversight. If this is
wrong, it is a one-line fix in the route handler's `else` clause (change
`Response.bad_request/2` to `Response.unprocessable/2`), not a change to this
module's own functions — `validate_page_size/1`'s return value is a bare atom
tuple (`{:error, :page_size_too_large}`), not a status code, precisely so the
status-code choice stays a route-handler/call-site concern this module does
not hard-code.

PROVENANCE (historical, not current decision authority):
**Same error atom for `0` and `> 200` — ported verbatim, not "fixed."**
`pagination.zig`'s `PageSizeError` set has exactly one member
(`PageSizeTooLarge`), so both the zero case and the too-large case return the
same Zig error despite zero being semantically "too small." This design ports
that single-atom choice as-is (`:page_size_too_large` covers both), rather
than inventing a separate `:page_size_too_small` atom R-Co itself does not
have — introducing a finer-grained atom set would be scope creep past what
the source actually does.

### 0.3 Structural enforcement of INV-1 / INV-5 (no tenant scope in the cursor)

PROVENANCE (historical, not current decision authority):
`Letflow.Api.Pagination.Cursor` (§2) has exactly one field: `inner ::
binary()`. There is no `tenant_id`, `schema`, `prefix`, or any other field a
caller-supplied, tamper-decoded value could populate to widen a query's scope
— this is enforced by the struct's field list simply not containing such a
slot, the same "remove the capability, don't rely on convention" pattern
REQ-066 used for INV-4/INV-5 (§0.4 of `req066-api-error-response.md`). A
future endpoint's own store/list function (e.g. `Letflow.Engine`'s list
queries) must derive its tenant scope **exclusively** from the
already-authenticated request context — REQ-072's resolved tenant context,
not yet implemented, referenced here only as the intended future caller, not
implemented or stubbed by this requirement — and must treat `cursor.inner` as
a fully opaque byte string it is not permitted to parse for anything other
than its own already-known sort-key/pagination fields (matching the Zig
source's own comment at `pagination.zig:63`: *"Callers do not interpret this —
they pass it to their store/list function"*).

**Consequence for TEST-DESIGNER (AC5):** because `Cursor.inner` structurally
cannot carry a tenant identity, a cursor minted while "scoped" to tenant A and
replayed against a request scoped to tenant B cannot leak tenant A's rows
*through the cursor* — the only way tenant scope enters a query is the
caller's own request-context parameter, never anything this module decodes.
The test this requirement's design owes TEST-DESIGNER is: build a raw cursor
payload via `build_raw_cursor/3`, decode it via `decode_cursor/4` (this
succeeds regardless of which tenant "produced" it, since decode has no tenant
concept at all), then hand `cursor.inner` to a **test-fixture** store/list
function that takes its own separate `tenant_scope` parameter derived
independently of the cursor, called once scoped to tenant B — and assert the
returned rows are all tenant B's, never tenant A's. The fixture store
function itself is TEST-DESIGNER's to write (this module ships no store/list
function of its own, per the scope boundary in §3); this design's contribution
is that `decode_cursor/4`'s return type gives that fixture nothing to
misuse.

## 1. Constants

```
@max_page_size     200          # pos_integer()
@default_page_size 50           # pos_integer()
@min_page_size     1            # pos_integer()
@cursor_expiry_us  86_400_000_000  # pos_integer(), 24h in microseconds
```

PROVENANCE (historical, not current decision authority):
Ported exactly as `pagination.zig` declares them (lines 18/21/24/27) — no
rounding, no re-derivation from a "24 * 3600 * 1_000_000" expression, matching
the handoff's explicit instruction to port the literal constants.

Public accessors (so AC1's "asserted against a named module attribute rather
than a literal buried in a function" is checkable from outside the module
without `@max_page_size`-style attribute access, which only compiles inside
the defining module):

```
@spec max_page_size()     :: pos_integer()   # 200
@spec default_page_size() :: pos_integer()   # 50
@spec min_page_size()     :: pos_integer()   # 1
@spec cursor_expiry_us()  :: pos_integer()   # 86_400_000_000
```

Each accessor's body is exactly its module attribute, nothing computed — a
test asserts e.g. `Pagination.max_page_size() == 200` and separately asserts
`validate_page_size(201) == {:error, :page_size_too_large}`, so the constant
and the behavior that depends on it are checked independently (AC1 requires
this decoupling explicitly: "rather than a literal buried in a function").

## 2. Core types

### 2.1 `Cursor`

```
defstruct [:inner]

@type t :: %__MODULE__{inner: binary()}
```

PROVENANCE (historical, not current decision authority):
Ports `pagination.zig`'s `Cursor` struct (lines 61-72) minus its
allocator/`deinit` fields — Elixir has no caller-managed allocator or manual
`free`, so `allocator` and `deinit/1` are dropped entirely (BEAM garbage
collection makes them meaningless to port, not merely simplified). **`inner`
is the only field** — see §0.3 for why this is the structural INV-1/INV-5
enforcement mechanism, not merely a documented convention.

### 2.2 Page response envelope

```
defmodule Letflow.Api.Pagination.Page do
  @derive {Jason.Encoder, only: [:items, :next_cursor, :count]}
  defstruct [:items, :next_cursor, count: 0]

  @type t(item) :: %__MODULE__{
          items: [item],
          next_cursor: String.t() | nil,
          count: non_neg_integer()
        }
end
```

PROVENANCE (historical, not current decision authority):
Ports `PageResponse(comptime T: type)` (lines 78-87) — Elixir has no generics,
so `Page.t(item)` is a parameterised `@type` (a documentation-only type
parameter, same technique Elixir's own `Enumerable.t()` uses), not a runtime
distinction. Serialises to exactly the shape `pagination.zig`'s own doc
comment specifies: `{"items": [...], "next_cursor": "<base64url>" | null,
"count": N}`.

```
@spec page_response([item], String.t() | nil) :: Letflow.Api.Pagination.Page.t(item) when item: var
```

`page_response/2`'s `count` field is always `length(items)`, computed by the
function — never a separately-suppliable count that could disagree with
`items`'s actual length (there is no `count` parameter to pass a wrong value
through).

## 3. Page-size validation

```
@spec parse_page_size_param(String.t() | nil) ::
        {:ok, pos_integer() | nil} | {:error, :invalid_page_size}

@spec validate_page_size(pos_integer() | nil) ::
        {:ok, pos_integer()} | {:error, :page_size_too_large}
```

- `parse_page_size_param/1` — see §0.1. `nil` → `{:ok, nil}`. A string is
  `{:ok, integer}` only if it parses via `Integer.parse/1` consuming the
  **entire** string with no remainder (mirroring the precedent at
  `lib/letflow/definitions/promotion_conflict.ex:129-130`'s
  `{int, ""} <- Integer.parse(str)` pattern) and the parsed integer is
  non-negative; any other input (non-numeric, decimal point, trailing
  garbage, negative sign) is `{:error, :invalid_page_size}`.
- `validate_page_size/1` — ports `validatePageSize/1` (§0.2) exactly:
  `nil` → `{:ok, @default_page_size}`; `0` → `{:error,
  :page_size_too_large}`; `> @max_page_size` → `{:error,
  :page_size_too_large}`; otherwise `{:ok, v}`.

Route-handler composition (not this module's own function) is shown in §0.1.

## 4. Cursor encoding

```
@spec encode_cursor(binary()) :: binary()
```

Ports `encodeCursor/2` (lines 115-121). `Base.url_encode64(raw, padding:
false)` — Elixir's builtin base64url encoder, `padding: false` matching
R-Co's `std.base64.url_safe_no_pad.Encoder` exactly (no separate
allocator-failure case to port; `Base.url_encode64/2` cannot fail on a
binary input).

## 5. Cursor decoding — prefix + expiry validation

```
@spec decode_cursor(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
        {:ok, t()}
        | {:error, :invalid_base64}
        | {:error, :wrong_endpoint}
        | {:error, :expired}
        | {:error, :invalid_cursor}
```

Signature: `decode_cursor(encoded, prefix, expiry_ts_offset,
expiry_window_us \\ @cursor_expiry_us)` — the fourth argument defaults to
`@cursor_expiry_us` (24h) so every ordinary call site only supplies the three
arguments that vary per endpoint (`encoded`, `prefix`, `expiry_ts_offset`),
matching how most of R-Co's own call sites are expected to use the 24h
default while still allowing an override for the rare endpoint (or a test)
that needs a different window. Ports `decodeCursor/5` (lines 140-180) minus
the `allocator` parameter (no caller-managed allocation in Elixir) and minus
the `Cursor.deinit`-owning return shape (BEAM GC).

Ports the three checks **in the same order** R-Co performs them, each a
distinct error atom (mirrors `CursorError`'s member set, lines 37-46, minus
`OutOfMemory` — no Elixir analogue, dropped same as REQ-066 dropped Zig's
allocator-failure branches):

PROVENANCE (historical, not current decision authority):
1. **Base64url decode.** `Base.url_decode64(encoded, padding: false)` — `:error`
   (malformed input) → `{:error, :invalid_base64}`.
2. **Prefix match.** `String.starts_with?(decoded, prefix)` — `false`, or
   `byte_size(decoded) < byte_size(prefix)`, → `{:error, :wrong_endpoint}`.
   This is the check that makes a cursor minted by one endpoint (e.g. a
   `"T:"`-prefixed task-list cursor) unusable against a different endpoint
   (e.g. an `"I:"`-prefixed instance-list cursor) — AC3.
3. **Expiry check.** Extract the decimal microsecond timestamp starting at
   byte offset `expiry_ts_offset` in `decoded`, ending at the next `:` byte
   or end-of-string (mirrors `pagination.zig:164-169`'s
   `std.mem.indexOfScalar(u8, ts_slice, ':')` / `ts_slice.len` fallback and
   `std.fmt.parseInt`). If that slice fails to parse as an integer, or
   `expiry_ts_offset >= byte_size(decoded)`, or the slice is empty (offset
   lands exactly on a `:`) → `{:error, :invalid_cursor}` (ports
   `pagination.zig`'s three `error.InvalidBase64`-returning malformed-offset
   branches at lines 161/167/169 under one atom — see the note below on why
   this design gives them their own atom rather than reusing
   `:invalid_base64`). Otherwise compute `now_us = System.system_time(:microsecond)`
   (this module's port of `currentMicrosecondTimestamp/0`, §5.1) and if
   `now_us - ts > expiry_window_us` → `{:error, :expired}` (AC4). Otherwise
   proceed to build the `Cursor`.

PROVENANCE (historical, not current decision authority):
**Deliberate atom-naming divergence, flagged rather than silently ported.**
`pagination.zig` reuses `error.InvalidBase64` for three different failure
modes: genuinely malformed base64 (check 1), and two malformed-timestamp-slice
cases inside check 3 (offset past the end of the decoded string; an empty
digit slice). This design gives those a distinct atom,
`:invalid_cursor`, instead of reusing `:invalid_base64` for a failure that has
nothing to do with base64 decoding — a decoded-but-then-malformed cursor is a
different failure class from an encoding that never decoded at all, and
conflating them under one atom would make route-handler error messages
misleading (`"page_size must be..."`-style precision, applied to cursors).
Behaviorally this is a strict no-op divergence (both cases are still a 400 at
the HTTP layer, exactly as `pagination.zig`'s error set collapses to one HTTP
status regardless), so it does not change any acceptance criterion — flagged
here per this project's "state divergences explicitly" rule, and open for
CODE-DESIGN-VALIDATOR/REVIEWER to overrule back to a single
`:invalid_base64` atom if consistency-with-source outweighs this reasoning.

On success: `{:ok, %Cursor{inner: decoded}}`.

### 5.1 Wall-clock time

PROVENANCE (historical, not current decision authority):
No standalone function is ported for `currentMicrosecondTimestamp/0` (lines
254-273) — Elixir's `System.system_time(:microsecond)` is a one-line BEAM
builtin with no OS-specific branching to hide behind a private helper, unlike
Zig's Windows/POSIX branch. It is called directly inside `decode_cursor/4`'s
body. Same purity boundary R-Co's own comment states (`pagination.zig:256-257`,
"permitted in the API handler layer only — never called from
src/engine/transition.zig or any pure-function module") applies here
unchanged: `Letflow.Api.Pagination` is API-layer code, and this module's
public functions are the only place in the pagination path allowed to read
wall-clock time. `Letflow.Engine.Transition` (or any pure S2/S3 module) must
never call `decode_cursor/4` for its time-reading side effect or take a
dependency on this module for anything but building/reading cursor payloads
handed to it as plain binaries by an API-layer caller.

## 6. Encode-side raw-payload builders

```
@spec build_raw_cursor(String.t(), integer(), String.t()) :: binary()
@spec build_raw_cursor_timestamp_key(String.t(), integer(), String.t(), integer()) :: binary()
```

Port `buildRawCursor/4` (lines 193-200) and `buildRawCursorTimestampKey/5`
(lines 210-222) minus their `allocator` parameter. Exact formats, ported
verbatim (`<<>>`/interpolation-built binaries, not implemented here — shape
only):

- `build_raw_cursor(prefix, timestamp_us, key)` → `"#{prefix}#{timestamp_us}:#{key}"`,
  e.g. `"T:1716412800000000:abc123"`.
- `build_raw_cursor_timestamp_key(prefix, sort_timestamp_us, key, cursor_created_at_us)`
  → `"#{prefix}#{sort_timestamp_us}:#{key}:#{cursor_created_at_us}"`, e.g.
  `"I:1716412800000000:abc123:1716412860000000"`.

These are the encode-side counterpart `encode_cursor/1` wraps: a caller builds
the raw payload with one of these two, then calls `encode_cursor/1` on the
result to get the opaque base64url string handed to the HTTP client as
`next_cursor`.

## 7. Cursor-payload parsing utilities

```
@spec parse_int_from_cursor(binary(), non_neg_integer(), non_neg_integer()) ::
        {:ok, integer()} | {:error, :invalid_cursor}

@spec find_nth_colon(binary(), pos_integer()) :: non_neg_integer() | nil
```

PROVENANCE (historical, not current decision authority):
Port `parseIntFromCursor/3` (lines 227-235) and `findNthColon/2` (lines
239-248) verbatim in shape. `parse_int_from_cursor/3` extracts a decimal `i64`
(Elixir: unbounded `integer()`) from `decoded[offset, len]`;
`offset + len > byte_size(decoded)` or a non-digit-only slice →
`{:error, :invalid_cursor}` (ports `CursorParseError.InvalidCursor`, line 51).
`find_nth_colon/2` returns the zero-indexed byte position of the `n`-th `:`
in `slice` (1-indexed `n`, matching `pagination.zig`'s own 1-indexing), or
`nil` if fewer than `n` colons exist. These are the utilities an endpoint's
own store/list function uses to pull its own sort-key fields (the parts after
the prefix and timestamp) out of `cursor.inner` — this module does not
interpret those fields itself, per §0.3's opacity requirement.

## 8. Error-tuple shapes (summary)

PROVENANCE (historical, not current decision authority):
| Function | Success | Errors |
|---|---|---|
| `parse_page_size_param/1` | `{:ok, pos_integer() \| nil}` | `{:error, :invalid_page_size}` |
| `validate_page_size/1` | `{:ok, pos_integer()}` | `{:error, :page_size_too_large}` |
| `decode_cursor/4` | `{:ok, t()}` | `{:error, :invalid_base64}` \| `{:error, :wrong_endpoint}` \| `{:error, :expired}` \| `{:error, :invalid_cursor}` |
| `parse_int_from_cursor/3` | `{:ok, integer()}` | `{:error, :invalid_cursor}` |
| `encode_cursor/1` | `binary()` (cannot fail) | — |
| `build_raw_cursor/3`, `build_raw_cursor_timestamp_key/4` | `binary()` (cannot fail) | — |
| `find_nth_colon/2` | `non_neg_integer() \| nil` (not a tuple — mirrors `pagination.zig`'s own `?usize` return, which is not an error union either) | — |
| `page_response/2` | `Page.t(item)` (cannot fail) | — |

No function in this module raises on well-typed input; every fallible
operation returns a tagged tuple, per `docs/agents/instructions/
security-invariants.md`'s INV-8 (no unhandled crashes on realistic failure
paths — cursor/page-size values are caller-controlled, network-facing
input).

## 9. Data / DB / cross-module

**No DB schema changes.** This module is pure — no `Ecto.Schema`, no
migration, no `Repo` call anywhere in it. It never itself reads or writes a
tenant-scoped table; it only encodes/decodes an opaque payload string.

**Cross-module dependencies:**
- `Base` (Elixir stdlib) — `encode_cursor/1`, `decode_cursor/4`'s step 1.
- `Integer` (Elixir stdlib) — `parse_page_size_param/1`, `parse_int_from_cursor/3`.
- `System` (Elixir stdlib) — `decode_cursor/4`'s wall-clock read (§5.1).
- `Jason` (existing dependency, via `@derive`) — `Page`'s JSON encoding.
- Consumed by: every future S4 list-route handler (REQ-073 onward) and,
  indirectly through the route-handler `else` clause shown in §0.1, by
  `Letflow.Api.Error`/`Letflow.Api.Response` (REQ-066) — this module itself
  never calls either.
- Intended future caller of the tenant-scoping guarantee in §0.3: REQ-072's
  resolved tenant-scoped request context. Not implemented or stubbed here.

**Scope boundary, stated explicitly (same pattern as REQ-056/REQ-078's
boundary paragraphs):** this requirement ships the shared
encode/decode/validate/response-envelope module only. It does **not** ship
any concrete list endpoint, any concrete store/list Ecto query, or REQ-072's
tenant-context resolution — those are separate, later requirements that will
depend on this module's public functions.

## 10. Invariants (restated compactly)

PROVENANCE (historical, not current decision authority):
- **INV-1 / INV-5 (structural, not conventional).** `Cursor.t()` has exactly
  one field, `inner :: binary()`. No `tenant_id`, `schema`, or `prefix` field
  exists on the struct — there is no slot a decoded cursor could populate to
  widen or redirect a query's tenant scope. Tenant scoping is exclusively the
  caller's own request-context parameter (REQ-072), never anything this
  module decodes. See §0.3 for the full statement and the test property this
  gives TEST-DESIGNER (AC5).
- **Prefix validation (AC3).** `decode_cursor/4`'s step 2 rejects any decoded
  value not starting with the caller-supplied `prefix` literal with
  `{:error, :wrong_endpoint}` — a cursor minted by one endpoint's prefix
  cannot be replayed against a different endpoint's `decode_cursor/4` call.
- **Expiry (AC4).** `decode_cursor/4`'s step 3 rejects any cursor whose
  embedded timestamp is more than `expiry_window_us` (default
  `@cursor_expiry_us`, 24h) older than `System.system_time(:microsecond)` with
  `{:error, :expired}`. Testable without waiting: build a raw cursor via
  `build_raw_cursor/3` with an old `timestamp_us` literal, encode it, decode
  it — the real current time minus that old literal already exceeds the
  window.
- **Reject, not clamp (AC2).** `validate_page_size/1` never rounds an
  out-of-range value to a bound; every 0, every `> 200` is `{:error,
  :page_size_too_large}`. `parse_page_size_param/1` separately rejects
  non-numeric input as `{:error, :invalid_page_size}` — see §0.1 for exactly
  where in the pipeline this lives and §0.2 for the flagged 400-vs-422
  divergence from `pagination.zig`'s own doc comment.
- **Constants ported verbatim (AC1).** §1's four values, each independently
  assertable via a public accessor function, not just a private attribute.
- **No-dup/no-gap paging (AC6).** Not a property this module's functions
  enforce by themselves — it is a joint property of (a) an endpoint's own
  query using a strictly monotonic sort key as the cursor's `key`/`ts_us`
  field, and (b) this module's round-trip fidelity:
  `decode_cursor(encode_cursor(raw), ...).inner == raw` for any well-formed
  `raw` this module itself built via `build_raw_cursor/3` or
  `build_raw_cursor_timestamp_key/4`, and not otherwise corrupted in transit.
  This module's contribution to AC6 is guaranteeing that round trip;
  TEST-DESIGNER's three-successive-pages test (using a test-fixture in-memory
  store, since no concrete store/list function ships with this requirement,
  per §9's scope boundary) is what actually demonstrates no dup/gap across
  pages.

## 11. Open questions (not silently resolved)

1. **Combined `parse_page_size_param/1` + `validate_page_size/1` convenience
   function?** §0.1 keeps them separate, mirroring the Zig source's own
   separation of concerns (implicit type boundary vs. explicit range check).
   A single `fetch_page_size(String.t() | nil) :: {:ok, pos_integer()} |
   {:error, :invalid_page_size} | {:error, :page_size_too_large}` would save
   one `with` step per call site at the cost of the two concerns being
   harder to test independently. Left to CODE-DESIGN-VALIDATOR/REVIEWER;
   either shape satisfies AC2 as written.
PROVENANCE (historical, not current decision authority):
2. **400 vs. 422 for page-size rejection (§0.2).** This design follows the
   requirement dispatch's explicit 400 instruction over `pagination.zig`'s own
   comment saying 422. Flagged for REVIEWER to confirm this reading of the
   dispatch is correct before ELIXIR-DEV wires the route-handler `else`
   clause to `Response.bad_request/2`.
PROVENANCE (historical, not current decision authority):
3. **`:invalid_cursor` vs. reusing `:invalid_base64` for malformed-timestamp-
   slice failures inside `decode_cursor/4` (§5).** This design splits them;
   `pagination.zig` conflates them under one Zig error. Behaviorally a no-op
   (both are the same HTTP status either way) — flagged in case
   CODE-DESIGN-VALIDATOR prefers exact atom-for-atom parity with the Zig
   error set instead.
4. **`expiry_window_us` default argument vs. required 4th positional
   argument on `decode_cursor/4`.** This design defaults it to
   `@cursor_expiry_us` (§5). If CODE-DESIGN-VALIDATOR prefers every call site
   to state the window explicitly (no implicit default), that is a one-line
   signature change with no other design impact.
