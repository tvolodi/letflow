/** Auth context — adapted from ai-dala-forge/frontend/src/core/auth/AuthContext.tsx */

import { createContext, useContext } from 'react'
import type { UserSession } from '@/types/api'

/** REQ-384 §5.3 — outcome of an in-app tenant switch. */
export type SwitchTenantOutcome = 'ok' | 'interaction_required' | 'error'

export interface AuthContextValue {
  session: UserSession | null
  isAuthenticated: boolean
  isLoading: boolean
  loginSource: 'oidc' | null
  login: (token: string) => Promise<void>
  logout: () => void
  setSession: (s: UserSession) => void
  /** REQ-384 §5.3 — in-app, no-full-page-reload switch to `targetSlug`. See
   *  `AuthProvider.tsx`'s own implementation for the exact ordering
   *  (cache-clear-before-setSessionState) that AC3 depends on. */
  switchTenant: (targetSlug: string) => Promise<SwitchTenantOutcome>
  /** REQ-384 §7.3.2 — the switch currently in flight, or null. Drives the
   *  shell remount `key` and `TenantSwitchTransitionScreen` (§7.3.3). */
  switchingToTenantSlug: string | null
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined)

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>')
  return ctx
}
