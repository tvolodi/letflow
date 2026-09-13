/** exam session API client — REQ-338
 *
 *  Follows web/src/api/definitions.ts's own shape: a plain object of named
 *  functions wrapping client.get/post/put, typed against web/src/types/exam.ts.
 *  Wraps REQ-335's ACTUAL route table
 *  (lib/letflow/routers/exam_sessions.ex's own moduledoc "Route table"),
 *  re-verified directly against that router's source, not the speculative
 *  paths this requirement's own description guessed at before REQ-335 landed:
 *
 *    | Handler             | Method/path                                       |
 *    |----------------------|---------------------------------------------------|
 *    | start_session        | POST   /exam-sessions                              |
 *    | get_session_state    | GET    /exam-sessions/:id                          |
 *    | autosave_answer      | PUT    /exam-sessions/:id/answers/:question_id     |
 *    | submit_session       | POST   /exam-sessions/:id/submit                   |
 *    | report_event         | POST   /exam-sessions/:id/events                   |
 *
 *  Mounted at `/exam-sessions` under the normal authenticated `/api/v1`
 *  forward (NOT decision 0028's unauthenticated capability-handle pattern),
 *  so every path below is `/api/v1/exam-sessions...`, matching
 *  web/src/api/definitions.ts's own `/api/v1/definitions` prefix convention.
 *
 *  Five named operations, matching this requirement's own description
 *  exactly (startSession, saveAnswer, submitSession, getSessionState,
 *  reportEvent) — REQ-335's real shapes did NOT differ from that description
 *  once its real routes were read (only the description's OWN speculative
 *  path guesses were wrong; the operation list held).
 *
 *  `queryExamRecords` below is this requirement's OWN, self-contained call
 *  onto the generic `POST /entities/query` route (the only record-read route
 *  in `lib/letflow/routers/entities.ex` — no dedicated "list exams" route
 *  exists, same finding REQ-336's own web/src/api/entities.ts documents).
 *  REQ-338 does not depend on REQ-336 (both requirements' own texts say so
 *  explicitly, and REQ-336 is currently blocked on ISS-0648), so this file
 *  does not import REQ-336's `entitiesApi` — it wraps the one generic route
 *  it needs directly, against the shared `EntityQueryRequest`/
 *  `EntityRecordsPage` types in web/src/types/api.ts (a pre-existing, shared
 *  type module, not one of REQ-336's own untracked files).
 */

import { client } from './client'
import type {
  AntiCheatSignalOutcome,
  AntiCheatSignalType,
  ExamAutosaveResponse,
  ExamSessionStateResponse,
  ExamSubmissionOutcome,
  SaveAnswerBody,
} from '@/types/exam'
import type { EntityQueryRequest, EntityRecordsPage } from '@/types/api'

const BASE = '/api/v1/exam-sessions'

export const examApi = {
  /** `POST /exam-sessions` — `candidate_id` is always the caller's own
   *  identity server-side; only `exam_id` is supplied here. */
  startSession: (examId: string) =>
    client.post<ExamSessionStateResponse>(BASE, { exam_id: examId }),

  /** `GET /exam-sessions/:id`. */
  getSessionState: (sessionId: string) =>
    client.get<ExamSessionStateResponse>(`${BASE}/${encodeURIComponent(sessionId)}`),

  /** `PUT /exam-sessions/:id/answers/:question_id` — `question_id` is a PATH
   *  segment, never a body field, matching the router's own shape. */
  saveAnswer: (sessionId: string, questionId: string, answer: SaveAnswerBody) =>
    client.put<ExamAutosaveResponse>(
      `${BASE}/${encodeURIComponent(sessionId)}/answers/${encodeURIComponent(questionId)}`,
      answer,
    ),

  /** `POST /exam-sessions/:id/submit`. */
  submitSession: (sessionId: string) =>
    client.post<ExamSubmissionOutcome>(`${BASE}/${encodeURIComponent(sessionId)}/submit`),

  /** `POST /exam-sessions/:id/events` — `type` is one of
   *  tab_switch | blur | fullscreen_exit (REQ-333's three accepted signal
   *  types); `action_taken` is never sent by the caller (the router has no
   *  such field in its own request schema). */
  reportEvent: (sessionId: string, type: AntiCheatSignalType) =>
    client.post<AntiCheatSignalOutcome>(`${BASE}/${encodeURIComponent(sessionId)}/events`, { type }),

  /** `POST /entities/query`, scoped to this requirement's own `exam` list
   *  screen. See this file's moduledoc comment above: the only record-read
   *  route in the entities router, called directly rather than through
   *  REQ-336's `entitiesApi.queryRecords`. */
  queryExamRecords: (query: Omit<EntityQueryRequest, 'entity_type'> = {}) =>
    client.post<EntityRecordsPage>('/api/v1/entities/query', { entity_type: 'exam', ...query }),
}
