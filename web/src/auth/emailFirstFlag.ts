/** Email-first login build flag (REQ-438; design req434 section 11.3).
 *
 *  `VITE_EMAIL_FIRST_LOGIN` is a build-time Vite variable. Only the exact
 *  value `true` enables the email-first screen; absent, empty or anything else
 *  is OFF, which restores the pre-REQ-438 behaviour exactly (immediate
 *  default-realm redirect). It is read through this one helper so a test (or a
 *  later move to runtime config) has a single seam.
 *
 *  Enabling it outside dev is gated on the backend enablement gate (REQ-444)
 *  and the server-side mount switch; the SPA cannot check either. No committed
 *  non-dev env file or vite config may set it to true
 *  (web/src/auth/__tests__/emailFirstFlag.test.ts asserts this).
 */
export function isEmailFirstLoginEnabled(): boolean {
  return (import.meta.env.VITE_EMAIL_FIRST_LOGIN as string | undefined) === 'true'
}
