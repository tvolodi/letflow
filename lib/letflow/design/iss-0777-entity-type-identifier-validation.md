
# ISS-0777 — `entity_type`/`attribute` identifier-format validation

**Issue:** `docs/issues/ISS-0777.yaml` (BLOCKER, `github_ref` GH-1696, `queue_ref` Q-776).
**Blocks:** REQ-375 AC5.
**Affected files (design scope):**
- `lib/letflow/tenant_provisioning.ex`
- `lib/letflow/platform/migration_rollout.ex`
- `lib/letflow/routers/platform_migrations.ex`

No new files. No migrations. No `Letflow.Api.Validation`/`FieldConstraint` changes.

---

## 1. Root cause (re-derived from source, not from the issue text alone)

Traced the full write path for `POST /platform-migrations/rollouts`:

1. `Letflow.Routers.PlatformMigrations`'s `@start_schema` (`platform_migrations.ex:88-110`)
   checks `entity_type`/`attribute` are non-empty strings ≤255 chars. No format check.
2. `handle_start/1` calls `Letflow.Platform.MigrationRollout.start_rollout/3`
   (`migration_rollout.ex:128`) with the raw string, unvalidated.
3. `start_rollout/3` → `start_new_rollout/3` (`migration_rollout.ex:174`) **inserts the
   `Rollout` row first** (`Repo.insert(Rollout.changeset(...))`, line 183), *before*
   entity_type/attribute are checked against anything.
4. It then loops every active tenant and calls
   `Letflow.TenantProvisioning.register_column_promotion/4`
   (`tenant_provisioning.ex:1308`) via `register_and_seed_outcome/5`
   (`migration_rollout.ex:254`). This function has **no format check either** — it
   inserts a `ColumnPromotion` row with `entity_type`/`column_name` taken verbatim.
5. Only later, when `run_column_promotion/1` is driven (via `apply_outstanding/1` in the
   same call, or later via `resume_rollout/1`), does anything reject a bad identifier:
   `checked_table_name/1` (`tenant_provisioning.ex:1463`) calls
   `table_name_for_entity_type/1` (line 1209), which calls
   `Letflow.Entities.Definition.DDL.valid_identifier?/1` (`ddl.ex:400`, regex
   `^[a-z][a-z0-9_]{0,63}$`, `ddl.ex:107`). On failure, `checked_table_name/1`
   **raises `ArgumentError`** (line 1469) instead of returning `{:error, _}`.
6. That raise is unhandled by every caller in the chain
   (`do_run_column_promotion/2` → `run_column_promotion/1` → `apply_outstanding/1` →
   `start_new_rollout/3` → `start_rollout/3` → router `handle_start/1`), so it surfaces
   as a bare HTTP 500.

**Two independently-confirmed bugs, not one:**

- **(a) No caller validates identifier format before the value is persisted or used.**
  `register_column_promotion/4`'s own moduledoc says nothing about format; its call
  sites (`migration_rollout.ex:255` and `entities/definitions.ex:549`) pass the value
  straight through.
- **(b) `checked_table_name/1`'s comment is false.** Lines 1455-1461 assert
  `entity_type`/`column_name` "were already validated as safe identifiers at
  `register_column_promotion/4` time" — grepped `register_column_promotion/4`'s full
  body (`tenant_provisioning.ex:1308-1335`): no `DDL.valid_identifier?/1` call, no
  regex, nothing. The comment must be corrected once real validation exists upstream
  (§4 below).

**A second, distinct defect found while tracing (not in the issue's own repro, but on
the same path, same root cause class):** if `register_column_promotion/4` alone were
patched to return `{:error, :invalid_entity_type}` (fix option "B" from the issue) with
`start_rollout/3` left untouched, `register_and_seed_outcome/5`
(`migration_rollout.ex:254-276`) would route that new atom into its `{:error,
changeset}` clause (loosely named, not pattern-matched to `%Ecto.Changeset{}` — it
compiles and matches any term). That falls into `record_registration_conflict/5`
(line 296), which does `Repo.get_by(ColumnPromotion, entity_type: entity_type, ...)` —
finds nothing, because nothing was ever registered for an invalid `entity_type` — and
hits the `nil ->` branch's **own explicit `raise`** (line 320-322): *"no matching
entity_column_promotions row to attribute the failure to"*. That is a second unhandled
crash, on a code path that has already inserted a `Rollout` row in `"running"` status by
that point. Fixing only `register_column_promotion/4` moves the 500 one function
sideways; it does not remove it. This is why §2 below rejects "fix only inside
`register_column_promotion/4`" as insufficient on its own.

