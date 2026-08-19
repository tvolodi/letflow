# ISS-0059: Collision-proof tenant slug suffix for `insert_tenant!/0` test helpers

## Problem

30 test files each define a local `insert_tenant!/0` (or `/1`, or an equivalent
locally-named tenant-fixture helper) that builds a tenant
`slug` as `"<file-prefix>-#{System.unique_integer([:positive, :monotonic])}"`.
`System.unique_integer/1` is only unique within a single BEAM VM run. All 30 files run
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (real, non-rolled-back commits)
in at least one code path, so a prior `mix test` run that crashed/was killed before its
`on_exit` cleanup ran can leave `tenants` rows behind. A fresh VM's monotonic counter
restarts from a low value and can reproduce a previously-used integer, causing
`tenants_slug_index has already been taken` (`Ecto.InvalidChangesetError`).

Fix: replace the `System.unique_integer(...)` suffix with an `Ecto.UUID.generate/0`
(or equivalent) suffix in every affected file, via one shared helper so the fix is
made once and is mechanically identical everywhere.

## New shared helper

### Location

`test/support/tenant_slug.ex` — a plain module under `test/support/`, alongside
`Letflow.DataCase` and the other shared test-support modules already there
(`data_case.ex`, `token_verifier_double.ex`, etc.). Not an `ExUnit.CaseTemplate` —
it has no setup/teardown behavior, just a pure function, so callers `alias` it
directly rather than `use` it.

### Module/function signature

```
defmodule Letflow.TenantSlugFixture do
  @moduledoc ...

  @spec unique_slug(prefix :: String.t()) :: String.t()
end
```

- `prefix`: the caller-supplied, file-distinguishing prefix (e.g. `"req027"`,
  `"req040-assertion-rerun"`, `"req036-conflict"`) — exactly the same literal each
  call site already uses today, minus the trailing `-#{System.unique_integer(...)}`
  part.
- Returns: `"#{prefix}-#{<collision-proof suffix>}"`, where the suffix is derived from
  `Ecto.UUID.generate/0` (a 36-character canonical UUID string, e.g.
  `"550e8400-e29b-41d4-a716-446655440000"`), collision-proof across VM restarts because
  it is not derived from any in-process counter or wall-clock value that resets.
- No error return — `Ecto.UUID.generate/0` cannot fail; this function is a pure string
  transform with no I/O.
- `tenants.slug` is an unbounded-length-in-practice `:string` (`varchar`, migration
  `20260816000001_create_tenants.exs`) with a unique index and no documented max-length
  changeset validation, so `prefix <> "-" <> <36-char UUID>` never risks a DB-level
  truncation collision the way a fixed-width column might.

### Open question (not silently resolved)

`identity_test.exs` mixes `Sandbox.mode(:auto)` (lines 146, 353) with
`:manual`/`{:shared, self()}` mode (lines 278, 280) across different describe blocks
in the same module (`async: false` for the whole file, so this is safe ordering, not a
bug). Its `unique_slug/1` helper is called from both kinds of describe block — some
calls back real, non-rolled-back tenant rows (vulnerable), others back rolled-back
sandbox transactions (not vulnerable). ELIXIR-DEV should confirm it is safe (and
simpler) to route *all* of `unique_slug/1`'s output through the shared collision-proof
helper regardless of which describe block calls it, rather than trying to split the
helper by mode — this design assumes yes (uniform fix, no behavior difference for the
already-safe callers, since a UUID suffix is at least as unique as a monotonic integer
in every case). Note `identity_test.exs` also has a separate `unique_realm/1` helper
(line 82) and uses `System.unique_integer([:positive])` directly for `preferred_username`
values (lines 118, 463, 481) — neither is a tenant slug and neither is in scope.

## Edit pattern (per call site)

Every affected file adds `alias Letflow.TenantSlugFixture` (or fully-qualifies the
call) and replaces the `slug:` line in its `insert_tenant!/0` with a call to
`Letflow.TenantSlugFixture.unique_slug/1`, passing the same literal prefix the file
already hard-codes today. General shape:

