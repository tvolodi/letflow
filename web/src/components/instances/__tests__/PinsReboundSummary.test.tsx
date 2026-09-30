// @vitest-environment jsdom
/** REQ-432 §6.3 / EO-005 — PinsReboundSummary rendering. */
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { PinsReboundSummary } from '../PinsReboundSummary'
expect.extend(jestDomMatchers)

afterEach(cleanup)

const PAYLOAD = {
  entries: [{ kind: 'catalog_entry', ref: 'svc-a', prior_version: '1', new_version: '2' }],
  actor: '11111111-2222-3333-4444-555555555555',
  reason: 'External system retires the old endpoint at month end.',
}

describe('PinsReboundSummary', () => {
  it('renders prior -> new version, reason and the supplied actor label', () => {
    render(<PinsReboundSummary payload={PAYLOAD} actorLabel="Admin User" />)
    expect(screen.getByTestId('pins-rebound-entry-svc-a').textContent).toContain('svc-a: 1 -> 2')
    expect(screen.getByTestId('pins-rebound-reason').textContent).toContain(PAYLOAD.reason)
    expect(screen.getByTestId('pins-rebound-actor')).toHaveTextContent('Admin User')
  })

  it('falls back to the payload actor UUID, never "system"', () => {
    render(<PinsReboundSummary payload={PAYLOAD} />)
    expect(screen.getByTestId('pins-rebound-actor')).toHaveTextContent(PAYLOAD.actor)
    expect(screen.queryByText('system')).not.toBeInTheDocument()
  })

  it('shows "unknown" when neither label nor payload actor exist', () => {
    render(<PinsReboundSummary payload={{ entries: [], reason: 'r' }} />)
    expect(screen.getByTestId('pins-rebound-actor')).toHaveTextContent('unknown')
  })

  it('renders "No version changed" for empty entries, still showing reason and actor', () => {
    render(<PinsReboundSummary payload={{ entries: [], reason: 'because', actor: 'a' }} actorLabel="Op" />)
    expect(screen.getByText('No version changed')).toBeInTheDocument()
    expect(screen.getByTestId('pins-rebound-reason')).toHaveTextContent('because')
    expect(screen.getByTestId('pins-rebound-actor')).toHaveTextContent('Op')
  })

  it('renders nothing for a malformed payload without throwing', () => {
    const { container } = render(<PinsReboundSummary payload={{ entries: 'nope' }} />)
    expect(container).toBeEmptyDOMElement()
    const second = render(<PinsReboundSummary payload={{ entries: [{ ref: 1 }] }} />)
    expect(second.container).toBeEmptyDOMElement()
  })
})
