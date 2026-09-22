import { Outlet, NavLink } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { ApiConnectivityBanner } from './ApiConnectivityBanner'
import { TestEnvironmentBanner } from './TestEnvironmentBanner'
import { TenantHeader } from './TenantHeader'
import { dlqApi } from '@/api/dlq'
import { queryKeys } from '@/api/queryKeys'
import { useBranding } from '@/theming/BrandingContext'

type Role = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER' | 'CANDIDATE'

interface NavItem {
  to: string
  label: string
  roles: Role[]
}

const NAV_ITEMS: NavItem[] = [
  { to: '/instances',     label: 'Instances',   roles: ['PLATFORM_ADMIN', 'PROCESS_DESIGNER', 'PROCESS_OPERATOR'] },
  { to: '/tasks',         label: 'My Tasks',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR', 'TASK_WORKER'] },
  { to: '/exam',          label: 'Exams',       roles: ['CANDIDATE'] },
  { to: '/definitions',  label: 'Definitions', roles: ['PLATFORM_ADMIN', 'PROCESS_DESIGNER'] },
  { to: '/dlq',           label: 'DLQ',         roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  { to: '/webhooks',      label: 'Webhooks',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  { to: '/admin/users',   label: 'Users',       roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/groups',  label: 'Groups',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/tokens',  label: 'Tokens',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/audit',   label: 'Audit',       roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/health',  label: 'Health',      roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/metrics', label: 'Metrics',     roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/onboarding/new', label: 'Register Tenant', roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/tenants',       label: 'Tenants',          roles: ['PLATFORM_ADMIN'] },
  { to: '/admin/services',       label: 'Services',         roles: ['PLATFORM_ADMIN'] },
  // REQ-343: question-bank/exam admin screens. Gated to the two roles that
  // actually hold Letflow.Api.Authorization's :EntitiesRecordsWrite
  // permission (REQ-309's role matrix) -- PLATFORM_ADMIN (catch-all) and
  // PROCESS_OPERATOR. PROCESS_DESIGNER holds :EntitiesDefinitionsWrite but
  // NOT :EntitiesRecordsWrite, and TASK_WORKER holds neither, so a member of
  // either role could not actually create/edit/delete a record here even if
  // shown the nav entry. There is no dedicated "question-bank editor" role
  // in Letflow.Api.Authorization.roles() to gate on instead:
  // priv/packs/bilimbaga/pack.json's manifest.required_roles
  // ("examiner", "department_admin", ...) is read-only advisory only (see
  // priv/packs/bilimbaga/README.md and REQ-325) and creates no real,
  // frontend-visible role -- citing the same role-registry checklist
  // REQ-328's pack install established, rather than inventing a role name.
  { to: '/admin/bilimbaga',      label: 'Question Bank',    roles: ['PLATFORM_ADMIN', 'PROCESS_OPERATOR'] },
  // REQ-375: operator-facing rollout-status screen for REQ-374's
  // platform-wide tenant-migration fanout runner. Same :TenantsManage
  // (PLATFORM_ADMIN-only) risk class as admin/tenants, admin/onboarding.
  { to: '/admin/platform-migrations', label: 'Platform Migrations', roles: ['PLATFORM_ADMIN'] },
  // REQ-381: solution-pack update review screen. `/solution-packs` needs a
  // discoverable nav link (unlike PromotionReviewPage.tsx's deliberate
  // no-nav-entry choice) -- REQ-381's own text requires the review screen
  // be "reachable from the company's pack screen," and the launcher page
  // serves that role (design §7). PLATFORM_ADMIN-only, same OQ-3 judgment
  // call as the launcher/review pages' own role gate (design §4.1).
  { to: '/solution-packs', label: 'Solution Packs', roles: ['PLATFORM_ADMIN'] },
  // REQ-377: operator-facing history-retirement screen for REQ-376's
  // whole-partition retirement mechanism. Same :TenantsManage
  // (PLATFORM_ADMIN-only) risk class as admin/platform-migrations.
  { to: '/admin/event-retention', label: 'Event Retention', roles: ['PLATFORM_ADMIN'] },
]

export function AppShell() {
  const { session, logout } = useAuth()
  const { appName, logoUrl } = useBranding()

  const dlqThreshold = Number(import.meta.env.VITE_DLQ_ALERT_THRESHOLD ?? '10')
  const { data: dlqSummary } = useQuery({
    queryKey: queryKeys.dlq.list({ status: 'pending', page_size: 101 }),
    queryFn: () => dlqApi.list({ status: 'pending', page_size: 101 }),
    refetchInterval: 15000,
  })

  const pendingDlqCount = dlqSummary?.items?.length ?? 0
  const dlqSeverity = pendingDlqCount <= 0 ? 'none' : (pendingDlqCount > dlqThreshold ? 'critical' : 'warning')

  const visibleNav = NAV_ITEMS.filter((n) =>
    n.roles.some((r) => session?.roles.includes(r)),
  )

  return (
    <div style={{ display: 'flex', minHeight: '100vh', fontFamily: 'system-ui, sans-serif' }}>
      {/* Sidebar */}
      <aside
        style={{
          width: '220px',
          background: 'var(--surface-sidebar)',
          color: 'var(--color-neutral-400)',
          display: 'flex',
          flexDirection: 'column',
          padding: '1.5rem 0',
          flexShrink: 0,
        }}
      >
        <div style={{ padding: '0 1.25rem', marginBottom: '1.5rem', display: 'flex', alignItems: 'center', gap: '.5rem', fontWeight: 700, fontSize: '1.1rem', color: 'var(--color-neutral-100)' }}>
          {logoUrl != null && (
            <img src={logoUrl} alt={appName} style={{ height: '1.5rem', width: 'auto' }} />
          )}
          {appName}
        </div>

        <TenantHeader />

        <nav style={{ flex: 1 }}>
          {visibleNav.map((n) => (
            <NavLink
              key={n.to}
              to={n.to}
              style={({ isActive }) => ({
                display: 'block',
                padding: '.5rem 1.25rem',
                color: isActive ? 'var(--color-neutral-100)' : 'var(--color-neutral-500)',
                background: isActive ? 'var(--color-sidebar-active)' : 'transparent',
                textDecoration: 'none',
                fontSize: '.9rem',
                borderLeft: isActive ? '3px solid var(--interactive-primary)' : '3px solid transparent',
              })}
            >
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: '.5rem' }}>
                {n.label}
                {n.to === '/dlq' && dlqSeverity !== 'none' && (
                  <span
                    style={{
                      minWidth: '1.25rem',
                      padding: '0 .35rem',
                      borderRadius: '999px',
                      fontSize: '.72rem',
                      lineHeight: '1.15rem',
                      textAlign: 'center',
                      fontWeight: 700,
                      color: 'var(--text-primary)',
                      background: dlqSeverity === 'critical' ? 'var(--color-error)' : 'var(--color-warning)',
                    }}
                    aria-label={`DLQ pending count ${pendingDlqCount}`}
                  >
                    {pendingDlqCount}
                  </span>
                )}
              </span>
            </NavLink>
          ))}
        </nav>

        <div style={{ padding: '.75rem 1.25rem', borderTop: '1px solid var(--color-sidebar-active)', fontSize: '.8rem', color: 'var(--text-secondary)' }}>
          <div
            data-testid="user-display-name"
            style={{ marginBottom: '.25rem', color: 'var(--color-neutral-500)' }}
          >
            {session?.display_name}
          </div>
          <div
            data-testid="user-roles"
            style={{ marginBottom: '.5rem', color: 'var(--text-secondary)', fontSize: '.75rem' }}
          >
            {session?.roles.join(', ')}
          </div>
          <button
            data-testid="logout-button"
            onClick={logout}
            style={{ background: 'none', border: 'none', color: 'var(--text-secondary)', cursor: 'pointer', padding: 0, fontSize: '.8rem' }}
          >
            Sign out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <main style={{ flex: 1, overflow: 'auto', background: 'var(--surface-page)' }}>
        <TestEnvironmentBanner />
        <ApiConnectivityBanner />
        <Outlet />
      </main>
    </div>
  )
}
