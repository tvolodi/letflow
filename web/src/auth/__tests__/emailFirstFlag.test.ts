// @vitest-environment node
/**
 * REQ-438 AC (BA decision D-D): the email-first flag is OFF by default in every
 * non-dev build. Behavioural default + a static assertion over the committed
 * env files, deploy/CI files and vite config that nothing committed sets it true.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { isEmailFirstLoginEnabled } from '../emailFirstFlag'

const WEB_ROOT = path.resolve(__dirname, '..', '..', '..')
const REPO_ROOT = path.resolve(WEB_ROOT, '..')

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('isEmailFirstLoginEnabled', () => {
  it('is off when the variable is unset', () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', '')
    expect(isEmailFirstLoginEnabled()).toBe(false)
  })

  it('is on only for the exact value true', () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    expect(isEmailFirstLoginEnabled()).toBe(true)
    for (const v of ['TRUE', '1', 'yes', 'false', ' true', 'on']) {
      vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', v)
      expect(isEmailFirstLoginEnabled()).toBe(false)
    }
  })
})

function listFiles(dir: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name)
    if (statSync(full).isDirectory()) listFiles(full, out)
    else out.push(full)
  }
  return out
}

/** A line that assigns VITE_EMAIL_FIRST_LOGIN a true value (env-file, compose,
 *  Dockerfile ARG/ENV or shell style), ignoring comment-only lines. */
const ENABLES_FLAG = /^\s*(?!#)(?:export\s+|ENV\s+|ARG\s+|-\s+)?VITE_EMAIL_FIRST_LOGIN\s*[=:]\s*["']?true\b/im

describe('committed build configuration never enables the flag', () => {
  const webEnvFiles = readdirSync(WEB_ROOT)
    .filter((n) => n.startsWith('.env') && !n.endsWith('.local'))
    .map((n) => path.join(WEB_ROOT, n))
  const deployFiles = [
    ...listFiles(path.join(REPO_ROOT, 'deploy')),
    ...listFiles(path.join(REPO_ROOT, '.github')),
    path.join(REPO_ROOT, '.env.example'),
  ].filter((f) => existsSync(f))

  it('scans at least the committed web env template and vite config', () => {
    expect(webEnvFiles.some((f) => f.endsWith('.env.example'))).toBe(true)
    expect(existsSync(path.join(WEB_ROOT, 'vite.config.ts'))).toBe(true)
  })

  for (const file of [...webEnvFiles, ...deployFiles, path.join(WEB_ROOT, 'vite.config.ts')]) {
    it(`${path.relative(REPO_ROOT, file).split(path.sep).join('/')} does not set it true`, () => {
      expect(readFileSync(file, 'utf-8')).not.toMatch(ENABLES_FLAG)
    })
  }

  it('the detector itself flags an enabling line (guards against a vacuous pass)', () => {
    expect('VITE_EMAIL_FIRST_LOGIN=true').toMatch(ENABLES_FLAG)
    expect('ENV VITE_EMAIL_FIRST_LOGIN=true').toMatch(ENABLES_FLAG)
    expect('# VITE_EMAIL_FIRST_LOGIN=true').not.toMatch(ENABLES_FLAG)
    expect('VITE_EMAIL_FIRST_LOGIN=false').not.toMatch(ENABLES_FLAG)
  })
})
