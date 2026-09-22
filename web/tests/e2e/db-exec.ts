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
