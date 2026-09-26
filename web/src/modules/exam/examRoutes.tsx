/** web/src/modules/exam/examRoutes.tsx — ISS-0844
 *
 *  The exam module's route objects. Imported by exam/index.ts and registered
 *  via registry.ts. Lives inside web/src/modules/exam/ so it counts as module
 *  code (0039 D3), not core code.
 *
 *  No guard wrapper here — registry.ts wraps these in ModuleGuard when
 *  building REGISTERED_MODULE_ROUTE_OBJECTS.
 */
import type { RouteObject } from 'react-router-dom'
import ExamListPage from './ExamListPage'
import ExamSessionPage from './ExamSessionPage'
import ExamSessionResultPage from './ExamSessionResultPage'
import BilimBagaAdminPage from './BilimBagaAdminPage'
import BilimBagaEntityRoute from './BilimBagaEntityRoute'

export const examRouteObjects: RouteObject[] = [
  {
    path: 'exam',
    children: [
      { index: true, element: <ExamListPage /> },
      { path: ':examId/session', element: <ExamSessionPage /> },
      { path: 'sessions/:sessionId/result', element: <ExamSessionResultPage /> },
    ],
  },
  {
    path: 'admin/bilimbaga',
    children: [
      { index: true, element: <BilimBagaAdminPage /> },
      { path: ':entityType', element: <BilimBagaEntityRoute /> },
    ],
  },
]
