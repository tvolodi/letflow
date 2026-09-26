/** ISS-0845 — minimal ambient typing for the `eslint` package's Node API,
 *  scoped to exactly what boundary-lint.test.ts calls (`ESLint#lintText`,
 *  `overrideConfig`). `@types/eslint` is not installed and this design
 *  introduces no new dependency (AC3) — this stub exists so `tsc` can type
 *  the test file without one, not as a general-purpose replacement for the
 *  real (much larger) ESLint type surface.
 */
declare module 'eslint' {
  export interface LintMessage {
    ruleId: string | null
    message: string
    line: number
    column: number
    severity: number
  }

  export interface LintResult {
    filePath: string
    messages: LintMessage[]
  }

  export interface ESLintOptions {
    cwd?: string
    overrideConfig?: Record<string, unknown>
  }

  export class ESLint {
    constructor(options?: ESLintOptions)
    lintText(code: string, options?: { filePath?: string }): Promise<LintResult[]>
  }
}
