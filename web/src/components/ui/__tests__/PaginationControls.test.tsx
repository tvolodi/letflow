// @vitest-environment jsdom
/**
 * Unit tests — REQ-287: PaginationControls design-system primitive
 *
 * Spec: docs/frontend/design-system.md §7.8
 * Design: lib/letflow/design/req287-design-system-primitives-group4.md
 *
 * TC-REQ287-01: "Showing X-Y of Z" summary text, known total
 * TC-REQ287-02/02b: Previous disabled on page 1 / enabled otherwise
 * TC-REQ287-03/03b: Next disabled on last page (known total) / enabled otherwise
 * TC-REQ287-04: null-totalItems summary text omits "of Z"
 * TC-REQ287-05/05b/05c: null-totalItems Next disabled/enabled via hasNextPage,
 *   defaults to disabled when hasNextPage is omitted
 * TC-REQ287-06/06b: page-size selector renders 25/50/100 when onPageSizeChange is
 *   supplied, is entirely absent when it is not
 * TC-REQ287-07/07b: onPageChange/onPageSizeChange wiring
 * TC-REQ287-08: keyboard operability + accessible names (FNFR-03/WCAG 2.1 AA)
 * TC-REQ287-09: disabled state is the native `disabled` attribute, not styling-only
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
expect.extend(jestDomMatchers)

import { PaginationControls, PAGE_SIZE_OPTIONS } from '../PaginationControls'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-287 — PaginationControls', () => {
  it('TC-REQ287-01: renders "Showing X-Y of Z" when totalItems is known', () => {
    render(
      <PaginationControls page={1} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    expect(screen.getByTestId('pagination-summary')).toHaveTextContent('Showing 1-25 of 120')
  })

  it('TC-REQ287-01b: "Showing X-Y of Z" reflects a later page and a partial last page', () => {
    render(
      <PaginationControls page={5} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    // start = (5-1)*25+1 = 101, end = min(5*25, 120) = 120
    expect(screen.getByTestId('pagination-summary')).toHaveTextContent('Showing 101-120 of 120')
  })

  it('TC-REQ287-02: Previous is disabled on page 1', () => {
    render(
      <PaginationControls page={1} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    expect(screen.getByRole('button', { name: 'Previous' })).toBeDisabled()
  })

  it('TC-REQ287-02b: Previous is enabled on any page after 1', () => {
    render(
      <PaginationControls page={2} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    expect(screen.getByRole('button', { name: 'Previous' })).toBeEnabled()
  })

  it('TC-REQ287-03: Next is disabled on the last page (known total, page*pageSize >= totalItems)', () => {
    render(
      <PaginationControls page={5} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    // page*pageSize = 125 >= 120
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled()
  })

  it('TC-REQ287-03b: Next is enabled when not on the last page (known total)', () => {
    render(
      <PaginationControls page={1} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    // page*pageSize = 25 < 120
    expect(screen.getByRole('button', { name: 'Next' })).toBeEnabled()
  })

  it('TC-REQ287-04: null totalItems renders "Showing X-Y" with no "of Z" suffix', () => {
    render(
      <PaginationControls
        page={2}
        pageSize={25}
        totalItems={null}
        onPageChange={vi.fn()}
        hasNextPage={true}
      />,
    )
    // start = (2-1)*25+1 = 26, end = 2*25 = 50
    const summary = screen.getByTestId('pagination-summary')
    expect(summary).toHaveTextContent('Showing 26-50')
    expect(summary.textContent).not.toMatch(/of/)
  })

  it('TC-REQ287-05: null totalItems, hasNextPage=false disables Next', () => {
    render(
      <PaginationControls
        page={1}
        pageSize={25}
        totalItems={null}
        onPageChange={vi.fn()}
        hasNextPage={false}
      />,
    )
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled()
  })

  it('TC-REQ287-05b: null totalItems, hasNextPage=true enables Next', () => {
    render(
      <PaginationControls
        page={1}
        pageSize={25}
        totalItems={null}
        onPageChange={vi.fn()}
        hasNextPage={true}
      />,
    )
    expect(screen.getByRole('button', { name: 'Next' })).toBeEnabled()
  })

  it('TC-REQ287-05c: null totalItems with hasNextPage omitted defaults Next to disabled', () => {
    render(<PaginationControls page={1} pageSize={25} totalItems={null} onPageChange={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled()
  })

  it('TC-REQ287-06: page-size selector renders exactly the 25/50/100 options when onPageSizeChange is supplied', () => {
    render(
      <PaginationControls
        page={1}
        pageSize={25}
        totalItems={120}
        onPageChange={vi.fn()}
        onPageSizeChange={vi.fn()}
      />,
    )
    const select = screen.getByTestId('pagination-size-select')
    expect(select).toBeInTheDocument()
    const optionValues = Array.from(select.querySelectorAll('option')).map((o) => o.textContent)
    expect(optionValues).toEqual(PAGE_SIZE_OPTIONS.map((size) => `${size} / page`))
  })

  it('TC-REQ287-06b: page-size selector is entirely absent when onPageSizeChange is not supplied', () => {
    render(
      <PaginationControls page={1} pageSize={25} totalItems={120} onPageChange={vi.fn()} />,
    )
    expect(screen.queryByTestId('pagination-size-select')).toBeNull()
  })

  it('TC-REQ287-07: clicking Previous/Next calls onPageChange with page-1/page+1', async () => {
    const user = userEvent.setup()
    const onPageChange = vi.fn()
    render(
      <PaginationControls page={2} pageSize={25} totalItems={120} onPageChange={onPageChange} />,
    )
    await user.click(screen.getByRole('button', { name: 'Previous' }))
    expect(onPageChange).toHaveBeenLastCalledWith(1)
    await user.click(screen.getByRole('button', { name: 'Next' }))
    expect(onPageChange).toHaveBeenLastCalledWith(3)
  })

  it('TC-REQ287-07b: changing the page-size selector calls onPageSizeChange with the numeric value', async () => {
    const user = userEvent.setup()
    const onPageSizeChange = vi.fn()
    render(
      <PaginationControls
        page={1}
        pageSize={25}
        totalItems={120}
        onPageChange={vi.fn()}
        onPageSizeChange={onPageSizeChange}
      />,
    )
    await user.selectOptions(screen.getByTestId('pagination-size-select'), '50')
    expect(onPageSizeChange).toHaveBeenCalledWith(50)
  })

  it('TC-REQ287-08: Previous/Next are real, keyboard-reachable buttons with visible accessible names', async () => {
    const user = userEvent.setup()
    const onPageChange = vi.fn()
    render(
      <PaginationControls page={2} pageSize={25} totalItems={120} onPageChange={onPageChange} />,
    )
    const prev = screen.getByRole('button', { name: 'Previous' })
    const next = screen.getByRole('button', { name: 'Next' })
    expect(prev.tagName).toBe('BUTTON')
    expect(next.tagName).toBe('BUTTON')

    await user.tab()
    expect(prev).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(onPageChange).toHaveBeenLastCalledWith(1)

    await user.tab()
    expect(next).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(onPageChange).toHaveBeenLastCalledWith(3)
  })

  it('TC-REQ287-09: disabled state is exposed via the native `disabled` HTML attribute, not styling-only', () => {
    render(<PaginationControls page={1} pageSize={25} totalItems={120} onPageChange={vi.fn()} />)
    const prev = screen.getByRole('button', { name: 'Previous' })
    expect(prev).toHaveAttribute('disabled')
    expect(prev).toBeDisabled()
  })
})
