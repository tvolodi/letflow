# Design: REQ-231 — Entity query DSL: keyset-pagination cursor codec and field-grant row-level redaction (query/cursor.zig + field_grants.zig)

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-231's full entry (scope items 1–2, the five
  acceptance criteria, `depends_on: [REQ-230]`, the explicit NOT-IN-SCOPE
  note on operator/allowlist/compiler logic and route/controller), and
  REQ-230's entry for the originating split context.
- `handoffs/WF02-REQ231-20260907/step-00-git-setup.json` — task framing,
  names `Letflow.Api.Authorization` explicitly as the module this design
  must read before answering the open design question.
- **`lib/letflow/api/authorization.ex` (REQ-069), read in full** — see §6.1
  for the researched answer this reading produced.
- `lib/letflow/secrets/redaction.ex` (REQ-190) — the only other
  redaction-shaped mechanism in the codebase; read in full, see §6.2 for
  why its *sentinel convention* is reused here even though its *matching
  mechanism* (a global, identity-blind, key-name denylist) is not.
- `test/support/tenant_fixture.ex`'s `@expected_tenant_tables` (lines
  123–163) — confirms no `entity_field_restrictions`/`user_entity_grants`-
  shaped table, nor any other per-field/per-user grant table, exists in the
  tenant schema today. The only RBAC-adjacent tables present are `groups`,
  `group_members`, `tenant_role`, `users` — all read below (§6.1).
- `lib/letflow/identity/group.ex`, `lib/letflow/identity/tenant_role.ex` —
  read in full; both are name/role *registry* tables (a group has a name, a
  tenant_role links a name to a group), with no field-name or entity-type
  column on either, and no row-level or attribute-level grant concept.
- `lib/letflow/identity/user.ex` — `users.id` is `:binary_id`
  (`@primary_key {:id, :binary_id, autogenerate: true}`), the type
  `user_entity_grants.user_id` (§6.3) is defined against.
- `lib/letflow/api/pagination.ex` (REQ-067) — read in full. This is
  Letflow's actual cursor-pagination contract (not R-Co's `pagination.zig`
  directly — `Letflow.Api.Pagination` is the already-ported, in-repo
  module every other paginated listing calls). Its `Cursor`/`Page` structs,
  `encode_cursor/1`/`decode_cursor/4`, `build_raw_cursor/3`/
  `build_raw_cursor_timestamp_key/4`, `parse_int_from_cursor/3`,
  `find_nth_colon/2`, page-size validation, and the INV-1/INV-5/INV-9
  guarantees stated in its moduledoc are all reused or extended here — see
  §2 for the exact fit and where this design must diverge (generic sort
  key vs. the fixed `inserted_at desc, id desc` shape).
- `lib/letflow/entities/definitions.ex` lines 277–362
  (`list_definitions/2` and its private cursor helpers) — REQ-226's own
  concrete consumer of `Letflow.Api.Pagination`, read in full as the
  worked example the task explicitly pointed to. Confirms the pattern this
  design generalizes: a per-listing cursor prefix constant (`"ED:"`), a
  cursor payload of `"<prefix><mint_time_us>:<id>:<inserted_at_us>"` built
  via `build_raw_cursor_timestamp_key/4`, a `WHERE (sort_col, id) <
  (^val, ^id)` resume filter, `LIMIT page_size + 1` with the extra row
  trimmed off to decide whether a `next_cursor` is minted, and tenant
  scoping enforced structurally by the per-tenant Postgres schema (`prefix`
  in `Repo.all(query, prefix: prefix)`), never by anything the cursor
  itself carries. §2 is this design's generalization of that exact shape
  to an arbitrary, caller-chosen `sort` clause list.
- `lib/letflow/entities/query/types.ex`, `allowlist.ex`, `compiler.ex`
  (REQ-230, already merged) — read in full. `Types.query_request()`'s
  `sort :: [sort_clause()]` (each `%{field: String.t(), dir: sort_dir()}`)
  is the input this design's cursor must be able to resume against for
  **any** allowlisted field, not just `inserted_at`. `Allowlist.allowlisted_field()`
  (`name`, `source :: :typed_column | :json_field`, `type`, `enum_values`)
  is what tells this design how to encode/decode a given sort field's
  resume value. `Compiler.compile/2` returns an unexecuted `Ecto.Query.t()`
  scoped to `Letflow.Entities.Record.Latest`, filtered by `entity_type` and
  the request's own filter clauses, with `order_by` already applied from
  `sort` — this design's `Cursor` module takes that query and adds the
  resume-filter + tiebreak-order + limit on top (§2.4), it does not
  re-derive filtering/sorting itself.
