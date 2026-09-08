// @vitest-environment jsdom
/**
 * Unit tests — REQ-275: JsonEditor design-system primitive
 *
 * TC-REQ275-13: onChange reports isValid: false for malformed JSON typed by the user
 * TC-REQ275-14: invalid JSON renders the error state (error border color + error message)
 * TC-REQ275-15: pretty-printing on blur — a valid, non-pretty JSON string is reformatted
 *   via onChange(pretty, true) when the field loses focus
 * TC-REQ275-16: empty string is treated as valid (no error state, isValid true) — §5.2
 * TC-REQ275-17: blur is a no-op while the value is invalid (no pretty-print attempted,
 *   error state persists as-is)
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { JsonEditor } from '../JsonEditor'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-275 — JsonEditor', () => {
  it('TC-REQ275-13: onChange reports isValid: false for malformed JSON input', () => {
    const onChange = vi.fn()
    render(<JsonEditor value="" onChange={onChange} label="Variables" />)

    const textarea = screen.getByTestId('json-editor-textarea')
    fireEvent.change(textarea, { target: { value: '{ "a": ' } })

    expect(onChange).toHaveBeenCalledWith('{ "a": ', false)
  })

  it('TC-REQ275-13b: onChange reports isValid: true for well-formed JSON input', () => {
    const onChange = vi.fn()
    render(<JsonEditor value="" onChange={onChange} label="Variables" />)

    const textarea = screen.getByTestId('json-editor-textarea')
    fireEvent.change(textarea, { target: { value: '{"a":1}' } })

    expect(onChange).toHaveBeenCalledWith('{"a":1}', true)
  })

  it('TC-REQ275-14: invalid JSON renders the error state (error border + error message)', () => {
    render(<JsonEditor value="{ invalid" onChange={vi.fn()} label="Variables" />)

    // jest-dom's toHaveStyle cannot parse a `border` shorthand containing a var()
    // reference (confirmed empirically), so the raw inline style string is asserted
    // directly, same escape hatch used by StatusBadge.test.tsx for `dot.style.animation`.
    const textarea = screen.getByTestId('json-editor-textarea') as HTMLTextAreaElement
    expect(textarea.style.border).toBe('1px solid var(--border-error)')
    expect(screen.getByTestId('json-editor-error')).toHaveTextContent('Invalid JSON')
  })

  it('TC-REQ275-14b: valid JSON renders no error state (default border, no error message)', () => {
    render(<JsonEditor value='{"a":1}' onChange={vi.fn()} label="Variables" />)

    const textarea = screen.getByTestId('json-editor-textarea') as HTMLTextAreaElement
    expect(textarea.style.border).toBe('1px solid var(--border-default)')
    expect(screen.queryByTestId('json-editor-error')).not.toBeInTheDocument()
  })

  it('TC-REQ275-15: pretty-prints a valid, non-pretty value on blur via onChange(pretty, true)', () => {
    const onChange = vi.fn()
    render(<JsonEditor value='{"a":1,"b":2}' onChange={onChange} label="Variables" />)

    const textarea = screen.getByTestId('json-editor-textarea')
    fireEvent.blur(textarea)

    expect(onChange).toHaveBeenCalledWith(JSON.stringify({ a: 1, b: 2 }, null, 2), true)
  })

  it('TC-REQ275-15b: blur is a no-op when the value is already pretty-printed', () => {
    const onChange = vi.fn()
    const pretty = JSON.stringify({ a: 1 }, null, 2)
    render(<JsonEditor value={pretty} onChange={onChange} label="Variables" />)

    fireEvent.blur(screen.getByTestId('json-editor-textarea'))

    expect(onChange).not.toHaveBeenCalled()
  })

  it('TC-REQ275-16: empty string is treated as valid — no error state', () => {
    render(<JsonEditor value="" onChange={vi.fn()} label="Variables" />)

    const textarea = screen.getByTestId('json-editor-textarea') as HTMLTextAreaElement
    expect(textarea.style.border).toBe('1px solid var(--border-default)')
    expect(screen.queryByTestId('json-editor-error')).not.toBeInTheDocument()
  })

  it('TC-REQ275-17: blur on an invalid value does not call onChange (no pretty-print attempted)', () => {
    const onChange = vi.fn()
    render(<JsonEditor value="{ invalid" onChange={onChange} label="Variables" />)

    fireEvent.blur(screen.getByTestId('json-editor-textarea'))

    expect(onChange).not.toHaveBeenCalled()
    // error state persists as-is
    expect(screen.getByTestId('json-editor-error')).toBeInTheDocument()
  })

  it('TC-REQ275-18: label, height, and readOnly are wired to rendered output', () => {
    render(<JsonEditor value="" onChange={vi.fn()} label="Payload" height={300} readOnly />)

    expect(screen.getByTestId('json-editor-label')).toHaveTextContent('Payload')
    const textarea = screen.getByTestId('json-editor-textarea') as HTMLTextAreaElement
    expect(textarea).toHaveStyle({ height: '300px' })
    expect(textarea).toHaveAttribute('readonly')
  })
})
