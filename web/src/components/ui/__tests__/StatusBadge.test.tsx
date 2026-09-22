// @vitest-environment jsdom
/**
 * Unit tests — REQ-272: StatusBadge design-system primitive
 *
 * TC-REQ272-06: §5.1 definition/DEPRECATED resolves bg/text/dot tokens
 * TC-REQ272-07: §5.2 instance/ERROR resolves bg/text/dot tokens (non-pulse case)
 * TC-REQ272-08: §5.2 instance/ACTIVE resolves the pulse animation on its dot
 * TC-REQ272-09: §5.3 task/PENDING resolves bg/text and omits the dot element entirely
 * TC-REQ272-10: unresolved timer/dlq domains render the fallback badge without throwing
 *
 * TC-REQ375-01..05: REQ-375 — the two rollout-shaped domains StatusBadge.tsx
 * added (`rollout`, `rollout-outcome`). REVIEWER's REQ-375 pass flagged these
 * as a real, live gap: `rollout.status` ('running'|'completed') and
 * `outcome.status` ('pending'|'succeeded'|'failed') are two DISJOINT enums
 * that were originally folded under one shared domain table and silently
 * fell through to FALLBACK for every rollout-level badge — the split into
 * two domains (StatusBadge.tsx `ROLLOUT_STATUSES`/`ROLLOUT_OUTCOME_STATUSES`)
 * was the fix, and until now nothing asserted either table resolves for
 * real, so a regression back to one shared (wrong) table would pass
 * silently. See lib/letflow/design/req375-rollout-status-screen.md §2/§7.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { StatusBadge } from '../StatusBadge'
import { applyBrandingColors } from '@/theming/applyBranding'

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

  // ── REQ-375 — rollout / rollout-outcome domains ──────────────────────────

  it('TC-REQ375-01: rollout/running resolves the info token triple with the pulse animation', () => {
    render(<StatusBadge status="running" domain="rollout" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveAttribute('data-domain', 'rollout')
    expect(badge).toHaveStyle({
      background: 'var(--color-info-light)',
      color: 'var(--color-info-dark)',
    })
    const dot = screen.getByTestId('status-badge-dot')
    expect(dot).toHaveStyle({ background: 'var(--color-info)' })
    expect(dot.style.animation).toMatch(/ds-status-badge-pulse/)
  })

  it('TC-REQ375-02: rollout/completed resolves the success token triple, no pulse', () => {
    render(<StatusBadge status="completed" domain="rollout" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveStyle({
      background: 'var(--color-success-light)',
      color: 'var(--color-success-dark)',
    })
    expect(screen.getByTestId('status-badge-dot').style.animation).toBeFalsy()
  })

  it('TC-REQ375-03: rollout-outcome/succeeded resolves the success token triple (the `rollout` domain\'s own "completed" value is NOT a valid rollout-outcome value, and vice versa — the two tables are disjoint, not merged)', () => {
    render(<StatusBadge status="succeeded" domain="rollout-outcome" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveAttribute('data-domain', 'rollout-outcome')
    expect(badge).toHaveStyle({
      background: 'var(--color-success-light)',
      color: 'var(--color-success-dark)',
    })
  })

  it('TC-REQ375-04: rollout-outcome/failed resolves the error token triple', () => {
    render(<StatusBadge status="failed" domain="rollout-outcome" />)
    expect(screen.getByTestId('status-badge')).toHaveStyle({
      background: 'var(--color-error-light)',
      color: 'var(--color-error-dark)',
    })
    expect(screen.getByTestId('status-badge-dot')).toHaveStyle({ background: 'var(--color-error)' })
  })

  it('TC-REQ375-05: rollout-outcome/pending resolves the info token triple with the pulse animation (an outstanding, not-yet-attempted company)', () => {
    render(<StatusBadge status="pending" domain="rollout-outcome" />)
    const badge = screen.getByTestId('status-badge')
    expect(badge).toHaveStyle({
      background: 'var(--color-info-light)',
      color: 'var(--color-info-dark)',
    })
    expect(screen.getByTestId('status-badge-dot').style.animation).toMatch(/ds-status-badge-pulse/)
  })

  it('TC-REQ375-06: cross-domain regression guard — rollout/"succeeded" (a valid rollout-outcome value, NOT a valid rollout value) falls through to FALLBACK, proving the two tables are not merged', () => {
    render(<StatusBadge status="succeeded" domain="rollout" />)
    expect(screen.getByTestId('status-badge')).toHaveStyle({
      background: 'var(--color-neutral-100)',
      color: 'var(--text-secondary)',
    })
  })

  // ── REQ-383/AC3/EO-002 — a tenant brand colour change must never affect
  // platform status colours. Structural today (StatusBadge's STATUS_TABLES
  // reference only --color-success*/--color-warning*/--color-error*/
  // --color-neutral*/--color-info* custom properties, never --color-brand-600,
  // and applyBrandingColors iterates ONLY BRAND_COLOR_CSS_PROPERTY's own keys
  // — exactly 'primary' → '--color-brand-600' today) — this pins that
  // structural claim as a real, failing-if-violated regression test rather
  // than leaving it as only a code-reading claim. See
  // lib/letflow/design/req383-appearance-settings-screen.md §6.
  describe('REQ-383/AC3 — brand colour change does not alter any StatusBadge resolution', () => {
    it('TC-REQ383-01: definition/DEPRECATED (warning) is byte-for-byte identical before and after a brand colour change', () => {
      render(<StatusBadge status="DEPRECATED" domain="definition" />)
      const before = {
        badge: { ...screen.getByTestId('status-badge').style },
        dot: { ...screen.getByTestId('status-badge-dot').style },
      }

      // The REAL function under regression test — not a mock/stub.
      applyBrandingColors({ primary: 'rebeccapurple' })

      const after = {
        badge: { ...screen.getByTestId('status-badge').style },
        dot: { ...screen.getByTestId('status-badge-dot').style },
      }
      expect(after.badge.background).toBe(before.badge.background)
      expect(after.badge.color).toBe(before.badge.color)
      expect(after.dot.background).toBe(before.dot.background)
    })

    it('TC-REQ383-02: instance/ACTIVE (info, pulsing) is identical before and after a brand colour change', () => {
      render(<StatusBadge status="ACTIVE" domain="instance" />)
      const badge = screen.getByTestId('status-badge')
      const dot = screen.getByTestId('status-badge-dot')
      const before = { background: badge.style.background, color: badge.style.color, dotBackground: dot.style.background, animation: dot.style.animation }

      applyBrandingColors({ primary: 'darkorange' })

      expect(badge.style.background).toBe(before.background)
      expect(badge.style.color).toBe(before.color)
      expect(dot.style.background).toBe(before.dotBackground)
      expect(dot.style.animation).toBe(before.animation)
    })

    it('TC-REQ383-03: task/PENDING (no dot column) is identical before and after a brand colour change', () => {
      render(<StatusBadge status="PENDING" domain="task" />)
      const badge = screen.getByTestId('status-badge')
      const before = { background: badge.style.background, color: badge.style.color }

      applyBrandingColors({ primary: 'seagreen' })

      expect(badge.style.background).toBe(before.background)
      expect(badge.style.color).toBe(before.color)
      expect(screen.queryByTestId('status-badge-dot')).toBeNull()
    })

    it('TC-REQ383-04: none of the four representative badges ever resolve to var(--color-brand-600), before OR after applyBrandingColors — confirms StatusBadge never even references the one custom property a brand colour change is capable of writing to', () => {
      render(<StatusBadge status="DEPRECATED" domain="definition" />)
      render(<StatusBadge status="ACTIVE" domain="instance" />)
      render(<StatusBadge status="PENDING" domain="task" />)
      render(<StatusBadge status="running" domain="rollout" />)

      const badges = screen.getAllByTestId('status-badge')
      for (const badge of badges) {
        expect(badge.style.background).not.toBe('var(--color-brand-600)')
        expect(badge.style.color).not.toBe('var(--color-brand-600)')
      }

      applyBrandingColors({ primary: 'midnightblue' })

      for (const badge of badges) {
        expect(badge.style.background).not.toBe('var(--color-brand-600)')
        expect(badge.style.color).not.toBe('var(--color-brand-600)')
      }
    })
  })
})
