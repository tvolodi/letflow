// @vitest-environment jsdom
/**
 * REQ-366 §3.3 / §8 AC2 — HelpMarkdown's sanitizing pipeline.
 *
 * TC-REQ366-05: a malicious payload (<script>, onerror-bearing <img>, and a
 *   javascript: link) is neutralized in the rendered output — no <script>
 *   tag, no onerror handler, no javascript: href reaches the DOM.
 * TC-REQ366-06: no dangerouslySetInnerHTML anywhere in this component's own
 *   source (structural guarantee design §3.1 argues for react-markdown;
 *   asserted directly here per design §3.3's own stated test obligation).
 * TC-REQ366-07: allowlisted markdown (headings, bold, links, lists) still
 *   renders through — the sanitizer narrows, it does not just blank
 *   everything.
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { HelpMarkdown } from '../HelpMarkdown'

expect.extend(jestDomMatchers)

afterEach(cleanup)

describe('HelpMarkdown', () => {
  it('TC-REQ366-05: neutralizes a malicious markdown/HTML payload', () => {
    const malicious = [
      '# Title',
      '<script>window.__pwned = true</script>',
      '<img src="x" onerror="window.__pwned2 = true" />',
      '[click me](javascript:window.__pwned3=true)',
      '<a href="javascript:alert(1)">bad link</a>',
    ].join('\n\n')

    const { container } = render(<HelpMarkdown source={malicious} />)

    expect(container.querySelector('script')).toBeNull()
    expect(container.innerHTML).not.toContain('onerror')
    expect(container.innerHTML).not.toContain('javascript:')
    expect((window as unknown as { __pwned?: boolean }).__pwned).toBeUndefined()
  })

  it('TC-REQ366-06: never calls dangerouslySetInnerHTML', () => {
    const source = readFileSync(join(__dirname, '../HelpMarkdown.tsx'), 'utf-8')
    expect(source).not.toContain('dangerouslySetInnerHTML')
  })

  it('TC-REQ366-07: allowlisted markdown still renders', () => {
    render(<HelpMarkdown source={'# Heading\n\n**bold** and [a safe link](https://example.com)'} />)
    expect(screen.getByRole('heading', { level: 1, name: 'Heading' })).toBeInTheDocument()
    expect(screen.getByText('bold')).toBeInTheDocument()
    const link = screen.getByRole('link', { name: 'a safe link' })
    expect(link).toHaveAttribute('href', 'https://example.com')
  })
})
