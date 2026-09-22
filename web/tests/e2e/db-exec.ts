/**
 * Real, non-mocked backend-setup helpers for
 * `platform-migration-partial-failure-resume.pipeline.e2e.spec.ts` (REQ-375
 * AC5). Two independent real-infra techniques live here:
 *
 *   - `runSqlAgainstDevPostgres`/`poisonCompanySchemaSql`/`cureCompanySchemaSql`
 *     — raw DDL via `docker compose exec postgres psql`, for the one company
 *     that must genuinely fail.
 *   - `createActiveEntityDefinition` — calls the real
 *     `Letflow.Entities.Definitions` context functions via `mix run --no-start -e`,
 *     for the companies that must genuinely succeed.
 *
 * `runSqlAgainstDevPostgres` — raw SQL execution against the real Postgres
 * instance backing an e2e run's target backend, via
 * `docker compose exec <service> psql`.
 *
 * Why this exists (REQ-375's e2e pipeline spec, AC5): a rollout started
 * through `POST /platform-migrations/rollouts` (`Letflow.Platform.MigrationRollout.start_rollout/3`)
 * has NO per-company scope parameter — confirmed by reading
 * `lib/letflow/platform/migration_rollout.ex`'s `active_company_tenant_ids/0`
 * (every :active tenant with a Registration row, unconditionally) and
 * `lib/letflow/routers/platform_migrations.ex` (the request body accepts only
 * `entity_type`/`attribute`/`column_spec`, no tenant filter at all). There is
 * therefore no real HTTP-only way to make exactly ONE company's schema fail
 * `Letflow.TenantProvisioning`'s real `check_additive_only/3`
 * `information_schema.columns` check while every other company succeeds —
 * the one thing this e2e spec's scenario (migration-partial-failure-resume)
 * needs to exercise for real, per its own precondition 2 ("one company's
 * workspace is arranged so the change under test cannot be applied to it").
 *
 * `test/letflow/platform/migration_rollout_test.exs`'s own `poison_company_schema!/3`
 * solves this identical problem, in the ExUnit suite, with a direct
 * `Repo.query!/2` CREATE TABLE against the target tenant's real schema —
 * this function is the Playwright-side equivalent of that exact technique,
 * not a substitute or mock for it. The resulting DDL conflict this produces
 * is real: `check_additive_only/3` detects it via a genuine
 * `information_schema.columns` read, exactly as it would for any real
 * pre-existing column collision.
 *
 * Deliberately NOT a new `pg`-client npm dependency (this file has zero
 * imports beyond Node's own `node:child_process`) — `docker compose` and the
 * `postgres` service it manages are already this repo's own standard
 * local/CI stack (`docker-compose.yml`, CLAUDE.md's "Zero manual work...
 * start docker compose yourself"), so shelling into the already-running
 * `postgres` service via its own `psql` client adds no new tooling
 * requirement beyond what every other agent in this pipeline already
 * assumes is available. `LETFLOW_PG_COMPOSE_SERVICE`/`LETFLOW_PG_DATABASE`/
 * `LETFLOW_PG_USER` are escape hatches for a CI environment whose compose
 * project/service naming differs from local dev's `docker-compose.yml`
 * (service `postgres`, `POSTGRES_DB: letflow_dev`, `POSTGRES_USER: letflow`
 * — see that file and `config/dev.exs`, which the real backend under test
 * itself connects with).
 */

import { execFileSync } from 'node:child_process'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

// ESM module scope has no `__dirname` -- derive it from `import.meta.url`
// (this repo's web/ is ESM, confirmed by playwright.config.ts's own `import`
// syntax and package.json's module type).
const CURRENT_DIR = path.dirname(fileURLToPath(import.meta.url))

/** `web/tests/e2e/db-exec.ts` -> repo root (three levels up). */
const REPO_ROOT = path.resolve(CURRENT_DIR, '../../..')

export function runSqlAgainstDevPostgres(sql: string): void {
  const composeService = process.env.LETFLOW_PG_COMPOSE_SERVICE ?? 'postgres'
  const dbName = process.env.LETFLOW_PG_DATABASE ?? 'letflow_dev'
  const dbUser = process.env.LETFLOW_PG_USER ?? 'letflow'

  execFileSync(
    'docker',
    ['compose', 'exec', '-T', composeService, 'psql', '-U', dbUser, '-d', dbName, '-v', 'ON_ERROR_STOP=1'],
    { input: sql, stdio: ['pipe', 'inherit', 'inherit'] },
  )
}

