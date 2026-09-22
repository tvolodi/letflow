/** eventRetention — REQ-377: operator-facing history-retirement screen's API
 *  client for the new `/event-retention` backend surface (built as part of
 *  REQ-377 itself — REQ-376 shipped the retirement mechanism but no HTTP
 *  API; see `lib/letflow/design/req377-history-retirement-screen.md` §0).
 *
 *  Dedicated small module (matching `api/platformMigrations.ts`'s own
 *  one-module-per-backend-concern precedent). Field names below are copied
 *  verbatim from the design's §2.1/§2.3 response shapes — no renaming, no
 *  camelCase conversion.
 */

import { client } from './client'

export interface RetentionSummary {
  oldest_eligible_month: { year: number; month: number } | null
  protected_record_count: number
  tenant_schema_count: number
  computed_at: string // ISO 8601
}

export interface RetirementOutcome {
  tenant_id: string
  status: 'succeeded' | 'skipped' | 'failed' | 'pending'
  retired_partition: string | null
  protected_rows_relocated: number | null
  resumed_from: 'not_started' | 'pending_detach' | 'detached_standalone' | 'already_retired' | null
  reason: string | null
  completed_at: string | null
}

export interface Retirement {
  id: string
  year: number | null
  month: number | null
  status: 'running' | 'completed' | 'failed'
  requested_by: string
  started_at: string // ISO 8601
  completed_at: string | null
}

export interface RetirementResult {
  retirement: Retirement
  outcomes: RetirementOutcome[]
}

export const eventRetentionApi = {
  summary: () => client.get<RetentionSummary>('/api/v1/event-retention/summary'),

  // §2.3 -- start's response body is a Retirement only (no outcomes yet: the
  // 202 fires before any tenant-schema fanout work has produced an outcome).
  start: () => client.post<Retirement>('/api/v1/event-retention/retirements', {}),

  status: (retirementId: string) =>
    client.get<RetirementResult>(`/api/v1/event-retention/retirements/${encodeURIComponent(retirementId)}`),
}
