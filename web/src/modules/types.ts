import type { RouteObject } from 'react-router-dom'

export type ModuleRole = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER' | 'CANDIDATE' | 'AGENT_RUNNER'

export interface InstalledModule {
  module_id: string
  version: string
}

export interface ModuleNavItem {
  to: string
  label: string
  roles: ModuleRole[]
}

/** A module's static definition. Each module's `web/src/modules/<id>/index.ts`
 *  exports exactly one of these. `registry.ts` is the only file that imports
 *  module code (0039 D3); it wraps `routeObjects` in a `ModuleGuard` when
 *  building the router's module route list. */
export interface ModuleDefinition {
  id: string
  depends_on?: string[]
  /** Plain route objects — no guard wrapper. Registry wraps them. */
  routeObjects: RouteObject[]
  navItems: ModuleNavItem[]
}