/**
 * Mirrors `Letflow.TenantProvisioning.schema_name_for_tenant/1`'s own
 * `"tenant_" <> <32 lowercase hex chars>` derivation (tenant_provisioning.ex
 * ~line 214) — a plain, deterministic string transform, not a value this
 * helper needs to look up from anywhere.
 */
export function tenantSchemaName(tenantId: string): string {
  return `tenant_${tenantId.replace(/-/g, '')}`
}

/**
 * The exact real-DDL-poison technique
 * `test/letflow/platform/migration_rollout_test.exs`'s `poison_company_schema!/3`
 * uses (same column set, same conflicting `bigint` type for a `text`
 * promotion) — reproduced here byte-for-byte in shape, not reinvented.
 */
export function poisonCompanySchemaSql(schema: string, tableName: string, columnName: string): string {
  return `
    CREATE TABLE "${schema}"."${tableName}" (
      id uuid PRIMARY KEY,
      record_id uuid NOT NULL UNIQUE,
      field_values jsonb NOT NULL DEFAULT '{}'::jsonb,
      deleted boolean NOT NULL DEFAULT false,
      entity_def_version bytea,
      last_event_global_seq bigint NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      "${columnName}" bigint
    );
  `
}

/** Mirrors `cure_company_schema!/3`'s `ALTER TABLE ... DROP COLUMN`. */
export function cureCompanySchemaSql(schema: string, tableName: string, columnName: string): string {
  return `ALTER TABLE "${schema}"."${tableName}" DROP COLUMN "${columnName}";`
}

/**
 * `createActiveEntityDefinition` — real, HTTP-independent setup for a
 * precondition this e2e spec's target rollout attribute needs on every
 * HEALTHY company (never the poisoned one — see below).
 *
 * Why this exists (UAT-RUNNER's live-run finding, second real gap after
 * ISS-0777): `Letflow.TenantProvisioning.do_run_column_promotion/2` calls
 * `ensure_entity_table/2` before `check_additive_only/3` -- and
 * `ensure_entity_table/2`'s OWN table-doesn't-exist-yet branch,
 * `create_and_populate_entity_table/3` (tenant_provisioning.ex ~line 1555),
 * requires `Letflow.Entities.Definitions.get_active_definition_by_name/2` to
 * find a real, ACTIVE entity definition for the target `entity_type` in that
 * tenant's schema -- with none registered, it genuinely returns
 * `{:error, :not_found}`, and the company fails, not succeeds. A company
 * whose `entity_<entity_type>` table ALREADY exists (the poisoned company,
 * via `poisonCompanySchemaSql` above) never reaches this branch at all
 * (`entity_table_exists?/2` short-circuits straight to `check_additive_only/3`)
 * -- so only the tenants meant to SUCCEED need this step; the poisoned one
 * does not, and must not (`create_and_populate_entity_table` never runs for
 * it either way, so calling this for it would be dead setup, not a fix).
 *
 * No HTTP endpoint reaches this: `POST /entities/definitions` /
 * `.../activate` (`lib/letflow/routers/entities.ex`) resolve their target
 * tenant schema from the CALLING TOKEN's own Keycloak realm
 * (`prefix!(conn)`), so writing into bilimbaga's/swiftroute's schema over
 * HTTP would need a real `:EntitiesDefinitionsWrite`-permission fixture user
 * registered in EACH of those tenants' own realms -- none is known to exist
 * for this pair, and inventing one is a bigger, riskier addition than this
 * fix warrants. Shelling into `mix run --no-start -e` (the same repo
 * checkout backing the running server under test, per `BPM_TEST_URL`) and
 * calling `Letflow.Entities.Definitions.create_definition/2` +
 * `.activate_definition/4` DIRECTLY is the real, non-mocked equivalent of
 * `test/letflow/platform/migration_rollout_test.exs`'s own
 * `create_active_definition!/3` fixture (same field shape: `amount`/`notes`
 * string fields) -- the exact functions that ExUnit fixture calls, not a
 * reimplementation of entity-definition persistence via raw SQL (which would
 * risk getting the real, non-trivial `content_hash`/`repository_artifacts`
 * persistence shape wrong). `--no-start` (skip `Letflow.Application.start/2`)
 * deliberately avoids booting Bandit/the HTTP listener a second time on top
 * of the already-running dev server -- only `:postgrex`/`:ecto_sql` and
 * `Letflow.Repo` itself are started, which is all `Definitions.create_definition/2`
 * needs.
 */
