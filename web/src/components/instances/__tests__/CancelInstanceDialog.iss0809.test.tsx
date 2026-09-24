// @vitest-environment jsdom
/**
 * ISS-0809: CancelInstanceDialog must show the real definition name and version,
 * not 'undefined v undefined' when ProcessInstance.definition_name/version are absent.
 *
 * Root cause: InstanceDetailPage.tsx:379 (before fix) read instance.definition_name and
 * instance.definition_version, but GET /api/v1/instances/:id only emits definition_id.
 * Fix: InstanceDetailPage now passes definition?.name + definition?.version (sourced
 * from the separately-fetched useDefinition call) to instanceName, same as the detail
 * row (cb3c6c49). This test pins the dialog's rendered content against the fixed prop.
 */

import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'

expect.extend(jestDomMatchers)

import { CancelInstanceDialog } from '@/components/instances/CancelInstanceDialog'

const noop = () => {}

afterEach(() => cleanup())

describe('ISS-0809 — CancelInstanceDialog instance name rendering', () => {
  it('TC-ISS0809-01: renders real definition name and version when definition is loaded', () => {
    render(
      React.createElement(CancelInstanceDialog, {
        open: true,
        instanceId: 'inst-abc',
        instanceName: 'hire-process v1.0',
        onConfirm: noop,
        onCancel: noop,
        isPending: false,
      }),
    )

    expect(screen.getByText(/This will cancel instance hire-process v1\.0\./)).toBeInTheDocument()
    // Regression: must NOT contain 'undefined'
    expect(screen.queryByText(/undefined/)).not.toBeInTheDocument()
  })

  it('TC-ISS0809-02: renders placeholder when definition has not yet loaded (instanceName is "—")', () => {
    render(
      React.createElement(CancelInstanceDialog, {
        open: true,
        instanceId: 'inst-xyz',
        instanceName: '—',
        onConfirm: noop,
        onCancel: noop,
        isPending: false,
      }),
    )

    // Neutral placeholder shown while definition is still fetching — never 'undefined'
    expect(screen.getByText(/This will cancel instance —\./)).toBeInTheDocument()
    expect(screen.queryByText(/undefined/)).not.toBeInTheDocument()
  })

  it('TC-ISS0809-03: dialog is not shown when open=false', () => {
    render(
      React.createElement(CancelInstanceDialog, {
        open: false,
        instanceId: 'inst-xyz',
        instanceName: 'some-process v2.0',
        onConfirm: noop,
        onCancel: noop,
        isPending: false,
      }),
    )

    // Dialog content must not be in the DOM when closed
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })
})
