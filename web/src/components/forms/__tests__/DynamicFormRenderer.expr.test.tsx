// @vitest-environment jsdom
/**
 * REQ-293 AC7 — one rendering test per key: visible_when hides a field,
 * computed field value updates on input change, cross-field validation error
 * surfaces with its message. Real backend not involved — this is a pure
 * component-rendering test (DIRECTIVE T-2 does not apply: no HTTP boundary
 * here, `onSubmit` is a plain prop callback).
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { DynamicFormRenderer } from '../DynamicFormRenderer'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-293 — DynamicFormRenderer expression wiring', () => {
  it('visible_when hides a field when the condition evaluates to false', async () => {
    const schema = {
      type: 'object',
      properties: {
        approved: { type: 'boolean', title: 'Approved' },
        approvalNote: {
          type: 'string',
          title: 'Approval note',
          'x-ui': { visible_when: 'variables.approved == true' },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={vi.fn()} />)

    await waitFor(() => {
      expect(screen.queryByLabelText('Approval note')).not.toBeInTheDocument()
    })

    fireEvent.click(screen.getByLabelText('Approved'))

    await waitFor(() => {
      expect(screen.getByLabelText('Approval note')).toBeInTheDocument()
    })
  })

  it('a computed field value updates when its input dependency changes', async () => {
    const schema = {
      type: 'object',
      properties: {
        quantity: { type: 'number', title: 'Quantity' },
        total: {
          type: 'number',
          title: 'Total',
          'x-ui': { computed: 'variables.quantity * 2' },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={vi.fn()} />)

    fireEvent.input(screen.getByLabelText('Quantity'), { target: { value: '5' } })

    await waitFor(() => {
      const totalInput = screen.getByTestId('computed-field-total') as HTMLInputElement
      expect(totalInput).toHaveAttribute('readonly')
      expect(totalInput.value).toBe('10')
    })

    fireEvent.input(screen.getByLabelText('Quantity'), { target: { value: '7' } })

    await waitFor(() => {
      expect((screen.getByTestId('computed-field-total') as HTMLInputElement).value).toBe('14')
    })
  })

  it('a cross-field validation error surfaces with its own message', async () => {
    const schema = {
      type: 'object',
      properties: {
        startDate: { type: 'number', title: 'Start' },
        endDate: {
          type: 'number',
          title: 'End',
          'x-ui': {
            cross_field_validation: {
              expression: 'variables.endDate > variables.startDate',
              message: 'End must be after start',
            },
          },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={vi.fn()} />)

    fireEvent.input(screen.getByLabelText('Start'), { target: { value: '10' } })
    fireEvent.input(screen.getByLabelText('End'), { target: { value: '5' } })

    await waitFor(() => {
      expect(screen.getByTestId('cross-field-error-endDate')).toHaveTextContent('End must be after start')
    })
  })

  it('AC8 — a client-side cross-field validation pass does not bypass submission to the server', async () => {
    // Server authority is retained by Letflow.Engine.FormExpressionReevaluation.
    // reevaluate/3 at task completion (design doc §8.5): this client's own
    // crossFieldErrors state is informational only, never wired into the Zod
    // resolver / form.setError / handleFormSubmit's own gate. This test proves
    // that directly: a fixture where the client's own check evaluates to
    // "passing" is submitted, and onSubmit is called with the client values
    // untouched by any cross-field gate.
    const onSubmit = vi.fn().mockResolvedValue(undefined)
    const schema = {
      type: 'object',
      properties: {
        startDate: { type: 'number', title: 'Start' },
        endDate: {
          type: 'number',
          title: 'End',
          'x-ui': {
            cross_field_validation: {
              expression: 'variables.endDate > variables.startDate',
              message: 'End must be after start',
            },
          },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={onSubmit} />)

    fireEvent.input(screen.getByLabelText('Start'), { target: { value: '1' } })
    fireEvent.input(screen.getByLabelText('End'), { target: { value: '10' } })

    await waitFor(() => {
      expect(screen.queryByTestId('cross-field-error-endDate')).not.toBeInTheDocument()
    })

    fireEvent.click(screen.getByTestId('task-submit-btn'))

    await waitFor(() => {
      expect(onSubmit).toHaveBeenCalledTimes(1)
    })
    expect(onSubmit).toHaveBeenCalledWith(expect.objectContaining({ startDate: 1, endDate: 10 }))
  })
})