export function createActiveEntityDefinition(schema: string, entityType: string): void {
  const elixirScript = `
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Letflow.Repo.start_link()

    schema = "${schema}"
    entity_type = "${entityType}"

    definition = %{
      name: entity_type,
      display_name: String.capitalize(entity_type),
      fields: [
        %{name: "amount", type: :string, queried: true},
        %{name: "notes", type: :string}
      ]
    }

    actor_id = Ecto.UUID.generate()

    {:ok, entity_definition} =
      Letflow.Entities.Definitions.create_definition(
        %{definition: definition, created_by: actor_id},
        schema
      )

    {:ok, _activated} =
      Letflow.Entities.Definitions.activate_definition(
        entity_definition.name,
        actor_id,
        "e2e fixture setup (platform-migration-partial-failure-resume)",
        schema
      )

    IO.puts("createActiveEntityDefinition: OK")
  `

  execFileSync('mix', ['run', '--no-start', '-e', elixirScript], {
    cwd: REPO_ROOT,
    env: { ...process.env, MIX_ENV: process.env.MIX_ENV ?? 'dev' },
    stdio: 'inherit',
  })
}

/**
 * REQ-377 fixture helpers for `platform-partition-retention-drop.pipeline.e2e.spec.ts`
 * -- producing a REAL month of event history old enough to be eligible for
 * `Letflow.EventStore.PartitionMaintenance.retire_month/3` against the real,
 * shipped `min_partition_age_days/0` default (400 days), not a shortened
 * test-only override.
 *
 * Why this can't just reuse `min_partition_age_days`'s config override
 * technique: `test/letflow/event_store/partition_maintenance_test.exs` and
 * `test/letflow/routers/event_retention_test.exs` override
 * `Application.put_env(:letflow, :event_retention, min_partition_age_days: 1)`
 * from INSIDE the same BEAM node the test runs in -- that process IS the one
 * that later reads the override back. This e2e spec drives a SEPARATE,
 * already-running server process (`BPM_TEST_URL`) over real HTTP; there is
 * no supported HTTP surface to change that server's own Application env at
 * runtime, and restarting it mid-suite would be far riskier than the
 * alternative below. Instead: create a partition whose month genuinely IS
 * more than 400 days in the past -- `eligible?/2`'s real, unmodified
 * `today >= last_day(month) + min_partition_age_days` check then finds it
 * eligible on its own, no server-side config change of any kind needed.
 * `PartitionMaintenance.ensure_future_partitions/2` only ever creates
 * partitions looking FORWARD from "now" (§3 of its own moduledoc), so a
 * partition this old is never auto-created -- it must be fabricated
 * directly, the same real-DDL technique `poisonCompanySchemaSql` above
 * already established for a different fixture need.
 *
 * `daysAgoOffset` is derived from the caller's own fixture id (not a fixed
 * literal) so that a repeat run of this spec against the SAME long-lived
 * dev/CI Postgres instance targets a fresh, never-previously-retired month
 * rather than colliding with a month an earlier run already retired (once
 * `retire_month/3` detaches a month's partition from `events`, that same
 * month can never become "eligible" again -- it is no longer attached, so
 * `eligible_months/1` simply stops listing it, which would make a second
 * run's `oldest_eligible_month` computation either pick a different month
 * anyway or -- if this were the LAST eligible month platform-wide --
 * surface a spurious `:no_eligible_month`/409 having nothing to do with a
 * real defect). Spread across ~8 years of possible months (401..3521 days
 * back) so collision probability across independent runs stays negligible
 * -- the same "fixture-unique, not shared" discipline
 * `platform-migration-partial-failure-resume`'s own `fixtureId`-derived
 * `entity_type`/`attribute` already establishes for a different resource,
 * applied here to a calendar month instead of an identifier string. This is
 * a real calendar-date computation from a fixture id, not unseeded
 * wall-clock-dependent randomness affecting pass/fail -- the spec's
 * assertions never depend on which particular month was chosen, only that
 * IT exists and becomes retired.
 */
export interface BackdatedMonth {
  year: number
  month: number
  /** `events_y<year>m<MM>` -- the exact partition name PartitionMaintenance itself derives. */
  partitionName: string
}

