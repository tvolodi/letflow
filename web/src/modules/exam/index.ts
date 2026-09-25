/** web/src/modules/exam/index.ts — REQ-412
 *
 *  Exports the exam module's ModuleDefinition for registration in
 *  web/src/modules/registry.ts. The definition provides:
 *
 *  - Five routes (metadata only — actual RouteObjects live in
 *    web/src/modules/examRoutes.tsx and reach router.tsx via the registry's
 *    REGISTERED_MODULE_ROUTE_OBJECTS export)
 *  - Two nav items: /exam for CANDIDATE, /admin/bilimbaga for
 *    PLATFORM_ADMIN and PROCESS_OPERATOR
 *
 *  No React imports here: this file is pure metadata consumed by
 *  registry.ts's REGISTERED_MODULES array.
 */
import type { ModuleDefinition } from '@/modules/types'

export const examModuleDefinition: ModuleDefinition = {
  id: 'exam',
  depends_on: [],
  routes: [
    { path: 'exam', element: 'ExamListPage', roles: ['CANDIDATE'] },
    { path: 'exam/:examId/session', element: 'ExamSessionPage', roles: ['CANDIDATE'] },
    { path: 'exam/sessions/:sessionId/result', element: 'ExamSessionResultPage', roles: ['CANDIDATE'] },
    { path: 'admin/bilimbaga', element: 'BilimBagaAdminPage', roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
    { path: 'admin/bilimbaga/:entityType', element: 'BilimBagaEntityRoute', roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  ],
  navItems: [
    { to: '/exam', label: 'Exams', roles: ['CANDIDATE'] },
    { to: '/admin/bilimbaga', label: 'Question Bank', roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  ],
}
