# Design: REQ-017 — Pure claim-mapping module (OIDC-08 equivalent)

PROVENANCE (historical, not current decision authority):
**Requirement:** REQ-017 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact `Letflow.Oidc.IdentityContext` struct shape, the
exact `Letflow.Oidc.ClaimMapping` module's function signatures, the exact
`Letflow.Oidc.ClaimMappingConfig` shape and its config-sourcing mechanism, every
defaulting rule cited against `claim_mapping.zig`'s actual source, and the one error
case's exact shape. No implementation code — no `.ex`/`.exs` code blocks with real
function bodies. Snippets below showing Zig source are cited evidence (what
`claim_mapping.zig` actually does), not Elixir code to copy verbatim.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-017 (full entry, `depends_on: []`) — description and all
  four acceptance criteria.
PROVENANCE (historical, not current decision authority):
- `c:\Users\tvolo\dev\ai-dala\R-Co\src\oidc\claim_mapping.zig` **in full** (506 lines) —
  the primary porting source. Read directly, not from the requirement's paraphrase.
- `docs/requirements.yaml` REQ-018, REQ-019, REQ-021 (full entries) — to confirm this
  design's field names match what those already-written requirements expect to consume.
- `lib/letflow/design/req016-oidc-dependency-supervision.md` — REQ-016's design/
  implementation history: the `config :letflow, :oidc` key convention, the
  `Letflow.Oidc.DefaultProvider` placeholder atom (never `defmodule`'d — confirmed no
  `lib/letflow/oidc/` directory exists yet, so this requirement is free to establish that
  namespace for real), and REQ-016's own scope boundary ("No `Ueberauth.Strategy.Oidcc`
  provider/strategy configuration... that is claim-mapping/verification wiring, REQ-017's
  territory").
- `docs/guides/backend_developer_guide.md` §3.5 (error handling — `:ok | {:error,
  term()}` / `{:ok, result} | {:error, reason}`, `@spec` states the error shape
  explicitly) and §3.1 (naming conventions).
- `lib/letflow/identity/user.ex`, `lib/letflow/identity/tenant.ex` — existing
  `@moduledoc`/style conventions to match (cites the R-Co source file(s) ported from,
  states explicitly what is and isn't covered by this module).
- `lib/letflow/process_instance.ex`, `lib/letflow/row_approval.ex` — existing
  `@spec`-first, error-tuple convention precedent (`{:error, term()}` /
  `{:error, :not_found}` style atoms).
- `config/dev.exs` — confirms the existing `config :letflow, :oidc` key
  (`issuer`, `provider_name`) REQ-016 added, and the file's config-block style.
- `docs/migration/stage-1-identity.md` — confirms S1 scope and REVIEWER's cross-decision
  finding (ISS-0007) that Decision B applies to all S1 tables (not directly load-bearing
  here since this requirement introduces no DB table, but read for stage context).

PROVENANCE (historical, not current decision authority):
## 1. Discrepancy check: requirement text vs. actual `claim_mapping.zig` source

**Read in full, not paraphrased.** REQ-017's requirement-text summary is accurate against
the actual source with **one clarification worth flagging explicitly** (not a
contradiction, but a gap the requirement text glosses over):

- The requirement text describes the mapping function as taking "verified OIDC claims (as
  returned by ueberauth_oidcc's callback)" as its input. The actual Zig source's
  `mapVerifiedClaims` takes **two separate arguments**: `subject: []const u8` (the `sub`
  claim, passed independently) **and** `raw_claims_json: []const u8` (the full decoded JWT
  payload, as a **JSON string** the function itself parses via `std.json.parseFromSlice`).
  This split exists because Zig's `mapVerifiedClaims` does its own JSON parsing as part of
  the "no I/O" pure function (parsing a string is not I/O; it's computation). In Elixir,
  `ueberauth_oidcc`'s callback already hands back claims as a **parsed map** (via the
  `oidcc`/`jose` JWT-decoding pipeline it wraps), not a raw JSON string — there is no
  re-parse step in the Elixir port, and no `std.json`-equivalent parse-error case exists
  in Elixir's version. §4 below states this port decision explicitly (function takes
  `subject` and an already-parsed `claims` map, not a JSON string) rather than silently
  reproducing Zig's JSON-string parameter shape, since re-serializing an already-parsed
  Elixir map back to a JSON string just to re-parse it inside the ported function would be
  pointless I/O-adjacent busywork with no invariant it protects.
  - **Consequence for the error set:** Zig's `MappingError` includes
    `ClaimPathMalformed` and `ClaimTypeMismatch` (see §2's error-set citation) — these
    exist to cover JSON-parse-time and path-resolution-time failure modes specific to
    walking a freshly-parsed `std.json.Value` tree with a possibly-malformed path string.
    Since Elixir's port takes an already-map-shaped `claims` argument (no string parse
    step, and path resolution never raises — `resolveJsonPath`'s Elixir equivalent
    returns `nil` on any resolution failure, matching Zig's own `orelse return null`
    behavior at every call site — see §5), **neither of these two error cases has an
    Elixir equivalent that can actually occur**. §3 states this as the resolved decision:
    the Elixir `MappingError` set is `{:sub_claim_missing}` only, not a direct 1:1 port of
    Zig's four-member error set. This is a case where the actual Zig source, read in
    full, changes the design from what "port the error cases" might have suggested — this
    is the "no discrepancy in requirement text vs. source" case that still surfaces a
    real design decision to state explicitly, per the task's instruction to verify
    against real source rather than trust the paraphrase alone.
