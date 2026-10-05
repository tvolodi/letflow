/** LoginIntlProvider -- REQ-438
 *
 *  Page-local `<IntlProvider>` for the public login page, in the style of
 *  EntitiesIntlProvider.tsx (no app-wide provider exists). Reuses
 *  `resolveUiLocale` from entitiesMessages.ts.
 */
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { resolveUiLocale } from './entitiesMessages'
import { loginMessages } from './loginMessages'

export function LoginIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={loginMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
