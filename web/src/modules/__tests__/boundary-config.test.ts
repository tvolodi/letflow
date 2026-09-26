/** ISS-0845 — drift check: `web/.eslintrc.json`'s per-module `overrides`
 *  entries vs. `REGISTERED_MODULES[*].depends_on` (the real, live source of
 *  truth in `web/src/modules/registry.ts`).
 *
 *  Kept separate from boundary-lint.test.ts (per
 *  lib/letflow/design/iss0845-frontend-module-boundary-eslint.md §2c) so a
 *  config-drift failure and a lint-behavior failure are never conflated in
 *  one report.
 *
 *  What "drift" means here: a config author adds `"hr"` to `exam`'s
 *  `depends_on` in `index.ts` but forgets the matching `.eslintrc.json`
 *  negation (or forgets to add/remove a sibling-deny entry when a module is
 *  registered/deregistered) — this test fails on the next `npm test`, before
 *  it fails a build or silently ships a bypassable boundary.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'fs'
import { resolve } from 'path'
import { REGISTERED_MODULES } from '../registry'

const ESLINTRC_PATH = resolve(__dirname, '..', '..', '..', '.eslintrc.json')

interface EslintRcOverride {
  files: string[]
  rules?: {
    'no-restricted-imports'?: [string, { patterns: string[] }]
  }
}

interface EslintRc {
  overrides?: EslintRcOverride[]
}

function readEslintRc(): EslintRc {
  return JSON.parse(readFileSync(ESLINTRC_PATH, 'utf-8')) as EslintRc
}

/** Module id parsed out of a `files: ["src/modules/<id>/**"]` glob, or
 *  `undefined` if the entry isn't a per-module override (e.g. registry.ts's
 *  own override, which stays out of scope for this drift check). */
function moduleIdFromFilesGlob(files: string[]): string | undefined {
  for (const glob of files) {
    const match = /^src\/modules\/([^/]+)\/\*\*$/.exec(glob)
    if (match) return match[1]
  }
  return undefined
}

/** Every module id an override's negated, `modules`-anchored patterns allow
 *  (i.e. `{id} ∪ depends_on`) — parsed back out of the `patterns` array by
 *  stripping the leading `!`, the `@/modules/`/`**\/modules/` prefix, and the
 *  trailing `/**`, then dropping `registry`/`types` (core, not module ids). */
function allowedModuleIds(patterns: string[]): Set<string> {
  const allowed = new Set<string>()
  for (const pattern of patterns) {
    if (!pattern.startsWith('!')) continue
    const negated = pattern.slice(1)
    const match =
      /^@\/modules\/([^/]+)\/\*\*$/.exec(negated) ??
      /^\*\*\/modules\/([^/]+)\/\*\*$/.exec(negated)
    if (!match) continue
    const id = match[1]
    if (id === 'registry' || id === 'types') continue
    allowed.add(id)
  }
  return allowed
}

/** Every module id the bare, `modules`-literal-free sibling-deny family
 *  (`**\/<other>/**`) denies — the direct sibling-relative-form bypass this
 *  design closes. Excludes `**\/modules/*\/**` (the generic modules-anchored
 *  deny-all, not a per-id entry) and any `!`-negated pattern. */
function denyModuleIds(patterns: string[]): Set<string> {
  const denied = new Set<string>()
  for (const pattern of patterns) {
    if (pattern.startsWith('!')) continue
    const match = /^\*\*\/([^/]+)\/\*\*$/.exec(pattern)
    if (!match) continue
    const id = match[1]
    if (id === '*' || id === 'modules') continue
    denied.add(id)
  }
  return denied
}

describe('module-boundary config drift (ISS-0845 §2c)', () => {
  const eslintRc = readEslintRc()
  const moduleOverrides = new Map<string, EslintRcOverride>()
  for (const override of eslintRc.overrides ?? []) {
    const id = moduleIdFromFilesGlob(override.files)
    if (id) moduleOverrides.set(id, override)
  }

  const allModuleIds = REGISTERED_MODULES.map((m) => m.id)

  it.each(REGISTERED_MODULES)(
    'module "$id" has an .eslintrc.json override whose allowed-id set is exactly {id} ∪ depends_on',
    (moduleDef) => {
      const override = moduleOverrides.get(moduleDef.id)
      expect(override, `expected an overrides entry for src/modules/${moduleDef.id}/**`).toBeDefined()

      const patterns = override!.rules?.['no-restricted-imports']?.[1]?.patterns ?? []
      const expected = new Set([moduleDef.id, ...(moduleDef.depends_on ?? [])])
      const actual = allowedModuleIds(patterns)

      expect(actual).toEqual(expected)
    },
  )

  it.each(REGISTERED_MODULES)(
    'module "$id" denies exactly the sibling ids not covered by an allow (Others - depends_on)',
    (moduleDef) => {
      const override = moduleOverrides.get(moduleDef.id)
      expect(override, `expected an overrides entry for src/modules/${moduleDef.id}/**`).toBeDefined()

      const patterns = override!.rules?.['no-restricted-imports']?.[1]?.patterns ?? []
      const others = allModuleIds.filter((id) => id !== moduleDef.id)
      const expectedDeny = new Set(others.filter((id) => !(moduleDef.depends_on ?? []).includes(id)))
      const actualDeny = denyModuleIds(patterns)

      expect(actualDeny).toEqual(expectedDeny)
    },
  )

  it('has no override naming a module id that is not in REGISTERED_MODULES (no stale entries)', () => {
    const registeredIds = new Set(allModuleIds)
    for (const id of moduleOverrides.keys()) {
      expect(registeredIds.has(id), `override for "${id}" has no matching REGISTERED_MODULES entry`).toBe(true)
    }
  })
})
