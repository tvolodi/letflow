/** web/src/modules/exam/index.ts — REQ-412 / ISS-0844
 *
 *  Exports the exam module's ModuleDefinition for registration in
 *  web/src/modules/registry.ts. The definition provides:
 *
 *  - Five route objects (actual React Router RouteObjects, no guard wrapper —
 *    registry.ts wraps them in ModuleGuard when building the router's list)
 *  - Two nav items: /exam for CANDIDATE, /admin/bilimbaga for
 *    PLATFORM_ADMIN and PROCESS_OPERATOR
 *
 *  SPA paths (unchanged per ISS-0844 / REQ-412):
 *    exam
 *    exam/:examId/session
 *    exam/sessions/:sessionId/result
 *    admin/bilimbaga
 *    admin/bilimbaga/:entityType
 */
import type { ModuleDefinition } from '@/modules/types'
import { examRouteObjects } from './examRoutes'

export const examModuleDefinition: ModuleDefinition = {
  id: 'exam',
  depends_on: [],
  routeObjects: examRouteObjects,
  navItems: [
    { to: '/exam', label: 'Exams', roles: ['CANDIDATE'] },
    { to: '/admin/bilimbaga', label: 'Question Bank', roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  ],
}
