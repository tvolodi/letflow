// @vitest-environment jsdom
/**
 * Tests for BrandingProvider.tsx — REQ-283 (0020 D1c, theming half).
 *
 * Covers AC2b (the /api/tenant-config call fails outright -> platform-default
 * fallback) and AC4 (a markup-injection logo_url value is passed through the
 * context as an opaque string, never interpreted). AC4's rendered-<img>
 * assertion lives in AppShell.branding.test.tsx per the design doc's test plan
 * (section 8, item 5) — this file verifies the provider/context boundary.
 *
 * DIRECTIVE T-2 / design doc section 8: mock web/src/api/client.ts's
 * client.get directly (no msw, no raw fetch mocking) — the same pattern
 * tenantConfig.ts's own module already relies on.
 *
 * tenantConfig.ts caches its result in a module-level singleton, so each test
 * resets the module registry (vi.resetModules) and re-imports BrandingProvider
 * fresh to get an un-cached fetchTenantConfig.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'

expect.extend(jestDomMatchers)

vi.mock('@/api/client', () => ({
  client: { get: vi.fn() },
}))

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  document.documentElement.removeAttribute('style')
})

/** Minimal consumer that surfaces useBranding()'s current value as text/DOM,
 * standing in for AppShell without pulling in its unrelated dependencies
 * (auth, dlq queries, tenant header). */
async function renderWithFreshProvider(mockedGetImpl: (...args: unknown[]) => unknown) {
  vi.resetModules()

  const clientModule = await import('@/api/client')
  vi.mocked(clientModule.client.get).mockImplementation(mockedGetImpl as never)

  const { BrandingProvider } = await import('../BrandingProvider')
  const { useBranding } = await import('../BrandingContext')

  function Probe() {
    const { appName, logoUrl } = useBranding()
    return (
      <div>
        <span data-testid="probe-app-name">{appName}</span>
        <span data-testid="probe-logo-url">{logoUrl ?? ''}</span>
      </div>
    )
  }

  render(
    <BrandingProvider>
      <Probe />
    </BrandingProvider>,
  )
}

describe('BrandingProvider', () => {
  it('AC2b: endpoint call fails outright -> context resolves to the platform default, never throws, never blank', async () => {
    await renderWithFreshProvider(() => Promise.reject(new Error('network partition')))

    await waitFor(() => {
      expect(screen.getByTestId('probe-app-name')).toHaveTextContent('Letflow')
    })
    expect(screen.getByTestId('probe-logo-url')).toHaveTextContent('')
  })

  it('AC4: a logo_url containing markup is passed through the context as an opaque string, never interpreted', async () => {
    const malicious = '"><img src=x onerror=window.__pwned=true>'

    await renderWithFreshProvider(() =>
      Promise.resolve({
        oidc_authority: 'http://example.invalid/realm',
        client_id: 'letflow-web',
        branding: {
          app_name: 'Letflow',
          logo_url: malicious,
          brand_colors: {},
        },
      }),
    )

    await waitFor(() => {
      expect(screen.getByTestId('probe-logo-url')).toHaveTextContent(malicious)
    })

    // Never interpreted as markup: no extra element, no global pollution.
    expect((window as unknown as { __pwned?: boolean }).__pwned).toBeUndefined()
    expect(document.body.querySelectorAll('img').length).toBe(0)
    expect(document.body.querySelectorAll('[onerror]').length).toBe(0)
  })

  it('AC4 (javascript: scheme): a javascript: logo_url is passed through as an opaque string, never executed', async () => {
    const jsScheme = 'javascript:window.__pwned2=true'

    await renderWithFreshProvider(() =>
      Promise.resolve({
        oidc_authority: 'http://example.invalid/realm',
        client_id: 'letflow-web',
        branding: {
          app_name: 'Letflow',
          logo_url: jsScheme,
          brand_colors: {},
        },
      }),
    )

    await waitFor(() => {
      expect(screen.getByTestId('probe-logo-url')).toHaveTextContent(jsScheme)
    })
    expect((window as unknown as { __pwned2?: boolean }).__pwned2).toBeUndefined()
  })
})
