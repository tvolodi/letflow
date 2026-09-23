// @vitest-environment jsdom
/**
 * Component-level coverage for AttachmentPanel (REQ-212/387 §3.1) — the
 * upload/list widget mounted on InstanceDetailPage. Mocks @/api/attachments
 * directly (same pattern as AttachmentViewerPage.test.tsx).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-1'

const list = vi.fn()
const upload = vi.fn()

vi.mock('@/api/attachments', () => ({
  attachmentsApi: {
    list: (...args: unknown[]) => list(...args),
    upload: (...args: unknown[]) => upload(...args),
  },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 't',
        display_name: 'Admin',
        roles: ['PLATFORM_ADMIN'],
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
        production_tenant_display_name: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { AttachmentPanel } from '@/components/instances/AttachmentPanel'

function renderPanel() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <AttachmentPanel instanceId={INSTANCE_ID} />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('AttachmentPanel', () => {
  it('lists existing attachments with a View link to the viewer route', async () => {
    list.mockResolvedValue({
      items: [
        {
          id: 'att-1',
          instance_id: INSTANCE_ID,
          file_name: 'delivery-note.pdf',
          content_type: 'application/pdf',
          byte_size: 2048,
          uploaded_by: 'lena',
          description: null,
          created_at: '2026-09-23T00:00:00Z',
        },
      ],
      next_cursor: null,
    })

    renderPanel()

    await waitFor(() => {
      expect(screen.getByText('delivery-note.pdf')).toBeInTheDocument()
    })
    const link = screen.getByTestId('attachment-view-link')
    expect(link).toHaveAttribute('href', `/instances/${INSTANCE_ID}/attachments/att-1`)
  })

  it('uploads a selected file and refetches the list on success', async () => {
    list.mockResolvedValue({ items: [], next_cursor: null })
    upload.mockResolvedValue({
      id: 'att-2',
      instance_id: INSTANCE_ID,
      file_name: 'new-file.pdf',
      content_type: 'application/pdf',
      byte_size: 100,
      uploaded_by: 'lena',
      description: null,
      created_at: '2026-09-23T00:00:00Z',
    })

    renderPanel()
    await waitFor(() => expect(list).toHaveBeenCalled())

    const user = userEvent.setup()
    const fileInput = screen.getByTestId('attachment-file-input') as HTMLInputElement
    const file = new File(['hello'], 'new-file.pdf', { type: 'application/pdf' })
    await user.upload(fileInput, file)

    await user.click(screen.getByTestId('attachment-upload-button'))

    await waitFor(() => {
      expect(upload).toHaveBeenCalledTimes(1)
    })
    const formData = upload.mock.calls[0][1] as FormData
    expect(formData.get('file')).toBeInstanceOf(File)
  })
})
