/** ExamIntlProvider — REQ-338
 *
 *  A local `<IntlProvider>` scoped to the candidate exam-taking screens
 *  (web/src/pages/exam/), following the exact pattern
 *  web/src/i18n/EntitiesIntlProvider.tsx (REQ-336) established: no app-wide
 *  `<IntlProvider>` exists in web/src/main.tsx yet, so each requirement that
 *  needs `useIntl()`/`<FormattedMessage>` wraps its own screens locally.
 */

import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { examMessages, resolveUiLocale } from './examMessages'

export function ExamIntlProvider({ children }: { children: ReactNode }) {
  const locale = resolveUiLocale()
  return (
    <IntlProvider locale={locale} defaultLocale="en" messages={examMessages[locale]}>
      {children}
    </IntlProvider>
  )
}
