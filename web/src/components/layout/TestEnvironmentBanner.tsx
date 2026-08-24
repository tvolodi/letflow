import type React from 'react'
import { useTenantContext } from '@/auth/useTenantContext'

export function TestEnvironmentBanner(): React.ReactElement | null {
  const { tenantType, productionDisplayName } = useTenantContext()

  if (tenantType !== 'test') {
    return null
  }

  const pairedText = productionDisplayName !== null
    ? `Paired with production: ${productionDisplayName}`
    : 'Paired with production: (unknown)'

  return (
    <div
      role="banner"
      aria-label="Test environment indicator"
      data-testid="test-environment-banner"
      style={{
        position: 'sticky',
        top: 0,
        zIndex: 200,
        background: 'var(--color-warning-banner)',
        color: 'var(--color-warning-text)',
        borderBottom: '1px solid var(--color-warning)',
        padding: '.5rem 1.25rem',
        display: 'flex',
        alignItems: 'center',
        gap: '.75rem',
        fontSize: '.875rem',
      }}
    >
      <span style={{ fontWeight: 700 }}>TEST ENVIRONMENT</span>
      <span style={{ fontWeight: 400 }}>{pairedText}</span>
    </div>
  )
}
