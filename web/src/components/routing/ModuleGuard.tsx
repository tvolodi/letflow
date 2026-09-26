/** ModuleGuard — moved to core routing per ISS-0844.
 *
 *  Wraps a set of module-specific routes. When the named module is not in the
 *  tenant's installed_modules list, renders NotFoundPage instead of the
 *  route's children. When installed, renders <Outlet /> so child routes
 *  proceed normally.
 *
 *  Used by web/src/modules/registry.ts, which wraps each registered module's
 *  route objects in this guard when building REGISTERED_MODULE_ROUTE_OBJECTS.
 *  Module code itself never imports ModuleGuard (0039 D3: modules may depend
 *  only on core's public API).
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
