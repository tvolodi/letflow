// @vitest-environment jsdom
/**
 * REQ-366 §2.2.1/§2.3 — HelpTrigger
 *
 * TC-REQ366-17: status: 'not-found' renders nothing (no error toast, no
 *   affordance) — design §2.2.1's own explicit requirement.
 * TC-REQ366-18: status: 'loading' renders nothing (no flicker).
 * TC-REQ366-19: status: 'error' renders nothing (a purely-assistive
 *   affordance never surfaces as a visible error state).
 * TC-REQ366-20: status: 'ready' renders the "?" affordance; clicking it
 *   opens HelpPanel with the resolved content.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { HelpTrigger } from '../HelpTrigger'
import type { ResolvedHelpContent } from '@/types/help'

expect.extend(jestDomMatchers)

const mockUseHelpContent = vi.fn()

vi.mock('@/hooks/useHelpContent', () => ({
  useHelpContent: (...args: unknown[]) => mockUseHelpContent(...args),
}))

afterEach(() => {
  vi.clearAllMocks()
  cleanup()
})

const content: ResolvedHelpContent = {
  id: 'help-1',
  screenId: 'exam-list',
  processDefinitionId: null,
  title: 'Exam list help',
  body: 'Body',
  status: 'live',
  confirmedAt: '2026-09-01T00:00:00Z',
  confirmedForDefinitionVersion: null,
  media: [],
  scope: 'tenant',
  stale: false,
}

describe('HelpTrigger', () => {
  it('TC-REQ366-17: not-found renders nothing', () => {
    mockUseHelpContent.mockReturnValue({ status: 'not-found' })
    const { container } = render(<HelpTrigger screenId="exam-list" />)
    expect(container).toBeEmptyDOMElement()
  })

  it('TC-REQ366-18: loading renders nothing', () => {
    mockUseHelpContent.mockReturnValue({ status: 'loading' })
    const { container } = render(<HelpTrigger screenId="exam-list" />)
    expect(container).toBeEmptyDOMElement()
  })

  it('TC-REQ366-19: error renders nothing', () => {
    mockUseHelpContent.mockReturnValue({ status: 'error', error: new Error('boom') })
    const { container } = render(<HelpTrigger screenId="exam-list" />)
    expect(container).toBeEmptyDOMElement()
  })

  it('TC-REQ366-20: ready renders the trigger and opens HelpPanel on click', () => {
    mockUseHelpContent.mockReturnValue({ status: 'ready', content })
    render(<HelpTrigger screenId="exam-list" />)

    expect(screen.queryByTestId('help-panel')).toBeNull()
    fireEvent.click(screen.getByTestId('help-trigger'))
    expect(screen.getByTestId('help-panel')).toBeInTheDocument()
    expect(screen.getByTestId('help-panel-title')).toHaveTextContent('Exam list help')
  })
})