---

## 2. Fix-location decision

**Decision: validate in both `Letflow.Platform.MigrationRollout.start_rollout/3` (top,
before any write) and `Letflow.TenantProvisioning.register_column_promotion/4` (top,
before any write) — not only one of the two, and not inside `@start_schema`.**

Reasoning, addressing the issue's own two named options plus the router-schema option:

- **Why not `@start_schema` alone (issue's option A).** `Letflow.Api.Validation` /
  `FieldConstraint` (`lib/letflow/api/validation.ex`) has no regex/`pattern` field today
  — `defstruct` at `validation.ex:12-22` lists `required, type, reject_empty_string,
  min_length, max_length, min_value, max_value, min_items, max_items, allowed_values`
  only. The issue's phrasing ("a regex `pattern` constraint via the existing
  `Letflow.Api.Validation` mechanism, per this codebase's established convention")
  describes a mechanism that does not actually exist yet — grepped every router under
  `lib/letflow/routers/*.ex` for `Regex.match?`/`valid_identifier?`: no router does
  format validation via `Validation` today (confirmed by grep, zero hits). Adding a new
  `pattern` field to the shared `FieldConstraint` struct, `validate_field/2`, and
  `Letflow.Api.Validation`'s moduledoc invariants (INV-8 "never raises", the documented
  NUL-byte/SQL-metacharacter posture) is a materially bigger, cross-cutting change to a
  module every router depends on, to fix a defect that is local to one write path. It
  would also only fix the HTTP-facing router — `register_column_promotion/4`'s other
  caller (`entities/definitions.ex:549`) does not go through this router at all, so a
  schema-only fix leaves the true root cause (an unvalidated public context function)
  in place.

