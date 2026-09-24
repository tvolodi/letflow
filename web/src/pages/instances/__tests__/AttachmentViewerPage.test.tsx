// @vitest-environment jsdom
/**
 * Component-level coverage for AttachmentViewerPage's ViewerStatus state
 * machine (REQ-387 §3.2/§3.3) -- each branch is exercised in isolation by
 * mocking @/api/attachments directly. The permanent e2e spec
 * (attachment-cross-tenant.pipeline.e2e.spec.ts) proves the real end-to-end
 * behavior against a running backend; this file proves the state machine
 * itself renders the right component for each response shape, the same
 * "unit coverage in addition to the e2e spec" gap TEST-DESIGNER already
 * flagged once for REQ-381.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-1'
const ATTACHMENT_ID = 'att-1'

// jsdom does not implement URL.createObjectURL/revokeObjectURL — stub them
// so AttachmentSuccessView's mount effect (D1: blob -> object URL) doesn't
// throw. Real browsers (and Playwright's Chromium, per the e2e spec) have
// the real implementation; this is a test-environment gap only.
if (typeof URL.createObjectURL !== 'function') {
  URL.createObjectURL = vi.fn(() => 'blob:mock-object-url')
}
if (typeof URL.revokeObjectURL !== 'function') {
  URL.revokeObjectURL = vi.fn()
}

const issueLink = vi.fn()
const fetchLinkContent = vi.fn()

vi.mock('@/api/attachments', () => ({
  attachmentsApi: {
    issueLink: (...args: unknown[]) => issueLink(...args),
    fetchLinkContent: (...args: unknown[]) => fetchLinkContent(...args),
  },
}))

import AttachmentViewerPage from '@/pages/instances/AttachmentViewerPage'

function apiError(status: number) {
  return { status, message: 'err', code: String(status) }
}

function renderPage(initialPath = `/instances/${INSTANCE_ID}/attachments/${ATTACHMENT_ID}`) {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/instances/:id/attachments/:attachmentId" element={<AttachmentViewerPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('AttachmentViewerPage — ViewerStatus state machine', () => {
  it('renders AttachmentSuccessView (PDF) for a valid, unexpired link', async () => {
    issueLink.mockResolvedValue({
      attachment_id: ATTACHMENT_ID,
      token: 'tok-1',
      url: '/ignored',
      expires_at: '2026-09-23T00:05:00Z',
      expires_in_seconds: 300,
    })
    const blob = new Blob(['%PDF-1.4'], { type: 'application/pdf' })
    fetchLinkContent.mockResolvedValue({ blob, contentType: 'application/pdf' })

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('attachment-content')).toBeInTheDocument()
    })
    expect(issueLink).toHaveBeenCalledWith(INSTANCE_ID, ATTACHMENT_ID)
    expect(fetchLinkContent).toHaveBeenCalledWith(INSTANCE_ID, ATTACHMENT_ID, 'tok-1')
  })

  it('renders content via a browser-local blob: object URL, never the raw backend link-content URL (D1)', async () => {
    issueLink.mockResolvedValue({
      attachment_id: ATTACHMENT_ID,
      token: 'tok-1',
      url: '/ignored',
      expires_at: '2026-09-23T00:05:00Z',
      expires_in_seconds: 300,
    })
    const blob = new Blob(['%PDF-1.4'], { type: 'application/pdf' })
    fetchLinkContent.mockResolvedValue({ blob, contentType: 'application/pdf' })

    renderPage()

    // AttachmentSuccessView renders twice: an empty `attachment-content`
    // placeholder while objectUrl is still null, then (after a second,
    // inner useEffect calls URL.createObjectURL) the same testid containing
    // the <iframe>. Waiting only for the container -- as the previous
    // version of this test did -- can resolve on the placeholder render,
    // racing the synchronous querySelector('iframe') assertion that used to
    // follow it (ISS-0817). Wait for the iframe itself so the assertion
    // can't observe the intermediate, iframe-less render.
    const iframe = await waitFor(() => {
      const content = screen.getByTestId('attachment-content')
      const el = content.querySelector('iframe')
      expect(el).not.toBeNull()
      return el
    })
    const src = iframe!.getAttribute('src') ?? ''
    // D1: must be a same-origin blob: object URL created from the
    // authenticated fetch's bytes -- never a direct pointer at the backend
    // link-content route (which the browser would fetch with no
    // Authorization header and 401 against).
    expect(src.startsWith('blob:')).toBe(true)
    expect(src).not.toContain('/api/v1/instances/')
    expect(src).not.toContain('link-content')
  })

  it('renders AttachmentNotFoundScreen (zero props) when link issuance 404s', async () => {
    issueLink.mockRejectedValue(apiError(404))

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('attachment-not-found')).toBeInTheDocument()
    })
    expect(fetchLinkContent).not.toHaveBeenCalled()
    expect(screen.getByText('Document not found.')).toBeInTheDocument()
  })

  it('renders the SAME AttachmentNotFoundScreen when content-fetch 404s (deleted after issuance)', async () => {
    issueLink.mockResolvedValue({
      attachment_id: ATTACHMENT_ID,
      token: 'tok-2',
      url: '/ignored',
      expires_at: '2026-09-23T00:05:00Z',
      expires_in_seconds: 300,
    })
    fetchLinkContent.mockRejectedValue(apiError(404))

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('attachment-not-found')).toBeInTheDocument()
    })
    expect(screen.getByText('Document not found.')).toBeInTheDocument()
  })

  it('foreign-tenant (issuance 404) and never-issued (issuance 404) renders are byte-identical text -- AC3', async () => {
    issueLink.mockRejectedValue(apiError(404))
    const { unmount } = renderPage(`/instances/foreign/attachments/${ATTACHMENT_ID}`)
    await waitFor(() => expect(screen.getByTestId('attachment-not-found')).toBeInTheDocument())
    const firstText = screen.getByTestId('attachment-not-found').textContent
    unmount()
    cleanup()
    vi.clearAllMocks()

    issueLink.mockRejectedValue(apiError(404))
    renderPage(`/instances/never-issued/attachments/${ATTACHMENT_ID}`)
    await waitFor(() => expect(screen.getByTestId('attachment-not-found')).toBeInTheDocument())
    const secondText = screen.getByTestId('attachment-not-found').textContent

    expect(secondText).toBe(firstText)
  })

  it('renders AttachmentLinkExpiredScreen for a 410 content-fetch response, with no document content', async () => {
    issueLink.mockResolvedValue({
      attachment_id: ATTACHMENT_ID,
      token: 'tok-3',
      url: '/ignored',
      expires_at: '2026-09-23T00:05:00Z',
      expires_in_seconds: 300,
    })
    fetchLinkContent.mockRejectedValue(apiError(410))

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('attachment-link-expired')).toBeInTheDocument()
    })
    expect(screen.queryByTestId('attachment-content')).not.toBeInTheDocument()
    expect(screen.getByTestId('attachment-request-fresh-link')).toBeInTheDocument()
  })

  it('renders AttachmentErrorScreen for a 500/422 response (catch-all, distinct from not-found)', async () => {
    issueLink.mockRejectedValue(apiError(500))

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('attachment-error')).toBeInTheDocument()
    })
    expect(screen.queryByTestId('attachment-not-found')).not.toBeInTheDocument()
  })

  it('skips issuance and fetches content directly when the URL already carries link_token (reload/bookmark)', async () => {
    const blob = new Blob(['hello'], { type: 'text/plain' })
    fetchLinkContent.mockResolvedValue({ blob, contentType: 'text/plain' })

    renderPage(`/instances/${INSTANCE_ID}/attachments/${ATTACHMENT_ID}?link_token=carried-token`)

    await waitFor(() => {
      expect(screen.getByTestId('attachment-content')).toBeInTheDocument()
    })
    expect(issueLink).not.toHaveBeenCalled()
    expect(fetchLinkContent).toHaveBeenCalledWith(INSTANCE_ID, ATTACHMENT_ID, 'carried-token')
  })
})
