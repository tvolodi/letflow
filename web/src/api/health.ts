import { client } from './client'
import type { HealthStatus } from '@/types/api'

// NOTE (ISS-0532): a readiness endpoint (`GET /health/ready`) used to be
// probed from here for both the site-wide connectivity banner and the admin
// Health dashboard. It does not exist on the backend — `lib/letflow/router.ex`
// deliberately does not port R-Co's readiness route; it requires S6
// observability subsystem probes that do not exist yet (see that router's
// moduledoc, and `docs/frontend/contract-gaps.md` row 15). Every call to it
// 404'd, which `healthReady()` silently swallowed into a permanent false
// "platform unavailable" banner. Fixed by pointing both callers at the real
// `GET /health` liveness endpoint instead. See
// `docs/frontend/contract-gaps.md` row 15 for the current status of true
// per-subsystem readiness (still gated on S6).

// `GET /api/v1/health` (`healthApi.get`) has no callers anywhere in
// `web/src` as of ISS-0532's diagnosis. Left in place — removing it is a
// separate, unrelated cleanup, not part of this fix.
export const healthApi = {
  get: () => client.get<HealthStatus>('/api/v1/health'),
}

/**
 * Connectivity probe — raw fetch to `GET /health` (liveness, not readiness;
 * see the ISS-0532 note above for why).
 * Returns true if the backend responds with a 2xx status.
 * Returns false on any error (network failure, timeout, non-2xx).
 * Never throws.
 */
export async function healthReady(): Promise<boolean> {
  try {
    await client.get<unknown>('/health')
    return true
  } catch {
    return false
  }
}
