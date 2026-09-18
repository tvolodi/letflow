// @vitest-environment jsdom
/**
 * REQ-366 §6/§2.3 — StalenessBadge
 *
 * TC-REQ366-08: kind="stale" renders a visible "may be outdated" indicator.
 * TC-REQ366-09: kind="reviewed" with a confirmedAt renders "Last reviewed
 *   <date>" — the plain non-stale reading design §6 requires for
 *   non-process (or not-yet-stale) help.
 * TC-REQ366-10: kind="reviewed" with confirmedAt=null does not invent a date.
 */
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { StalenessBadge } from '../StalenessBadge'

expect.extend(jestDomMatchers)

afterEach(cleanup)

describe('StalenessBadge', () => {
  it('TC-REQ366-08: stale renders a visible "may be outdated" indicator', () => {
    render(<StalenessBadge kind="stale" />)
    const badge = screen.getByTestId('help-staleness-badge')
    expect(badge).toHaveAttribute('data-staleness', 'stale')
    expect(badge).toHaveTextContent(/outdated/i)
  })

  it('TC-REQ366-09: reviewed with confirmedAt renders "last reviewed <date>"', () => {
    render(<StalenessBadge kind="reviewed" confirmedAt="2026-09-01T00:00:00Z" />)
    const badge = screen.getByTestId('help-staleness-badge')
    expect(badge).toHaveAttribute('data-staleness', 'reviewed')
    expect(badge).toHaveTextContent(/last reviewed/i)
  })

  it('TC-REQ366-10: reviewed with confirmedAt=null does not invent a date', () => {
    render(<StalenessBadge kind="reviewed" confirmedAt={null} />)
    const badge = screen.getByTestId('help-staleness-badge')
    expect(badge).not.toHaveTextContent(/last reviewed/i)
  })
})
