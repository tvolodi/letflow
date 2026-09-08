// @vitest-environment jsdom
/**
 * Unit tests — REQ-272: Button design-system primitive
 *
 * TC-REQ272-01: renders each variant/size without throwing, exposes children
 * TC-REQ272-02: onClick fires on a normal click
 * TC-REQ272-03: disabled prevents click (onClick never called) and disables the element
 * TC-REQ272-04: loading renders a spinner, disables the element, and prevents click
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { Button, type ButtonProps } from '../Button'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const VARIANTS: ButtonProps['variant'][] = ['primary', 'secondary', 'danger', 'ghost']
const SIZES: ButtonProps['size'][] = ['sm', 'md', 'lg']

describe('REQ-272 — Button', () => {
  describe.each(VARIANTS)('TC-REQ272-01: variant=%s', variant => {
    it.each(SIZES)('renders size=%s with its label', size => {
      render(
        <Button variant={variant} size={size}>
          Label
        </Button>,
      )
      const btn = screen.getByTestId('ds-button')
      expect(btn).toBeVisible()
      expect(btn).toHaveTextContent('Label')
    })
  })

  it('TC-REQ272-02: onClick fires when an enabled button is clicked', () => {
    const onClick = vi.fn()
    render(
      <Button variant="primary" size="md" onClick={onClick}>
        Save
      </Button>,
    )
    fireEvent.click(screen.getByTestId('ds-button'))
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('TC-REQ272-03: disabled renders a disabled element and prevents onClick from firing', () => {
    const onClick = vi.fn()
    render(
      <Button variant="primary" size="md" disabled onClick={onClick}>
        Save
      </Button>,
    )
    const btn = screen.getByTestId('ds-button')
    expect(btn).toBeDisabled()
    fireEvent.click(btn)
    expect(onClick).not.toHaveBeenCalled()
  })

  it('TC-REQ272-04: loading renders a spinner, disables the element, and prevents onClick from firing', () => {
    const onClick = vi.fn()
    render(
      <Button variant="primary" size="md" loading onClick={onClick}>
        Save
      </Button>,
    )
    const btn = screen.getByTestId('ds-button')
    expect(btn).toBeDisabled()
    expect(screen.getByTestId('ds-button-spinner')).toBeInTheDocument()
    fireEvent.click(btn)
    expect(onClick).not.toHaveBeenCalled()
  })

  it('TC-REQ272-05: not loading and not disabled renders no spinner', () => {
    render(
      <Button variant="primary" size="md">
        Save
      </Button>,
    )
    expect(screen.queryByTestId('ds-button-spinner')).not.toBeInTheDocument()
  })
})
