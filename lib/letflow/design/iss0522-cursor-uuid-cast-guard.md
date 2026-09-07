# ISS-0522 — safe-cast guard for a cursor's own binary_id component

Design for the fix to ISS-0522. Diagnosis: step-01 (ISSUE-FIXER), this session
(`WF03-ISS0522-20260907`). No implementation code below — new function
signature, `@spec` deltas, and clause-shape description only.

## 0. Restating the defect, independently re-verified against source

Read directly (not taken on ISSUE-FIXER's word):

- `lib/letflow/entities/definitions.ex` lines 297-346 (`list_definitions/2`,
  `filter_by_list_definitions_cursor/2`, `decode_list_definitions_cursor/1`,
  `decode_list_definitions_seek/1`).
- `lib/letflow/api/pagination.ex` in full (382 lines) — confirms INV-8/INV-9
  live here and confirms `decode_cursor/4`'s own contract already returns
  tagged tuples for every network-facing failure it itself can detect.

Confirmed: `decode_list_definitions_seek/1` (definitions.ex:340-346) does

```
[_mint_time_us_str, id_str, inserted_at_us_str] = String.split(rest, ":", parts: 3)
inserted_at = DateTime.from_unix!(String.to_integer(inserted_at_us_str), :microsecond)
{inserted_at, id_str}
```

`id_str` is returned **unchecked** — no `Ecto.UUID.cast/1`, no format
assertion. `decode_list_definitions_cursor/1` (definitions.ex:323-334) wraps
this unconditionally as `{:ok, decode_list_definitions_seek(cursor)}`
(line 329) — there is no failure arm for a malformed `id_str`, because
`decode_list_definitions_seek/1` cannot itself fail today (its own crash
mode, `String.to_integer/1` on a non-numeric `inserted_at_us_str`, is a
*separate*, pre-existing gap not in scope here — see §4). `list_definitions/2`'s
`with` chain (line 297-313) then treats `cursor_seek` as trusted and passes it
into `filter_by_list_definitions_cursor/2` (line 317-319), which pins the raw
string into `where: {e.inserted_at, e.id} < {^inserted_at, ^id_str}` against
`EntityDefinition.id`, typed `:binary_id`. `Repo.all/2` (line 307) then raises
`Ecto.Query.CastError` for any `id_str` that isn't a valid UUID string —
outside every `with`-chain error arm, unhandled. Confirmed matches
ISSUE-FIXER's reproduction.

Also confirmed independently: `lib/letflow/entities/query/cursor.ex` does not
exist in this checkout (`git log --all -- lib/letflow/entities/query/cursor.ex`
returns nothing; no worktree has it; only an unrelated
`lib/letflow/ordering/cursor.ex` exists). REQ-231 is `status: pending` in
`docs/requirements.yaml`. ISS-0522's own title/description claim "2 call
sites" — this is currently false; there is exactly **one** real call site.
See §4.

## 1. The new helper

**Module: `Letflow.Api.Pagination`.** Confirmed the right home: INV-8/INV-9
already live in this module's moduledoc as the project's one place that
states "every fallible operation returns a tagged tuple" for cursor-adjacent
input, `parse_int_from_cursor/3` already exists here as the established
precedent for "a helper an endpoint's own store/list function uses to pull
*its own* sort-key/domain field out of `cursor.inner`, returning a tagged
tuple instead of raising" (moduledoc §7, lines 341-343) — a UUID-shaped
domain field is the same category of thing, just a different Ecto primitive
type than the integer `parse_int_from_cursor/3` already handles. No new
module needed; this is squarely inside the existing module's stated
responsibility, not a scope stretch.

```
@doc """
Casts a cursor-payload substring expected to be an Ecto :binary_id (UUID)
component into its binary form, or rejects it. Companion to
parse_int_from_cursor/3 (§7) for the binary_id case: an endpoint's own
store/list function uses this to validate a domain field parsed out of
cursor.inner before pinning it into a query against a :binary_id column --
this module never interprets cursor.inner's domain fields on its own
(design §0.3 is unchanged by this addition).
"""
@spec cast_binary_id_component(String.t()) ::
        {:ok, Ecto.UUID.t()} | {:error, :invalid_cursor}
def cast_binary_id_component(component) when is_binary(component)
def cast_binary_id_component(_component)  # non-binary input, same error
```

Contract:

- Input: the raw substring pulled out of a decoded cursor payload (e.g.
  `id_str` in `decode_list_definitions_seek/1`) — a `String.t()`, but not
  guaranteed to actually be one at the call site's type level since it comes
  from `String.split/3` on caller-controlled bytes, so the function accepts
  any term and returns `{:error, :invalid_cursor}` for non-binary input
  rather than pattern-match-failing.
- Success: `{:ok, uuid_binary}` — delegates to `Ecto.UUID.cast/1`, which
  already returns `{:ok, binary} | :error` for exactly this "is this a
  syntactically valid UUID string" question; this helper's only job is
  translating `Ecto.UUID.cast/1`'s bare `:error` into this module's
  established `{:error, :invalid_cursor}` shape, matching the atom
  `decode_list_definitions_cursor/1`'s own `else` clause already uses for
  every other cursor-shaped failure (definitions.ex:332) — no new atom
  introduced.
- Failure: `{:error, :invalid_cursor}` for anything `Ecto.UUID.cast/1`
  rejects, or for non-binary input.
- **Does not raise** — this is exactly INV-8's stated scope ("cursor/page-size
  values are caller-controlled, network-facing input" — moduledoc lines
  27-29): an `id_str` parsed out of a decoded cursor is network-facing input
  in the same sense the rest of the cursor payload is, unlike ISS-0216's
  `prefix` (which is caller-internal configuration). This helper therefore
  follows the tagged-tuple pattern, not the `raise` pattern ISS-0216 chose —
  the two fixes are not the same shape, because the two inputs are not the
  same trust category.

