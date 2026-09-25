import { describe, expect, it } from 'vitest'
import { getInstalledModuleNavItems, getInstalledModuleRoutes } from '../registry'
import type { ModuleDefinition } from '../types'

const fixtureDefinitions: ModuleDefinition[] = [
  {
    id: 'sample',
    depends_on: [],
    routes: [{ path: '/sample', element: 'SamplePage' }],
    navItems: [{ to: '/sample', label: 'Sample', roles: ['CANDIDATE'] }],
  },
]

describe('module registry', () => {
  it('returns only the installed modules\' routes and nav items', () => {
    const installed = [
      { module_id: 'sample', version: '1.0.0' },
      { module_id: 'other', version: '2.0.0' },
    ]

    expect(getInstalledModuleRoutes(installed, fixtureDefinitions)).toEqual(fixtureDefinitions[0].routes)
    expect(getInstalledModuleNavItems(installed, fixtureDefinitions)).toEqual(fixtureDefinitions[0].navItems)
  })

  it('returns empty arrays when no module is installed', () => {
    const installed = [{ module_id: 'missing', version: '1.0.0' }]

    expect(getInstalledModuleRoutes(installed, fixtureDefinitions)).toEqual([])
    expect(getInstalledModuleNavItems(installed, fixtureDefinitions)).toEqual([])
  })
})