/** Picks a real calendar month strictly more than 400 days before today, deterministically from `fixtureId`. */
export function pickEligibleBackdatedMonth(fixtureId: string): BackdatedMonth {
  const seed = parseInt(fixtureId.replace(/-/g, '').slice(0, 8), 16)
  const daysAgoOffset = 401 + (seed % 3120) // 401..3521 days back (> 400-day min_partition_age_days, spread ~8 years)

  const target = new Date()
  target.setUTCDate(target.getUTCDate() - daysAgoOffset)
  const year = target.getUTCFullYear()
  const month = target.getUTCMonth() + 1 // JS months are 0-based; partition-name/bounds convention is 1-based

  return { year, month, partitionName: `events_y${year}m${String(month).padStart(2, '0')}` }
}

function pad2(n: number): string {
  return String(n).padStart(2, '0')
}

/** `[fromInclusive, toExclusive)` calendar-month bounds, same convention `month_bounds_str/2` uses on the ExUnit side. */
function monthBoundsStr(year: number, month: number): { from: string; to: string } {
  const nextMonth = month === 12 ? 1 : month + 1
  const nextYear = month === 12 ? year + 1 : year
  return { from: `${year}-${pad2(month)}-01`, to: `${nextYear}-${pad2(nextMonth)}-01` }
}

/**
 * Real DDL: attaches a new `events_y<year>m<MM>` partition to `events` for a
 * real, backdated calendar-month range -- mirrors
 * `partition_maintenance_test.exs`'s own `create_events_month_partition!/3`
 * and priv/repo/migrations/20260922000002_create_events_p_initial_partitions.exs's
 * `create_month_partition!/3` DDL shape exactly.
 */
export function createBackdatedEventPartitionSql(schema: string, month: BackdatedMonth): string {
  const { from, to } = monthBoundsStr(month.year, month.month)
  return `CREATE TABLE "${schema}"."${month.partitionName}" PARTITION OF "${schema}".events FOR VALUES FROM ('${from}') TO ('${to}');`
}

/**
 * Seeds ONE real event row inside the backdated partition above (mid-month,
 * so it always routes into that exact partition regardless of month
 * length) -- so this scenario retires a month that genuinely held history,
 * not an empty partition. Column list mirrors
 * `20260922000001_create_events_partitioned.exs`'s real `events_p` column
 * list (pre-swap `events`/`events_p` are the same shape); `global_seq` is
 * left to its own sequence default. A fresh, real UUID per call (never a
 * shared literal) keeps repeat runs from colliding on `event_id`'s PK.
 */
export function seedHistoricalEventSql(schema: string, month: BackdatedMonth, eventId: string, instanceId: string): string {
  const midMonth = `${month.year}-${pad2(month.month)}-15 12:00:00`
  return `
    INSERT INTO "${schema}"."events"
      (event_id, created_at, instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata)
    VALUES
      ('${eventId}', '${midMonth}', '${instanceId}', 'req377_e2e_seed_event', '{}'::jsonb, '${instanceId}', 1, 'req377-e2e-${eventId}', '{}'::jsonb);
  `
}

/**
 * REQ-384 EO-001 fixture helper for `tenant-cache.pipeline.e2e.spec.ts` --
 * creates and activates a real process definition DIRECTLY inside tenant B's
 * own schema, bypassing HTTP entirely.
 *
 * Why direct `mix run`, not an HTTP `POST /api/v1/definitions`: exactly the
 * same gap `createActiveEntityDefinition` above documents for a different
 * resource -- `Letflow.Definitions.create/2`/`activate/2` resolve their
 * target tenant schema from the CALLING TOKEN's own Keycloak realm
 * (`conn.assigns.scoped_opts`, `lib/letflow/routers/definitions.ex`), so an
 * HTTP write into tenant B's schema would need a real admin credential
 * that can actually authenticate AS tenant B. None exists here: REQ-384's
 * `POST /api/v1/onboarding` (`Letflow.Routers.Onboarding.handle_create/1`)
 * explicitly does not provision a Keycloak realm/client/admin-user for the
 * tenant it creates (see that module's own moduledoc, "What is deliberately
 * NOT ported") -- `Letflow.Identity.create_tenant/1` is called with
 * `oidc_mode: :disabled`, so tenant B's `idp_realm_id` stays nil and no
 * Keycloak-side account for `admin_email`/`admin_username` is ever created.
 * There is therefore no real bearer token this test could obtain that is
 * scoped to tenant B -- direct `mix run --no-start -e` against the already-
 * provisioned real schema (confirmed synchronously ready by the time
 * `POST /onboarding` returns, per that router's own moduledoc) is the only
 * real, non-mocked way to seed tenant-B-owned data for this fixture.
 */