- **Why not `register_column_promotion/4` alone (issue's option B, in isolation).**
  Verified real call sites (`grep -rn "register_column_promotion(" lib/letflow/`):
  1. `lib/letflow/platform/migration_rollout.ex:255` (`register_and_seed_outcome/5`,
     called from `start_new_rollout/3` and `apply_to_existing_rollout/2`) — reached from
     the raw HTTP request body, **no upstream format validation**.
  2. `lib/letflow/entities/definitions.ex:549` (`register_and_run_column_promotion/4`,
     called from `ensure_one_column_promotion/3` / `ensure_column_promotions/2`) — its
     `entity_type` is `promoted.name`, an entity-type name that already passed
     `Letflow.Entities.Definition.Validator`'s `name_format_violations/1`
     (`validator.ex:266-276`, same `^[a-z][a-z0-9_]{0,63}$` pattern, `validator.ex:48`)
     at definition-create/activation time. **This caller already validates upstream.**

  So a fix inside `register_column_promotion/4` alone is necessary (closes the gap for
  caller 1, the one this issue is about, and is genuine defence-in-depth for caller 2,
  which happens to already be safe) but **not sufficient**: as shown in §1's "second
  distinct defect", `start_new_rollout/3` has already written the `Rollout` row and
  reached the per-company loop by the time `register_column_promotion/4` would reject
  it, and the loop's own error-handling assumes an Ecto changeset shape, so a bare atom
  error there produces a *different* unhandled `raise`, not a clean result.

- **Why both, and why `start_rollout/3`'s check must come first, at its very top.**
  `start_rollout/3` (`migration_rollout.ex:128-134`) is itself a public context-module
  function — REQ-374's design doc frames it as the module's one caller-facing entry
  point, and nothing stops a future caller (another router, a mix task, a future
  scheduled job) from calling it directly, bypassing `platform_migrations.ex` entirely,
  the same way `entities/definitions.ex` already bypasses it to reach
  `register_column_promotion/4` directly. Trusting "the router already checked it" is
  exactly the assumption that produced this issue's stale, false comment in the first
  place (§1(b)) — this codebase's own established posture, stated explicitly at three
  other points in `tenant_provisioning.ex` (`checked_table_name/1`'s comment intent
  *before* correction, `execute_add_column/4`'s "re-validated immediately before
  interpolation ... defence in depth matching DDL's own posture", and
  `ensure_entity_table/2`), is that a function reachable from more than one call site
  re-validates at its own boundary rather than trusting a sibling already did. Putting
  the check at the top of `start_rollout/3`, before `Repo.get_by(Rollout, ...)` (line
  130) and therefore before any row of any kind is written, is the earliest point in
  this module's own write path — no `Rollout` row, no `Outcome` row, no per-company loop
  entered for an invalid pair. `register_column_promotion/4`'s check is then genuinely
  redundant for the `start_rollout/3` path (harmless — dead code on that path once
  `start_rollout/3` itself rejects first) and is the actual, sole protection for the
  `entities/definitions.ex` path if that caller's own upstream guarantee is ever
  weakened later. This mirrors the exact "re-check where it doesn't cost anything to be
  wrong twice" posture `execute_add_column/4` already uses for `table_name`/
  `column_name`/`pg_type`/`generated_as`.

- **No change to `@start_schema` or `Letflow.Api.Validation`.** Not required once
  `start_rollout/3` rejects first — the router only needs to translate the two new
  tagged errors into a 422 (§3). Keeps this fix's blast radius to the three files the
  issue itself names as affected.

---

## 3. Validation rule (exact)

**Rule:** `entity_type` and `attribute` must each independently satisfy
`Letflow.Entities.Definition.DDL.valid_identifier?/1` — i.e. match
`~r/^[a-z][a-z0-9_]{0,63}$/` (lowercase ASCII letter first, then up to 63 more lowercase
letters/digits/underscores, 1-64 chars total).

**Decision: call `DDL.valid_identifier?/1` directly. Do not re-derive or duplicate the
regex.** This is the exact same predicate `table_name_for_entity_type/1` and
`execute_add_column/4` already gate on further down this same write path — `entity_type`
literally becomes `"entity_" <> entity_type` (`tenant_provisioning.ex:1211`) and
`attribute` literally becomes the physical column name (`column_name: attribute`,
`tenant_provisioning.ex:1321`, then interpolated as `promotion.column_name` in
`execute_add_column/4`, line 1798). Using any other rule — stricter or looser — would
reintroduce exactly this issue's shape in reverse (reject a value at the new checkpoint
that DDL would have accepted, or vice versa). `DDL.valid_identifier?/1` is already
public (`@spec valid_identifier?(String.t()) :: boolean()`, `ddl.ex:400`) and already
documented as the shared, independent source of truth other modules call rather than
reimplementing (`tenant_provisioning.ex:1202-1205`'s own moduledoc comment on
`table_name_for_entity_type/1`) — `TenantProvisioning` already `alias`es
`Letflow.Entities.Definition.DDL` (`tenant_provisioning.ex:188`), so no new alias is
needed there; `Letflow.Platform.MigrationRollout` needs one new
`alias Letflow.Entities.Definition.DDL` line.

No new regex constant, no new module. This is intentionally the narrowest rule that
closes the gap without drifting from what DDL will accept later in the same request.

---

## 4. Function-level design

### 4.1 `Letflow.Platform.MigrationRollout.start_rollout/3` (`migration_rollout.ex`)

Add `alias Letflow.Entities.Definition.DDL` near the module's existing aliases.

Change `@spec` return type to add the two new error reasons:

```
@spec start_rollout(
        entity_type :: String.t(),
        attribute :: String.t(),
        column_spec :: %{
          required(:pg_type) => String.t(),
          required(:nullable) => true,
          optional(:references_entity) => String.t(),
          optional(:generated_as) => String.t() | nil
        }
      ) :: {:ok, rollout_result()}
         | {:error, :invalid_entity_type}
         | {:error, :invalid_attribute}
         | {:error, :column_spec_conflict}
         | {:error, term()}
```

Behavior change: `start_rollout/3`'s function head gains a validation step that runs
**before** the existing `Repo.get_by(Rollout, entity_type: entity_type, attribute:
attribute)` case (`migration_rollout.ex:130`) — i.e. this is the very first thing the
function does, ahead of any `Repo` call:

- If `DDL.valid_identifier?(entity_type)` is `false` → return `{:error,
  :invalid_entity_type}` immediately. No `Repo` call of any kind.
- Else if `DDL.valid_identifier?(attribute)` is `false` → return `{:error,
  :invalid_attribute}` immediately. No `Repo` call of any kind.
- Else → proceed exactly as today (the existing `Repo.get_by` dispatch to
  `start_new_rollout/3` / `continue_existing_rollout/2`, unchanged).

Order matters for a deterministic single error when both are invalid: `entity_type` is
checked first (matches field declaration order in `@start_schema` and in this function's
own argument order).

