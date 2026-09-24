/** attachments API client — REQ-212/386/387
 *
 *  Follows web/src/api/entities.ts's own shape exactly: a plain object of
 *  named functions wrapping client.get/post/getBlob, typed against
 *  web/src/types/api.ts. Not a new client abstraction.
 *
 *  ⛔ THE REAL ROUTE TABLE (lib/letflow/routers/instances.ex), confirmed by
 *  lib/letflow/design/req387-attachment-document-viewer.md §0 against the
 *  shipped source, not the REQ-386 design doc's paraphrase:
 *
 *  - `POST   /api/v1/instances/:id/attachments`                         (:AttachmentsManage, multipart)
 *  - `GET    /api/v1/instances/:id/attachments`                         (:AttachmentsRead, cursor-paginated)
 *  - `DELETE /api/v1/instances/:id/attachments/:attachment_id`          (:AttachmentsManage)
 *  - `POST   /api/v1/instances/:id/attachments/:attachment_id/link`         (:AttachmentsRead) — REQ-386
 *  - `GET    /api/v1/instances/:id/attachments/:attachment_id/link-content` (:AttachmentsRead) — REQ-386
 *
 *  `issueLink` has no idempotency/reuse contract — every call issues a
 *  fresh, independently-valid signed link (REQ-386 design §2.2 AC3).
 *  `fetchLinkContent` uses `client.getBlob`, not `client.get` — attachment
 *  bytes are binary, never JSON.
 */

import { client } from './client'
import type { Attachment, AttachmentsPage, AttachmentLink, AttachmentBlob, StorageUsage } from '@/types/api'

export const attachmentsApi = {
  /** `POST /api/v1/instances/:id/attachments`, multipart. `file` required,
   *  `description` optional. Caller builds and passes the FormData; this
   *  function does not construct it (matches client.post's own existing
   *  `body instanceof FormData` passthrough). */
  upload: (instanceId: string, formData: FormData): Promise<Attachment> =>
    client.post<Attachment>(`/api/v1/instances/${encodeURIComponent(instanceId)}/attachments`, formData),

  /** `GET /api/v1/instances/:id/attachments` -- cursor-paginated. */
  list: (instanceId: string, params?: { cursor?: string; page_size?: number }): Promise<AttachmentsPage> =>
    client.get<AttachmentsPage>(`/api/v1/instances/${encodeURIComponent(instanceId)}/attachments`, params),

  /** `DELETE /api/v1/instances/:id/attachments/:attachment_id`. */
  delete: (instanceId: string, attachmentId: string): Promise<void> =>
    client.delete<void>(
      `/api/v1/instances/${encodeURIComponent(instanceId)}/attachments/${encodeURIComponent(attachmentId)}`,
    ),

  /** `POST /api/v1/instances/:id/attachments/:attachment_id/link` -- REQ-386.
   *  Issues a fresh, independently-valid ~5-minute signed link every call. */
  issueLink: (instanceId: string, attachmentId: string): Promise<AttachmentLink> =>
    client.post<AttachmentLink>(
      `/api/v1/instances/${encodeURIComponent(instanceId)}/attachments/${encodeURIComponent(attachmentId)}/link`,
    ),

  /** `GET /api/v1/instances/:id/attachments/:attachment_id/link-content` --
   *  REQ-386. `token` is passed as the `link_token` query param, matching
   *  the shipped route's own query-param name exactly. Uses client.getBlob
   *  (never client.get) -- attachment bytes are binary. */
  fetchLinkContent: (instanceId: string, attachmentId: string, token: string): Promise<AttachmentBlob> =>
    client.getBlob(
      `/api/v1/instances/${encodeURIComponent(instanceId)}/attachments/${encodeURIComponent(attachmentId)}/link-content`,
      { link_token: token },
    ),

  /** `GET /api/v1/instances/storage-usage` -- REQ-392 §1.2. Tenant-wide, not
   *  instance-scoped -- no `:id` path segment, matches
   *  `Attachments.storage_summary/1`'s own per-tenant scope. */
  storageUsage: (): Promise<StorageUsage> => client.get<StorageUsage>('/api/v1/instances/storage-usage'),
}