- Old: `slug: "<prefix>-#{System.unique_integer([:positive, :monotonic])}",`
- New: `slug: Letflow.TenantSlugFixture.unique_slug("<prefix>"),`

Only the `slug:` field inside `insert_tenant!/0` (or `provisioned_tenant/N`'s tenant
fixture, where that's the function name) is in scope. Other `System.unique_integer`
uses in the same files (definition names, idempotency keys, correlation keys, SandboxPool
process names, node ids) are untouched — they are not tenant slugs, are not checked
against a real unique DB index across VM restarts in the same way, and are out of
scope for ISS-0059.

Per-file old → new (prefix preserved from the file's own current literal):

| File | Old slug expression | New slug expression |
|---|---|---|
| `test/letflow/definitions/export_import_test.exs` | `"req034-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req034")` |
| `test/letflow/definitions/migrations_test.exs` | `"req027-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req027")` |
| `test/letflow/definitions/promotion_assertion_rerun_test.exs` | `"req040-assertion-rerun-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req040-assertion-rerun")` |
| `test/letflow/definitions/promotion_conflict_test.exs` | `"req036-conflict-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req036-conflict")` |
| `test/letflow/definitions/promotion_plan_test.exs` | `"req036-plan-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req036-plan")` |
| `test/letflow/definitions/promotion_review_migration_test.exs` | `"req035-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req035")` |
| `test/letflow/definitions/promotion_review_store_test.exs` | `"req037-review-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req037-review")` |
| `test/letflow/definitions/promotion_test.exs` | `"req037-promo-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req037-promo")` |
| `test/letflow/definitions/rollback_test.exs` | `"req038-rollback-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req038-rollback")` |
| `test/letflow/definitions/search_test.exs` | `"req042-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req042")` |
| `test/letflow/definitions/snapshot_store_test.exs` | `"req033-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req033")` |
| `test/letflow/definitions/store_test.exs` | `"req030-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req030")` |
| `test/letflow/engine_cancel_instance_test.exs` | `"req052-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req052")` |
| `test/letflow/engine_complete_task_test.exs` | `"req048-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req048")` |
| `test/letflow/engine/lua_script_audit_test.exs` | `"req058-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req058")` |
| `test/letflow/engine/migrations_test.exs` | `"req043-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req043")` |
| `test/letflow/engine_test.exs` | `"req045-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req045")` |
| `test/letflow/event_store/migrations_test.exs` | `"req023-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req023")` |
| `test/letflow/event_store/registry_test.exs` | `"req024-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req024")` |
| `test/letflow/event_store_test.exs` | `"req025-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req025")` |
| `test/letflow/identity_test.exs` | `defp unique_slug(prefix \\ "tenant"), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"` — body only, keep the function name/arity (called elsewhere in the file) | body becomes `Letflow.TenantSlugFixture.unique_slug(prefix)`; leave `defp unique_slug(prefix \\ "tenant")` head and the sibling `unique_realm/1` (a different, out-of-scope concept) untouched |
| `test/letflow/plugs/auth_pipeline_test.exs` | `defp unique_slug(prefix \\ "tenant"), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"` — body only | body becomes `Letflow.TenantSlugFixture.unique_slug(prefix)`; leave the `defp unique_slug(prefix \\ "tenant")` head and sibling `unique_realm/1` untouched |
| `test/letflow/req064_tenant_id_removal_test.exs` | `"req064-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req064")` |
| `test/letflow/tenant_provisioning_test.exs` | `"req022-#{System.unique_integer([:positive, :monotonic])}"` | `Letflow.TenantSlugFixture.unique_slug("req022")` |
| `test/letflow/identity/group_test.exs` | `defp unique_slug, do: "req063-group-#{System.unique_integer([:positive, :monotonic])}"` (line 40, called line 48) | body becomes `Letflow.TenantSlugFixture.unique_slug("req063-group")`; keep the `defp unique_slug, do: ...` head/arity |
| `test/letflow/identity/user_test.exs` | `defp unique_slug, do: "req063-user-#{System.unique_integer([:positive, :monotonic])}"` (line 106, called line 123) | body becomes `Letflow.TenantSlugFixture.unique_slug("req063-user")`; keep the head/arity |
| `test/letflow/identity/tenant_role_test.exs` | `defp unique_slug, do: "req063-trole-#{System.unique_integer([:positive, :monotonic])}"` (line 38, called line 46) | body becomes `Letflow.TenantSlugFixture.unique_slug("req063-trole")`; keep the head/arity |
| `test/letflow/identity_migration_test.exs` | `defp unique_slug, do: "req063-idmig-#{System.unique_integer([:positive, :monotonic])}"` (line 79, called line 88) | body becomes `Letflow.TenantSlugFixture.unique_slug("req063-idmig")`; keep the head/arity. Leave the file's other, unrelated `System.unique_integer` uses untouched (line 72's `900_000_000 + ...` node-id offset, lines 175/187/197's `legacy-user-`/`legacy-`/`legacy-role-` username/email/role-name generators) — none are `tenants.slug`. |
| `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs` | `defp unique_slug(prefix \\ "tenant") do "#{prefix}-#{System.unique_integer([:positive, :monotonic])}" end` (lines 69-71, called with no arg at line 92 inside `insert_tenant_for_realm!/1`, so default prefix `"tenant"` applies) | body becomes `Letflow.TenantSlugFixture.unique_slug(prefix)`; keep the `defp unique_slug(prefix \\ "tenant")` head. Leave the sibling `defp unique_realm(prefix)` (lines 65-67, an OIDC realm id, not a tenant slug) untouched. |
| `test/letflow/role_registry_test.exs` | `defp unique_slug, do: "req063-rolereg-#{System.unique_integer([:positive, :monotonic])}"` (line 99, called line 107) | body becomes `Letflow.TenantSlugFixture.unique_slug("req063-rolereg")`; keep the head/arity. Leave the file's sibling `unique_realm/1`-style prefix helper (line 96) and the unrelated group-name generators (lines 168, 185-187) untouched — none are `tenants.slug`. |

## Files verified NOT affected (excluded from ISSUE-FIXER's original list)

- `test/letflow/definitions/pack_update_migration_test.exs` — defines `insert_tenant!/0`
  with the same `System.unique_integer` slug pattern, but the module is
  `async: true` using `Letflow.DataCase`'s ordinary sandboxed-and-rolled-back
  transaction (no `Sandbox.mode(Letflow.Repo, :auto)` call anywhere in the file — this
  is called out explicitly in its own moduledoc, "exactly like `identity/tenant_role_test.exs`").
  No real commit ever survives the test, so it cannot leave a stale row across VM
  restarts. Out of scope.
- `test/letflow/plugs/tenant_status_test.exs` — same reasoning: `async: true`, no
  `Sandbox.mode(:auto)` call in the file. Already uses its own `unique_slug/1` helper
  but is not at risk from this failure mode. Out of scope.

## Files ISSUE-FIXER's diagnosis missed (added after grep verification)

- `test/letflow/definitions/promotion_test.exs` — defines `insert_tenant!/0`, has
  `Sandbox.mode(Letflow.Repo, :auto)` (line 79), `async: false`. Genuinely affected;
  ISSUE-FIXER's list omitted it.
- `test/letflow/identity_test.exs` — defines `insert_tenant!/2`, has
  `Sandbox.mode(Letflow.Repo, :auto)` in two describe blocks (lines 146, 353),
  `async: false` for the whole module. Genuinely affected; ISSUE-FIXER's list omitted
  it. See Open Question above for the one wrinkle (its `unique_slug/1` helper is
  reused for non-tenant values too).

`test/letflow/definitions/promotion_assertion_rerun_test.exs` (exact filename
confirmed to exist as named, no typo) and all other files ISSUE-FIXER listed were
independently confirmed present and vulnerable by the same grep methodology.

## Rework iteration 1: 6 further files CODE-DESIGN-VALIDATOR found missing

CODE-DESIGN-VALIDATOR independently re-derived the candidate set via
`comm -12 <(grep -rl "unique_integer(\[:positive, :monotonic\])" test/ | sort) <(grep -rl "Sandbox.mode(Letflow.Repo, :auto)" test/ | sort)`
(re-run here with `LC_ALL=C` to get a stable sort — the default locale's `sort`
disagreed with `comm`'s own ordering check and errored) and got 32 candidates
against this design's original 24. Each of the 32 was re-inspected by hand this
iteration (`grep -n "async\|Sandbox.mode\|unique_integer\|defp insert_tenant\|slug:"`
per file, plus a full read of one representative file). Two are confirmed NOT
affected (their `unique_integer` call builds a SandboxPool/process registration name,
never fed into a `tenants.slug` insert), matching CODE-DESIGN-VALIDATOR's own
exclusion — not re-added:

- `test/letflow/sandbox_pool_test.exs`
- `test/letflow/sandbox_pool/fixture_loader_test.exs`

The remaining 6 are genuinely affected — same vulnerable shape as the other 24 (a
`defp unique_slug` helper feeding `Tenant.create_changeset/2`'s `slug:` field, inside
a module that calls `Sandbox.mode(Letflow.Repo, :auto)` before the insert) — and are
now added to the edit-pattern table above:

- `test/letflow/identity/group_test.exs`
- `test/letflow/identity/user_test.exs`
- `test/letflow/identity/tenant_role_test.exs`
- `test/letflow/identity_migration_test.exs`
- `test/letflow/plugs/auth_pipeline_configurable_verifier_test.exs`
- `test/letflow/role_registry_test.exs`

None of the 6 introduce a design gap beyond what the Open Question above already
flags for `identity_test.exs`/`auth_pipeline_test.exs`: they follow the plain
single-mode `defp unique_slug, do: "<prefix>-#{System.unique_integer(...)}"` shape
(one `Sandbox.mode(:auto)` call per `setup`, no mixing of `:auto` and
`:manual`/`{:shared, self()}` around the tenant-insert itself — the later
`:manual` + bare `checkout/1` calls in some of these files, e.g.
`group_test.exs` line 98, happen strictly *after* the tenant is already inserted, to
restore a transaction for a subsequent `SET search_path`, so they don't affect
slug-collision risk), except
`auth_pipeline_configurable_verifier_test.exs`, which mirrors
`auth_pipeline_test.exs`/`identity_test.exs`'s parameterized-prefix shape
(`defp unique_slug(prefix \\ "tenant")`) rather than the fixed-prefix shape — both
shapes route through the same `Letflow.TenantSlugFixture.unique_slug/1` call, just
with a literal vs. a variable argument.

Final affected-file count: **30** (24 original + 6 above), confirmed by
`comm -12` giving 32 raw candidates minus the 2 confirmed-unaffected SandboxPool
files.

## Invariants

- The shared helper never changes what a `slug:` collision means at the DB level — the
  `unique_index(:tenants, [:slug])` constraint and `Tenant.create_changeset/1,2`'s
  `unique_constraint(:slug)` are untouched.
- The helper does not touch `on_exit` cleanup logic in any file — this fix addresses
  the slug-generation half of ISS-0059's diagnosis, not the "make `on_exit` robust to
  a crash by also cleaning stale rows at setup" alternative the issue also floats as a
  possible fix. Both are independently sufficient per the issue's own wording ("Likely
  fix: ... or ..."); this design implements only the slug-generation fix, matching the
  task instruction.
- No behavioral change to any assertion in any of the 30 files: the slug's role in
  every test is "distinct enough to not collide," never a value asserted on for its own
  content (verified no affected file's `unique_integer`-derived slug appears in an
  `assert`/`assert_receive` pattern match beyond equality-with-itself).