No other function in this module changes. `start_new_rollout/3`,
`continue_existing_rollout/2`, `register_and_seed_outcome/5`,
`record_registration_conflict/5` are unmodified — by the time any of them run,
`entity_type`/`attribute` are already known-valid, so `record_registration_conflict/5`'s
existing `nil ->` raise (§1's "second distinct defect") stays unreached via this path,
without needing to touch that function.

### 4.2 `Letflow.TenantProvisioning.register_column_promotion/4` (`tenant_provisioning.ex`)

`DDL` is already aliased (line 188) — no new alias needed.

Change `@spec` return type:

```
@spec register_column_promotion(
        entity_type :: String.t(),
        attribute :: String.t(),
        column_spec :: %{
          required(:pg_type) => String.t(),
          required(:nullable) => true,
          optional(:references_entity) => String.t(),
          optional(:generated_as) => String.t() | nil
        },
        tenant_ids :: [Ecto.UUID.t()] | :all
      ) :: {:ok, [ColumnPromotion.t()]}
         | {:error, :invalid_entity_type}
         | {:error, :invalid_attribute}
         | {:error, term()}
```

Behavior change: the function head gains the same two-step check as §4.1, run before
`resolve_tenant_ids/1` and before `Repo.transaction/1` (i.e. before line 1310 in the
current file) — no tenant resolution, no transaction opened, no row of any kind touched
for an invalid pair:

- `DDL.valid_identifier?(entity_type) == false` → return `{:error,
  :invalid_entity_type}`.
- `DDL.valid_identifier?(attribute) == false` → return `{:error, :invalid_attribute}`.
- Otherwise unchanged (existing body, `tenant_ids = resolve_tenant_ids(tenant_ids)`
  onward, exactly as today).

Caller impact, verified:
- `migration_rollout.ex:255` (`register_and_seed_outcome/5`) — unreachable with an
  invalid pair once §4.1 lands (start_rollout/3 already rejected first); if ever
  reached anyway, its existing loosely-typed `{:error, changeset} ->` clause still
  compiles against a bare atom (no pattern-match failure) — it would still hit
  `record_registration_conflict/5`'s `nil ->` raise. This is accepted as the "belt"
  half of belt-and-suspenders: `start_rollout/3`'s check is the real protection for
  this caller, this one is pure defence-in-depth for a future caller of
  `register_column_promotion/4` that does not go through `start_rollout/3`.
- `entities/definitions.ex:549` (`register_and_run_column_promotion/4`) — its
  `{:error, reason} -> Logger.error(...)` clause (`definitions.ex:551-556`) already
  handles an arbitrary `{:error, reason}` term generically; no crash, no pattern-match
  risk. In practice unreachable today (its `entity_type` already passed
  `Validator.name_format_violations/1` upstream), confirmed defence-in-depth only.

### 4.3 `Letflow.Routers.PlatformMigrations.handle_start/1` (`platform_migrations.ex`)

No change to `@start_schema`. The existing
`case MigrationRollout.start_rollout(entity_type, attribute, column_spec) do` block
(`platform_migrations.ex:120-124`) gains two new match clauses, both placed **before**
the existing catch-all `{:error, _reason} -> Response.internal_error(conn)` clause (an
`{:error, :invalid_entity_type}` / `{:error, :invalid_attribute}` tuple would otherwise
fall into that catch-all and produce a 500 again, defeating the whole fix):

- When `start_rollout/3` returns `{:error, :invalid_entity_type}`: build one
  `FieldError.t()` (`Letflow.Api.Validation.FieldError`, already `alias`ed by this
  module's `Letflow.Api.Validation.FieldConstraint` neighbor — add `FieldError` to that
  same `alias` group) with `field` set to the literal string `"entity_type"`,
  `constraint` set to a short machine-readable atom-like string naming this class of
  failure (e.g. `"identifier_format"` — TEST-DESIGNER/ELIXIR-DEV's exact spelling is not
  load-bearing, but it must be stable and distinct from every other `constraint` value
  `Letflow.Api.Validation` already emits, since Test 6.1-A asserts on it), `message` set
  to a human-readable sentence stating the allowed shape (must communicate: starts with
  a lowercase letter, only lowercase letters/digits/underscores after that, maximum 64
  characters total — i.e. describe `DDL.valid_identifier?/1`'s rule in prose, not
  restate the regex), and `received` set to the caller-supplied `entity_type` value
  (so the client can see what it sent, same convention every other `FieldError` in this
  codebase already follows). Pass that single-element list through the same
  `Validation.problem/1` → `Response.send_problem/2` pair `handle_start/1`'s existing
  `{:errors, field_errors} ->` branch already uses two lines above (line 115) — reuse,
  do not reimplement that pairing.
- When `start_rollout/3` returns `{:error, :invalid_attribute}`: identical shape, with
  `field` set to `"attribute"` and `message` describing the same rule against
  `attribute` instead of `entity_type`, `received` set to the caller-supplied
  `attribute` value.

`Validation.problem/1` (`validation.ex:252-255`) already builds the RFC 9457 body with
status 422 from a non-empty `FieldError.t()` list — reused as-is, no change to that
function or to `Letflow.Api.Validation` at all. This keeps the error response shape
identical to every other 422 this router (and every other router) already produces via
the same schema-validation path, even
though this particular check does not run through `Validation.validate/2` itself.

The existing `{:error, :column_spec_conflict} -> Response.conflict(conn, ...)` clause
and the catch-all `{:error, _reason} -> Response.internal_error(conn)` clause are
unchanged and stay below the two new clauses.

### 4.4 Corrected comment (`tenant_provisioning.ex:1455-1461`, `checked_table_name/1`)

Replace the current (false) comment:

> `# entity_type/column_name were already validated as safe identifiers at`
> `# register_column_promotion/4 time -- re-checked here anyway (defence in`
> `# depth matching DDL's own posture) and raised as an ArgumentError, never`
> `# silently proceeded, if a stored row somehow holds an unsafe value (which`
> `# would mean some write path bypassed register_column_promotion/4`
> `# entirely). This is why :invalid_entity_type is not in run_column_promotion/1's`
> `# own @spec -- it is unreachable via any function on this module's own`
> `# public surface.`

with (content, not literal final wording — ELIXIR-DEV may phrase this naturally, but it
must state these facts and no longer claim a false one):

- `entity_type` IS validated before a `ColumnPromotion` row can exist for it, as of
  ISS-0777: at `register_column_promotion/4`'s own entry (§4.2) for every caller, and
  additionally at `Letflow.Platform.MigrationRollout.start_rollout/3`'s entry (§4.1)
  for the platform-migration-rollout write path specifically, before that function ever
  reaches `register_column_promotion/4`.
- This function's raise remains reachable only if a `ColumnPromotion` row was written
  by some path that bypasses `register_column_promotion/4` entirely (e.g. a direct
  `Repo.insert`/`Repo.insert!` against the schema, or a future write path added without
  reading this comment) — a genuine internal-invariant violation, not a value this
  module's own public write surface can currently produce. Keep the raise (do not
  convert it to a tagged `{:error, _}` — RELEASE-VALIDATOR/REVIEWER should treat
  silently downgrading this specific raise as scope creep beyond ISS-0777, since it is
  intentionally a loud last-resort assertion, not a normal control-flow error).
