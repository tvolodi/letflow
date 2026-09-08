// @vitest-environment jsdom
/**
 * Unit tests — REQ-272: StatusBadge design-system primitive
 *
 * TC-REQ272-06: §5.1 definition/DEPRECATED resolves bg/text/dot tokens
 * TC-REQ272-07: §5.2 instance/ERROR resolves bg/text/dot tokens (non-pulse case)
 * TC-REQ272-08: §5.2 instance/ACTIVE resolves the pulse animation on its dot
 * TC-REQ272-09: §5.3 task/PENDING resolves bg/text and omits the dot element entirely
 * TC-REQ272-10: unresolved timer/dlq domains render the fallback badge without throwing
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { StatusBadge } from '../StatusBadge'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-272 — StatusBadge', () => {
  it('TC-REQ272-06: definition/DEPRECATED (§5.1) resolves the warning token triple', () => {
    render(<StatusBadge status="DEPRECATED" domain="definition" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveStyle({
      background: 'var(--color-warning-light)',
      color: 'var(--color-warning-dark)',
    })
    expect(screen.getByTestId('status-badge-dot')).toHaveStyle({
      background: 'var(--color-warning)',
    })
  })

  it('TC-REQ272-07: instance/ERROR (§5.2) resolves the error token triple, no pulse', () => {
    render(<StatusBadge status="ERROR" domain="instance" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveStyle({
      background: 'var(--color-error-light)',
      color: 'var(--color-error-dark)',
    })
    const dot = screen.getByTestId('status-badge-dot')
    expect(dot).toHaveStyle({ background: 'var(--color-error)' })
    expect(dot.style.animation).toBeFalsy()
  })

  it('TC-REQ272-08: instance/ACTIVE (§5.2) is the one status carrying the pulse animation', () => {
    render(<StatusBadge status="ACTIVE" domain="instance" />)
    const dot = screen.getByTestId('status-badge-dot')
    expect(dot.style.animation).toMatch(/ds-status-badge-pulse/)
  })

  it('TC-REQ272-09: task/PENDING (§5.3) resolves bg/text and renders NO dot element at all', () => {
    render(<StatusBadge status="PENDING" domain="task" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveStyle({
      background: 'var(--color-info-light)',
      color: 'var(--color-info-dark)',
    })
    expect(screen.queryByTestId('status-badge-dot')).toBeNull()
  })

  it('TC-REQ272-10: an unresolved (timer, status) pair renders the neutral fallback without throwing, no dot', () => {
    expect(() => render(<StatusBadge status="EXPIRED" domain="timer" />)).not.toThrow()
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveStyle({
      background: 'var(--color-neutral-100)',
      color: 'var(--text-secondary)',
    })
    expect(screen.queryByTestId('status-badge-dot')).toBeNull()
  })

  it('TC-REQ272-11: an unresolved (dlq, status) pair renders the neutral fallback without throwing', () => {
    expect(() => render(<StatusBadge status="STUCK" domain="dlq" />)).not.toThrow()
    expect(screen.getByTestId('status-badge')).toHaveStyle({
      background: 'var(--color-neutral-100)',
      color: 'var(--text-secondary)',
    })
  })
})
