/** definitionRollback — REQ-371: operator-facing rollback/withdrawal API client
 *
 *  Dedicated small module (kept out of `definitions.ts`), matching this
 *  codebase's precedent of one small API module per distinct backend concern
 *  (c.f. `api/audit.ts`). See
 *  `lib/letflow/design/req371-rollback-withdrawal-screen.md` §3 — field
 *  names below are copied verbatim from `rollback_map/1`
 *  (`lib/letflow/routers/definitions.ex:1186-1195`); no renaming, no
 *  camelCase conversion.
 */

import { client } from './client'

export interface RollbackRequest {
  target_version: string
}

export interface RollbackResult {
  definition_id: string
  version: string
  rolled_back_from_version: string
  superseded_review_id: string | null
  event_id: string
}

export const definitionRollbackApi = {
  rollback: (processKey: string, body: RollbackRequest) =>
    client.post<RollbackResult>(
      `/api/v1/definitions/${encodeURIComponent(processKey)}/rollback`,
      body,
    ),
}
