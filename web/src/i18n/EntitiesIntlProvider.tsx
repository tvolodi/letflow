/** EntitiesIntlProvider — REQ-336
 *
 *  A local, self-contained `<IntlProvider>` scoped to the entities screens
 *  this requirement adds. No app-wide `<IntlProvider>` exists yet in
 *  web/src/main.tsx (react-intl's `createIntl()` is used imperatively, for
 *  date/time formatting only — see web/src/i18n/format.ts) — adding one at
 *  the app root is out of this requirement's scope (it is infrastructure
 *  affecting every existing page, not "a component this requirement adds").
 *  Wrapping locally, at the entities pages' own root, keeps react-intl's
 *  `useIntl()`/`<FormattedMessage>` usable inside the new components without
 *  touching main.tsx or any pre-existing page.
 */

import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { entitiesMessages, resolveUiLocale } from './entitiesMessages'

export function EntitiesIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={entitiesMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
