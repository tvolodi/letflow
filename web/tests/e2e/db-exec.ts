/**
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
