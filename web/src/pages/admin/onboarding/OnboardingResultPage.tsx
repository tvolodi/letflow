/** OnboardingResultPage — ONB-UI-04
 *
 * Shows the final outcome of the onboarding saga.
 *
 * State restore priority:
 * 1. Router location.state.sagaResult (forward navigation from progress screen)
 * 2. GET /api/v1/onboarding?hostname=<h> (page-reload restore via URL search param)
 * 3. "Could not restore" fallback (no state, no hostname, or 404)
 *
 * Role guard: redirects to /instances if session does not include PLATFORM_ADMIN.
 * All hooks are called before the early return per React rules.
 */

import { useEffect, useState } from 'react'
import { Navigate, useNavigate, useParams, useLocation, Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'
import { Button } from '@/components/ui/Button'
import {
  getOnboardingByHostname,
  OnboardingApiError,
  type OnboardingFormValues,
  type OnboardingStatusCompleted,
  type OnboardingStatusFailed,
  type OnboardingSagaResult,
} from '@/api/onboarding'

// ── Types ──────────────────────────────────────────────────────────────────────

type ViewState =
  | { phase: 'loading' }
  | { phase: 'completed'; result: OnboardingStatusCompleted; formValues?: OnboardingFormValues }
  | { phase: 'failed'; result: OnboardingStatusFailed; formValues?: OnboardingFormValues }
  | { phase: 'restore-failed' }

// ── Helpers ────────────────────────────────────────────────────────────────────

function resolveViewFromSaga(
  result: OnboardingSagaResult,
  formValues?: OnboardingFormValues,
): ViewState {
  if (result.state === 'completed') {
    return { phase: 'completed', result, formValues }
  }
  if (result.state === 'failed') {
    return { phase: 'failed', result, formValues }
  }
  // pending — should not normally reach result screen; treat as restore-failed
  return { phase: 'restore-failed' }
}

// ── Styles ─────────────────────────────────────────────────────────────────────

const tdLabelStyle: React.CSSProperties = {
  padding: '.45rem .75rem .45rem 0',
  fontWeight: 600,
  fontSize: '.87rem',
  color: 'var(--text-primary)',
  verticalAlign: 'top',
  whiteSpace: 'nowrap',
  width: '160px',
}

const tdValueStyle: React.CSSProperties = {
  padding: '.45rem 0',
  fontSize: '.87rem',
  color: 'var(--text-primary)',
  wordBreak: 'break-all',
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function OnboardingResultPage() {
  const { session } = useAuth()
  const { onboardingId } = useParams<{ onboardingId: string }>()
  const navigate = useNavigate()
  const location = useLocation()

  const locationState = location.state as {
    sagaResult?: OnboardingSagaResult
    formValues?: OnboardingFormValues
  } | null

  const [view, setView] = useState<ViewState>(() => {
    if (locationState?.sagaResult) {
      return resolveViewFromSaga(locationState.sagaResult, locationState.formValues)
    }
    return { phase: 'loading' }
  })

  useEffect(() => {
    // If we already have a result from router state, skip the fetch
    if (locationState?.sagaResult) return

    const params = new URLSearchParams(location.search)
    const hostname = params.get('hostname')

    if (!hostname) {
      setView({ phase: 'restore-failed' })
      return
    }

    let cancelled = false

    getOnboardingByHostname(hostname)
      .then((result) => {
        if (!cancelled) {
          setView({ phase: 'completed', result })
        }
      })
      .catch((err) => {
        if (!cancelled) {
          if (err instanceof OnboardingApiError && err.httpStatus === 404) {
            setView({ phase: 'restore-failed' })
          } else {
            setView({ phase: 'restore-failed' })
          }
        }
      })

    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Role guard — after all hooks
  if (!session?.roles.includes('PLATFORM_ADMIN')) {
    return <Navigate to="/instances" replace />
  }

  // ── Render ───────────────────────────────────────────────────────────────────

  if (view.phase === 'loading') {
    return (
      <div style={{ padding: '2rem', color: 'var(--text-secondary)' }}>
        Restoring onboarding state…
      </div>
    )
  }

  if (view.phase === 'restore-failed') {
    return (
      <div style={{ padding: '2rem', maxWidth: '520px' }}>
        <h2 style={{ margin: '0 0 1rem 0' }}>Could not restore onboarding state</h2>
        <p style={{ color: 'var(--text-secondary)', marginBottom: '1.5rem' }}>
          The onboarding record for this page could not be retrieved. The saga may have failed, or the URL may be invalid.
        </p>
        {/* Navigational CTA styled as a button -- kept as Link (not Button, which
            has no href/anchor semantics) so browser features (open-in-new-tab,
            middle-click) keep working. */}
        <Link
          to="/admin/onboarding/new"
          style={{
            display: 'inline-block',
            padding: '.5rem 1.2rem',
            background: 'var(--interactive-primary)',
            color: 'var(--text-inverse)',
            textDecoration: 'none',
            borderRadius: 'var(--radius-sm)',
            fontWeight: 600,
            fontSize: '.9rem',
          }}
        >
          Start over
        </Link>
      </div>
    )
  }

  if (view.phase === 'completed') {
    return (
      <div style={{ padding: '2rem', maxWidth: '520px' }}>
        <div
          style={{
            marginBottom: '1.5rem',
            padding: '.75rem 1rem',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--color-success-border)',
            background: 'var(--color-success-tint)',
            color: 'var(--color-success-dark)',
            fontWeight: 600,
          }}
        >
          Tenant onboarding completed successfully.
        </div>

        <table style={{ borderCollapse: 'collapse', width: '100%', marginBottom: '1.5rem' }}>
          <tbody>
            <tr>
              <td style={tdLabelStyle}>Slug</td>
              <td style={tdValueStyle}>
                <code>{view.result.slug ?? onboardingId}</code>
              </td>
            </tr>
            <tr>
              <td style={tdLabelStyle}>OIDC Authority</td>
              <td style={tdValueStyle}>
                <a href={view.result.oidc_authority} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--interactive-primary)' }}>
                  {view.result.oidc_authority}
                </a>
              </td>
            </tr>
            {view.result.hostname && (
              <tr>
                <td style={tdLabelStyle}>Hostname</td>
                <td style={tdValueStyle}>{view.result.hostname}</td>
              </tr>
            )}
          </tbody>
        </table>

        {view.result.slug && (
          // Navigational CTA to a per-tenant hostname outside the SPA's own
          // router -- kept as a plain <a>, not Button, for the same reason
          // as "Start over" above. Colour consolidated onto the same
          // --interactive-primary token as the other CTAs on this page
          // rather than reusing --color-avatar-teal, which tokens.css
          // reserves explicitly for actor-avatar backgrounds only.
          <a
            href={`${window.location.origin}/?realm=${view.result.slug}`}
            style={{
              display: 'inline-block',
              marginBottom: '1rem',
              padding: '.5rem 1.2rem',
              background: 'var(--interactive-primary)',
              color: 'var(--text-inverse)',
              textDecoration: 'none',
              borderRadius: 'var(--radius-sm)',
              fontWeight: 600,
              fontSize: '.9rem',
            }}
          >
            Open {view.result.slug} workspace
          </a>
        )}

        <Button variant="primary" size="md" onClick={() => navigate('/admin/users')}>
          Back to Admin
        </Button>
      </div>
    )
  }

  // phase === 'failed'
  const failureReason =
    view.result.error?.trim() || 'Onboarding failed. No additional detail is available.'

  return (
    <div style={{ padding: '2rem', maxWidth: '520px' }}>
      <div
        style={{
          marginBottom: '1.5rem',
          padding: '.75rem 1rem',
          borderRadius: 'var(--radius-sm)',
          border: '1px solid var(--color-error-border)',
          background: 'var(--color-error-tint)',
          color: 'var(--color-error-dark)',
        }}
      >
        <strong>Onboarding failed.</strong>
        <p style={{ margin: '.5rem 0 0 0', fontSize: '.88rem' }}>{failureReason}</p>
      </div>

      <Button
        variant="primary"
        size="md"
        onClick={() => {
          navigate('/admin/onboarding/new', {
            state: view.formValues ? { prefill: view.formValues } : undefined,
          })
        }}
      >
        Try Again
      </Button>
    </div>
  )
}
