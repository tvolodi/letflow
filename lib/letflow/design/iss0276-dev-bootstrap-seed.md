# Design: ISS-0276 — `mix letflow.seed` dev-bootstrap default tenant

**Issue:** ISS-0276 (`docs/issues/ISS-0276.yaml`, GH#546)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** Mix.Task module/function signature, call-sequence,
idempotency/guard behavior, and documentation-copy shape only. No implementation code,
no function bodies. ELIXIR-DEV writes the actual `.ex` file from this.

## 0. Sources read for this design

- `handoffs/WF03-ISS0276-20260822/step-01-issue-fixer.json` `result.summary` in full —
  ISSUE-FIXER's diagnosis: root cause is that no code path anywhere creates a
  `idp_realm_id = "bpm-default"` tenant row on a fresh dev database; the only existing
  chain that produces a usable tenant is `Letflow.Identity.create_tenant/1` →
  `Letflow.TenantProvisioning.provision_tenant_schema/1` →
  `Letflow.TenantProvisioning.replay_migrations/1`, currently reachable only via an
  authenticated `POST /tenants` (which itself needs a PLATFORM_ADMIN caller that doesn't
  exist yet on a fresh environment either).
- `docs/issues/ISS-0276.yaml` — full filing, fix direction, 3 acceptance criteria.
- `lib/letflow/identity.ex` lines ~560–598 (`create_tenant/1` — full `@doc`/`@spec`/body
  read) and `slug_unique_conflict?/1` (~719–725).
- `lib/letflow/tenant_provisioning.ex` — full `provision_tenant_schema/1` and
  `replay_migrations/2` `@doc`/`@spec`/body.
- `lib/letflow/routers/tenants.ex` lines ~198–237 — `@create_schema` field constraints
  and `handle_create/1`, confirming the exact attrs shape and error-handling precedent
  this task's own attrs/error-handling should match.
- `lib/letflow/repo.ex` full `init/2` — the `LETFLOW_DEV_DB_CONFIRMED` guard.
- `config/dev.exs` line 49 — `require_dev_db_confirmation: true` (dev-env-only; not set
  for `:test`).
- `lib/mix/tasks/letflow.copy_identity_tables.ex` (full) — this project's own
  established Mix.Task shape/style for a `Letflow.*` custom task: `use Mix.Task`,
  `@shortdoc`, `@moduledoc` with a `## Usage` section, `Mix.Task.run("app.start")` as the
  first line of `run/1`, `Mix.shell().info/1` on success, `Mix.raise/1` on failure —
  followed here as the naming/structure precedent.
- `README.md` "Running it" section (lines 79–186) — exact prose/fencing style used for
  setup-step documentation, followed for the doc addition below.
- `test/support/tenant_fixture.ex` — confirmed it does **not** set `idp_realm_id` and is
  test-only (`elixirc_paths(:test)`), so it is not a substitute dev-bootstrap path and is
  out of this design's scope.

## 1. Module

```
Mix.Tasks.Letflow.Seed
```

File: `lib/mix/tasks/letflow.seed.ex` (matches this directory's existing
`letflow.<name>.ex` filename convention — see `letflow.copy_identity_tables.ex`,
`letflow.check_toolchain.ex`).

Invocation: `mix letflow.seed`. No arguments, no options (matches
`letflow.copy_identity_tables`'s own no-args precedent — nothing about this task's scope
needs a flag; see §4 for why idempotency is a fixed behavior, not an opt-in flag).

```
@shortdoc "Provisions the default bpm-default tenant against a fresh dev database (ISS-0276)"

use Mix.Task

@impl Mix.Task
@spec run(args :: [String.t()]) :: :ok
def run(_args)
```

`@moduledoc` carries a `## Usage` section (matching `letflow.copy_identity_tables.ex`'s
own structure) stating: invocation, that it targets `letflow_dev` (so
`LETFLOW_DEV_DB_CONFIRMED=1` is required — §3), that it is idempotent (§4), and a
one-line description of what it creates (a `bpm-default` tenant, its Postgres schema,
and that schema's migrations).

## 2. Call sequence and exact attrs shape

`run/1`'s body, in order:

1. `Mix.Task.run("app.start")` — starts the `:letflow` OTP application (and therefore
   `Letflow.Repo`), exactly as `letflow.copy_identity_tables.ex` does. This is also where
   the `LETFLOW_DEV_DB_CONFIRMED` guard fires or doesn't — see §3.
2. Build the attrs map (a plain module-level literal inside `run/1`, not user input — no
   `Letflow.Api.Validation.validate/2` pass is needed here since there is no untrusted
   caller, unlike `Letflow.Routers.Tenants`'s `handle_create/1`; the literal is
   constructed to already satisfy `Tenant.create_changeset/3`'s cast/validation rules,
   the same shape `@create_schema` in `lib/letflow/routers/tenants.ex` documents):

   ```
   %{
     "slug" => "bpm-default",
     "display_name" => "Default Tenant",
     "idp_realm_id" => "bpm-default"
   }
   ```

   String keys (matching `create_tenant/1`'s documented "caller-validated map ... with
   keys `"slug"`/`"display_name"`/optionally `"idp_realm_id"`" — the same shape
   `Letflow.Routers.Tenants` passes through from `Validation.validate/2`'s output).
   `display_name` value `"Default Tenant"` is this design's own choice (no prior
   precedent fixes it) — flagged as an open question in §6 in case a more specific
   convention is wanted later; it has no behavioral effect (AC2 only depends on `slug`/
   `idp_realm_id`, not `display_name`).

3. `Letflow.Identity.create_tenant/1` called with that attrs map.
4. On `{:ok, %Tenant{id: tenant_id}}`: call `Letflow.TenantProvisioning.provision_tenant_schema/1`
   with `tenant_id`.
5. On that returning `{:ok, %Registration{}}`: call
   `Letflow.TenantProvisioning.replay_migrations/1` with the same `tenant_id` (arity-1 —
   default `migration_source` `nil`, resolving to `tenant_scoped_migrations/0` inside
   that function, same as `Letflow.Routers.Tenants`'s own call site per ISSUE-FIXER's
   diagnosis).
6. On that returning `{:ok, applied_versions}`: `Mix.shell().info/1` a one-line success
   message naming the tenant id and migration count. `run/1` returns `:ok`.

Every non-`{:ok, _}` return from steps 3, 4, or 5 is handled explicitly — see §4 and §5,
no case is left to fall through to an unmatched-clause `CaseClauseError`.

## 3. `LETFLOW_DEV_DB_CONFIRMED` interaction

**Resolution: no special-cased logic in this task at all — it inherits the existing
guard automatically, and that is the correct, complete behavior.**

`config/dev.exs` sets `require_dev_db_confirmation: true` only under `MIX_ENV=dev`
(confirmed: not present in `config/test.exs`'s equivalent block). `Letflow.Repo.init/2`
reads that config key and raises unless `LETFLOW_DEV_DB_CONFIRMED` is set, and this
check fires the moment `Letflow.Repo` actually starts — which happens inside this task's
own step 1 (`Mix.Task.run("app.start")`), under whatever `MIX_ENV` the task is invoked
with. So:

- Run as `mix letflow.seed` (implicit `MIX_ENV=dev`) without the env var set: `app.start`
  itself raises `Letflow.Repo.init/2`'s existing message before any of this task's own
  code runs. The task requires no `System.get_env` check, no duplicate guard, no
  task-specific error message — `Mix.Task.run("app.start")` already fails closed.
- Run as `LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed`: `app.start` succeeds, the task
  proceeds normally.
- Run as `MIX_ENV=test MIX_TEST_PARTITION=<N> mix letflow.seed` (the isolated-partition
  pattern already documented in `README.md` and `lib/letflow/repo.ex`'s own raised
  message): no confirmation needed, since `require_dev_db_confirmation` is not set for
  `:test`. This is also how a future automated regression test for this issue can invoke
  the task without needing the env var.

This task is **not exempted** as a "one-time bootstrap action" — it is exactly the kind
of write against the shared `letflow_dev` database the guard exists to gate (per
`lib/letflow/repo.ex`'s own moduledoc-adjacent comment: concurrent workspaces sharing one
`letflow_dev`). Treating it as exempt would silently reopen the exact multi-workspace
corruption risk the guard was built to close. No code changes to `lib/letflow/repo.ex`
or `config/dev.exs` are needed or in scope.

## 4. Idempotency (re-run behavior)

**Resolution: re-running `mix letflow.seed` against a database that already has a
`bpm-default` tenant is a successful no-op, not an error and not a crash.**

Rationale: `provision_tenant_schema/1` and `replay_migrations/1` are already documented
idempotent (`provision_tenant_schema/1`'s own `@doc`: "Calling this twice for the same
`tenant_id` is not an error"; `replay_migrations/1`'s underlying `Ecto.Migrator.run/4`
only applies not-yet-applied versions). The one non-idempotent link is
`create_tenant/1`, which returns `{:error, :duplicate_slug}` on a second call — so this
task must special-case exactly that one return value to reach the same
already-idempotent continuation the fresh-database path reaches. Design:

- On `Letflow.Identity.create_tenant/1` returning `{:error, :duplicate_slug}`: **do not
  treat this as a task failure.** Instead, look up the existing tenant by realm —
  `Letflow.Identity.resolve_tenant_by_realm("bpm-default")` (the same read this issue's
  own regression scenario, AC2, exercises) — and if it returns `{:ok, %Tenant{id:
  tenant_id}}`, continue the call sequence from step 4 (§2) using that `tenant_id`
  instead of a freshly-created one. This reaches `provision_tenant_schema/1` /
  `replay_migrations/1`'s own already-idempotent behavior on every re-run, so re-running
  the task repeatedly converges rather than erroring.
  - If `resolve_tenant_by_realm/1` instead returns `{:error, :not_found}` on the
    `:duplicate_slug` branch (meaning some other tenant already holds the `bpm-default`
    *slug* but with a different or absent `idp_realm_id` — a slug collision that isn't
    this task's own prior run), `Mix.raise/1` with a message naming that exact
    conflict, rather than silently proceeding against the wrong tenant or masking a real
    naming collision. This is a real, distinct failure mode (a human or another tool
    created a differently-configured `bpm-default`-slugged tenant first) and must not be
    swallowed.
- `Mix.shell().info/1`'s success message (§2 step 6) is worded to cover both paths (e.g.
  "created" vs. "already present, re-provisioned/re-verified") so a developer re-running
  the task sees which branch executed, without that distinction changing `run/1`'s exit
  behavior (`:ok` either way).

## 5. Error handling for the two provisioning steps

`provision_tenant_schema/1` and `replay_migrations/1` are internal-precondition calls
here (the `tenant_id` passed always comes from a `Tenant` this task itself just
created-or-resolved, never external input), so their failure modes are treated as fatal
task failures via `Mix.raise/1`, not recoverable branches — matching
`letflow.copy_identity_tables.ex`'s own `Mix.raise/1`-on-failure precedent:

- `provision_tenant_schema/1` returning `{:error, :tenant_not_found}`,
  `{:error, :invalid_tenant_id}`, or `{:error, term()}` → `Mix.raise/1`, message includes
  the tenant id and `inspect(reason)`.
- `replay_migrations/1` returning `{:error, :tenant_not_provisioned}` or
  `{:error, {:migration_failed, exception}}` → `Mix.raise/1`, message includes the
  tenant id and the wrapped exception/reason.
- `create_tenant/1` returning `{:error, %Ecto.Changeset{}}` (a validation failure on this
  task's own hardcoded literal attrs, not expected in practice but not assumed
  impossible) → `Mix.raise/1` with `inspect(changeset.errors)`, since a hardcoded literal
  failing changeset validation indicates a schema/task drift bug, not a runtime
  condition to recover from.

No exception is left to propagate as a raw, unexplained crash — every non-`:ok` branch
from every one of the three calls (across both the fresh-create and duplicate-slug
paths) maps to either a handled continuation (§4) or a `Mix.raise/1` with a stated
reason.

## 6. Open questions (explicitly unresolved — not decided here)

- `display_name` value: this design fixes it to the literal `"Default Tenant"` (§2 step
  2) since nothing in the codebase established a different convention; ELIXIR-DEV should
  treat this as this design's own placeholder choice, not a pre-existing standard, and
  may flag it back if a different value is wanted — it has no effect on any acceptance
  criterion.
- Whether a future automated regression test for ISS-0276 invokes this Mix.Task
  directly (`Mix.Task.run("letflow.seed")` inside a test, per `Mix.Task.rerun/1`
  semantics for re-invocation across tests) or instead calls the same three
  `Identity`/`TenantProvisioning` functions directly the way `test/support/tenant_fixture.ex`
  does, is left to TEST-DESIGNER — this design only specifies the task's own behavior,
  not test strategy.

## 7. Documentation (AC3)

**Location: `README.md`, "Running it" section, immediately after the existing
`LETFLOW_DEV_DB_CONFIRMED=1 mix ecto.setup` / `LETFLOW_DEV_DB_CONFIRMED=1 mix run
--no-halt` fenced block (currently lines 81–86) and before the `curl -s
localhost:4000/health` block** — i.e., seeding is the next setup step after migrating
and before running/exercising the server, matching the natural order a developer
follows setting up a fresh environment (docker compose → deps.get → migrate → seed →
run).

Added text (prose + one fenced command block, matching the surrounding section's own
style):

- A fenced block: `LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed`.
- One short paragraph stating: this provisions the `bpm-default` tenant (slug and
  `idp_realm_id` both `bpm-default`) that authenticated requests bearing a
  `bpm-default`-realm token resolve against (`AuthPipeline`'s tenant-resolution step,
  `Letflow.Identity.resolve_tenant_by_realm/1`); required once per fresh `letflow_dev`
  database (a fresh `docker compose up -d` volume, or after a `mix ecto.reset`); safe to
  re-run (idempotent — §4 above, phrased for a reader without linking to this internal
  design doc).
- No new top-level README section — this is one step folded into the existing "Running
  it" narrative, since it is exactly that: a step in running the app locally, not a
  separate concern.

`lib/mix/tasks/letflow.seed.ex`'s own `@moduledoc`/`@shortdoc` (§1) is the second,
code-adjacent copy of this same information (`mix help letflow.seed` reachability) — both
locations are required for AC3 ("documented ... so a developer setting up a fresh
environment finds it without reading this issue"): the README for the setup-flow reader,
the moduledoc for the `mix help`/source reader.

## 8. Acceptance-criteria coverage map

| ISS-0276 AC | Design element that satisfies it |
|---|---|
| AC1 (fresh-DB seed run creates `idp_realm_id = "bpm-default"` row) | §2 steps 1–4: `create_tenant/1` with `"idp_realm_id" => "bpm-default"` in the fresh-create branch (§4's duplicate-slug branch does not apply on a fresh DB). |
| AC2 (authenticated `bpm-default`-realm request then resolves a tenant) | Direct consequence of AC1's row plus `provision_tenant_schema/1` + `replay_migrations/1` (§2 steps 4–5) actually provisioning the schema so the tenant is fully usable, not just a bare `tenants` row — `resolve_tenant_by_realm/1` (used internally, `AuthPipeline`) reads exactly that row. |
| AC3 (documented) | §7 — README "Running it" addition plus the task's own `@moduledoc`. |
