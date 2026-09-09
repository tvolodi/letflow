/**
 * Applies tenant-supplied brand colours as CSS custom-property overrides on
 * document.documentElement. No React here — see BrandingProvider.tsx for the
 * component that calls this on mount.
 *
 * REQ-283 (0020 D1c). See lib/letflow/design/req283-branding-css-theming.md
 * section 3 for the full design rationale.
 */
import { BRAND_COLOR_CSS_PROPERTY } from './brandingDefaults'

/**
 * Sets CSS custom properties for every key present in the closed
 * BRAND_COLOR_CSS_PROPERTY allowlist and also present (as a non-empty string) in
 * `brandColors`. Any key in `brandColors` that is NOT in the allowlist is never
 * read and never reaches the DOM — this function iterates the allowlist's OWN
 * keys, never `Object.keys(brandColors)`, so a tenant-supplied object can never
 * widen which CSS custom properties this function is capable of touching.
 *
 * Absent/falsy values are left untouched: tokens.css's own cascade default
 * continues to apply (see design doc section 4 — "one rule, three triggering
 * cases", all of which collapse to "do not override").
 */
export function applyBrandingColors(brandColors: Record<string, string> | undefined): void {
  const allowlistedKeys = Object.keys(BRAND_COLOR_CSS_PROPERTY) as Array<keyof typeof BRAND_COLOR_CSS_PROPERTY>

  for (const key of allowlistedKeys) {
    const value = brandColors?.[key]
    if (typeof value === 'string' && value.length > 0) {
      document.documentElement.style.setProperty(BRAND_COLOR_CSS_PROPERTY[key], value)
    }
  }
}
