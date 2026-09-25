/** examRoutes — REQ-412
 *
 *  Provides the React Router RouteObject[] for the exam module's five SPA
 *  routes. Imported by registry.ts and re-exported as
 *  REGISTERED_MODULE_ROUTE_OBJECTS so that router.tsx can access them via
 *  the allowed @/modules/registry import without crossing the module
 *  boundary directly.
 *
 *  Each top-level entry wraps its children in ModuleGuard (moduleId="exam"),
 *  which checks useInstalledModules() at render time: if the exam module is
 *  not in installed_modules, the guard renders NotFoundPage; if installed,
 *  it renders <Outlet /> and child routes proceed.
 *
 *  SPA paths are unchanged from router.tsx (REQ-412's own text):
 *    exam
 *    exam/:examId/session
 *    exam/sessions/:sessionId/result
 *    admin/bilimbaga
 *    admin/bilimbaga/:entityType
 */
import type { RouteObject } from 'react-router-dom'
import { ModuleGuard } from './ModuleGuard'
import ExamListPage from './exam/ExamListPage'
import ExamSessionPage from './exam/ExamSessionPage'
import ExamSessionResultPage from './exam/ExamSessionResultPage'
import BilimBagaAdminPage from './exam/BilimBagaAdminPage'
import BilimBagaEntityRoute from './exam/BilimBagaEntityRoute'

export const EXAM_ROUTE_OBJECTS: RouteObject[] = [
  {
    path: 'exam',
    element: <ModuleGuard moduleId="exam" />,
    children: [
      { index: true, element: <ExamListPage /> },
      { path: ':examId/session', element: <ExamSessionPage /> },
      { path: 'sessions/:sessionId/result', element: <ExamSessionResultPage /> },
    ],
  },
  {
    path: 'admin/bilimbaga',
    element: <ModuleGuard moduleId="exam" />,
    children: [
      { index: true, element: <BilimBagaAdminPage /> },
      { path: ':entityType', element: <BilimBagaEntityRoute /> },
    ],
  },
]