- Do NOT claim `register_column_promotion/4` is the *only* place this is checked —
  after this fix it is checked in two places (§2's rationale), and the comment must
  name both rather than re-narrowing back to a single, eventually-stale claim.

---

## 5. Acceptance-criteria mapping

| Acceptance criterion (from issue `fix_direction`) | Design element |
|---|---|
| Add identifier-format validation for `entity_type` | §4.1 (`start_rollout/3`) + §4.2 (`register_column_promotion/4`), rule in §3 |
| Verify `attribute` too — likely has the identical gap | Confirmed in §1 (becomes `column_name`, checked by `execute_add_column/4` at DDL time); same two checkpoints in §4.1/§4.2 validate `attribute` identically to `entity_type` |
| At the earliest reasonable point in the write path | §2's decision + §4.1 placing the check before `start_rollout/3`'s first `Repo` call |
| Return a clean, actionable 422-class error instead of ever reaching `checked_table_name/1`'s raise | §4.3 (router maps both new error atoms to 422 via existing `Validation.problem/1`) |
| Correct the stale/incorrect comment | §4.4 |
| Regression test: hyphenated/invalid `entity_type` rejected cleanly at the API layer, never reaching DDL execution | §6 |

---

## 6. Regression-test design (for `TEST-DESIGNER`, not implemented here)

All tests use real Ecto/Postgres (this codebase's established test posture — no mocking
`Repo`). No new fixtures beyond what REQ-374/375's existing test support already
provides for `platform_migration_rollouts`/`entity_column_promotions`.

### 6.1 Router-level (API boundary) — the issue's own named regression case

Module: alongside the existing `platform_migrations` router test file (or created
adjacent to it if none exists yet for this router).

- **Test A — hyphenated `entity_type`, issue's exact repro value.**
  `POST /api/v1/platform-migrations/rollouts` with
  `entity_type: "pl-rollout-95a456dd"` (the literal REQ-375 fixture value from the
  issue), a valid `attribute`, and a valid `column_spec`. Assert:
  - HTTP status `422`.
  - Response body is an RFC 9457 problem document with an `errors` array containing one
    entry with `field: "entity_type"`, `constraint: "identifier_format"`.
  - No `platform_migration_rollouts` row exists afterward (`Repo.get_by(Rollout,
    entity_type: "pl-rollout-95a456dd")` is `nil`) — proves rejection happens before any
    write, not merely before a 200 response.
  - No `entity_column_promotions` row exists afterward for that `entity_type`.
  - No crash/`ArgumentError`/500 — the request completes normally (this is the
    regression the issue is actually about: previously this same request produced an
    unhandled 500).

- **Test B — hyphenated `attribute`, valid `entity_type`.** Same shape as Test A but
  with a valid `entity_type` and `attribute: "some-attr"`. Assert `422`, `field:
  "attribute"`, `constraint: "identifier_format"`, no row written.

- **Test C — uppercase / leading-digit / too-long variants (boundary coverage).** Table
  of invalid values exercising each rejected shape DDL's regex excludes:
  `"Entity_Type"` (uppercase), `"9entity"` (leading digit), `String.duplicate("a", 65)`
  (65 chars, over the 64-char cap), `"entity type"` (space), `"entity.type"` (dot).
  Each asserted `422` with the correct `field`, no row written. (Not one test per value
  — a single parameterized/`for`-driven test case is fine per this codebase's existing
  test style; TEST-DESIGNER's call.)

- **Test D — valid identifiers still succeed (no false positive).** `entity_type:
  "pl_rollout_95a456dd"` (same value, underscore instead of hyphen — the legitimate
  form) with a valid `attribute` and `column_spec` succeeds with `200` and a real
  `rollout` in the response body, proving the fix does not over-reject.

### 6.2 Context-module level — `Letflow.Platform.MigrationRollout.start_rollout/3`

- Direct call with an invalid `entity_type` returns `{:error, :invalid_entity_type}`,
  and no `Rollout` row exists afterward (`Repo.get_by/2` directly against the schema,
  bypassing the HTTP layer — proves the check runs before `Repo.insert`, not just that
  the eventual HTTP response is a 422).
- Direct call with an invalid `attribute` (valid `entity_type`) returns `{:error,
  :invalid_attribute}`, no `Rollout` row written.
- Direct call with both valid still returns `{:ok, rollout_result()}` exactly as before
  (no regression on the happy path — reuse/extend REQ-374/375's existing
  `start_rollout/3` happy-path test rather than duplicating its setup).

### 6.3 Context-module level — `Letflow.TenantProvisioning.register_column_promotion/4`

- Direct call with an invalid `entity_type` returns `{:error, :invalid_entity_type}`,
  no `ColumnPromotion` row written, no transaction side effect.
- Direct call with an invalid `attribute` returns `{:error, :invalid_attribute}`, no row
  written.
- Existing REQ-297/298 happy-path tests for this function (valid, `Validator`-checked
  `entity_type`/`attribute` from a real entity definition) must still pass unchanged —
  run the full existing `register_column_promotion/4` test module as part of this
  regression run to confirm no behavioral change on the already-valid path.

### 6.4 Explicitly out of scope for this regression suite

- `checked_table_name/1`'s raise itself is NOT deleted or converted, so no test should
  assert it no longer exists — only that it is no longer *reachable* via the
  `POST /rollouts` → `run_column_promotion/1` path for a value the API accepted. A
  direct unit test of `checked_table_name/1` still raising for a row that bypassed
  `register_column_promotion/4` (e.g. via a raw `Repo.insert!` in the test itself,
  simulating the invariant violation §4.4 describes) may be added as *confirmation the
  defence-in-depth layer is still live*, but is not required to close this issue.

---

## 7. Open questions

None. Every affected file, function, call site, and the exact regex has been read and
traced end-to-end above; no assumption in this design is unresolved or deferred to the
implementer's guess.
