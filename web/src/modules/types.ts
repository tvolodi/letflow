export type ModuleRole = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER' | 'CANDIDATE'

export interface InstalledModule {
  module_id: string
  version: string
}

export interface ModuleRoute {
  path: string
  element?: string
  roles?: ModuleRole[]
}

export interface ModuleNavItem {
  to: string
  label: string
  roles: ModuleRole[]
}

export interface ModuleDefinition {
  id: string
  depends_on?: string[]
  routes: ModuleRoute[]
  navItems: ModuleNavItem[]
}
