import { Navigate } from 'react-router-dom'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { healthReady } from '@/api/health'
import { queryKeys } from '@/api/queryKeys'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'

// NOTE (ISS-0532): this page used to render per-subsystem `database`/
// `scheduler` status sourced from `GET /health/ready`, a route the backend
// does not serve (see `docs/frontend/contract-gaps.md` row 15 — readiness
// requires S6 observability probes that do not exist yet). That 404 was
// silently mapped into a fabricated "degraded" snapshot with invented
// component statuses. Rather than keep inventing subsystem data the backend
// cannot provide, this page now degrades to an honest liveness-only view,
// backed by the real `GET /health` endpoint, and says plainly that
// per-subsystem readiness is not available yet.
export function useAdminHealthSnapshot(): UseQueryResult<boolean> {
  return useQuery({
    queryKey: queryKeys.admin.health(),
    queryFn: () => healthReady(),
    refetchInterval: 15_000,
  })
}

export default function HealthDashboardPage() {
  const { session } = useAuth()
  const isPlatformAdmin = Boolean(session?.roles.includes('PLATFORM_ADMIN'))
  const { data: isLive, isLoading, isFetching, isError, error, dataUpdatedAt, refetch } = useAdminHealthSnapshot()

  if (!isPlatformAdmin) {
    return <Navigate to="/instances" replace />
  }

  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'
  const livenessLabel = isLive ? 'LIVE' : 'UNREACHABLE'
  const livenessColor = isLive ? '#16a34a' : '#dc2626'

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '1rem', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Health</h2>
        {dataUpdatedAt > 0 && (
          <span style={{ fontSize: '.8rem', color: '#94a3b8' }}>
            Updated {new Date(dataUpdatedAt).toLocaleTimeString()}
          </span>
        )}
        {isFetching && <span style={{ fontSize: '.8rem', color: '#0369a1' }}>Refreshing…</span>}
        <button
          onClick={() => {
            void refetch()
          }}
          style={{ marginLeft: 'auto', padding: '.35rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', background: '#fff', cursor: 'pointer', fontSize: '.82rem' }}
        >
          Refresh now
        </button>
      </div>

      <QueryStateBoundary state={rendererState} onRetry={() => { void refetch() }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', marginBottom: '1.25rem' }}>
          <span
            data-testid="liveness-badge"
            style={{ fontWeight: 700, fontSize: '1.2rem', color: livenessColor }}
          >
            {livenessLabel}
          </span>
          <span style={{ color: '#64748b', fontSize: '.9rem' }}>Backend liveness (GET /health)</span>
        </div>

        <div
          data-testid="readiness-not-available"
          role="status"
          style={{
            padding: '.9rem 1rem',
            borderRadius: '6px',
            border: '1px solid #cbd5e1',
            background: '#f8fafc',
            color: '#475569',
            fontSize: '.9rem',
          }}
        >
          Per-subsystem readiness (database, scheduler) is not available yet —
          it requires observability instrumentation planned for a later stage
          (S6) that has not been built. This page currently reports basic
          backend liveness only, from the real <code>GET /health</code>{' '}
          endpoint.
        </div>
      </QueryStateBoundary>
    </div>
  )
}
