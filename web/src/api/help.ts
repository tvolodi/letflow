/** Help API client — REQ-366 §2.1
 *
 *  Wraps `GET /api/v1/help/resolved` (`lib/letflow/routers/help.ex`, REQ-366
 *  §1, ELIXIR-DEV commit 452c29e0), following `web/src/api/exam.ts`'s own
 *  shape: a plain object of named functions wrapping `client.get`, typed
 *  against `web/src/types/help.ts`. Response-shape field names/casing
 *  confirmed directly against `resolved_help_json/3` in that router's
 *  source, not re-derived from the design doc alone.
 */

import { client } from './client'
import type { ResolvedHelpContent, ResolvedHelpContentResponse } from '@/types/help'

const BASE = '/api/v1/help'

function toResolvedHelpContent(json: ResolvedHelpContentResponse): ResolvedHelpContent {
  return {
    id: json.id,
    screenId: json.screen_id,
    processDefinitionId: json.process_definition_id,
    title: json.title,
    body: json.body,
    status: json.status,
    confirmedAt: json.confirmed_at,
    confirmedForDefinitionVersion: json.confirmed_for_definition_version,
    media: json.media,
    scope: json.scope,
    stale: json.stale,
  }
}

export const helpApi = {
  /** `GET /api/v1/help/resolved?screen_id=...[&process_definition_id=...]`.
   *  A 404 (no help authored for this screen yet) is a normal, expected
   *  response `client.get` surfaces as a rejected promise with
   *  `ApiError.status === 404` — `web/src/hooks/useHelpContent.ts` is the
   *  layer that treats that as "not-found", not an error (design §2.2.1). */
  getResolved: (screenId: string, processDefinitionId?: string): Promise<ResolvedHelpContent> =>
    client
      .get<ResolvedHelpContentResponse>(`${BASE}/resolved`, {
        screen_id: screenId,
        process_definition_id: processDefinitionId,
      })
      .then(toResolvedHelpContent),
}
