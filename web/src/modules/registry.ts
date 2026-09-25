import type { InstalledModule, ModuleDefinition, ModuleNavItem, ModuleRoute } from './types'

export const REGISTERED_MODULES: ModuleDefinition[] = [
  {
    id: 'sample',
    depends_on: [],
    routes: [{ path: '/sample', element: 'SamplePage' }],
    navItems: [{ to: '/sample', label: 'Sample', roles: ['CANDIDATE'] }],
  },
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