- Everything else in REQ-017's requirement-text summary (the six `IdentityContext` fields
  and their names, the five configurable claim paths and their names, the five defaulting
  rules, the one `sub`-missing error case) **matches the actual source exactly** — no
  further discrepancy found. This does **not** repeat ISS-0001/ISS-0002's pattern of a
  stale requirement-text citation; REQ-017's text was evidently drafted directly against
  this source.

PROVENANCE (historical, not current decision authority):
## 2. `claim_mapping.zig`'s actual error sets (cited, not paraphrased)

Two separate error sets exist in the source — conflating them would be a real bug, so
naming both explicitly:

```zig
/// Errors that can occur when loading configuration from the database.
pub const ClaimMappingError = error{
    RealmConfigNotFound,
    PoolExhausted,
    ConfigParseFailed,
    OutOfMemory,
};

/// Errors that can occur during the pure mapping function.
pub const MappingError = error{
    SubClaimMissing,
    ClaimPathMalformed,
    ClaimTypeMismatch,
    OutOfMemory,
};
```

`ClaimMappingError` belongs to `loadClaimMappingConfig` — the **I/O-performing**
config-loading function (queries a `realm_claim_mapping_config` table). This function is
**explicitly out of REQ-017's scope**: REQ-017's description says per-realm config is
"sourced from application config for now (a DB-backed per-realm config table is not
required for this requirement)". So `ClaimMappingConfig`'s DB-loading error set has no
Elixir equivalent to build in this requirement — noted so nobody mistakes
`ClaimMappingError`'s four members as something this design needs to port.

`MappingError` belongs to `mapVerifiedClaims` — the pure function this requirement
actually ports. Per §1's finding, only `SubClaimMissing` has a reachable Elixir
equivalent; see §3.

## 3. Elixir error shape (established, not left implicit)

No prior fallible **pure** function exists in this codebase to imitate exactly (the
existing `{:error, term()}` precedents — `process_instance.ex`, `row_approval.ex` — are
all `gen_statem`/DB-backed, not pure). This design **establishes** the convention for
`Letflow.Oidc.ClaimMapping`, following `backend_developer_guide.md` §3.5's existing
project-wide rule (`@spec` states the error shape explicitly; `{:ok, result} |
{:error, reason}` shape) and the existing atom-tag style
(`row_approval.ex`'s `{:error, :not_found}` — a bare descriptive atom, not a generic
`term()`, when the error case is a single known condition):

```
@type mapping_error :: :sub_claim_missing
```

`map_verified_claims/3` returns `{:ok, IdentityContext.t()} | {:error, :sub_claim_missing}`.
Only one error atom exists because, per §1's finding, Zig's `ClaimPathMalformed` and
`ClaimTypeMismatch` have no reachable Elixir equivalent given the already-parsed-map input
shape this port uses — not because they were dropped carelessly. If a future requirement
changes the input shape back to a raw JSON string (unlikely — `ueberauth_oidcc` does not
hand back raw JSON), that future requirement would need to reintroduce a parse-error case;
not anticipated speculatively here (YAGNI, consistent with REQ-016 design precedent's own
reasoning style in its §9).

