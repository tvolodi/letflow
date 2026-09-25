import { client } from './client'

export interface InstalledModule {
  module_id: string
  version: string
}

export interface InstalledModulesResponse {
  installed_modules: InstalledModule[]
}

export const meApi = {
  listInstalledModules: () => client.get<InstalledModulesResponse>('/api/v1/me/modules'),
}