Placement: alongside `parse_int_from_cursor/3` and `find_nth_colon/2` in the
"Cursor-payload parsing utilities (§7)" section, since it's the same kind of
utility (a per-field decode a call site's own list function uses on its own
domain slice of `cursor.inner`) — not new module machinery, no interaction
with `decode_cursor/4`'s own `with` chain.

## 2. `decode_list_definitions_seek/1` and its caller

### 2.1 `decode_list_definitions_seek/1` — return-type change

Current: always returns a bare `{inserted_at, id_str}` tuple (never an error
tuple) — the `[_mint, id_str, inserted_at_us_str] = String.split(...)` match
and `DateTime.from_unix!/2` calls are its only two failure modes today, both
of which currently raise rather than return.

New contract (this fix addresses the `id_str` component only — see §4 for
what stays unaddressed):

```
@spec decode_list_definitions_seek(Pagination.Cursor.t()) ::
        {:ok, {DateTime.t(), Ecto.UUID.t()}} | {:error, :invalid_cursor}
```

Body shape: after the existing `String.split/3` produces `id_str`, call
`Pagination.cast_binary_id_component(id_str)`; on `{:ok, id}` return
`{:ok, {inserted_at, id}}`; on `{:error, :invalid_cursor}` return that tuple
unchanged (pass-through, no new atom). The existing `DateTime.from_unix!/2`
call is unchanged in this fix (see §4) — it still runs before the new cast
and still raises on its own malformed input, which is a distinct,
out-of-scope gap.

### 2.2 `decode_list_definitions_cursor/1` — propagation

Current body (definitions.ex:323-334):

```
case Pagination.decode_cursor(raw, @list_definitions_cursor_prefix, byte_size(@list_definitions_cursor_prefix)) do
  {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_list_definitions_seek(cursor)}
  {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
  {:error, :expired} -> {:error, :expired}
  {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
end
```

Change: the first branch's right-hand side changes from
`{:ok, decode_list_definitions_seek(cursor)}` (which always wraps in `:ok`,
now wrong since `decode_list_definitions_seek/1` can itself fail) to
`decode_list_definitions_seek(cursor)` directly — i.e. that branch now
returns whatever `decode_list_definitions_seek/1` itself returns
(`{:ok, {inserted_at, id}} | {:error, :invalid_cursor}`), since that function
now already produces the correctly-shaped tuple. `decode_list_definitions_cursor/1`'s
own `@spec` (currently undocumented/private, no explicit `@spec` in the
source read) is unchanged in surface shape — it already returns
`{:ok, term} | {:error, :wrong_endpoint} | {:error, :expired} |
{:error, :invalid_cursor}`; only the set of paths that can now reach
`{:error, :invalid_cursor}` grows.

### 2.3 `list_definitions/2` — no change needed

Its `with` chain (line 297-313) already has
`{:ok, cursor_seek} <- decode_list_definitions_cursor(Map.get(filters, :cursor))`
as one clause; when that now returns `{:error, :invalid_cursor}` instead of
raising, the `with` construct's implicit `else` (absent here, so the
non-matching value is returned as-is per Elixir `with` semantics) makes
`list_definitions/2` itself return `{:error, :invalid_cursor}` directly —
**this is already in `list_definitions/2`'s own documented `@spec`**
(definitions.ex line 296: `| {:error, :invalid_cursor}` is already listed).
So the full propagation path is: `Ecto.UUID.cast/1` (via the new helper) →
`decode_list_definitions_seek/1` → `decode_list_definitions_cursor/1` →
`list_definitions/2`'s existing `with` short-circuit → the already-declared
`{:error, :invalid_cursor}` return. No `@spec` change to `list_definitions/2`
itself; no route-handler change (route handlers translating `list_definitions/2`
error atoms into problem documents already have a clause for
`:invalid_cursor`, per the moduledoc's stated division of responsibility
between this module and `Letflow.Api.Error`/`Letflow.Api.Response`). This
matches the ISS-0216 precedent's own note that `:invalid_cursor` is the
module's established atom for "the decoded payload doesn't parse the way
this endpoint expects," which is exactly this case.

