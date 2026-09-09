import { createContext, useContext } from 'react'
import { DEFAULT_BRANDING_CONTEXT_VALUE, type BrandingContextValue } from './brandingDefaults'

/**
 * Publishes { appName, logoUrl } to consumers (e.g. AppShell's sidebar).
 * Default value (used when no <BrandingProvider> ancestor exists, and for the
 * one render before BrandingProvider's fetch resolves) is the platform default —
 * never blank, never a thrown error. See BrandingProvider.tsx and design doc
 * section 2 step 5.
 */
export const BrandingContext = createContext<BrandingContextValue>(DEFAULT_BRANDING_CONTEXT_VALUE)

export function useBranding(): BrandingContextValue {
  return useContext(BrandingContext)
}
