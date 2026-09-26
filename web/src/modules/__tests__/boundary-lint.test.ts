/** ISS-0845 — frontend module-boundary ESLint rule, lint-behavior test (AC1).
 *
 *  Verifies `web/.eslintrc.json`'s `no-restricted-imports` module-boundary
 *  configuration actually rejects/allows the import specifiers 0039 D3's two
 *  rules require, per lib/letflow/design/iss0845-frontend-module-boundary-eslint.md
 *  §3's eight-case table.
 *
 *  Cases 1, 2, 4, 5 exercise the REAL, shipped `.eslintrc.json` (via `cwd`)
 *  against the real `exam` module and `registry.ts` — no fixture files.
 *
 *  Cases 3, 3b, 6, 6b need a second module and a declared dependency, which
 *  does not exist in production today (only `exam` is registered). Rather
 *  than invent a throwaway real module directory, they use the ESLint Node
 *  API's own `overrideConfig` composition (documented feature: `overrideConfig`
 *  merges on top of whatever `.eslintrc.json` is found via `cwd`, at the
 *  highest precedence) to layer two throwaway module overrides — `alpha`/
 *  `beta` — built from the same §2b template the real `exam` override uses.
 *  Nothing under `web/src/modules/` gains an `alpha` or `beta` directory; the
 *  `filePath` passed to `lintText` need not exist on disk.
 */
import { describe, expect, it } from 'vitest'
import { ESLint } from 'eslint'
import { resolve } from 'path'

const WEB_ROOT = resolve(__dirname, '..', '..', '..')

/** One line of code is enough for `no-restricted-imports` to evaluate the
 *  specifier; a trailing no-op statement keeps the file parseable. */
function importLine(specifier: string): string {
  return `import X from '${specifier}'\nexport {}\n`
}

async function lint(eslint: ESLint, filePath: string, code: string) {
  const results = await eslint.lintText(code, { filePath })
  return results[0].messages.filter((m) => m.ruleId === 'no-restricted-imports')
}

describe('module-boundary ESLint rule (ISS-0845, real shipped config)', () => {
  const realConfigESLint = new ESLint({ cwd: WEB_ROOT })

  it('case 1: core -> module, relative form is rejected', async () => {
    const messages = await lint(
      realConfigESLint,
      'src/pages/Probe.tsx',
      importLine('../modules/exam/ExamListPage'),
    )
    expect(messages).toHaveLength(1)
    expect(messages[0].ruleId).toBe('no-restricted-imports')
  })

  it('case 2: core -> module, alias form is rejected (regression guard)', async () => {
    const messages = await lint(
      realConfigESLint,
      'src/pages/Probe.tsx',
      importLine('@/modules/exam/ExamListPage'),
    )
    expect(messages).toHaveLength(1)
    expect(messages[0].ruleId).toBe('no-restricted-imports')
  })

  it('case 4: registry.ts -> module index is allowed', async () => {
    const messages = await lint(
      realConfigESLint,
      'src/modules/registry.ts',
      "import { examModuleDefinition } from './exam/index'\nexport {}\n",
    )
    expect(messages).toHaveLength(0)
  })

  it('case 5: module -> core is allowed', async () => {
    const messages = await lint(
      realConfigESLint,
      'src/modules/exam/Probe.tsx',
      importLine('@/components/routing/ModuleGuard'),
    )
    expect(messages).toHaveLength(0)
  })
})

describe('module-boundary ESLint rule (ISS-0845, throwaway alpha/beta fixture, §3 cases 3/3b/6/6b)', () => {
  /** alpha depends_on: [] — beta is an undeclared sibling, must be denied both
   *  spellings. Built from §2b's full template with Others = ['beta']. */
  const undeclaredESLint = new ESLint({
    cwd: WEB_ROOT,
    overrideConfig: {
      overrides: [
        {
          files: ['src/modules/alpha/**'],
          rules: {
            'no-restricted-imports': [
              'error',
              {
                patterns: [
                  '@/modules/*/**',
                  '!@/modules/alpha/**',
                  '!@/modules/registry',
                  '!@/modules/types',
                  '**/modules/*/**',
                  '!**/modules/alpha/**',
                  '!**/modules/registry',
                  '!**/modules/types',
                  '**/beta/**',
                ],
              },
            ],
          },
        },
      ],
    },
  })

  /** alpha depends_on: ['beta'] — beta is now a declared dependency, must be
   *  allowed both spellings; the bare sibling-deny entry for beta is dropped. */
  const declaredESLint = new ESLint({
    cwd: WEB_ROOT,
    overrideConfig: {
      overrides: [
        {
          files: ['src/modules/alpha/**'],
          rules: {
            'no-restricted-imports': [
              'error',
              {
                patterns: [
                  '@/modules/*/**',
                  '!@/modules/alpha/**',
                  '!@/modules/registry',
                  '!@/modules/types',
                  '!@/modules/beta/**',
                  '**/modules/*/**',
                  '!**/modules/alpha/**',
                  '!**/modules/registry',
                  '!**/modules/types',
                  '!**/modules/beta/**',
                ],
              },
            ],
          },
        },
      ],
    },
  })

  it('case 3: module a -> module b, alias form, b not in a\'s depends_on -> rejected', async () => {
    const messages = await lint(
      undeclaredESLint,
      'src/modules/alpha/Probe.tsx',
      importLine('@/modules/beta/Thing'),
    )
    expect(messages).toHaveLength(1)
    expect(messages[0].ruleId).toBe('no-restricted-imports')
  })

  it('case 3b: module a -> module b, relative form, b not in a\'s depends_on -> rejected', async () => {
    const messages = await lint(
      undeclaredESLint,
      'src/modules/alpha/Probe.tsx',
      importLine('../beta/Thing'),
    )
    expect(messages).toHaveLength(1)
    expect(messages[0].ruleId).toBe('no-restricted-imports')
  })

  it('case 6: module a -> module b, alias form, b declared in a\'s depends_on -> allowed', async () => {
    const messages = await lint(
      declaredESLint,
      'src/modules/alpha/Probe.tsx',
      importLine('@/modules/beta/Thing'),
    )
    expect(messages).toHaveLength(0)
  })

  it('case 6b: module a -> module b, relative form, b declared in a\'s depends_on -> allowed', async () => {
    const messages = await lint(
      declaredESLint,
      'src/modules/alpha/Probe.tsx',
      importLine('../beta/Thing'),
    )
    expect(messages).toHaveLength(0)
  })

  it('same-module self-import remains unaffected regardless of depends_on state', async () => {
    const undeclaredSelf = await lint(
      undeclaredESLint,
      'src/modules/alpha/Probe.tsx',
      importLine('../alpha/SiblingFile'),
    )
    expect(undeclaredSelf).toHaveLength(0)

    const declaredSelf = await lint(
      declaredESLint,
      'src/modules/alpha/Probe.tsx',
      importLine('../alpha/SiblingFile'),
    )
    expect(declaredSelf).toHaveLength(0)
  })

  it('the sibling-deny reach is depth-independent, not depth-1-lucky', async () => {
    const deepUndeclared = await lint(
      undeclaredESLint,
      'src/modules/alpha/x/y/z/Probe.tsx',
      importLine('../../../../beta/Thing'),
    )
    expect(deepUndeclared).toHaveLength(1)

    const deepDeclared = await lint(
      declaredESLint,
      'src/modules/alpha/x/y/z/Probe.tsx',
      importLine('../../../../beta/Thing'),
    )
    expect(deepDeclared).toHaveLength(0)
  })
})