## 3. What this design does NOT fix, and why

1. **`lib/letflow/entities/query/cursor.ex` does not exist.** ISS-0522's own
   description names it as the REQ-231 call site. REQ-231 is still `pending`
   in `docs/requirements.yaml` — there is no code there to change. This
   design touches only `definitions.ex` and `pagination.ex`. **ISS-0522's
   "2 call sites" framing is currently inaccurate** (only 1 real site exists
   today); this should be corrected in the issue's own resolution note by
   ISSUE-FIXER at WF-03 Step 5, not silently absorbed here.
2. **`Pagination.cast_binary_id_component/1`'s contract is intentionally
   designed for reuse.** When REQ-231 is eventually implemented and
   `Letflow.Entities.Query.Cursor` (or whatever module REQ-231 actually
   introduces) needs to parse its own `binary_id` cursor component, it should
   call this same helper rather than re-deriving an `Ecto.UUID.cast/1`
   wrapper — this is the "shared, reusable safe-decode helper" ISS-0522 asks
   for, landed now against the one site that actually exists, ready for the
   second site whenever it exists.
3. **`decode_list_definitions_seek/1`'s `DateTime.from_unix!/2` and the
   `String.split/3` pattern match above it are unchanged and still raise** on
   a malformed `inserted_at_us_str` or a cursor body with fewer than 3
   colon-separated parts. This is a real, separate gap (same "unhandled raise
   on malformed cursor component" category ISS-0522 names) but is a different
   defect than the one ISS-0522's diagnosis reproduced (`id_str`/binary_id,
   not the timestamp component) — flagged here as an open question (§5) for
   CODE-DESIGN-VALIDATOR/REVIEWER rather than silently folded into this fix's
   scope, since ISS-0522's own reproduction and title are specifically about
   the binary_id-cast raise.

## 4. Test-ability

TEST-DESIGNER should cover, at minimum:

1. **The new helper directly** (`Letflow.Api.PaginationTest` or wherever
   `parse_int_from_cursor/3` is already tested, same file):
   - `cast_binary_id_component/1` with a valid UUID string → `{:ok, binary}`
     matching `Ecto.UUID.cast/1`'s own success shape.
   - with a non-UUID string (e.g. `"not-a-uuid"`, empty string, a string with
     valid UUID length but non-hex characters) → `{:error, :invalid_cursor}`.
   - with a non-binary argument (if reachable/relevant) → `{:error, :invalid_cursor}`.
2. **End-to-end via `list_definitions/2`** (mirrors ISSUE-FIXER's own
   reproduction, now asserting a return value instead of a raise): build a
   raw cursor via `Pagination.build_raw_cursor_timestamp_key/4` under
   `@list_definitions_cursor_prefix` with a non-UUID string in the `id`
   position, encode it via `Pagination.encode_cursor/1`, call
   `list_definitions(%{cursor: encoded_cursor}, tenant_prefix)`, and assert
   `{:error, :invalid_cursor}` — explicitly **not** `assert_raise`, since this
   fix's whole point is that no raise reaches the caller. Must NOT reach
   `Repo.all/2`/`Ecto.Query.CastError` at all (a regression here means the
   fix didn't actually short-circuit before the query).
3. **Non-regression**: a valid cursor (valid UUID `id` component, valid
   timestamp) through `list_definitions/2` still returns
   `{:ok, %Pagination.Page{}}` unchanged — the existing REQ-226/067 cursor
   round-trip tests must still pass.

## 5. Open questions (not silently resolved)

1. **Should this fix also guard `decode_list_definitions_seek/1`'s
   `String.split/3` pattern match and `DateTime.from_unix!/2` call** (§3.3)?
   Out of scope per ISS-0522's own reproduction and title (binary_id cast,
   not timestamp parsing), but it is the same defect *category* and lives in
   the same three-line function this fix is already touching. Flagged for
   CODE-DESIGN-VALIDATOR/REVIEWER to decide whether to fold in now (cheap,
   same function) or file as its own follow-up issue.
2. **Whether `cast_binary_id_component/1` should accept only `String.t()`
   per its `@spec`, or explicitly guard non-binary input with its own
   clause** (as drafted in §1) versus letting a non-binary argument be a
   type-contract violation left to Dialyzer (the ISS-0216 precedent's
   reasoning for *not* guarding `decode_cursor/4`'s `prefix` against
   non-binary input doesn't directly transfer here, since `id_str` — unlike
   `prefix` — is derived from caller-controlled bytes via `String.split/3`,
   which always yields binaries, making the non-binary case likely
   unreachable in practice). This design includes the guard defensively;
   CODE-DESIGN-VALIDATOR may drop it as dead code if judged unreachable.
