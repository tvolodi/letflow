/** platformMigrations — REQ-375: operator-facing rollout-status screen's API client
 *
 *  Dedicated small module (matching the existing one-module-per-backend-concern
 *  precedent `api/definitionRollback.ts` follows, c.f. `api/audit.ts`). See
 *  `lib/letflow/design/req375-rollout-status-screen.md` §3 — field names below
 *  are copied verbatim from `lib/letflow/routers/platform_migrations.ex`'s
 *  `rollout_map/1`/`outcome_map/1`; no renaming, no camelCase conversion.
 *
 *  Backend: REQ-374 (shipped, commit `eaa8abe6`, PR 1693) — no new endpoint,
 *  no new field, no change to `lib/letflow/`.
 */

import { client } from './client'

export interface ColumnSpecRequest {
  pg_type: string
  references_entity?: string | null
  generated_as?: string | null
}

export interface StartRolloutRequest {
  entity_type: string
  attribute: string
  column_spec: ColumnSpecRequest
}

export interface RolloutOutcome {
  tenant_id: string
  status: 'pending' | 'succeeded' | 'failed'
  completed_at: string | null // ISO 8601, or null
  reason: string | null
  already_current: boolean
}

export interface Rollout {
  id: string
  entity_type: string
  attribute: string
  status: 'running' | 'completed'
  started_at: string // ISO 8601
  completed_at: string | null
}

export interface RolloutResult {
  rollout: Rollout
  outcomes: RolloutOutcome[]
}

export const platformMigrationsApi = {
  start: (body: StartRolloutRequest) =>
    client.post<RolloutResult>('/api/v1/platform-migrations/rollouts', body),

  status: (rolloutId: string) =>
    client.get<RolloutResult>(`/api/v1/platform-migrations/rollouts/${encodeURIComponent(rolloutId)}`),

  resume: (rolloutId: string) =>
    client.post<RolloutResult>(`/api/v1/platform-migrations/rollouts/${encodeURIComponent(rolloutId)}/resume`, {}),
}