export function createActiveDefinitionInSchema(schema: string, name: string, version: string): void {
  const elixirScript = `
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Letflow.Repo.start_link()

    schema = "${schema}"
    name = "${name}"
    version = "${version}"

    graph = %{
      "nodes" => [
        %{"id" => "n1", "node_type" => "START", "label" => "Start", "attributes" => nil},
        %{
          "id" => "n2",
          "node_type" => "HUMAN_TASK",
          "label" => "Task",
          "attributes" => %{"role" => "admin-user", "assignee_type" => "user", "assignee_ref" => "admin-user"}
        },
        %{"id" => "n3", "node_type" => "END", "label" => "End", "attributes" => nil}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "n1", "target" => "n2"},
        %{"id" => "e2", "source" => "n2", "target" => "n3"}
      ]
    }

    attrs = %{
      name: name,
      version: version,
      description: "REQ-384 EO-001 tenant-B marker fixture (tenant-cache.pipeline.e2e.spec.ts)",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    {:ok, definition} = Letflow.Definitions.create(attrs, prefix: schema)
    {:ok, _activated} = Letflow.Definitions.activate(definition.id, prefix: schema)

    IO.puts("createActiveDefinitionInSchema: OK id=#{definition.id}")
  `

  execFileSync('mix', ['run', '--no-start', '-e', elixirScript], {
    cwd: REPO_ROOT,
    // Letflow.Repo.init/2's require_dev_db_confirmation guard (config/dev.exs)
    // refuses to connect to the shared letflow_dev database without this --
    // the deliberate escape hatch that guard's own error text names for
    // "genuinely need the interactive dev environment" use. Required here
    // (unlike `createActiveEntityDefinition` above, written before that
    // guard existed): this script MUST land in the same letflow_dev database
    // the real running BPM_TEST_URL backend serves from -- tenant B's schema
    // only exists there, not in any MIX_TEST_PARTITION test database.
    env: { ...process.env, MIX_ENV: process.env.MIX_ENV ?? 'dev', LETFLOW_DEV_DB_CONFIRMED: '1' },
    stdio: 'inherit',
  })
}

/**
 * REQ-384 EO-001 fixture helper for `tenant-cache.pipeline.e2e.spec.ts` --
 * inserts a real `tenant_memberships` row directly via SQL.
 *
 * Why direct SQL, not an HTTP write: `priv/repo/migrations/20260922000011_create_tenant_memberships.exs`'s
 * own header comment and `lib/letflow/identity/tenant_membership.ex`'s moduledoc
 * both state this table is ADMIN-WRITE-ONLY and that "no application-code writer
 * ships with REQ-384" -- `Letflow.Identity` exposes only
 * `list_memberships_for_subject/1` (read), never a create function, and no
 * router mounts a write route for this table (design
 * `lib/letflow/design/req384-tenant-switcher-cache-isolation.md` SS1.1, OQ-2).
 * This is the exact same "no HTTP path exists for the fixture this spec needs"
 * situation `createActiveEntityDefinition` above documents for a different
 * table -- direct SQL is the only real, non-mocked way to create this row.
 *
 * `subjectKey` must already be normalized (lower-cased, trimmed) exactly as
 * `TenantMembership.normalize_subject_key/1`'s write-side changeset would --
 * this helper does not re-normalize, matching that module's own "normalize
 * once, at the caller" discipline.
 *
 * Public-schema table (no tenant-prefixed schema qualifier) -- same tier as
 * `tenants` itself (design SS1.1).
 */
export function insertTenantMembershipSql(
  id: string,
  subjectKey: string,
  tenantId: string,
  displayLabel: string,
): string {
  return `
    INSERT INTO tenant_memberships (id, subject_key, tenant_id, display_label, inserted_at, updated_at)
    VALUES ('${id}', '${subjectKey}', '${tenantId}', '${displayLabel}', NOW(), NOW())
    ON CONFLICT (subject_key, tenant_id) DO NOTHING;
  `
}

/** Cleanup counterpart to `insertTenantMembershipSql` -- removes exactly the row this test run created. */
export function deleteTenantMembershipSql(id: string): string {
  return `DELETE FROM tenant_memberships WHERE id = '${id}';`
}
