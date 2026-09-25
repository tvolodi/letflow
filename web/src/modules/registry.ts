import type { InstalledModule, ModuleDefinition, ModuleNavItem, ModuleRoute } from './types'
import { examModuleDefinition } from './exam/index'
import { EXAM_ROUTE_OBJECTS } from './examRoutes'
import type { RouteObject } from 'react-router-dom'

export const REGISTERED_MODULES: ModuleDefinition[] = [
  {
    id: 'sample',
    depends_on: [],
    routes: [{ path: '/sample', element: 'SamplePage' }],
    navItems: [{ to: '/sample', label: 'Sample', roles: ['CANDIDATE'] }],
  },
  examModuleDefinition,
]

/** All registered module RouteObjects for inclusion in the static router.
 *  Each top-level entry wraps its children in ModuleGuard so routes only
 *  render when the module is installed. Router.tsx spreads this array into
 *  the authenticated route's children. */
export const REGISTERED_MODULE_ROUTE_OBJECTS: RouteObject[] = [
  ...EXAM_ROUTE_OBJECTS,
]

export function getInstalledModuleDefinitions(
  installedModules: InstalledModule[],
  definitions: ModuleDefinition[] = REGISTERED_MODULES,
): ModuleDefinition[] {
  const installedIds = new Set(installedModules.map((module) => module.module_id))
  return definitions.filter((definition) => installedIds.has(definition.id))
}

export function getInstalledModuleRoutes(
  installedModules: InstalledModule[],
  definitions: ModuleDefinition[] = REGISTERED_MODULES,
): ModuleRoute[] {
  return getInstalledModuleDefinitions(installedModules, definitions).flatMap((definition) => definition.routes)
}

export function getInstalledModuleNavItems(
  installedModules: InstalledModule[],
  definitions: ModuleDefinition[] = REGISTERED_MODULES,
): ModuleNavItem[] {
  return getInstalledModuleDefinitions(installedModules, definitions).flatMap((definition) => definition.navItems)
}
