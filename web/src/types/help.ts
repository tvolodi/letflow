/** Help types — REQ-366 §2
 *
 *  Mirrors `lib/letflow/routers/help.ex`'s `resolved_help_json/3` response
 *  shape (design §1.6/§2.2) field-for-field. Read directly from that
 *  router's source (not re-derived from the design doc alone) before
 *  writing this file — the wire shape is snake_case; `ResolvedHelpContent`
 *  is this file's own camelCase mirror, mapped in `web/src/api/help.ts`.
 */

/** Wire shape — `GET /api/v1/help/resolved`'s JSON body, verbatim. */
export interface ResolvedHelpContentResponse {
  id: string
  screen_id: string
  process_definition_id: string | null
  title: string
  body: string
  status: 'live'
  confirmed_at: string | null
  confirmed_for_definition_version: string | null
  media: unknown[]
  scope: 'tenant' | 'platform'
  stale: boolean
}

/** camelCase mirror consumed by `web/src/components/help/*` and
 *  `web/src/hooks/useHelpContent.ts` (design §2.2). */
export interface ResolvedHelpContent {
  id: string
  screenId: string
  processDefinitionId: string | null
  title: string
  body: string
  status: 'live'
  confirmedAt: string | null
  confirmedForDefinitionVersion: string | null
  media: unknown[]
  scope: 'tenant' | 'platform'
  stale: boolean
}

/** `content.media`'s one recognised element shape (design §5.1) — no other
 *  requirement defines an element shape, so anything not matching this is
 *  skipped silently by `HelpPanel`, never crashed on. */
export interface HelpMediaImage {
  type: 'image'
  url: string
}

export function isHelpMediaImage(item: unknown): item is HelpMediaImage {
  return (
    typeof item === 'object' &&
    item !== null &&
    (item as { type?: unknown }).type === 'image' &&
    typeof (item as { url?: unknown }).url === 'string'
  )
}
