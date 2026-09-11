/**
 * REQ-293 — REQ-290's client contract, design doc §7/§13.1-13.2. Set-membership
 * check on the tag vocabulary, not a semver comparison — `corpus_schema_version`
 * is surfaced for diagnostics only, never parsed as a version number here.
 */

import type { Ast } from './types'

/**
 * This evaluator's own statically-known implemented-tag set, hand-maintained,
 * one entry per `grammar_constructs` tag this module actually implements — the
 * 30 tags in `priv/expr_conformance/manifest.json` today, enumerated literally.
 */
export const STATIC_CAPABILITIES: ReadonlySet<string> = new Set([
  'arith:add',
  'arith:div',
  'arith:mod',
  'arith:mul',
  'arith:neg',
  'arith:sub',
  'bool:and',
  'bool:not',
  'bool:or',
  'builtin:coalesce',
  'builtin:contains',
  'builtin:endsWith',
  'builtin:length',
  'builtin:lower',
  'builtin:startsWith',
  'builtin:trim',
  'builtin:upper',
  'cmp:eq',
  'cmp:gt',
  'cmp:gte',
  'cmp:lt',
  'cmp:lte',
  'cmp:neq',
  'lit:boolean',
  'lit:float',
  'lit:integer',
  'lit:null',
  'lit:string',
  'var:dotted',
  'var:simple',
])

export interface ManifestCompatibility {
  compatible: boolean
  /** manifest.capabilities - STATIC_CAPABILITIES, empty iff compatible. */
  unsupported: string[]
}

/** §13.1 point 1 — coarse, proactive, at load/startup. */
export function checkManifestCompatibility(manifestCapabilities: string[]): ManifestCompatibility {
  const unsupported = manifestCapabilities.filter((tag) => !STATIC_CAPABILITIES.has(tag))
  return { compatible: unsupported.length === 0, unsupported }
}

const CMP_TAG: Record<string, string> = {
  eq: 'cmp:eq',
  neq: 'cmp:neq',
  lt: 'cmp:lt',
  lte: 'cmp:lte',
  gt: 'cmp:gt',
  gte: 'cmp:gte',
}

const ARITH_TAG: Record<string, string> = {
  add: 'arith:add',
  sub: 'arith:sub',
  mul: 'arith:mul',
  div: 'arith:div',
  mod: 'arith:mod',
}

const BUILTIN_TAG: Record<string, string> = {
  length: 'builtin:length',
  lower: 'builtin:lower',
  upper: 'builtin:upper',
  trim: 'builtin:trim',
  contains: 'builtin:contains',
  startsWith: 'builtin:startsWith',
  endsWith: 'builtin:endsWith',
  coalesce: 'builtin:coalesce',
}

function tagsForLit(value: unknown): string {
  if (value === null) return 'lit:null'
  if (typeof value === 'boolean') return 'lit:boolean'
  if (typeof value === 'string') return 'lit:string'
  if (typeof value === 'number') return Number.isInteger(value) ? 'lit:integer' : 'lit:float'
  return 'lit:string'
}

/**
 * §13.1 point 2 — fine, reactive, per parsed AST, defense in depth. Walks `ast`
 * and returns every `grammar_constructs`-shaped tag it actually uses that is
 * NOT in `STATIC_CAPABILITIES`.
 */
export function checkAstCapabilities(ast: Ast): string[] {
  const found = new Set<string>()

  function visit(node: Ast): void {
    switch (node.kind) {
      case 'lit':
        found.add(tagsForLit(node.value))
        return
      case 'var':
        found.add(node.path.length > 1 ? 'var:dotted' : 'var:simple')
        return
      case 'not':
        found.add('bool:not')
        visit(node.sub)
        return
      case 'and':
        found.add('bool:and')
        visit(node.left)
        visit(node.right)
        return
      case 'or':
        found.add('bool:or')
        visit(node.left)
        visit(node.right)
        return
      case 'cmp':
        found.add(CMP_TAG[node.op] ?? `cmp:${node.op}`)
        visit(node.left)
        visit(node.right)
        return
      case 'arith':
        found.add(ARITH_TAG[node.op] ?? `arith:${node.op}`)
        visit(node.left)
        visit(node.right)
        return
      case 'neg':
        found.add('arith:neg')
        visit(node.sub)
        return
      case 'call':
        found.add(BUILTIN_TAG[node.name] ?? `builtin:${node.name}`)
        for (const arg of node.args) visit(arg)
        return
    }
  }

  visit(ast)

  return Array.from(found).filter((tag) => !STATIC_CAPABILITIES.has(tag))
}

/** Composed startup check `DynamicFormRenderer` calls once per form_schema load. */
export function evaluatorCompatibility(manifest: { capabilities: string[] }): ManifestCompatibility {
  return checkManifestCompatibility(manifest.capabilities)
}
