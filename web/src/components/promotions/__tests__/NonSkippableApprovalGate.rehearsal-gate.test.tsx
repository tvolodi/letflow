// @vitest-environment jsdom
/**
 * Unit tests — ISS-0767: NonSkippableApprovalGate rehearsal-gate blocked states
 * + classifyApplyRehearsalError.
 *
 * See lib/letflow/design/iss0767-non-skippable-gate-rehearsal-blocked-state.md §8.
 * Five component-level cases (§8.1): four new rehearsal-gate states, plus one
 * explicit regression guard proving the pre-existing :digest_mismatch 409 is
 * still routed to `digest-mismatch-error` and is NOT swallowed by the new
 * `classifyApplyRehearsalError` check (this is the case that would catch a
 * regression to the §3.1/§4.2 ordering fix). Plus §8.2's direct classifier
 * unit tests.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/react'
import {
  NonSkippableApprovalGate,
  classifyApplyRehearsalError,
} from '../NonSkippableApprovalGate'
import type { PromotionContext } from '@/api/promotions'

expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

// ── Fixtures ─────────────────────────────────────────────────────────────────

const baseContext: PromotionContext = {
  review: {
    id: 'review-1',
    tenant_id: 'tenant-1',
    plan_digest: 'a'.repeat(64),
    def_type: 'process',
    def_id: 'def-1',
    serialised_plan: '{}',
    status: 'approved',
    requested_by: 'user-requester',
    approved_by: 'user-approver',
    approved_at: '2026-09-21T00:00:00Z',
    superseded_by: null,
    row_version: 1,
    created_at: '2026-09-21T00:00:00Z',
    updated_at: '2026-09-21T00:00:00Z',
  },
  plan: { entries: [] },
  digest_verified: true,
  assertions: [],
}

function renderGate(onApply: (reviewId: string, planDigest: string) => Promise<void>) {
  return render(
    <NonSkippableApprovalGate
      context={baseContext}
      currentUserId="user-approver"
      onApprove={vi.fn()}
      onReject={vi.fn()}
      onApply={onApply}
    />
  )
}

async function clickApplyAndWait() {
  fireEvent.click(screen.getByTestId('apply-btn'))
  await waitFor(() => expect(screen.getByTestId('apply-btn')).not.toBeDisabled())
}

const DETAILS = {
  missing: 'no assertion run has been recorded for this review; run assertions before applying',
  staleDigest:
    'the most recent assertion run does not match the plan_digest being applied; re-run assertions against the current plan',
  inProgress:
    'the most recent assertion run for this review has not finished yet; wait for it to complete or re-run assertions before applying',
  failed:
    'the most recent assertion run recorded failing assertions; applying is blocked until a rehearsal with zero failures is recorded',
  digestMismatch: 'the provided plan_digest does not match the stored digest',
}

const REHEARSAL_TESTIDS = [
  'rehearsal-gate-error-missing',
  'rehearsal-gate-error-stale',
  'rehearsal-gate-error-in-progress',
  'rehearsal-gate-error-failed',
]

// ── §8.1 component-level tests ────────────────────────────────────────────────

describe('NonSkippableApprovalGate — rehearsal-gate blocked states', () => {
  it('TC-ISS0767-01: assertion_run_missing renders rehearsal-gate-error-missing', async () => {
    const onApply = vi.fn().mockRejectedValue({
      status: 409,
      details: { detail: DETAILS.missing },
    })
    renderGate(onApply)

    await clickApplyAndWait()

    expect(screen.getByTestId('rehearsal-gate-error-missing')).toBeInTheDocument()
    expect(screen.queryByTestId('digest-mismatch-error')).not.toBeInTheDocument()
    expect(screen.queryByTestId('transition-error')).not.toBeInTheDocument()
  })

  it('TC-ISS0767-02: assertion_run_digest_mismatch renders rehearsal-gate-error-stale, not digest-mismatch-error', async () => {
    // This is the test that most directly guards the §3.1/§4.2 ordering fix --
    // a regression that put the new check *after* the existing bare
    // `status === 409` branch would make this exact case wrongly render
    // `digest-mismatch-error` instead.
    const onApply = vi.fn().mockRejectedValue({
      status: 409,
      details: { detail: DETAILS.staleDigest },
    })
    renderGate(onApply)

    await clickApplyAndWait()

    expect(screen.getByTestId('rehearsal-gate-error-stale')).toBeInTheDocument()
    expect(screen.queryByTestId('digest-mismatch-error')).not.toBeInTheDocument()
  })

  it('TC-ISS0767-03: assertion_run_in_progress renders rehearsal-gate-error-in-progress', async () => {
    const onApply = vi.fn().mockRejectedValue({
      status: 409,
      details: { detail: DETAILS.inProgress },
    })
    renderGate(onApply)

    await clickApplyAndWait()

    expect(screen.getByTestId('rehearsal-gate-error-in-progress')).toBeInTheDocument()
  })

  it('TC-ISS0767-04: assertion_run_failed renders rehearsal-gate-error-failed', async () => {
    const onApply = vi.fn().mockRejectedValue({
      status: 409,
      details: { detail: DETAILS.failed },
    })
    renderGate(onApply)

    await clickApplyAndWait()

    expect(screen.getByTestId('rehearsal-gate-error-failed')).toBeInTheDocument()
  })

  it('TC-ISS0767-05 (AC3 regression guard): pre-existing digest_mismatch 409 still renders digest-mismatch-error, not a rehearsal-gate state', async () => {
    const onApply = vi.fn().mockRejectedValue({
      status: 409,
      code: 'PLAN_DIGEST_MISMATCH',
      details: { detail: DETAILS.digestMismatch },
    })
    renderGate(onApply)

    await clickApplyAndWait()

    expect(screen.getByTestId('digest-mismatch-error')).toBeInTheDocument()
    for (const testId of REHEARSAL_TESTIDS) {
      expect(screen.queryByTestId(testId)).not.toBeInTheDocument()
    }
  })
})

// ── §8.2 classifier unit tests ──────────────────────────────────────────────

describe('classifyApplyRehearsalError', () => {
  it('classifies assertion_run_missing', () => {
    expect(classifyApplyRehearsalError({ status: 409, details: { detail: DETAILS.missing } })).toBe(
      'assertion_run_missing'
    )
  })

  it('classifies assertion_run_digest_mismatch', () => {
    expect(
      classifyApplyRehearsalError({ status: 409, details: { detail: DETAILS.staleDigest } })
    ).toBe('assertion_run_digest_mismatch')
  })

  it('classifies assertion_run_in_progress', () => {
    expect(
      classifyApplyRehearsalError({ status: 409, details: { detail: DETAILS.inProgress } })
    ).toBe('assertion_run_in_progress')
  })

  it('classifies assertion_run_failed', () => {
    expect(classifyApplyRehearsalError({ status: 409, details: { detail: DETAILS.failed } })).toBe(
      'assertion_run_failed'
    )
  })

  it('returns not_rehearsal_related for a non-409 status', () => {
    expect(
      classifyApplyRehearsalError({ status: 400, details: { detail: DETAILS.missing } })
    ).toBe('not_rehearsal_related')
  })

  it('returns not_rehearsal_related for a 409 whose detail matches none of the four (e.g. the pre-existing digest_mismatch)', () => {
    expect(
      classifyApplyRehearsalError({ status: 409, details: { detail: DETAILS.digestMismatch } })
    ).toBe('not_rehearsal_related')
  })
})
