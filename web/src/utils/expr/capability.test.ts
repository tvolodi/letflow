import { describe, it, expect } from 'vitest'
import { STATIC_CAPABILITIES, checkManifestCompatibility, checkAstCapabilities, evaluatorCompatibility } from './capability'
import { parse } from './parser'

describe('checkManifestCompatibility', () => {
  it('is compatible when every manifest capability is statically implemented', () => {
    const result = checkManifestCompatibility(Array.from(STATIC_CAPABILITIES))
    expect(result).toEqual({ compatible: true, unsupported: [] })
  })

  it('names the specific missing tags when incompatible', () => {
    const result = checkManifestCompatibility(['cmp:eq', 'builtin:now'])
    expect(result.compatible).toBe(false)
    expect(result.unsupported).toEqual(['builtin:now'])
  })

  it('is a superset check, not a semver comparison — extra client capabilities are fine', () => {
    const result = checkManifestCompatibility(['cmp:eq'])
    expect(result).toEqual({ compatible: true, unsupported: [] })
  })
})

describe('checkAstCapabilities', () => {
  it('returns empty for an AST built entirely from statically-implemented constructs', () => {
    const parsed = parse('amount > 100 and lower(name) == "bob"')
    expect(parsed.ok).toBe(true)
    if (parsed.ok) expect(checkAstCapabilities(parsed.ast)).toEqual([])
  })

  it('distinguishes var:simple from var:dotted', () => {
    const simple = parse('amount')
    const dotted = parse('order.status')
    expect(simple.ok && dotted.ok).toBe(true)
    if (simple.ok && dotted.ok) {
      expect(checkAstCapabilities(simple.ast)).not.toContain('var:dotted')
      expect(checkAstCapabilities(dotted.ast)).toEqual([])
    }
  })
})

describe('evaluatorCompatibility', () => {
  it('composes the manifest-shaped check', () => {
    expect(evaluatorCompatibility({ capabilities: ['cmp:eq'] })).toEqual({ compatible: true, unsupported: [] })
  })
})