- `lib/letflow/entities/record/latest.ex` (REQ-228) — `entity_record_latest`'s
  actual columns (`id` binary_id PK, `entity_type`, `record_id`,
  `field_values` JSONB map, `deleted`, `entity_def_version`,
  `last_event_global_seq`, `inserted_at`/`updated_at`), confirming `id` is
  the only column guaranteed unique-and-total-ordered per row, hence this
  design's choice of `id` as the universal tiebreaker (§2.3).
- `lib/letflow/design/req230-entity-query-dsl-compiler.md` — read in full
  for house style (section numbering, "Sources read," error-taxonomy
  table, "Open questions," "Traceability" sections) and as the direct
  sibling design this one continues from. Its own §9 "Open questions" item
  4 restates REQ-231's field-grant open question verbatim, confirming
  REQ-230's own design pass deliberately deferred it here rather than
  guessing.
- `lib/letflow/design/iss0438-entity-subsystem-scoping.md` §6 item 4 — the
  original scoping note that first flagged this open question, confirming
  it did **not** read the authorization modules and explicitly deferred
  the read to "slice 6's own design pass" (this document).
- `docs/anti-patterns.md` — checked for existing entries on cursor/pagination
  or redaction; none apply beyond the `fragment/1` literal entry already
  addressed by REQ-230 (not this design's concern).

## 1. Scope (from REQ-231's own text, restated)

1. `cursor.zig`-equivalent: a keyset-pagination cursor codec for entity
   query results, matching REQ-067's existing `Letflow.Api.Pagination`
   contract, generalized to an arbitrary caller-chosen `sort` clause list
   (REQ-230's compiler supports sorting by any allowlisted field or
   fields, not a fixed `inserted_at desc, id desc` shape).
2. `field_grants.zig`-equivalent: a per-user, per-entity-type/field
   access-control loader that redacts specific fields from a query result
   row (not the whole row), per QRY-05.
3. Answer, from an actual reading of Letflow's existing authorization
   modules, whether field-grant redaction maps onto an existing primitive
   or needs new tables (§6).

**Not in this design:** operator/allowlist/compiler logic (REQ-230,
already shipped — this design only *consumes* `Types`/`Allowlist`/
`Compiler`); any route or controller (same deferral REQ-230 states, "no
consumer contract" — `Letflow.Routers.EntityQuery` remains deferred).

## 2. `Letflow.Entities.Query.Cursor` — the cursor codec

### 2.1 Why REQ-067's own helper functions cannot be reused unmodified

`Letflow.Api.Pagination.build_raw_cursor_timestamp_key/4` and
`parse_int_from_cursor/3`/`find_nth_colon/2` assume a **single** resume key
(one string or one integer) at a fixed colon-delimited offset — exactly
what `list_definitions/2`'s fixed `inserted_at desc, id desc` shape needs
and no more. REQ-230's compiler accepts a `sort :: [sort_clause()]` of
**arbitrary length**, over fields whose `Allowlist.allowlisted_field().type`
can be any of `Letflow.Entities.Definition.field_type()`'s six values
(`:string | :integer | :decimal | :boolean | :date | :datetime`, plus
`:enum` treated as `:string` for ordering purposes) — a fixed
"`<int>:<string>`" slot layout cannot represent that. This design therefore
defines its own raw-payload shape (§2.2) while still reusing
`Letflow.Api.Pagination`'s **outer envelope** verbatim: `encode_cursor/1`,
`decode_cursor/4`'s prefix+expiry check, `Cursor.t()`'s single-`inner`-field
opacity guarantee (INV-1/INV-5, moduledoc), and `Page.t()`/`page_response/2`
for the response envelope. Nothing about REQ-067's *security* contract
changes; only the *domain-payload* format inside `Cursor.inner`'s tail
(after the mint-time timestamp REQ-067's own expiry check reads) is new,
exactly the same freedom `list_definitions/2`'s own private cursor helpers
already exercise (design §0 — `Pagination`'s moduledoc §0.3: "an endpoint's
own store/list function... pulls its own sort-key fields out of
`cursor.inner`... this module never interprets those fields itself").

### 2.2 Raw payload shape

`Letflow.Entities.Query.Cursor.cursor_prefix/0` returns the fixed literal
`"EQ:"` (Entity Query), a sibling of `list_definitions/2`'s `"ED:"`,
distinct so a cursor minted by one listing can never decode successfully
against the other (REQ-067's `:wrong_endpoint` check, §2.1 reused as-is).

The raw payload, before base64url-encoding, is:

`"<prefix><mint_time_us>:<resume_key_json>"`

where `<mint_time_us>` is `System.system_time(:microsecond)` at mint time
(the same first-slot-after-prefix convention `list_definitions/2` uses, so
`decode_cursor/4`'s `expiry_ts_offset` argument is always
`byte_size(prefix)` and its 24h `cursor_expiry_us/0` default applies
unchanged), and `<resume_key_json>` is a JSON-encoded (via `Jason`, the
dependency this project already uses for every other API-facing JSON
encode/decode) array of exactly `length(sort) + 1` entries: one entry per
`sort_clause()` in the request's own order, each carrying that field's
resume value in the same JSON-native representation
`Letflow.Entities.Record.Latest.field_values` itself already stores
JSONB values in (string, number, boolean, or an ISO-8601 string for
`:date`/`:datetime`), followed by one final entry which is always the last
row's `id` (the `entity_record_latest` UUID primary key) as a string — the
universal tiebreaker (§2.3). `<resume_key_json>` never carries a field
*name* or *type* — see §2.3 for why that is a deliberate omission, not an
oversight.

### 2.3 Tiebreaker and resume-filter composition — why no field name/type travels in the cursor

Multiple distinct rows in `entity_record_latest` can share an identical
tuple of sort-field values (e.g. two records both created in the same
microsecond with the same value in every sorted field) — without a final,
strictly-monotonic tiebreaker, keyset pagination over an arbitrary sort can
silently skip or repeat rows exactly the way REQ-231's own acceptance
criterion 1 forbids. `id` (the `entity_record_latest` binary UUID primary
key) is appended as an implicit final ascending sort key to every compiled
query this module executes, **in addition to** whatever `sort` the caller
specified — this is `Cursor`'s own addition on top of `Compiler.compile/2`'s
returned query, not a change to `Compiler`/`Allowlist` (which remain
exactly REQ-230's shipped scope).

The resume filter this module builds from a decoded cursor is the standard
row-wise (lexicographic) keyset comparison over the same ordered tuple:
given sort clauses `s1..sn` with directions `d1..dn` and resume values
`v1..vn` plus tiebreak `(id, v_id)`, the filter is the row-comparison
`(f1, f2, ..., fn, id) </> (v1, v2, ..., vn, v_id)`, where each `</>` is
`<` if that position's direction is `:desc` or `>` if `:asc` — Postgres's
native row-comparison semantics (the same `{col1, col2} < {val1, val2}`
tuple-comparison idiom `list_definitions/2`'s own
`filter_by_list_definitions_cursor/2` already uses for its two-column
case, generalized here to `n + 1` columns via `Ecto.Query.dynamic/2`
composed left-to-right rather than a literal tuple, since Ecto's fragment
syntax cannot itself parameterize over a runtime-variable tuple arity).
**Field name/type do not need to travel inside the cursor** because the
decoded resume values are positionally re-paired against the *caller's own
resent* `sort` list on the next request (the same list REQ-230's
`Allowlist.resolve_field/2` re-validates from scratch on every call, since
the compiler is stateless and re-runs its full three-layer defence on
every invocation) — position `i` in `<resume_key_json>`'s array always
corresponds to position `i` in that request's `sort`. A caller who submits
a *different* `sort` order/length than the one that minted the cursor
produces `{:error, :resume_key_arity_mismatch}` (§2.5) rather than a
silently wrong resume point — this module never trusts the decoded JSON's
own shape to imply what the fields were.

### 2.4 Module responsibility and signature

`Letflow.Entities.Query.Cursor` owns both the codec (§2.2–2.3) and the
query-composition step that consumes `Compiler.compile/2`'s output — this
mirrors `list_definitions/2`'s own undivided responsibility (that function
also owns its cursor helpers and its query composition together, not
split across two modules), and keeps `Compiler`/`Allowlist` (REQ-230,
already reviewed and merged) completely unchanged.

`@type resume_key :: [term()]` — the decoded, positionally-ordered list of
`length(sort) + 1` JSON-native values described in §2.2, still in raw
decoded form (no type-casting against `Allowlist` field types performed
yet — that happens when the resume filter is built, per field type, the
same per-`field_type()` cast dispatch `Compiler.build_filter_dynamic/2`
already performs for JSON-field comparisons, reused here rather than
duplicated).

`@spec paginate(request :: Types.query_request(), compiled_query ::
Ecto.Query.t(), allowlist :: Allowlist.allowlist(), opts :: %{optional(:cursor) => String.t() | nil, optional(:page_size) => pos_integer() | nil}, prefix :: String.t()) :: {:ok, Pagination.Page.t(Latest.t())} | {:error, :page_size_too_large} | {:error, :invalid_cursor} | {:error, :wrong_endpoint} | {:error, :expired} | {:error, :resume_key_arity_mismatch} | {:error, {:field_not_allowed, String.t()}}`

Step order, mirroring `list_definitions/2`'s own `with` chain: (1)
`Pagination.validate_page_size/1` on `opts.page_size`; (2) decode
`opts.cursor` via `Pagination.decode_cursor/4` with this module's own
`cursor_prefix/0` and JSON-parse the tail into a `resume_key()`, per §2.2;
(3) re-resolve every `sort_clause().field` against `allowlist` (the same
`Allowlist.resolve_field/2` the compiler already used to build
`compiled_query`'s own `ORDER BY` — re-resolved here only to learn each
field's `type()` and `source()` for building the typed resume-filter
comparison, not to re-validate the compiler's own filter/sort compilation,
which already happened before this function was called); (4) if a decoded
`resume_key()` is present, check `length(resume_key) ==
length(sort) + 1`, `{:error, :resume_key_arity_mismatch}` otherwise; (5)
build the row-wise resume filter (§2.3) and add it to `compiled_query` via
`Ecto.Query.where/3`, add the implicit `id` tiebreak order (§2.3) via
`Ecto.Query.order_by/3`, add `Ecto.Query.limit/2` of `page_size + 1`; (6)
`Repo.all(query, prefix: prefix)`, split off the possible extra row per
`list_definitions/2`'s own `split_list_definitions_page/2` idiom, and — if
a next page exists — mint the next cursor by JSON-encoding the last row's
own resolved sort-field values (re-read off the returned struct/row, per
field `source()`: `Map.fetch!(row, column_atom)` for `:typed_column`,
`Map.fetch!(row.field_values, field_name)` for `:json_field`) plus its
`id`, through `Pagination.build_raw_cursor/3` (prefix + mint_time_us +
JSON key) and `Pagination.encode_cursor/1`.

### 2.5 Error taxonomy addition

| Error | Meaning |
|---|---|
| `{:error, :resume_key_arity_mismatch}` | A decoded cursor's resume-key array length does not equal `length(sort) + 1` for the `sort` list the caller resent alongside the cursor — the caller changed their sort shape between the minting request and the resume request. |

All of REQ-067's own `decode_cursor/4` errors (`:invalid_base64` mapped to
`:invalid_cursor` exactly as `list_definitions/2`'s own
`decode_list_definitions_cursor/1` already does, `:wrong_endpoint`,
`:expired`) and `Pagination.validate_page_size/1`'s `:page_size_too_large`
pass through unchanged. A field-resolution failure at step 3 (§2.4)
returns `Allowlist.resolve_field/2`'s own `{:error, {:field_not_allowed,
_}}` — this can only happen if the caller's resent `sort` names a field no
longer in that entity type's current allowlist (e.g. the entity definition
changed between requests), not a cursor-payload defect.

## 3. `Letflow.Entities.Query.FieldGrants` — per-field row-level redaction

### 3.1 The open design question — researched answer

**Decision: field-grant redaction needs two new, dedicated tenant-schema
tables. It does not map onto any existing Letflow authorization/RBAC
primitive.** This is not a default guess — it follows from reading the two
candidate mechanisms in full:

**`Letflow.Api.Authorization` (REQ-069, `lib/letflow/api/authorization.ex`,
read in full for this design).** Its entire contract is coarse,
route/action-level, all-or-nothing: `evaluate_access/2` takes an
`AccessContext.t()` (`user_id`, `roles`) and an `endpoint_policy_key()`
(one atom per HTTP-method+path-template pair, per `endpoint_policy_key/2`'s
own match clauses) and returns exactly one of `:Allow`, `:Deny403`, or
`:AllowWithRowFilter` — and even that third kind's only payload,
`task_row_scope() :: :all | {:own_user_and_groups, user_id}`, is a
**whole-row** filter for exactly one endpoint (`:TasksList`, gated by
`is_task_worker_only?/1`), never a per-column or per-field concept. The
module's own moduledoc states this is structural, not incidental: INV-2's
own text is "there is no third parameter through which request-derived
data... could reach this function," so `evaluate_access/2` could not be
extended to accept "which field" as an input without breaking the pure,
two-argument contract INV-2 names as load-bearing. There is no `field`,
`column`, or per-entity-type concept anywhere in `role/0`, `permission/0`,
or `endpoint_policy_key/0`'s closed enums, and the eighteen `permission/0`
atoms (`DefinitionsRead`, `InstancesRead`, `AttachmentsRead`, etc.) are all
resource-*category*-level, never resource-*attribute*-level. This module
answers "can this user call this endpoint at all," never "which columns of
this endpoint's response may this user see" — a materially different
question REQ-231's QRY-05 redaction needs answered.

**`Letflow.Secrets.Redaction` (REQ-190, `lib/letflow/secrets/redaction.ex`,
read in full for this design).** The other candidate the task's own
research step named. Its `redact_map/1` is a **global, identity-blind**
key-name denylist applied uniformly to every log event's metadata map — it
has no `user_id` parameter at all, no per-tenant or per-entity-type
configuration, and no data-driven grant/restriction table backing it (its
`@sensitive_exact_keys`/`@sensitive_suffixes` are compile-time module
attributes, not rows in any table). It redacts because a key *name*
matches a fixed denylist, never because *this specific caller* lacks
*this specific field's* grant. It is architecturally the wrong shape for
QRY-05 (which must vary per user and per entity type/field, not
uniformly for everyone), but its **sentinel-vs-omission convention**
("the key itself is always kept, unmodified... the corresponding value
with the literal string `[REDACTED]`") is reused for §3.4's mechanism
choice below, since it is the one existing in-repo precedent for "redact a
field's value while keeping its key visible," and there is no reason to
invent a second, different convention when one already exists and fits.

**`groups`/`group_members`/`tenant_role`/`users`
(`test/support/tenant_fixture.ex`'s `@expected_tenant_tables`, and
`lib/letflow/identity/group.ex`/`tenant_role.ex`/`user.ex`, all read in
full).** These are name/role *registry* tables — `groups` has `name`,
`display_name`, `description`; `tenant_role` links a `name` to a
`group_id`; neither has a `field_name`, `entity_type`, or any per-attribute
column, nor any row representing "this identity may/may not see this
specific data field." There is no existing table in the tenant schema this
mechanism could be grafted onto without adding new columns that would
change those tables' own already-reviewed, already-migrated shape for an
unrelated concern.

**Conclusion:** no existing Letflow primitive — neither the pure,
two-argument, endpoint-level `Letflow.Api.Authorization`, nor the
identity-blind `Letflow.Secrets.Redaction`, nor any RBAC-adjacent registry
table — represents "may user U see entity-type T's field F." QRY-05 is a
genuinely new access-control axis (per-user, per-entity-type, per-field),
and needs two new, dedicated tenant-schema tables, named per R-Co's own
naming (`entity_field_restrictions`, `user_entity_grants`) since that
naming is already accurate to the two-table default-deny-with-override
shape this design settles on (§3.2) and this project's own convention
(REQ-230's `Compiler`/`Allowlist`, REQ-228's `Latest`) is to keep a ported
table's R-Co name unless a concrete Letflow-side reason argues otherwise —
none does here.

### 3.2 Grant model — default-deny-with-explicit-override

Two tables, both tenant-scoped (live in the per-tenant Postgres schema,
same isolation mechanism as every other Decision-B table in this
subsystem — no `tenant_id` column needed on either, matching
`entity_definitions`/`entity_record_latest`'s own schema-per-tenant
scoping, not `users`/`groups`'s belt-and-suspenders `tenant_id` column
precedent, since these two tables are pure-tenant-schema data with no
cross-tenant registry counterpart to reconcile against):

- **`entity_field_restrictions`** — one row per `(entity_type, field_name)`
  pair that is, by default, hidden from every user unless that user holds
  a matching `user_entity_grants` row. Columns: `id` (binary_id PK),
  `entity_type` (string, matches `Types.query_request().entity_type`
  values — no FK to `entity_definitions` since a restriction can be
  declared before an entity type's active definition version exists, the
  same "queries by string name, not by definition row" convention
  `Allowlist.load/2` itself already uses), `field_name` (string — an
  entity-definition-declared field name, checked against that entity
  type's *current* allowlist only at grant-authoring time, not at
  redaction time, since redaction must degrade gracefully rather than
  error out if a definition's fields changed after a restriction was
  declared — see §3.5), `inserted_at`/`updated_at`. Unique index on
  `(entity_type, field_name)` — a field is either restricted or not, never
  restricted "twice."
- **`user_entity_grants`** — one row per `(user_id, entity_type,
  field_name)` triple that lifts a matching `entity_field_restrictions`
  row for exactly that one user. Columns: `id` (binary_id PK), `user_id`
  (`:binary_id`, FK to `users.id` — matches `users.id`'s own
  `:binary_id` primary key type read in §0), `entity_type` (string, same
  convention as above), `field_name` (string), `inserted_at`. Unique index
  on `(user_id, entity_type, field_name)`.

A field with **no** `entity_field_restrictions` row is visible to every
user unconditionally — `user_entity_grants` never needs a row for a field
nobody restricted (this is the "default allow, restrict by exception,
override the exception per user" shape R-Co's own naming already implies:
"restrictions" name the default-deny set, "grants" name the per-user
lift). A restricted field's *absence* from a given user's
`user_entity_grants` rows is exactly that user's redaction set for that
entity type.

### 3.3 Why not model this as a new `permission/0` atom instead

A tempting alternative — add one coarse `:EntityFieldsRead` permission to
`Letflow.Api.Authorization` and gate the *entire* redaction mechanism
behind "does this role hold that permission" — was considered and
rejected: QRY-05's own acceptance criterion 2 requires **two users with
the same role** to see different redaction outcomes ("a user holding a
field-level restriction... has that field redacted... while a user
*without* that restriction sees the field populated" — both users could
easily share every one of `Letflow.Api.Authorization`'s five roles). Since
`role_allows?/2` is a pure function of `role()` alone (§0's reading of
`lib/letflow/api/authorization.ex` lines 502–549), no permutation of
`Letflow.Api.Authorization`'s existing types can express a *per-user*
(not per-role) grant without changing that module's own closed,
already-reviewed contract — which this design declines to do, consistent
with this project's "don't silently re-decide what a decision record
already settled" rule (`CLAUDE.md`) applied here to REQ-069's own
already-merged, already-security-reviewed design.

### 3.4 Redaction mechanism — sentinel value, key retained

**Chosen mechanism: for each restricted-and-not-granted field, the key
stays present in the returned `field_values` map, and its value is
replaced by a fixed sentinel** — the same "key retained, value replaced"
convention `Letflow.Secrets.Redaction.redact_map/1` already establishes
project-wide (§3.1). The sentinel is the atom `:__field_redacted__`
(distinct from `Letflow.Secrets.Redaction`'s own `"[REDACTED]"` **string**
literal deliberately: a JSONB-sourced `field_values` map can legitimately
contain the literal string `"[REDACTED]"` as real business data typed by
an end user into a `:string` field, which `Letflow.Secrets.Redaction`'s
log-metadata use case never needs to worry about since log metadata is
not itself arbitrary tenant business data — an atom sentinel cannot
collide with any JSON-decoded value, since JSON has no atom type and
`field_values` is always decoded from JSONB through `Jason`, which never
produces a bare Elixir atom other than `nil`/`true`/`false`).

**Rejected alternative — omit the key entirely:** rejected because
omission is ambiguous with "this record's `field_values` never had this
key set" (a field left unset on a particular record, or absent because an
older `entity_def_version`'s schema didn't declare it) — the caller
cannot distinguish "no data" from "data exists, you may not see it" from
an omitted key alone, whereas a present key with the redaction sentinel
states the second case unambiguously, matching the reasoning
`Letflow.Secrets.Redaction`'s own moduledoc gives for retaining the key
("The key itself is always kept, unmodified").

**Rejected alternative — null the value:** rejected for the same
ambiguity reason as omission — `field_values`'s own JSONB values can be
genuinely `nil` for an optional entity-definition field the record simply
never set, so a caller could not distinguish a real `nil` from a redacted
one.

**Scope of what is redactable:** only `:json_field`-sourced fields (an
`Allowlist.allowlisted_field().source == :json_field`, i.e. an
entity-definition-declared business field actually living inside
`field_values`) are eligible for an `entity_field_restrictions` row.
`:typed_column`-sourced fields (`entity_type`, `record_id`, `deleted`,
`entity_def_version`, `last_event_global_seq`, `inserted_at`/`updated_at`
— `Allowlist.typed_columns/0`'s fixed table, REQ-230 §3.3) are structural
metadata every caller with read access to the row needs to interpret it
at all (e.g. a caller cannot page or de-duplicate results without `id`/
`inserted_at`, and cannot tell a soft-deleted record apart from a live one
without `deleted`) — this design does not make them eligible for
field-grant restriction, and `entity_field_restrictions.field_name`
insertion should be validated by its own owning command module (deferred
— no such command module exists yet; this design only specifies the
tables and the redaction read path) against exactly the set
`Allowlist.load/2` reports as `:json_field`-sourced for that entity type.

### 3.5 Loader and redaction function signatures

`@type restriction_set :: MapSet.t(String.t())` — the set of `field_name`
values redacted for one `(user_id, entity_type)` pair, already resolved
(restrictions minus that user's own grants).

`@spec load_restrictions(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) :: {:ok, restriction_set()} | {:error, :invalid_schema_name}`

Computes `entity_field_restrictions` rows for `entity_type` whose
`field_name` has no matching `user_entity_grants` row for `(user_id,
entity_type, field_name)` — a single query (an `Ecto.Query` anti-join:
`entity_field_restrictions` `LEFT JOIN user_entity_grants` on all three
key columns `WHERE user_entity_grants.id IS NULL`), scoped to the tenant
schema named by `prefix`, matching every other tenant-scoped query in this
subsystem's `Repo.all(query, prefix: prefix)` convention. Returns
`MapSet.new([])` (never an error) when `entity_type` has no restricted
fields at all — an entity type with zero `entity_field_restrictions` rows
is not an error condition, it is the common case.

`@spec redact_field_values(field_values :: map(), restriction_set()) :: map()`

Pure, no I/O: for each `field_name` in `restriction_set` that is also a
key of `field_values` (a restriction naming a field the current entity
definition version no longer declares, or that this particular record
never set, is simply a no-op for that key — §3.2's "checked at
grant-authoring time, not at redaction time" note), replaces that key's
value with `:__field_redacted__` (§3.4); every other key is passed through
unchanged. Never raises — a `restriction_set` naming a field absent from
`field_values` is not an error, per the no-op rule just stated.

`@spec redact_page(page :: Pagination.Page.t(Latest.t()), restriction_set()) :: Pagination.Page.t(Latest.t())`

Maps `redact_field_values/2` over every row's own `field_values`,
returning a new `Page.t()` with the same `next_cursor`/`count` and each
item's `field_values` redacted — the composition point where §2's
`Cursor.paginate/5` output and this section's `load_restrictions/3` output
meet, most naturally invoked by a future orchestrating function (deferred,
same "no consumer contract" reasoning as the route/controller, §1) by
passing `Cursor.paginate/5`'s resulting page straight into `redact_page/2`
alongside that user's own `restriction_set()`.

## 4. Module naming under `Letflow.Entities.Query.*`

`Letflow.Entities.Query.Cursor` and `Letflow.Entities.Query.FieldGrants` —
both single-word nouns naming *what the module is* (a cursor codec, a
field-grants loader/redactor), exactly the naming register REQ-230 already
established for this namespace's three siblings: `Types` (the enums/request
shape), `Allowlist` (the per-tenant field resolver), `Compiler` (the SQL
compiler) — none of REQ-230's three names are verb phrases or
R-Co-filename-derived (`types`/`allowlist`/`compiler` happen to match
`types.zig`/`allowlist.zig`/`compiler.zig`'s own stems, but that is because
those stems already read as plain English nouns; `cursor.zig`/
`field_grants.zig` read the same way — `Cursor`, and `FieldGrants` rather
than the literal `Field_grants`/`FieldGrant`, since Elixir module names are
PascalCase over the underlying concept, not a transliterated filename, and
"grants" (plural) matches this design's own two-table, per-row-grant model
better than a singular `FieldGrant` would).

## 5. Confirmed non-goals (scope boundary)

- No changes to `Letflow.Entities.Query.Types`, `Allowlist`, or `Compiler`
  (REQ-230, already reviewed and merged) — `Cursor`/`FieldGrants` are pure
  additions that consume those modules' existing, unchanged output types.
- No route or controller — `Letflow.Routers.EntityQuery` remains deferred,
  same as REQ-230 states.
- No command/mutation path for authoring `entity_field_restrictions`/
  `user_entity_grants` rows (an admin-facing "grant field access" endpoint)
  — this design specifies the tables and the read-side loader/redactor
  only; a future requirement owns the write path, the same deferral
  pattern `Allowlist`'s own read-only `load/2` already established for
  REQ-230 relative to entity-definition *authoring* (REQ-225/226 own
  that).
- No change to `Letflow.Api.Authorization` — §3.3 states explicitly why
  this design does not add a new permission atom there.

## 6. Open questions

None remaining for this slice's own scope — the question REQ-231's text
named explicitly (§3.1) has been researched and answered. One question is
deferred, not silently resolved, to the future write-path requirement
named in §5: whether authoring an `entity_field_restrictions`/
`user_entity_grants` row should itself be gated by a new
`Letflow.Api.Authorization` permission (e.g. `:EntityFieldGrantsManage`) —
that is a question about *writing* grants, which is out of this
read-path-only design's scope (§5), not about the redaction mechanism
itself.

## 7. Traceability — acceptance criteria to design elements

| # | Acceptance criterion | Design element |
|---|---|---|
| 1 | A query result set larger than one page returns a `next_cursor`; passing it back returns the next distinct page with no repeated/skipped records (REQ-067's contract) | §2 whole section — codec (§2.2), tiebreak+resume-filter composition (§2.3), `paginate/5` (§2.4) |
| 2 | A user holding a field-level restriction has that field redacted (not the whole row); a user without it sees the field populated — two explicit tests | §3.2 (grant model), §3.4 (mechanism), §3.5 (`load_restrictions/3`/`redact_field_values/2`/`redact_page/2`) — the two tests are, respectively, a user with no matching `user_entity_grants` row and a user with one, against the same `entity_field_restrictions` row |
| 3 | The design artefact states whether field-level grants reuse an existing primitive or need new tables, and names which module was read | §3.1, in full — states the new-tables conclusion, names `Letflow.Api.Authorization` (REQ-069) and `Letflow.Secrets.Redaction` (REQ-190) as the modules read, and states what each was found to lack |
| 4 | No route or controller file added or modified | §1 "Not in this design," §5 |
| 5 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | Implementation-phase (ELIXIR-DEV) concern — this design imposes no construct that would be untestable or would warn (no unused aliases beyond what §2.4/§3.5's signatures already name as used) |
