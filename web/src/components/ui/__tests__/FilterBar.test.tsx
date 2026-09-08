// @vitest-environment jsdom
/**
 * Unit tests — REQ-274: FilterBar design-system primitive
 *
 * TC-REQ274-08: children render inside FilterBar unmodified
 * TC-REQ274-09: onClear + activeCount>0 shows the clear action, which invokes onClear
 * TC-REQ274-10: onClear omitted (or activeCount=0) hides the clear action
 * TC-REQ274-11: activeCount>0 renders the active-count badge with the count
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { FilterBar } from '../FilterBar'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-274 — FilterBar', () => {
  it('TC-REQ274-08: renders children unmodified', () => {
    render(
      <FilterBar>
        <input data-testid="my-filter" placeholder="Search" />
      </FilterBar>,
    )

    expect(screen.getByTestId('my-filter')).toBeInTheDocument()
  })

  it('TC-REQ274-09: onClear + activeCount>0 shows the clear action and invokes onClear on click', () => {
    const onClear = vi.fn()
    render(
      <FilterBar onClear={onClear} activeCount={2}>
        <span>filter</span>
      </FilterBar>,
    )

    const clearAction = screen.getByTestId('filter-bar-clear')
    expect(clearAction).toBeInTheDocument()

    fireEvent.click(screen.getByText('Clear filters'))
    expect(onClear).toHaveBeenCalledTimes(1)
  })

  it('TC-REQ274-10: onClear omitted hides the clear action', () => {
    render(
      <FilterBar activeCount={2}>
        <span>filter</span>
      </FilterBar>,
    )

    expect(screen.queryByTestId('filter-bar-clear')).not.toBeInTheDocument()
  })

  it('TC-REQ274-10b: activeCount=0 hides the clear action even with onClear provided', () => {
    const onClear = vi.fn()
    render(
      <FilterBar onClear={onClear} activeCount={0}>
        <span>filter</span>
      </FilterBar>,
    )

    expect(screen.queryByTestId('filter-bar-clear')).not.toBeInTheDocument()
  })

  it('TC-REQ274-11: activeCount>0 renders the active-count badge', () => {
    render(
      <FilterBar activeCount={3}>
        <span>filter</span>
      </FilterBar>,
    )

    expect(screen.getByTestId('filter-bar-count')).toHaveTextContent('3')
  })
})
