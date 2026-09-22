/** REQ-383 — tenant self-service settings API client.
 *
 * Wraps `PATCH /api/v1/tenant/settings` (REQ-382,
 * `lib/letflow/routers/tenant_settings.ex`). Unlike `tenants.ts`, this
 * endpoint has NO target-tenant path parameter — it always patches the
 * caller's own tenant (`conn.assigns.auth_context.tenant_id`). Kept as its
 * own module rather than added to `tenants.ts`, whose whole surface is
 * slug-addressed per-tenant-registry operations (design doc §1/§3.3).
 *
 * This screen sends exactly one shape and nothing else:
 * `{ settings: { brand_colors: { primary } } }` — see
 * `lib/letflow/design/req383-appearance-settings-screen.md` §5 for the
 * closed-form argument that AppearanceSettingsPage cannot construct any
 * other request body.
 */
import { client } from './client'

export interface TenantSettingsPatchBody {
  settings: {
    brand_colors: {
      primary: string // "#RRGGBB" — the only key this screen ever sends
    }
  }
}

export interface TenantSettingsPatchResponse {
  tenant_id: string
  settings: Record<string, unknown> // full merged settings map (REQ-382 §3 step 9b)
}

export const tenantSettingsApi = {
  patchBrandColorPrimary: (primary: string) =>
    client.patch<TenantSettingsPatchResponse>('/api/v1/tenant/settings', {
      settings: { brand_colors: { primary } },
    } satisfies TenantSettingsPatchBody),
}