`OutOfMemory` (present in Zig's `MappingError`) has no Elixir equivalent at all — the BEAM
does not surface allocation failure as a function return value; an actual OOM condition
kills the process/node, which is not a case any Elixir `@spec` models. Not carried over,
and not a discrepancy — this is an artifact of Zig's manual-allocator model with no
BEAM-side counterpart.

## 4. `Letflow.Oidc.ClaimMappingConfig` — config struct shape

PROVENANCE (historical, not current decision authority):
Ported from `claim_mapping.zig`'s `ClaimMappingConfig` (lines 55-62, cited below), with
the JSON-string-vs-map distinction from §1 folded in and Elixir-idiomatic types
substituted for Zig's `[]const u8`/`[]const []const u8`:

```zig
pub const ClaimMappingConfig = struct {
    realm: []const u8,
    tenant_id_claim: []const u8,
    roles_claim_paths: []const []const u8,
    email_claim: []const u8,
    preferred_username_claim: []const u8,
    display_name_claim: []const u8,
};
```

**Elixir shape** — a plain `defstruct` (reasoning in §6 below covers both structs;
config gets the same treatment as `IdentityContext` since it is likewise a small,
ephemeral, in-memory-only value with fixed known fields, not a persisted entity):

| Field | Zig source field | Elixir type | Notes |
|---|---|---|---|
| `realm` | `realm` | `String.t()` | The realm this config applies to. Same field name as `IdentityContext.realm` (§5) — REQ-018/019/021 already expect `realm` as the canonical name (per REQ-018's description explicitly warning against inventing an `external_realm`-named struct field — see §8). |
| `tenant_id_claim` | `tenant_id_claim` | `String.t()` | Dot-delimited claim path (e.g. `"tenant_id"` or `"org.tenant_id"`), same path-string convention as Zig's `splitPath` consumes (§5). |
| `roles_claim_paths` | `roles_claim_paths` | `[String.t()]` | **List**, not a single path — Zig tries each path in order, taking the first that resolves to a JSON array (§5). |
| `email_claim` | `email_claim` | `String.t()` | Dot-delimited claim path. |
| `preferred_username_claim` | `preferred_username_claim` | `String.t()` | Dot-delimited claim path. |
| `display_name_claim` | `display_name_claim` | `String.t()` | Dot-delimited claim path. |

`@type t :: %__MODULE__{realm: String.t(), tenant_id_claim: String.t(),
roles_claim_paths: [String.t()], email_claim: String.t(), preferred_username_claim:
String.t(), display_name_claim: String.t()}`

All six fields are required (no field defaults on the struct itself) — a config value
missing one of these fields is a configuration bug to catch at config-read time (§4.1),
not something `map_verified_claims/3` should silently patch with an assumed path string.

### 4.1 Sourcing from application config (not hardcoded)

Per REQ-017's description ("sourced from application config for now") and REQ-016's
established `config :letflow, :oidc` precedent (`config/dev.exs`, cited in §0), this
config is **per-realm** — REQ-016's existing `:oidc` key only has one realm's worth of
keys (`issuer`, `provider_name`), so this requirement adds a **new, distinct** config key
rather than nesting under the existing `:oidc` key, to avoid conflating REQ-016's
provider-worker-startup config (consumed by `Letflow.Application`) with REQ-017's
claim-mapping config (consumed by `Letflow.Oidc.ClaimMapping`) — same separation-of-concern
reasoning REQ-016's design applied when it kept `config :letflow, :oidc` distinct from
`config :ueberauth_oidcc, :issuers`.

**New config key**, added to `config/dev.exs` (and `config/test.exs`, mirroring REQ-016's
precedent of duplicating config across env files since no cross-env config-loading
mechanism exists — see REQ-016 design §5):

```
config :letflow, :oidc_claim_mapping, %{
  "bpm-default" => %{
    tenant_id_claim: "tenant_id",
    roles_claim_paths: ["realm_access.roles", "roles"],
    email_claim: "email",
    preferred_username_claim: "preferred_username",
    display_name_claim: "name"
  }
}
```

Shape: a **map keyed by realm string** (matching Zig's own
`DEFAULT_CLAIM_MAPPING_CONFIG.realm` default of `"bpm-default"` — the same default-tenant
realm value REQ-015/REQ-019 already establish as the pinned default tenant's
`idp_realm_id`), each value being a map of the five claim-path fields (the `realm` field
itself is **not** duplicated inside each value — it is supplied by
`Letflow.Oidc.ClaimMappingConfig.for_realm/1` from the lookup key itself, see the function
signature in §7, avoiding a redundant/potentially-inconsistent second copy of the realm
string inside its own config entry).

A **module-level default fallback** function (`default/0`, §7) mirrors Zig's
`DEFAULT_CLAIM_MAPPING_CONFIG` (lines 87-95, cited below) exactly, for realms with no
explicit config entry:

```zig
pub const DEFAULT_CLAIM_MAPPING_CONFIG: ClaimMappingConfig = .{
    .realm = "",
    .tenant_id_claim = "tenant_id",
    .roles_claim_paths = &.{ "realm_access.roles", "roles" },
    .email_claim = "email",
    .preferred_username_claim = "preferred_username",
    .display_name_claim = "name",
};
```

Elixir's `default/0` returns the same five claim-path values (`tenant_id_claim:
"tenant_id"`, `roles_claim_paths: ["realm_access.roles", "roles"]`, `email_claim:
"email"`, `preferred_username_claim: "preferred_username"`, `display_name_claim: "name"`)
— **with one deliberate deviation from Zig's literal `.realm = ""`**: Elixir's `default/0`
takes the target realm as an argument and populates the returned struct's `realm` field
with that argument, rather than hardcoding an empty string. Zig's `""` default exists
because Zig's `DEFAULT_CLAIM_MAPPING_CONFIG` is a `comptime`-constructed constant with no
way to know the caller's realm ahead of time; Elixir's `for_realm/1` (§7) always knows the
realm being looked up, so threading it through avoids ever constructing an
`IdentityContext` whose `realm` field is an empty string by construction — the empty-realm
case in Zig's constant is a Zig-ism, not a semantic REQ-017 needs to reproduce. Flagged as
an explicit, deliberate deviation, not a silent guess (per this task's "don't silently
resolve" instruction) — **open question OQ-1 in §11 asks CODE-DESIGN-VALIDATOR/REVIEWER to
confirm this deviation is acceptable**, since it is a judgment call rather than a
strictly-forced port decision.

**No DB-backed `realm_claim_mapping_config` table** is built (matches REQ-017's own scope
note and §2's finding that `loadClaimMappingConfig`/`ClaimMappingError` are out of scope) —
noted here again as the deferred item REQ-017's description asks to flag explicitly.

PROVENANCE (historical, not current decision authority):
## 5. Defaulting rules — cited from `claim_mapping.zig`'s actual mapping logic

Per-field, citing the actual Zig code block each rule comes from (lines 240-262 of the
source), not the requirement text's paraphrase:

| Field | Zig source (cited) | Rule |
|---|---|---|
| `email` | `if (resolveJsonPath(root, ep)) \|ev\| blk: { if (ev != .string) break :blk try allocator.dupe(u8, ""); break :blk try allocator.dupe(u8, ev.string); } else try allocator.dupe(u8, "")` | Missing claim **or** claim present but not a string → `""`. Both branches converge on `""` — not just "missing → default", also "wrong type → default" (no error either way). |
| `preferred_username` | `if (resolveJsonPath(root, up)) \|uv\| blk: { if (uv != .string) break :blk try allocator.dupe(u8, subject); break :blk try allocator.dupe(u8, uv.string); } else try allocator.dupe(u8, subject)` | Missing claim **or** wrong-type claim → the `subject` value (i.e. the same value written to `external_user_id`). Same "missing-or-wrong-type" convergence as `email`. |
| `roles` | Loop over `config.roles_claim_paths`, first path where `resolveJsonPath` returns `.array` wins; non-string array elements become `""` (`switch (item) { .string => \|s\| s, else => "" }`); if **no** path resolves to an array, `roles_buf` stays `&.{}` (initialized empty, never reassigned) | Try each configured path in order; first one that resolves to a JSON array is used (non-string elements inside that array silently become empty strings, not dropped — same length preserved); if none resolve to an array at all, → `[]` (empty list, not an error). |
| `display_name` | `if (resolveJsonPath(root, dp)) \|dv\| blk: { if (dv != .string) break :blk null; break :blk try allocator.dupe(u8, dv.string); } else null` | Missing claim **or** wrong-type claim → `nil`. Same convergence pattern again. |
| `tenant_id` | `if (resolveJsonPath(root, tid_path)) \|tv\| blk: { if (tv != .string) break :blk null; break :blk try allocator.dupe(u8, tv.string); } else null` | Missing claim **or** wrong-type claim → `nil`. Same convergence pattern again. |

**Cross-field pattern worth stating explicitly** (not called out separately in the
requirement text, but structurally identical across all five optional fields, confirmed
by reading all five blocks): every optional field's resolution is "missing path → default;
path resolves to wrong JSON type → same default" — type-mismatch is treated identically to
absence, never as a separate error. This is a stronger and more specific statement of
"Key Invariant 3" than the requirement text's paraphrase gives, and ELIXIR-DEV should
implement it as such (a single `resolve_optional_string_claim/3`-shaped helper reused
across `email`/`preferred_username`/`display_name`/`tenant_id`, differing only in their
default value — see §7's helper signature — rather than four independently-hand-written
type checks that could drift from each other).

**`roles` is structurally different** from the other four (it walks a **list** of
candidate paths, not one path, and checks for `.array` rather than `.string`) — do not
force it into the same shared helper as the string-valued fields; §7 gives it its own
helper signature.

`resolveJsonPath`'s own resolution semantics (lines 288-299, cited):

```zig
pub fn resolveJsonPath(document: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = document;
    for (path) |segment| {
        switch (current) {
            .object => |obj| {
                current = obj.get(segment) orelse return null;
            },
            else => return null,
        }
    }
    return current;
}
```

Dot-delimited path, walked segment by segment; any segment that doesn't resolve to an
object-with-that-key (including hitting a non-object mid-path) returns `nil` immediately —
**never raises**. The Elixir port's path-resolution helper (§7) must have the same
total/non-raising behavior: given an Elixir `claims` map (string keys, since that's what
JSON-derived/`ueberauth_oidcc`-derived maps use) and a dot-delimited path string, return
`nil` on any resolution failure, never `raise`.

## 6. `Letflow.Oidc.IdentityContext` — struct shape and struct-vs-map reasoning

PROVENANCE (historical, not current decision authority):
Ported from `claim_mapping.zig`'s `IdentityContext` (lines 65-72, cited below), dropping
the `deinit/2` manual-memory-management function (lines 74-84) entirely — that function
exists only because Zig has no garbage collector; the BEAM's own GC makes it structurally
inapplicable, not an omission to flag as a gap:

```zig
pub const IdentityContext = struct {
    external_user_id: []const u8,
    tenant_id: ?[]const u8,
    realm: []const u8,
    roles: []const []const u8,
    email: []const u8,
    preferred_username: []const u8,
    display_name: ?[]const u8,
};
```

**Elixir shape:**

| Field | Zig source field | Elixir type | Default when claim absent |
|---|---|---|---|
| `external_user_id` | `external_user_id` | `String.t()` | N/A — never defaulted; missing `sub` is the one error case (§3) |
| `tenant_id` | `tenant_id` | `String.t() \| nil` | `nil` |
| `realm` | `realm` | `String.t()` | N/A — always supplied by the caller's `ClaimMappingConfig.realm` (§4), never claim-derived, never defaulted |
| `roles` | `roles` | `[String.t()]` | `[]` |
| `email` | `email` | `String.t()` | `""` |
| `preferred_username` | `preferred_username` | `String.t()` | the `external_user_id` value (i.e. `subject`) |
| `display_name` | `display_name` | `String.t() \| nil` | `nil` |

`@type t :: %__MODULE__{external_user_id: String.t(), tenant_id: String.t() | nil, realm:
String.t(), roles: [String.t()], email: String.t(), preferred_username: String.t(),
display_name: String.t() | nil}`

**Struct-vs-map reasoning (per this task's explicit instruction to state it):** a plain
`defstruct` (`Letflow.Oidc.IdentityContext`, `use` nothing — no `Ecto.Schema`), **not**
an `Ecto.Schema` and **not** a bare map. Reasoning:

- **Not `Ecto.Schema`:** this value never touches the DB directly — REQ-017's own
  acceptance criterion 1 requires zero I/O in the mapping function's call graph, and an
  `Ecto.Schema` module's whole purpose (backing a DB table, supporting `Repo` operations,
  changesets) has no referent here. `IdentityContext` is not itself persisted; REQ-018
  reads specific *fields* off of it to populate `users` table columns (`external_realm`,
  `external_id`, etc.) via its own separate changeset — `IdentityContext` itself is never
  the argument to `Repo.insert`/`Repo.get` anywhere. Reusing `Ecto.Schema` here would
  falsely imply a `identity_contexts` table exists or that this struct supports
  Ecto-changeset validation, neither of which is true, and would pull in
  `Ecto.Schema`'s primary-key/timestamps machinery for a value that has neither.
- **Not a bare map:** REQ-017's own acceptance criteria name six specific, fixed,
  always-present keys (with two of them nullable, not optional-key) — a `defstruct`
  gives compile-time-checkable field names (`%IdentityContext{}.tenant_id` typos raise a
  `KeyError`/`CompileError` at build time via `struct!`-style construction, whereas
  `%{}.tenant_id` or `map.tenent_id` on a bare map either raises only at runtime or,
  worse, silently returns `nil` for a typo'd key that was never meant to be optional).
  Since `IdentityContext` has exactly seven fixed fields (never a variable/open key set —
  unlike, say, `raw_claims_json`/`claims`, which genuinely is an open, provider-defined
  key set and stays a map), a `defstruct` is the correct fit: it is an ephemeral,
  in-memory-only **fixed-shape record**, and `defstruct` is Elixir's idiomatic
  vehicle for exactly that shape, independent of persistence. This also matches
  `docs/agents/instructions` project-wide precedent of preferring compile-time-checkable
  shapes where the field set is known and fixed (same reasoning `row_approval.ex`'s plain
  `Ecto.Schema` — itself not this struct's model, but the general "give a fixed-field
  value its own named type" convention — already establishes elsewhere in this codebase).
- `@enforce_keys` should include all seven fields (all seven are always present on any
  successfully constructed `IdentityContext`, even when a field's value is a default like
  `""`/`nil`/`[]` — "always present, sometimes a default value" is different from
  "sometimes absent from the struct entirely", and `@enforce_keys` communicates that
  distinction directly: this struct is never partially constructed).

## 7. Function signatures

All functions live in `Letflow.Oidc.ClaimMapping` (new module,
`lib/letflow/oidc/claim_mapping.ex`), except the config struct itself
(`Letflow.Oidc.ClaimMappingConfig`, new module, `lib/letflow/oidc/claim_mapping_config.ex`)
and the identity struct (`Letflow.Oidc.IdentityContext`, new module,
`lib/letflow/oidc/identity_context.ex`) — three new files, establishing the
`Letflow.Oidc` namespace for the first time (confirmed empty per §0).

### 7.1 `Letflow.Oidc.IdentityContext`

```
defstruct + @enforce_keys, per §6's field table.
@type t :: %__MODULE__{...}  (per §6)
```

No functions on this module beyond the struct definition itself — it is a pure data
shape, matching Zig's `IdentityContext` minus `deinit/2` (§6).

### 7.2 `Letflow.Oidc.ClaimMappingConfig`

```
@type t :: %__MODULE__{...}  (per §4's field table)

@spec for_realm(realm :: String.t()) :: t()
```
Looks up `realm` in `Application.fetch_env!(:letflow, :oidc_claim_mapping)` (the map
config from §4.1); if the realm key is present, builds a `%ClaimMappingConfig{}` from
that entry's five claim-path fields plus `realm: realm`; if absent, falls back to
`default(realm)` (below). This function itself performs a **config read**
(`Application.fetch_env!/2`), which is **not** claims-mapping I/O (no DB/network call —
reading compiled-in application config is the same category of operation
`req016-oidc-dependency-supervision.md` §6 already treats as non-I/O, e.g.
`Application.get_env(:letflow, :oidc)`) — see §9 for why this keeps
`map_verified_claims/3` itself I/O-free even though `for_realm/1` exists as a
convenience wrapper.

```
@spec default(realm :: String.t()) :: t()
```
Returns the hardcoded five-field default from §4.1 (`tenant_id_claim: "tenant_id"`,
`roles_claim_paths: ["realm_access.roles", "roles"]`, `email_claim: "email"`,
`preferred_username_claim: "preferred_username"`, `display_name_claim: "name"`), with
`realm: realm` (the argument, per §4.1's stated deviation from Zig's literal `.realm =
""`). Pure, no config read, no I/O — usable directly by tests and by `for_realm/1`'s
fallback branch alike.

### 7.3 `Letflow.Oidc.ClaimMapping`

```
@type mapping_error :: :sub_claim_missing

@spec map_verified_claims(
        config :: Letflow.Oidc.ClaimMappingConfig.t(),
        subject :: String.t(),
        claims :: %{optional(String.t()) => term()}
      ) :: {:ok, Letflow.Oidc.IdentityContext.t()} | {:error, mapping_error()}
```
The primary ported function (Zig's `mapVerifiedClaims`, §1's input-shape port decision
applied: `claims` is an already-parsed map, not a JSON string — no `allocator` parameter
either, since Elixir has no manual-allocator equivalent to thread through). Returns
`{:error, :sub_claim_missing}` when `subject` is `""` or (defensively) `nil` — matching
Zig's `if (subject.len == 0) return error.SubClaimMissing` (line 190) check, generalized
to also cover Elixir's `nil` case since `nil` has no Zig-side equivalent to have already
ruled out upstream (Zig's `subject` parameter is a non-optional `[]const u8`, so
Elixir's port must decide independently whether `nil` behaves like empty-string; **this
design's decision: yes, `nil` is treated identically to `""`**, both trigger
`:sub_claim_missing`, since both represent "no usable subject value" and REQ-021's
pipeline wiring should not need to separately guard against passing `nil` through — flag
in §11 as OQ-2 for validator confirmation since it's this design's own extension beyond
what the Zig source explicitly covers, not a silently-resolved guess left unstated).

Zero I/O in this function's own body and everywhere in its call graph — see §9's
explicit call-graph accounting.

```
@spec resolve_claim_path(claims :: %{optional(String.t()) => term()}, path :: String.t()) ::
        term() | nil
```
Elixir port of `resolveJsonPath` + `splitPath` combined (Zig splits the path string once
via `splitPath`, then walks it via `resolveJsonPath` — the Elixir port can fold path-string
splitting and map-walking into one helper, since Elixir has no separate
allocate-then-free step to justify keeping them apart as two functions the way Zig's
manual-memory-management style does). Splits `path` on `.`, walks `claims` segment by
segment; any segment whose current value is not a map, or whose key is absent, returns
`nil` immediately (§5's cited non-raising behavior). Pure, no I/O, never raises.

```
@spec resolve_optional_string_claim(
        claims :: %{optional(String.t()) => term()},
        path :: String.t(),
        default :: String.t() | nil
      ) :: String.t() | nil
```
Shared helper for `email`/`preferred_username`/`display_name`/`tenant_id` (§5's noted
structural commonality): calls `resolve_claim_path/2`; if the result is a binary
(`is_binary/1`), returns it; otherwise (nil, or present-but-wrong-type — number, map,
list, boolean) returns `default` unchanged. This single helper is what makes the
"missing-or-wrong-type both default identically" rule (§5) structurally impossible to get
wrong per-field, rather than four hand-written type checks that could drift.

```
@spec resolve_roles(
        claims :: %{optional(String.t()) => term()},
        paths :: [String.t()]
      ) :: [String.t()]
```
Iterates `paths` in order; for the first path where `resolve_claim_path/2` returns a
list, maps each element to itself if it `is_binary/1`, else `""` (matching Zig's `switch
(item) { .string => |s| s, else => "" }`, line 229-231 — non-string array elements
become empty strings, not dropped, preserving array length), and returns that list
immediately (short-circuit on first array-typed match, matching Zig's `break` on line
234). If no path in `paths` resolves to a list, returns `[]`.

## 8. Field-name cross-check against REQ-018/019/021 (downstream consumers)

Read `docs/requirements.yaml`'s REQ-018/019/021 entries in full (§0) specifically to catch
the realm/external_realm mismatch class of error REQ-VALIDATOR previously caught during
REQ-017's own requirement drafting (per this task's instruction). Confirmed:

- **REQ-018** ("JIT user provisioning"): explicitly states "REQ-017 names its struct field
  `realm`, not `external_realm`; the two are the same value under different names at this
  producer/consumer boundary — struct field -> DB column — so do not assume a struct field
  literally named `external_realm` exists to read from" and "REQ-017's `realm` field is
  the source value written to this table's `external_realm` column." **This design's
  struct field is named `realm`** (§6) — matches. REQ-018's upsert key is
  `(tenant_id, external_realm, external_id)` where `external_realm` <- `IdentityContext.realm`
  and `external_id` <- `IdentityContext.external_user_id`. Both source field names
  (`realm`, `external_user_id`) exist exactly as REQ-018 expects them to.
- **REQ-018** also needs `IdentityContext.tenant_id` — present (§6), nullable, matches
  REQ-018's own "upsert keyed on (tenant_id, ...)" framing (tenant_id is resolved
  separately by REQ-019's realm-ownership guard before REQ-018 is called per REQ-021's
  pipeline order — REQ-017's own `tenant_id` field, sourced from the token's claims per
  §4/§5, is not necessarily the same authoritative value REQ-018 ultimately writes; that
  reconciliation is REQ-019/021's territory, not this design's — noted so it isn't
  mistaken for something REQ-017 needs to resolve itself).
- **REQ-019** ("Tenant<->realm binding"): its realm-ownership guard ("verify the token's
  claimed external_realm actually maps to the request's resolved tenant") consumes
  REQ-017's `realm` field as its input for "the token's claimed external_realm" — same
  field, matches; REQ-019 itself doesn't name a specific struct field in its
  `docs/requirements.yaml` text but its description's terminology ("claimed
  external_realm") is describing REQ-017's `realm` field by role, not asserting a
  differently-named struct field must exist.
- **REQ-021** ("Wire identity into the Plug pipeline"): its acceptance criteria mention
  "an auth context (`user_id`, `tenant_id`, `roles`)" as the pipeline's end-state output —
  this is REQ-021's **own** auth-context shape (assembled after REQ-018's JIT
  provisioning returns a real `user_id`), not a direct alias for
  `Letflow.Oidc.IdentityContext` itself (which has no `user_id` field — it has
  `external_user_id`, pre-provisioning). No mismatch: REQ-021's auth context is a
  **different, later-stage** struct/map that REQ-021 itself defines, built partly from
  this requirement's `IdentityContext.tenant_id`/`roles` fields (both present, §6) plus
  REQ-018's provisioned `user_id`. Flagging explicitly so ELIXIR-DEV building REQ-021
  later doesn't conflate the two shapes.

**No naming mismatch found** between this design's field names and what REQ-018/019/021
already expect — the specific `realm` vs. `external_realm` trap REQ-018's text warns
about is avoided by this design using `realm` (§6), consistent with what REQ-018 already
assumes.

## 9. Zero-I/O call-graph confirmation (acceptance criterion 1)

Per REQ-017's acceptance criterion 1 ("no Repo call, no HTTP call, and no other I/O
anywhere in its call graph — verified by inspection and stated explicitly in the
handoff"), the complete call graph of `map_verified_claims/3` is enumerated here so
ELIXIR-DEV's own inspection has a checklist to confirm against, not just an assertion to
restate:

```
map_verified_claims/3
├── resolve_claim_path/2            (map traversal only — no I/O)
├── resolve_optional_string_claim/3 (calls resolve_claim_path/2 — no I/O)
│   ├── for tenant_id
│   ├── for email
│   ├── for preferred_username (default arg = subject, not a further call)
│   └── for display_name
└── resolve_roles/2                 (calls resolve_claim_path/2 in a loop — no I/O)
```

Every function in this graph takes only in-memory arguments (`claims` map, `path`
strings, `config` struct, `subject` string) and returns only computed values — no
`Letflow.Repo` call, no `HTTPoison`/`Req`/`Finch`/any HTTP client call, no
`File`/`:file` call, no `GenServer.call` to any external process, no `Application.get_env`
call anywhere in *this* subtree (config was already resolved into a `ClaimMappingConfig`
struct by the caller before `map_verified_claims/3` is invoked — see below).

**`ClaimMappingConfig.for_realm/1` is explicitly NOT part of this call graph** — it is a
separate, one-level-up caller convenience (§7.2) that itself does read `Application`
config (a config read, not I/O in the network/DB sense, but flagged for precision
regardless). The design's contract: **whatever calls `map_verified_claims/3` (REQ-021's
pipeline, or a test) resolves the `ClaimMappingConfig` first** (via `for_realm/1` or by
constructing one directly, e.g. in tests) and passes the **already-resolved struct** in as
`map_verified_claims/3`'s first argument. This keeps `map_verified_claims/3` itself
provably zero-I/O by construction (its own signature takes a pre-built config value, never
a realm string it would need to look up itself) — matching Zig's own `mapVerifiedClaims`
signature shape exactly (`config: ClaimMappingConfig`, already-resolved, passed in;
`loadClaimMappingConfig` is Zig's separate, explicitly-I/O-performing sibling function,
§2). ELIXIR-DEV's handoff should state this explicitly: "`map_verified_claims/3` takes an
already-resolved `ClaimMappingConfig` struct; config resolution (`for_realm/1`) happens in
the caller, one level above this function, and is not part of this function's own call
graph" — this is the structurally-checkable form of acceptance criterion 1, not just an
assertion.

## 10. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-017 acceptance criterion | Concrete design element addressing it |
|---|---|
| "the mapping function has no Repo call, no HTTP call, and no other I/O anywhere in its call graph — verified by inspection and stated explicitly in the handoff" | §9 gives the complete call-graph enumeration and the exact handoff statement to make |
| "given claims missing every optional field, the function returns defaults matching claim_mapping.zig's Key Invariant 3 (email->\"\", preferred_username->sub value, roles->[], display_name->nil, tenant_id->nil) rather than erroring" | §5 cites each rule against the actual Zig source lines; §7.3 gives `resolve_optional_string_claim/3` and `resolve_roles/2`'s exact signatures implementing them |
| "given claims with no sub/subject, the function returns an error (not a default), matching claim_mapping.zig's SubClaimMissing" | §3 establishes the `{:error, :sub_claim_missing}` shape; §7.3's `map_verified_claims/3` signature states the empty-string-or-nil-subject check |
| "@moduledoc cites src/oidc/claim_mapping.zig as the ported source" | Instruction to ELIXIR-DEV in §12 below; matches `user.ex`/`tenant.ex`'s existing citation-style precedent (§0) |

## 11. Open questions (not silently resolved)

1. **OQ-1 — Elixir `default/0`'s `realm` argument vs. Zig's literal `""` default (§4.1).**
   This design deliberately threads the target realm through
   `ClaimMappingConfig.default/1` instead of reproducing Zig's `.realm = ""` literal,
   reasoning that an empty-string realm on a constructed `IdentityContext` is a
   Zig-comptime-constant artifact, not a semantic REQ-017 needs to preserve. Flagged for
   CODE-DESIGN-VALIDATOR/REVIEWER to confirm this deviation is acceptable rather than
   something that should instead exactly mirror Zig's literal (e.g. if some future
   consumer specifically depends on being able to detect "config used the hardcoded
   default, not a realm-specific entry" via an empty-string sentinel — no such consumer
   is named in REQ-018/019/021's current text, so this design does not believe one
   exists, but has not exhaustively proven a negative).
PROVENANCE (historical, not current decision authority):
2. **OQ-2 — `nil` subject treated identically to `""` subject (§7.3).** Zig's `subject`
   parameter is non-optional (`[]const u8`, never null in Zig's type system), so
   `claim_mapping.zig` itself has no "what if subject is null" case to port from — only
   "what if subject is empty". This design extends the error check to also cover
   Elixir's `nil` case (since `ueberauth_oidcc`'s claims map could plausibly hand back a
   missing/`nil` `"sub"` key upstream of this function, depending on how REQ-021's
   pipeline extracts `subject` before calling `map_verified_claims/3` — not yet built,
   so unconfirmed). Flagged as this design's own extension beyond the literal source,
   not a silently-resolved guess.
3. **Multi-realm config growth path (§4.1).** The `config :letflow, :oidc_claim_mapping`
   map-keyed-by-realm shape supports N realms today (unlike REQ-016's single-map `:oidc`
   key, which REQ-016's own design §9 explicitly deferred generalizing until a second
   realm exists) — this design chose the map-keyed-by-realm shape up front for
   `oidc_claim_mapping` specifically because REQ-017's own requirement text already names
   "Per-realm configurable claim paths" as the requirement's premise (unlike REQ-016,
   which had exactly one realm in scope and no per-realm framing at all). Not believed to
   be over-building relative to YAGNI, but named explicitly in case REVIEWER disagrees
   and would rather this requirement also hardcode a single realm the way REQ-016 did.
4. **Whether `ueberauth_oidcc`'s callback claims map uses string keys or atom keys.**
   This design assumes **string keys** (`%{optional(String.t()) => term()}`, §7.3),
   consistent with standard JWT-claims-as-JSON-object decoding (JSON object keys are
   always strings; no Elixir JSON/JWT library atom-izes arbitrary external-controlled
   keys as a matter of security practice — atomizing unbounded external input would leak
   the atom table). Not empirically verified against a real `ueberauth_oidcc` callback in
   this environment (no deps fetched, no reachable OIDC issuer — same environment
   limitation REQ-016's design and implementation both hit and documented). ELIXIR-DEV
   should confirm this against `ueberauth_oidcc`'s actual callback return shape (via
   hexdocs or source, same verification discipline REQ-016's design applied in its §3)
   before implementing, and flag back to CODE-DESIGNER if the actual shape differs
   (e.g. if it turns out to be atom-keyed, or a struct rather than a bare map).

## 12. Instructions to ELIXIR-DEV (non-code, procedural)

- New files: `lib/letflow/oidc/identity_context.ex`, `lib/letflow/oidc/claim_mapping_config.ex`,
  `lib/letflow/oidc/claim_mapping.ex` — establishing the `Letflow.Oidc` namespace (first
  use; REQ-016 only referenced `Letflow.Oidc.DefaultProvider` as a bare config atom,
  never a real module).
PROVENANCE (historical, not current decision authority):
- Each `@moduledoc` cites `src/oidc/claim_mapping.zig` explicitly (acceptance criterion
  4) — match `user.ex`/`tenant.ex`'s existing citation style (§0): name the specific
  source file, and state explicitly what this module does and does NOT cover (no DB-backed
  per-realm config table; §1's error-set-narrowing decision; §6's struct-vs-schema
  reasoning restated briefly).
- Add `config :letflow, :oidc_claim_mapping, %{...}` to both `config/dev.exs` and
  `config/test.exs` per §4.1 (test needs at least the `"bpm-default"` entry, or can rely
  on `default/1`'s fallback — ELIXIR-DEV's choice, either satisfies §4.1, but state which
  was chosen in the handoff).
- No migration, no `Ecto.Schema` — confirm `mix ecto.migrate` is a no-op for this
  requirement (nothing to apply).
- Self-review per `backend_developer_guide.md` §4, plus this design's own §9 call-graph
  checklist restated as the literal handoff statement to write.
