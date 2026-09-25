/** ModuleGuard — REQ-412
 *
 *  Wraps a set of module-specific routes. When the named module is not in the
 *  tenant's installed_modules list, renders NotFoundPage instead of the
 *  route's children. When installed, renders <Outlet /> so child routes
 *  proceed normally.
 *
 *  Only used from web/src/modules/examRoutes.tsx (accessed by router.tsx via
 *  @/modules/registry). Never imported directly from outside @/modules/registry.
 */
import { Outlet } from 'react-router-dom'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { NotFoundPage } from '@/pages/NotFoundPage'

interface ModuleGuardProps {
  moduleId: string
}

export function ModuleGuard({ moduleId }: ModuleGuardProps) {
  const { data: installedModules, isLoading } = useInstalledModules()

  // While loading, render nothing to avoid a flash of not-found content.
  if (isLoading) return null

  const isInstalled = (installedModules ?? []).some((m) => m.module_id === moduleId)
  if (!isInstalled) return <NotFoundPage />

  return <Outlet />
}
