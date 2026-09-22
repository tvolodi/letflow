/** useHelpContent — REQ-366 §2.2
 *
 *  Data-fetching hook backing `HelpTrigger`/`HelpPanel`
 *  (`web/src/components/help/`). Built on `@tanstack/react-query`, the
 *  existing convention every other `web/src/api/*.ts` consumer uses — no new
 *  data-fetching library (design §2.2).
 *
 *  Placed under `web/src/hooks/` (not `web/src/components/help/`, which the
 *  design's own §2.1 file-layout sketch names) so it falls under
 *  `tests/guards/forbidlist.ts`'s existing `missing-query-state-boundary`
 *  exemption for custom hooks ("Custom hooks return query results for
 *  callers to wrap" — that guard's own rationale comment). The public
 *  contract (function name, signature, `UseHelpContentResult` shape) is
 *  exactly design §2.2's; only the file's location follows this codebase's
 *  own established hooks-directory convention rather than the design's
 *  sketch, consistent with every other hook in `web/src/hooks/`.
 *
 *  §2.2.1 — a 404 from `GET /help/resolved` (no help authored for this
 *  screen_id yet) is the common case, not an error: distinguished here via
 *  `ApiError.status === 404` so `HelpTrigger` never renders an error state
 *  for a screen that simply has no help content.
 */

import { useQuery } from '@tanstack/react-query'
import { helpApi } from '@/api/help'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { ApiError } from '@/types/api'
import type { ResolvedHelpContent } from '@/types/help'

export type UseHelpContentResult =
  | { status: 'loading' }
  | { status: 'not-found' }
  | { status: 'error'; error: unknown }
  | { status: 'ready'; content: ResolvedHelpContent }

function isNotFound(error: unknown): boolean {
  return typeof error === 'object' && error !== null && (error as ApiError).status === 404
}

export function useHelpContent(screenId: string, processDefinitionId?: string): UseHelpContentResult {
  const helpKeys = useTenantScopedQueryKeys().help
  const query = useQuery({
    queryKey: helpKeys.resolved(screenId, processDefinitionId ?? null),
    queryFn: () => helpApi.getResolved(screenId, processDefinitionId),
    enabled: !!screenId,
    // A 404 (no help authored yet) is a stable, expected outcome, not a
    // transient failure worth retrying (design §2.2.1).
    retry: (failureCount, error) => !isNotFound(error) && failureCount < 1,
  })

  if (query.isLoading) return { status: 'loading' }

  if (query.isError) {
    if (isNotFound(query.error)) return { status: 'not-found' }
    return { status: 'error', error: query.error }
  }

  if (query.data) return { status: 'ready', content: query.data }

  return { status: 'loading' }
}
