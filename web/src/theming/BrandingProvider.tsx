import { useEffect, useState, type ReactNode } from 'react'
import { fetchTenantConfig } from '@/auth/tenantConfig'
import { applyBrandingColors } from './applyBranding'
import { BrandingContext } from './BrandingContext'
import { DEFAULT_BRANDING_CONTEXT_VALUE, PLATFORM_DEFAULT_APP_NAME, type BrandingContextValue } from './brandingDefaults'

/**
 * Mounted once at the app root (web/src/main.tsx), wrapping <RouterProvider>.
 *
 * On mount, calls the EXISTING fetchTenantConfig(window.location.hostname) —
 * the same module-level cache main.tsx's pre-warm call already populates, so
 * this never issues a duplicate network request (see design doc section 2).
 *
 * fetchTenantConfig never rejects (it catches internally and resolves to its
 * own fallback object), so no .catch() is needed here — every one of the three
 * fallback cases in design doc section 4 is already handled by fetchTenantConfig
 * itself plus this component's `?.`/`??` reads.
 */
export function BrandingProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<BrandingContextValue>(DEFAULT_BRANDING_CONTEXT_VALUE)

  useEffect(() => {
    let cancelled = false

    void fetchTenantConfig(window.location.hostname).then((config) => {
      applyBrandingColors(config.branding?.brand_colors)

      if (cancelled) return
      setValue({
        appName: config.branding?.app_name ?? PLATFORM_DEFAULT_APP_NAME,
        logoUrl: config.branding?.logo_url ?? null,
      })
    })

    return () => {
      cancelled = true
    }
  }, [])

  return <BrandingContext.Provider value={value}>{children}</BrandingContext.Provider>
}
